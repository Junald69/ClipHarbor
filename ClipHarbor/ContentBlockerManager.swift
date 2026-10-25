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
    static let contentBlockerCompileFailed = Notification.Name("ClipHarbor.ContentBlocker.CompileFailed")
}

/// 広告・トラッカーブロックおよび迷惑ポップアップ対策の管理クラス
/// - 通常タブ用: ベースルール＋永続ホワイトリスト例外（if-top-url + ignore-previous-rules）を単一リストに統合
/// - プライベートタブ用: 例外ドメインを一切含まないベースルールのみを使用（ディスク・キャッシュ残留完全防止）
/// - ホスト完全一致（サブドメインや前方一致偽装ドメインを厳格除外）
/// - AdAway Default Blocklist (CC BY 3.0) 準拠
@MainActor
final class ContentBlockerManager: ObservableObject {
    static let shared = ContentBlockerManager()

    @Published private(set) var state: BlockerState = .preparing

    /// 通常タブ用コンパイル済みWKContentRuleList（ベース＋通常例外統合）
    private(set) var normalRuleList: WKContentRuleList?

    /// プライベートタブ用コンパイル済みWKContentRuleList（ベースルールのみ、例外ホスト一切不含）
    private(set) var privateBaseRuleList: WKContentRuleList?

    /// ルールメタデータ
    private(set) var ruleVersion: String = "1.0.0"
    private(set) var ruleCount: Int = 0
    private(set) var sourceCommit: String = ""
    private(set) var license: String = "CC BY 3.0"

    private let privateBaseIdentifier = "ClipHarborPrivateBaseRules_v1"
    private let fallbackRuleListIdentifier = "ClipHarborFallbackRules_v1"
    private var normalCompilationGeneration: Int = 0
    private var activeNormalIdentifier: String?
    private var isCompilingBase: Bool = false
    private var isCompilingNormal: Bool = false

    /// ブロッカーが利用可能かどうか
    var isReady: Bool {
        switch state {
        case .active, .fallbackActive:
            return normalRuleList != nil || privateBaseRuleList != nil
        default:
            return false
        }
    }

    private init() {
        loadMetadata()
        prepareAllRules()
    }

    /// ホスト完全一致用の正規表現パターン
    /// - `example.com` の場合: `^https?://example\.com(:[0-9]+)?([/?#].*)?$`
    /// - サブドメイン（`sub.example.com`）や前方一致偽装ドメイン（`example.com.evil.test`）を確実に除外
    static func exactHostPattern(for rawHost: String) -> String {
        let trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let escaped = NSRegularExpression.escapedPattern(for: trimmed)
        return "^https?://" + escaped + "(:[0-9]+)?([/?#].*)?$"
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

    /// 全ルールの準備（プライベート用ベースルール＋通常用統合ルール）
    func prepareAllRules() {
        preparePrivateBaseRuleList()
        recompileNormalRuleList()
    }

    // MARK: - プライベート用ベースルール（例外ホストを一切含まない）

    private func preparePrivateBaseRuleList() {
        guard !isCompilingBase else { return }
        guard let store = WKContentRuleListStore.default() else {
            self.state = .failed("WKContentRuleListStore is unavailable")
            return
        }

        isCompilingBase = true
        store.lookUpContentRuleList(forIdentifier: privateBaseIdentifier) { [weak self] ruleList, _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if let ruleList = ruleList {
                    self.privateBaseRuleList = ruleList
                    self.isCompilingBase = false
                    self.checkStateAfterCompilation()
                } else {
                    self.compileBundledBaseRules()
                }
            }
        }
    }

