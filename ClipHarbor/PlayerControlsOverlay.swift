import SwiftUI
import AVKit
import AVFoundation

/// プレイヤーコントロールの実際のレイアウト領域を背景ジェスチャーへ通知するPreference Key
struct ControlExclusionFramesPreferenceKey: PreferenceKey {
    static var defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    func reportControlFrame(in coordinateSpace: String) -> some View {
        self.background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: ControlExclusionFramesPreferenceKey.self,
                    value: [geo.frame(in: .named(coordinateSpace))]
                )
            }
        )
    }
}

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
    let isFavorite: Bool
    @Binding var isLandscape: Bool

    // 表示・権限情報
    let title: String
    let isVault: Bool
    let isImage: Bool
    let isHLS: Bool
    let canGoNext: Bool
    let canGoPrevious: Bool
    var isFailed: Bool = false

    // コールバック
    let onClose: () -> Void
    let onEdit: () -> Void
    let onShare: () -> Void
    let onRestart: () -> Void
    let onTogglePlay: () -> Void
    let onSeekTo: (Double) -> Void
    let onNextFile: () -> Void
    let onPreviousFile: () -> Void
    let onToggleOrientation: () -> Void
    let onTriggerPiP: () -> Void
    let onMoveFile: () -> Void
    let onDeleteFile: () -> Void
    let onToggleFavorite: () -> Void
    let onInteractionStarted: (String) -> Void
    let onInteractionEnded: (String) -> Void

    // スピード選択肢
    private let speedOptions: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    // ドラッグ中フラグ
    @State private var isScrubbing: Bool = false
    @State private var scrubTime: Double = 0.0
    @State private var isBrightnessDragging: Bool = false
    @State private var isVolumeDragging: Bool = false

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
                    .reportControlFrame(in: "playerContainer")
                    .padding(.top, isLandscape ? 8 : 4)

                Spacer()

                // MARK: - 中央コントロール（動画のみ表示、画像時および失敗時は非表示）
                if !isImage && !isFailed {
                    centerControlsView
                        .reportControlFrame(in: "playerContainer")
                }

                Spacer()

                // MARK: - 下部コントロールパネル
                bottomControlsView
                    .reportControlFrame(in: "playerContainer")
                    .padding(.bottom, isLandscape ? 12 : 8)
            }
            .padding(.horizontal, isLandscape ? 24 : 16)

            // MARK: - 左右縦スライダー（動画のみ、失敗時は非表示）
            if !isImage && !isFailed {
                HStack {
                    verticalBrightnessSlider
                        .reportControlFrame(in: "playerContainer")
                    Spacer()
                    verticalVolumeSlider
                        .reportControlFrame(in: "playerContainer")
                }
                .padding(.horizontal, isLandscape ? 24 : 12)
            }
        }
    }

    // MARK: - ヘッダー（縦: カプセル型、横: 全画面バー）

    @ViewBuilder
    private var headerView: some View {
        HStack(spacing: 12) {
            // 閉じるボタン（見た目32pt、内部タッチ領域44pt以上確保）
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.black.opacity(0.4), in: Circle())
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(NSLocalizedString("Close", comment: ""))

            // タイトル（ボタンを圧迫しないよう末尾省略）
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                // 編集ボタン（動画のみ、通常・Vault両方で有効、見た目32pt、内部タッチ領域44pt以上確保）
                if !isImage {
                    Button(action: onEdit) {
                        Image(systemName: "pencil")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Color.black.opacity(0.4), in: Circle())
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(NSLocalizedString("Edit", comment: ""))
                }

                // 共有・出力ボタン（通常・Vault両方で表示、見た目32pt、内部タッチ領域44pt以上確保）
                Button(action: onShare) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.black.opacity(0.4), in: Circle())
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(NSLocalizedString("Share", comment: ""))
            }
            .fixedSize(horizontal: true, vertical: false)
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

    // MARK: - 中央コントロール（前ファイル／再生・停止／次ファイル）

    private var centerControlsView: some View {
        HStack(spacing: 36) {
            // 前のファイルへ
            Button {
                onPreviousFile()
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(Color.black.opacity(0.45), in: Circle())
            }
            .disabled(!canGoPrevious)
            .opacity(canGoPrevious ? 1.0 : 0.3)
            .accessibilityLabel(NSLocalizedString("Previous File", comment: ""))
            .accessibilityHint(canGoPrevious ? NSLocalizedString("Show previous file", comment: "") : NSLocalizedString("First file", comment: ""))

            // 再生・一時停止（動画のみ表示、画像時はレイアウトバランス保持のため透明枠）
            if !isImage {
                Button(action: onTogglePlay) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .background(Color.white.opacity(0.25), in: Circle())
                        .background(.ultraThinMaterial.opacity(0.4), in: Circle())
                }
                .accessibilityLabel(isPlaying ? NSLocalizedString("Pause", comment: "") : NSLocalizedString("Play", comment: ""))
            } else {
                Color.clear
                    .frame(width: 72, height: 72)
                    .allowsHitTesting(false)
            }

            // 次のファイルへ
            Button {
                onNextFile()
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(Color.black.opacity(0.45), in: Circle())
            }
            .disabled(!canGoNext)
            .opacity(canGoNext ? 1.0 : 0.3)
            .accessibilityLabel(NSLocalizedString("Next File", comment: ""))
            .accessibilityHint(canGoNext ? NSLocalizedString("Show next file", comment: "") : NSLocalizedString("Last file", comment: ""))
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
                        .frame(height: 44)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if !isScrubbing {
                                        isScrubbing = true
                                        onInteractionStarted("scrubber")
                                    }
                                    let p = min(1.0, max(0.0, value.location.x / sliderWidth))
                                    scrubTime = duration * p
                                }
                                .onEnded { value in
                                    let p = min(1.0, max(0.0, value.location.x / sliderWidth))
                                    let finalTime = duration * p
                                    onSeekTo(finalTime)
                                    isScrubbing = false
                                    onInteractionEnded("scrubber")
                                }
                        )
                    }
                    .frame(height: 44)

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
                        Image(systemName: "repeat")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(NSLocalizedString("Restart Playback", comment: ""))
                }

                // 2. お気に入り (承認済みデザインの「星」アイコン)
                Button {
                    onToggleFavorite()
                } label: {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.system(size: 16))
                        .foregroundStyle(isFavorite ? Color.yellow : Color.white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(isFavorite ? NSLocalizedString("Remove from Favorites", comment: "") : NSLocalizedString("Add to Favorites", comment: ""))

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
                        Text(String(format: "%.1fx", playbackRate))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(NSLocalizedString("Playback Speed", comment: ""))
                    .accessibilityValue(String(format: "%.1fx", playbackRate))

                    // 4. PiP (Vault内は無効化)
                    Button(action: onTriggerPiP) {
                        Image(systemName: "pip.enter")
                            .font(.system(size: 16))
                            .foregroundStyle(isVault ? .white.opacity(0.3) : .white)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .disabled(isVault)
                    .accessibilityLabel(NSLocalizedString("Picture in Picture", comment: ""))

                    // 5. 縦横切替
                    Button(action: onToggleOrientation) {
                        OrientationSwitchIcon()
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(NSLocalizedString("Toggle Orientation", comment: ""))
                }

                // 6. … その他メニュー
                Menu {
                    if !isImage {
                        Menu(NSLocalizedString("Subtitles", comment: "")) {
                            Text(NSLocalizedString("No Subtitles", comment: ""))
                        }
                    }

                    Button(action: onMoveFile) {
                        Label(NSLocalizedString("Move File", comment: ""), systemImage: "folder")
                    }

                    Button(action: onShare) {
                        Label(NSLocalizedString("Export / Share", comment: ""), systemImage: "square.and.arrow.up")
                    }

                    Divider()

                    Button(role: .destructive, action: onDeleteFile) {
                        Label(
                            isVault ? NSLocalizedString("Delete Permanently", comment: "") : NSLocalizedString("Move to Trash", comment: ""),
                            systemImage: "trash"
                        )
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(NSLocalizedString("More Actions", comment: ""))
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
                            if !isBrightnessDragging {
                                isBrightnessDragging = true
                                onInteractionStarted("brightness")
                            }
                            let p = min(1.0, max(0.0, 1.0 - (value.location.y / h)))
                            brightness = Double(p)
                            UIScreen.main.brightness = CGFloat(p)
                        }
                        .onEnded { _ in
                            isBrightnessDragging = false
                            onInteractionEnded("brightness")
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
                            if !isVolumeDragging {
                                isVolumeDragging = true
                                onInteractionStarted("volume")
                            }
                            let p = min(1.0, max(0.0, 1.0 - (value.location.y / h)))
                            volume = Double(p)
                        }
                        .onEnded { _ in
                            isVolumeDragging = false
                            onInteractionEnded("volume")
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

// MARK: - 縦横切替ベクターアイコン（縦長＋横長画面＋回転矢印）

struct OrientationSwitchIcon: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height

            // 縦長長方形 (左奥)
            let portraitRect = CGRect(x: w * 0.08, y: h * 0.12, width: w * 0.42, height: h * 0.65)
            let portraitPath = Path(roundedRect: portraitRect, cornerRadius: 2.5)
            context.stroke(portraitPath, with: .color(.white), lineWidth: 1.4)

            // 横長長方形 (右下手前)
            let landscapeRect = CGRect(x: w * 0.36, y: h * 0.42, width: w * 0.56, height: h * 0.46)
            let landscapePath = Path(roundedRect: landscapeRect, cornerRadius: 2.5)
            context.stroke(landscapePath, with: .color(.white), lineWidth: 1.4)

            // 上部の回転円弧矢印
            var arrowArc = Path()
            arrowArc.addArc(
                center: CGPoint(x: w * 0.60, y: h * 0.28),
                radius: w * 0.26,
                startAngle: .degrees(170),
                endAngle: .degrees(315),
                clockwise: false
            )
            context.stroke(arrowArc, with: .color(.white), lineWidth: 1.4)

            // 矢印の鏃
            let tipAngle = 315.0 * Double.pi / 180.0
            let tipX = w * 0.60 + (w * 0.26) * cos(tipAngle)
            let tipY = h * 0.28 + (w * 0.26) * sin(tipAngle)
            var arrowHead = Path()
            arrowHead.move(to: CGPoint(x: tipX - 2.5, y: tipY - 4.5))
            arrowHead.addLine(to: CGPoint(x: tipX, y: tipY))
            arrowHead.addLine(to: CGPoint(x: tipX - 4.5, y: tipY - 1.5))
            context.stroke(arrowHead, with: .color(.white), lineWidth: 1.4)
        }
        .frame(width: 18, height: 16)
    }
}
