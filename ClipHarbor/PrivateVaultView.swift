import SwiftUI
import LocalAuthentication
import AVKit

/// Private Vault（非公開保管庫）のメイン画面
/// - 初回パスコード設定 (6桁PIN)
/// - パスコード入力 / Face ID・Touch ID によるロック解除
/// - Aloha風2列カードグリッドによる完全暗号化動画一覧
/// - 安全な一時復号再生（AVPlayer対応、終了時・バックグラウンド時即時抹消）
/// - アトミックな通常一覧への復元および完全削除
/// - App Switcherプライバシーシールド
struct PrivateVaultView: View {
    @ObservedObject var vaultManager = VaultManager.shared
    @ObservedObject var downloads: DownloadCenter
    @ObservedObject var folderManager: VideoFolderManager
    @Environment(\.dismiss) private var dismiss

    @State private var showChangePasscode = false
    @State private var showVaultSettings = false
    @State private var showImportSheet = false
    @State private var activePlayingItem: VaultItem?
    @State private var activePlaybackURL: URL?
    @State private var deletingItem: VaultItem?
    @State private var isSelectionMode = false
    @State private var selectedItemIDs: Set<UUID> = []
    @State private var showBatchDeleteAlert = false
    @State private var noticeMessage: String?
    @State private var errorMessage: String?
    @State private var isOperating = false

