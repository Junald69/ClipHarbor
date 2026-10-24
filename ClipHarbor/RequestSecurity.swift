import Foundation

/// ダウンロード要求に必要な最小限のページ情報。メモリ上でのみ保持し、永続化・ログ出力しない。
struct RequestContext {
    let cookies: [HTTPCookie]
    let userAgent: String?
    let pageURL: URL?

    /// Refererは完全なページURLではなく、オリジン（scheme://host[:port]/）のみ送る。
    /// HTTPSページからHTTPの宛先へは送らない。
    func refererValue(for target: URL) -> String? {
        guard let page = pageURL, let scheme = page.scheme?.lowercased(), let host = page.host,
              ["http", "https"].contains(scheme) else { return nil }
        if scheme == "https" && target.scheme?.lowercased() != "https" { return nil }
        var origin = "\(scheme)://\(host)"
        if let port = page.port { origin += ":\(port)" }
        return origin + "/"
    }

    /// 指定URLに送ってよいCookieヘッダー
    func cookieHeaders(for url: URL) -> [String: String] {
        let matched = CookiePolicy.cookies(cookies, matching: url)
        guard !matched.isEmpty else { return [:] }
        return HTTPCookie.requestHeaderFields(with: matched)
    }

    /// 初回リクエストを作る。Cookieは宛先URLに一致するもののみ付与する。
    func makeRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.httpShouldHandleCookies = false
        request.networkServiceType = .responsiveData
        // 既に圧縮済みの動画バイナリに対する不要なgzip再圧縮を防ぎ、Content-LengthとRange応答を維持する
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let ua = userAgent, !ua.isEmpty { request.setValue(ua, forHTTPHeaderField: "User-Agent") }
        if let referer = refererValue(for: url) { request.setValue(referer, forHTTPHeaderField: "Referer") }
        for (key, value) in cookieHeaders(for: url) { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }

    /// リダイレクト先用にリクエストを作り直す。前の宛先のCookie/Authorizationは引き継がない。
    func redirectedRequest(_ request: URLRequest, from previous: URL?) -> URLRequest? {
        guard let url = request.url, let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host != nil else { return nil }
        var r = request
        r.httpShouldHandleCookies = false
        r.setValue(nil, forHTTPHeaderField: "Cookie")
        r.setValue(nil, forHTTPHeaderField: "Authorization")
        r.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
        r.setValue(refererValue(for: url), forHTTPHeaderField: "Referer")
        for (key, value) in cookieHeaders(for: url) { r.setValue(value, forHTTPHeaderField: key) }
        return r
    }
}

/// WebViewのCookieから、宛先URLへ送るべきものだけを選ぶ（RFC 6265のドメイン/パス/Secure/期限）。
enum CookiePolicy {
    static func cookies(_ all: [HTTPCookie], matching url: URL, now: Date = Date()) -> [HTTPCookie] {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return [] }
        let isHTTPS = url.scheme?.lowercased() == "https"
        let path = url.path.isEmpty ? "/" : url.path
        let hostIsIP = host.contains(":") || host.split(separator: ".").allSatisfy { Int($0) != nil }

        return all.filter { cookie in
            if let expires = cookie.expiresDate, expires <= now { return false }
            if cookie.isSecure && !isHTTPS { return false }
            guard domainMatches(cookieDomain: cookie.domain, host: host, hostIsIP: hostIsIP) else { return false }
            return pathMatches(cookiePath: cookie.path, requestPath: path)
        }
    }

    static func domainMatches(cookieDomain: String, host: String, hostIsIP: Bool) -> Bool {
        let raw = cookieDomain.lowercased()
        if raw.hasPrefix(".") {
            let domain = String(raw.dropFirst())
            // "com" のようなドット無しドメインへのCookieは拒否（簡易的な公開サフィックス対策）
            guard !domain.isEmpty, domain.contains(".") else { return false }
            if hostIsIP { return host == domain }
            return host == domain || host.hasSuffix("." + domain)
        }
        // ホスト限定Cookieは完全一致のみ
        return host == raw
    }

    static func pathMatches(cookiePath: String, requestPath: String) -> Bool {
        let cp = cookiePath.isEmpty ? "/" : cookiePath
        if cp == "/" || requestPath == cp { return true }
        guard requestPath.hasPrefix(cp) else { return false }
        if cp.hasSuffix("/") { return true }
        let index = requestPath.index(requestPath.startIndex, offsetBy: cp.count)
        return requestPath[index] == "/"
    }
}

