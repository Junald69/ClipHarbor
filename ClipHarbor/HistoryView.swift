import SwiftUI

/// 閲覧履歴一覧画面。
/// - HistoryManager.shared の訪問履歴を時系列・日付グループ表示。
/// - タイトル・URL・ホスト名でのインクリメンタル検索。
/// - 行タップで現在のアクティブタブで開く。
/// - 長押しコンテキストメニューから「このタブで開く」「新しいタブで開く」「URLをコピー」「履歴から削除」。
/// - スワイプによる個別削除、および確認ダイアログ付き全削除。
/// - ライトモード・ダークモード対応。
struct HistoryView: View {
    /// URL選択時のコールバック: (対象URL, 新規タブで開くか否か)
    var onSelectURL: ((URL, Bool) -> Void)? = nil

    @ObservedObject private var historyManager = HistoryManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var showClearConfirm = false
    @State private var copyNotice: String?

    private struct HistoryDateGroup: Identifiable {
        let id: String
        let title: String
        let items: [HistoryItem]
    }

    private var filteredItems: [HistoryItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return historyManager.items }
        return historyManager.items.filter { item in
            item.title.localizedCaseInsensitiveContains(query) ||
            item.urlString.localizedCaseInsensitiveContains(query) ||
            item.host.localizedCaseInsensitiveContains(query)
        }
    }

    private var groupedItems: [HistoryDateGroup] {
        let calendar = Calendar.current
        var todayItems: [HistoryItem] = []
        var yesterdayItems: [HistoryItem] = []
        var olderByDate: [Date: [HistoryItem]] = [:]
        var olderDates: [Date] = []

        for item in filteredItems {
            if calendar.isDateInToday(item.visitedAt) {
                todayItems.append(item)
            } else if calendar.isDateInYesterday(item.visitedAt) {
                yesterdayItems.append(item)
            } else {
                let startOfDay = calendar.startOfDay(for: item.visitedAt)
                if olderByDate[startOfDay] == nil {
                    olderDates.append(startOfDay)
                    olderByDate[startOfDay] = [item]
                } else {
                    olderByDate[startOfDay]?.append(item)
                }
            }
        }

        var groups: [HistoryDateGroup] = []
        if !todayItems.isEmpty {
            groups.append(HistoryDateGroup(id: "today", title: "今日", items: todayItems))
        }
        if !yesterdayItems.isEmpty {
            groups.append(HistoryDateGroup(id: "yesterday", title: "昨日", items: yesterdayItems))
        }

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "ja_JP")
        dateFormatter.dateFormat = "M月d日 (E)"

        let yearFormatter = DateFormatter()
        yearFormatter.locale = Locale(identifier: "ja_JP")
        yearFormatter.dateFormat = "yyyy年M月d日"

        let currentYear = calendar.component(.year, from: Date())

        for date in olderDates {
            let year = calendar.component(.year, from: date)
            let title = (year == currentYear) ? dateFormatter.string(from: date) : yearFormatter.string(from: date)
            if let items = olderByDate[date], !items.isEmpty {
                groups.append(HistoryDateGroup(id: "date-\(date.timeIntervalSince1970)", title: title, items: items))
            }
        }
        return groups
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                if filteredItems.isEmpty {
                    emptyView
                } else {
                    historyList
                }

                if let notice = copyNotice {
                    copyNoticeBanner(text: notice)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: copyNotice)
            .navigationTitle("履歴")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "タイトルまたはURLで検索")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Text("全消去")
                            .foregroundStyle(.red)
                    }
                    .disabled(historyManager.items.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完了") {
                        dismiss()
                    }
                }
            }
            .confirmationDialog(
                "すべての閲覧履歴を消去しますか？",
                isPresented: $showClearConfirm,
                titleVisibility: .visible
            ) {
                Button("すべての履歴を消去", role: .destructive) {
                    historyManager.clearAll()
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("この操作を取り消すことはできません。Cookieや保存済み動画は削除されません。")
            }
        }
    }

    private var historyList: some View {
        List {
            ForEach(groupedItems) { group in
                Section(group.title) {
                    ForEach(group.items) { item in
                        HistoryItemRow(
                            item: item,
                            onSelect: { url, openInNewTab in
                                onSelectURL?(url, openInNewTab)
                                dismiss()
                            },
                            onCopy: { url in
                                copyURL(url)
                            },
                            onDelete: {
                                historyManager.deleteItem(id: item.id)
                            }
                        )
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: searchText.isEmpty ? "clock" : "magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            Text(searchText.isEmpty ? "履歴はありません" : "検索結果が見つかりません")
                .font(.headline)
                .foregroundStyle(.primary)

            Text(searchText.isEmpty ?
                 "Webサイトを閲覧すると、ここに履歴が表示されます。\nプライベートブラウズ中の履歴は保存されません。" :
                 "「\(searchText)」に一致する閲覧履歴は見つかりませんでした。別のキーワードをお試しください。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func copyURL(_ url: URL) {
        UIPasteboard.general.string = url.absoluteString
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.easeInOut(duration: 0.2)) {
            copyNotice = "URLをコピーしました"
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(.easeInOut(duration: 0.2)) {
                copyNotice = nil
            }
        }
    }

    private func copyNoticeBanner(text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
        .zIndex(10)
    }
}

// MARK: - 履歴エントリ行

private struct HistoryItemRow: View {
    let item: HistoryItem
    let onSelect: (URL, Bool) -> Void
    let onCopy: (URL) -> Void
    let onDelete: () -> Void

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "HH:mm"
        return f
    }()

    private var validatedURL: URL? {
        guard let rawURL = item.url,
              let scheme = rawURL.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = rawURL.host, !host.isEmpty else {
            return nil
        }
        return rawURL
    }

    var body: some View {
        Button {
            if let url = validatedURL {
                onSelect(url, false)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Text(item.host.isEmpty ? item.urlString : item.host)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer()

                    Text(Self.timeFormatter.string(from: item.visitedAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 2)
        }
        .contextMenu {
            if let url = validatedURL {
                Button {
                    onSelect(url, false)
                } label: {
                    Label("このタブで開く", systemImage: "safari")
                }

                Button {
                    onSelect(url, true)
                } label: {
                    Label("新しいタブで開く", systemImage: "plus.square")
                }

                Button {
                    onCopy(url)
                } label: {
                    Label("URLをコピー", systemImage: "doc.on.doc")
                }

                Divider()
            }

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("履歴から削除", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("削除", systemImage: "trash")
            }
        }
    }
}
