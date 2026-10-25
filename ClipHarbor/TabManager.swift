import Foundation
import SwiftUI
import WebKit

/// タブ復元用の最小限の永続化レコード
struct SavedTabItem: Codable, Equatable, Sendable {
    let id: UUID
    let urlString: String
    let title: String
}

/// セッション全体の永続化レコード
struct TabSessionRecord: Codable, Sendable {
    let activeTabID: UUID
    let tabs: [SavedTabItem]
}

/// タブ永続化用のURL安全性ポリシー。
/// - http/https スキームのみ許可。
/// - 認証情報（username/password）を完全除去。
/// - token, signature, session 等の一時的な認証・署名クエリパラメータを平文保存しないよう除外。
/// - 検索クエリ（q）や動画ID（v, id）等の通常ページへの再訪問に必要なパラメータ・パスは完全に保持。
/// - ログイン・OAuth専用URLは除外。
enum TabURLPolicy {
    private static let sensitiveQueryKeys: Set<String> = [
        "token", "access_token", "auth_token", "auth", "signature", "sig",
        "session", "session_id", "jsessionid", "phpsessid", "aspsessionid",
        "bearer", "api_key", "apikey", "secret", "jwt", "code"
    ]

    static func sanitizeForTabRestore(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        // 1. 認証情報（username / password）の除去
        components.user = nil
        components.password = nil

        // 2. ログイン・OAuth認証専用パスの除外
        let lowerPath = components.path.lowercased()
        if lowerPath.contains("/oauth") || lowerPath.contains("/signin") || lowerPath.contains("/login") {
            return nil
        }

        // 3. トークン・署名・セッションクエリの除去（検索クエリや動画IDパラメータ等は維持）
        if let queryItems = components.queryItems, !queryItems.isEmpty {
            let filtered = queryItems.filter { item in
                !sensitiveQueryKeys.contains(item.name.lowercased())
            }
            components.queryItems = filtered.isEmpty ? nil : filtered
        }

        guard let cleanURL = components.url else { return nil }
        guard cleanURL.absoluteString.count <= 2048 else { return nil }
        return cleanURL
    }
}

/// 複数タブのライフサイクル（生成・切り替え・削除・上限管理・自動永続化・復元）を担当するマネージャー。
/// - 各タブは独立した BrowserModel インスタンスとして保持される。
/// - 通常タブ間では既存の WKWebsiteDataStore.default() を共有し、同一セッション・ログイン状態を維持する。
/// - タブ切り替え時は既存の BrowserModel および WKWebView を再利用し、破棄や再読み込みを行わない。
/// - タブ削除時のみ BrowserModel.teardown() を呼び出し、強参照循環やメモリリークを防止する。
/// - アプリ終了・再起動後もタブ数・順序・URL・タイトル・アクティブタブを `Library/Application Support/ClipHarbor/tabs.json` から自動復元。
/// - 非アクティブタブは lazy var webView により遅延ロードされ、起動時の過剰なメモリ・通信消費を防ぐ。
@MainActor
final class TabManager: ObservableObject {
    /// 安全のための通常タブ上限数（過剰なメモリ消費を防止）
    static let maxTabs: Int = 20
    /// プライベートタブ上限数（メモリ保護のため同等に設定）
    static let maxPrivateTabs: Int = 20

    /// 管理中の全通常タブ（最低1つを維持、tabs.jsonに永続化）
    @Published private(set) var tabs: [BrowserModel] = []

    /// 管理中の全プライベートタブ（非永続、アプリ終了・全閉鎖で完全に破棄）
    @Published private(set) var privateTabs: [BrowserModel] = []

    /// 現在のブラウズモード（false: 通常モード, true: 🕶️プライベートモード）
    @Published var isPrivateMode: Bool = false

    /// 現在画面に表示中の通常アクティブタブID
    @Published var activeTabID: UUID {
        didSet {
            if oldValue != activeTabID {
                handleActiveTabChanged(from: oldValue, to: activeTabID)
                scheduleSave()
            }
        }
    }

    /// 現在画面に表示中のプライベートアクティブタブID
    @Published var activePrivateTabID: UUID?

