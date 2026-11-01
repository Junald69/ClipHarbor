import Foundation
import SwiftUI
import AVFoundation
import UIKit

/// オフライン音声再生ビューモデル
/// - AVAudioPlayerによる安定した端末内ローカル音声再生
/// - 再生・一時停止・15秒送り戻し・シーク・時間表示・アートワーク抽出・終了時自動リセット
@MainActor
final class AudioPlayerViewModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying: Bool = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var errorMessage: String? = nil
    @Published var artworkImage: UIImage? = nil
    @Published var isDraggingSlider: Bool = false

    private(set) var audioPlayer: AVAudioPlayer?
    private var timer: Timer?

    var formattedCurrentTime: String {
        formatTime(currentTime)
    }

    var formattedDuration: String {
        formatTime(duration)
    }

    func loadAndPlay(item: ManagedFileItem, zipManager: ZipArchiveManager) {
        guard item.isAudioFile else {
            errorMessage = NSLocalizedString("Not an audio file.", comment: "")
            return
        }

        guard item.isSupportedAudio else {
            errorMessage = String(
                format: NSLocalizedString("Unsupported audio format: %@ is not supported.", comment: ""),
                item.fileExtension.uppercased()
            )
            return
        }

        let url = zipManager.resolveFileURL(for: item)
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = NSLocalizedString("Audio file not found on disk.", comment: "")
            return
        }

        if FileClassification.isInsideVaultOrTempArea(url) {
            errorMessage = NSLocalizedString("Cannot play files located in protected storage.", comment: "")
            return
        }

        loadAudio(from: url)
        extractArtwork(from: url)
    }

    func loadAudio(from url: URL) {
        stopAndCleanup()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)

            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            self.audioPlayer = player
            self.duration = player.duration
            self.currentTime = 0
            self.errorMessage = nil

            // 自動再生開始
            if player.play() {
                self.isPlaying = true
                self.startTimer()
            }
        } catch {
            self.errorMessage = NSLocalizedString("Failed to play audio file.", comment: "")
            self.audioPlayer = nil
            self.isPlaying = false
            self.duration = 0
            self.currentTime = 0
        }
    }

    func togglePlayPause() {
        guard let player = audioPlayer else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            stopTimer()
        } else {
            // 末尾に達している場合は先頭から再生
            if currentTime >= duration && duration > 0 {
                player.currentTime = 0
                currentTime = 0
            }
            if player.play() {
                isPlaying = true
                startTimer()
            }
        }
    }

    func skipBackward(seconds: TimeInterval = 15) {
        guard let player = audioPlayer else { return }
        let newTime = max(0, player.currentTime - seconds)
        player.currentTime = newTime
        currentTime = newTime
    }

    func skipForward(seconds: TimeInterval = 15) {
        guard let player = audioPlayer else { return }
        let newTime = min(duration, player.currentTime + seconds)
        player.currentTime = newTime
        currentTime = newTime
        if newTime >= duration {
            player.pause()
            isPlaying = false
            stopTimer()
        }
    }

    func onSliderChanged(to newValue: TimeInterval) {
        isDraggingSlider = true
        currentTime = max(0, min(newValue, duration))
    }

    func onSliderEnded(at newValue: TimeInterval) {
        isDraggingSlider = false
        seek(to: newValue)
    }

    func seek(to time: TimeInterval) {
        guard let player = audioPlayer else { return }
        let clamped = max(0, min(time, duration))
        player.currentTime = clamped
        currentTime = clamped
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, let player = self.audioPlayer, self.isPlaying else { return }
                if !self.isDraggingSlider {
                    self.currentTime = player.currentTime
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    func stopAndCleanup() {
        stopTimer()
        if let player = audioPlayer {
            player.stop()
            player.delegate = nil
            audioPlayer = nil
        }
        isPlaying = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func extractArtwork(from url: URL) {
        Task {
            let asset = AVURLAsset(url: url)
            if #available(iOS 16.0, *) {
                if let metadata = try? await asset.load(.metadata) {
                    for item in metadata {
                        if item.commonKey == .commonKeyArtwork {
                            if let data = try? await item.load(.dataValue), let img = UIImage(data: data) {
                                await MainActor.run {
                                    self.artworkImage = img
                                }
                                return
                            }
                        }
                    }
                }
            } else {
                for item in asset.commonMetadata {
                    if item.commonKey == .commonKeyArtwork, let data = item.dataValue, let img = UIImage(data: data) {
                        await MainActor.run {
                            self.artworkImage = img
                        }
                        return
                    }
                }
            }
        }
    }

    // MARK: - AVAudioPlayerDelegate
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.currentTime = 0
            self.audioPlayer?.currentTime = 0
            self.stopTimer()
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard !seconds.isNaN && !seconds.isInfinite && seconds >= 0 else {
            return "00:00"
        }
        let total = Int(seconds)
        let s = total % 60
        let m = (total / 60) % 60
        let h = total / 3600
        if h > 0 {
            return String(format: "%02d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%02d:%02d", m, s)
        }
    }

    deinit {
        timer?.invalidate()
        audioPlayer?.stop()
    }
}

