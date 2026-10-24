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
    /// アプリ内でのフォルダ分類名（空文字は未分類 / Downloads直下）
    /// - MP4/MOV/M4V: Documents/Downloads/<folderName> の実サブフォルダと対応
    /// - HLS(.movpkg): Apple指定の保存場所を維持したまま、メタデータ上の論理フォルダとして分類
    var folderName: String
    /// AVAssetDownloadDelegateから受け取った .movpkg URL のブックマークデータ（Apple推奨の参照保持方式）
    var bookmarkData: Data?
    /// 再生可能性・再生時間の検証状態
    var verificationState: VideoVerificationState

    init(
        id: UUID,
        title: String,
        relativePath: String,
        format: Format,
        sourceHost: String?,
        createdAt: Date,
        byteSize: Int64?,
        folderName: String = "",
        bookmarkData: Data? = nil,
        verificationState: VideoVerificationState = .unverified
    ) {
        self.id = id
        self.title = title
        self.relativePath = relativePath
        self.format = format
        self.sourceHost = sourceHost
        self.createdAt = createdAt
        self.byteSize = byteSize
        self.folderName = folderName
        self.bookmarkData = bookmarkData
        self.verificationState = verificationState
    }

    enum CodingKeys: String, CodingKey {
        case id, title, relativePath, format, sourceHost, createdAt, byteSize, folderName, bookmarkData, verificationState
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        relativePath = try c.decode(String.self, forKey: .relativePath)
        format = try c.decode(Format.self, forKey: .format)
        sourceHost = try c.decodeIfPresent(String.self, forKey: .sourceHost)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        byteSize = try c.decodeIfPresent(Int64.self, forKey: .byteSize)
        folderName = try c.decodeIfPresent(String.self, forKey: .folderName)
            ?? Self.inferredFolderName(fromRelativePath: relativePath)
        bookmarkData = try c.decodeIfPresent(Data.self, forKey: .bookmarkData)
        verificationState = try c.decodeIfPresent(VideoVerificationState.self, forKey: .verificationState)
            ?? .unverified
    }

    var isHLS: Bool { format == .hls }

    /// 再生・参照用の実ファイルURL。
    /// HLS(.movpkg)の場合はブックマーク解決を優先し、フォールバック時もディレクトリURL(isDirectory: true)として構築する。
    var fileURL: URL {
        if let data = bookmarkData {
            var isStale = false
            if let resolved = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale),
               FileManager.default.fileExists(atPath: resolved.path) {
                if isHLS && !resolved.hasDirectoryPath {
                    return URL(fileURLWithPath: resolved.path, isDirectory: true)
                }
                return resolved
            }
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(relativePath, isDirectory: isHLS)
    }

    var fileExists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// ユーザー向けの保存場所表示（ファイルアプリで見えるかどうかを明確に区別する）
    var storageLocationLabel: String {
        if isHLS {
            if folderName.isEmpty {
                return "アプリ内HLS領域（ファイルアプリ非表示）"
            } else {
                return "アプリ内HLS領域 · 分類: \(folderName)"
            }
        } else {
            if folderName.isEmpty {
                return "ファイルアプリ: ClipHarbor/Downloads"
            } else {
                return "ファイルアプリ: Downloads/\(folderName)"
            }
        }
    }

    /// Documents/Downloads/サブフォルダ/ファイル.mp4 からサブフォルダ名を推定する
    static func inferredFolderName(fromRelativePath relative: String) -> String {
        let parts = relative.split(separator: "/").map(String.init)
        if let idx = parts.firstIndex(of: "Downloads"), parts.count > idx + 2 {
            return parts[idx + 1]
        }
        return ""
    }

    static func relativePath(for url: URL) -> String? {
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.resolvingSymlinksInPath().path
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = home.hasSuffix("/") ? home : home + "/"
        if target.hasPrefix(prefix) { return String(target.dropFirst(prefix.count)) }
        let relative = url.relativePath
        if !relative.hasPrefix("/") && !relative.isEmpty { return relative }
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

/// URLSessionTaskMetrics とファイル処理から計測した通信内訳（URLは含まない）
struct DownloadMetricsSummary: Equatable {
    var protocolName: String?
    var dnsMilliseconds: Double?
    var connectMilliseconds: Double?
    var tlsMilliseconds: Double?
    var ttfbMilliseconds: Double?
    var transferSeconds: Double?
    var fileWriteMilliseconds: Double?
    var averageSpeedBytesPerSec: Double?
    var isServerPacingSuspected: Bool = false

    var summaryLine: String {
        var parts: [String] = []
        if let proto = protocolName, !proto.isEmpty { parts.append(proto.uppercased()) }
        if let dns = dnsMilliseconds { parts.append(String(format: "DNS %.0fms", dns)) }
        if let tls = tlsMilliseconds { parts.append(String(format: "TLS %.0fms", tls)) }
        if let ttfb = ttfbMilliseconds { parts.append(String(format: "初回応答 %.0fms", ttfb)) }
        if let write = fileWriteMilliseconds { parts.append(String(format: "書込 %.0fms", write)) }
        if let avg = averageSpeedBytesPerSec, avg > 0 {
            parts.append(String(format: "平均 %.2f MB/s", avg / (1024 * 1024)))
        }
        return parts.joined(separator: " · ")
    }

    var diagnosisNote: String? {
        if isServerPacingSuspected {
            return "接続・応答・ファイル書込は高速ですが、受信速度が一定に抑えられています。配信元サーバー側で1接続あたりの帯域制限（ストリーム・ペーシング）が行われている可能性が高いです。"
        }
        return nil
    }
}

enum DownloadState: Equatable {
    case preparing
    case downloading(progress: Double?)
    case paused(progress: Double?)
    case verifying
    case completed
    case verificationIndeterminate(String)
    case verificationFailed(String)
    case failed(String)
    case cancelled

    var label: String {
        switch self {
        case .preparing: return "準備中"
        case .downloading(let p):
            if let p = p { return "ダウンロード中 \(Int(p * 100))%" }
            return "ダウンロード中"
        case .paused(let p):
            if let p = p { return "一時停止中 \(Int(p * 100))%" }
            return "一時停止中"
        case .verifying:
            return "保存データを初期検証中…"
        case .completed:
            return "保存完了（初期検証済）"
        case .verificationIndeterminate(let note):
            return "保存済（非同期読み込み未完了）：\(note)"
        case .verificationFailed(let reason):
            return "保存データを検証できません：\(reason)"
        case .failed(let message):
            return "保存失敗：\(message)"
        case .cancelled:
            return "キャンセルしました"
        }
    }

    var isActive: Bool {
        switch self {
        case .preparing, .downloading, .verifying: return true
        default: return false
        }
    }

    var isPaused: Bool {
        if case .paused = self { return true }
        return false
    }
}

/// 進行中・一時停止・完了・失敗したダウンロード（UI表示用）
struct DownloadJob: Identifiable, Equatable {
    let id: UUID
    var displayName: String
    var targetFolder: String
    let isHLS: Bool
    let host: String
    var state: DownloadState
    var receivedBytes: Int64 = 0
    var expectedBytes: Int64 = 0
    var currentSpeedBytesPerSec: Double = 0
    var averageSpeedBytesPerSec: Double = 0
    var estimatedRemainingSeconds: Double?
    var canRetry: Bool = false
    var canPause: Bool = false
    var metrics: DownloadMetricsSummary?
    /// エラー詳細やHLSプレイリスト・セグメント診断結果（URLは含まない）
    var diagnosticReport: String?

    static func formatSpeed(_ bytesPerSec: Double) -> String {
        guard bytesPerSec > 0 else { return "計測中…" }
        let mb = bytesPerSec / (1024 * 1024)
        if mb >= 0.1 {
            return String(format: "%.2f MB/s", mb)
        }
        let kb = bytesPerSec / 1024
        return String(format: "%.0f KB/s", kb)
    }

    static func formatETA(_ seconds: Double?) -> String? {
        guard let s = seconds, s.isFinite, s >= 0, s < 86_400 else { return nil }
        let total = Int(s.rounded())
        if total < 60 { return "残り約\(max(1, total))秒" }
        let m = total / 60
        let rem = total % 60
        return rem > 0 ? "残り約\(m)分\(rem)秒" : "残り約\(m)分"
    }
}

/// アプリ再起動後もHLSのバックグラウンドダウンロードとローカル保存先URLを復元するための情報（配信元URLは含まない）
struct PendingHLSRecord: Codable {
    let jobID: UUID
    let displayName: String
    let host: String
    var folderName: String
    var relativePath: String?
    var bookmarkData: Data?

    init(
        jobID: UUID,
        displayName: String,
        host: String,
        folderName: String = "",
        relativePath: String? = nil,
        bookmarkData: Data? = nil
    ) {
        self.jobID = jobID
        self.displayName = displayName
        self.host = host
        self.folderName = folderName
        self.relativePath = relativePath
        self.bookmarkData = bookmarkData
    }

    enum CodingKeys: String, CodingKey {
        case jobID, displayName, host, folderName, relativePath, bookmarkData
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jobID = try c.decode(UUID.self, forKey: .jobID)
        displayName = try c.decode(String.self, forKey: .displayName)
        host = try c.decode(String.self, forKey: .host)
        folderName = try c.decodeIfPresent(String.self, forKey: .folderName) ?? ""
        relativePath = try c.decodeIfPresent(String.self, forKey: .relativePath)
        bookmarkData = try c.decodeIfPresent(Data.self, forKey: .bookmarkData)
    }

    var restoredLocationURL: URL? {
        if let data = bookmarkData {
            var isStale = false
            if let resolved = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale),
               FileManager.default.fileExists(atPath: resolved.path) {
                return resolved.hasDirectoryPath ? resolved : URL(fileURLWithPath: resolved.path, isDirectory: true)
            }
        }
        if let rel = relativePath, !rel.isEmpty {
            return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent(rel, isDirectory: true)
        }
        return nil
    }
}

/// ローカルファイルの並び替え順
enum FileSortOrder: String, CaseIterable, Identifiable {
    case dateDesc = "新しい順"
    case dateAsc = "古い順"
    case nameAsc = "名前順"
    case sizeDesc = "サイズ順"

    var id: String { rawValue }
}
