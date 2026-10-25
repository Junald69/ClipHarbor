import SwiftUI

/// アプリ内ゴミ箱画面（Aloha風の2列カードグリッドUI）
/// - 通常ファイル一覧と完全統一された2列グリッド（サムネイル高140pt・角丸16pt・上端厳格整列）
/// - Dynamic Type対応の2行タイトル領域予約＋形式・容量行＋残り保持時間バッジ
/// - ゴミ箱内非公開領域に永続化されたサムネイル画像の非同期読み込み・表示
/// - 各カード右上の「…」メニューから「復元」「完全に削除」を個別実行
/// - ツールバーの「閉じる」「空にする」と誤操作防止の確認ダイアログ
/// - 説明バナーの余白を最適化し、一覧の表示領域を最大化
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

    /// 左右のサムネイル上端を厳格に揃えるため alignment: .top を明示指定
    private let gridColumns = [
        GridItem(.flexible(), spacing: 14, alignment: .top),
        GridItem(.flexible(), spacing: 14, alignment: .top)
    ]

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                if trashManager.items.isEmpty {
                    emptyTrashPlaceholder
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            // コンパクトな説明バナー（余分な空白を排除し一覧領域を拡大）
                            compactInfoBanner

                            // 2列カードグリッド（通常一覧と完全に同一の整列仕様）
                            LazyVGrid(columns: gridColumns, spacing: 18) {
                                ForEach(trashManager.items) { item in
                                    AlohaTrashCardView(
                                        item: item,
                                        isProcessing: trashManager.processingItemIDs.contains(item.id) || isOperating,
                                        onRestore: {
                                            restoreItem(item)
                                        },
                                        onDeletePermanently: {
                                            deletingItem = item
                                        }
                                    )
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 4)
                            .padding(.bottom, 24)
                        }
                    }
                }

                // 操作通知トースト
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

    // MARK: - コンパクトなインフォバナー

    private var compactInfoBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.caption)
                .foregroundStyle(.blue)

            Text("設定された保持期間（現在: \(AppSettingsManager.shared.trashRetentionPeriod.title)）が経過した動画は次回起動時などに自動削除されます")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    // MARK: - プレースホルダー（ゴミ箱が空の場合）

    private var emptyTrashPlaceholder: some View {
        VStack(spacing: 14) {
            Image(systemName: "trash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("ゴミ箱は空です")
                .font(.headline)
            Text("削除した動画はここに保管されます。\n設定された保持期間が経過すると自動削除されます（設定から変更可能）。")
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

// MARK: - Aloha風ゴミ箱動画カード（通常一覧と厳密に揃えた2列グリッドカード）

private struct AlohaTrashCardView: View {
    let item: TrashItem
    let isProcessing: Bool
    let onRestore: () -> Void
    let onDeletePermanently: () -> Void

    @ObservedObject private var trashManager = TrashManager.shared

    @ScaledMetric(relativeTo: .subheadline) private var titleLineHeight: CGFloat = 20
    @ScaledMetric(relativeTo: .caption2) private var subtitleHeight: CGFloat = 16
    @ScaledMetric(relativeTo: .caption2) private var expiryHeight: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // サムネイル領域（高さ140pt・角丸16pt固定、中央トリミング）
            ZStack(alignment: .topTrailing) {
                TrashClippedThumbnailTileView(item: item)
                    .frame(height: 140)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                // 右上: 「…」メニューボタン（個別ファイル操作用: 復元・完全削除）
                Menu {
                    Button(action: onRestore) {
                        Label("復元", systemImage: "arrow.uturn.backward")
                    }

                    Divider()

                    Button(role: .destructive, action: onDeletePermanently) {
                        Label("完全に削除", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.92), in: Circle())
                        .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
                        .padding(8)
                }
                .buttonStyle(.plain)
                .disabled(isProcessing)

                // 処理中スピナー表示
                if isProcessing {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.black.opacity(0.35))
                        ProgressView()
                            .tint(.white)
                    }
                }
            }
            .frame(height: 140)

            // テキスト情報領域（Dynamic Type対応で高さを厳格予約し左右の上端を完全一致）
            VStack(alignment: .leading, spacing: 2) {
                // ファイル名（最大2行表示、1行の場合も2行分を確保）
                Text(item.originalTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(height: titleLineHeight * 2, alignment: .topLeading)

                // 形式・容量（1行固定）
                HStack(spacing: 4) {
                    Text(item.format.label)
                        .font(.caption2.weight(.semibold))

                    if let size = item.byteSize, size > 0 {
                        Text("· \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
                            .font(.caption2)
                    }
                }
                .foregroundStyle(.secondary)
                .frame(height: subtitleHeight, alignment: .leading)

                // ゴミ箱特有情報: 完全削除までの残り時間
                HStack(spacing: 3) {
                    Image(systemName: "clock")
                        .font(.system(size: 9))
                    Text(item.remainingTimeDescription)
                        .font(.caption2.weight(.medium))
                }
                .foregroundStyle(item.isExpired ? Color.red : Color.secondary)
                .frame(height: expiryHeight, alignment: .leading)
            }
            .padding(.horizontal, 4)
        }
    }
}

// MARK: - ゴミ箱専用サムネイルタイル（非公開領域から読み込み・枠内中央トリミング）

private struct TrashClippedThumbnailTileView: View {
    let item: TrashItem
    @State private var thumbnail: UIImage?
    @State private var hasAttemptedLoad = false

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let h = max(1, geo.size.height)

            ZStack {
                Color(.secondarySystemBackground)

                if let img = thumbnail {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: w, height: h)
                        .clipped()
                } else {
                    // サムネイル未取得または生成不可時のプレースホルダー
                    VStack(spacing: 6) {
                        Image(systemName: item.format == .hls ? "film.stack" : "play.rectangle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        Text(item.format.label)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .task(id: item.id) {
                guard !hasAttemptedLoad else { return }
                hasAttemptedLoad = true
                let loaded = await TrashManager.shared.loadThumbnail(for: item)
                await MainActor.run {
                    self.thumbnail = loaded
                }
            }
        }
    }
}
