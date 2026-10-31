import Foundation

/// 既存のダウンロードエンジン（DownloadCenter）とは独立して、保存済み動画のフォルダ整理・名前変更・移動を管理する層。
/// - MP4 / MOV / M4V 等の直接ファイル: `Documents/Downloads/` 配下のサブフォルダへ実ファイルを移動・名前変更し、`SavedVideo.relativePath` を整合させる（iOS「ファイル」アプリからも閲覧可能）。
/// - HLS（`.movpkg`）: AVFoundationが保存したローカルパッケージの場所・`relativePath` は一切変更せず、アプリ内の論理フォルダ情報（メタデータ）のみを管理する。
final class VideoFolderManager: ObservableObject {
    static let shared = VideoFolderManager()

    enum FolderFilter: Hashable, Identifiable {
        case all
        case uncategorized
        case folder(String)

        var id: String {
            switch self {
            case .all: return "__all__"
            case .uncategorized: return "__uncategorized__"
            case .folder(let name): return "folder:\(name)"
            }
        }

        var title: String {
            switch self {
            case .all: return NSLocalizedString("All Videos", comment: "")
            case .uncategorized: return NSLocalizedString("Downloads (Uncategorized)", comment: "")
            case .folder(let name): return name
            }
        }
    }

    enum FolderError: LocalizedError {
        case emptyName
        case alreadyExists
        case fileOperationFailed(String)

        var errorDescription: String? {
            switch self {
            case .emptyName:
                return NSLocalizedString("Please enter a valid name.", comment: "")
            case .alreadyExists:
                return NSLocalizedString("A folder with the same name already exists.", comment: "")
            case .fileOperationFailed(let message):
                return message
            }
        }
    }

    @Published private(set) var folders: [String] = []
    /// `SavedVideo.id.uuidString` -> フォルダ名（空文字は未分類）
    @Published private(set) var folderMap: [String: String] = [:]

    private let downloads: DownloadCenter
    private var pendingJobFolders: [UUID: String] = [:]

    private static let foldersKey = "clipHarborFolderListV21"
    private static let folderMapKey = "clipHarborVideoFolderMapV21"
    private static let savedVideosKey = "clipHarborSavedVideosV2"

    init(downloads: DownloadCenter = .shared) {
        self.downloads = downloads
        _ = try? Self.ensureDownloadsDirectory()
        loadPersistedState()
        migrateLegacyFolderMetadataIfNeeded()
        syncWithFileSystemAndSavedVideos()

        if downloads.onVideoSaved == nil {
            downloads.onVideoSaved = { [weak self] jobID, video in
                self?.handleVideoSaved(jobID: jobID, video: video)
            }
        }
    }

    // MARK: - フォルダ・動画の参照

    /// 指定した動画の所属フォルダ名を返す（未分類の場合は `""`）
    func folderName(for video: SavedVideo) -> String {
        if let mapped = folderMap[video.id.uuidString], !mapped.isEmpty {
            return mapped
        }
        if !video.isHLS, let inferred = Self.inferSubfolder(fromRelativePath: video.relativePath) {
            return inferred
        }
        return ""
    }

    /// フィルタ条件に一致する保存済み動画一覧を返す
    func videos(in filter: FolderFilter) -> [SavedVideo] {
        downloads.saved.filter { video in
            let current = folderName(for: video)
            switch filter {
            case .all:
                return true
            case .uncategorized:
                return current.isEmpty
            case .folder(let target):
                return current == target
            }
        }
    }

    /// 特定フォルダ内の動画件数
    func videoCount(in filter: FolderFilter) -> Int {
        videos(in: filter).count
    }

    // MARK: - ダウンロード開始・完了時のフォルダ連携

    /// ダウンロード開始時にユーザーが選択した保存先フォルダを記録する
    func registerPendingFolder(_ rawFolderName: String, forJobID jobID: UUID) {
        let clean = Self.sanitizedFolderName(rawFolderName)
        guard !clean.isEmpty else {
            pendingJobFolders[jobID] = nil
            return
        }
        if !folders.contains(clean) {
            _ = createFolder(name: clean)
        }
        pendingJobFolders[jobID] = clean
    }

    /// DownloadCenter で保存が完了した直後に呼ばれ、必要に応じてフォルダ移動または論理フォルダ設定を行う
    private func handleVideoSaved(jobID: UUID, video: SavedVideo) {
        guard let targetFolder = pendingJobFolders.removeValue(forKey: jobID),
              !targetFolder.isEmpty else {
            return
        }
        _ = moveVideo(video, toFolder: targetFolder)
    }

    // MARK: - フォルダ作成・名前変更・削除

