import Foundation
import AVFoundation
import UIKit

/// ユーザーが保存操作をした動画のみダウンロードする。回数・件数によるアプリ内制限はない（DL-03）。
/// - MP4等の直接ファイル: Documents/Downloads（およびそのサブフォルダ）へ保存（ファイルアプリから参照可能）
/// - HLS: AVFoundationのオフライン形式（.movpkg）でApple指定の領域へ保存。MP4には変換しない。
/// - 元の動画URL・Cookieはメモリ上のみで扱い、永続化・ログ出力しない（DL-04）。
final class DownloadCenter: NSObject, ObservableObject, URLSessionDownloadDelegate, AVAssetDownloadDelegate {
    static let shared = DownloadCenter()

    @Published private(set) var saved: [SavedVideo] = []
    @Published private(set) var jobs: [DownloadJob] = []
    @Published private(set) var folders: [String] = []
    @Published var statusMessage: String?

    var activeCount: Int { jobs.filter { $0.state.isActive }.count }
    /// AppDelegateから渡される、バックグラウンドURLSession完了時のハンドラー
    var backgroundCompletionHandler: (() -> Void)?

    enum FolderOperationError: LocalizedError {
        case emptyName
        case alreadyExists
        case fileSystemError(String)

        var errorDescription: String? {
            switch self {
            case .emptyName: return "有効な名前を入力してください。"
            case .alreadyExists: return "同じ名前のフォルダが既に存在します。"
            case .fileSystemError(let msg): return msg
            }
        }
    }

    private final class Transfer {
        let jobID: UUID
        let candidate: MediaCandidate
        let context: RequestContext
        var baseName: String
        var targetFolder: String
        var redirectCount = 0
        var outcome: Outcome?
        var failureOverride: String?
        var checkedCapacity = false

        // 速度・進捗計測（delegateQueue上で更新）
        var startUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
        var initialOffsetBytes: Int64 = 0
        var lastSampleUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
        var lastSampleBytes: Int64 = 0
        var smoothedSpeedBytesPerSec: Double = 0
        var lastUIUpdateUptime: TimeInterval = 0

        // メトリクス計測
        var fileWriteMilliseconds: Double?
        var metricsSummary: DownloadMetricsSummary?

        // 一時停止・再開（HTTP Range 対応サーバー用）
        var resumeData: Data?
        var isPausing = false

        init(jobID: UUID, candidate: MediaCandidate, context: RequestContext, baseName: String, targetFolder: String) {
            self.jobID = jobID
            self.candidate = candidate
            self.context = context
            self.baseName = baseName
            self.targetFolder = targetFolder
        }

        func resetTiming(initialBytes: Int64 = 0) {
            let now = ProcessInfo.processInfo.systemUptime
            startUptime = now
            initialOffsetBytes = initialBytes
            lastSampleUptime = now
            lastSampleBytes = initialBytes
            smoothedSpeedBytesPerSec = 0
            lastUIUpdateUptime = 0
        }
    }

    private enum Outcome {
        case saved(SavedVideo)
        case failed(String)
    }

    private let stateLock = NSLock()
    private var transfers: [UUID: Transfer] = [:]
    private var tasks: [UUID: URLSessionTask] = [:]
    private var observations: [UUID: NSKeyValueObservation] = [:]
    private var hlsLocations: [UUID: URL] = [:]
    private var pendingHLS: [UUID: PendingHLSRecord] = [:]
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var statusClearWork: DispatchWorkItem?

    private static let savedKey = "clipHarborSavedVideosV2"
    private static let legacyKey = "clipHarborSavedVideosV1"
    private static let pendingHLSKey = "clipHarborPendingHLSV2"
    private static let guideFileName = "ClipHarbor_保存先案内.txt"
    private static let minimumFreeBytes: Int64 = 100 * 1024 * 1024
    private static let maxRedirects = 10
    /// 進捗UIの更新間隔（秒）。メインスレッドの再描画負荷を抑えるため最大約4回/秒に制限する。
    private static let uiUpdateInterval: TimeInterval = 0.25

    /// 直接ファイル受信用デリゲートキュー（メインスレッドをブロックしない専用直列キュー）
    private lazy var fileDelegateQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "ClipHarbor.FileDownloadDelegateQueue"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()

