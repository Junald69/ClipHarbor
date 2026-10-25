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
            case .all: return "すべての動画"
            case .uncategorized: return "Downloads（未分類）"
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
                return "有効な名前を入力してください。"
            case .alreadyExists:
                return "同じ名前のフォルダが既に存在します。"
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

        downloads.onVideoSaved = { [weak self] jobID, video in
            self?.handleVideoSaved(jobID: jobID, video: video)
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
            return .failure(.fileOperationFailed("フォルダを作成できませんでした。"))
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
                return .failure(.fileOperationFailed("フォルダ名が不正です。"))
            }

            if FileManager.default.fileExists(atPath: oldURL.path) {
                if FileManager.default.fileExists(atPath: newURL.path) {
                    return .failure(.alreadyExists)
                }
                try FileManager.default.moveItem(at: oldURL, to: newURL)
            } else {
                try FileManager.default.createDirectory(at: newURL, withIntermediateDirectories: true)
            }

            // 直接ファイル（MP4等）で対象フォルダ内に保存されているものの relativePath を更新
            for video in downloads.saved where !video.isHLS {
                let currentFolder = folderName(for: video)
                if currentFolder == cleanOld {
                    let fileName = (video.relativePath as NSString).lastPathComponent
                    let updatedURL = newURL.appendingPathComponent(fileName)
                    if let rel = SavedVideo.relativePath(for: updatedURL) {
                        downloads.updateSavedVideo(id: video.id, relativePath: rel)
                    }
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
            return .failure(.fileOperationFailed("フォルダ名を変更できませんでした。"))
        }
    }

    /// フォルダを削除する（中の動画は削除せず、Downloads（未分類）へ戻す）
    func deleteFolder(name rawName: String) {
        let clean = Self.sanitizedFolderName(rawName)
        guard !clean.isEmpty else { return }

        // フォルダ内の動画を未分類（Documents/Downloads 直下）へ戻す（HLSは論理フォルダ解除のみ）
        let affectedVideos = downloads.saved.filter { folderName(for: $0) == clean }
        for video in affectedVideos {
            _ = moveVideo(video, toFolder: "")
        }

        // 空になったサブフォルダがあれば削除
        if let root = try? Self.ensureDownloadsDirectory() {
            let sub = root.appendingPathComponent(clean, isDirectory: true)
            if FileNaming.isDirectChild(sub, of: root),
               let items = try? FileManager.default.contentsOfDirectory(atPath: sub.path),
               items.isEmpty {
                try? FileManager.default.removeItem(at: sub)
            }
        }

        for (videoID, mappedFolder) in folderMap where mappedFolder == clean {
            folderMap[videoID] = nil
        }
        folders.removeAll { $0 == clean }
        persistState()
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
                    return .failure(.fileOperationFailed("移動元のファイルが見つかりません。"))
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
                    return .failure(.fileOperationFailed("移動先のパスが不正です。"))
                }
                try FileManager.default.moveItem(at: currentURL, to: destURL)
                downloads.updateSavedVideo(id: video.id, relativePath: rel)
            }

            if cleanFolder.isEmpty {
                folderMap[video.id.uuidString] = nil
            } else {
                folderMap[video.id.uuidString] = cleanFolder
            }
            persistState()
            return .success(())
        } catch {
            return .failure(.fileOperationFailed("ファイルを移動できませんでした。"))
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
                    return .failure(.fileOperationFailed("ファイル名が不正です。"))
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
            return .failure(.fileOperationFailed("名前を変更できませんでした。"))
        }
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

    /// ファイルシステム上のサブフォルダと保存済み動画一覧を再スキャンして同期する
    func syncWithFileSystemAndSavedVideos() {
        var folderSet = Set(folders)

        if let root = try? Self.ensureDownloadsDirectory(),
           let contents = try? FileManager.default.contentsOfDirectory(
               at: root,
               includingPropertiesForKeys: [.isDirectoryKey],
               options: [.skipsHiddenFiles]
           ) {
            for url in contents {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    let clean = Self.sanitizedFolderName(url.lastPathComponent)
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

        let sorted = folderSet.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        if sorted != folders || changedMap {
            folders = sorted
            persistState()
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

    private static func ensureDownloadsDirectory() throws -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func ensureSubfolder(named folderName: String) throws -> URL {
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