/// ダウンロードしたファイルの先頭バイトから、実際の形式を確認する。
enum MediaSniffer {
    enum Result: Equatable {
        case mp4, m4v, mov, webm
        case hlsPlaylist
        case textOrHTML
        case unknown

        var fileExtension: String? {
            switch self {
            case .mp4: return "mp4"
            case .m4v: return "m4v"
            case .mov: return "mov"
            case .webm: return "webm"
            default: return nil
            }
        }
    }

    static func sniff(fileAt url: URL) -> Result {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 64)) ?? Data()
        return sniff(data)
    }

    static func sniff(_ data: Data) -> Result {
        let bytes = [UInt8](data)
        guard bytes.count >= 12 else { return bytes.isEmpty ? .unknown : looksLikeText(bytes) ? .textOrHTML : .unknown }
        if bytes[0] == 0x1A && bytes[1] == 0x45 && bytes[2] == 0xDF && bytes[3] == 0xA3 { return .webm }
        let box = String(bytes: bytes[4..<8], encoding: .ascii) ?? ""
        if box == "ftyp" {
            let brand = String(bytes: bytes[8..<12], encoding: .ascii) ?? ""
            if brand == "qt  " { return .mov }
            if brand.hasPrefix("M4V") { return .m4v }
            return .mp4
        }
        if ["moov", "mdat", "wide", "free", "skip"].contains(box) { return .mov }
        if let head = String(bytes: bytes.prefix(16), encoding: .utf8), head.hasPrefix("#EXTM3U") || head.hasPrefix("\u{FEFF}#EXTM3U") {
            return .hlsPlaylist
        }
        if looksLikeText(bytes) { return .textOrHTML }
        return .unknown
    }

    private static func looksLikeText(_ bytes: [UInt8]) -> Bool {
        var start = 0
        if bytes.count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF { start = 3 }
        while start < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[start]) { start += 1 }
        guard start < bytes.count else { return false }
        return bytes[start] == UInt8(ascii: "<") || bytes[start] == UInt8(ascii: "{") || bytes[start] == UInt8(ascii: "[")
    }
}

/// 仕様書8章に沿ったエラー表示
enum DownloadErrorMessage {
    static func forHTTPStatus(_ code: Int) -> String {
        switch code {
        case 401, 403: return "配信元へのアクセス権を確認できません（HTTP \(code)）"
        case 404, 410: return "動画が見つからないか、URLの有効期限が切れました（HTTP \(code)）"
        case 416: return "配信元が要求を受け付けませんでした（HTTP 416）"
        case 429: return "配信元へのアクセスが集中しています。時間をおいて再試行してください（HTTP 429）"
        case 500...599: return "配信元のサーバーでエラーが発生しました（HTTP \(code)）"
        default: return "保存できませんでした（HTTP \(code)）"
        }
    }

    static func forError(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                return "通信が切断されました。接続を確認して再試行してください。"
            case NSURLErrorTimedOut: return "通信がタイムアウトしました。"
            case NSURLErrorCannotCreateFile, NSURLErrorCannotWriteToFile:
                return "ファイルを書き込めませんでした。空き容量を確認してください。"
            case NSURLErrorHTTPTooManyRedirects: return "リダイレクトが多すぎるため中止しました。"
            case NSURLErrorServerCertificateUntrusted, NSURLErrorSecureConnectionFailed:
                return "安全な接続を確立できませんでした。"
            default: break
            }
        }
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError {
            return "iPhoneの空き容量が不足しています"
        }
        return "保存に失敗しました（\(ns.domain) \(ns.code)）"
    }
}
