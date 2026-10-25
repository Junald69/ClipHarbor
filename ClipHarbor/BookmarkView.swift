import SwiftUI

/// ブックマーク一覧画面。
/// - BookmarkManager.shared のデータを登録順（新しい順）で表示。
/// - タイトル・URL・ホスト名によるインクリメンタル検索。
/// - 行タップで現在のアクティブタブで開く。
/// - 長押しコンテキストメニューから「このタブで開く」「新しいタブで開く」「URLをコピー」「名前を変更」「ブックマークを削除」。
/// - スワイプによる個別削除。
/// - タイトルのインプレース名前変更（空文字・長大文字列ガード付き）。
/// - ライトモード・ダークモード対応、Safe Area準拠。
struct BookmarkView: View {
    /// URL選択時のコールバック: (対象URL, 新規タブで開くか否か)
    var onSelectURL: ((URL, Bool) -> Void)? = nil

    @ObservedObject private var bookmarkManager = BookmarkManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var renamingItem: BookmarkItem?
    @State private var renameTitleInput = ""
    @State private var copyNotice: String?

    private var filteredItems: [BookmarkItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return bookmarkManager.items }
        return bookmarkManager.items.filter { item in
            item.title.localizedCaseInsensitiveContains(query) ||
            item.urlString.localizedCaseInsensitiveContains(query) ||
            item.host.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                if filteredItems.isEmpty {
                    emptyView
                } else {
                    bookmarkList
                }

                if let notice = copyNotice {
                    copyNoticeBanner(text: notice)
                }

                if !bookmarkManager.canSave {
                    corruptionWarningBanner
                }
            }
            .animation(.easeInOut(duration: 0.2), value: copyNotice)
            .navigationTitle(Text("Bookmarks"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: Text("Search by title or URL"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .alert(
                NSLocalizedString("Rename Bookmark", comment: ""),
                isPresented: Binding(
                    get: { renamingItem != nil },
                    set: { if !$0 { renamingItem = nil } }
                )
            ) {
                TextField("Title", text: $renameTitleInput)
                Button("Cancel", role: .cancel) {
                    renamingItem = nil
                }
                Button("Save") {
                    handleRenameConfirm()
                }
            } message: {
                Text("Please enter a new name for the bookmark.")
            }
        }
    }

    private var bookmarkList: some View {
        List {
            ForEach(filteredItems) { item in
                BookmarkItemRow(
                    item: item,
                    onSelect: { url, openInNewTab in
                        onSelectURL?(url, openInNewTab)
                        dismiss()
                    },
                    onCopy: { url in
                        copyURL(url)
                    },
                    onRename: {
                        renameTitleInput = item.title
                        renamingItem = item
                    },
                    onDelete: {
                        bookmarkManager.removeBookmark(id: item.id)
                    }
                )
            }
            .onDelete { indexSet in
                for index in indexSet {
                    if index < filteredItems.count {
                        bookmarkManager.removeBookmark(id: filteredItems[index].id)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: searchText.isEmpty ? "bookmark" : "magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            Text(searchText.isEmpty ? "No Bookmarks" : "No Results Found")
                .font(.headline)
                .foregroundStyle(.primary)

            Text(searchText.isEmpty ?
                 NSLocalizedString("When you bookmark frequently visited web pages from the menu, they will appear here.", comment: "") :
                 String(format: NSLocalizedString("No bookmarks matching \"%@\" were found. Try another keyword.", comment: ""), searchText))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func handleRenameConfirm() {
        guard let item = renamingItem else { return }
        let trimmed = renameTitleInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let safeTitle = String(trimmed.prefix(200))
            bookmarkManager.updateTitle(id: item.id, newTitle: safeTitle)
        }
        renamingItem = nil
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

    private var corruptionWarningBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("Disk persistence is disabled to protect against file corruption.")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.top, 8)
        .zIndex(9)
    }
}

// MARK: - ブックマークエントリ行

private struct BookmarkItemRow: View {
    let item: BookmarkItem
    let onSelect: (URL, Bool) -> Void
    let onCopy: (URL) -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy/M/d"
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

                    Text(Self.dateFormatter.string(from: item.createdAt))
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

            Button {
                onRename()
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Divider()

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete Bookmark", systemImage: "trash")
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
