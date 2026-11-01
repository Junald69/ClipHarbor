import SwiftUI
import AVKit

/// ダウンロードボタンを押したときに表示する、ネイティブのファイル名入力・保存形式選択・保存先フォルダ選択・保存確認シート。
/// - HLS候補：「オフラインHLS」（既定・従来のDownloadCenter）と「MP4として保存」（VideoExportManager）を選択できる。
/// - 動画ファイル候補：従来どおりDownloadCenterで直接保存する（保存形式の選択はない）。
struct SaveVideoSheet: View {
    /// HLS候補の保存方式
    enum SaveFormat: Hashable {
        case offlineHLS
        case mp4
    }

    /// MP4互換性判定の表示状態
    enum ProbeState: Equatable {
        case idle
        case checking
        case finished(VideoExportManager.MP4Compatibility)
    }

    let candidate: MediaCandidate
    let existingFolders: [String]
    /// 従来の保存（HLSはオフラインHLS、動画ファイルは直接保存）。DownloadCenterを使用する。
    let onConfirm: (String, String) -> Void
    /// 「MP4として保存」を選んだ場合の開始処理。VideoExportManagerを使用する。
    var onConfirmMP4: ((String, String) -> Void)? = nil
    /// MP4互換性の事前判定（プレイリストと初期化セグメントのみ取得。変換・保存は行わない）
    var mp4Probe: (() async -> VideoExportManager.MP4Compatibility)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var videoName: String
    @State private var selectedFolder: String = ""
    @State private var isCreatingNewFolder = false
    @State private var newFolderName: String = ""
    @State private var saveFormat: SaveFormat = .offlineHLS
    @State private var probeState: ProbeState = .idle
    @State private var probeRunID = 0
    @State private var didConfirm = false
    @FocusState private var nameFocused: Bool

    init(
        candidate: MediaCandidate,
        existingFolders: [String] = [],
        onConfirm: @escaping (String, String) -> Void,
        onConfirmMP4: ((String, String) -> Void)? = nil,
        mp4Probe: (() async -> VideoExportManager.MP4Compatibility)? = nil
    ) {
        self.candidate = candidate
        self.existingFolders = existingFolders
        self.onConfirm = onConfirm
        self.onConfirmMP4 = onConfirmMP4
        self.mp4Probe = mp4Probe
        _videoName = State(initialValue: candidate.suggestedName)
    }

    // MARK: - 派生値

    /// HLS候補で、MP4保存の開始処理と互換性判定の両方が提供されている場合のみ形式選択を表示する
    private var offersMP4Option: Bool {
        candidate.isHLS && onConfirmMP4 != nil && mp4Probe != nil
    }

    private var effectiveFormat: SaveFormat {
        offersMP4Option ? saveFormat : .offlineHLS
    }

    private var isMP4Selected: Bool {
        candidate.isHLS && effectiveFormat == .mp4
    }

    private var compatibilityDetail: VideoExportManager.MP4CompatibilityDetail? {
        if case .finished(.compatible(let detail)) = probeState { return detail }
        return nil
    }

    /// MP4保存は「互換性あり」と判定できた場合だけ開始できる（未判定・判定不能・非対応では開始しない）
    private var canStart: Bool {
        if didConfirm { return false }
        if candidate.isHLS { return false } // HLS形式の保存は一時停止
        if isMP4Selected { return compatibilityDetail != nil }
        return true
    }

    private var sanitizedName: String {
        let s = FileNaming.sanitizedBaseName(videoName)
        return s.isEmpty ? "Video" : s
    }

    private var resolvedFolderName: String {
        if isCreatingNewFolder {
            return VideoFolderManager.sanitizedFolderName(newFolderName)
        }
        return VideoFolderManager.sanitizedFolderName(selectedFolder)
    }

    private var previewFilename: String {
        if isMP4Selected {
            return "\(sanitizedName).mp4"
        }
        if let ext = candidate.expectedExtension {
            return "\(sanitizedName).\(ext)"
        }
        return sanitizedName
    }

