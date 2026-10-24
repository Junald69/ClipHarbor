import Foundation
import SwiftUI

/// ブックマークの1エントリ。
/// - HistoryManager（閲覧履歴）とは独立した永続化コレクション。
/// - URL文字列はクレデンシャル・機密パラメータ除去済み。
struct BookmarkItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let urlString: String
    var title: String
    let createdAt: Date
    var updatedAt: Date

    var url: URL? {
        URL(string: urlString)
    }

    var host: String {
        url?.host ?? ""
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        if !host.isEmpty {
            return host
        }
        return urlString
    }
}

/// ブックマーク登録用URLの安全性ポリシー。
/// - http/https スキームのみ許可。
/// - ユーザー名・パスワード等の認証情報を完全除去。
/// - token, signature, session 等の一時的な認証・署名パラメータを平文保存しないよう除外。
/// - 検索クエリ（q）や動画ID（v, id）等の通常ページへの再訪問に必要なパラメータ・パスは完全に保持。
/// - ログイン・OAuth認証専用URLは除外。
enum BookmarkURLPolicy {
    private static let sensitiveQueryKeys: Set<String> = [
        "token", "access_token", "auth_token", "auth", "signature", "sig",
        "session", "session_id", "jsessionid", "phpsessid", "aspsessionid",
        "bearer", "api_key", "apikey", "secret", "jwt", "code"
    ]

    static func sanitize(_ url: URL) -> URL? {
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

/// 全通常ブラウザで共有されるブックマークマネージャー。
/// - 保存先: `Library/Application Support/ClipHarbor/bookmarks.json`（ファイルアプリには露出しない）
/// - メモリ上（@MainActor）で最新のブックマーク一覧を即時管理し、バックグラウンド直列キューで安全・原子的に永続化。
/// - URLの正規化により同一URLの重複登録を防止。
/// - 読み込み失敗時は破損ファイルをバックアップ退避（.corrupted）し、空データによる自動上書きを防止。
@MainActor
final class BookmarkManager: ObservableObject {
    static let shared = BookmarkManager()

    /// ブックマーク一覧（新しい順：最新の追加・更新が先頭）
    @Published private(set) var items: [BookmarkItem] = []

    /// 非同期ファイル保存用直列キュー（FIFO実行により書き込み順序を完全保証）
    private let saveQueue = DispatchQueue(label: "com.clipharbor.bookmarkmanager.save", qos: .utility)

    /// 読み込み時に破損が検知され、かつバックアップ退避に失敗した場合にデータ上書きを禁止する安全フラグ
    private(set) var isPersistenceDisabledDueToCorruption = false

    /// 保存先ディレクトリ（Library/Application Support/ClipHarbor）
    private static var storageDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("ClipHarbor", isDirectory: true)
    }

    /// 保存先JSONファイルURL
    private static var bookmarksFileURL: URL {
        storageDirectoryURL.appendingPathComponent("bookmarks.json", isDirectory: false)
    }

    /// 破損検知時のバックアップ退避先URL
    private static var corruptedBackupFileURL: URL {
        storageDirectoryURL.appendingPathComponent("bookmarks.json.corrupted", isDirectory: false)
    }

    init() {
        loadFromDisk()

        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.saveImmediately()
        }
    }

    // MARK: - ブックマーク判定・取得API

    /// 指定URLがブックマーク登録済みか判定（正規化URLで比較）
    func isBookmarked(url: URL) -> Bool {
        guard let clean = BookmarkURLPolicy.sanitize(url) else { return false }
        return items.contains { $0.urlString == clean.absoluteString }
    }

    /// 指定URLに該当する登録済みBookmarkItemを取得
    func bookmark(for url: URL) -> BookmarkItem? {
        guard let clean = BookmarkURLPolicy.sanitize(url) else { return nil }
        return items.first { $0.urlString == clean.absoluteString }
    }

    // MARK: - ブックマーク操作API

    /// ブックマークを追加する。
    /// - 未登録なら先頭に追加して保存。
    /// - 既に登録済みなら既存エントリを維持（勝手に削除しない）。
    @discardableResult
    func addBookmark(url: URL, title: String?) -> BookmarkItem? {
        guard let clean = BookmarkURLPolicy.sanitize(url) else { return nil }
        let cleanURLString = clean.absoluteString

        // 重複登録防止：既に登録済みなら既存エントリを維持
        if let existing = items.first(where: { $0.urlString == cleanURLString }) {
            return existing
        }

        let resolvedTitle: String
        if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            resolvedTitle = t
        } else if let host = clean.host, !host.isEmpty {
            resolvedTitle = host
        } else {
            resolvedTitle = cleanURLString
        }

