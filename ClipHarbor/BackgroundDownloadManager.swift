import Foundation
import UIKit
import UserNotifications
import AVFoundation

/// アプリ再起動後もバックグラウンドダウンロードを復元・照合するための永続化レコード
struct PendingBackgroundDownloadRecord: Codable, Equatable {
    let jobID: UUID
    let taskIdentifier: Int
    let originalURL: URL
    let displayName: String
    let host: String
    let folderName: String?
    let sourcePageURL: String?
    let createdAt: Date
    var expectedBytes: Int64
    var receivedBytes: Int64
}

/// iOS標準の URLSessionConfiguration.background によるバックグラウンドダウンロード管理者
/// 認証不要・静的HTTPSファイル（MP4, M4V, MOV, WebM, M4A, MP3 等）を対象とし、
/// 画面ロック中やアプリサスペンド中も通信を継続し、アプリ再起動時にタスクを再接続・復元する。
final class BackgroundDownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = BackgroundDownloadManager()
    static let sessionIdentifier = "com.junald69.clipharbor.background-download"
    private static let pendingKey = "clipHarborPendingBackgroundDownloads_v1"
    private static let minimumFreeBytes: Int64 = 100 * 1024 * 1024 // 100MB

    /// AppDelegateから渡される、バックグラウンドURLSession完了時のハンドラー
    var backgroundCompletionHandler: (() -> Void)?

    /// テスト容易性のためのUserDefaultsおよびダウンロード先ディレクトリ注入
    let userDefaults: UserDefaults
    let customDownloadsRootURL: URL?
    /// テスト容易性のための空き容量プロバイダー
    var customAvailableCapacityProvider: (() -> Int64?)? = nil

    /// 進行中タスクのメタデータ管理 [UUID: PendingBackgroundDownloadRecord]
    private(set) var pendingRecords: [UUID: PendingBackgroundDownloadRecord] = [:]
    /// URLSessionTaskIdentifier -> Job UUID の逆引きマップ
    private var taskIDToJobMap: [Int: UUID] = [:]
    /// セッションタスク参照 [UUID: URLSessionDownloadTask]
    private var activeTasks: [UUID: URLSessionDownloadTask] = [:]
    /// 完了処理の二重実行防止用セット
    private var processingJobIDs: Set<UUID> = []
    /// 排他制御用ロック
    private let lock = NSRecursiveLock()

    /// URLSession（バックグラウンドセッション）
    private(set) lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    init(userDefaults: UserDefaults = .standard, customDownloadsRootURL: URL? = nil) {
        self.userDefaults = userDefaults
        self.customDownloadsRootURL = customDownloadsRootURL
        super.init()
        loadPendingRecords()
    }

    // MARK: - 適格性判定（Scope Check）

    /// 対象のダウンロード候補がバックグラウンドダウンロード（URLSessionConfiguration.background）の要件を満たすか判定する
    /// - HTTPS必須（非暗号化HTTPは除外）
    /// - HLS・DRMは除外
    /// - 認証Cookie・機密ヘッダーが必須のものは除外（DL-04規約順守・前景セッションで実行）
    /// - 静的メディアファイル形式（MP4, M4V, MOV, WebM, M4A, MP3 等）に限定
    static func isEligible(candidate: MediaCandidate, context: RequestContext) -> Bool {
        // 1. HTTPS必須
        guard let scheme = candidate.url.scheme?.lowercased(), scheme == "https" else {
            return false
        }
        // 機密認証情報の埋め込みURL（ユーザー名・パスワード）は除外
        if candidate.url.user != nil || candidate.url.password != nil {
            return false
        }
        // 2. HLSは対象外（前景またはAVAssetDownload）
        guard !candidate.isHLS else {
            return false
        }
        // 3. クッキーやセッション認証を要求するものは対象外（DL-04規約順守・前景セッション維持）
        let matchingCookies = CookiePolicy.cookies(context.cookies, matching: candidate.url)
        guard matchingCookies.isEmpty else {
            return false
        }
        // 4. 静的メディアファイル形式の判定
        switch candidate.kind {
        case .file(let type):
            switch type {
            case .mp4, .m4v, .mov, .webm:
                return true
            case .unknown:
                let ext = candidate.url.pathExtension.lowercased()
                return ["mp4", "m4v", "mov", "webm", "m4a", "mp3"].contains(ext)
            }
        case .hls:
            return false
        }
    }

    // MARK: - ダウンロード開始・管理

    /// バックグラウンドダウンロードを開始する
    @discardableResult
    func startDownload(
        jobID: UUID,
        url: URL,
        displayName: String,
        host: String,
        folderName: String?,
        sourcePageURL: String?
    ) -> URLSessionDownloadTask? {
        lock.lock()
        defer { lock.unlock() }

        // 機密URL保護：埋め込みクレデンシャルの除去
        var cleanURL = url
        if var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            if comps.user != nil || comps.password != nil {
                comps.user = nil
                comps.password = nil
                if let stripped = comps.url {
                    cleanURL = stripped
                }
            }
        }

        // 保存元WebページURLのサニタイズ（機密クエリパラメータ等の除去）
        let cleanSourcePageURL = sourcePageURL.flatMap { SourceURLPolicy.sanitize(URL(string: $0)) }

        // 同一URLの重複ダウンロード防止（既にアクティブに実行中のタスクがある場合は二重起動しない）
        if let existing = pendingRecords.values.first(where: { $0.originalURL == cleanURL }),
           let activeTask = activeTasks[existing.jobID],
           activeTask.state == .running || activeTask.state == .suspended {
            return activeTask
        }

        // ストレージ容量チェック
        if let free = availableCapacity(), free < Self.minimumFreeBytes {
            DispatchQueue.main.async {
                DownloadCenter.shared.finishBackgroundJob(
                    id: jobID,
                    state: .failed(NSLocalizedString("Insufficient storage available on iPhone", comment: "")),
                    name: displayName
                )
            }
            return nil
        }

        var request = URLRequest(url: cleanURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 6 * 60 * 60

        let task = session.downloadTask(with: request)
        task.taskDescription = jobID.uuidString

        let record = PendingBackgroundDownloadRecord(
            jobID: jobID,
            taskIdentifier: task.taskIdentifier,
            originalURL: cleanURL,
            displayName: displayName,
            host: host,
            folderName: folderName,
            sourcePageURL: cleanSourcePageURL,
            createdAt: Date(),
            expectedBytes: 0,
            receivedBytes: 0
        )

        pendingRecords[jobID] = record
        taskIDToJobMap[task.taskIdentifier] = jobID
        activeTasks[jobID] = task
        persistPendingRecords()

        task.resume()
        return task
    }

    /// ダウンロードのキャンセル
    func cancel(jobID: UUID) {
        lock.lock()
        let task = activeTasks.removeValue(forKey: jobID)
        var displayName = "Download"
        if let record = pendingRecords[jobID] {
            displayName = record.displayName
            taskIDToJobMap.removeValue(forKey: record.taskIdentifier)
            // 再試行のために record は pendingRecords に残し、taskIdentifier を無効化
            let inactiveRecord = PendingBackgroundDownloadRecord(
                jobID: record.jobID,
                taskIdentifier: -1,
                originalURL: record.originalURL,
                displayName: record.displayName,
                host: record.host,
                folderName: record.folderName,
                sourcePageURL: record.sourcePageURL,
                createdAt: record.createdAt,
                expectedBytes: record.expectedBytes,
                receivedBytes: record.receivedBytes
            )
            pendingRecords[jobID] = inactiveRecord
            persistPendingRecords()
        }
        lock.unlock()

        task?.cancel()
        DispatchQueue.main.async {
            DownloadCenter.shared.finishBackgroundJob(
                id: jobID,
                state: .cancelled,
                name: displayName
            )
        }
    }

    /// 失敗またはキャンセルしたタスクの安全な再試行
    func retry(jobID: UUID, folderName: String? = nil) {
        lock.lock()
        guard let record = pendingRecords[jobID] else {
            lock.unlock()
            return
        }
        // 既存のアクティブタスクがあれば破棄
        if let existingTask = activeTasks.removeValue(forKey: jobID) {
            taskIDToJobMap.removeValue(forKey: existingTask.taskIdentifier)
            existingTask.cancel()
        }

        var request = URLRequest(url: record.originalURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 6 * 60 * 60

        let task = session.downloadTask(with: request)
        task.taskDescription = jobID.uuidString

        let targetFolder = folderName ?? record.folderName
        let newRecord = PendingBackgroundDownloadRecord(
            jobID: jobID,
            taskIdentifier: task.taskIdentifier,
            originalURL: record.originalURL,
            displayName: record.displayName,
            host: record.host,
            folderName: targetFolder,
            sourcePageURL: record.sourcePageURL,
            createdAt: Date(),
            expectedBytes: 0,
            receivedBytes: 0
        )
        pendingRecords[jobID] = newRecord
        taskIDToJobMap[task.taskIdentifier] = jobID
        activeTasks[jobID] = task
        persistPendingRecords()
        lock.unlock()

        task.resume()
    }

    /// 履歴からの除外
    func dismiss(jobID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        let record = pendingRecords.removeValue(forKey: jobID)
        if let tID = record?.taskIdentifier {
            taskIDToJobMap.removeValue(forKey: tID)
        }
        activeTasks.removeValue(forKey: jobID)
        persistPendingRecords()
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        lock.lock()
        guard let jobID = taskIDToJobMap[downloadTask.taskIdentifier],
              var record = pendingRecords[jobID] else {
            lock.unlock()
            return
        }
        record.receivedBytes = totalBytesWritten
        let expected = max(totalBytesExpectedToWrite, 0)
        record.expectedBytes = expected
        pendingRecords[jobID] = record
        lock.unlock()

        // 容量監視：最低空き容量および残り書き込み所要容量の確認
        let remainingBytes = max(expected - totalBytesWritten, 0)
        if let free = availableCapacity() {
            if free < Self.minimumFreeBytes || (expected > 0 && remainingBytes + Self.minimumFreeBytes > free) {
                downloadTask.cancel()
                DispatchQueue.main.async {
                    DownloadCenter.shared.finishBackgroundJob(
                        id: jobID,
                        state: .failed(NSLocalizedString("Insufficient storage available on iPhone", comment: "")),
                        name: record.displayName
                    )
                }
                return
            }
        }

        let progressValue: Double? = expected > 0 ? min(Double(totalBytesWritten) / Double(expected), 1.0) : nil
        DispatchQueue.main.async {
            DownloadCenter.shared.updateJobProgress(
                id: jobID,
                receivedBytes: totalBytesWritten,
                expectedBytes: expected,
                progress: progressValue
            )
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        lock.lock()
        guard let jobID = taskIDToJobMap[downloadTask.taskIdentifier],
              let record = pendingRecords[jobID] else {
            lock.unlock()
            return
        }
        // 二重保存防止
        if processingJobIDs.contains(jobID) {
            lock.unlock()
            return
        }
        processingJobIDs.insert(jobID)
        lock.unlock()

        let outcome = processDownloadedFile(at: location, response: downloadTask.response, record: record)

        lock.lock()
        pendingRecords.removeValue(forKey: jobID)
        taskIDToJobMap.removeValue(forKey: downloadTask.taskIdentifier)
        activeTasks.removeValue(forKey: jobID)
        persistPendingRecords()
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            switch outcome {
            case .saved(let savedVideo, _):
                if let subfolder = record.folderName, !subfolder.isEmpty {
                    _ = VideoFolderManager.shared.createFolder(name: subfolder)
                }
                VideoFolderManager.shared.syncWithFileSystemAndSavedVideos()
                if let video = savedVideo {
                    DownloadCenter.shared.addSavedVideoFromBackground(video)
                    DownloadCenter.shared.notifyVideoSaved(jobID: jobID, video: video)
                }
                DownloadCenter.shared.finishBackgroundJob(
                    id: jobID,
                    state: .completed,
                    name: record.displayName
                )
                self?.sendLocalNotification(for: record.displayName)
                NotificationCenter.default.post(name: NSNotification.Name("ManagedFilesDidChangeNotification"), object: nil)

            case .failed(let message):
                DownloadCenter.shared.finishBackgroundJob(
                    id: jobID,
                    state: .failed(message),
                    name: record.displayName
                )
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard let jobID = taskIDToJobMap[task.taskIdentifier],
              let record = pendingRecords[jobID] else {
            lock.unlock()
            return
        }
        // didFinishDownloadingTo で処理が既に完了している場合は何もしない
        if processingJobIDs.contains(jobID) {
            processingJobIDs.remove(jobID)
            lock.unlock()
            return
        }

        taskIDToJobMap.removeValue(forKey: task.taskIdentifier)
        activeTasks.removeValue(forKey: jobID)
        // 再試行のために pendingRecords には保持し、taskIdentifier を -1 に無効化
        let inactiveRecord = PendingBackgroundDownloadRecord(
            jobID: record.jobID,
            taskIdentifier: -1,
            originalURL: record.originalURL,
            displayName: record.displayName,
            host: record.host,
            folderName: record.folderName,
            sourcePageURL: record.sourcePageURL,
            createdAt: record.createdAt,
            expectedBytes: record.expectedBytes,
            receivedBytes: record.receivedBytes
        )
        pendingRecords[jobID] = inactiveRecord
        persistPendingRecords()
        lock.unlock()

        DispatchQueue.main.async {
            if let error = error {
                let ns = error as NSError
                if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                    DownloadCenter.shared.finishBackgroundJob(id: jobID, state: .cancelled, name: record.displayName)
                } else {
                    DownloadCenter.shared.finishBackgroundJob(id: jobID, state: .failed(DownloadErrorMessage.forError(error)), name: record.displayName)
                }
            } else {
                DownloadCenter.shared.finishBackgroundJob(id: jobID, state: .failed(NSLocalizedString("Could not save (HTTP 500)", comment: "")), name: record.displayName)
            }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            let handler = self.backgroundCompletionHandler
            self.backgroundCompletionHandler = nil
            handler?()
        }
    }

    // MARK: - ファイル検証・アトミック保存処理

    enum Outcome: Equatable {
        case saved(SavedVideo?, URL)
        case failed(String)
    }

    /// ダウンロード完了ファイルを安全に検証し、Documents/Downloads へアトミック移動する
    func processDownloadedFile(at location: URL, response: URLResponse?, record: PendingBackgroundDownloadRecord) -> Outcome {
        // 1. HTTPステータスチェック（404, 500等のエラーページを保存させない）
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            return .failed(DownloadErrorMessage.forHTTPStatus(http.statusCode))
        }

        // 2. MIMEタイプチェック（HTML/テキスト応答の拒否）
        let mime = response?.mimeType?.lowercased() ?? ""
        if mime.hasPrefix("text/") || mime.contains("html") {
            return .failed(NSLocalizedString("This URL cannot be identified as a video file.", comment: ""))
        }

        // 3. マジックナンバーチェック（偽装HTMLや空ファイルの排除）
        let sniffed = MediaSniffer.sniff(fileAt: location)
        if sniffed == .textOrHTML || sniffed == .hlsPlaylist {
            return .failed(NSLocalizedString("This URL cannot be identified as a video file.", comment: ""))
        }

        // 4. 拡張子とフォーマット判定
        let ext: String
        let savedFormat: SavedVideo.Format?

        switch sniffed {
        case .mp4:
            ext = "mp4"
            savedFormat = .mp4
        case .m4v:
            ext = "m4v"
            savedFormat = .m4v
        case .mov:
            ext = "mov"
            savedFormat = .mov
        case .webm:
            ext = "webm"
            savedFormat = .webm
        case .m4a:
            ext = "m4a"
            savedFormat = .m4a
        case .mp3:
            ext = "mp3"
            savedFormat = .mp3
        case .unknown:
            let pathExt = record.originalURL.pathExtension.lowercased()
            if ["mp4", "m4v", "mov", "webm", "m4a", "mp3"].contains(pathExt) {
                ext = pathExt
                savedFormat = SavedVideo.Format(rawValue: pathExt)
            } else if mime.hasPrefix("video/") {
                ext = "mp4"
                savedFormat = .mp4
            } else if mime.hasPrefix("audio/") {
                ext = "m4a"
                savedFormat = .m4a
            } else {
                return .failed(NSLocalizedString("This URL cannot be identified as a video file.", comment: ""))
            }
        default:
            return .failed(NSLocalizedString("This URL cannot be identified as a video file.", comment: ""))
        }

        // 5. 保存先ディレクトリの準備
        do {
            let baseDownloadsFolder = try ensureDownloadsDirectory()
            var targetFolder = baseDownloadsFolder
            if let subfolder = record.folderName, !subfolder.isEmpty {
                targetFolder = baseDownloadsFolder.appendingPathComponent(subfolder, isDirectory: true)
                try FileManager.default.createDirectory(at: targetFolder, withIntermediateDirectories: true)
            }

            // 6. 同名ファイル衝突回避（既存ファイルを上書き・破壊しない）
            var destination: URL?
            for _ in 0..<10 {
                let candidateURL = FileNaming.uniqueDestination(in: targetFolder, baseName: record.displayName, fileExtension: ext)
                guard FileNaming.isDirectChild(candidateURL, of: targetFolder) else {
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

            guard let savedURL = destination else {
                return .failed(NSLocalizedString("A folder with the same name already exists.", comment: ""))
            }

            // 7. セキュリティ属性の設定
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: savedURL.path
            )

            // 8. ファイルサイズ取得
            let size = (try? FileManager.default.attributesOfItem(atPath: savedURL.path)[.size] as? NSNumber)?.int64Value

            // 9. SavedVideoメタデータ生成
            if let format = savedFormat, let relative = SavedVideo.relativePath(for: savedURL) {
                let video = SavedVideo(
                    id: record.jobID,
                    title: record.displayName,
                    relativePath: relative,
                    format: format,
                    sourceHost: record.host,
                    createdAt: Date(),
                    byteSize: size,
                    sourcePageURL: record.sourcePageURL
                )
                return .saved(video, savedURL)
            } else {
                return .saved(nil, savedURL)
            }
        } catch {
            return .failed(DownloadErrorMessage.forError(error))
        }
    }

    // MARK: - コールドローンチ再接続・復元（Cold Launch Reconnection）

    /// アプリ再起動時、OSが継続実行しているバックグラウンドタスクと再接続し、
    /// App Switcherでのスワイプ終了等で消滅したタスクを検知して安全にクリーンアップする
    func restoreTasks() {
        session.getAllTasks { [weak self] tasks in
            guard let self = self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }

            let activeTaskIDs = Set(tasks.map { $0.taskIdentifier })
            var activeJobsToRestore: [DownloadJob] = []
            var deadJobIDs: [UUID] = []

            for (jobID, record) in self.pendingRecords {
                if activeTaskIDs.contains(record.taskIdentifier) {
                    if let task = tasks.first(where: { $0.taskIdentifier == record.taskIdentifier }) as? URLSessionDownloadTask {
                        self.activeTasks[jobID] = task
                        self.taskIDToJobMap[task.taskIdentifier] = jobID

                        let progress: Double? = record.expectedBytes > 0 ? min(Double(record.receivedBytes) / Double(record.expectedBytes), 1.0) : nil
                        let job = DownloadJob(
                            id: jobID,
                            displayName: record.displayName,
                            isHLS: false,
                            host: record.host,
                            state: .downloading(progress: progress),
                            receivedBytes: record.receivedBytes,
                            expectedBytes: record.expectedBytes,
                            canRetry: false,
                            isBackground: true
                        )
                        activeJobsToRestore.append(job)
                    }
                } else {
                    // タスクがOSにより破棄された（App Switcher強制終了等）
                    deadJobIDs.append(jobID)
                }
            }

            for id in deadJobIDs {
                if let record = self.pendingRecords.removeValue(forKey: id) {
                    self.taskIDToJobMap.removeValue(forKey: record.taskIdentifier)
                    DispatchQueue.main.async {
                        DownloadCenter.shared.finishBackgroundJob(
                            id: id,
                            state: .failed(NSLocalizedString("The download was interrupted because the app was closed.", comment: "")),
                            name: record.displayName
                        )
                    }
                }
            }
            self.persistPendingRecords()

            if !activeJobsToRestore.isEmpty {
                DispatchQueue.main.async {
                    for job in activeJobsToRestore {
                        DownloadCenter.shared.restoreBackgroundJob(job)
                    }
                }
            }
        }
    }

    // MARK: - 永続化と補助処理

    private func loadPendingRecords() {
        guard let data = userDefaults.data(forKey: Self.pendingKey),
              let decoded = try? JSONDecoder().decode([PendingBackgroundDownloadRecord].self, from: data) else {
            return
        }
        for record in decoded {
            pendingRecords[record.jobID] = record
            taskIDToJobMap[record.taskIdentifier] = record.jobID
        }
    }

    private func persistPendingRecords() {
        let list = Array(pendingRecords.values)
        if let data = try? JSONEncoder().encode(list) {
            userDefaults.set(data, forKey: Self.pendingKey)
        }
    }

    private func ensureDownloadsDirectory() throws -> URL {
        if let custom = customDownloadsRootURL {
            try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
            return custom
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func availableCapacity() -> Int64? {
        if let custom = customAvailableCapacityProvider {
            return custom()
        }
        let url = customDownloadsRootURL ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private func sendLocalNotification(for title: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("Download Complete", comment: "")
        content.body = String(format: NSLocalizedString("Successfully downloaded \"%@\"", comment: ""), title)
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    // MARK: - テスト用ヘルパー

    func appendPendingRecordForTesting(_ record: PendingBackgroundDownloadRecord) {
        lock.lock()
        defer { lock.unlock() }
        pendingRecords[record.jobID] = record
        taskIDToJobMap[record.taskIdentifier] = record.jobID
        persistPendingRecords()
    }
}
