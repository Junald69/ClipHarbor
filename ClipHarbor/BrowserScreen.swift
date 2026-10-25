import SwiftUI
import WebKit

struct BrowserScreen: View {
    @StateObject private var tabManager = TabManager()
    @ObservedObject private var downloads = DownloadCenter.shared
    @ObservedObject private var folderManager = VideoFolderManager.shared
    @ObservedObject private var exports = VideoExportManager.shared

    var body: some View {
        ActiveBrowserContainer(
            tabManager: tabManager,
            browser: tabManager.activeTab,
            downloads: downloads,
            folderManager: folderManager,
            exports: exports
        )
    }
}

private struct ActiveBrowserContainer: View {
    @ObservedObject var tabManager: TabManager
    @ObservedObject var browser: BrowserModel
    @ObservedObject var downloads: DownloadCenter
    @ObservedObject var folderManager: VideoFolderManager
    @ObservedObject var exports: VideoExportManager

    @State private var savingCandidate: MediaCandidate?
    @State private var showCandidateList = false
    @State private var showDownloads = false
    @State private var showHistory = false
    @State private var showBookmarks = false
    @State private var pendingSourceURL: URL?
    @State private var pendingHistoryAction: HistoryNavigationAction?
    @State private var pendingBookmarkAction: HistoryNavigationAction?
    @State private var pendingMenuAction: (() -> Void)?
    @State private var showMenu = false
    @State private var showSettings = false
    @State private var showTabSwitcher = false
    @State private var unsupportedMessage: String?
    @FocusState private var addressFocused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            // 1. Webビュー（上部Safe Area内配置でステータスバー重なりを防止、下部はEdge-to-Edgeでフローティングツールバーと自然に連携）
            BrowserWebView(browser: browser)
                .id(browser.id)
                .ignoresSafeArea(.container, edges: .bottom)

            // 2. 動画検出オーバーレイ（全画面座標、ボタン部分のみタップ判定）
            GeometryReader { geo in
                videoDownloadOverlay(in: geo.size)
            }
            .ignoresSafeArea(.container, edges: .bottom)

            // 3. ページ読み込み進捗バー（ステータスバー直下に配置、タップ判定は背後に透過）
            if browser.isLoading {
                VStack(spacing: 0) {
                    ProgressView(value: max(0.05, min(browser.loadingProgress, 1.0)))
                        .progressViewStyle(.linear)
                        .tint(.blue)
                    Spacer()
                }
                .allowsHitTesting(false)
            }

            // 4. URL編集中にWebビュー領域タップで編集をキャンセルする透明レイヤー
            if browser.isEditingAddress {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture {
                        addressFocused = false
                        browser.isEditingAddress = false
                        browser.address = browser.currentURL.absoluteString
                    }
            }

