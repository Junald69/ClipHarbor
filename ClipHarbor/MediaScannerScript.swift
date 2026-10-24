import Foundation

/// WKWebViewの隔離されたコンテンツワールド（.defaultClient）に注入する監視スクリプト。
/// - ページ自身のJavaScriptからはこのスクリプトとメッセージハンドラーにアクセスできない。
/// - DOMのvideo要素の状態・表示領域と、Performance APIで見えるメディアURLのみを扱う。
/// - DRM解除、通信の傍受、blob/MSE内部バッファの抽出は行わない。
enum MediaScannerScript {
    static let handlerName = "clipHarborMedia"

    static let source = #"""
    (() => {
      if (window.__clipHarborInstalled) return;
      window.__clipHarborInstalled = true;
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.clipHarborMedia;
      if (!handler) return;

      const isTop = (window === window.top);
      const frameToken = Math.random().toString(36).slice(2, 10);
      const MAX_URL = 4096;
      const MEDIA_EXT = /\.(mp4|m4v|mov|webm|m3u8)(?:$|[?#])/i;
      const EVENTS = ["play", "playing", "pause", "ended", "loadedmetadata", "emptied",
                      "encrypted", "webkitneedkey", "webkitbeginfullscreen", "webkitendfullscreen"];
      let counter = 0;
      const state = new WeakMap();
      const videos = new Map();

      const post = (msg) => { try { handler.postMessage(msg); } catch (_) { } };
      const text = (s, n) => (typeof s === "string" ? s.slice(0, n) : "");
      const absURL = (u) => {
        if (!u || typeof u !== "string") return "";
        try {
          const href = new URL(u, document.baseURI).href;
          return href.length > MAX_URL ? "" : href;
        } catch (_) { return ""; }
      };

      // このフレームの座標をトップレベルの visual viewport 座標へ変換する情報。
      // クロスオリジンiframeでは親にアクセスできないためnullを返す。
      const geometry = () => {
        try {
          let x = 0, y = 0, w = window;
          while (w !== w.top) {
            const fe = w.frameElement;
            if (!fe) return null;
            const r = fe.getBoundingClientRect();
            const cs = w.parent.getComputedStyle(fe);
            x += r.left + (parseFloat(cs.borderLeftWidth) || 0) + (parseFloat(cs.paddingLeft) || 0);
            y += r.top + (parseFloat(cs.borderTopWidth) || 0) + (parseFloat(cs.paddingTop) || 0);
            w = w.parent;
          }
          const vv = w.visualViewport;
          return {
            x: x - (vv ? vv.offsetLeft : 0),
            y: y - (vv ? vv.offsetTop : 0),
            width: vv ? vv.width : w.innerWidth
          };
        } catch (_) { return null; }
      };

      const ensure = (v) => {
        let s = state.get(v);
        if (!s) {
          s = { id: frameToken + "-" + (++counter), lastPlay: 0, interacted: 0,
                played: false, protected: false, fullscreen: false };
          state.set(v, s);
          videos.set(s.id, v);
          // iPhoneでもページ内（インライン）再生にして、保存ボタンを重ねられるようにする
          try {
            if (!v.hasAttribute("playsinline")) {
              v.setAttribute("playsinline", "");
              v.setAttribute("webkit-playsinline", "");
            }
          } catch (_) { }
        }
        return s;
      };

      const describe = (v, event) => {
        const s = ensure(v);
        const r = v.getBoundingClientRect();
        const g = geometry();
        const vw = window.innerWidth, vh = window.innerHeight;
        const visW = Math.max(0, Math.min(r.right, vw) - Math.max(r.left, 0));
        const visH = Math.max(0, Math.min(r.bottom, vh) - Math.max(r.top, 0));
        const area = r.width * r.height;
        const sources = [];
        try {
          v.querySelectorAll("source").forEach(x => {
            const u = absURL(x.getAttribute("src"));
            if (u && sources.length < 8) sources.push(u);
          });
        } catch (_) { }
        let src = "";
        try { src = v.currentSrc || ""; } catch (_) { }
        if (!src) src = absURL(v.getAttribute("src"));
        if (src.length > MAX_URL) src = "";
        let isProtected = s.protected;
        try { if (v.mediaKeys || v.webkitKeys) isProtected = true; } catch (_) { }
        return {
          type: "video", event: event, id: s.id,
          src: src, sources: sources,
          poster: absURL(v.getAttribute("poster")),
          title: text(v.getAttribute("title") || v.getAttribute("aria-label") || "", 200),
          frameTitle: text(document.title || "", 200),
          playing: !v.paused && !v.ended,
          played: s.played, ended: !!v.ended, muted: !!v.muted || v.volume === 0,
          protected: isProtected, fullscreen: s.fullscreen,
          duration: isFinite(v.duration) ? v.duration : -1,
          visible: area > 0 ? (visW * visH) / area : 0,
          lastPlay: s.lastPlay, interacted: s.interacted,
          hasRect: !!g,
          x: g ? r.left + g.x : 0, y: g ? r.top + g.y : 0,
          w: r.width, h: r.height, vw: g ? g.width : 0
        };
      };

      EVENTS.forEach(name => document.addEventListener(name, (e) => {
        const v = e.target;
        if (!v || v.tagName !== "VIDEO") return;
        const s = ensure(v);
        if (name === "play" || name === "playing") { s.lastPlay = Date.now(); s.played = true; }
        if (name === "encrypted" || name === "webkitneedkey") s.protected = true;
        if (name === "webkitbeginfullscreen") s.fullscreen = true;
        if (name === "webkitendfullscreen") s.fullscreen = false;
        post(describe(v, name));
      }, true));

      // ユーザーがタップした位置にある動画を「操作された動画」として記録する
      document.addEventListener("touchend", (e) => {
        const t = e.changedTouches && e.changedTouches[0];
        if (!t) return;
        videos.forEach(v => {
          if (!v.isConnected) return;
          const r = v.getBoundingClientRect();
          if (t.clientX >= r.left && t.clientX <= r.right && t.clientY >= r.top && t.clientY <= r.bottom) {
            ensure(v).interacted = Date.now();
            post(describe(v, "interaction"));
          }
        });
      }, { capture: true, passive: true });

      const removeDisconnected = () => {
        videos.forEach((v, id) => {
          if (!v.isConnected) { videos.delete(id); post({ type: "removed", id: id }); }
        });
      };

      const scan = () => {
        try {
          document.querySelectorAll("video").forEach(v => {
            if (!state.get(v)) { ensure(v); post(describe(v, "discovered")); }
          });
        } catch (_) { }
        removeDisconnected();
      };

      // 再生済み・再生中の動画の位置を、スクロール等に合わせて間引きながら送る
      let scheduled = false, lastRun = 0;
      const refresh = (reason) => {
        if (scheduled) return;
        scheduled = true;
        const wait = Math.max(0, 80 - (Date.now() - lastRun));
        setTimeout(() => requestAnimationFrame(() => {
          scheduled = false;
          lastRun = Date.now();
          removeDisconnected();
          videos.forEach(v => {
            const s = state.get(v);
            if (s && (s.played || !v.paused)) post(describe(v, reason));
          });
        }), wait);
      };
      window.addEventListener("scroll", () => refresh("scroll"), { passive: true, capture: true });
      window.addEventListener("resize", () => refresh("resize"), { passive: true });
      if (window.visualViewport) {
        window.visualViewport.addEventListener("scroll", () => refresh("viewport"), { passive: true });
        window.visualViewport.addEventListener("resize", () => refresh("viewport"), { passive: true });
      }
      setInterval(() => refresh("tick"), 1000);

      let mutationTimer = null;
      try {
        new MutationObserver((records) => {
          records.forEach(rec => {
            if (rec.type === "attributes" && rec.target) {
              const el = rec.target;
              const v = el.tagName === "VIDEO" ? el : (el.tagName === "SOURCE" ? el.closest("video") : null);
              if (v && state.get(v)) post(describe(v, "attribute"));
            }
          });
          if (mutationTimer) return;
          mutationTimer = setTimeout(() => { mutationTimer = null; scan(); }, 250);
        }).observe(document.documentElement, { childList: true, subtree: true, attributes: true,
                                               attributeFilter: ["src", "poster"] });
      } catch (_) { }

      // Performance APIから見える、拡張子でメディアと判断できるURL（候補一覧のフォールバック用）
      const reported = new Set();
      const reportResource = (u) => {
        if (!u || typeof u !== "string" || !MEDIA_EXT.test(u)) return;
        const a = absURL(u);
        if (!/^https?:\/\//i.test(a) || reported.has(a) || reported.size > 200) return;
        reported.add(a);
        post({ type: "resource", url: a, frameTitle: text(document.title || "", 200) });
      };
      try { performance.getEntriesByType("resource").forEach(e => reportResource(e.name)); } catch (_) { }
      try {
        new PerformanceObserver(list => list.getEntries().forEach(e => reportResource(e.name)))
          .observe({ type: "resource", buffered: true });
      } catch (_) { }

      // SPA（pushState）によるページ移動を検出し、古い候補を無効化する
      if (isTop) {
        let last = location.href.split("#")[0];
        setInterval(() => {
          const now = location.href.split("#")[0];
          if (now === last) return;
          last = now;
          reported.clear();
          post({ type: "navigated" });
          videos.forEach(v => { if (v.isConnected) post(describe(v, "rescan")); });
        }, 1000);
      }

      scan();
    })();
    """#
}
