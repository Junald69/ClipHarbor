import Foundation
import AVFoundation

/// 保存済み動画の初期検証状態（URLやトークンは含まない）
/// ※公開API（AVURLAsset / AVAssetCache / AVPlayerItem）による初期読み込み・メタデータ検証であり、動画全編の再生完了を保証するものではない。
enum VideoVerificationState: Codable, Equatable {
    /// まだ検証を実行していない状態
    case unverified
    /// 公開APIによる初期読み込み・再生時間メタデータを確認済み
    case verified(durationSeconds: Double)
    /// 非同期読み込みがタイムアウト時点で未完了、または再生時間が未確定（明確なエラーではない状態）
    case indeterminate(note: String, diagnosticDetail: String)
    /// 明確な再生エラー（isPlayable == false / isPlayableOffline == false / AVPlayerItem.failed 等）。データは削除せず保持する。
    case failed(reason: String, diagnosticDetail: String)

    var isVerified: Bool {
        if case .verified = self { return true }
        return false
    }

    var badgeText: String {
        switch self {
        case .unverified:
            return "未検証"
        case .verified(let sec):
            return "初期検証済 (\(Self.formatDuration(sec)))"
        case .indeterminate:
            return "読み込み未完了（要確認）"
        case .failed:
            return "保存データを検証できません"
        }
    }

    static func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}

/// ダウンロード完了時および再生前の公開APIによるアセット検証結果
struct PlayabilityVerificationResult: Equatable {
    enum Evaluation: Equatable {
        /// isPlayable / duration / AVPlayerItem.readyToPlay を確認済み
        case verified(durationSeconds: Double)
        /// 明確なエラーはないが、非同期読み込みや再生時間の確定が完了していない
        case indeterminate(String)
        /// 明確な再生エラーまたはオフライン再生不可が検出された
        case failed(String)
    }

    let fileExists: Bool
    let byteSize: Int64
    let isPlayable: Bool?
    let isPlayableOffline: Bool?
    let durationSeconds: Double?
    let trackCount: Int
    let playerItemStatusDescription: String
    let evaluation: Evaluation
    let errorSummary: String?
    let errorLogSummary: String?

    var isVerifiedPlayable: Bool {
        if case .verified = evaluation { return true }
        return false
    }

    var statusMessage: String {
        switch evaluation {
        case .verified(let sec):
            return "初期検証済（再生時間 \(VideoVerificationState.formatDuration(sec))）"
        case .indeterminate(let note):
            return note
        case .failed(let reason):
            return reason
        }
    }

    var detailedReport: String {
        var lines: [String] = []
        let sizeStr = ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
        lines.append("ファイル/アセット存在: \(fileExists ? "あり (\(sizeStr))" : "なし")")
        if let offline = isPlayableOffline {
            lines.append("AVAssetCache.isPlayableOffline: \(offline ? "true" : "false")")
        }
        if let playable = isPlayable {
            lines.append("AVAsset.isPlayable: \(playable ? "true" : "false") / トラック数: \(trackCount)")
        } else {
            lines.append("AVAsset.isPlayable: 未確定 / トラック数: \(trackCount)")
        }
        if let d = durationSeconds, d.isFinite, d > 0 {
            lines.append("再生時間(duration): \(VideoVerificationState.formatDuration(d)) (\(String(format: "%.1f秒", d)))")
        } else {
            lines.append("再生時間(duration): --:-- (未確定または無期限)")
        }
        lines.append("AVPlayerItem.status: \(playerItemStatusDescription)")
        if let err = errorSummary, !err.isEmpty {
            lines.append("エラー詳細: \(err)")
        }
        if let log = errorLogSummary, !log.isEmpty {
            lines.append("AVPlayerItem.errorLog: \(log)")
        }
        lines.append("※公開APIによるメタデータ・初期読み込み検証であり、動画全編の再生を保証するものではありません。")
        return lines.joined(separator: "\n")
    }
}

/// ダウンロードされたMP4またはHLS（.movpkg）を公開API（AVURLAsset / AVAssetCache / AVPlayerItem）で検証する。
/// .movpkg の非公開内部構造（boot.xml 等）には一切依存しない。
enum MediaPlayabilityVerifier {

    static func verify(url: URL, isHLS: Bool) async -> PlayabilityVerificationResult {
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: url.path)
        let size = exists ? Self.computeSize(at: url) : 0
        guard exists, size > 0 else {
            return PlayabilityVerificationResult(
                fileExists: exists,
                byteSize: size,
                isPlayable: false,
                isPlayableOffline: nil,
                durationSeconds: nil,
                trackCount: 0,
                playerItemStatusDescription: "未実行（ファイル不在または0バイト）",
                evaluation: .failed("保存先ファイルが存在しないか、サイズが0バイトです。"),
                errorSummary: nil,
                errorLogSummary: nil
            )
        }