            // 5. 下部フローティング通知 & ツールバー（ホームインジケータ上に配置）
            VStack(spacing: 6) {
                statusBanner
                floatingToolbar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
        .onChange(of: addressFocused) { _, focused in
            browser.isEditingAddress = focused
            if focused {
                browser.showToolbar()
            }
        }
        .onChange(of: browser.id) { _, _ in
            browser.showToolbar()
        }
        .sheet(item: $browser.activePopup) { popup in
            PopupSheetView(
                popup: popup,
                isPrivate: browser.isPrivate,
                onClose: { browser.closeActivePopup() }
            )
        }
        .sheet(item: $savingCandidate) { candidate in
            SaveVideoSheet(
                candidate: candidate,
                existingFolders: folderManager.folders,
                onConfirm: { chosenName, chosenFolder in
                    startDownload(candidate: candidate, displayName: chosenName, folderName: chosenFolder)
                },
                onConfirmMP4: mp4ConfirmHandler(for: candidate),
                mp4Probe: mp4ProbeHandler(for: candidate)
            )
        }
        .sheet(isPresented: $showCandidateList) {
            CandidateListSheet(browser: browser) { candidate in
                savingCandidate = candidate
            }
        }
        .sheet(isPresented: $showDownloads, onDismiss: {
            browser.showToolbar()
            if let url = pendingSourceURL {
                pendingSourceURL = nil
                handleOpenURLInNewTab(url)
            }
        }) {
            FileManagerView(
                downloads: downloads,
                folderManager: folderManager,
                onOpenSourcePage: { url in
                    pendingSourceURL = url
                }
            )
        }
        .sheet(isPresented: $showMenu, onDismiss: {
            browser.showToolbar()
            if let action = pendingMenuAction {
                pendingMenuAction = nil
                action()
            }
        }) {
            BrowserMenuSheet(
                browser: browser,
                tabManager: tabManager,
                downloads: downloads,
                exports: exports,
                onOpenCandidateList: {
                    pendingMenuAction = { showCandidateList = true }
                    showMenu = false
                },
                onOpenDownloads: {
                    pendingMenuAction = { showDownloads = true }
                    showMenu = false
                },
                onOpenHistory: {
                    pendingMenuAction = { showHistory = true }
                    showMenu = false
                },
                onOpenBookmarks: {
                    pendingMenuAction = { showBookmarks = true }
                    showMenu = false
                },
                onOpenPrivateTab: {
                    pendingMenuAction = {
                        handleOpenPrivateTab()
                    }
                    showMenu = false
                },
                onOpenSettings: {
                    pendingMenuAction = { showSettings = true }
                    showMenu = false
                }
            )
        }
        .sheet(isPresented: $showHistory, onDismiss: {
            browser.showToolbar()
            if let action = pendingHistoryAction {
                pendingHistoryAction = nil
                handleHistoryNavigation(action)
            }
        }) {
            HistoryView(
                onSelectURL: { url, openInNewTab in
                    if openInNewTab {
                        pendingHistoryAction = .openInNewTab(url)
                    } else {
                        pendingHistoryAction = .openInCurrentTab(url)
                    }
                }
            )
        }
        .sheet(isPresented: $showBookmarks, onDismiss: {
            browser.showToolbar()
            if let action = pendingBookmarkAction {
                pendingBookmarkAction = nil
                handleHistoryNavigation(action)
            }
        }) {
            BookmarkView(
                onSelectURL: { url, openInNewTab in
                    if openInNewTab {
                        pendingBookmarkAction = .openInNewTab(url)
                    } else {
                        pendingBookmarkAction = .openInCurrentTab(url)
                    }
                }
            )
        }
        .sheet(isPresented: $showTabSwitcher, onDismiss: {
            browser.showToolbar()
        }) {
            TabSwitcherView(tabManager: tabManager)
        }
        .sheet(isPresented: $showSettings, onDismiss: {
            browser.showToolbar()
        }) {
            AppSettingsView(
                downloads: downloads,
                folderManager: folderManager
            )
        }
        .alert(
            "この動画は保存できません",
            isPresented: Binding(
                get: { unsupportedMessage != nil },
                set: { if !$0 { unsupportedMessage = nil } }
            )
        ) {
            if browser.candidateRows.contains(where: { $0.candidate != nil }) {
                Button("他の候補を見る") {
                    unsupportedMessage = nil
                    showCandidateList = true
                }
            }
            Button("OK", role: .cancel) { unsupportedMessage = nil }
        } message: {
            Text(unsupportedMessage ?? "")
        }
    }

    // MARK: - フローティングツールバー（Aloha風・画面下部・スクロール連動）

