import SwiftUI
import AVKit
import PhotosUI
import UniformTypeIdentifiers

/// Aloha Browser風のモダンなファイル・動画管理画面
/// - 2カラムのカードグリッドUI（左右上端厳格整列・タイトル2行固定高）
/// - 動画入りフォルダのモザイクプレビュー表示（中央トリミング・枠内厳格フィット）
/// - アプリ内ゴミ箱機能（72時間保持・自動完全削除・復元・空にする操作）
/// - サムネイル・動画時間の非同期取得・NSCacheメモリ管理
/// - フローティング操作バー（検索・並び替え・新規フォルダ作成・ゴミ箱・追加）
/// - カードタップと「…」メニューのジェスチャー完全分離（誤再生・誤遷移防止）
/// - 既存のダウンロード・fMP4変換・オフライン再生・移動・リネーム・削除処理を完全保護
struct FileManagerView: View {
    @ObservedObject var downloads: DownloadCenter
    @ObservedObject var folderManager: VideoFolderManager
    var onOpenSourcePage: ((URL) -> Void)? = nil
    @ObservedObject private var exports = VideoExportManager.shared
    @ObservedObject private var trashManager = TrashManager.shared
    @ObservedObject private var vaultManager = VaultManager.shared
    @ObservedObject private var settingsManager = AppSettingsManager.shared
    @ObservedObject private var zipManager = ZipArchiveManager.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    // ナビゲーション管理
    @State private var navigationPath: [VideoFolderManager.FolderFilter] = []

    // 検索・並び替え
    @State private var searchText = ""
    @State private var sortOption: SortOption = .dateDescending

    // 再生・移動対象
    @State private var playingVideo: SavedVideo?
    @State private var movingVideo: SavedVideo?
    @State private var showTrashSheet = false
    @State private var showSettingsSheet = false
    @State private var showPrivateVaultSheet = false
    @State private var pendingVaultVideos: [SavedVideo] = []

    // 複数選択モード
    @State private var isSelecting = false
    @State private var selectedVideoIDs: Set<UUID> = []
    @State private var selectedManagedFileIDs: Set<UUID> = []

    private var totalSelectedCount: Int {
        selectedVideoIDs.count + selectedManagedFileIDs.count
    }

    private var currentActiveFolderName: String {
        if let last = navigationPath.last, case .folder(let name) = last {
            return name
        }
        return ""
    }
    @State private var showBatchMoveSheet = false
    @State private var showBatchDeleteAlert = false

    // フォルダ操作用ダイアログ
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var renamingFolder: String?
    @State private var renameFolderInput = ""
    @State private var deletingFolder: String?

    // 削除対象の統合管理（動画・一般ファイルの共通ダイアログ用）
    enum DeletionTarget: Identifiable, Equatable {
        case video(SavedVideo)
        case managedFile(ManagedFileItem)

        var id: UUID {
            switch self {
            case .video(let v): return v.id
            case .managedFile(let m): return m.id
            }
        }

        var title: String {
            switch self {
            case .video(let v): return v.title
            case .managedFile(let m): return m.title
            }
        }

        var dialogTitle: String {
            switch self {
            case .video:
                return NSLocalizedString("Move Video to Trash", comment: "")
            case .managedFile:
                return NSLocalizedString("Move File to Trash", comment: "")
            }
        }

        @MainActor
        var dialogMessage: String {
            dialogMessage(retentionPeriod: AppSettingsManager.shared.trashRetentionPeriod)
        }

        func dialogMessage(retentionPeriod: TrashRetentionPeriod) -> String {
            retentionPeriod.itemDeletionMessage(title: title)
        }
    }

    @State private var itemPendingDeletion: DeletionTarget? = nil

    // 動画操作用ダイアログ
    @State private var renamingVideo: SavedVideo?
    @State private var renameVideoInput = ""

    // 一般ファイル操作用ダイアログ (Phase F2-A / F2-B)
    @State private var renamingManagedFile: ManagedFileItem?
    @State private var renameManagedFileInput = ""
    @State private var movingManagedFile: ManagedFileItem?
    @State private var editingTextDocument: ManagedFileItem?
    @State private var playingAudioItem: ManagedFileItem?

    // 画像インポート
    @State private var showPhotosPicker = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showFileImporter = false

    // エラー・通知
    @State private var errorMessage: String?
    @State private var copyNotice: String?

    // 進行中タスクの展開状態
    @State private var isJobsBannerExpanded = true

    // MARK: - ソート順列挙型

