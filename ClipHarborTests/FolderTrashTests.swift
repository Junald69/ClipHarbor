import XCTest
import ZIPFoundation
@testable import ClipHarbor

/// フォルダ一括ゴミ箱移動・復元・競合解決・トランザクション障害復旧の網羅的テストスイート (Phase S3)
/// - 本番データ・UserDefaults・実ファイルを完全隔離し一時サンドボックスで実行
final class FolderTrashTests: XCTestCase {

    // MARK: - 1. 空フォルダの移動と復元

    @MainActor
    func testFolderTrash_EmptyFolder_MoveAndRestore() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("FolderTrash_Empty_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let trashContainer = tempRoot.appendingPathComponent("TrashContainer", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let dc = DownloadCenter()
        for v in dc.saved { dc.removeSavedVideoWithoutDeletingFile(id: v.id) }
        let fm = VideoFolderManager(downloads: dc)
        let defaults = UserDefaults(suiteName: "test.folder.empty.\(UUID().uuidString)")!
        let zipMgr = ZipArchiveManager(userDefaults: defaults, customDownloadsRootURL: downloadsDir)
        let trashMgr = TrashManager(customTrashDirectoryURL: trashContainer)

        let folderName = "EmptyFolder"
        let folderURL = downloadsDir.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        fm.registerLogicalFolderIfNeeded(folderName)

        // ゴミ箱へ移動
        let moveResult = await trashMgr.moveToTrash(
            folderName: folderName,
            downloads: dc,
            folderManager: fm,
            zipManager: zipMgr,
            customRootURL: downloadsDir
        )
        guard case .success(let trashItem) = moveResult else {
            XCTFail("Moving empty folder to trash failed")
            return
        }

        XCTAssertTrue(trashItem.isFolder)
        XCTAssertEqual(trashItem.fileName, folderName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folderURL.path), "Original folder should be moved from Downloads")

        // 復元
        let restoreResult = await trashMgr.restoreFolder(
            item: trashItem,
            downloads: dc,
            folderManager: fm,
            zipManager: zipMgr,
            resolution: .rename,
            customRootURL: downloadsDir
        )
        guard case .success(let restoredName) = restoreResult else {
            XCTFail("Restoring empty folder failed")
            return
        }

