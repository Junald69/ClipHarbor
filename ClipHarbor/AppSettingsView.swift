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
                    Picker("既定の検索エンジン", selection: $settingsManager.searchEngine) {
                        ForEach(SearchEngine.allCases) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }

                    Button {
                        showClearDataSheet = true
                    } label: {
                        HStack {
                            Text("閲覧データの削除")
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("ブラウザ")
                } footer: {
                    Text("検索バーに直接URLを入力した場合は、検索を行わず直接そのWebページを開きます。")
                        .font(.caption2)
                }

                // MARK: - 【ファイルとストレージ】
                Section("ファイルとストレージ") {
                    HStack {
                        Label("保存済み動画", systemImage: "play.rectangle")
                        Spacer()
                        Text("\(downloads.saved.count) 本 (\(ByteCountFormatter.string(fromByteCount: totalSavedBytes, countStyle: .file)))")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Label("フォルダ数", systemImage: "folder")
                        Spacer()
                        Text("\(folderManager.folders.count) 個")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Label("ゴミ箱", systemImage: "trash")
                        Spacer()
                        Text("\(trashManager.items.count) 件 (\(ByteCountFormatter.string(fromByteCount: totalTrashBytes, countStyle: .file)))")
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        VideoThumbnailManager.shared.clearAllCache()
                        showToast("サムネイルのメモリキャッシュを解放しました")
                    } label: {
                        HStack {
                            Label("サムネイルのメモリキャッシュを解放", systemImage: "photo.on.rectangle.angled")
                            Spacer()
                        }
                    }

                    Picker("ゴミ箱の保持期間", selection: $settingsManager.trashRetentionPeriod) {
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
                        Label("ファイル管理の詳細設定", systemImage: "slider.horizontal.3")
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
                    Text("プライバシー")
                } footer: {
                    Text("プライベートブラウズとPrivate Vaultは独立した機能です。プライベートタブの履歴・Cookieはタブ終了時に自動破棄されます。")
                        .font(.caption2)
                }

                // MARK: - 【アプリ情報】
                Section("アプリ情報") {
                    HStack {
                        Text("アプリ名")
                        Spacer()
                        Text("ClipHarbor")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("バージョン")
                        Spacer()
                        Text(appVersion)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("ビルド番号")
                        Spacer()
                        Text(buildNumber)
                            .foregroundStyle(.secondary)
                    }

                    NavigationLink {
                        AppLicensesView()
                    } label: {
                        Text("ライセンスとセキュリティ方針")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
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
                    Toggle("閲覧履歴 (\(historyManager.items.count)件)", isOn: $clearHistory)
                    Toggle("Cookie・サイトデータ (ログイン情報等)", isOn: $clearCookies)
                    Toggle("Webキャッシュ (一時保存された画像・スタイル)", isOn: $clearCache)
                } header: {
                    Text("削除対象の選択")
                } footer: {
                    if clearCookies {
                        Text("※ Cookieを削除すると、ログイン中のWebサイトからログアウトされます。保存済みの動画、ブックマーク、Private Vaultには一切影響しません。")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    } else {
                        Text("保存済みの動画、ブックマーク、Private Vaultには一切影響しません。")
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
                            Text("選択した閲覧データを削除")
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
            .navigationTitle("閲覧データの削除")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                        .disabled(isProcessing)
                }
            }
            .alert("Cookie・サイトデータの削除", isPresented: $showConfirmAlert) {
                Button("キャンセル", role: .cancel) { }
                Button("削除する", role: .destructive) {
                    performClear()
                }
            } message: {
                Text("Cookieを削除すると、Webサイトのログイン状態がリセットされます。続行しますか？")
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
                    statusMessage = "選択した閲覧データを正常に削除しました。"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        dismiss()
                    }
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    isError = true
                    statusMessage = "削除処理中にエラーが発生しました: \(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - ライセンス・セキュリティ方針ビュー

private struct AppLicensesView: View {
    var body: some View {
        List {
            Section("フレームワークとライブラリ") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Apple Native SDKs")
                        .font(.headline)
                    Text("ClipHarborはApple標準のSwiftUI, AVFoundation, WebKit, CryptoKit, CommonCrypto, Security, LocalAuthenticationフレームワークのみを使用して構築されています。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 6) {
                    Text("サードパーティ製SDK")
                        .font(.headline)
                    Text("外部のクラウド解析、トラッキング、広告配信SDKは一切組み込まれていません。通信はユーザー自身がアクセスするWebサイトおよび動画ホストとの間でのみ行われます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("セキュリティ・プライバシー保護方針") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("トークン漏洩防止 (DL-04)")
                        .font(.headline)
                    Text("保存済み動画のメタデータには動画自体の直接URL（認証トークン等を含むURL）は永続化されず、ブラウザで閲覧していたWebページURLのみが安全に保持されます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Private Vault の暗号化")
                        .font(.headline)
                    Text("保管庫内のファイルはAES-256-GCMによりローカルでストリーム暗号化され、パスコードから導出されたマスター鍵で保護されます。外部サーバーへの鍵送信は行われません。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("ライセンスと方針")
        .navigationBarTitleDisplayMode(.inline)
    }
}