    enum SortOption: String, CaseIterable, Identifiable {
        case dateDescending = "dateDescending"
        case nameAscending = "nameAscending"
        case sizeDescending = "sizeDescending"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .dateDescending: return NSLocalizedString("Date (Newest)", comment: "")
            case .nameAscending: return NSLocalizedString("Name", comment: "")
            case .sizeDescending: return NSLocalizedString("Size (Largest)", comment: "")
            }
        }
    }

    // MARK: - デザインカラー

    private let alohaTeal = Color(red: 0.12, green: 0.68, blue: 0.78)
    private let alohaFolderBg = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.13, green: 0.23, blue: 0.27, alpha: 1.0)
            : UIColor(red: 0.88, green: 0.96, blue: 0.98, alpha: 1.0)
    })

    @ScaledMetric(relativeTo: .subheadline) private var folderTitleHeight: CGFloat = 20
    @ScaledMetric(relativeTo: .caption) private var folderSubtitleHeight: CGFloat = 16

    /// 左右のサムネイル上端を厳格に揃えるため alignment: .top を明示指定
    private let gridColumns = [
        GridItem(.flexible(), spacing: 14, alignment: .top),
        GridItem(.flexible(), spacing: 14, alignment: .top)
    ]

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 通常画面における Vault 入口・表示の可視性（ステルスモード・旧カード非表示設定を統合）
    private var vaultPolicy: VaultVisibilityPolicy {
        VaultVisibilityPolicy(
            isStealthModeEnabled: settingsManager.isStealthModeEnabled,
            hideVaultCardInFileList: settingsManager.hideVaultInFileList,
            isVaultInitialized: vaultManager.isInitialized
        )
    }

    private var rootScrollView: some View {
        ScrollView {
            VStack(spacing: 16) {
                if hasActiveJobs {
                    activeJobsBanner
                }

                if isSearching {
                    searchResultsSection
                } else {
                    rootFoldersAndVideosGrid
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 80)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private var activeBottomBar: some View {
        Group {
            if isSelecting {
                let currentVideos = searchText.isEmpty
                    ? folderManager.videos(in: .uncategorized)
                    : folderManager.videos(in: .all).filter { $0.title.localizedCaseInsensitiveContains(searchText) }
                let currentFiles = searchText.isEmpty
                    ? sortManagedFiles(zipManager.managedFiles(in: .uncategorized))
                    : sortManagedFiles(zipManager.managedFiles(in: .all).filter { $0.title.localizedCaseInsensitiveContains(searchText) })
                selectionBottomBar(currentVideos: currentVideos, currentFiles: currentFiles)
            } else {
                floatingBottomBar(isRoot: true)
            }
        }
    }

    private func setupNavigationBarAppearance() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = .systemBackground
        appearance.shadowColor = .separator
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
    }

    private var toastOverlay: some View {
        Group {
            if let notice = copyNotice {
                VStack {
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
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(10)
            }
        }
    }

    private var privacyShieldOverlay: some View {
        Group {
            if vaultManager.isPrivacyShieldActive {
                ZStack {
                    Color(.systemBackground)
                        .ignoresSafeArea()
                    VStack(spacing: 16) {
                        if vaultPolicy.showsVaultMentions {
                            Image(systemName: "lock.shield.fill")
                                .font(.system(size: 56))
                                .foregroundStyle(.indigo)
                            Text("Private Vault Protected")
                                .font(.headline)
                        } else {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 56))
                                .foregroundStyle(.secondary)
                            Text(verbatim: "ClipHarbor")
                                .font(.headline)
                        }
                    }
                }
                .transition(.opacity)
                .zIndex(99)
            }
        }
    }

    var body: some View {
        applyAlerts(to: applySheets(to: fileManagerRootNavigation))
    }

    private var fileManagerRootNavigation: some View {
        NavigationStack(path: $navigationPath) {
            ZStack(alignment: .bottom) {
                rootScrollView
                activeBottomBar
                toastOverlay
                privacyShieldOverlay
            }
            .animation(.easeInOut(duration: 0.25), value: copyNotice)
            .navigationTitle(isSelecting ? String(format: NSLocalizedString("%lld selected", comment: ""), totalSelectedCount) : NSLocalizedString("Files", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                rootToolbarContent
            }
            .toolbarBackground(Color(.systemBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .confirmationDialog(
                itemPendingDeletion?.dialogTitle ?? "",
                isPresented: Binding(
                    get: { itemPendingDeletion != nil && navigationPath.isEmpty },
                    set: { if !$0 { itemPendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Move to Trash", role: .destructive) {
                    if let target = itemPendingDeletion {
                        executeDeletion(target)
                    }
                    itemPendingDeletion = nil
                }
                Button("Cancel", role: .cancel) {
                    itemPendingDeletion = nil
                }
            } message: {
                if let target = itemPendingDeletion {
                    Text(target.dialogMessage(retentionPeriod: settingsManager.trashRetentionPeriod))
                }
            }
            .navigationDestination(for: VideoFolderManager.FolderFilter.self) { filter in
                folderDetailView(for: filter)
            }
            .onAppear {
                setupNavigationBarAppearance()
                folderManager.syncWithFileSystemAndSavedVideos()
                trashManager.purgeExpiredItems()
                if let notice = zipManager.unresolvedRecoveryNotice {
                    errorMessage = notice
                }
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    folderManager.syncWithFileSystemAndSavedVideos()
                    if let notice = zipManager.unresolvedRecoveryNotice {
                        errorMessage = notice
                    }
                }
            }
            .fullScreenCover(item: $playingVideo) { video in
                let currentFilter = navigationPath.last ?? .all
                let baseVideos = folderManager.videos(in: currentFilter)
                let query = searchText.trimmingCharacters(in: .whitespaces)
                let matching = query.isEmpty ? baseVideos : baseVideos.filter { $0.title.localizedCaseInsensitiveContains(query) }
                let playlist = sortVideos(matching)
                OfflineVideoPlayerSheet(
                    video: video,
                    playlist: playlist,
                    folderTitle: folderTitle(for: currentFilter)
                )
            }
            .photosPicker(isPresented: $showPhotosPicker, selection: $selectedPhotoItems, matching: .images)
            .onChange(of: selectedPhotoItems) { newItems in
                if !newItems.isEmpty {
                    handleImportedPhotos(newItems)
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.image, .zip, .plainText, .text],
                allowsMultipleSelection: true
            ) { result in
                handleFileImport(result: result)
            }
            .onChange(of: vaultManager.isUnlocked) { isUnlocked in
                if isUnlocked && !pendingVaultVideos.isEmpty {
                    let toMove = pendingVaultVideos
                    pendingVaultVideos = []
                    // ステルス中は通常画面からの Vault 移動を実行しない（UI 非表示に加えた実行経路ガード）
                    guard vaultPolicy.allowsMoveToVaultFromNormalUI else { return }
                    Task {
                        let (succeeded, _) = await vaultManager.moveMultipleToVault(
                            videos: toMove,
                            downloads: downloads,
                            folderManager: folderManager
                        )
                        copyNotice = String(format: NSLocalizedString("Moved %lld videos to Private Vault", comment: ""), succeeded)
                    }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var rootToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            if isSelecting {
                Text(String(format: NSLocalizedString("%lld selected", comment: ""), totalSelectedCount))
                    .font(.headline)
            } else if navigationPath.isEmpty {
                Text("Files")
                    .font(.headline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .modifier(StealthTitleGestureModifier(gesture: settingsManager.stealthAccessGesture) {
                        showPrivateVaultSheet = true
                    })
                    .modifier(ConditionalNamedAccessibilityAction(
                        isEnabled: vaultPolicy.exposesNamedAccessibilityAction,
                        name: Text("Open Vault")
                    ) {
                        showPrivateVaultSheet = true
                    })
            }
        }

        ToolbarItem(placement: .topBarLeading) {
            if isSelecting {
                Button("Cancel") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isSelecting = false
                        selectedVideoIDs.removeAll()
                        selectedManagedFileIDs.removeAll()
                    }
                }
            } else {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 32, height: 32)
                        .background(Color(.secondarySystemBackground), in: Circle())
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if isSelecting {
                Button("Done") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isSelecting = false
                        selectedVideoIDs.removeAll()
                        selectedManagedFileIDs.removeAll()
                    }
                }
                .font(.body.weight(.semibold))
            } else {
                Menu {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isSelecting = true
                            selectedVideoIDs.removeAll()
                            selectedManagedFileIDs.removeAll()
                        }
                    } label: {
                        Label("Select", systemImage: "checkmark.circle")
                    }
                    .disabled(downloads.saved.isEmpty)

                    Button {
                        showSettingsSheet = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }

                    if vaultPolicy.showsVaultMenuEntry {
                        Button {
                            showPrivateVaultSheet = true
                        } label: {
                            Label("Private Vault", systemImage: "lock.shield")
                        }
                    }

                    Divider()

                    Button {
                        showTrashSheet = true
                    } label: {
                        Label(String(format: NSLocalizedString("Trash (%lld)", comment: ""), trashManager.items.count), systemImage: "trash")
                    }

                    Divider()

                    Button {
                        showPhotosPicker = true
                    } label: {
                        Label("Import Photos", systemImage: "photo.on.rectangle")
                    }
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("Import from Files", systemImage: "doc.badge.plus")
                    }
                    Button {
                        newFolderName = ""
                        showNewFolderAlert = true
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                    Button {
                        folderManager.syncWithFileSystemAndSavedVideos()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 32, height: 32)
                        .background(Color(.secondarySystemBackground), in: Circle())
                }
            }
        }
    }

    @ViewBuilder
    private func applySheets(to content: some View) -> some View {
        content
            .sheet(item: $movingVideo) { video in
                MoveToFolderSheet(
                    video: video,
                    currentFolder: folderManager.folderName(for: video),
                    folders: folderManager.folders,
                    onSelectFolder: { targetFolder in
                        if case .failure(let err) = folderManager.moveVideo(video, toFolder: targetFolder) {
                            errorMessage = err.localizedDescription
                        }
                    }
                )
            }
            .sheet(item: $movingManagedFile) { item in
                MoveManagedFileToFolderSheet(
                    item: item,
                    currentFolder: item.folderName ?? "",
                    folders: folderManager.folders,
                    onSelectFolder: { targetFolder in
                        do {
                            _ = try zipManager.moveManagedFile(item, toFolder: targetFolder, folderManager: folderManager)
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                )
            }
            .sheet(item: $editingTextDocument) { item in
                TextDocumentEditorSheet(item: item, zipManager: zipManager)
            }
            .sheet(item: $playingAudioItem) { item in
                AudioPlayerSheet(item: item, zipManager: zipManager)
            }
            .sheet(isPresented: $showTrashSheet) {
                TrashView(
                    trashManager: trashManager,
                    downloads: downloads,
                    folderManager: folderManager,
                    zipManager: zipManager
                )
            }
            .sheet(isPresented: $showSettingsSheet) {
                FileManagerSettingsView(
                    downloads: downloads,
                    folderManager: folderManager
                )
            }
            .sheet(isPresented: $showPrivateVaultSheet, onDismiss: {
                pendingVaultVideos = []
                VaultPresentationLifecycle.handleVaultScreenClosed(vaultManager: vaultManager)
            }) {
                PrivateVaultView(
                    downloads: downloads,
                    folderManager: folderManager
                )
            }
            .sheet(isPresented: $showBatchMoveSheet) {
                BatchMoveToFolderSheet(
                    count: totalSelectedCount,
                    folders: folderManager.folders,
                    onSelectFolder: { targetFolder in
                        handleBatchMoveToFolder(targetFolder: targetFolder)
                    }
                )
            }
    }

    @ViewBuilder
    private func applyAlerts(to content: some View) -> some View {
        content
            .alert(NSLocalizedString("Move Selected Items to Trash", comment: ""), isPresented: $showBatchDeleteAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Move to Trash", role: .destructive) {
                    handleBatchMoveToTrash(videos: downloads.saved)
                }
            } message: {
                Text(settingsManager.trashRetentionPeriod.batchDeletionMessage(count: totalSelectedCount))
            }
            .alert(NSLocalizedString("New Folder", comment: ""), isPresented: $showNewFolderAlert) {
                TextField("Folder Name", text: $newFolderName)
                Button("Cancel", role: .cancel) { }
                Button("Create") {
                    switch folderManager.createFolder(name: newFolderName) {
                    case .success(let created):
                        navigationPath.append(.folder(created))
                    case .failure(let err):
                        errorMessage = err.localizedDescription
                    }
                }
            } message: {
                Text("Create a new folder to organize videos.")
            }
            .alert(
                NSLocalizedString("Rename Folder", comment: ""),
                isPresented: Binding(
                    get: { renamingFolder != nil },
                    set: { if !$0 { renamingFolder = nil } }
                )
            ) {
                TextField("New Folder Name", text: $renameFolderInput)
                Button("Cancel", role: .cancel) { renamingFolder = nil }
                Button("Change") {
                    if let old = renamingFolder {
                        switch folderManager.renameFolder(from: old, to: renameFolderInput) {
                        case .success(let updated):
                            if let idx = navigationPath.firstIndex(of: .folder(old)) {
                                navigationPath[idx] = .folder(updated)
                            }
                        case .failure(let err):
                            errorMessage = err.localizedDescription
                        }
                    }
                    renamingFolder = nil
                }
            }
            .alert(
                NSLocalizedString("Delete Folder", comment: ""),
                isPresented: Binding(
                    get: { deletingFolder != nil },
                    set: { if !$0 { deletingFolder = nil } }
                )
            ) {
                Button("Cancel", role: .cancel) { deletingFolder = nil }
                Button(NSLocalizedString("Delete Folder", comment: ""), role: .destructive) {
                    if let target = deletingFolder {
                        switch folderManager.deleteFolder(name: target) {
                        case .success:
                            navigationPath.removeAll { $0 == .folder(target) }
                        case .failure(let err):
                            errorMessage = err.localizedDescription
                        }
                    }
                    deletingFolder = nil
                }
            } message: {
                if let target = deletingFolder {
                    Text(String(format: NSLocalizedString("Are you sure you want to delete folder \"%@\"?\nVideos inside will not be deleted and will return to Uncategorized.", comment: ""), target))
                }
            }
            .alert(
                NSLocalizedString("Change Video Name", comment: ""),
                isPresented: Binding(
                    get: { renamingVideo != nil },
                    set: { if !$0 { renamingVideo = nil } }
                )
            ) {
                TextField("New Video Name", text: $renameVideoInput)
                Button("Cancel", role: .cancel) { renamingVideo = nil }
                Button("Change") {
                    if let target = renamingVideo {
                        VideoThumbnailManager.shared.invalidateCache(for: target)
                        if case .failure(let err) = folderManager.renameVideo(target, to: renameVideoInput) {
                            errorMessage = err.localizedDescription
                        }
                    }
                    renamingVideo = nil
                }
            }
            .alert(
                NSLocalizedString("Change File Name", comment: ""),
                isPresented: Binding(
                    get: { renamingManagedFile != nil },
                    set: { if !$0 { renamingManagedFile = nil } }
                )
            ) {
                TextField("New File Name", text: $renameManagedFileInput)
                Button("Cancel", role: .cancel) { renamingManagedFile = nil }
                Button("Change") {
                    if let target = renamingManagedFile {
                        do {
                            _ = try zipManager.renameManagedFile(target, to: renameManagedFileInput)
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    renamingManagedFile = nil
                }
            }
            .alert(
                NSLocalizedString("Could not perform operation", comment: ""),
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
    }

    // MARK: - ルート画面のフォルダ・動画グリッド

    private var rootFoldersAndVideosGrid: some View {
        let uncategorizedVideos = folderManager.videos(in: .uncategorized)
        let uncategorizedFiles = sortManagedFiles(zipManager.managedFiles(in: .uncategorized))
        let hasFolders = !folderManager.folders.isEmpty
        let hasUncategorized = !uncategorizedVideos.isEmpty || !uncategorizedFiles.isEmpty

        return Group {
            LazyVGrid(columns: gridColumns, spacing: 18) {
                // Private Vaultカード（非公開保管庫、隠しモード無効時のみ表示）
                if vaultPolicy.showsVaultCard {
                    privateVaultCard
                }

                // 未分類フォルダカード（未分類動画・ファイルがある、またはフォルダが作成されている場合に表示）
                if hasUncategorized || hasFolders {
                    folderCard(
                        title: NSLocalizedString("Uncategorized Videos", comment: ""),
                        itemCount: uncategorizedVideos.count + uncategorizedFiles.count,
                        videos: uncategorizedVideos,
                        filter: .uncategorized,
                        isCustomFolder: false
                    )
                }

                // ユーザー作成フォルダ群
                ForEach(folderManager.folders, id: \.self) { folderName in
                    let videosInFolder = folderManager.videos(in: .folder(folderName))
                    let filesInFolder = zipManager.managedFiles(in: .folder(folderName))
                    folderCard(
                        title: folderName,
                        itemCount: videosInFolder.count + filesInFolder.count,
                        videos: videosInFolder,
                        filter: .folder(folderName),
                        isCustomFolder: true
                    )
                }

                // ルート直下（Documents/Downloads）のZIP・一般ファイルカード表示
                ForEach(uncategorizedFiles) { fileItem in
                    AlohaManagedFileCardView(
                        item: fileItem,
                        isSelecting: isSelecting,
                        isSelected: selectedManagedFileIDs.contains(fileItem.id),
                        onToggleSelect: {
                            if selectedManagedFileIDs.contains(fileItem.id) {
                                selectedManagedFileIDs.remove(fileItem.id)
                            } else {
                                selectedManagedFileIDs.insert(fileItem.id)
                            }
                        },
                        isOperating: zipManager.activeOperation != nil,
                        onOpenText: {
                            editingTextDocument = fileItem
                        },
                        onOpenAudio: {
                            handleOpenAudio(fileItem)
                        },
                        onExtract: fileItem.isZip ? {
                            handleExtractZip(fileItem)
                        } : nil,
                        onCompress: !fileItem.isZip ? {
                            handleCompressManagedFile(fileItem)
                        } : nil,
                        onRename: {
                            renameManagedFileInput = fileItem.title
                            renamingManagedFile = fileItem
                        },
                        onMove: {
                            movingManagedFile = fileItem
                        },
                        onDelete: {
                            itemPendingDeletion = .managedFile(fileItem)
                        }
                    )
                }
            }

            if !hasFolders && !hasUncategorized && !hasActiveJobs {
                emptyFilesPlaceholder
            }
        }
    }

    // MARK: - Private Vault カード（ルート画面用・厳格整列）

    private var privateVaultCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Button {
                    showPrivateVaultSheet = true
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.indigo.opacity(0.18),
                                        Color.purple.opacity(0.12)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )

                        VStack(spacing: 8) {
                            ZStack {
                                Circle()
                                    .fill(Color.indigo.opacity(0.15))
                                    .frame(width: 52, height: 52)
                                Image(systemName: vaultManager.isUnlocked ? "lock.open.fill" : "lock.shield.fill")
                                    .font(.system(size: 26))
                                    .foregroundStyle(.indigo)
                            }

                            Text(vaultManager.isUnlocked ? NSLocalizedString("Unlocked", comment: "") : NSLocalizedString("Encrypted", comment: ""))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.indigo)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.indigo.opacity(0.12), in: Capsule())
                        }
                    }
                    .frame(height: 140)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)

                // 右上「…」メニュー
                Menu {
                    Button {
                        showPrivateVaultSheet = true
                    } label: {
                        Label("Open Vault", systemImage: "lock.shield")
                    }

                    if vaultManager.isUnlocked {
                        Button(role: .destructive) {
                            vaultManager.lock()
                        } label: {
                            Label("Lock Now", systemImage: "lock.fill")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.indigo)
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.92), in: Circle())
                        .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
                        .padding(8)
                }
                .buttonStyle(.plain)
            }
            .frame(height: 140)

            // タイトルとサブタイトル（Dynamic Type対応で高さを確保し、2段目の上端を厳格一致）
            Button {
                showPrivateVaultSheet = true
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("Private Vault")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.indigo)
                    }
                    .frame(height: folderTitleHeight, alignment: .leading)

                    Text(vaultManager.isUnlocked ? String(format: NSLocalizedString("%lld videos", comment: ""), vaultManager.items.count) : NSLocalizedString("Private Vault", comment: ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(height: folderSubtitleHeight, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - フォルダカードコンポーネント（タップ領域とメニューを独立化・上端整列）

    private func folderCard(
        title: String,
        itemCount: Int,
        videos: [SavedVideo],
        filter: VideoFolderManager.FolderFilter,
        isCustomFolder: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                // カード本体タップで遷移（frame先行で枠内に中央トリミング固定）
                Button {
                    navigationPath.append(filter)
                } label: {
                    if !videos.isEmpty {
                        FolderMosaicView(videos: videos)
                            .frame(height: 140)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(alohaFolderBg)
                            Image(systemName: "folder.fill")
                                .font(.system(size: 42))
                                .foregroundStyle(alohaTeal)
                        }
                        .frame(height: 140)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
                .buttonStyle(.plain)

                // 右上「…」メニューボタン（遷移ボタンの外側に独立配置し競合を防止）
                Menu {
                    Button {
                        navigationPath.append(filter)
                    } label: {
                        Label("Open", systemImage: "folder")
                    }

                    if isCustomFolder {
                        Button {
                            renameFolderInput = title
                            renamingFolder = title
                        } label: {
                            Label(NSLocalizedString("Rename Folder", comment: ""), systemImage: "pencil")
                        }

                        Button {
                            handleCompressFolder(named: title)
                        } label: {
                            Label(NSLocalizedString("Compress (Create ZIP)", comment: ""), systemImage: "doc.zipper")
                        }
                        .disabled(zipManager.activeOperation != nil)

                        Divider()

                        Button(role: .destructive) {
                            deletingFolder = title
                        } label: {
                            Label(NSLocalizedString("Delete Folder", comment: ""), systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(alohaTeal)
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.92), in: Circle())
                        .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
                        .padding(8)
                }
                .buttonStyle(.plain)
            }
            .frame(height: 140)

            // フォルダタイトルとアイテム数（Dynamic Type対応で高さを確保し、2段目の上端を厳格一致）
            Button {
                navigationPath.append(filter)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .frame(height: folderTitleHeight, alignment: .topLeading)
                    Text(String(format: NSLocalizedString("%lld items", comment: ""), itemCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(height: folderSubtitleHeight, alignment: .leading)
                }
                .padding(.horizontal, 4)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - フォルダ内動画詳細ビュー（確認ダイアログを直結し確実に表示）

    private func folderDetailView(for filter: VideoFolderManager.FolderFilter) -> some View {
        let videos = sortVideos(folderManager.videos(in: filter))
        let filteredVideos = searchText.trimmingCharacters(in: .whitespaces).isEmpty
            ? videos
            : videos.filter { $0.title.localizedCaseInsensitiveContains(searchText) }

        let managedFiles = sortManagedFiles(zipManager.managedFiles(in: filter))
        let filteredManagedFiles = searchText.trimmingCharacters(in: .whitespaces).isEmpty
            ? managedFiles
            : managedFiles.filter {
                $0.title.localizedCaseInsensitiveContains(searchText)
                    || ($0.displaySubfolderPrefix?.localizedCaseInsensitiveContains(searchText) ?? false)
            }

        return ZStack(alignment: .bottom) {
            ScrollView {
                VStack(spacing: 16) {
                    if filteredVideos.isEmpty && filteredManagedFiles.isEmpty {
                        emptyFolderPlaceholder(isSearch: !searchText.isEmpty)
                    } else {
                        LazyVGrid(columns: gridColumns, spacing: 18) {
                            ForEach(filteredVideos) { video in
                                AlohaVideoCardView(
                                    video: video,
                                    isSelecting: isSelecting,
                                    isSelected: selectedVideoIDs.contains(video.id),
                                    onToggleSelect: {
                                        if selectedVideoIDs.contains(video.id) {
                                            selectedVideoIDs.remove(video.id)
                                        } else {
                                            selectedVideoIDs.insert(video.id)
                                        }
                                    },
                                    onPlay: { playingVideo = video },
                                    onRename: {
                                        renameVideoInput = video.title
                                        renamingVideo = video
                                    },
                                    onMove: { movingVideo = video },
                                    onMoveToVault: vaultPolicy.allowsMoveToVaultFromNormalUI ? {
                                        handleMoveToVault(video: video)
                                    } : nil,
                                    onCompress: !video.isHLS ? {
                                        handleCompressVideo(video)
                                    } : nil,
                                    onDelete: {
                                        itemPendingDeletion = .video(video)
                                    },
                                    onOpenSourcePage: { url in
                                        onOpenSourcePage?(url)
                                        dismiss()
                                    },
                                    onCopySourcePageURL: copySourcePageURL
                                )
                            }

                            ForEach(filteredManagedFiles) { fileItem in
                                AlohaManagedFileCardView(
                                    item: fileItem,
                                    isSelecting: isSelecting,
                                    isSelected: selectedManagedFileIDs.contains(fileItem.id),
                                    onToggleSelect: {
                                        if selectedManagedFileIDs.contains(fileItem.id) {
                                            selectedManagedFileIDs.remove(fileItem.id)
                                        } else {
                                            selectedManagedFileIDs.insert(fileItem.id)
                                        }
                                    },
                                    isOperating: zipManager.activeOperation != nil,
                                    onOpenText: {
                                        editingTextDocument = fileItem
                                    },
                                    onOpenAudio: {
                                        handleOpenAudio(fileItem)
                                    },
                                    onExtract: fileItem.isZip ? {
                                        handleExtractZip(fileItem)
                                    } : nil,
                                    onCompress: !fileItem.isZip ? {
                                        handleCompressManagedFile(fileItem)
                                    } : nil,
                                    onRename: {
                                        renameManagedFileInput = fileItem.title
                                        renamingManagedFile = fileItem
                                    },
                                    onMove: {
                                        movingManagedFile = fileItem
                                    },
                                    onDelete: {
                                        itemPendingDeletion = .managedFile(fileItem)
                                    }
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 80)
            }
            .scrollDismissesKeyboard(.immediately)

            // フォルダ内フローティング操作バー（選択モード切替対応）
            if isSelecting {
                selectionBottomBar(currentVideos: filteredVideos, currentFiles: filteredManagedFiles)
            } else {
                floatingBottomBar(isRoot: false)
            }
        }
        .navigationTitle(isSelecting ? String(format: NSLocalizedString("%lld selected", comment: ""), totalSelectedCount) : filter.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isSelecting {
                    Button("Done") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isSelecting = false
                            selectedVideoIDs.removeAll()
                            selectedManagedFileIDs.removeAll()
                        }
                    }
                    .font(.body.weight(.semibold))
                } else {
                    Menu {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isSelecting = true
                                selectedVideoIDs.removeAll()
                                selectedManagedFileIDs.removeAll()
                            }
                        } label: {
                            Label("Select", systemImage: "checkmark.circle")
                        }
                        .disabled(filteredVideos.isEmpty)

                        Button {
                            showSettingsSheet = true
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }

                        Divider()

                        Button {
                            showTrashSheet = true
                        } label: {
                            Label(String(format: NSLocalizedString("Trash (%lld)", comment: ""), trashManager.items.count), systemImage: "trash")
                        }

                        if case .folder(let folderName) = filter {
                            Divider()
                            Button {
                                renameFolderInput = folderName
                                renamingFolder = folderName
                            } label: {
                                Label(NSLocalizedString("Rename Folder", comment: ""), systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                deletingFolder = folderName
                            } label: {
                                Label(NSLocalizedString("Delete Folder", comment: ""), systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 32, height: 32)
                            .background(Color(.secondarySystemBackground), in: Circle())
                    }
                }
            }
        }
        .toolbarBackground(Color(.systemBackground), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        // 遷移先画面自身に共通削除確認ダイアログを接続（動画・一般ファイル双方対応）
        .confirmationDialog(
            itemPendingDeletion?.dialogTitle ?? "",
            isPresented: Binding(
                get: { itemPendingDeletion != nil && !navigationPath.isEmpty },
                set: { if !$0 { itemPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let target = itemPendingDeletion {
                    executeDeletion(target)
                }
                itemPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                itemPendingDeletion = nil
            }
        } message: {
            if let target = itemPendingDeletion {
                Text(target.dialogMessage(retentionPeriod: settingsManager.trashRetentionPeriod))
            }
        }
    }

    // MARK: - 全体検索結果セクション

    private var searchResultsSection: some View {
        let allVideos = folderManager.videos(in: .all)
        let matchedVideos = sortVideos(allVideos.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
        })
        let allManaged = zipManager.managedFiles(in: .all)
        let matchedManaged = sortManagedFiles(allManaged.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || ($0.displaySubfolderPrefix?.localizedCaseInsensitiveContains(searchText) ?? false)
        })
        let matchedFolders = folderManager.folders.filter {
            $0.localizedCaseInsensitiveContains(searchText)
        }

        return VStack(alignment: .leading, spacing: 16) {
            if matchedFolders.isEmpty && matchedVideos.isEmpty && matchedManaged.isEmpty {
                emptyFolderPlaceholder(isSearch: true)
            } else {
                if !matchedFolders.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Matching Folders")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: gridColumns, spacing: 14) {
                            ForEach(matchedFolders, id: \.self) { folderName in
                                let vids = folderManager.videos(in: .folder(folderName))
                                let files = zipManager.managedFiles(in: .folder(folderName))
                                folderCard(
                                    title: folderName,
                                    itemCount: vids.count + files.count,
                                    videos: vids,
                                    filter: .folder(folderName),
                                    isCustomFolder: true
                                )
                            }
                        }
                    }
                }

                if !matchedVideos.isEmpty || !matchedManaged.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(format: NSLocalizedString("Matching Videos (%lld)", comment: ""), matchedVideos.count + matchedManaged.count))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: gridColumns, spacing: 14) {
                            ForEach(matchedVideos) { video in
                                AlohaVideoCardView(
                                    video: video,
                                    isSelecting: isSelecting,
                                    isSelected: selectedVideoIDs.contains(video.id),
                                    onToggleSelect: {
                                        if selectedVideoIDs.contains(video.id) {
                                            selectedVideoIDs.remove(video.id)
                                        } else {
                                            selectedVideoIDs.insert(video.id)
                                        }
                                    },
                                    onPlay: { playingVideo = video },
                                    onRename: {
                                        renameVideoInput = video.title
                                        renamingVideo = video
                                    },
                                    onMove: { movingVideo = video },
                                    onMoveToVault: vaultPolicy.allowsMoveToVaultFromNormalUI ? {
                                        handleMoveToVault(video: video)
                                    } : nil,
                                    onCompress: !video.isHLS ? {
                                        handleCompressVideo(video)
                                    } : nil,
                                    onDelete: {
                                        itemPendingDeletion = .video(video)
                                    },
                                    onOpenSourcePage: { url in
                                        onOpenSourcePage?(url)
                                        dismiss()
                                    },
                                    onCopySourcePageURL: copySourcePageURL
                                )
                            }

                            ForEach(matchedManaged) { fileItem in
                                AlohaManagedFileCardView(
                                    item: fileItem,
                                    isSelecting: isSelecting,
                                    isSelected: selectedManagedFileIDs.contains(fileItem.id),
                                    onToggleSelect: {
                                        if selectedManagedFileIDs.contains(fileItem.id) {
                                            selectedManagedFileIDs.remove(fileItem.id)
                                        } else {
                                            selectedManagedFileIDs.insert(fileItem.id)
                                        }
                                    },
                                    isOperating: zipManager.activeOperation != nil,
                                    onOpenText: {
                                        editingTextDocument = fileItem
                                    },
                                    onOpenAudio: {
                                        handleOpenAudio(fileItem)
                                    },
                                    onExtract: fileItem.isZip ? {
                                        handleExtractZip(fileItem)
                                    } : nil,
                                    onCompress: !fileItem.isZip ? {
                                        handleCompressManagedFile(fileItem)
                                    } : nil,
                                    onRename: {
                                        renameManagedFileInput = fileItem.title
                                        renamingManagedFile = fileItem
                                    },
                                    onMove: {
                                        movingManagedFile = fileItem
                                    },
                                    onDelete: {
                                        itemPendingDeletion = .managedFile(fileItem)
                                    }
                                )
                            }
                        }
                    }
                }
            }
        }

    }

    // MARK: - フローティング操作バー

    private func floatingBottomBar(isRoot: Bool) -> some View {
        HStack(spacing: 12) {
            // 左側: 検索バー
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("Search", text: $searchText)
                    .font(.subheadline)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .shadow(color: Color.black.opacity(0.12), radius: 8, y: 3)

            // 右側: 並び替え・新規フォルダ・アクションボタン（選択・設定・ゴミ箱を排除し窮屈さを解消）
            HStack(spacing: 12) {
                // 並び替えメニュー
                Menu {
                    ForEach(SortOption.allCases) { opt in
                        Button {
                            sortOption = opt
                        } label: {
                            HStack {
                                Text(opt.title)
                                if sortOption == opt {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                }

                // 新規フォルダ作成ボタン
                Button {
                    newFolderName = ""
                    showNewFolderAlert = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                }

                // クイック追加(+)ボタン
                Menu {
                    Button {
                        showPhotosPicker = true
                    } label: {
                        Label("Import Photos", systemImage: "photo.on.rectangle")
                    }
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("Import from Files", systemImage: "doc.badge.plus")
                    }
                    Divider()
                    Button {
                        newFolderName = ""
                        showNewFolderAlert = true
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                    Button {
                        showTrashSheet = true
                    } label: {
                        Label(String(format: NSLocalizedString("Open Trash (%lld)", comment: ""), trashManager.items.count), systemImage: "trash")
                    }
                    Button {
                        showSettingsSheet = true
                    } label: {
                        Label("Open Settings", systemImage: "gearshape")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(alohaTeal, in: Circle())
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .shadow(color: Color.black.opacity(0.12), radius: 8, y: 3)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    // MARK: - 複数選択モード専用フローティングバー

    private func selectionBottomBar(currentVideos: [SavedVideo], currentFiles: [ManagedFileItem] = []) -> some View {
        let totalCount = totalSelectedCount
        let allCurrentCount = currentVideos.count + currentFiles.count
        let isAllSelected = (totalCount == allCurrentCount && allCurrentCount > 0)

        return HStack(spacing: 12) {
            // 全選択 / 選択解除ボタン
            Button {
                if isAllSelected {
                    selectedVideoIDs.removeAll()
                    selectedManagedFileIDs.removeAll()
                } else {
                    selectedVideoIDs = Set(currentVideos.map { $0.id })
                    selectedManagedFileIDs = Set(currentFiles.map { $0.id })
                }
            } label: {
                Text(isAllSelected ? NSLocalizedString("Deselect All", comment: "") : NSLocalizedString("Select All", comment: ""))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(.secondarySystemBackground), in: Capsule())
            }

            Spacer()

            // 選択件数
            Text(String(format: NSLocalizedString("%lld selected", comment: ""), totalCount))
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
                        .foregroundStyle(totalCount == 0 ? Color.secondary : Color.primary)
                        .frame(width: 34, height: 34)
                        .background(Color(.secondarySystemBackground), in: Circle())
                }
                .disabled(totalCount == 0)

                // 一括ZIP圧縮（Phase F2-D）
                Button {
                    handleBatchCompress()
                } label: {
                    Image(systemName: "doc.zipper")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(totalCount == 0 ? Color.secondary : Color.blue)
                        .frame(width: 34, height: 34)
                        .background(totalCount == 0 ? Color(.secondarySystemBackground) : Color.blue.opacity(0.12), in: Circle())
                }
                .disabled(totalCount == 0)

                // 一括Private Vault移動（ステルス中は非表示）
                if vaultPolicy.allowsMoveToVaultFromNormalUI {
                    Button {
                        handleBatchMoveToVault()
                    } label: {
                        Image(systemName: "lock.shield")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(selectedVideoIDs.isEmpty ? Color.secondary : Color.indigo)
                            .frame(width: 34, height: 34)
                            .background(selectedVideoIDs.isEmpty ? Color(.secondarySystemBackground) : Color.indigo.opacity(0.12), in: Circle())
                    }
                    .disabled(selectedVideoIDs.isEmpty)
                }

                // 一括ゴミ箱移動
                Button {
                    showBatchDeleteAlert = true
                } label: {
                    Image(systemName: "trash")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(totalCount == 0 ? Color.secondary : Color.red)
                        .frame(width: 34, height: 34)
                        .background(totalCount == 0 ? Color(.secondarySystemBackground) : Color.red.opacity(0.12), in: Circle())
                }
                .disabled(totalCount == 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: Color.black.opacity(0.15), radius: 10, y: 4)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    // MARK: - 一括操作処理

    private func handleBatchMoveToFolder(targetFolder: String) {
        let videoTargets = downloads.saved.filter { selectedVideoIDs.contains($0.id) }
        let fileTargets = zipManager.managedFiles.filter { selectedManagedFileIDs.contains($0.id) }
        guard !videoTargets.isEmpty || !fileTargets.isEmpty else { return }

        var successCount = 0
        for v in videoTargets {
            if case .success = folderManager.moveVideo(v, toFolder: targetFolder) {
                successCount += 1
            }
        }
        for f in fileTargets {
            if (try? zipManager.moveManagedFile(f, toFolder: targetFolder, folderManager: folderManager)) != nil {
                successCount += 1
            }
        }
        withAnimation {
            isSelecting = false
            selectedVideoIDs.removeAll()
            selectedManagedFileIDs.removeAll()
        }
        let destName = targetFolder.isEmpty ? NSLocalizedString("Downloads (Uncategorized)", comment: "") : "「\(targetFolder)」"
        showToast(String(format: NSLocalizedString("Moved %lld items to %@", comment: ""), successCount, destName))
    }

    private func handleBatchMoveToTrash(videos: [SavedVideo]) {
        let videoTargets = videos.filter { selectedVideoIDs.contains($0.id) }
        let fileTargets = zipManager.managedFiles.filter { selectedManagedFileIDs.contains($0.id) }
        guard !videoTargets.isEmpty || !fileTargets.isEmpty else { return }
        Task {
            var successCount = 0
            for v in videoTargets {
                let folder = folderManager.folderName(for: v)
                if case .success = await trashManager.moveToTrash(
                    video: v,
                    folderName: folder,
                    downloads: downloads,
                    folderManager: folderManager
                ) {
                    successCount += 1
                }
            }
            for f in fileTargets {
                if case .success = await trashManager.moveToTrash(
                    managedFile: f,
                    zipManager: zipManager
                ) {
                    successCount += 1
                }
            }
            await MainActor.run {
                withAnimation {
                    isSelecting = false
                    selectedVideoIDs.removeAll()
                    selectedManagedFileIDs.removeAll()
                }
                showToast(String(format: NSLocalizedString("Moved %lld items to Trash", comment: ""), successCount))
            }
        }
    }

    private func handleBatchCompress() {
        let videoTargets = downloads.saved.filter { selectedVideoIDs.contains($0.id) }
        let fileTargets = zipManager.managedFiles.filter { selectedManagedFileIDs.contains($0.id) }
        guard !videoTargets.isEmpty || !fileTargets.isEmpty else { return }

        Task {
            do {
let targetFolder = currentActiveFolderName

                let created = try await zipManager.compressMultipleItems(
                    videos: videoTargets,
                    managedFiles: fileTargets,
                    targetFolderName: targetFolder,
                    downloads: downloads,
                    folderManager: folderManager
                )
                await MainActor.run {
                    showToast(String(format: NSLocalizedString("Created \"%@.zip\"", comment: ""), created.title))
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isSelecting = false
                        selectedVideoIDs.removeAll()
                        selectedManagedFileIDs.removeAll()
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func handleMoveToVault(video: SavedVideo) {
        // ステルス中は通常画面からの Vault 移動を受け付けない（Vault 内部のインポートを使用）
        guard vaultPolicy.allowsMoveToVaultFromNormalUI else { return }
        if video.isHLS {
            errorMessage = VaultError.hlsNotSupportedYet.localizedDescription
            return
        }

        if !vaultManager.isUnlocked {
            pendingVaultVideos = [video]
            showPrivateVaultSheet = true
        } else {
            Task {
                do {
                    try await vaultManager.moveToVault(
                        video: video,
                        downloads: downloads,
                        folderManager: folderManager
                    )
                    showToast(String(format: NSLocalizedString("Moved \"%@\" to Private Vault", comment: ""), video.title))
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func handleBatchMoveToVault() {
        guard vaultPolicy.allowsMoveToVaultFromNormalUI else { return }
        let targets = downloads.saved.filter { selectedVideoIDs.contains($0.id) }
        guard !targets.isEmpty else { return }

        let validTargets = targets.filter { $0.format.isVideo && !$0.isHLS }
        if validTargets.isEmpty {
            errorMessage = NSLocalizedString("None of the selected items can be imported (HLS format and image files are not supported).", comment: "")
            return
        }

        if !vaultManager.isUnlocked {
            pendingVaultVideos = validTargets
            showPrivateVaultSheet = true
        } else {
            Task {
                let (succeeded, _) = await vaultManager.moveMultipleToVault(
                    videos: validTargets,
                    downloads: downloads,
                    folderManager: folderManager
                )
                await MainActor.run {
                    withAnimation {
                        isSelecting = false
                        selectedVideoIDs.removeAll()
                    }
                    showToast(String(format: NSLocalizedString("Moved %lld videos to Private Vault", comment: ""), succeeded))
                }
            }
        }
    }

    // MARK: - フォルダ名ヘルパー

    private func folderTitle(for filter: VideoFolderManager.FolderFilter) -> String {
        switch filter {
        case .all: return NSLocalizedString("All Files", comment: "")
        case .uncategorized: return NSLocalizedString("Uncategorized", comment: "")
        case .folder(let name): return name
        }
    }

    // MARK: - 画像インポート処理（最小構成: PhotosPicker / fileImporter）

    private func handleImportedPhotos(_ items: [PhotosPickerItem]) {
        Task {
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await importImageData(data, preferredName: "Photo")
                }
            }
            await MainActor.run {
                selectedPhotoItems.removeAll()
            }
        }
    }

    private func handleFileImport(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            let currentFilter = navigationPath.last ?? .all
            let targetFolderName: String
            if case .folder(let name) = currentFilter {
                targetFolderName = name
            } else {
                targetFolderName = ""
            }

            Task {
                for url in urls {
                    let hasScope = url.startAccessingSecurityScopedResource()
                    defer {
                        if hasScope {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }

                    let ext = url.pathExtension.lowercased()
                    let isText = ["txt", "text", "md", "markdown"].contains(ext)
                    if ext == "zip" || isText {
                        await MainActor.run {
                            do {
                                let imported = try zipManager.importExternalFile(
                                    from: url,
                                    targetFolderName: targetFolderName,
                                    downloads: downloads,
                                    folderManager: folderManager
                                )
                                showToast(String(format: NSLocalizedString("Imported \"%@\"", comment: ""), "\(imported.title).\(imported.fileExtension)"))
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    } else {
                        let data = try? Data(contentsOf: url)
                        let name = url.deletingPathExtension().lastPathComponent
                        if let d = data {
                            await importImageData(d, preferredName: name)
                        }
                    }
                }
            }
        case .failure(let err):
            errorMessage = String(format: NSLocalizedString("Failed to load file: %@", comment: ""), err.localizedDescription)
        }
    }

    private func importImageData(_ data: Data, preferredName: String) async {
        guard let _ = UIImage(data: data) else { return }

        // CGImageSourceおよびマジックバイト等でフォーマット判定
        var format: SavedVideo.Format = .jpeg
        var ext: String = "jpg"

        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let type = CGImageSourceGetType(source) as String? {
            let lower = type.lowercased()
            if lower.contains("png") {
                format = .png
                ext = "png"
            } else if lower.contains("gif") {
                format = .gif
                ext = "gif"
            } else if lower.contains("heic") || lower.contains("heif") {
                format = .heic
                ext = "heic"
            } else {
                format = .jpeg
                ext = "jpg"
            }
        } else if data.prefix(3) == Data([0xFF, 0xD8, 0xFF]) {
            format = .jpeg
            ext = "jpg"
        } else if data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) {
            format = .png
            ext = "png"
        } else if data.prefix(3) == Data([0x47, 0x49, 0x46]) {
            format = .gif
            ext = "gif"
        } else if data.count >= 12, data[4...7] == Data([0x66, 0x74, 0x79, 0x70]) {
            format = .heic
            ext = "heic"
        }

        do {
            let root = try VideoFolderManager.ensureDownloadsDirectory()
            let targetDir: URL
            let currentFilter = navigationPath.last ?? .all
            switch currentFilter {
            case .folder(let name):
                targetDir = try VideoFolderManager.ensureSubfolder(named: name)
            default:
                targetDir = root
            }

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            let timeStr = formatter.string(from: Date())
            let baseName = "\(FileNaming.sanitizedBaseName(preferredName))_\(timeStr)"
            let destURL = FileNaming.uniqueDestination(in: targetDir, baseName: baseName, fileExtension: ext)

            try data.write(to: destURL, options: .atomic)
            guard let rel = SavedVideo.relativePath(for: destURL) else { return }

            let savedItem = SavedVideo(
                id: UUID(),
                title: destURL.deletingPathExtension().lastPathComponent,
                relativePath: rel,
                format: format,
                sourceHost: nil,
                createdAt: Date(),
                byteSize: Int64(data.count),
                sourcePageURL: nil,
                isFavorite: false
            )

            await MainActor.run {
                downloads.addSaved(savedItem)
                if case .folder(let name) = currentFilter {
                    folderManager.setFolderName(name, for: savedItem)
                }
                showToast(String(format: NSLocalizedString("Imported \"%@\"", comment: ""), savedItem.title))
            }
        } catch {
            await MainActor.run {
                errorMessage = String(format: NSLocalizedString("Failed to save image: %@", comment: ""), error.localizedDescription)
            }
        }
    }

    // MARK: - 進行中ダウンロード・MP4変換バナー

    private var hasActiveJobs: Bool {
        !downloads.jobs.isEmpty || !exports.exportJobs.isEmpty || zipManager.activeOperation != nil
    }

    private var activeJobsBanner: some View {
        let zipCount = zipManager.activeOperation != nil ? 1 : 0
        let activeCount = downloads.jobs.filter { $0.state.isActive }.count + exports.exportJobs.filter { $0.state.isActive }.count + zipCount
        let totalCount = downloads.jobs.count + exports.exportJobs.count + zipCount

        return VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isJobsBannerExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: zipManager.activeOperation != nil ? "doc.zipper" : "arrow.down.circle.fill")
                        .foregroundStyle(.blue)
                        .font(.headline)
                    Text(String(format: NSLocalizedString("Download & Conversion Tasks (%@)", comment: ""), activeCount > 0 ? String(format: NSLocalizedString("%lld running / %lld total", comment: ""), activeCount, totalCount) : String(format: NSLocalizedString("%lld total", comment: ""), totalCount)))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: isJobsBannerExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if isJobsBannerExpanded {
                VStack(spacing: 12) {
                    if let zipOp = zipManager.activeOperation {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label(
                                    zipOp.kind == .extracting
                                        ? String(format: NSLocalizedString("Extracting \"%@\"...", comment: ""), zipOp.targetTitle)
                                        : String(format: NSLocalizedString("Compressing \"%@\"...", comment: ""), zipOp.targetTitle),
                                    systemImage: "doc.zipper"
                                )
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                                Spacer()
                                Button("Cancel", role: .destructive) {
                                    zipManager.cancelCurrentOperation()
                                }
                                .font(.caption)
                                .buttonStyle(.borderless)
                            }
                            ProgressView(value: zipOp.fractionCompleted)
                                .tint(alohaTeal)
                        }
                    }

                    ForEach(downloads.jobs) { job in
                        SimpleDownloadJobRow(
                            job: job,
                            onCancel: { downloads.cancel(job.id) },
                            onRetry: { downloads.retry(job.id) },
                            onDismiss: { downloads.dismissJob(job.id) }
                        )
                    }

                    ForEach(exports.exportJobs) { job in
                        FMP4ExportJobRow(
                            job: job,
                            onCancel: { exports.cancelExport(job.id) },
                            onDismiss: { exports.dismissExportJob(job.id) }
                        )
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - プレースホルダー表示

    private var emptyFilesPlaceholder: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 48))
                .foregroundStyle(alohaTeal)
            Text("No Files")
                .font(.headline)
            Text("When you play a video in the browser, you can download it from the save button at the bottom right.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func emptyFolderPlaceholder(isSearch: Bool) -> some View {
        VStack(spacing: 12) {
            Image(systemName: isSearch ? "magnifyingglass" : "square.and.arrow.down")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(isSearch ? "No Matching Files" : "No Videos")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - ソート処理

    private func sortVideos(_ list: [SavedVideo]) -> [SavedVideo] {
        switch sortOption {
        case .dateDescending:
            return list.sorted { $0.createdAt > $1.createdAt }
        case .nameAscending:
            return list.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .sizeDescending:
            return list.sorted { ($0.byteSize ?? 0) > ($1.byteSize ?? 0) }
        }
    }

    private func sortManagedFiles(_ list: [ManagedFileItem]) -> [ManagedFileItem] {
        switch sortOption {
        case .dateDescending:
            return list.sorted { $0.createdAt > $1.createdAt }
        case .nameAscending:
            return list.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .sizeDescending:
            return list.sorted { $0.byteSize > $1.byteSize }
        }
    }

    // MARK: - ZIP展開・圧縮ハンドラ（Phase F1）

    private func handleExtractZip(_ item: ManagedFileItem) {
        Task {
            do {
                let extractedFolder = try await zipManager.extractZip(
                    item: item,
                    downloads: downloads,
                    folderManager: folderManager
                )
                showToast(String(format: NSLocalizedString("Extracted to folder \"%@\"", comment: ""), extractedFolder))
            } catch ZipOperationError.cancelled {
                showToast(NSLocalizedString("ZIP operation was cancelled.", comment: ""))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func handleCompressVideo(_ video: SavedVideo) {
        Task {
            do {
                let created = try await zipManager.compressSingleVideo(
                    video,
                    downloads: downloads,
                    folderManager: folderManager
                )
                showToast(String(format: NSLocalizedString("Created \"%@.zip\"", comment: ""), created.title))
            } catch ZipOperationError.cancelled {
                showToast(NSLocalizedString("ZIP operation was cancelled.", comment: ""))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func handleCompressManagedFile(_ item: ManagedFileItem) {
        Task {
            do {
                let created = try await zipManager.compressSingleManagedFile(
                    item,
                    downloads: downloads,
                    folderManager: folderManager
                )
                showToast(String(format: NSLocalizedString("Created \"%@.zip\"", comment: ""), created.title))
            } catch ZipOperationError.cancelled {
                showToast(NSLocalizedString("ZIP operation was cancelled.", comment: ""))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func handleCompressFolder(named folderName: String) {
        Task {
            do {
                let created = try await zipManager.compressFolder(
                    named: folderName,
                    downloads: downloads,
                    folderManager: folderManager
                )
                showToast(String(format: NSLocalizedString("Created \"%@.zip\"", comment: ""), created.title))
            } catch ZipOperationError.cancelled {
                showToast(NSLocalizedString("ZIP operation was cancelled.", comment: ""))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - ゴミ箱移動とURLコピー通知

    private func handleOpenAudio(_ item: ManagedFileItem) {
        guard !isSelecting else { return }
        guard item.isAudioFile else { return }
        guard item.isSupportedAudio else {
            errorMessage = String(
                format: NSLocalizedString("Unsupported audio format: %@ is not supported.", comment: ""),
                item.fileExtension.uppercased()
            )
            return
        }
        let fileURL = zipManager.resolveFileURL(for: item)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            errorMessage = NSLocalizedString("Audio file not found.", comment: "")
            return
        }
        if FileClassification.isInsideVaultOrTempArea(fileURL) {
            errorMessage = NSLocalizedString("Cannot play files located in protected storage.", comment: "")
            return
        }
        playingAudioItem = item
    }

    private func executeDeletion(_ target: DeletionTarget) {
        switch target {
        case .video(let video):
            handleMoveToTrash(video: video)
        case .managedFile(let managedFile):
            handleMoveToTrash(managedFile: managedFile)
        }
    }

    private func handleMoveToTrash(video: SavedVideo) {
        let folder = folderManager.folderName(for: video)
        Task {
            let result = await trashManager.moveToTrash(
                video: video,
                folderName: folder,
                downloads: downloads,
                folderManager: folderManager
            )
            await MainActor.run {
                switch result {
                case .success:
                    showToast(String(format: NSLocalizedString("Moved \"%@\" to Trash", comment: ""), video.title))
                case .failure(let err):
                    errorMessage = String(format: NSLocalizedString("Failed to move to Trash: %@", comment: ""), err.localizedDescription)
                }
            }
        }
    }

    private func handleMoveToTrash(managedFile: ManagedFileItem) {
        Task {
            let result = await trashManager.moveToTrash(
                managedFile: managedFile,
                zipManager: zipManager
            )
            await MainActor.run {
                switch result {
                case .success:
                    showToast(String(format: NSLocalizedString("Moved \"%@\" to Trash", comment: ""), managedFile.title))
                case .failure(let err):
                    errorMessage = String(format: NSLocalizedString("Failed to move to Trash: %@", comment: ""), err.localizedDescription)
                }
            }
        }
    }

    private func showToast(_ msg: String) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.easeInOut(duration: 0.2)) {
            copyNotice = msg
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(.easeInOut(duration: 0.2)) {
                copyNotice = nil
            }
        }
    }

    private func copySourcePageURL(_ urlString: String) {
        UIPasteboard.general.string = urlString
        showToast(NSLocalizedString("Copied page URL", comment: ""))
    }
}

// MARK: - フォルダ内モザイクプレビュー表示（Aloha風の1〜3枚コラージュ・枠内厳格フィット）

private struct FolderMosaicView: View {
    let videos: [SavedVideo]

    var body: some View {
        GeometryReader { proxy in
            let w = max(1, proxy.size.width)
            let h = max(1, proxy.size.height)

            if videos.count == 1 {
                ClippedThumbnailTileView(video: videos[0], width: w, height: h)
            } else if videos.count == 2 {
                let leftW = max(1, (w - 2) / 2)
                let rightW = max(1, w - 2 - leftW)
                HStack(spacing: 2) {
                    ClippedThumbnailTileView(video: videos[0], width: leftW, height: h)
                    ClippedThumbnailTileView(video: videos[1], width: rightW, height: h)
                }
            } else {
                let leftW = max(1, (w - 2) / 2)
                let rightW = max(1, w - 2 - leftW)
                let topH = max(1, (h - 2) / 2)
                let bottomH = max(1, h - 2 - topH)

                HStack(spacing: 2) {
                    // 左側: 大きな代表サムネイル
                    ClippedThumbnailTileView(video: videos[0], width: leftW, height: h)

                    // 右側: 縦積み2枚
                    VStack(spacing: 2) {
                        ClippedThumbnailTileView(video: videos[1], width: rightW, height: topH)
                        ClippedThumbnailTileView(video: videos[2], width: rightW, height: bottomH)
                    }
                }
            }
        }
        .frame(height: 140)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Aloha風動画カード（再生タップ領域と「…」メニューを独立化・枠内厳格フィット・上端整列・複数選択対応）

private struct AlohaVideoCardView: View {
    let video: SavedVideo
    var isSelecting: Bool = false
    var isSelected: Bool = false
    var onToggleSelect: (() -> Void)? = nil
    let onPlay: () -> Void
    let onRename: () -> Void
    let onMove: () -> Void
    var onMoveToVault: (() -> Void)? = nil
    var onCompress: (() -> Void)? = nil
    let onDelete: () -> Void
    let onOpenSourcePage: (URL) -> Void
    let onCopySourcePageURL: (String) -> Void

    @ScaledMetric(relativeTo: .subheadline) private var titleLineHeight: CGFloat = 20
    @ScaledMetric(relativeTo: .caption2) private var subtitleHeight: CGFloat = 16

    private var validatedSourcePageURL: URL? {
        guard let raw = video.sourcePageURL,
              let rawURL = URL(string: raw),
              let sanitized = SourceURLPolicy.sanitize(rawURL),
              let url = URL(string: sanitized) else {
            return nil
        }
        return url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                // サムネイルタップ（選択モード時は選択トグル、通常時は再生）
                Button {
                    if isSelecting {
                        onToggleSelect?()
                    } else {
                        onPlay()
                    }
                } label: {
                    GeometryReader { geo in
                        let w = max(1, geo.size.width)
                        ClippedThumbnailTileView(
                            video: video,
                            width: w,
                            height: 140,
                            cornerRadius: 16
                        )
                    }
                    .frame(height: 140)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)

                // 選択モード中のチェックマーク（左上）
                if isSelecting {
                    HStack {
                        ZStack {
                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 24))
                                    .foregroundStyle(.blue)
                                    .background(Circle().fill(.white))
                            } else {
                                Circle()
                                    .strokeBorder(Color.white, lineWidth: 2)
                                    .background(Circle().fill(Color.black.opacity(0.35)))
                                    .frame(width: 24, height: 24)
                            }
                        }
                        .padding(8)
                        Spacer()
                    }
                }

                // 左下: お気に入り星バッジ（登録時のみ表示）
                if !isSelecting && video.isFavorite {
                    VStack {
                        Spacer()
                        HStack {
                            Image(systemName: "star.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.yellow)
                                .padding(5)
                                .background(Color.black.opacity(0.65), in: Circle())
                                .padding(6)
                            Spacer()
                        }
                    }
                    .frame(height: 140)
                    .allowsHitTesting(false)
                }

                // 右下: 再生時間バッジ（通常時のみ表示）
                if !isSelecting {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            VideoDurationBadge(video: video)
                        }
                    }
                    .frame(height: 140)
                    .allowsHitTesting(false)
                }

                // 右上: 「…」メニューボタン（通常時のみ表示し誤操作を防止）
                if !isSelecting {
                    Menu {
                        Button(action: onPlay) {
                            Label("Play", systemImage: "play.fill")
                        }

                        Button(action: onRename) {
                            Label("Rename", systemImage: "pencil")
                        }

                        Button(action: onMove) {
                            Label("Move to Folder", systemImage: "folder")
                        }

                        if let onMoveToVault = onMoveToVault {
                            Button(action: onMoveToVault) {
                                Label("Move to Private Vault", systemImage: "lock.shield")
                            }
                        }

                        if let onCompress = onCompress, !video.isHLS && video.fileExists {
                            Button(action: onCompress) {
                                Label("Compress (Create ZIP)", systemImage: "doc.zipper")
                            }
                        }

                        if !video.isHLS && video.fileExists {
                            ShareLink(item: video.fileURL) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                        }

                        if let validURL = validatedSourcePageURL {
                            Divider()
                            Button {
                                onOpenSourcePage(validURL)
                            } label: {
                                Label("Open Original Web Page", systemImage: "arrow.up.right.square")
                            }
                            Button {
                                onCopySourcePageURL(validURL.absoluteString)
                            } label: {
                                Label("Copy Page URL", systemImage: "doc.on.doc")
                            }
                        }

                        Divider()

                        Button(role: .destructive, action: onDelete) {
                            Label("Move to Trash", systemImage: "trash")
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
            }
            .frame(height: 140)

            // タイトルと詳細（Dynamic Type対応で2行分の高さを確保し、2段目以降の上端を左右で統一）
            Button {
                if isSelecting {
                    onToggleSelect?()
                } else {
                    onPlay()
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(video.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(height: titleLineHeight * 2, alignment: .topLeading)

                    HStack(spacing: 4) {
                        if let sub = video.displaySubfolderPrefix {
                            Image(systemName: "folder")
                                .font(.system(size: 9))
                            Text("\(sub) ·")
                                .font(.caption2)
                                .lineLimit(1)
                        }

                        Text(video.format.label)
                            .font(.caption2.weight(.semibold))

                        if let size = video.byteSize, size > 0 {
                            Text("· \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
                                .font(.caption2)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .frame(height: subtitleHeight, alignment: .leading)
                }
                .padding(.horizontal, 4)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Aloha風ZIP・一般ファイルカード（2列グリッド厳格整列・プレイヤー/サムネイル非接続）

private struct AlohaManagedFileCardView: View {
    let item: ManagedFileItem
    var isSelecting: Bool = false
    var isSelected: Bool = false
    var onToggleSelect: (() -> Void)? = nil
    var isOperating: Bool = false
    var onOpenText: (() -> Void)? = nil
    var onOpenAudio: (() -> Void)? = nil
    var onExtract: (() -> Void)? = nil
    var onCompress: (() -> Void)? = nil
    var onRename: (() -> Void)? = nil
    var onMove: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    @ScaledMetric(relativeTo: .subheadline) private var titleLineHeight: CGFloat = 20
    @ScaledMetric(relativeTo: .caption2) private var subtitleHeight: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                // ファイルタイル（選択モード時はタップで選択切り替え、非選択時は抽出/エディター起動）
                Group {
                    if isSelecting {
                        Button(action: { onToggleSelect?() }) {
                            tileVisual
                        }
                        .buttonStyle(.plain)
                    } else if let onExtract = onExtract, item.isZip {
                        Button(action: onExtract) {
                            tileVisual
                        }
                        .buttonStyle(.plain)
                        .disabled(isOperating)
                    } else if let onOpenText = onOpenText, item.isTextDocument {
                        Button(action: onOpenText) {
                            tileVisual
                        }
                        .buttonStyle(.plain)
                        .disabled(isOperating)
                    } else if let onOpenAudio = onOpenAudio, item.isAudioFile {
                        Button(action: onOpenAudio) {
                            tileVisual
                        }
                        .buttonStyle(.plain)
                        .disabled(isOperating)
                    } else {
                        tileVisual
                    }
                }

                // 選択インジケーター（左上）
                if isSelecting {
                    HStack {
                        ZStack {
                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 24))
                                    .foregroundStyle(.blue)
                                    .background(Circle().fill(.white))
                            } else {
                                Circle()
                                    .strokeBorder(Color.white, lineWidth: 2)
                                    .background(Circle().fill(Color.black.opacity(0.35)))
                                    .frame(width: 24, height: 24)
                            }
                        }
                        .padding(8)
                        Spacer()
                    }
                }

                // 右上「…」メニュー（Phase F1 / F2-A 対応済みの機能を表示）
                if !isSelecting {
                    Menu {
                    if item.isAudioFile, let onOpenAudio = onOpenAudio, item.fileExists {
                        Button(action: onOpenAudio) {
                            Label(NSLocalizedString("Play Audio", comment: ""), systemImage: "play.circle")
                        }
                        .disabled(isOperating)
                    }

                    if item.isTextDocument, let onOpenText = onOpenText, item.fileExists {
                        Button(action: onOpenText) {
                            Label("Edit Text", systemImage: "square.and.pencil")
                        }
                        .disabled(isOperating)
                    }

                    if item.isZip, let onExtract = onExtract {
                        Button(action: onExtract) {
                            Label("Extract Files", systemImage: "archivebox")
                        }
                        .disabled(isOperating)
                    }

                    if !item.isZip, let onCompress = onCompress, item.fileExists {
                        Button(action: onCompress) {
                            Label("Compress (Create ZIP)", systemImage: "doc.zipper")
                        }
                        .disabled(isOperating)
                    }

                    if let onRename = onRename, item.fileExists {
                        Button(action: onRename) {
                            Label("Change File Name", systemImage: "pencil")
                        }
                        .disabled(isOperating)
                    }

                    if let onMove = onMove, item.fileExists {
                        Button(action: onMove) {
                            Label("Move to Folder", systemImage: "folder")
                        }
                        .disabled(isOperating)
                    }

                    if item.fileExists {
                        ShareLink(item: item.fileURL) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }

                    if let onDelete = onDelete, item.fileExists {
                        Divider()
                        Button(role: .destructive, action: onDelete) {
                            Label("Delete", systemImage: "trash")
                        }
                        .disabled(isOperating)
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
            }
            .frame(height: 140)

            // タイトルと形式・サイズ（Dynamic Type 2行高予約・左右上端厳格一致）
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(height: titleLineHeight * 2, alignment: .topLeading)

                HStack(spacing: 4) {
                    if let sub = item.displaySubfolderPrefix {
                        Image(systemName: "folder")
                            .font(.system(size: 9))
                        Text("\(sub) ·")
                            .font(.caption2)
                            .lineLimit(1)
                    }

                    Text(item.formatLabel)
                        .font(.caption2.weight(.semibold))

                    if item.byteSize > 0 {
                        Text("· \(ByteCountFormatter.string(fromByteCount: item.byteSize, countStyle: .file))")
                            .font(.caption2)
                    }
                }
                .foregroundStyle(.secondary)
                .frame(height: subtitleHeight, alignment: .leading)
            }
            .padding(.horizontal, 4)
        }
    }

    private var tileVisual: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: item.isZip
                            ? [Color.orange.opacity(0.18), Color.amberAccent.opacity(0.10)]
                            : [Color.teal.opacity(0.16), Color.cyan.opacity(0.10)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill((item.isZip ? Color.orange : Color.teal).opacity(0.15))
                        .frame(width: 52, height: 52)
                    Image(systemName: item.sfSymbolName)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(item.isZip ? Color.orange : Color.teal)
                }

                Text(item.formatLabel)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(item.isZip ? Color.orange : Color.teal)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((item.isZip ? Color.orange : Color.teal).opacity(0.14), in: Capsule())
            }
        }
        .frame(height: 140)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private extension Color {
    static let amberAccent = Color(red: 0.95, green: 0.65, blue: 0.12)
}

// MARK: - 枠に合わせて中央トリミングし、はみ出しを確実に防止するサムネイルタイルコンポーネント

private struct ClippedThumbnailTileView: View {
    let video: SavedVideo
    let width: CGFloat
    let height: CGFloat
    var cornerRadius: CGFloat = 0

    @State private var image: UIImage? = nil

    var body: some View {
        ZStack {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: max(1, width), height: max(1, height))
                    .clipped()
            } else {
                fallbackPlaceholder
            }
        }
        .frame(width: max(1, width), height: max(1, height))
        .clipped()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: video.id) {
            if let cached = VideoThumbnailManager.shared.cachedThumbnail(for: video) {
                self.image = cached
                return
            }
            let loaded = await VideoThumbnailManager.shared.loadThumbnail(for: video)
            if let loaded = loaded {
                withAnimation(.easeIn(duration: 0.15)) {
                    self.image = loaded
                }
            }
        }
    }

    private var fallbackPlaceholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.22), Color(white: 0.14)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: 4) {
                Image(systemName: video.isHLS ? "film.stack" : "play.circle.fill")
                    .font(.system(size: min(width, height) > 80 ? 28 : 18))
                    .foregroundStyle(.white.opacity(0.7))
                if height > 55 && width > 55 {
                    Text(video.format.label)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.12), in: Capsule())
                }
            }
        }
        .frame(width: max(1, width), height: max(1, height))
        .clipped()
    }
}

// MARK: - 再生時間バッジ

private struct VideoDurationBadge: View {
    let video: SavedVideo
    @State private var durationText: String? = nil

    var body: some View {
        Group {
            if video.format.isVideo, let text = durationText {
                Text(text)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(Color.black.opacity(0.75), in: Capsule())
                    .padding(6)
            }
        }
        .task(id: video.id) {
            guard video.format.isVideo else { return }
            if let cached = VideoThumbnailManager.shared.formattedDuration(for: video) {
                self.durationText = cached
                return
            }
            if let seconds = await VideoThumbnailManager.shared.loadDuration(for: video) {
                self.durationText = VideoThumbnailManager.formatDuration(seconds)
            } else {
                self.durationText = NSLocalizedString("Unknown", comment: "")
            }
        }
    }
}

// MARK: - ダウンロード進捗行

private struct SimpleDownloadJobRow: View {
    let job: DownloadJob
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(job.displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer()
                if job.state.isActive {
                    Button("Cancel", role: .destructive, action: onCancel)
                        .font(.caption)
                        .buttonStyle(.borderless)
                } else {
                    HStack(spacing: 12) {
                        if job.canRetry {
                            Button("Retry", action: onRetry)
                                .font(.caption.weight(.semibold))
                                .buttonStyle(.borderless)
                        }
                        Button(action: onDismiss) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Dismiss from History"))
                    }
                }
            }

            switch job.state {
            case .preparing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(String(format: NSLocalizedString("Preparing… (%@)", comment: ""), job.host))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .downloading(let progress):
                if let p = progress {
                    ProgressView(value: p)
                } else {
                    ProgressView()
                }
                HStack {
                    Text(job.state.label)
                    Spacer()
                    if job.receivedBytes > 0 {
                        Text(byteProgressText)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            case .completed:
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            case .cancelled:
                Label("Cancelled", systemImage: "slash.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var byteProgressText: String {
        let received = ByteCountFormatter.string(fromByteCount: job.receivedBytes, countStyle: .file)
        if job.expectedBytes > 0 {
            let total = ByteCountFormatter.string(fromByteCount: job.expectedBytes, countStyle: .file)
            return "\(received) / \(total)"
        }
        return received
    }
}

// MARK: - fMP4 → MP4 変換テスト進捗行

private struct FMP4ExportJobRow: View {
    let job: VideoExportManager.ExportJob
    let onCancel: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(job.displayName).mp4")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer()
                if job.state.isActive {
                    Button("Cancel", role: .destructive, action: onCancel)
                        .font(.caption)
                        .buttonStyle(.borderless)
                } else {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Dismiss from History"))
                }
            }

            switch job.state {
            case .analyzingPlaylist, .remuxingToMP4, .verifyingMP4:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(job.state.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .downloadingSegments(_, _, _, let progress):
                ProgressView(value: progress)
                Text(job.state.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .completed(let summary):
                Label(job.state.label, systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                let sizeStr = ByteCountFormatter.string(fromByteCount: summary.byteSize, countStyle: .file)
                let audioStr = summary.audioCodec ?? NSLocalizedString("None (Video Only)", comment: "")
                let segStr = summary.isSeparateAudioMerged
                    ? String(format: NSLocalizedString("Video %lld + Audio %lld seg (Sync offset: %lldms)", comment: ""), summary.videoSegmentCount, summary.audioSegmentCount, summary.avSyncOffsetMs)
                    : "\(summary.videoSegmentCount)seg"
                Text(String(format: NSLocalizedString("Video: %@ / Audio: %@ · Preset: %@ · %@ · %@ · Frame checkpoints: %lld/3 passed", comment: ""), summary.videoCodec, audioStr, summary.exportPresetUsed, sizeStr, segStr, summary.decodedCheckpoints))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let aDur = summary.audioDurationSeconds {
                    Text(String(format: NSLocalizedString("Video length: %.1fs / Audio length: %.1fs · *Please verify AV sync at beginning, middle, and end on real device", comment: ""), summary.durationSeconds, aDur))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            case .failed(let reason):
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case .cancelled:
                Label("Cancelled", systemImage: "slash.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - フォルダ移動シート

struct MoveToFolderSheet: View {
    let video: SavedVideo
    let currentFolder: String
    let folders: [String]
    let onSelectFolder: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newFolderName = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Select Destination Folder") {
                    Button {
                        dismiss()
                        onSelectFolder("")
                    } label: {
                        HStack {
                            Label("Downloads (Uncategorized)", systemImage: "folder")
                            Spacer()
                            if currentFolder.isEmpty {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }

                    ForEach(folders, id: \.self) { folder in
                        Button {
                            dismiss()
                            onSelectFolder(folder)
                        } label: {
                            HStack {
                                Label(folder, systemImage: "folder.fill")
                                Spacer()
                                if currentFolder == folder {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                }

                Section("Create New Folder and Move") {
                    HStack {
                        TextField("New Folder Name", text: $newFolderName)
                        Button("Create and Move") {
                            let target = newFolderName
                            dismiss()
                            onSelectFolder(target)
                        }
                        .disabled(VideoFolderManager.sanitizedFolderName(newFolderName).isEmpty)
                    }
                }
            }
            .navigationTitle(Text("Move to Folder"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .toolbarBackground(Color(.systemBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - 一般ファイルフォルダ移動シート (Phase F2-A)

private struct MoveManagedFileToFolderSheet: View {
    let item: ManagedFileItem
    let currentFolder: String
    let folders: [String]
    let onSelectFolder: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newFolderName = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Select Destination Folder") {
                    Button {
                        dismiss()
                        onSelectFolder("")
                    } label: {
                        HStack {
                            Label("Downloads (Uncategorized)", systemImage: "folder")
                            Spacer()
                            if currentFolder.isEmpty {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }

                    ForEach(folders, id: \.self) { folder in
                        Button {
                            dismiss()
                            onSelectFolder(folder)
                        } label: {
                            HStack {
                                Label(folder, systemImage: "folder.fill")
                                Spacer()
                                if currentFolder == folder {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                }

                Section("Create New Folder and Move") {
                    HStack {
                        TextField("New Folder Name", text: $newFolderName)
                        Button("Create and Move") {
                            let target = newFolderName
                            dismiss()
                            onSelectFolder(target)
                        }
                        .disabled(VideoFolderManager.sanitizedFolderName(newFolderName).isEmpty)
                    }
                }
            }
            .navigationTitle(Text("Move to Folder"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .toolbarBackground(Color(.systemBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - 一括フォルダ移動シート

private struct BatchMoveToFolderSheet: View {
    let count: Int
    let folders: [String]
    let onSelectFolder: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newFolderName = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Select Destination Folder") {
                    Button {
                        dismiss()
                        onSelectFolder("")
                    } label: {
                        Label("Downloads (Uncategorized)", systemImage: "folder")
                    }

                    ForEach(folders, id: \.self) { folder in
                        Button {
                            dismiss()
                            onSelectFolder(folder)
                        } label: {
                            Label(folder, systemImage: "folder.fill")
                        }
                    }
                }

                Section("Create New Folder and Move") {
                    HStack {
                        TextField("New Folder Name", text: $newFolderName)
                        Button("Create and Move") {
                            let target = newFolderName
                            dismiss()
                            onSelectFolder(target)
                        }
                        .disabled(VideoFolderManager.sanitizedFolderName(newFolderName).isEmpty)
                    }
                }
            }
            .navigationTitle(String(format: NSLocalizedString("Move %lld Videos", comment: ""), count))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .toolbarBackground(Color(.systemBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .presentationDetents([.medium, .large])
    }
}
