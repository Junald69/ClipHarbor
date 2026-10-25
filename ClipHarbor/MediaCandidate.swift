import Foundation

/// 保存候補（メモリ上のみで扱う）。URLには期限付きトークン等が含まれ得るため、永続化・ログ出力しない。
struct MediaCandidate: Identifiable, Hashable {
    enum FileType: String {
        case mp4, m4v, mov, webm
        /// video要素のsrcだが拡張子から形式を判定できない。ダウンロード後に中身で判定する。
        case unknown
    }

    enum Kind: Hashable {
        case file(FileType)
        case hls
    }

    let url: URL
    let kind: Kind
    /// 動画自体のタイトル（title/aria-label属性など）。なければ空。
    let videoTitle: String
    /// ページタイトル
    let pageTitle: String
    let posterURL: URL?
    /// 対応するvideo要素の一時ID（Performance APIから見つけたURLはnil）
    let videoID: String?

    var id: String { url.absoluteString }
    var host: String { url.host ?? NSLocalizedString("Unknown Host", comment: "") }

    var isHLS: Bool { if case .hls = kind { return true } else { return false } }

    /// 保存シートの初期ファイル名：動画タイトル → ページタイトル → "Video"
    var suggestedName: String {
        let video = videoTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !video.isEmpty { return video }
        let page = pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return page.isEmpty ? "Video" : page
    }

    /// 形式の短い表示名
    var formatLabel: String {
        switch kind {
        case .hls: return NSLocalizedString("Offline HLS", comment: "")
        case .file(let type):
            switch type {
            case .mp4: return "MP4"
            case .m4v: return "M4V"
            case .mov: return "MOV"
            case .webm: return "WebM"
            case .unknown: return NSLocalizedString("Video File (Format confirmed upon save)", comment: "")
            }
        }
    }

    /// 形式についての注意書き。HLSをMP4に変換できると誤認させない。
    var formatNote: String? {
        switch kind {
        case .hls:
            return NSLocalizedString("HLS will not be converted to MP4. It is saved in Apple's standard offline format and can only be played within ClipHarbor. Unsupported or DRM-protected streams cannot be saved.", comment: "")
        case .file(.webm):
            return NSLocalizedString("WebM may not play on iPhone.", comment: "")
        case .file(.unknown):
            return NSLocalizedString("The file contents will be checked after download, and saved if it is a video file like MP4/MOV. If a web page or other content is returned, it will not be saved.", comment: "")
        default:
            return nil
        }
    }

    /// 予定される拡張子（不明な場合はnil）
    var expectedExtension: String? {
        switch kind {
        case .hls: return nil
        case .file(let type): return type == .unknown ? nil : type.rawValue
        }
    }

    static func == (lhs: MediaCandidate, rhs: MediaCandidate) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// JavaScriptから届いたURL文字列（非信頼入力）を分類する。
enum MediaClassifier {
    static let maxURLLength = 4096

    enum Result {
        case supported(URL, MediaCandidate.Kind)
        case unsupported(String)
    }

    /// - Parameter allowUnknownExtension: video要素のsrcなど「動画であることが確実なURL」の場合のみtrue。
    static func classify(_ raw: String, allowUnknownExtension: Bool) -> Result {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .unsupported(NSLocalizedString("Cannot obtain video URL.", comment: ""))
        }
        let lowerPrefix = trimmed.prefix(12).lowercased()
        if lowerPrefix.hasPrefix("blob:") {
            return .unsupported(NSLocalizedString("This video is played via blob/MSE, so a downloadable URL cannot be obtained.", comment: ""))
        }
        if lowerPrefix.hasPrefix("mediastream:") || lowerPrefix.hasPrefix("data:") {
            return .unsupported(NSLocalizedString("Videos using this playback method cannot be saved.", comment: ""))
        }
        guard trimmed.count <= maxURLLength,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else {
            return .unsupported(NSLocalizedString("This streaming URL format is not supported.", comment: ""))
        }
        let path = url.path.lowercased()
        if path.hasSuffix(".m3u8") { return .supported(url, .hls) }
        if path.hasSuffix(".mp4") { return .supported(url, .file(.mp4)) }
        if path.hasSuffix(".m4v") { return .supported(url, .file(.m4v)) }
        if path.hasSuffix(".mov") { return .supported(url, .file(.mov)) }
        if path.hasSuffix(".webm") { return .supported(url, .file(.webm)) }
        if allowUnknownExtension { return .supported(url, .file(.unknown)) }
        return .unsupported(NSLocalizedString("This URL cannot be identified as a video file.", comment: ""))
    }
}
