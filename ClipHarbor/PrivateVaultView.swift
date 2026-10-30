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

    // フォルダ管理ステート
    @State private var currentFolder: VaultFolder? = nil
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var renamingFolder: VaultFolder? = nil
    @State private var renameFolderInput = ""
    @State private var deletingFolder: VaultFolder? = nil
    @State private var movingItem: VaultItem? = nil
    @State private var showBatchMoveSheet = false

    var body: some View {
        NavigationStack {
            ZStack {
                if !vaultManager.isInitialized {
                    // 1. 初回セットアップ画面
                    VaultPasscodeSetupView(
                        onCompleted: {
                            showToast(NSLocalizedString("Private Vault configured", comment: ""))
                        },
                        onCancel: {
                            dismiss()
                        }
                    )
                } else if !vaultManager.isUnlocked {
                    // 2. ロック解除画面
                    VaultUnlockView(
                        onUnlocked: {
                            showToast(NSLocalizedString("Vault unlocked", comment: ""))
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
            .navigationTitle(vaultManager.isUnlocked ? (currentFolder?.name ?? "Private Vault") : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if vaultManager.isUnlocked {
                    ToolbarItem(placement: .topBarLeading) {
                        if currentFolder != nil {
                            Button {
                                withAnimation {
                                    currentFolder = nil
                                    isSelectionMode = false
                                    selectedItemIDs.removeAll()
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "chevron.left")
                                        .font(.system(size: 14, weight: .semibold))
                                    Text("Private Vault")
                                }
                            }
                        } else {
                            Button("Close") {
                                vaultManager.lock()
                                dismiss()
                            }
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
                                Button(isSelectionMode ? NSLocalizedString("Done", comment: "") : NSLocalizedString("Select", comment: "")) {
                                    withAnimation {
                                        isSelectionMode.toggle()
                                        if !isSelectionMode {
                                            selectedItemIDs.removeAll()
                                        }
                                    }
                                }
                            }

                            Menu {
                                if currentFolder == nil {
                                    Button {
                                        newFolderName = ""
                                        showNewFolderAlert = true
                                    } label: {
                                        Label(NSLocalizedString("New Folder", comment: ""), systemImage: "folder.badge.plus")
                                    }
                                } else if let folder = currentFolder {
                                    Button {
                                        renameFolderInput = folder.name
                                        renamingFolder = folder
                                    } label: {
                                        Label(NSLocalizedString("Rename Folder", comment: ""), systemImage: "pencil")
                                    }

                                    Button(role: .destructive) {
                                        deletingFolder = folder
                                    } label: {
                                        Label(NSLocalizedString("Delete Folder", comment: ""), systemImage: "trash")
                                    }
                                }

                                Divider()

                                Button {
                                    showVaultSettings = true
                                } label: {
                                    Label("Vault Settings", systemImage: "gearshape")
                                }

                                Divider()

                                Button(role: .destructive) {
                                    vaultManager.lock()
                                    dismiss()
                                } label: {
                                    Label("Lock and Close Now", systemImage: "lock.fill")
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
                    showToast(NSLocalizedString("Passcode changed", comment: ""))
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
            .sheet(item: $movingItem) { item in
                MoveToVaultFolderSheet(
                    currentFolderID: item.folderID,
                    folders: vaultManager.folders,
                    onSelectFolder: { targetFolderID in
                        try vaultManager.moveItem(id: item.id, to: targetFolderID)
                        showToast(NSLocalizedString("File moved", comment: ""))
                    },
                    onCreateNewFolderAndMove: { folderName in
                        let newFolder = try vaultManager.createFolder(name: folderName)
                        try vaultManager.moveItem(id: item.id, to: newFolder.id)
                        showToast(NSLocalizedString("File moved", comment: ""))
                    }
                )
            }
            .sheet(isPresented: $showBatchMoveSheet) {
                MoveToVaultFolderSheet(
                    currentFolderID: currentFolder?.id,
                    folders: vaultManager.folders,
                    onSelectFolder: { targetFolderID in
                        try vaultManager.moveItems(ids: selectedItemIDs, to: targetFolderID)
                        showToast(NSLocalizedString("File moved", comment: ""))
                        withAnimation {
                            isSelectionMode = false
                            selectedItemIDs.removeAll()
                        }
                    },
                    onCreateNewFolderAndMove: { folderName in
                        let newFolder = try vaultManager.createFolder(name: folderName)
                        try vaultManager.moveItems(ids: selectedItemIDs, to: newFolder.id)
                        showToast(NSLocalizedString("File moved", comment: ""))
                        withAnimation {
                            isSelectionMode = false
                            selectedItemIDs.removeAll()
                        }
                    }
                )
            }
            .alert(NSLocalizedString("New Folder", comment: ""), isPresented: $showNewFolderAlert) {
                TextField(NSLocalizedString("Folder Name", comment: ""), text: $newFolderName)
                Button(NSLocalizedString("Create", comment: "")) {
                    createVaultFolder(name: newFolderName)
                }
                Button(NSLocalizedString("Cancel", comment: ""), role: .cancel) {}
            }
            .alert(NSLocalizedString("Rename Folder", comment: ""), isPresented: Binding(
                get: { renamingFolder != nil },
                set: { if !$0 { renamingFolder = nil } }
            )) {
                TextField(NSLocalizedString("Folder Name", comment: ""), text: $renameFolderInput)
                Button(NSLocalizedString("Rename", comment: "")) {
                    if let folder = renamingFolder {
                        renameVaultFolder(folder: folder, newName: renameFolderInput)
                    }
                }
                Button(NSLocalizedString("Cancel", comment: ""), role: .cancel) {}
            }
            .alert(
                String(format: NSLocalizedString("Are you sure you want to delete folder \"%@\"?\nVideos inside will not be deleted and will return to Uncategorized.", comment: ""), deletingFolder?.name ?? ""),
                isPresented: Binding(
                    get: { deletingFolder != nil },
                    set: { if !$0 { deletingFolder = nil } }
                )
            ) {
                Button(NSLocalizedString("Delete Folder", comment: ""), role: .destructive) {
                    if let folder = deletingFolder {
                        deleteVaultFolder(folder: folder)
                    }
                }
                Button(NSLocalizedString("Cancel", comment: ""), role: .cancel) {}
            }
            .alert(NSLocalizedString("Delete Permanently", comment: ""), isPresented: Binding(
                get: { deletingItem != nil },
                set: { if !$0 { deletingItem = nil } }
            )) {
                Button("Cancel", role: .cancel) { deletingItem = nil }
                Button(NSLocalizedString("Delete Permanently", comment: ""), role: .destructive) {
                    if let item = deletingItem {
                        performDelete(item)
                    }
                }
            } message: {
                Text(String(format: NSLocalizedString("Are you sure you want to permanently delete \"%@\" from this device?\nEncrypted data cannot be recovered.", comment: ""), deletingItem?.originalTitle ?? ""))
            }
            .alert(NSLocalizedString("Delete Selected Items", comment: ""), isPresented: $showBatchDeleteAlert) {
                Button("Cancel", role: .cancel) { }
                Button(NSLocalizedString("Delete Permanently", comment: ""), role: .destructive) {
                    performBatchDelete()
                }
            } message: {
                Text(String(format: NSLocalizedString("Are you sure you want to permanently delete %lld selected videos?\nThis action cannot be undone.", comment: ""), selectedItemIDs.count))
            }
            .alert(NSLocalizedString("Error", comment: ""), isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .onChange(of: vaultManager.isUnlocked) { isUnlocked in
                if !isUnlocked {
                    resetVaultUIState()
                }
            }
            .onDisappear {
                resetVaultUIState()
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
                    Text("Private Vault Protected")
                        .font(.headline)
                }
            }
            .transition(.opacity)
            .zIndex(99)
        }
    }

    @ViewBuilder
    private func vaultPlayerCover(for item: VaultItem) -> some View {
        let playlistItems = vaultManager.items(in: currentFolder?.id)
        return PrivateVaultPlayerSheet(
            vaultItems: playlistItems.isEmpty ? vaultManager.items : playlistItems,
            initialItem: item,
            sessionToken: vaultManager.sessionToken
        ) {
            activePlaybackURL = nil
            vaultManager.cleanupPlaybackTemp(itemID: item.id)
            activePlayingItem = nil
        }
    }

    // MARK: - アンロック後コンテンツ一覧

    private let gridColumns = [
        GridItem(.flexible(), spacing: 14, alignment: .top),
        GridItem(.flexible(), spacing: 14, alignment: .top)
    ]

    private var vaultContentView: some View {
        let displayedItems = vaultManager.items(in: currentFolder?.id)
        let isRoot = currentFolder == nil
        let hasFolders = !vaultManager.folders.isEmpty
        let hasItems = !displayedItems.isEmpty

        return ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                if let warning = vaultManager.folderMetadataWarning {
                    folderWarningBanner(warning)
                }

                if isRoot && !hasFolders && !hasItems {
                    emptyVaultPlaceholder
                } else if !isRoot && !hasItems {
                    emptyFolderPlaceholder
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            securityInfoBanner

                            LazyVGrid(columns: gridColumns, spacing: 18) {
                                // ルート画面: フォルダカード一覧を表示
                                if isRoot {
                                    ForEach(vaultManager.folders) { folder in
                                        vaultFolderCard(folder: folder)
                                    }
                                }

                                // 動画カード一覧を表示（ルートなら未分類、フォルダ内ならそのフォルダ内の動画）
                                ForEach(displayedItems) { item in
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
                                        onMove: {
                                            movingItem = item
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
            }

            // 選択モード時の下部フローティングバー
            if isSelectionMode {
                selectionBottomBar(displayedItems: displayedItems)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - フォルダカードコンポーネント

    private func vaultFolderCard(folder: VaultFolder) -> some View {
        let itemsInFolder = vaultManager.items(in: folder.id)
        return VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                // カード本体タップでフォルダ内へ遷移
                Button {
                    withAnimation {
                        currentFolder = folder
                        isSelectionMode = false
                        selectedItemIDs.removeAll()
                    }
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.indigo.opacity(0.12))
                        Image(systemName: "folder.fill")
                            .font(.system(size: 42))
                            .foregroundStyle(Color.indigo)
                    }
                    .frame(height: 140)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)

                // 右上「…」メニュー
                if !isSelectionMode {
                    Menu {
                        Button {
                            withAnimation {
                                currentFolder = folder
                                isSelectionMode = false
                                selectedItemIDs.removeAll()
                            }
                        } label: {
                            Label("Open", systemImage: "folder")
                        }

                        Button {
                            renameFolderInput = folder.name
                            renamingFolder = folder
                        } label: {
                            Label(NSLocalizedString("Rename Folder", comment: ""), systemImage: "pencil")
                        }

                        Divider()

                        Button(role: .destructive) {
                            deletingFolder = folder
                        } label: {
                            Label(NSLocalizedString("Delete Folder", comment: ""), systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.indigo)
                            .frame(width: 28, height: 28)
                            .background(Color.white.opacity(0.92), in: Circle())
                            .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
                            .padding(8)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(height: 140)

            // フォルダ名・件数
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(String.localizedStringWithFormat(NSLocalizedString("%lld items", comment: ""), itemsInFolder.count))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
        }
    }

    private var emptyFolderPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder")
                .font(.system(size: 52))
                .foregroundStyle(Color.indigo)
            Text(NSLocalizedString("Folder is Empty", comment: ""))
                .font(.headline)
            Text("When you move videos to Vault from the \"…\" menu in the file list, they are encrypted with AES-256 and securely stored here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - セキュリティ情報バナー

    private var securityInfoBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .font(.caption)
                .foregroundStyle(.indigo)

            Text("Protected with AES-256-GCM encryption. Inaccessible from iOS file sharing and external apps.")
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

    private func folderWarningBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)

            Text(message)
                .font(.caption2)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    // MARK: - プレースホルダー（保管庫が空の場合）

    private var emptyVaultPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 52))
                .foregroundStyle(.indigo)
            Text("Private Vault is Empty")
                .font(.headline)
            Text("When you move videos to Vault from the \"…\" menu in the file list, they are encrypted with AES-256 and securely stored here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 選択モード用フローティング操作バー

    private func selectionBottomBar(displayedItems: [VaultItem]) -> some View {
        let displayedIDs = Set(displayedItems.map { $0.id })
        let isAllSelected = !displayedItems.isEmpty && displayedIDs.isSubset(of: selectedItemIDs)

        return HStack(spacing: 12) {
            // 全選択 / 選択解除ボタン
            Button {
                if isAllSelected {
                    selectedItemIDs.removeAll()
                } else {
                    selectedItemIDs = displayedIDs
                }
            } label: {
                Text(isAllSelected ? NSLocalizedString("Deselect All", comment: "") : NSLocalizedString("Select All", comment: ""))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(.secondarySystemBackground), in: Capsule())
            }
            .disabled(displayedItems.isEmpty)

            Spacer()

            // 選択件数
            Text(String(format: NSLocalizedString("%lld selected", comment: ""), selectedItemIDs.count))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            Spacer()

            // 一括操作ボタン群
            HStack(spacing: 8) {
                // 一括フォルダ移動
                Button {
                    showBatchMoveSheet = true
                } label: {
                    Image(systemName: "folder")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(selectedItemIDs.isEmpty ? Color.secondary : Color.primary)
                        .frame(width: 34, height: 34)
                        .background(Color(.secondarySystemBackground), in: Circle())
                }
                .disabled(selectedItemIDs.isEmpty)
                .accessibilityLabel(NSLocalizedString("Move to Folder", comment: ""))

                // 一括通常一覧へ復元
                Button {
                    performBatchRestore()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(selectedItemIDs.isEmpty ? Color.secondary : Color.indigo)
                        .frame(width: 34, height: 34)
                        .background(selectedItemIDs.isEmpty ? Color(.secondarySystemBackground) : Color.indigo.opacity(0.12), in: Circle())
                }
                .disabled(selectedItemIDs.isEmpty)
                .accessibilityLabel(NSLocalizedString("Restore to Normal List", comment: ""))

                // 一括完全削除
                Button(role: .destructive) {
                    showBatchDeleteAlert = true
                } label: {
                    Image(systemName: "trash")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(selectedItemIDs.isEmpty ? Color.secondary : Color.red)
                        .frame(width: 34, height: 34)
                        .background(selectedItemIDs.isEmpty ? Color(.secondarySystemBackground) : Color.red.opacity(0.12), in: Circle())
                }
                .disabled(selectedItemIDs.isEmpty)
                .accessibilityLabel(NSLocalizedString("Delete", comment: ""))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: Color.black.opacity(0.15), radius: 10, y: 4)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    // MARK: - 操作ロジック

    private func playItem(_ item: VaultItem) {
        do {
            let tempURL = try vaultManager.preparePlaybackURL(for: item)
            activePlaybackURL = tempURL
            activePlayingItem = item
        } catch {
            errorMessage = String(format: NSLocalizedString("Failed to prepare playback: %@", comment: ""), error.localizedDescription)
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
                showToast(String(format: NSLocalizedString("Restored \"%@\"", comment: ""), item.originalTitle))
            } catch {
                errorMessage = String(format: NSLocalizedString("Failed to restore: %@", comment: ""), error.localizedDescription)
            }
            isOperating = false
        }
    }

    private func performDelete(_ item: VaultItem) {
        do {
            try vaultManager.deletePermanently(item: item)
            showToast(NSLocalizedString("Permanently deleted", comment: ""))
        } catch {
            errorMessage = String(format: NSLocalizedString("Failed to delete: %@", comment: ""), error.localizedDescription)
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
            showToast(String(format: NSLocalizedString("Restored %lld videos", comment: ""), result.succeeded))
        }
    }

    private func performBatchDelete() {
        let targetItems = vaultManager.items.filter { selectedItemIDs.contains($0.id) }
        do {
            try vaultManager.deleteMultiplePermanently(items: targetItems)
            isSelectionMode = false
            selectedItemIDs.removeAll()
            showToast(String(format: NSLocalizedString("Permanently deleted %lld items", comment: ""), targetItems.count))
        } catch {
            errorMessage = String(format: NSLocalizedString("Batch deletion failed: %@", comment: ""), error.localizedDescription)
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
            showToast(String(format: NSLocalizedString("Imported %lld videos", comment: ""), succeeded))
        }
    }

    private func createVaultFolder(name: String) {
        do {
            _ = try vaultManager.createFolder(name: name)
            showToast(NSLocalizedString("Folder created", comment: ""))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func renameVaultFolder(folder: VaultFolder, newName: String) {
        do {
            try vaultManager.renameFolder(id: folder.id, newName: newName)
            if currentFolder?.id == folder.id {
                currentFolder = vaultManager.folder(for: folder.id)
            }
            showToast(NSLocalizedString("Title changed", comment: ""))
        } catch {
            errorMessage = error.localizedDescription
        }
        renamingFolder = nil
    }

    private func deleteVaultFolder(folder: VaultFolder) {
        do {
            if currentFolder?.id == folder.id {
                currentFolder = nil
            }
            try vaultManager.deleteFolder(id: folder.id)
            showToast(NSLocalizedString("Deleted", comment: ""))
        } catch {
            errorMessage = error.localizedDescription
        }
        deletingFolder = nil
    }

    private func showToast(_ message: String) {
        noticeMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            withAnimation(.easeInOut(duration: 0.2)) {
                noticeMessage = nil
            }
        }
    }

    /// ロック時および画面非表示時のUI状態完全クリア
    /// - 閲覧中フォルダをルート(nil)に戻し、再解錠時に必ずルート画面を表示
    /// - 選択状態、動画ID、フォルダ操作用文字列・参照をクリアし、復号済みフォルダ名をメモリ上に残さない
    private func resetVaultUIState() {
        currentFolder = nil
        isSelectionMode = false
        selectedItemIDs.removeAll()
        newFolderName = ""
        showNewFolderAlert = false
        renamingFolder = nil
        renameFolderInput = ""
        deletingFolder = nil
        movingItem = nil
        showBatchMoveSheet = false
        showBatchDeleteAlert = false
        deletingItem = nil
        activePlayingItem = nil
        activePlaybackURL = nil
        showImportSheet = false
        showVaultSettings = false
        showChangePasscode = false
    }
}

// MARK: - Aloha風Vault動画カード

private struct AlohaVaultCardView: View {
    let item: VaultItem
    let isSelectionMode: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let onPlay: () -> Void
    let onMove: () -> Void
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
                            Label("Play", systemImage: "play.fill")
                        }

                        Button(action: onMove) {
                            Label(NSLocalizedString("Move to Folder", comment: ""), systemImage: "folder")
                        }

                        Button(action: onRestore) {
                            Label("Restore to Files", systemImage: "arrow.uturn.backward")
                        }

                        Divider()

                        Button(role: .destructive, action: onDelete) {
                            Label(NSLocalizedString("Delete Permanently", comment: ""), systemImage: "trash")
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
                            Text("Encrypted")
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

                Text(String(format: NSLocalizedString("Stored: %@", comment: ""), item.vaultAddedAt.formatted(date: .numeric, time: .omitted)))
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
                    Button("Close") {
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
                Button(NSLocalizedString("Cancel", comment: ""), action: onCancel)
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
                Text(step == .enterFirst ? NSLocalizedString("Create Private Vault", comment: "") : NSLocalizedString("Confirm Passcode", comment: ""))
                    .font(.title2.weight(.bold))
                Text(step == .enterFirst ? NSLocalizedString("Set a 6-digit passcode for your Vault", comment: "") : NSLocalizedString("Re-enter your passcode to confirm", comment: ""))
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
                    Label(NSLocalizedString("Use Face ID / Biometrics", comment: ""), systemImage: "faceid")
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
            errorMessage = NSLocalizedString("Passcodes do not match. Please try again from the beginning.", comment: "")
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
    @State private var isAuthenticatingBiometrics = false

    var body: some View {
        VStack(spacing: 24) {
            HStack {
                Button(NSLocalizedString("Cancel", comment: ""), action: onCancel)
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
                    let minutes = max(1, (vaultManager.remainingLockoutSeconds + 59) / 60)
                    Text(String.localizedStringWithFormat(
                        NSLocalizedString("vault_unlock_lockout_warning %lld", comment: ""),
                        Int64(minutes)
                    ))
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                } else {
                    Text(NSLocalizedString("Enter passcode to unlock", comment: ""))
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
                onBiometric: (vaultManager.isBiometricsEnabled && !isAuthenticatingBiometrics) ? {
                    attemptBiometricUnlock()
                } : nil
            )
            .disabled(vaultManager.remainingLockoutSeconds > 0 || isAuthenticatingBiometrics)
            .opacity(vaultManager.remainingLockoutSeconds > 0 ? 0.4 : 1.0)
            .padding(.bottom, 24)
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
        guard !isAuthenticatingBiometrics else { return }
        guard vaultManager.remainingLockoutSeconds == 0 else { return }
        isAuthenticatingBiometrics = true
        errorMessage = nil

        Task { @MainActor in
            defer {
                isAuthenticatingBiometrics = false
            }
            do {
                try await vaultManager.unlockWithBiometrics()
                onUnlocked()
            } catch let vaultErr as VaultError {
                let desc = vaultErr.localizedDescription
                if desc.localizedCaseInsensitiveContains("cancel") || desc.contains("キャンセル") {
                    // キャンセル時はエラーメッセージを表示せずロック解除画面に留まる
                    errorMessage = nil
                } else {
                    errorMessage = desc
                }
            } catch {
                let desc = error.localizedDescription
                if desc.localizedCaseInsensitiveContains("cancel") || desc.contains("キャンセル") {
                    errorMessage = nil
                } else {
                    errorMessage = desc
                }
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
                    .accessibilityLabel(NSLocalizedString("Unlock with Face ID", comment: ""))
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
                .accessibilityLabel(NSLocalizedString("Delete", comment: ""))
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
        .accessibilityLabel(title)
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
                Section(NSLocalizedString("Current Passcode", comment: "")) {
                    SecureField(NSLocalizedString("Current Passcode (6 digits)", comment: ""), text: $currentPasscode)
                        .keyboardType(.numberPad)
                }

                Section(NSLocalizedString("New Passcode", comment: "")) {
                    SecureField(NSLocalizedString("New Passcode (6 digits)", comment: ""), text: $newPasscode)
                        .keyboardType(.numberPad)
                    SecureField(NSLocalizedString("Re-enter to confirm", comment: ""), text: $confirmPasscode)
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
            .navigationTitle(NSLocalizedString("Change Passcode", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(NSLocalizedString("Cancel", comment: "")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(NSLocalizedString("Change", comment: "")) {
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
                        Text("No Videos Available to Import")
                            .font(.headline)
                        Text("There are no videos in normal storage, or all videos are HLS format or images.\n*Vault encryption for HLS format and images is currently not supported.")
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
                            Text("Imported videos are encrypted with AES-256 and safely removed from the normal file list.")
                                .font(.caption2)
                        }
                    }
                }
            }
            .navigationTitle(Text("Import Videos"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(String(format: NSLocalizedString("Import (%lld)", comment: ""), selectedIDs.count)) {
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

/// Private Vault用の全画面メディアプレイヤーシート
/// - @StateObject でプレイリストコンテキストを保持し、再描画時のリセットを防止
private struct PrivateVaultPlayerSheet: View {
    @StateObject private var playlistContext: PlaybackPlaylistContext
    let onDismiss: () -> Void

    init(vaultItems: [VaultItem], initialItem: VaultItem, sessionToken: UUID, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        _playlistContext = StateObject(wrappedValue: PlaybackPlaylistContext(
            vaultItems: vaultItems,
            initialItem: initialItem,
            sessionToken: sessionToken
        ))
    }

    var body: some View {
        ModernVideoPlayerView(playlistContext: playlistContext) {
            onDismiss()
        }
    }
}

// MARK: - Vaultフォルダ移動シート

struct MoveToVaultFolderSheet: View {
    let currentFolderID: UUID?
    let folders: [VaultFolder]
    let onSelectFolder: (UUID?) throws -> Void
    let onCreateNewFolderAndMove: (String) throws -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        do {
                            try onSelectFolder(nil)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    } label: {
                        HStack {
                            Label(NSLocalizedString("Uncategorized", comment: ""), systemImage: "tray")
                                .foregroundStyle(.primary)
                            Spacer()
                            if currentFolderID == nil {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.indigo)
                            }
                        }
                    }
                }

                if !folders.isEmpty {
                    Section(header: Text(NSLocalizedString("Folders", comment: ""))) {
                        ForEach(folders) { folder in
                            Button {
                                do {
                                    try onSelectFolder(folder.id)
                                    dismiss()
                                } catch {
                                    errorMessage = error.localizedDescription
                                }
                            } label: {
                                HStack {
                                    Label(folder.name, systemImage: "folder")
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if currentFolderID == folder.id {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.indigo)
                                    }
                                }
                            }
                        }
                    }
                }

                Section {
                    Button {
                        newFolderName = ""
                        showNewFolderAlert = true
                    } label: {
                        Label(NSLocalizedString("New Folder", comment: ""), systemImage: "folder.badge.plus")
                            .foregroundStyle(Color.indigo)
                    }
                }
            }
            .navigationTitle(NSLocalizedString("Move to Folder", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(NSLocalizedString("Cancel", comment: "")) {
                        dismiss()
                    }
                }
            }
            .alert(NSLocalizedString("New Folder", comment: ""), isPresented: $showNewFolderAlert) {
                TextField(NSLocalizedString("Folder Name", comment: ""), text: $newFolderName)
                Button(NSLocalizedString("Create", comment: "")) {
                    let clean = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clean.isEmpty {
                        do {
                            try onCreateNewFolderAndMove(clean)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
                Button(NSLocalizedString("Cancel", comment: ""), role: .cancel) {}
            }
            .alert(NSLocalizedString("Error", comment: ""), isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .presentationDetents([.medium, .large])
    }
}