/// 専用のオフライン音声プレイヤーシート
struct AudioPlayerSheet: View {
    let item: ManagedFileItem
    @ObservedObject var zipManager: ZipArchiveManager
    @Environment(\.dismiss) private var dismiss

    @StateObject private var viewModel = AudioPlayerViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                // アートワークまたは波形アイコン
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                        .shadow(color: Color.black.opacity(0.12), radius: 12, y: 6)

                    if let artwork = viewModel.artworkImage {
                        Image(uiImage: artwork)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "waveform")
                                .font(.system(size: 72, weight: .light))
                                .foregroundStyle(Color.indigo)
                        }
                    }
                }
                .frame(width: 240, height: 240)
                .padding(.horizontal, 32)

                // ファイル名・形式バッジ・サイズ
                VStack(spacing: 8) {
                    Text(item.title)
                        .font(.title3.weight(.bold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 24)

                    HStack(spacing: 8) {
                        Text(item.formatLabel)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.indigo.opacity(0.15))
                            .foregroundStyle(Color.indigo)
                            .clipShape(Capsule())

                        Text(ByteCountFormatter.string(fromByteCount: item.byteSize, countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // エラーバナー（存在時）
                if let error = viewModel.errorMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 24)
                }

                Spacer()

                // シークバーと再生時間
                VStack(spacing: 6) {
                    Slider(
                        value: Binding(
                            get: { viewModel.currentTime },
                            set: { viewModel.onSliderChanged(to: $0) }
                        ),
                        in: 0...max(viewModel.duration, 0.01),
                        onEditingChanged: { isEditing in
                            if !isEditing {
                                viewModel.onSliderEnded(at: viewModel.currentTime)
                            }
                        }
                    )
                    .tint(.indigo)
                    .disabled(viewModel.duration <= 0)

                    HStack {
                        Text(viewModel.formattedCurrentTime)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(viewModel.formattedDuration)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 28)

                // 操作コントロール（15秒戻し・再生/一時停止・15秒送り）
                HStack(spacing: 40) {
                    Button {
                        viewModel.skipBackward(seconds: 15)
                    } label: {
                        Image(systemName: "gobackward.15")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(.primary)
                    }
                    .disabled(viewModel.duration <= 0)

                    Button {
                        viewModel.togglePlayPause()
                    } label: {
                        Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(Color.indigo)
                    }
                    .disabled(viewModel.audioPlayer == nil)

                    Button {
                        viewModel.skipForward(seconds: 15)
                    } label: {
                        Image(systemName: "goforward.15")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(.primary)
                    }
                    .disabled(viewModel.duration <= 0)
                }
                .padding(.bottom, 24)
            }
            .navigationTitle(NSLocalizedString("Audio Player", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear {
            viewModel.loadAndPlay(item: item, zipManager: zipManager)
        }
        .onDisappear {
            viewModel.stopAndCleanup()
        }
    }
}
