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
    @State private var showMenu = false
    @State private var showTabList = false
    @State private var unsupportedMessage: String?
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            addressBar

            if browser.isLoading {
                ProgressView(value: max(0.05, min(browser.loadingProgress, 1.0)))
                    .progressViewStyle(.linear)
                    .tint(.blue)
            }

            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    BrowserWebView(browser: browser)
                        .id(browser.id)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .ignoresSafeArea(.keyboard, edges: .bottom)

                    videoDownloadOverlay(in: geo.size)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            statusBanner
            bottomToolbar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .onChange(of: addressFocused) { _, focused in
            browser.isEditingAddress = focused
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
        .sheet(isPresented: $showDownloads) {
            FileManagerView(downloads: downloads, folderManager: folderManager)
        }
        .sheet(isPresented: $showMenu) {
            BrowserMenuSheet(
                browser: browser,
                downloads: downloads,
                exports: exports,
                onOpenCandidateList: {
                    showMenu = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        showCandidateList = true
                    }
                },
                onOpenDownloads: {
                    showMenu = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        showDownloads = true
                    }
                }
            )
        }
        .sheet(isPresented: $showTabList) {
            TabListSheet(tabManager: tabManager)
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

    // MARK: - 上部URLバー（Safe Area内）

    private var addressBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .foregroundStyle(.secondary)
            TextField("URL または検索語を入力", text: $browser.address)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($addressFocused)
                .onSubmit {
                    browser.navigate(to: browser.address)
                    addressFocused = false
                }
            if addressFocused && !browser.address.isEmpty {
                Button {
                    browser.address = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("URLをクリア")
            }
            Button {
                browser.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel("再読み込み")
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Aloha風 動画ダウンロードボタン（オーバーレイ）

    @ViewBuilder
    private func videoDownloadOverlay(in size: CGSize) -> some View {
        let currentSelection = browser.selection
        if let activeVideo = currentSelection.video, !activeVideo.isFullscreen {
            if let anchor = overlayPosition(for: activeVideo, in: size) {
                alohaDownloadButton(for: activeVideo, compact: true)
                    .position(anchor)
                    .transition(.scale.combined(with: .opacity))
            } else {
                // クロスオリジンiframe等で座標が取れない場合は右下に配置
                alohaDownloadButton(for: activeVideo, compact: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(16)
            }
        } else if currentSelection.isAmbiguous || browser.hasAnyMedia {
            // 複数動画が同時再生されている場合、またはリソース候補のみ検出されている場合
            fallbackOverlayButton
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(16)
        }
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

    private func startDownload(candidate: MediaCandidate, displayName: String, folderName: String) {
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

    // MARK: - ステータス表示と下部ツールバー（Safe Area内）

    @ViewBuilder
    private var statusBanner: some View {
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
            .background(.ultraThinMaterial)
        }
    }

    private var bottomToolbar: some View {
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
                showTabList = true
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "square.on.square")
                        .frame(minWidth: 44, minHeight: 44)

                    Text("\(tabManager.count)")
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.blue, in: Capsule())
                        .foregroundStyle(.white)
                        .offset(x: 10, y: 4)
                }
            }
            .accessibilityLabel("タブ (\(tabManager.count)件)")
        }
        .font(.title3)
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(.bar)
    }
}

// MARK: - メニューシート（進む・再読み込み・動画候補一覧・将来機能の明示）

struct BrowserMenuSheet: View {
    @ObservedObject var browser: BrowserModel
    @ObservedObject var downloads: DownloadCenter
    @ObservedObject var exports: VideoExportManager
    let onOpenCandidateList: () -> Void
    let onOpenDownloads: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("ページ操作") {
                    Button {
                        dismiss()
                        browser.goForward()
                    } label: {
                        Label("進む", systemImage: "chevron.right")
                    }
                    .disabled(!browser.canGoForward)

                    Button {
                        dismiss()
                        browser.reload()
                    } label: {
                        Label("再読み込み", systemImage: "arrow.clockwise")
                    }

                    Button {
                        dismiss()
                        browser.goHome()
                    } label: {
                        Label("ホームへ移動", systemImage: "house")
                    }
                }

                Section("動画とダウンロード") {
                    Button(action: onOpenCandidateList) {
                        HStack {
                            Label("動画の候補一覧", systemImage: "film.stack")
                            Spacer()
                            if !browser.candidateRows.isEmpty {
                                Text("\(browser.candidateRows.count)件")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(!browser.hasAnyMedia)

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
                    HStack {
                        Label("履歴", systemImage: "clock")
                        Spacer()
                        Text("Step 5で実装予定")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.secondary)

                    HStack {
                        Label("ブックマーク", systemImage: "bookmark")
                        Spacer()
                        Text("Step 6で実装予定")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.secondary)

                    HStack {
                        Label("プライベートタブ", systemImage: "eye.slash")
                        Spacer()
                        Text("Step 7で実装予定")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.secondary)

                    HStack {
                        Label("設定", systemImage: "gearshape")
                        Spacer()
                        Text("Step 8で実装予定")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.secondary)
                } header: {
                    Text("準備中の機能（将来のアップデート）")
                } footer: {
                    Text("閲覧履歴・ブックマーク・プライベートブラウズ・各種設定は、今後のステップで順次実装されます。")
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
}

// MARK: - 複数タブ一覧シート（Step 2-B 検証用タブ管理UI）

struct TabListSheet: View {
    @ObservedObject var tabManager: TabManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(tabManager.tabs) { tab in
                        tabRow(for: tab)
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            guard index < tabManager.tabs.count else { continue }
                            let tab = tabManager.tabs[index]
                            tabManager.closeTab(id: tab.id)
                        }
                    }
                } header: {
                    Text("開いているタブ (\(tabManager.count) / \(TabManager.maxTabs))")
                } footer: {
                    Text("タップしてタブを切り替え、または右上の「＋」で新しいタブを追加できます。Step 2-Cでカード型グリッド表示に進化予定です。")
                }
            }
            .navigationTitle("タブ一覧")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if tabManager.canCreateNewTab {
                            _ = tabManager.createNewTab()
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(!tabManager.canCreateNewTab)
                    .accessibilityLabel("新しいタブを開く")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func tabRow(for tab: BrowserModel) -> some View {
        let isActive = (tab.id == tabManager.activeTabID)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tab.pageTitle.isEmpty ? "名称未設定" : tab.pageTitle)
                    .font(.body.weight(isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? .primary : .secondary)
                    .lineLimit(1)

                Text(tab.address.isEmpty ? "about:blank" : tab.address)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.blue)
            }

            Button {
                tabManager.closeTab(id: tab.id)
            } label: {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("タブを閉じる")
        }
        .contentShape(Rectangle())
        .onTapGesture {
            tabManager.selectTab(id: tab.id)
            dismiss()
        }
    }
}

private struct BrowserWebView: UIViewRepresentable {
    let browser: BrowserModel
    func makeUIView(context: Context) -> WKWebView { browser.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) { }
}
