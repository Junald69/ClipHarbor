import Foundation
import WebKit

/// 既定の検索エンジン列挙型
enum SearchEngine: String, CaseIterable, Identifiable, Codable {
    case google = "google"
    case duckDuckGo = "duckduckgo"
    case bing = "bing"
    case yahooJapan = "yahoojapan"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .google: return "Google"
        case .duckDuckGo: return "DuckDuckGo"
        case .bing: return "Bing"
        case .yahooJapan: return "Yahoo! JAPAN"
        }
    }

    var homeURL: URL {
        switch self {
        case .google:
            return URL(string: "https://www.google.com/")!
        case .duckDuckGo:
            return URL(string: "https://duckduckgo.com/")!
        case .bing:
            return URL(string: "https://www.bing.com/")!
        case .yahooJapan:
            return URL(string: "https://www.yahoo.co.jp/")!
        }
    }

    func searchURL(for query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        switch self {
        case .google:
            var comp = URLComponents(string: "https://www.google.com/search")
            comp?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
            return comp?.url
        case .duckDuckGo:
            var comp = URLComponents(string: "https://duckduckgo.com/")
            comp?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
            return comp?.url
        case .bing:
            var comp = URLComponents(string: "https://www.bing.com/search")
            comp?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
            return comp?.url
        case .yahooJapan:
            var comp = URLComponents(string: "https://search.yahoo.co.jp/search")
            comp?.queryItems = [URLQueryItem(name: "p", value: trimmed)]
            return comp?.url
        }
    }
}

/// ゴミ箱保持期間の選択肢
enum TrashRetentionPeriod: Int, CaseIterable, Identifiable, Codable {
    case oneDay = 1
    case threeDays = 3
    case sevenDays = 7
    case thirtyDays = 30
    case never = 0

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .oneDay: return "1日"
        case .threeDays: return "3日（初期値）"
        case .sevenDays: return "7日"
        case .thirtyDays: return "30日"
        case .never: return "自動削除しない"
        }
    }

    var summaryText: String {
        switch self {
        case .oneDay: return "削除から1日後に完全削除"
        case .threeDays: return "削除から3日後に完全削除"
        case .sevenDays: return "削除から7日後に完全削除"
        case .thirtyDays: return "削除から30日後に完全削除"
        case .never: return "手動で削除するまで永続保持"
        }
    }

    /// 秒数換算（nilは自動削除なし）
    var timeInterval: TimeInterval? {
        switch self {
        case .oneDay: return 86_400
        case .threeDays: return 3 * 86_400
        case .sevenDays: return 7 * 86_400
        case .thirtyDays: return 30 * 86_400
        case .never: return nil
        }
    }
}

/// アプリ全体の設定マネージャー
/// - メイン設定とファイル管理設定で同一の設定値を一元管理・永続化
/// - 暗号鍵や機密情報は一切含まない安全な設定層
@MainActor
final class AppSettingsManager: ObservableObject {
    static let shared = AppSettingsManager()

    // MARK: - Publishedプロパティ
    @Published var searchEngine: SearchEngine {
        didSet {
            UserDefaults.standard.set(searchEngine.rawValue, forKey: searchEngineKey)
        }
    }

    @Published var trashRetentionPeriod: TrashRetentionPeriod {
        didSet {
            UserDefaults.standard.set(trashRetentionPeriod.rawValue, forKey: trashRetentionKey)
        }
    }

    // MARK: - キー定義
    private let searchEngineKey = "clipHarbor.settings.searchEngine"
    private let trashRetentionKey = "clipHarbor.settings.trashRetentionPeriod"

    private init() {
        // 検索エンジン読み出し (デフォルト: Google)
        if let raw = UserDefaults.standard.string(forKey: searchEngineKey),
           let engine = SearchEngine(rawValue: raw) {
            self.searchEngine = engine
        } else {
            self.searchEngine = .google
        }

        // ゴミ箱保持期間読み出し (デフォルト: 3日)
        let rawRetention = UserDefaults.standard.object(forKey: trashRetentionKey) as? Int
        if let rawInt = rawRetention, let period = TrashRetentionPeriod(rawValue: rawInt) {
            self.trashRetentionPeriod = period
        } else {
            self.trashRetentionPeriod = .threeDays
        }
    }

    // MARK: - 閲覧データ削除

    /// 閲覧データの選択的削除
    /// - パラメータ:
    ///   - clearHistory: 閲覧履歴の全消去
    ///   - clearCookies: WebKit Cookieおよびサイトストレージ（IndexedDB, LocalStorage）の消去
    ///   - clearCache: WebKit ディスクキャッシュ・メモリキャッシュの消去
    /// - 注意: ブックマーク、保存済み動画、Private Vaultのデータには一切影響しません。
    func clearBrowsingData(clearHistory: Bool, clearCookies: Bool, clearCache: Bool) async throws {
        if clearHistory {
            HistoryManager.shared.clearAllHistory()
        }

        var dataTypes = Set<String>()
        if clearCookies {
            dataTypes.insert(WKWebsiteDataTypeCookies)
            dataTypes.insert(WKWebsiteDataTypeLocalStorage)
            dataTypes.insert(WKWebsiteDataTypeIndexedDBDatabases)
            dataTypes.insert(WKWebsiteDataTypeWebSQLDatabases)
            dataTypes.insert(WKWebsiteDataTypeServiceWorkerRegistrations)
        }
        if clearCache {
            dataTypes.insert(WKWebsiteDataTypeDiskCache)
            dataTypes.insert(WKWebsiteDataTypeMemoryCache)
        }

        if !dataTypes.isEmpty {
            let dataStore = WKWebsiteDataStore.default()
            await dataStore.removeData(ofTypes: dataTypes, modifiedSince: .distantPast)
        }
    }
}