    private var floatingToolbar: some View {
        VStack(spacing: 6) {
            addressBarUpperTier
            if !browser.isEditingAddress {
                navigationBarLowerTier
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, browser.isEditingAddress ? 6 : 4)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: Color.black.opacity(0.16), radius: 10, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .offset(y: browser.isToolbarHidden ? 160 : 0)
        .opacity(browser.isToolbarHidden ? 0 : 1)
        .allowsHitTesting(!browser.isToolbarHidden)
        .animation(.easeInOut(duration: 0.2), value: browser.isToolbarHidden)
        .animation(.easeInOut(duration: 0.2), value: browser.isEditingAddress)
    }

    @ViewBuilder
    private var addressBarUpperTier: some View {
        if browser.isEditingAddress {
            HStack(spacing: 6) {
                if browser.isPrivate {
                    Image(systemName: "eyeglasses")
                        .font(.caption)
                        .foregroundStyle(.purple)
                }

                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("検索またはURLを入力", text: $browser.address)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($addressFocused)
                    .onSubmit {
                        browser.navigate(to: browser.address)
                        addressFocused = false
                        browser.isEditingAddress = false
                    }

                if !browser.address.isEmpty {
                    Button {
                        browser.address = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("入力をクリア")
                }

                Button("キャンセル") {
                    addressFocused = false
                    browser.isEditingAddress = false
                    browser.address = browser.currentURL.absoluteString
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.blue)
            }
            .font(.subheadline)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            HStack(spacing: 8) {
                if browser.isPrivate {
                    Image(systemName: "eyeglasses")
                        .font(.caption)
                        .foregroundStyle(.purple)
                }

                Image(systemName: browser.isSecurePage ? "lock.fill" : "globe")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(browser.displayDomainOrURL)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                Button {
                    browser.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("再読み込み")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture {
                let currentURLString = browser.currentURL.absoluteString
                if !currentURLString.isEmpty && currentURLString != "about:blank" {
                    browser.address = currentURLString
                }
                browser.isEditingAddress = true
                addressFocused = true
            }
        }
    }

    // MARK: - Aloha風 動画ダウンロードボタン（オーバーレイ）

    @ViewBuilder
    private func videoDownloadOverlay(in size: CGSize) -> some View {
        ZStack(alignment: .bottomTrailing) {
            let currentSelection = browser.selection
            if let activeVideo = currentSelection.video, !activeVideo.isFullscreen {
                if let anchor = overlayPosition(for: activeVideo, in: size) {
                    alohaDownloadButton(for: activeVideo, compact: true)
                        .position(anchor)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    // クロスオリジンiframe等で座標が取れない場合は右下に配置
                    alohaDownloadButton(for: activeVideo, compact: false)
                        .padding(16)
                        .padding(.bottom, browser.isToolbarHidden ? 34 : 110)
                        .animation(.easeInOut(duration: 0.2), value: browser.isToolbarHidden)
                }
            } else if currentSelection.isAmbiguous || browser.hasAnyMedia {
                // 複数動画が同時再生されている場合、またはリソース候補のみ検出されている場合
                fallbackOverlayButton
                    .padding(16)
                    .padding(.bottom, browser.isToolbarHidden ? 34 : 110)
                    .animation(.easeInOut(duration: 0.2), value: browser.isToolbarHidden)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .bottomTrailing)
    }

    /// 動画の右上（シークバーや中央の再生ボタンを妨げない位置）の座標を計算する。
    private func overlayPosition(for video: TrackedVideo, in viewSize: CGSize) -> CGPoint? {
        guard let cssRect = video.rectInCSS,
              video.viewportCSSWidth > 0,
              viewSize.width > 0, viewSize.height > 0,
              video.visibleRatio > 0.15 else {
            return nil
        }
        let scale = viewSize.width / CGFloat(video.viewportCSSWidth)
        let videoFrame = CGRect(
            x: cssRect.minX * scale,
            y: cssRect.minY * scale,
            width: cssRect.width * scale,
            height: cssRect.height * scale
        )
        let bounds = CGRect(origin: .zero, size: viewSize)
        let visible = videoFrame.intersection(bounds)
        guard !visible.isNull, visible.width >= 60, visible.height >= 48 else {
            return nil
        }
        let margin: CGFloat = 28
        let targetX = min(max(videoFrame.maxX - margin, margin), viewSize.width - margin)
        let targetY = min(max(videoFrame.minY + margin, margin), viewSize.height - margin)
        return CGPoint(x: targetX, y: targetY)
    }

    private func alohaDownloadButton(for video: TrackedVideo, compact: Bool) -> some View {
        let isSavable = (video.candidate != nil)
        return Button {
            handleTapOnVideo(video)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.to.line.compact")
                    .font(.system(size: 18, weight: .bold))
                if !compact {
                    Text(isSavable ? "動画を保存" : "保存を確認")
                        .font(.system(size: 14, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 13 : 15)
            .padding(.vertical, compact ? 13 : 11)
            .frame(minWidth: 44, minHeight: 44)
            .background(isSavable ? Color.blue : Color.secondary, in: Capsule())
            .overlay(
                Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 3)
        }
        .accessibilityLabel("再生中の動画を保存")
        .contextMenu {
            if let candidate = video.candidate {
                Button {
                    savingCandidate = candidate
                } label: {
                    Label("ファイル名を指定して保存", systemImage: "arrow.down.circle")
                }
            }
            if browser.candidateRows.count > 1 {
                Button {
                    showCandidateList = true
                } label: {
                    Label("候補一覧を表示 (\(browser.candidateRows.count)件)", systemImage: "list.bullet")
                }
            }
        }
    }

    private var fallbackOverlayButton: some View {
        Button {
            handleFallbackTap()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.to.line.compact")
                    .font(.system(size: 17, weight: .bold))
                Text("動画候補 (\(browser.candidateRows.count))")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(minWidth: 44, minHeight: 44)
            .background(Color.blue, in: Capsule())
            .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
        }
        .accessibilityLabel("検出された動画の候補を表示")
    }

    private func handleTapOnVideo(_ video: TrackedVideo) {
        if let candidate = video.candidate {
            savingCandidate = candidate
        } else if browser.candidateRows.contains(where: { $0.candidate != nil }) {
            // 再生中のvideo要素自体はblob等でも、Performance API等でm3u8/mp4候補が見つかっている場合は候補一覧を出す
            showCandidateList = true
        } else {
            unsupportedMessage = video.unsupportedReason
                ?? "動画は検出しましたが、保存用のURLを取得できません。blob/MSE・DRM・サイト専用の配信方式などには対応していません。"
        }
    }

    private func handleFallbackTap() {
        let savable = browser.candidateRows.compactMap { $0.candidate }
        if !browser.selection.isAmbiguous, savable.count == 1, let only = savable.first {
            savingCandidate = only
        } else {
            showCandidateList = true
        }
    }

    private enum HistoryNavigationAction {
        case openInCurrentTab(URL)
        case openInNewTab(URL)
    }

    private func handleHistoryNavigation(_ action: HistoryNavigationAction) {
        switch action {
        case .openInCurrentTab(let url):
            guard let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  let host = url.host, !host.isEmpty else {
                return
            }
            browser.navigate(to: url.absoluteString)
        case .openInNewTab(let url):
            handleOpenURLInNewTab(url)
        }
    }

    private func handleOpenURLInNewTab(_ url: URL) {
        tabManager.openURLInNewTab(url, from: browser)
    }

    private func handleOpenPrivateTab() {
        if tabManager.canCreateNewPrivateTab {
            if let newTab = tabManager.createPrivateTab() {
                tabManager.selectPrivateTab(id: newTab.id)
            }
        } else {
            browser.showNotice("プライベートタブ上限（\(TabManager.maxPrivateTabs)件）に達しているため、新しいプライベートタブを開けませんでした。不要なタブを閉じてから再度お試しください。")
        }
    }

    private func startDownload(candidate: MediaCandidate, displayName: String, folderName: String) {
        if browser.isPrivate {
            browser.showNotice("💡 保存動画および保存元URLは端末ストレージに保存されます。")
        }
        browser.makeRequestContext { context in
            let jobID = downloads.start(candidate, displayName: displayName, context: context)
            folderManager.registerPendingFolder(folderName, forJobID: jobID)
        }
    }

    /// HLS候補のみ「MP4として保存」を提供する（動画ファイル候補は従来の直接保存のみ）
    private func mp4ConfirmHandler(for candidate: MediaCandidate) -> ((String, String) -> Void)? {
        guard candidate.isHLS else { return nil }
        return { chosenName, chosenFolder in
            startMP4Export(candidate: candidate, displayName: chosenName, folderName: chosenFolder)
        }
    }

    private func mp4ProbeHandler(for candidate: MediaCandidate) -> (() async -> VideoExportManager.MP4Compatibility)? {
        guard candidate.isHLS else { return nil }
        return {
            await probeMP4Compatibility(candidate: candidate)
        }
    }

    /// 「MP4として保存」：VideoExportManagerで変換・品質検証し、合格時のみDocuments/Downloads（または選択フォルダ）へ保存・一覧登録する。
    /// 保存先フォルダはファイルの配置場所で決まるため、DownloadCenterのonVideoSaved（フォルダ移動）は経由しない。
    private func startMP4Export(candidate: MediaCandidate, displayName: String, folderName: String) {
        if browser.isPrivate {
            browser.showNotice("💡 保存動画および保存元URLは端末ストレージに保存されます。")
        }
        browser.makeRequestContext { context in
            _ = exports.startFMP4Export(
                candidate: candidate,
                displayName: displayName,
                targetFolder: folderName,
                context: context
            )
        }
    }

    /// 保存シートのMP4互換性判定。ページのCookie等は既存のmakeRequestContextでメモリ上にのみ取得する。
    private func probeMP4Compatibility(candidate: MediaCandidate) async -> VideoExportManager.MP4Compatibility {
        let context = await withCheckedContinuation { (continuation: CheckedContinuation<RequestContext, Never>) in
            browser.makeRequestContext { context in
                continuation.resume(returning: context)
            }
        }
        return await exports.probeMP4Compatibility(candidate: candidate, context: context)
    }

    // MARK: - ステータス表示と下部ナビゲーションバー（下段）

    @ViewBuilder
    private var statusBanner: some View {
        VStack(spacing: 6) {
            if let _ = browser.pendingBlockedPopupHost {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundStyle(.orange)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(NSLocalizedString("Blocked an annoying pop-up. If this was intentional, allow it for this site and retry.", comment: ""))
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(3)
                        Button {
                            browser.allowPopupsForCurrentSiteAndReload()
                        } label: {
                            Text(NSLocalizedString("Allow for this site and reload", comment: ""))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.blue)
                        }
                    }
                    Spacer(minLength: 4)
                    Button {
                        browser.clearBlockedPopupNotice()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(4)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.orange.opacity(0.35), lineWidth: 0.8)
                )
                .padding(.horizontal, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let notice = browser.notice ?? downloads.statusMessage ?? exports.statusMessage {
                let hasActiveTask = (downloads.activeCount + exports.activeCount) > 0
                HStack(spacing: 8) {
                    if hasActiveTask {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.blue)
                    }
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if hasActiveTask || !exports.exportJobs.isEmpty {
                        Button("詳細") { showDownloads = true }
                            .font(.caption.weight(.semibold))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
                .padding(.horizontal, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var navigationBarLowerTier: some View {
        HStack {
            // 1. 戻る（chevron.left）
            Button {
                browser.goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(!browser.canGoBack)
            .accessibilityLabel("戻る")

            Spacer()

            // 2. ホーム（house）
            Button {
                browser.goHome()
            } label: {
                Image(systemName: "house")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("ホーム")

            Spacer()

            // 3. メニュー（line.3.horizontal）
            Button {
                showMenu = true
            } label: {
                Image(systemName: "line.3.horizontal")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("メニュー")

            Spacer()

            // 4. ダウンロード（arrow.down.to.line）
            Button {
                showDownloads = true
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "arrow.down.to.line")
                        .frame(minWidth: 44, minHeight: 44)

                    let totalActive = downloads.activeCount + exports.activeCount
                    if totalActive > 0 {
                        Text("\(totalActive)")
                            .font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.blue, in: Capsule())
                            .foregroundStyle(.white)
                            .offset(x: 10, y: 4)
                    }
                }
            }
            .accessibilityLabel("ダウンロード・保存動画")

            Spacer()

            // 5. タブ（square.on.square）
            Button {
                tabManager.activeTab.captureSnapshot()
                showTabSwitcher = true
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "square.on.square")
                        .frame(minWidth: 44, minHeight: 44)

                    let currentCount = browser.isPrivate ? tabManager.privateCount : tabManager.count
                    Text("\(currentCount)")
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(browser.isPrivate ? Color.indigo : Color.blue, in: Capsule())
                        .foregroundStyle(.white)
                        .offset(x: 10, y: 4)
                }
            }
            .accessibilityLabel(browser.isPrivate ? "プライベートタブ (\(tabManager.privateCount)件)" : "タブ (\(tabManager.count)件)")
        }
        .font(.title3)
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
    }
}

// MARK: - メニューシート（進む・再読み込み・動画候補一覧・将来機能の明示）

struct BrowserMenuSheet: View {
    @ObservedObject var browser: BrowserModel
    @ObservedObject var tabManager: TabManager
    @ObservedObject var downloads: DownloadCenter
    @ObservedObject var exports: VideoExportManager
    @ObservedObject private var historyManager = HistoryManager.shared
    @ObservedObject private var bookmarkManager = BookmarkManager.shared
    let onOpenCandidateList: () -> Void
    let onOpenDownloads: () -> Void
    let onOpenHistory: () -> Void
    let onOpenBookmarks: () -> Void
    let onOpenPrivateTab: () -> Void
    let onOpenSettings: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var isCurrentPageValidURL: Bool {
        let url = browser.currentURL
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else {
            return false
        }
        return BookmarkURLPolicy.sanitize(url) != nil
    }

    private var isCurrentPageBookmarked: Bool {
        guard isCurrentPageValidURL else { return false }
        return bookmarkManager.isBookmarked(url: browser.currentURL)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("動画とダウンロード") {
                    let isCandidateDisabled = !browser.hasAnyMedia
                    Button(action: onOpenCandidateList) {
                        HStack {
                            Label {
                                Text("動画の候補一覧")
                                    .foregroundStyle(isCandidateDisabled ? Color.blue.opacity(0.4) : Color.blue)
                            } icon: {
                                Image(systemName: "film.stack")
                                    .foregroundStyle(isCandidateDisabled ? Color.blue.opacity(0.4) : Color.blue)
                            }
                            Spacer()
                            if !browser.candidateRows.isEmpty {
                                Text("\(browser.candidateRows.count)件")
                                    .font(.caption)
                                    .foregroundStyle(isCandidateDisabled ? Color.secondary.opacity(0.4) : Color.secondary)
                            }
                        }
                    }
                    .disabled(isCandidateDisabled)

                    Button(action: onOpenDownloads) {
                        HStack {
                            Label("保存動画・フォルダ管理", systemImage: "arrow.down.to.line")
                            Spacer()
                            let activeCount = downloads.activeCount + exports.activeCount
                            if activeCount > 0 {
                                Text("\(activeCount)件処理中")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                }

                Section {
                    let isBookmarkDisabled = browser.isPrivate || !isCurrentPageValidURL
                    Button {
                        if browser.isPrivate {
                            dismiss()
                            browser.showNotice("プライベートブラウジング中は、プライバシー保護のためブックマークの登録・解除は無効化されています。")
                            return
                        }
                        let targetURL = browser.currentURL
                        let targetTitle = browser.pageTitle
                        dismiss()
                        toggleBookmark(url: targetURL, title: targetTitle)
                    } label: {
                        Label {
                            Text(isCurrentPageBookmarked ? "ブックマークを解除" : "このページをブックマーク")
                                .foregroundStyle(isBookmarkDisabled ? Color.blue.opacity(0.4) : Color.blue)
                        } icon: {
                            Image(systemName: isCurrentPageBookmarked ? "bookmark.fill" : "bookmark")
                                .foregroundStyle(isBookmarkDisabled ? Color.blue.opacity(0.4) : Color.blue)
                        }
                    }
                    .disabled(isBookmarkDisabled)

                    Button(action: onOpenBookmarks) {
                        HStack {
                            Label("ブックマーク", systemImage: "bookmark")
                            Spacer()
                            if !bookmarkManager.items.isEmpty {
                                Text("\(bookmarkManager.items.count)件")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("ブックマーク")
                } footer: {
                    if browser.isPrivate {
                        Text("※プライベートブラウジング中はブックマーク登録が無効化されます。")
                    }
                }

                Section {
                    Button(action: onOpenHistory) {
                        HStack {
                            Label("履歴", systemImage: "clock")
                            Spacer()
                            if !historyManager.items.isEmpty {
                                Text("\(historyManager.items.count)件")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("履歴")
                } footer: {
                    if browser.isPrivate {
                        Text("※プライベートタブでの閲覧履歴は一切保存されません。")
                    }
                }

                if let host = browser.currentURL.host, !host.isEmpty {
                    Section {
                        let isWhitelisted = ContentBlockerManager.shared.isHostWhitelisted(host, isPrivate: browser.isPrivate)
                        let isGlobalDisabled = !AppSettingsManager.shared.blockAdsAndTrackers && !AppSettingsManager.shared.blockAnnoyingPopups

                        Button {
                            dismiss()
                            browser.toggleSiteProtection()
                        } label: {
                            HStack {
                                Label {
                                    Text(isWhitelisted ? NSLocalizedString("Enable Protection on This Site", comment: "") : NSLocalizedString("Disable Protection on This Site", comment: ""))
                                        .foregroundStyle(isGlobalDisabled ? Color.secondary : (isWhitelisted ? Color.blue : Color.red))
                                } icon: {
                                    Image(systemName: isWhitelisted ? "shield" : "shield.slash")
                                        .foregroundStyle(isGlobalDisabled ? Color.secondary : (isWhitelisted ? Color.blue : Color.red))
                                }
                                Spacer()
                                if isWhitelisted {
                                    Text(NSLocalizedString("Protection Disabled", comment: ""))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else if !isGlobalDisabled {
                                    Text(NSLocalizedString("Protection Enabled", comment: ""))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(isGlobalDisabled)
                    } header: {
                        Text(NSLocalizedString("Site Protection", comment: ""))
                    } footer: {
                        if !AppSettingsManager.shared.blockAdsAndTrackers && !AppSettingsManager.shared.blockAnnoyingPopups {
                            Text(NSLocalizedString("Global content blocking is disabled in Settings.", comment: ""))
                        } else if browser.isPrivate {
                            Text(NSLocalizedString("※ Exceptions set in Private Browsing are kept in memory and cleared when private tabs are closed.", comment: ""))
                        } else {
                            Text(String.localizedStringWithFormat(NSLocalizedString("Protection status for %@", comment: ""), host))
                        }
                    }
                }

                Section {
                    Button(action: onOpenPrivateTab) {
                        HStack {
                            Label(
                                browser.isPrivate ? "新しいプライベートタブを開く" : "プライベートタブを開く",
                                systemImage: "eyeglasses"
                            )
                            Spacer()
                            if tabManager.privateCount > 0 {
                                Text("\(tabManager.privateCount)件")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Button(action: onOpenSettings) {
                        HStack {
                            Label("設定", systemImage: "gearshape")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("ブラウズ機能")
                } footer: {
                    Text("プライベートモードでは閲覧履歴を残さず、Cookieやキャッシュもタブ終了時に消去されます。")
                }
            }
            .navigationTitle("メニュー")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func toggleBookmark(url: URL, title: String) {
        if bookmarkManager.isBookmarked(url: url) {
            bookmarkManager.removeBookmark(for: url)
            browser.showNotice("ブックマークを解除しました")
        } else {
            guard bookmarkManager.canSave else {
                browser.showNotice("保存領域が保護されているため、ブックマークを保存できません")
                return
            }
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedTitle = trimmed.isEmpty ? (url.host ?? "新規ブックマーク") : trimmed
            if bookmarkManager.addBookmark(url: url, title: resolvedTitle) != nil {
                browser.showNotice("ブックマークに追加しました")
            } else {
                browser.showNotice("このページはブックマークに登録できません")
            }
        }
    }
}

private struct BrowserWebView: UIViewRepresentable {
    let browser: BrowserModel

    func makeUIView(context: Context) -> WKWebView {
        browser.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
    }
}

private struct PopupWebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
    }
}

private struct PopupSheetView: View {
    let popup: PopupInfo
    let isPrivate: Bool
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            PopupWebViewContainer(webView: popup.webView)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(popup.initialURL?.host ?? "Popup")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(NSLocalizedString("Close", comment: "")) {
                            onClose()
                        }
                    }
                    if isPrivate {
                        ToolbarItem(placement: .principal) {
                            HStack(spacing: 4) {
                                Image(systemName: "eyeglasses")
                                    .font(.caption)
                                Text(popup.initialURL?.host ?? "")
                                    .font(.headline)
                            }
                        }
                    }
                }
        }
    }
}
