import Foundation

/// 保存済み動画のメタデータ。**元の動画URLは保存しない**（トークン漏えい防止 / DL-04）。
struct SavedVideo: Identifiable, Codable, Equatable {
    enum Format: String, Codable {
        case mp4, m4v, mov, webm, hls

        var label: String {
            switch self {
            case .hls: return "オフラインHLS"
            default: return rawValue.uppercased()
            }
        }
    }

    let id: UUID
    var title: String
    /// ホームディレクトリからの相対パス。アプリ更新・再インストールでコンテナの絶対パスが変わっても参照できる。
    var relativePath: String
    let format: Format
    /// 表示用の配信元ドメインのみ（パス・クエリは保存しない）
    let sourceHost: String?
    let createdAt: Date
    var byteSize: Int64?

    var fileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(relativePath)
    }
    var isHLS: Bool { format == .hls }
    var fileExists: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    static func relativePath(for url: URL) -> String? {
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.resolvingSymlinksInPath().path
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = home.hasSuffix("/") ? home : home + "/"
        if target.hasPrefix(prefix) { return String(target.dropFirst(prefix.count)) }
        // AVAssetDownloadの保存先はホーム基準の相対URLで渡される場合がある
        let relative = url.relativePath
        if !relative.hasPrefix("/") && !relative.isEmpty { return relative }
        // /private/var と /var の差異などに備え、既知のフォルダ名以降を使う
        for marker in ["/Documents/", "/Library/"] {
            if let range = target.range(of: marker) {
                return String(target[target.index(after: range.lowerBound)...])
            }
        }
        return nil
    }
}

/// v1形式（sourceURLStringを含む）からの移行用。sourceURLStringは読み込まず破棄する。
struct LegacySavedVideoV1: Decodable {
    let id: UUID
    let title: String
    let fileURLString: String
    let format: String
    let createdAt: Date
}

enum DownloadState: Equatable {
    case preparing
    case downloading(progress: Double?)
    case completed
    case failed(String)
    case cancelled

    var label: String {
        switch self {
        case .preparing: return "準備中"
        case .downloading(let p):
            if let p = p { return "ダウンロード中 \(Int(p * 100))%" }
            return "ダウンロード中"
        case .completed: return "保存完了"
        case .failed(let message): return "保存失敗：\(message)"
        case .cancelled: return "キャンセルしました"
        }
    }

    var isActive: Bool {
        switch self {
        case .preparing, .downloading: return true
        default: return false
        }
    }
}

/// 進行中・失敗したダウンロード（UI表示用）
struct DownloadJob: Identifiable, Equatable {
    let id: UUID
    var displayName: String
    let isHLS: Bool
    let host: String
    var state: DownloadState
    var receivedBytes: Int64 = 0
    var expectedBytes: Int64 = 0
    /// 同じアプリ起動中であれば再試行できる（URLはメモリ上のみ）
    var canRetry: Bool = false
}

/// アプリ再起動後もHLSのバックグラウンドダウンロードを表示するための情報（URLは含まない）
struct PendingHLSRecord: Codable {
    let jobID: UUID
    let displayName: String
    let host: String
}
