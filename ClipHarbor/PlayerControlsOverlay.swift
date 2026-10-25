import SwiftUI
import AVKit
import AVFoundation

/// 刷新されたAloha風メディアプレイヤー用コントロールオーバーレイ
/// - カプセル型フローティングヘッダー（閉じる、省略ファイル名、編集、共有）
/// - 中央 10秒戻し／再生・一時停止／10秒送りボタン
/// - 左右 縦型スライダー（左: 画面照度、右: 動画音量）
/// - 下部 シークバー & 厳格な6ボタン（最初から[0秒+即再生]、お気に入り[星]、速度変更、PiP、縦横切替、…メニュー）
struct PlayerControlsOverlay: View {
    // 状態バインディング
    @Binding var isPlaying: Bool
    @Binding var currentTime: Double
    @Binding var duration: Double
    @Binding var playbackRate: Float
    @Binding var brightness: Double
    @Binding var volume: Double
    @Binding var isFavorite: Bool
    @Binding var isLandscape: Bool

    // 表示・権限情報
    let title: String
    let isVault: Bool
    let isImage: Bool
    let isHLS: Bool

    // コールバック
    let onClose: () -> Void
    let onEdit: () -> Void
    let onShare: () -> Void
    let onRestart: () -> Void
    let onTogglePlay: () -> Void
    let onSeekBy: (Double) -> Void
    let onSeekTo: (Double) -> Void
    let onToggleOrientation: () -> Void
    let onTriggerPiP: () -> Void
    let onMoveFile: () -> Void

    // スピード選択肢
    private let speedOptions: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    // ドラッグ中フラグ
    @State private var isScrubbing: Bool = false
    @State private var scrubTime: Double = 0.0

    var body: some View {
        ZStack {
            // 上部・下部のグラデーションシャドウ（横全画面時の視認性向上）
            VStack {
                LinearGradient(colors: [Color.black.opacity(0.7), Color.clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 100)
                    .allowsHitTesting(false)
                Spacer()
                LinearGradient(colors: [Color.clear, Color.black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 140)
                    .allowsHitTesting(false)
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // MARK: - 上部ヘッダー
                headerView
                    .padding(.top, isLandscape ? 8 : 4)

                Spacer()

                // MARK: - 中央コントロール（動画のみ）
                if !isImage {
                    centerControlsView
                }

                Spacer()

                // MARK: - 下部コントロールパネル
                bottomControlsView
                    .padding(.bottom, isLandscape ? 12 : 8)
            }
            .padding(.horizontal, isLandscape ? 24 : 16)

            // MARK: - 左右縦スライダー（動画のみ）
            if !isImage {
                HStack {
                    verticalBrightnessSlider
                    Spacer()
                    verticalVolumeSlider
                }
                .padding(.horizontal, isLandscape ? 24 : 12)
            }
        }
    }

    // MARK: - ヘッダー（縦: カプセル型、横: 全画面バー）

    @ViewBuilder
    private var headerView: some View {
        HStack(spacing: 12) {
            // 閉じるボタン
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.black.opacity(0.4), in: Circle())
            }

            // タイトル（ボタンを圧迫しないよう末尾省略）
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            // 編集ボタン（VaultおよびHLSトリミング制限は編集画面側で適切に制御）
            if !isVault && !isImage {
                Button(action: onEdit) {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil")
                            .font(.system(size: 12, weight: .semibold))
                        Text("編集")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.4), in: Capsule())
                }
            }

