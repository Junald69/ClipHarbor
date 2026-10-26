import Foundation

/// プレイヤー・ビューアーが再生中のメディアリスト文脈
/// - 通常フォルダ一覧、未分類一覧、またはVault暗号化保管庫のいずれかに厳格に限定
/// - 左右スワイプによる「次へ」「前へ」の移動において境界外や循環ループを遮断
enum PlaybackMediaItem: Identifiable, Equatable {
    case normal(SavedVideo)
    case vault(VaultItem)

    var id: UUID {
        switch self {
        case .normal(let v): return v.id
        case .vault(let item): return item.id
        }
    }

    var title: String {
        switch self {
        case .normal(let v): return v.title
        case .vault(let item): return item.originalTitle
        }
    }

    var isHLS: Bool {
        switch self {
        case .normal(let v): return v.isHLS
        case .vault: return false
        }
    }

    var isImage: Bool {
        switch self {
        case .normal(let v): return v.format.isImage
        case .vault(let item): return item.format.isImage
        }
    }

    var isVideo: Bool {
        !isImage
    }

    var isFavorite: Bool {
        get {
            switch self {
            case .normal(let v): return v.isFavorite
            case .vault(let item): return item.isFavorite
            }
        }
        set {
            switch self {
            case .normal(var v):
                v.isFavorite = newValue
                self = .normal(v)
            case .vault(var item):
                item.isFavorite = newValue
                self = .vault(item)
            }
        }
    }
}

final class PlaybackPlaylistContext: ObservableObject, Equatable {
    let contextTitle: String
    let isVault: Bool
    let vaultSessionToken: UUID?
    @Published private(set) var items: [PlaybackMediaItem]
    @Published private(set) var currentIndex: Int

    init(contextTitle: String, isVault: Bool, vaultSessionToken: UUID? = nil, items: [PlaybackMediaItem], initialIndex: Int) {
        self.contextTitle = contextTitle
        self.isVault = isVault
        self.vaultSessionToken = vaultSessionToken
        self.items = items
        self.currentIndex = max(0, min(initialIndex, max(0, items.count - 1)))
    }

    convenience init(normalVideos: [SavedVideo], initialVideo: SavedVideo, folderTitle: String) {
        let mapped = normalVideos.map { PlaybackMediaItem.normal($0) }
        let idx = normalVideos.firstIndex(where: { $0.id == initialVideo.id }) ?? 0
        self.init(contextTitle: folderTitle, isVault: false, vaultSessionToken: nil, items: mapped, initialIndex: idx)
    }

    convenience init(vaultItems: [VaultItem], initialItem: VaultItem, sessionToken: UUID) {
        let mapped = vaultItems.map { PlaybackMediaItem.vault($0) }
        let idx = vaultItems.firstIndex(where: { $0.id == initialItem.id }) ?? 0
        self.init(contextTitle: "Private Vault", isVault: true, vaultSessionToken: sessionToken, items: mapped, initialIndex: idx)
    }

    var currentItem: PlaybackMediaItem? {
        guard items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }

    /// 左スワイプ（指を右から左へ動かす）で「次へ」移動可能か
    var canGoNext: Bool {
        currentIndex < items.count - 1
    }

    /// 右スワイプ（指を左から右へ動かす）で「前へ」移動可能か
    var canGoPrevious: Bool {
        currentIndex > 0
    }

    /// 次のアイテムへ移動（末尾では循環させず false を返す）
    @discardableResult
    func moveToNext() -> PlaybackMediaItem? {
        guard canGoNext else { return nil }
        currentIndex += 1
        return currentItem
    }

    /// 前のアイテムへ移動（先頭では循環させず false を返す）
    @discardableResult
    func moveToPrevious() -> PlaybackMediaItem? {
        guard canGoPrevious else { return nil }
        currentIndex -= 1
        return currentItem
    }

    /// 指定されたIDのアイテムをプレイリストから除外し、次のアイテムへ進む（末尾なら前へ、0件ならnil）
    @discardableResult
    func removeItem(id: UUID) -> PlaybackMediaItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            return currentItem
        }
        items.remove(at: index)
        if items.isEmpty {
            currentIndex = 0
            return nil
        }
        if index >= items.count {
            currentIndex = items.count - 1
        } else {
            currentIndex = index
        }
        return currentItem
    }

    /// 指定されたIDのアイテムのお気に入り状態を同期・更新
    func updateFavorite(id: UUID, isFavorite: Bool) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[idx].isFavorite != isFavorite else { return }
        items[idx].isFavorite = isFavorite
    }

    static func == (lhs: PlaybackPlaylistContext, rhs: PlaybackPlaylistContext) -> Bool {
        lhs.isVault == rhs.isVault &&
        lhs.vaultSessionToken == rhs.vaultSessionToken &&
        lhs.currentIndex == rhs.currentIndex &&
        lhs.items == rhs.items
    }
}