    var body: some View {
        NavigationStack {
            ZStack {
                if !vaultManager.isInitialized {
                    // 1. 初回セットアップ画面
                    VaultPasscodeSetupView(
                        onCompleted: {
                            showToast("Private Vaultを設定しました")
                        },
                        onCancel: {
                            dismiss()
                        }
                    )
                } else if !vaultManager.isUnlocked {
                    // 2. ロック解除画面
                    VaultUnlockView(
                        onUnlocked: {
                            showToast("保管庫のロックを解除しました")
                        },
                        onCancel: {
                            dismiss()
                        }
                    )
                } else {
                    // 3. アンロック後: Aloha風ファイルグリッド一覧
                    vaultContentView
                }

                // 処理中プログレスオーバーレイ
                processingOverlay

                // 操作通知トースト
                noticeToastOverlay

                // App Switcher等のプライバシーシールド
                privacyShieldOverlay
            }
            .animation(.easeInOut(duration: 0.25), value: noticeMessage)
            .animation(.easeInOut(duration: 0.25), value: vaultManager.isProcessing)
            .animation(.easeInOut(duration: 0.2), value: vaultManager.isPrivacyShieldActive)
            .navigationTitle(vaultManager.isUnlocked ? "Private Vault" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if vaultManager.isUnlocked {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("閉じる") {
                            vaultManager.lock()
                            dismiss()
                        }
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 12) {
                            Button {
                                showImportSheet = true
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 15, weight: .bold))
                                    .frame(width: 32, height: 32)
                            }
                            .disabled(isSelectionMode)

                            if !vaultManager.items.isEmpty {
                                Button(isSelectionMode ? "完了" : "選択") {
                                    withAnimation {
                                        isSelectionMode.toggle()
                                        if !isSelectionMode {
                                            selectedItemIDs.removeAll()
                                        }
                                    }
                                }
                            }

                            Menu {
                                Button {
                                    showVaultSettings = true
                                } label: {
                                    Label("Vault設定", systemImage: "gearshape")
                                }

                                Divider()

                                Button(role: .destructive) {
                                    vaultManager.lock()
                                    dismiss()
                                } label: {
                                    Label("今すぐロックして閉じる", systemImage: "lock.fill")
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 15, weight: .bold))
                                    .frame(width: 32, height: 32)
                            }
                        }
                    }
                }
            }
            .fullScreenCover(item: $activePlayingItem) { item in
                vaultPlayerCover(for: item)
            }
            .sheet(isPresented: $showChangePasscode) {
                VaultChangePasscodeView {
                    showToast("パスコードを変更しました")
                }
            }
            .sheet(isPresented: $showVaultSettings) {
                VaultSettingsView()
            }
            .sheet(isPresented: $showImportSheet) {
                VaultImportPickerView(
                    downloads: downloads,
                    folderManager: folderManager,
                    onImport: { videos in
                        handleImportVideos(videos)
                    }
                )
            }
            .alert("完全に削除", isPresented: Binding(
                get: { deletingItem != nil },
                set: { if !$0 { deletingItem = nil } }
            )) {
                Button("キャンセル", role: .cancel) { deletingItem = nil }
                Button("完全に削除", role: .destructive) {
                    if let item = deletingItem {
                        performDelete(item)
                    }
                }
            } message: {
                Text("「\(deletingItem?.originalTitle ?? "")」を端末から完全に削除しますか？\n暗号化データは復元できなくなります。")
            }
            .alert("選択したアイテムを削除", isPresented: $showBatchDeleteAlert) {
                Button("キャンセル", role: .cancel) { }
                Button("完全に削除", role: .destructive) {
                    performBatchDelete()
                }
            } message: {
                Text("選択された \(selectedItemIDs.count) 件の動画を完全に削除しますか？\nこの操作は取り消せません。")
            }
            .alert("エラー", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: - サブビュー（コンパイラ型推論負荷軽減）

    @ViewBuilder
    private var processingOverlay: some View {
        if vaultManager.isProcessing {
            ZStack {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.2)
                        .tint(.white)
                    Text(vaultManager.processingMessage)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                }
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var noticeToastOverlay: some View {
        if let notice = noticeMessage {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(notice)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .zIndex(10)
        }
    }

    @ViewBuilder
    private var privacyShieldOverlay: some View {
        if vaultManager.isPrivacyShieldActive {
            ZStack {
                Color(.systemBackground)
                    .ignoresSafeArea()
                VStack(spacing: 16) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.indigo)
                    Text("Private Vault 保護中")
                        .font(.headline)
                }
            }
            .transition(.opacity)
            .zIndex(99)
        }
    }

    @ViewBuilder
    private func vaultPlayerCover(for item: VaultItem) -> some View {
        let context = PlaybackPlaylistContext(vaultItems: vaultManager.items, initialItem: item)
        ModernVideoPlayerView(playlistContext: context) {
            activePlaybackURL = nil
            vaultManager.cleanupPlaybackTemp(for: item.id)
        }
    }

    // MARK: - アンロック後コンテンツ一覧

    private let gridColumns = [
        GridItem(.flexible(), spacing: 14, alignment: .top),
        GridItem(.flexible(), spacing: 14, alignment: .top)
    ]

    private var vaultContentView: some View {
        ZStack(alignment: .bottom) {
            if vaultManager.items.isEmpty {
                emptyVaultPlaceholder
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        securityInfoBanner

                        LazyVGrid(columns: gridColumns, spacing: 18) {
                            ForEach(vaultManager.items) { item in
                                AlohaVaultCardView(
                                    item: item,
                                    isSelectionMode: isSelectionMode,
                                    isSelected: selectedItemIDs.contains(item.id),
                                    onSelect: {
                                        if selectedItemIDs.contains(item.id) {
                                            selectedItemIDs.remove(item.id)
                                        } else {
                                            selectedItemIDs.insert(item.id)
                                        }
                                    },
                                    onPlay: {
                                        playItem(item)
                                    },
                                    onRestore: {
                                        restoreItem(item)
                                    },
                                    onDelete: {
                                        deletingItem = item
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                        .padding(.bottom, isSelectionMode ? 80 : 24)
                    }
                }
            }

            // 選択モード時の下部フローティングバー
            if isSelectionMode && !selectedItemIDs.isEmpty {
                selectionBottomBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - セキュリティ情報バナー

    private var securityInfoBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .font(.caption)
                .foregroundStyle(.indigo)

            Text("AES-256-GCM暗号化により保護されています。iOSファイル共有や外部アプリからは参照できません。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    // MARK: - プレースホルダー（保管庫が空の場合）

    private var emptyVaultPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 52))
                .foregroundStyle(.indigo)
            Text("Private Vault は空です")
                .font(.headline)
            Text("ファイル一覧の「…」メニューから動画をVaultへ移動すると、AES-256暗号化されてここに安全に保管されます。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 選択モード用フローティング操作バー

    private var selectionBottomBar: some View {
        HStack(spacing: 16) {
            Button {
                performBatchRestore()
            } label: {
                Label("復元 (\(selectedItemIDs.count))", systemImage: "arrow.uturn.backward")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            }

            Button(role: .destructive) {
                showBatchDeleteAlert = true
            } label: {
                Label("削除 (\(selectedItemIDs.count))", systemImage: "trash")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    // MARK: - 操作ロジック

    private func playItem(_ item: VaultItem) {
        do {
            let tempURL = try vaultManager.preparePlaybackURL(for: item)
            activePlaybackURL = tempURL
            activePlayingItem = item
        } catch {
            errorMessage = "再生の準備に失敗しました: \(error.localizedDescription)"
        }
    }

    private func restoreItem(_ item: VaultItem) {
        guard !isOperating else { return }
        isOperating = true
        Task {
            do {
                try await vaultManager.restoreFromVault(
                    item: item,
                    targetFolder: nil,
                    downloads: downloads,
                    folderManager: folderManager
                )
                showToast("「\(item.originalTitle)」を復元しました")
            } catch {
                errorMessage = "復元に失敗しました: \(error.localizedDescription)"
            }
            isOperating = false
        }
    }

    private func performDelete(_ item: VaultItem) {
        do {
            try vaultManager.deletePermanently(item: item)
            showToast("完全に削除しました")
        } catch {
            errorMessage = "削除に失敗しました: \(error.localizedDescription)"
        }
        deletingItem = nil
    }

    private func performBatchRestore() {
        guard !isOperating else { return }
        let targetItems = vaultManager.items.filter { selectedItemIDs.contains($0.id) }
        guard !targetItems.isEmpty else { return }

        isOperating = true
        Task {
            let result = await vaultManager.restoreMultipleFromVault(
                items: targetItems,
                targetFolder: nil,
                downloads: downloads,
                folderManager: folderManager
            )
            isSelectionMode = false
            selectedItemIDs.removeAll()
            isOperating = false
            showToast("\(result.succeeded) 件の動画を復元しました")
        }
    }

    private func performBatchDelete() {
        let targetItems = vaultManager.items.filter { selectedItemIDs.contains($0.id) }
        do {
            try vaultManager.deleteMultiplePermanently(items: targetItems)
            isSelectionMode = false
            selectedItemIDs.removeAll()
            showToast("\(targetItems.count) 件を完全に削除しました")
        } catch {
            errorMessage = "一括削除に失敗しました: \(error.localizedDescription)"
        }
    }

    private func handleImportVideos(_ videos: [SavedVideo]) {
        guard !videos.isEmpty else { return }
        Task {
            let (succeeded, _) = await vaultManager.moveMultipleToVault(
                videos: videos,
                downloads: downloads,
                folderManager: folderManager
            )
            showToast("\(succeeded) 件の動画を取り込みました")
        }
    }

    private func showToast(_ message: String) {
        noticeMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            withAnimation(.easeInOut(duration: 0.2)) {
                noticeMessage = nil
            }
        }
    }
}

// MARK: - Aloha風Vault動画カード

private struct AlohaVaultCardView: View {
    let item: VaultItem
    let isSelectionMode: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let onPlay: () -> Void
    let onRestore: () -> Void
    let onDelete: () -> Void

    @ObservedObject private var vaultManager = VaultManager.shared
    @ScaledMetric(relativeTo: .subheadline) private var titleLineHeight: CGFloat = 20
    @ScaledMetric(relativeTo: .caption2) private var subtitleHeight: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                // サムネイル表示
                VaultThumbnailTileView(item: item)
                    .frame(height: 140)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .onTapGesture {
                        if isSelectionMode {
                            onSelect()
                        } else {
                            onPlay()
                        }
                    }

                // 左上: 選択チェックボックス
                if isSelectionMode {
                    HStack {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 22))
                            .foregroundStyle(isSelected ? Color.indigo : Color.white.opacity(0.85))
                            .background(isSelected ? Color.white : Color.black.opacity(0.3), in: Circle())
                            .padding(8)
                        Spacer()
                    }
                }

                // 右上: 「…」メニューボタン
                if !isSelectionMode {
                    Menu {
                        Button(action: onPlay) {
                            Label("再生", systemImage: "play.fill")
                        }

                        Button(action: onRestore) {
                            Label("通常一覧へ復元", systemImage: "arrow.uturn.backward")
                        }

                        Divider()

                        Button(role: .destructive, action: onDelete) {
                            Label("完全に削除", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.primary)
                            .frame(width: 28, height: 28)
                            .background(Color.white.opacity(0.92), in: Circle())
                            .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
                            .padding(8)
                    }
                    .buttonStyle(.plain)
                }

                // 左下: 暗号化保護バッジ
                VStack {
                    Spacer()
                    HStack {
                        HStack(spacing: 4) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 9))
                            Text("暗号化")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.65), in: Capsule())
                        .padding(6)
                        Spacer()
                    }
                }
            }
            .frame(height: 140)

            // テキスト領域
            VStack(alignment: .leading, spacing: 2) {
                Text(item.originalTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(height: titleLineHeight * 2, alignment: .topLeading)

                HStack(spacing: 4) {
                    Text(item.format.label)
                        .font(.caption2.weight(.semibold))

                    Text("· \(item.formattedSize)")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .frame(height: subtitleHeight, alignment: .leading)

                Text("保管: \(item.vaultAddedAt.formatted(date: .numeric, time: .omitted))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelectionMode {
                onSelect()
            } else {
                onPlay()
            }
        }
    }
}

// MARK: - Vault用サムネイルビュー（非同期復号・インメモリキャッシュ）

private struct VaultThumbnailTileView: View {
    let item: VaultItem
    @ObservedObject private var vaultManager = VaultManager.shared
    @State private var thumbnailImage: UIImage?

    var body: some View {
        ZStack {
            Color(.secondarySystemGroupedBackground)

            if let image = thumbnailImage {
                GeometryReader { geo in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.indigo.opacity(0.8))
                    Text(item.format.label)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            loadThumbnail()
        }
    }

    private func loadThumbnail() {
        if let img = vaultManager.thumbnail(for: item) {
            thumbnailImage = img
        }
    }
}

// MARK: - 再生シート

private struct VaultVideoPlayerSheet: View {
    let item: VaultItem
    let url: URL
    let onDismiss: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                VideoPlayer(player: player)
                    .ignoresSafeArea(edges: .bottom)
            }
            .navigationTitle(item.originalTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("閉じる") {
                        dismiss()
                    }
                    .tint(.white)
                }
            }
            .onAppear {
                let avPlayer = AVPlayer(url: url)
                self.player = avPlayer
                avPlayer.play()
            }
            .onDisappear {
                player?.pause()
                player = nil
                onDismiss()
            }
        }
    }
}