            // 共有・出力ボタン（Vault内は外部共有を制限）
            if !isVault {
                Button(action: onShare) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.black.opacity(0.4), in: Circle())
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Color.black.opacity(0.65)
                .background(.ultraThinMaterial.opacity(0.3))
                .clipShape(Capsule())
        )
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
        )
    }

    // MARK: - 中央コントロール

    private var centerControlsView: some View {
        HStack(spacing: 40) {
            // 10秒戻し
            Button {
                onSeekBy(-10)
            } label: {
                Image(systemName: "gobackward.10")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(Color.black.opacity(0.45), in: Circle())
            }

            // 再生・一時停止
            Button(action: onTogglePlay) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(Color.white.opacity(0.25), in: Circle())
                    .background(.ultraThinMaterial.opacity(0.4), in: Circle())
            }

            // 10秒送り
            Button {
                onSeekBy(10)
            } label: {
                Image(systemName: "goforward.10")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(Color.black.opacity(0.45), in: Circle())
            }
        }
    }

    // MARK: - 下部コントロール

    private var bottomControlsView: some View {
        VStack(spacing: 12) {
            if !isImage {
                // シークバーと再生時間
                VStack(spacing: 4) {
                    GeometryReader { geo in
                        let sliderWidth = geo.size.width
                        let displayTime = isScrubbing ? scrubTime : currentTime
                        let progress = duration > 0 ? min(1.0, max(0.0, displayTime / duration)) : 0.0

                        ZStack(alignment: .leading) {
                            // 背景トラック
                            Capsule()
                                .fill(Color.white.opacity(0.25))
                                .frame(height: 4)

                            // 進行状況トラック
                            Capsule()
                                .fill(Color.white)
                                .frame(width: sliderWidth * progress, height: 4)

                            // つまみ
                            Circle()
                                .fill(Color.white)
                                .frame(width: 12, height: 12)
                                .offset(x: max(0, min(sliderWidth * progress - 6, sliderWidth - 12)))
                        }
                        .frame(height: 16)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    isScrubbing = true
                                    let p = min(1.0, max(0.0, value.location.x / sliderWidth))
                                    scrubTime = duration * p
                                }
                                .onEnded { value in
                                    let p = min(1.0, max(0.0, value.location.x / sliderWidth))
                                    let finalTime = duration * p
                                    onSeekTo(finalTime)
                                    isScrubbing = false
                                }
                        )
                    }
                    .frame(height: 16)

                    // 時間表示
                    HStack {
                        let display = isScrubbing ? scrubTime : currentTime
                        Text(formatDuration(display))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                        Spacer()
                        Text(formatDuration(duration))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            }

            // 厳格な順序の下部6ボタン
            HStack {
                if !isImage {
                    // 1. 最初から再生 (0秒へシークして即再生開始)
                    Button(action: onRestart) {
                        VStack(spacing: 3) {
                            Image(systemName: "backward.end.fill")
                                .font(.system(size: 15))
                            Text("最初から")
                                .font(.system(size: 9))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                    }
                }

                // 2. お気に入り (承認済みデザインの「星」アイコン)
                Button {
                    isFavorite.toggle()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .font(.system(size: 15))
                            .foregroundStyle(isFavorite ? Color.yellow : Color.white)
                        Text(isFavorite ? "登録済" : "お気に入り")
                            .font(.system(size: 9))
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity)
                }

                if !isImage {
                    // 3. 再生速度変更 (0.5 / 0.75 / 1.0 / 1.25 / 1.5 / 2.0x)
                    Menu {
                        ForEach(speedOptions, id: \.self) { speed in
                            Button {
                                playbackRate = speed
                            } label: {
                                HStack {
                                    Text(String(format: "%.2fx", speed))
                                    if playbackRate == speed {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        VStack(spacing: 3) {
                            Text(String(format: "%.1fx", playbackRate))
                                .font(.system(size: 13, weight: .bold))
                            Text("速度")
                                .font(.system(size: 9))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                    }

                    // 4. PiP (Vault内は無効化)
                    Button(action: onTriggerPiP) {
                        VStack(spacing: 3) {
                            Image(systemName: "pip.enter")
                                .font(.system(size: 15))
                            Text("PiP")
                                .font(.system(size: 9))
                        }
                        .foregroundStyle(isVault ? .white.opacity(0.3) : .white)
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(isVault)

                    // 5. 縦横切替
                    Button(action: onToggleOrientation) {
                        VStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 15))
                            Text(isLandscape ? "縦画面" : "横全画面")
                                .font(.system(size: 9))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                    }
                }

                // 6. … その他メニュー
                Menu {
                    if !isImage {
                        Menu("字幕") {
                            Text("字幕トラックなし")
                        }
                    }

                    Button(action: onMoveFile) {
                        Label("ファイル移動", systemImage: "folder")
                    }

                    if !isVault {
                        Button(action: onShare) {
                            Label("出力・共有", systemImage: "square.and.arrow.up")
                        }
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 15, weight: .bold))
                        Text("その他")
                            .font(.system(size: 9))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(
                Color.black.opacity(0.65)
                    .background(.ultraThinMaterial.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            )
        }
    }

    // MARK: - 左右縦型スライダー

    private var verticalBrightnessSlider: some View {
        VStack(spacing: 8) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 12))
                .foregroundStyle(.white)

            GeometryReader { geo in
                let h = geo.size.height
                ZStack(alignment: .bottom) {
                    Capsule()
                        .fill(Color.white.opacity(0.25))
                        .frame(width: 4)

                    Capsule()
                        .fill(Color.white)
                        .frame(width: 4, height: h * CGFloat(brightness))
                }
                .frame(width: 20)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let p = min(1.0, max(0.0, 1.0 - (value.location.y / h)))
                            brightness = Double(p)
                            UIScreen.main.brightness = CGFloat(p)
                        }
                )
            }
            .frame(width: 20, height: 90)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(Color.black.opacity(0.4), in: Capsule())
    }

    private var verticalVolumeSlider: some View {
        VStack(spacing: 8) {
            Image(systemName: volume > 0.05 ? "speaker.wave.3.fill" : "speaker.slash.fill")
                .font(.system(size: 12))
                .foregroundStyle(.white)

            GeometryReader { geo in
                let h = geo.size.height
                ZStack(alignment: .bottom) {
                    Capsule()
                        .fill(Color.white.opacity(0.25))
                        .frame(width: 4)

                    Capsule()
                        .fill(Color.white)
                        .frame(width: 4, height: h * CGFloat(volume))
                }
                .frame(width: 20)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let p = min(1.0, max(0.0, 1.0 - (value.location.y / h)))
                            volume = Double(p)
                        }
                )
            }
            .frame(width: 20, height: 90)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(Color.black.opacity(0.4), in: Capsule())
    }

    private func formatDuration(_ seconds: Double) -> String {
        guard seconds > 0, !seconds.isNaN, !seconds.isInfinite else { return "0:00" }
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
