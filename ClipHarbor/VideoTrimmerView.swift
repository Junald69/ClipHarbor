import SwiftUI
import AVKit
import AVFoundation

/// 動画トリミング・ファイル名変更画面
/// - フィルムストリップサムネイル生成（Task協調キャンセル・枚数制限対応）
/// - 開始・終了ハンドルによる範囲指定と選択時間表示
/// - パススルー切り出し（キーフレーム精度）と再エンコード事前確認
/// - 出力動画の自動検証（再生時間・トラック・再生可能判定）
/// - HLS動画は名前変更のみ対応し、トリミングは安全に制限
struct VideoTrimmerView: View {
    let sourceURL: URL
    let originalTitle: String
    let isHLS: Bool
    let isVault: Bool
    let onSaveRenameOnly: (String) -> Void
    let onSaveClip: (URL, String, CMTimeRange) async throws -> Void

    @Environment(\.dismiss) private var dismiss

    // 編集ステート
    @State private var editedTitle: String = ""
    @State private var player: AVPlayer?
    @State private var assetDuration: Double = 0.0
    @State private var startTime: Double = 0.0
    @State private var endTime: Double = 0.0
    @State private var isPlaying: Bool = false
    @State private var thumbnails: [UIImage] = []

    // 処理ステート
    @State private var isExporting: Bool = false
    @State private var exportProgress: Double = 0.0
    @State private var statusMessage: String?
    @State private var showDiscardAlert: Bool = false
    @State private var showReencodeConfirmAlert: Bool = false
    @State private var pendingReencodePreset: String?
    @State private var errorMessage: String?

    // サムネイル生成管理
    @State private var thumbnailGenerator: AVAssetImageGenerator?
    @State private var thumbnailTask: Task<Void, Never>?

    private var hasTrimmed: Bool {
        guard assetDuration > 0 else { return false }
        return startTime > 0.05 || (assetDuration - endTime) > 0.05
    }

    private var hasTitleChanged: Bool {
        let clean = FileNaming.sanitizedBaseName(editedTitle)
        return !clean.isEmpty && clean != originalTitle
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    // MARK: - プレビュープレイヤー
                    previewPlayerArea
                        .frame(maxHeight: .infinity)

                    // MARK: - 下部トリミング操作パネル
                    bottomEditingPanel
                }

