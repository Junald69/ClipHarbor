import SwiftUI

/// ファイル管理の設定画面
/// - ストレージ使用状況（保存済み動画・フォルダ数・ゴミ箱容量）の実測表示
/// - サムネイルキャッシュの手動消去（メモリ解放）
/// - ゴミ箱保持期間の将来仕様（1日/3日/7日/30日/自動削除なし）の案内表示
/// - iOS「ファイル」アプリ共有機能のステータス案内
struct FileManagerSettingsView: View {
    @ObservedObject var downloads: DownloadCenter
    @ObservedObject var folderManager: VideoFolderManager
    @ObservedObject var trashManager = TrashManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var toastMessage: String?

    // ストレージ計算
    private var totalSavedBytes: Int64 {
        downloads.saved.reduce(0) { $0 + ($1.byteSize ?? 0) }
    }

    private var totalTrashBytes: Int64 {
        trashManager.items.reduce(0) { $0 + ($1.byteSize ?? 0) }
    }

    var body: some View {
        NavigationStack {
            List {
                // セクション 1: ストレージ使用状況
                Section("ストレージ使用状況") {
                    HStack {
                        Label("保存済み動画", systemImage: "play.rectangle")
                        Spacer()
                        Text("\(downloads.saved.count) 本 (\(ByteCountFormatter.string(fromByteCount: totalSavedBytes, countStyle: .file)))")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Label("フォルダ数", systemImage: "folder")
                        Spacer()
                        Text("\(folderManager.folders.count) 個")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Label("ゴミ箱", systemImage: "trash")
                        Spacer()
                        Text("\(trashManager.items.count) 件 (\(ByteCountFormatter.string(fromByteCount: totalTrashBytes, countStyle: .file)))")
                            .foregroundStyle(.secondary)
                    }
                }

                // セクション 2: キャッシュ管理
                Section("キャッシュ管理") {
                    Button {
                        VideoThumbnailManager.shared.clearAllCache()
                        showToast("サムネイルキャッシュを消去しました")
                    } label: {
                        HStack {
                            Label("サムネイルキャッシュを消去", systemImage: "photo.on.rectangle.angled")
                            Spacer()
                            Text("メモリ解放")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // セクション 3: ゴミ箱の自動削除設定（将来対応予定の告知）
                Section {
                    HStack {
                        Text("保持期間")
                        Spacer()
                        Text("3日間 (初期値)")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("ゴミ箱の自動削除設定")
                } footer: {
                    Text("削除から3日経過後、次回のアプリ起動時などに完全削除されます。\n※ 将来のアップデートにて、1日・3日・7日・30日・自動削除なしの選択に対応予定です（現在は3日間固定）。")
                        .font(.caption2)
                }

                // セクション 4: ファイル共有とセキュリティ
                Section("ファイル共有") {
                    HStack {
                        Label("iOS「ファイル」アプリ連携", systemImage: "doc.badge.arrow.up")
                        Spacer()
                        Text("有効")
                            .foregroundStyle(.green)
                    }

                    Text("「Downloads」配下の動画はiOS標準の「ファイル」アプリから閲覧・共有できます。ゴミ箱内のファイルは非公開領域に安全に隔離されます。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("ファイル管理設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") {
                        dismiss()
                    }
                    .font(.body.weight(.semibold))
                }
            }
            .overlay(alignment: .top) {
                if let msg = toastMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(msg)
                            .font(.caption.weight(.medium))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: toastMessage)
        }
    }

    private func showToast(_ msg: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            toastMessage = msg
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(.easeInOut(duration: 0.2)) {
                toastMessage = nil
            }
        }
    }
}
