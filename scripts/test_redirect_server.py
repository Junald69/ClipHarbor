import http.server
import socketserver
import urllib.parse
import sys
import datetime

PORT = 8080
LOG_FILE = "test_access.log"

def log_request(msg):
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    entry = f"[{now}] {msg}\n"
    print(entry, end="")
    with open(LOG_FILE, "a", encoding="utf-8") as f:
        f.write(entry)

class RedirectTestHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        host_header = self.headers.get('Host', '')
        log_request(f"Incoming GET: host={host_header}, path={self.path}")

        parsed = urllib.parse.urlparse(self.path)

        # 1. サイトA（例外ホスト想定）からサイトB（非例外ホスト想定）への絶対URLによる302リダイレクト
        if parsed.path == "/redirect-to-b":
            target_host = "localhost" if "127.0.0.1" in host_header else "127.0.0.1"
            target_url = f"http://{target_host}:{PORT}/destination-page"
            log_request(f"Responding 302 Found -> {target_url}")
            self.send_response(302)
            self.send_header("Location", target_url)
            self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
            self.end_headers()
            return

        # 2. 遷移先ページ（広告リソースと通常リソースを含む）
        if parsed.path == "/destination-page":
            html = f"""<!DOCTYPE html>
<html>
<head><title>Destination Page ({host_header})</title></head>
<body>
    <h1>Destination Page on {host_header}</h1>
    <p>Loading test resources...</p>
    <script src="/normal-resource.js"></script>
    <script src="/blocked-tracker.js"></script>
</body>
</html>"""
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            self.wfile.write(html.encode("utf-8"))
            return

        # 3. 通常リソース（許可対象）
        if parsed.path == "/normal-resource.js":
            log_request(f"Serving normal-resource.js to {host_header}")
            self.send_response(200)
            self.send_header("Content-Type", "application/javascript")
            self.end_headers()
            self.wfile.write(b"console.log('normal-resource loaded successfully');")
            return

        # 4. ブロック対象模擬トラッカー（ブロック時はWebKitによりアクセスが遮断される）
        if parsed.path == "/blocked-tracker.js":
            log_request(f"ALERT: /blocked-tracker.js was REQUESTED by {host_header} (Not blocked if this appears!)")
            self.send_response(200)
            self.send_header("Content-Type", "application/javascript")
            self.end_headers()
            self.wfile.write(b"console.log('blocked-tracker loaded');")
            return

        # 5. ポップアップテストページ
        if parsed.path == "/popup-test":
            html = """<!DOCTYPE html>
<html>
<head><title>Popup Test</title></head>
<body>
    <h1>Popup Test</h1>
    <button id="manual-btn" onclick="openPopup()">User Click Popup</button>
    <script>
        function openPopup() {
            window.open('/popup-target', '_blank', 'width=400,height=500');
        }
        // スクリプト自動ポップアップ
        window.addEventListener('load', function() {
            setTimeout(function() {
                window.open('/popup-target', '_blank');
            }, 1000);
        });
    </script>
</body>
</html>"""
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(html.encode("utf-8"))
            return

        if parsed.path == "/popup-target":
            html = """<!DOCTYPE html>
<html>
<head><title>Popup Target</title></head>
<body>
    <h1>Popup Target Opened</h1>
    <button onclick="window.close()">Close this popup (window.close)</button>
</body>
</html>"""
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(html.encode("utf-8"))
            return

        self.send_response(404)
        self.end_headers()

if __name__ == "__main__":
    with open(LOG_FILE, "w", encoding="utf-8") as f:
        f.write(f"=== Test Redirect Server Started on port {PORT} ===\n")
    print(f"Starting test server on http://127.0.0.1:{PORT} and http://localhost:{PORT}")
    server = socketserver.TCPServer(("", PORT), RedirectTestHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping server.")
