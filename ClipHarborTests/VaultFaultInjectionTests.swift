import XCTest
import CryptoKit
@testable import ClipHarbor

// MARK: - テスト用モック（本番データ・Keychain・UserDefaults・実ファイル完全隔離）

@MainActor
final class MockVaultKeychainStorage: VaultKeychainStorageProtocol {
    var storedKey: SymmetricKey?
    var saveCallCount = 0
    var loadCallCount = 0
    var deleteCallCount = 0

    func saveBiometricMasterKey(_ key: SymmetricKey) -> Bool {
        saveCallCount += 1
        storedKey = key
        return true
    }

    func loadBiometricMasterKey() -> SymmetricKey? {
        loadCallCount += 1
        return storedKey
    }

    @discardableResult
    func deleteBiometricMasterKey() -> Bool {
        deleteCallCount += 1
        storedKey = nil
        return true
    }
}

@MainActor
final class MockDownloadManager: VaultDownloadManaging {
    var savedVideos: [UUID: SavedVideo] = [:]
    var persistShouldFail: Bool = false
    var removeCalledForIDs: [UUID] = []

    func removeSavedVideoWithoutDeletingFile(id: UUID) {
        removeCalledForIDs.append(id)
        savedVideos.removeValue(forKey: id)
    }

    func restoreSavedVideoThrowing(_ video: SavedVideo) throws {
        if persistShouldFail {
            throw NSError(domain: "MockDownloadManager", code: 500, userInfo: [
                NSLocalizedDescriptionKey: "Simulated persistSaved failure"
            ])
        }
        savedVideos[video.id] = video
    }
}

@MainActor
final class MockFolderManager: VaultFolderManaging {
    var folderMap: [UUID: String] = [:]
    var removedVideoIDs: [UUID] = []

    func folderName(for video: SavedVideo) -> String {
        folderMap[video.id] ?? ""
    }

    func removeVideoFromFolder(videoID: UUID) {
        removedVideoIDs.append(videoID)
        folderMap.removeValue(forKey: videoID)
    }

    func restoreVideoToFolder(_ video: SavedVideo, targetFolder: String) {
        folderMap[video.id] = targetFolder
    }
}

@MainActor
final class MockThumbnailManager: VaultThumbnailManaging {
    var cache: [UUID: UIImage] = [:]
    var invalidatedIDs: [UUID] = []

    func cachedThumbnail(for video: SavedVideo) -> UIImage? {
        cache[video.id]
    }

    func cacheThumbnail(_ image: UIImage, for video: SavedVideo) {
        cache[video.id] = image
    }

    func invalidateCache(for video: SavedVideo) {
        invalidatedIDs.append(video.id)
        cache.removeValue(forKey: video.id)
    }
}

// MARK: - XCTestCase

@MainActor
final class VaultFaultInjectionTests: XCTestCase {

    private struct TestEnv {
        let baseDir: URL
        let downloadsDir: URL
        let vault: VaultManager
        let mockDownloads: MockDownloadManager
        let mockFolders: MockFolderManager
        let mockThumbnails: MockThumbnailManager
        let mockKeychain: MockVaultKeychainStorage

        func cleanup() {
            try? FileManager.default.removeItem(at: baseDir)
        }
    }

