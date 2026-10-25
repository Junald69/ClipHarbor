import SwiftUI
import AVKit
import AVFoundation
import ImageIO

/// 刷新されたAloha風全画面メディアプレイヤー／画像ビューアー
/// - 動画: AVPlayerLayer (CustomVideoPlayerView) + 完全カスタムUI
/// - 画像: UIScrollView (ZoomableImageView) + ピンチズーム・パン
/// - カプセルヘッダー（閉じる・省略タイトル・編集・共有）
/// - 左右スワイプ（左＝次、右＝前）による安全なプレイリスト移動（境界越え・循環ループなし）
/// - 左右ダブルタップによる10秒シーク & 方向フィードバックバッジ
/// - 厳格な下部6ボタン（最初から[0秒+即再生]、星型お気に入り、速度、PiP、縦横切替、その他メニュー）
/// - 左右縦スライダー（画面照度・動画音量）
/// - iOS 16 回転制御 & 終了時のブラウザ縦画面復帰
struct ModernVideoPlayerView: View {
    @ObservedObject var playlistContext: PlaybackPlaylistContext
    let onDismiss: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    // 再生・セッション状態
    @StateObject private var coordinator = VideoPlaybackCoordinator.shared
    @State private var player: AVPlayer?
    @State private var sessionID: UUID = UUID()
    @State private var isPlaying: Bool = false
    @State private var currentTime: Double = 0.0
    @State private var duration: Double = 0.0
    @State private var playbackRate: Float = 1.0
    @State private var timeObserverToken: Any?

    // UI表示状態
    @State private var areControlsVisible: Bool = true
    @State private var autoHideTimer: Timer?
    @State private var isLandscape: Bool = false
    @State private var originalBrightness: CGFloat = 0.5
    @State private var brightnessValue: Double = 0.5
    @State private var volumeValue: Double = 1.0

    // 画像閲覧状態
    private enum ImageLoadState: Equatable {
        case loading
        case success(UIImage)
        case failure(String)
    }
    @State private var isImageZoomed: Bool = false
    @State private var imageLoadState: ImageLoadState = .loading
    @State private var imageLoadTaskID: UUID = UUID()

    // フィードバックバッジ
    @State private var seekFeedbackText: String?
    @State private var seekFeedbackIsForward: Bool = true
    @State private var seekFeedbackOpacity: Double = 0.0

    // シート表示
    @State private var showTrimmerSheet: Bool = false
    @State private var showShareSheet: Bool = false
    @State private var showMoveSheet: Bool = false
    @State private var toastMessage: String?
    @State private var showVaultShareAlert: Bool = false

    // 削除処理状態
    struct PendingDeletionContext: Identifiable {
        let item: PlaybackMediaItem
        let sessionToken: UUID?
        var id: UUID { item.id }
        var title: String { item.title }
    }
    @State private var pendingDeletionContext: PendingDeletionContext?
    @State private var isDeletingItem: Bool = false

    // 操作中状態管理・自動非表示排他制御
    @State private var activeInteractions: Set<String> = []
    @State private var timerGeneration: Int = 0
    @State private var lastDoubleTapTime: Date = .distantPast

    // Vault一時再生URL管理
    @State private var vaultActivePlaybackURL: URL?
    @State private var currentPlaybackURL: URL?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // MARK: - メディア描画レイヤー（動画 or 画像）
            mediaContentLayer
                .ignoresSafeArea()

            // MARK: - 背景ジェスチャー検出レイヤー（動画のみ）
            if let item = playlistContext.currentItem, !item.isImage {
                videoGestureDetectionLayer
            }

            // MARK: - ダブルタップ10秒シークフィードバックバッジ
            if seekFeedbackOpacity > 0 {
                seekFeedbackBadge
            }

