import SwiftUI
import WebKit
import AVKit

struct BrowserScreen: View {
    @StateObject private var browser = BrowserModel()
    @StateObject private var downloads = DownloadCenter()
    @State private var showCandidates = false
    @State private var showUnsupported = false
    @State private var showDownloads = false
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
                TextField("URL または検索", text: $browser.address)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($addressFocused)
                    .onSubmit {
                        browser.navigate(to: browser.address)
                        addressFocused = false
                    }
                if browser.isLoading { ProgressView().controlSize(.small) }
                Button { browser.reload() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("再読み込み")
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            ZStack(alignment: .bottomTrailing) {
                BrowserWebView(browser: browser)
                    .ignoresSafeArea(.keyboard, edges: .bottom)

                if browser.hasPlayingVideo || !browser.candidates.isEmpty {
                    Button {
                        if browser.candidates.isEmpty { showUnsupported = true }
                        else { showCandidates = true }
                    } label: {
                        Label("動画を保存", systemImage: "arrow.down.to.line.compact")
                            .font(.system(size: 15, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(.blue, in: Capsule())
                            .foregroundStyle(.white)
                            .shadow(radius: 6)
                    }
                    .padding(16)
                }
            }

            if let message = downloads.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
            }
            HStack {
                Button { browser.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!browser.canGoBack)
                Spacer()
                Button { browser.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!browser.canGoForward)
                Spacer()
                Button { browser.navigate(to: "https://example.com") } label: { Image(systemName: "house") }
                Spacer()
                Button { showDownloads = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "folder")
                        if downloads.activeCount > 0 { Text("\(downloads.activeCount)").font(.caption2) }
                    }
                }
            }
            .font(.title3)
            .buttonStyle(.plain)
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .confirmationDialog("保存する動画を選択", isPresented: $showCandidates,
                            titleVisibility: .visible) {
            ForEach(browser.candidates) { candidate in
                Button(candidate.shortDescription) {
                    downloads.start(candidate, from: browser.webView)
                }
            }
        } message: {
            Text("保存が許可されている動画を選択してください。配信方法や認証によっては保存できません。")
        }
        .alert("ダウンロードURLを検出できません", isPresented: $showUnsupported) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("動画は検出しましたが、直接保存可能なURLが見つかりません。blob/MSE・DRM・サイト専用の配信方式などには対応していません。")
        }
        .sheet(isPresented: $showDownloads) {
            DownloadLibrary(downloads: downloads)
        }
    }
}

private struct BrowserWebView: UIViewRepresentable {
    let browser: BrowserModel
    func makeUIView(context: Context) -> WKWebView { browser.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) { }
}

private struct DownloadLibrary: View {
    @ObservedObject var downloads: DownloadCenter
    @Environment(\.dismiss) private var dismiss
    @State private var selectedVideo: SavedVideo?

    var body: some View {
        NavigationStack {
            List {
                if downloads.saved.isEmpty {
                    ContentUnavailableView("保存した動画はありません",
                                           systemImage: "square.and.arrow.down",
                                           description: Text("動画再生中に表示される保存ボタンから追加できます。"))
                }
                ForEach(downloads.saved) { video in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(video.title).lineLimit(2).font(.headline)
                        Text("\(video.format) · \(video.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 20) {
                            Button("再生") { selectedVideo = video }
                                .buttonStyle(.borderless)
                            if !video.isHLS, let fileURL = video.fileURL {
                                ShareLink(item: fileURL) {
                                    Label("共有・書き出し", systemImage: "square.and.arrow.up")
                                }
                            }
                        }
                        .font(.subheadline)
                    }
                    .padding(.vertical, 6)
                }
                .onDelete { indices in
                    let selected = indices.map { downloads.saved[$0] }
                    for video in selected { downloads.delete(video) }
                }
            }
            .navigationTitle("ダウンロード")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
            .sheet(item: $selectedVideo) { video in
                NavigationStack {
                    Group {
                        if let url = video.fileURL, FileManager.default.fileExists(atPath: url.path) {
                            VideoPlayer(player: AVPlayer(url: url))
                        } else {
                            ContentUnavailableView("ファイルがありません", systemImage: "exclamationmark.triangle",
                                                   description: Text("保存場所が変更されたか、OSによって消去された可能性があります。"))
                        }
                    }
                    .navigationTitle(video.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("閉じる") { selectedVideo = nil }
                        }
                    }
                }
            }
        }
    }
}
