import Foundation
import CoreGraphics

/// Webページ内のHTML5 video要素1つ分の状態（メモリ上のみ）。
/// IDはページ読み込みごとにJavaScript側で割り当てる一時的なもので、ページ移動で破棄される。
struct TrackedVideo: Identifiable, Equatable {
    let id: String
    var isMainFrame: Bool
    var sourceURL: String
    var sourceList: [String]
    var posterURL: URL?
    var title: String
    var frameTitle: String
    var isPlaying: Bool
    var hasPlayed: Bool
    var hasEnded: Bool
    var isMuted: Bool
    var isProtected: Bool
    var isFullscreen: Bool
    var duration: Double
    /// 0〜1。フレームのビューポート内に見えている割合
    var visibleRatio: Double
    /// JavaScriptの Date.now()（ミリ秒）
    var lastPlayAt: Double
    var lastInteractionAt: Double
    /// トップレベルの visual viewport 基準のCSSピクセル座標。クロスオリジンiframe等で取得できない場合はnil。
    var rectInCSS: CGRect?
    /// 上記座標の基準となる visual viewport の幅（CSSピクセル）
    var viewportCSSWidth: Double

    /// 保存可能な候補（取得できない場合はnil）
    var candidate: MediaCandidate?
    /// 保存できない理由（candidateがnilの場合）
    var unsupportedReason: String?

    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        let f = frameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return f.isEmpty ? "動画" : f
    }

    var stateLabel: String {
        if isPlaying { return "再生中" }
        if hasEnded { return "再生終了" }
        if hasPlayed { return "一時停止" }
        return "未再生"
    }

    /// 内部の候補・理由を再計算する
    mutating func resolveCandidate(pageTitle: String) {
        if isProtected {
            candidate = nil
            unsupportedReason = "保護されたコンテンツ（DRM）は保存できません。"
            return
        }
        var urls: [String] = []
        if !sourceURL.isEmpty { urls.append(sourceURL) }
        urls.append(contentsOf: sourceList)
        var firstReason: String?
        for raw in urls {
            switch MediaClassifier.classify(raw, allowUnknownExtension: true) {
            case .supported(let url, let kind):
                candidate = MediaCandidate(url: url, kind: kind, videoTitle: title,
                                           pageTitle: pageTitle, posterURL: posterURL, videoID: id)
                unsupportedReason = nil
                return
            case .unsupported(let reason):
                if firstReason == nil { firstReason = reason }
            }
        }
        candidate = nil
        unsupportedReason = firstReason ?? "動画のURLを取得できません。"
    }
}

/// 複数の動画からユーザーが見ている「メイン動画」を選ぶ。
enum VideoSelection {
    struct Result {
        let video: TrackedVideo?
        /// 複数の動画が同時に再生されていて、どれが目的の動画か判断できない
        let isAmbiguous: Bool
    }

    static func select(from videos: [TrackedVideo], now: Double = Date().timeIntervalSince1970 * 1000) -> Result {
        let relevant = videos.filter { $0.isPlaying || $0.hasPlayed }
        let playing = relevant.filter { $0.isPlaying }

        if !playing.isEmpty {
            let ranked = playing.sorted { score($0, now: now) > score($1, now: now) }
            guard let best = ranked.first else { return Result(video: nil, isAmbiguous: false) }
            if ranked.count >= 2 {
                let second = ranked[1]
                let recentlyTouched = now - best.lastInteractionAt < 15_000
                // ユーザー操作がなく、スコアが拮抗している場合は自動で決めない
                if !recentlyTouched && score(best, now: now) - score(second, now: now) < 3_000 {
                    return Result(video: nil, isAmbiguous: true)
                }
            }
            return Result(video: best, isAmbiguous: false)
        }

        // 再生中の動画がない場合は、直近に再生・操作され、まだ見えている動画を対象にする
        let paused = relevant
            .filter { $0.visibleRatio > 0.2 }
            .sorted { max($0.lastPlayAt, $0.lastInteractionAt) > max($1.lastPlayAt, $1.lastInteractionAt) }
        return Result(video: paused.first, isAmbiguous: false)
    }

    /// ミリ秒単位のスコア。新しい再生・操作ほど高く、見えている割合と音声有無も考慮する。
    private static func score(_ v: TrackedVideo, now: Double) -> Double {
        var s = max(v.lastPlayAt, v.lastInteractionAt)
        if now - v.lastInteractionAt < 15_000 { s += 30_000 }
        s += v.visibleRatio * 5_000
        // ミュートの自動再生（背景動画・広告など）は優先度を下げる
        if v.isMuted && now - v.lastInteractionAt > 15_000 { s -= 60_000 }
        if let r = v.rectInCSS { s += min(Double(r.width * r.height) / 100, 3_000) }
        return s
    }
}