        let normalizedURL: URL
        if isHLS && !url.hasDirectoryPath {
            normalizedURL = URL(fileURLWithPath: url.path, isDirectory: true)
        } else {
            normalizedURL = url
        }

        let asset = AVURLAsset(url: normalizedURL)
        let isPlayableOffline: Bool? = isHLS ? asset.assetCache?.isPlayableOffline : nil

        // 明示的にオフライン再生不可と判定された場合
        if isHLS && isPlayableOffline == false {
            return PlayabilityVerificationResult(
                fileExists: exists,
                byteSize: size,
                isPlayable: nil,
                isPlayableOffline: false,
                durationSeconds: nil,
                trackCount: 0,
                playerItemStatusDescription: "未実行（isPlayableOffline == false）",
                evaluation: .failed("AVAssetCache.isPlayableOffline が false のため、オフライン再生に必要なデータが揃っていません。"),
                errorSummary: nil,
                errorLogSummary: nil
            )
        }

        var loadedPlayable: Bool?
        var durationSeconds: Double?
        var trackCount = 0
        var assetLoadError: Error?

        do {
            let isPlayableValue = try await asset.load(.isPlayable)
            loadedPlayable = isPlayableValue
            let durationValue = try await asset.load(.duration)
            if durationValue.isNumeric && !durationValue.isIndefinite && durationValue.seconds > 0 {
                durationSeconds = durationValue.seconds
            }
            if let tracksValue = try? await asset.load(.tracks) {
                trackCount = tracksValue.count
            }
        } catch {
            assetLoadError = error
        }

        if loadedPlayable == false {
            let errText = assetLoadError.map { ErrorChainFormatter.describe($0) }
            return PlayabilityVerificationResult(
                fileExists: exists,
                byteSize: size,
                isPlayable: false,
                isPlayableOffline: isPlayableOffline,
                durationSeconds: durationSeconds,
                trackCount: trackCount,
                playerItemStatusDescription: "未実行（isPlayable == false）",
                evaluation: .failed("AVURLAsset.isPlayable が false です（保護コンテンツまたは非対応コーデックの可能性があります）。"),
                errorSummary: errText,
                errorLogSummary: nil
            )
        }

        // AVPlayerItem による公開APIステータス・エラーログ確認
        let itemCheck = await verifyPlayerItem(with: asset)
        if durationSeconds == nil, let itemDur = itemCheck.itemDurationSeconds, itemDur > 0 {
            durationSeconds = itemDur
        }
        let finalTrackCount = max(trackCount, itemCheck.itemTrackCount)
        let combinedError = itemCheck.errorSummary ?? assetLoadError.map { ErrorChainFormatter.describe($0) }

        let evaluation: PlayabilityVerificationResult.Evaluation
        switch itemCheck.status {
        case .failed:
            let reason = combinedError ?? "AVPlayerItem の読み込みが失敗しました（.failed）。"
            evaluation = .failed("プレイヤーで再生できません：\(reason)")
        case .readyToPlay:
            if let dur = durationSeconds, dur > 0 {
                evaluation = .verified(durationSeconds: dur)
            } else {
                evaluation = .indeterminate("AVPlayerItem は準備完了（.readyToPlay）ですが、再生時間（duration）が未確定（--:--）です。")
            }
        case .unknown:
            if let err = combinedError {
                evaluation = .failed("アセット読み込み中にエラーが発生しました：\(err)")
            } else if let dur = durationSeconds, dur > 0, loadedPlayable == true {
                evaluation = .indeterminate("アセットのメタデータ（\(VideoVerificationState.formatDuration(dur))）は確認できましたが、AVPlayerItem の非同期準備がまだ完了していません。")
            } else {
                evaluation = .indeterminate("非同期読み込みが待機時間内に完了しませんでした（明確なエラーは検出されていません）。")
            }
        @unknown default:
            evaluation = .indeterminate("プレイヤーの状態が未確定です。")
        }

