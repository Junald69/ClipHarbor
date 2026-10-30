import Foundation
import AVFoundation
import UIKit

/// ユーザーが保存操作をした動画のみダウンロードする。回数・件数によるアプリ内制限はない（DL-03）。
/// - MP4等の直接ファイル: Documents/Downloads へ保存（ファイルアプリから参照可能）
/// - HLS: AVFoundationのオフライン形式（.movpkg）でApple指定の領域へ保存。MP4には変換しない。
/// - 元の動画URL・Cookieはメモリ上のみで扱い、永続化・ログ出力しない（DL-04）。
final class DownloadCenter: NSObject, ObservableObject, URLSessionDownloadDelegate, AVAssetDownloadDelegate {
    static let shared = DownloadCenter()

    @Published private(set) var saved: [SavedVideo] = []
    @Published private(set) var jobs: [DownloadJob] = []
    @Published var statusMessage: String?

    var activeCount: Int { jobs.filter { $0.state.isActive }.count }
    /// AppDelegateから渡される、バックグラウンドURLSession完了時のハンドラー
    var backgroundCompletionHandler: (() -> Void)?
    /// 動画の保存完了後にフォルダ管理層（VideoFolderManager）へ通知するコールバック
    var onVideoSaved: ((UUID, SavedVideo) -> Void)?

    private final class Transfer {
        let jobID: UUID
        let candidate: MediaCandidate
        let context: RequestContext
        let baseName: String
        let sourcePageURL: String?
        var redirectCount = 0
        var outcome: Outcome?
        var failureOverride: String?
        var checkedCapacity = false

        init(jobID: UUID, candidate: MediaCandidate, context: RequestContext, baseName: String, sourcePageURL: String? = nil) {
            self.jobID = jobID
            self.candidate = candidate
            self.context = context
            self.baseName = baseName
            self.sourcePageURL = sourcePageURL
        }
    }

    private enum Outcome {
        case saved(SavedVideo)
        case failed(String)
    }

    private var transfers: [UUID: Transfer] = [:]
    private var tasks: [UUID: URLSessionTask] = [:]
    private var observations: [UUID: NSKeyValueObservation] = [:]
    private var hlsLocations: [UUID: URL] = [:]
    private var pendingHLS: [UUID: PendingHLSRecord] = [:]
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var statusClearWork: DispatchWorkItem?
    private var lastProgressUpdateTimes: [UUID: Date] = [:]
    private var lastReportedProgress: [UUID: Double] = [:]

    private static let savedKey = "clipHarborSavedVideosV2"
    private static let legacyKey = "clipHarborSavedVideosV1"
    private static let pendingHLSKey = "clipHarborPendingHLSV2"
    private static let minimumFreeBytes: Int64 = 100 * 1024 * 1024
    private static let maxRedirects = 10

    /// 直接ファイル用。Cookieは自動保存・自動送信せず、リダイレクトごとに宛先を検証する。
    private lazy var fileSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 6 * 60 * 60
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    /// HLS用。AVAssetDownloadURLSessionはバックグラウンド構成が必須。
    private lazy var hlsSession: AVAssetDownloadURLSession = {
        let id = (Bundle.main.bundleIdentifier ?? "ClipHarbor") + ".HLS"
        let config = URLSessionConfiguration.background(withIdentifier: id)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return AVAssetDownloadURLSession(configuration: config, assetDownloadDelegate: self, delegateQueue: .main)
    }()

    override init() {
        super.init()
        loadSaved()
        loadPendingHLS()
        restoreHLSTasks()
    }

    // MARK: - 公開操作

