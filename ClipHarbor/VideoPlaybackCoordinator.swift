import Foundation
import AVKit
import AVFoundation
import SwiftUI

/// アプリ全体の動画再生・PiP（ピクチャ・イン・ピクチャ）ライフサイクルを統括する調整役
/// - シート画面が閉じられた後も AVPlayer および AVPlayerLayer の参照寿命を保持
/// - セッションID (sessionID) によるデリゲート通知の識別で、旧PiPの停止が新動画を破壊しないよう保護
/// - UI復帰完了後の completionHandler(true) の呼び出し
/// - Vault再生時の外部映像出力（AirPlay / 外部ディスプレイ）の明示的無効化
@MainActor
final class VideoPlaybackCoordinator: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {
    static let shared = VideoPlaybackCoordinator()

    @Published private(set) var activePlayer: AVPlayer?
    @Published private(set) var currentSessionID: UUID = UUID()
    @Published private(set) var isPiPActive: Bool = false
    @Published var isTransitioningToPiP: Bool = false
    @Published var shouldRestoreUIFromPiP: Bool = false

    // 再生状態・コンテキストの保持
    private(set) var activeMediaContext: PlaybackPlaylistContext?
    private var pipController: AVPictureInPictureController?
    private var retainedPlayerLayer: AVPlayerLayer?
    private var restoreCompletionHandler: ((Bool) -> Void)?

    private override init() {
        super.init()
        setupAudioSession()
    }

    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[VideoPlaybackCoordinator] AudioSession設定失敗: \(error.localizedDescription)")
        }
    }

    // MARK: - セッション開始と初期化

    /// 新規再生セッションを開始
    /// - isVault: Vault内再生の場合は AirPlay・外部出力を完全遮断
    func startPlaybackSession(
        url: URL,
        context: PlaybackPlaylistContext,
        isVault: Bool,
        initialRate: Float = 1.0,
        seekTime: CMTime = .zero
    ) -> (AVPlayer, UUID) {
        // 先行する別セッション（PiP含む）を安全に停止
        stopAndReleaseCurrentSession()

        let sessionID = UUID()
        self.currentSessionID = sessionID
        self.activeMediaContext = context
        self.isTransitioningToPiP = false
        self.isPiPActive = false

        let player = AVPlayer(url: url)
        player.actionAtItemEnd = .pause

        if isVault {
            // Vault内の動画は AirPlay・外部画面出力を明示的に無効化
            player.allowsExternalPlayback = false
            player.usesExternalPlaybackWhileExternalScreenIsActive = false
        } else {
            player.allowsExternalPlayback = true
        }

        if seekTime > .zero {
            player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.rate = initialRate

        self.activePlayer = player
        return (player, sessionID)
    }

    /// PiPコントローラーのバインド
    func attachPiPController(_ controller: AVPictureInPictureController, forLayer layer: AVPlayerLayer, sessionID: UUID) {
        guard sessionID == currentSessionID else { return }
        self.pipController = controller
        self.retainedPlayerLayer = layer
        controller.delegate = self
    }

    /// PiPの開始要求
    func startPictureInPicture(sessionID: UUID) {
        guard sessionID == currentSessionID, let controller = pipController else { return }
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        guard controller.isPictureInPicturePossible else { return }

        isTransitioningToPiP = true
        controller.startPictureInPicture()
    }

    /// 通常の終了・リソース解放
    func stopAndRelease(sessionID: UUID? = nil) {
        if let targetID = sessionID, targetID != currentSessionID {
            return // 過去セッションからの遅延通知は無視
        }
        stopAndReleaseCurrentSession()
    }

    private func stopAndReleaseCurrentSession() {
        if let pip = pipController, pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        }
        pipController?.delegate = nil
        pipController = nil
        retainedPlayerLayer = nil

        activePlayer?.pause()
        activePlayer?.replaceCurrentItem(with: nil)
        activePlayer = nil
        activeMediaContext = nil

        isPiPActive = false
        isTransitioningToPiP = false
        shouldRestoreUIFromPiP = false
        restoreCompletionHandler = nil
    }

    // MARK: - AVPictureInPictureControllerDelegate

    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.isPiPActive = true
        }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.isPiPActive = true
            self.isTransitioningToPiP = false
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor in
            self.isTransitioningToPiP = false
            self.isPiPActive = false
            print("[VideoPlaybackCoordinator] PiP開始失敗: \(error.localizedDescription)")
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        Task { @MainActor in
            self.restoreCompletionHandler = completionHandler
            self.shouldRestoreUIFromPiP = true
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.isPiPActive = false
            if !self.shouldRestoreUIFromPiP {
                // UI復帰を伴わない終了（PiP小窓の「×」タップなど）はリソースを完全解放
                self.stopAndReleaseCurrentSession()
            }
        }
    }

    /// UI復帰が正常に完了したことをシート側から通知し、PiP完了ハンドラーを呼び出す
    func notifyUIRestoredSuccessfully() {
        shouldRestoreUIFromPiP = false
        restoreCompletionHandler?(true)
        restoreCompletionHandler = nil
    }
}
