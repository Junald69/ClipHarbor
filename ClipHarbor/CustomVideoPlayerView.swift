import SwiftUI
import AVKit
import AVFoundation

/// 純粋な映像描画を行う AVPlayerLayer ラッパービュー
/// - OS標準の再生コントロール（シークバー・完了ボタン等）を一切介在させず、完全カスタムUIの描画を可能にする
/// - アスペクト比を維持した .resizeAspect 描画（引き伸ばし・強制クロップ禁止）
/// - AVPictureInPictureController を生成し VideoPlaybackCoordinator へ連携
struct CustomVideoPlayerView: UIViewRepresentable {
    let player: AVPlayer
    let sessionID: UUID

    func makeUIView(context: Context) -> PlayerContainerUIView {
        let view = PlayerContainerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect

        // PiPコントローラーの初期化とバインド
        if AVPictureInPictureController.isPictureInPictureSupported() {
            if let pip = AVPictureInPictureController(playerLayer: view.playerLayer) {
                pip.canStartPictureInPictureAutomaticallyFromInline = false
                VideoPlaybackCoordinator.shared.attachPiPController(pip, forLayer: view.playerLayer, sessionID: sessionID)
            }
        }

        return view
    }

    func updateUIView(_ uiView: PlayerContainerUIView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }
}

final class PlayerContainerUIView: UIView {
    override static var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .black
    }
}
