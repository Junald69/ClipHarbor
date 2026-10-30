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
    @Published private(set) var isViewerActive: Bool = false
    @Published var activePlaybackRate: Float = 1.0
    @Published var isTransitioningToPiP: Bool = false
    @Published var shouldDismissPlayerForPiP: Bool = false
    @Published var pipErrorMessage: String? = nil

    // 再生状態・コンテキストの保持
    private(set) var activeMediaContext: PlaybackPlaylistContext?
    private var pipController: AVPictureInPictureController?
    private var retainedPlayerLayer: AVPlayerLayer?
    private var restoreCompletionHandler: ((Bool) -> Void)?
    private(set) var isRestoringUI: Bool = false

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
        setupAudioSession()

        let sessionID = UUID()
        self.currentSessionID = sessionID
        self.activeMediaContext = context
        self.isTransitioningToPiP = false
        self.isPiPActive = false
        self.shouldDismissPlayerForPiP = false
        self.pipErrorMessage = nil
        self.isRestoringUI = false
        self.activePlaybackRate = (initialRate > 0.0) ? initialRate : 1.0

        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: playerItem)
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
        if initialRate > 0.0 {
            player.playImmediately(atRate: initialRate)
        }

        self.activePlayer = player
        return (player, sessionID)
    }

    /// 選択中の再生速度を保持（PiP復帰時や一時停止時の速度維持）
    func updatePlaybackRate(_ rate: Float) {
        if rate > 0.0 {
            self.activePlaybackRate = rate
        }
    }

    /// 既存の再生セッションを再利用してUIを再接続する（startPlaybackSession による再初期化を防止）
    func reconnectSession(for context: PlaybackPlaylistContext) -> (AVPlayer, UUID)? {
        guard let player = activePlayer,
              let activeContext = activeMediaContext,
              !activeContext.isVault,
              !context.isVault else {
            return nil
        }
        return (player, currentSessionID)
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
        guard sessionID == currentSessionID, let controller = pipController else {
            pipErrorMessage = NSLocalizedString("Currently cannot start Picture in Picture.", comment: "")
            return
        }
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            pipErrorMessage = NSLocalizedString("Picture in Picture is not supported on this device.", comment: "")
            return
        }
        guard controller.isPictureInPicturePossible else {
            if let player = activePlayer, player.currentItem?.status != .readyToPlay {
                pipErrorMessage = NSLocalizedString("Video is preparing. Please try again after playback starts.", comment: "")
            } else {
                pipErrorMessage = NSLocalizedString("Currently cannot start Picture in Picture.", comment: "")
            }
            return
        }

        setupAudioSession()
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
        shouldDismissPlayerForPiP = false
        isRestoringUI = false
        restoreCompletionHandler = nil

        evaluateMediaSuspensionState()
    }

    // MARK: - メディアビューアー・Web再生抑止連携

    /// メディアビューアー（全画面プレイヤー／画像ビューアー）画面が表示された
    func viewerDidAppear() {
        isViewerActive = true
    }

    /// メディアビューアー画面が閉じられた
    func viewerDidDisappear() {
        isViewerActive = false
        evaluateMediaSuspensionState()
    }

    /// Webメディア再生抑止の解除を安全に評価・実行
    func evaluateMediaSuspensionState() {
        // 全画面プレイヤーが表示されておらず、かつPiPも動いていない場合のみ解除
        guard !isViewerActive,
              !isPiPActive,
              !isTransitioningToPiP,
              activePlayer == nil else {
            return
        }
        TabManager.shared?.resumeAllMediaPlayback()
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
            // PiPウィンドウの展開が確定した後に画面を閉じる指示を発行
            self.shouldDismissPlayerForPiP = true
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor in
            self.isTransitioningToPiP = false
            self.isPiPActive = false
            let format = NSLocalizedString("Failed to start Picture in Picture: %@", comment: "")
            self.pipErrorMessage = String(format: format, error.localizedDescription)
            print("[VideoPlaybackCoordinator] PiP開始失敗: \(error.localizedDescription)")
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        Task { @MainActor in
            self.isRestoringUI = true
            guard let context = self.activeMediaContext, !context.isVault else {
                self.isRestoringUI = false
                completionHandler(false)
                return
            }
            self.presentRestoredUI(context: context, completion: completionHandler)
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.isPiPActive = false
            if !self.isRestoringUI {
                // UI復帰を伴わない終了（PiP小窓の「×」タップなど）はリソースを完全解放
                self.stopAndReleaseCurrentSession()
            }
        }
    }

    // MARK: - PiP画面復帰UIの提示

    private func presentRestoredUI(context: PlaybackPlaylistContext, completion: @escaping (Bool) -> Void) {
        guard let windowScene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            self.isRestoringUI = false
            completion(false)
            return
        }

        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }

        let playerView = ModernVideoPlayerView(playlistContext: context) { [weak topVC] in
            topVC?.dismiss(animated: true)
        }
        let host = UIHostingController(rootView: playerView)
        host.modalPresentationStyle = .fullScreen

        topVC.present(host, animated: true) {
            self.isRestoringUI = false
            completion(true)
        }
    }
}