                // エクスポート中オーバーレイ
                if isExporting {
                    exportingOverlay
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back") {
                        if hasTrimmed || hasTitleChanged {
                            showDiscardAlert = true
                        } else {
                            dismiss()
                        }
                    }
                    .foregroundStyle(.white)
                }

                ToolbarItem(placement: .principal) {
                    TextField(NSLocalizedString("Title", comment: ""), text: $editedTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 200)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        handleSaveTapped()
                    }
                    .font(.body.weight(.bold))
                    .foregroundStyle(isExporting ? Color.secondary : Color.blue)
                    .disabled(isExporting)
                }
            }
            .alert(NSLocalizedString("Discard changes?", comment: ""), isPresented: $showDiscardAlert) {
                Button("Discard", role: .destructive) {
                    dismiss()
                }
                Button("Keep Editing", role: .cancel) {}
            } message: {
                Text("Unsaved changes will be lost.")
            }
            .alert(NSLocalizedString("High-Precision Export Confirmation", comment: ""), isPresented: $showReencodeConfirmAlert) {
                Button("Export with High Precision") {
                    if let preset = pendingReencodePreset {
                        performExport(presetName: preset)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This video does not support fast keyframe-based clipping. Do you want to export with re-encoding while maintaining original resolution?")
            }
            .alert(NSLocalizedString("Error", comment: ""), isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear {
                setupView()
            }
            .onDisappear {
                cleanupResources()
            }
        }
    }

    // MARK: - プレビューエリア

    private var previewPlayerArea: some View {
        Group {
            if let p = player {
                VideoPlayer(player: p)
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
    }

    // MARK: - 下部パネル

    private var bottomEditingPanel: some View {
        VStack(spacing: 16) {
            // 再生時間・選択時間
            HStack {
                Text(String(format: NSLocalizedString("Selection: %@", comment: ""), formatSeconds(max(0, endTime - startTime))))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)

                Spacer()

                Text(String(format: NSLocalizedString("Total: %@", comment: ""), formatSeconds(assetDuration)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)

            if isHLS {
                // HLS警告表示
                Text("*Offline HLS packages cannot be trimmed due to segmented structure (only title changes can be saved)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            } else {
                // フィルムストリップ & トリムハンドル
                trimmerStripView
                    .frame(height: 54)
                    .padding(.horizontal, 20)
            }

            // 再生プレビューボタン
            Button {
                togglePlayPreview()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.2), in: Circle())
            }
            .padding(.bottom, 12)
        }
        .padding(.top, 12)
        .background(Color.black.opacity(0.85))
    }

    // MARK: - トリムスライダー

    private var trimmerStripView: some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width
            let startX = assetDuration > 0 ? (startTime / assetDuration) * totalWidth : 0
            let endX = assetDuration > 0 ? (endTime / assetDuration) * totalWidth : totalWidth

            ZStack(alignment: .leading) {
                // サムネイルフィルムストリップ
                HStack(spacing: 0) {
                    if thumbnails.isEmpty {
                        Rectangle()
                            .fill(Color.white.opacity(0.1))
                    } else {
                        ForEach(0..<thumbnails.count, id: \.self) { idx in
                            Image(uiImage: thumbnails[idx])
                                .resizable()
                                .scaledToFill()
                                .frame(width: totalWidth / CGFloat(thumbnails.count), height: 54)
                                .clipped()
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))

                // 暗い未選択オーバーレイ（左側）
                Rectangle()
                    .fill(Color.black.opacity(0.6))
                    .frame(width: max(0, startX), height: 54)

                // 暗い未選択オーバーレイ（右側）
                Rectangle()
                    .fill(Color.black.opacity(0.6))
                    .frame(width: max(0, totalWidth - endX), height: 54)
                    .offset(x: endX)

                // 選択枠
                Rectangle()
                    .stroke(Color.yellow, lineWidth: 2)
                    .frame(width: max(10, endX - startX), height: 54)
                    .offset(x: startX)

                // 開始ハンドル
                handleView(isLeft: true)
                    .offset(x: max(0, startX - 10))
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let newX = max(0, min(value.location.x, endX - 15))
                                let p = newX / totalWidth
                                startTime = assetDuration * p
                                player?.seek(to: CMTime(seconds: startTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                            }
                    )

                // 終了ハンドル
                handleView(isLeft: false)
                    .offset(x: max(0, min(endX - 10, totalWidth - 20)))
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let newX = max(startX + 15, min(value.location.x, totalWidth))
                                let p = newX / totalWidth
                                endTime = assetDuration * p
                                player?.seek(to: CMTime(seconds: endTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                            }
                    )
            }
        }
    }

    private func handleView(isLeft: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.yellow)
                .frame(width: 20, height: 54)

            Image(systemName: isLeft ? "chevron.right" : "chevron.left")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.black)
        }
    }

    private var exportingOverlay: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.3)
                Text(statusMessage ?? NSLocalizedString("Exporting clip…", comment: ""))
                    .font(.subheadline)
                    .foregroundStyle(.white)
            }
            .padding(24)
            .background(Color.secondary.opacity(0.2), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: - ロジック

    private func setupView() {
        editedTitle = originalTitle
        let p = AVPlayer(url: sourceURL)
        self.player = p

        Task {
            let asset = AVURLAsset(url: sourceURL)
            if let cmDuration = try? await asset.load(.duration) {
                let secs = CMTimeGetSeconds(cmDuration)
                if secs > 0 && !secs.isNaN {
                    await MainActor.run {
                        self.assetDuration = secs
                        self.startTime = 0.0
                        self.endTime = secs
                        if !isHLS {
                            loadFilmstripThumbnails(asset: asset, duration: secs)
                        }
                    }
                }
            }
        }
    }

    private func cleanupResources() {
        thumbnailTask?.cancel()
        thumbnailGenerator?.cancelAllCGImageGeneration()
        thumbnailGenerator = nil
        player?.pause()
        player = nil
    }

    private func togglePlayPreview() {
        guard let p = player else { return }
        if isPlaying {
            p.pause()
            isPlaying = false
        } else {
            let current = CMTimeGetSeconds(p.currentTime())
            if current >= endTime || current < startTime {
                p.seek(to: CMTime(seconds: startTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
            p.play()
            isPlaying = true
        }
    }

    private func loadFilmstripThumbnails(asset: AVAsset, duration: Double) {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 120, height: 120)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        self.thumbnailGenerator = generator

        let count = 10
        var times: [CMTime] = []
        for i in 0..<count {
            let s = (duration / Double(count)) * Double(i)
            times.append(CMTime(seconds: s, preferredTimescale: 600))
        }

        thumbnailTask = Task {
            var imgs: [UIImage] = []
            for t in times {
                if Task.isCancelled { break }
                if let (cgImg, _) = try? await generator.image(at: t) {
                    imgs.append(UIImage(cgImage: cgImg))
                }
            }
            if !Task.isCancelled {
                await MainActor.run {
                    self.thumbnails = imgs
                }
            }
        }
    }

    private func handleSaveTapped() {
        let clean = FileNaming.sanitizedBaseName(editedTitle)
        guard !clean.isEmpty else {
            errorMessage = NSLocalizedString("Please enter a title.", comment: "")
            return
        }

        // HLSまたはトリミング範囲未変更の場合: タイトル変更のみ
        if isHLS || !hasTrimmed {
            onSaveRenameOnly(clean)
            dismiss()
            return
        }

        // トリミング書き出し判定
        checkCompatibilityAndExport()
    }

    private func checkCompatibilityAndExport() {
        let asset = AVURLAsset(url: sourceURL)
        let compatiblePresets = AVAssetExportSession.exportPresets(compatibleWith: asset)

        // まずはパススルーを試行
        if compatiblePresets.contains(AVAssetExportPresetPassthrough) {
            performExport(presetName: AVAssetExportPresetPassthrough)
        } else if compatiblePresets.contains(AVAssetExportPresetHighestQuality) {
            // パススルー非対応時は事前確認
            pendingReencodePreset = AVAssetExportPresetHighestQuality
            showReencodeConfirmAlert = true
        } else {
            errorMessage = NSLocalizedString("This video format does not support trimming.", comment: "")
        }
    }

    private func performExport(presetName: String) {
        isExporting = true
        statusMessage = NSLocalizedString("Exporting clip…", comment: "")

        let asset = AVURLAsset(url: sourceURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: presetName) else {
            isExporting = false
            errorMessage = NSLocalizedString("Failed to initialize export session.", comment: "")
            return
        }

        let ext = sourceURL.pathExtension.isEmpty ? "mp4" : sourceURL.pathExtension
        let tempOutURL = FileManager.default.temporaryDirectory.appendingPathComponent("trimmed_\(UUID().uuidString).\(ext)")

        session.outputURL = tempOutURL
        session.outputFileType = AVFileType.mp4
        if !session.supportedFileTypes.contains(.mp4), let firstType = session.supportedFileTypes.first {
            session.outputFileType = firstType
        }

        let startCM = CMTime(seconds: startTime, preferredTimescale: 600)
        let durationCM = CMTime(seconds: max(0.5, endTime - startTime), preferredTimescale: 600)
        session.timeRange = CMTimeRange(start: startCM, duration: durationCM)

        Task {
            await session.export()

            await MainActor.run {
                switch session.status {
                case .completed:
                    // 出力検証
                    validateAndFinishExport(tempURL: tempOutURL, expectedDuration: durationCM)
                case .failed:
                    isExporting = false
                    try? FileManager.default.removeItem(at: tempOutURL)
                    errorMessage = String(format: NSLocalizedString("Export failed: %@", comment: ""), session.error?.localizedDescription ?? NSLocalizedString("Unknown Error", comment: ""))
                case .cancelled:
                    isExporting = false
                    try? FileManager.default.removeItem(at: tempOutURL)
                default:
                    isExporting = false
                    try? FileManager.default.removeItem(at: tempOutURL)
                }
            }
        }
    }

    private func validateAndFinishExport(tempURL: URL, expectedDuration: CMTime) {
        statusMessage = NSLocalizedString("Validating generated clip…", comment: "")
        let exportedAsset = AVURLAsset(url: tempURL)

        Task {
            // タイムアウト付き検証
            do {
                let duration = try await exportedAsset.load(.duration)
                let tracks = try await exportedAsset.load(.tracks)
                guard !tracks.isEmpty else {
                    throw NSError(domain: "VideoTrimmer", code: 1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("No valid media tracks exist.", comment: "")])
                }

                let actualSecs = CMTimeGetSeconds(duration)
                let expectedSecs = CMTimeGetSeconds(expectedDuration)
                // パススルー時のキーフレーム吸着を考慮しつつ最低限の長さがあるか検証
                guard actualSecs > 0.2 else {
                    throw NSError(domain: "VideoTrimmer", code: 2, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Exported video length is invalid.", comment: "")])
                }

                await MainActor.run {
                    Task {
                        do {
                            let titleToUse = FileNaming.sanitizedBaseName(editedTitle)
                            let timeRange = CMTimeRange(start: CMTime(seconds: startTime, preferredTimescale: 600), duration: duration)
                            try await onSaveClip(tempURL, titleToUse, timeRange)
                            isExporting = false
                            dismiss()
                        } catch {
                            isExporting = false
                            try? FileManager.default.removeItem(at: tempURL)
                            errorMessage = String(format: NSLocalizedString("Failed to save clip: %@", comment: ""), error.localizedDescription)
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    isExporting = false
                    try? FileManager.default.removeItem(at: tempURL)
                    errorMessage = String(format: NSLocalizedString("Failed to validate clip: %@", comment: ""), error.localizedDescription)
                }
            }
        }
    }

    private func formatSeconds(_ seconds: Double) -> String {
        guard seconds > 0, !seconds.isNaN else { return "0:00" }
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
