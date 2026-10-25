import SwiftUI
import WebKit

/// 子ポップアップWebViewの管理レコード
struct PopupInfo: Identifiable {
    let id = UUID()
    let webView: WKWebView
    let initialURL: URL?
}

/// WKWebViewのブラウズと、ページ内のHTML5動画の状態管理を担当する。
/// 暗号化/DRMの解除、通信内容の強制傍受、保護されたAPIへのアクセスは行わない。
@MainActor
final class BrowserModel: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    static let homeURL = URL(string: "https://www.google.com/")!

    let id: UUID
    let initialURL: URL

    @Published var address: String
    @Published var pageTitle = "ClipHarbor"
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var loadingProgress: Double = 0
    /// ページ内で検出した動画（キーは一時ID）
    @Published private(set) var videos: [String: TrackedVideo] = [:]
    /// Performance API等で見つけたメディアURL（video要素との対応は不明）
    @Published private(set) var resourceCandidates: [MediaCandidate] = []
    /// 画面下部に一時的に表示する案内
    @Published var notice: String?
    /// メモリ内にのみ保持する最新ページのサムネイル（ディスク永続化なし）
    @Published private(set) var snapshot: UIImage?

    /// 下部フローティングツールバーの非表示フラグ（スクロール連動）
    @Published var isToolbarHidden = false
    /// URL入力・編集中フラグ（編集中はツールバーを常時表示）
    @Published var isEditingAddress = false
    /// 迷惑ポップアップブロック通知（ブロックされたホストを保持、画面遷移で失効）
    @Published var pendingBlockedPopupHost: String?
    /// 現在表示中の子ポップアップ情報（最大1件制限）
    @Published var activePopup: PopupInfo?
    /// プライベートブラウズモード（trueの場合、閲覧履歴・Cookie・セッションは永続化されない）
    let isPrivate: Bool
    /// プライベートタブ用の非永続WKWebsiteDataStore（通常タブはnil、WKWebsiteDataStore.default()を使用）
    private let customWebsiteDataStore: WKWebsiteDataStore?
    /// ナビゲーション完了時（通常遷移およびSPA遷移）の通知コールバック（TabManager等のセッション同期用）
    var onNavigationFinished: (() -> Void)? = nil
    /// リンク長押しメニュー等から新しいタブを開く要求コールバック
    var onRequestOpenInNewTab: ((URL) -> Void)? = nil
    private(set) var isWebViewCreated = false
    private(set) var isTornDown = false
    private var attachedRuleList: WKContentRuleList?
    private var lastBlockedPopupTime: Date = .distantPast
    private var noticeTask: Task<Void, Never>?
    private var progressObservation: NSKeyValueObservation?
    private var scrollObservation: NSKeyValueObservation?
    private var lastScrollY: CGFloat = 0
    private var accumulatedDownwardScroll: CGFloat = 0
    private var accumulatedUpwardScroll: CGFloat = 0
    private static let maxVideos = 50
    private static let maxResources = 50

    /// 現在のタブのURL（WebView未生成時は初期URL）
    var currentURL: URL {
        if isWebViewCreated, let url = webView.url, url.scheme?.lowercased() != "about" {
            return url
        }
        return initialURL
    }

    /// フローティングツールバー上段で表示するドメインまたはURL
    var displayDomainOrURL: String {
        if let host = currentURL.host, !host.isEmpty {
            return host
        }
        if !pageTitle.isEmpty && pageTitle != "ClipHarbor" {
            return pageTitle
        }
        return address.isEmpty ? "検索またはURLを入力" : address
    }

    /// 現在のURLがHTTPS接続か判定
    var isSecurePage: Bool {
        currentURL.scheme?.lowercased() == "https"
    }

    init(
        id: UUID = UUID(),
        initialURL: URL = BrowserModel.homeURL,
        initialTitle: String = "",
        isPrivate: Bool = false,
        websiteDataStore: WKWebsiteDataStore? = nil
    ) {
        self.id = id
        self.initialURL = initialURL
        self.address = initialURL.absoluteString
        self.pageTitle = initialTitle
        self.isPrivate = isPrivate
        self.customWebsiteDataStore = websiteDataStore
        super.init()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleContentBlockerNotification),
            name: .contentBlockerRulesReady,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleContentBlockerNotification),
            name: .contentBlockerSettingsChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleContentBlockerCompileFailed(_:)),
            name: .contentBlockerCompileFailed,
            object: nil
        )
    }

    @objc private func handleContentBlockerNotification() {
        guard isWebViewCreated, !isTornDown else { return }
        syncContentBlockerRules(host: webView.url?.host ?? currentURL.host)
    }

    @objc private func handleContentBlockerCompileFailed(_ notification: Notification) {
        showNotice(NSLocalizedString("Failed to update content blocking rules. Preserving previous rules.", comment: ""))
    }

    lazy var webView: WKWebView = {
        isWebViewCreated = true
        let controller = WKUserContentController()
        // ページのJavaScriptから隔離されたワールドで監視する（ページ側が偽のメッセージを送れない）
        controller.add(self, contentWorld: .defaultClient, name: MediaScannerScript.handlerName)
        controller.addUserScript(WKUserScript(source: MediaScannerScript.source,
                                              injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: false,
                                              in: .defaultClient))
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true

        // スクリプトからのウィンドウ作成要求をcreateWebViewWithに確実に到達させ、アプリ側で一元判定
        let preferences = WKPreferences()
        preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.preferences = preferences

        // Webサイトデータ（Cookie・キャッシュ・LocalStorage等）の分離設定
        if isPrivate {
            // プライベートモード: 注入された非永続ストアを使用（未指定時も安全にnonPersistent()を生成し、default()へのフォールバックを絶対防止）
            configuration.websiteDataStore = customWebsiteDataStore ?? WKWebsiteDataStore.nonPersistent()
        } else {
            // 通常モード: 永続ストアを使用
            configuration.websiteDataStore = WKWebsiteDataStore.default()
        }

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self

        // 初期のコンテンツブロッカールール適用
        syncContentBlockerRules(host: initialURL.host)
        // WebKit標準の左右スワイプによる進む・戻るジェスチャーナビゲーションを有効化（通常・プライベート共通）
        view.allowsBackForwardNavigationGestures = true
        view.backgroundColor = .systemBackground
        view.scrollView.backgroundColor = .systemBackground
        // Edge-to-Edge描画のため自動インセット調整を無効化（上下の黒帯や予期しない空白を防止）
        view.scrollView.contentInsetAdjustmentBehavior = .never
        // ホームインジケータ領域（約24pt）を考慮した最小限のコンテンツ余白
        view.scrollView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 24, right: 0)
        view.scrollView.scrollIndicatorInsets = UIEdgeInsets(top: 0, left: 0, bottom: 24, right: 0)
        progressObservation = view.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            let value = webView.estimatedProgress
            Task { @MainActor in self?.loadingProgress = value }
        }
        scrollObservation = view.scrollView.observe(\.contentOffset, options: [.old, .new]) { [weak self] scrollView, change in
            guard let self = self else { return }
            let currentY = scrollView.contentOffset.y
            let oldY = change.oldValue?.y ?? currentY
            if Thread.isMainThread {
                self.handleScroll(currentY: currentY, oldY: oldY, in: scrollView)
            } else {
                Task { @MainActor in
                    self.handleScroll(currentY: currentY, oldY: oldY, in: scrollView)
                }
            }
        }
        view.load(URLRequest(url: initialURL))
        return view
    }()

    // MARK: - 動画の選択

    var selection: VideoSelection.Result {
        VideoSelection.select(from: Array(videos.values))
    }

    /// 候補一覧（フォールバック）用の行
    struct CandidateRow: Identifiable {
        let id: String
        let title: String
        let detail: String
        let posterURL: URL?
        let stateLabel: String?
        let isPlaying: Bool
        let candidate: MediaCandidate?
        let reason: String?
    }

    var candidateRows: [CandidateRow] {
        let sortedVideos = videos.values.sorted {
            if $0.isPlaying != $1.isPlaying { return $0.isPlaying }
            return max($0.lastPlayAt, $0.lastInteractionAt) > max($1.lastPlayAt, $1.lastInteractionAt)
        }
        var rows: [CandidateRow] = []
        var usedURLs = Set<String>()
        for video in sortedVideos {
            if let c = video.candidate { usedURLs.insert(c.id) }
            let detail: String
            if let c = video.candidate {
                detail = "\(c.formatLabel) · \(c.host)"
            } else {
                detail = video.isMainFrame ? "ページ内の動画" : "埋め込み（iframe）内の動画"
            }
            rows.append(CandidateRow(id: "video-\(video.id)", title: video.displayTitle, detail: detail,
                                     posterURL: video.posterURL, stateLabel: video.stateLabel,
                                     isPlaying: video.isPlaying, candidate: video.candidate,
                                     reason: video.unsupportedReason))
        }
        for c in resourceCandidates where !usedURLs.contains(c.id) {
            rows.append(CandidateRow(id: "res-\(c.id)", title: c.suggestedName,
                                     detail: "\(c.formatLabel) · \(c.host)（ページ内の通信から検出）",
                                     posterURL: nil, stateLabel: nil, isPlaying: false,
                                     candidate: c, reason: nil))
        }
        return rows
    }

    var hasAnyMedia: Bool { !videos.isEmpty || !resourceCandidates.isEmpty }

    // MARK: - フローティングツールバー表示制御 & スクロール監視

    /// ツールバーを即時またはアニメーションで再表示
    func showToolbar() {
        if isToolbarHidden {
            withAnimation(.easeInOut(duration: 0.2)) {
                isToolbarHidden = false
            }
        }
        accumulatedDownwardScroll = 0
        accumulatedUpwardScroll = 0
    }

    /// ツールバーをアニメーションで非表示
    func hideToolbar() {
        guard !isEditingAddress else { return }
        if !isToolbarHidden {
            withAnimation(.easeInOut(duration: 0.2)) {
                isToolbarHidden = true
            }
        }
        accumulatedDownwardScroll = 0
        accumulatedUpwardScroll = 0
    }

    private func handleScroll(currentY: CGFloat, oldY: CGFloat, in scrollView: UIScrollView) {
        // 1. URL編集中は常に表示を維持
        if isEditingAddress {
            if isToolbarHidden { showToolbar() }
            return
        }

        // 2. ページ最上部（または上端バウンス中）は常に表示
        if currentY <= 0 {
            showToolbar()
            lastScrollY = currentY
            return
        }

        // 3. コンテンツ全体の高さと画面高さを取得
        let effectiveContentHeight = scrollView.contentSize.height + scrollView.contentInset.bottom
        let visibleHeight = scrollView.bounds.height
        let maxOffsetY = effectiveContentHeight - visibleHeight

        // 4. コンテンツ全体の高さが画面以下の場合は常に表示
        if maxOffsetY <= 0 {
            showToolbar()
            lastScrollY = currentY
            return
        }

        // 5. ページ下端バウンス（rubber-band）の無視
        if currentY >= maxOffsetY {
            lastScrollY = currentY
            return
        }

        let delta = currentY - oldY
        lastScrollY = currentY

        // 6. 非常に小さな揺れ（0.5pt未満）は無視
        if abs(delta) < 0.5 {
            return
        }

        if delta > 0 {
            // 下方向へスクロール（コンテンツが上へ移動：delta > 0）
            accumulatedUpwardScroll = 0
            accumulatedDownwardScroll += delta
            if accumulatedDownwardScroll >= 24 {
                hideToolbar()
            }
        } else {
            // 上方向へスクロール（コンテンツが下へ移動：delta < 0）
            accumulatedDownwardScroll = 0
            accumulatedUpwardScroll += abs(delta)
            if accumulatedUpwardScroll >= 12 {
                showToolbar()
            }
        }
    }

    // MARK: - ナビゲーション

    func navigate(to input: String) {
        showToolbar()
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let target: URL?
        if let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            target = url
        } else if !trimmed.contains(" "), trimmed.contains("."), !trimmed.contains("://") {
            target = URL(string: "https://" + trimmed)
        } else {
            target = AppSettingsManager.shared.searchEngine.searchURL(for: trimmed)
        }
        guard let target = target else { return }
        webView.load(URLRequest(url: target))
    }

    /// URLを直接指定して現在のタブで読み込む
    func loadURL(_ url: URL) {
        showToolbar()
        webView.load(URLRequest(url: url))
    }

    func goBack() {
        showToolbar()
        if webView.canGoBack { webView.goBack() }
    }

    func goForward() {
        showToolbar()
        if webView.canGoForward { webView.goForward() }
    }

    func reload() {
        showToolbar()
        webView.reload()
    }

    func goHome() {
        showToolbar()
        webView.load(URLRequest(url: AppSettingsManager.shared.searchEngine.homeURL))
    }

    /// ダウンロード時に使う、ページの最小限の通信情報（メモリ上のみ）
    func makeRequestContext(completion: @escaping (RequestContext) -> Void) {
        let pageURL = webView.url
        let store = webView.configuration.websiteDataStore.httpCookieStore
        Task { @MainActor [weak self] in
            let cookies = await store.allCookies()
            var userAgent: String?
            if let webView = self?.webView {
                let result: Any? = try? await webView.evaluateJavaScript("navigator.userAgent")
                userAgent = result as? String
            }
            completion(RequestContext(cookies: cookies, userAgent: userAgent, pageURL: pageURL))
        }
    }

    func showNotice(_ text: String, seconds: Double = 5) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: - メモリ内ページスナップショット（タブプレビュー用）

    /// 現在のWebViewの描画内容をメモリ内に非同期取得する
    func captureSnapshot() {
        guard isWebViewCreated, !isTornDown else { return }
        guard webView.bounds.width > 0, webView.bounds.height > 0 else { return }

        let capturedURL = webView.url
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = NSNumber(value: 320)

        webView.takeSnapshot(with: config) { [weak self] image, _ in
            guard let self = self, !self.isTornDown, let image = image else { return }
            // 撮影中に別URLへ遷移していた場合、旧ページのスナップショットで上書きしない
            if let captured = capturedURL, let current = self.webView.url, captured != current {
                return
            }
            self.snapshot = image
        }
    }

    // MARK: - 複数タブ管理用ライフサイクル（明示的なタブ破棄）

    /// TabManager等から明示的にタブを閉じる際に呼び出される破棄処理。
    /// - 複数回呼ばれても安全な冪等処理（guard !isTornDown）。
    /// - 未生成のlazy var webViewを誤って初期化・生成しない（guard isWebViewCreated）。
    /// - WKUserContentControllerのScriptMessageHandlerおよびKVO・delegateを確実に解除し、強参照循環とメモリリークを防ぐ。
    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true

        onNavigationFinished = nil
        onRequestOpenInNewTab = nil
        snapshot = nil

        noticeTask?.cancel()
        noticeTask = nil

        progressObservation?.invalidate()
        progressObservation = nil

        scrollObservation?.invalidate()
        scrollObservation = nil

        NotificationCenter.default.removeObserver(self)
        clearBlockedPopupNotice()
        closeActivePopup()

        guard isWebViewCreated else { return }

        if let attached = attachedRuleList {
            webView.configuration.userContentController.remove(attached)
            attachedRuleList = nil
        }

        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil

        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: MediaScannerScript.handlerName, contentWorld: .defaultClient)

        resetPageState()
    }

    /// アクティブな子ポップアップを安全に閉じる（親のuserContentControllerは破壊しない）
    func closeActivePopup() {
        guard let popup = activePopup else { return }
        popup.webView.stopLoading()
        popup.webView.navigationDelegate = nil
        popup.webView.uiDelegate = nil
        activePopup = nil
    }

    private func resetPageState() {
        videos.removeAll()
        resourceCandidates.removeAll()
        snapshot = nil
    }

    private func updateNavigation(_ webView: WKWebView) {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        if !isEditingAddress { address = webView.url?.absoluteString ?? address }
        if let title = webView.title, !title.isEmpty { pageTitle = title }
    }

    private func recordHistoryIfEligible() {
        guard !isPrivate, !isTornDown else { return }
        guard let url = webView.url else { return }
        HistoryManager.shared.recordVisit(url: url, title: pageTitle)
    }

    // MARK: - コンテンツブロッカー & ポップアップ制御

    /// 現在のページで保護（広告・トラッカーまたはポップアップ）が有効に機能しているか
    var isProtectionActiveForCurrentPage: Bool {
        guard ContentBlockerManager.shared.isReady else { return false }
        let globalAd = AppSettingsManager.shared.blockAdsAndTrackers
        let globalPopup = AppSettingsManager.shared.blockAnnoyingPopups
        guard globalAd || globalPopup else { return false }
        guard let host = currentURL.host, !host.isEmpty else { return false }
        return !ContentBlockerManager.shared.isHostWhitelisted(host, isPrivate: isPrivate)
    }

    /// ホストのコンテンツブロッカールールを同期
    func syncContentBlockerRules(host: String? = nil) {
        guard isWebViewCreated, !isTornDown else { return }
        let targetHost = host ?? currentURL.host ?? webView.url?.host
        let shouldAttach = ContentBlockerManager.shared.shouldAttachRules(for: targetHost, isPrivate: isPrivate)
        guard let targetList = ContentBlockerManager.shared.targetRuleList(isPrivate: isPrivate) else { return }

        let controller = webView.configuration.userContentController
        if shouldAttach {
            if attachedRuleList !== targetList {
                controller.add(targetList)
                if let old = attachedRuleList {
                    controller.remove(old)
                }
                attachedRuleList = targetList
            }
        } else {
            if let attached = attachedRuleList {
                controller.remove(attached)
                attachedRuleList = nil
            }
        }
    }

    /// 現在のサイトの保護例外（ホワイトリスト）を反転し、ルール同期と再読み込みを実行
    func toggleSiteProtection() {
        guard let host = currentURL.host, !host.isEmpty else { return }
        ContentBlockerManager.shared.toggleWhitelist(for: host, isPrivate: isPrivate)
        syncContentBlockerRules(host: host)
        webView.reload()
    }

    /// 迷惑ポップアップブロック通知の発火（2秒以内の同一ホスト連打防止）
    func notifyBlockedPopup(for url: URL?) {
        let host = url?.host ?? currentURL.host ?? ""
        let now = Date()
        if now.timeIntervalSince(lastBlockedPopupTime) < 2.0 && pendingBlockedPopupHost == host {
            return
        }
        lastBlockedPopupTime = now
        pendingBlockedPopupHost = host
    }

    /// ポップアップブロック通知の消去
    func clearBlockedPopupNotice() {
        pendingBlockedPopupHost = nil
    }

    /// このサイトでポップアップを許可して再読み込み
    func allowPopupsForCurrentSiteAndReload() {
        let host = pendingBlockedPopupHost ?? currentURL.host ?? ""
        clearBlockedPopupNotice()
        guard !host.isEmpty else { return }
        ContentBlockerManager.shared.toggleWhitelist(for: host, isPrivate: isPrivate)
        syncContentBlockerRules(host: host)
        webView.reload()
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if navigationAction.targetFrame?.isMainFrame == true, let host = navigationAction.request.url?.host {
            syncContentBlockerRules(host: host)
        }
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        // 想定外のスキーム（アプリ起動URL等）への遷移はブロックする
        return ["http", "https", "about", "blob", "data"].contains(scheme) ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        clearBlockedPopupNotice()
        showToolbar()
        resetPageState()
        isLoading = true
        updateNavigation(webView)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        clearBlockedPopupNotice()
        // 旧ページから遅れて届いた情報を確実に破棄する
        resetPageState()
        updateNavigation(webView)
        syncContentBlockerRules(host: webView.url?.host)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        showToolbar()
        isLoading = false
        updateNavigation(webView)
        recordHistoryIfEligible()
        onNavigationFinished?()
        // 読み込み完了後にサムネイルを非同期更新
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.captureSnapshot()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        updateNavigation(webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        updateNavigation(webView)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // 同時に開ける子ポップアップは最大1件に制限（多重ポップアップ・DoS防止）
        guard activePopup == nil else { return nil }

        let targetHost = navigationAction.request.url?.host ?? webView.url?.host
        let shouldBlock = ContentBlockerManager.shared.shouldBlockPopups(for: targetHost, isPrivate: isPrivate)

        if shouldBlock {
            if navigationAction.navigationType == .linkActivated {
                // ユーザーによる意図的なタップ（リンククリック、target="_blank"等）: 許可して子画面として生成
                return spawnChildPopup(with: configuration, request: navigationAction.request)
            }
            // スクリプト等による勝手なポップアップ・新規ウィンドウ要求をブロック
            notifyBlockedPopup(for: navigationAction.request.url ?? webView.url)
            return nil
        } else {
            // ポップアップブロック無効、またはサイト例外登録済み: 許可して子画面として生成
            return spawnChildPopup(with: configuration, request: navigationAction.request)
        }
    }

    private func spawnChildPopup(with configuration: WKWebViewConfiguration, request: URLRequest) -> WKWebView {
        let child = WKWebView(frame: .zero, configuration: configuration)
        child.uiDelegate = self
        child.navigationDelegate = self
        child.allowsBackForwardNavigationGestures = true
        self.activePopup = PopupInfo(webView: child, initialURL: request.url)
        return child
    }

    func webViewDidClose(_ webView: WKWebView) {
        if activePopup?.webView === webView {
            closeActivePopup()
        }
    }

    // MARK: - リンク長押しコンテキストメニュー

    func webView(
        _ webView: WKWebView,
        contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
        completionHandler: @escaping (UIContextMenuConfiguration?) -> Void
    ) {
        guard let url = elementInfo.linkURL else {
            // リンク以外の要素（画像、テキスト選択等）はWebKitデフォルトのメニューを維持
            completionHandler(nil)
            return
        }

        let scheme = url.scheme?.lowercased() ?? ""
        guard ["http", "https"].contains(scheme) else {
            // HTTP/HTTPS以外のスキーム（tel, mailto等）は無理にWebViewへ読み込まず既存のスキーム方針を維持
            completionHandler(nil)
            return
        }

        let config = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self = self else { return UIMenu() }

            // 1. リンクを開く / Open Link (ClipHarborの現在のタブで開く)
            let openAction = UIAction(
                title: NSLocalizedString("Open Link", comment: ""),
                image: UIImage(systemName: "safari")
            ) { [weak self] _ in
                self?.loadURL(url)
            }

            // 2. 新しいタブで開く / Open in New Tab (ClipHarbor内の新しいタブで開き、そのタブへ切り替える)
            let openNewTabAction = UIAction(
                title: NSLocalizedString("Open in New Tab", comment: ""),
                image: UIImage(systemName: "plus.square.on.square")
            ) { [weak self] _ in
                self?.onRequestOpenInNewTab?(url)
            }

            // 3. リンクをコピー / Copy Link
            let copyAction = UIAction(
                title: NSLocalizedString("Copy Link", comment: ""),
                image: UIImage(systemName: "doc.on.doc")
            ) { _ in
                UIPasteboard.general.url = url
                UIPasteboard.general.string = url.absoluteString
            }

            // 4. 共有… / Share…
            let shareAction = UIAction(
                title: NSLocalizedString("Share…", comment: ""),
                image: UIImage(systemName: "square.and.arrow.up")
            ) { [weak self] _ in
                self?.presentShareSheet(for: url)
            }

            return UIMenu(title: url.absoluteString, children: [
                openAction,
                openNewTabAction,
                copyAction,
                shareAction
            ])
        }

        completionHandler(config)
    }

    private func presentShareSheet(for url: URL) {
        guard let windowScene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            return
        }
        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = webView
            popover.sourceRect = CGRect(x: webView.bounds.midX, y: webView.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        topVC.present(activityVC, animated: true)
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == MediaScannerScript.handlerName,
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        let isMainFrame = message.frameInfo.isMainFrame

        switch type {
        case "video":
            handleVideoMessage(body, isMainFrame: isMainFrame)
        case "removed":
            if let id = Self.validID(body["id"]) { videos[id] = nil }
        case "resource":
            handleResourceMessage(body)
        case "navigated":
            if isMainFrame {
                resetPageState()
                updateNavigation(webView)
                recordHistoryIfEligible()
                onNavigationFinished?()
            }
        default:
            break
        }
    }

    private func handleVideoMessage(_ body: [String: Any], isMainFrame: Bool) {
        guard let id = Self.validID(body["id"]) else { return }
        if videos[id] == nil && videos.count >= Self.maxVideos { return }
        let event = Self.string(body["event"], max: 40)

        var video = TrackedVideo(
            id: id,
            isMainFrame: isMainFrame,
            sourceURL: Self.string(body["src"], max: MediaClassifier.maxURLLength),
            sourceList: (body["sources"] as? [Any] ?? []).prefix(8).map { Self.string($0, max: MediaClassifier.maxURLLength) }
                .filter { !$0.isEmpty },
            posterURL: Self.httpURL(Self.string(body["poster"], max: MediaClassifier.maxURLLength)),
            title: Self.string(body["title"], max: 200),
            frameTitle: Self.string(body["frameTitle"], max: 200),
            isPlaying: Self.bool(body["playing"]),
            hasPlayed: Self.bool(body["played"]),
            hasEnded: Self.bool(body["ended"]),
            isMuted: Self.bool(body["muted"]),
            isProtected: Self.bool(body["protected"]),
            isFullscreen: Self.bool(body["fullscreen"]),
            duration: Self.number(body["duration"]) ?? -1,
            visibleRatio: min(max(Self.number(body["visible"]) ?? 0, 0), 1),
            lastPlayAt: Self.number(body["lastPlay"]) ?? 0,
            lastInteractionAt: Self.number(body["interacted"]) ?? 0,
            rectInCSS: nil,
            viewportCSSWidth: Self.number(body["vw"]) ?? 0,
            candidate: nil,
            unsupportedReason: nil)

        if Self.bool(body["hasRect"]),
           let x = Self.number(body["x"]), let y = Self.number(body["y"]),
           let w = Self.number(body["w"]), let h = Self.number(body["h"]),
           w > 0, h > 0, video.viewportCSSWidth > 0 {
            video.rectInCSS = CGRect(x: x, y: y, width: w, height: h)
        }
        let title = webView.title.flatMap { $0.isEmpty ? nil : $0 } ?? pageTitle
        video.resolveCandidate(pageTitle: title)

        let previous = videos[id]
        if previous != video { videos[id] = video }

        if event == "webkitbeginfullscreen" {
            showNotice("全画面表示中は保存ボタンを表示できません。全画面を閉じると↓ボタンから保存できます。", seconds: 6)
        }
    }

    private func handleResourceMessage(_ body: [String: Any]) {
        guard resourceCandidates.count < Self.maxResources else { return }
        let raw = Self.string(body["url"], max: MediaClassifier.maxURLLength)
        guard case .supported(let url, let kind) = MediaClassifier.classify(raw, allowUnknownExtension: false) else { return }
        let title = webView.title.flatMap { $0.isEmpty ? nil : $0 } ?? pageTitle
        let candidate = MediaCandidate(url: url, kind: kind, videoTitle: "", pageTitle: title,
                                       posterURL: nil, videoID: nil)
        if !resourceCandidates.contains(candidate) { resourceCandidates.append(candidate) }
    }

    // MARK: - 非信頼入力の検証

    private static func validID(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty, s.count <= 64,
              s.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" }) else { return nil }
        return s
    }

    private static func string(_ value: Any?, max: Int) -> String {
        guard let s = value as? String, s.count <= max else { return "" }
        return s
    }

    private static func bool(_ value: Any?) -> Bool {
        (value as? NSNumber)?.boolValue ?? false
    }

    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    private static func httpURL(_ raw: String) -> URL? {
        guard !raw.isEmpty, let url = URL(string: raw),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
}