            // MARK: - コントロールオーバーレイ
            if areControlsVisible {
                if let item = playlistContext.currentItem {
                    PlayerControlsOverlay(
                        isPlaying: $isPlaying,
                        currentTime: $currentTime,
                        duration: $duration,
                        playbackRate: $playbackRate,
                        brightness: $brightnessValue,
                        volume: $volumeValue,
                        isFavorite: Binding(
                            get: { item.isFavorite },
                            set: { _ in toggleFavoriteCurrentItem() }
                        ),
                        isLandscape: $isLandscape,
                        title: item.title,
                        isVault: playlistContext.isVault,
                        isImage: item.isImage,
                        isHLS: item.isHLS,
                        canGoNext: playlistContext.canGoNext,
                        canGoPrevious: playlistContext.canGoPrevious,
                        onClose: handleClose,
                        onEdit: {
                            registerUserAction()
                            showTrimmerSheet = true
                        },
                        onShare: handleShareTapped,
                        onRestart: handleRestart,
                        onTogglePlay: togglePlayPause,
                        onSeekTo: { handleSeekToTime($0) },
                        onNextFile: handleNavigateNext,
                        onPreviousFile: handleNavigatePrevious,
                        onToggleOrientation: toggleOrientation,
                        onTriggerPiP: triggerPiP,
                        onMoveFile: {
                            registerUserAction()
                            showMoveSheet = true
                        },
                        onDeleteFile: handleDeleteTapped,
                        onInteractionStarted: { handleInteractionStarted($0) },
                        onInteractionEnded: { handleInteractionEnded($0) }
                    )
                    .transition(.opacity.animation(.easeInOut(duration: 0.2)))
                }
            }

