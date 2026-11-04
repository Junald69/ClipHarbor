import SwiftUI

/// ゴミ箱内フォルダの内容閲覧・復元・完全削除詳細シート (Phase S3)
/// - 削除前の内部ファイル構成（動画・一般ファイル・未登録ファイル・サブフォルダ）を復元前に確認可能
/// - 各アイテムの形式、容量、サブパスを一覧表示
/// - 「フォルダを復元」「完全に削除」アクション
/// - 復元時の同名衝突安全解決（別名で復元 / キャンセル）
struct TrashFolderDetailView: View {
    let item: TrashItem
    @ObservedObject var downloads: DownloadCenter
    @ObservedObject var folderManager: VideoFolderManager
    var zipManager: ZipArchiveManager = ZipArchiveManager.shared
    let onRestored: (String) -> Void
    let onDeleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var trashManager = TrashManager.shared

    @State private var manifest: FolderTrashManifest? = nil
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    @State private var isOperating = false
    @State private var showConflictAlert = false
    @State private var showDeleteAlert = false

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Reading folder contents...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let manifest = manifest {
                    ScrollView {
                        VStack(spacing: 16) {
                            // フォルダヘッダー情報
                            folderHeaderCard(manifest: manifest)

                            // アクションボタン（復元・完全削除）
                            actionButtonsBar

                            // 内部ファイル構成リスト
                            contentsListView(manifest: manifest)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                } else {
                    // マニフェスト読み込み不可（破損・欠損）時の安全表示
                    corruptedManifestPlaceholder
                }
            }
            .navigationTitle(item.originalTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                    .disabled(isOperating)
                }
            }
            .task {
                loadManifest()
            }
            .alert(
                NSLocalizedString("Folder Already Exists", comment: ""),
                isPresented: $showConflictAlert
            ) {
                Button(NSLocalizedString("Restore with Different Name", comment: "")) {
                    performRestore(resolution: .rename)
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text(String(format: NSLocalizedString("A folder named \"%@\" already exists in Downloads. Would you like to restore it with a different name?", comment: ""), item.originalTitle))
            }
            .alert(
                NSLocalizedString("Delete Folder Permanently", comment: ""),
                isPresented: $showDeleteAlert
            ) {
                Button("Cancel", role: .cancel) { }
                Button(NSLocalizedString("Delete Permanently", comment: ""), role: .destructive) {
                    performPermanentDelete()
                }
            } message: {
                Text(String(format: NSLocalizedString("Are you sure you want to permanently delete folder \"%@\" and all its contents from this device?\nThis action cannot be undone.", comment: ""), item.originalTitle))
            }
            .alert(NSLocalizedString("Error", comment: ""), isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: - フォルダヘッダーカード

    private func folderHeaderCard(manifest: FolderTrashManifest) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "folder.fill")
                .font(.system(size: 40))
                .foregroundStyle(.blue.gradient)
                .frame(width: 56, height: 56)
                .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(manifest.originalFolderName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    let totalCount = manifest.videos.count + manifest.generalFiles.count + manifest.unregisteredFiles.count
                    Text(String(format: NSLocalizedString("%lld items", comment: ""), totalCount))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text("·")
                        .foregroundStyle(.secondary)

                    Text(ByteCountFormatter.string(fromByteCount: manifest.totalByteSize, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.caption2)
                    Text(item.remainingTimeDescription)
                        .font(.caption2.weight(.medium))
                }
                .foregroundStyle(item.isExpired ? Color.red : Color.secondary)
            }

            Spacer()
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - アクションボタン

    private var actionButtonsBar: some View {
        HStack(spacing: 12) {
            Button {
                checkConflictAndRestore()
            } label: {
                HStack(spacing: 6) {
                    if isOperating {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    Text("Restore Folder")
                        .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.blue, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .foregroundStyle(.white)
            }
            .disabled(isOperating)

            Button(role: .destructive) {
                showDeleteAlert = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                    Text("Delete")
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .foregroundStyle(.red)
            }
            .disabled(isOperating)
        }
    }

    // MARK: - 内部ファイル構成リスト

    private func contentsListView(manifest: FolderTrashManifest) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if !manifest.videos.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(format: NSLocalizedString("Videos (%lld)", comment: ""), manifest.videos.count))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.secondary)

                    ForEach(manifest.videos, id: \.video.id) { vRec in
                        HStack(spacing: 10) {
                            Image(systemName: vRec.video.isHLS ? "film.stack" : "play.rectangle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(.blue)
                                .frame(width: 32)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(vRec.video.title)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                Text(vRec.relativeSubpath)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 2) {
                                Text(vRec.video.format.label)
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.blue)

                                if let size = vRec.video.byteSize, size > 0 {
                                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 6)
                        Divider()
                    }
                }
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if !manifest.generalFiles.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(format: NSLocalizedString("Files (%lld)", comment: ""), manifest.generalFiles.count))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.secondary)

                    ForEach(manifest.generalFiles, id: \.file.id) { fRec in
                        HStack(spacing: 10) {
                            let ext = fRec.file.fileExtension.lowercased()
                            let iconName = ext == "zip" ? "doc.zipper" : (ext == "pdf" ? "doc.richtext" : "doc.fill")
                            Image(systemName: iconName)
                                .font(.system(size: 20))
                                .foregroundStyle(.purple)
                                .frame(width: 32)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(fRec.file.title)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                Text(fRec.relativeSubpath)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 2) {
                                Text(fRec.file.fileExtension.uppercased())
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.purple)

                                Text(ByteCountFormatter.string(fromByteCount: fRec.file.byteSize, countStyle: .file))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                        Divider()
                    }
                }
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if !manifest.unregisteredFiles.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(format: NSLocalizedString("Other Files (%lld)", comment: ""), manifest.unregisteredFiles.count))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.secondary)

                    ForEach(manifest.unregisteredFiles, id: \.relativeSubpath) { uRec in
                        HStack(spacing: 10) {
                            Image(systemName: "doc")
                                .font(.system(size: 18))
                                .foregroundStyle(.secondary)
                                .frame(width: 32)

                            Text(uRec.relativeSubpath)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Spacer()

                            Text(ByteCountFormatter.string(fromByteCount: uRec.byteSize, countStyle: .file))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        Divider()
                    }
                }
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if !manifest.emptySubdirectories.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(NSLocalizedString("Empty Subfolders", comment: ""))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)

                    ForEach(manifest.emptySubdirectories, id: \.self) { sub in
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(sub)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    // MARK: - マニフェスト破損時のプレースホルダー

    private var corruptedManifestPlaceholder: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)

            Text("Folder Manifest Unreadable")
                .font(.headline)

            Text("The detailed list of files inside this folder could not be parsed, but the physical folder and its contents are safely preserved in Trash.\nIt is strictly protected from auto-deletion.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            actionButtonsBar
                .padding(.top, 12)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 処理ロジック

    private func loadManifest() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = trashManager.loadFolderManifest(for: item.id)
            DispatchQueue.main.async {
                self.manifest = loaded
                self.isLoading = false
            }
        }
    }

    private func checkConflictAndRestore() {
        guard !isOperating else { return }
        let cleanName = VideoFolderManager.sanitizedFolderName(manifest?.originalFolderName.isEmpty == false ? manifest!.originalFolderName : item.fileName)
        let downloadsDir = zipManager.downloadsRootURL
        let targetDir = downloadsDir.appendingPathComponent(cleanName, isDirectory: true)

        if FileManager.default.fileExists(atPath: targetDir.path) {
            showConflictAlert = true
        } else {
            performRestore(resolution: .rename)
        }
    }

    private func performRestore(resolution: FolderRestoreConflictResolution) {
        guard !isOperating else { return }
        isOperating = true
        Task {
            let res = await trashManager.restoreFolder(
                item: item,
                downloads: downloads,
                folderManager: folderManager,
                zipManager: zipManager,
                resolution: resolution
            )
            await MainActor.run {
                isOperating = false
                switch res {
                case .success(let restoredName):
                    onRestored(restoredName)
                    dismiss()
                case .failure(let err):
                    errorMessage = err.localizedDescription
                }
            }
        }
    }

    private func performPermanentDelete() {
        guard !isOperating else { return }
        isOperating = true
        Task {
            let res = await trashManager.deletePermanently(item: item)
            await MainActor.run {
                isOperating = false
                switch res {
                case .success:
                    onDeleted()
                    dismiss()
                case .failure(let err):
                    errorMessage = err.localizedDescription
                }
            }
        }
    }
}