// MARK: - 初回パスコード設定画面

private struct VaultPasscodeSetupView: View {
    let onCompleted: () -> Void
    let onCancel: () -> Void

    @ObservedObject private var vaultManager = VaultManager.shared
    @State private var step: SetupStep = .enterFirst
    @State private var firstPasscode: String = ""
    @State private var confirmPasscode: String = ""
    @State private var enableBiometrics = true
    @State private var errorMessage: String?
    @State private var shakeOffset: CGFloat = 0

    enum SetupStep {
        case enterFirst
        case confirm
    }

    private var currentPasscode: Binding<String> {
        Binding(
            get: { step == .enterFirst ? firstPasscode : confirmPasscode },
            set: { val in
                if step == .enterFirst {
                    firstPasscode = val
                    if val.count == 6 {
                        withAnimation {
                            step = .confirm
                        }
                    }
                } else {
                    confirmPasscode = val
                    if val.count == 6 {
                        verifyAndSave()
                    }
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 24) {
            HStack {
                Button("キャンセル", action: onCancel)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            Spacer()

            // アイコン
            ZStack {
                Circle()
                    .fill(Color.indigo.opacity(0.12))
                    .frame(width: 88, height: 88)
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(.indigo)
            }

            VStack(spacing: 8) {
                Text(step == .enterFirst ? "Private Vaultの作成" : "パスコードの確認")
                    .font(.title2.weight(.bold))
                Text(step == .enterFirst ? "保管庫のパスコード（6桁の数字）を設定してください" : "確認のため、もう一度入力してください")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            // PINドット表示
            HStack(spacing: 16) {
                ForEach(0..<6, id: \.self) { index in
                    Circle()
                        .fill(index < currentPasscode.wrappedValue.count ? Color.indigo : Color(.systemGray4))
                        .frame(width: 14, height: 14)
                }
            }
            .padding(.vertical, 8)
            .offset(x: shakeOffset)

            if let error = errorMessage {
                Text(error)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 24)
            }

            // 生体認証トグル（Face ID対応端末）
            if LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) {
                Toggle(isOn: $enableBiometrics) {
                    Label("Face ID / 生体認証を使用する", systemImage: "faceid")
                        .font(.subheadline)
                }
                .padding(.horizontal, 40)
                .padding(.top, 8)
            }

            Spacer()

            // テンキー
            PinKeypadView(passcode: currentPasscode, onBiometric: nil)
                .padding(.bottom, 24)
        }
    }

    private func verifyAndSave() {
        if firstPasscode == confirmPasscode {
            do {
                try vaultManager.setupPasscode(firstPasscode, confirmPasscode: confirmPasscode, enableBiometrics: enableBiometrics)
                onCompleted()
            } catch {
                errorMessage = error.localizedDescription
                shake()
            }
        } else {
            errorMessage = "パスコードが一致しません。最初からやり直してください。"
            shake()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                firstPasscode = ""
                confirmPasscode = ""
                step = .enterFirst
                errorMessage = nil
            }
        }
    }

    private func shake() {
        withAnimation(.default) { shakeOffset = -10 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.default) { shakeOffset = 10 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            withAnimation(.default) { shakeOffset = 0 }
        }
    }
}

// MARK: - ロック解除画面

private struct VaultUnlockView: View {
    let onUnlocked: () -> Void
    let onCancel: () -> Void