    private var formatDisplayLabel: String {
        isMP4Selected ? NSLocalizedString("MP4 (Converted from HLS)", comment: "") : candidate.formatLabel
    }

        private var isBackgroundCandidate: Bool {
        guard candidate.url.scheme?.lowercased() == "https", !candidate.isHLS else { return false }
        switch candidate.kind {
        case .file(let type):
            switch type {
            case .mp4, .m4v, .mov, .webm: return true
            case .unknown:
                let ext = candidate.url.pathExtension.lowercased()
                return ["mp4", "m4v", "mov", "webm", "m4a", "mp3"].contains(ext)
            }
        case .hls:
            return false
        }
    }

    private var destinationLabel: String {
        let filesPath = resolvedFolderName.isEmpty
            ? "ClipHarbor / Documents / Downloads"
            : "ClipHarbor / Documents / Downloads / \(resolvedFolderName)"
        if candidate.isHLS && !isMP4Selected {
            return resolvedFolderName.isEmpty
                ? NSLocalizedString("In ClipHarbor (Offline HLS)", comment: "")
                : String(format: NSLocalizedString("In ClipHarbor (Offline HLS) · In-app folder \"%@\"", comment: ""), resolvedFolderName)
        }
        return filesPath
    }

    private var startButtonTitle: String {
        if candidate.isHLS {
            return NSLocalizedString("Download Unsupported", comment: "")
        }
        return isMP4Selected ? NSLocalizedString("Start Saving as MP4", comment: "") : NSLocalizedString("Download", comment: "")
    }

    // MARK: - 画面