        XCTAssertEqual(restoredName, folderName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folderURL.path), "Folder should be recreated in Downloads")
        XCTAssertTrue(fm.folders.contains(folderName))
    }

    // MARK: - 2. 動画・一般ファイル・HLS・未登録ファイルを含む混在フォルダの完全性検証

    @MainActor
    func testFolderTrash_MixedContents_MoveAndRestore_Integrity() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("FolderTrash_Mixed_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let trashContainer = tempRoot.appendingPathComponent("TrashContainer", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let dc = DownloadCenter()
        for v in dc.saved { dc.removeSavedVideoWithoutDeletingFile(id: v.id) }
        let fm = VideoFolderManager(downloads: dc)
        let defaults = UserDefaults(suiteName: "test.folder.mixed.\(UUID().uuidString)")!
        let zipMgr = ZipArchiveManager(userDefaults: defaults, customDownloadsRootURL: downloadsDir)
        let trashMgr = TrashManager(customTrashDirectoryURL: trashContainer)

        let targetFolder = "MediaProject"
        fm.registerLogicalFolderIfNeeded(targetFolder)
        let folderURL = downloadsDir.appendingPathComponent(targetFolder, isDirectory: true)
        let subDir = folderURL.appendingPathComponent("Clips", isDirectory: true)
        let emptySubDir = folderURL.appendingPathComponent("EmptyNested", isDirectory: true)
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: emptySubDir, withIntermediateDirectories: true)

        // 1. MP4動画
        let mp4URL = subDir.appendingPathComponent("intro.mp4")
        try Data(repeating: 0xAA, count: 1024).write(to: mp4URL)
        let introVideoID = UUID()
        let introVideo = SavedVideo(
            id: introVideoID,
            title: "intro",
            relativePath: "Documents/Downloads/\(targetFolder)/Clips/intro.mp4",
            format: .mp4,
            sourceHost: "clips.example.com",
            createdAt: Date(),
            byteSize: 1024,
            isFavorite: true
        )
        dc.restoreSavedVideo(introVideo)
        fm.restoreVideoToFolder(introVideo, targetFolder: targetFolder)

        // 2. HLS (.movpkg) パッケージ
        let hlsDirURL = subDir.appendingPathComponent("stream.movpkg", isDirectory: true)
        try FileManager.default.createDirectory(at: hlsDirURL, withIntermediateDirectories: true)
        try Data("HLS Playlist Content".utf8).write(to: hlsDirURL.appendingPathComponent("master.m3u8"))
        let hlsVideoID = UUID()
        let hlsVideo = SavedVideo(
            id: hlsVideoID,
            title: "stream",
            relativePath: "Documents/Downloads/\(targetFolder)/Clips/stream.movpkg",
            format: .hls,
            sourceHost: "stream.example.com",
            createdAt: Date(),
            byteSize: 500,
            isFavorite: false
        )
        dc.restoreSavedVideo(hlsVideo)
        fm.restoreVideoToFolder(hlsVideo, targetFolder: targetFolder)

        // 3. 一般ファイル (ZIP)
        let zipURL = folderURL.appendingPathComponent("assets.zip")
        try Data("ZIP Archive Mock".utf8).write(to: zipURL)
        let zipFileID = UUID()
        let managedZip = ManagedFileItem(
            id: zipFileID,
            title: "assets",
            relativePath: "Documents/Downloads/\(targetFolder)/assets.zip",
            fileExtension: "zip",
            createdAt: Date(),
            byteSize: 256,
            folderName: targetFolder,
            relativeSubpath: "assets.zip"
        )
        zipMgr.restoreManagedFileToIndex(managedZip)

        // 4. 未登録物理ファイル
        let unregURL = subDir.appendingPathComponent("notes.txt")
        try Data("Unregistered Notes".utf8).write(to: unregURL)

        XCTAssertEqual(dc.saved.filter { fm.folderName(for: $0) == targetFolder }.count, 2)
        XCTAssertEqual(zipMgr.managedFiles.filter { $0.folderName == targetFolder }.count, 1)

        // ゴミ箱へ移動
        let moveResult = await trashMgr.moveToTrash(
            folderName: targetFolder,
            downloads: dc,
            folderManager: fm,
            zipManager: zipMgr,
            customRootURL: downloadsDir
        )
        guard case .success(let trashItem) = moveResult else {
            XCTFail("Move mixed folder failed")
            return
        }

        // ゴミ箱移動後の状態検証
        XCTAssertTrue(trashItem.isFolder)
        XCTAssertEqual(trashItem.folderItemCount, 4) // 2 videos + 1 zip + 1 unreg
        XCTAssertFalse(FileManager.default.fileExists(atPath: folderURL.path), "Folder must be moved out of Downloads")
        XCTAssertEqual(dc.saved.filter { fm.folderName(for: $0) == targetFolder }.count, 0, "Videos must be removed from DownloadCenter")
        XCTAssertEqual(zipMgr.managedFiles.filter { $0.folderName == targetFolder }.count, 0, "Files must be removed from ZipArchiveManager")
        XCTAssertFalse(fm.folders.contains(targetFolder), "Folder must be removed from VideoFolderManager")

        // マニフェスト検証
        guard let manifest = trashMgr.loadFolderManifest(for: trashItem.id) else {
            XCTFail("Folder manifest should be readable")
            return
        }
        XCTAssertEqual(manifest.version, 1)
        XCTAssertEqual(manifest.originalFolderName, targetFolder)
        XCTAssertEqual(manifest.videos.count, 2)
        XCTAssertEqual(manifest.generalFiles.count, 1)
        XCTAssertEqual(manifest.unregisteredFiles.count, 1)
        XCTAssertTrue(manifest.emptySubdirectories.contains(where: { $0.contains("EmptyNested") }))

        // 復元
        let restoreResult = await trashMgr.restoreFolder(
            item: trashItem,
            downloads: dc,
            folderManager: fm,
            zipManager: zipMgr,
            resolution: .rename,
            customRootURL: downloadsDir
        )
        guard case .success(let restoredName) = restoreResult else {
            XCTFail("Restore failed")
            return
        }

        XCTAssertEqual(restoredName, targetFolder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folderURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mp4URL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: hlsDirURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: zipURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unregURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: emptySubDir.path))

        // IDとメタデータ・お気に入りの完全維持検証
        let restoredIntro = dc.saved.first(where: { $0.id == introVideoID })
        XCTAssertNotNil(restoredIntro)
        XCTAssertEqual(restoredIntro?.title, "intro")
        XCTAssertEqual(restoredIntro?.isFavorite, true)

        let restoredHLS = dc.saved.first(where: { $0.id == hlsVideoID })
        XCTAssertNotNil(restoredHLS)
        XCTAssertEqual(restoredHLS?.format, .hls)

        let restoredZip = zipMgr.managedFiles.first(where: { $0.id == zipFileID })
        XCTAssertNotNil(restoredZip)
        XCTAssertEqual(restoredZip?.fileExtension, "zip")
    }

    // MARK: - 3. 復元時の同名競合解決（別名復元）

    @MainActor
    func testFolderTrash_RestoreConflict_Rename() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("FolderTrash_ConflictRename_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let trashContainer = tempRoot.appendingPathComponent("TrashContainer", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let dc = DownloadCenter()
        for v in dc.saved { dc.removeSavedVideoWithoutDeletingFile(id: v.id) }
        let fm = VideoFolderManager(downloads: dc)
        let defaults = UserDefaults(suiteName: "test.folder.conflict.\(UUID().uuidString)")!
        let zipMgr = ZipArchiveManager(userDefaults: defaults, customDownloadsRootURL: downloadsDir)
        let trashMgr = TrashManager(customTrashDirectoryURL: trashContainer)

        let folderName = "Documents"
        fm.registerLogicalFolderIfNeeded(folderName)
        let originalDir = downloadsDir.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: originalDir, withIntermediateDirectories: true)
        let fileURL = originalDir.appendingPathComponent("fileA.txt")
        try Data("Original File A".utf8).write(to: fileURL)

        // ゴミ箱へ移動
        let moveRes = await trashMgr.moveToTrash(
            folderName: folderName,
            downloads: dc,
            folderManager: fm,
            zipManager: zipMgr,
            customRootURL: downloadsDir
        )
        guard case .success(let trashItem) = moveRes else {
            XCTFail("Move failed")
            return
        }

        // 復元先に「同名の新フォルダ」を作成（競合を発生させる）
        let conflictingDir = downloadsDir.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: conflictingDir, withIntermediateDirectories: true)
        try Data("Conflicting content".utf8).write(to: conflictingDir.appendingPathComponent("other.txt"))

        // 「別名で復元」を実行
        let restoreRes = await trashMgr.restoreFolder(
            item: trashItem,
            downloads: dc,
            folderManager: fm,
            zipManager: zipMgr,
            resolution: .rename,
            customRootURL: downloadsDir
        )
        guard case .success(let restoredName) = restoreRes else {
            XCTFail("Restore with rename should succeed")
            return
        }

        XCTAssertEqual(restoredName, "\(folderName) (1)")

        // 競合フォルダと別名復元フォルダが両方安全に共存していること
        let expectedRenamedDir = downloadsDir.appendingPathComponent("\(folderName) (1)", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: conflictingDir.path), "Existing folder must NOT be overwritten")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedRenamedDir.path), "Restored folder must exist as (1)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedRenamedDir.appendingPathComponent("fileA.txt").path))
        XCTAssertTrue(fm.folders.contains("\(folderName) (1)"))
    }

    // MARK: - 4. 復元時の同名競合解決（キャンセル）

    @MainActor
    func testFolderTrash_RestoreConflict_Cancel() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("FolderTrash_ConflictCancel_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let trashContainer = tempRoot.appendingPathComponent("TrashContainer", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let dc = DownloadCenter()
        for v in dc.saved { dc.removeSavedVideoWithoutDeletingFile(id: v.id) }
        let fm = VideoFolderManager(downloads: dc)
        let defaults = UserDefaults(suiteName: "test.folder.cancel.\(UUID().uuidString)")!
        let zipMgr = ZipArchiveManager(userDefaults: defaults, customDownloadsRootURL: downloadsDir)
        let trashMgr = TrashManager(customTrashDirectoryURL: trashContainer)

        let folderName = "Projects"
        fm.registerLogicalFolderIfNeeded(folderName)
        let dir = downloadsDir.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let moveRes = await trashMgr.moveToTrash(
            folderName: folderName,
            downloads: dc,
            folderManager: fm,
            zipManager: zipMgr,
            customRootURL: downloadsDir
        )
        guard case .success(let trashItem) = moveRes else {
            XCTFail("Move failed")
            return
        }

        // 同名フォルダを復元先に作成
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // キャンセル指定で復元試行 -> 失敗しゴミ箱に残る
        let restoreRes = await trashMgr.restoreFolder(
            item: trashItem,
            downloads: dc,
            folderManager: fm,
            zipManager: zipMgr,
            resolution: .cancel,
            customRootURL: downloadsDir
        )
        guard case .failure = restoreRes else {
            XCTFail("Restore with cancel should return failure")
            return
        }

        // ゴミ箱にアイテムが残っていること
        XCTAssertTrue(trashMgr.items.contains(where: { $0.id == trashItem.id }))
    }

    // MARK: - 5. フォールトインジェクション: 物理移動前の障害発生

    @MainActor
    func testFolderTrash_FaultInjection_CrashBeforePhysicalMove() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("FolderTrash_FIBeforeMove_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let trashContainer = tempRoot.appendingPathComponent("TrashContainer", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let dc = DownloadCenter()
        for v in dc.saved { dc.removeSavedVideoWithoutDeletingFile(id: v.id) }
        let fm = VideoFolderManager(downloads: dc)
        let defaults = UserDefaults(suiteName: "test.folder.fibefore.\(UUID().uuidString)")!
        let zipMgr = ZipArchiveManager(userDefaults: defaults, customDownloadsRootURL: downloadsDir)
        let trashMgr = TrashManager(customTrashDirectoryURL: trashContainer)

        let folderName = "ImportantData"
        let folderURL = downloadsDir.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try Data("Safe Payload".utf8).write(to: folderURL.appendingPathComponent("file.dat"))

        // 物理移動直前にエラー注入
        trashMgr.faultInjectionBeforePhysicalMove = {
            throw NSError(domain: "TestFault", code: 999, userInfo: [NSLocalizedDescriptionKey: "Simulated crash before physical move"])
        }

        let moveRes = await trashMgr.moveToTrash(
            folderName: folderName,
            downloads: dc,
            folderManager: fm,
            zipManager: zipMgr,
            customRootURL: downloadsDir
        )
        guard case .failure = moveRes else {
            XCTFail("Operation must fail when error is injected")
            return
        }

        // 移動元のフォルダとファイルが一切失われていないこと
        XCTAssertTrue(FileManager.default.fileExists(atPath: folderURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folderURL.appendingPathComponent("file.dat").path))
        XCTAssertEqual(trashMgr.items.count, 0)
    }

    // MARK: - 6. フォールトインジェクション: 物理移動後・メタデータ保存前の障害発生とリカバリ

    @MainActor
    func testFolderTrash_FaultInjection_CrashAfterPhysicalMoveBeforeMetadata() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("FolderTrash_FIAfterMove_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let trashContainer = tempRoot.appendingPathComponent("TrashContainer", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let dc = DownloadCenter()
        for v in dc.saved { dc.removeSavedVideoWithoutDeletingFile(id: v.id) }
        let fm = VideoFolderManager(downloads: dc)
        let defaults = UserDefaults(suiteName: "test.folder.fiafter.\(UUID().uuidString)")!
        let zipMgr = ZipArchiveManager(userDefaults: defaults, customDownloadsRootURL: downloadsDir)
        let trashMgr = TrashManager(customTrashDirectoryURL: trashContainer)

        let folderName = "RescueFolder"
        let folderURL = downloadsDir.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try Data("Rescue File".utf8).write(to: folderURL.appendingPathComponent("doc.txt"))

        // 物理移動完了後、メタデータコミット直前に強制クラッシュシミュレーション
        trashMgr.faultInjectionBeforeMetadataCommit = {
            throw NSError(domain: "TestFault", code: 998, userInfo: [NSLocalizedDescriptionKey: "Simulated crash after physical move"])
        }

        let moveRes = await trashMgr.moveToTrash(
            folderName: folderName,
            downloads: dc,
            folderManager: fm,
            zipManager: zipMgr,
            customRootURL: downloadsDir
        )
        guard case .failure = moveRes else {
            XCTFail("Operation must fail")
            return
        }

        // メタデータ失敗時は元のDownloadsへ即時安全ロールバックされること
        XCTAssertTrue(FileManager.default.fileExists(atPath: folderURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folderURL.appendingPathComponent("doc.txt").path))
    }

    // MARK: - 7. マニフェスト破損時の自動パージ除外保護

    @MainActor
    func testFolderTrash_CorruptedManifest_ExcludedFromAutoPurge() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("FolderTrash_CorruptManifest_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let trashContainer = tempRoot.appendingPathComponent("TrashContainer", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let dc = DownloadCenter()
        for v in dc.saved { dc.removeSavedVideoWithoutDeletingFile(id: v.id) }
        let fm = VideoFolderManager(downloads: dc)
        let defaults = UserDefaults(suiteName: "test.folder.corrupt.\(UUID().uuidString)")!
        let zipMgr = ZipArchiveManager(userDefaults: defaults, customDownloadsRootURL: downloadsDir)
        let trashMgr = TrashManager(customTrashDirectoryURL: trashContainer)

        let folderName = "CorruptedTarget"
        let folderURL = downloadsDir.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try Data("Payload".utf8).write(to: folderURL.appendingPathComponent("payload.bin"))

        let moveRes = await trashMgr.moveToTrash(
            folderName: folderName,
            downloads: dc,
            folderManager: fm,
            zipManager: zipMgr,
            customRootURL: downloadsDir
        )
        guard case .success(let trashItem) = moveRes else {
            XCTFail("Move failed")
            return
        }

        // マニフェストファイルを意図的に破損させる
        let itemDir = trashContainer.appendingPathComponent("Trash", isDirectory: true).appendingPathComponent(trashItem.id.uuidString, isDirectory: true)
        let manifestURL = itemDir.appendingPathComponent("folder_manifest.json")
        try Data("CORRUPTED_JSON_BYTES_NOT_VALID".utf8).write(to: manifestURL)

        // 保持期限切れをシミュレート
        let expiredItem = TrashItem(
            id: trashItem.id,
            originalVideoID: trashItem.originalVideoID,
            originalTitle: trashItem.originalTitle,
            originalRelativePath: trashItem.originalRelativePath,
            originalFolderName: trashItem.originalFolderName,
            format: trashItem.format,
            byteSize: trashItem.byteSize,
            sourceHost: trashItem.sourceHost,
            sourcePageURL: trashItem.sourcePageURL,
            deletedAt: Date().addingTimeInterval(-100000),
            expiresAt: Date().addingTimeInterval(-1000),
            fileName: trashItem.fileName,
            isFavorite: trashItem.isFavorite,
            payloadKind: .folder,
            fileExtension: trashItem.fileExtension,
            relativeSubpath: trashItem.relativeSubpath,
            folderItemCount: trashItem.folderItemCount
        )

        // 自動パージを実行
        trashMgr.purgeExpiredItems()

        // 待機
        try await Task.sleep(nanoseconds: 100_000_000)

        // マニフェストが破損しているフォルダは自動パージから厳格に除外され、物理データが残っていること！
        let folderInTrash = itemDir.appendingPathComponent(folderName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folderInTrash.path), "Corrupted folder must NEVER be auto-purged to protect user data")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folderInTrash.appendingPathComponent("payload.bin").path))
    }

    // MARK: - 8. フォルダの完全削除

    @MainActor
    func testFolderTrash_PermanentDelete_RemovesPhysicalAndManifest() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("FolderTrash_PermDelete_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let trashContainer = tempRoot.appendingPathComponent("TrashContainer", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let dc = DownloadCenter()
        for v in dc.saved { dc.removeSavedVideoWithoutDeletingFile(id: v.id) }
        let fm = VideoFolderManager(downloads: dc)
        let defaults = UserDefaults(suiteName: "test.folder.perm.\(UUID().uuidString)")!
        let zipMgr = ZipArchiveManager(userDefaults: defaults, customDownloadsRootURL: downloadsDir)
        let trashMgr = TrashManager(customTrashDirectoryURL: trashContainer)

        let folderName = "DeleteMe"
        let folderURL = downloadsDir.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try Data("Temp".utf8).write(to: folderURL.appendingPathComponent("temp.txt"))

        let moveRes = await trashMgr.moveToTrash(
            folderName: folderName,
            downloads: dc,
            folderManager: fm,
            zipManager: zipMgr,
            customRootURL: downloadsDir
        )
        guard case .success(let trashItem) = moveRes else {
            XCTFail("Move failed")
            return
        }

        let itemDir = trashContainer.appendingPathComponent("Trash", isDirectory: true).appendingPathComponent(trashItem.id.uuidString, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: itemDir.path))

        // 完全削除
        let delRes = await trashMgr.deletePermanently(item: trashItem)
        guard case .success = delRes else {
            XCTFail("Permanent deletion failed")
            return
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: itemDir.path), "Item directory must be completely removed")
        XCTAssertFalse(trashMgr.items.contains(where: { $0.id == trashItem.id }))
    }

    // MARK: - 9. アプリ再起動後の整合性回復

    @MainActor
    func testFolderTrash_PersistenceAcrossRestart() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("FolderTrash_Restart_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let trashContainer = tempRoot.appendingPathComponent("TrashContainer", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let dc = DownloadCenter()
        for v in dc.saved { dc.removeSavedVideoWithoutDeletingFile(id: v.id) }
        let fm = VideoFolderManager(downloads: dc)
        let defaults = UserDefaults(suiteName: "test.folder.restart.\(UUID().uuidString)")!
        let zipMgr = ZipArchiveManager(userDefaults: defaults, customDownloadsRootURL: downloadsDir)

        let trashMgrA = TrashManager(customTrashDirectoryURL: trashContainer)

        let folderName = "PersistFolder"
        let folderURL = downloadsDir.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try Data("Persistent Content".utf8).write(to: folderURL.appendingPathComponent("data.bin"))

        let moveRes = await trashMgrA.moveToTrash(
            folderName: folderName,
            downloads: dc,
            folderManager: fm,
            zipManager: zipMgr,
            customRootURL: downloadsDir
        )
        guard case .success(let trashItem) = moveRes else {
            XCTFail("Move failed")
            return
        }

        // アプリ再起動を模して別インスタンス初期化
        let trashMgrB = TrashManager(customTrashDirectoryURL: trashContainer)
        let reloadedItem = trashMgrB.items.first(where: { $0.id == trashItem.id })

        XCTAssertNotNil(reloadedItem)
        XCTAssertEqual(reloadedItem?.isFolder, true)
        XCTAssertEqual(reloadedItem?.originalTitle, folderName)

        let reloadedManifest = trashMgrB.loadFolderManifest(for: trashItem.id)
        XCTAssertNotNil(reloadedManifest)
        XCTAssertEqual(reloadedManifest?.originalFolderName, folderName)
    }

    // MARK: - 10. Private Vault領域への影響遮断（VaultフォルダはTrash拒絶）

    @MainActor
    func testFolderTrash_VaultFolderCannotBeTrashed() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("FolderTrash_Vault_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        let trashContainer = tempRoot.appendingPathComponent("TrashContainer", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let dc = DownloadCenter()
        let fm = VideoFolderManager(downloads: dc)
        let defaults = UserDefaults(suiteName: "test.folder.vault.\(UUID().uuidString)")!
        let zipMgr = ZipArchiveManager(userDefaults: defaults, customDownloadsRootURL: downloadsDir)
        let trashMgr = TrashManager(customTrashDirectoryURL: trashContainer)

        // Documents/PrivateVault/ 配下のフォルダ作成
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let vaultBase = docs.appendingPathComponent("PrivateVault", isDirectory: true)
        let vaultFolder = vaultBase.appendingPathComponent("SecretFolder", isDirectory: true)
        try? FileManager.default.createDirectory(at: vaultFolder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: vaultFolder)
            try? FileManager.default.removeItem(at: vaultBase)
        }

        let res = await trashMgr.moveToTrash(
            folderName: "SecretFolder",
            downloads: dc,
            folderManager: fm,
            zipManager: zipMgr,
            customRootURL: vaultBase
        )

        guard case .failure(let err) = res else {
            XCTFail("Operating on Vault path must fail")
            return
        }
        XCTAssertEqual((err as NSError).code, 403)
    }
}
