import SwiftUI
import AVKit
import AVFoundation

/// Aloha風のローカルファイル管理＆ダウンロード進捗・速度計測・再生検証シート。
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

    // 検証・診断表示状態
    @State private var verifyingVideoIDs: Set<UUID> = []
    @State private var showStorageDiagnostics = false
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
                        Button {
                            verifyAllSavedVideos()
                        } label: {
                            Label("保存済み動画をすべて検証", systemImage: "checkmark.shield")
                        }
                        Button {
                            showStorageDiagnostics.toggle()
                        } label: {
                            Label("保存先・Info.plist診断を表示", systemImage: "stethoscope")
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
                OfflineVideoPlayerSheet(video: video, downloads: downloads)
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

    private func verifySingleVideo(_ video: SavedVideo) {
        guard !verifyingVideoIDs.contains(video.id) else { return }
        verifyingVideoIDs.insert(video.id)
        Task { @MainActor in
            _ = await downloads.verifySavedVideo(video.id)
            verifyingVideoIDs.remove(video.id)
        }
    }

    private func verifyAllSavedVideos() {
        let ids = downloads.saved.map(\.id)
        for id in ids { verifyingVideoIDs.insert(id) }
        Task { @MainActor in
            for id in ids {
                _ = await downloads.verifySavedVideo(id)
                verifyingVideoIDs.remove(id)
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
                        isVerifying: verifyingVideoIDs.contains(video.id),
                        onPlay: { playingVideo = video },
                        onVerify: { verifySingleVideo(video) },
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
        Section("保存場所のご案内と診断") {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text("MP4 / MOV / M4V 動画：iOSの「ファイル」アプリ →「このiPhone内」→「ClipHarbor」→「Downloads」に保存され、直接参照・共有できます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.blue)
                }

                Label {
                    Text("オフラインHLS（.movpkg）：AppleのAVFoundation仕様によりアプリ内の管理領域（Library）に保存されます。「ファイル」アプリには表示されませんが、この画面からフォルダ分類・再生・検証が可能です。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "play.square.stack.fill")
                        .foregroundStyle(.indigo)
                }
            }
            .padding(.vertical, 2)

            Button {
                showStorageDiagnostics.toggle()
            } label: {
                Label(
                    showStorageDiagnostics ? "保存先・Info.plist 診断を隠す" : "保存先・Info.plist 診断を表示",
                    systemImage: "stethoscope"
                )
                .font(.caption.weight(.semibold))
            }

            if showStorageDiagnostics {
                Text(downloads.storageDiagnosticSummary())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

// MARK: - ダウンロード行（現在速度・平均速度・残り時間・一時停止/再開・メトリクス・エラー診断）

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
                        Label(
                            job.isHLS
                                ? (job.targetFolder.isEmpty ? "アプリ内HLS領域" : "アプリ内HLS · \(job.targetFolder)")
                                : (job.targetFolder.isEmpty ? "Downloads" : "Downloads/\(job.targetFolder)"),
                            systemImage: job.isHLS ? "play.square.stack" : "folder"
                        )
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

            case .verifying:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("公開API（AVURLAsset / AVPlayerItem）で初期検証中…")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }

            case .completed:
                HStack {
                    Label("保存完了（初期検証済）", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    if job.receivedBytes > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: job.receivedBytes, countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)

            case .verificationIndeterminate(let note):
                Label("保存完了（非同期読み込み未確定）：\(note)", systemImage: "clock.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.blue)

            case .verificationFailed(let reason):
                Label("保存データを検証できません：\(reason)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)

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

            if let diag = job.diagnosticReport, !diag.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("通信・検証診断レポート", systemImage: "doc.text.magnifyingglass")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(diag)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
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

// MARK: - 保存済み動画行（サムネイル・保存場所・検証状態・操作メニュー）

private struct SavedVideoRow: View {
    let video: SavedVideo
    let isVerifying: Bool
    let onPlay: () -> Void
    let onVerify: () -> Void
    let onRename: () -> Void
    let onMove: () -> Void
    let onDelete: () -> Void

    @State private var showDiagnosticDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                Button(action: onPlay) {
                    SavedVideoThumbnailView(video: video)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 5) {
                    Text(video.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)

                    // 保存場所と実ファイル有無の明示
                    HStack(spacing: 6) {
                        Label(
                            video.storageLocationLabel,
                            systemImage: video.isHLS ? "internaldrive" : "folder.fill"
                        )
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background((video.isHLS ? Color.indigo : Color.blue).opacity(0.12), in: Capsule())
                        .foregroundStyle(video.isHLS ? .indigo : .blue)

                        if !video.fileExists {
                            Label("実データなし", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.red)
                        }
                    }

                    // 検証ステータスバッジ・サイズ・配信元
                    HStack(spacing: 6) {
                        verificationBadge

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

                    HStack(spacing: 14) {
                        Button(action: onPlay) {
                            Label("再生", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderless)

                        Button(action: onVerify) {
                            if isVerifying {
                                HStack(spacing: 4) {
                                    ProgressView().controlSize(.mini)
                                    Text("検証中")
                                }
                            } else {
                                Label("検証", systemImage: "checkmark.shield")
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(isVerifying)

                        Button(action: onMove) {
                            Label("分類/移動", systemImage: "folder")
                        }
                        .buttonStyle(.borderless)

                        if !video.isHLS && video.fileExists {
                            ShareLink(item: video.fileURL) {
                                Label("共有", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.borderless)
                        }

                        Menu {
                            Button(action: onPlay) {
                                Label("再生（プレイヤーを開く）", systemImage: "play.fill")
                            }
                            Button(action: onVerify) {
                                Label("再生可能性・時間を再検証", systemImage: "checkmark.shield")
                            }
                            switch video.verificationState {
                            case .failed, .indeterminate:
                                Button {
                                    showDiagnosticDetail.toggle()
                                } label: {
                                    Label(showDiagnosticDetail ? "検証詳細を隠す" : "検証詳細を表示",
                                          systemImage: "doc.text.magnifyingglass")
                                }
                            case .unverified, .verified:
                                EmptyView()
                            }
                            Divider()
                            Button(action: onRename) {
                                Label(video.isHLS ? "表示名を変更" : "ファイル名を変更", systemImage: "pencil")
                            }
                            Button(action: onMove) {
                                Label(video.isHLS ? "アプリ内フォルダ分類を変更" : "保存先フォルダへ移動", systemImage: "folder")
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

            if case .failed(let reason, let detail) = video.verificationState {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label("保存データを検証できません：\(reason)", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                        Spacer()
                        Button(showDiagnosticDetail ? "閉じる" : "詳細") {
                            showDiagnosticDetail.toggle()
                        }
                        .font(.caption2)
                        .buttonStyle(.borderless)
                    }
                    if showDiagnosticDetail {
                        Text(detail)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
            } else if case .indeterminate(let note, let detail) = video.verificationState {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label("非同期読み込み未確定：\(note)", systemImage: "clock.badge.exclamationmark")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.blue)
                        Spacer()
                        Button(showDiagnosticDetail ? "閉じる" : "詳細") {
                            showDiagnosticDetail.toggle()
                        }
                        .font(.caption2)
                        .buttonStyle(.borderless)
                    }
                    if showDiagnosticDetail {
                        Text(detail)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button(action: onPlay) {
                Label("再生", systemImage: "play.fill")
            }
            Button(action: onVerify) {
                Label("再生可能性を再検証", systemImage: "checkmark.shield")
            }
            Button(action: onRename) {
                Label(video.isHLS ? "表示名を変更" : "名前を変更", systemImage: "pencil")
            }
            Button(action: onMove) {
                Label(video.isHLS ? "フォルダ分類を変更" : "フォルダへ移動", systemImage: "folder")
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

    @ViewBuilder
    private var verificationBadge: some View {
        switch video.verificationState {
        case .verified(let sec):
            Label("初期検証済 \(VideoVerificationState.formatDuration(sec))", systemImage: "checkmark.circle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.green)
        case .indeterminate:
            Label("読込未確定", systemImage: "clock.badge.exclamationmark")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.blue)
        case .unverified:
            Label("未検証", systemImage: "questionmark.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .failed:
            Label("検証エラー", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
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
                Section {
                    Button {
                        dismiss()
                        onMove("")
                    } label: {
                        HStack {
                            Label(video.isHLS ? "未分類（標準）" : "Downloads（標準）", systemImage: "folder")
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
                                Label(video.isHLS ? folder : "Downloads / \(folder)", systemImage: "folder.fill")
                                Spacer()
                                if video.folderName == folder {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                } header: {
                    Text(video.isHLS ? "アプリ内の分類フォルダを選択" : "移動先フォルダを選択")
                } footer: {
                    if video.isHLS {
                        Text("オフラインHLSパッケージ（.movpkg）はApple指定場所から移動せず、アプリ内の分類メタデータのみ変更します。")
                    } else {
                        Text("選択した Documents / Downloads 配下のフォルダへ実ファイルを移動します。")
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

/// ClipHarbor独自の全画面動画プレイヤーシート（オフライン保存済み動画の再生＆リアルタイム診断用）。
struct OfflineVideoPlayerSheet: View {
    let video: SavedVideo
    @ObservedObject var downloads: DownloadCenter
    @Environment(\.dismiss) private var dismiss

    @State private var player: AVPlayer?
    @State private var statusObservation: NSKeyValueObservation?
    @State private var playerDiagnostic: String?
    @State private var isRunningDeepVerify = false
    @State private var showDiagnosticsPanel = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if video.fileExists {
                    VideoPlayer(player: player)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)
                        .onAppear {
                            startPlaybackAndMonitor()
                        }
                        .onDisappear {
                            cleanupPlayer()
                        }
                } else {
                    ContentUnavailableView(
                        "ファイルがありません",
                        systemImage: "exclamationmark.triangle",
                        description: Text("保存場所が変更されたか、OSによって消去された可能性があります。\n想定パス: \(video.relativePath)")
                    )
                }

                if let diag = playerDiagnostic, showDiagnosticsPanel {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label("再生・アセット検証診断（黒画面 / --:-- 解析）",
                                      systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.orange)
                                Spacer()
                                if isRunningDeepVerify {
                                    ProgressView().controlSize(.mini)
                                }
                                Button("閉じる") {
                                    showDiagnosticsPanel = false
                                }
                                .font(.caption)
                            }
                            Text(diag)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(12)
                    }
                    .frame(maxHeight: 220)
                    .background(.regularMaterial)
                }
            }
            .navigationTitle(video.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        runDeepVerification()
                    } label: {
                        Label("再生検証", systemImage: "stethoscope")
                    }
                    if !video.isHLS && video.fileExists {
                        ShareLink(item: video.fileURL) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
    }

    private func startPlaybackAndMonitor() {
        let targetURL = video.fileURL
        let asset = AVURLAsset(url: targetURL)
        let item = AVPlayerItem(asset: asset)
        let avPlayer = AVPlayer(playerItem: item)
        player = avPlayer

        statusObservation = item.observe(\.status, options: [.initial, .new]) { observedItem, _ in
            DispatchQueue.main.async {
                switch observedItem.status {
                case .readyToPlay:
                    let dur = observedItem.duration
                    if !dur.isNumeric || dur.isIndefinite || dur.seconds <= 0 {
                        self.runDeepVerification()
                    }
                case .failed:
                    let errText = observedItem.error.map { ErrorChainFormatter.describe($0) } ?? "不明な再生エラー"
                    let logText = MediaPlayabilityVerifier.summarizeErrorLog(observedItem.errorLog())
                    var msg = "AVPlayerItem.status = .failed\nエラー: \(errText)"
                    if let logText = logText {
                        msg += "\nErrorLog: \(logText)"
                    }
                    self.playerDiagnostic = msg
                    self.showDiagnosticsPanel = true
                    self.runDeepVerification()
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }

        avPlayer.play()

        // 以前「検証エラー / 読込未確定」だった動画や、2.5秒経過しても再生時間が不明(--:--)の場合は自動的に詳細診断を実行する
        switch video.verificationState {
        case .failed(_, let detail), .indeterminate(_, let detail):
            playerDiagnostic = detail
            showDiagnosticsPanel = true
        case .unverified, .verified:
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard let currentItem = player?.currentItem else { return }
                let dur = currentItem.duration
                if currentItem.status != .readyToPlay || !dur.isNumeric || dur.isIndefinite || dur.seconds <= 0 {
                    runDeepVerification()
                }
            }
        }
    }

    private func runDeepVerification() {
        guard !isRunningDeepVerify else { return }
        isRunningDeepVerify = true
        showDiagnosticsPanel = true
        if playerDiagnostic == nil {
            playerDiagnostic = "アセットの再生可能性（isPlayable / duration / tracks / ErrorLog）を検査しています…"
        }
        Task { @MainActor in
            if let result = await downloads.verifySavedVideo(video.id) {
                playerDiagnostic = result.detailedReport
                if !result.isVerifiedPlayable {
                    showDiagnosticsPanel = true
                }
            }
            isRunningDeepVerify = false
        }
    }

    private func cleanupPlayer() {
        statusObservation?.invalidate()
        statusObservation = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }
}
