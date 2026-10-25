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
        case .oneDay: return NSLocalizedString("1 Day", comment: "")
        case .threeDays: return NSLocalizedString("3 Days (Default)", comment: "")
        case .sevenDays: return NSLocalizedString("7 Days", comment: "")
        case .thirtyDays: return NSLocalizedString("30 Days", comment: "")
        case .never: return NSLocalizedString("Do Not Auto-Delete", comment: "")
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

    /// ファイル一覧でのPrivate Vaultカード非表示設定 (true = 非表示, false = 表示)
    @Published var hideVaultInFileList: Bool {
        didSet {
            UserDefaults.standard.set(hideVaultInFileList, forKey: hideVaultInFileListKey)
        }
    }

    // MARK: - キー定義
    private let searchEngineKey = "clipHarbor.settings.searchEngine"
    private let trashRetentionKey = "clipHarbor.settings.trashRetentionPeriod"
    private let hideVaultInFileListKey = "clipHarbor.settings.hideVaultInFileList"
    private let legacyStealthModePrefKey = "VaultManager.isStealthModeEnabled"

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

        // Private Vault表示設定読み出し（新キー優先、未保存時のみ旧隠しモード引き継ぎ、初期値: false=カード表示）
        if let existingVal = UserDefaults.standard.object(forKey: hideVaultInFileListKey) as? Bool {
            self.hideVaultInFileList = existingVal
        } else if let legacyVal = UserDefaults.standard.object(forKey: legacyStealthModePrefKey) as? Bool {
            self.hideVaultInFileList = legacyVal
            UserDefaults.standard.set(legacyVal, forKey: hideVaultInFileListKey)
        } else {
            self.hideVaultInFileList = false
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
            HistoryManager.shared.clearAll()
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