    private func compileBundledBaseRules() {
        guard let url = Bundle.main.url(forResource: "blocker_rules", withExtension: "json"),
              let ruleJSONString = try? String(contentsOf: url, encoding: .utf8),
              let store = WKContentRuleListStore.default() else {
            self.isCompilingBase = false
            self.compileFallbackRules(originalError: "blocker_rules.json not found")
            return
        }

        store.compileContentRuleList(forIdentifier: privateBaseIdentifier, encodedContentRuleList: ruleJSONString) { [weak self] ruleList, error in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.isCompilingBase = false
                if let ruleList = ruleList {
                    self.privateBaseRuleList = ruleList
                    self.checkStateAfterCompilation()
                } else {
                    let errMsg = error?.localizedDescription ?? "Unknown compilation error"
                    self.compileFallbackRules(originalError: errMsg)
                }
            }
        }
    }

    // MARK: - 通常タブ用統合ルール（ベースルール＋通常例外ホストの統合）

    /// 通常例外設定が変更された際に呼び出され、最新世代の統合ルールを非同期コンパイル
    func recompileNormalRuleList() {
        guard let store = WKContentRuleListStore.default() else {
            self.state = .failed("WKContentRuleListStore is unavailable")
            return
        }

        // 世代カウントをインクリメント（連続変更時の古いコンパイル完了による上書きを防止）
        normalCompilationGeneration += 1
        let currentGeneration = normalCompilationGeneration
        let targetIdentifier = "ClipHarborNormalRules_gen\(currentGeneration)"

        guard let url = Bundle.main.url(forResource: "blocker_rules", withExtension: "json"),
              let baseData = try? Data(contentsOf: url),
              var rulesArray = (try? JSONSerialization.jsonObject(with: baseData)) as? [[String: Any]] else {
            return
        }

        // 通常タブのホワイトリスト例外ホストを取得
        let whitelisted = AppSettingsManager.shared.whitelistedHosts
        for host in whitelisted {
            let pattern = Self.exactHostPattern(for: host)
            let exceptionRule: [String: Any] = [
                "trigger": [
                    "url-filter": ".*",
                    "if-top-url": [pattern]
                ],
                "action": [
                    "type": "ignore-previous-rules"
                ]
            ]
            rulesArray.append(exceptionRule)
        }

        guard let mergedData = try? JSONSerialization.data(withJSONObject: rulesArray),
              let mergedJSONString = String(data: mergedData, encoding: .utf8) else {
            return
        }

        isCompilingNormal = true

        store.compileContentRuleList(forIdentifier: targetIdentifier, encodedContentRuleList: mergedJSONString) { [weak self] newRuleList, error in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.isCompilingNormal = false

                // 世代チェック: 新しい世代のコンパイルが既に走っている場合は破棄
                guard currentGeneration == self.normalCompilationGeneration else {
                    store.removeContentRuleList(forIdentifier: targetIdentifier) { _ in }
                    return
                }

                if let newRuleList = newRuleList {
                    let oldIdentifier = self.activeNormalIdentifier
                    self.normalRuleList = newRuleList
                    self.activeNormalIdentifier = targetIdentifier
                    self.checkStateAfterCompilation()

                    // 古い世代のコンパイル済みルールを非同期削除
                    if let oldId = oldIdentifier, oldId != targetIdentifier {
                        store.removeContentRuleList(forIdentifier: oldId) { _ in }
                    }

                    NotificationCenter.default.post(name: .contentBlockerRulesReady, object: nil)
                } else {
                    let errMsg = error?.localizedDescription ?? "Normal rules compilation failed"
                    // 失敗時は旧ルールを保持し、エラーを通知
                    NotificationCenter.default.post(name: .contentBlockerCompileFailed, object: errMsg)
                }
            }
        }
    }

    private func compileFallbackRules(originalError: String) {
        guard let store = WKContentRuleListStore.default() else {
            self.state = .failed("WKContentRuleListStore is unavailable")
            return
        }

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
                    self.privateBaseRuleList = ruleList
                    self.normalRuleList = ruleList
                    self.state = .fallbackActive(version: "fallback-1.0")
                    NotificationCenter.default.post(name: .contentBlockerRulesReady, object: nil)
                } else {
                    self.state = .failed(originalError)
                }
            }
        }
    }

    private func checkStateAfterCompilation() {
        if normalRuleList != nil || privateBaseRuleList != nil {
            self.state = .active(version: self.ruleVersion)
        }
    }

    /// 設定変更時の通知
    func notifySettingsChanged() {
        NotificationCenter.default.post(name: .contentBlockerSettingsChanged, object: nil)
    }

    // MARK: - 判定と適用管理

    /// 通常・プライベートに応じた適用ルールリストを返却
    func targetRuleList(isPrivate: Bool) -> WKContentRuleList? {
        if isPrivate {
            return privateBaseRuleList
        } else {
            return normalRuleList
        }
    }

    /// 指定タブ・ホストにおいてルールをWKUserContentControllerに装着すべきか判定
    func shouldAttachRules(for host: String?, isPrivate: Bool) -> Bool {
        guard AppSettingsManager.shared.blockAdsAndTrackers else { return false }
        guard isReady else { return false }

        if isPrivate {
            // プライベートタブ: メモリ内例外ホストの場合はルールを脱着して解除
            if let host = host, isHostWhitelisted(host, isPrivate: true) {
                return false
            }
            return true
        } else {
            // 通常タブ: 統合ルール内に ignore-previous-rules が含まれているため常時装着
            return true
        }
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
            NotificationCenter.default.post(name: .contentBlockerSettingsChanged, object: nil)
        } else {
            AppSettingsManager.shared.toggleWhitelist(for: host)
            recompileNormalRuleList()
        }
    }
}
