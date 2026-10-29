import Foundation

/// 保存済み動画のメタデータ。**元の動画URLは保存しない**（トークン漏えい防止 / DL-04）。
struct SavedVideo: Identifiable, Codable, Equatable {
    enum Format: String, Codable {
        case mp4, m4v, mov, webm, hls
        case jpeg, jpg, png, gif, heic

        var isImage: Bool {
            switch self {
            case .jpeg, .jpg, .png, .gif, .heic:
                return true
            case .mp4, .m4v, .mov, .webm, .hls:
                return false
            }
        }

        var isVideo: Bool { !isImage }

        var label: String {
            switch self {
            case .hls: return NSLocalizedString("Offline HLS", comment: "")
            case .jpeg, .jpg: return "JPEG"
            case .png: return "PNG"
            case .gif: return "GIF"
            case .heic: return "HEIC"
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
    /// 保存元WebページのURL（動画の直接URLではなく、閲覧していたページURL。クレデンシャル・機密パラメータ除去済み）
    var sourcePageURL: String? = nil
    /// お気に入りフラグ（星アイコン表示と連動）
    var isFavorite: Bool = false

    init(
        id: UUID,
        title: String,
        relativePath: String,
        format: Format,
        sourceHost: String?,
        createdAt: Date,
        byteSize: Int64?,
        sourcePageURL: String? = nil,
        isFavorite: Bool = false
    ) {
        self.id = id
        self.title = title
        self.relativePath = relativePath
        self.format = format
        self.sourceHost = sourceHost
        self.createdAt = createdAt
        self.byteSize = byteSize
        self.sourcePageURL = sourcePageURL
        self.isFavorite = isFavorite
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.title = try container.decode(String.self, forKey: .title)
        self.relativePath = try container.decode(String.self, forKey: .relativePath)
        self.format = try container.decode(Format.self, forKey: .format)
        self.sourceHost = try container.decodeIfPresent(String.self, forKey: .sourceHost)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.byteSize = try container.decodeIfPresent(Int64.self, forKey: .byteSize)
        self.sourcePageURL = try container.decodeIfPresent(String.self, forKey: .sourcePageURL)
        self.isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
    }

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
        case .preparing: return NSLocalizedString("Preparing…", comment: "")
        case .downloading(let p):
            if let p = p { return String(format: NSLocalizedString("Downloading %lld%%", comment: ""), Int64(p * 100)) }
            return NSLocalizedString("Downloading…", comment: "")
        case .completed: return NSLocalizedString("Saved", comment: "")
        case .failed(let message): return String(format: NSLocalizedString("Save failed: %@", comment: ""), message)
        case .cancelled: return NSLocalizedString("Cancelled", comment: "")
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

/// アプリ再起動後もHLSのバックグラウンドダウンロードを表示するための情報
struct PendingHLSRecord: Codable {
    let jobID: UUID
    let displayName: String
    let host: String
    var pageURL: String? = nil
}
