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
            groups.append(HistoryDateGroup(id: "today", title: NSLocalizedString("Today", comment: ""), items: todayItems))
        }
        if !yesterdayItems.isEmpty {
            groups.append(HistoryDateGroup(id: "yesterday", title: NSLocalizedString("Yesterday", comment: ""), items: yesterdayItems))
        }

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "ja_JP")
        dateFormatter.setLocalizedDateFormatFromTemplate("MMMdE")

        let yearFormatter = DateFormatter()
        yearFormatter.locale = Locale(identifier: "ja_JP")
        yearFormatter.setLocalizedDateFormatFromTemplate("yMMMd")

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
            .navigationTitle(Text("History"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: Text("Search by title or URL"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Text("Clear All")
                            .foregroundStyle(.red)
                    }
                    .disabled(historyManager.items.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .confirmationDialog(
                NSLocalizedString("Clear all browsing history?", comment: ""),
                isPresented: $showClearConfirm,
                titleVisibility: .visible
            ) {
                Button("Clear All History", role: .destructive) {
                    historyManager.clearAll()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This action cannot be undone. Cookies and saved videos will not be deleted.")
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

            Text(searchText.isEmpty ? "No History" : "No Results Found")
                .font(.headline)
                .foregroundStyle(.primary)

            Text(searchText.isEmpty ?
                 NSLocalizedString("When you browse websites, your history will appear here.\nHistory is not saved during Private Browsing.", comment: "") :
                 String(format: NSLocalizedString("No browsing history matching \"%@\" were found. Try another keyword.", comment: ""), searchText))
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
            copyNotice = NSLocalizedString("URL copied", comment: "")
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
                    Label("Open in This Tab", systemImage: "safari")
                }

                Button {
                    onSelect(url, true)
                } label: {
                    Label("Open in New Tab", systemImage: "plus.square")
                }

                Button {
                    onCopy(url)
                } label: {
                    Label("Copy URL", systemImage: "doc.on.doc")
                }

                Divider()
            }

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete from History", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}