        return PlayabilityVerificationResult(
            fileExists: exists,
            byteSize: size,
            isPlayable: loadedPlayable,
            isPlayableOffline: isPlayableOffline,
            durationSeconds: durationSeconds,
            trackCount: finalTrackCount,
            playerItemStatusDescription: itemCheck.statusLabel,
            evaluation: evaluation,
            errorSummary: combinedError,
            errorLogSummary: itemCheck.errorLogSummary
        )
    }

    private struct PlayerItemCheckResult {
        let status: AVPlayerItem.Status
        let statusLabel: String
        let itemDurationSeconds: Double?
        let itemTrackCount: Int
        let errorSummary: String?
        let errorLogSummary: String?
    }

    @MainActor
    private static func verifyPlayerItem(with asset: AVURLAsset) async -> PlayerItemCheckResult {
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true

        // 最大6秒間、item.status が .readyToPlay または .failed に遷移するのを待機する
        let deadline = Date().addingTimeInterval(6.0)
        while item.status == .unknown && Date() < deadline {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        let currentStatus = item.status
        let statusLabel: String
        switch currentStatus {
        case .unknown: statusLabel = ".unknown（非同期読み込み中）"
        case .readyToPlay: statusLabel = ".readyToPlay（準備完了）"
        case .failed: statusLabel = ".failed（再生エラー）"
        @unknown default: statusLabel = "不明"
        }

        var itemDur: Double?
        if item.duration.isNumeric && !item.duration.isIndefinite && item.duration.seconds > 0 {
            itemDur = item.duration.seconds
        }
        let itemTracks = item.tracks.count
        let errSummary = item.error.map { ErrorChainFormatter.describe($0) }
        let logSummary = summarizeErrorLog(item.errorLog())

        player.pause()
        player.replaceCurrentItem(with: nil)

        return PlayerItemCheckResult(
            status: currentStatus,
            statusLabel: statusLabel,
            itemDurationSeconds: itemDur,
            itemTrackCount: itemTracks,
            errorSummary: errSummary,
            errorLogSummary: logSummary
        )
    }

    static func summarizeErrorLog(_ log: AVPlayerItemErrorLog?) -> String? {
        guard let events = log?.events, !events.isEmpty else { return nil }
        var parts: [String] = []
        for ev in events.suffix(3) {
            var entry = "\(ev.errorDomain) (\(ev.errorStatusCode))"
            if let comment = ev.errorComment, !comment.isEmpty {
                let sanitized = sanitizeDiagnosticText(comment)
                if !sanitized.isEmpty {
                    entry += ": \(sanitized)"
                }
            }
            parts.append(entry)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " / ")
    }

    private static func computeSize(at url: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    static func sanitizeDiagnosticText(_ raw: String) -> String {
        // http:// や https:// 以降のURL・クエリ文字列をマスクする（DL-04遵守）
        var text = raw.replacingOccurrences(of: "\n", with: " ")
        if let range = text.range(of: "https?://[^\\s\"'<>]+", options: .regularExpression) {
            text.replaceSubrange(range, with: "[URL省略]")
        }
        if text.count > 160 {
            text = String(text.prefix(160)) + "…"
        }
        return text
    }
}

/// NSError の Domain / Code / Underlying Error 階層を安全に文字列化する（URL・トークンは出力しない）
enum ErrorChainFormatter {
    static func describe(_ error: Error) -> String {
        var current: NSError? = error as NSError
        var chain: [String] = []
        var depth = 0

        while let ns = current, depth < 4 {
            let meaning = knownCodeMeaning(domain: ns.domain, code: ns.code)
            if let meaning = meaning {
                chain.append("\(ns.domain) \(ns.code) (\(meaning))")
            } else {
                chain.append("\(ns.domain) \(ns.code)")
            }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return chain.joined(separator: " ← ")
    }

    static func knownCodeMeaning(domain: String, code: Int) -> String? {
        if domain == "CoreMediaErrorDomain" {
            switch code {
            case -12937: return "HTTP 401 認証エラー"
            case -12938: return "HTTP 404 Not Found: プレイリストまたはセグメントURLが存在しないか期限切れ"
            case -12660: return "HTTP 403 Forbidden: アクセス拒否・ヘッダー/Cookie不一致"
            case -12661: return "HTTP 503 サーバー一時利用不可"
            case -12642, -12645: return "HLSストリーム応答タイムアウト"
            case -12889, -12158, -16830: return "非対応のHLS構成または暗号化保護"
            case -42656: return "復号キーまたは保護コンテンツエラー"
            default: return nil
            }
        }
        if domain == AVFoundationErrorDomain {
            switch code {
            case AVError.Code.contentIsProtected.rawValue: return "DRM保護コンテンツ"
            case AVError.Code.contentIsNotAuthorized.rawValue: return "コンテンツ認証不可"
            case AVError.Code.fileFormatNotRecognized.rawValue: return "ファイル形式認識不可"
            case AVError.Code.failedToParse.rawValue: return "プレイリスト/メディア解析失敗"
            case AVError.Code.noCompatibleAlternatesForExternalDisplay.rawValue: return "互換バリアントなし"
            default: return nil
            }
        }
        if domain == NSURLErrorDomain {
            switch code {
            case NSURLErrorTimedOut: return "通信タイムアウト"
            case NSURLErrorNotConnectedToInternet: return "オフライン"
            case NSURLErrorNetworkConnectionLost: return "通信切断"
            case NSURLErrorFileDoesNotExist: return "ファイル不在"
            default: return nil
            }
        }
        return nil
    }
}

/// CoreMediaErrorDomain -12938 等の発生時に、HLSプレイリスト・セグメントの応答状況をメモリ上のみで調査する
enum HLSDiagnosticProbe {

    struct Report: Equatable {
        let errorChain: String
        let playlistHTTPStatus: Int?
        let redirected: Bool
        let isMasterPlaylist: Bool?
        let isMediaPlaylist: Bool?
        let hasKeyEncryption: Bool
        let isLiveStream: Bool
        let firstChildKind: String?
        let firstChildHTTPStatus: Int?
        let conclusion: String

        var summaryText: String {
            var parts: [String] = []
            parts.append("エラー: \(errorChain)")
            if let status = playlistHTTPStatus {
                parts.append("プレイリストHTTP応答: \(status)\(redirected ? " (リダイレクトあり)" : "")")
            }
            if isMasterPlaylist == true {
                parts.append("種別: マスタープレイリスト(#EXT-X-STREAM-INF)")
            } else if isMediaPlaylist == true {
                parts.append("種別: 単一メディアプレイリスト(#EXTINFのみ)")
            }
            if hasKeyEncryption {
                parts.append("暗号化: #EXT-X-KEYあり")
            }
            if isLiveStream {
                parts.append("配信形態: ライブ/動的プレイリスト(#EXT-X-ENDLISTなし)")
            }
            if let kind = firstChildKind, let childStatus = firstChildHTTPStatus {
                parts.append("\(kind)応答: HTTP \(childStatus)")
            }
            parts.append("診断結果: \(conclusion)")
            return parts.joined(separator: "\n")
        }
    }

    static func diagnose(error: Error, candidateURL: URL, context: RequestContext, session: URLSession) async -> Report {
        let chain = ErrorChainFormatter.describe(error)
        let req = context.makeRequest(for: candidateURL)

        var playlistStatus: Int?
        var redirected = false
        var finalPlaylistURL = candidateURL
        var bodyText: String?

        do {
            let (data, response) = try await session.data(for: req)
            if let http = response as? HTTPURLResponse {
                playlistStatus = http.statusCode
                if let respURL = http.url, respURL.absoluteString != candidateURL.absoluteString {
                    redirected = true
                    finalPlaylistURL = respURL
                }
            }
            if data.count <= 256 * 1024 {
                bodyText = String(data: data, encoding: .utf8)
            }
        } catch {
            return Report(
                errorChain: chain,
                playlistHTTPStatus: nil,
                redirected: false,
                isMasterPlaylist: nil,
                isMediaPlaylist: nil,
                hasKeyEncryption: false,
                isLiveStream: false,
                firstChildKind: nil,
                firstChildHTTPStatus: nil,
                conclusion: "プレイリストの再取得時に通信エラーが発生しました（URLの有効期限切れ、または通信切断の可能性があります）。"
            )
        }

        if let status = playlistStatus, !(200...299).contains(status) {
            let reason: String
            switch status {
            case 401, 403:
                reason = "プレイリスト自体が HTTP \(status) を返しました。Refererヘッダーや一時トークン・認証が必要な配信のため、iOS標準のAVAssetDownloadURLSessionでは拒否されています。"
            case 404, 410:
                reason = "プレイリストURLが HTTP \(status)（存在しないか有効期限切れ）を返しました。一回限りの署名URLまたは期限切れの可能性があります。"
            default:
                reason = "プレイリスト取得時に HTTP \(status) が返されました。"
            }
            return Report(
                errorChain: chain,
                playlistHTTPStatus: status,
                redirected: redirected,
                isMasterPlaylist: nil,
                isMediaPlaylist: nil,
                hasKeyEncryption: false,
                isLiveStream: false,
                firstChildKind: nil,
                firstChildHTTPStatus: nil,
                conclusion: reason
            )
        }

        guard let text = bodyText, text.contains("#EXTM3U") else {
            return Report(
                errorChain: chain,
                playlistHTTPStatus: playlistStatus,
                redirected: redirected,
                isMasterPlaylist: false,
                isMediaPlaylist: false,
                hasKeyEncryption: false,
                isLiveStream: false,
                firstChildKind: nil,
                firstChildHTTPStatus: nil,
                conclusion: "応答はHTTP 200でしたが、有効なHLSプレイリスト（#EXTM3U）ではなくWebページ等が返されました。"
            )
        }

        let isMaster = text.contains("#EXT-X-STREAM-INF")
        let isMedia = !isMaster && text.contains("#EXTINF")
        let hasKey = text.contains("#EXT-X-KEY") || text.contains("#EXT-X-SESSION-KEY")
        let isLive = isMedia && !text.contains("#EXT-X-ENDLIST")

        var firstChildKind: String?
        var firstChildStatus: Int?
        if let child = extractFirstReference(from: text, baseURL: finalPlaylistURL) {
            firstChildKind = child.kind
            var childReq = context.makeRequest(for: child.url)
            childReq.setValue("bytes=0-1", forHTTPHeaderField: "Range")
            if let (_, resp) = try? await session.data(for: childReq),
               let http = resp as? HTTPURLResponse {
                firstChildStatus = http.statusCode
            }
        }

        var conclusions: [String] = []
        if let childStatus = firstChildStatus, childStatus == 404 || childStatus == 410 {
            conclusions.append("プレイリストは取得できましたが、参照先の\(firstChildKind ?? "セグメント")が HTTP \(childStatus) (Not Found) を返しました（CoreMediaErrorDomain -12938 の直接原因）。セグメントの有効期限切れ・相対パス不整合・または配信サーバー側の制限です。")
        } else if let childStatus = firstChildStatus, childStatus == 401 || childStatus == 403 {
            conclusions.append("プレイリスト内の\(firstChildKind ?? "セグメント")が HTTP \(childStatus)（アクセス拒否）を返しました。セグメント取得にRefererやカスタム認証ヘッダーが必要な配信方式です。")
        }
        if isMedia && !isMaster {
            conclusions.append("検出されたURLはマスタープレイリスト（#EXT-X-STREAM-INF）ではなく単一メディアプレイリスト（#EXTINF）です。AppleのAVAssetDownloadURLSessionはマスタープレイリストを要求するため、単一プレイリストではエラー（-12938等）になる場合があります。候補一覧に master.m3u8 等がある場合はそちらを選択してください。")
        }
        if isLive {
            conclusions.append("プレイリストに #EXT-X-ENDLIST がないため、ライブ配信または動的ストリームと判定されました（オフライン保存非対応）。")
        }
        if hasKey {
            conclusions.append("プレイリストに #EXT-X-KEY（暗号化）が含まれています。配信元がオフライン保存を許可していない可能性があります。")
        }
        if conclusions.isEmpty {
            conclusions.append("AVAssetDownloadURLSession のバックグラウンド取得中にサーバーが404または非対応レスポンスを返しました（ブラウザのWebViewとは異なるシステムデーモンから通信するため、Referer必須や一時トークン制限のある配信では保存できません）。")
        }

        return Report(
            errorChain: chain,
            playlistHTTPStatus: playlistStatus,
            redirected: redirected,
            isMasterPlaylist: isMaster,
            isMediaPlaylist: isMedia,
            hasKeyEncryption: hasKey,
            isLiveStream: isLive,
            firstChildKind: firstChildKind,
            firstChildHTTPStatus: firstChildStatus,
            conclusion: conclusions.joined(separator: " ")
        )
    }

    private static func extractFirstReference(from playlist: String, baseURL: URL) -> (kind: String, url: URL)? {
        let lines = playlist.components(separatedBy: .newlines)
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXT-X-MAP:"),
               let uri = extractAttributeURI(from: line),
               let resolved = URL(string: uri, relativeTo: baseURL)?.absoluteURL {
                return ("初期化セグメント(#EXT-X-MAP)", resolved)
            }
            if !line.hasPrefix("#"),
               let resolved = URL(string: line, relativeTo: baseURL)?.absoluteURL,
               ["http", "https"].contains(resolved.scheme?.lowercased() ?? "") {
                let isSubPlaylist = resolved.path.lowercased().hasSuffix(".m3u8")
                return (isSubPlaylist ? "バリアントプレイリスト" : "メディアセグメント", resolved)
            }
        }
        return nil
    }

    private static func extractAttributeURI(from tagLine: String) -> String? {
        guard let range = tagLine.range(of: "URI=\"([^\"]+)\"", options: .regularExpression) else { return nil }
        let matched = String(tagLine[range])
        return matched
            .replacingOccurrences(of: "URI=\"", with: "")
            .replacingOccurrences(of: "\"", with: "")
    }
}
