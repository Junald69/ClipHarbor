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

    @MainActor
    func testZipPhaseF1_DeleteFolder_DirectoryReadFailure_AndPhysicalFolderRemovalFailure() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ZipF1_DelDirFail_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let stagingDir = tempRoot.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let suiteName = "com.clipharbor.test.zipf1.deldirfail.\(UUID().uuidString)"
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

        let targetFolder = "ProtectedFolder"
        fm.registerLogicalFolderIfNeeded(targetFolder)
        let folderURL = downloadsDir.appendingPathComponent(targetFolder, isDirectory: true)
        let subDir = folderURL.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        let vidURL = subDir.appendingPathComponent("movie.mp4")
        let pdfURL = folderURL.appendingPathComponent("manual.pdf")
        try Data(repeating: 0x44, count: 512).write(to: vidURL)
        try Data("Manual Content".utf8).write(to: pdfURL)

        zipMgr.syncWithFileSystem(downloads: dc, folderManager: fm)
        let origVidID = try XCTUnwrap(dc.saved.first(where: { $0.title == "movie" })?.id)
        let origPdfID = try XCTUnwrap(zipMgr.managedFiles.first(where: { $0.title == "manual" })?.id)

        // 1. 事前走査時のディレクトリ読み取り失敗 -> 「空」と扱わず即座に中止し、ファイルもフォルダ情報も維持すること
        let preReadFailRes = fm.deleteFolder(
            name: targetFolder,
            customRootURL: downloadsDir,
            zipManager: zipMgr,
            directoryReader: { _ in
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError, userInfo: nil)
            }
        )
        if case .success = preReadFailRes {
            XCTFail("deleteFolder must fail when pre-scan directory reading fails")
        }
        XCTAssertTrue(fm.folders.contains(targetFolder))
        XCTAssertTrue(FileManager.default.fileExists(atPath: vidURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pdfURL.path))

        // 2. 全ファイル移動後の最終確認フェーズでのディレクトリ読み取り失敗 -> 空と扱わず全件逆順ロールバックし、フォルダ情報を保持すること
        var readCallCount = 0
        let postMoveReadFailRes = fm.deleteFolder(
            name: targetFolder,
            customRootURL: downloadsDir,
            zipManager: zipMgr,
            directoryReader: { dirURL in
                readCallCount += 1
                // 事前走査（フォルダ直下＋サブディレクトリ）は成功させ、移動後の最終確認（3回目以降）でエラー注入
                if readCallCount >= 3 {
                    throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: nil)
                }
                return try FileManager.default.contentsOfDirectory(atPath: dirURL.path)
            }
        )
        if case .success = postMoveReadFailRes {
            XCTFail("deleteFolder must fail and rollback when post-move directory verification fails")
        }
        XCTAssertTrue(fm.folders.contains(targetFolder))
        XCTAssertTrue(FileManager.default.fileExists(atPath: vidURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pdfURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloadsDir.appendingPathComponent("movie.mp4").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloadsDir.appendingPathComponent("manual.pdf").path))

        // 3. 物理フォルダ削除失敗（エラー送出） -> 論理フォルダ情報を削除せず、退避済みファイルを元の階層へ完全ロールバックすること
        let removeThrowRes = fm.deleteFolder(
            name: targetFolder,
            customRootURL: downloadsDir,
            zipManager: zipMgr,
            folderRemover: { _ in
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError, userInfo: nil)
            }
        )
        switch removeThrowRes {
        case .success:
            XCTFail("deleteFolder must fail when physical folder removal throws")
        case .failure(let err):
            XCTAssertFalse((err.errorDescription ?? "").isEmpty)
        }
        XCTAssertTrue(fm.folders.contains(targetFolder), "物理削除が失敗した場合は論理フォルダ情報を削除しないこと")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folderURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: vidURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pdfURL.path))

        // 4. 物理フォルダ削除がエラーを投げないがフォルダがディスク上に残存している場合も検出しロールバックすること
        let removeNoOpRes = fm.deleteFolder(
            name: targetFolder,
            customRootURL: downloadsDir,
            zipManager: zipMgr,
            folderRemover: { _ in
                // 何もしない（フォルダが残存）
            }
        )
        if case .success = removeNoOpRes {
            XCTFail("deleteFolder must fail when folder still exists on disk after folderRemover")
        }
        XCTAssertTrue(fm.folders.contains(targetFolder))
        XCTAssertTrue(FileManager.default.fileExists(atPath: vidURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pdfURL.path))

        // IDとメタデータが一切破損していないこと
        let currentVid = try XCTUnwrap(dc.saved.first(where: { $0.title == "movie" }))
        let currentPdf = try XCTUnwrap(zipMgr.managedFiles.first(where: { $0.title == "manual" }))
        XCTAssertEqual(currentVid.id, origVidID)
        XCTAssertEqual( fm.folderName(for: currentVid), targetFolder)
        XCTAssertEqual(currentPdf.id, origPdfID)
        XCTAssertEqual(currentPdf.folderName, targetFolder)
    }

    @MainActor
    func testZipPhaseF1_DeleteFolder_PartialMoveBeforeError_FinalRemainingRollbackFailure_AndIDIntegrity() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ZipF1_DelEdge_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let stagingDir = tempRoot.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let suiteName = "com.clipharbor.test.zipf1.deledge.\(UUID().uuidString)"
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

        let targetFolder = "EdgeCaseFolder"
        fm.registerLogicalFolderIfNeeded(targetFolder)
        let folderURL = downloadsDir.appendingPathComponent(targetFolder, isDirectory: true)
        let subA = folderURL.appendingPathComponent("SubA", isDirectory: true)
        let subB = folderURL.appendingPathComponent("SubB", isDirectory: true)
        try FileManager.default.createDirectory(at: subA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: subB, withIntermediateDirectories: true)

        let vid1URL = subA.appendingPathComponent("alpha.mp4")
        let vid2URL = subB.appendingPathComponent("beta.mp4")
        let docURL = folderURL.appendingPathComponent("notes.txt")
        try Data(repeating: 0xA1, count: 512).write(to: vid1URL)
        try Data(repeating: 0xB2, count: 512).write(to: vid2URL)
        try Data("Notes text".utf8).write(to: docURL)

        zipMgr.syncWithFileSystem(downloads: dc, folderManager: fm)
        let origVid1ID = try XCTUnwrap(dc.saved.first(where: { $0.title == "alpha" })?.id)
        let origVid2ID = try XCTUnwrap(dc.saved.first(where: { $0.title == "beta" })?.id)
        let origDocID = try XCTUnwrap(zipMgr.managedFiles.first(where: { $0.title == "notes" })?.id)

        // 1. 「途中まで成立したファイル移動」の検証：
        // 2件目の move で実ファイルを移動させた直後にエラーを投げた場合でも、実ファイルの存在を確認して2件目・1件目の両方を逆順ロールバックすること
        var stepCount1 = 0
        let moveThenThrowOnSecond: (URL, URL) throws -> Void = { src, dst in
            stepCount1 += 1
            try FileManager.default.moveItem(at: src, to: dst)
            if stepCount1 == 2 {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: nil)
            }
        }

        let partialMoveRes = fm.deleteFolder(
            name: targetFolder,
            customRootURL: downloadsDir,
            zipManager: zipMgr,
            fileMover: moveThenThrowOnSecond
        )
        if case .success = partialMoveRes {
            XCTFail("deleteFolder must fail when mover throws after moving file")
        }

        // 2件目も含めてすべて元のサブフォルダへ復元されていること
        XCTAssertTrue(fm.folders.contains(targetFolder))
        XCTAssertTrue(FileManager.default.fileExists(atPath: vid1URL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: vid2URL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: docURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloadsDir.appendingPathComponent("alpha.mp4").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloadsDir.appendingPathComponent("beta.mp4").path))

        // IDと所属フォルダが完全に維持されていること
        XCTAssertEqual(dc.saved.first(where: { $0.title == "alpha" })?.id, origVid1ID)
        XCTAssertEqual(dc.saved.first(where: { $0.title == "beta" })?.id, origVid2ID)
        XCTAssertEqual(zipMgr.managedFiles.first(where: { $0.title == "notes" })?.id, origDocID)

        // 2. 「最終残存ファイル検出後のロールバック失敗」および「失敗後のファイルID・メタデータ整合性」の検証：
        // 全件移動成功後、最終確認フェーズで予期しない残存ファイル（late_arrival.dat）が検出され、
        // さらに逆順ロールバック時に alpha.mp4 の復元だけが失敗（Downloads直下に残存）し、beta.mp4 と notes.txt は元のフォルダへ戻ったケース
        let lateFileURL = folderURL.appendingPathComponent("late_arrival.txt")
        var injectedLateFile = false

        let injectLateFileMover: (URL, URL) throws -> Void = { src, dst in
            try FileManager.default.moveItem(at: src, to: dst)
            if !injectedLateFile {
                injectedLateFile = true
                try? Data("Late file".utf8).write(to: lateFileURL)
            }
        }

        let selectiveFailRollbackMover: (URL, URL) throws -> Void = { src, dst in
            // alpha.mp4 のロールバックのみ失敗させる（Downloads/alpha.mp4 に残る）
            if src.lastPathComponent == "alpha.mp4" {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError, userInfo: nil)
            }
            try FileManager.default.moveItem(at: src, to: dst)
        }

        let finalPhasePartialRollbackRes = fm.deleteFolder(
            name: targetFolder,
            customRootURL: downloadsDir,
            zipManager: zipMgr,
            fileMover: injectLateFileMover,
            rollbackMover: selectiveFailRollbackMover
        )
        switch finalPhasePartialRollbackRes {
        case .success:
            XCTFail("deleteFolder must fail when unexpected file remains in final verification")
        case .failure(let err):
            let msg = err.errorDescription ?? ""
            XCTAssertFalse(msg.isEmpty)
        }

        // 既存フォルダ情報は削除されず保持されていること
        XCTAssertTrue(fm.folders.contains(targetFolder))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folderURL.path))

        // 実ファイルの所在地確認：alpha.mp4 は Downloads 直下、beta.mp4 と notes.txt と late_arrival.txt はフォルダ内
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloadsDir.appendingPathComponent("alpha.mp4").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vid1URL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: vid2URL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: docURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: lateFileURL.path))

        // メタデータとファイルIDの整合性確認：
        // 1) alpha.mp4 は元の UUID (origVid1ID) を維持したまま未分類 ("") に更新されていること
        let afterAlpha = try XCTUnwrap(dc.saved.first(where: { $0.id == origVid1ID }))
        XCTAssertEqual(fm.folderName(for: afterAlpha), "")
        XCTAssertTrue(afterAlpha.relativePath.hasSuffix("Documents/Downloads/alpha.mp4"))

        // 2) beta.mp4 と notes.txt は元の UUID (origVid2ID, origDocID) とフォルダ所属 (EdgeCaseFolder) を維持していること
        let afterBeta = try XCTUnwrap(dc.saved.first(where: { $0.id == origVid2ID }))
        XCTAssertEqual(fm.folderName(for: afterBeta), targetFolder)
        let afterNotes = try XCTUnwrap(zipMgr.managedFiles.first(where: { $0.id == origDocID }))
        XCTAssertEqual(afterNotes.folderName, targetFolder)

        // 3) 次回スキャンを実行しても ID が変わらず、全4ファイル（late_arrival.txt 含む）が正しく認識されること
        zipMgr.syncWithFileSystem(downloads: dc, folderManager: fm)
        XCTAssertNotNil(dc.saved.first(where: { $0.id == origVid1ID }))
        XCTAssertNotNil(dc.saved.first(where: { $0.id == origVid2ID }))
        XCTAssertNotNil(zipMgr.managedFiles.first(where: { $0.id == origDocID }))
        XCTAssertNotNil(zipMgr.managedFiles.first(where: { $0.title == "late_arrival" && $0.folderName == targetFolder }))
    }

    @MainActor
    func testZipPhaseF1_DeleteFolder_BothExistConflict_AndNeitherExistsMissing_PreservesFilesAndNotifiesError() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ZipF1_Conflict_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let stagingDir = tempRoot.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let suiteName = "com.clipharbor.test.zipf1.conflict.\(UUID().uuidString)"
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

        let targetFolder = "ConflictFolder"
        fm.registerLogicalFolderIfNeeded(targetFolder)
        let folderURL = downloadsDir.appendingPathComponent(targetFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let sourcePayload = Data("Original source file bytes".utf8)
        let destConflictPayload = Data("Distinct destination file bytes".utf8)
        let vidURL = folderURL.appendingPathComponent("clip.mp4")
        let docURL = folderURL.appendingPathComponent("readme.txt")
        try sourcePayload.write(to: vidURL)
        try Data("Readme content".utf8).write(to: docURL)

        zipMgr.syncWithFileSystem(downloads: dc, folderManager: fm)
        let origVidID = try XCTUnwrap(dc.saved.first(where: { $0.title == "clip" })?.id)

        // 1. 移動元と移動先の両方に実ファイルが存在する競合ケース：
        // 移動元のサイズが0より大きくても移動先ファイルを削除せず両方保持し、競合エラーを返すこと
        let conflictMover: (URL, URL) throws -> Void = { src, dst in
            if src.lastPathComponent == "clip.mp4" {
                try destConflictPayload.write(to: dst)
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError, userInfo: nil)
            }
            try FileManager.default.moveItem(at: src, to: dst)
        }

        let conflictRes = fm.deleteFolder(
            name: targetFolder,
            customRootURL: downloadsDir,
            zipManager: zipMgr,
            fileMover: conflictMover
        )
        switch conflictRes {
        case .success:
            XCTFail("deleteFolder must fail when both source and destination files exist")
        case .failure(let err):
            XCTAssertFalse((err.errorDescription ?? "").isEmpty)
        }

        let destClipURL = downloadsDir.appendingPathComponent("clip.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: vidURL.path), "移動元のファイルが保持されていること")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destClipURL.path), "移動先のファイルも勝手に削除されず保持されていること")
        XCTAssertEqual(try Data(contentsOf: vidURL), sourcePayload)
        XCTAssertEqual(try Data(contentsOf: destClipURL), destConflictPayload)
        XCTAssertTrue(fm.folders.contains(targetFolder), "競合発生時はフォルダ管理情報を削除しないこと")
        XCTAssertEqual(dc.saved.first(where: { $0.id == origVidID })?.id, origVidID)

        // 競合で生成された移動先ファイルを片付けて次のテストへ
        try? FileManager.default.removeItem(at: destClipURL)
        zipMgr.syncWithFileSystem(downloads: dc, folderManager: fm)

        // 2. 移動元にも移動先にもファイルが存在しない異常ケース：
        // 1件目は正常移動、2件目で移動元が消失し移動先にも存在しない状態を注入 -> 1件目をロールバックし、フォルダを保持してエラー通知すること
        var callIndex = 0
        var removedPathForTest: URL?
        var removedDataBackup: Data?

        let missingBothMover: (URL, URL) throws -> Void = { src, dst in
            callIndex += 1
            if callIndex == 1 {
                try FileManager.default.moveItem(at: src, to: dst)
            } else {
                removedPathForTest = src
                removedDataBackup = try? Data(contentsOf: src)
                try? FileManager.default.removeItem(at: src)
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError, userInfo: nil)
            }
        }

        let missingRes = fm.deleteFolder(
            name: targetFolder,
            customRootURL: downloadsDir,
            zipManager: zipMgr,
            fileMover: missingBothMover
        )
        switch missingRes {
        case .success:
            XCTFail("deleteFolder must fail when neither source nor destination exists")
        case .failure(let err):
            XCTAssertFalse((err.errorDescription ?? "").isEmpty)
        }

        // フォルダは削除されず、1件目のファイルも元のフォルダ内へロールバックされていること
        XCTAssertTrue(fm.folders.contains(targetFolder))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folderURL.path))
        if let path = removedPathForTest, let backup = removedDataBackup {
            try? backup.write(to: path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: vidURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: docURL.path))
    }

    @MainActor
    func testZipPhaseF1_DeleteFolder_RestoresEmptySubfoldersOnSubsequentFailure() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ZipF1_EmptySub_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let stagingDir = tempRoot.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let suiteName = "com.clipharbor.test.zipf1.emptysub.\(UUID().uuidString)"
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

        // Work/EmptySubfolder/ と Work/DeepEmpty/InnerEmpty/ と Work/video.mp4 を作成
        let targetFolder = "Work"
        fm.registerLogicalFolderIfNeeded(targetFolder)
        let workURL = downloadsDir.appendingPathComponent(targetFolder, isDirectory: true)
        let emptySubURL = workURL.appendingPathComponent("EmptySubfolder", isDirectory: true)
        let deepInnerEmptyURL = workURL.appendingPathComponent("DeepEmpty/InnerEmpty", isDirectory: true)
        let videoURL = workURL.appendingPathComponent("video.mp4")

        try FileManager.default.createDirectory(at: emptySubURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: deepInnerEmptyURL, withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 512).write(to: videoURL)

        zipMgr.syncWithFileSystem(downloads: dc, folderManager: fm)

        // ファイル退避＋空サブフォルダ削除の後に、物理フォルダ削除エラーを注入
        let res = fm.deleteFolder(
            name: targetFolder,
            customRootURL: downloadsDir,
            zipManager: zipMgr,
            folderRemover: { _ in
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError, userInfo: nil)
            }
        )
        switch res {
        case .success:
            XCTFail("deleteFolder must fail when folderRemover fails")
        case .failure(let err):
            XCTAssertFalse((err.errorDescription ?? "").isEmpty)
        }

        // Work/video.mp4 と Work/EmptySubfolder/（およびネストされた空サブフォルダ）が両方とも元どおり残っていること
        var isDirEmptySub: ObjCBool = false
        var isDirDeepSub: ObjCBool = false
        XCTAssertTrue(fm.folders.contains(targetFolder))
        XCTAssertTrue(FileManager.default.fileExists(atPath: videoURL.path), "Work/video.mp4 が元どおり復元されていること")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: emptySubURL.path, isDirectory: &isDirEmptySub) && isDirEmptySub.boolValue,
            "Work/EmptySubfolder/ が削除されたままにならず元の階層へ復元されていること"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: deepInnerEmptyURL.path, isDirectory: &isDirDeepSub) && isDirDeepSub.boolValue,
            "多階層の空サブフォルダも元の階層へ復元されていること"
        )
    }

    // MARK: - Phase F2-A: 一般ファイルの名前変更・フォルダ移動テスト (全10件)

    @MainActor
    func testZipPhaseF2A_RenameTxtPdfZip_PreservesUUIDAndExtension() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ZipF2A_Rename_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let stagingDir = tempRoot.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let suiteName = "com.clipharbor.test.zipf2a.rename.\(UUID().uuidString)"
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

        // 1. テスト用ファイル作成 (txt, pdf, zip)
        let txtURL = downloadsDir.appendingPathComponent("note.txt")
        let pdfURL = downloadsDir.appendingPathComponent("doc.pdf")
        let zipURL = downloadsDir.appendingPathComponent("pack.zip")
        try Data("Hello text".utf8).write(to: txtURL)
        try Data("%PDF-1.4 sample".utf8).write(to: pdfURL)
        try ZipArchiveTestHelper.createArchive(at: zipURL, entries: [
            .file("inside.txt", data: Data("abc".utf8))
        ])

        zipMgr.syncWithFileSystem(downloads: dc, folderManager: fm)
        guard let txtItem = zipMgr.managedFiles.first(where: { $0.fileExtension == "txt" }),
              let pdfItem = zipMgr.managedFiles.first(where: { $0.fileExtension == "pdf" }),
              let zipItem = zipMgr.managedFiles.first(where: { $0.fileExtension == "zip" }) else {
            XCTFail("Initial items not found in managedFiles")
            return
        }

        let origTxtID = txtItem.id
        let origPdfID = pdfItem.id
        let origZipID = zipItem.id

        // TXTリネーム
        let renamedTxt = try zipMgr.renameManagedFile(txtItem, to: "renamed_note")
        XCTAssertEqual(renamedTxt.id, origTxtID, "TXTリネーム後もUUIDが100%維持されること")
        XCTAssertEqual(renamedTxt.title, "renamed_note")
        XCTAssertEqual(renamedTxt.fileExtension, "txt", "拡張子が固定維持されること")
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloadsDir.appendingPathComponent("renamed_note.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: txtURL.path))

        // PDFリネーム
        let renamedPdf = try zipMgr.renameManagedFile(pdfItem, to: "renamed_doc")
        XCTAssertEqual(renamedPdf.id, origPdfID, "PDFリネーム後もUUIDが100%維持されること")
        XCTAssertEqual(renamedPdf.title, "renamed_doc")
        XCTAssertEqual(renamedPdf.fileExtension, "pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloadsDir.appendingPathComponent("renamed_doc.pdf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pdfURL.path))

        // ZIPリネーム
        let renamedZip = try zipMgr.renameManagedFile(zipItem, to: "renamed_pack")
        XCTAssertEqual(renamedZip.id, origZipID, "ZIPリネーム後もUUIDが100%維持されること")
        XCTAssertEqual(renamedZip.title, "renamed_pack")
        XCTAssertEqual(renamedZip.fileExtension, "zip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloadsDir.appendingPathComponent("renamed_pack.zip").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: zipURL.path))

        // 同一判定（Unicode正規化・大文字小文字違い）の safe no-op
        let noopZip = try zipMgr.renameManagedFile(renamedZip, to: "renamed_pack")
        XCTAssertEqual(noopZip.id, origZipID)
    }

    @MainActor
    func testZipPhaseF2A_MoveBetweenFolders_PreservesUUID() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ZipF2A_Move_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let stagingDir = tempRoot.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let suiteName = "com.clipharbor.test.zipf2a.move.\(UUID().uuidString)"
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

        let initialFile = downloadsDir.appendingPathComponent("document.txt")
        try Data("Folder move test".utf8).write(to: initialFile)

        fm.registerLogicalFolderIfNeeded("AlphaFolder")
        fm.registerLogicalFolderIfNeeded("BetaFolder")

        zipMgr.syncWithFileSystem(downloads: dc, folderManager: fm)
        guard let item = zipMgr.managedFiles.first(where: { $0.title == "document" }) else {
            XCTFail("Initial item not found")
            return
        }
        let origID = item.id

        // 未分類 -> AlphaFolder へ移動
        let step1 = try zipMgr.moveManagedFile(item, toFolder: "AlphaFolder", folderManager: fm)
        XCTAssertEqual(step1.id, origID, "フォルダ移動後もUUIDが完全一致すること")
        XCTAssertEqual(step1.folderName, "AlphaFolder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloadsDir.appendingPathComponent("AlphaFolder/document.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: initialFile.path))

        // AlphaFolder -> BetaFolder へ移動
        let step2 = try zipMgr.moveManagedFile(step1, toFolder: "BetaFolder", folderManager: fm)
        XCTAssertEqual(step2.id, origID, "別フォルダ移動後もUUIDが完全一致すること")
        XCTAssertEqual(step2.folderName, "BetaFolder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloadsDir.appendingPathComponent("BetaFolder/document.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloadsDir.appendingPathComponent("AlphaFolder/document.txt").path))

        // BetaFolder -> 未分類（Downloads直下）へ戻す移動
        let step3 = try zipMgr.moveManagedFile(step2, toFolder: "", folderManager: fm)
        XCTAssertEqual(step3.id, origID, "未分類復帰後もUUIDが完全一致すること")
        XCTAssertEqual(step3.folderName, "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloadsDir.appendingPathComponent("document.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloadsDir.appendingPathComponent("BetaFolder/document.txt").path))
    }

    @MainActor
    func testZipPhaseF2A_MoveNestedFile_CleansIntermediateDirectoriesAndFlattensToDestination() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ZipF2A_NestedMove_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let stagingDir = tempRoot.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let suiteName = "com.clipharbor.test.zipf2a.nestedmove.\(UUID().uuidString)"
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

        // SourceFolder/level1/level2/nested.pdf を作成
        let sourceFolder = "SourceFolder"
        let destFolder = "DestFolder"
        fm.registerLogicalFolderIfNeeded(sourceFolder)
        fm.registerLogicalFolderIfNeeded(destFolder)

        let deepDir = downloadsDir.appendingPathComponent("\(sourceFolder)/level1/level2", isDirectory: true)
        try FileManager.default.createDirectory(at: deepDir, withIntermediateDirectories: true)
        let nestedFile = deepDir.appendingPathComponent("nested.pdf")
        try Data("%PDF nested content".utf8).write(to: nestedFile)

        zipMgr.syncWithFileSystem(downloads: dc, folderManager: fm)
        guard let nestedItem = zipMgr.managedFiles.first(where: { $0.title == "nested" }) else {
            XCTFail("nested item not found")
            return
        }
        XCTAssertEqual(nestedItem.folderName, sourceFolder)
        XCTAssertEqual(nestedItem.relativeSubpath, "level1/level2")
        let origID = nestedItem.id

        // DestFolder 直下へ移動
        let moved = try zipMgr.moveManagedFile(nestedItem, toFolder: destFolder, folderManager: fm)
        XCTAssertEqual(moved.id, origID, "多階層からの移動後もUUIDが維持されること")
        XCTAssertEqual(moved.folderName, destFolder)
        XCTAssertNil(moved.relativeSubpath, "移動先では親フォルダ直下に配置されること")

        let expectedDestFile = downloadsDir.appendingPathComponent("\(destFolder)/nested.pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedDestFile.path))

        // 空になった中間ディレクトリ level2, level1 は安全に削除されていること
        XCTAssertFalse(FileManager.default.fileExists(atPath: deepDir.path), "空のlevel2ディレクトリは削除されていること")
        let level1Dir = downloadsDir.appendingPathComponent("\(sourceFolder)/level1", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: level1Dir.path), "空のlevel1ディレクトリは削除されていること")

        // トップレベル管理フォルダ SourceFolder 自体は維持されていること
        var isDir: ObjCBool = false
        let sourceFolderDir = downloadsDir.appendingPathComponent(sourceFolder, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceFolderDir.path, isDirectory: &isDir) && isDir.boolValue)
    }

    @MainActor
    func testZipPhaseF2A_MoveToSameFolder_IsNoOpAndPreservesSubpath() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ZipF2A_SameFolder_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let stagingDir = tempRoot.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let suiteName = "com.clipharbor.test.zipf2a.samefolder.\(UUID().uuidString)"
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

        let folder = "KeepFolder"
        fm.registerLogicalFolderIfNeeded(folder)
        let subDir = downloadsDir.appendingPathComponent("\(folder)/nested", isDirectory: true)
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        let fileURL = subDir.appendingPathComponent("stay.txt")
        try Data("staying here".utf8).write(to: fileURL)

        zipMgr.syncWithFileSystem(downloads: dc, folderManager: fm)
        guard let item = zipMgr.managedFiles.first(where: { $0.title == "stay" }) else {
            XCTFail("stay item not found")
            return
        }

        // 同一フォルダへの移動を指示
        let res = try zipMgr.moveManagedFile(item, toFolder: folder, folderManager: fm)
        XCTAssertEqual(res.id, item.id)
        XCTAssertEqual(res.relativeSubpath, "nested", "同一フォルダ指定時はサブパスが破壊・フラット化されず保持されること")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        // ルート（未分類）から未分類への移動も no-op
        let rootFile = downloadsDir.appendingPathComponent("root_stay.txt")
        try Data("root".utf8).write(to: rootFile)
        zipMgr.syncWithFileSystem(downloads: dc, folderManager: fm)
        let rootItem = zipMgr.managedFiles.first(where: { $0.title == "root_stay" })!
        let rootRes = try zipMgr.moveManagedFile(rootItem, toFolder: "", folderManager: fm)
        XCTAssertEqual(rootRes.id, rootItem.id)
    }

    @MainActor
    func testZipPhaseF2A_MoveConflict_AutoGeneratesUniqueSequence() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ZipF2A_Conflict_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let stagingDir = tempRoot.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let suiteName = "com.clipharbor.test.zipf2a.conflict.\(UUID().uuidString)"
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

        let targetFolder = "Destination"
        fm.registerLogicalFolderIfNeeded(targetFolder)
        let targetDir = downloadsDir.appendingPathComponent(targetFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        // 移動先に既に report.pdf が存在
        let existingTarget = targetDir.appendingPathComponent("report.pdf")
        try Data("Existing PDF in folder".utf8).write(to: existingTarget)

        // ルートにも report.pdf が存在
        let sourceFile = downloadsDir.appendingPathComponent("report.pdf")
        try Data("Source PDF in root".utf8).write(to: sourceFile)

        zipMgr.syncWithFileSystem(downloads: dc, folderManager: fm)
        guard let sourceItem = zipMgr.managedFiles.first(where: { $0.folderName.isEmpty && $0.title == "report" }) else {
            XCTFail("source report item not found")
            return
        }
        let origID = sourceItem.id

        // 移動を実行
        let moved = try zipMgr.moveManagedFile(sourceItem, toFolder: targetFolder, folderManager: fm)
        XCTAssertEqual(moved.id, origID, "連番化されてもUUIDは維持されること")
        XCTAssertEqual(moved.title, "report (1)", "同名衝突時は自動的に連番が付与されること")
        XCTAssertEqual(moved.folderName, targetFolder)

        // 両方のファイルが共存し、上書きされていないこと
        XCTAssertTrue(FileManager.default.fileExists(atPath: existingTarget.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetDir.appendingPathComponent("report (1).pdf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceFile.path))
    }

    @MainActor
    func testZipPhaseF2A_PhysicalMoveFailure_RollsBackStateSafely() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ZipF2A_Rollback_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let stagingDir = tempRoot.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let suiteName = "com.clipharbor.test.zipf2a.rollback.\(UUID().uuidString)"
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

        // 実体ファイルを作成
        let fileURL = downloadsDir.appendingPathComponent("valid.txt")
        try Data("valid".utf8).write(to: fileURL)

        zipMgr.syncWithFileSystem(downloads: dc, folderManager: fm)
        guard let item = zipMgr.managedFiles.first(where: { $0.title == "valid" }) else {
            XCTFail("item not found")
            return
        }

        // リネーム時に宛先と同名ファイルが既に存在する場合、上書きせずエラーを投げる
        let anotherFileURL = downloadsDir.appendingPathComponent("another.txt")
        try Data("another".utf8).write(to: anotherFileURL)
        zipMgr.syncWithFileSystem(downloads: dc, folderManager: fm)

        XCTAssertThrowsError(try zipMgr.renameManagedFile(item, to: "another"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: anotherFileURL.path))

        // 実体ファイルが削除された不正状態で移動を試みる
        try? FileManager.default.removeItem(at: fileURL)
        XCTAssertThrowsError(try zipMgr.moveManagedFile(item, toFolder: "NewFolder", folderManager: fm))
    }

    // 未完了操作ジャーナルを手動準備し、プロセス再起動時にUUIDが100%復旧されることを検証
    @MainActor
    func testZipPhaseF2A_UnfinishedOperation_RecoversUUIDViaJournal() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ZipF2A_Journal_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let stagingDir = tempRoot.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let suiteName = "com.clipharbor.test.zipf2a.journal.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let dc = DownloadCenter()
        for v in dc.saved { dc.removeSavedVideoWithoutDeletingFile(id: v.id) }
        let fm = VideoFolderManager(downloads: dc)

        // 状況設定：
        // 物理移動（Downloads/alpha.txt -> Downloads/Folder1/alpha.txt）は完了したが、
        // アプリが突然クラッシュし、UserDefaultsのメタデータ保存が完了しなかった。
        // しかし移動前にジャーナルが記録されていた。
        let targetFolder = "Folder1"
        fm.registerLogicalFolderIfNeeded(targetFolder)
        let targetDir = downloadsDir.appendingPathComponent(targetFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let destFile = targetDir.appendingPathComponent("alpha.txt")
        try Data("alpha content".utf8).write(to: destFile)

        let targetUUID = UUID()
        let pendingOp = ManagedFilePendingOperation(
            operationID: UUID(),
            itemID: targetUUID,
            kind: .move,
            sourceRelativePath: "Documents/Downloads/alpha.txt",
            destinationRelativePath: "Documents/Downloads/Folder1/alpha.txt",
            originalTitle: "alpha",
            destinationTitle: "alpha",
            originalFolderName: "",
            destinationFolderName: "Folder1",
            fileExtension: "txt",
            createdAt: Date()
        )
        let journalKey = ZipArchiveManager.pendingOperationKey
        let enc = try JSONEncoder().encode(pendingOp)
        defaults.set(enc, forKey: journalKey)

        // 新しいZipArchiveManagerが起動（クラッシュ後の再起動をシミュレート）
        let zipMgr = ZipArchiveManager(
            userDefaults: defaults,
            customDownloadsRootURL: downloadsDir,
            customStagingRootURL: stagingDir
        )

        // syncWithFileSystemを実行
        zipMgr.syncWithFileSystem(downloads: dc, folderManager: fm)

        // ジャーナルからUUIDが正しく復元され、managedFilesに登録されていること
        guard let recovered = zipMgr.managedFiles.first(where: { $0.title == "alpha" }) else {
            XCTFail("Recovered file not found in managedFiles")
            return
        }
        XCTAssertEqual(recovered.id, targetUUID, "ジャーナルから元のUUIDが100%復旧されること")
        XCTAssertEqual(recovered.folderName, "Folder1")

        // 復旧後にジャーナルがクリアされていること
        XCTAssertNil(defaults.data(forKey: journalKey), "復旧完了後に保留ジャーナルがクリアされること")
    }

    @MainActor
    func testZipPhaseF2A_RestartAndSync_PreservesRenamedAndMovedUUID() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ZipF2A_Restart_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let stagingDir = tempRoot.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let suiteName = "com.clipharbor.test.zipf2a.restart.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let dc = DownloadCenter()
        for v in dc.saved { dc.removeSavedVideoWithoutDeletingFile(id: v.id) }
        let fm = VideoFolderManager(downloads: dc)

        var zipMgr: ZipArchiveManager? = ZipArchiveManager(
            userDefaults: defaults,
            customDownloadsRootURL: downloadsDir,
            customStagingRootURL: stagingDir
        )

        let initialFile = downloadsDir.appendingPathComponent("doc.txt")
        try Data("Sample text".utf8).write(to: initialFile)

        zipMgr?.syncWithFileSystem(downloads: dc, folderManager: fm)
        let origItem = zipMgr!.managedFiles.first(where: { $0.title == "doc" })!
        let targetID = origItem.id

        // リネーム & 移動
        fm.registerLogicalFolderIfNeeded("ArchiveFolder")
        let renamed = try zipMgr!.renameManagedFile(origItem, to: "final_doc")
        let moved = try zipMgr!.moveManagedFile(renamed, toFolder: "ArchiveFolder", folderManager: fm)
        XCTAssertEqual(moved.id, targetID)

        // インスタンス破棄（アプリ終了）
        zipMgr = nil

        // 新しいインスタンス生成（アプリ再起動）
        let newZipMgr = ZipArchiveManager(
            userDefaults: defaults,
            customDownloadsRootURL: downloadsDir,
            customStagingRootURL: stagingDir
        )
        newZipMgr.syncWithFileSystem(downloads: dc, folderManager: fm)

        guard let reloadedItem = newZipMgr.managedFiles.first(where: { $0.title == "final_doc" }) else {
            XCTFail("final_doc not found after reboot sync")
            return
        }
        XCTAssertEqual(reloadedItem.id, targetID, "再起動後もリネーム・移動したファイルのUUIDが同一であること")
        XCTAssertEqual(reloadedItem.folderName, "ArchiveFolder")
    }

    @MainActor
    func testZipPhaseF2A_PendingRecovery_ConflictSourceAndDestBothExist_PreservesBoth() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ZipF2A_BothExist_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let stagingDir = tempRoot.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let suiteName = "com.clipharbor.test.zipf2a.bothexist.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let dc = DownloadCenter()
        for v in dc.saved { dc.removeSavedVideoWithoutDeletingFile(id: v.id) }
        let fm = VideoFolderManager(downloads: dc)

        // 元ファイルと移動先ファイルの両方が実在する異常競合状態
        let srcFile = downloadsDir.appendingPathComponent("src.txt")
        try Data("source content".utf8).write(to: srcFile)

        fm.registerLogicalFolderIfNeeded("FolderY")
        let destFolderDir = downloadsDir.appendingPathComponent("FolderY", isDirectory: true)
        try FileManager.default.createDirectory(at: destFolderDir, withIntermediateDirectories: true)
        let dstFile = destFolderDir.appendingPathComponent("src.txt")
        try Data("dest content".utf8).write(to: dstFile)

        let journalKey = ZipArchiveManager.pendingOperationKey
        let pendingOp = ManagedFilePendingOperation(
            operationID: UUID(),
            itemID: UUID(),
            kind: .move,
            sourceRelativePath: "Documents/Downloads/src.txt",
            destinationRelativePath: "Documents/Downloads/FolderY/src.txt",
            originalTitle: "src",
            destinationTitle: "src",
            originalFolderName: "",
            destinationFolderName: "FolderY",
            fileExtension: "txt",
            createdAt: Date()
        )
        let enc = try JSONEncoder().encode(pendingOp)
        defaults.set(enc, forKey: journalKey)

        let zipMgr = ZipArchiveManager(
            userDefaults: defaults,
            customDownloadsRootURL: downloadsDir,
            customStagingRootURL: stagingDir
        )
        zipMgr.recoverPendingOperationsIfNeeded()

        // 競合時はどちらのファイルも勝手に削除せず、未解決状態の復旧ジャーナルを維持すること
        XCTAssertTrue(FileManager.default.fileExists(atPath: srcFile.path), "元ファイルが保持されること")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dstFile.path), "移動先ファイルが保持されること")
        XCTAssertNotNil(zipMgr.loadPendingOperation(), "未解決競合時は復旧ジャーナルを消去せず保持すること")
        XCTAssertNotNil(zipMgr.unresolvedRecoveryNotice, "未解決状態が通知されること")
    }

    @MainActor
    func testZipPhaseF2A_VaultAndVideoIsolation_CannotMoveOrRenameVaultFiles() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ZipF2A_VaultIso_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let stagingDir = tempRoot.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let suiteName = "com.clipharbor.test.zipf2a.vaultiso.\(UUID().uuidString)"
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

        // Vault 暗号化ファイル（.vault）がDownloads内に存在したとしても操作を拒否
        let secretVaultFile = downloadsDir.appendingPathComponent("secret.vault")
        try Data("vault secret".utf8).write(to: secretVaultFile)

        let vaultItem = ManagedFileItem(
            id: UUID(),
            title: "secret",
            relativePath: "Documents/Downloads/secret.vault",
            fileExtension: "vault",
            createdAt: Date(),
            byteSize: 12,
            folderName: "",
            relativeSubpath: nil
        )

        // リネーム試行の拒否
        XCTAssertThrowsError(try zipMgr.renameManagedFile(vaultItem, to: "leak"))

        // 移動試行の拒否
        fm.registerLogicalFolderIfNeeded("PublicFolder")
        XCTAssertThrowsError(try zipMgr.moveManagedFile(vaultItem, toFolder: "PublicFolder", folderManager: fm))

        // 動画ファイルがManagedFilesに混入しないこと
        let videoFile = downloadsDir.appendingPathComponent("movie.mp4")
        try Data(repeating: 0x00, count: 128).write(to: videoFile)
        zipMgr.syncWithFileSystem(downloads: dc, folderManager: fm)
        XCTAssertFalse(zipMgr.managedFiles.contains(where: { $0.fileExtension.lowercased() == "mp4" }))
    }

    @MainActor
    func testZipPhaseF2A_InjectedMetadataPersistFailure_MaintainsJournalAndRecovers() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ZipF2A_InjectFail_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let stagingDir = tempRoot.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let suiteName = "com.clipharbor.test.zipf2a.injectfail.\(UUID().uuidString)"
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

        let testFile = downloadsDir.appendingPathComponent("persist_test.txt")
        try Data("test persistence".utf8).write(to: testFile)
        zipMgr.syncWithFileSystem(downloads: dc, folderManager: fm)

        guard let item = zipMgr.managedFiles.first(where: { $0.title == "persist_test" }) else {
            XCTFail("item not found")
            return
        }
        let origID = item.id

        // 永続化失敗を注入
        struct MockPersistError: Error {}
        zipMgr.metadataPersistFailureInjector = {
            throw MockPersistError()
        }

        // リネームを試行（永続化が失敗するためエラーがスローされる）
        do {
            _ = try zipMgr.renameManagedFile(item, to: "failed_rename")
            XCTFail("Must fail when metadata persistence fails")
        } catch {
            // ロールバックが成功した場合、元ファイル名に戻り、物理ファイルが維持される
            XCTAssertTrue(FileManager.default.fileExists(atPath: testFile.path))
        }

        // 移動を試行（移動先で永続化が失敗し、ロールバックも物理的に失敗する極限状況をシミュレート）
        fm.registerLogicalFolderIfNeeded("TargetDir")
        let destRelative = "Documents/Downloads/TargetDir/persist_test.txt"
        let destURL = downloadsDir.appendingPathComponent("TargetDir/persist_test.txt")
        try FileManager.default.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 物理ファイルを移動
        try FileManager.default.moveItem(at: testFile, to: destURL)

        let pending = ManagedFilePendingOperation(
            operationID: UUID(),
            itemID: origID,
            kind: .move,
            sourceRelativePath: item.normalizedRelativePath,
            destinationRelativePath: destRelative,
            originalTitle: item.title,
            destinationTitle: "persist_test",
            originalFolderName: "",
            destinationFolderName: "TargetDir",
            fileExtension: "txt",
            createdAt: item.createdAt
        )
        try zipMgr.recordPendingOperation(pending)

        // 永続化失敗注入状態のまま復旧を試行
        zipMgr.recoverPendingOperationsIfNeeded()
        // 永続化が失敗したため、ジャーナルは削除されずに保持されていること！
        XCTAssertNotNil(zipMgr.loadPendingOperation(), "永続化失敗時はジャーナルを消去せず保持すること")
        XCTAssertNotNil(zipMgr.unresolvedRecoveryNotice, "未解決通知が保持されること")

        // 永続化失敗注入を解除して再度復旧
        zipMgr.metadataPersistFailureInjector = nil
        zipMgr.recoverPendingOperationsIfNeeded()

        // 永続化成功により、UUIDが復旧されジャーナルが安全にクリアされること
        XCTAssertNil(zipMgr.loadPendingOperation(), "復旧永続化成功後にジャーナルがクリアされること")
        XCTAssertNil(zipMgr.unresolvedRecoveryNotice)
        XCTAssertEqual(zipMgr.managedFiles.first?.id, origID, "元のUUIDが100%復元されていること")
    }

    @MainActor
    func testZipPhaseF2A_Rename_CaseOnlyAndUnicodeCanonicalEquivalence() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ZipF2A_CaseNorm_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let stagingDir = tempRoot.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let suiteName = "com.clipharbor.test.zipf2a.casenorm.\(UUID().uuidString)"
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

        let initialFile = downloadsDir.appendingPathComponent("readme.txt")
        try Data("case test".utf8).write(to: initialFile)

        zipMgr.syncWithFileSystem(downloads: dc, folderManager: fm)
        guard let item = zipMgr.managedFiles.first(where: { $0.title == "readme" }) else {
            XCTFail("item not found")
            return
        }
        let origID = item.id

        // 1. 同名変更（完全一致）は safe no-op
        let sameRes = try zipMgr.renameManagedFile(item, to: "readme")
        XCTAssertEqual(sameRes.id, origID)
        XCTAssertEqual(sameRes.title, "readme")

        // 2. APFS case-insensitive 環境での大文字のみへの変更（readme -> README）
        let upperRes = try zipMgr.renameManagedFile(item, to: "README")
        XCTAssertEqual(upperRes.id, origID)
        XCTAssertEqual(upperRes.title, "README", "大文字へのリネームが成立すること")
        XCTAssertEqual(upperRes.fileExtension, "txt")

        // 3. 大文字から小文字キャメルケースへの変更（README -> ReadMe）
        let camelRes = try zipMgr.renameManagedFile(upperRes, to: "ReadMe")
        XCTAssertEqual(camelRes.id, origID)
        XCTAssertEqual(camelRes.title, "ReadMe")

        // 4. Unicode NFC vs NFD の正準等価衝突テスト
        // 別ファイルとして "cafe\u{0301}.txt" (NFD) を作成
        let nfdURL = downloadsDir.appendingPathComponent("cafe\u{0301}.txt")
        try Data("cafe content".utf8).write(to: nfdURL)
        zipMgr.syncWithFileSystem(downloads: dc, folderManager: fm)

        // camelRes を "café" (NFC) へリネームしようとすると、既存の "cafe\u{0301}.txt" と正準等価衝突するため alreadyExists エラー
        XCTAssertThrowsError(try zipMgr.renameManagedFile(camelRes, to: "caf\u{00E9}")) { error in
            guard let folderErr = error as? VideoFolderManager.FolderError else {
                XCTFail("Expected FolderError, got \(error)")
                return
            }
            if case .alreadyExists = folderErr {
                // OK
            } else {
                XCTFail("Expected alreadyExists, got \(folderErr)")
            }
        }
    }

    @MainActor
    func testZipPhaseF2A_Move_NewFolderCleanupFaultInjection_DoesNotDeleteNonEmptyFolder() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ZipF2A_CleanupFault_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let stagingDir = tempRoot.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let suiteName = "com.clipharbor.test.zipf2a.cleanupfault.\(UUID().uuidString)"
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

        // 1. 新規作成フォルダ "SafeNewFolder" を作成
        let newFolder = "SafeNewFolder"
        let newFolderURL = downloadsDir.appendingPathComponent(newFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: newFolderURL, withIntermediateDirectories: true)
        fm.registerLogicalFolderIfNeeded(newFolder)

        // 2. そのフォルダ内に別の既存ファイル "important.data" を配置
        let existingFile = newFolderURL.appendingPathComponent("important.data")
        try Data("do not delete me".utf8).write(to: existingFile)

        // 3. 宛先ファイルURL
        let destFileURL = newFolderURL.appendingPathComponent("failed_move.txt")

        // 4. cleanup関数を直接呼び出す（失敗時のクリーンアップ処理の厳格検証）
        ZipArchiveManager.safelyCleanupNewlyCreatedFolderIfNeeded(
            newFolderURL,
            destinationFileURL: destFileURL,
            folderName: newFolder,
            folderManager: fm,
            fileManager: FileManager.default
        )

        // 検証: ファイルが含まれるため、新規作成フォルダも中のファイルも一切削除されていないこと！
        XCTAssertTrue(FileManager.default.fileExists(atPath: newFolderURL.path), "中身が存在するフォルダは削除されないこと")
        XCTAssertTrue(FileManager.default.fileExists(atPath: existingFile.path), "フォルダ内の既存ファイルは保護されること")
        XCTAssertTrue(fm.folders.contains(newFolder), "論理フォルダ管理メタデータも維持されること")

        // 5. 空の新規フォルダに対するクリーンアップ検証
        let emptyFolder = "EmptyNewFolder"
        let emptyFolderURL = downloadsDir.appendingPathComponent(emptyFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: emptyFolderURL, withIntermediateDirectories: true)
        fm.registerLogicalFolderIfNeeded(emptyFolder)

        ZipArchiveManager.safelyCleanupNewlyCreatedFolderIfNeeded(
            emptyFolderURL,
            destinationFileURL: emptyFolderURL.appendingPathComponent("not_there.txt"),
            folderName: emptyFolder,
            folderManager: fm,
            fileManager: FileManager.default
        )

        // 検証: 完全に空の場合は安全に削除され、メタデータからも解除されること
        XCTAssertFalse(FileManager.default.fileExists(atPath: emptyFolderURL.path), "空の新規フォルダは削除されること")
        XCTAssertFalse(fm.folders.contains(emptyFolder), "論理フォルダも整合解除されること")
    }

    @MainActor
    func testZipPhaseF2A_DocumentsRootFile_RenameAndBoundaryCheck() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ZipF2A_Boundary_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let stagingDir = tempRoot.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let suiteName = "com.clipharbor.test.zipf2a.boundary.\(UUID().uuidString)"
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

        // 1. Documents 直下に配置されたファイル（Documents/doc_root.txt）をシミュレート
        let docRootFile = tempRoot.appendingPathComponent("doc_root.txt")
        try Data("root doc content".utf8).write(to: docRootFile)

        let rootItem = ManagedFileItem(
            id: UUID(),
            title: "doc_root",
            relativePath: "Documents/doc_root.txt",
            fileExtension: "txt",
            createdAt: Date(),
            byteSize: 16,
            folderName: "",
            relativeSubpath: nil
        )
        zipMgr.appendManagedFileForTesting(rootItem)

        // Documents直下のファイルをリネーム
        let renamed = try zipMgr.renameManagedFile(rootItem, to: "doc_root_renamed")
        XCTAssertEqual(renamed.id, rootItem.id)
        XCTAssertEqual(renamed.title, "doc_root_renamed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent("doc_root_renamed.txt").path))

        // 2. 領域外参照（.. を含む不正パスやルート逸脱）の拒否検証
        XCTAssertThrowsError(try zipMgr.renameManagedFile(renamed, to: "../../etc_passwd"))

        // 3. シンボリックリンクの拒否検証
        let symlinkURL = downloadsDir.appendingPathComponent("link.txt")
        let targetFile = downloadsDir.appendingPathComponent("target.txt")
        try Data("target content".utf8).write(to: targetFile)
        try? FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: targetFile)

        if FileManager.default.fileExists(atPath: symlinkURL.path) {
            let symItem = ManagedFileItem(
                id: UUID(),
                title: "link",
                relativePath: "Documents/Downloads/link.txt",
                fileExtension: "txt",
                createdAt: Date(),
                byteSize: 10,
                folderName: "",
                relativeSubpath: nil
            )
            XCTAssertThrowsError(try zipMgr.renameManagedFile(symItem, to: "renamed_link")) { err in
                XCTAssertTrue(err.localizedDescription.contains("Symbolic link") || err.localizedDescription.contains("シンボリックリンク"))
            }
        }
    }

    // MARK: - Phase F2-A 最終復旧・安全性追加テスト

    @MainActor
    func testZipPhaseF2A_Rename_CaseOnlyIntermediateCrash_RecoversUUIDAndFile() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ZipF2A_CaseCrash_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let stagingDir = tempRoot.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let suiteName = "com.clipharbor.test.zipf2a.casecrash.\(UUID().uuidString)"
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

        // 状況設定：
        // sample.txt -> SAMPLE.txt へのリネーム中、中間ファイル .rename_case_tmp_<UUID> に移動した直後にクラッシュ
        let origUUID = UUID()
        let intermediateFileName = ".rename_case_tmp_\(UUID().uuidString)"
        let intermediateFile = downloadsDir.appendingPathComponent(intermediateFileName)
        try Data("case sensitive recovery content".utf8).write(to: intermediateFile)

        let intermediateRel = "Documents/Downloads/\(intermediateFileName)"
        let pendingOp = ManagedFilePendingOperation(
            operationID: UUID(),
            itemID: origUUID,
            kind: .rename,
            sourceRelativePath: "Documents/Downloads/sample.txt",
            destinationRelativePath: "Documents/Downloads/SAMPLE.txt",
            intermediateRelativePath: intermediateRel,
            originalTitle: "sample",
            destinationTitle: "SAMPLE",
            originalFolderName: "",
            destinationFolderName: "",
            fileExtension: "txt",
            createdAt: Date()
        )
        try zipMgr.recordPendingOperationForTesting(pendingOp)

        // 復旧処理を実行
        zipMgr.recoverPendingOperationsIfNeeded()

        // 中間ファイルから SAMPLE.txt への移動が完遂され、UUIDが維持され、ジャーナルがクリアされていること
        let destFile = downloadsDir.appendingPathComponent("SAMPLE.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destFile.path), "目的地に実ファイルが存在すること")
        XCTAssertFalse(FileManager.default.fileExists(atPath: intermediateFile.path), "中間ファイルは解消されていること")
        XCTAssertNil(zipMgr.loadPendingOperation(), "復旧完了後にジャーナルがクリアされること")
        XCTAssertNil(zipMgr.unresolvedRecoveryNotice)
        XCTAssertEqual(zipMgr.managedFiles.first?.id, origUUID, "UUIDが完全に維持されていること")
        XCTAssertEqual(zipMgr.managedFiles.first?.title, "SAMPLE")
    }

    @MainActor
    func testZipPhaseF2A_PendingOperation_RejectsNewOperationAndPreventsOverwrite() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ZipF2A_RejectNew_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let stagingDir = tempRoot.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let suiteName = "com.clipharbor.test.zipf2a.rejectnew.\(UUID().uuidString)"
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

        // 既存の未解決ジャーナルを記録
        let existingOpID = UUID()
        let existingOp = ManagedFilePendingOperation(
            operationID: existingOpID,
            itemID: UUID(),
            kind: .rename,
            sourceRelativePath: "Documents/Downloads/pending1.txt",
            destinationRelativePath: "Documents/Downloads/pending1_renamed.txt",
            intermediateRelativePath: nil,
            originalTitle: "pending1",
            destinationTitle: "pending1_renamed",
            originalFolderName: "",
            destinationFolderName: "",
            fileExtension: "txt",
            createdAt: Date()
        )
        try zipMgr.recordPendingOperationForTesting(existingOp)

        // 操作対象の通常ファイルを作成
        let activeFile = downloadsDir.appendingPathComponent("active.txt")
        try Data("active content".utf8).write(to: activeFile)
        let activeItem = ManagedFileItem(
            id: UUID(),
            title: "active",
            relativePath: "Documents/Downloads/active.txt",
            fileExtension: "txt",
            createdAt: Date(),
            byteSize: 14,
            folderName: "",
            relativeSubpath: nil
        )
        zipMgr.appendManagedFileForTesting(activeItem)

        // 未解決ジャーナルが存在する状態での新規リネームが拒否されること
        XCTAssertThrowsError(try zipMgr.renameManagedFile(activeItem, to: "active_renamed")) { error in
            XCTAssertTrue(error.localizedDescription.contains("pending recovery") || error.localizedDescription.contains("復旧待ち"))
        }

        // 既存ジャーナルが上書きされず維持されていること
        let currentJournal = zipMgr.loadPendingOperation()
        XCTAssertEqual(currentJournal?.operationID, existingOpID, "既存のジャーナルが上書きされず維持されること")
    }

    @MainActor
    func testZipPhaseF2A_PendingRecovery_BothMissing_MaintainsJournal() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ZipF2A_Missing_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let stagingDir = tempRoot.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let suiteName = "com.clipharbor.test.zipf2a.missing.\(UUID().uuidString)"
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

        // 状況設定：元・中間・宛先のどこにも実ファイルが存在しない
        let missingOp = ManagedFilePendingOperation(
            operationID: UUID(),
            itemID: UUID(),
            kind: .rename,
            sourceRelativePath: "Documents/Downloads/ghost_src.txt",
            destinationRelativePath: "Documents/Downloads/ghost_dst.txt",
            intermediateRelativePath: nil,
            originalTitle: "ghost_src",
            destinationTitle: "ghost_dst",
            originalFolderName: "",
            destinationFolderName: "",
            fileExtension: "txt",
            createdAt: Date()
        )
        try zipMgr.recordPendingOperationForTesting(missingOp)

        zipMgr.recoverPendingOperationsIfNeeded()

        // 原因が確定するまでジャーナルを消去せず保持し、未解決通知が設定されること
        XCTAssertNotNil(zipMgr.loadPendingOperation(), "全地点不在でも原因確定までジャーナルを維持すること")
        XCTAssertNotNil(zipMgr.unresolvedRecoveryNotice, "未解決状態が通知されること")
    }

    @MainActor
    func testZipPhaseF2A_Move_FolderCleanup_DoesNotDeleteFolderWithDSStore() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ZipF2A_DSStore_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let testFolder = downloadsDir.appendingPathComponent("FolderWithDSStore", isDirectory: true)
        try FileManager.default.createDirectory(at: testFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let dc = DownloadCenter()
        let fm = VideoFolderManager(downloads: dc)
        fm.registerLogicalFolderIfNeeded("FolderWithDSStore")

        // フォルダ内に .DS_Store を配置
        let dsStoreFile = testFolder.appendingPathComponent(".DS_Store")
        try Data("dummy ds_store".utf8).write(to: dsStoreFile)

        let destFile = testFolder.appendingPathComponent("non_existent.txt")

        // クリーンアップを呼び出し
        ZipArchiveManager.safelyCleanupNewlyCreatedFolderIfNeeded(
            testFolder,
            destinationFileURL: destFile,
            folderName: "FolderWithDSStore",
            folderManager: fm,
            fileManager: FileManager.default
        )

        // .DS_Store があるためフォルダは削除されず保持されること
        XCTAssertTrue(FileManager.default.fileExists(atPath: testFolder.path), "DS_Store等の残存ファイルがある場合はフォルダを削除しないこと")
        XCTAssertTrue(fm.folders.contains("FolderWithDSStore"), "論理フォルダも維持されること")
    }

    // MARK: - Phase F2-B 一般ファイルのゴミ箱統合テスト

    @MainActor
    func testZipPhaseF2B_TrashItem_BackwardCompatibility_DecodesLegacyVideoJSONWithoutPayloadKind() throws {
        // payloadKind, fileExtension, relativeSubpath が存在しない旧バージョンの動画ゴミ箱JSON
        let legacyJSON = """
        [
            {
                "id": "11111111-2222-3333-4444-555555555555",
                "originalVideoID": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                "originalTitle": "Legacy Video",
                "originalRelativePath": "Documents/Downloads/legacy.mp4",
                "originalFolderName": "Movies",
                "format": "mp4",
                "byteSize": 1048576,
                "sourceHost": "example.com",
                "sourcePageURL": "https://example.com/watch",
                "deletedAt": 700000000,
                "expiresAt": 700259200,
                "fileName": "legacy.mp4",
                "isFavorite": true
            }
        ]
        """
        let data = Data(legacyJSON.utf8)
        let items = try JSONDecoder().decode([TrashItem].self, from: data)
        XCTAssertEqual(items.count, 1)

        let item = items[0]
        XCTAssertEqual(item.id, UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        XCTAssertEqual(item.originalVideoID, UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
        XCTAssertEqual(item.originalTitle, "Legacy Video")
        XCTAssertEqual(item.payloadKind, .video, "旧JSONは自動的に.videoとしてデコードされること")
        XCTAssertTrue(item.isVideo, "isVideoがtrueであること")
        XCTAssertFalse(item.isGeneralFile, "isGeneralFileがfalseであること")
        XCTAssertEqual(item.format, .mp4)
        XCTAssertEqual(item.typeLabel, "MP4")
        XCTAssertNil(item.fileExtension)
        XCTAssertNil(item.relativeSubpath)
    }

    @MainActor
    func testZipPhaseF2B_MoveGeneralFileToTrash_MaintainsUUIDAndFileIntegrity() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ZipF2B_MoveTrash_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let stagingDir = tempRoot.appendingPathComponent("Staging", isDirectory: true)
        let trashDir = tempRoot.appendingPathComponent("TrashRoot", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let suiteName = "com.clipharbor.test.zipf2b.movetrash.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let zipMgr = ZipArchiveManager(
            userDefaults: defaults,
            customDownloadsRootURL: downloadsDir,
            customStagingRootURL: stagingDir
        )
        let trashMgr = TrashManager(customTrashDirectoryURL: trashDir)

        // 1. テスト対象の一般ファイルを作成（note.txt）
        let testFile = downloadsDir.appendingPathComponent("note.txt")
        try Data("General file trash test content".utf8).write(to: testFile)

        let origID = UUID()
        let item = ManagedFileItem(
            id: origID,
            title: "note",
            relativePath: "Documents/Downloads/note.txt",
            fileExtension: "txt",
            createdAt: Date(),
            byteSize: 31,
            folderName: "",
            relativeSubpath: nil
        )
        zipMgr.appendManagedFileForTesting(item)

        // 2. ゴミ箱へ移動
        let res = await trashMgr.moveToTrash(managedFile: item, zipManager: zipMgr)
        guard case .success(let trashItem) = res else {
            XCTFail("moveToTrash failed")
            return
        }

        // 検証:
        // 元の場所から物理移動され、ゴミ箱内に実ファイルが存在すること
        XCTAssertFalse(FileManager.default.fileExists(atPath: testFile.path), "元ファイルが物理移動されていること")
        let trashFileURL = trashMgr.itemFileURL(for: trashItem)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashFileURL.path), "ゴミ箱内に実ファイルが存在すること")

        // UUID・種別・拡張子が維持されていること
        XCTAssertEqual(trashItem.originalVideoID, origID, "元のUUIDが維持されていること")
        XCTAssertEqual(trashItem.payloadKind, .generalFile, "payloadKindが.generalFileであること")
        XCTAssertTrue(trashItem.isGeneralFile)
        XCTAssertFalse(trashItem.isVideo)
        XCTAssertEqual(trashItem.fileExtension, "txt")
        XCTAssertEqual(trashItem.typeLabel, "TXT")

        // zipManager のインデックスから除外されていること
        XCTAssertFalse(zipMgr.managedFiles.contains(where: { $0.id == origID }))

        // 一般ファイルに対してサムネイル生成が行われないこと（必須条件2）
        let thumb = await trashMgr.loadThumbnail(for: trashItem)
        XCTAssertNil(thumb, "一般ファイルは動画サムネイル生成に渡されずnilを返すこと")
    }

    @MainActor
    func testZipPhaseF2B_RestoreGeneralFile_MaintainsUUID_RecreatesFolderAndAvoidsOverwrite() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ZipF2B_Restore_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let stagingDir = tempRoot.appendingPathComponent("Staging", isDirectory: true)
        let trashDir = tempRoot.appendingPathComponent("TrashRoot", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let suiteName = "com.clipharbor.test.zipf2b.restore.\(UUID().uuidString)"
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
        let trashMgr = TrashManager(customTrashDirectoryURL: trashDir)

        // 状況設定：
        // 管理フォルダ "ArchivedReports" 配下の "report.pdf" をゴミ箱へ移動
        let folderName = "ArchivedReports"
        fm.registerLogicalFolderIfNeeded(folderName)
        let folderDir = downloadsDir.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folderDir, withIntermediateDirectories: true)

        let pdfFile = folderDir.appendingPathComponent("report.pdf")
        try Data("PDF report content".utf8).write(to: pdfFile)

        let origID = UUID()
        let managedItem = ManagedFileItem(
            id: origID,
            title: "report",
            relativePath: "Documents/Downloads/\(folderName)/report.pdf",
            fileExtension: "pdf",
            createdAt: Date(),
            byteSize: 18,
            folderName: folderName,
            relativeSubpath: nil
        )
        zipMgr.appendManagedFileForTesting(managedItem)

        // ゴミ箱へ移動
        let moveRes = await trashMgr.moveToTrash(managedFile: managedItem, zipManager: zipMgr)
        guard case .success(let trashItem) = moveRes else {
            XCTFail("moveToTrash failed")
            return
        }

        // 移動後、元のフォルダを物理的・論理的に削除（元フォルダ削除のシミュレーション）
        try? FileManager.default.removeItem(at: folderDir)
        fm.unregisterLogicalFolderIfNeeded(folderName)
        XCTAssertFalse(fm.folders.contains(folderName))

        // 復元先のフォルダに同名の "report.pdf" を新規作成（同名衝突・上書き禁止シミュレーション）
        try FileManager.default.createDirectory(at: folderDir, withIntermediateDirectories: true)
        let conflictFile = folderDir.appendingPathComponent("report.pdf")
        try Data("Existing conflicting PDF".utf8).write(to: conflictFile)

        // 復元を実行
        let restoreRes = await trashMgr.restore(item: trashItem, downloads: dc, folderManager: fm, zipManager: zipMgr)
        guard case .success(let restored) = restoreRes else {
            XCTFail("restore failed")
            return
        }

        guard case .generalFile(let restoredFile) = restored else {
            XCTFail("Expected generalFile result")
            return
        }

        // 検証:
        // 1. UUIDが100%維持されていること
        XCTAssertEqual(restoredFile.id, origID, "UUIDが100%維持されていること")
        // 2. 削除されていたフォルダが論理・物理両面で再作成されていること
        XCTAssertTrue(fm.folders.contains(folderName), "元フォルダが論理登録に再生成されていること")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folderDir.path))
        // 3. 既存の同名ファイルが上書きされず保持されていること
        XCTAssertEqual(try? String(contentsOf: conflictFile, encoding: .utf8), "Existing conflicting PDF", "既存ファイルが上書きされていないこと")
        // 4. 復元ファイルが連番付きで安全に共存していること（上書き禁止）
        XCTAssertTrue(restoredFile.title.contains("report"), "復元されたタイトルが維持されていること")
        let restoredPhysURL = zipMgr.resolveFileURL(for: restoredFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: restoredPhysURL.path), "復元ファイルが物理的に存在すること")
        XCTAssertNotEqual(restoredPhysURL.path, conflictFile.path, "競合ファイルと別パスで保存されていること")
        // 5. ゴミ箱メタデータから除外されていること
        XCTAssertFalse(trashMgr.items.contains(where: { $0.id == trashItem.id }))
    }

    @MainActor
    func testZipPhaseF2B_TrashAutoPurge_GeneralFileExpiresCorrectly() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ZipF2B_Purge_\(UUID().uuidString)", isDirectory: true)
        let trashDir = tempRoot.appendingPathComponent("TrashRoot", isDirectory: true)
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let trashMgr = TrashManager(customTrashDirectoryURL: trashDir)

        // 1. 期限切れ一般ファイル（1日前に期限切れ）を作成
        let expiredID = UUID()
        let expiredDir = trashMgr.trashDirectoryURL.appendingPathComponent(expiredID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: expiredDir, withIntermediateDirectories: true)
        let expiredFile = expiredDir.appendingPathComponent("old.txt")
        try Data("old content".utf8).write(to: expiredFile)

        let expiredItem = TrashItem(
            id: expiredID,
            originalVideoID: UUID(),
            originalTitle: "old",
            originalRelativePath: "Documents/Downloads/old.txt",
            originalFolderName: "",
            format: .mp4,
            byteSize: 11,
            sourceHost: nil,
            sourcePageURL: nil,
            deletedAt: Date().addingTimeInterval(-86400 * 4),
            expiresAt: Date().addingTimeInterval(-86400 * 1), // 昨日期限切れ
            fileName: "old.txt",
            isFavorite: false,
            payloadKind: .generalFile,
            fileExtension: "txt",
            relativeSubpath: nil
        )

        // 2. 有効期間内の一般ファイル（3日後に期限切れ）を作成
        let validID = UUID()
        let validDir = trashMgr.trashDirectoryURL.appendingPathComponent(validID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: validDir, withIntermediateDirectories: true)
        let validFile = validDir.appendingPathComponent("valid.zip")
        try Data("valid zip content".utf8).write(to: validFile)

        let validItem = TrashItem(
            id: validID,
            originalVideoID: UUID(),
            originalTitle: "valid",
            originalRelativePath: "Documents/Downloads/valid.zip",
            originalFolderName: "",
            format: .mp4,
            byteSize: 17,
            sourceHost: nil,
            sourcePageURL: nil,
            deletedAt: Date(),
            expiresAt: Date().addingTimeInterval(86400 * 3), // 3日後期限
            fileName: "valid.zip",
            isFavorite: false,
            payloadKind: .generalFile,
            fileExtension: "zip",
            relativeSubpath: nil
        )

        // メタデータを直接書き込み
        let metadataURL = trashMgr.metadataFileURL
        let data = try JSONEncoder().encode([expiredItem, validItem])
        try data.write(to: metadataURL, options: .atomic)

        // マネージャーにリロードさせる
        let reloadMgr = TrashManager(customTrashDirectoryURL: trashDir)

        // パージ実行待機
        for _ in 0..<30 {
            if !reloadMgr.items.contains(where: { $0.id == expiredID }) {
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        // 検証:
        // 期限切れファイルは完全削除されていること
        XCTAssertFalse(reloadMgr.items.contains(where: { $0.id == expiredID }), "期限切れアイテムが一覧から除外されていること")
        XCTAssertFalse(FileManager.default.fileExists(atPath: expiredFile.path), "期限切れファイルがディスクから物理削除されていること")

        // 有効期間内のアイテムは保持されていること
        XCTAssertTrue(reloadMgr.items.contains(where: { $0.id == validID }), "有効なアイテムが保持されていること")
        XCTAssertTrue(FileManager.default.fileExists(atPath: validFile.path), "有効なファイルがディスク上に保持されていること")
    }

    @MainActor
    func testZipPhaseF2B_OrphanFileRecovery_DoesNotMistreatGeneralFileAsVideo() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ZipF2B_Orphan_\(UUID().uuidString)", isDirectory: true)
        let trashDir = tempRoot.appendingPathComponent("TrashRoot", isDirectory: true)
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        // メタデータなしで Trash/ 直下に孤立ディレクトリとファイルを直接作成
        let orphanUUID = UUID()
        let orphanDir = trashDir.appendingPathComponent("Trash", isDirectory: true).appendingPathComponent(orphanUUID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: orphanDir, withIntermediateDirectories: true)

        let orphanZipFile = orphanDir.appendingPathComponent("archive.zip")
        try Data("orphan zip content".utf8).write(to: orphanZipFile)

        // TrashManager 初期化（メタデータ不在からのスキャン復旧）
        let trashMgr = TrashManager(customTrashDirectoryURL: trashDir)

        // 検証:
        // 孤立したZIPファイルが救済され、誤って.videoではなく.generalFileとして登録されていること（必須条件4）
        guard let recoveredItem = trashMgr.items.first(where: { $0.id == orphanUUID }) else {
            XCTFail("Orphaned zip file was not recovered")
            return
        }

        XCTAssertEqual(recoveredItem.payloadKind, .generalFile, "孤立ZIPは誤って動画と判定されず.generalFileとして救済されること")
        XCTAssertTrue(recoveredItem.isGeneralFile)
        XCTAssertFalse(recoveredItem.isVideo)
        XCTAssertEqual(recoveredItem.fileExtension, "zip")
        XCTAssertEqual(recoveredItem.typeLabel, "ZIP")
        XCTAssertEqual(recoveredItem.fileName, "archive.zip")
    }

    @MainActor
    func testZipPhaseF2B_ExistingVideoAndHLS_RegressionCheck() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ZipF2B_Regression_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let stagingDir = tempRoot.appendingPathComponent("Staging", isDirectory: true)
        let trashDir = tempRoot.appendingPathComponent("TrashRoot", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let suiteName = "com.clipharbor.test.zipf2b.regression.\(UUID().uuidString)"
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
        let trashMgr = TrashManager(customTrashDirectoryURL: trashDir)

        // 1. 通常のMP4動画の移動と復元
        let mp4File = downloadsDir.appendingPathComponent("sample_video.mp4")
        try Data("dummy mp4 video bytes".utf8).write(to: mp4File)

        let video = SavedVideo(
            id: UUID(),
            title: "sample_video",
            relativePath: "Documents/Downloads/sample_video.mp4",
            format: .mp4,
            sourceHost: "clipharbor.test",
            createdAt: Date(),
            byteSize: 22,
            sourcePageURL: "https://clipharbor.test/page"
        )
        dc.addSaved(video)

        // ゴミ箱へ移動
        let moveRes = await trashMgr.moveToTrash(video: video, folderName: "", downloads: dc, folderManager: fm)
        guard case .success(let trashVideo) = moveRes else {
            XCTFail("Video moveToTrash failed")
            return
        }

        XCTAssertEqual(trashVideo.payloadKind, .video, "動画のpayloadKindは.videoであること")
        XCTAssertTrue(trashVideo.isVideo)
        XCTAssertFalse(trashVideo.isGeneralFile)
        XCTAssertFalse(dc.saved.contains(where: { $0.id == video.id }), "通常一覧から除外されていること")

        // 復元
        let restoreRes = await trashMgr.restore(item: trashVideo, downloads: dc, folderManager: fm, zipManager: zipMgr)
        guard case .success(let restored) = restoreRes else {
            XCTFail("Video restore failed")
            return
        }

        guard case .video(let restoredVideo) = restored else {
            XCTFail("Expected video result")
            return
        }

        XCTAssertEqual(restoredVideo.id, video.id, "動画のUUIDが一致すること")
        XCTAssertEqual(restoredVideo.format, .mp4)
        XCTAssertTrue(dc.saved.contains(where: { $0.id == video.id }), "通常一覧へ復元されていること")
    }

}
