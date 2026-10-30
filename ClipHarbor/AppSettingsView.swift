import SwiftUI
import WebKit

/// アプリ全体の設定画面
/// - 【ブラウザ】検索エンジンの変更、閲覧データの個別削除
/// - 【ファイルとストレージ】ストレージ情報、メモリキャッシュ解放、ゴミ箱保持期間
/// - 【プライバシー】Private Vault設定（隠しモード時は完全非表示）
/// - 【アプリ情報】実バージョン・ビルド番号、ライセンス・セキュリティ方針
struct AppSettingsView: View {
    @ObservedObject var downloads: DownloadCenter
    @ObservedObject var folderManager: VideoFolderManager
    @ObservedObject private var settingsManager = AppSettingsManager.shared
    @ObservedObject private var vaultManager = VaultManager.shared
    @ObservedObject private var trashManager = TrashManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showVaultAuth = false
    @State private var showVaultSettings = false
    @State private var showClearDataSheet = false
    @State private var toastMessage: String?
    @State private var versionTapCount = 0

    // ストレージ実測
    private var totalSavedBytes: Int64 {
        downloads.saved.reduce(0) { $0 + ($1.byteSize ?? 0) }
    }

    private var totalTrashBytes: Int64 {
        trashManager.items.reduce(0) { $0 + ($1.byteSize ?? 0) }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.3.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        NavigationStack {
            List {
                // MARK: - 【ブラウザ】
                Section {
                    Picker(NSLocalizedString("Default Search Engine", comment: ""), selection: $settingsManager.searchEngine) {
                        ForEach(SearchEngine.allCases) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }

                    Button {
                        showClearDataSheet = true
                    } label: {
                        HStack {
                            Text(NSLocalizedString("Clear Browsing Data", comment: ""))
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text(NSLocalizedString("Browser", comment: ""))
                } footer: {
                    Text(NSLocalizedString("Entering a URL directly in the search bar opens the webpage without searching.", comment: ""))
                        .font(.caption2)
                }

                // MARK: - 【コンテンツブロック】
                Section {
                    Toggle(NSLocalizedString("Block Ads & Trackers", comment: ""), isOn: $settingsManager.blockAdsAndTrackers)
                    Toggle(NSLocalizedString("Block Annoying Pop-ups", comment: ""), isOn: $settingsManager.blockAnnoyingPopups)
                } header: {
                    Text(NSLocalizedString("Content Blocking", comment: ""))
                } footer: {
                    Text(NSLocalizedString("Block evaluation is performed on-device using local rules. Browsing URLs and history are never sent to external servers for block evaluation.", comment: ""))
                        .font(.caption2)
                }

                // MARK: - 【ファイルとストレージ】
                Section(NSLocalizedString("Files and Storage", comment: "")) {
                    HStack {
                        Label(NSLocalizedString("Saved Videos", comment: ""), systemImage: "play.rectangle")
                        Spacer()
                        Text("\(String.localizedStringWithFormat(NSLocalizedString("%lld videos", comment: ""), Int64(downloads.saved.count))) (\(ByteCountFormatter.string(fromByteCount: totalSavedBytes, countStyle: .file)))")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Label(NSLocalizedString("Folders", comment: ""), systemImage: "folder")
                        Spacer()
                        Text(String.localizedStringWithFormat(NSLocalizedString("%lld folders", comment: ""), Int64(folderManager.folders.count)))
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Label(NSLocalizedString("Trash", comment: ""), systemImage: "trash")
                        Spacer()
                        Text("\(String.localizedStringWithFormat(NSLocalizedString("%lld items", comment: ""), Int64(trashManager.items.count))) (\(ByteCountFormatter.string(fromByteCount: totalTrashBytes, countStyle: .file)))")
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        VideoThumbnailManager.shared.clearAllCache()
                        showToast(NSLocalizedString("Cleared thumbnail memory cache", comment: ""))
                    } label: {
                        HStack {
                            Label(NSLocalizedString("Clear Thumbnail Memory Cache", comment: ""), systemImage: "photo.on.rectangle.angled")
                            Spacer()
                        }
                    }

                    Picker(NSLocalizedString("Trash Retention Period", comment: ""), selection: $settingsManager.trashRetentionPeriod) {
                        ForEach(TrashRetentionPeriod.allCases) { period in
                            Text(period.title).tag(period)
                        }
                    }

                    NavigationLink {
                        FileManagerSettingsView(
                            downloads: downloads,
                            folderManager: folderManager
                        )
                    } label: {
                        Label(NSLocalizedString("Advanced File Settings", comment: ""), systemImage: "slider.horizontal.3")
                    }
                }

                // MARK: - 【プライバシー】
                Section {
                    Button {
                        if vaultManager.isUnlocked {
                            showVaultSettings = true
                        } else {
                            showVaultAuth = true
                        }
                    } label: {
                        HStack {
                            Label(NSLocalizedString("Private Vault Settings", comment: ""), systemImage: "lock.shield")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(vaultManager.isUnlocked ? NSLocalizedString("Unlocked", comment: "") : NSLocalizedString("Locked", comment: ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text(NSLocalizedString("Privacy", comment: ""))
                } footer: {
                    Text(NSLocalizedString("Private Browsing and Private Vault are independent features. History and cookies from private tabs are automatically discarded when tabs are closed.", comment: ""))
                        .font(.caption2)
                }

                // MARK: - 【アプリ情報】
                Section(NSLocalizedString("App Information", comment: "")) {
                    HStack {
                        Text(NSLocalizedString("App Name", comment: ""))
                        Spacer()
                        Text("ClipHarbor")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text(NSLocalizedString("Version", comment: ""))
                        Spacer()
                        Text(appVersion)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        versionTapCount += 1
                        if versionTapCount >= 5 {
                            versionTapCount = 0
                            settingsManager.enableDeveloperDiagnostics.toggle()
                            let state = settingsManager.enableDeveloperDiagnostics ? NSLocalizedString("Enabled", comment: "") : NSLocalizedString("Disabled", comment: "")
                            showToast(String(format: "%@: %@", NSLocalizedString("Developer Diagnostics", comment: ""), state))
                        }
                    }

                    HStack {
                        Text(NSLocalizedString("Build Number", comment: ""))
                        Spacer()
                        Text(buildNumber)
                            .foregroundStyle(.secondary)
                    }

                    NavigationLink {
                        AppLicensesView()
                    } label: {
                        Text(NSLocalizedString("Licenses & Security Policy", comment: ""))
                    }
                }

                if settingsManager.enableDeveloperDiagnostics {
                    Section(NSLocalizedString("Developer Diagnostics", comment: "")) {
                        Toggle(NSLocalizedString("Enable Playback Diagnostics", comment: ""), isOn: $settingsManager.enableDeveloperDiagnostics)
                    } footer: {
                        Text(NSLocalizedString("Shows diagnostic stethoscope tool during video playback for troubleshooting.", comment: ""))
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(NSLocalizedString("Settings", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("Close", comment: "")) { dismiss() }
                }
            }
            .sheet(isPresented: $showClearDataSheet) {
                ClearBrowsingDataSheet()
            }
            .sheet(isPresented: $showVaultAuth) {
                // 未解錠時の認証画面
                PrivateVaultView(
                    downloads: downloads,
                    folderManager: folderManager
                )
            }
            .sheet(isPresented: $showVaultSettings) {
                VaultSettingsView()
            }
            .overlay(alignment: .top) {
                if let toast = toastMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(toast)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: toastMessage)
        }
    }

    private func showToast(_ msg: String) {
        toastMessage = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation {
                toastMessage = nil
            }
        }
    }
}

// MARK: - 閲覧データ削除シート

private struct ClearBrowsingDataSheet: View {
    @ObservedObject private var historyManager = HistoryManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var clearHistory = true
    @State private var clearCookies = false
    @State private var clearCache = true
    @State private var showConfirmAlert = false
    @State private var isProcessing = false
    @State private var statusMessage: String?
    @State private var isError = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(String.localizedStringWithFormat(NSLocalizedString("clear_history_toggle %lld", comment: ""), Int64(historyManager.items.count)), isOn: $clearHistory)
                    Toggle(NSLocalizedString("Cookies & Site Data (Login Info, etc.)", comment: ""), isOn: $clearCookies)
                    Toggle(NSLocalizedString("Web Cache (Cached Images & Styles)", comment: ""), isOn: $clearCache)
                } header: {
                    Text(NSLocalizedString("Select Data to Clear", comment: ""))
                } footer: {
                    if clearCookies {
                        Text(NSLocalizedString("※ Clearing cookies will log you out of active website sessions. Saved videos, bookmarks, and Private Vault are completely unaffected.", comment: ""))
                            .font(.caption2)
                            .foregroundStyle(.red)
                    } else {
                        Text(NSLocalizedString("Saved videos, bookmarks, and Private Vault are completely unaffected.", comment: ""))
                            .font(.caption2)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        if clearCookies {
                            showConfirmAlert = true
                        } else {
                            performClear()
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if isProcessing {
                                ProgressView()
                                    .padding(.trailing, 8)
                            }
                            Text(NSLocalizedString("Clear Selected Browsing Data", comment: ""))
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(!clearHistory && !clearCookies && !clearCache || isProcessing)
                }

                if let msg = statusMessage {
                    Section {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(isError ? .red : .green)
                    }
                }
            }
            .navigationTitle(NSLocalizedString("Clear Browsing Data", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("Close", comment: "")) { dismiss() }
                        .disabled(isProcessing)
                }
            }
            .alert(NSLocalizedString("Clear Cookies & Site Data", comment: ""), isPresented: $showConfirmAlert) {
                Button(NSLocalizedString("Cancel", comment: ""), role: .cancel) { }
                Button(NSLocalizedString("Clear", comment: ""), role: .destructive) {
                    performClear()
                }
            } message: {
                Text(NSLocalizedString("Clearing cookies will reset website login sessions. Continue?", comment: ""))
            }
        }
    }

    private func performClear() {
        isProcessing = true
        statusMessage = nil
        isError = false

        Task {
            do {
                try await AppSettingsManager.shared.clearBrowsingData(
                    clearHistory: clearHistory,
                    clearCookies: clearCookies,
                    clearCache: clearCache
                )
                await MainActor.run {
                    isProcessing = false
                    statusMessage = NSLocalizedString("Successfully cleared selected browsing data.", comment: "")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        dismiss()
                    }
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    isError = true
                    let format = NSLocalizedString("An error occurred while clearing data: %@", comment: "")
                    statusMessage = String(format: format, error.localizedDescription)
                }
            }
        }
    }
}

// MARK: - ライセンス・セキュリティ方針ビュー

private struct AppLicensesView: View {
    var body: some View {
        List {
            Section(NSLocalizedString("Frameworks & Libraries", comment: "")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Apple Native SDKs")
                        .font(.headline)
                    Text(NSLocalizedString("licenses_apple_sdks_desc", comment: ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 6) {
                    Text(NSLocalizedString("Third-Party SDKs", comment: ""))
                        .font(.headline)
                    Text(NSLocalizedString("licenses_third_party_desc", comment: ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section(NSLocalizedString("Security & Privacy Policy", comment: "")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(NSLocalizedString("Token Leakage Prevention (DL-04)", comment: ""))
                        .font(.headline)
                    Text(NSLocalizedString("licenses_dl04_desc", comment: ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 6) {
                    Text(NSLocalizedString("Private Vault Encryption", comment: ""))
                        .font(.headline)
                    Text(NSLocalizedString("licenses_vault_enc_desc", comment: ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section(NSLocalizedString("Content Blocker & Data Sources", comment: "")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("AdAway Default Blocklist")
                        .font(.headline)
                    Text(NSLocalizedString("licenses_adaway_desc", comment: ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(NSLocalizedString("licenses_adaway_license", comment: ""))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle(NSLocalizedString("Licenses & Policy", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
    }
}