        let now = Date()
        let newItem = BookmarkItem(
            id: UUID(),
            urlString: cleanURLString,
            title: resolvedTitle,
            createdAt: now,
            updatedAt: now
        )

        items.insert(newItem, at: 0)
        scheduleSave()
        return newItem
    }

    /// 指定IDのブックマークを明示的に削除
    func removeBookmark(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: index)
        scheduleSave()
    }

    /// 指定URLのブックマークを明示的に削除
    func removeBookmark(for url: URL) {
        guard let clean = BookmarkURLPolicy.sanitize(url) else { return }
        guard let index = items.firstIndex(where: { $0.urlString == clean.absoluteString }) else { return }
        items.remove(at: index)
        scheduleSave()
    }

    /// 登録・解除のトグル操作（UIのワンタップ登録/解除専用）
    /// - 登録済みなら削除して false を返す
    /// - 未登録なら追加して true を返す
    @discardableResult
    func toggleBookmark(url: URL, title: String?) -> Bool {
        guard let clean = BookmarkURLPolicy.sanitize(url) else { return false }
        if let index = items.firstIndex(where: { $0.urlString == clean.absoluteString }) {
            items.remove(at: index)
            scheduleSave()
            return false
        } else {
            addBookmark(url: url, title: title)
            return true
        }
    }

    /// 既存のIDを維持したままブックマークのタイトルを変更
    func updateTitle(id: UUID, newTitle: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        items[index].title = trimmed
        items[index].updatedAt = Date()
        scheduleSave()
    }

    // MARK: - 永続化（直列非同期・原子的保存）

    private func scheduleSave() {
        guard !isPersistenceDisabledDueToCorruption else { return }
        let snapshot = items
        let dirURL = Self.storageDirectoryURL
        let fileURL = Self.bookmarksFileURL

        saveQueue.async {
            Self.writeRecord(snapshot, dirURL: dirURL, fileURL: fileURL)
        }
    }

    /// アプリバックグラウンド移行時の即時保存
    func saveImmediately() {
        guard !isPersistenceDisabledDueToCorruption else { return }
        let snapshot = items
        let dirURL = Self.storageDirectoryURL
        let fileURL = Self.bookmarksFileURL

        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "com.clipharbor.bookmarkmanager.save") {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }

        saveQueue.async {
            Self.writeRecord(snapshot, dirURL: dirURL, fileURL: fileURL)
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
        }
    }

    private static func writeRecord(_ record: [BookmarkItem], dirURL: URL, fileURL: URL) {
        do {
            if !FileManager.default.fileExists(atPath: dirURL.path) {
                try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .sortedKeys
            let data = try encoder.encode(record)
            // .atomic により書き込み途中の破損を防止
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // ログ出力・クラッシュを回避
        }
    }

    private func loadFromDisk() {
        let fileURL = Self.bookmarksFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            self.items = []
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let loaded = try decoder.decode([BookmarkItem].self, from: data)
            self.items = loaded
            self.isPersistenceDisabledDueToCorruption = false
        } catch {
            // JSON読み込み失敗時のデータ保護：
            // 既存ファイルを安易に削除・上書きせず、タイムスタンプ付きの独立したバックアップファイルへ保護退避
            let formatter = ISO8601DateFormatter()
            let timeString = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backupFileName = "bookmarks.json.corrupted.\(timeString)"
            let backupURL = Self.storageDirectoryURL.appendingPathComponent(backupFileName, isDirectory: false)

            var backupSucceeded = false
            do {
                try FileManager.default.copyItem(at: fileURL, to: backupURL)
                backupSucceeded = true
            } catch {
                backupSucceeded = false
            }

            // バックアップに失敗した場合は、既存データの喪失を防ぐため以後のディスク保存を完全禁止
            if !backupSucceeded {
                self.isPersistenceDisabledDueToCorruption = true
            } else {
                self.isPersistenceDisabledDueToCorruption = false
            }

            // メモリ上は空リストで初期化（ディスクの即座上書きは行わない）
            self.items = []
        }
    }
}