    @discardableResult
    func start(_ candidate: MediaCandidate, displayName: String, context: RequestContext) -> UUID? {
        // HLSダウンロードの二重防御（UIを経由しない呼び出しからもHLSダウンロードを開始させない）
        guard !candidate.isHLS else {
            return nil
        }
        var name = FileNaming.sanitizedBaseName(displayName)
        if name.isEmpty { name = FileNaming.sanitizedBaseName(candidate.suggestedName) }
        if name.isEmpty { name = "Video" }
        let job = DownloadJob(id: UUID(), displayName: name, isHLS: candidate.isHLS,
                              host: candidate.host, state: .preparing)
        jobs.insert(job, at: 0)
        let cleanPageURL = SourceURLPolicy.sanitize(context.pageURL)
        let transfer = Transfer(jobID: job.id, candidate: candidate, context: context, baseName: name, sourcePageURL: cleanPageURL)
        transfers[job.id] = transfer
        launch(transfer)
        return job.id
    }

    func cancel(_ jobID: UUID) {
        if let task = tasks[jobID] {
            task.cancel()
        } else {
            updateJob(jobID) { $0.state = .cancelled }
        }
    }

    func retry(_ jobID: UUID) {
        guard let transfer = transfers[jobID],
              let job = jobs.first(where: { $0.id == jobID }), !job.state.isActive else { return }
        launch(transfer)
    }

    func dismissJob(_ jobID: UUID) {
        guard let job = jobs.first(where: { $0.id == jobID }), !job.state.isActive else { return }
        jobs.removeAll { $0.id == jobID }
        transfers[jobID] = nil
    }

    func delete(_ item: SavedVideo) {
        if item.fileExists {
            do {
                try FileManager.default.removeItem(at: item.fileURL)
            } catch {
                setStatus(NSLocalizedString("Failed to delete file", comment: ""))
                return
            }
        }
        saved.removeAll { $0.id == item.id }
        try? persistSaved()
    }

