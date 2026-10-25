import SwiftUI
import AVKit
import PhotosUI

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
    @State private var showBatchMoveSheet = false
    @State private var showBatchDeleteAlert = false

    // フォルダ操作用ダイアログ
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var renamingFolder: String?
    @State private var renameFolderInput = ""
    @State private var deletingFolder: String?

    // 動画操作用ダイアログ
    @State private var renamingVideo: SavedVideo?
    @State private var renameVideoInput = ""

    // 画像インポート
    @State private var showPhotosPicker = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showFileImporter = false
    @State private var deletingVideo: SavedVideo?

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
                selectionBottomBar(currentVideos: currentVideos)
            } else {
                floatingBottomBar(isRoot: true)
            }
        }
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
            .navigationTitle(isSelecting ? String(format: NSLocalizedString("%lld selected", comment: ""), selectedVideoIDs.count) : NSLocalizedString("Files", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                rootToolbarContent
            }
            .navigationDestination(for: VideoFolderManager.FolderFilter.self) { filter in
                folderDetailView(for: filter)
            }
            .onAppear {
                folderManager.syncWithFileSystemAndSavedVideos()
                trashManager.purgeExpiredItems()
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    folderManager.syncWithFileSystemAndSavedVideos()
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
                allowedContentTypes: [.image],
                allowsMultipleSelection: true
            ) { result in
                handleFileImport(result: result)
            }
            .onChange(of: vaultManager.isUnlocked) { isUnlocked in
                if isUnlocked && !pendingVaultVideos.isEmpty {
                    let toMove = pendingVaultVideos
                    pendingVaultVideos = []
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
                Text(String(format: NSLocalizedString("%lld selected", comment: ""), selectedVideoIDs.count))
                    .font(.headline)
            } else if navigationPath.isEmpty {
                Text("Files")
                    .font(.headline)
                    .contentShape(Rectangle())
                    .onLongPressGesture(minimumDuration: 2.0) {
                        let generator = UIImpactFeedbackGenerator(style: .medium)
                        generator.impactOccurred()
                        showPrivateVaultSheet = true
                    }
                    .accessibilityAction(named: Text("Open Vault")) {
                        showPrivateVaultSheet = true
                    }
            }
        }

        ToolbarItem(placement: .topBarLeading) {
            if isSelecting {
                Button("Cancel") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isSelecting = false
                        selectedVideoIDs.removeAll()
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
                    }
                }
                .font(.body.weight(.semibold))
            } else {
                Menu {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isSelecting = true
                            selectedVideoIDs.removeAll()
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

                    Button {
                        showPrivateVaultSheet = true
                    } label: {
                        Label("Private Vault", systemImage: "lock.shield")
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
                    Divider()
                    pocVerificationMenu
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
            .sheet(isPresented: $showTrashSheet) {
                TrashView(
                    trashManager: trashManager,
                    downloads: downloads,
                    folderManager: folderManager
                )
            }
            .sheet(isPresented: $showSettingsSheet) {
                FileManagerSettingsView(
                    downloads: downloads,
                    folderManager: folderManager
                )
            }
            .sheet(isPresented: $showPrivateVaultSheet) {
                PrivateVaultView(
                    downloads: downloads,
                    folderManager: folderManager
                )
            }
            .sheet(isPresented: $showBatchMoveSheet) {
                BatchMoveToFolderSheet(
                    count: selectedVideoIDs.count,
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
            .alert(NSLocalizedString("Move Selected Videos to Trash", comment: ""), isPresented: $showBatchDeleteAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Move to Trash", role: .destructive) {
                    handleBatchMoveToTrash(videos: downloads.saved)
                }
            } message: {
                Text(String(format: NSLocalizedString("Are you sure you want to move %lld selected videos to Trash?\n(Permanently deleted after 3 days)", comment: ""), selectedVideoIDs.count))
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
                        navigationPath.removeAll { $0 == .folder(target) }
                        folderManager.deleteFolder(name: target)
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
            .confirmationDialog(
                NSLocalizedString("Move Video to Trash", comment: ""),
                isPresented: Binding(
                    get: { deletingVideo != nil && navigationPath.isEmpty && searchText.isEmpty },
                    set: { if !$0 { deletingVideo = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Move to Trash", role: .destructive) {
                    if let target = deletingVideo {
                        handleMoveToTrash(video: target)
                    }
                    deletingVideo = nil
                }
                Button("Cancel", role: .cancel) {
                    deletingVideo = nil
                }
            } message: {
                if let target = deletingVideo {
                    Text(String(format: NSLocalizedString("Are you sure you want to move \"%@\" to Trash?\n(Permanently deleted after 3 days)", comment: ""), target.title))
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
        let hasFolders = !folderManager.folders.isEmpty
        let hasUncategorized = !uncategorizedVideos.isEmpty

        return Group {
            LazyVGrid(columns: gridColumns, spacing: 18) {
                // Private Vaultカード（非公開保管庫、隠しモード無効時のみ表示）
                if !settingsManager.hideVaultInFileList {
                    privateVaultCard
                }

                // 未分類フォルダカード（未分類動画がある、またはフォルダが作成されている場合に表示）
                if hasUncategorized || hasFolders {
                    folderCard(
                        title: NSLocalizedString("Uncategorized Videos", comment: ""),
                        itemCount: uncategorizedVideos.count,
                        videos: uncategorizedVideos,
                        filter: .uncategorized,
                        isCustomFolder: false
                    )
                }

                // ユーザー作成フォルダ群
                ForEach(folderManager.folders, id: \.self) { folderName in
                    let videosInFolder = folderManager.videos(in: .folder(folderName))
                    folderCard(
                        title: folderName,
                        itemCount: videosInFolder.count,
                        videos: videosInFolder,
                        filter: .folder(folderName),
                        isCustomFolder: true
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

        return ZStack(alignment: .bottom) {
            ScrollView {
                VStack(spacing: 16) {
                    if filteredVideos.isEmpty {
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
                                    onMoveToVault: {
                                        handleMoveToVault(video: video)
                                    },
                                    onDelete: {
                                        deletingVideo = video
                                    },
                                    onOpenSourcePage: { url in
                                        onOpenSourcePage?(url)
                                        dismiss()
                                    },
                                    onCopySourcePageURL: copySourcePageURL
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
                selectionBottomBar(currentVideos: filteredVideos)
            } else {
                floatingBottomBar(isRoot: false)
            }
        }
        .navigationTitle(isSelecting ? String(format: NSLocalizedString("%lld selected", comment: ""), selectedVideoIDs.count) : filter.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isSelecting {
                    Button("Done") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isSelecting = false
                            selectedVideoIDs.removeAll()
                        }
                    }
                    .font(.body.weight(.semibold))
                } else {
                    Menu {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isSelecting = true
                                selectedVideoIDs.removeAll()
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
        // 遷移先画面自身に確認ダイアログを接続することで確実に表示されるよう修正
        .confirmationDialog(
            NSLocalizedString("Move Video to Trash", comment: ""),
            isPresented: Binding(
                get: { deletingVideo != nil },
                set: { if !$0 { deletingVideo = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let target = deletingVideo {
                    handleMoveToTrash(video: target)
                }
                deletingVideo = nil
            }
            Button("Cancel", role: .cancel) {
                deletingVideo = nil
            }
        } message: {
            if let target = deletingVideo {
                Text(String(format: NSLocalizedString("Are you sure you want to move \"%@\" to Trash?\n(Permanently deleted after 3 days)", comment: ""), target.title))
            }
        }
    }

    // MARK: - 全体検索結果セクション

    private var searchResultsSection: some View {
        let allVideos = folderManager.videos(in: .all)
        let matchedVideos = sortVideos(allVideos.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
        })
        let matchedFolders = folderManager.folders.filter {
            $0.localizedCaseInsensitiveContains(searchText)
        }

        return VStack(alignment: .leading, spacing: 16) {
            if matchedFolders.isEmpty && matchedVideos.isEmpty {
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
                                folderCard(
                                    title: folderName,
                                    itemCount: vids.count,
                                    videos: vids,
                                    filter: .folder(folderName),
                                    isCustomFolder: true
                                )
                            }
                        }
                    }
                }

                if !matchedVideos.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(format: NSLocalizedString("Matching Videos (%lld)", comment: ""), matchedVideos.count))
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
                                    onMoveToVault: {
                                        handleMoveToVault(video: video)
                                    },
                                    onDelete: {
                                        deletingVideo = video
                                    },
                                    onOpenSourcePage: { url in
                                        onOpenSourcePage?(url)
                                        dismiss()
                                    },
                                    onCopySourcePageURL: copySourcePageURL
                                )
                            }
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            NSLocalizedString("Move Video to Trash", comment: ""),
            isPresented: Binding(
                get: { deletingVideo != nil && !searchText.isEmpty },
                set: { if !$0 { deletingVideo = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let target = deletingVideo {
                    handleMoveToTrash(video: target)
                }
                deletingVideo = nil
            }
            Button("Cancel", role: .cancel) {
                deletingVideo = nil
            }
        } message: {
            if let target = deletingVideo {
                Text(String(format: NSLocalizedString("Are you sure you want to move \"%@\" to Trash?\n(Permanently deleted after 3 days)", comment: ""), target.title))
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

    private func selectionBottomBar(currentVideos: [SavedVideo]) -> some View {
        HStack(spacing: 12) {
            // 全選択 / 選択解除ボタン
            Button {
                if selectedVideoIDs.count == currentVideos.count && !currentVideos.isEmpty {
                    selectedVideoIDs.removeAll()
                } else {
                    selectedVideoIDs = Set(currentVideos.map { $0.id })
                }
            } label: {
                Text(selectedVideoIDs.count == currentVideos.count && !currentVideos.isEmpty ? NSLocalizedString("Deselect All", comment: "") : NSLocalizedString("Select All", comment: ""))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(.secondarySystemBackground), in: Capsule())
            }

            Spacer()

            // 選択件数
            Text(String(format: NSLocalizedString("%lld selected", comment: ""), selectedVideoIDs.count))
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
                        .foregroundStyle(selectedVideoIDs.isEmpty ? Color.secondary : Color.primary)
                        .frame(width: 34, height: 34)
                        .background(Color(.secondarySystemBackground), in: Circle())
                }
                .disabled(selectedVideoIDs.isEmpty)

                // 一括Private Vault移動
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

                // 一括ゴミ箱移動
                Button {
                    showBatchDeleteAlert = true
                } label: {
                    Image(systemName: "trash")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(selectedVideoIDs.isEmpty ? Color.secondary : Color.red)
                        .frame(width: 34, height: 34)
                        .background(selectedVideoIDs.isEmpty ? Color(.secondarySystemBackground) : Color.red.opacity(0.12), in: Circle())
                }
                .disabled(selectedVideoIDs.isEmpty)
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
        let targets = downloads.saved.filter { selectedVideoIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        var successCount = 0
        for v in targets {
            if case .success = folderManager.moveVideo(v, toFolder: targetFolder) {
                successCount += 1
            }
        }
        withAnimation {
            isSelecting = false
            selectedVideoIDs.removeAll()
        }
        let destName = targetFolder.isEmpty ? NSLocalizedString("Downloads (Uncategorized)", comment: "") : "「\(targetFolder)」"
        showToast(String(format: NSLocalizedString("Moved %lld videos to %@", comment: ""), successCount, destName))
    }

    private func handleBatchMoveToTrash(videos: [SavedVideo]) {
        let targets = videos.filter { selectedVideoIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        Task {
            var successCount = 0
            for v in targets {
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
            await MainActor.run {
                withAnimation {
                    isSelecting = false
                    selectedVideoIDs.removeAll()
                }
                showToast(String(format: NSLocalizedString("Moved %lld videos to Trash", comment: ""), successCount))
            }
        }
    }

    private func handleMoveToVault(video: SavedVideo) {
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
            Task {
                for url in urls {
                    guard url.startAccessingSecurityScopedResource() else { continue }
                    let data = try? Data(contentsOf: url)
                    let name = url.deletingPathExtension().lastPathComponent
                    url.stopAccessingSecurityScopedResource()

                    if let d = data {
                        await importImageData(d, preferredName: name)
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
        !downloads.jobs.isEmpty || !exports.exportJobs.isEmpty
    }

    private var activeJobsBanner: some View {
        let activeCount = downloads.jobs.filter { $0.state.isActive }.count + exports.exportJobs.filter { $0.state.isActive }.count
        let totalCount = downloads.jobs.count + exports.exportJobs.count

        return VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isJobsBannerExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
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

    // MARK: - PoC検証メニュー

    private var pocVerificationMenu: some View {
        Menu {
            Button {
                _ = exports.startPoCTestA_MuxedFMP4()
            } label: {
                Label("Test A: Unified Video/Audio fMP4 → MP4", systemImage: "checkmark.seal")
            }
            Button {
                _ = exports.startPoCTestB_AppleSeparateAudioFMP4()
            } label: {
                Label("Test B: Apple Official Separate Audio fMP4 → MP4 Join", systemImage: "waveform.badge.plus")
            }
            Button {
                _ = exports.startPoCTestC_MPEGTS()
            } label: {
                Label("Test C: MPEG-TS Format Unsupported Check", systemImage: "film.stack")
            }
        } label: {
            Label("fMP4→MP4 PoC On-Device Test (A/B/C)", systemImage: "testtube.2")
        }
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

    // MARK: - ゴミ箱移動とURLコピー通知

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
        }
        .presentationDetents([.medium, .large])
    }
}