    var body: some View {
        NavigationStack {
            Form {
                if candidate.isHLS {
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(NSLocalizedString("HLS streaming format is currently not supported for download.", comment: ""))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(NSLocalizedString("Please enjoy playback directly within the browser.", comment: ""))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section("Video Name") {
                    HStack {
                        TextField("Enter video title", text: $videoName)
                            .focused($nameFocused)
                            .submitLabel(.done)
                        if !videoName.isEmpty {
                            Button {
                                videoName = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Clear text"))
                        }
                    }
                    LabeledContent(NSLocalizedString("Save Name Preview", comment: ""), value: previewFilename)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if offersMP4Option {
                    Section {
                        Picker("Save Format", selection: $saveFormat) {
                            Text("Offline HLS").tag(SaveFormat.offlineHLS)
                            Text("MP4").tag(SaveFormat.mp4)
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        Text("Save Format")
                    } footer: {
                        Text(isMP4Selected
                             ? NSLocalizedString("Fetches video and audio to create an MP4 file. Saved only if quality verification passes, accessible from the \"Files\" app. Please keep ClipHarbor open during conversion.", comment: "")
                             : NSLocalizedString("Saves in Apple's standard offline format (recommended standard method). Playable within ClipHarbor.", comment: ""))
                    }
                }

                Section("Destination Folder") {
                    if !isCreatingNewFolder {
                        Picker("Folder", selection: $selectedFolder) {
                            Text("Downloads (Standard)").tag("")
                            ForEach(existingFolders, id: \.self) { folder in
                                Text(folder).tag(folder)
                            }
                        }
                        Button {
                            isCreatingNewFolder = true
                        } label: {
                            Label("Create New Folder and Save", systemImage: "folder.badge.plus")
                                .font(.subheadline)
                        }
                    } else {
                        HStack {
                            Image(systemName: "folder.badge.plus")
                                .foregroundStyle(.blue)
                            TextField("New Folder Name", text: $newFolderName)
                            Button("Choose from List") {
                                isCreatingNewFolder = false
                                newFolderName = ""
                            }
                            .font(.caption)
                        }
                    }
                }

                if offersMP4Option {
                    mp4CompatibilitySection
                }

                Section("Save Info") {
                    LabeledContent(NSLocalizedString("Save Format", comment: ""), value: formatDisplayLabel)
                    if isBackgroundCandidate {
                        LabeledContent(NSLocalizedString("Download Mode", comment: ""), value: NSLocalizedString("Background", comment: ""))
                    }
                    LabeledContent(NSLocalizedString("Source", comment: ""), value: candidate.host)
                    LabeledContent(NSLocalizedString("Save Destination", comment: ""), value: destinationLabel)
                    if isBackgroundCandidate {
                        Text(NSLocalizedString("This file will continue downloading even if the screen is locked or the app is closed.", comment: ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !isMP4Selected, let note = candidate.formatNote {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        startSelectedSave()
                    } label: {
                        HStack {
                            Spacer()
                            Label(startButtonTitle, systemImage: isMP4Selected ? "film.stack" : "arrow.down.circle.fill")
                                .font(.headline)
                            Spacer()
                        }
                    }
                    .disabled(!canStart)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if isMP4Selected && compatibilityDetail == nil {
                            Text("Cannot start saving as MP4 because conversion compatibility could not be verified. Please select \"Offline HLS\".")
                                .foregroundStyle(.orange)
                        }
                        Text("Please only save videos with the copyright holder's permission. Depending on access restrictions or expiration of the stream, saving may not be possible.")
                    }
                }
            }
            .navigationTitle(Text("Save Video"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isMP4Selected ? NSLocalizedString("Save as MP4", comment: "") : NSLocalizedString("Download", comment: "")) {
                        startSelectedSave()
                    }
                    .fontWeight(.semibold)
                    .disabled(!canStart)
                }
            }
            .task(id: probeRunID) {
                await runProbeIfNeeded()
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - MP4互換性判定セクション

    @ViewBuilder
    private var mp4CompatibilitySection: some View {
        Section {
            switch probeState {
            case .idle, .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking playlist and initialization segments…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .finished(let result):
                switch result {
                case .compatible(let detail):
                    Label("Compatible with MP4 conversion", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                    Text(compatibilitySummary(detail))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .incompatible(let reason):
                    Label("Not eligible for MP4 conversion", systemImage: "xmark.octagon.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .undetermined(let reason):
                    Label("Could not determine compatibility", systemImage: "questionmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        probeState = .idle
                        probeRunID += 1
                    } label: {
                        Label("Re-evaluate", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                    }
                }
            }
        } header: {
            Text("MP4 Compatibility Check")
        } footer: {
            Text("Target is unencrypted VOD fMP4 HLS (unified or separate audio). Even if check passes, saving will not complete until converted quality verification succeeds. Encrypted, DRM, live streams, and MPEG-TS are not eligible for MP4 conversion.")
        }
    }

    private func compatibilitySummary(_ detail: VideoExportManager.MP4CompatibilityDetail) -> String {
        let structure = detail.isSeparateAudio ? NSLocalizedString("Separate Audio fMP4", comment: "") : NSLocalizedString("Unified Video/Audio fMP4", comment: "")
        let audio = detail.audioCodec ?? NSLocalizedString("No Audio", comment: "")
        let segments = detail.isSeparateAudio
            ? String(format: NSLocalizedString("Video %lld · Audio %lld segments", comment: ""), detail.videoSegmentCount, detail.audioSegmentCount)
            : String(format: NSLocalizedString("%lld segments", comment: ""), detail.videoSegmentCount)
        return String(
            format: NSLocalizedString("%@ · Video %@ / Audio %@ · ~%.0fs · %@", comment: ""),
            structure,
            detail.videoCodec,
            audio,
            detail.durationSeconds,
            segments
        )
    }

    // MARK: - 処理

    private func runProbeIfNeeded() async {
        guard offersMP4Option, let probe = mp4Probe else { return }
        if case .finished = probeState { return }
        probeState = .checking
        let result = await probe()
        guard !Task.isCancelled else { return }
        probeState = .finished(result)
    }

    private func startSelectedSave() {
        guard canStart else { return }
        didConfirm = true
        let finalName = sanitizedName
        let finalFolder = resolvedFolderName
        let useMP4 = isMP4Selected
        dismiss()
        if useMP4, let onConfirmMP4 {
            onConfirmMP4(finalName, finalFolder)
        } else {
            onConfirm(finalName, finalFolder)
        }
    }
}

/// 再生中の動画を1つに特定できない場合や、複数候補から選ぶためのフォールバック一覧シート。
struct CandidateListSheet: View {
    @ObservedObject var browser: BrowserModel
    let onSelectCandidate: (MediaCandidate) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedInfoRow: BrowserModel.CandidateRow?

    var body: some View {
        NavigationStack {
            List {
                if browser.selection.isAmbiguous {
                    Section {
                        Label(NSLocalizedString("Multiple videos detected simultaneously. Please select the video you want to save.", comment: ""),
                              systemImage: "film.stack")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                let rows = browser.candidateRows
                if rows.isEmpty {
                    ContentUnavailableView(
                        NSLocalizedString("No videos detected", comment: ""),
                        systemImage: "video.slash",
                        description: Text("When you play a video on the page, savable candidates will appear here.")
                    )
                } else {
                    Section("Detected Videos & Media") {
                        ForEach(rows) { row in
                            CandidateRowView(
                                row: row,
                                onSelect: { candidate in
                                    dismiss()
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                        onSelectCandidate(candidate)
                                    }
                                },
                                onShowInfo: { infoRow in
                                    selectedInfoRow = infoRow
                                }
                            )
                        }
                    }
                }
            }
            .navigationTitle(Text("Video Candidates"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
            .alert(
                selectedInfoRow?.unsupportedTitle ?? NSLocalizedString("Format Information", comment: ""),
                isPresented: Binding(
                    get: { selectedInfoRow != nil },
                    set: { if !$0 { selectedInfoRow = nil } }
                )
            ) {
                Button("OK", role: .cancel) {
                    selectedInfoRow = nil
                }
            } message: {
                Text(selectedInfoRow?.unsupportedMessage ?? "")
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct CandidateRowView: View {
    let row: BrowserModel.CandidateRow
    let onSelect: (MediaCandidate) -> Void
    let onShowInfo: (BrowserModel.CandidateRow) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            thumbnail
                .frame(width: 52, height: 36)
                .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 5) {
                    formatBadgeView

                    if row.isPlaying {
                        Text(NSLocalizedString("Playing", comment: ""))
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.blue.opacity(0.12), in: Capsule())
                            .foregroundStyle(.blue)
                    }

                    Text(row.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 4)

            if row.isDownloadable, let candidate = row.candidate {
                Button {
                    onSelect(candidate)
                } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.blue)
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Save Video"))
            } else {
                Button {
                    onShowInfo(row)
                } label: {
                    Image(systemName: "info.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Format Information"))
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            if row.isDownloadable, let candidate = row.candidate {
                onSelect(candidate)
            } else {
                onShowInfo(row)
            }
        }
    }

    @ViewBuilder
    private var formatBadgeView: some View {
        let color: Color = {
            switch row.formatBadge {
            case "MP4", "MOV", "M4V":
                return .blue
            case "HLS":
                return .orange
            case "Blob / MSE":
                return .purple
            case "WebM":
                return .teal
            default:
                return .secondary
            }
        }()

        Text(row.formatBadge)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(color)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let posterURL = row.posterURL {
            AsyncImage(url: posterURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    fallbackThumbnailIcon
                }
            }
        } else {
            fallbackThumbnailIcon
        }
    }

    private var fallbackThumbnailIcon: some View {
        Image(systemName: row.isDownloadable ? "film" : "play.tv")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

extension BrowserModel.CandidateRow {
    var unsupportedTitle: String {
        switch formatBadge {
        case "HLS":
            return NSLocalizedString("HLS Streaming", comment: "")
        case "Blob / MSE":
            return NSLocalizedString("Blob / MSE Streaming", comment: "")
        case "DRM":
            return NSLocalizedString("Protected Content", comment: "")
        default:
            return NSLocalizedString("Format Information", comment: "")
        }
    }

    var unsupportedMessage: String {
        if candidate?.isHLS == true || formatBadge == "HLS" {
            return String(format: "%@ %@",
                          NSLocalizedString("HLS streaming format is currently not supported for download.", comment: ""),
                          NSLocalizedString("Please enjoy playback directly within the browser.", comment: ""))
        }
        if let reason = reason, !reason.isEmpty {
            return reason
        }
        return String(format: "%@ %@",
                      NSLocalizedString("Videos using this playback method cannot be saved.", comment: ""),
                      NSLocalizedString("Please enjoy playback directly within the browser.", comment: ""))
    }
}

/// ダウンロードの進捗管理と、保存済み動画の再生・共有・削除を行うシート。
struct DownloadLibrarySheet: View {
    @ObservedObject var downloads: DownloadCenter
    @Environment(\.dismiss) private var dismiss
    @State private var playingVideo: SavedVideo?

    var body: some View {
        NavigationStack {
            List {
                if !downloads.jobs.isEmpty {
                    Section("Download Status") {
                        ForEach(downloads.jobs) { job in
                            DownloadJobRow(
                                job: job,
                                onCancel: { downloads.cancel(job.id) },
                                onRetry: { downloads.retry(job.id) },
                                onDismiss: { downloads.dismissJob(job.id) }
                            )
                        }
                    }
                }

                Section("Saved Videos") {
                    if downloads.saved.isEmpty {
                        ContentUnavailableView(
                            NSLocalizedString("No saved videos", comment: ""),
                            systemImage: "square.and.arrow.down",
                            description: Text("You can save videos using the download button shown while playing videos.")
                        )
                    } else {
                        ForEach(downloads.saved) { video in
                            SavedVideoRow(video: video) {
                                playingVideo = video
                            }
                        }
                        .onDelete { indices in
                            let targets = indices.map { downloads.saved[$0] }
                            for item in targets { downloads.delete(item) }
                        }
                    }
                }
            }
            .navigationTitle(Text("Download"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
            .fullScreenCover(item: $playingVideo) { video in
                OfflineVideoPlayerSheet(video: video)
            }
        }
    }
}

private struct DownloadJobRow: View {
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
                    Button("Cancel", role: .destructive, action: onCancel)
                        .font(.caption)
                        .buttonStyle(.borderless)
                } else {
                    HStack(spacing: 12) {
                        if job.canRetry {
                            Button("Retry", action: onRetry)
                                .font(.caption.weight(.semibold))
                                .buttonStyle(.borderless)
                        }
                        Button(action: onDismiss) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Dismiss from History"))
                    }
                }
            }

            switch job.state {
            case .preparing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(String(format: NSLocalizedString("Preparing… (%@)", comment: ""), job.host))
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
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            case .cancelled:
                Label("Cancelled", systemImage: "slash.circle")
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

private struct SavedVideoRow: View {
    let video: SavedVideo
    let onPlay: () -> Void

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
                if let size = video.byteSize, size > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                }
                if let host = video.sourceHost, !host.isEmpty {
                    Text("· \(host)")
                }
                Text("· \(video.createdAt.formatted(date: .abbreviated, time: .shortened))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 20) {
                Button(action: onPlay) {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(.borderless)

                if !video.isHLS && video.fileExists {
                    ShareLink(item: video.fileURL) {
                        Label("Share / Export", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                } else if video.isHLS {
                    Text("App Playback Only (HLS)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }
}

/// ClipHarbor独自の全画面動画プレイヤーシート（オフライン保存済み動画の再生用）。
/// - ModernVideoPlayerView を使用したAloha風プレイヤーへのブリッジ
/// - @StateObject でプレイリストコンテキストを保持し、再描画時のリセットを防止
struct OfflineVideoPlayerSheet: View {
    @StateObject private var playlistContext: PlaybackPlaylistContext
    @Environment(\.dismiss) private var dismiss

    init(video: SavedVideo, playlist: [SavedVideo] = [], folderTitle: String = NSLocalizedString("Saved Files", comment: "")) {
        let videos = playlist.isEmpty ? [video] : playlist
        _playlistContext = StateObject(wrappedValue: PlaybackPlaylistContext(
            normalVideos: videos,
            initialVideo: video,
            folderTitle: folderTitle
        ))
    }

    var body: some View {
        ModernVideoPlayerView(playlistContext: playlistContext) {
            dismiss()
        }
    }
}
