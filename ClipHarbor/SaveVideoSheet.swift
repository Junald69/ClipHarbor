import SwiftUI
import AVKit

/// ダウンロードボタンを押したときに表示する、ネイティブのファイル名入力・保存先フォルダ選択・保存確認シート。
struct SaveVideoSheet: View {
    let candidate: MediaCandidate
    let existingFolders: [String]
    let onConfirm: (String, String) -> Void
    var onStartFMP4ExportPoC: ((String, String) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var videoName: String
    @State private var selectedFolder: String = ""
    @State private var isCreatingNewFolder = false
    @State private var newFolderName: String = ""
    @FocusState private var nameFocused: Bool

    init(
        candidate: MediaCandidate,
        existingFolders: [String] = [],
        onConfirm: @escaping (String, String) -> Void,
        onStartFMP4ExportPoC: ((String, String) -> Void)? = nil
    ) {
        self.candidate = candidate
        self.existingFolders = existingFolders
        self.onConfirm = onConfirm
        self.onStartFMP4ExportPoC = onStartFMP4ExportPoC
        _videoName = State(initialValue: candidate.suggestedName)
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
        if let ext = candidate.expectedExtension {
            return "\(sanitizedName).\(ext)"
        }
        return sanitizedName
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("動画名") {
                    HStack {
                        TextField("動画名を入力", text: $videoName)
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
                            .accessibilityLabel("入力をクリア")
                        }
                    }
                    LabeledContent("保存名プレビュー", value: previewFilename)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("保存先フォルダ") {
                    if !isCreatingNewFolder {
                        Picker("フォルダ", selection: $selectedFolder) {
                            Text("Downloads（標準）").tag("")
                            ForEach(existingFolders, id: \.self) { folder in
                                Text(folder).tag(folder)
                            }
                        }
                        Button {
                            isCreatingNewFolder = true
                        } label: {
                            Label("新規フォルダを作成して保存", systemImage: "folder.badge.plus")
                                .font(.subheadline)
                        }
                    } else {
                        HStack {
                            Image(systemName: "folder.badge.plus")
                                .foregroundStyle(.blue)
                            TextField("新しいフォルダ名", text: $newFolderName)
                            Button("一覧から選ぶ") {
                                isCreatingNewFolder = false
                                newFolderName = ""
                            }
                            .font(.caption)
                        }
                    }
                }

                Section("保存情報") {
                    LabeledContent("保存形式", value: candidate.formatLabel)
                    LabeledContent("配信元", value: candidate.host)
                    LabeledContent(
                        "保存先",
                        value: candidate.isHLS
                            ? "ClipHarbor内（オフラインHLS）"
                            : (resolvedFolderName.isEmpty
                                ? "ClipHarbor / Documents / Downloads"
                                : "ClipHarbor / Documents / Downloads / \(resolvedFolderName)")
                    )
                    if let note = candidate.formatNote {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        let finalName = sanitizedName
                        let finalFolder = resolvedFolderName
                        dismiss()
                        onConfirm(finalName, finalFolder)
                    } label: {
                        HStack {
                            Spacer()
                            Label("ダウンロード", systemImage: "arrow.down.circle.fill")
                                .font(.headline)
                            Spacer()
                        }
                    }
                } footer: {
                    Text("権利者の許可がある動画のみ保存してください。配信元のアクセス制限や有効期限によっては保存できない場合があります。")
                }

                if candidate.isHLS, let onStartFMP4ExportPoC {
                    Section {
                        Button {
                            let finalName = sanitizedName
                            let finalFolder = resolvedFolderName
                            dismiss()
                            onStartFMP4ExportPoC(finalName, finalFolder)
                        } label: {
                            HStack {
                                Spacer()
                                Label("fMP4→MP4変換を試す（PoC検証）", systemImage: "film.stack")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                            }
                        }
                    } header: {
                        Text("MP4変換テスト（Phase 2：単一＆分離音声fMP4対応）")
                    } footer: {
                        Text("非暗号化fMP4形式のVOD HLS（単一ストリームおよび #EXT-X-MEDIA:TYPE=AUDIO 分離音声）から映像と音声を取得・同期・結合してMP4を生成し、品質検証に合格した場合のみDocuments/Downloadsへ保存します。非対応形式（MPEG-TS・暗号化HLS等）の場合は理由を表示します。通常の確実な保存は上の「ダウンロード」を使用してください。")
                    }
                }
            }
            .navigationTitle("動画を保存")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("ダウンロード") {
                        let finalName = sanitizedName
                        let finalFolder = resolvedFolderName
                        dismiss()
                        onConfirm(finalName, finalFolder)
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// 再生中の動画を1つに特定できない場合や、複数候補から選ぶためのフォールバック一覧シート。
struct CandidateListSheet: View {
    @ObservedObject var browser: BrowserModel
    let onSelectCandidate: (MediaCandidate) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if browser.selection.isAmbiguous {
                    Section {
                        Label("複数の動画が同時に検出されています。保存したい動画を選択してください。",
                              systemImage: "film.stack")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                let rows = browser.candidateRows
                if rows.isEmpty {
                    ContentUnavailableView(
                        "検出された動画はありません",
                        systemImage: "video.slash",
                        description: Text("ページ内で動画を再生すると、保存可能な候補がここに表示されます。")
                    )
                } else {
                    Section("検出された動画・メディア") {
                        ForEach(rows) { row in
                            CandidateRowView(row: row) { candidate in
                                dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                    onSelectCandidate(candidate)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("動画の候補一覧")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct CandidateRowView: View {
    let row: BrowserModel.CandidateRow
    let onSelect: (MediaCandidate) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail
                .frame(width: 64, height: 44)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let stateLabel = row.stateLabel {
                        Text(stateLabel)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(row.isPlaying ? Color.blue.opacity(0.18) : Color.secondary.opacity(0.15),
                                        in: Capsule())
                            .foregroundStyle(row.isPlaying ? .blue : .secondary)
                    }
                    Text(row.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                }

                Text(row.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let reason = row.reason, row.candidate == nil {
                    Label(reason, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 4)

            if let candidate = row.candidate {
                Button {
                    onSelect(candidate)
                } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.blue)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("この動画を保存")
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let posterURL = row.posterURL {
            AsyncImage(url: posterURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    Image(systemName: "film").foregroundStyle(.secondary)
                }
            }
        } else {
            Image(systemName: row.candidate != nil ? "film" : "video.slash")
                .foregroundStyle(.secondary)
        }
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
                    Section("ダウンロード状況") {
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

                Section("保存済み動画") {
                    if downloads.saved.isEmpty {
                        ContentUnavailableView(
                            "保存した動画はありません",
                            systemImage: "square.and.arrow.down",
                            description: Text("動画再生中に表示される↓ボタンから保存できます。")
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
            .navigationTitle("ダウンロード")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
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
                    Label("再生", systemImage: "play.fill")
                }
                .buttonStyle(.borderless)

                if !video.isHLS && video.fileExists {
                    ShareLink(item: video.fileURL) {
                        Label("共有・書き出し", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                } else if video.isHLS {
                    Text("アプリ内再生専用（HLS）")
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
