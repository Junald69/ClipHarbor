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
                Section(NSLocalizedString("Storage Usage", comment: "")) {
                    HStack {
                        Label(NSLocalizedString("Saved Videos", comment: ""), systemImage: "play.rectangle")
                        Spacer()
                        Text("\(String.localizedStringWithFormat(NSLocalizedString("%lld videos", comment: ""), Int64(downloads.saved.count))) (\(ByteCountFormatter.string(fromByteCount: totalSavedBytes, countStyle: .file)))")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Label(NSLocalizedString("Folders", comment: ""), systemImage: "folder")
                        Spacer()
                        Text(String.localizedStringWithFormat(NSLocalizedString("%lld folders", comment: ""), Int64(folderManager.folders.count)))
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Label(NSLocalizedString("Trash", comment: ""), systemImage: "trash")
                        Spacer()
                        Text("\(String.localizedStringWithFormat(NSLocalizedString("%lld items", comment: ""), Int64(trashManager.items.count))) (\(ByteCountFormatter.string(fromByteCount: totalTrashBytes, countStyle: .file)))")
                            .foregroundStyle(.secondary)
                    }
                }

                // セクション 3: キャッシュ管理
                Section {
                    Button {
                        VideoThumbnailManager.shared.clearAllCache()
                        showToast(NSLocalizedString("Cleared thumbnail memory cache", comment: ""))
                    } label: {
                        HStack {
                            Label(NSLocalizedString("Clear Thumbnail Memory Cache", comment: ""), systemImage: "photo.on.rectangle.angled")
                            Spacer()
                        }
                    }
                } header: {
                    Text(NSLocalizedString("Cache Management", comment: ""))
                } footer: {
                    Text(NSLocalizedString("Frees temporary memory cache. Saved video files and data on disk will not be deleted.", comment: ""))
                        .font(.caption2)
                }

                // セクション 4: ゴミ箱の自動削除設定
                Section {
                    Picker(NSLocalizedString("Retention Period", comment: ""), selection: $settingsManager.trashRetentionPeriod) {
                        ForEach(TrashRetentionPeriod.allCases) { period in
                            Text(period.title).tag(period)
                        }
                    }
                } header: {
                    Text(NSLocalizedString("Trash Auto-Deletion Settings", comment: ""))
                } footer: {
                    Text(NSLocalizedString("Changes will apply to files moved to trash in the future. The expiration date of files currently in trash will not change. If 'Do Not Auto-Delete' is selected, files will continue to consume device storage until manually deleted.", comment: ""))
                        .font(.caption2)
                }

                // セクション 5: ファイル共有とセキュリティ
                Section(NSLocalizedString("File Sharing", comment: "")) {
                    HStack {
                        Label(NSLocalizedString("iOS Files App Integration", comment: ""), systemImage: "doc.badge.arrow.up")
                        Spacer()
                        Text(NSLocalizedString("Enabled", comment: ""))
                            .foregroundStyle(.green)
                    }

                    Text(NSLocalizedString("Files in 'Downloads' can be viewed and shared via the iOS Files app. Files in Trash are securely isolated in a private directory.", comment: ""))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(NSLocalizedString("File Management Settings", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(NSLocalizedString("Close", comment: "")) {
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
