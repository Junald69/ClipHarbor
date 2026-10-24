import SwiftUI
import WebKit

struct BrowserScreen: View {
    @StateObject private var browser = BrowserModel()
    @ObservedObject private var downloads = DownloadCenter.shared
    @ObservedObject private var folderManager = VideoFolderManager.shared
    @ObservedObject private var exports = VideoExportManager.shared

    @State private var savingCandidate: MediaCandidate?
    @State private var showCandidateList = false
    @State private var showDownloads = false
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
            Button { browser.goBack() } label: {
                Image(systemName: "chevron.left")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(!browser.canGoBack)
            .accessibilityLabel("戻る")

            Spacer()

            Button { browser.goForward() } label: {
                Image(systemName: "chevron.right")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(!browser.canGoForward)
            .accessibilityLabel("進む")

            Spacer()

            Button { browser.goHome() } label: {
                Image(systemName: "house")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("ホーム")

            Spacer()

            Button { showCandidateList = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle")
                    if !browser.candidateRows.isEmpty {
                        Text("\(browser.candidateRows.count)")
                            .font(.caption2.weight(.bold))
                    }
                }
                .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(!browser.hasAnyMedia)
            .accessibilityLabel("動画の候補一覧")

            Spacer()

            Button { showDownloads = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                    if downloads.activeCount + exports.activeCount > 0 {
                        Text("\(downloads.activeCount + exports.activeCount)")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.blue, in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
                .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("ダウンロード一覧")
        }
        .font(.title3)
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
        .background(.bar)
    }
}

private struct BrowserWebView: UIViewRepresentable {
    let browser: BrowserModel
    func makeUIView(context: Context) -> WKWebView { browser.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) { }
}
