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
    @ObservedObject private var settingsManager = AppSettingsManager.shared
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
                Section {
                    Button {
                        VideoThumbnailManager.shared.clearAllCache()
                        showToast("サムネイルのメモリキャッシュを解放しました")
                    } label: {
                        HStack {
                            Label("サムネイルのメモリキャッシュを解放", systemImage: "photo.on.rectangle.angled")
                            Spacer()
                        }
                    }
                } header: {
                    Text("キャッシュ管理")
                } footer: {
                    Text("メモリ上の一時キャッシュを解放します。保存済みの動画ファイルやディスク上のデータは消去されません。")
                        .font(.caption2)
                }

                // セクション 3: ゴミ箱の自動削除設定
                Section {
                    Picker("保持期間", selection: $settingsManager.trashRetentionPeriod) {
                        ForEach(TrashRetentionPeriod.allCases) { period in
                            Text(period.title).tag(period)
                        }
                    }
                } header: {
                    Text("ゴミ箱の自動削除設定")
                } footer: {
                    Text("設定を変更すると、今後ゴミ箱に移動した動画から適用されます。既にゴミ箱にある動画の期限は変更されません。「自動削除しない」を選択した場合、手動で削除するまで端末の容量を消費し続けます。")
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
