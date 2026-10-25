import Foundation
import WebKit

/// コンテンツブロッカーの状態
enum BlockerState: Equatable {
    case preparing
    case active(version: String)
    case fallbackActive(version: String)
    case disabled
    case failed(String)
}

extension Notification.Name {
    static let contentBlockerRulesReady = Notification.Name("ClipHarbor.ContentBlocker.RulesReady")
    static let contentBlockerSettingsChanged = Notification.Name("ClipHarbor.ContentBlocker.SettingsChanged")
}

/// 広告・トラッカーブロックおよび迷惑ポップアップ対策の管理クラス
/// - 端末内WebKitルール（WKContentRuleList）によるオンデバイス判定
/// - 閲覧URLや履歴の外部送信は一切行わない
/// - AdAway Default Blocklist (CC BY 3.0) 準拠
@MainActor
final class ContentBlockerManager: ObservableObject {
    static let shared = ContentBlockerManager()

    @Published private(set) var state: BlockerState = .preparing

    /// コンパイル済みWKContentRuleList（メモリ保持）
    private(set) var compiledRuleList: WKContentRuleList?

    /// ルールリスト識別子
    private let ruleListIdentifier = "ClipHarborContentBlockerRules_v1"
    private let fallbackRuleListIdentifier = "ClipHarborContentBlockerRules_fallback"

    /// ルールメタデータ
    private(set) var ruleVersion: String = "1.0.0"
    private(set) var ruleCount: Int = 0
    private(set) var sourceCommit: String = ""
    private(set) var license: String = "CC BY 3.0"

    private var isCompiling: Bool = false

    /// ブロッカーが利用可能（アクティブまたはフォールバックアクティブ）かどうか
    var isReady: Bool {
        switch state {
        case .active, .fallbackActive:
            return compiledRuleList != nil
        default:
            return false
        }
    }

    private init() {
        loadMetadata()
        prepareRuleList()
    }

    /// バンドルからメタデータを読み込む
    private func loadMetadata() {
        guard let url = Bundle.main.url(forResource: "blocker_metadata", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        if let v = (json["ruleVersion"] ?? json["version"]) as? String { ruleVersion = v }
        if let c = (json["ruleCount"] ?? json["rule_count"]) as? Int { ruleCount = c }
        if let sc = (json["sourceCommit"] ?? json["source_commit"]) as? String { sourceCommit = sc }
        if let lic = (json["sourceLicense"] ?? json["license"]) as? String { license = lic }
    }

    /// ルールリストの準備（キャッシュルックアップまたは非同期コンパイル）
    func prepareRuleList() {
        guard !isCompiling else { return }

        guard let store = WKContentRuleListStore.default() else {
            self.state = .failed("WKContentRuleListStore is unavailable")
            return
        }

        isCompiling = true
        state = .preparing

        store.lookUpContentRuleList(forIdentifier: ruleListIdentifier) { [weak self] ruleList, error in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if let ruleList = ruleList {
                    self.compiledRuleList = ruleList
                    self.isCompiling = false
                    self.updateStateAfterCompilation(success: true, isFallback: false)
                    NotificationCenter.default.post(name: .contentBlockerRulesReady, object: nil)
                } else {
                    // ストアに未コンパイルのため、同梱JSONからコンパイル
                    self.compileBundledRules()
                }
            }
        }
    }

    private func compileBundledRules() {
        guard let url = Bundle.main.url(forResource: "blocker_rules", withExtension: "json"),
              let ruleJSONString = try? String(contentsOf: url, encoding: .utf8) else {
            self.isCompiling = false
            self.state = .failed("blocker_rules.json not found in bundle")
            return
        }

        guard let store = WKContentRuleListStore.default() else {
            self.isCompiling = false
            self.state = .failed("WKContentRuleListStore is unavailable")
            return
        }

        store.compileContentRuleList(forIdentifier: ruleListIdentifier, encodedContentRuleList: ruleJSONString) { [weak self] ruleList, error in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.isCompiling = false
                if let ruleList = ruleList {
                    self.compiledRuleList = ruleList
                    self.updateStateAfterCompilation(success: true, isFallback: false)
                    NotificationCenter.default.post(name: .contentBlockerRulesReady, object: nil)
                } else {
                    let errMsg = error?.localizedDescription ?? "Unknown compilation error"
                    self.compileFallbackRules(originalError: errMsg)
                }
            }
        }
    }

    private func compileFallbackRules(originalError: String) {
        guard let store = WKContentRuleListStore.default() else {
            self.state = .failed("WKContentRuleListStore is unavailable")
            return
        }

        // 最小限のフォールバックルール（主要広告配信ドメイン）
        let fallbackJSON = """
        [
          {
            "trigger": { "url-filter": ".*\\\\.doubleclick\\\\.net/.*" },
            "action": { "type": "block" }
          }
        ]
        """
        store.compileContentRuleList(forIdentifier: fallbackRuleListIdentifier, encodedContentRuleList: fallbackJSON) { [weak self] ruleList, error in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if let ruleList = ruleList {
                    self.compiledRuleList = ruleList
                    self.updateStateAfterCompilation(success: true, isFallback: true)
                    NotificationCenter.default.post(name: .contentBlockerRulesReady, object: nil)
                } else {
                    self.state = .failed(originalError)
                }
            }
        }
    }

    private func updateStateAfterCompilation(success: Bool, isFallback: Bool) {
        if success {
            if isFallback {
                self.state = .fallbackActive(version: "fallback-1.0")
            } else {
                self.state = .active(version: self.ruleVersion)
            }
        }
    }

    /// 設定変更時の通知
    func notifySettingsChanged() {
        NotificationCenter.default.post(name: .contentBlockerSettingsChanged, object: nil)
    }

    /// 指定ホスト・モードにおいて広告・トラッカーをブロックすべきか判定
    func shouldBlockAds(for host: String?, isPrivate: Bool) -> Bool {
        guard AppSettingsManager.shared.blockAdsAndTrackers else { return false }
        guard isReady else { return false }
        return !isHostWhitelisted(host, isPrivate: isPrivate)
    }

    /// 指定ホスト・モードにおいて迷惑ポップアップをブロックすべきか判定
    func shouldBlockPopups(for host: String?, isPrivate: Bool) -> Bool {
        guard AppSettingsManager.shared.blockAnnoyingPopups else { return false }
        return !isHostWhitelisted(host, isPrivate: isPrivate)
    }

    /// ホストがホワイトリスト（例外）に登録されているか判定
    func isHostWhitelisted(_ host: String?, isPrivate: Bool) -> Bool {
        guard let host = host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !host.isEmpty else {
            return false
        }
        if isPrivate {
            return TabManager.shared?.isPrivateWhitelisted(host: host) ?? false
        } else {
            return AppSettingsManager.shared.isWhitelisted(host: host)
        }
    }

    /// ホストのホワイトリスト登録状態を反転
    func toggleWhitelist(for host: String?, isPrivate: Bool) {
        guard let host = host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !host.isEmpty else {
            return
        }
        if isPrivate {
            TabManager.shared?.togglePrivateWhitelist(for: host)
        } else {
            AppSettingsManager.shared.toggleWhitelist(for: host)
        }
        notifySettingsChanged()
    }
}