    private func createTestEnvironment() throws -> TestEnv {
        let fileManager = FileManager.default
        let baseDir = fileManager.temporaryDirectory.appendingPathComponent("VaultTest_\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: baseDir, withIntermediateDirectories: true)

        let downloadsDir = baseDir.appendingPathComponent("IsolatedDownloads", isDirectory: true)
        try fileManager.createDirectory(at: downloadsDir, withIntermediateDirectories: true)

        let mockKeychain = MockVaultKeychainStorage()
        let suiteName = "com.clipharbor.test.isolated.\(UUID().uuidString)"
        guard let mockDefaults = UserDefaults(suiteName: suiteName), mockDefaults !== UserDefaults.standard else {
            throw VaultError.fileOperationFailed("Failed to create isolated UserDefaults suite: \(suiteName)")
        }
        let mockDownloads = MockDownloadManager()
        let mockFolders = MockFolderManager()
        let mockThumbnails = MockThumbnailManager()

        let vault = VaultManager(
            baseDirectory: baseDir,
            downloadsDirectory: downloadsDir,
            keychainStorage: mockKeychain,
            userDefaults: mockDefaults
        )
        try vault.setupPasscode("123456", confirmPasscode: "123456", enableBiometrics: false)

        return TestEnv(
            baseDir: baseDir,
            downloadsDir: downloadsDir,
            vault: vault,
            mockDownloads: mockDownloads,
            mockFolders: mockFolders,
            mockThumbnails: mockThumbnails,
            mockKeychain: mockKeychain
        )
    }

    private func createDummyVideoFile(in dir: URL, name: String, content: String = "CLIPHARBOR_TEST_VIDEO_PAYLOAD_1234567890") throws -> (URL, SavedVideo) {
        let fileURL = dir.appendingPathComponent(name)
        let data = content.data(using: .utf8)!
        try data.write(to: fileURL, options: .atomic)

        let video = SavedVideo(
            id: UUID(),
            title: (name as NSString).deletingPathExtension,
            relativePath: "IsolatedDownloads/\(name)",
            format: .mp4,
            sourceHost: "example.com",
            createdAt: Date(),
            byteSize: Int64(data.count)
        )
        return (fileURL, video)
    }

    // 1. 通常移動の正常系テスト
    func testMoveToVault_Success() async throws {
        let env = try createTestEnvironment()
        defer { env.cleanup() }

        let (sourceURL, video) = try createDummyVideoFile(in: env.downloadsDir, name: "NormalTest.mp4")
        env.mockDownloads.savedVideos[video.id] = video
        env.mockFolders.folderMap[video.id] = "MyFolder"

        try await env.vault.moveToVault(
            video: video,
            sourceURL: sourceURL,
            downloads: env.mockDownloads,
            folderManager: env.mockFolders,
            thumbnailManager: env.mockThumbnails
        )

        // 原本平文ファイルは安全に削除されたか
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        // Vaultインデックスにアイテムが追加されたか
        XCTAssertEqual(env.vault.items.count, 1)
        let item = env.vault.items[0]
        XCTAssertEqual(item.originalVideoID, video.id)
        // 暗号化コンテナが正しく保存されたか
        let encURL = env.baseDir.appendingPathComponent("Vault/items/\(item.id.uuidString)/video.enc")
        XCTAssertTrue(FileManager.default.fileExists(atPath: encURL.path))
        let encSize = (try? FileManager.default.attributesOfItem(atPath: encURL.path)[.size] as? Int64) ?? 0
        XCTAssertGreaterThan(encSize, 0)
        // 通常一覧およびフォルダから解除されたか
        XCTAssertNil(env.mockDownloads.savedVideos[video.id])
        XCTAssertTrue(env.mockDownloads.removeCalledForIDs.contains(video.id))
        XCTAssertTrue(env.mockFolders.removedVideoIDs.contains(video.id))
    }

    // 2. 移動時: 原本平文削除失敗時のロールバックテスト（元ファイルを保全しVaultインデックスを巻き戻す）
    func testMoveToVault_SourceRemovalFailure_RollsBackIndexAndKeepsSource() async throws {
        let env = try createTestEnvironment()
        defer { env.cleanup() }

        let (sourceURL, video) = try createDummyVideoFile(in: env.downloadsDir, name: "RemovalFail.mp4")
        env.mockDownloads.savedVideos[video.id] = video
        env.mockFolders.folderMap[video.id] = "MyFolder"

        // 障害注入: 平文削除の失敗をシミュレート
        env.vault.faultConfig.simulateSourceRemovalFailure = true

        do {
            try await env.vault.moveToVault(
                video: video,
                sourceURL: sourceURL,
                downloads: env.mockDownloads,
                folderManager: env.mockFolders,
                thumbnailManager: env.mockThumbnails
            )
            XCTFail("Should have thrown error on removal failure")
        } catch {
            // エラーが正常にスローされたことを検証
            XCTAssertTrue(error.localizedDescription.contains("Failed to safely remove original file") || (error as? VaultError) != nil)
        }

        // 検証: 元平文ファイルは絶対に失われず存在し続ける
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        // 検証: Vaultインデックスからアイテムは安全に除外されている
        XCTAssertEqual(env.vault.items.count, 0)
        // 検証: DownloadCenterの通常一覧およびフォルダ登録は維持されている
        XCTAssertNotNil(env.mockDownloads.savedVideos[video.id])
        XCTAssertFalse(env.mockDownloads.removeCalledForIDs.contains(video.id))
        XCTAssertFalse(env.mockFolders.removedVideoIDs.contains(video.id))
    }

    // 3. 移動時: インデックス保存失敗時のクリーンアップテスト（元ファイルを保全し不完全なVault内領域を破棄）
    func testMoveToVault_IndexSaveFailure_CleansUpAndKeepsSource() async throws {
        let env = try createTestEnvironment()
        defer { env.cleanup() }

        let (sourceURL, video) = try createDummyVideoFile(in: env.downloadsDir, name: "IndexFail.mp4")
        env.mockDownloads.savedVideos[video.id] = video

        // 障害注入: インデックス保存失敗をシミュレート
        env.vault.faultConfig.simulateIndexSaveFailure = true

        do {
            try await env.vault.moveToVault(
                video: video,
                sourceURL: sourceURL,
                downloads: env.mockDownloads,
                folderManager: env.mockFolders,
                thumbnailManager: env.mockThumbnails
            )
            XCTFail("Should have thrown error on index save failure")
        } catch {
            // スローされたことを確認
        }

        // 検証: 元ファイルは残っている
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        // 検証: Vault一覧は空
        XCTAssertEqual(env.vault.items.count, 0)
        // 検証: DownloadCenterの通常一覧は維持されている
        XCTAssertNotNil(env.mockDownloads.savedVideos[video.id])
    }

    // 4. 通常復元の正常系テスト（原本復号、一覧登録、暗号化ファイル削除）
    func testRestoreFromVault_Success() async throws {
        let env = try createTestEnvironment()
        defer { env.cleanup() }

        let (sourceURL, video) = try createDummyVideoFile(in: env.downloadsDir, name: "RestoreTest.mp4", content: "TEST_ROUND_TRIP_PAYLOAD")
        env.mockDownloads.savedVideos[video.id] = video

        try await env.vault.moveToVault(
            video: video,
            sourceURL: sourceURL,
            downloads: env.mockDownloads,
            folderManager: env.mockFolders,
            thumbnailManager: env.mockThumbnails
        )

        let vaultItem = env.vault.items[0]
        let encURL = env.baseDir.appendingPathComponent("Vault/items/\(vaultItem.id.uuidString)/video.enc")
        XCTAssertTrue(FileManager.default.fileExists(atPath: encURL.path))

        // 復元実行
        try await env.vault.restoreFromVault(
            item: vaultItem,
            targetFolder: nil,
            downloads: env.mockDownloads,
            folderManager: env.mockFolders,
            thumbnailManager: env.mockThumbnails
        )

        // 検証: Vault内の暗号化原本が消去され、アイテム一覧から除去されたか
        XCTAssertEqual(env.vault.items.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: encURL.path))
        // 検証: DownloadCenterに復元動画が再登録されたか
        XCTAssertNotNil(env.mockDownloads.savedVideos[video.id])
        // 検証: 復元先平文ファイルが存在し、内容が同一であるか
        let restoredVideo = env.mockDownloads.savedVideos[video.id]!
        let restoredDestURL = env.downloadsDir.appendingPathComponent("RestoreTest.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: restoredDestURL.path))
        let restoredContent = String(data: try Data(contentsOf: restoredDestURL), encoding: .utf8)
        XCTAssertEqual(restoredContent, "TEST_ROUND_TRIP_PAYLOAD")
        XCTAssertEqual(restoredVideo.byteSize, Int64("TEST_ROUND_TRIP_PAYLOAD".utf8.count))
    }

    // 5. 復元時: DownloadCenter永続化失敗時のロールバックテスト（復元途中ファイルを削除し、暗号原本を完全保全）
    func testRestoreFromVault_DownloadPersistenceFailure_CleansUpPlaintextAndPreservesEncrypted() async throws {
        let env = try createTestEnvironment()
        defer { env.cleanup() }

        let (sourceURL, video) = try createDummyVideoFile(in: env.downloadsDir, name: "RestorePersistFail.mp4")
        env.mockDownloads.savedVideos[video.id] = video

        try await env.vault.moveToVault(
            video: video,
            sourceURL: sourceURL,
            downloads: env.mockDownloads,
            folderManager: env.mockFolders,
            thumbnailManager: env.mockThumbnails
        )

        let vaultItem = env.vault.items[0]
        let encURL = env.baseDir.appendingPathComponent("Vault/items/\(vaultItem.id.uuidString)/video.enc")
        XCTAssertTrue(FileManager.default.fileExists(atPath: encURL.path))

        // 障害注入: DownloadCenterへの登録・永続化の失敗
        env.mockDownloads.persistShouldFail = true

        do {
            try await env.vault.restoreFromVault(
                item: vaultItem,
                targetFolder: nil,
                downloads: env.mockDownloads,
                folderManager: env.mockFolders,
                thumbnailManager: env.mockThumbnails
            )
            XCTFail("Should have thrown error on DownloadCenter persist failure")
        } catch {
            // スローされたことを確認
        }

        // 検証: Vault内のアイテムと暗号原本は失われず確実に保全されている
        XCTAssertEqual(env.vault.items.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: encURL.path))
        // 検証: 通常一覧への登録は行われていない
        XCTAssertNil(env.mockDownloads.savedVideos[video.id])
        // 検証: 不完全な平文復元先ファイルはディスクに残っていない
        let destURL = env.downloadsDir.appendingPathComponent("RestorePersistFail.mp4")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destURL.path))
    }

    // 6. 復元時: Vaultインデックス保存失敗時（Point of No Return後の両損防止テスト）
    func testRestoreFromVault_IndexSaveFailure_PreservesPlaintextAndEncrypted() async throws {
        let env = try createTestEnvironment()
        defer { env.cleanup() }

        let (sourceURL, video) = try createDummyVideoFile(in: env.downloadsDir, name: "RestoreIndexFail.mp4", content: "CRITICAL_PAYLOAD")
        env.mockDownloads.savedVideos[video.id] = video

        try await env.vault.moveToVault(
            video: video,
            sourceURL: sourceURL,
            downloads: env.mockDownloads,
            folderManager: env.mockFolders,
            thumbnailManager: env.mockThumbnails
        )

        let vaultItem = env.vault.items[0]
        let encURL = env.baseDir.appendingPathComponent("Vault/items/\(vaultItem.id.uuidString)/video.enc")

        // 障害注入: 復号後、Vaultインデックスの保存失敗
        env.vault.faultConfig.simulateIndexSaveFailure = true

        do {
            try await env.vault.restoreFromVault(
                item: vaultItem,
                targetFolder: nil,
                downloads: env.mockDownloads,
                folderManager: env.mockFolders,
                thumbnailManager: env.mockThumbnails
            )
            XCTFail("Should have thrown error on Vault index save failure")
        } catch {
            // スローされたことを確認
        }

        // ★最重要検証: 両損防止
        // 1. 暗号化原本は削除されず残っている（Vaultインデックス保存に失敗したため）
        XCTAssertTrue(FileManager.default.fileExists(atPath: encURL.path))
        XCTAssertEqual(env.vault.items.count, 1)
        // 2. 復元済み平文ファイルもロールバック削除されず残っている（重複を許容し、両方失われる事態を防止）
        let destURL = env.downloadsDir.appendingPathComponent("RestoreIndexFail.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path))
        let restoredData = try Data(contentsOf: destURL)
        XCTAssertEqual(String(data: restoredData, encoding: .utf8), "CRITICAL_PAYLOAD")
        // 3. DownloadCenterにも登録が残っている
        XCTAssertNotNil(env.mockDownloads.savedVideos[video.id])
    }

    // 7. 復元時: 暗号化ファイル破損時の改ざん検知テスト
    func testRestoreFromVault_CorruptedContainer_ThrowsIntegrityError() async throws {
        let env = try createTestEnvironment()
        defer { env.cleanup() }

        let (sourceURL, video) = try createDummyVideoFile(in: env.downloadsDir, name: "CorruptTest.mp4")
        env.mockDownloads.savedVideos[video.id] = video

        try await env.vault.moveToVault(
            video: video,
            sourceURL: sourceURL,
            downloads: env.mockDownloads,
            folderManager: env.mockFolders,
            thumbnailManager: env.mockThumbnails
        )

        let vaultItem = env.vault.items[0]
        let encURL = env.baseDir.appendingPathComponent("Vault/items/\(vaultItem.id.uuidString)/video.enc")

        // ファイルを意図的に破損させる (末尾をランダムデータで破壊)
        var encData = try Data(contentsOf: encURL)
        if encData.count > 30 {
            encData[encData.count - 5] ^= 0xFF
            encData[encData.count - 10] ^= 0xAA
            try encData.write(to: encURL, options: .atomic)
        }

        do {
            try await env.vault.restoreFromVault(
                item: vaultItem,
                targetFolder: nil,
                downloads: env.mockDownloads,
                folderManager: env.mockFolders,
                thumbnailManager: env.mockThumbnails
            )
            XCTFail("Should have thrown integrityCheckFailed error")
        } catch let err as VaultError {
            switch err {
            case .integrityCheckFailed:
                break // 正常に整合性エラーを検出
            default:
                XCTFail("Unexpected error type: \(err)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // 検証: 破損した平文ファイルが通常領域に残っていないこと
        let destURL = env.downloadsDir.appendingPathComponent("CorruptTest.mp4")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destURL.path))
        // 暗号原本はVault内に残っている
        XCTAssertTrue(FileManager.default.fileExists(atPath: encURL.path))
    }

    // 8. セキュリティ: 許可外パスへのアクセス遮断テスト
    func testSecurity_OutsidePath_RejectsMoveBeforeOperation() async throws {
        let env = try createTestEnvironment()
        defer { env.cleanup() }

        // システム一時領域外（例えばルート直下や別ディレクトリ）を指定
        let outsideURL = URL(fileURLWithPath: "/private/var/mobile/unauthorized_test.mp4")
        let video = SavedVideo(
            id: UUID(),
            title: "Unauthorized",
            relativePath: "unauthorized.mp4",
            format: .mp4,
            sourceHost: "example.com",
            createdAt: Date(),
            byteSize: 100
        )

        do {
            try await env.vault.moveToVault(
                video: video,
                sourceURL: outsideURL,
                downloads: env.mockDownloads,
                folderManager: env.mockFolders,
                thumbnailManager: env.mockThumbnails
            )
            XCTFail("Should have thrown error on unauthorized outside path")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Security violation") || (error as? VaultError) != nil)
        }
    }
}