    /// プライベートセッション用の非永続WKWebsiteDataStore（プライベートタブ間でCookie等を共有）
    private(set) var privateDataStore: WKWebsiteDataStore = WKWebsiteDataStore.nonPersistent()

    /// 現在のアクティブタブ（現在のモードに応じた有効なBrowserModelを返す純粋ゲッター。副作用なし）
    var activeTab: BrowserModel {
        if isPrivateMode {
            if let id = activePrivateTabID, let current = privateTabs.first(where: { $0.id == id }) {
                return current
            }
            if let first = privateTabs.first {
                return first
            }
        }
        return activeRegularTab
    }

    /// 通常アクティブタブ（常に有効なインスタンスを返す）
    private var activeRegularTab: BrowserModel {
        if let current = tabs.first(where: { $0.id == activeTabID }) {
            return current
        }
        if let first = tabs.first {
            return first
        }
        // 万が一空の場合は新しいホームタブを生成して復旧
        let fallback = BrowserModel()
        setupTab(fallback)
        tabs = [fallback]
        activeTabID = fallback.id
        return fallback
    }

    /// 通常タブの新規作成が可能か
    var canCreateNewTab: Bool {
        tabs.count < Self.maxTabs
    }

    /// プライベートタブの新規作成が可能か
    var canCreateNewPrivateTab: Bool {
        privateTabs.count < Self.maxPrivateTabs
    }

    /// 通常タブ数
    var count: Int {
        tabs.count
    }

    /// プライベートタブ数
    var privateCount: Int {
        privateTabs.count
    }

    /// 非同期保存用直列キュー（FIFO実行により順序を保証）
    private let saveQueue = DispatchQueue(label: "com.clipharbor.tabmanager.save", qos: .utility)

