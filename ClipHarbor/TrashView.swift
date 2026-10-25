import SwiftUI

/// アプリ内ゴミ箱画面
/// - 削除された動画の一覧、サイズ、完全削除までの残り時間を表示
/// - 個別の復元、個別の完全削除、ゴミ箱を空にする操作を提供
/// - 誤操作防止の確認ダイアログを完備
/// - 非同期実行と二重タップ防止、UI処理中インジケータ対応
struct TrashView: View {
    @ObservedObject var trashManager = TrashManager.shared
    @ObservedObject var downloads: DownloadCenter
    @ObservedObject var folderManager: VideoFolderManager
    @Environment(\.dismiss) private var dismiss

    @State private var deletingItem: TrashItem?
    @State private var showEmptyTrashAlert = false
    @State private var noticeMessage: String?
    @State private var errorMessage: String?
    @State private var isOperating = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                if trashManager.items.isEmpty {
                    emptyTrashPlaceholder
                } else {
                    List {
                        Section {
                            infoBanner
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                        }

                        Section {
                            ForEach(trashManager.items) { item in
                                TrashItemRow(
                                    item: item,
                                    isItemProcessing: trashManager.processingItemIDs.contains(item.id) || isOperating,
                                    onRestore: {
                                        restoreItem(item)
                                    },
                                    onDeletePermanently: {
                                        deletingItem = item
                                    }
                                )
                            }
                        } header: {
                            Text("保管中の動画 (\(trashManager.items.count)件)")
                        }
                    }
                    .listStyle(.insetGrouped)
                }

                if let notice = noticeMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(notice)
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
            .animation(.easeInOut(duration: 0.25), value: noticeMessage)
            .navigationTitle("ゴミ箱")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("閉じる") {
                        dismiss()
                    }
                    .disabled(isOperating)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        showEmptyTrashAlert = true
                    } label: {
                        Text("空にする")
                            .foregroundStyle(trashManager.items.isEmpty || isOperating ? Color.secondary : Color.red)
                    }
                    .disabled(trashManager.items.isEmpty || isOperating)
                }
            }
            .onAppear {
                trashManager.purgeExpiredItems()
            }
            .alert(
                "項目を完全に削除",
                isPresented: Binding(
                    get: { deletingItem != nil },
                    set: { if !$0 { deletingItem = nil } }
                )
            ) {
                Button("キャンセル", role: .cancel) { deletingItem = nil }
                Button("完全に削除", role: .destructive) {
                    if let target = deletingItem {
                        performPermanentDelete(target)
                    }
                    deletingItem = nil
                }
            } message: {
                if let target = deletingItem {
                    Text("「\(target.originalTitle)」を端末から完全に削除しますか？\nこの操作は取り消せません。")
                }
            }
            .alert("ゴミ箱を空にする", isPresented: $showEmptyTrashAlert) {
                Button("キャンセル", role: .cancel) { }
                Button("すべて完全に削除", role: .destructive) {
                    performEmptyTrash()
                }
            } message: {
                Text("ゴミ箱内のすべてのファイル（\(trashManager.items.count)件）を端末から完全に削除しますか？\nこの操作は取り消せません。")
            }
            .alert("エラー", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: - インフォバナー

    private var infoBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.blue)
                .font(.subheadline)
                .padding(.top, 1)

            Text("削除から3日経過後、次回のアプリ起動時などに完全削除されます")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    // MARK: - プレースホルダー

    private var emptyTrashPlaceholder: some View {
        VStack(spacing: 14) {
            Image(systemName: "trash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("ゴミ箱は空です")
                .font(.headline)
            Text("削除した動画はここに3日間保管されます。\n削除から3日経過後、次回のアプリ起動時などに完全削除されます。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 非同期操作

    private func restoreItem(_ item: TrashItem) {
        guard !isOperating else { return }
        isOperating = true
        Task {
            let result = await trashManager.restore(item: item, downloads: downloads, folderManager: folderManager)
            await MainActor.run {
                isOperating = false
                switch result {
                case .success(let video):
                    showToast("「\(video.title)」を復元しました")
                case .failure(let err):
                    errorMessage = "復元に失敗しました: \(err.localizedDescription)"
                }
            }
        }
    }

    private func performPermanentDelete(_ item: TrashItem) {
        guard !isOperating else { return }
        isOperating = true
        Task {
            let result = await trashManager.deletePermanently(item: item)
            await MainActor.run {
                isOperating = false
                switch result {
                case .success:
                    showToast("項目を完全に削除しました")
                case .failure(let err):
                    errorMessage = "削除に失敗しました: \(err.localizedDescription)"
                }
            }
        }
    }

    private func performEmptyTrash() {
        guard !isOperating else { return }
        isOperating = true
        Task {
            let result = await trashManager.emptyTrash()
            await MainActor.run {
                isOperating = false
                switch result {
                case .success:
                    showToast("ゴミ箱を空にしました")
                case .failure(let err):
                    errorMessage = "ゴミ箱のクリアに失敗しました: \(err.localizedDescription)"
                }
            }
        }
    }

    private func showToast(_ msg: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            noticeMessage = msg
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(.easeInOut(duration: 0.2)) {
                noticeMessage = nil
            }
        }
    }
}

// MARK: - ゴミ箱アイテム行

private struct TrashItemRow: View {
    let item: TrashItem
    var isItemProcessing: Bool = false
    let onRestore: () -> Void
    let onDeletePermanently: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                // アイコン
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                        .frame(width: 44, height: 44)
                    Image(systemName: item.format == .hls ? "film.stack" : "play.rectangle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }

                // タイトルと詳細
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.originalTitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    HStack(spacing: 4) {
                        Text(item.format.label)
                            .font(.caption2.weight(.semibold))

                        if let size = item.byteSize, size > 0 {
                            Text("· \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
                        }

                        if !item.originalFolderName.isEmpty {
                            Text("· フォルダ: \(item.originalFolderName)")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                Spacer()
            }

            // 残り時間バッジとアクションボタン
            HStack(spacing: 10) {
                // 残り時間バッジ
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.caption2)
                    Text(item.remainingTimeDescription)
                        .font(.caption2.weight(.medium))
                }
                .foregroundStyle(item.isExpired ? Color.red : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    (item.isExpired ? Color.red.opacity(0.12) : Color(.secondarySystemBackground)),
                    in: Capsule()
                )

                Spacer()

                if isItemProcessing {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(height: 26)
                } else {
                    // 復元ボタン
                    Button(action: onRestore) {
                        Label("復元", systemImage: "arrow.uturn.backward")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)

                    // 完全削除ボタン
                    Button(action: onDeletePermanently) {
                        Image(systemName: "trash")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                            .padding(6)
                            .background(Color.red.opacity(0.1), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }
}
