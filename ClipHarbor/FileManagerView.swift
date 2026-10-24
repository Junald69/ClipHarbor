import SwiftUI
import AVKit

/// Aloha風のローカルファイル管理＆ダウンロード進捗・速度計測シート。
struct FileManagerView: View {
    @ObservedObject var downloads: DownloadCenter
    @Environment(\.dismiss) private var dismiss

    enum FolderFilter: Hashable, Identifiable {
        case all
        case root
        case custom(String)

        var id: String {
            switch self {
            case .all: return "__all__"
            case .root: return "__root__"
            case .custom(let name): return "folder:\(name)"
            }
        }

        var title: String {
            switch self {
            case .all: return "すべての動画"
            case .root: return "Downloads（未分類）"
            case .custom(let name): return name
            }
        }
    }

    @State private var selectedFilter: FolderFilter = .all
    @State private var sortOrder: FileSortOrder = .dateDesc
    @State private var searchText: String = ""
    @State private var playingVideo: SavedVideo?

    // フォルダ操作用ダイアログ状態
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var renamingFolder: String?
    @State private var renameFolderInput = ""

    // ファイル操作用ダイアログ状態
    @State private var renamingVideo: SavedVideo?
    @State private var renameVideoInput = ""
    @State private var movingVideo: SavedVideo?

    @State private var alertMessage: String?

