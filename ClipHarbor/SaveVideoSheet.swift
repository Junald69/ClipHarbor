import SwiftUI

/// ダウンロードボタンを押したときに表示する、ネイティブのファイル名・保存先フォルダ入力シート。
struct SaveVideoSheet: View {
    let candidate: MediaCandidate
    @ObservedObject var downloads: DownloadCenter
    let onConfirm: (_ chosenName: String, _ folderName: String, _ pauseWebPlayback: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var videoName: String
    @State private var selectedFolder: String = ""
    @State private var pauseWebPlayback: Bool = true
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""
    @FocusState private var nameFocused: Bool

    init(
        candidate: MediaCandidate,
        downloads: DownloadCenter = .shared,
        onConfirm: @escaping (_ chosenName: String, _ folderName: String, _ pauseWebPlayback: Bool) -> Void
    ) {
        self.candidate = candidate
        self.downloads = downloads
        self.onConfirm = onConfirm
        _videoName = State(initialValue: candidate.suggestedName)
    }

    private var sanitizedName: String {
        let s = FileNaming.sanitizedBaseName(videoName)
        return s.isEmpty ? "Video" : s
    }

    private var previewFilename: String {
        if let ext = candidate.expectedExtension {
            return "\(sanitizedName).\(ext)"
        }
        return sanitizedName
    }

    private var destinationDescription: String {
        if candidate.isHLS {
            return selectedFolder.isEmpty
                ? "ClipHarbor内（オフラインHLS）"
                : "ClipHarbor内（オフラインHLS · フォルダ: \(selectedFolder)）"
        }
        return selectedFolder.isEmpty
            ? "ClipHarbor / Documents / Downloads"
            : "ClipHarbor / Documents / Downloads / \(selectedFolder)"
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
                    Picker("フォルダ", selection: $selectedFolder) {
                        Text("Downloads（標準）").tag("")
                        ForEach(downloads.folders, id: \.self) { folder in
                            Text("Downloads / \(folder)").tag(folder)
                        }
                    }
                    Button {
                        newFolderName = ""
                        showNewFolderAlert = true
                    } label: {
                        Label("新しいフォルダを作成…", systemImage: "folder.badge.plus")
                            .font(.subheadline)
                    }
                }

                Section("高速化オプション") {
                    Toggle("保存開始時にページの再生を一時停止", isOn: $pauseWebPlayback)
                    Text("再生中の動画ストリームによる帯域・接続枠の競合を防ぎ、ダウンロード速度を優先します。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("保存情報") {
                    LabeledContent("保存形式", value: candidate.formatLabel)
                    LabeledContent("配信元", value: candidate.host)
                    LabeledContent("保存先", value: destinationDescription)
                    if let note = candidate.formatNote {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        confirmDownload()
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
            }
            .navigationTitle("動画を保存")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("ダウンロード") {
                        confirmDownload()
                    }
                    .fontWeight(.semibold)
                }
            }
            .alert("新規フォルダ作成", isPresented: $showNewFolderAlert) {
                TextField("フォルダ名", text: $newFolderName)
                Button("キャンセル", role: .cancel) { }
                Button("作成") {
                    if case .success(let folder) = downloads.createFolder(name: newFolderName) {
                        selectedFolder = folder
                    }
                }
            } message: {
                Text("Documents / Downloads 内に新しいサブフォルダを作成します。")
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func confirmDownload() {
        let finalName = sanitizedName
        let folder = selectedFolder
        let pause = pauseWebPlayback
        dismiss()
        onConfirm(finalName, folder, pause)
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
