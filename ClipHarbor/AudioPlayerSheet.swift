import Foundation
import SwiftUI
import AVFoundation
import UIKit
import MediaPlayer

/// オフライン音声再生ビューモデル
/// - AVAudioPlayerによる安定した端末内ローカル音声再生
/// - ロック画面・コントロールセンター（MPNowPlayingInfoCenter / MPRemoteCommandCenter）連携
/// - 電話着信・アラーム・Siri等のオーディオ割り込み処理
/// - 有線イヤホン抜去・Bluetooth切断時の自動一時停止（誤爆防止）
/// - 再生・一時停止・15秒送り戻し・シーク・時間表示・アートワーク抽出・終了時自動リセット
@MainActor
final class AudioPlayerViewModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying: Bool = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var errorMessage: String? = nil
    @Published var artworkImage: UIImage? = nil
    @Published var isDraggingSlider: Bool = false

    private(set) var currentTitle: String = ""
    private(set) var audioPlayer: AVAudioPlayer?
    private var timer: Timer?

    // ロック画面・リモート操作ターゲット
    private var playCommandTarget: Any?
    private var pauseCommandTarget: Any?
    private var togglePlayPauseTarget: Any?
    private var skipBackwardTarget: Any?
    private var skipForwardTarget: Any?
    private var changePlaybackPositionTarget: Any?

    // 割り込み直前の再生状態
    private var wasPlayingBeforeInterruption: Bool = false

    var formattedCurrentTime: String {
        formatTime(currentTime)
    }

    var formattedDuration: String {
        formatTime(duration)
    }

    func loadAndPlay(item: ManagedFileItem, zipManager: ZipArchiveManager) {
        self.currentTitle = item.title

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

        setupRemoteCommands()
        setupAudioSessionObservers()
        loadAudio(from: url)
        extractArtwork(from: url)
    }

    func loadAudio(from url: URL) {
        stopAndCleanupPlayer()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)

            // 先行して動作している動画プレイヤー（PiP含む）を一時停止
            VideoPlaybackCoordinator.shared.activePlayer?.pause()

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
                self.updateNowPlayingInfo()
            }
        } catch {
            self.errorMessage = NSLocalizedString("Failed to play audio file.", comment: "")
            self.audioPlayer = nil
            self.isPlaying = false
            self.duration = 0
            self.currentTime = 0
            self.clearNowPlayingInfo()
        }
    }

    func play() {
        guard let player = audioPlayer else { return }

        // 動画プレイヤーとの競合防止
        VideoPlaybackCoordinator.shared.activePlayer?.pause()

        if currentTime >= duration && duration > 0 {
            player.currentTime = 0
            currentTime = 0
        }
        if player.play() {
            isPlaying = true
            startTimer()
            updateNowPlayingInfo()
        }
    }

    func pause() {
        guard let player = audioPlayer else { return }
        player.pause()
        isPlaying = false
        stopTimer()
        updateNowPlayingInfo()
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func skipBackward(seconds: TimeInterval = 15) {
        guard let player = audioPlayer else { return }
        let newTime = max(0, player.currentTime - seconds)
        player.currentTime = newTime
        currentTime = newTime
        updateNowPlayingInfo()
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
        updateNowPlayingInfo()
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
        updateNowPlayingInfo()
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

    // MARK: - ロック画面・コントロールセンター（MPNowPlayingInfoCenter）

    func updateNowPlayingInfo() {
        guard let player = audioPlayer else {
            clearNowPlayingInfo()
            return
        }

        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = currentTitle.isEmpty ? NSLocalizedString("Audio", comment: "") : currentTitle
        info[MPMediaItemPropertyPlaybackDuration] = player.duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0

        if let artwork = artworkImage {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        } else if let fallbackArtwork = makeFallbackArtwork() {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: fallbackArtwork.size) { _ in fallbackArtwork }
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func makeFallbackArtwork() -> UIImage? {
        let size = CGSize(width: 512, height: 512)
        UIGraphicsBeginImageContextWithOptions(size, false, 0.0)
        defer { UIGraphicsEndImageContext() }

        guard UIGraphicsGetCurrentContext() != nil else { return nil }

        let rect = CGRect(origin: .zero, size: size)
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 48)
        UIColor.systemIndigo.setFill()
        path.fill()

        let config = UIImage.SymbolConfiguration(pointSize: 180, weight: .light)
        if let icon = UIImage(systemName: "waveform", withConfiguration: config)?.withTintColor(.white, renderingMode: .alwaysOriginal) {
            let iconOrigin = CGPoint(
                x: (size.width - icon.size.width) / 2.0,
                y: (size.height - icon.size.height) / 2.0
            )
            icon.draw(at: iconOrigin)
        }

        return UIGraphicsGetImageFromCurrentImageContext()
    }

    // MARK: - 外部メディア操作（MPRemoteCommandCenter）

    private func setupRemoteCommands() {
        removeRemoteCommands()
        let commandCenter = MPRemoteCommandCenter.shared()

        // 再生
        commandCenter.playCommand.isEnabled = true
        playCommandTarget = commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.play()
            }
            return .success
        }

        // 一時停止
        commandCenter.pauseCommand.isEnabled = true
        pauseCommandTarget = commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pause()
            }
            return .success
        }

        // トグル（AirPods タップなど）
        commandCenter.togglePlayPauseCommand.isEnabled = true
        togglePlayPauseTarget = commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.togglePlayPause()
            }
            return .success
        }

        // 15秒戻し
        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        skipBackwardTarget = commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.skipBackward(seconds: 15)
            }
            return .success
        }

        // 15秒送り
        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [15]
        skipForwardTarget = commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.skipForward(seconds: 15)
            }
            return .success
        }

        // シーク位置変更（ロック画面スライダー操作）
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        changePlaybackPositionTarget = commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let posEvent = event as? MPChangePlaybackPositionCommandEvent {
                Task { @MainActor [weak self] in
                    self?.seek(to: posEvent.positionTime)
                }
                return .success
            }
            return .commandFailed
        }
    }

    private func removeRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        if let target = playCommandTarget {
            commandCenter.playCommand.removeTarget(target)
            playCommandTarget = nil
        }
        if let target = pauseCommandTarget {
            commandCenter.pauseCommand.removeTarget(target)
            pauseCommandTarget = nil
        }
        if let target = togglePlayPauseTarget {
            commandCenter.togglePlayPauseCommand.removeTarget(target)
            togglePlayPauseTarget = nil
        }
        if let target = skipBackwardTarget {
            commandCenter.skipBackwardCommand.removeTarget(target)
            skipBackwardTarget = nil
        }
        if let target = skipForwardTarget {
            commandCenter.skipForwardCommand.removeTarget(target)
            skipForwardTarget = nil
        }
        if let target = changePlaybackPositionTarget {
            commandCenter.changePlaybackPositionCommand.removeTarget(target)
            changePlaybackPositionTarget = nil
        }

        commandCenter.playCommand.isEnabled = false
        commandCenter.pauseCommand.isEnabled = false
        commandCenter.togglePlayPauseCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false
        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.changePlaybackPositionCommand.isEnabled = false
    }

    // MARK: - オーディオセッション割り込み & ルート変更監視

    private func setupAudioSessionObservers() {
        removeAudioSessionObservers()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleVideoPlaybackStarted(_:)),
            name: .videoPlaybackDidStart,
            object: nil
        )
    }

    private func removeAudioSessionObservers() {
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: .videoPlaybackDidStart, object: nil)
    }

    @objc private nonisolated func handleAudioInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        Task { @MainActor in
            switch type {
            case .began:
                // 電話着信、Siri、アラーム等で割り込み発生
                self.wasPlayingBeforeInterruption = self.isPlaying
                if self.isPlaying {
                    self.pause()
                }
            case .ended:
                // 割り込み終了時、OSが再開を推奨しており直前に再生中だった場合のみ自動再開
                if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                    if options.contains(.shouldResume) && self.wasPlayingBeforeInterruption {
                        self.play()
                    }
                }
                self.wasPlayingBeforeInterruption = false
            @unknown default:
                break
            }
        }
    }

    @objc private nonisolated func handleAudioRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }
        Task { @MainActor in
            switch reason {
            case .oldDeviceUnavailable:
                // 有線イヤホン抜去、Bluetoothイヤホン切断時に意図しないスピーカー大音量再生を防ぐため自動一時停止
                if self.isPlaying {
                    self.pause()
                }
            default:
                break
            }
        }
    }

    @objc private nonisolated func handleVideoPlaybackStarted(_ notification: Notification) {
        Task { @MainActor in
            if self.isPlaying {
                self.pause()
            }
        }
    }

    // MARK: - リソース解放・クリーンアップ

    private func stopAndCleanupPlayer() {
        stopTimer()
        if let player = audioPlayer {
            player.stop()
            player.delegate = nil
            audioPlayer = nil
        }
        isPlaying = false
    }

    func stopAndCleanup() {
        stopAndCleanupPlayer()
        removeRemoteCommands()
        removeAudioSessionObservers()
        clearNowPlayingInfo()
        wasPlayingBeforeInterruption = false
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
                                    self.updateNowPlayingInfo()
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
                            self.updateNowPlayingInfo()
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
            self.updateNowPlayingInfo()
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
