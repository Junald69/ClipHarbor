import Foundation

struct MediaCandidate: Identifiable, Hashable {
    enum MediaKind: String {
        case videoFile = "動画ファイル"
        case hls = "HLS配信"
    }

    let url: URL
    let kind: MediaKind
    let pageTitle: String
    var id: String { url.absoluteString }
    var shortDescription: String {
        "\(kind.rawValue) · \(url.host ?? "不明なホスト")"
    }

    static func from(urlString: String, pageTitle: String) -> MediaCandidate? {
        guard let url = URL(string: urlString),
              ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        let lower = url.path.lowercased()
        let kind: MediaKind
        if lower.hasSuffix(".m3u8") {
            kind = .hls
        } else if [".mp4", ".m4v", ".mov", ".webm"].contains(where: lower.hasSuffix) {
            kind = .videoFile
        } else {
            return nil
        }
        return MediaCandidate(url: url, kind: kind, pageTitle: pageTitle)
    }
}
