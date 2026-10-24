import Foundation
import Combine

/// 閲覧履歴の1エントリ。
/// - 将来のブックマーク機能とは別のデータ構造として管理する。
/// - URL文字列はクレデンシャル・機密パラメータ除去済み。
struct HistoryItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let urlString: String
    var title: String
    var visitedAt: Date

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

/// 全通常タブで共有される閲覧履歴マネージャー。
/// - 保存先: `Library/Application Support/ClipHarbor/history.json`（ファイルアプリには露出しない）
/// - メモリ上（@MainActor）で最新の履歴を即時管理し、バックグラウンド直列キューで安全・原子的に永続化。
/// - 最大件数: 1,000件（超過分は古い順に自動トリミング）。
/// - 同一URLの連続記録は新規追加せず、日時・タイトルの更新に留める（リロード・SPAの連続検知による重複防止）。
@MainActor
final class HistoryManager: ObservableObject {
    static let shared = HistoryManager()

    /// 履歴の最大保持件数
    static let maxHistoryCount = 1000

    /// 新しい順に並んだ履歴一覧
    @Published private(set) var items: [HistoryItem] = []

    /// 非同期ファイル保存用直列キュー（FIFO実行により書き込み順序を完全保証）
    private let saveQueue = DispatchQueue(label: "com.clipharbor.history.save", qos: .utility)

    /// 保存先ディレクトリ（Library/Application Support/ClipHarbor）
    private static var storageDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("ClipHarbor", isDirectory: true)
    }

    /// 保存先JSONファイルURL
    private static var historyFileURL: URL {
        storageDirectoryURL.appendingPathComponent("history.json", isDirectory: false)
    }

    init() {
        loadFromDisk()
    }

    // MARK: - 記録API

    /// ページ訪問を記録する。
    /// - http/https スキームのみ対象
    /// - SourceURLPolicy でサニタイズされた安全な URL のみ記録
    /// - 直前の履歴と同一 URL の場合は新規追加せず、最終訪問日時とタイトルを更新
    func recordVisit(url: URL, title: String?) {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else {
            return
        }

        guard let sanitizedURLString = SourceURLPolicy.sanitize(url) else {
            return
        }

        let resolvedTitle: String
        if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            resolvedTitle = t
        } else {
            resolvedTitle = host
        }

        // 直前（最新）の履歴と同一URLの場合：連続記録による重複を防止し、日時・タイトルを更新
        if let first = items.first, first.urlString == sanitizedURLString {
            items[0].visitedAt = Date()
            if resolvedTitle != host || items[0].title.isEmpty {
                items[0].title = resolvedTitle
            }
            scheduleSave()
            return
        }

        // 新規訪問として先頭に追加
        let newItem = HistoryItem(
            id: UUID(),
            urlString: sanitizedURLString,
            title: resolvedTitle,
            visitedAt: Date()
        )
        items.insert(newItem, at: 0)

        // 最大1,000件にトリミング
        if items.count > Self.maxHistoryCount {
            items.removeLast(items.count - Self.maxHistoryCount)
        }

        scheduleSave()
    }

    // MARK: - 削除API

    /// 指定IDの履歴を個別削除
    func deleteItem(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: index)
        scheduleSave()
    }

    /// 全履歴を削除
    func clearAll() {
        guard !items.isEmpty else { return }
        items.removeAll()
        scheduleSave()
    }

    // MARK: - 永続化（非同期・直列化・原子的）

    private func scheduleSave() {
        let snapshot = items
        let dirURL = Self.storageDirectoryURL
        let fileURL = Self.historyFileURL

        saveQueue.async {
            do {
                if !FileManager.default.fileExists(atPath: dirURL.path) {
                    try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
                }
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(snapshot)
                // .atomic により書き込み途中の破損を防止
                try data.write(to: fileURL, options: .atomic)
            } catch {
                // ログ出力・クラッシュを回避し安全に処理
            }
        }
    }

    private func loadFromDisk() {
        let fileURL = Self.historyFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            self.items = []
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let loaded = try decoder.decode([HistoryItem].self, from: data)
            self.items = Array(loaded.prefix(Self.maxHistoryCount))
        } catch {
            // 読み込み失敗時は既存ファイルを空JSONで上書きしない（データ保護）
            self.items = []
        }
    }
}