    @ObservedObject private var vaultManager = VaultManager.shared
    @State private var passcode = ""
    @State private var errorMessage: String?
    @State private var shakeOffset: CGFloat = 0

    var body: some View {
        VStack(spacing: 24) {
            HStack {
                Button("キャンセル", action: onCancel)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            Spacer()

            // アイコン
            ZStack {
                Circle()
                    .fill(Color.indigo.opacity(0.12))
                    .frame(width: 88, height: 88)
                Image(systemName: "lock.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.indigo)
            }

            VStack(spacing: 8) {
                Text("Private Vault")
                    .font(.title2.weight(.bold))

                if vaultManager.remainingLockoutSeconds > 0 {
                    let minutes = (vaultManager.remainingLockoutSeconds + 59) / 60
                    Text("試行回数の上限に達しました。\nあと \(minutes) 分後に再試行できます。")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                } else {
                    Text("パスコードを入力してロックを解除")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            // PINドット表示
            HStack(spacing: 16) {
                ForEach(0..<6, id: \.self) { index in
                    Circle()
                        .fill(index < passcode.count ? Color.indigo : Color(.systemGray4))
                        .frame(width: 14, height: 14)
                }
            }
            .padding(.vertical, 8)
            .offset(x: shakeOffset)

            if let error = errorMessage {
                Text(error)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 24)
            }

            Spacer()

            // テンキー
            PinKeypadView(
                passcode: Binding(
                    get: { passcode },
                    set: { val in
                        passcode = val
                        if val.count == 6 {
                            attemptUnlock()
                        }
                    }
                ),
                onBiometric: vaultManager.isBiometricsEnabled ? {
                    attemptBiometricUnlock()
                } : nil
            )
            .disabled(vaultManager.remainingLockoutSeconds > 0)
            .opacity(vaultManager.remainingLockoutSeconds > 0 ? 0.4 : 1.0)
            .padding(.bottom, 24)
        }
        .onAppear {
            if vaultManager.isBiometricsEnabled && vaultManager.remainingLockoutSeconds == 0 {
                attemptBiometricUnlock()
            }
        }
    }

    private func attemptUnlock() {
        do {
            try vaultManager.unlock(with: passcode)
            onUnlocked()
        } catch {
            errorMessage = error.localizedDescription
            shake()
            passcode = ""
        }
    }

    private func attemptBiometricUnlock() {
        Task {
            do {
                try await vaultManager.unlockWithBiometrics()
                onUnlocked()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func shake() {
        withAnimation(.default) { shakeOffset = -10 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.default) { shakeOffset = 10 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            withAnimation(.default) { shakeOffset = 0 }
        }
    }
}

// MARK: - テンキーコンポーネント

private struct PinKeypadView: View {
    @Binding var passcode: String
    let onBiometric: (() -> Void)?

    private let buttonSize: CGFloat = 68

    var body: some View {
        VStack(spacing: 14) {
            ForEach(0..<3) { row in
                HStack(spacing: 24) {
                    ForEach(1...3, id: \.self) { col in
                        let num = row * 3 + col
                        digitButton(title: "\(num)")
                    }
                }
            }

            HStack(spacing: 24) {
                // 左下: 生体認証または空白
                if let onBiometric = onBiometric {
                    Button(action: onBiometric) {
                        Image(systemName: "faceid")
                            .font(.system(size: 26))
                            .foregroundStyle(.indigo)
                            .frame(width: buttonSize, height: buttonSize)
                    }
                } else {
                    Spacer().frame(width: buttonSize, height: buttonSize)
                }

                // 中央: 0
                digitButton(title: "0")

                // 右下: 削除ボタン
                Button {
                    if !passcode.isEmpty {
                        passcode.removeLast()
                    }
                } label: {
                    Image(systemName: "delete.left")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: buttonSize, height: buttonSize)
                }
            }
        }
    }

    private func digitButton(title: String) -> some View {
        Button {
            if passcode.count < 6 {
                passcode.append(title)
            }
        } label: {
            Text(title)
                .font(.system(size: 28, weight: .regular, design: .rounded))
                .foregroundStyle(.primary)
                .frame(width: buttonSize, height: buttonSize)
                .background(Color(.systemGray6), in: Circle())
        }
    }
}

// MARK: - パスコード変更シート

struct VaultChangePasscodeView: View {
    let onCompleted: () -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var vaultManager = VaultManager.shared

    @State private var currentPasscode = ""
    @State private var newPasscode = ""
    @State private var confirmPasscode = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("現在のパスコード") {
                    SecureField("現在のパスコード（6桁）", text: $currentPasscode)
                        .keyboardType(.numberPad)
                }

                Section("新しいパスコード") {
                    SecureField("新しいパスコード（6桁）", text: $newPasscode)
                        .keyboardType(.numberPad)
                    SecureField("確認のため再入力", text: $confirmPasscode)
                        .keyboardType(.numberPad)
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("パスコード変更")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("変更") {
                        applyChange()
                    }
                    .disabled(currentPasscode.count < 6 || newPasscode.count < 6 || confirmPasscode.count < 6)
                }
            }
        }
    }

    private func applyChange() {
        do {
            try vaultManager.changePasscode(
                currentPasscode: currentPasscode,
                newPasscode: newPasscode,
                confirmNewPasscode: confirmPasscode
            )
            onCompleted()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Vault用動画インポートピッカー

struct VaultImportPickerView: View {
    @ObservedObject var downloads: DownloadCenter
    @ObservedObject var folderManager: VideoFolderManager
    let onImport: ([SavedVideo]) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var selectedIDs = Set<UUID>()

    private var availableVideos: [SavedVideo] {
        downloads.saved.filter { $0.format.isVideo && !$0.isHLS }
    }

    var body: some View {
        NavigationStack {
            Group {
                if availableVideos.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "film")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("取り込める動画がありません")
                            .font(.headline)
                        Text("通常保存領域に動画がないか、すべての動画がHLS形式または画像ファイルです。\n※ 現在HLS形式および画像ファイルのVault暗号化は非対応です。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Section {
                            ForEach(availableVideos) { video in
                                Button {
                                    if selectedIDs.contains(video.id) {
                                        selectedIDs.remove(video.id)
                                    } else {
                                        selectedIDs.insert(video.id)
                                    }
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: selectedIDs.contains(video.id) ? "checkmark.circle.fill" : "circle")
                                            .font(.title3)
                                            .foregroundStyle(selectedIDs.contains(video.id) ? Color.indigo : Color.secondary)

                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(video.title)
                                                .font(.subheadline.weight(.medium))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                            HStack(spacing: 6) {
                                                Text(video.format.label)
                                                    .font(.caption2.weight(.semibold))
                                                if let size = video.byteSize {
                                                    Text("· \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
                                                        .font(.caption2)
                                                }
                                                let folder = folderManager.folderName(for: video)
                                                if !folder.isEmpty {
                                                    Text("· \(folder)")
                                                        .font(.caption2)
                                                }
                                            }
                                            .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        } footer: {
                            Text("取り込んだ動画はAES-256暗号化され、元の通常ファイル一覧からは安全に削除されます。")
                                .font(.caption2)
                        }
                    }
                }
            }
            .navigationTitle("動画を取り込む")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("取り込む (\(selectedIDs.count))") {
                        let chosen = availableVideos.filter { selectedIDs.contains($0.id) }
                        onImport(chosen)
                        dismiss()
                    }
                    .disabled(selectedIDs.isEmpty)
                }
            }
        }
    }
}