    /// 指定IDの保存済みアイテムのお気に入り状態を反転して永続化し、新しい状態を返す
    @discardableResult
    func toggleFavorite(id: UUID) throws -> Bool {
        guard let idx = saved.firstIndex(where: { $0.id == id }) else {
            throw NSError(domain: "ClipHarbor.DownloadCenter", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "Item not found in saved list"
            ])
        }
        let targetState = !saved[idx].isFavorite
        saved[idx].isFavorite = targetState
        do {
            try persistSaved()
            return targetState
        } catch {
            saved[idx].isFavorite = !targetState
            throw error
        }
    }

    /// フォルダ管理層（VideoFolderManager）による名前変更・MP4フォルダ移動・お気に入り更新後にメタデータを更新する
    func updateSavedVideo(id: UUID, title: String? = nil, relativePath: String? = nil, isFavorite: Bool? = nil) {
        guard let idx = saved.firstIndex(where: { $0.id == id }) else { return }
        if let title = title { saved[idx].title = title }
        if let relativePath = relativePath { saved[idx].relativePath = relativePath }
        if let isFavorite = isFavorite { saved[idx].isFavorite = isFavorite }
        try? persistSaved()
    }

    /// ゴミ箱移動時に、実ファイルを削除せずに保存済み一覧からのみ除外する
    func removeSavedVideoWithoutDeletingFile(id: UUID) {
        saved.removeAll { $0.id == id }
        try? persistSaved()
    }

    /// ゴミ箱からの復元時に、保存済み動画を再登録する
    func restoreSavedVideo(_ video: SavedVideo) {
        if !saved.contains(where: { $0.id == video.id }) {
            saved.insert(video, at: 0)
            try? persistSaved()
        }
    }

    /// Vault復元等、ディスク永続化の成功保証が必須な場面向けの再登録API
    func restoreSavedVideoThrowing(_ video: SavedVideo) throws {
        let previousSaved = self.saved

        // 既存の同一IDエントリが存在する場合は最新情報（新パス・サイズ等）で更新、存在しない場合は先頭に挿入
        if let existingIndex = saved.firstIndex(where: { $0.id == video.id }) {
            saved[existingIndex] = video
        } else {
            saved.insert(video, at: 0)
        }

        do {
            try persistSaved()
        } catch {
            // 永続化失敗時はメモリ上の一覧を完全ロールバック
            self.saved = previousSaved
            throw error
        }
    }

    /// VideoExportManager が生成・品質検証を完了したMP4ファイルを保存済み一覧へ登録する。
    /// - 二重登録を防止し、onVideoSaved による二重ファイル移動を発生させない。
    @discardableResult
    func registerExportedVideo(_ video: SavedVideo) -> Bool {
        guard !video.isHLS, video.fileExists else { return false }
        guard !saved.contains(where: { $0.id == video.id || $0.relativePath == video.relativePath }) else {
            return false
        }
        addSaved(video)
        setStatus(String(format: NSLocalizedString("Saved as MP4: %@", comment: ""), video.title))
        return true
    }

    // MARK: - 開始処理

    private func launch(_ transfer: Transfer) {
        transfer.outcome = nil
        transfer.failureOverride = nil
        transfer.checkedCapacity = false
        transfer.redirectCount = 0
        updateJob(transfer.jobID) {
            $0.state = .preparing
            $0.receivedBytes = 0
            $0.expectedBytes = 0
            $0.canRetry = false
        }
        if let free = availableCapacity(), free < Self.minimumFreeBytes {
            finish(transfer.jobID, state: .failed(NSLocalizedString("Insufficient storage available on iPhone", comment: "")), name: transfer.baseName)
            return
        }
        if transfer.candidate.isHLS {
            // HLS保存は一時無効化（将来の機能拡張用に基盤コードは保持）
            finish(transfer.jobID, state: .failed(NSLocalizedString("HLS streaming format is currently not supported for download.", comment: "")), name: transfer.baseName)
            return
        } else {
            launchFile(transfer)
        }
        setStatus(String(format: NSLocalizedString("Started download for \"%@\"", comment: ""), transfer.baseName))
        updateBackgroundTask()
    }

    private func launchFile(_ transfer: Transfer) {
        let request = transfer.context.makeRequest(for: transfer.candidate.url)
        let task = fileSession.downloadTask(with: request)
        task.taskDescription = transfer.jobID.uuidString
        tasks[transfer.jobID] = task
        updateJob(transfer.jobID) { $0.state = .downloading(progress: nil) }
        task.resume()
    }

    private func launchHLS(_ transfer: Transfer) {
        // AVFoundation標準のHLS保存。DRM解除や特別な認証トークンの取得はしない。
        var options: [String: Any] = [:]
        let cookies = CookiePolicy.cookies(transfer.context.cookies, matching: transfer.candidate.url)
        if !cookies.isEmpty { options[AVURLAssetHTTPCookiesKey] = cookies }
        if let ua = transfer.context.userAgent, !ua.isEmpty { options[AVURLAssetHTTPUserAgentKey] = ua }
        let asset = AVURLAsset(url: transfer.candidate.url, options: options)
        let configuration = AVAssetDownloadConfiguration(asset: asset, title: transfer.baseName)
        let task = hlsSession.makeAssetDownloadTask(downloadConfiguration: configuration)
        task.taskDescription = transfer.jobID.uuidString
        tasks[transfer.jobID] = task
        observations[transfer.jobID] = observeProgress(of: task, jobID: transfer.jobID)
        pendingHLS[transfer.jobID] = PendingHLSRecord(jobID: transfer.jobID, displayName: transfer.baseName,
                                                       host: transfer.candidate.host, pageURL: transfer.sourcePageURL)
        persistPendingHLS()
        updateJob(transfer.jobID) { $0.state = .downloading(progress: nil) }
        task.resume()
    }

    private func observeProgress(of task: URLSessionTask, jobID: UUID) -> NSKeyValueObservation {
        task.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            let value = progress.fractionCompleted
            DispatchQueue.main.async {
                self?.updateJob(jobID) { job in
                    if job.state.isActive { job.state = .downloading(progress: min(max(value, 0), 1)) }
                }
            }
        }
    }

    // MARK: - URLSessionDelegate（直接ファイル）

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let id = jobID(for: task), let transfer = transfers[id] else {
            completionHandler(nil)
            return
        }
        transfer.redirectCount += 1
        guard transfer.redirectCount <= Self.maxRedirects else {
            transfer.failureOverride = NSLocalizedString("Too many redirects", comment: "")
            completionHandler(nil)
            task.cancel()
            return
        }
        // 前の宛先のCookie/Authorizationを外し、新しい宛先に一致するCookieだけを付け直す
        guard let next = transfer.context.redirectedRequest(request, from: task.currentRequest?.url) else {
            transfer.failureOverride = NSLocalizedString("Could not establish a secure connection", comment: "")
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let id = jobID(for: downloadTask), let transfer = transfers[id] else { return }
        let expected = max(totalBytesExpectedToWrite, 0)
        if !transfer.checkedCapacity && expected > 0 {
            transfer.checkedCapacity = true
            if let free = availableCapacity(), expected + Self.minimumFreeBytes > free {
                transfer.failureOverride = NSLocalizedString("Insufficient storage available on iPhone", comment: "")
                downloadTask.cancel()
                return
            }
        }
        updateJob(id) {
            $0.receivedBytes = totalBytesWritten
            $0.expectedBytes = expected
            $0.state = .downloading(progress: expected > 0 ? min(Double(totalBytesWritten) / Double(expected), 1) : nil)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // このメソッドから戻ると一時ファイルは削除されるため、ここで検証・移動する
        guard let id = jobID(for: downloadTask), let transfer = transfers[id] else { return }
        transfer.outcome = processDownloadedFile(at: location, response: downloadTask.response, transfer: transfer)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = jobID(for: task) else { return }
        tasks[id] = nil
        observations[id] = nil

        if task is AVAssetDownloadTask {
            completeHLS(jobID: id, error: error)
            return
        }
        guard let transfer = transfers[id] else { return }
        if let message = transfer.failureOverride {
            finish(id, state: .failed(message), name: transfer.baseName)
        } else if let error = error {
            if (error as NSError).code == NSURLErrorCancelled && (error as NSError).domain == NSURLErrorDomain {
                finish(id, state: .cancelled, name: transfer.baseName)
            } else {
                finish(id, state: .failed(DownloadErrorMessage.forError(error)), name: transfer.baseName)
            }
        } else if let outcome = transfer.outcome {
            switch outcome {
            case .saved(let video):
                addSaved(video)
                finish(id, state: .completed, name: video.title)
                onVideoSaved?(id, video)
            case .failed(let message):
                finish(id, state: .failed(message), name: transfer.baseName)
            }
        } else {
            finish(id, state: .failed(NSLocalizedString("Could not save (HTTP 500)", comment: "")), name: transfer.baseName)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            let handler = self.backgroundCompletionHandler
            self.backgroundCompletionHandler = nil
            handler?()
        }
    }

    // MARK: - AVAssetDownloadDelegate（HLS）

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                    willDownloadTo location: URL) {
        guard let id = jobID(for: assetDownloadTask) else { return }
        hlsLocations[id] = location
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let id = jobID(for: assetDownloadTask) else { return }
        hlsLocations[id] = location
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                    didLoad timeRange: CMTimeRange,
                    totalTimeRangesLoaded: [NSValue],
                    timeRangeExpectedToLoad: CMTimeRange) {
        guard let id = jobID(for: assetDownloadTask) else { return }

        let expectedSecs = CMTimeGetSeconds(timeRangeExpectedToLoad.duration)
        guard !expectedSecs.isNaN, !expectedSecs.isInfinite, expectedSecs > 0 else {
            // 総時間不明の場合は progress: nil（不確定インジケーター表示）を維持
            return
        }

        // 時間範囲の重複を統合（マージ）して二重計上を防止
        var rawRanges: [(start: Double, end: Double)] = []
        for val in totalTimeRangesLoaded {
            let range = val.timeRangeValue
            let start = CMTimeGetSeconds(range.start)
            let dur = CMTimeGetSeconds(range.duration)
            guard !start.isNaN, !start.isInfinite, !dur.isNaN, !dur.isInfinite, dur > 0 else { continue }
            rawRanges.append((start: start, end: start + dur))
        }

        rawRanges.sort { $0.start < $1.start }
        var mergedRanges: [(start: Double, end: Double)] = []
        for r in rawRanges {
            if let last = mergedRanges.last {
                if r.start <= last.end {
                    mergedRanges[mergedRanges.count - 1] = (start: last.start, end: max(last.end, r.end))
                } else {
                    mergedRanges.append(r)
                }
            } else {
                mergedRanges.append(r)
            }
        }

        var loadedSecs: Double = 0.0
        for r in mergedRanges {
            loadedSecs += (r.end - r.start)
        }

        let ratio = loadedSecs / expectedSecs
        let progress = min(max(ratio, 0.0), 1.0)

        // スロットリング制御: 前回のUI通知から0.25秒以上経過、または2%以上の進捗変化、または100%到達時のみ発火
        let now = Date()
        let lastTime = lastProgressUpdateTimes[id] ?? .distantPast
        let lastProg = lastReportedProgress[id] ?? -1.0
        let timeDelta = now.timeIntervalSince(lastTime)
        let progDelta = abs(progress - lastProg)

        if timeDelta >= 0.25 || progDelta >= 0.02 || progress >= 1.0 {
            lastProgressUpdateTimes[id] = now
            lastReportedProgress[id] = progress
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.updateJob(id) { job in
                    // 完了、失敗、キャンセル済みのジョブを進捗通知で上書きしない
                    guard job.state.isActive else { return }
                    job.state = .downloading(progress: progress)
                }
            }
        }
    }

    private func completeHLS(jobID id: UUID, error: Error?) {
        let location = hlsLocations.removeValue(forKey: id)
        let record = pendingHLS.removeValue(forKey: id)
        persistPendingHLS()
        let name = transfers[id]?.baseName ?? record?.displayName ?? NSLocalizedString("Offline HLS", comment: "")
        let host = transfers[id]?.candidate.host ?? record?.host

        if let error = error {
            if let location = location { try? FileManager.default.removeItem(at: location) }
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                finish(id, state: .cancelled, name: name)
            } else {
                finish(id, state: .failed(Self.hlsMessage(for: error)), name: name)
            }
            return
        }
        guard let location = location else {
            finish(id, state: .failed(NSLocalizedString("Could not save (HTTP 500)", comment: "")), name: name)
            return
        }
        let asset = AVURLAsset(url: location)
        guard asset.assetCache?.isPlayableOffline == true,
              let relative = SavedVideo.relativePath(for: location) else {
            try? FileManager.default.removeItem(at: location)
            finish(id, state: .failed(NSLocalizedString("This streaming URL format is not supported.", comment: "")), name: name)
            return
        }
        let pageURL = transfers[id]?.sourcePageURL ?? record?.pageURL
        let video = SavedVideo(id: UUID(), title: name, relativePath: relative, format: .hls,
                               sourceHost: host, createdAt: Date(), byteSize: Self.directorySize(location),
                               sourcePageURL: pageURL)
        var locIsDir: ObjCBool = false
        let locExists = FileManager.default.fileExists(atPath: location.path, isDirectory: &locIsDir)
        let locReadable = FileManager.default.isReadableFile(atPath: location.path)
        var resIsDir: ObjCBool = false
        let resExists = FileManager.default.fileExists(atPath: video.fileURL.path, isDirectory: &resIsDir)
        let resReadable = FileManager.default.isReadableFile(atPath: video.fileURL.path)
        let pathsMatch = (location.standardizedFileURL.resolvingSymlinksInPath().path == video.fileURL.standardizedFileURL.resolvingSymlinksInPath().path)
        print("[DownloadDiag] HLS complete locExists=\(locExists) locIsDir=\(locIsDir.boolValue) locReadable=\(locReadable) resExists=\(resExists) resIsDir=\(resIsDir.boolValue) resReadable=\(resReadable) pathsMatch=\(pathsMatch) playable=\(asset.assetCache?.isPlayableOffline == true)")
        addSaved(video)
        finish(id, state: .completed, name: name)
        onVideoSaved?(id, video)
    }

    private static func hlsMessage(for error: Error) -> String {
        let ns = error as NSError
        if ns.domain == AVFoundationErrorDomain {
            if ns.code == AVError.Code.contentIsProtected.rawValue || ns.code == AVError.Code.contentIsNotAuthorized.rawValue {
                return NSLocalizedString("Protected content (DRM) cannot be saved.", comment: "")
            }
            return NSLocalizedString("This streaming URL format is not supported.", comment: "")
        }
        return DownloadErrorMessage.forError(error)
    }

    private func restoreHLSTasks() {
        hlsSession.getAllTasks { [weak self] sessionTasks in
            DispatchQueue.main.async {
                guard let self = self else { return }
                for task in sessionTasks {
                    guard let desc = task.taskDescription, let id = UUID(uuidString: desc),
                          let record = self.pendingHLS[id], self.tasks[id] == nil else { continue }
                    self.tasks[id] = task
                    self.observations[id] = self.observeProgress(of: task, jobID: id)
                    if !self.jobs.contains(where: { $0.id == id }) {
                        self.jobs.append(DownloadJob(id: id, displayName: record.displayName, isHLS: true,
                                                     host: record.host, state: .downloading(progress: nil)))
                    }
                }
            }
        }
    }

    // MARK: - ファイル処理

    private func processDownloadedFile(at location: URL, response: URLResponse?, transfer: Transfer) -> Outcome {
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            return .failed(DownloadErrorMessage.forHTTPStatus(http.statusCode))
        }
        let mime = response?.mimeType?.lowercased() ?? ""
        let format: SavedVideo.Format
        switch MediaSniffer.sniff(fileAt: location) {
        case .mp4: format = .mp4
        case .m4v: format = .m4v
        case .mov: format = .mov
        case .webm: format = .webm
        case .hlsPlaylist:
            return .failed(NSLocalizedString("This streaming URL format is not supported.", comment: ""))
        case .textOrHTML:
            return .failed(NSLocalizedString("This URL cannot be identified as a video file.", comment: ""))
        case .unknown:
            if mime.hasPrefix("video/"), let ext = transfer.candidate.expectedExtension,
               let f = SavedVideo.Format(rawValue: ext) {
                format = f
            } else {
                return .failed(NSLocalizedString("This URL cannot be identified as a video file.", comment: ""))
            }
        }

        do {
            let folder = try ensureDownloadsDirectory()
            var destination: URL?
            for _ in 0..<5 {
                let candidateURL = FileNaming.uniqueDestination(in: folder, baseName: transfer.baseName,
                                                                fileExtension: format.rawValue)
                guard FileNaming.isDirectChild(candidateURL, of: folder) else {
                    return .failed(NSLocalizedString("Invalid file name.", comment: ""))
                }
                do {
                    try FileManager.default.moveItem(at: location, to: candidateURL)
                    destination = candidateURL
                    break
                } catch let error as CocoaError where error.code == .fileWriteFileExists {
                    continue
                }
            }
            guard let saved = destination else { return .failed(NSLocalizedString("A folder with the same name already exists.", comment: "")) }
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                   ofItemAtPath: saved.path)
            let size = (try? FileManager.default.attributesOfItem(atPath: saved.path)[.size] as? NSNumber)?.int64Value
            guard let relative = SavedVideo.relativePath(for: saved) else {
                try? FileManager.default.removeItem(at: saved)
                return .failed(NSLocalizedString("Could not save (HTTP 500)", comment: ""))
            }
            return .saved(SavedVideo(id: UUID(), title: transfer.baseName, relativePath: relative, format: format,
                                     sourceHost: transfer.candidate.url.host, createdAt: Date(), byteSize: size,
                                     sourcePageURL: transfer.sourcePageURL))
        } catch {
            return .failed(DownloadErrorMessage.forError(error))
        }
    }

    private func ensureDownloadsDirectory() throws -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func availableCapacity() -> Int64? {
        let url = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private static func directorySize(_ url: URL) -> Int64? {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    // MARK: - 状態管理

    private func jobID(for task: URLSessionTask) -> UUID? {
        task.taskDescription.flatMap(UUID.init(uuidString:))
    }

    private func updateJob(_ id: UUID, _ change: (inout DownloadJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        var job = jobs[index]
        change(&job)
        if job != jobs[index] { jobs[index] = job }
    }

    private func finish(_ id: UUID, state: DownloadState, name: String) {
        lastProgressUpdateTimes.removeValue(forKey: id)
        lastReportedProgress.removeValue(forKey: id)
        switch state {
        case .completed:
            jobs.removeAll { $0.id == id }
            transfers[id] = nil
            setStatus(String(format: NSLocalizedString("Saved: %@", comment: ""), name))
        case .failed(let message):
            updateJob(id) { $0.state = state; $0.canRetry = true }
            setStatus("「\(name)」\(message)")
        case .cancelled:
            updateJob(id) { $0.state = state; $0.canRetry = true }
            setStatus(String(format: NSLocalizedString("Cancelled download for \"%@\"", comment: ""), name))
        default:
            updateJob(id) { $0.state = state }
        }
        if transfers[id] == nil { updateJob(id) { $0.canRetry = false } }
        updateBackgroundTask()
    }

    private func setStatus(_ text: String) {
        statusMessage = text
        statusClearWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.statusMessage = nil }
        statusClearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    /// 直接ファイルのダウンロード中にアプリが背面へ移動しても、OSが許す範囲で処理を続ける
    private func updateBackgroundTask() {
        let hasActiveFile = jobs.contains { $0.state.isActive && !$0.isHLS }
        MainActor.assumeIsolated {
            if hasActiveFile && backgroundTaskID == .invalid {
                backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "ClipHarborDownload") { [weak self] in
                    self?.endBackgroundTask()
                }
            } else if !hasActiveFile {
                endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        MainActor.assumeIsolated {
            guard backgroundTaskID != .invalid else { return }
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }

    // MARK: - 永続化（URLを含まないメタデータのみ）

    func addSaved(_ video: SavedVideo) {
        saved.insert(video, at: 0)
        try? persistSaved()
    }

    private func persistSaved() throws {
        do {
            let data = try JSONEncoder().encode(saved)
            UserDefaults.standard.set(data, forKey: Self.savedKey)
        } catch {
            print("[DownloadCenter] Failed to encode saved videos: \(error)")
            throw error
        }
    }

    private func loadSaved() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.savedKey),
           let items = try? JSONDecoder().decode([SavedVideo].self, from: data) {
            saved = items
        }
        // v1形式からの移行。元URL（sourceURLString）は読み込まずにデータごと削除する。
        if let legacy = defaults.data(forKey: Self.legacyKey) {
            if let old = try? JSONDecoder().decode([LegacySavedVideoV1].self, from: legacy) {
                for item in old where !saved.contains(where: { $0.id == item.id }) {
                    guard let url = URL(string: item.fileURLString), url.isFileURL,
                          let relative = SavedVideo.relativePath(for: url) else { continue }
                    let format = SavedVideo.Format(rawValue: item.format.lowercased()) ?? .mp4
                    saved.append(SavedVideo(id: item.id, title: item.title, relativePath: relative, format: format,
                                            sourceHost: nil, createdAt: item.createdAt, byteSize: nil, sourcePageURL: nil))
                }
            }
            defaults.removeObject(forKey: Self.legacyKey)
            try? persistSaved()
        }
    }

    private func loadPendingHLS() {
        guard let data = UserDefaults.standard.data(forKey: Self.pendingHLSKey),
              let records = try? JSONDecoder().decode([PendingHLSRecord].self, from: data) else { return }
        for record in records { pendingHLS[record.jobID] = record }
    }

    private func persistPendingHLS() {
        if let data = try? JSONEncoder().encode(Array(pendingHLS.values)) {
            UserDefaults.standard.set(data, forKey: Self.pendingHLSKey)
        }
    }
}


// MARK: - VaultDownloadManaging Conformance
extension DownloadCenter: VaultDownloadManaging {}
