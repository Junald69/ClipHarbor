import Foundation
import WebKit
import AVFoundation

struct SavedVideo: Identifiable, Codable {
    let id: UUID
    let title: String
    let fileURLString: String
    let sourceURLString: String
    let format: String
    let createdAt: Date

    var fileURL: URL? { URL(string: fileURLString) }
    var isHLS: Bool { format == "HLS" }
}

/// ユーザーが保存操作をした動画のみダウンロードする。回数・件数によるアプリ内制限はない。
/// MP4等はDocuments/Downloadsへ、HLSはAppleが指定したオフライン保存先へ格納する。
final class DownloadCenter: NSObject, ObservableObject, URLSessionDownloadDelegate, AVAssetDownloadDelegate {
    @Published private(set) var saved: [SavedVideo] = []
    @Published private(set) var activeCount = 0
    @Published var statusMessage: String?

    private struct Pending {
        let candidate: MediaCandidate
        var hlsDestination: URL?
    }
    private var pending: [String: Pending] = [:]
    private static let storageKey = "clipHarborSavedVideosV1"

    private lazy var fileSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    private lazy var hlsSession: AVAssetDownloadURLSession = {
        let id = (Bundle.main.bundleIdentifier ?? "ClipHarbor") + ".HLS"
        let config = URLSessionConfiguration.background(withIdentifier: id)
        config.isDiscretionary = false
        return AVAssetDownloadURLSession(configuration: config, assetDownloadDelegate: self, delegateQueue: .main)
    }()

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let items = try? JSONDecoder().decode([SavedVideo].self, from: data) {
            saved = items
        }
    }

    func start(_ candidate: MediaCandidate, from webView: WKWebView) {
        statusMessage = "ダウンロードを準備しています…"
        if candidate.kind == .hls {
            // AVFoundationによる標準HLS保存。DRM解除や特別な認証トークンの取得はしない。
            let asset = AVURLAsset(url: candidate.url)
            let configuration = AVAssetDownloadConfiguration(asset: asset, title: candidate.pageTitle)
            let task = hlsSession.makeAssetDownloadTask(downloadConfiguration: configuration)
            pending["hls-\(task.taskIdentifier)"] = Pending(candidate: candidate)
            activeCount += 1
            statusMessage = "HLSの保存を開始しました（対応する配信のみ）"
            task.resume()
        } else {
            // WebViewでログインした一般的なサイト向けに、対象ドメインのCookieとRefererを引き継ぐ。
            let pageURL = webView.url
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self, weak webView] cookies in
                guard let self = self else { return }
                webView?.evaluateJavaScript("navigator.userAgent") { result, _ in
                    self.startDirectFile(candidate, pageURL: pageURL, cookies: cookies,
                                         userAgent: result as? String)
                }
                if webView == nil {
                    self.startDirectFile(candidate, pageURL: pageURL, cookies: cookies, userAgent: nil)
                }
            }
        }
    }

    private func startDirectFile(_ candidate: MediaCandidate, pageURL: URL?,
                                 cookies: [HTTPCookie], userAgent: String?) {
        var request = URLRequest(url: candidate.url)
        request.timeoutInterval = 90
        if let pageURL = pageURL { request.setValue(pageURL.absoluteString, forHTTPHeaderField: "Referer") }
        if let userAgent = userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        if let host = candidate.url.host?.lowercased() {
            let matching = cookies.filter { cookie in
                let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return (host == domain || host.hasSuffix("." + domain))
                    && candidate.url.path.hasPrefix(cookie.path)
                    && (!cookie.isSecure || candidate.url.scheme == "https")
            }
            for (key, value) in HTTPCookie.requestHeaderFields(with: matching) {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        let task = fileSession.downloadTask(with: request)
        pending["file-\(task.taskIdentifier)"] = Pending(candidate: candidate)
        activeCount += 1
        statusMessage = "動画ファイルの保存を開始しました"
        task.resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let key = "file-\(downloadTask.taskIdentifier)"
        guard let transfer = pending[key] else { return }
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(response.statusCode) {
            statusMessage = "保存できませんでした（HTTP \(response.statusCode)）"
            return
        }
        if let mime = downloadTask.response?.mimeType?.lowercased(),
           mime.contains("text/html") || mime.contains("application/json") {
            statusMessage = "動画ではなくWebページ/JSONが返されました。認証や期限をご確認ください。"
            return
        }

        do {
            let folder = try ensureDownloadsDirectory()
            let fileExtension = transfer.candidate.url.pathExtension.isEmpty
                ? "mp4" : transfer.candidate.url.pathExtension.lowercased()
            let filename = uniqueFilename(title: transfer.candidate.pageTitle, extension: fileExtension)
            let destination = folder.appendingPathComponent(filename)
            try FileManager.default.moveItem(at: location, to: destination)
            addSaved(url: destination, candidate: transfer.candidate, format: fileExtension.uppercased())
            statusMessage = "保存しました：\(filename)"
        } catch {
            statusMessage = "ファイルの保存に失敗しました：\(error.localizedDescription)"
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        // プログレスバーを追加する場合はこのコールバックを利用する。
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                    willDownloadTo location: URL) {
        let key = "hls-\(assetDownloadTask.taskIdentifier)"
        pending[key]?.hlsDestination = location
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        let isHLS = task is AVAssetDownloadTask
        let key = "\(isHLS ? "hls" : "file")-\(task.taskIdentifier)"
        guard let transfer = pending.removeValue(forKey: key) else { return }
        activeCount = max(0, activeCount - 1)

        if let error = error {
            statusMessage = "保存に失敗しました：\(error.localizedDescription)"
            return
        }
        if isHLS {
            guard let location = transfer.hlsDestination else {
                statusMessage = "HLSの保存先を取得できませんでした"
                return
            }
            // HLSパッケージはApple指定のディレクトリから移動しない。
            addSaved(url: location, candidate: transfer.candidate, format: "HLS")
            statusMessage = "HLS動画をオフライン保存しました"
        }
    }

    func delete(_ item: SavedVideo) {
        // AppleのHLSサンプルに従い、HLSパッケージも保存場所で削除する。
        if let url = item.fileURL {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                statusMessage = "ファイルを削除できませんでした：\(error.localizedDescription)"
                return
            }
        }
        saved.removeAll { $0.id == item.id }
        persist()
    }

    private func addSaved(url: URL, candidate: MediaCandidate, format: String) {
        saved.insert(SavedVideo(id: UUID(), title: candidate.pageTitle,
                                fileURLString: url.absoluteString,
                                sourceURLString: candidate.url.absoluteString,
                                format: format, createdAt: Date()), at: 0)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private func ensureDownloadsDirectory() throws -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func uniqueFilename(title: String, extension ext: String) -> String {
        let sanitized = title.replacingOccurrences(of: #"[/\\:*?\"<>|\n\r]"#,
                                                   with: "_", options: .regularExpression)
        let base = String(sanitized.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
        let safeBase = base.isEmpty ? "Video" : base
        return "\(safeBase)_\(UUID().uuidString.prefix(8)).\(ext)"
    }
}
