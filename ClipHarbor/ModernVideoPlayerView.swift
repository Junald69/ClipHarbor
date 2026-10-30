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
    @State private var playbackSessionID: UUID? = nil
    @State private var viewGenerationID: UUID = UUID()
    @State private var isPlaying: Bool = false
    @State private var currentTime: Double = 0.0
    @State private var duration: Double = 0.0
    @State private var playbackRate: Float = 1.0
    @State private var isSyncingPlaybackRate: Bool = false
    @State private var timeObserverToken: Any?

    // 実機診断用状態（HLS Diagnostics）
    @State private var showDiagnosticsSheet: Bool = false
    @State private var showDiagnosticsPrompt: Bool = false
    @State private var diagnosticReport: String = ""
    @State private var hasCopiedDiagnostics: Bool = false
    @State private var diagnosticsTimer: Timer?
    @State private var playerSetupDate: Date = Date()

    // UI表示状態
    @State private var areControlsVisible: Bool = true
    @State private var autoHideTimer: Timer?
    @State private var isLandscape: Bool = false
    @State private var originalBrightness: CGFloat = 0.5
    @State private var brightnessValue: Double = 0.5
    @State private var volumeValue: Double = 1.0
    @State private var isDismissingDueToPiP: Bool = false

    // 動画読み込み状態
    private enum VideoLoadState: Equatable {
        case preparing
        case ready
        case failed(domain: String, code: Int)
    }
    private var isVideoFailed: Bool {
        if case .failed = videoLoadState { return true }
        return false
    }
    @State private var videoLoadState: VideoLoadState = .preparing
    @State private var itemStatusObserver: NSKeyValueObservation?
    @State private var playerStatusObserver: NSKeyValueObservation?
    @State private var timeControlStatusObserver: NSKeyValueObservation?
    @State private var itemDidPlayToEndObserver: NSObjectProtocol?

    // 画像閲覧状態
    private enum ImageLoadState: Equatable {
        case loading
        case success(UIImage)
        case failure(String)
    }
    @State private var isImageZoomed: Bool = false
    @State private var imageLoadState: ImageLoadState = .loading
    @State private var imageLoadTaskID: UUID = UUID()
    @State private var videoLoadTaskID: UUID = UUID()

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
    @State private var controlExclusionFrames: [CGRect] = []
    @State private var isCurrentDragSwipeEligible: Bool? = nil
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

            // MARK: - 背景ジェスチャー検出レイヤー（動画のみ・失敗時は無効化して再試行ボタンのタップを確保）
            if let item = playlistContext.currentItem, !item.isImage, !isVideoFailed {
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
                        isFavorite: item.isFavorite,
                        isLandscape: $isLandscape,
                        title: item.title,
                        isVault: playlistContext.isVault,
                        isImage: item.isImage,
                        isHLS: item.isHLS,
                        canGoNext: playlistContext.canGoNext,
                        canGoPrevious: playlistContext.canGoPrevious,
                        isFailed: isVideoFailed,
                        onShowDiagnostics: AppSettingsManager.shared.enableDeveloperDiagnostics ? {
                            diagnosticReport = buildDiagnosticReport()
                            showDiagnosticsSheet = true
                        } : nil,
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
                        onRestoreFile: playlistContext.isVault ? handleRestoreVaultFile : nil,
                        onDeleteFile: handleDeleteTapped,
                        onToggleFavorite: toggleFavoriteCurrentItem,
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
        .coordinateSpace(name: "playerContainer")
        .onPreferenceChange(ControlExclusionFramesPreferenceKey.self) { frames in
            self.controlExclusionFrames = frames
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
        .sheet(isPresented: $showDiagnosticsSheet) {
            diagnosticsSheetView
        }
        .alert(NSLocalizedString("Sharing Vault Files", comment: ""), isPresented: $showVaultShareAlert) {
            Button(NSLocalizedString("OK", comment: ""), role: .cancel) {
                scheduleAutoHide(delay: 10.0)
            }
        } message: {
            Text(NSLocalizedString("Videos in Private Vault cannot be shared directly. Move the video back to a normal folder before sharing.", comment: ""))
        }
        .alert(
            pendingDeletionContext != nil
                ? (playlistContext.isVault
                    ? String(format: NSLocalizedString("Permanently delete \"%@\"?", comment: ""), pendingDeletionContext?.title ?? "")
                    : String(format: NSLocalizedString("Move \"%@\" to Trash?", comment: ""), pendingDeletionContext?.title ?? ""))
                : "",
            isPresented: Binding(
                get: { pendingDeletionContext != nil },
                set: { if !$0 && !isDeletingItem { pendingDeletionContext = nil; scheduleAutoHide(delay: 10.0) } }
            )
        ) {
            Button(NSLocalizedString("Cancel", comment: ""), role: .cancel) {
                pendingDeletionContext = nil
                scheduleAutoHide(delay: 10.0)
            }
            if let context = pendingDeletionContext {
                Button(
                    playlistContext.isVault ? NSLocalizedString("Delete Permanently", comment: "") : NSLocalizedString("Move to Trash", comment: ""),
                    role: .destructive
                ) {
                    executeDeletion(for: context)
                }
            }
        } message: {
            if playlistContext.isVault {
                Text(NSLocalizedString("This file will be permanently deleted. This action cannot be undone.", comment: ""))
            } else {
                Text(NSLocalizedString("Files moved to trash are kept for the configured retention period and can be restored later.", comment: ""))
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
            registerUserAction()
            guard !isSyncingPlaybackRate else { return }
            let snapped = PlaybackSpeedFormatter.snapToStandardSpeed(newRate)
            coordinator.updatePlaybackRate(snapped)
            if isPlaying, let p = player, p.currentItem?.status == .readyToPlay {
                p.playImmediately(atRate: snapped)
            } else if !isPlaying {
                player?.rate = 0.0
            }
        }
        .onChange(of: volumeValue) { newVol in
            player?.volume = Float(newVol)
        }
        .onChange(of: coordinator.shouldDismissPlayerForPiP) { shouldDismiss in
            if shouldDismiss {
                coordinator.shouldDismissPlayerForPiP = false
                isDismissingDueToPiP = true
                dismiss()
            }
        }
        .onChange(of: coordinator.pipErrorMessage) { errorMsg in
            if let msg = errorMsg {
                showToast(msg)
                coordinator.pipErrorMessage = nil
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                // ホーム画面移行時に画面照度を確実に復帰し、タイマーと操作状態をクリア
                UIScreen.main.brightness = originalBrightness
                activeInteractions.removeAll()
                isCurrentDragSwipeEligible = nil
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
            isCurrentDragSwipeEligible = nil
            stopAutoHideTimer()
            // 画面を離れる際の明るさ復元など、再生停止とは無関係な後始末は常に維持
            UIScreen.main.brightness = originalBrightness
            if isLandscape {
                setOrientation(.portrait)
            }
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
                        Button("Retry") {
                            loadCurrentItem(autoPlay: false)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.white.opacity(0.3))
                    }
                }
            } else {
                switch videoLoadState {
                case .preparing:
                    ZStack {
                        if let p = player {
                            CustomVideoPlayerView(player: p, sessionID: playbackSessionID ?? viewGenerationID)
                        }
                        VStack(spacing: 12) {
                            ProgressView().tint(.white)
                            if AppSettingsManager.shared.enableDeveloperDiagnostics && showDiagnosticsPrompt {
                                Button {
                                    diagnosticReport = buildDiagnosticReport()
                                    showDiagnosticsSheet = true
                                } label: {
                                    Label("HLS Diagnostics", systemImage: "stethoscope")
                                        .font(.caption.weight(.medium))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(.ultraThinMaterial, in: Capsule())
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                    }
                case .ready:
                    if let p = player {
                        CustomVideoPlayerView(player: p, sessionID: playbackSessionID ?? viewGenerationID)
                    } else {
                        ProgressView().tint(.white)
                    }
                case .failed(let domain, let code):
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 44))
                            .foregroundStyle(.white.opacity(0.8))
                        Text(NSLocalizedString("Playback Failed", comment: ""))
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text(String(format: NSLocalizedString("Error: %@ (%lld)", comment: ""), domain, Int64(code)))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                        HStack(spacing: 12) {
                            Button(NSLocalizedString("Retry", comment: "")) {
                                loadCurrentItem(autoPlay: true)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.white.opacity(0.3))

                            if AppSettingsManager.shared.enableDeveloperDiagnostics {
                                Button {
                                    diagnosticReport = buildDiagnosticReport()
                                    showDiagnosticsSheet = true
                                } label: {
                                    Label("Diagnostics", systemImage: "stethoscope")
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.white.opacity(0.3))
                            }
                        }
                    }
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
                DragGesture(minimumDistance: 25, coordinateSpace: .named("playerContainer"))
                    .onChanged { value in
                        if isCurrentDragSwipeEligible == nil {
                            let startPoint = value.startLocation
                            let isControlActive = !activeInteractions.isEmpty
                            let isInsideControl = areControlsVisible && controlExclusionFrames.contains { $0.insetBy(dx: -10, dy: -10).contains(startPoint) }
                            let isBlocked = isDeletingItem || pendingDeletionContext != nil || isControlActive || isInsideControl
                            isCurrentDragSwipeEligible = !isBlocked
                        }
                    }
                    .onEnded { value in
                        defer { isCurrentDragSwipeEligible = nil }
                        guard isCurrentDragSwipeEligible == true else { return }
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
                    Text(seekFeedbackText ?? "-10s")
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
                    Text(seekFeedbackText ?? "+10s")
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
                    self.imageLoadState = .failure(NSLocalizedString("Failed to load image", comment: ""))
                }
            }
        }
    }

    private func loadCurrentItem(autoPlay: Bool = true) {
        guard let item = playlistContext.currentItem else { return }

        // 前のプレイヤー・音声監視の停止
        let prevSID = playbackSessionID
        tearDownPlayer()

        switch item {
        case .normal(let video):
            currentPlaybackURL = video.fileURL
            if video.format.isImage {
                playbackSessionID = nil
                coordinator.stopAndRelease(sessionID: prevSID)
                loadImage(from: video.fileURL)
            } else {
                let taskID = UUID()
                videoLoadTaskID = taskID
                videoLoadState = .preparing
                Task { @MainActor in
                    // Web動画の一時停止を待機（最大250ms）
                    await TabManager.shared?.pauseAllBrowserMedia()
                    // 待機中に画面が閉じられた、または別の動画へ移動した場合は破棄
                    guard self.videoLoadTaskID == taskID else { return }
                    self.setupVideoPlayer(url: video.fileURL, isVault: false, autoPlay: autoPlay)
                }
            }

        case .vault(let vaultItem):
            do {
                let opID = UUID()
                let tempURL = try VaultManager.shared.preparePlaybackURL(for: vaultItem, operationID: opID)
                self.vaultActivePlaybackURL = tempURL
                self.currentPlaybackURL = tempURL
                if vaultItem.format.isImage {
                    playbackSessionID = nil
                    coordinator.stopAndRelease(sessionID: prevSID)
                    loadImage(from: tempURL)
                } else {
                    let taskID = UUID()
                    videoLoadTaskID = taskID
                    videoLoadState = .preparing
                    Task { @MainActor in
                        // Web動画の一時停止を待機（最大250ms）
                        await TabManager.shared?.pauseAllBrowserMedia()
                        // 待機中に画面が閉じられた、または別の動画へ移動した場合は破棄
                        guard self.videoLoadTaskID == taskID else { return }
                        self.setupVideoPlayer(url: tempURL, isVault: true, autoPlay: autoPlay)
                    }
                }
            } catch {
                showToast(String(format: NSLocalizedString("Failed to prepare playback: %@", comment: ""), error.localizedDescription))
            }
        }
    }

    private func setupVideoPlayer(url: URL, isVault: Bool, autoPlay: Bool) {
        videoLoadState = .preparing
        currentTime = 0.0
        duration = 0.0
        self.isPlaying = autoPlay

        // セーフな匿名診断ログ（個人ファイル名・生URL・生パスを出力しない）
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let isReadable = FileManager.default.isReadableFile(atPath: url.path)
        let isHLS = url.pathExtension.lowercased() == "movpkg" || playlistContext.currentItem?.isHLS == true
        let asset = AVURLAsset(url: url)
        let isOfflinePlayable = asset.assetCache?.isPlayableOffline
        let docPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? ""
        let cachesPath = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.path ?? ""
        let homePath = NSHomeDirectory()
        let isUnderDocs = !docPath.isEmpty && url.path.hasPrefix(docPath)
        let isUnderCaches = !cachesPath.isEmpty && url.path.hasPrefix(cachesPath)
        let isUnderHome = !homePath.isEmpty && url.path.hasPrefix(homePath)
        let scheme = url.scheme ?? "nil"
        let ext = url.pathExtension.lowercased()
        print("[PlayerDiag] setup scheme=\(scheme) isFile=\(url.isFileURL) ext=\(ext) isDir=\(isDir.boolValue) exists=\(exists) isReadable=\(isReadable) offlinePlayable=\(String(describing: isOfflinePlayable)) underHome=\(isUnderHome) underDocs=\(isUnderDocs) underCaches=\(isUnderCaches) isHLS=\(isHLS) autoPlay=\(autoPlay)")

        // PiP中または復帰中の既存セッションがある場合は再利用（startPlaybackSession による再初期化を防止）
        if !isVault,
           (coordinator.isPiPActive || coordinator.isRestoringUI),
           let (existingPlayer, existingSID) = coordinator.reconnectSession(for: playlistContext) {
            self.player = existingPlayer
            self.playbackSessionID = existingSID
            let currentRate = existingPlayer.rate
            let rawRate = (currentRate > 0.0) ? currentRate : coordinator.activePlaybackRate
            let preservedRate = PlaybackSpeedFormatter.snapToStandardSpeed(rawRate)
            self.isSyncingPlaybackRate = true
            self.playbackRate = preservedRate
            DispatchQueue.main.async {
                self.isSyncingPlaybackRate = false
            }
            self.isPlaying = (currentRate > 0.0) || (existingPlayer.timeControlStatus == .waitingToPlayAtSpecifiedRate)
            existingPlayer.volume = Float(volumeValue)
            let currentSecs = CMTimeGetSeconds(existingPlayer.currentTime())
            if !currentSecs.isNaN && !currentSecs.isInfinite {
                self.currentTime = max(0, currentSecs)
            }
            if let d = existingPlayer.currentItem?.duration {
                let secs = CMTimeGetSeconds(d)
                if !secs.isNaN && !secs.isInfinite && secs > 0 {
                    self.duration = secs
                }
            }
            if existingPlayer.currentItem?.status == .readyToPlay {
                diagnosticsTimer?.invalidate()

        diagnosticsTimer = nil

        showDiagnosticsPrompt = false

        self.videoLoadState = .ready
            }
            let gen = self.viewGenerationID
            attachTimeObserver(for: existingPlayer, generation: gen)
            observePlayerAndItem(player: existingPlayer, generation: gen, isReconnect: true)
            return
        }

        let (p, sid) = coordinator.startPlaybackSession(
            url: url,
            context: playlistContext,
            isVault: isVault,
            initialRate: autoPlay ? playbackRate : 0.0
        )
        self.player = p
        self.playbackSessionID = sid
        p.volume = Float(volumeValue)

        if !autoPlay {
            p.pause()
        }

        playerSetupDate = Date()
        showDiagnosticsPrompt = false
        diagnosticsTimer?.invalidate()
        diagnosticsTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: false) { [weak coordinator] _ in
            DispatchQueue.main.async {
                if self.videoLoadState != .ready {
                    self.diagnosticReport = self.buildDiagnosticReport()
                    self.showDiagnosticsPrompt = true
                    print("[PlayerDiag] 15s timeout snapshot taken")
                }
            }
        }

        let gen = self.viewGenerationID
        attachTimeObserver(for: p, generation: gen)
        observePlayerAndItem(player: p, generation: gen, isReconnect: false)
    }

    private func observePlayerAndItem(player: AVPlayer, generation targetGen: UUID, isReconnect: Bool) {
        itemStatusObserver?.invalidate()
        itemStatusObserver = nil
        playerStatusObserver?.invalidate()
        playerStatusObserver = nil
        timeControlStatusObserver?.invalidate()
        timeControlStatusObserver = nil
        if let endObserver = itemDidPlayToEndObserver {
            NotificationCenter.default.removeObserver(endObserver)
            itemDidPlayToEndObserver = nil
        }

        // Player level status
        playerStatusObserver = player.observe(\.status, options: [.initial, .new]) { [weak player] p, _ in
            DispatchQueue.main.async {
                guard self.viewGenerationID == targetGen,
                      let currentP = self.player,
                      currentP === player else {
                    return
                }
                if p.status == .failed {
                    let nsError = p.error as NSError?
                    let domain = nsError?.domain ?? "AVPlayer"
                    let code = nsError?.code ?? -1
                    let underlying = nsError?.userInfo[NSUnderlyingErrorKey] as? NSError
                    let uDomain = underlying?.domain ?? "none"
                    let uCode = underlying?.code ?? 0
                    print("[PlayerDiag] player failed domain=\(domain) code=\(code) uDomain=\(uDomain) uCode=\(uCode)")
                    diagnosticsTimer?.invalidate()

        diagnosticsTimer = nil

        self.diagnosticReport = self.buildDiagnosticReport()

        self.videoLoadState = .failed(domain: domain, code: code)
                    self.isPlaying = false
                    self.areControlsVisible = true
                    self.stopAutoHideTimer()
                }
            }
        }

        // TimeControlStatus
        timeControlStatusObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak player] p, _ in
            DispatchQueue.main.async {
                guard self.viewGenerationID == targetGen,
                      let currentP = self.player,
                      currentP === player else {
                    return
                }
                print("[PlayerDiag] timeControlStatus=\(p.timeControlStatus.rawValue) rate=\(p.rate)")
            }
        }

        guard let item = player.currentItem else { return }

        itemStatusObserver = item.observe(\.status, options: [.initial, .new]) { [weak player] currentItem, _ in
            DispatchQueue.main.async {
                guard self.viewGenerationID == targetGen,
                      let currentP = self.player,
                      currentP === player,
                      currentP.currentItem === currentItem else {
                    return
                }

                switch currentItem.status {
                case .readyToPlay:
                    self.handleItemReady(player: currentP, item: currentItem, generation: targetGen, isReconnect: isReconnect)
                case .failed:
                    self.handleItemFailed(item: currentItem, generation: targetGen)
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }

        itemDidPlayToEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak player] notification in
            guard self.viewGenerationID == targetGen,
                  let currentP = self.player,
                  currentP === player,
                  let endItem = notification.object as? AVPlayerItem,
                  currentP.currentItem === endItem else {
                return
            }
            self.handlePlaybackEnded()
        }
    }

    private func handlePlaybackEnded() {
        stopAutoHideTimer()
        isPlaying = false
        if duration > 0 {
            currentTime = duration
        }
        withAnimation(.easeInOut(duration: 0.25)) {
            areControlsVisible = true
        }
    }

    private func handleItemReady(player: AVPlayer, item: AVPlayerItem, generation targetGen: UUID, isReconnect: Bool) {
        guard self.viewGenerationID == targetGen, self.player === player else { return }
        guard self.videoLoadState != .ready else { return }
        print("[PlayerDiag] item readyToPlay isPlayingIntent=\(self.isPlaying) rate=\(self.playbackRate) isReconnect=\(isReconnect)")
        self.videoLoadState = .ready

        let d = CMTimeGetSeconds(item.duration)
        if !d.isNaN && !d.isInfinite && d > 0 {
            self.duration = d
        }

        if !isReconnect {
            if self.isPlaying {
                player.playImmediately(atRate: self.playbackRate)
            } else {
                player.pause()
            }
        }
    }

    private func handleItemFailed(item: AVPlayerItem, generation targetGen: UUID) {
        guard self.viewGenerationID == targetGen, self.player?.currentItem === item else { return }
        if case .failed = self.videoLoadState { return }
        let nsError = item.error as NSError?
        let domain = nsError?.domain ?? "AVPlayerItem"
        let code = nsError?.code ?? -1
        let underlying = nsError?.userInfo[NSUnderlyingErrorKey] as? NSError
        let uDomain = underlying?.domain ?? "none"
        let uCode = underlying?.code ?? 0
        print("[PlayerDiag] item failed domain=\(domain) code=\(code) uDomain=\(uDomain) uCode=\(uCode)")
        self.videoLoadState = .failed(domain: domain, code: code)
        self.isPlaying = false
        self.areControlsVisible = true
        self.stopAutoHideTimer()
    }

    private func attachTimeObserver(for p: AVPlayer, generation targetGen: UUID) {
        if let token = timeObserverToken {
            p.removeTimeObserver(token)
            timeObserverToken = nil
        }
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserverToken = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak p] time in
            guard let player = p, self.player === player, self.viewGenerationID == targetGen else { return }
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
        videoLoadTaskID = UUID() // 待機中の動画ロードタスクを無効化
        diagnosticsTimer?.invalidate()
        diagnosticsTimer = nil
        showDiagnosticsPrompt = false
        viewGenerationID = UUID() // 読み込み世代を更新し、メインキューに残った古い動画の通知を確実に破棄
        itemStatusObserver?.invalidate()
        itemStatusObserver = nil
        playerStatusObserver?.invalidate()
        playerStatusObserver = nil
        timeControlStatusObserver?.invalidate()
        timeControlStatusObserver = nil
        if let endObserver = itemDidPlayToEndObserver {
            NotificationCenter.default.removeObserver(endObserver)
            itemDidPlayToEndObserver = nil
        }

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
        if isDismissingDueToPiP || coordinator.isPiPActive {
            // PiPへ移行したため全画面を閉じるケース:
            // AVPlayerとCoordinatorの再生セッションを破棄せず保持しつつ、画面ローカルの監視・世代を切り離す
            viewGenerationID = UUID()
            itemStatusObserver?.invalidate()
            itemStatusObserver = nil
            playerStatusObserver?.invalidate()
            playerStatusObserver = nil
            timeControlStatusObserver?.invalidate()
            timeControlStatusObserver = nil
            if let endObserver = itemDidPlayToEndObserver {
                NotificationCenter.default.removeObserver(endObserver)
                itemDidPlayToEndObserver = nil
            }
            if let token = timeObserverToken, let p = player {
                p.removeTimeObserver(token)
                timeObserverToken = nil
            }
            player = nil
            onDismiss()
            return
        }

        let sid = playbackSessionID
        tearDownPlayer()
        playbackSessionID = nil
        coordinator.stopAndRelease(sessionID: sid)
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
            // 再生終了状態（末尾から0.3秒以内）なら先頭から再生
            if duration > 0 && currentTime >= duration - 0.3 {
                p.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                currentTime = 0.0
            }
            isPlaying = true
            if p.currentItem?.status == .readyToPlay {
                p.playImmediately(atRate: playbackRate)
            }
            scheduleAutoHide(delay: 10.0)
        }
    }

    private func handleRestart() {
        guard let p = player else { return }
        p.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        isPlaying = true
        if p.currentItem?.status == .readyToPlay {
            p.playImmediately(atRate: playbackRate)
        }
        registerUserAction()
    }

    private func handleSeek(offset: Double) {
        guard let p = player else { return }
        let newTime = max(0, min(duration, currentTime + offset))
        currentTime = newTime
        registerUserAction()
        let targetRate = playbackRate
        let shouldResume = isPlaying
        p.seek(to: CMTime(seconds: newTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] completed in
            guard completed, let self = self else { return }
            if shouldResume && self.isPlaying && p.currentItem?.status == .readyToPlay {
                p.playImmediately(atRate: targetRate)
            }
        }
    }

    private func handleSeekToTime(_ targetTime: Double) {
        guard let p = player else { return }
        let clamped = max(0, min(duration, targetTime))
        currentTime = clamped
        registerUserAction()
        let targetRate = playbackRate
        let shouldResume = isPlaying
        p.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] completed in
            guard completed, let self = self else { return }
            if shouldResume && self.isPlaying && p.currentItem?.status == .readyToPlay {
                p.playImmediately(atRate: targetRate)
            }
        }
    }

    private func handleDoubleTapSeek(isForward: Bool) {
        lastDoubleTapTime = Date()
        let offset: Double = isForward ? 10.0 : -10.0
        handleSeek(offset: offset)

        // フィードバックバッジ演出
        seekFeedbackIsForward = isForward
        seekFeedbackText = isForward ? "+10s" : "-10s"
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
        // - 動画 -> 動画: 前の動画の再生状態（再生中／停止中）を引き継ぐ
        // - 画像 -> 動画: 動画を自動再生する (true)
        // - 動画 -> 画像 / 画像 -> 画像: 画像のため自動再生不要 (false)
        let shouldAutoPlay: Bool
        if newItem.isImage {
            shouldAutoPlay = false
        } else if wasImage {
            shouldAutoPlay = true
        } else {
            shouldAutoPlay = wasPlaying
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
            do {
                let newFavorite = try VideoFolderManager(downloads: .shared).toggleFavorite(for: video)
                playlistContext.updateFavorite(id: video.id, isFavorite: newFavorite)
            } catch {
                showToast(String(format: NSLocalizedString("Failed to update favorite: %@", comment: ""), error.localizedDescription))
            }
        case .vault(let vaultItem):
            guard let token = playlistContext.vaultSessionToken else {
                showToast(NSLocalizedString("Vault session is invalid. Please unlock again.", comment: ""))
                return
            }
            do {
                let newFavorite = try VaultManager.shared.toggleFavorite(for: vaultItem, expectedSessionToken: token)
                playlistContext.updateFavorite(id: vaultItem.id, isFavorite: newFavorite)
            } catch {
                showToast(String(format: NSLocalizedString("Failed to update favorite: %@", comment: ""), error.localizedDescription))
            }
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
        isCurrentDragSwipeEligible = nil
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
            showToast(NSLocalizedString("PiP is not available for Vault items.", comment: ""))
            return
        }
        guard let sid = playbackSessionID else { return }
        coordinator.startPictureInPicture(sessionID: sid)
    }

    // MARK: - 共有・書き出し

    private func handleShareTapped() {
        registerUserAction()
        guard !playlistContext.isVault else {
            showVaultShareAlert = true
            return
        }
        guard let url = currentPlaybackURL, FileManager.default.fileExists(atPath: url.path) else {
            showToast(NSLocalizedString("File to share not found", comment: ""))
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
                showToast(String(format: "%@: %@", NSLocalizedString("Failed to delete", comment: ""), errorMessage ?? ""))

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
        isDismissingDueToPiP = false
        let sid = playbackSessionID
        tearDownPlayer()
        playbackSessionID = nil
        coordinator.stopAndRelease(sessionID: sid)
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
            showToast(NSLocalizedString("Title changed", comment: ""))
        case .vault(let vaultItem):
            do {
                try VaultManager.shared.renameVaultItem(vaultItem, to: newTitle)
                showToast(NSLocalizedString("Title changed", comment: ""))
            } catch {
                showToast(String(format: NSLocalizedString("Failed to change title: %@", comment: ""), error.localizedDescription))
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
                throw NSError(domain: "Player", code: 500, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Failed to generate save path.", comment: "")])
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
            showToast(String(format: NSLocalizedString("Saved \"%@\" as new clip", comment: ""), clean))

        case .vault(let vaultItem):
            do {
                _ = try await VaultManager.shared.addEncryptedClip(tempURL: tempURL, clipTitle: clipTitle, sourceVaultItem: vaultItem)
                showToast(String(format: NSLocalizedString("Saved \"%@\" to Vault as clip", comment: ""), clipTitle))
            } catch {
                showToast(String(format: NSLocalizedString("Failed to save clip to Vault: %@", comment: ""), error.localizedDescription))
            }
        }
    }

    @ViewBuilder
    private var moveFolderDestinationView: some View {
        if let item = playlistContext.currentItem {
            switch item {
            case .normal(let video):
                let folderManager = VideoFolderManager(downloads: .shared)
                MoveToFolderSheet(
                    video: video,
                    currentFolder: folderManager.folderName(for: video),
                    folders: folderManager.folders,
                    onSelectFolder: { targetFolder in
                        _ = folderManager.moveVideo(video, toFolder: targetFolder)
                        showToast(NSLocalizedString("File moved", comment: ""))
                    }
                )
            case .vault(let vaultItem):
                MoveToVaultFolderSheet(
                    currentFolderID: vaultItem.folderID,
                    folders: VaultManager.shared.folders,
                    onSelectFolder: { targetFolderID in
                        do {
                            try VaultManager.shared.moveItem(id: vaultItem.id, to: targetFolderID)
                            showToast(NSLocalizedString("File moved", comment: ""))
                        } catch {
                            showToast(error.localizedDescription)
                        }
                    },
                    onCreateNewFolderAndMove: { folderName in
                        do {
                            let newFolder = try VaultManager.shared.createFolder(name: folderName)
                            try VaultManager.shared.moveItem(id: vaultItem.id, to: newFolder.id)
                            showToast(NSLocalizedString("File moved", comment: ""))
                        } catch {
                            showToast(error.localizedDescription)
                        }
                    }
                )
            }
        }
    }

    private func handleRestoreVaultFile() {
        guard let item = playlistContext.currentItem, case .vault(let vaultItem) = item else { return }
        Task {
            do {
                try await VaultManager.shared.restoreFromVault(
                    item: vaultItem,
                    targetFolder: nil,
                    downloads: .shared,
                    folderManager: VideoFolderManager(downloads: .shared)
                )
                showToast(String(format: NSLocalizedString("Restored \"%@\"", comment: ""), vaultItem.originalTitle))
                if playlistContext.items.count > 1 {
                    handleNavigateNext()
                } else {
                    handleClose()
                }
            } catch {
                showToast(String(format: NSLocalizedString("Failed to restore: %@", comment: ""), error.localizedDescription))
            }
        }
    }

    // MARK: - 実機HLS診断レポート生成・シートUI

    private func buildDiagnosticReport() -> String {
        var lines: [String] = []
        lines.append("=== ClipHarbor Playback Diagnostics ===")
        lines.append("Timestamp: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("ElapsedSinceSetup: \(String(format: "%.1f", Date().timeIntervalSince(playerSetupDate)))s")
        lines.append("VideoLoadState: \(videoLoadState)")
        lines.append("IsHLS: \(playlistContext.currentItem?.isHLS == true)")
        lines.append("AutoPlayIntent: \(self.isPlaying)")
        lines.append("PlaybackRate: \(self.playbackRate)")
        lines.append("Duration: \(String(format: "%.2f", self.duration))")
        lines.append("CurrentTime: \(String(format: "%.2f", self.currentTime))")

        // 1. URL & File System
        if let url = currentPlaybackURL {
            lines.append("\n--- [URL & File System] ---")
            lines.append("Scheme: \(url.scheme ?? "none")")
            lines.append("IsFileURL: \(url.isFileURL)")
            lines.append("Extension: \(url.pathExtension.lowercased())")
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            lines.append("Exists: \(exists)")
            lines.append("IsDir: \(isDir.boolValue)")
            let readable = FileManager.default.isReadableFile(atPath: url.path)
            lines.append("IsReadable: \(readable)")

            let homePath = NSHomeDirectory()
            let docPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? ""
            let cachesPath = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.path ?? ""
            lines.append("UnderHome: \(!homePath.isEmpty && url.path.hasPrefix(homePath))")
            lines.append("UnderDocs: \(!docPath.isEmpty && url.path.hasPrefix(docPath))")
            lines.append("UnderCaches: \(!cachesPath.isEmpty && url.path.hasPrefix(cachesPath))")

            // .movpkg パッケージ内部の安全な確認（個人名・パス全文はマスクし、拡張子と個数のみ）
            if isDir.boolValue {
                if let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path) {
                    let exts = contents.map { ($0 as NSString).pathExtension.lowercased() }.filter { !$0.isEmpty }
                    let extCounts = Dictionary(grouping: exts, by: { $0 }).mapValues { $0.count }
                    lines.append("PackageItemCount: \(contents.count)")
                    lines.append("PackageExtensions: \(extCounts)")
                } else {
                    lines.append("PackageContents: <unreadable directory>")
                }
            }

            if let item = playlistContext.currentItem, case .normal(let v) = item {
                let hasValidPrefix = v.relativePath.hasPrefix("Library/") || v.relativePath.hasPrefix("Documents/")
                lines.append("SavedRelativePathPrefix: \(hasValidPrefix ? "standard" : "other")")
                let reconstructed = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(v.relativePath)
                lines.append("PathMatchesReconstructed: \(reconstructed.path == url.path)")
            }
        }

        // 2. AVURLAsset & AssetCache
        if let url = currentPlaybackURL {
            lines.append("\n--- [AVURLAsset & AssetCache] ---")
            let asset = AVURLAsset(url: url)
            lines.append("IsPlayable: \(asset.isPlayable)")
            if let cache = asset.assetCache {
                lines.append("AssetCache.isPlayableOffline: \(cache.isPlayableOffline)")
            } else {
                lines.append("AssetCache: nil")
            }
            lines.append("TracksCount: \(asset.tracks.count)")
        }

        // 3. AVPlayer
        lines.append("\n--- [AVPlayer] ---")
        if let p = player {
            let pStatusStr: String
            switch p.status {
            case .readyToPlay: pStatusStr = "readyToPlay"
            case .failed: pStatusStr = "failed"
            case .unknown: pStatusStr = "unknown"
            @unknown default: pStatusStr = "unknownDefault"
            }
            lines.append("Player.status: \(pStatusStr)")

            let tcStr: String
            switch p.timeControlStatus {
            case .paused: tcStr = "paused (0)"
            case .waitingToPlayAtSpecifiedRate: tcStr = "waitingToPlayAtSpecifiedRate (1)"
            case .playing: tcStr = "playing (2)"
            @unknown default: tcStr = "unknown"
            }
            lines.append("TimeControlStatus: \(tcStr)")
            lines.append("ReasonForWaiting: \(p.reasonForWaitingToPlay?.rawValue ?? "none")")
            lines.append("Player.rate: \(p.rate)")

            if let pErr = p.error as NSError? {
                let uErr = pErr.userInfo[NSUnderlyingErrorKey] as? NSError
                lines.append("Player.error: domain=\(pErr.domain) code=\(pErr.code) uDomain=\(uErr?.domain ?? "none") uCode=\(uErr?.code ?? 0)")
            } else {
                lines.append("Player.error: nil")
            }
        } else {
            lines.append("Player: nil")
        }

        // 4. AVPlayerItem
        lines.append("\n--- [AVPlayerItem] ---")
        if let item = player?.currentItem {
            let itemStatusStr: String
            switch item.status {
            case .readyToPlay: itemStatusStr = "readyToPlay"
            case .failed: itemStatusStr = "failed"
            case .unknown: itemStatusStr = "unknown"
            @unknown default: itemStatusStr = "unknownDefault"
            }
            lines.append("Item.status: \(itemStatusStr)")
            lines.append("IsPlaybackBufferEmpty: \(item.isPlaybackBufferEmpty)")
            lines.append("IsPlaybackLikelyToKeepUp: \(item.isPlaybackLikelyToKeepUp)")
            lines.append("IsPlaybackBufferFull: \(item.isPlaybackBufferFull)")

            let dSecs = CMTimeGetSeconds(item.duration)
            lines.append("Item.duration: \(dSecs.isNaN ? "NaN" : String(format: "%.2f", dSecs))")

            let loadedRanges = item.loadedTimeRanges.compactMap { val -> String? in
                let r = val.timeRangeValue
                let start = CMTimeGetSeconds(r.start)
                let dur = CMTimeGetSeconds(r.duration)
                guard !start.isNaN, !dur.isNaN else { return nil }
                return "[\(String(format: "%.1f", start))-\(String(format: "%.1f", start+dur))]"
            }
            lines.append("LoadedTimeRanges: \(loadedRanges)")

            if let iErr = item.error as NSError? {
                let uErr = iErr.userInfo[NSUnderlyingErrorKey] as? NSError
                lines.append("Item.error: domain=\(iErr.domain) code=\(iErr.code) uDomain=\(uErr?.domain ?? "none") uCode=\(uErr?.code ?? 0)")
            } else {
                lines.append("Item.error: nil")
            }

            // ErrorLog
            if let errorLog = item.errorLog() {
                let events = errorLog.events
                lines.append("ErrorLogEventCount: \(events.count)")
                for (idx, evt) in events.suffix(3).enumerated() {
                    let comment = evt.errorComment ?? ""
                    let safeComment = comment.isEmpty ? "none" : String(comment.prefix(80))
                    lines.append("ErrorLog[\(idx)]: status=\(evt.errorStatusCode) domain=\(evt.errorDomain ?? "nil") comment=\(safeComment)")
                }
            } else {
                lines.append("ErrorLog: nil")
            }
        } else {
            lines.append("CurrentItem: nil")
        }

        return lines.joined(separator: "\n")
    }

    private var diagnosticsSheetView: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(diagnosticReport.isEmpty ? buildDiagnosticReport() : diagnosticReport)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color(UIColor.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .padding()
            }
            .navigationTitle(NSLocalizedString("HLS Diagnostics", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: {
                        diagnosticReport = buildDiagnosticReport()
                    }) {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Button(action: {
                            let text = diagnosticReport.isEmpty ? buildDiagnosticReport() : diagnosticReport
                            UIPasteboard.general.string = text
                            hasCopiedDiagnostics = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                hasCopiedDiagnostics = false
                            }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: hasCopiedDiagnostics ? "checkmark" : "doc.on.doc")
                                Text(hasCopiedDiagnostics ? NSLocalizedString("Copied", comment: "") : NSLocalizedString("Copy", comment: ""))
                            }
                        }
                        Button(NSLocalizedString("Done", comment: "")) {
                            showDiagnosticsSheet = false
                        }
                    }
                }
            }
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