            // トースト表示
            if let toast = toastMessage {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.85), in: Capsule())
                        .padding(.bottom, 80)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .statusBarHidden(isLandscape || !areControlsVisible)
        .sheet(isPresented: $showTrimmerSheet) {
            trimmerDestinationView
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = currentPlaybackURL {
                ShareActivityView(activityItems: [url])
            }
        }
        .sheet(isPresented: $showMoveSheet) {
            moveFolderDestinationView
        }
        .alert("Vaultファイルの共有について", isPresented: $showVaultShareAlert) {
            Button("OK", role: .cancel) {
                scheduleAutoHide(delay: 10.0)
            }
        } message: {
            Text("Vault内の動画は直接共有できません。共有するには、通常フォルダへ戻してから共有してください。")
        }
        .alert(
            pendingDeletionContext != nil
                ? (playlistContext.isVault
                    ? "「\(pendingDeletionContext?.title ?? "")」を削除しますか？"
                    : "「\(pendingDeletionContext?.title ?? "")」をゴミ箱へ移動しますか？")
                : "",
            isPresented: Binding(
                get: { pendingDeletionContext != nil },
                set: { if !$0 && !isDeletingItem { pendingDeletionContext = nil; scheduleAutoHide(delay: 10.0) } }
            )
        ) {
            Button("キャンセル", role: .cancel) {
                pendingDeletionContext = nil
                scheduleAutoHide(delay: 10.0)
            }
            if let context = pendingDeletionContext {
                Button(playlistContext.isVault ? "削除" : "ゴミ箱へ移動", role: .destructive) {
                    executeDeletion(for: context)
                }
            }
        } message: {
            if playlistContext.isVault {
                Text("このファイルを削除します。この操作は取り消せません。")
            } else {
                Text("ゴミ箱に移動したファイルは、設定された保持期間の間保管され、後から復元できます。")
            }
        }
        .onChange(of: showTrimmerSheet) { isPresented in
            if !isPresented { scheduleAutoHide(delay: 10.0) }
        }
        .onChange(of: showShareSheet) { isPresented in
            if !isPresented { scheduleAutoHide(delay: 10.0) }
        }
        .onChange(of: showMoveSheet) { isPresented in
            if !isPresented { scheduleAutoHide(delay: 10.0) }
        }
        .onChange(of: playbackRate) { newRate in
            player?.rate = isPlaying ? newRate : 0.0
        }
        .onChange(of: volumeValue) { newVol in
            player?.volume = Float(newVol)
        }
        .onChange(of: coordinator.isTransitioningToPiP) { isTrans in
            if isTrans {
                // PiP移行が成立したためシートを閉じる（再生リソースはCoordinatorが維持）
                dismiss()
            }
        }
        .onChange(of: coordinator.shouldRestoreUIFromPiP) { shouldRestore in
            if shouldRestore {
                coordinator.notifyUIRestoredSuccessfully()
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                // ホーム画面移行時に画面照度を確実に復帰し、タイマーと操作状態をクリア
                UIScreen.main.brightness = originalBrightness
                activeInteractions.removeAll()
                stopAutoHideTimer()
            }
        }
        .onAppear {
            originalBrightness = UIScreen.main.brightness
            brightnessValue = Double(originalBrightness)
            loadCurrentItem()
            scheduleAutoHide(delay: 10.0)
        }
        .onDisappear {
            activeInteractions.removeAll()
            stopAutoHideTimer()
            handleViewDismissed()
        }
    }

    // MARK: - メディア描画レイヤー

    @ViewBuilder
    private var mediaContentLayer: some View {
        if let item = playlistContext.currentItem {
            if item.isImage {
                switch imageLoadState {
                case .loading:
                    ProgressView().tint(.white)
                case .success(let img):
                    ZoomableImageView(
                        image: img,
                        isZoomed: $isImageZoomed,
                        onTap: { toggleControlsVisibility() },
                        onSwipeNext: { handleNavigateNext() },
                        onSwipePrevious: { handleNavigatePrevious() }
                    )
                case .failure(let errorMsg):
                    VStack(spacing: 16) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 44))
                            .foregroundStyle(.white.opacity(0.8))
                        Text(errorMsg)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.8))
                        Button("再試行") {
                            loadCurrentItem(autoPlay: false)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.white.opacity(0.3))
                    }
                }
            } else {
                if let p = player {
                    CustomVideoPlayerView(player: p, sessionID: sessionID)
                } else {
                    ProgressView().tint(.white)
                }
            }
        }
    }

    // MARK: - 動画用ジェスチャー検出レイヤー

    private var videoGestureDetectionLayer: some View {
        GeometryReader { geo in
            let w = geo.size.width
            HStack(spacing: 0) {
                // 左40%: -10秒ダブルタップ & シングルタップでコントロール表示切替
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        guard !isDeletingItem && pendingDeletionContext == nil else { return }
                        handleDoubleTapSeek(isForward: false)
                    }
                    .onTapGesture(count: 1) {
                        guard !isDeletingItem && pendingDeletionContext == nil else { return }
                        guard Date().timeIntervalSince(lastDoubleTapTime) > 0.35 else { return }
                        toggleControlsVisibility()
                    }

                // 中央20%: シングルタップでコントロール表示切替
                Color.clear
                    .frame(width: max(60, w * 0.2))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 1) {
                        guard !isDeletingItem && pendingDeletionContext == nil else { return }
                        guard Date().timeIntervalSince(lastDoubleTapTime) > 0.35 else { return }
                        toggleControlsVisibility()
                    }

                // 右40%: +10秒ダブルタップ & シングルタップでコントロール表示切替
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        guard !isDeletingItem && pendingDeletionContext == nil else { return }
                        handleDoubleTapSeek(isForward: true)
                    }
                    .onTapGesture(count: 1) {
                        guard !isDeletingItem && pendingDeletionContext == nil else { return }
                        guard Date().timeIntervalSince(lastDoubleTapTime) > 0.35 else { return }
                        toggleControlsVisibility()
                    }
            }
            .gesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        guard !isDeletingItem && pendingDeletionContext == nil else { return }
                        let horizontal = value.translation.width
                        let vertical = value.translation.height
                        // 水平優位性判定（垂直スクロールや斜めドラッグを確実に除外）
                        guard abs(horizontal) > abs(vertical) * 1.5 else { return }
                        if horizontal < -50 {
                            // 左スワイプ（指を右から左へ）＝ 次へ (Next)
                            handleNavigateNext()
                        } else if horizontal > 50 {
                            // 右スワイプ（指を左から右へ）＝ 前へ (Previous)
                            handleNavigatePrevious()
                        }
                    }
            )
        }
    }

    // MARK: - 10秒シークフィードバックバッジ

    private var seekFeedbackBadge: some View {
        HStack {
            if !seekFeedbackIsForward {
                VStack(spacing: 6) {
                    Image(systemName: "gobackward.10")
                        .font(.system(size: 32, weight: .semibold))
                    Text(seekFeedbackText ?? "-10秒")
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(.white)
                .padding(20)
                .background(Color.black.opacity(0.65), in: Circle())
                .padding(.leading, 40)
            }

            Spacer()

            if seekFeedbackIsForward {
                VStack(spacing: 6) {
                    Image(systemName: "goforward.10")
                        .font(.system(size: 32, weight: .semibold))
                    Text(seekFeedbackText ?? "+10秒")
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(.white)
                .padding(20)
                .background(Color.black.opacity(0.65), in: Circle())
                .padding(.trailing, 40)
            }
        }
        .opacity(seekFeedbackOpacity)
        .allowsHitTesting(false)
    }

    // MARK: - メディアロード & ライフサイクル

    private func downsampleImage(at url: URL, maxPixelSize: CGFloat = 4096) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return UIImage(contentsOfFile: url.path)
        }
        let downsampleOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as [CFString: Any] as CFDictionary

        if let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions) {
            return UIImage(cgImage: thumbnail)
        }
        return UIImage(contentsOfFile: url.path)
    }

    private func loadImage(from url: URL) {
        let taskID = UUID()
        imageLoadTaskID = taskID
        imageLoadState = .loading
        isPlaying = false
        duration = 0.0
        currentTime = 0.0

        Task.detached(priority: .userInitiated) {
            let loaded = self.downsampleImage(at: url, maxPixelSize: 4096)
            await MainActor.run {
                guard self.imageLoadTaskID == taskID else { return }
                if let image = loaded {
                    self.imageLoadState = .success(image)
                } else {
                    self.imageLoadState = .failure("画像の読み込みに失敗しました")
                }
            }
        }
    }

    private func loadCurrentItem(autoPlay: Bool = true) {
        guard let item = playlistContext.currentItem else { return }

        // 前のプレイヤー・音声監視の停止
        tearDownPlayer()

        switch item {
        case .normal(let video):
            currentPlaybackURL = video.fileURL
            if video.format.isImage {
                loadImage(from: video.fileURL)
            } else {
                setupVideoPlayer(url: video.fileURL, isVault: false, autoPlay: autoPlay)
            }

        case .vault(let vaultItem):
            do {
                let opID = UUID()
                let tempURL = try VaultManager.shared.preparePlaybackURL(for: vaultItem, operationID: opID)
                self.vaultActivePlaybackURL = tempURL
                self.currentPlaybackURL = tempURL
                if vaultItem.format.isImage {
                    loadImage(from: tempURL)
                } else {
                    setupVideoPlayer(url: tempURL, isVault: true, autoPlay: autoPlay)
                }
            } catch {
                showToast("再生準備に失敗しました: \(error.localizedDescription)")
            }
        }
    }

    private func setupVideoPlayer(url: URL, isVault: Bool, autoPlay: Bool) {
        let (p, sid) = coordinator.startPlaybackSession(
            url: url,
            context: playlistContext,
            isVault: isVault,
            initialRate: autoPlay ? playbackRate : 0.0
        )
        self.player = p
        self.sessionID = sid
        self.isPlaying = autoPlay
        p.volume = Float(volumeValue)

        if !autoPlay {
            p.pause()
        }

        // 再生時間の監視
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserverToken = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak p] time in
            guard let player = p else { return }
            let secs = CMTimeGetSeconds(time)
            if !secs.isNaN && !secs.isInfinite {
                self.currentTime = max(0, secs)
            }
            if let itemDuration = player.currentItem?.duration {
                let d = CMTimeGetSeconds(itemDuration)
                if !d.isNaN && !d.isInfinite && d > 0 {
                    self.duration = d
                }
            }
        }
    }

    private func tearDownPlayer() {
        if let token = timeObserverToken, let p = player {
            p.removeTimeObserver(token)
            timeObserverToken = nil
        }
        player?.pause()
        player = nil

        // Vault一時再生ファイルの回収
        if let vaultTemp = vaultActivePlaybackURL {
            VaultManager.shared.cleanupPlaybackTemp(fileURL: vaultTemp)
            vaultActivePlaybackURL = nil
        }
    }

    private func handleViewDismissed() {
        tearDownPlayer()
        coordinator.stopAndRelease(sessionID: sessionID)
        UIScreen.main.brightness = originalBrightness

        // 縦画面へ確実に復帰
        if isLandscape {
            setOrientation(.portrait)
        }
        onDismiss()
    }

    // MARK: - 再生操作ロジック

    private func togglePlayPause() {
        guard let p = player else { return }
        if isPlaying {
            p.pause()
            isPlaying = false
            stopAutoHideTimer()
        } else {
            p.rate = playbackRate
            isPlaying = true
            scheduleAutoHide(delay: 10.0)
        }
    }

    private func handleRestart() {
        guard let p = player else { return }
        p.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        p.rate = playbackRate
        isPlaying = true
        registerUserAction()
    }

    private func handleSeek(offset: Double) {
        guard let p = player else { return }
        let newTime = max(0, min(duration, currentTime + offset))
        p.seek(to: CMTime(seconds: newTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = newTime
        registerUserAction()
    }

    private func handleSeekToTime(_ targetTime: Double) {
        guard let p = player else { return }
        let clamped = max(0, min(duration, targetTime))
        p.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
        registerUserAction()
    }

    private func handleDoubleTapSeek(isForward: Bool) {
        lastDoubleTapTime = Date()
        let offset: Double = isForward ? 10.0 : -10.0
        handleSeek(offset: offset)

        // フィードバックバッジ演出
        seekFeedbackIsForward = isForward
        seekFeedbackText = isForward ? "+10秒" : "-10秒"
        withAnimation(.easeIn(duration: 0.15)) {
            seekFeedbackOpacity = 1.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            withAnimation(.easeOut(duration: 0.25)) {
                seekFeedbackOpacity = 0.0
            }
        }
    }

    // MARK: - 次／前メディアナビゲーション（スワイプ & ボタン共有）

    private func handleNavigateNext() {
        navigateToItem(isNext: true)
    }

    private func handleNavigatePrevious() {
        navigateToItem(isNext: false)
    }

    private func navigateToItem(isNext: Bool) {
        guard !isDeletingItem && pendingDeletionContext == nil else { return }

        // 1. 境界チェック（リソース破棄前に行う。境界到達時はトーストを出さず再生停止もしない）
        let canNavigate = isNext ? playlistContext.canGoNext : playlistContext.canGoPrevious
        guard canNavigate else { return }

        // 2. 現在のメディア種別と再生中状態の保存
        let currentItem = playlistContext.currentItem
        let wasImage = currentItem?.isImage ?? false
        let wasPlaying = !wasImage && isPlaying

        // 3. インデックスの移動
        let targetItem = isNext ? playlistContext.moveToNext() : playlistContext.moveToPrevious()
        guard let newItem = targetItem else { return }

        // 4. 次のメディアの自動再生判定:
        // - 動画 -> 動画: 再生状態をそのまま引き継ぐ
        // - 動画 -> 画像: 画像は自動再生不可 (false)
        // - 画像 -> 動画: 不意な大音量再生を防ぐため停止状態で開始 (false)
        // - 画像 -> 画像: (false)
        let shouldAutoPlay: Bool
        if !wasImage && !newItem.isImage {
            shouldAutoPlay = wasPlaying
        } else {
            shouldAutoPlay = false
        }

        // 5. 前のリソース解放
        activeInteractions.removeAll()
        tearDownPlayer()

        // 6. 新しいアイテムのロード
        loadCurrentItem(autoPlay: shouldAutoPlay)

        // 7. コントロール表示中なら自動非表示タイマーをリセット
        if areControlsVisible {
            scheduleAutoHide(delay: 10.0)
        }
    }

    private func toggleFavoriteCurrentItem() {
        registerUserAction()
        guard let item = playlistContext.currentItem else { return }
        switch item {
        case .normal(let video):
            VideoFolderManager(downloads: .shared).toggleFavorite(for: video)
        case .vault(let vaultItem):
            VaultManager.shared.toggleFavorite(for: vaultItem)
        }
    }

    // MARK: - UI表示・自動非表示（10秒保持・操作中消去防止）

    private func toggleControlsVisibility() {
        withAnimation(.easeInOut(duration: 0.2)) {
            areControlsVisible.toggle()
        }
        if areControlsVisible {
            scheduleAutoHide(delay: 10.0)
        } else {
            stopAutoHideTimer()
            activeInteractions.removeAll()
        }
    }

    private func registerUserAction() {
        if areControlsVisible {
            scheduleAutoHide(delay: 10.0)
        }
    }

    private func handleInteractionStarted(_ source: String) {
        activeInteractions.insert(source)
        stopAutoHideTimer()
    }

    private func handleInteractionEnded(_ source: String) {
        activeInteractions.remove(source)
        if activeInteractions.isEmpty && areControlsVisible && isPlaying {
            scheduleAutoHide(delay: 10.0)
        }
    }

    private func scheduleAutoHide(delay: Double = 10.0) {
        stopAutoHideTimer()
        guard areControlsVisible,
              isPlaying,
              activeInteractions.isEmpty,
              pendingDeletionContext == nil,
              !isDeletingItem,
              !showTrimmerSheet,
              !showShareSheet,
              !showMoveSheet,
              !showVaultShareAlert,
              !UIAccessibility.isVoiceOverRunning else { return }

        timerGeneration += 1
        let currentGen = timerGeneration

        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            Task { @MainActor in
                guard self.timerGeneration == currentGen else { return }
                guard self.areControlsVisible,
                      self.isPlaying,
                      self.activeInteractions.isEmpty,
                      self.pendingDeletionContext == nil,
                      !self.isDeletingItem,
                      !self.showTrimmerSheet,
                      !self.showShareSheet,
                      !self.showMoveSheet,
                      !self.showVaultShareAlert,
                      !UIAccessibility.isVoiceOverRunning else { return }

                withAnimation(.easeInOut(duration: 0.25)) {
                    self.areControlsVisible = false
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.autoHideTimer = timer
    }

    private func stopAutoHideTimer() {
        timerGeneration += 1
        autoHideTimer?.invalidate()
        autoHideTimer = nil
    }

    // MARK: - 画面回転 (iOS 16+ API)

    private func toggleOrientation() {
        activeInteractions.removeAll()
        registerUserAction()
        let target: UIInterfaceOrientationMask = isLandscape ? .portrait : .landscapeRight
        setOrientation(target)
    }

    private func setOrientation(_ orientation: UIInterfaceOrientationMask) {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        let geomUpdate = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: orientation)
        windowScene.requestGeometryUpdate(geomUpdate) { error in
            print("[ModernVideoPlayerView] 回転リクエスト失敗: \(error.localizedDescription)")
        }
        isLandscape = (orientation != .portrait)
    }

    // MARK: - PiP 起動

    private func triggerPiP() {
        registerUserAction()
        guard !playlistContext.isVault else {
            showToast("Vault内アイテムではPiPは利用できません")
            return
        }
        coordinator.startPictureInPicture(sessionID: sessionID)
    }

    // MARK: - 共有・書き出し

    private func handleShareTapped() {
        registerUserAction()
        guard !playlistContext.isVault else {
            showVaultShareAlert = true
            return
        }
        guard let url = currentPlaybackURL, FileManager.default.fileExists(atPath: url.path) else {
            showToast("共有対象ファイルが見つかりません")
            return
        }
        showShareSheet = true
    }

    // MARK: - ファイル削除処理

    private func handleDeleteTapped() {
        guard !isDeletingItem, pendingDeletionContext == nil else { return }
        guard let current = playlistContext.currentItem else { return }
        stopAutoHideTimer()
        let token = playlistContext.isVault ? VaultManager.shared.sessionToken : nil
        pendingDeletionContext = PendingDeletionContext(item: current, sessionToken: token)
    }

    private func executeDeletion(for context: PendingDeletionContext) {
        guard !isDeletingItem else { return }
        let targetItem = context.item
        let targetID = context.id
        let expectedToken = context.sessionToken
        let savedTime = currentTime
        let savedRate = playbackRate
        let savedPlaying = isPlaying
        let wasImage = targetItem.isImage
        let isVault = playlistContext.isVault

        // 1. 再生リソース解放前の検証（保持したトークンとの一致 & isUnlocked）
        if isVault {
            guard let expected = expectedToken,
                  VaultManager.shared.isUnlocked,
                  VaultManager.shared.sessionToken == expected else {
                pendingDeletionContext = nil
                handleClose()
                return
            }
        }

        // 2. 状態更新と再生・リソースの確実な解放
        isDeletingItem = true
        stopAutoHideTimer()
        activeInteractions.removeAll()
        tearDownPlayer()

        // 3. 削除処理の非同期実行
        Task { @MainActor in
            var deleteSuccess = false
            var errorMessage: String? = nil

            switch targetItem {
            case .normal(let video):
                let folder = VideoFolderManager(downloads: .shared).folderName(for: video)
                let result = await TrashManager.shared.moveToTrash(
                    video: video,
                    folderName: folder,
                    downloads: .shared,
                    folderManager: VideoFolderManager(downloads: .shared)
                )
                switch result {
                case .success:
                    deleteSuccess = true
                case .failure(let error):
                    deleteSuccess = false
                    errorMessage = error.localizedDescription
                }

            case .vault(let vaultItem):
                // 実際の削除処理直前の検証（保持したトークンとの一致 & isUnlocked）
                guard let expected = expectedToken,
                      VaultManager.shared.isUnlocked,
                      VaultManager.shared.sessionToken == expected else {
                    isDeletingItem = false
                    pendingDeletionContext = nil
                    handleClose()
                    return
                }
                do {
                    try VaultManager.shared.deletePermanently(item: vaultItem, expectedSessionToken: expected)
                    deleteSuccess = true
                } catch {
                    deleteSuccess = false
                    errorMessage = error.localizedDescription
                }
            }

            // 4. 非同期処理完了後、プレイリスト更新前の検証
            if deleteSuccess {
                if isVault {
                    guard let expected = expectedToken,
                          VaultManager.shared.isUnlocked,
                          VaultManager.shared.sessionToken == expected else {
                        isDeletingItem = false
                        pendingDeletionContext = nil
                        handleClose()
                        return
                    }
                }

                isDeletingItem = false
                pendingDeletionContext = nil

                let nextItem = playlistContext.removeItem(id: targetID)
                if nextItem == nil {
                    // 残り0件なら一覧へ戻る
                    handleClose()
                } else {
                    // 削除後の自動切り替え先は一時停止状態にし、画像ならそのまま表示
                    loadCurrentItem(autoPlay: false)
                    if areControlsVisible {
                        scheduleAutoHide(delay: 10.0)
                    }
                }
            } else {
                // 5. 削除失敗時の復帰処理
                isDeletingItem = false
                pendingDeletionContext = nil
                showToast("削除に失敗しました: \(errorMessage ?? "不明なエラー")")

                if isVault {
                    // 削除失敗後、元ファイルを復号・再表示する前の検証
                    guard let expected = expectedToken,
                          VaultManager.shared.isUnlocked,
                          VaultManager.shared.sessionToken == expected else {
                        // 不一致なら再復号・画面復帰を行わず安全に終了
                        handleClose()
                        return
                    }
                }

                // 検証OKの場合のみ元ファイルへ復帰
                loadCurrentItem(autoPlay: savedPlaying)
                if !wasImage, let p = player {
                    await p.seek(to: CMTime(seconds: savedTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                    currentTime = savedTime
                    p.rate = savedPlaying ? savedRate : 0.0
                    isPlaying = savedPlaying
                }
                if areControlsVisible && savedPlaying {
                    scheduleAutoHide(delay: 10.0)
                }
            }
        }
    }

    private func handleClose() {
        activeInteractions.removeAll()
        stopAutoHideTimer()
        coordinator.stopAndRelease(sessionID: sessionID)
        dismiss()
    }

    private func showToast(_ message: String) {
        withAnimation {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation {
                if toastMessage == message {
                    toastMessage = nil
                }
            }
        }
    }

    // MARK: - トリミング・移動シート遷移

    @ViewBuilder
    private var trimmerDestinationView: some View {
        if let url = currentPlaybackURL, let item = playlistContext.currentItem {
            VideoTrimmerView(
                sourceURL: url,
                originalTitle: item.title,
                isHLS: item.isHLS,
                isVault: playlistContext.isVault,
                onSaveRenameOnly: { newTitle in
                    handleRenameOnly(newTitle: newTitle)
                },
                onSaveClip: { tempURL, clipTitle, timeRange in
                    try await handleSaveClip(tempURL: tempURL, clipTitle: clipTitle)
                }
            )
        }
    }

    private func handleRenameOnly(newTitle: String) {
        guard let item = playlistContext.currentItem else { return }
        switch item {
        case .normal(let video):
            let folderManager = VideoFolderManager(downloads: .shared)
            _ = folderManager.renameVideo(video, to: newTitle)
            showToast("タイトルを変更しました")
        case .vault(let vaultItem):
            do {
                try VaultManager.shared.renameVaultItem(vaultItem, to: newTitle)
                showToast("タイトルを変更しました")
            } catch {
                showToast("タイトルの変更に失敗しました: \(error.localizedDescription)")
            }
        }
    }

    private func handleSaveClip(tempURL: URL, clipTitle: String) async throws {
        guard let item = playlistContext.currentItem else { return }
        switch item {
        case .normal(let video):
            // 新規MP4クリップとして登録
            let ext = tempURL.pathExtension.isEmpty ? "mp4" : tempURL.pathExtension
            let root = try VideoFolderManager.ensureDownloadsDirectory()
            let clean = FileNaming.sanitizedBaseName(clipTitle)
            let destURL = FileNaming.uniqueDestination(in: root, baseName: clean, fileExtension: ext)

            try FileManager.default.moveItem(at: tempURL, to: destURL)
            guard let rel = SavedVideo.relativePath(for: destURL) else {
                throw NSError(domain: "Player", code: 500, userInfo: [NSLocalizedDescriptionKey: "保存パスの生成に失敗しました。"])
            }

            let newVideo = SavedVideo(
                id: UUID(),
                title: clean,
                relativePath: rel,
                format: .mp4,
                sourceHost: video.sourceHost,
                createdAt: Date(),
                byteSize: (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? Int64) ?? 0,
                sourcePageURL: video.sourcePageURL,
                isFavorite: false
            )
            DownloadCenter.shared.registerExportedVideo(newVideo)
            showToast("「\(clean)」を新しいクリップとして保存しました")

        case .vault(let vaultItem):
            do {
                _ = try await VaultManager.shared.addEncryptedClip(tempURL: tempURL, clipTitle: clipTitle, sourceVaultItem: vaultItem)
                showToast("「\(clipTitle)」をVault内にクリップ保存しました")
            } catch {
                showToast("Vault内クリップ保存に失敗しました: \(error.localizedDescription)")
            }
        }
    }

    @ViewBuilder
    private var moveFolderDestinationView: some View {
        if let item = playlistContext.currentItem, case .normal(let video) = item {
            let folderManager = VideoFolderManager(downloads: .shared)
            MoveToFolderSheet(
                video: video,
                currentFolder: folderManager.folderName(for: video),
                folders: folderManager.folders,
                onSelectFolder: { targetFolder in
                    _ = folderManager.moveVideo(video, toFolder: targetFolder)
                    showToast("ファイルを移動しました")
                }
            )
        }
    }
}

/// 共有用 UIActivityViewController ラッパー
struct ShareActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