    /// 直接ファイル用。Cookieは自動保存・自動送信せず、リダイレクトごとに宛先を検証する。
    private lazy var fileSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.networkServiceType = .responsiveData
        config.httpMaximumConnectionsPerHost = 6
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 6 * 60 * 60
        return URLSession(configuration: config, delegate: self, delegateQueue: fileDelegateQueue)
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
        _ = try? ensureDownloadsDirectory()
        ensureFilesAppVisibilityGuide()
        loadSaved()
        reloadFolders()
        loadPendingHLS()
        restoreHLSTasks()
    }

    // MARK: - 公開操作（ダウンロード制御）

    func start(_ candidate: MediaCandidate, displayName: String, folderName: String = "", context: RequestContext) {
        var name = FileNaming.sanitizedBaseName(displayName)
        if name.isEmpty { name = FileNaming.sanitizedBaseName(candidate.suggestedName) }
        if name.isEmpty { name = "Video" }
        let cleanFolder = FileNaming.sanitizedFolderName(folderName)
        // MP4等の直接ファイルの場合のみ、実サブフォルダを事前に作成する（HLSはメタデータ分類のみ）
        if !cleanFolder.isEmpty && !candidate.isHLS {
            _ = try? ensureSubfolder(named: cleanFolder)
            reloadFolders()
        }

        let job = DownloadJob(
            id: UUID(),
            displayName: name,
            targetFolder: cleanFolder,
            isHLS: candidate.isHLS,
            host: candidate.host,
            state: .preparing,
            canPause: !candidate.isHLS
        )
        onMain {
            self.jobs.insert(job, at: 0)
        }
        let transfer = Transfer(jobID: job.id, candidate: candidate, context: context,
                                baseName: name, targetFolder: cleanFolder)
        stateLock.withLock {
            transfers[job.id] = transfer
        }
        launch(transfer, resumeData: nil)
    }

    func pause(_ jobID: UUID) {
        guard let transfer = stateLock.withLock({ transfers[jobID] }),
              !transfer.candidate.isHLS,
              let downloadTask = stateLock.withLock({ tasks[jobID] }) as? URLSessionDownloadTask else { return }

        stateLock.withLock {
            transfer.isPausing = true
            tasks[jobID] = nil
        }
        downloadTask.cancel(byProducingResumeData: { [weak self] data in
            guard let self = self else { return }
            self.stateLock.withLock {
                transfer.resumeData = data
                transfer.isPausing = false
            }
            self.onMain {
                self.updateJob(jobID) { job in
                    let p: Double? = job.expectedBytes > 0
                        ? min(Double(job.receivedBytes) / Double(job.expectedBytes), 1.0)
                        : nil
                    job.state = .paused(progress: p)
                    job.currentSpeedBytesPerSec = 0
                    job.estimatedRemainingSeconds = nil
                    job.canRetry = true
                }
                self.setStatus("「\(transfer.baseName)」を一時停止しました")
                self.updateBackgroundTask()
            }
        })
    }

    func resume(_ jobID: UUID) {
        guard let transfer = stateLock.withLock({ transfers[jobID] }) else { return }
        let data = stateLock.withLock { () -> Data? in
            let d = transfer.resumeData
            transfer.resumeData = nil
            return d
        }
        launch(transfer, resumeData: data)
    }

    func cancel(_ jobID: UUID) {
        if let transfer = stateLock.withLock({ transfers[jobID] }) {
            stateLock.withLock {
                transfer.isPausing = false
                transfer.resumeData = nil
            }
        }
        if let task = stateLock.withLock({ tasks[jobID] }) {
            task.cancel()
        } else {
            onMain {
                self.updateJob(jobID) {
                    $0.state = .cancelled
                    $0.currentSpeedBytesPerSec = 0
                    $0.estimatedRemainingSeconds = nil
                    $0.canRetry = true
                }
                self.updateBackgroundTask()
            }
        }
    }

    func retry(_ jobID: UUID) {
        guard let transfer = stateLock.withLock({ transfers[jobID] }),
              let job = jobs.first(where: { $0.id == jobID }), !job.state.isActive else { return }
        let data = stateLock.withLock { () -> Data? in
            let d = transfer.resumeData
            transfer.resumeData = nil
            return d
        }
        launch(transfer, resumeData: data)
    }

    func dismissJob(_ jobID: UUID) {
        guard let job = jobs.first(where: { $0.id == jobID }), !job.state.isActive else { return }
        jobs.removeAll { $0.id == jobID }
        stateLock.withLock {
            transfers[jobID] = nil
        }
    }

    func clearInactiveJobs() {
        let inactiveIDs = jobs.filter { !$0.state.isActive && !$0.state.isPaused }.map(\.id)
        jobs.removeAll { !$0.state.isActive && !$0.state.isPaused }
        stateLock.withLock {
            for id in inactiveIDs { transfers[id] = nil }
        }
    }

    /// 保存済み動画の再生可能性・再生時間を公開APIで検証し、メタデータを更新する（データは削除しない）
    @MainActor
    func verifySavedVideo(_ videoID: UUID) async -> PlayabilityVerificationResult? {
        guard let idx = saved.firstIndex(where: { $0.id == videoID }) else { return nil }
        let target = saved[idx]
        let result = await MediaPlayabilityVerifier.verify(url: target.fileURL, isHLS: target.isHLS)
        guard let updatedIdx = saved.firstIndex(where: { $0.id == videoID }) else { return result }
        if result.byteSize > 0 {
            saved[updatedIdx].byteSize = result.byteSize
        }
        switch result.evaluation {
        case .verified(let dur):
            saved[updatedIdx].verificationState = .verified(durationSeconds: dur)
        case .indeterminate(let note):
            saved[updatedIdx].verificationState = .indeterminate(
                note: note,
                diagnosticDetail: result.detailedReport
            )
        case .failed(let reason):
            saved[updatedIdx].verificationState = .failed(
                reason: reason,
                diagnosticDetail: result.detailedReport
            )
        }
        persistSaved()
        return result
    }

    // MARK: - 公開操作（フォルダ管理・ファイル管理）

    func reloadFolders() {
        onMain {
            guard let root = try? self.ensureDownloadsDirectory() else { return }
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            var names: Set<String> = []
            for url in contents {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    let clean = FileNaming.sanitizedFolderName(url.lastPathComponent)
                    if !clean.isEmpty { names.insert(clean) }
                }
            }
            for video in self.saved where !video.folderName.isEmpty {
                names.insert(video.folderName)
            }
            let sorted = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            if self.folders != sorted {
                self.folders = sorted
            }
        }
    }

    @discardableResult
    func createFolder(name: String) -> Result<String, FolderOperationError> {
        let clean = FileNaming.sanitizedFolderName(name)
        guard !clean.isEmpty else { return .failure(.emptyName) }
        if folders.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) {
            return .failure(.alreadyExists)
        }
        do {
            _ = try ensureSubfolder(named: clean)
            reloadFolders()
            setStatus("フォルダ「\(clean)」を作成しました")
            return .success(clean)
        } catch {
            return .failure(.fileSystemError("フォルダを作成できませんでした"))
        }
    }

    @discardableResult
    func renameFolder(from oldName: String, to newName: String) -> Result<String, FolderOperationError> {
        let cleanNew = FileNaming.sanitizedFolderName(newName)
        guard !cleanNew.isEmpty else { return .failure(.emptyName) }
        if oldName == cleanNew { return .success(cleanNew) }
        if folders.contains(where: { $0.caseInsensitiveCompare(cleanNew) == .orderedSame }) {
            return .failure(.alreadyExists)
        }
        do {
            let root = try ensureDownloadsDirectory()
            let oldURL = root.appendingPathComponent(oldName, isDirectory: true)
            let newURL = root.appendingPathComponent(cleanNew, isDirectory: true)
            guard FileNaming.isDirectChild(oldURL, of: root),
                  FileNaming.isDirectChild(newURL, of: root) else {
                return .failure(.emptyName)
            }
            if FileManager.default.fileExists(atPath: oldURL.path) {
                try FileManager.default.moveItem(at: oldURL, to: newURL)
            } else {
                try FileManager.default.createDirectory(at: newURL, withIntermediateDirectories: true)
            }
            for idx in saved.indices where saved[idx].folderName == oldName {
                saved[idx].folderName = cleanNew
                // HLS(.movpkg)はApple指定の保存場所から一切移動せず、MP4等の直接ファイルのみ相対パスを更新する
                if !saved[idx].isHLS {
                    let fileName = (saved[idx].relativePath as NSString).lastPathComponent
                    let updatedURL = newURL.appendingPathComponent(fileName)
                    if let rel = SavedVideo.relativePath(for: updatedURL) {
                        saved[idx].relativePath = rel
                    }
                }
            }
            persistSaved()
            reloadFolders()
            setStatus("フォルダ名を「\(cleanNew)」に変更しました")
            return .success(cleanNew)
        } catch {
            return .failure(.fileSystemError("フォルダ名を変更できませんでした"))
        }
    }

    func deleteFolder(name: String) {
        guard !name.isEmpty, let root = try? ensureDownloadsDirectory() else { return }
        let folderURL = root.appendingPathComponent(name, isDirectory: true)
        guard FileNaming.isDirectChild(folderURL, of: root) else { return }

        // フォルダ内の動画が消えないよう、先にDownloads直下（未分類）へ移動する
        let videosInFolder = saved.filter { $0.folderName == name }
        for video in videosInFolder {
            _ = moveVideo(video, toFolder: "")
        }

        if FileManager.default.fileExists(atPath: folderURL.path) {
            try? FileManager.default.removeItem(at: folderURL)
        }
        reloadFolders()
        setStatus("フォルダ「\(name)」を削除しました（動画はDownloads直下へ移動）")
    }

    @discardableResult
    func renameVideo(_ item: SavedVideo, to newTitle: String) -> Result<SavedVideo, FolderOperationError> {
        let cleanBase = FileNaming.sanitizedBaseName(newTitle)
        guard !cleanBase.isEmpty else { return .failure(.emptyName) }
        guard let idx = saved.firstIndex(where: { $0.id == item.id }) else {
            return .failure(.fileSystemError("対象の動画が見つかりません"))
        }

        // HLS（.movpkg）はApple指定場所のパッケージ名を変更せず、表示タイトルのみ変更する
        if item.isHLS {
            saved[idx].title = cleanBase
            persistSaved()
            setStatus("「\(cleanBase)」に表示名を変更しました")
            return .success(saved[idx])
        }

        let currentURL = item.fileURL
        let folderURL = currentURL.deletingLastPathComponent()
        let ext = currentURL.pathExtension.isEmpty ? item.format.rawValue : currentURL.pathExtension
        let desiredURL = folderURL.appendingPathComponent(cleanBase).appendingPathExtension(ext)

        if currentURL.standardizedFileURL == desiredURL.standardizedFileURL {
            saved[idx].title = cleanBase
            persistSaved()
            return .success(saved[idx])
        }

        guard let root = try? ensureDownloadsDirectory(),
              FileNaming.isDescendant(desiredURL, of: root) else {
            return .failure(.fileSystemError("不正なファイル名です"))
        }

        let targetURL = FileNaming.uniqueDestination(in: folderURL, baseName: cleanBase, fileExtension: ext)
        do {
            if FileManager.default.fileExists(atPath: currentURL.path) {
                try FileManager.default.moveItem(at: currentURL, to: targetURL)
            }
            if let rel = SavedVideo.relativePath(for: targetURL) {
                saved[idx].relativePath = rel
            }
            saved[idx].title = cleanBase
            persistSaved()
            setStatus("「\(cleanBase)」に名前を変更しました")
            return .success(saved[idx])
        } catch {
            return .failure(.fileSystemError("ファイル名を変更できませんでした"))
        }
    }

    @discardableResult
    func moveVideo(_ item: SavedVideo, toFolder folderName: String) -> Result<SavedVideo, FolderOperationError> {
        let cleanFolder = FileNaming.sanitizedFolderName(folderName)
        guard let idx = saved.firstIndex(where: { $0.id == item.id }) else {
            return .failure(.fileSystemError("対象の動画が見つかりません"))
        }
        if saved[idx].folderName == cleanFolder {
            return .success(saved[idx])
        }

        // HLS（.movpkg）はApple指定の保存場所から一切移動せず、メタデータ上の分類フォルダのみ更新する
        if item.isHLS {
            saved[idx].folderName = cleanFolder
            persistSaved()
            reloadFolders()
            let destLabel = cleanFolder.isEmpty ? "未分類" : cleanFolder
            setStatus("「\(item.title)」の分類を「\(destLabel)」へ変更しました")
            return .success(saved[idx])
        }

        do {
            let targetDir = try cleanFolder.isEmpty
                ? ensureDownloadsDirectory()
                : ensureSubfolder(named: cleanFolder)
            let currentURL = item.fileURL
            let ext = currentURL.pathExtension.isEmpty ? item.format.rawValue : currentURL.pathExtension
            let base = FileNaming.sanitizedBaseName(item.title)
            let destURL = FileNaming.uniqueDestination(in: targetDir, baseName: base.isEmpty ? "Video" : base, fileExtension: ext)
            let root = try ensureDownloadsDirectory()
            guard FileNaming.isDescendant(destURL, of: root) else {
                return .failure(.fileSystemError("移動先のパスが不正です"))
            }
            if FileManager.default.fileExists(atPath: currentURL.path) {
                try FileManager.default.moveItem(at: currentURL, to: destURL)
            }
            if let rel = SavedVideo.relativePath(for: destURL) {
                saved[idx].relativePath = rel
            }
            saved[idx].folderName = cleanFolder
            persistSaved()
            reloadFolders()
            let destLabel = cleanFolder.isEmpty ? "Downloads" : cleanFolder
            setStatus("「\(item.title)」を「\(destLabel)」へ移動しました")
            return .success(saved[idx])
        } catch {
            return .failure(.fileSystemError("ファイルを移動できませんでした"))
        }
    }

    func delete(_ item: SavedVideo) {
        if item.fileExists {
            do {
                try FileManager.default.removeItem(at: item.fileURL)
            } catch {
                setStatus("ファイルを削除できませんでした")
                return
            }
        }
        Task { @MainActor in
            VideoThumbnailGenerator.shared.invalidate(for: item.id.uuidString)
        }
        saved.removeAll { $0.id == item.id }
        persistSaved()
        reloadFolders()
    }

    /// Info.plist設定と保存先・メタデータの整合性を点検して返す
    func storageDiagnosticSummary() -> String {
        let fileSharing = (Bundle.main.object(forInfoDictionaryKey: "UIFileSharingEnabled") as? Bool) ?? false
        let openInPlace = (Bundle.main.object(forInfoDictionaryKey: "LSSupportsOpeningDocumentsInPlace") as? Bool) ?? false
        let directVideos = saved.filter { !$0.isHLS }
        let directExisting = directVideos.filter { $0.fileExists }.count
        let hlsVideos = saved.filter { $0.isHLS }
        let hlsExisting = hlsVideos.filter { $0.fileExists }.count

        var lines: [String] = []
        lines.append("Info.plist UIFileSharingEnabled: \(fileSharing ? "YES (有効)" : "NO")")
        lines.append("Info.plist LSSupportsOpeningDocumentsInPlace: \(openInPlace ? "YES (有効)" : "NO")")
        lines.append("MP4/MOV/M4V (Documents/Downloads): 登録 \(directVideos.count)件 / 実ファイル確認 \(directExisting)件")
        lines.append("オフラインHLS (Library内Apple管理領域): 登録 \(hlsVideos.count)件 / 実パッケージ確認 \(hlsExisting)件")
        lines.append("※iOSの仕様上、「ファイル」アプリには Documents/Downloads 内のMP4/MOV/M4Vのみが表示され、Library内のオフラインHLS(.movpkg)はファイルアプリには表示されません。")
        return lines.joined(separator: "\n")
    }

    // MARK: - 開始処理

    private func launch(_ transfer: Transfer, resumeData: Data?) {
        stateLock.withLock {
            transfer.outcome = nil
            transfer.failureOverride = nil
            transfer.checkedCapacity = false
            transfer.redirectCount = 0
            transfer.isPausing = false
            transfer.fileWriteMilliseconds = nil
            transfer.metricsSummary = nil
            transfer.resetTiming()
        }
        onMain {
            self.updateJob(transfer.jobID) {
                $0.state = .preparing
                if resumeData == nil {
                    $0.receivedBytes = 0
                    $0.expectedBytes = 0
                }
                $0.currentSpeedBytesPerSec = 0
                $0.averageSpeedBytesPerSec = 0
                $0.estimatedRemainingSeconds = nil
                $0.canRetry = false
                $0.canPause = !transfer.candidate.isHLS
                $0.metrics = nil
                $0.diagnosticReport = nil
            }
        }
        if let free = availableCapacity(), free < Self.minimumFreeBytes {
            finish(transfer.jobID, state: .failed("iPhoneの空き容量が不足しています"), name: transfer.baseName)
            return
        }
        if transfer.candidate.isHLS {
            launchHLS(transfer)
        } else {
            launchFile(transfer, resumeData: resumeData)
        }
        let actionText = resumeData != nil ? "再開" : "開始"
        onMain {
            self.setStatus("「\(transfer.baseName)」のダウンロードを\(actionText)しました")
            self.updateBackgroundTask()
        }
    }

    private func launchFile(_ transfer: Transfer, resumeData: Data?) {
        let task: URLSessionDownloadTask
        if let resumeData = resumeData {
            task = fileSession.downloadTask(withResumeData: resumeData)
        } else {
            let request = transfer.context.makeRequest(for: transfer.candidate.url)
            task = fileSession.downloadTask(with: request)
        }
        task.taskDescription = transfer.jobID.uuidString
        task.priority = URLSessionTask.highPriority
        stateLock.withLock {
            tasks[transfer.jobID] = task
        }
        onMain {
            self.updateJob(transfer.jobID) { job in
                let p: Double? = job.expectedBytes > 0
                    ? min(Double(job.receivedBytes) / Double(job.expectedBytes), 1.0)
                    : nil
                job.state = .downloading(progress: p)
            }
        }
        task.resume()
    }

    private func launchHLS(_ transfer: Transfer) {
        // AVFoundation標準のHLS保存。DRM解除や特別な認証トークンの取得はしない。
        // RFC 6265（Domain / Path / Secure / 有効期限）に基づき、宛先URLに一致するCookieのみを渡す。
        var options: [String: Any] = [:]
        let matchedCookies = CookiePolicy.cookies(transfer.context.cookies, matching: transfer.candidate.url)
        if !matchedCookies.isEmpty { options[AVURLAssetHTTPCookiesKey] = matchedCookies }
        if let ua = transfer.context.userAgent, !ua.isEmpty { options[AVURLAssetHTTPUserAgentKey] = ua }

        let asset = AVURLAsset(url: transfer.candidate.url, options: options)
        let configuration = AVAssetDownloadConfiguration(asset: asset, title: transfer.baseName)
        let task = hlsSession.makeAssetDownloadTask(downloadConfiguration: configuration)
        task.taskDescription = transfer.jobID.uuidString
        stateLock.withLock {
            tasks[transfer.jobID] = task
        }
        observations[transfer.jobID] = observeProgress(of: task, jobID: transfer.jobID)
        pendingHLS[transfer.jobID] = PendingHLSRecord(
            jobID: transfer.jobID,
            displayName: transfer.baseName,
            host: transfer.candidate.host,
            folderName: transfer.targetFolder
        )
        persistPendingHLS()
        onMain {
            self.updateJob(transfer.jobID) { $0.state = .downloading(progress: nil) }
        }
        task.resume()
    }

    private func observeProgress(of task: URLSessionTask, jobID: UUID) -> NSKeyValueObservation {
        task.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            guard let self = self else { return }
            let value = progress.fractionCompleted
            let now = ProcessInfo.processInfo.systemUptime
            let shouldUpdate = self.stateLock.withLock { () -> Bool in
                guard let transfer = self.transfers[jobID] else { return true }
                if now - transfer.lastUIUpdateUptime >= Self.uiUpdateInterval || value >= 0.999 {
                    transfer.lastUIUpdateUptime = now
                    return true
                }
                return false
            }
            guard shouldUpdate else { return }
            self.onMain {
                self.updateJob(jobID) { job in
                    if job.state.isActive { job.state = .downloading(progress: min(max(value, 0), 1)) }
                }
            }
        }
    }

    // MARK: - URLSessionDelegate（直接ファイル・fileDelegateQueue上で実行）

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let id = jobID(for: task),
              let transfer = stateLock.withLock({ transfers[id] }) else {
            completionHandler(nil)
            return
        }
        transfer.redirectCount += 1
        guard transfer.redirectCount <= Self.maxRedirects else {
            transfer.failureOverride = "リダイレクトが多すぎるため中止しました。"
            completionHandler(nil)
            task.cancel()
            return
        }
        // 前の宛先のCookie/Authorizationを外し、新しい宛先に一致するCookieだけを付け直す
        guard let next = transfer.context.redirectedRequest(request, from: task.currentRequest?.url) else {
            transfer.failureOverride = "安全でない転送先のため中止しました。"
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        guard let id = jobID(for: downloadTask),
              let transfer = stateLock.withLock({ transfers[id] }) else { return }
        transfer.resetTiming(initialBytes: fileOffset)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let id = jobID(for: downloadTask),
              let transfer = stateLock.withLock({ transfers[id] }) else { return }
        let expected = max(totalBytesExpectedToWrite, 0)
        if !transfer.checkedCapacity && expected > 0 {
            transfer.checkedCapacity = true
            if let free = availableCapacity(), expected + Self.minimumFreeBytes > free {
                transfer.failureOverride = "iPhoneの空き容量が不足しています"
                downloadTask.cancel()
                return
            }
        }

        let now = ProcessInfo.processInfo.systemUptime
        if transfer.initialOffsetBytes == 0 && totalBytesWritten == bytesWritten {
            transfer.resetTiming(initialBytes: 0)
        }

        let sampleDelta = now - transfer.lastSampleUptime
        if sampleDelta >= Self.uiUpdateInterval {
            let bytesDelta = max(totalBytesWritten - transfer.lastSampleBytes, 0)
            let instantSpeed = Double(bytesDelta) / sampleDelta
            if transfer.smoothedSpeedBytesPerSec > 0 {
                transfer.smoothedSpeedBytesPerSec = transfer.smoothedSpeedBytesPerSec * 0.65 + instantSpeed * 0.35
            } else {
                transfer.smoothedSpeedBytesPerSec = instantSpeed
            }
            transfer.lastSampleUptime = now
            transfer.lastSampleBytes = totalBytesWritten
        }

        let isFinished = expected > 0 && totalBytesWritten >= expected
        guard isFinished || (now - transfer.lastUIUpdateUptime >= Self.uiUpdateInterval) else {
            return
        }
        transfer.lastUIUpdateUptime = now

        let elapsed = max(now - transfer.startUptime, 0.001)
        let sessionBytes = max(totalBytesWritten - transfer.initialOffsetBytes, 0)
        let avgSpeed = Double(sessionBytes) / elapsed
        let currentSpeed = transfer.smoothedSpeedBytesPerSec > 0 ? transfer.smoothedSpeedBytesPerSec : avgSpeed
        let eta: Double?
        if expected > totalBytesWritten && currentSpeed > 0 {
            eta = Double(expected - totalBytesWritten) / currentSpeed
        } else {
            eta = nil
        }

        onMain {
            self.updateJob(id) {
                $0.receivedBytes = totalBytesWritten
                $0.expectedBytes = expected
                $0.currentSpeedBytesPerSec = currentSpeed
                $0.averageSpeedBytesPerSec = avgSpeed
                $0.estimatedRemainingSeconds = eta
                $0.state = .downloading(progress: expected > 0 ? min(Double(totalBytesWritten) / Double(expected), 1) : nil)
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // このメソッドから戻ると一時ファイルは削除されるため、バックグラウンドキュー上で検証・移動する
        guard let id = jobID(for: downloadTask),
              let transfer = stateLock.withLock({ transfers[id] }) else { return }
        let writeStart = ProcessInfo.processInfo.systemUptime
        let outcome = processDownloadedFile(at: location, response: downloadTask.response, transfer: transfer)
        let writeMs = (ProcessInfo.processInfo.systemUptime - writeStart) * 1000.0
        stateLock.withLock {
            transfer.fileWriteMilliseconds = writeMs
            transfer.outcome = outcome
            if var summary = transfer.metricsSummary {
                summary.fileWriteMilliseconds = writeMs
                if summary.isServerPacingSuspected && writeMs > 1000 {
                    summary.isServerPacingSuspected = false
                }
                transfer.metricsSummary = summary
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let id = jobID(for: task),
              let transfer = stateLock.withLock({ transfers[id] }) else { return }

        let tx = metrics.transactionMetrics.last { $0.resourceFetchType == .networkLoad } ?? metrics.transactionMetrics.last
        var summary = DownloadMetricsSummary()
        summary.protocolName = tx?.networkProtocolName

        if let s = tx?.domainLookupStartDate, let e = tx?.domainLookupEndDate {
            summary.dnsMilliseconds = max(e.timeIntervalSince(s) * 1000.0, 0)
        }
        if let s = tx?.connectStartDate, let e = tx?.connectEndDate {
            summary.connectMilliseconds = max(e.timeIntervalSince(s) * 1000.0, 0)
        }
        if let s = tx?.secureConnectionStartDate, let e = tx?.secureConnectionEndDate {
            summary.tlsMilliseconds = max(e.timeIntervalSince(s) * 1000.0, 0)
        }
        if let s = tx?.requestStartDate, let e = tx?.responseStartDate {
            summary.ttfbMilliseconds = max(e.timeIntervalSince(s) * 1000.0, 0)
        }

        let bodyBytes = tx?.countOfResponseBodyBytesReceived ?? task.countOfBytesReceived
        let transferSec: Double
        if let rs = tx?.responseStartDate, let re = tx?.responseEndDate, re > rs {
            transferSec = re.timeIntervalSince(rs)
        } else {
            transferSec = max(metrics.taskInterval.duration, 0.001)
        }
        summary.transferSeconds = transferSec
        let avgSpeed = transferSec > 0 ? Double(bodyBytes) / transferSec : 0
        summary.averageSpeedBytesPerSec = avgSpeed

        let writeMs = stateLock.withLock { transfer.fileWriteMilliseconds }
        summary.fileWriteMilliseconds = writeMs

        let fastSetup = (summary.ttfbMilliseconds ?? 0) < 1500
        let fastDisk = (writeMs ?? 0) < 1000
        if bodyBytes >= 2 * 1024 * 1024 && fastSetup && fastDisk && avgSpeed > 0 && avgSpeed < 600 * 1024 {
            summary.isServerPacingSuspected = true
        }

        stateLock.withLock {
            transfer.metricsSummary = summary
        }
        onMain {
            self.updateJob(id) {
                $0.metrics = summary
                if avgSpeed > 0 { $0.averageSpeedBytesPerSec = avgSpeed }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = jobID(for: task) else { return }

        if task is AVAssetDownloadTask {
            stateLock.withLock { tasks[id] = nil }
            onMain {
                self.observations[id] = nil
                self.completeHLS(jobID: id, error: error)
            }
            return
        }

        guard let transfer = stateLock.withLock({ transfers[id] }) else { return }
        let isPausing = stateLock.withLock { transfer.isPausing }
        if isPausing {
            return
        }
        stateLock.withLock {
            tasks[id] = nil
        }

        var finalMetrics = stateLock.withLock { transfer.metricsSummary }
        if var m = finalMetrics, m.fileWriteMilliseconds == nil {
            m.fileWriteMilliseconds = stateLock.withLock { transfer.fileWriteMilliseconds }
            finalMetrics = m
        }

        if let message = stateLock.withLock({ transfer.failureOverride }) {
            finish(id, state: .failed(message), name: transfer.baseName, metrics: finalMetrics)
        } else if let error = error {
            let ns = error as NSError
            if let resumeData = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                stateLock.withLock { transfer.resumeData = resumeData }
            }
            if ns.code == NSURLErrorCancelled && ns.domain == NSURLErrorDomain {
                let paused = stateLock.withLock { transfer.resumeData != nil }
                if !paused {
                    finish(id, state: .cancelled, name: transfer.baseName, metrics: finalMetrics)
                }
            } else {
                finish(id, state: .failed(DownloadErrorMessage.forError(error)), name: transfer.baseName,
                       metrics: finalMetrics, diagnostic: ErrorChainFormatter.describe(error))
            }
        } else if let outcome = stateLock.withLock({ transfer.outcome }) {
            switch outcome {
            case .saved(var video):
                onMain {
                    self.updateJob(id) { $0.state = .verifying }
                }
                Task {
                    let report = await MediaPlayabilityVerifier.verify(url: video.fileURL, isHLS: false)
                    switch report.evaluation {
                    case .verified(let dur):
                        video.verificationState = .verified(durationSeconds: dur)
                        self.onMain {
                            self.addSaved(video)
                            self.reloadFolders()
                        }
                        self.finish(id, state: .completed, name: video.title, metrics: finalMetrics)
                    case .indeterminate(let note):
                        video.verificationState = .indeterminate(note: note, diagnosticDetail: report.detailedReport)
                        self.onMain {
                            self.addSaved(video)
                            self.reloadFolders()
                        }
                        self.finish(id, state: .verificationIndeterminate(note), name: video.title,
                                    metrics: finalMetrics, diagnostic: report.detailedReport)
                    case .failed(let reason):
                        // 検証失敗時もファイルは自動削除せず保持し、「保存データを検証できません」と表示する
                        video.verificationState = .failed(reason: reason, diagnosticDetail: report.detailedReport)
                        self.onMain {
                            self.addSaved(video)
                            self.reloadFolders()
                        }
                        self.finish(id, state: .verificationFailed(reason), name: video.title,
                                    metrics: finalMetrics, diagnostic: report.detailedReport)
                    }
                }
            case .failed(let message):
                finish(id, state: .failed(message), name: transfer.baseName, metrics: finalMetrics)
            }
        } else {
            finish(id, state: .failed("保存できませんでした"), name: transfer.baseName, metrics: finalMetrics)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        onMain {
            let handler = self.backgroundCompletionHandler
            self.backgroundCompletionHandler = nil
            handler?()
        }
    }

    // MARK: - AVAssetDownloadDelegate（HLS）

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                    willDownloadTo location: URL) {
        guard let id = jobID(for: assetDownloadTask) else { return }
        recordHLSLocation(location, for: id)
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let id = jobID(for: assetDownloadTask) else { return }
        recordHLSLocation(location, for: id)
    }

    /// AVFoundationから通知されたローカルURL（.movpkg）をメモリおよび永続レコード（PendingHLSRecord）に保持する。
    /// これにより、バックグラウンドダウンロード中にアプリが再起動した場合でも保存先URLを復元できる。
    private func recordHLSLocation(_ location: URL, for id: UUID) {
        hlsLocations[id] = location
        let rel = SavedVideo.relativePath(for: location)
        let bookmark = try? location.bookmarkData()
        onMain {
            if var record = self.pendingHLS[id] {
                if let rel = rel { record.relativePath = rel }
                if let bookmark = bookmark { record.bookmarkData = bookmark }
                self.pendingHLS[id] = record
                self.persistPendingHLS()
            }
        }
    }

    private func completeHLS(jobID id: UUID, error: Error?) {
        let record = pendingHLS.removeValue(forKey: id)
        persistPendingHLS()
        let location = hlsLocations.removeValue(forKey: id) ?? record?.restoredLocationURL
        let transfer = stateLock.withLock { transfers[id] }
        let name = transfer?.baseName ?? record?.displayName ?? "HLS動画"
        let host = transfer?.candidate.host ?? record?.host
        let folderName = transfer?.targetFolder ?? record?.folderName ?? ""

        if let error = error {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                if let location = location { try? FileManager.default.removeItem(at: location) }
                finish(id, state: .cancelled, name: name)
                return
            }

            let errorChain = ErrorChainFormatter.describe(error)
            let userMessage = Self.hlsMessage(for: error)
            finish(id, state: .failed(userMessage), name: name, diagnostic: "エラー詳細: \(errorChain)\n原因を調査中…")

            // メモリ上にTransfer情報がある場合は、プレイリスト応答・セグメント有効性を非同期診断する
            if let transfer = transfer {
                let candidateURL = transfer.candidate.url
                let context = transfer.context
                let probeSession = self.fileSession
                Task {
                    let report = await HLSDiagnosticProbe.diagnose(
                        error: error,
                        candidateURL: candidateURL,
                        context: context,
                        session: probeSession
                    )
                    self.onMain {
                        self.updateJob(id) {
                            $0.diagnosticReport = report.summaryText
                        }
                    }
                }
            }
            return
        }

        guard let location = location else {
            finish(id, state: .failed("HLSの保存先URLをデリゲートから取得できませんでした"), name: name)
            return
        }

        guard let relative = SavedVideo.relativePath(for: location) ?? record?.relativePath else {
            finish(id, state: .verificationFailed("保存先パスを解決できませんでした"), name: name)
            return
        }

        // Apple推奨のブックマークデータを生成（.movpkg のディレクトリ参照をアプリ再起動後も維持）
        let bookmark = (try? location.bookmarkData()) ?? record?.bookmarkData

        updateJob(id) {
            $0.state = .verifying
        }

        Task {
            let report = await MediaPlayabilityVerifier.verify(url: location, isHLS: true)
            let verificationState: VideoVerificationState
            let finishedState: DownloadState
            switch report.evaluation {
            case .verified(let dur):
                verificationState = .verified(durationSeconds: dur)
                finishedState = .completed
            case .indeterminate(let note):
                verificationState = .indeterminate(
                    note: note,
                    diagnosticDetail: report.detailedReport
                )
                finishedState = .verificationIndeterminate(note)
            case .failed(let reason):
                verificationState = .failed(
                    reason: reason,
                    diagnosticDetail: report.detailedReport
                )
                finishedState = .verificationFailed(reason)
            }

            // 検証結果にかかわらず保存データは自動削除せず保持する
            let video = SavedVideo(
                id: UUID(),
                title: name,
                relativePath: relative,
                format: .hls,
                sourceHost: host,
                createdAt: Date(),
                byteSize: report.byteSize > 0 ? report.byteSize : Self.directorySize(location),
                folderName: folderName,
                bookmarkData: bookmark,
                verificationState: verificationState
            )

            self.onMain {
                self.addSaved(video)
                self.reloadFolders()
                self.finish(
                    id,
                    state: finishedState,
                    name: name,
                    diagnostic: report.detailedReport
                )
            }
        }
    }

    private static func hlsMessage(for error: Error) -> String {
        let ns = error as NSError
        if let meaning = ErrorChainFormatter.knownCodeMeaning(domain: ns.domain, code: ns.code) {
            return "\(meaning)（\(ns.domain) \(ns.code)）"
        }
        if ns.domain == AVFoundationErrorDomain {
            if ns.code == AVError.Code.contentIsProtected.rawValue || ns.code == AVError.Code.contentIsNotAuthorized.rawValue {
                return "保護されたコンテンツは保存できません（\(ns.domain) \(ns.code)）"
            }
            return "この配信方式のオフライン保存には対応していません（\(ns.domain) \(ns.code)）"
        }
        return DownloadErrorMessage.forError(error)
    }

    private func restoreHLSTasks() {
        hlsSession.getAllTasks { [weak self] sessionTasks in
            DispatchQueue.main.async {
                guard let self = self else { return }
                for task in sessionTasks {
                    guard let desc = task.taskDescription, let id = UUID(uuidString: desc),
                          let record = self.pendingHLS[id],
                          self.stateLock.withLock({ self.tasks[id] == nil }) else { continue }
                    self.stateLock.withLock { self.tasks[id] = task }
                    if self.hlsLocations[id] == nil, let restoredURL = record.restoredLocationURL {
                        self.hlsLocations[id] = restoredURL
                    }
                    self.observations[id] = self.observeProgress(of: task, jobID: id)
                    if !self.jobs.contains(where: { $0.id == id }) {
                        self.jobs.append(DownloadJob(id: id, displayName: record.displayName,
                                                     targetFolder: record.folderName,
                                                     isHLS: true, host: record.host,
                                                     state: .downloading(progress: nil),
                                                     canPause: false))
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
            return .failed("このURLはHLS配信でした。候補一覧に「オフラインHLS」がある場合はそちらから保存してください。")
        case .textOrHTML:
            return .failed("動画ではなくWebページ等が返されました。ログイン状態やURLの有効期限を確認してください。")
        case .unknown:
            if mime.hasPrefix("video/"), let ext = transfer.candidate.expectedExtension,
               let f = SavedVideo.Format(rawValue: ext) {
                format = f
            } else {
                return .failed("動画ファイルとして確認できませんでした。")
            }
        }

        do {
            let root = try ensureDownloadsDirectory()
            let cleanFolder = FileNaming.sanitizedFolderName(transfer.targetFolder)
            let folder = try cleanFolder.isEmpty
                ? root
                : ensureSubfolder(named: cleanFolder)
            var destination: URL?
            for _ in 0..<5 {
                let candidateURL = FileNaming.uniqueDestination(in: folder, baseName: transfer.baseName,
                                                                fileExtension: format.rawValue)
                guard FileNaming.isDirectChild(candidateURL, of: folder),
                      FileNaming.isDescendant(candidateURL, of: root) else {
                    return .failed("ファイル名が不正です。別の名前で保存してください。")
                }
                do {
                    try FileManager.default.moveItem(at: location, to: candidateURL)
                    destination = candidateURL
                    break
                } catch let error as CocoaError where error.code == .fileWriteFileExists {
                    continue
                }
            }
            guard let saved = destination else { return .failed("同名のファイルが多すぎるため保存できませんでした。") }
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                   ofItemAtPath: saved.path)
            let size = (try? FileManager.default.attributesOfItem(atPath: saved.path)[.size] as? NSNumber)?.int64Value
            guard let relative = SavedVideo.relativePath(for: saved) else {
                try? FileManager.default.removeItem(at: saved)
                return .failed("保存先を確認できませんでした。")
            }
            return .saved(SavedVideo(id: UUID(), title: transfer.baseName, relativePath: relative, format: format,
                                     sourceHost: transfer.candidate.url.host, createdAt: Date(),
                                     byteSize: size, folderName: cleanFolder))
        } catch {
            return .failed(DownloadErrorMessage.forError(error))
        }
    }

    func downloadsRootURL() -> URL? {
        try? ensureDownloadsDirectory()
    }

    private func ensureDownloadsDirectory() throws -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// iOSの「ファイル」アプリ（「このiPhone内」→「ClipHarbor」→「Downloads」）が空フォルダ時に非表示にならないよう案内ファイルを配置する
    private func ensureFilesAppVisibilityGuide() {
        guard let root = try? ensureDownloadsDirectory() else { return }
        let guideURL = root.appendingPathComponent(Self.guideFileName)
        guard !FileManager.default.fileExists(atPath: guideURL.path) else { return }
        let text = """
        ClipHarbor 保存先フォルダのご案内
        ================================

        1. MP4 / MOV / M4V 動画
           この「Downloads」フォルダ（および作成したサブフォルダ）に実ファイルとして保存されます。
           iOSの「ファイル」アプリから直接再生・移動・共有できます。

        2. オフラインHLS動画（.movpkg）
           AppleのAVFoundation仕様により、アプリ内部のシステム管理領域（Library）に保存されます。
           「ファイル」アプリ上には表示されませんが、ClipHarborアプリ内の「ファイル管理」画面から一覧表示・フォルダ分類・オフライン再生が可能です。
        """
        try? text.write(to: guideURL, atomically: true, encoding: .utf8)
    }

    private func ensureSubfolder(named folderName: String) throws -> URL {
        let root = try ensureDownloadsDirectory()
        let clean = FileNaming.sanitizedFolderName(folderName)
        guard !clean.isEmpty else { return root }
        let sub = root.appendingPathComponent(clean, isDirectory: true)
        guard FileNaming.isDirectChild(sub, of: root) else { return root }
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        return sub
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

    // MARK: - 状態管理（メインスレッド上でUI状態を更新）

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    private func jobID(for task: URLSessionTask) -> UUID? {
        task.taskDescription.flatMap(UUID.init(uuidString:))
    }

    private func updateJob(_ id: UUID, _ change: (inout DownloadJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        var job = jobs[index]
        change(&job)
        if job != jobs[index] { jobs[index] = job }
    }

    private func finish(_ id: UUID, state: DownloadState, name: String,
                        metrics: DownloadMetricsSummary? = nil, diagnostic: String? = nil) {
        onMain {
            let hasTransfer = self.stateLock.withLock { self.transfers[id] != nil }
            switch state {
            case .completed:
                self.stateLock.withLock { self.transfers[id] = nil }
                self.updateJob(id) {
                    $0.state = .completed
                    $0.currentSpeedBytesPerSec = 0
                    $0.estimatedRemainingSeconds = nil
                    $0.canRetry = false
                    $0.canPause = false
                    if let m = metrics { $0.metrics = m }
                    if let d = diagnostic { $0.diagnosticReport = d }
                }
                self.setStatus("保存・初期検証が完了しました：\(name)")
            case .verificationIndeterminate(let note):
                self.stateLock.withLock { self.transfers[id] = nil }
                self.updateJob(id) {
                    $0.state = .verificationIndeterminate(note)
                    $0.currentSpeedBytesPerSec = 0
                    $0.estimatedRemainingSeconds = nil
                    $0.canRetry = false
                    $0.canPause = false
                    if let m = metrics { $0.metrics = m }
                    if let d = diagnostic { $0.diagnosticReport = d }
                }
                self.setStatus("「\(name)」保存完了（非同期読み込み未確定）：\(note)")
            case .verificationFailed(let reason):
                self.updateJob(id) {
                    $0.state = .verificationFailed(reason)
                    $0.currentSpeedBytesPerSec = 0
                    $0.estimatedRemainingSeconds = nil
                    $0.canRetry = hasTransfer
                    $0.canPause = false
                    if let m = metrics { $0.metrics = m }
                    if let d = diagnostic { $0.diagnosticReport = d }
                }
                self.setStatus("「\(name)」保存データを検証できません：\(reason)")
            case .failed(let message):
                self.updateJob(id) {
                    $0.state = state
                    $0.currentSpeedBytesPerSec = 0
                    $0.estimatedRemainingSeconds = nil
                    $0.canRetry = hasTransfer
                    if let m = metrics { $0.metrics = m }
                    if let d = diagnostic { $0.diagnosticReport = d }
                }
                self.setStatus("「\(name)」\(message)")
            case .cancelled:
                self.updateJob(id) {
                    $0.state = state
                    $0.currentSpeedBytesPerSec = 0
                    $0.estimatedRemainingSeconds = nil
                    $0.canRetry = hasTransfer
                    if let m = metrics { $0.metrics = m }
                    if let d = diagnostic { $0.diagnosticReport = d }
                }
                self.setStatus("「\(name)」のダウンロードをキャンセルしました")
            default:
                self.updateJob(id) {
                    $0.state = state
                    if let m = metrics { $0.metrics = m }
                    if let d = diagnostic { $0.diagnosticReport = d }
                }
            }
            self.updateBackgroundTask()
        }
    }

    private func setStatus(_ text: String) {
        onMain {
            self.statusMessage = text
            self.statusClearWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.statusMessage = nil }
            self.statusClearWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
        }
    }

    /// 直接ファイルのダウンロード中にアプリが背面へ移動しても、OSが許す範囲で処理を続ける
    private func updateBackgroundTask() {
        onMain {
            let hasActiveFile = self.jobs.contains { $0.state.isActive && !$0.isHLS }
            MainActor.assumeIsolated {
                if hasActiveFile && self.backgroundTaskID == .invalid {
                    self.backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "ClipHarborDownload") { [weak self] in
                        self?.endBackgroundTask()
                    }
                } else if !hasActiveFile {
                    self.endBackgroundTask()
                }
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

    private func addSaved(_ video: SavedVideo) {
        saved.insert(video, at: 0)
        persistSaved()
    }

    private func persistSaved() {
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: Self.savedKey)
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
                                            sourceHost: nil, createdAt: item.createdAt, byteSize: nil))
                }
            }
            defaults.removeObject(forKey: Self.legacyKey)
            persistSaved()
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