    private var filteredVideos: [SavedVideo] {
        var list = downloads.saved.filter { video in
            switch selectedFilter {
            case .all:
                return true
            case .root:
                return video.folderName.isEmpty
            case .custom(let folder):
                return video.folderName == folder
            }
        }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            list = list.filter {
                $0.title.localizedCaseInsensitiveContains(q)
                    || ($0.sourceHost?.localizedCaseInsensitiveContains(q) ?? false)
                    || $0.folderName.localizedCaseInsensitiveContains(q)
            }
        }
        switch sortOrder {
        case .dateDesc:
            list.sort { $0.createdAt > $1.createdAt }
        case .dateAsc:
            list.sort { $0.createdAt < $1.createdAt }
        case .nameAsc:
            list.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .sizeDesc:
            list.sort { ($0.byteSize ?? 0) > ($1.byteSize ?? 0) }
        }
        return list
    }

    var body: some View {
        NavigationStack {
            List {
                if !downloads.jobs.isEmpty {
                    downloadsSection
                }

                foldersSection
                videosSection
                filesAppGuidanceSection
            }
            .navigationTitle("ファイル管理")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "動画名・サイト名・フォルダ名で検索")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("並び替え", selection: $sortOrder) {
                            ForEach(FileSortOrder.allCases) { order in
                                Text(order.rawValue).tag(order)
                            }
                        }
                        Divider()
                        Button {
                            newFolderName = ""
                            showNewFolderAlert = true
                        } label: {
                            Label("新規フォルダを作成", systemImage: "folder.badge.plus")
                        }
                    } label: {
                        Label("整理", systemImage: "arrow.up.arrow.down.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
            .fullScreenCover(item: $playingVideo) { video in
                OfflineVideoPlayerSheet(video: video)
            }
            .sheet(item: $movingVideo) { video in
                MoveVideoFolderSheet(
                    video: video,
                    folders: downloads.folders,
                    onMove: { targetFolder in
                        if case .failure(let err) = downloads.moveVideo(video, toFolder: targetFolder) {
                            alertMessage = err.localizedDescription
                        }
                    },
                    onCreateAndMove: { rawName in
                        switch downloads.createFolder(name: rawName) {
                        case .success(let created):
                            if case .failure(let err) = downloads.moveVideo(video, toFolder: created) {
                                alertMessage = err.localizedDescription
                            }
                        case .failure(let err):
                            alertMessage = err.localizedDescription
                        }
                    }
                )
            }
            .alert("新規フォルダ作成", isPresented: $showNewFolderAlert) {
                TextField("フォルダ名", text: $newFolderName)
                Button("キャンセル", role: .cancel) { }
                Button("作成") {
                    switch downloads.createFolder(name: newFolderName) {
                    case .success(let folder):
                        selectedFilter = .custom(folder)
                    case .failure(let err):
                        alertMessage = err.localizedDescription
                    }
                }
            } message: {
                Text("Documents / Downloads 内に新しいサブフォルダを作成します。")
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
                        switch downloads.renameFolder(from: old, to: renameFolderInput) {
                        case .success(let updated):
                            if selectedFilter == .custom(old) {
                                selectedFilter = .custom(updated)
                            }
                        case .failure(let err):
                            alertMessage = err.localizedDescription
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
                        if case .failure(let err) = downloads.renameVideo(target, to: renameVideoInput) {
                            alertMessage = err.localizedDescription
                        }
                    }
                    renamingVideo = nil
                }
            }
            .alert(
                "操作できませんでした",
                isPresented: Binding(
                    get: { alertMessage != nil },
                    set: { if !$0 { alertMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { alertMessage = nil }
            } message: {
                Text(alertMessage ?? "")
            }
        }
    }

    // MARK: - ダウンロード状況＆通信速度・診断セクション

    private var downloadsSection: some View {
        Section {
            ForEach(downloads.jobs) { job in
                DownloadJobRow(
                    job: job,
                    onPause: { downloads.pause(job.id) },
                    onResume: { downloads.resume(job.id) },
                    onCancel: { downloads.cancel(job.id) },
                    onRetry: { downloads.retry(job.id) },
                    onDismiss: { downloads.dismissJob(job.id) }
                )
            }
        } header: {
            HStack {
                Text("ダウンロード状況・通信速度")
                Spacer()
                if downloads.jobs.contains(where: { !$0.state.isActive && !$0.state.isPaused }) {
                    Button("完了履歴を消去") {
                        downloads.clearInactiveJobs()
                    }
                    .font(.caption)
                    .textCase(nil)
                }
            }
        }
    }

    // MARK: - フォルダ一覧セクション

    private var foldersSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    folderChip(.all, icon: "tray.full.fill", count: downloads.saved.count)
                    folderChip(.root, icon: "folder.fill", count: downloads.saved.filter { $0.folderName.isEmpty }.count)
                    ForEach(downloads.folders, id: \.self) { folder in
                        let count = downloads.saved.filter { $0.folderName == folder }.count
                        folderChip(.custom(folder), icon: "folder.fill.badge.gearshape", count: count)
                            .contextMenu {
                                Button {
                                    renameFolderInput = folder
                                    renamingFolder = folder
                                } label: {
                                    Label("フォルダ名を変更", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    if selectedFilter == .custom(folder) {
                                        selectedFilter = .all
                                    }
                                    downloads.deleteFolder(name: folder)
                                } label: {
                                    Label("フォルダを削除（動画は残す）", systemImage: "trash")
                                }
                            }
                    }

                    Button {
                        newFolderName = ""
                        showNewFolderAlert = true
                    } label: {
                        Label("新規フォルダ", systemImage: "folder.badge.plus")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 4)
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
        } header: {
            HStack {
                Text("フォルダ（長押しで編集）")
                Spacer()
                if case .custom(let currentFolder) = selectedFilter {
                    Menu {
                        Button {
                            renameFolderInput = currentFolder
                            renamingFolder = currentFolder
                        } label: {
                            Label("「\(currentFolder)」の名前を変更", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            selectedFilter = .all
                            downloads.deleteFolder(name: currentFolder)
                        } label: {
                            Label("「\(currentFolder)」を削除", systemImage: "trash")
                        }
                    } label: {
                        Label(currentFolder, systemImage: "ellipsis.circle")
                            .font(.caption)
                            .textCase(nil)
                    }
                }
            }
        }
    }

    private func folderChip(_ filter: FolderFilter, icon: String, count: Int) -> some View {
        let isSelected = (selectedFilter == filter)
        return Button {
            selectedFilter = filter
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(filter.title)
                    .lineLimit(1)
                Text("\(count)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(isSelected ? Color.white.opacity(0.24) : Color.secondary.opacity(0.16), in: Capsule())
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(isSelected ? .white : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.blue : Color.secondary.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 保存済み動画一覧セクション

    private var videosSection: some View {
        Section {
            let items = filteredVideos
            if items.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "このフォルダに動画はありません" : "一致する動画がありません",
                    systemImage: searchText.isEmpty ? "film.stack" : "magnifyingglass",
                    description: Text(searchText.isEmpty
                                      ? "動画再生中に表示される↓ボタンから保存できます。"
                                      : "検索語や選択中のフォルダを変更してください。")
                )
            } else {
                ForEach(items) { video in
                    SavedVideoRow(
                        video: video,
                        showFolderBadge: selectedFilter == .all,
                        onPlay: { playingVideo = video },
                        onRename: {
                            renameVideoInput = video.title
                            renamingVideo = video
                        },
                        onMove: { movingVideo = video },
                        onDelete: { downloads.delete(video) }
                    )
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            downloads.delete(video)
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
        } header: {
            HStack {
                Text("\(selectedFilter.title)（\(filteredVideos.count)件）")
                Spacer()
                Text(sortOrder.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            }
        }
    }

    private var filesAppGuidanceSection: some View {
        Section {
            Label {
                Text("MP4 / MOV / M4V 動画は、iOSの「ファイル」アプリ →「このiPhone内」→「ClipHarbor」→「Downloads」から直接開いたりPCへコピーしたりできます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "folder.badge.person.crop")
                    .foregroundStyle(.blue)
            }
        }
    }
}

// MARK: - ダウンロード行（現在速度・平均速度・残り時間・一時停止/再開・メトリクス内訳）

private struct DownloadJobRow: View {
    let job: DownloadJob
    let onPause: () -> Void
    let onResume: () -> Void
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Label(job.targetFolder.isEmpty ? "Downloads" : "Downloads/\(job.targetFolder)",
                              systemImage: "folder")
                        Text("· \(job.host)")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                actionButtons
            }

            switch job.state {
            case .preparing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("接続・準備中…")
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
                        .fontWeight(.medium)
                    Spacer()
                    if job.receivedBytes > 0 {
                        Text(byteProgressText)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if !job.isHLS {
                    HStack(spacing: 10) {
                        Label("現在 \(DownloadJob.formatSpeed(job.currentSpeedBytesPerSec))",
                              systemImage: "speedometer")
                            .foregroundStyle(.blue)
                        if job.averageSpeedBytesPerSec > 0 {
                            Text("平均 \(DownloadJob.formatSpeed(job.averageSpeedBytesPerSec))")
                        }
                        Spacer()
                        if let etaText = DownloadJob.formatETA(job.estimatedRemainingSeconds) {
                            Text(etaText)
                                .fontWeight(.medium)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

            case .paused(let progress):
                if let p = progress {
                    ProgressView(value: p)
                        .tint(.orange)
                }
                HStack {
                    Label(job.state.label, systemImage: "pause.circle.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    if job.receivedBytes > 0 {
                        Text(byteProgressText)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)

            case .completed:
                HStack {
                    Label("保存完了", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    if job.receivedBytes > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: job.receivedBytes, countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)

            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)

            case .cancelled:
                Label("キャンセルしました", systemImage: "slash.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let metrics = job.metrics, !metrics.summaryLine.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(metrics.summaryLine)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if let note = metrics.diagnosisNote {
                        Label(note, systemImage: "waveform.path.ecg")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 12) {
            if job.state.isActive {
                if job.canPause {
                    Button(action: onPause) {
                        Label("一時停止", systemImage: "pause.circle.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                }
                Button("中止", role: .destructive, action: onCancel)
                    .font(.caption)
                    .buttonStyle(.borderless)
            } else if job.state.isPaused {
                Button(action: onResume) {
                    Label("再開", systemImage: "play.circle.fill")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                Button("中止", role: .destructive, action: onCancel)
                    .font(.caption)
                    .buttonStyle(.borderless)
            } else {
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

    private var byteProgressText: String {
        let received = ByteCountFormatter.string(fromByteCount: job.receivedBytes, countStyle: .file)
        if job.expectedBytes > 0 {
            let total = ByteCountFormatter.string(fromByteCount: job.expectedBytes, countStyle: .file)
            return "\(received) / \(total)"
        }
        return received
    }
}

// MARK: - 保存済み動画行（サムネイル・メタ情報・操作メニュー）

private struct SavedVideoRow: View {
    let video: SavedVideo
    let showFolderBadge: Bool
    let onPlay: () -> Void
    let onRename: () -> Void
    let onMove: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onPlay) {
                SavedVideoThumbnailView(video: video)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 5) {
                Text(video.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)

                HStack(spacing: 6) {
                    if showFolderBadge {
                        Label(video.folderName.isEmpty ? "Downloads" : video.folderName,
                              systemImage: "folder")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.12), in: Capsule())
                            .foregroundStyle(.blue)
                    }
                    if let size = video.byteSize, size > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    }
                    if let host = video.sourceHost, !host.isEmpty {
                        Text("· \(host)")
                            .lineLimit(1)
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
                        Label("移動", systemImage: "folder")
                    }
                    .buttonStyle(.borderless)

                    if !video.isHLS && video.fileExists {
                        ShareLink(item: video.fileURL) {
                            Label("共有", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderless)
                    }

                    Menu {
                        Button(action: onRename) {
                            Label("名前を変更", systemImage: "pencil")
                        }
                        Button(action: onMove) {
                            Label("フォルダへ移動", systemImage: "folder")
                        }
                        if !video.isHLS && video.fileExists {
                            ShareLink(item: video.fileURL) {
                                Label("共有・ファイルへ書き出す", systemImage: "square.and.arrow.up")
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
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button(action: onPlay) {
                Label("再生", systemImage: "play.fill")
            }
            Button(action: onRename) {
                Label("名前を変更", systemImage: "pencil")
            }
            Button(action: onMove) {
                Label("フォルダへ移動", systemImage: "folder")
            }
            if !video.isHLS && video.fileExists {
                ShareLink(item: video.fileURL) {
                    Label("共有・ファイルへ書き出す", systemImage: "square.and.arrow.up")
                }
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label("削除", systemImage: "trash")
            }
        }
    }
}

// MARK: - フォルダ移動シート

private struct MoveVideoFolderSheet: View {
    let video: SavedVideo
    let folders: [String]
    let onMove: (String) -> Void
    let onCreateAndMove: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newFolderName = ""

    var body: some View {
        NavigationStack {
            List {
                Section("移動先フォルダを選択") {
                    Button {
                        dismiss()
                        onMove("")
                    } label: {
                        HStack {
                            Label("Downloads（標準）", systemImage: "folder")
                            Spacer()
                            if video.folderName.isEmpty {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }

                    ForEach(folders, id: \.self) { folder in
                        Button {
                            dismiss()
                            onMove(folder)
                        } label: {
                            HStack {
                                Label("Downloads / \(folder)", systemImage: "folder.fill")
                                Spacer()
                                if video.folderName == folder {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                }

                Section("新しいフォルダを作成して移動") {
                    HStack {
                        TextField("新しいフォルダ名", text: $newFolderName)
                        Button("作成して移動") {
                            let name = newFolderName
                            dismiss()
                            onCreateAndMove(name)
                        }
                        .disabled(FileNaming.sanitizedFolderName(newFolderName).isEmpty)
                    }
                }
            }
            .navigationTitle("「\(video.title)」を移動")
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

/// ClipHarbor独自の全画面動画プレイヤーシート（オフライン保存済み動画の再生用）。
struct OfflineVideoPlayerSheet: View {
    let video: SavedVideo
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            Group {
                if video.fileExists {
                    VideoPlayer(player: player)
                        .ignoresSafeArea(edges: .bottom)
                        .onAppear {
                            let avPlayer = AVPlayer(url: video.fileURL)
                            player = avPlayer
                            avPlayer.play()
                        }
                        .onDisappear {
                            player?.pause()
                            player = nil
                        }
                } else {
                    ContentUnavailableView(
                        "ファイルがありません",
                        systemImage: "exclamationmark.triangle",
                        description: Text("保存場所が変更されたか、OSによって消去された可能性があります。")
                    )
                }
            }
            .navigationTitle(video.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("閉じる") { dismiss() }
                }
                if !video.isHLS && video.fileExists {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: video.fileURL) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
    }
}
