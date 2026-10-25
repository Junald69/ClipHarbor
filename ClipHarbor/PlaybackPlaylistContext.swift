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
        case .vault: return false
        }
    }

    var isVideo: Bool {
        !isImage
    }

    var isFavorite: Bool {
        switch self {
        case .normal(let v): return v.isFavorite
        case .vault(let item): return item.isFavorite
        }
    }
}

final class PlaybackPlaylistContext: ObservableObject, Equatable {
    let contextTitle: String
    let isVault: Bool
    @Published private(set) var items: [PlaybackMediaItem]
    @Published private(set) var currentIndex: Int

    init(contextTitle: String, isVault: Bool, items: [PlaybackMediaItem], initialIndex: Int) {
        self.contextTitle = contextTitle
        self.isVault = isVault
        self.items = items
        self.currentIndex = max(0, min(initialIndex, max(0, items.count - 1)))
    }

    convenience init(normalVideos: [SavedVideo], initialVideo: SavedVideo, folderTitle: String) {
        let mapped = normalVideos.map { PlaybackMediaItem.normal($0) }
        let idx = normalVideos.firstIndex(where: { $0.id == initialVideo.id }) ?? 0
        self.init(contextTitle: folderTitle, isVault: false, items: mapped, initialIndex: idx)
    }

    convenience init(vaultItems: [VaultItem], initialItem: VaultItem) {
        let mapped = vaultItems.map { PlaybackMediaItem.vault($0) }
        let idx = vaultItems.firstIndex(where: { $0.id == initialItem.id }) ?? 0
        self.init(contextTitle: "Private Vault", isVault: true, items: mapped, initialIndex: idx)
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

    static func == (lhs: PlaybackPlaylistContext, rhs: PlaybackPlaylistContext) -> Bool {
        lhs.isVault == rhs.isVault &&
        lhs.currentIndex == rhs.currentIndex &&
        lhs.items == rhs.items
    }
}
