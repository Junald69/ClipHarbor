import SwiftUI
import WebKit

/// WebKitでブラウズし、Webページ内のHTMLVideoElementから再生イベントとURLを受け取ります。
/// 暗号化/DRMの解除、通信内容の強制傍受、保護されたAPIへのアクセスは行いません。
final class BrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    @Published var address = "https://example.com"
    @Published var pageTitle = "ClipHarbor"
    @Published var hasPlayingVideo = false
    @Published var candidates: [MediaCandidate] = []
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false

    lazy var webView: WKWebView = {
        let controller = WKUserContentController()
        controller.add(self, name: "clipHarborMedia")
        controller.addUserScript(WKUserScript(source: Self.mediaScannerScript,
                                             injectionTime: .atDocumentEnd,
                                             forMainFrameOnly: false))
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.allowsInlineMediaPlayback = true

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: URL(string: address)!))
        return view
    }()

    func navigate(to input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let target: URL?
        if let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            target = url
        } else if !trimmed.contains(" "), trimmed.contains(".") {
            target = URL(string: "https://" + trimmed)
        } else {
            var components = URLComponents(string: "https://www.google.com/search")
            components?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
            target = components?.url
        }
        guard let target = target else { return }
        webView.load(URLRequest(url: target))
    }

    func goBack() { if webView.canGoBack { webView.goBack() } }
    func goForward() { if webView.canGoForward { webView.goForward() } }
    func reload() { webView.reload() }

    private func updateNavigation(_ webView: WKWebView) {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        address = webView.url?.absoluteString ?? address
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        hasPlayingVideo = false
        candidates.removeAll()
        isLoading = true
        updateNavigation(webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        pageTitle = webView.title ?? "動画"
        updateNavigation(webView)
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
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "clipHarborMedia",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        if type == "playing" {
            hasPlayingVideo = true
        } else if type == "media", let raw = body["url"] as? String {
            let title = (body["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? pageTitle
            guard let candidate = MediaCandidate.from(urlString: raw, pageTitle: title) else { return }
            // 同じURLは一度だけ候補に追加。多く検出された場合は最新の20件まで。
            if !candidates.contains(where: { $0.id == candidate.id }) {
                candidates.insert(candidate, at: 0)
                if candidates.count > 20 { candidates.removeLast() }
            }
        }
    }

    /// 再生開始イベント・video/sourceタグ・リソースURLを検出する。
    /// blob:, DRM, WebSocket, MSE内部の断片などをファイルURLだと誤認しないようにする。
    private static let mediaScannerScript = #"""
    (() => {
      if (window.__clipHarborInstalled) return;
      window.__clipHarborInstalled = true;
      const send = (type, url = "") => {
        try { window.webkit.messageHandlers.clipHarborMedia.postMessage({ type, url, title: document.title }); }
        catch (_) { }
      };
      const supported = /\.(mp4|m4v|mov|webm|m3u8)(?:$|[?#])/i;
      const found = new Set();
      const report = (url) => {
        if (!url || !supported.test(url)) return;
        let absolute;
        try { absolute = new URL(url, document.baseURI).href; } catch (_) { return; }
        if (!/^https?:\/\//i.test(absolute) || found.has(absolute)) return;
        found.add(absolute);
        send("media", absolute);
      };
      const scan = () => {
        document.querySelectorAll("video").forEach(video => {
          report(video.currentSrc); report(video.src);
          video.querySelectorAll("source").forEach(source => report(source.src));
          if (!video.paused && !video.ended) send("playing");
        });
      };
      document.addEventListener("play", e => {
        if (e.target && e.target.tagName === "VIDEO") {
          send("playing");
          report(e.target.currentSrc); report(e.target.src);
        }
      }, true);
      document.addEventListener("loadedmetadata", e => {
        if (e.target && e.target.tagName === "VIDEO") {
          report(e.target.currentSrc); report(e.target.src);
        }
      }, true);
      const scanPerformance = () => {
        try { performance.getEntriesByType("resource").forEach(item => report(item.name)); }
        catch (_) { }
      };
      try {
        const observer = new MutationObserver(() => scan());
        observer.observe(document.documentElement, { childList: true, subtree: true, attributes: true,
          attributeFilter: ["src"] });
      } catch (_) { }
      try {
        new PerformanceObserver(list => list.getEntries().forEach(item => report(item.name)))
          .observe({ type: "resource", buffered: true });
      } catch (_) { }
      scan(); scanPerformance();
    })();
    """#
}