    /// 保存先ディレクトリ（Library/Application Support/ClipHarbor）
    private static var storageDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("ClipHarbor", isDirectory: true)
    }

    /// 保存先JSONファイルURL
    private static var sessionFileURL: URL {
        storageDirectoryURL.appendingPathComponent("tabs.json", isDirectory: false)
    }

    init() {
        let restored = Self.loadSessionFromDisk()
        if let (restoredTabs, restoredActiveID) = restored, !restoredTabs.isEmpty {
            self.tabs = restoredTabs
            self.activeTabID = restoredActiveID
        } else {
            let initialTab = BrowserModel()
            self.tabs = [initialTab]
            self.activeTabID = initialTab.id
        }

        for tab in self.tabs {
            setupTab(tab)
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.saveImmediately()
        }
    }

    // MARK: - タブ操作API

    /// 新しいタブを作成し、アクティブにする
    @discardableResult
    func createNewTab(url: URL = BrowserModel.homeURL) -> BrowserModel? {
        guard canCreateNewTab else { return nil }
        activeTab.captureSnapshot()
        let newTab = BrowserModel(initialURL: url)
        setupTab(newTab)
        tabs.append(newTab)
        activeTabID = newTab.id // didSet により scheduleSave() が発火
        if isPrivateMode {
            isPrivateMode = false
        }
        return newTab
    }

    /// 指定IDのタブをアクティブにする（WebViewの再生成や再読み込みは行わない）
    func selectTab(id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        if isPrivateMode {
            isPrivateMode = false
        }
        guard activeTabID != id else { return }
        activeTab.captureSnapshot()
        activeTabID = id // didSet により scheduleSave() が発火
    }

    /// 指定IDのタブを明示的に閉じる
    /// - 最後のタブを閉じた場合は空画面にせず、自動的に新しいホームタブを作成する。
    /// - 削除されたタブに対してのみ BrowserModel.teardown() を実行する。
    func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closingTab = tabs[index]

        // 閉じる対象がアクティブタブの場合、削除前に新しいアクティブタブを決定する
        if activeTabID == id {
            if tabs.count > 1 {
                let nextIndex = index > 0 ? index - 1 : index + 1
                activeTabID = tabs[nextIndex].id
            }
        }

        tabs.remove(at: index)

        // WebKit強参照循環およびKVO・delegateを安全に解除
        closingTab.teardown()

        // 最後のタブを閉じた場合は空画面にせず、新しいホームタブを作成
        if tabs.isEmpty {
            let freshTab = BrowserModel()
            setupTab(freshTab)
            tabs = [freshTab]
            activeTabID = freshTab.id
        }

        scheduleSave()
    }

    // MARK: - プライベートタブ操作API

    /// 新しいプライベートタブを作成し、アクティブにする
    @discardableResult
    func createPrivateTab(url: URL = BrowserModel.homeURL) -> BrowserModel? {
        guard canCreateNewPrivateTab else { return nil }
        activeTab.captureSnapshot()
        let newTab = BrowserModel(
            initialURL: url,
            isPrivate: true,
            websiteDataStore: privateDataStore
        )
        setupTab(newTab)
        privateTabs.append(newTab)
        activePrivateTabID = newTab.id
        if !isPrivateMode {
            isPrivateMode = true
        }
        return newTab
    }

    /// 指定IDのプライベートタブをアクティブにする
    func selectPrivateTab(id: UUID) {
        guard privateTabs.contains(where: { $0.id == id }) else { return }
        if !isPrivateMode {
            isPrivateMode = true
        }
        guard activePrivateTabID != id else { return }
        activeTab.captureSnapshot()
        activePrivateTabID = id
    }

    /// 指定IDのプライベートタブを明示的に閉じる
    /// - 最後のプライベートタブを閉じた場合は、旧ストアのデータを非同期消去し、通常モードへ安全に復帰する。
    func closePrivateTab(id: UUID) {
        guard let index = privateTabs.firstIndex(where: { $0.id == id }) else { return }
        let closingTab = privateTabs[index]

        // 閉じる対象がアクティブタブの場合、削除前に新しいアクティブタブを決定
        if activePrivateTabID == id {
            if privateTabs.count > 1 {
                let nextIndex = index > 0 ? index - 1 : index + 1
                activePrivateTabID = privateTabs[nextIndex].id
            } else {
                activePrivateTabID = nil
            }
        }

        privateTabs.remove(at: index)

        // WebKit強参照循環およびKVO・delegateを安全に解除
        closingTab.teardown()

        // 最後のプライベートタブが閉じられた場合
        if privateTabs.isEmpty {
            activePrivateTabID = nil
            resetPrivateSessionStore()
            if isPrivateMode {
                isPrivateMode = false
            }
        }
    }

    /// すべてのプライベートタブを一括で閉じ、セッションデータを破棄して通常モードに復帰する
    func closeAllPrivateTabs() {
        for tab in privateTabs {
            tab.teardown()
        }
        privateTabs.removeAll()
        activePrivateTabID = nil
        resetPrivateSessionStore()
        if isPrivateMode {
            isPrivateMode = false
        }
    }

    /// ブラウズモードを切り替える（通常モード ⇔ 🕶️プライベートモード）
    /// - プライベートモード切替時にタブが0件の場合は明示的に1つ作成。作成失敗時はモード切替を安全に中止する。
    @discardableResult
    func switchBrowsingMode(toPrivate: Bool) -> Bool {
        guard isPrivateMode != toPrivate else { return true }
        if toPrivate {
            if privateTabs.isEmpty {
                guard createPrivateTab() != nil else {
                    return false
                }
            }
        }
        activeTab.captureSnapshot()
        isPrivateMode = toPrivate
        return true
    }

    /// プライベートセッション用ストアを安全に再生成し、旧ストアを非同期消去する
    private func resetPrivateSessionStore() {
        let oldStore = self.privateDataStore
        // 即座に新規ストアを割り当て、直後に新規タブが開かれても旧ストアの消去に巻き込まれないようにする
        self.privateDataStore = WKWebsiteDataStore.nonPersistent()
        // 旧ストアのデータを全消去（通常ストアdefault()には一切影響なし）
        oldStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
            // 非同期消去完了
        }
    }

    // MARK: - 内部処理と永続化

    /// URLを新しいタブで開き、そのタブをアクティブにする（プライベート状態を継承）
    func openURLInNewTab(_ url: URL, from tab: BrowserModel) {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else {
            return
        }
        if tab.isPrivate {
            if canCreateNewPrivateTab {
                createPrivateTab(url: url)
            } else {
                tab.showNotice("プライベートタブ上限（\(Self.maxPrivateTabs)件）に達しているため、新しいタブを開けませんでした。不要なタブを閉じてから再度お試しください。")
            }
        } else {
            if canCreateNewTab {
                createNewTab(url: url)
            } else {
                tab.showNotice("タブ上限（\(Self.maxTabs)件）に達しているため、新しいタブを開けませんでした。不要なタブを閉じてから再度お試しください。")
            }
        }
    }

    private func setupTab(_ tab: BrowserModel) {
        tab.onNavigationFinished = { [weak self, weak tab] in
            guard let self = self, let tab = tab else { return }
            if !tab.isPrivate {
                self.scheduleSave()
            }
        }
        tab.onRequestOpenInNewTab = { [weak self, weak tab] url in
            guard let self = self, let tab = tab else { return }
            self.openURLInNewTab(url, from: tab)
        }
    }

    private func handleActiveTabChanged(from oldID: UUID, to newID: UUID) {
        // 将来のステップでタブ非アクティブ化時のサムネイル記録や音声制御を安全にフック可能
    }

    /// 非同期保存をスケジュール（直列キューでFIFO実行）
    func scheduleSave() {
        guard let record = createSessionRecord() else { return }
        let dirURL = Self.storageDirectoryURL
        let fileURL = Self.sessionFileURL

        saveQueue.async {
            Self.writeRecord(record, dirURL: dirURL, fileURL: fileURL)
        }
    }

    /// アプリバックグラウンド移行時の即時保存（UIBackgroundTaskIdentifierにより非同期完了を保証し、メインスレッドのブロッキングやデッドロックを防止）
    func saveImmediately() {
        guard let record = createSessionRecord() else { return }
        let dirURL = Self.storageDirectoryURL
        let fileURL = Self.sessionFileURL

        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "com.clipharbor.tabmanager.save") {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }

        saveQueue.async {
            Self.writeRecord(record, dirURL: dirURL, fileURL: fileURL)
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
        }
    }

    private func createSessionRecord() -> TabSessionRecord? {
        // 将来のプライベートタブは永続化対象外
        let regularTabs = tabs.filter { !$0.isPrivate }
        guard !regularTabs.isEmpty else { return nil }

        let snapshotTabs: [SavedTabItem] = regularTabs.map { tab in
            let validURL = TabURLPolicy.sanitizeForTabRestore(tab.currentURL) ?? BrowserModel.homeURL
            return SavedTabItem(
                id: tab.id,
                urlString: validURL.absoluteString,
                title: tab.pageTitle
            )
        }

        let safeActiveID = regularTabs.contains(where: { $0.id == activeTabID }) ? activeTabID : regularTabs.first!.id
        return TabSessionRecord(activeTabID: safeActiveID, tabs: snapshotTabs)
    }

    private static func writeRecord(_ record: TabSessionRecord, dirURL: URL, fileURL: URL) {
        do {
            if !FileManager.default.fileExists(atPath: dirURL.path) {
                try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let data = try encoder.encode(record)
            // .atomic により書き込み途中の破損を防止
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // ログ出力・クラッシュを回避
        }
    }

    private static func loadSessionFromDisk() -> (tabs: [BrowserModel], activeID: UUID)? {
        let fileURL = sessionFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let record = try JSONDecoder().decode(TabSessionRecord.self, from: data)
            let safeItems = Array(record.tabs.prefix(maxTabs))
            guard !safeItems.isEmpty else { return nil }

            var restoredModels: [BrowserModel] = []
            for item in safeItems {
                let targetURL: URL
                if let url = URL(string: item.urlString),
                   let clean = TabURLPolicy.sanitizeForTabRestore(url) {
                    targetURL = clean
                } else {
                    targetURL = BrowserModel.homeURL
                }
                let model = BrowserModel(id: item.id, initialURL: targetURL, initialTitle: item.title)
                restoredModels.append(model)
            }

            let activeID: UUID
            if restoredModels.contains(where: { $0.id == record.activeTabID }) {
                activeID = record.activeTabID
            } else {
                activeID = restoredModels.first!.id
            }

            return (restoredModels, activeID)
        } catch {
            // 破損JSON読み込み失敗時は既存ファイルを空JSONで上書きせず安全に無視
            return nil
        }
    }
}
