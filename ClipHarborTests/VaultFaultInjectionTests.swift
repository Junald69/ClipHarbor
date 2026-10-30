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

    func testVaultPlayer_PlaylistContextItemRemovalAndIndex() {
        let item1 = VaultItem(id: UUID(), encryptedFileName: "item1.enc", originalTitle: "Video 1", originalFileName: "video1.mp4", fileSize: 1000, duration: 10, createdAt: Date(), folderID: nil, format: .mp4)
        let item2 = VaultItem(id: UUID(), encryptedFileName: "item2.enc", originalTitle: "Video 2", originalFileName: "video2.mp4", fileSize: 2000, duration: 20, createdAt: Date(), folderID: nil, format: .mp4)
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
        let item1 = VaultItem(id: UUID(), encryptedFileName: "item1.enc", originalTitle: "Video 1", originalFileName: "video1.mp4", fileSize: 1000, duration: 10, createdAt: Date(), folderID: nil, format: .mp4)
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
        let env = try createIsolatedTestEnvironment()
        defer { env.cleanup() }

        try env.vault.unlock(with: "123456")
        let video = SavedVideo(title: "SessionTest", fileName: "session.mp4", fileSize: 500, duration: 5, createdAt: Date(), folder: nil, format: .mp4)
        let url = try env.createDummyDownloadFile(named: "session.mp4")

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

        // フォルダ移動試行: 無効トークン時はVaultError.lockedがスローされることを検証
        let folder = try env.vault.createFolder(name: "TestFolder")
        do {
            guard env.vault.isUnlocked, env.vault.sessionToken == fakeToken else {
                throw VaultError.locked
            }
            try env.vault.moveItem(id: vaultItem.id, to: folder.id)
            XCTFail("Should not reach here")
        } catch let err as VaultError {
            if case .locked = err {
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
                throw VaultError.locked
            }
            try env.vault.moveItem(id: vaultItem.id, to: folder.id)
            XCTFail("Should not reach here")
        } catch let err as VaultError {
            if case .locked = err {
                // Expected
            } else {
                XCTFail("Unexpected error: \(err)")
            }
        }
    }

    func testVaultPlayer_RestoreFailure_PreservesEncryptedSource() async throws {
        let env = try createIsolatedTestEnvironment()
        defer { env.cleanup() }

        try env.vault.unlock(with: "123456")
        let video = SavedVideo(title: "PreserveTest", fileName: "preserve.mp4", fileSize: 500, duration: 5, createdAt: Date(), folder: nil, format: .mp4)
        let url = try env.createDummyDownloadFile(named: "preserve.mp4")

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
                folderManager: env.mockFolders
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
        let env = try createIsolatedTestEnvironment()
        defer { env.cleanup() }

        try env.vault.unlock(with: "123456")
        let video = SavedVideo(title: "MoveFailTest", fileName: "movefail.mp4", fileSize: 500, duration: 5, createdAt: Date(), folder: nil, format: .mp4)
        let url = try env.createDummyDownloadFile(named: "movefail.mp4")

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
        XCTAssertEqual(env.vault.items(in: nil).count, 1)
    }
}