    @discardableResult
    func createFolder(name rawName: String) -> Result<String, FolderError> {
        let clean = Self.sanitizedFolderName(rawName)
        guard !clean.isEmpty else { return .failure(.emptyName) }
        if folders.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) {
            return .failure(.alreadyExists)
        }
        do {
            _ = try Self.ensureSubfolder(named: clean)
            folders.append(clean)
            folders.sort { $0.localizedStandardCompare($1) == .orderedAscending }
            persistState()
            return .success(clean)
        } catch {
            return .failure(.fileOperationFailed(NSLocalizedString("Failed to create folder.", comment: "")))
        }
    }

    @discardableResult
    func renameFolder(from oldName: String, to rawNewName: String) -> Result<String, FolderError> {
        let cleanOld = Self.sanitizedFolderName(oldName)
        let cleanNew = Self.sanitizedFolderName(rawNewName)
        guard !cleanOld.isEmpty, !cleanNew.isEmpty else { return .failure(.emptyName) }
        if cleanOld == cleanNew { return .success(cleanNew) }
        if folders.contains(where: { $0 != cleanOld && $0.caseInsensitiveCompare(cleanNew) == .orderedSame }) {
            return .failure(.alreadyExists)
        }

        do {
            let root = try Self.ensureDownloadsDirectory()
            let oldURL = root.appendingPathComponent(cleanOld, isDirectory: true)
            let newURL = root.appendingPathComponent(cleanNew, isDirectory: true)
            guard FileNaming.isDirectChild(oldURL, of: root),
                  FileNaming.isDirectChild(newURL, of: root) else {
                return .failure(.fileOperationFailed(NSLocalizedString("Invalid folder name.", comment: "")))
            }

            if FileManager.default.fileExists(atPath: oldURL.path) {
                if FileManager.default.fileExists(atPath: newURL.path) {
                    return .failure(.alreadyExists)
                }
                try FileManager.default.moveItem(at: oldURL, to: newURL)
            } else {
                try FileManager.default.createDirectory(at: newURL, withIntermediateDirectories: true)
            }

            // 直接ファイル（MP4等・サブフォルダ内ファイル含む）で対象フォルダ内に保存されているものの relativePath を更新
            let oldFolderPrefix = "Documents/Downloads/\(cleanOld)/"
            for video in downloads.saved where !video.isHLS {
                let currentFolder = folderName(for: video)
                if currentFolder == cleanOld {
                    let normRel = FileClassification.normalizedRelativePath(video.relativePath)
                    let relativeInsideFolder: String
                    if normRel.hasPrefix(oldFolderPrefix) {
                        relativeInsideFolder = String(normRel.dropFirst(oldFolderPrefix.count))
                    } else {
                        relativeInsideFolder = (video.relativePath as NSString).lastPathComponent
                    }
                    let updatedURL = newURL.appendingPathComponent(relativeInsideFolder)
                    if let rel = SavedVideo.relativePath(for: updatedURL) {
                        downloads.updateSavedVideo(id: video.id, relativePath: FileClassification.normalizedRelativePath(rel))
                    }
                }
            }

            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    ZipArchiveManager.shared.handleFolderRenamed(from: cleanOld, to: cleanNew)
                }
            }

            // 論理フォルダマップ（MP4・HLS共通）を更新
            for (videoID, mappedFolder) in folderMap where mappedFolder == cleanOld {
                folderMap[videoID] = cleanNew
            }
            for video in downloads.saved where folderName(for: video) == cleanOld {
                folderMap[video.id.uuidString] = cleanNew
            }

            folders.removeAll { $0 == cleanOld }
            if !folders.contains(cleanNew) {
                folders.append(cleanNew)
            }
            folders.sort { $0.localizedStandardCompare($1) == .orderedAscending }
            persistState()
            return .success(cleanNew)
        } catch {
            return .failure(.fileOperationFailed(NSLocalizedString("Failed to rename folder.", comment: "")))
        }
    }

    /// テスト環境（カスタムDownloadsルート）等で物理ディレクトリ作成を伴わずにトップレベル論理フォルダ名を登録する
    func registerLogicalFolderIfNeeded(_ rawName: String) {
        let clean = Self.sanitizedFolderName(rawName)
        guard !clean.isEmpty else { return }
        if !folders.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) {
            folders.append(clean)
            folders.sort { $0.localizedStandardCompare($1) == .orderedAscending }
            persistState()
        }
    }

    /// 新規作成フォルダへの移動失敗クリーンアップ時等に、論理フォルダの登録を解除する
    func unregisterLogicalFolderIfNeeded(_ rawName: String) {
        let clean = Self.sanitizedFolderName(rawName)
        guard !clean.isEmpty else { return }
        if folders.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) {
            folders.removeAll { $0.caseInsensitiveCompare(clean) == .orderedSame }
            persistState()
        }
    }

    /// フォルダ削除時の退避計画レコード（事前計画・移動確認・逆順ロールバック用）
    private struct FolderEvacuationRecord {
        enum ItemKind {
            case savedVideo(UUID)
            case managedFile(UUID)
            case unregisteredFile
        }
        let kind: ItemKind
        let sourceURL: URL
        let destinationURL: URL
        let destinationRelativePath: String
        let destinationTitle: String
    }

    /// フォルダを削除する（中の動画・一般ファイル・未登録ファイルは削除せず、Downloads（未分類）へ安全に退避する）
    /// - 退避対象ファイルと移動元・移動先パスを事前に記録し、全件の移動結果を検証する。
    /// - 移動APIがエラーを返した場合でも実ファイルの所在地を確認し、移動が成立していた分も含めて逆順ロールバック対象とする。
    /// - 移動失敗・ディレクトリ読み取り失敗・残存ファイル検出・物理フォルダ削除失敗のいずれにおいても、統一されたロールバック＆所在地確認＆メタデータ整合処理を実行し、論理フォルダ情報を削除せず保持してUIへ通知する。
    @discardableResult
    func deleteFolder(
        name rawName: String,
        customRootURL: URL? = nil,
        zipManager: ZipArchiveManager? = nil,
        fileMover: ((URL, URL) throws -> Void)? = nil,
        rollbackMover: ((URL, URL) throws -> Void)? = nil,
        directoryReader: ((URL) throws -> [String])? = nil,
        folderRemover: ((URL) throws -> Void)? = nil
    ) -> Result<Void, FolderError> {
        let clean = Self.sanitizedFolderName(rawName)
        guard !clean.isEmpty else { return .failure(.emptyName) }

        let root: URL
        do {
            if let customRoot = customRootURL {
                try FileManager.default.createDirectory(at: customRoot, withIntermediateDirectories: true)
                root = customRoot
            } else {
                root = try Self.ensureDownloadsDirectory()
            }
        } catch {
            return .failure(.fileOperationFailed(NSLocalizedString("Failed to access Downloads directory.", comment: "")))
        }

        let folderURL = root.appendingPathComponent(clean, isDirectory: true)
        guard FileNaming.isDirectChild(folderURL, of: root) else {
            return .failure(.fileOperationFailed(NSLocalizedString("Invalid folder name.", comment: "")))
        }

        let fm = FileManager.default
        let performMove: (URL, URL) throws -> Void = fileMover ?? { src, dst in
            try fm.moveItem(at: src, to: dst)
        }
        let performRollbackMove: (URL, URL) throws -> Void = rollbackMover ?? { src, dst in
            try fm.moveItem(at: src, to: dst)
        }
        let performReadDirectory: (URL) throws -> [String] = directoryReader ?? { dirURL in
            try fm.contentsOfDirectory(atPath: dirURL.path)
        }
        let performFolderRemove: (URL) throws -> Void = folderRemover ?? { dirURL in
            try fm.removeItem(at: dirURL)
        }

        // 1. 事前計画フェーズ：退避対象ファイル（SavedVideo / ManagedFileItem / 未登録物理ファイル）と一意の移動先URLを記録
        var reservedDestPathsLower: Set<String> = []
        var plannedSourceCanonicalPaths: Set<String> = []
        var plannedRecords: [FolderEvacuationRecord] = []
        var hlsVideoIDsToUnmap: [UUID] = []

        func allocateUniqueDestination(baseName: String, ext: String) -> URL {
            let safeBase = FileNaming.sanitizedBaseName(baseName).isEmpty ? "File" : FileNaming.sanitizedBaseName(baseName)
            let cleanExt = ext.trimmingCharacters(in: CharacterSet(charactersIn: "."))

            func makeCandidate(_ name: String) -> URL {
                if cleanExt.isEmpty {
                    return root.appendingPathComponent(name, isDirectory: false)
                } else {
                    return root.appendingPathComponent(name, isDirectory: false).appendingPathExtension(cleanExt)
                }
            }

            let first = makeCandidate(safeBase)
            let firstKey = first.standardizedFileURL.path.lowercased()
            if !fm.fileExists(atPath: first.path) && !reservedDestPathsLower.contains(firstKey) {
                reservedDestPathsLower.insert(firstKey)
                return first
            }

            for index in 1...9999 {
                let candidate = makeCandidate("\(safeBase) (\(index))")
                let key = candidate.standardizedFileURL.path.lowercased()
                if !fm.fileExists(atPath: candidate.path) && !reservedDestPathsLower.contains(key) {
                    reservedDestPathsLower.insert(key)
                    return candidate
                }
            }

            let fallback = makeCandidate("\(safeBase)_\(UUID().uuidString.prefix(6))")
            reservedDestPathsLower.insert(fallback.standardizedFileURL.path.lowercased())
            return fallback
        }

        func resolveSourceVideoURL(_ video: SavedVideo) -> URL {
            if let customRoot = customRootURL {
                let norm = FileClassification.normalizedRelativePath(video.relativePath)
                let prefix = "Documents/Downloads/"
                if norm.hasPrefix(prefix) {
                    let subRel = String(norm.dropFirst(prefix.count))
                    return customRoot.appendingPathComponent(subRel)
                }
            }
            return video.fileURL
        }

        // 1-A. 登録済み SavedVideo の計画
        let affectedVideos = downloads.saved.filter { folderName(for: $0) == clean }
        for video in affectedVideos {
            if video.isHLS {
                hlsVideoIDsToUnmap.append(video.id)
                continue
            }
            let srcURL = resolveSourceVideoURL(video)
            guard fm.fileExists(atPath: srcURL.path) else {
                return .failure(.fileOperationFailed(NSLocalizedString("Source file not found.", comment: "")))
            }
            let ext = srcURL.pathExtension.isEmpty ? video.format.rawValue : srcURL.pathExtension
            let destURL = allocateUniqueDestination(baseName: video.title, ext: ext)
            guard let destRel = FileClassification.normalizedContainerRelativePath(for: destURL, customRootURL: customRootURL) else {
                return .failure(.fileOperationFailed(NSLocalizedString("Destination path is invalid.", comment: "")))
            }
            let canonSrc = srcURL.standardizedFileURL.resolvingSymlinksInPath().path
            plannedSourceCanonicalPaths.insert(canonSrc)
            plannedRecords.append(FolderEvacuationRecord(
                kind: .savedVideo(video.id),
                sourceURL: srcURL,
                destinationURL: destURL,
                destinationRelativePath: destRel,
                destinationTitle: destURL.deletingPathExtension().lastPathComponent
            ))
        }

        // 1-B. 登録済み ManagedFileItem の計画
        let resolvedZipMgr: ZipArchiveManager? = zipManager ?? (Thread.isMainThread ? MainActor.assumeIsolated { ZipArchiveManager.shared } : nil)
        if let zMgr = resolvedZipMgr {
            let affectedManaged: [ManagedFileItem] = MainActor.assumeIsolated {
                zMgr.managedFiles.filter { $0.folderName == clean }
            }
            for item in affectedManaged {
                let srcURL: URL = MainActor.assumeIsolated { zMgr.resolveFileURL(for: item) }
                guard fm.fileExists(atPath: srcURL.path) else {
                    return .failure(.fileOperationFailed(NSLocalizedString("Source file not found.", comment: "")))
                }
                let canonSrc = srcURL.standardizedFileURL.resolvingSymlinksInPath().path
                guard !plannedSourceCanonicalPaths.contains(canonSrc) else { continue }

                let destURL = allocateUniqueDestination(baseName: item.title, ext: item.fileExtension)
                guard let destRel = FileClassification.normalizedContainerRelativePath(for: destURL, customRootURL: customRootURL) else {
                    return .failure(.fileOperationFailed(NSLocalizedString("Destination path is invalid.", comment: "")))
                }
                plannedSourceCanonicalPaths.insert(canonSrc)
                plannedRecords.append(FolderEvacuationRecord(
                    kind: .managedFile(item.id),
                    sourceURL: srcURL,
                    destinationURL: destURL,
                    destinationRelativePath: destRel,
                    destinationTitle: destURL.deletingPathExtension().lastPathComponent
                ))
            }
        }

        // 1-C. フォルダ内の未登録物理ファイル・既存サブディレクトリ構造（空サブフォルダ含む）・シンボリックリンク有無の事前走査
        var preExistingSubdirectoryURLs: [URL] = []
        if fm.fileExists(atPath: folderURL.path) {
            // ディレクトリ読み取り失敗を「空」と誤認しないよう明示的に検証
            do {
                _ = try performReadDirectory(folderURL)
            } catch {
                return .failure(.fileOperationFailed(
                    String(format: NSLocalizedString("Failed to read contents of folder \"%@\". The folder was not deleted.", comment: ""), clean)
                ))
            }

            var enumerationErrorOccurred = false
            let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            guard let enumerator = fm.enumerator(
                at: folderURL,
                includingPropertiesForKeys: keys,
                options: [],
                errorHandler: { _, _ in
                    enumerationErrorOccurred = true
                    return false
                }
            ) else {
                return .failure(.fileOperationFailed(
                    String(format: NSLocalizedString("Failed to read contents of folder \"%@\". The folder was not deleted.", comment: ""), clean)
                ))
            }

            for case let itemURL as URL in enumerator {
                let vals: URLResourceValues
                do {
                    vals = try itemURL.resourceValues(forKeys: Set(keys))
                } catch {
                    return .failure(.fileOperationFailed(
                        String(format: NSLocalizedString("Failed to read contents of folder \"%@\". The folder was not deleted.", comment: ""), clean)
                    ))
                }

                let nameLower = itemURL.lastPathComponent.lowercased()
                if nameLower == ".ds_store" || nameLower == "__macosx" {
                    if vals.isDirectory == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                // シンボリックリンクが含まれている場合は勝手に削除せず中止
                if vals.isSymbolicLink == true {
                    return .failure(.fileOperationFailed(
                        NSLocalizedString("Cannot delete folder because it contains an unsupported symbolic link.", comment: "")
                    ))
                }
                if vals.isDirectory == true {
                    // サブディレクトリ自体も読み取り可能であることを確認し、ロールバック時の階層復元用に記録（空サブフォルダも含む）
                    do {
                        _ = try performReadDirectory(itemURL)
                    } catch {
                        return .failure(.fileOperationFailed(
                            String(format: NSLocalizedString("Failed to read contents of folder \"%@\". The folder was not deleted.", comment: ""), clean)
                        ))
                    }
                    preExistingSubdirectoryURLs.append(itemURL)
                }
                if vals.isRegularFile == true {
                    let canonSrc = itemURL.standardizedFileURL.resolvingSymlinksInPath().path
                    if !plannedSourceCanonicalPaths.contains(canonSrc) {
                        let base = itemURL.deletingPathExtension().lastPathComponent
                        let ext = itemURL.pathExtension
                        let destURL = allocateUniqueDestination(baseName: base.isEmpty ? "File" : base, ext: ext)
                        guard let destRel = FileClassification.normalizedContainerRelativePath(for: destURL, customRootURL: customRootURL) else {
                            return .failure(.fileOperationFailed(NSLocalizedString("Destination path is invalid.", comment: "")))
                        }
                        plannedSourceCanonicalPaths.insert(canonSrc)
                        plannedRecords.append(FolderEvacuationRecord(
                            kind: .unregisteredFile,
                            sourceURL: itemURL,
                            destinationURL: destURL,
                            destinationRelativePath: destRel,
                            destinationTitle: destURL.deletingPathExtension().lastPathComponent
                        ))
                    }
                }
            }

            if enumerationErrorOccurred {
                return .failure(.fileOperationFailed(
                    String(format: NSLocalizedString("Failed to read contents of folder \"%@\". The folder was not deleted.", comment: ""), clean)
                ))
            }
        }

        // 統一された逆順ロールバック＆サブフォルダ階層復元＆実ファイル所在地確認＆メタデータ整合ルーチン
        func rollbackAndReconcile(
            recordsToRollback: [FolderEvacuationRecord],
            defaultCompleteRollbackMessage: String
        ) -> Result<Void, FolderError> {
            // A-1. 既存のすべてのサブディレクトリ（空サブフォルダ含む）を復元
            for subDirURL in preExistingSubdirectoryURLs {
                try? fm.createDirectory(at: subDirURL, withIntermediateDirectories: true)
            }

            // A-2. 逆順でファイル移動のロールバックを試行
            // 注意: 移動元と移動先の両方にファイルが存在する場合は、勝手にどちらかを削除せず両方保持する
            for doneRecord in recordsToRollback.reversed() {
                let srcExists = fm.fileExists(atPath: doneRecord.sourceURL.path)
                let dstExists = fm.fileExists(atPath: doneRecord.destinationURL.path)
                if dstExists && !srcExists {
                    let parentDir = doneRecord.sourceURL.deletingLastPathComponent()
                    try? fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
                    try? performRollbackMove(doneRecord.destinationURL, doneRecord.sourceURL)
                }
            }

            // B. 全計画レコードの実ファイルの実際の所在地を確認（ロールバック成否・競合・消失を実ファイル基準で確定）
            var actuallyMovedToUncategorized: [FolderEvacuationRecord] = []
            var bothExistConflictRecords: [FolderEvacuationRecord] = []
            var missingBothRecords: [FolderEvacuationRecord] = []
            var remainingInFolderCount = 0

            for record in plannedRecords {
                let atSource = fm.fileExists(atPath: record.sourceURL.path)
                let atDest = fm.fileExists(atPath: record.destinationURL.path)
                if !atSource && atDest {
                    actuallyMovedToUncategorized.append(record)
                } else if atSource && atDest {
                    // 移動元と移動先の両方に存在（競合状態：両方とも削除せず保持）
                    bothExistConflictRecords.append(record)
                    remainingInFolderCount += 1
                } else if !atSource && !atDest {
                    // 移動元にも移動先にも存在しない異常状態
                    missingBothRecords.append(record)
                } else {
                    remainingInFolderCount += 1
                }
            }

            // C. ロールバックが一部失敗し Downloads 直下にのみ移動したファイルがある場合は、IDを維持したまま未分類へメタデータを整合
            var hadMovedUnregistered = false
            if !actuallyMovedToUncategorized.isEmpty {
                for moved in actuallyMovedToUncategorized {
                    switch moved.kind {
                    case .savedVideo(let videoID):
                        downloads.updateSavedVideo(
                            id: videoID,
                            title: moved.destinationTitle,
                            relativePath: moved.destinationRelativePath
                        )
                        folderMap[videoID.uuidString] = nil
                    case .managedFile(let itemID):
                        if let zMgr = resolvedZipMgr {
                            MainActor.assumeIsolated {
                                zMgr.applyEvacuatedManagedFileUpdate(
                                    id: itemID,
                                    newTitle: moved.destinationTitle,
                                    newRelativePath: moved.destinationRelativePath
                                )
                            }
                        }
                    case .unregisteredFile:
                        hadMovedUnregistered = true
                    }
                }
                persistState()
            }

            // 競合ファイル（移動先に複製されたファイル）や移動済み未登録ファイルを見失わないようファイルシステム同期を実行
            if (hadMovedUnregistered || !bothExistConflictRecords.isEmpty), let zMgr = resolvedZipMgr {
                MainActor.assumeIsolated {
                    zMgr.syncWithFileSystem(downloads: downloads, folderManager: self)
                }
            }

            // D-1. 移動元・移動先の両方にファイルが存在する競合状態の通知（両方保持）
            if !bothExistConflictRecords.isEmpty {
                let conflictMsg = String(
                    format: NSLocalizedString("Failed to delete folder \"%@\" due to a file conflict (files exist in both original and destination locations). Both files and the folder were kept to protect your data.", comment: ""),
                    clean
                )
                return .failure(.fileOperationFailed(conflictMsg))
            }

            // D-2. 移動元・移動先の両方でファイルが確認できない異常状態の通知（フォルダ保持）
            if !missingBothRecords.isEmpty {
                let missingMsg = String(
                    format: NSLocalizedString("Failed to delete folder \"%@\" because an expected file could not be verified at either source or destination. The folder was kept to protect your data.", comment: ""),
                    clean
                )
                return .failure(.fileOperationFailed(missingMsg))
            }

            // D-3. 部分移動状態の通知
            if !actuallyMovedToUncategorized.isEmpty {
                let movedCount = actuallyMovedToUncategorized.count
                let remCount = max(1, remainingInFolderCount)
                let partialMsg = String(
                    format: NSLocalizedString("Failed to delete folder \"%@\". %lld files moved to Uncategorized, and %lld files remain in the folder. The folder was kept to protect your data.", comment: ""),
                    clean, movedCount, remCount
                )
                return .failure(.fileOperationFailed(partialMsg))
            }

            // D-4. 全ファイルおよび空サブフォルダが元のフォルダ内に完全復元・保持されている場合
            return .failure(.fileOperationFailed(defaultCompleteRollbackMessage))
        }

        // 2. 移動実行と結果確認フェーズ（移動APIがエラーを投げた場合も途中まで成立していないか実ファイルの存在を確認）
        var touchedRecords: [FolderEvacuationRecord] = []
        var moveFailed = false

        for record in plannedRecords {
            do {
                try performMove(record.sourceURL, record.destinationURL)
                let dstExists = fm.fileExists(atPath: record.destinationURL.path)
                let srcExists = fm.fileExists(atPath: record.sourceURL.path)
                if dstExists || !srcExists {
                    touchedRecords.append(record)
                }
                guard dstExists && !srcExists else {
                    moveFailed = true
                    break
                }
            } catch {
                // エラー発生時も、ファイル移動が実際には成立している（または移動元・移動先の状態が変化した）か確認
                let dstExists = fm.fileExists(atPath: record.destinationURL.path)
                let srcExists = fm.fileExists(atPath: record.sourceURL.path)
                if dstExists || !srcExists {
                    touchedRecords.append(record)
                }
                moveFailed = true
                break
            }
        }

        // 3. 移動失敗時の逆順ロールバック＆整合フェーズ
        if moveFailed {
            let defaultMsg = String(
                format: NSLocalizedString("Failed to move some files out of folder \"%@\". All changes were rolled back and the folder was kept to protect your data.", comment: ""),
                clean
            )
            return rollbackAndReconcile(
                recordsToRollback: touchedRecords,
                defaultCompleteRollbackMessage: defaultMsg
            )
        }

        // 4. 全件移動成功後の最終確認・物理フォルダ削除フェーズ
        if fm.fileExists(atPath: folderURL.path) {
            Self.removeEmptySubdirectoriesRecursively(inside: folderURL)

            // ディレクトリ読み取り失敗を「空」と扱わず、失敗時はロールバック＆整合処理へ移行
            let firstListing: [String]
            do {
                firstListing = try performReadDirectory(folderURL)
            } catch {
                let readErrMsg = String(
                    format: NSLocalizedString("Failed to verify contents of folder \"%@\". All changes were rolled back and the folder was kept to protect your data.", comment: ""),
                    clean
                )
                return rollbackAndReconcile(
                    recordsToRollback: touchedRecords,
                    defaultCompleteRollbackMessage: readErrMsg
                )
            }

            for meta in firstListing where meta == ".DS_Store" || meta == "__MACOSX" {
                try? fm.removeItem(at: folderURL.appendingPathComponent(meta))
            }

            let secondListing: [String]
            do {
                secondListing = try performReadDirectory(folderURL)
            } catch {
                let readErrMsg = String(
                    format: NSLocalizedString("Failed to verify contents of folder \"%@\". All changes were rolled back and the folder was kept to protect your data.", comment: ""),
                    clean
                )
                return rollbackAndReconcile(
                    recordsToRollback: touchedRecords,
                    defaultCompleteRollbackMessage: readErrMsg
                )
            }

            let unexpectedRemaining = secondListing.filter {
                $0 != ".DS_Store" && $0 != "__MACOSX"
            }
            if !unexpectedRemaining.isEmpty {
                // 予期しない残存ファイルを検出した場合も、統一されたロールバック＆実ファイル所在地確認＆メタデータ整合を実行
                let remainingMsg = String(
                    format: NSLocalizedString("Failed to delete folder \"%@\" because some files still remain inside.", comment: ""),
                    clean
                )
                return rollbackAndReconcile(
                    recordsToRollback: touchedRecords,
                    defaultCompleteRollbackMessage: remainingMsg
                )
            }

            // 物理フォルダの削除を実行し、結果を明示的に確認（失敗時は論理フォルダ情報を削除せずロールバック）
            do {
                try performFolderRemove(folderURL)
                guard !fm.fileExists(atPath: folderURL.path) else {
                    let removeFailMsg = String(
                        format: NSLocalizedString("Failed to remove folder \"%@\" from storage. All changes were rolled back and the folder was kept.", comment: ""),
                        clean
                    )
                    return rollbackAndReconcile(
                        recordsToRollback: touchedRecords,
                        defaultCompleteRollbackMessage: removeFailMsg
                    )
                }
            } catch {
                let removeFailMsg = String(
                    format: NSLocalizedString("Failed to remove folder \"%@\" from storage. All changes were rolled back and the folder was kept.", comment: ""),
                    clean
                )
                return rollbackAndReconcile(
                    recordsToRollback: touchedRecords,
                    defaultCompleteRollbackMessage: removeFailMsg
                )
            }
        }

        // 5. 全ファイルの移動と物理フォルダ削除の完了が確認できたため、インデックスとフォルダ管理情報を確定更新
        var hadUnregisteredFiles = false
        for record in touchedRecords {
            switch record.kind {
            case .savedVideo(let videoID):
                downloads.updateSavedVideo(
                    id: videoID,
                    title: record.destinationTitle,
                    relativePath: record.destinationRelativePath
                )
                folderMap[videoID.uuidString] = nil
            case .managedFile(let itemID):
                if let zMgr = resolvedZipMgr {
                    MainActor.assumeIsolated {
                        zMgr.applyEvacuatedManagedFileUpdate(
                            id: itemID,
                            newTitle: record.destinationTitle,
                            newRelativePath: record.destinationRelativePath
                        )
                    }
                }
            case .unregisteredFile:
                hadUnregisteredFiles = true
            }
        }

        for hlsID in hlsVideoIDsToUnmap {
            folderMap[hlsID.uuidString] = nil
        }
        for (videoID, mappedFolder) in folderMap where mappedFolder == clean {
            folderMap[videoID] = nil
        }
        folders.removeAll { $0 == clean }
        persistState()

        if hadUnregisteredFiles, let zMgr = resolvedZipMgr {
            MainActor.assumeIsolated {
                zMgr.syncWithFileSystem(downloads: downloads, folderManager: self)
            }
        }

        return .success(())
    }

    // MARK: - 動画のフォルダ移動・名前変更・削除

    /// 動画を指定フォルダへ移動する（`rawFolderName` が空文字なら未分類 `Downloads` へ戻す）
    @discardableResult
    func moveVideo(_ video: SavedVideo, toFolder rawFolderName: String) -> Result<Void, FolderError> {
        let cleanFolder = Self.sanitizedFolderName(rawFolderName)
        if !cleanFolder.isEmpty && !folders.contains(cleanFolder) {
            switch createFolder(name: cleanFolder) {
            case .success:
                break
            case .failure(let err):
                return .failure(err)
            }
        }

        // HLS動画は AVFoundation の保存場所（.movpkg）を絶対に変更せず、論理フォルダ情報のみ更新する
        if video.isHLS {
            if cleanFolder.isEmpty {
                folderMap[video.id.uuidString] = nil
            } else {
                folderMap[video.id.uuidString] = cleanFolder
            }
            persistState()
            return .success(())
        }

        // MP4 / MOV / M4V 等の直接ファイルは Documents/Downloads 配下の対象フォルダへ実ファイルを移動する
        do {
            let root = try Self.ensureDownloadsDirectory()
            let targetDir = try cleanFolder.isEmpty
                ? root
                : Self.ensureSubfolder(named: cleanFolder)

            let currentURL = video.fileURL
            let currentParent = currentURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
            let targetParent = targetDir.standardizedFileURL.resolvingSymlinksInPath().path

            if currentParent != targetParent {
                guard FileManager.default.fileExists(atPath: currentURL.path) else {
                    return .failure(.fileOperationFailed(NSLocalizedString("Source file not found.", comment: "")))
                }
                let ext = currentURL.pathExtension.isEmpty ? video.format.rawValue : currentURL.pathExtension
                let base = FileNaming.sanitizedBaseName(video.title)
                let destURL = FileNaming.uniqueDestination(
                    in: targetDir,
                    baseName: base.isEmpty ? "Video" : base,
                    fileExtension: ext
                )
                guard FileNaming.isDirectChild(destURL, of: targetDir),
                      Self.isDescendant(destURL, of: root),
                      let rel = SavedVideo.relativePath(for: destURL) else {
                    return .failure(.fileOperationFailed(NSLocalizedString("Destination path is invalid.", comment: "")))
                }
                try FileManager.default.moveItem(at: currentURL, to: destURL)
                downloads.updateSavedVideo(id: video.id, relativePath: FileClassification.normalizedRelativePath(rel))
                // 移動元がサブフォルダ内のネスト階層で空になった場合、親の管理フォルダ直下まで空ディレクトリを掃除
                let oldFolder = folderName(for: video)
                if !oldFolder.isEmpty {
                    let oldTopFolderURL = root.appendingPathComponent(oldFolder, isDirectory: true)
                    Self.removeEmptySubdirectoriesRecursively(inside: oldTopFolderURL)
                }
            }

            if cleanFolder.isEmpty {
                folderMap[video.id.uuidString] = nil
            } else {
                folderMap[video.id.uuidString] = cleanFolder
            }
            persistState()
            return .success(())
        } catch {
            return .failure(.fileOperationFailed(NSLocalizedString("Failed to move file.", comment: "")))
        }
    }

    /// 動画の表示名・ファイル名を変更する
    @discardableResult
    func renameVideo(_ video: SavedVideo, to rawNewTitle: String) -> Result<Void, FolderError> {
        let cleanTitle = FileNaming.sanitizedBaseName(rawNewTitle)
        guard !cleanTitle.isEmpty else { return .failure(.emptyName) }

        // HLS動画は .movpkg の場所・パスを変更せず、表示タイトルのみ変更する
        if video.isHLS {
            VideoThumbnailManager.shared.invalidateCache(for: video)
            downloads.updateSavedVideo(id: video.id, title: cleanTitle)
            return .success(())
        }

        // MP4 / MOV / M4V 等の直接ファイルは現在のフォルダ内で実ファイル名も変更する
        do {
            let root = try Self.ensureDownloadsDirectory()
            let currentURL = video.fileURL
            let parentDir = currentURL.deletingLastPathComponent()
            let ext = currentURL.pathExtension.isEmpty ? video.format.rawValue : currentURL.pathExtension
            let desiredFileName = "\(cleanTitle).\(ext)"

            if currentURL.lastPathComponent != desiredFileName && FileManager.default.fileExists(atPath: currentURL.path) {
                let destURL = FileNaming.uniqueDestination(in: parentDir, baseName: cleanTitle, fileExtension: ext)
                guard FileNaming.isDirectChild(destURL, of: parentDir),
                      Self.isDescendant(destURL, of: root),
                      let rel = SavedVideo.relativePath(for: destURL) else {
                    return .failure(.fileOperationFailed(NSLocalizedString("Invalid file name.", comment: "")))
                }
                try FileManager.default.moveItem(at: currentURL, to: destURL)
                VideoThumbnailManager.shared.invalidateCache(for: video)
                downloads.updateSavedVideo(id: video.id, title: cleanTitle, relativePath: rel)
                return .success(())
            }

            VideoThumbnailManager.shared.invalidateCache(for: video)
            downloads.updateSavedVideo(id: video.id, title: cleanTitle)
            return .success(())
        } catch {
            return .failure(.fileOperationFailed(NSLocalizedString("Failed to rename.", comment: "")))
        }
    }

    /// 動画・画像のお気に入り状態を切り替える（正本配列に基づいてトグルし、新状態を返す）
    @discardableResult
    func toggleFavorite(for video: SavedVideo) throws -> Bool {
        try downloads.toggleFavorite(id: video.id)
    }

    /// 動画を削除する
    func deleteVideo(_ video: SavedVideo) {
        VideoThumbnailManager.shared.invalidateCache(for: video)
        folderMap[video.id.uuidString] = nil
        persistState()
        downloads.delete(video)
    }

    /// ゴミ箱移動時に論理フォルダマップから除外する
    func removeVideoFromFolder(videoID: UUID) {
        folderMap[videoID.uuidString] = nil
        persistState()
    }

    /// ゴミ箱復元時に論理フォルダマップを再設定する
    func restoreVideoToFolder(_ video: SavedVideo, targetFolder: String) {
        let clean = Self.sanitizedFolderName(targetFolder)
        if !clean.isEmpty {
            if !folders.contains(clean) {
                _ = createFolder(name: clean)
            }
            folderMap[video.id.uuidString] = clean
            persistState()
        }
    }

    /// 動画・画像の所属フォルダを論理マップに登録・保存する
    func setFolderName(_ folderName: String, for video: SavedVideo) {
        restoreVideoToFolder(video, targetFolder: folderName)
    }

    /// ファイルシステム上のサブフォルダと保存済み動画・一般ファイル一覧を再スキャンして同期する
    func syncWithFileSystemAndSavedVideos() {
        // 未登録メディア（画像・展開された動画）の安全な自動スキャン・インデックス
        scanAndRegisterUnmanagedImages()

        if Thread.isMainThread {
            MainActor.assumeIsolated {
                ZipArchiveManager.shared.syncWithFileSystem(downloads: self.downloads, folderManager: self)
            }
        }

        var folderSet = Set(folders)

        if let root = try? Self.ensureDownloadsDirectory(),
           let contents = try? FileManager.default.contentsOfDirectory(
               at: root,
               includingPropertiesForKeys: [.isDirectoryKey],
               options: [.skipsHiddenFiles]
           ) {
            for url in contents {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    let name = url.lastPathComponent
                    guard !name.lowercased().hasSuffix(".movpkg"), name != "__MACOSX" else { continue }
                    let clean = Self.sanitizedFolderName(name)
                    if !clean.isEmpty {
                        folderSet.insert(clean)
                    }
                }
            }
        }

        var changedMap = false
        for video in downloads.saved {
            if !video.isHLS, let sub = Self.inferSubfolder(fromRelativePath: video.relativePath) {
                folderSet.insert(sub)
                if folderMap[video.id.uuidString] != sub {
                    folderMap[video.id.uuidString] = sub
                    changedMap = true
                }
            } else if let mapped = folderMap[video.id.uuidString], !mapped.isEmpty {
                folderSet.insert(mapped)
            }
        }

        if Thread.isMainThread {
            MainActor.assumeIsolated {
                for item in ZipArchiveManager.shared.managedFiles where !item.folderName.isEmpty {
                    folderSet.insert(item.folderName)
                }
            }
        }

        let sorted = folderSet.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        if sorted != folders || changedMap {
            folders = sorted
            persistState()
        }
    }

    /// Documents/Downloads 直下およびそのサブフォルダ（多階層含む）内の未登録メディア（画像・展開動画）を検出し、SavedVideoとして登録
    func scanAndRegisterUnmanagedImages() {
        guard let root = try? Self.ensureDownloadsDirectory() else { return }
        let fileManager = FileManager.default

        // 既存の登録済み相対パス・URLパスのセット
        var existingPaths = Set(downloads.saved.map { FileClassification.normalizedRelativePath($0.relativePath) })
        var existingFullPaths = Set(downloads.saved.map { $0.fileURL.standardizedFileURL.resolvingSymlinksInPath().path })

        // Documents/Downloads 配下を再帰走査（.movpkg と __MACOSX はスキップ）
        if let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            while let fileURL = enumerator.nextObject() as? URL {
                let last = fileURL.lastPathComponent
                if last == "__MACOSX" || last.lowercased().hasSuffix(".movpkg") || last.hasPrefix(".") {
                    enumerator.skipDescendants()
                    continue
                }
                let vals = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                if vals?.isSymbolicLink == true || vals?.isDirectory == true {
                    continue
                }
                if vals?.isRegularFile == true {
                    let rel = SavedVideo.relativePath(for: fileURL) ?? ""
                    let inferredFolder = Self.inferSubfolder(fromRelativePath: rel) ?? ""
                    processCandidateFile(
                        fileURL,
                        folderName: inferredFolder,
                        existingPaths: &existingPaths,
                        existingFullPaths: &existingFullPaths
                    )
                }
            }
        }

        // Documents直下にユーザーが配置した画像・メディアファイルもチェック
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let docsFiles = try? fileManager.contentsOfDirectory(
            at: docs,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) {
            for file in docsFiles {
                let vals = try? file.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                if vals?.isSymbolicLink == true || vals?.isDirectory == true {
                    continue
                }
                if vals?.isRegularFile == true {
                    processCandidateFile(
                        file,
                        folderName: "",
                        existingPaths: &existingPaths,
                        existingFullPaths: &existingFullPaths
                    )
                }
            }
        }
    }

    private func processCandidateFile(
        _ fileURL: URL,
        folderName: String,
        existingPaths: inout Set<String>,
        existingFullPaths: inout Set<String>
    ) {
        guard case .media(let format) = FileClassification.classify(url: fileURL) else { return }

        // シンボリックリンクや隠しファイルを除外
        guard !fileURL.lastPathComponent.hasPrefix(".") else { return }
        let standardizedPath = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard !existingFullPaths.contains(standardizedPath) else { return }
        guard let rawRel = SavedVideo.relativePath(for: fileURL) else { return }
        let rel = FileClassification.normalizedRelativePath(rawRel)
        guard !existingPaths.contains(rel) else { return }

        // サイズ確認
        let attrs = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)) ?? [:]
        let size = (attrs[.size] as? Int64) ?? 0
        guard size > 0 else { return }

        let creation = (attrs[.creationDate] as? Date) ?? Date()
        let title = fileURL.deletingPathExtension().lastPathComponent

        let newSaved = SavedVideo(
            id: UUID(),
            title: title,
            relativePath: rel,
            format: format,
            sourceHost: nil,
            createdAt: creation,
            byteSize: size,
            sourcePageURL: nil,
            isFavorite: false
        )

        downloads.addSaved(newSaved)
        if !folderName.isEmpty {
            setFolderName(folderName, for: newSaved)
        }
        existingPaths.insert(rel)
        existingFullPaths.insert(standardizedPath)
    }

    /// 指定ディレクトリ内部の空のサブディレクトリを再帰的に下位から削除する（ルートディレクトリ自体は削除しない）
    static func removeEmptySubdirectoriesRecursively(inside directoryURL: URL) {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else { return }

        for child in children {
            let name = child.lastPathComponent
            if name == ".DS_Store" || name == "__MACOSX" {
                try? fm.removeItem(at: child)
                continue
            }
            let vals = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if vals?.isDirectory == true && vals?.isSymbolicLink != true {
                guard !name.lowercased().hasSuffix(".movpkg") else { continue }
                removeEmptySubdirectoriesRecursively(inside: child)
                let subRemaining = (try? fm.contentsOfDirectory(atPath: child.path)) ?? []
                if subRemaining.isEmpty {
                    try? fm.removeItem(at: child)
                }
            }
        }
    }

    // MARK: - 永続化と既存データ移行

    private func loadPersistedState() {
        let defaults = UserDefaults.standard
        if let savedFolders = defaults.stringArray(forKey: Self.foldersKey) {
            let cleanList = savedFolders.map(Self.sanitizedFolderName).filter { !$0.isEmpty }
            folders = Array(Set(cleanList)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        if let savedMap = defaults.dictionary(forKey: Self.folderMapKey) as? [String: String] {
            var cleanMap: [String: String] = [:]
            for (k, v) in savedMap {
                let clean = Self.sanitizedFolderName(v)
                if !clean.isEmpty { cleanMap[k] = clean }
            }
            folderMap = cleanMap
        }
    }

    /// 以前のバージョンで `clipHarborSavedVideosV2` 内に `folderName` が保存されていた場合、それを読み取って引き継ぐ
    private func migrateLegacyFolderMetadataIfNeeded() {
        struct LegacyFolderItem: Decodable {
            let id: UUID
            let folderName: String?
        }
        let defaults = UserDefaults.standard
        if let legacyFolders = defaults.stringArray(forKey: "clipHarborCustomFoldersV1") {
            for raw in legacyFolders {
                let clean = Self.sanitizedFolderName(raw)
                if !clean.isEmpty && !folders.contains(clean) {
                    folders.append(clean)
                }
            }
        }
        if let data = defaults.data(forKey: Self.savedVideosKey),
           let items = try? JSONDecoder().decode([LegacyFolderItem].self, from: data) {
            for item in items {
                if let raw = item.folderName {
                    let clean = Self.sanitizedFolderName(raw)
                    if !clean.isEmpty && folderMap[item.id.uuidString] == nil {
                        folderMap[item.id.uuidString] = clean
                    }
                }
            }
        }
    }

    private func persistState() {
        let defaults = UserDefaults.standard
        defaults.set(folders, forKey: Self.foldersKey)
        defaults.set(folderMap, forKey: Self.folderMapKey)
    }

    // MARK: - パス・フォルダ名ヘルパー

    static func sanitizedFolderName(_ raw: String) -> String {
        let clean = FileNaming.sanitizedBaseName(raw)
        if clean.lowercased() == "downloads" { return "" }
        return clean
    }

    static func ensureDownloadsDirectory() throws -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func ensureSubfolder(named folderName: String) throws -> URL {
        let root = try ensureDownloadsDirectory()
        let clean = sanitizedFolderName(folderName)
        guard !clean.isEmpty else { return root }
        let sub = root.appendingPathComponent(clean, isDirectory: true)
        guard FileNaming.isDirectChild(sub, of: root) else { return root }
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        return sub
    }

    private static func inferSubfolder(fromRelativePath relativePath: String) -> String? {
        let components = relativePath.split(separator: "/").map(String.init)
        // Documents / Downloads / <Subfolder> / <File>
        guard let dlIndex = components.firstIndex(of: "Downloads"),
              components.count >= dlIndex + 3 else {
            return nil
        }
        let clean = sanitizedFolderName(components[dlIndex + 1])
        return clean.isEmpty ? nil : clean
    }

    private static func isDescendant(_ url: URL, of root: URL) -> Bool {
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return target.hasPrefix(prefix) && !url.lastPathComponent.hasPrefix(".")
    }
}


// MARK: - VaultFolderManaging Conformance
extension VideoFolderManager: VaultFolderManaging {}
