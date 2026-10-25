import SwiftUI
import AVKit
import AVFoundation

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
    @State private var isImageZoomed: Bool = false
    @State private var currentLoadedImage: UIImage?

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

            // MARK: - 背景ジェスチャー検出レイヤー
            gestureDetectionLayer

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
                        onClose: handleClose,
                        onEdit: {
                            registerUserAction()
                            showTrimmerSheet = true
                        },
                        onShare: handleShareTapped,
                        onRestart: handleRestart,
                        onTogglePlay: togglePlayPause,
                        onSeekBy: { handleSeek(offset: $0) },
                        onSeekTo: { handleSeekToTime($0) },
                        onToggleOrientation: toggleOrientation,
                        onTriggerPiP: triggerPiP,
                        onMoveFile: {
                            registerUserAction()
                            showMoveSheet = true
                        },
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
                if let img = currentLoadedImage {
                    ZoomableImageView(
                        image: img,
                        isZoomed: $isImageZoomed,
                        onTap: { toggleControlsVisibility() }
                    )
                } else {
                    ProgressView().tint(.white)
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

    // MARK: - ジェスチャー検出レイヤー

    private var gestureDetectionLayer: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            Color.clear
                .contentShape(Rectangle())
                // シングルタップで UI 表示切替
                .onTapGesture(count: 1) {
                    toggleControlsVisibility()
                }
                // ダブルタップ（左: -10秒、右: +10秒）動画のみ有効
                .highPriorityGesture(
                    TapGesture(count: 2)
                        .onEnded {
                            // ダブルタップ位置の判定（画面中央から左または右）
                            // SwiftUIのTapGestureは位置を取れないため、DragGestureまたは左右分割エリアで検出
                        }
                )
                // 水平スワイプ（左右）による次／前切り替え（画像拡大中は無効）
                .gesture(
                    DragGesture(minimumDistance: 40)
                        .onEnded { value in
                            guard !isImageZoomed else { return }
                            let horizontal = value.translation.width
                            let vertical = value.translation.height

                            // 水平判定（垂直ドラッグを無視）
                            guard abs(horizontal) > abs(vertical) * 1.5 else { return }

                            if horizontal < -50 {
                                // 左スワイプ（指を右から左へ）＝ 次へ (Next)
                                handleSwipeNext()
                            } else if horizontal > 50 {
                                // 右スワイプ（指を左から右へ）＝ 前へ (Previous)
                                handleSwipePrevious()
                            }
                        }
                )
                // 左右のダブルタップ領域オーバーレイ（動画のみ）
                .overlay(
                    HStack(spacing: 0) {
                        // 左半分: -10秒ダブルタップ
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                if let item = playlistContext.currentItem, !item.isImage {
                                    handleDoubleTapSeek(isForward: false)
                                }
                            }
                            .onTapGesture(count: 1) {
                                guard Date().timeIntervalSince(lastDoubleTapTime) > 0.35 else { return }
                                toggleControlsVisibility()
                            }

                        // 中央タップ透過領域
                        Color.clear
                            .frame(width: 80)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 1) {
                                guard Date().timeIntervalSince(lastDoubleTapTime) > 0.35 else { return }
                                toggleControlsVisibility()
                            }

                        // 右半分: +10秒ダブルタップ
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                if let item = playlistContext.currentItem, !item.isImage {
                                    handleDoubleTapSeek(isForward: true)
                                }
                            }
                            .onTapGesture(count: 1) {
                                guard Date().timeIntervalSince(lastDoubleTapTime) > 0.35 else { return }
                                toggleControlsVisibility()
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

    private func loadCurrentItem() {
        guard let item = playlistContext.currentItem else { return }

        // 前のプレイヤー・音声監視の停止
        tearDownPlayer()

        switch item {
        case .normal(let video):
            currentPlaybackURL = video.fileURL
            if video.format.isImage {
                // 画像のダウンサンプリング読み込み
                currentLoadedImage = UIImage(contentsOfFile: video.fileURL.path)
                isPlaying = false
                duration = 0.0
                currentTime = 0.0
            } else {
                currentLoadedImage = nil
                setupVideoPlayer(url: video.fileURL, isVault: false)
            }

        case .vault(let vaultItem):
            currentLoadedImage = nil
            do {
                let opID = UUID()
                let tempURL = try VaultManager.shared.preparePlaybackURL(for: vaultItem, operationID: opID)
                self.vaultActivePlaybackURL = tempURL
                self.currentPlaybackURL = tempURL
                setupVideoPlayer(url: tempURL, isVault: true)
            } catch {
                showToast("再生準備に失敗しました: \(error.localizedDescription)")
            }
        }
    }

    private func setupVideoPlayer(url: URL, isVault: Bool) {
        let (p, sid) = coordinator.startPlaybackSession(
            url: url,
            context: playlistContext,
            isVault: isVault,
            initialRate: playbackRate
        )
        self.player = p
        self.sessionID = sid
        self.isPlaying = true
        p.volume = Float(volumeValue)

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

    // MARK: - スワイプ次／前ナビゲーション

    private func handleSwipeNext() {
        activeInteractions.removeAll()
        guard playlistContext.canGoNext else {
            showToast("最後のファイルです")
            return
        }
        playlistContext.moveToNext()
        loadCurrentItem()
        if areControlsVisible {
            scheduleAutoHide(delay: 10.0)
        }
    }

    private func handleSwipePrevious() {
        activeInteractions.removeAll()
        guard playlistContext.canGoPrevious else {
            showToast("先頭のファイルです")
            return
        }
        playlistContext.moveToPrevious()
        loadCurrentItem()
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
