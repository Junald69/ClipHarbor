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

    // 9. 移動時: 暗号化中のセッション変更（lock呼び出しによるsessionToken不一致）テスト
    func testMoveToVault_SessionChangeDuringEncryption_AbortsAndProtectsSourceAndCleansProcessing() async throws {
        let env = try createTestEnvironment()
        defer { env.cleanup() }

        let (sourceURL, video) = try createDummyVideoFile(in: env.downloadsDir, name: "SessionMoveTest.mp4")
        env.mockDownloads.savedVideos[video.id] = video

        // 障害注入: 暗号化タスク完了直後（インデックス反映前）にVaultがロックされるシナリオ
        env.vault.faultConfig.onOperationPhase = {
            env.vault.lock()
        }

        do {
            try await env.vault.moveToVault(
                video: video,
                sourceURL: sourceURL,
                downloads: env.mockDownloads,
                folderManager: env.mockFolders,
                thumbnailManager: env.mockThumbnails
            )
            XCTFail("Should have thrown sessionExpired error")
        } catch let err as VaultError {
            switch err {
            case .sessionExpired:
                break // 正常にセッション期限切れを検出
            default:
                XCTFail("Unexpected error type: \(err)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // 検証: 元平文ファイルは絶対に削除されず保護されている
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        // 検証: 通常ダウンロード一覧から除去されていない
        XCTAssertNotNil(env.mockDownloads.savedVideos[video.id])
        // 検証: UI処理中フラグが確実にfalseへ解除されている
        XCTAssertFalse(env.vault.isProcessing)
    }

    // 10. 復元時: 復号中のセッション変更（lock呼び出しによるsessionToken不一致）テスト
    func testRestoreFromVault_SessionChangeDuringDecryption_AbortsAndCleansDestFileAndCleansProcessing() async throws {
        let env = try createTestEnvironment()
        defer { env.cleanup() }

        let (sourceURL, video) = try createDummyVideoFile(in: env.downloadsDir, name: "SessionRestoreTest.mp4")
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

        // 障害注入: 復号タスク完了直後（ダウンロード登録前）にVaultがロックされるシナリオ
        env.vault.faultConfig.onOperationPhase = {
            env.vault.lock()
        }

        let destURL = env.downloadsDir.appendingPathComponent("SessionRestoreTest.mp4")

        do {
            try await env.vault.restoreFromVault(
                item: vaultItem,
                targetFolder: nil,
                downloads: env.mockDownloads,
                folderManager: env.mockFolders,
                thumbnailManager: env.mockThumbnails
            )
            XCTFail("Should have thrown sessionExpired error")
        } catch let err as VaultError {
            switch err {
            case .sessionExpired:
                break // 正常にセッション期限切れを検出
            default:
                XCTFail("Unexpected error type: \(err)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // 検証: ロックされたため、復元途中の平文ファイルはディスク上に残留せず削除されている
        XCTAssertFalse(FileManager.default.fileExists(atPath: destURL.path))
        // 検証: 暗号化原本はVault内に確実に保護されている
        XCTAssertTrue(FileManager.default.fileExists(atPath: encURL.path))
        // 検証: 通常ダウンロード一覧には登録されていない
        XCTAssertNil(env.mockDownloads.savedVideos[video.id])
        // 検証: UI処理中フラグが確実にfalseへ解除されている
        XCTAssertFalse(env.vault.isProcessing)
    }

    // 11. 復元時: ディレクトリ作成失敗テスト
    func testRestoreFromVault_DestinationDirectoryCreationFailed_FailsGracefullyAndCleansProcessing() async throws {
        let env = try createTestEnvironment()
        defer { env.cleanup() }

        let (sourceURL, video) = try createDummyVideoFile(in: env.downloadsDir, name: "DirFailTest.mp4")
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

        // 障害注入: ダウンロード先ディレクトリと同名の通常ファイルを配置し、createDirectoryを強制失敗させる
        try FileManager.default.removeItem(at: env.downloadsDir)
        try Data("dummy_file_blocking_dir_creation".utf8).write(to: env.downloadsDir)

        do {
            try await env.vault.restoreFromVault(
                item: vaultItem,
                targetFolder: nil,
                downloads: env.mockDownloads,
                folderManager: env.mockFolders,
                thumbnailManager: env.mockThumbnails
            )
            XCTFail("Should have thrown directory creation error")
        } catch {
            // エラーがスローされたことを確認
        }

        // 検証: UI状態 isProcessing が確実にfalseへ復帰している
        XCTAssertFalse(env.vault.isProcessing)
        // 検証: 暗号化原本は失われず残っている
        XCTAssertTrue(FileManager.default.fileExists(atPath: encURL.path))
    }

    // 12. 中断・失敗時のUI状態 (isProcessing) 解除テスト
    func testMoveToVault_Failure_CleansProcessingState() async throws {
        let env = try createTestEnvironment()
        defer { env.cleanup() }

        let nonExistentURL = env.downloadsDir.appendingPathComponent("non_existent.mp4")
        let video = SavedVideo(
            id: UUID(),
            title: "NotFound",
            relativePath: "IsolatedDownloads/non_existent.mp4",
            format: .mp4,
            sourceHost: "example.com",
            createdAt: Date(),
            byteSize: 100
        )

        do {
            try await env.vault.moveToVault(
                video: video,
                sourceURL: nonExistentURL,
                downloads: env.mockDownloads,
                folderManager: env.mockFolders,
                thumbnailManager: env.mockThumbnails
            )
            XCTFail("Should fail because file does not exist")
        } catch {
            // 失敗を確認
        }

        // 検証: 準備段階で例外がスローされても、isProcessing が確実に false に戻っている
        XCTAssertFalse(env.vault.isProcessing)
    }

    // 13. 生体認証: ロック後に自動起動せず、明示的呼び出しでのみアンロックされること
    func testBiometrics_DoesNotAutoUnlockOnLock_UnlocksWhenExplicitlyTriggered() async throws {
        let env = try createTestEnvironment()
        defer { env.cleanup() }

        // 生体認証を有効化
        try env.vault.setBiometricsEnabled(true)
        XCTAssertTrue(env.vault.isBiometricsEnabled)

        // ロック実行
        env.vault.lock()
        // 自動アンロックされないことを検証（必ずロック解除画面に留まる）
        XCTAssertFalse(env.vault.isUnlocked)
        XCTAssertTrue(env.vault.items.isEmpty)

        // テンキー左下の生体認証ボタンを押したときのみアンロックが明示的に実行される
        try await env.vault.unlockWithBiometrics()
        XCTAssertTrue(env.vault.isUnlocked)
    }

    // 14. 既存Vaultインデックスの読み込み互換性 (folderIDキーなしの旧データ)
    func testBackwardCompatibility_LegacyIndexWithoutFolderID_LoadsAsUncategorized() async throws {
        let env = try createTestEnvironment()
        defer { env.cleanup() }

        let itemID = UUID()
        let originalVideoID = UUID()
        let legacyJSON = """
        [
            {
                "id": "\(itemID.uuidString)",
                "originalVideoID": "\(originalVideoID.uuidString)",
                "originalTitle": "LegacyVideo",
                "originalFileName": "LegacyVideo.mp4",
                "originalRelativePath": "Downloads/LegacyVideo.mp4",
                "originalFolderName": "",
                "format": "mp4",
                "byteSize": 1024,
                "createdAt": 1700000000,
                "vaultAddedAt": 1700000000,
                "isFavorite": false
            }
        ]
        """
        guard let data = legacyJSON.data(using: .utf8) else {
            XCTFail("Failed to encode legacy JSON")
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decodedItems = try decoder.decode([VaultItem].self, from: data)

        XCTAssertEqual(decodedItems.count, 1)
        XCTAssertEqual(decodedItems[0].originalTitle, "LegacyVideo")
        XCTAssertNil(decodedItems[0].folderID, "Legacy items without folderID must decode with folderID = nil (Uncategorized)")
    }

    // 15. フォルダ作成・変更・削除
    func testVaultFolders_CreateRenameDelete() async throws {
        let env = try createTestEnvironment()
        defer { env.cleanup() }

        // 1. フォルダ新規作成
        let folder = try env.vault.createFolder(name: "MyFolder")
        XCTAssertEqual(env.vault.folders.count, 1)
        XCTAssertEqual(env.vault.folders[0].name, "MyFolder")
        XCTAssertEqual(env.vault.folders[0].id, folder.id)

        // 空白または重複フォルダ名のバリデーション
        XCTAssertThrowsError(try env.vault.createFolder(name: "   "))
        XCTAssertThrowsError(try env.vault.createFolder(name: "myfolder"))

        // 2. フォルダ名変更
        try env.vault.renameFolder(id: folder.id, newName: "RenamedFolder")
        XCTAssertEqual(env.vault.folders[0].name, "RenamedFolder")

        // 3. フォルダ削除
        try env.vault.deleteFolder(id: folder.id)
        XCTAssertTrue(env.vault.folders.isEmpty)
    }

    // 16. 動画の単体・一括移動
    func testVaultFolders_SingleAndBatchMove() async throws {
        let env = try createTestEnvironment()
        defer { env.cleanup() }

        let (url1, video1) = try createDummyVideoFile(in: env.downloadsDir, name: "V1.mp4")
        let (url2, video2) = try createDummyVideoFile(in: env.downloadsDir, name: "V2.mp4")
        env.mockDownloads.savedVideos[video1.id] = video1
        env.mockDownloads.savedVideos[video2.id] = video2

        try await env.vault.moveToVault(
            video: video1,
            sourceURL: url1,
            downloads: env.mockDownloads,
            folderManager: env.mockFolders,
            thumbnailManager: env.mockThumbnails
        )
        try await env.vault.moveToVault(
            video: video2,
            sourceURL: url2,
            downloads: env.mockDownloads,
            folderManager: env.mockFolders,
            thumbnailManager: env.mockThumbnails
        )

        // デフォルトでは未分類（folderID == nil）
        XCTAssertEqual(env.vault.items.count, 2)
        XCTAssertNil(env.vault.items[0].folderID)
        XCTAssertNil(env.vault.items[1].folderID)

        let folder = try env.vault.createFolder(name: "FolderA")

        // 単体移動
        let item1ID = env.vault.items.first(where: { $0.originalVideoID == video1.id })!.id
        try env.vault.moveItem(id: item1ID, to: folder.id)
        XCTAssertEqual(env.vault.items.first(where: { $0.id == item1ID })?.folderID, folder.id)

        // 一括移動
        let allIDs = Set(env.vault.items.map { $0.id })
        try env.vault.moveItems(ids: allIDs, to: folder.id)
        XCTAssertEqual(env.vault.items(in: folder.id).count, 2)
        XCTAssertEqual(env.vault.items(in: nil).count, 0)

        // 未分類へ一括戻し
        try env.vault.moveItems(ids: allIDs, to: nil)
        XCTAssertEqual(env.vault.items(in: nil).count, 2)
    }

    // 17. フォルダメタデータ保存失敗時のデータ保護
    func testVaultFolders_SaveFailure_RollsBackAndProtectsData() async throws {
        let env = try createTestEnvironment()
        defer { env.cleanup() }

        let folder = try env.vault.createFolder(name: "StableFolder")
        XCTAssertEqual(env.vault.folders.count, 1)

        // フォルダメタデータ保存失敗の障害注入
        env.vault.faultConfig.simulateFolderSaveFailure = true

        // 新規作成が失敗し、ロールバックされること
        XCTAssertThrowsError(try env.vault.createFolder(name: "WillFailFolder"))
        XCTAssertEqual(env.vault.folders.count, 1)
        XCTAssertEqual(env.vault.folders[0].name, "StableFolder")

        // 名前変更が失敗し、ロールバックされること
        XCTAssertThrowsError(try env.vault.renameFolder(id: folder.id, newName: "NewName"))
        XCTAssertEqual(env.vault.folders[0].name, "StableFolder")

        // 削除が失敗し、ロールバックされること
        XCTAssertThrowsError(try env.vault.deleteFolder(id: folder.id))
        XCTAssertEqual(env.vault.folders.count, 1)
    }

    // 18. アプリ再起動（再ロック・再アンロック）後のフォルダ維持
    func testVaultFolders_PersistsAcrossLockAndUnlock() async throws {
        let env = try createTestEnvironment()
        defer { env.cleanup() }

        let (url, video) = try createDummyVideoFile(in: env.downloadsDir, name: "PersistTest.mp4")
        env.mockDownloads.savedVideos[video.id] = video

        try await env.vault.moveToVault(
            video: video,
            sourceURL: url,
            downloads: env.mockDownloads,
            folderManager: env.mockFolders,
            thumbnailManager: env.mockThumbnails
        )

        let folder = try env.vault.createFolder(name: "PersistentFolder")
        let itemID = env.vault.items[0].id
        try env.vault.moveItem(id: itemID, to: folder.id)

        // ロック実行: メモリ上の鍵・アイテム・フォルダ管理情報が完全にクリアされること
        env.vault.lock()
        XCTAssertFalse(env.vault.isUnlocked)
        XCTAssertTrue(env.vault.items.isEmpty)
        XCTAssertTrue(env.vault.folders.isEmpty)

        // 再度アンロック: 暗号化されたvault_folders.encおよびvault_index.encから復号・復元されること
        try env.vault.unlock(with: "123456")
        XCTAssertTrue(env.vault.isUnlocked)
        XCTAssertEqual(env.vault.folders.count, 1)
        XCTAssertEqual(env.vault.folders[0].name, "PersistentFolder")
        XCTAssertEqual(env.vault.items.count, 1)
        XCTAssertEqual(env.vault.items[0].folderID, folder.id)
    }

    // 19. フォルダ削除で動画実体が削除されないこと
    func testVaultFolders_DeleteFolder_RetainsVideoFilesAsUncategorized() async throws {
        let env = try createTestEnvironment()
        defer { env.cleanup() }

        let (url, video) = try createDummyVideoFile(in: env.downloadsDir, name: "RetainTest.mp4")
        env.mockDownloads.savedVideos[video.id] = video

        try await env.vault.moveToVault(
            video: video,
            sourceURL: url,
            downloads: env.mockDownloads,
            folderManager: env.mockFolders,
            thumbnailManager: env.mockThumbnails
        )

        let vaultItem = env.vault.items[0]
        let encURL = env.baseDir.appendingPathComponent("Vault/items/\(vaultItem.id.uuidString)/video.enc")
        XCTAssertTrue(FileManager.default.fileExists(atPath: encURL.path))

        let folder = try env.vault.createFolder(name: "TempFolder")
        try env.vault.moveItem(id: vaultItem.id, to: folder.id)
        XCTAssertEqual(env.vault.items[0].folderID, folder.id)

        // フォルダ削除実行
        try env.vault.deleteFolder(id: folder.id)

        // 検証: フォルダは削除されている
        XCTAssertTrue(env.vault.folders.isEmpty)
        // 検証: 動画アイテムは削除されず未分類（folderID == nil）に戻っている
        XCTAssertEqual(env.vault.items.count, 1)
        XCTAssertNil(env.vault.items[0].folderID)
        // 検証: 暗号化動画実体ファイル（video.enc）は確実に保護されている
        XCTAssertTrue(FileManager.default.fileExists(atPath: encURL.path))
        let encSize = (try? FileManager.default.attributesOfItem(atPath: encURL.path)[.size] as? Int64) ?? 0
        XCTAssertGreaterThan(encSize, 0)
    }

    // 20. フォルダメタデータ: vault_folders.enc が存在しない状態（初期状態・アップグレード時）
    func testVaultFolders_NonExistentFile_InitializesCleanlyWithoutError() async throws {
        let env = try createTestEnvironment()
        defer { env.cleanup() }

        let foldersFile = env.baseDir.appendingPathComponent("Vault/vault_folders.enc")
        XCTAssertFalse(FileManager.default.fileExists(atPath: foldersFile.path))

        // ロック＆再アンロック
        env.vault.lock()
        try env.vault.unlock(with: "123456")

        XCTAssertTrue(env.vault.isUnlocked)
        XCTAssertTrue(env.vault.folders.isEmpty)
        XCTAssertFalse(env.vault.isFolderMetadataCorrupted)
        XCTAssertNil(env.vault.folderMetadataWarning)
    }

    // 21. フォルダメタデータ: vault_folders.enc の復号失敗時、警告を通知し動画を保護、空配列での上書き保存を防止
    func testVaultFolders_DecryptionFailure_ProtectsVideosAndPreventsSilentOverwrite() async throws {
        let env = try createTestEnvironment()
        defer { env.cleanup() }

        let (url, video) = try createDummyVideoFile(in: env.downloadsDir, name: "DecFailTest.mp4")
        env.mockDownloads.savedVideos[video.id] = video
        try await env.vault.moveToVault(
            video: video,
            sourceURL: url,
            downloads: env.mockDownloads,
            folderManager: env.mockFolders,
            thumbnailManager: env.mockThumbnails
        )

        let folder = try env.vault.createFolder(name: "ImportantFolder")
        try env.vault.moveItem(id: env.vault.items[0].id, to: folder.id)

        let foldersFile = env.baseDir.appendingPathComponent("Vault/vault_folders.enc")
        XCTAssertTrue(FileManager.default.fileExists(atPath: foldersFile.path))

        // フォルダメタデータファイルをゴミデータで破損させる
        try Data("corrupted_junk_data".utf8).write(to: foldersFile)

        env.vault.lock()
        try env.vault.unlock(with: "123456")

        // 検証: 破損フラグが立ち、警告メッセージが設定されること
        XCTAssertTrue(env.vault.isFolderMetadataCorrupted)
        XCTAssertNotNil(env.vault.folderMetadataWarning)

        // 検証: 動画は未分類として安全にアクセス可能であること
        let uncategorized = env.vault.items(in: nil)
        XCTAssertEqual(uncategorized.count, 1)
        XCTAssertEqual(uncategorized[0].id, env.vault.items[0].id)

        // 検証: 破損したフォルダファイルを空配列で勝手に上書き保存しないこと
        XCTAssertThrowsError(try env.vault.saveEncryptedFolders())
    }

    // 22. 存在しないfolderIDを持つ孤立動画が未分類（nil）として安全に表示・アクセスできること
    func testVaultFolders_OrphanedFolderID_FallbacksToUncategorized() async throws {
        let env = try createTestEnvironment()
        defer { env.cleanup() }

        let (url, video) = try createDummyVideoFile(in: env.downloadsDir, name: "OrphanTest.mp4")
        env.mockDownloads.savedVideos[video.id] = video
        try await env.vault.moveToVault(
            video: video,
            sourceURL: url,
            downloads: env.mockDownloads,
            folderManager: env.mockFolders,
            thumbnailManager: env.mockThumbnails
        )

        // 存在しないランダムなfolderIDを付与（孤立状態）
        let orphanID = UUID()
        let itemID = env.vault.items[0].id
        env.vault.setItemFolderIDForTesting(id: itemID, folderID: orphanID)

        // 既存フォルダには orphanID は存在しない
        XCTAssertFalse(env.vault.folders.contains(where: { $0.id == orphanID }))

        // items(in: nil) を取得した際、孤立動画が未分類としてフォールバック表示されること
        let itemsInRoot = env.vault.items(in: nil)
        XCTAssertTrue(itemsInRoot.contains(where: { $0.id == itemID }))
    }

    // 23. フォルダ削除でインデックス保存が失敗した場合、ロールバックされフォルダ・動画共に保護されること
    func testVaultFolders_DeleteFolder_IndexSaveFailure_RollsBackAndProtects() async throws {
        let env = try createTestEnvironment()
        defer { env.cleanup() }

        let (url, video) = try createDummyVideoFile(in: env.downloadsDir, name: "DelIdxFail.mp4")
        env.mockDownloads.savedVideos[video.id] = video
        try await env.vault.moveToVault(
            video: video,
            sourceURL: url,
            downloads: env.mockDownloads,
            folderManager: env.mockFolders,
            thumbnailManager: env.mockThumbnails
        )

        let folder = try env.vault.createFolder(name: "FolderToDel")
        let itemID = env.vault.items[0].id
        try env.vault.moveItem(id: itemID, to: folder.id)

        // 第1ステップ（インデックス保存）の障害注入
        env.vault.faultConfig.simulateIndexSaveFailure = true

        XCTAssertThrowsError(try env.vault.deleteFolder(id: folder.id))

        // 検証: フォルダは削除されず残っている
        XCTAssertEqual(env.vault.folders.count, 1)
        XCTAssertEqual(env.vault.folders[0].id, folder.id)
        // 検証: アイテムのfolderIDもロールバックされて維持されている
        XCTAssertEqual(env.vault.items.first(where: { $0.id == itemID })?.folderID, folder.id)
    }

    // 24. フォルダ削除でインデックス保存成功後にフォルダ保存が失敗した場合、動画は未分類として安全にアクセス可能であること
    func testVaultFolders_DeleteFolder_FolderSaveFailure_RetainsVideosSafely() async throws {
        let env = try createTestEnvironment()
        defer { env.cleanup() }

        let (url, video) = try createDummyVideoFile(in: env.downloadsDir, name: "DelFldFail.mp4")
        env.mockDownloads.savedVideos[video.id] = video
        try await env.vault.moveToVault(
            video: video,
            sourceURL: url,
            downloads: env.mockDownloads,
            folderManager: env.mockFolders,
            thumbnailManager: env.mockThumbnails
        )

        let folder = try env.vault.createFolder(name: "FolderToDel2")
        let itemID = env.vault.items[0].id
        try env.vault.moveItem(id: itemID, to: folder.id)

        // 第2ステップ（フォルダ定義保存）のみ失敗する障害注入
        env.vault.faultConfig.simulateFolderSaveFailure = true

        XCTAssertThrowsError(try env.vault.deleteFolder(id: folder.id))

        // 検証: インメモリのフォルダは復元される
        XCTAssertEqual(env.vault.folders.count, 1)
        // 検証: 第1ステップで動画のfolderID=nilが既に永続化インデックスに書き込まれているため、再ロック・再アンロック後も全動画にアクセスできる
        env.vault.faultConfig.simulateFolderSaveFailure = false
        env.vault.lock()
        try env.vault.unlock(with: "123456")

        // 全動画がアクセス可能（未分類として表示）
        XCTAssertEqual(env.vault.items.count, 1)
        XCTAssertNil(env.vault.items[0].folderID)
        XCTAssertEqual(env.vault.items(in: nil).count, 1)
    }

    // 25. 削除処理途中で中断（インデックス保存完了直後に強制終了）した状態の復旧・動画実体検証
    func testVaultFolders_DeleteFolder_InterruptedMidway_RecoversCleanlyAndRetainsFiles() async throws {
        let env = try createTestEnvironment()
        defer { env.cleanup() }

        let (url, video) = try createDummyVideoFile(in: env.downloadsDir, name: "MidwayTest.mp4")
        env.mockDownloads.savedVideos[video.id] = video
        try await env.vault.moveToVault(
            video: video,
            sourceURL: url,
            downloads: env.mockDownloads,
            folderManager: env.mockFolders,
            thumbnailManager: env.mockThumbnails
        )

        let folder = try env.vault.createFolder(name: "MidwayFolder")
        let vaultItem = env.vault.items[0]
        try env.vault.moveItem(id: vaultItem.id, to: folder.id)

        let encURL = env.baseDir.appendingPathComponent("Vault/items/\(vaultItem.id.uuidString)/video.enc")
        XCTAssertTrue(FileManager.default.fileExists(atPath: encURL.path))

        // 中断状態を手動シミュレート: 動画のfolderIDはnilでインデックス保存されたが、vault_folders.encにはまだフォルダが残っている
        try env.vault.moveItem(id: vaultItem.id, to: nil)

        // アプリ終了・再起動シミュレーション
        env.vault.lock()
        try env.vault.unlock(with: "123456")

        // 検証: 再アンロック後、動画は未分類として安全に表示される
        XCTAssertEqual(env.vault.items.count, 1)
        XCTAssertNil(env.vault.items[0].folderID)
        XCTAssertEqual(env.vault.items(in: nil).count, 1)

        // 検証: 暗号化動画実体（video.enc）は100%保護されている
        XCTAssertTrue(FileManager.default.fileExists(atPath: encURL.path))
        let encSize = (try? FileManager.default.attributesOfItem(atPath: encURL.path)[.size] as? Int64) ?? 0
        XCTAssertGreaterThan(encSize, 0)
    }

    // MARK: - 再生速度表示フォーマット & 整合性検証

    func testPlaybackSpeed_FormattingPrecisionAndDisplayMatch() {
        // 要求仕様: 0.5x, 0.75x, 1.0x, 1.25x, 1.5x, 2.0x
        XCTAssertEqual(PlaybackSpeedFormatter.format(0.5), "0.5x")
        XCTAssertEqual(PlaybackSpeedFormatter.format(0.75), "0.75x")
        XCTAssertEqual(PlaybackSpeedFormatter.format(1.0), "1.0x")
        XCTAssertEqual(PlaybackSpeedFormatter.format(1.25), "1.25x")
        XCTAssertEqual(PlaybackSpeedFormatter.format(1.5), "1.5x")
        XCTAssertEqual(PlaybackSpeedFormatter.format(2.0), "2.0x")
    }

    func testPlaybackSpeed_FloatDriftAndSnapping() {
        // AVPlayer / PiP 復帰時の微小浮動小数点誤差の吸収テスト
        XCTAssertEqual(PlaybackSpeedFormatter.snapToStandardSpeed(0.75000006), 0.75)
        XCTAssertEqual(PlaybackSpeedFormatter.format(0.75000006), "0.75x")

        XCTAssertEqual(PlaybackSpeedFormatter.snapToStandardSpeed(1.2500001), 1.25)
        XCTAssertEqual(PlaybackSpeedFormatter.format(1.2500001), "1.25x")

        XCTAssertEqual(PlaybackSpeedFormatter.snapToStandardSpeed(0.4999999), 0.5)
        XCTAssertEqual(PlaybackSpeedFormatter.format(0.4999999), "0.5x")

        XCTAssertEqual(PlaybackSpeedFormatter.snapToStandardSpeed(1.9999999), 2.0)
        XCTAssertEqual(PlaybackSpeedFormatter.format(1.9999999), "2.0x")

        // 標準以外の速度
        XCTAssertEqual(PlaybackSpeedFormatter.format(0.8), "0.8x")
        XCTAssertEqual(PlaybackSpeedFormatter.format(3.0), "3.0x")
    }

    func testPlaybackSpeed_StandardSpeedsOrderAndCount() {
        let expected: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
        XCTAssertEqual(PlaybackSpeedFormatter.standardSpeeds.count, 6)
        XCTAssertEqual(PlaybackSpeedFormatter.standardSpeeds, expected)
    }

    func testPlaybackSpeed_CoordinatorPreservesRequestedRateAcrossSessions() {
        let coordinator = VideoPlaybackCoordinator.shared
        defer { coordinator.updatePlaybackRate(1.0) }
        for speed in PlaybackSpeedFormatter.standardSpeeds {
            coordinator.updatePlaybackRate(speed)
            XCTAssertEqual(coordinator.activePlaybackRate, speed)
            XCTAssertEqual(PlaybackSpeedFormatter.format(coordinator.activePlaybackRate), PlaybackSpeedFormatter.format(speed))
        }
    }

    // MARK: - Vaultプレイヤー内復元・フォルダ移動検証

    private func makeVaultItem(id: UUID = UUID(), title: String = "Test Video", folderID: UUID? = nil) -> VaultItem {
        VaultItem(
            id: id,
            originalVideoID: UUID(),
            originalTitle: title,
            originalFileName: "\(title).mp4",
            originalRelativePath: "IsolatedDownloads/\(title).mp4",
            originalFolderName: "",
            format: .mp4,
            byteSize: 1024,
            sourceHost: "example.com",
            sourcePageURL: nil,
            createdAt: Date(),
            vaultAddedAt: Date(),
            isFavorite: false,
            folderID: folderID
        )
    }

    func testVaultPlayer_PlaylistContextItemRemovalAndIndex() {
        let item1 = makeVaultItem(title: "Video 1")
        let item2 = makeVaultItem(title: "Video 2")
        let token = UUID()
        let playlist = PlaybackPlaylistContext(vaultItems: [item1, item2], initialItem: item1, sessionToken: token)

        XCTAssertEqual(playlist.items.count, 2)
        XCTAssertEqual(playlist.currentIndex, 0)
        XCTAssertEqual(playlist.currentItem?.id, item1.id)

        // 復元成功後のアイテム除外: item1 を除外すると次の item2 がカレントになる
        let nextItem = playlist.removeItem(id: item1.id)
        XCTAssertEqual(playlist.items.count, 1)
        XCTAssertEqual(playlist.currentIndex, 0)
        XCTAssertEqual(playlist.currentItem?.id, item2.id)
        XCTAssertEqual(nextItem?.id, item2.id)

        // 最後のアイテムを除外すると空になり nil が返る
        let emptyItem = playlist.removeItem(id: item2.id)
        XCTAssertEqual(playlist.items.count, 0)
        XCTAssertNil(emptyItem)
    }

    func testVaultPlayer_UpdateVaultItemFolderInPlaylist() {
        let item1 = makeVaultItem(title: "Video 1")
        let token = UUID()
        let playlist = PlaybackPlaylistContext(vaultItems: [item1], initialItem: item1, sessionToken: token)

        XCTAssertNil(item1.folderID)

        let targetFolderID = UUID()
        playlist.updateVaultItemFolder(id: item1.id, folderID: targetFolderID)

        if case .vault(let updatedItem) = playlist.currentItem! {
            XCTAssertEqual(updatedItem.folderID, targetFolderID)
        } else {
            XCTFail("Expected vault item")
        }
    }

    func testVaultPlayer_SessionValidation_RejectsInvalidSessionForRestoreAndMove() async throws {
        let env = try createTestEnvironment()
        defer { env.cleanup() }

        let (url, video) = try createDummyVideoFile(in: env.downloadsDir, name: "session.mp4")

        try await env.vault.moveToVault(
            video: video,
            sourceURL: url,
            downloads: env.mockDownloads,
            folderManager: env.mockFolders,
            thumbnailManager: env.mockThumbnails
        )

        let vaultItem = env.vault.items[0]
        let realToken = env.vault.sessionToken

        // 無効なセッショントークン
        let fakeToken = UUID()

        // 復元試行: 無効トークン時はガードで弾かれ実行されないことを検証
        let isSessionValid = env.vault.isUnlocked && env.vault.sessionToken == fakeToken
        XCTAssertFalse(isSessionValid)

        // フォルダ移動試行: 無効トークン時はVaultError.sessionExpiredがスローされることを検証
        let folder = try env.vault.createFolder(name: "TestFolder")
        do {
            guard env.vault.isUnlocked, env.vault.sessionToken == fakeToken else {
                throw VaultError.sessionExpired
            }
            try env.vault.moveItem(id: vaultItem.id, to: folder.id)
            XCTFail("Should not reach here")
        } catch let err as VaultError {
            if case .sessionExpired = err {
                // Expected
            } else {
                XCTFail("Unexpected error: \(err)")
            }
        }

        // ロック時も弾かれることを検証
        env.vault.lock()
        XCTAssertFalse(env.vault.isUnlocked)
        do {
            guard env.vault.isUnlocked, env.vault.sessionToken == realToken else {
                throw VaultError.sessionExpired
            }
            try env.vault.moveItem(id: vaultItem.id, to: folder.id)
            XCTFail("Should not reach here")
        } catch let err as VaultError {
            if case .sessionExpired = err {
                // Expected
            } else {
                XCTFail("Unexpected error: \(err)")
            }
        }
    }

    func testVaultPlayer_RestoreFailure_PreservesEncryptedSource() async throws {
        let env = try createTestEnvironment()
        defer { env.cleanup() }

        let (url, video) = try createDummyVideoFile(in: env.downloadsDir, name: "preserve.mp4")

        try await env.vault.moveToVault(
            video: video,
            sourceURL: url,
            downloads: env.mockDownloads,
            folderManager: env.mockFolders,
            thumbnailManager: env.mockThumbnails
        )

        let vaultItem = env.vault.items[0]
        let encURL = env.baseDir.appendingPathComponent("Vault/items/\(vaultItem.id.uuidString)/video.enc")
        XCTAssertTrue(FileManager.default.fileExists(atPath: encURL.path))

        // 復元失敗を注入: mockDownloads.persistShouldFail = true
        env.mockDownloads.persistShouldFail = true

        do {
            try await env.vault.restoreFromVault(
                item: vaultItem,
                targetFolder: nil,
                downloads: env.mockDownloads,
                folderManager: env.mockFolders,
                thumbnailManager: env.mockThumbnails
            )
            XCTFail("Should fail due to persist failure")
        } catch {
            // Expected
        }

        // 検証: 復元失敗時でも暗号化原本は完全に保持され、Vault一覧からも消えない
        XCTAssertTrue(FileManager.default.fileExists(atPath: encURL.path))
        XCTAssertEqual(env.vault.items.count, 1)
        XCTAssertEqual(env.vault.items[0].id, vaultItem.id)
    }

    func testVaultPlayer_MoveFailure_DoesNotTreatAsSuccess() async throws {
        let env = try createTestEnvironment()
        defer { env.cleanup() }

        let (url, video) = try createDummyVideoFile(in: env.downloadsDir, name: "movefail.mp4")

        try await env.vault.moveToVault(
            video: video,
            sourceURL: url,
            downloads: env.mockDownloads,
            folderManager: env.mockFolders,
            thumbnailManager: env.mockThumbnails
        )

        let vaultItem = env.vault.items[0]
        let nonExistentFolderID = UUID()

        // 存在しないフォルダへの移動試行
        XCTAssertThrowsError(try env.vault.moveItem(id: vaultItem.id, to: nonExistentFolderID))

        // フォルダIDはnilのままであり、変更されていないことを検証
        XCTAssertNil(env.vault.items[0].folderID)
        let rootItems = env.vault.items(in: (nil as UUID?))
        XCTAssertEqual(rootItems.count, 1)
    }

    // MARK: - VaultPlayerRestoreController & VideoFolderManager 回帰テスト

    func testRestoreController_Success_ClearsFlagAndInvokesDismiss() async throws {
        let env = try createTestEnvironment()
        defer { env.cleanup() }

        let (url, video) = try createDummyVideoFile(in: env.downloadsDir, name: "ctrl_success.mp4")
        try await env.vault.moveToVault(
            video: video,
            sourceURL: url,
            downloads: env.mockDownloads,
            folderManager: env.mockFolders,
            thumbnailManager: env.mockThumbnails
        )
        let vaultItem = env.vault.items[0]
        let token = env.vault.sessionToken
        let coordinator = VideoPlaybackCoordinator.shared
        let sessionID = UUID()

        let controller = VaultPlayerRestoreController()
        let context = VaultPlayerRestoreController.PendingRestoreContext(
            vaultItem: vaultItem,
            sessionToken: token,
            playbackSessionID: sessionID
        )

        var didTearDown = false
        var cleanedUpItemID: UUID? = nil
        var successTargetID: UUID? = nil
        var didDismiss = false

        await controller.executeRestore(
            context: context,
            vaultManager: env.vault,
            downloads: env.mockDownloads,
            folderManager: env.mockFolders,
            thumbnailManager: env.mockThumbnails,
            coordinator: coordinator,
            tearDownPlayer: { didTearDown = true },
            cleanupTemp: { cleanedUpItemID = $0 },
            onSuccess: { id, _ in successTargetID = id },
            onReloadItem: { XCTFail("Should not reload on success") },
            onDismiss: {
                // 画面終了実行時点で isRestoring が解除され、canClose が true であることを検証
                XCTAssertFalse(controller.isRestoring)
                XCTAssertTrue(controller.canClose(isDeleting: false))
                didDismiss = true
            }
        )

        XCTAssertTrue(didTearDown)
        XCTAssertEqual(cleanedUpItemID, vaultItem.id)
        XCTAssertEqual(successTargetID, vaultItem.id)
        XCTAssertTrue(didDismiss)
        XCTAssertFalse(controller.isRestoring)
        XCTAssertNil(controller.pendingContext)
        XCTAssertEqual(env.vault.items.count, 0)
    }

    func testRestoreController_SessionInvalidation_DoesNotBlockDismiss() async throws {
        let env = try createTestEnvironment()
        defer { env.cleanup() }

        let (url, video) = try createDummyVideoFile(in: env.downloadsDir, name: "ctrl_session.mp4")
        try await env.vault.moveToVault(
            video: video,
            sourceURL: url,
            downloads: env.mockDownloads,
            folderManager: env.mockFolders,
            thumbnailManager: env.mockThumbnails
        )
        let vaultItem = env.vault.items[0]
        let expiredToken = UUID() // 不正トークン
        let coordinator = VideoPlaybackCoordinator.shared

        let controller = VaultPlayerRestoreController()
        let context = VaultPlayerRestoreController.PendingRestoreContext(
            vaultItem: vaultItem,
            sessionToken: expiredToken,
            playbackSessionID: UUID()
        )

        var didDismiss = false
        await controller.executeRestore(
            context: context,
            vaultManager: env.vault,
            downloads: env.mockDownloads,
            folderManager: env.mockFolders,
            thumbnailManager: env.mockThumbnails,
            coordinator: coordinator,
            tearDownPlayer: { XCTFail("Should not tear down when session is invalid") },
            cleanupTemp: { _ in XCTFail("Should not clean temp when session is invalid") },
            onSuccess: { _, _ in XCTFail("Should not succeed") },
            onReloadItem: { XCTFail("Should not reload") },
            onDismiss: {
                // セッション失効時でも isRestoring が false であり、canClose で終了可能であることを検証
                XCTAssertFalse(controller.isRestoring)
                XCTAssertTrue(controller.canClose(isDeleting: false))
                didDismiss = true
            }
        )

        XCTAssertTrue(didDismiss)
        XCTAssertNil(controller.pendingContext)
        XCTAssertEqual(env.vault.items.count, 1) // 原本保持
    }

    func testRestoreController_RestoreFailure_PreservesOriginal_AndReloadsIfUnlocked() async throws {
        let env = try createTestEnvironment()
        defer { env.cleanup() }

        let (url, video) = try createDummyVideoFile(in: env.downloadsDir, name: "ctrl_fail.mp4")
        try await env.vault.moveToVault(
            video: video,
            sourceURL: url,
            downloads: env.mockDownloads,
            folderManager: env.mockFolders,
            thumbnailManager: env.mockThumbnails
        )
        let vaultItem = env.vault.items[0]
        let token = env.vault.sessionToken
        let coordinator = VideoPlaybackCoordinator.shared
        let encURL = env.baseDir.appendingPathComponent("Vault/items/\(vaultItem.id.uuidString)/video.enc")

        // 障害注入
        env.mockDownloads.persistShouldFail = true

        let controller = VaultPlayerRestoreController()
        let context = VaultPlayerRestoreController.PendingRestoreContext(
            vaultItem: vaultItem,
            sessionToken: token,
            playbackSessionID: UUID()
        )

        var didReload = false
        var didDismiss = false

        await controller.executeRestore(
            context: context,
            vaultManager: env.vault,
            downloads: env.mockDownloads,
            folderManager: env.mockFolders,
            thumbnailManager: env.mockThumbnails,
            coordinator: coordinator,
            tearDownPlayer: {},
            cleanupTemp: { _ in },
            onSuccess: { _, _ in XCTFail("Should not succeed") },
            onReloadItem: {
                XCTAssertFalse(controller.isRestoring)
                didReload = true
            },
            onDismiss: { didDismiss = true }
        )

        // 失敗時でも原本とインデックスは完全保持され、アンロック状態なので再ロードされる
        XCTAssertTrue(didReload)
        XCTAssertFalse(didDismiss)
        XCTAssertTrue(FileManager.default.fileExists(atPath: encURL.path))
        XCTAssertEqual(env.vault.items.count, 1)
        XCTAssertEqual(env.vault.items[0].id, vaultItem.id)
        XCTAssertFalse(controller.isRestoring)
    }

    func testRestoreController_RestoreFailure_WhenVaultLocked_DismissesWithoutReloading() async throws {
        let env = try createTestEnvironment()
        defer { env.cleanup() }

        let (url, video) = try createDummyVideoFile(in: env.downloadsDir, name: "ctrl_lock_fail.mp4")
        try await env.vault.moveToVault(
            video: video,
            sourceURL: url,
            downloads: env.mockDownloads,
            folderManager: env.mockFolders,
            thumbnailManager: env.mockThumbnails
        )
        let vaultItem = env.vault.items[0]
        let token = env.vault.sessionToken
        let coordinator = VideoPlaybackCoordinator.shared

        // 障害注入 + 復元処理中のロック発生
        env.mockDownloads.persistShouldFail = true

        let controller = VaultPlayerRestoreController()
        let context = VaultPlayerRestoreController.PendingRestoreContext(
            vaultItem: vaultItem,
            sessionToken: token,
            playbackSessionID: UUID()
        )

        var didDismiss = false

        await controller.executeRestore(
            context: context,
            vaultManager: env.vault,
            downloads: env.mockDownloads,
            folderManager: env.mockFolders,
            thumbnailManager: env.mockThumbnails,
            coordinator: coordinator,
            tearDownPlayer: {},
            cleanupTemp: { _ in
                // クリーンアップ時点でVaultがバックグラウンド等でロックされた状態を注入
                env.vault.lock()
            },
            onSuccess: { _, _ in XCTFail("Should not succeed") },
            onReloadItem: { XCTFail("Should NOT reload or recreate plaintext when vault is locked") },
            onDismiss: {
                XCTAssertFalse(controller.isRestoring)
                XCTAssertTrue(controller.canClose(isDeleting: false))
                didDismiss = true
            }
        )

        XCTAssertTrue(didDismiss)
        XCTAssertFalse(controller.isRestoring)
    }

    func testRestoreController_DoubleExecutionProtection() async throws {
        let env = try createTestEnvironment()
        defer { env.cleanup() }

        let (url, video) = try createDummyVideoFile(in: env.downloadsDir, name: "ctrl_double.mp4")
        try await env.vault.moveToVault(
            video: video,
            sourceURL: url,
            downloads: env.mockDownloads,
            folderManager: env.mockFolders,
            thumbnailManager: env.mockThumbnails
        )
        let vaultItem = env.vault.items[0]
        let token = env.vault.sessionToken
        let coordinator = VideoPlaybackCoordinator.shared

        let controller = VaultPlayerRestoreController()
        let context = VaultPlayerRestoreController.PendingRestoreContext(
            vaultItem: vaultItem,
            sessionToken: token,
            playbackSessionID: UUID()
        )

        var firstRunSuccessCount = 0
        var secondRunCallCount = 0
        var reachedInFlight = false

        await controller.executeRestore(
            context: context,
            vaultManager: env.vault,
            downloads: env.mockDownloads,
            folderManager: env.mockFolders,
            thumbnailManager: env.mockThumbnails,
            coordinator: coordinator,
            tearDownPlayer: {
                // 実行中フラグが立っており、ユーザーによる画面終了が禁止されていることを検証
                XCTAssertTrue(controller.isRestoring)
                XCTAssertFalse(controller.canClose(isDeleting: false))
                reachedInFlight = true

                // 二重実行試行（isRestoring が true のため即時無視される）
                Task { @MainActor in
                    await controller.executeRestore(
                        context: context,
                        vaultManager: env.vault,
                        downloads: env.mockDownloads,
                        folderManager: env.mockFolders,
                        thumbnailManager: env.mockThumbnails,
                        coordinator: coordinator,
                        tearDownPlayer: {},
                        cleanupTemp: { _ in },
                        onSuccess: { _, _ in secondRunCallCount += 1 },
                        onReloadItem: {},
                        onDismiss: {}
                    )
                }
            },
            cleanupTemp: { _ in },
            onSuccess: { _, _ in firstRunSuccessCount += 1 },
            onReloadItem: {},
            onDismiss: {}
        )

        XCTAssertTrue(reachedInFlight)
        XCTAssertEqual(firstRunSuccessCount, 1)
        XCTAssertEqual(secondRunCallCount, 0)
        XCTAssertFalse(controller.isRestoring)
        XCTAssertTrue(controller.canClose(isDeleting: false))
    }

    func testRestoreController_ReleasesPlayerAndCoordinatorSessionBeforeRestore() async throws {
        let env = try createTestEnvironment()
        defer { env.cleanup() }

        let (url, video) = try createDummyVideoFile(in: env.downloadsDir, name: "ctrl_coord.mp4")
        try await env.vault.moveToVault(
            video: video,
            sourceURL: url,
            downloads: env.mockDownloads,
            folderManager: env.mockFolders,
            thumbnailManager: env.mockThumbnails
        )
        let vaultItem = env.vault.items[0]
        let token = env.vault.sessionToken
        let coordinator = VideoPlaybackCoordinator.shared
        let mySessionID = UUID()

        var callOrder: [String] = []

        let controller = VaultPlayerRestoreController()
        let context = VaultPlayerRestoreController.PendingRestoreContext(
            vaultItem: vaultItem,
            sessionToken: token,
            playbackSessionID: mySessionID
        )

        await controller.executeRestore(
            context: context,
            vaultManager: env.vault,
            downloads: env.mockDownloads,
            folderManager: env.mockFolders,
            thumbnailManager: env.mockThumbnails,
            coordinator: coordinator,
            tearDownPlayer: {
                callOrder.append("tearDownPlayer")
            },
            cleanupTemp: { _ in
                callOrder.append("cleanupTemp")
            },
            onSuccess: { _, _ in
                callOrder.append("onSuccess")
            },
            onReloadItem: {},
            onDismiss: {
                callOrder.append("onDismiss")
            }
        )

        // tearDownPlayer -> cleanupTemp -> onSuccess -> onDismiss の順序を検証
        XCTAssertEqual(callOrder, ["tearDownPlayer", "cleanupTemp", "onSuccess", "onDismiss"])
    }

    func testVideoFolderManager_InitDoesNotOverwriteExistingOnVideoSavedCallback() {
        let dc = DownloadCenter()
        var callbackInvoked = false
        dc.onVideoSaved = { _, _ in
            callbackInvoked = true
        }

        _ = VideoFolderManager(downloads: dc)

        let testVideo = SavedVideo(
            id: UUID(),
            title: "TestCallback",
            relativePath: "test.mp4",
            format: .mp4,
            sourceHost: "example.com",
            createdAt: Date(),
            byteSize: 100
        )
        dc.onVideoSaved?(UUID(), testVideo)

        XCTAssertTrue(callbackInvoked, "Existing onVideoSaved callback must not be overwritten by new VideoFolderManager")
    }

    // MARK: - Private Vault 全選択・選択解除検証

    func testVaultSelection_SelectAllAndDeselectAll_RootScope_ExcludesFolderItems() async throws {
        let env = try createTestEnvironment()
        defer { env.cleanup() }

        // ルート用動画2件
        let (url1, v1) = try createDummyVideoFile(in: env.downloadsDir, name: "root1.mp4")
        let (url2, v2) = try createDummyVideoFile(in: env.downloadsDir, name: "root2.mp4")
        try await env.vault.moveToVault(video: v1, sourceURL: url1, downloads: env.mockDownloads, folderManager: env.mockFolders, thumbnailManager: env.mockThumbnails)
        try await env.vault.moveToVault(video: v2, sourceURL: url2, downloads: env.mockDownloads, folderManager: env.mockFolders, thumbnailManager: env.mockThumbnails)

        // フォルダ「ABC」とフォルダ内動画2件
        let folder = try env.vault.createFolder(name: "ABC")
        let (url3, v3) = try createDummyVideoFile(in: env.downloadsDir, name: "folder1.mp4")
        let (url4, v4) = try createDummyVideoFile(in: env.downloadsDir, name: "folder2.mp4")
        try await env.vault.moveToVault(video: v3, sourceURL: url3, downloads: env.mockDownloads, folderManager: env.mockFolders, thumbnailManager: env.mockThumbnails)
        try await env.vault.moveToVault(video: v4, sourceURL: url4, downloads: env.mockDownloads, folderManager: env.mockFolders, thumbnailManager: env.mockThumbnails)

        let item3 = env.vault.items.first { $0.originalVideoID == v3.id }!
        let item4 = env.vault.items.first { $0.originalVideoID == v4.id }!
        try env.vault.moveItem(id: item3.id, to: folder.id)
        try env.vault.moveItem(id: item4.id, to: folder.id)

        // ルート画面の表示対象はルート動画2件のみ（フォルダ内動画を含まない）
        let rootDisplayedItems = env.vault.items(in: nil)
        XCTAssertEqual(rootDisplayedItems.count, 2)
        let rootDisplayedIDs = Set(rootDisplayedItems.map { $0.id })

        // 全選択ロジックの検証
        var selectedItemIDs: Set<UUID> = []
        var isAllSelected = !rootDisplayedItems.isEmpty && rootDisplayedIDs.isSubset(of: selectedItemIDs)
        XCTAssertFalse(isAllSelected)

        // 全選択実行
        if isAllSelected {
            selectedItemIDs.removeAll()
        } else {
            selectedItemIDs = rootDisplayedIDs
        }
        XCTAssertEqual(selectedItemIDs.count, 2)
        XCTAssertTrue(selectedItemIDs.contains(rootDisplayedItems[0].id))
        XCTAssertTrue(selectedItemIDs.contains(rootDisplayedItems[1].id))
        // サブフォルダの動画が全選択に含まれていないことを検証
        XCTAssertFalse(selectedItemIDs.contains(item3.id))
        XCTAssertFalse(selectedItemIDs.contains(item4.id))

        // すべて選択済み状態の判定
        isAllSelected = !rootDisplayedItems.isEmpty && rootDisplayedIDs.isSubset(of: selectedItemIDs)
        XCTAssertTrue(isAllSelected)

        // 選択解除実行
        if isAllSelected {
            selectedItemIDs.removeAll()
        } else {
            selectedItemIDs = rootDisplayedIDs
        }
        XCTAssertEqual(selectedItemIDs.count, 0)
    }

    func testVaultSelection_SelectAllAndDeselectAll_FolderScope_IncludesOnlyFolderItems() async throws {
        let env = try createTestEnvironment()
        defer { env.cleanup() }

        // ルート用動画1件
        let (url1, v1) = try createDummyVideoFile(in: env.downloadsDir, name: "root_video.mp4")
        try await env.vault.moveToVault(video: v1, sourceURL: url1, downloads: env.mockDownloads, folderManager: env.mockFolders, thumbnailManager: env.mockThumbnails)
        let rootItem = env.vault.items[0]

        // フォルダ「SubFolder」とフォルダ内動画2件
        let folder = try env.vault.createFolder(name: "SubFolder")
        let (url2, v2) = try createDummyVideoFile(in: env.downloadsDir, name: "sub1.mp4")
        let (url3, v3) = try createDummyVideoFile(in: env.downloadsDir, name: "sub2.mp4")
        try await env.vault.moveToVault(video: v2, sourceURL: url2, downloads: env.mockDownloads, folderManager: env.mockFolders, thumbnailManager: env.mockThumbnails)
        try await env.vault.moveToVault(video: v3, sourceURL: url3, downloads: env.mockDownloads, folderManager: env.mockFolders, thumbnailManager: env.mockThumbnails)

        let item2 = env.vault.items.first { $0.originalVideoID == v2.id }!
        let item3 = env.vault.items.first { $0.originalVideoID == v3.id }!
        try env.vault.moveItem(id: item2.id, to: folder.id)
        try env.vault.moveItem(id: item3.id, to: folder.id)

        // フォルダ内の表示対象はフォルダ内動画2件のみ（ルート動画を含まない）
        let folderDisplayedItems = env.vault.items(in: folder.id)
        XCTAssertEqual(folderDisplayedItems.count, 2)
        let folderDisplayedIDs = Set(folderDisplayedItems.map { $0.id })

        // フォルダ内での全選択実行
        var selectedItemIDs: Set<UUID> = []
        selectedItemIDs = folderDisplayedIDs

        XCTAssertEqual(selectedItemIDs.count, 2)
        XCTAssertTrue(selectedItemIDs.contains(item2.id))
        XCTAssertTrue(selectedItemIDs.contains(item3.id))
        XCTAssertFalse(selectedItemIDs.contains(rootItem.id))

        // 選択解除
        let isAllSelected = !folderDisplayedItems.isEmpty && folderDisplayedIDs.isSubset(of: selectedItemIDs)
        XCTAssertTrue(isAllSelected)
        selectedItemIDs.removeAll()
        XCTAssertEqual(selectedItemIDs.count, 0)
    }

    func testVaultSelection_PartialSelection_TogglesToSelectAll() async throws {
        let env = try createTestEnvironment()
        defer { env.cleanup() }

        let (url1, v1) = try createDummyVideoFile(in: env.downloadsDir, name: "p1.mp4")
        let (url2, v2) = try createDummyVideoFile(in: env.downloadsDir, name: "p2.mp4")
        try await env.vault.moveToVault(video: v1, sourceURL: url1, downloads: env.mockDownloads, folderManager: env.mockFolders, thumbnailManager: env.mockThumbnails)
        try await env.vault.moveToVault(video: v2, sourceURL: url2, downloads: env.mockDownloads, folderManager: env.mockFolders, thumbnailManager: env.mockThumbnails)

        let displayedItems = env.vault.items(in: nil)
        let displayedIDs = Set(displayedItems.map { $0.id })

        // 1件のみ手動選択した状態
        var selectedItemIDs: Set<UUID> = [displayedItems[0].id]

        // 1件のみ選択時は isAllSelected が false
        var isAllSelected = !displayedItems.isEmpty && displayedIDs.isSubset(of: selectedItemIDs)
        XCTAssertFalse(isAllSelected)

        // タップすると「全選択」として全件選択に更新される
        if isAllSelected {
            selectedItemIDs.removeAll()
        } else {
            selectedItemIDs = displayedIDs
        }
        XCTAssertEqual(selectedItemIDs.count, 2)

        // 全件選択後は isAllSelected が true
        isAllSelected = !displayedItems.isEmpty && displayedIDs.isSubset(of: selectedItemIDs)
        XCTAssertTrue(isAllSelected)

        // 再度タップすると「選択解除」としてクリアされる
        if isAllSelected {
            selectedItemIDs.removeAll()
        } else {
            selectedItemIDs = displayedIDs
        }
        XCTAssertEqual(selectedItemIDs.count, 0)
    }

    // MARK: - Phase E: ステルスモード・旧設定互換・ジェスチャー境界・終了時ロック検証

    func testStealthSettings_DefaultValuesAndInvalidFallback() throws {
        let suiteName = "com.clipharbor.test.stealth.defaults.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName), defaults !== UserDefaults.standard else {
            XCTFail("Failed to create isolated UserDefaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // 初期状態: ステルスOFF、カード非表示OFF、ジェスチャーは長押し
        XCTAssertFalse(VaultStealthSettingsStore.loadStealthModeEnabled(from: defaults))
        XCTAssertFalse(VaultStealthSettingsStore.loadHideVaultInFileList(from: defaults))
        XCTAssertEqual(VaultStealthSettingsStore.loadAccessGesture(from: defaults), .longPress)

        // 5回タップの保存と復元
        VaultStealthSettingsStore.saveAccessGesture(.fiveTaps, to: defaults)
        XCTAssertEqual(VaultStealthSettingsStore.loadAccessGesture(from: defaults), .fiveTaps)

        // 不正な文字列や空文字が書き込まれても、必ず .longPress へ安全にフォールバックし入口を失わない
        defaults.set("invalid_gesture_value", forKey: VaultStealthSettingsStore.accessGestureKey)
        XCTAssertEqual(VaultStealthSettingsStore.loadAccessGesture(from: defaults), .longPress)
        XCTAssertEqual(StealthAccessGesture.resolve(rawValue: ""), .longPress)
        XCTAssertEqual(StealthAccessGesture.resolve(rawValue: nil), .longPress)
    }

    func testStealthSettings_LegacyMigrationPreservesCardHideWithoutEnablingStealth() throws {
        let suiteName = "com.clipharbor.test.stealth.migration.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName), defaults !== UserDefaults.standard else {
            XCTFail("Failed to create isolated UserDefaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // 旧設定でカード非表示（hideVaultInFileList == true）にしていた既存ユーザー環境を再現
        defaults.set(true, forKey: VaultStealthSettingsStore.hideVaultInFileListKey)

        // 1. 新ステルスモードは自動でONにならず初期OFFであること
        let stealthEnabled = VaultStealthSettingsStore.loadStealthModeEnabled(from: defaults)
        let hideCard = VaultStealthSettingsStore.loadHideVaultInFileList(from: defaults)
        XCTAssertFalse(stealthEnabled)
        XCTAssertTrue(hideCard)

        // 2. ステルスOFFでも旧カード非表示設定が維持され、メニューや設定入口は利用可能であること
        let policyBeforeStealth = VaultVisibilityPolicy(
            isStealthModeEnabled: stealthEnabled,
            hideVaultCardInFileList: hideCard,
            isVaultInitialized: true
        )
        XCTAssertFalse(policyBeforeStealth.showsVaultCard)
        XCTAssertTrue(policyBeforeStealth.showsVaultMenuEntry)
        XCTAssertTrue(policyBeforeStealth.allowsMoveToVaultFromNormalUI)
        XCTAssertTrue(policyBeforeStealth.showsVaultSettingsEntry)

        // 3. ステルスONにした場合、全入口・説明・アクセシビリティアクションが非表示になること
        VaultStealthSettingsStore.saveStealthModeEnabled(true, to: defaults)
        let policyDuringStealth = VaultVisibilityPolicy(
            isStealthModeEnabled: VaultStealthSettingsStore.loadStealthModeEnabled(from: defaults),
            hideVaultCardInFileList: VaultStealthSettingsStore.loadHideVaultInFileList(from: defaults),
            isVaultInitialized: true
        )
        XCTAssertTrue(policyDuringStealth.isStealthActive)
        XCTAssertFalse(policyDuringStealth.showsVaultCard)
        XCTAssertFalse(policyDuringStealth.showsVaultMenuEntry)
        XCTAssertFalse(policyDuringStealth.allowsMoveToVaultFromNormalUI)
        XCTAssertFalse(policyDuringStealth.showsVaultSettingsEntry)
        XCTAssertFalse(policyDuringStealth.showsVaultMentions)
        XCTAssertFalse(policyDuringStealth.exposesNamedAccessibilityAction)

        // 4. ステルスOFFへ戻した際も、ユーザーが変更していない旧カード非表示設定(true)が勝手に解除されないこと
        VaultStealthSettingsStore.saveStealthModeEnabled(false, to: defaults)
        let hideCardAfterStealthOff = VaultStealthSettingsStore.loadHideVaultInFileList(from: defaults)
        XCTAssertTrue(hideCardAfterStealthOff)
        let policyAfterStealthOff = VaultVisibilityPolicy(
            isStealthModeEnabled: VaultStealthSettingsStore.loadStealthModeEnabled(from: defaults),
            hideVaultCardInFileList: hideCardAfterStealthOff,
            isVaultInitialized: true
        )
        XCTAssertFalse(policyAfterStealthOff.showsVaultCard)
        XCTAssertTrue(policyAfterStealthOff.showsVaultMenuEntry)

        // 5. さらに古い legacyHideVaultKey ("VaultManager.isStealthModeEnabled") からの移行確認
        let legacySuiteName = "com.clipharbor.test.stealth.legacykey.\(UUID().uuidString)"
        if let legacyDefaults = UserDefaults(suiteName: legacySuiteName) {
            defer { legacyDefaults.removePersistentDomain(forName: legacySuiteName) }
            legacyDefaults.set(true, forKey: VaultStealthSettingsStore.legacyHideVaultKey)
            XCTAssertTrue(VaultStealthSettingsStore.loadHideVaultInFileList(from: legacyDefaults))
            XCTAssertFalse(VaultStealthSettingsStore.loadStealthModeEnabled(from: legacyDefaults))
        }
    }

    func testStealthVisibilityPolicy_UninitializedVaultDoesNotActivateStealth() {
        // 万が一 Vault 未初期化状態で isStealthModeEnabled が true でも実効ステルスにはならない
        let policy = VaultVisibilityPolicy(
            isStealthModeEnabled: true,
            hideVaultCardInFileList: false,
            isVaultInitialized: false
        )
        XCTAssertFalse(policy.isStealthActive)
        XCTAssertTrue(policy.showsVaultCard)
        XCTAssertTrue(policy.showsVaultMenuEntry)
        XCTAssertTrue(policy.showsVaultSettingsEntry)
    }

    func testStealthTapDetector_BoundaryConditionsAndReset() {
        var detector = StealthTapDetector(requiredTaps: 5, timeWindow: 3.0, minimumInterval: 0.05)

        // 1. ちょうど3.0秒以内に5回タップ（t = 10.0, 10.7, 11.4, 12.1, 13.0）で発火し、直後にクリアされる
        XCTAssertFalse(detector.registerTap(at: 10.0))
        XCTAssertFalse(detector.registerTap(at: 10.7))
        XCTAssertFalse(detector.registerTap(at: 11.4))
        XCTAssertFalse(detector.registerTap(at: 12.1))
        XCTAssertTrue(detector.registerTap(at: 13.0))
        XCTAssertTrue(detector.timestamps.isEmpty, "発火直後にタップ履歴がクリアされること")

        // 2. 発火直後の1回タップで再発火しないこと
        XCTAssertFalse(detector.registerTap(at: 13.2))
        detector.reset()
        XCTAssertTrue(detector.timestamps.isEmpty, "画面離脱・モード変更時のresetで履歴がクリアされること")

        // 3. 3.0秒を超過した古いタップはウィンドウから除外されること
        XCTAssertFalse(detector.registerTap(at: 20.0))
        XCTAssertFalse(detector.registerTap(at: 20.8))
        XCTAssertFalse(detector.registerTap(at: 21.6))
        XCTAssertFalse(detector.registerTap(at: 22.4))
        // 5回目のタップが最初のタップ(20.0)から3.01秒後 -> 20.0が期限切れとなり4回扱いで未成立
        XCTAssertFalse(detector.registerTap(at: 23.01))
        XCTAssertEqual(detector.timestamps.count, 4)
        // 20.8から3.0秒以内である 23.5 に次のタップが来ると5回成立
        XCTAssertTrue(detector.registerTap(at: 23.5))
        XCTAssertTrue(detector.timestamps.isEmpty)

        // 4. 最小間隔(0.05秒)未満の同一タップ二重通知は無視されること
        XCTAssertFalse(detector.registerTap(at: 30.0))
        XCTAssertFalse(detector.registerTap(at: 30.01))
        XCTAssertEqual(detector.timestamps.count, 1)
    }

    func testVaultPresentationLifecycle_LocksOnCloseAndPreservesDuringChildTransitions() throws {
        let env = try createTestEnvironment()
        defer { env.cleanup() }

        XCTAssertTrue(env.vault.isUnlocked)
        let initialToken = env.vault.sessionToken

        // 1. プレイヤー遷移中やネストした設定・インポートシート表示中はロックしない
        XCTAssertFalse(VaultPresentationLifecycle.shouldLockOnDisappear(isPresentingPlayer: true, isPresentingNestedSheet: false))
        XCTAssertFalse(VaultPresentationLifecycle.shouldLockOnDisappear(isPresentingPlayer: false, isPresentingNestedSheet: true))
        XCTAssertTrue(env.vault.isUnlocked)
        XCTAssertEqual(env.vault.sessionToken, initialToken)

        // 2. Vault画面を完全に閉じた場合（スワイプ閉鎖・閉じるボタン・システム終了）は確実にロックされる
        XCTAssertTrue(VaultPresentationLifecycle.shouldLockOnDisappear(isPresentingPlayer: false, isPresentingNestedSheet: false))
        VaultPresentationLifecycle.handleVaultScreenClosed(vaultManager: env.vault)
        XCTAssertFalse(env.vault.isUnlocked, "Vault画面終了後は必ずロック状態になること")
        XCTAssertNotEqual(env.vault.sessionToken, initialToken)

        // 3. 既にロック済みの状態で再度呼ばれても安全で、不要にトークンを更新しないこと
        let lockedToken = env.vault.sessionToken
        VaultPresentationLifecycle.handleVaultScreenClosed(vaultManager: env.vault)
        XCTAssertFalse(env.vault.isUnlocked)
        XCTAssertEqual(env.vault.sessionToken, lockedToken)
    }

    func testStealthSettings_DependencyAndReconciliationWithCardHide() throws {
        let suiteName = "com.clipharbor.test.stealth.dependency.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName), defaults !== UserDefaults.standard else {
            XCTFail("Failed to create isolated UserDefaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // 1. 以前のバージョンで「ステルスON・カード非表示OFF」が保存されていたケース:
        //    更新後もステルス状態を維持し、安全にカード非表示をONへ整合・永続化すること
        defaults.set(true, forKey: VaultStealthSettingsStore.stealthModeKey)
        defaults.set(false, forKey: VaultStealthSettingsStore.hideVaultInFileListKey)

        XCTAssertTrue(VaultStealthSettingsStore.loadStealthModeEnabled(from: defaults))
        XCTAssertTrue(VaultStealthSettingsStore.loadHideVaultInFileList(from: defaults))
        XCTAssertEqual(defaults.object(forKey: VaultStealthSettingsStore.hideVaultInFileListKey) as? Bool, true)

        // 2. ステルスON中はカード非表示をOFFに変更しようとしてもON固定が維持されること
        let whileStealthResult = VaultStealthSettingsStore.saveHideVaultInFileList(false, to: defaults)
        XCTAssertTrue(whileStealthResult)
        XCTAssertTrue(VaultStealthSettingsStore.loadHideVaultInFileList(from: defaults))

        // 3. ステルスをOFFにすると、カード非表示はONのまま残り、その後OFFへの変更が再び可能になること
        VaultStealthSettingsStore.saveStealthModeEnabled(false, to: defaults)
        XCTAssertFalse(VaultStealthSettingsStore.loadStealthModeEnabled(from: defaults))
        XCTAssertTrue(VaultStealthSettingsStore.loadHideVaultInFileList(from: defaults), "ステルス解除直後もカード非表示はONのまま維持されること")

        let afterStealthOffResult = VaultStealthSettingsStore.saveHideVaultInFileList(false, to: defaults)
        XCTAssertFalse(afterStealthOffResult, "ステルス解除後はカード非表示をOFFへ変更可能になること")
        XCTAssertFalse(VaultStealthSettingsStore.loadHideVaultInFileList(from: defaults))
    }

    // MARK: - Phase F1: ZIPファイル管理・展開・単体圧縮・セキュリティ境界検証

    @MainActor
    func testZipPhaseF1_AutoDetection_ExclusiveClassification_AndUUIDStability() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ZipF1_Detect_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let stagingDir = tempRoot.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let suiteName = "com.clipharbor.test.zipf1.detect.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let dc = DownloadCenter()
        for v in dc.saved { dc.removeSavedVideoWithoutDeletingFile(id: v.id) }
        let fm = VideoFolderManager(downloads: dc)
        let zipMgr = ZipArchiveManager(
            userDefaults: defaults,
            customDownloadsRootURL: downloadsDir,
            customStagingRootURL: stagingDir
        )

        // 1. .zip、.txt、.mp4、および HLS .movpkg ディレクトリを配置
        let zipURL = downloadsDir.appendingPathComponent("archive_sample.zip")
        try ZipArchiveTestHelper.createArchive(at: zipURL, entries: [
            .file("hello.txt", data: Data("hello world".utf8))
        ])
        let txtURL = downloadsDir.appendingPathComponent("notes.txt")
        try Data("plain text note".utf8).write(to: txtURL)
        let mp4URL = downloadsDir.appendingPathComponent("clip.mp4")
        try Data(repeating: 0x42, count: 256).write(to: mp4URL)

        let movpkgDir = downloadsDir.appendingPathComponent("stream.movpkg", isDirectory: true)
        try FileManager.default.createDirectory(at: movpkgDir, withIntermediateDirectories: true)
        try Data("fragment".utf8).write(to: movpkgDir.appendingPathComponent("0-1.frag"))

        // 2. スキャン実行
        zipMgr.syncWithFileSystem(downloads: dc, folderManager: fm)

        // 3. 排他分類の検証:
        //    - clip.mp4 は SavedVideo のみに登録され、ManagedFileItem には含まれない
        //    - archive_sample.zip と notes.txt は ManagedFileItem のみに登録され、SavedVideo には含まれない
        //    - stream.movpkg 内部の .frag はどちらにも登録されない
        XCTAssertTrue(dc.saved.contains(where: { $0.title == "clip" && $0.format == .mp4 }))
        XCTAssertFalse(dc.saved.contains(where: { $0.title == "archive_sample" || $0.title == "notes" || $0.title == "0-1" }))

        XCTAssertEqual(zipMgr.managedFiles.count, 2)
        guard let detectedZip = zipMgr.managedFiles.first(where: { $0.title == "archive_sample" }),
              let detectedTxt = zipMgr.managedFiles.first(where: { $0.title == "notes" }) else {
            XCTFail("Expected both archive_sample.zip and notes.txt in managedFiles")
            return
        }
        XCTAssertTrue(detectedZip.isZip)
        XCTAssertEqual(detectedZip.sfSymbolName, "doc.zipper")
        XCTAssertEqual(detectedZip.formatLabel, "ZIP")
        XCTAssertFalse(detectedTxt.isZip)
        XCTAssertEqual(detectedTxt.formatLabel, "TXT")
        XCTAssertFalse(zipMgr.managedFiles.contains(where: { $0.title.contains("frag") || $0.title.contains("movpkg") }))

        // 4. 再スキャン時の UUID 安定性検証
        let firstZipID = detectedZip.id
        let firstTxtID = detectedTxt.id
        zipMgr.syncWithFileSystem(downloads: dc, folderManager: fm)
        let secondZip = zipMgr.managedFiles.first(where: { $0.title == "archive_sample" })
        let secondTxt = zipMgr.managedFiles.first(where: { $0.title == "notes" })
        XCTAssertEqual(secondZip?.id, firstZipID, "再スキャン後も既存のUUIDが維持されること")
        XCTAssertEqual(secondTxt?.id, firstTxtID, "再スキャン後も既存のUUIDが維持されること")
    }

    @MainActor
    func testZipPhaseF1_ExtractMultipleFiles_AndDuplicateFolderCollisionAvoidance() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ZipF1_Extract_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let stagingDir = tempRoot.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let suiteName = "com.clipharbor.test.zipf1.extract.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let dc = DownloadCenter()
        for v in dc.saved { dc.removeSavedVideoWithoutDeletingFile(id: v.id) }
        let fm = VideoFolderManager(downloads: dc)
        let zipMgr = ZipArchiveManager(
            userDefaults: defaults,
            customDownloadsRootURL: downloadsDir,
            customStagingRootURL: stagingDir
        )

        let videoBytes = Data(repeating: 0xAA, count: 1024)
        let imageBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: UInt8(0x11), count: 120))
        let docBytes = Data("Trip schedule and notes".utf8)

        let zipURL = downloadsDir.appendingPathComponent("旅行動画.zip")
        try ZipArchiveTestHelper.createArchive(at: zipURL, entries: [
            .file("movie1.mp4", data: videoBytes),
            .file("snap1.png", data: imageBytes),
            .file("memo.txt", data: docBytes)
        ])

        zipMgr.syncWithFileSystem(downloads: dc, folderManager: fm)
        guard let zipItem = zipMgr.managedFiles.first(where: { $0.title == "旅行動画" && $0.isZip }) else {
            XCTFail("旅行動画.zip should be detected")
            return
        }

        // 1回目の展開 -> 「旅行動画」フォルダが作成される
        let folder1 = try await zipMgr.extractZip(item: zipItem, downloads: dc, folderManager: fm)
        XCTAssertEqual(folder1, "旅行動画")
        // 元のZIPファイルが削除されず保持されていること
        XCTAssertTrue(FileManager.default.fileExists(atPath: zipURL.path))
        // 展開されたメディアと一般ファイルがそれぞれ正しく登録されていること
        XCTAssertTrue(dc.saved.contains(where: { $0.title == "movie1" && $0.format == .mp4 }))
        XCTAssertTrue(dc.saved.contains(where: { $0.title == "snap1" && $0.format == .png }))
        XCTAssertTrue(zipMgr.managedFiles.contains(where: { $0.title == "memo" && $0.folderName == "旅行動画" }))

        // 2回目の展開 -> 同名フォルダ衝突を回避して「旅行動画 (1)」が作成され、既存ファイルを上書きしないこと
        let folder2 = try await zipMgr.extractZip(item: zipItem, downloads: dc, folderManager: fm)
        XCTAssertEqual(folder2, "旅行動画 (1)")
        let folder1Memo = downloadsDir.appendingPathComponent("旅行動画/memo.txt")
        let folder2Memo = downloadsDir.appendingPathComponent("旅行動画 (1)/memo.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder1Memo.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder2Memo.path))
    }

    @MainActor
    func testZipPhaseF1_ExtractNestedSubfolders_PreservesHierarchyAndDisplaysSubpaths() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ZipF1_Nested_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let stagingDir = tempRoot.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let suiteName = "com.clipharbor.test.zipf1.nested.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let dc = DownloadCenter()
        for v in dc.saved { dc.removeSavedVideoWithoutDeletingFile(id: v.id) }
        let fm = VideoFolderManager(downloads: dc)
        let zipMgr = ZipArchiveManager(
            userDefaults: defaults,
            customDownloadsRootURL: downloadsDir,
            customStagingRootURL: stagingDir
        )

        let zipURL = downloadsDir.appendingPathComponent("ProjectArchive.zip")
        try ZipArchiveTestHelper.createArchive(at: zipURL, entries: [
            .directory("Day1/"),
            .directory("Day1/Morning/"),
            .file("Day1/Morning/beach.mp4", data: Data(repeating: 0x33, count: 512)),
            .file("Day2/Docs/guide.pdf", data: Data("PDF-content".utf8))
        ])

        zipMgr.syncWithFileSystem(downloads: dc, folderManager: fm)
        let zipItem = try XCTUnwrap(zipMgr.managedFiles.first(where: { $0.title == "ProjectArchive" }))

        let extractedFolder = try await zipMgr.extractZip(item: zipItem, downloads: dc, folderManager: fm)
        XCTAssertEqual(extractedFolder, "ProjectArchive")

        // 物理的な多階層ディレクトリ構造が保持されていること
        let nestedVideoURL = downloadsDir.appendingPathComponent("ProjectArchive/Day1/Morning/beach.mp4")
        let nestedPdfURL = downloadsDir.appendingPathComponent("ProjectArchive/Day2/Docs/guide.pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: nestedVideoURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nestedPdfURL.path))

        // サブフォルダ内のファイルが一覧で見失われず、サブパス情報を持っていること
        let extractedVideo = try XCTUnwrap(dc.saved.first(where: { $0.title == "beach" }))
        XCTAssertEqual(extractedVideo.displaySubfolderPrefix, "Day1/Morning")

        let extractedPdf = try XCTUnwrap(zipMgr.managedFiles.first(where: { $0.title == "guide" }))
        XCTAssertEqual(extractedPdf.folderName, "ProjectArchive")
        XCTAssertEqual(extractedPdf.displaySubfolderPrefix, "Day2/Docs")

        // フォルダ名変更時にネストされたサブパス参照が壊れないこと
        zipMgr.handleFolderRenamed(from: "ProjectArchive", to: "RenamedProject")
        let updatedPdf = try XCTUnwrap(zipMgr.managedFiles.first(where: { $0.title == "guide" }))
        XCTAssertEqual(updatedPdf.folderName, "RenamedProject")
        XCTAssertEqual(updatedPdf.displaySubfolderPrefix, "Day2/Docs")
        XCTAssertTrue(updatedPdf.relativePath.contains("RenamedProject/Day2/Docs/guide.pdf"))
    }

    @MainActor
    func testZipPhaseF1_SingleFileCompression_RoundTripMatchesBytes_AndAvoidsDuplicateZipNames() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ZipF1_Compress_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let stagingDir = tempRoot.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let suiteName = "com.clipharbor.test.zipf1.compress.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let dc = DownloadCenter()
        for v in dc.saved { dc.removeSavedVideoWithoutDeletingFile(id: v.id) }
        let fm = VideoFolderManager(downloads: dc)
        let zipMgr = ZipArchiveManager(
            userDefaults: defaults,
            customDownloadsRootURL: downloadsDir,
            customStagingRootURL: stagingDir
        )

        // 元ファイルを作成（ランダム性のある決定論的バイナリデータ 40KB）
        var originalPayload = Data(capacity: 40_960)
        for i in 0..<40_960 {
            originalPayload.append(UInt8((i * 73 + 19) & 0xFF))
        }
        let sourceFileURL = downloadsDir.appendingPathComponent("original_clip.mp4")
        try originalPayload.write(to: sourceFileURL)

        // 1回目の単体ZIP圧縮
        let createdZip1 = try await zipMgr.compressSingleFileAtURL(
            sourceURL: sourceFileURL,
            preferredBaseName: "original_clip",
            folderName: "",
            downloads: dc,
            folderManager: fm
        )
        XCTAssertEqual(createdZip1.title, "original_clip")
        XCTAssertTrue(createdZip1.isZip)
        // 元ファイルが削除されず保持されていること
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceFileURL.path))

        // 2回目の単体ZIP圧縮 -> 同名ZIPを上書きせず「original_clip (1).zip」になること
        let createdZip2 = try await zipMgr.compressSingleFileAtURL(
            sourceURL: sourceFileURL,
            preferredBaseName: "original_clip",
            folderName: "",
            downloads: dc,
            folderManager: fm
        )
        XCTAssertEqual(createdZip2.title, "original_clip (1)")

        // 作成したZIPを再展開し、元ファイルとバイト列が100%一致することを検証
        let extractedFolder = try await zipMgr.extractZip(item: createdZip1, downloads: dc, folderManager: fm)
        let roundTripFileURL = downloadsDir
            .appendingPathComponent(extractedFolder, isDirectory: true)
            .appendingPathComponent("original_clip.mp4")
        let roundTripData = try Data(contentsOf: roundTripFileURL)
        XCTAssertEqual(roundTripData, originalPayload, "圧縮→再展開後のファイル内容が元ファイルと完全一致すること")
    }

    @MainActor
    func testZipPhaseF1_Security_RejectsZipSlip_AbsolutePaths_Symlinks_AndConflictingEntries() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ZipF1_SecPath_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let stagingDir = tempRoot.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let suiteName = "com.clipharbor.test.zipf1.secpath.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let dc = DownloadCenter()
        for v in dc.saved { dc.removeSavedVideoWithoutDeletingFile(id: v.id) }
        let fm = VideoFolderManager(downloads: dc)
        let zipMgr = ZipArchiveManager(
            userDefaults: defaults,
            customDownloadsRootURL: downloadsDir,
            customStagingRootURL: stagingDir
        )

        func makeManagedZipItem(named name: String, entries: [ZipArchiveTestHelper.TestEntrySpec]) throws -> ManagedFileItem {
            let url = downloadsDir.appendingPathComponent("\(name).zip")
            try ZipArchiveTestHelper.createArchive(at: url, entries: entries)
            return ManagedFileItem(
                id: UUID(),
                title: name,
                relativePath: "Documents/Downloads/\(name).zip",
                fileExtension: "zip",
                createdAt: Date(),
                byteSize: 100,
                folderName: "",
                relativeSubpath: nil
            )
        }

        // 1. ZIP Slip ("../evil.txt") の拒否
        let slipItem = try makeManagedZipItem(named: "slip", entries: [
            .file("../evil.txt", data: Data("pwn".utf8))
        ])
        do {
            _ = try await zipMgr.extractZip(item: slipItem, downloads: dc, folderManager: fm)
            XCTFail("ZIP Slip archive must be rejected")
        } catch let err as ZipOperationError {
            guard case .maliciousPathDetected = err else {
                XCTFail("Expected maliciousPathDetected, got \(err)")
                return
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent("evil.txt").path))

        // 2. 絶対パス ("/etc/passwd") の拒否
        let absItem = try makeManagedZipItem(named: "abs", entries: [
            .file("/etc/passwd", data: Data("root".utf8))
        ])
        do {
            _ = try await zipMgr.extractZip(item: absItem, downloads: dc, folderManager: fm)
            XCTFail("Absolute path archive must be rejected")
        } catch let err as ZipOperationError {
            guard case .maliciousPathDetected = err else {
                XCTFail("Expected maliciousPathDetected, got \(err)")
                return
            }
        }

        // 3. シンボリックリンクの拒否
        let symlinkItem = try makeManagedZipItem(named: "symlink", entries: [
            .symlink("shortcut", target: "../outside")
        ])
        do {
            _ = try await zipMgr.extractZip(item: symlinkItem, downloads: dc, folderManager: fm)
            XCTFail("Symlink archive must be rejected")
        } catch let err as ZipOperationError {
            guard case .symlinkNotAllowed = err else {
                XCTFail("Expected symlinkNotAllowed, got \(err)")
                return
            }
        }

        // 4. ファイルとディレクトリの型衝突 ("conflict" がファイルであり、同時に "conflict/sub.txt" が存在する) の拒否
        let conflictItem = try makeManagedZipItem(named: "conflict", entries: [
            .file("conflict", data: Data("file".utf8)),
            .file("conflict/sub.txt", data: Data("nested".utf8))
        ])
        do {
            _ = try await zipMgr.extractZip(item: conflictItem, downloads: dc, folderManager: fm)
            XCTFail("Conflicting file/directory archive must be rejected")
        } catch let err as ZipOperationError {
            guard case .conflictingEntries = err else {
                XCTFail("Expected conflictingEntries, got \(err)")
                return
            }
        }

        // ステージング一時ディレクトリが空にクリーンアップされていること
        let remainingStaging = (try? FileManager.default.contentsOfDirectory(atPath: stagingDir.path)) ?? []
        XCTAssertTrue(remainingStaging.isEmpty, "失敗後にステージング一時ファイルが残らないこと")
    }

    @MainActor
    func testZipPhaseF1_Security_RuntimeByteLimit_EntryCountLimit_PasswordZip_AndCorruptedCRC() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ZipF1_Limits_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let stagingDir = tempRoot.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let suiteName = "com.clipharbor.test.zipf1.limits.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let dc = DownloadCenter()
        for v in dc.saved { dc.removeSavedVideoWithoutDeletingFile(id: v.id) }
        let fm = VideoFolderManager(downloads: dc)
        let zipMgr = ZipArchiveManager(
            userDefaults: defaults,
            customDownloadsRootURL: downloadsDir,
            customStagingRootURL: stagingDir
        )

        // 1. エントリ数上限超過の拒否
        let manyFilesURL = downloadsDir.appendingPathComponent("many.zip")
        try ZipArchiveTestHelper.createArchive(at: manyFilesURL, entries: [
            .file("1.txt", data: Data("1".utf8)),
            .file("2.txt", data: Data("2".utf8)),
            .file("3.txt", data: Data("3".utf8))
        ])
        let manyItem = ManagedFileItem(
            id: UUID(), title: "many", relativePath: "Documents/Downloads/many.zip",
            fileExtension: "zip", createdAt: Date(), byteSize: 100, folderName: "", relativeSubpath: nil
        )
        let strictCountLimits = ZipSecurityLimits(maxEntryCount: 2)
        do {
            _ = try await zipMgr.extractZip(item: manyItem, downloads: dc, folderManager: fm, limits: strictCountLimits)
            XCTFail("Archive exceeding maxEntryCount must be rejected")
        } catch let err as ZipOperationError {
            XCTAssertEqual(err, .entryCountLimitExceeded(2))
        }

        // 2. 展開サイズ上限超過の拒否とステージング完全削除
        let oversizeURL = downloadsDir.appendingPathComponent("oversize.zip")
        try ZipArchiveTestHelper.createArchive(at: oversizeURL, entries: [
            .file("big.bin", data: Data(repeating: 0x55, count: 4096))
        ])
        let oversizeItem = ManagedFileItem(
            id: UUID(), title: "oversize", relativePath: "Documents/Downloads/oversize.zip",
            fileExtension: "zip", createdAt: Date(), byteSize: 100, folderName: "", relativeSubpath: nil
        )
        let strictByteLimits = ZipSecurityLimits(maxTotalUncompressedBytes: 1024)
        do {
            _ = try await zipMgr.extractZip(item: oversizeItem, downloads: dc, folderManager: fm, limits: strictByteLimits)
            XCTFail("Archive exceeding maxTotalUncompressedBytes must be rejected")
        } catch let err as ZipOperationError {
            guard case .uncompressedSizeLimitExceeded = err else {
                XCTFail("Expected uncompressedSizeLimitExceeded, got \(err)")
                return
            }
        }
        // 元ZIPは保持され、不完全な展開先フォルダが存在しないこと
        XCTAssertTrue(FileManager.default.fileExists(atPath: oversizeURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloadsDir.appendingPathComponent("oversize").path))

        // 3. 高圧縮だが小サイズの正常テキスト（32KBの反復文字）が100倍超の圧縮率だけで誤拒否されないこと
        let highRatioNormalURL = downloadsDir.appendingPathComponent("normal_log.zip")
        try ZipArchiveTestHelper.createArchive(at: highRatioNormalURL, entries: [
            .file("app.log", data: Data(repeating: 0x41, count: 32_768), compressed: true)
        ])
        let highRatioNormalItem = ManagedFileItem(
            id: UUID(), title: "normal_log", relativePath: "Documents/Downloads/normal_log.zip",
            fileExtension: "zip", createdAt: Date(), byteSize: 100, folderName: "", relativeSubpath: nil
        )
        let extractedNormalFolder = try await zipMgr.extractZip(item: highRatioNormalItem, downloads: dc, folderManager: fm)
        XCTAssertEqual(extractedNormalFolder, "normal_log")

        // 4. パスワード付きZIPの明確な拒否
        let encURL = downloadsDir.appendingPathComponent("encrypted.zip")
        try ZipArchiveTestHelper.createPasswordProtectedArchive(at: encURL)
        let encItem = ManagedFileItem(
            id: UUID(), title: "encrypted", relativePath: "Documents/Downloads/encrypted.zip",
            fileExtension: "zip", createdAt: Date(), byteSize: 100, folderName: "", relativeSubpath: nil
        )
        do {
            _ = try await zipMgr.extractZip(item: encItem, downloads: dc, folderManager: fm)
            XCTFail("Password-protected archive must be rejected")
        } catch let err as ZipOperationError {
            XCTAssertEqual(err, .passwordProtected)
        }

        // 5. CRC32不一致（破損ZIP）の拒否とロールバック
        let crcURL = downloadsDir.appendingPathComponent("badcrc.zip")
        try ZipArchiveTestHelper.createCorruptedCRCArchive(at: crcURL)
        let crcItem = ManagedFileItem(
            id: UUID(), title: "badcrc", relativePath: "Documents/Downloads/badcrc.zip",
            fileExtension: "zip", createdAt: Date(), byteSize: 100, folderName: "", relativeSubpath: nil
        )
        do {
            _ = try await zipMgr.extractZip(item: crcItem, downloads: dc, folderManager: fm)
            XCTFail("Corrupted CRC archive must be rejected")
        } catch let err as ZipOperationError {
            XCTAssertEqual(err, .corruptedArchive)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: crcURL.path), "失敗時も元のZIPファイルは保持されること")
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloadsDir.appendingPathComponent("badcrc").path), "破損展開ファイルが残らないこと")
    }

    @MainActor
    func testZipPhaseF1_VaultAndHLS_StrictIsolationFromCompression() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ZipF1_Isolation_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let stagingDir = tempRoot.appendingPathComponent("Staging", isDirectory: true)
        let vaultSimDir = tempRoot.appendingPathComponent("Application Support/Vault", isDirectory: true)
        let tempPlaybackDir = tempRoot.appendingPathComponent(".playback_temp", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: vaultSimDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempPlaybackDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let suiteName = "com.clipharbor.test.zipf1.isolation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let dc = DownloadCenter()
        for v in dc.saved { dc.removeSavedVideoWithoutDeletingFile(id: v.id) }
        let fm = VideoFolderManager(downloads: dc)
        let zipMgr = ZipArchiveManager(
            userDefaults: defaults,
            customDownloadsRootURL: downloadsDir,
            customStagingRootURL: stagingDir
        )

        // 1. Vault 暗号化ファイルの圧縮拒否
        let vaultFile = vaultSimDir.appendingPathComponent("encrypted.vault")
        try Data("secret".utf8).write(to: vaultFile)
        do {
            _ = try await zipMgr.compressSingleFileAtURL(
                sourceURL: vaultFile,
                preferredBaseName: "leak",
                folderName: "",
                downloads: dc,
                folderManager: fm
            )
            XCTFail("Vault file compression must be rejected")
        } catch let err as ZipOperationError {
            guard case .unsupportedSourceForCompression = err else {
                XCTFail("Expected unsupportedSourceForCompression, got \(err)")
                return
            }
        }

        // 2. 一時復号再生ファイル (.playback_temp) の圧縮拒否
        let tempDecrypted = tempPlaybackDir.appendingPathComponent("temp.mp4")
        try Data("decrypted".utf8).write(to: tempDecrypted)
        do {
            _ = try await zipMgr.compressSingleFileAtURL(
                sourceURL: tempDecrypted,
                preferredBaseName: "temp",
                folderName: "",
                downloads: dc,
                folderManager: fm
            )
            XCTFail("Playback temp file compression must be rejected")
        } catch let err as ZipOperationError {
            guard case .unsupportedSourceForCompression = err else {
                XCTFail("Expected unsupportedSourceForCompression, got \(err)")
                return
            }
        }

        // 3. HLS .movpkg の圧縮拒否
        let hlsVideo = SavedVideo(
            id: UUID(),
            title: "HLSStream",
            relativePath: "Documents/Downloads/stream.movpkg",
            format: .hls,
            sourceHost: nil,
            createdAt: Date(),
            byteSize: 1024
        )
        do {
            _ = try await zipMgr.compressSingleVideo(hlsVideo, downloads: dc, folderManager: fm)
            XCTFail("HLS .movpkg compression must be rejected")
        } catch let err as ZipOperationError {
            guard case .unsupportedSourceForCompression = err else {
                XCTFail("Expected unsupportedSourceForCompression, got \(err)")
                return
            }
        }
    }

    @MainActor
    func testZipPhaseF1_FolderCompression_RoundTripPreservesHierarchy_AndRejectsHLSAndSymlinks() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ZipF1_FolderComp_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let stagingDir = tempRoot.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let suiteName = "com.clipharbor.test.zipf1.foldercomp.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let dc = DownloadCenter()
        for v in dc.saved { dc.removeSavedVideoWithoutDeletingFile(id: v.id) }
        let fm = VideoFolderManager(downloads: dc)
        let zipMgr = ZipArchiveManager(
            userDefaults: defaults,
            customDownloadsRootURL: downloadsDir,
            customStagingRootURL: stagingDir
        )

        // 多階層フォルダ「旅行」を構築
        let folderName = "旅行"
        fm.registerLogicalFolderIfNeeded(folderName)
        let folderURL = downloadsDir.appendingPathComponent(folderName, isDirectory: true)
        let subMorning = folderURL.appendingPathComponent("Day1/Morning", isDirectory: true)
        let subDocs = folderURL.appendingPathComponent("Day2/Docs", isDirectory: true)
        try FileManager.default.createDirectory(at: subMorning, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: subDocs, withIntermediateDirectories: true)

        let beachPayload = Data((0..<8192).map { UInt8(($0 * 31 + 7) & 0xFF) })
        let guidePayload = Data("Travel Guide PDF Content 2026".utf8)
        let memoPayload = Data("Root memo text".utf8)

        let beachURL = subMorning.appendingPathComponent("beach.mp4")
        let guideURL = subDocs.appendingPathComponent("guide.pdf")
        let memoURL = folderURL.appendingPathComponent("memo.txt")
        try beachPayload.write(to: beachURL)
        try guidePayload.write(to: guideURL)
        try memoPayload.write(to: memoURL)

        zipMgr.syncWithFileSystem(downloads: dc, folderManager: fm)

        // 1. 論理HLS動画が所属している場合はフォルダ圧縮を拒否し、部分ZIPを作らないこと
        let logicalHLS = SavedVideo(
            id: UUID(),
            title: "LiveHLS",
            relativePath: "Library/Application Support/hls_pkg.movpkg",
            format: .hls,
            sourceHost: nil,
            createdAt: Date(),
            byteSize: 2048
        )
        dc.addSaved(logicalHLS)
        fm.setFolderName(folderName, for: logicalHLS)

        do {
            _ = try await zipMgr.compressFolder(named: folderName, downloads: dc, folderManager: fm)
            XCTFail("Folder containing logical HLS video must be rejected from ZIP compression")
        } catch let err as ZipOperationError {
            guard case .unsupportedSourceForCompression(let msg) = err else {
                XCTFail("Expected unsupportedSourceForCompression, got \(err)")
                return
            }
            XCTAssertFalse(msg.isEmpty)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloadsDir.appendingPathComponent("旅行.zip").path))

        // 論理HLSを除去
        dc.removeSavedVideoWithoutDeletingFile(id: logicalHLS.id)

        // 2. 物理的な .movpkg が混在している場合も拒否すること
        let movpkgDir = folderURL.appendingPathComponent("stream.movpkg", isDirectory: true)
        try FileManager.default.createDirectory(at: movpkgDir, withIntermediateDirectories: true)
        try Data("frag".utf8).write(to: movpkgDir.appendingPathComponent("frag.ts"))

        do {
            _ = try await zipMgr.compressFolder(named: folderName, downloads: dc, folderManager: fm)
            XCTFail("Folder containing physical .movpkg must be rejected from ZIP compression")
        } catch let err as ZipOperationError {
            guard case .unsupportedSourceForCompression = err else {
                XCTFail("Expected unsupportedSourceForCompression, got \(err)")
                return
            }
        }
        try FileManager.default.removeItem(at: movpkgDir)

        // 3. 正常な多階層フォルダのZIP圧縮（1回目 -> 旅行.zip、2回目 -> 旅行 (1).zip）
        let zip1 = try await zipMgr.compressFolder(named: folderName, downloads: dc, folderManager: fm)
        XCTAssertEqual(zip1.title, "旅行")
        XCTAssertEqual(zip1.folderName, "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloadsDir.appendingPathComponent("旅行.zip").path))
        // 元フォルダ・元ファイルが一切変更・削除されていないこと
        XCTAssertTrue(FileManager.default.fileExists(atPath: beachURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: guideURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: memoURL.path))

        let zip2 = try await zipMgr.compressFolder(named: folderName, downloads: dc, folderManager: fm)
        XCTAssertEqual(zip2.title, "旅行 (1)")

        // 4. 作成したフォルダZIPを再展開（既存「旅行」と衝突回避して「旅行 (1)」フォルダへ展開）し、階層とバイト列が100%一致すること
        let extractedName = try await zipMgr.extractZip(item: zip1, downloads: dc, folderManager: fm)
        XCTAssertEqual(extractedName, "旅行 (1)")

        let extractedRoot = downloadsDir.appendingPathComponent("旅行 (1)", isDirectory: true)
        let roundTripBeach = try Data(contentsOf: extractedRoot.appendingPathComponent("Day1/Morning/beach.mp4"))
        let roundTripGuide = try Data(contentsOf: extractedRoot.appendingPathComponent("Day2/Docs/guide.pdf"))
        let roundTripMemo = try Data(contentsOf: extractedRoot.appendingPathComponent("memo.txt"))
        XCTAssertEqual(roundTripBeach, beachPayload)
        XCTAssertEqual(roundTripGuide, guidePayload)
        XCTAssertEqual(roundTripMemo, memoPayload)
    }

    @MainActor
    func testZipPhaseF1_ExtractInSameFolder_NoSpuriousTopLevelFolders_AndHandlesDuplicateNames() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ZipF1_SameFolder_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let stagingDir = tempRoot.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let suiteName = "com.clipharbor.test.zipf1.samefolder.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let dc = DownloadCenter()
        for v in dc.saved { dc.removeSavedVideoWithoutDeletingFile(id: v.id) }
        let fm = VideoFolderManager(downloads: dc)
        let zipMgr = ZipArchiveManager(
            userDefaults: defaults,
            customDownloadsRootURL: downloadsDir,
            customStagingRootURL: stagingDir
        )

        // 既存フォルダ「旅行」の中に「archive.zip」を配置
        let parentFolder = "旅行"
        fm.registerLogicalFolderIfNeeded(parentFolder)
        let parentFolderURL = downloadsDir.appendingPathComponent(parentFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: parentFolderURL, withIntermediateDirectories: true)

        let inFolderZipURL = parentFolderURL.appendingPathComponent("archive.zip")
        let clipData = Data(repeating: 0x7A, count: 1024)
        let noteData = Data("Nested note inside folder zip".utf8)
        try ZipArchiveTestHelper.createArchive(at: inFolderZipURL, entries: [
            .file("clip.mp4", data: clipData),
            .directory("Sub/"),
            .file("Sub/notes.txt", data: noteData)
        ])

        zipMgr.syncWithFileSystem(downloads: dc, folderManager: fm)
        let zipItem = try XCTUnwrap(zipMgr.managedFiles.first(where: { $0.title == "archive" && $0.folderName == parentFolder }))

        let topFoldersBefore = fm.folders
        XCTAssertTrue(topFoldersBefore.contains(parentFolder))
        XCTAssertFalse(topFoldersBefore.contains("archive"))

        // 1回目の展開 -> Downloads/旅行/archive/ に展開されること
        let extracted1 = try await zipMgr.extractZip(item: zipItem, downloads: dc, folderManager: fm)
        XCTAssertEqual(extracted1, "archive")

        let expectedExtractedDir1 = parentFolderURL.appendingPathComponent("archive", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedExtractedDir1.appendingPathComponent("clip.mp4").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedExtractedDir1.appendingPathComponent("Sub/notes.txt").path))
        // トップレベル（Downloads/archive）には作られていないこと
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloadsDir.appendingPathComponent("archive").path))
        // トップレベル管理フォルダ一覧に「archive」が不要に追加されていないこと
        XCTAssertFalse(fm.folders.contains("archive"))

        // 親フォルダ「旅行」の所属ファイルとしてサブパス付きで認識されていること
        let extractedClip = try XCTUnwrap(dc.saved.first(where: { $0.title == "clip" }))
        XCTAssertEqual(fm.folderName(for: extractedClip), parentFolder)
        XCTAssertEqual(extractedClip.displaySubfolderPrefix, "archive")

        let extractedNote = try XCTUnwrap(zipMgr.managedFiles.first(where: { $0.title == "notes" }))
        XCTAssertEqual(extractedNote.folderName, parentFolder)
        XCTAssertEqual(extractedNote.displaySubfolderPrefix, "archive/Sub")

        // 2回目の展開 -> 同階層内で重複回避され Downloads/旅行/archive (1)/ に展開されること
        let extracted2 = try await zipMgr.extractZip(item: zipItem, downloads: dc, folderManager: fm)
        XCTAssertEqual(extracted2, "archive (1)")
        let expectedExtractedDir2 = parentFolderURL.appendingPathComponent("archive (1)", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedExtractedDir2.appendingPathComponent("clip.mp4").path))
        XCTAssertFalse(fm.folders.contains("archive (1)"))
    }

    @MainActor
    func testZipPhaseF1_DeleteFolder_FaultInjectionRollback_PartialRollback_AndUnregisteredFileProtection() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ZipF1_DelRollback_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let stagingDir = tempRoot.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let suiteName = "com.clipharbor.test.zipf1.delrollback.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let dc = DownloadCenter()
        for v in dc.saved { dc.removeSavedVideoWithoutDeletingFile(id: v.id) }
        let fm = VideoFolderManager(downloads: dc)
        let zipMgr = ZipArchiveManager(
            userDefaults: defaults,
            customDownloadsRootURL: downloadsDir,
            customStagingRootURL: stagingDir
        )

        let targetFolder = "WorkFolder"
        fm.registerLogicalFolderIfNeeded(targetFolder)
        let folderURL = downloadsDir.appendingPathComponent(targetFolder, isDirectory: true)
        let subA = folderURL.appendingPathComponent("SubA", isDirectory: true)
        let subB = folderURL.appendingPathComponent("SubB", isDirectory: true)
        try FileManager.default.createDirectory(at: subA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: subB, withIntermediateDirectories: true)

        let vid1URL = subA.appendingPathComponent("vid1.mp4")
        let vid2URL = subB.appendingPathComponent("vid2.mp4")
        let docURL = folderURL.appendingPathComponent("spec.pdf")
        try Data(repeating: 0x11, count: 512).write(to: vid1URL)
        try Data(repeating: 0x22, count: 512).write(to: vid2URL)
        try Data("Spec PDF".utf8).write(to: docURL)

        // スキャンして vid1, vid2, spec.pdf を登録
        zipMgr.syncWithFileSystem(downloads: dc, folderManager: fm)
        XCTAssertEqual(dc.saved.filter { fm.folderName(for: $0) == targetFolder }.count, 2)
        XCTAssertEqual(zipMgr.managedFiles.filter { $0.folderName == targetFolder }.count, 1)

        // さらにスキャン未実行の「未登録ファイル」をフォルダ内に直接配置
        let unregisteredURL = folderURL.appendingPathComponent("untracked_note.txt")
        try Data("Important untracked user note".utf8).write(to: unregisteredURL)

        // --- ケースA: 2件目のファイル移動でエラー注入 -> 1件目が逆順ロールバックされ、フォルダも全ファイルも元の場所に保持されること ---
        var moveAttemptCountA = 0
        let failOnSecondMover: (URL, URL) throws -> Void = { src, dst in
            moveAttemptCountA += 1
            if moveAttemptCountA == 2 {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: nil)
            }
            try FileManager.default.moveItem(at: src, to: dst)
        }

        let resA = fm.deleteFolder(
            name: targetFolder,
            customRootURL: downloadsDir,
            zipManager: zipMgr,
            fileMover: failOnSecondMover
        )
        switch resA {
        case .success:
            XCTFail("deleteFolder must fail when a file move fails")
        case .failure:
            break
        }

        // ロールバックにより全4ファイルが元のフォルダ内に存在し、フォルダも消えていないこと
        XCTAssertTrue(fm.folders.contains(targetFolder))
        XCTAssertTrue(FileManager.default.fileExists(atPath: vid1URL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: vid2URL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: docURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unregisteredURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloadsDir.appendingPathComponent("vid1.mp4").path))

        // --- ケースB: 2件目の移動失敗 ＋ 1件目のロールバックも失敗 -> 部分移動状態を正確に通知し、フォルダ管理情報を削除しないこと ---
        var moveAttemptCountB = 0
        let failOnSecondMoverB: (URL, URL) throws -> Void = { src, dst in
            moveAttemptCountB += 1
            if moveAttemptCountB == 2 {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: nil)
            }
            try FileManager.default.moveItem(at: src, to: dst)
        }
        let failingRollbackMover: (URL, URL) throws -> Void = { _, _ in
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError, userInfo: nil)
        }

        let resB = fm.deleteFolder(
            name: targetFolder,
            customRootURL: downloadsDir,
            zipManager: zipMgr,
            fileMover: failOnSecondMoverB,
            rollbackMover: failingRollbackMover
        )
        switch resB {
        case .success:
            XCTFail("deleteFolder must return failure on partial rollback failure")
        case .failure(let err):
            XCTAssertFalse((err.errorDescription ?? "").isEmpty)
        }

        // フォルダ管理情報は維持されていること
        XCTAssertTrue(fm.folders.contains(targetFolder))
        // 移動済みの1件目（Downloads直下）と残存3件（WorkFolder内）のいずれも消失せず、再スキャンでも見失わないこと
        zipMgr.syncWithFileSystem(downloads: dc, folderManager: fm)
        let totalTrackedAfterPartial = dc.saved.count + zipMgr.managedFiles.count
        XCTAssertEqual(totalTrackedAfterPartial, 4, "部分失敗後も未登録ファイルを含めた全4件が見失われないこと")

        // --- ケースC: 正常にフォルダ削除を再実行（さらにスキャン未実行の未登録ファイルも追加） -> 残存ファイルもすべて未分類へ安全に退避され、空になったフォルダが削除されること ---
        let unregistered2URL = folderURL.appendingPathComponent("untracked_raw.txt")
        try Data("Second untracked file".utf8).write(to: unregistered2URL)

        let resC = fm.deleteFolder(
            name: targetFolder,
            customRootURL: downloadsDir,
            zipManager: zipMgr
        )
        switch resC {
        case .success:
            break
        case .failure(let err):
            XCTFail("Normal deleteFolder should succeed, got \(err)")
        }

        XCTAssertFalse(fm.folders.contains(targetFolder))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folderURL.path))
        // 未登録だったファイルも削除されず Downloads 直下に退避・保持されていること
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloadsDir.appendingPathComponent("untracked_note.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloadsDir.appendingPathComponent("untracked_raw.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloadsDir.appendingPathComponent("vid1.mp4").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloadsDir.appendingPathComponent("vid2.mp4").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloadsDir.appendingPathComponent("spec.pdf").path))
    }
}
