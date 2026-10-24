import SwiftUI
import AVKit

/// Aloha風のシンプルなアプリ内フォルダ・保存動画管理シート。
/// MP4とHLSを同じフォルダ一覧UIで整理でき、HLSはローカルアセット（.movpkg）を移動せず論理フォルダのみで管理する。
struct FileManagerView: View {
    @ObservedObject var downloads: DownloadCenter
    @ObservedObject var folderManager: VideoFolderManager
    @ObservedObject private var exports = VideoExportManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selectedFilter: VideoFolderManager.FolderFilter = .all
    @State private var playingVideo: SavedVideo?

    // フォルダ操作用ダイアログ
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var renamingFolder: String?
    @State private var renameFolderInput = ""

    // 動画操作用ダイアログ・シート
    @State private var renamingVideo: SavedVideo?
    @State private var renameVideoInput = ""
    @State private var movingVideo: SavedVideo?
    @State private var errorMessage: String?

    private var currentVideos: [SavedVideo] {
        folderManager.videos(in: selectedFilter)
    }

    var body: some View {
        NavigationStack {
            List {
                if !downloads.jobs.isEmpty {
                    Section("ダウンロード状況") {
                        ForEach(downloads.jobs) { job in
                            SimpleDownloadJobRow(
                                job: job,
                                onCancel: { downloads.cancel(job.id) },
                                onRetry: { downloads.retry(job.id) },
                                onDismiss: { downloads.dismissJob(job.id) }
                            )
                        }
                    }
                }

                if !exports.exportJobs.isEmpty {
                    Section("MP4変換テスト状況 (fMP4 PoC)") {
                        ForEach(exports.exportJobs) { job in
                            FMP4ExportJobRow(
                                job: job,
                                onCancel: { exports.cancelExport(job.id) },
                                onDismiss: { exports.dismissExportJob(job.id) }
                            )
                        }
                    }
                }

                foldersSection
                videosSection
                pocVerificationSection
            }
            .navigationTitle("フォルダ・動画管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        newFolderName = ""
                        showNewFolderAlert = true
                    } label: {
                        Label("新規フォルダ", systemImage: "folder.badge.plus")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
            .onAppear {
                folderManager.syncWithFileSystemAndSavedVideos()
            }
            .fullScreenCover(item: $playingVideo) { video in
                OfflineVideoPlayerSheet(video: video)
            }
            .sheet(item: $movingVideo) { video in
                MoveToFolderSheet(
                    video: video,
                    currentFolder: folderManager.folderName(for: video),
                    folders: folderManager.folders,
                    onSelectFolder: { targetFolder in
                        if case .failure(let err) = folderManager.moveVideo(video, toFolder: targetFolder) {
                            errorMessage = err.localizedDescription
                        }
                    }
                )
            }
            .alert("新規フォルダを作成", isPresented: $showNewFolderAlert) {
                TextField("フォルダ名", text: $newFolderName)
                Button("キャンセル", role: .cancel) { }
                Button("作成") {
                    switch folderManager.createFolder(name: newFolderName) {
                    case .success(let created):
                        selectedFilter = .folder(created)
                    case .failure(let err):
                        errorMessage = err.localizedDescription
                    }
                }
            } message: {
                Text("動画を整理するための新しいフォルダを作成します。")
            }
            .alert(
                "フォルダ名を変更",
                isPresented: Binding(
                    get: { renamingFolder != nil },
                    set: { if !$0 { renamingFolder = nil } }
                )
            ) {
                TextField("新しいフォルダ名", text: $renameFolderInput)
                Button("キャンセル", role: .cancel) { renamingFolder = nil }
                Button("変更") {
                    if let old = renamingFolder {
                        switch folderManager.renameFolder(from: old, to: renameFolderInput) {
                        case .success(let updated):
                            if selectedFilter == .folder(old) {
                                selectedFilter = .folder(updated)
                            }
                        case .failure(let err):
                            errorMessage = err.localizedDescription
                        }
                    }
                    renamingFolder = nil
                }
            }
            .alert(
                "動画の名前を変更",
                isPresented: Binding(
                    get: { renamingVideo != nil },
                    set: { if !$0 { renamingVideo = nil } }
                )
            ) {
                TextField("新しい動画名", text: $renameVideoInput)
                Button("キャンセル", role: .cancel) { renamingVideo = nil }
                Button("変更") {
                    if let target = renamingVideo {
                        if case .failure(let err) = folderManager.renameVideo(target, to: renameVideoInput) {
                            errorMessage = err.localizedDescription
                        }
                    }
                    renamingVideo = nil
                }
            }
            .alert(
                "操作できませんでした",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: - フォルダ一覧セクション

    private var foldersSection: some View {
        Section {
            folderRow(.all, icon: "tray.full.fill")
            folderRow(.uncategorized, icon: "folder")

            ForEach(folderManager.folders, id: \.self) { name in
                folderRow(.folder(name), icon: "folder.fill")
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            if selectedFilter == .folder(name) {
                                selectedFilter = .all
                            }
                            folderManager.deleteFolder(name: name)
                        } label: {
                            Label("削除", systemImage: "trash")
                        }
                        Button {
                            renameFolderInput = name
                            renamingFolder = name
                        } label: {
                            Label("名前変更", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                    .contextMenu {
                        Button {
                            renameFolderInput = name
                            renamingFolder = name
                        } label: {
                            Label("フォルダ名を変更", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            if selectedFilter == .folder(name) {
                                selectedFilter = .all
                            }
                            folderManager.deleteFolder(name: name)
                        } label: {
                            Label("フォルダを削除（動画は残す）", systemImage: "trash")
                        }
                    }
            }
        } header: {
            HStack {
                Text("フォルダ")
                Spacer()
                if case .folder(let currentName) = selectedFilter {
                    Menu {
                        Button {
                            renameFolderInput = currentName
                            renamingFolder = currentName
                        } label: {
                            Label("「\(currentName)」の名前を変更", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            selectedFilter = .all
                            folderManager.deleteFolder(name: currentName)
                        } label: {
                            Label("「\(currentName)」を削除（動画は残す）", systemImage: "trash")
                        }
                    } label: {
                        Label("フォルダ編集", systemImage: "ellipsis.circle")
                            .font(.caption)
                            .textCase(nil)
                    }
                }
            }
        }
    }

    private func folderRow(_ filter: VideoFolderManager.FolderFilter, icon: String) -> some View {
        let isSelected = (selectedFilter == filter)
        let count = folderManager.videoCount(in: filter)
        return Button {
            selectedFilter = filter
        } label: {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(isSelected ? .blue : .secondary)
                Text(filter.title)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? .blue : .secondary)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.blue)
                }
            }
        }
    }

    // MARK: - 保存済み動画一覧セクション

    private var videosSection: some View {
        Section("\(selectedFilter.title)（\(currentVideos.count)件）") {
            if currentVideos.isEmpty {
                ContentUnavailableView(
                    "動画はありません",
                    systemImage: "square.and.arrow.down",
                    description: Text("動画再生中に表示される↓ボタンから保存できます。")
                )
            } else {
                ForEach(currentVideos) { video in
                    FolderVideoRow(
                        video: video,
                        folderName: folderManager.folderName(for: video),
                        onPlay: { playingVideo = video },
                        onMove: { movingVideo = video },
                        onRename: {
                            renameVideoInput = video.title
                            renamingVideo = video
                        },
                        onDelete: { folderManager.deleteVideo(video) }
                    )
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            folderManager.deleteVideo(video)
                        } label: {
                            Label("削除", systemImage: "trash")
                        }
                        Button {
                            movingVideo = video
                        } label: {
                            Label("移動", systemImage: "folder")
                        }
                        .tint(.indigo)
                        Button {
                            renameVideoInput = video.title
                            renamingVideo = video
                        } label: {
                            Label("名前変更", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }
            }
        }
    }
    // MARK: - fMP4 → MP4 PoC実機検証セクション（テストA / B / C）

    private var pocVerificationSection: some View {
        Section {
            Menu {
                Button {
                    _ = exports.startPoCTestA_MuxedFMP4()
                } label: {
                    Label("テストA：映像・音声統合型 fMP4（MP4変換成功確認）", systemImage: "checkmark.seal")
                }
                Button {
                    _ = exports.startPoCTestB_AppleSeparateAudioFMP4()
                } label: {
                    Label("テストB：Apple公式 分離音声 fMP4（映像＋音声結合MP4変換）", systemImage: "waveform.badge.plus")
                }
                Button {
                    _ = exports.startPoCTestC_MPEGTS()
                } label: {
                    Label("テストC：MPEG-TS形式 HLS（非対応判定確認）", systemImage: "film.stack")
                }
            } label: {
                Label("fMP4→MP4 PoC実機テストを実行 (A / B / C)", systemImage: "testtube.2")
                    .font(.subheadline)
            }
        } header: {
            Text("PoC検証メニュー（Phase 2：分離音声fMP4対応）")
        } footer: {
            Text("テストAは統合型fMP4 HLS（18秒）、テストBはApple公式の分離音声fMP4 HLS（#EXT-X-MEDIA:TYPE=AUDIO、600秒）から映像と音声を取得・同期・結合してMP4を生成し、品質検証の合格後にDocuments/Downloadsへ保存します。テストCはMPEG-TS形式が非対応判定されることを確認します。")
        }
    }
}

// MARK: - ダウンロード進捗行（v2.1のシンプルな表示を維持）

private struct SimpleDownloadJobRow: View {
    let job: DownloadJob
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(job.displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer()
                if job.state.isActive {
                    Button("キャンセル", role: .destructive, action: onCancel)
                        .font(.caption)
                        .buttonStyle(.borderless)
                } else {
                    HStack(spacing: 12) {
                        if job.canRetry {
                            Button("再試行", action: onRetry)
                                .font(.caption.weight(.semibold))
                                .buttonStyle(.borderless)
                        }
                        Button(action: onDismiss) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("履歴から消す")
                    }
                }
            }

            switch job.state {
            case .preparing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("準備中… (\(job.host))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .downloading(let progress):
                if let p = progress {
                    ProgressView(value: p)
                } else {
                    ProgressView()
                }
                HStack {
                    Text(job.state.label)
                    Spacer()
                    if job.receivedBytes > 0 {
                        Text(byteProgressText)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            case .completed:
                Label("保存完了", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            case .cancelled:
                Label("キャンセルしました", systemImage: "slash.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var byteProgressText: String {
        let received = ByteCountFormatter.string(fromByteCount: job.receivedBytes, countStyle: .file)
        if job.expectedBytes > 0 {
            let total = ByteCountFormatter.string(fromByteCount: job.expectedBytes, countStyle: .file)
            return "\(received) / \(total)"
        }
        return received
    }
}

// MARK: - fMP4 → MP4 変換テスト進捗・品質検証結果行

private struct FMP4ExportJobRow: View {
    let job: VideoExportManager.ExportJob
    let onCancel: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(job.displayName).mp4")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer()
                if job.state.isActive {
                    Button("キャンセル", role: .destructive, action: onCancel)
                        .font(.caption)
                        .buttonStyle(.borderless)
                } else {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("履歴から消す")
                }
            }

            switch job.state {
            case .analyzingPlaylist, .remuxingToMP4, .verifyingMP4:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(job.state.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .downloadingSegments(_, _, _, let progress):
                ProgressView(value: progress)
                Text(job.state.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .completed(let summary):
                Label(job.state.label, systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                let sizeStr = ByteCountFormatter.string(fromByteCount: summary.byteSize, countStyle: .file)
                let audioStr = summary.audioCodec ?? "なし(映像のみ)"
                let segStr = summary.isSeparateAudioMerged
                    ? "映像\(summary.videoSegmentCount)+音声\(summary.audioSegmentCount)seg (同期補正:\(summary.avSyncOffsetMs)ms)"
                    : "\(summary.videoSegmentCount)seg"
                Text("映像:\(summary.videoCodec) / 音声:\(audioStr) · Preset:\(summary.exportPresetUsed) · \(sizeStr) · \(segStr) · フレーム検査:\(summary.decodedCheckpoints)/3点合格")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let aDur = summary.audioDurationSeconds {
                    Text(String(format: "映像長:%.1f秒 / 音声長:%.1f秒 · ※実機再生で冒頭・中間・終端の音声同期もご確認ください", summary.durationSeconds, aDur))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            case .failed(let reason):
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case .cancelled:
                Label("キャンセルしました", systemImage: "slash.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 保存済み動画行（再生・フォルダ移動・名前変更・共有・削除）

private struct FolderVideoRow: View {
    let video: SavedVideo
    let folderName: String
    let onPlay: () -> Void
    let onMove: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(video.title)
                .font(.headline)
                .lineLimit(2)

            HStack(spacing: 6) {
                Text(video.format.label)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())

                Label(folderName.isEmpty ? "Downloads" : folderName, systemImage: "folder")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let size = video.byteSize, size > 0 {
                    Text("· \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
                }
                if let host = video.sourceHost, !host.isEmpty {
                    Text("· \(host)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(video.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                Button(action: onPlay) {
                    Label("再生", systemImage: "play.fill")
                }
                .buttonStyle(.borderless)

                Button(action: onMove) {
                    Label("フォルダ移動", systemImage: "folder")
                }
                .buttonStyle(.borderless)

                Button(action: onRename) {
                    Label("名前変更", systemImage: "pencil")
                }
                .buttonStyle(.borderless)

                if !video.isHLS && video.fileExists {
                    ShareLink(item: video.fileURL) {
                        Label("共有", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                }

                Spacer()

                Menu {
                    Button(action: onPlay) {
                        Label("再生", systemImage: "play.fill")
                    }
                    Button(action: onMove) {
                        Label("フォルダへ移動", systemImage: "folder")
                    }
                    Button(action: onRename) {
                        Label("名前を変更", systemImage: "pencil")
                    }
                    if !video.isHLS && video.fileExists {
                        ShareLink(item: video.fileURL) {
                            Label("共有・書き出し", systemImage: "square.and.arrow.up")
                        }
                    }
                    Divider()
                    Button(role: .destructive, action: onDelete) {
                        Label("削除", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .buttonStyle(.borderless)
            }
            .font(.caption.weight(.medium))
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 動画のフォルダ移動シート

private struct MoveToFolderSheet: View {
    let video: SavedVideo
    let currentFolder: String
    let folders: [String]
    let onSelectFolder: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newFolderName = ""

    var body: some View {
        NavigationStack {
            List {
                Section("移動先フォルダを選択") {
                    Button {
                        dismiss()
                        onSelectFolder("")
                    } label: {
                        HStack {
                            Label("Downloads（未分類）", systemImage: "folder")
                            Spacer()
                            if currentFolder.isEmpty {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }

                    ForEach(folders, id: \.self) { folder in
                        Button {
                            dismiss()
                            onSelectFolder(folder)
                        } label: {
                            HStack {
                                Label(folder, systemImage: "folder.fill")
                                Spacer()
                                if currentFolder == folder {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                }

                Section("新規フォルダを作成して移動") {
                    HStack {
                        TextField("新しいフォルダ名", text: $newFolderName)
                        Button("作成して移動") {
                            let target = newFolderName
                            dismiss()
                            onSelectFolder(target)
                        }
                        .disabled(VideoFolderManager.sanitizedFolderName(newFolderName).isEmpty)
                    }
                }
            }
            .navigationTitle("フォルダ移動")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
