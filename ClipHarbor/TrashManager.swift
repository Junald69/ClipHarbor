import Foundation
import UIKit

/// ゴミ箱内アイテムのペイロード種別（動画 vs 一般ファイル vs フォルダ） (Phase F2-B & S3)
enum TrashPayloadKind: String, Codable {
    case video          // 既存の動画・HLS
    case generalFile    // ZIP・PDF・TXT・MD等の一般ファイル
    case folder         // フォルダ一括（配下の全ファイル・サブフォルダ構造を保持）
}

/// ゴミ箱内のファイル管理アイテムモデル
struct TrashItem: Identifiable, Codable, Equatable {
    let id: UUID                     // ゴミ箱管理用の一意ID
    let originalVideoID: UUID        // 元のSavedVideo.idまたはManagedFileItem.id
    let originalTitle: String        // 表示名
    let originalRelativePath: String // 元の相対パス
    let originalFolderName: String   // 元のフォルダ名（空文字は未分類）
    let format: SavedVideo.Format    // MP4 / HLS 等（一般ファイル時は互換性ダミー値 .mp4 を保持）
    let byteSize: Int64?             // ファイルサイズ
    let sourceHost: String?          // 配信元ホスト
    let sourcePageURL: String?       // 元WebページURL
    let deletedAt: Date              // ゴミ箱移動日時
    let expiresAt: Date?             // 完全削除予定日時（nilは自動削除なし）
    let fileName: String             // 実際のファイル名またはパッケージ名
    let isFavorite: Bool?            // 元のお気に入り状態

    // --- Phase F2-B 拡張フィールド ---
    let payloadKind: TrashPayloadKind // ペイロード種別（動画 / 一般ファイル / フォルダ）
    let fileExtension: String?        // 一般ファイルの拡張子（例: "txt", "zip", "pdf"）
    let relativeSubpath: String?      // ネスト階層情報

    // --- Phase S3 フォルダ一括拡張フィールド ---
    let folderItemCount: Int?        // フォルダ内のアイテム総数

    var isGeneralFile: Bool { payloadKind == .generalFile }
    var isVideo: Bool { payloadKind == .video }
    var isFolder: Bool { payloadKind == .folder }

    var typeLabel: String {
        if isFolder {
            return NSLocalizedString("FOLDER", comment: "")
        } else if isGeneralFile {
            return (fileExtension?.isEmpty == false ? fileExtension! : "FILE").uppercased()
        } else {
            return format.label
        }
    }

    var isExpired: Bool {
        guard let expiresAt = expiresAt else { return false }
        return Date() >= expiresAt
    }

    /// 完全削除までの残り時間表示
    var remainingTimeDescription: String {
        guard let expiresAt = expiresAt else {
            return NSLocalizedString("No auto-delete (Kept until deleted manually)", comment: "")
        }
        let remaining = expiresAt.timeIntervalSince(Date())
        if remaining <= 0 {
            return NSLocalizedString("Expired (Deleted on next app launch)", comment: "")
        }
        let totalHours = Int(remaining / 3600)
        let days = totalHours / 24
        let remHours = totalHours % 24
        if days > 0 {
            return String(format: NSLocalizedString("%lldd %lldh left", comment: ""), days, remHours)
        } else {
            let mins = Int((remaining.truncatingRemainder(dividingBy: 3600)) / 60)
            if totalHours > 0 {
                return String(format: NSLocalizedString("%lldh %lldm left", comment: ""), totalHours, mins)
            } else {
                return String(format: NSLocalizedString("%lldm left", comment: ""), max(1, mins))
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, originalVideoID, originalTitle, originalRelativePath, originalFolderName
        case format, byteSize, sourceHost, sourcePageURL, deletedAt, expiresAt, fileName, isFavorite
        case payloadKind, fileExtension, relativeSubpath, folderItemCount
    }

    init(
        id: UUID,
        originalVideoID: UUID,
        originalTitle: String,
        originalRelativePath: String,
        originalFolderName: String,
        format: SavedVideo.Format,
        byteSize: Int64?,
        sourceHost: String?,
        sourcePageURL: String?,
        deletedAt: Date,
        expiresAt: Date?,
        fileName: String,
        isFavorite: Bool? = false,
        payloadKind: TrashPayloadKind = .video,
        fileExtension: String? = nil,
        relativeSubpath: String? = nil,
        folderItemCount: Int? = nil
    ) {
        self.id = id
        self.originalVideoID = originalVideoID
        self.originalTitle = originalTitle
        self.originalRelativePath = originalRelativePath
        self.originalFolderName = originalFolderName
        self.format = format
        self.byteSize = byteSize
        self.sourceHost = sourceHost
        self.sourcePageURL = sourcePageURL
        self.deletedAt = deletedAt
        self.expiresAt = expiresAt
        self.fileName = fileName
        self.isFavorite = isFavorite
        self.payloadKind = payloadKind
        self.fileExtension = fileExtension
        self.relativeSubpath = relativeSubpath
        self.folderItemCount = folderItemCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        originalVideoID = try container.decode(UUID.self, forKey: .originalVideoID)
        originalTitle = try container.decode(String.self, forKey: .originalTitle)
        originalRelativePath = try container.decode(String.self, forKey: .originalRelativePath)
        originalFolderName = try container.decode(String.self, forKey: .originalFolderName)
        format = try container.decode(SavedVideo.Format.self, forKey: .format)
        byteSize = try container.decodeIfPresent(Int64.self, forKey: .byteSize)
        sourceHost = try container.decodeIfPresent(String.self, forKey: .sourceHost)
        sourcePageURL = try container.decodeIfPresent(String.self, forKey: .sourcePageURL)
        deletedAt = try container.decode(Date.self, forKey: .deletedAt)
        fileName = try container.decode(String.self, forKey: .fileName)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite)
        payloadKind = try container.decodeIfPresent(TrashPayloadKind.self, forKey: .payloadKind) ?? .video
        fileExtension = try container.decodeIfPresent(String.self, forKey: .fileExtension)
        relativeSubpath = try container.decodeIfPresent(String.self, forKey: .relativeSubpath)
        folderItemCount = try container.decodeIfPresent(Int.self, forKey: .folderItemCount)

        if container.contains(.expiresAt) {
            expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        } else {
            // 旧データに期限がない場合は、従来どおり削除日時＋72時間とする
            expiresAt = deletedAt.addingTimeInterval(72 * 3600)
        }
    }
}

/// フォルダ復元時の競合解決オプション（初期実装: 別名復元またはキャンセル）
enum FolderRestoreConflictResolution: String, Codable {
    case rename  // 別名で安全に共存（<フォルダ名> (1) など）
    case cancel  // 復元中断
}

/// フォルダ一括ゴミ箱移動時の詳細マニフェスト（スキーマバージョン管理対応）
struct FolderTrashManifest: Codable {
    static let currentVersion = 1

    let version: Int
    let folderID: UUID
    let originalFolderName: String
    let deletedAt: Date
    let totalByteSize: Int64
    let videos: [TrashFolderVideoRecord]
    let generalFiles: [TrashFolderGeneralFileRecord]
    let unregisteredFiles: [TrashFolderUnregisteredFileRecord]
    let emptySubdirectories: [String]
    let externalHLSAssets: [TrashFolderExternalHLSAssetRecord]?

    enum CodingKeys: String, CodingKey {
        case version, folderID, originalFolderName, deletedAt, totalByteSize
        case videos, generalFiles, unregisteredFiles, emptySubdirectories, externalHLSAssets
    }

    init(
        version: Int = FolderTrashManifest.currentVersion,
        folderID: UUID,
        originalFolderName: String,
        deletedAt: Date,
        totalByteSize: Int64,
        videos: [TrashFolderVideoRecord],
        generalFiles: [TrashFolderGeneralFileRecord],
        unregisteredFiles: [TrashFolderUnregisteredFileRecord],
        emptySubdirectories: [String],
        externalHLSAssets: [TrashFolderExternalHLSAssetRecord]? = nil
    ) {
        self.version = version
        self.folderID = folderID
        self.originalFolderName = originalFolderName
        self.deletedAt = deletedAt
        self.totalByteSize = totalByteSize
        self.videos = videos
        self.generalFiles = generalFiles
        self.unregisteredFiles = unregisteredFiles
        self.emptySubdirectories = emptySubdirectories
        self.externalHLSAssets = externalHLSAssets
    }
}

struct TrashFolderVideoRecord: Codable {
    let video: SavedVideo
    let relativeSubpath: String
}

struct TrashFolderGeneralFileRecord: Codable {
    let file: ManagedFileItem
    let relativeSubpath: String
}

struct TrashFolderUnregisteredFileRecord: Codable {
    let relativeSubpath: String
    let byteSize: Int64
}

struct TrashFolderExternalHLSAssetRecord: Codable {
    let videoID: UUID
    let originalRelativePath: String
    let trashPackageSubpath: String
}

/// フォルダゴミ箱移動・復元のトランザクション管理レコード（強制終了・クラッシュからの自動復旧用）
struct TrashTransaction: Codable {
    enum Operation: String, Codable {
        case moveToTrash
        case restore
    }
    enum Phase: String, Codable {
        case manifestVerified    // マニフェスト書き込み・検証完了
        case physicalMoved       // 物理ディレクトリ移動完了
        case metadataCommitted   // メタデータ永続化完了
    }

    let transactionID: UUID
    let trashID: UUID
    let folderName: String
    let operation: Operation
    var phase: Phase
    let sourcePath: String
    let destinationPath: String
    let timestamp: Date
}

/// アプリ内ゴミ箱管理マネージャー
/// - 保存先: `Library/Application Support/Trash/`（iOSファイルアプリから不可視、OS自動消去対象外）
/// - サムネイル保存: `Library/Application Support/Trash/<id>/thumbnail.jpg`（非公開領域に永続化、再起動後も表示）
/// - 72時間（3日間）保持後に次回起動時またはフォアグラウンド復帰時にバックグラウンド完全削除
/// - 大容量ファイルの操作はバックグラウンドシリアルキューで実行しメインスレッドを阻害しない
/// - 二重操作防止（処理中アイテムのロック管理）
/// - ロールバック機能（ファイル移動やメタデータ書き込み失敗時に元の状態へ安全復元）
/// - メタデータ破損時でもゴミ箱内ファイルを空と誤認して削除しない安全保護機構
/// - MP4およびオフラインHLS（.movpkg一式）、一般ファイル（ZIP・PDF・TXT等）の確実な移動と復元に対応
final class TrashManager: ObservableObject {
    static let shared = TrashManager()

    /// 保持期限（72時間）
    static let expirationInterval: TimeInterval = 72 * 3600

    @Published private(set) var items: [TrashItem] = []
    @Published private(set) var processingItemIDs: Set<UUID> = []

    private let fileManager = FileManager.default
    private let ioQueue = DispatchQueue(label: "com.clipharbor.trashmanager.io", qos: .userInitiated)
    private let trashThumbnailCache = NSCache<NSString, UIImage>()

    /// テスト用のカスタムゴミ箱ディレクトリ（指定時はこの配下に Trash/ が作られる）
    var customTrashDirectoryURL: URL? = nil

    // MARK: - パス管理

    private static var defaultTrashDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let trashDir = appSupport.appendingPathComponent("Trash", isDirectory: true)
        if !FileManager.default.fileExists(atPath: trashDir.path) {
            try? FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        }
        return trashDir
    }

    var trashDirectoryURL: URL {
        if let custom = customTrashDirectoryURL {
            let trashDir = custom.appendingPathComponent("Trash", isDirectory: true)
            if !fileManager.fileExists(atPath: trashDir.path) {
                try? fileManager.createDirectory(at: trashDir, withIntermediateDirectories: true)
            }
            return trashDir
        }
        return Self.defaultTrashDirectoryURL
    }

    var metadataFileURL: URL {
        trashDirectoryURL.appendingPathComponent("trash_metadata.json")
    }

    var transactionsDirectoryURL: URL {
        let dir = trashDirectoryURL.appendingPathComponent("transactions", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func transactionFileURL(for trashID: UUID) -> URL {
        transactionsDirectoryURL.appendingPathComponent("\(trashID.uuidString).json")
    }

    private func itemDirectoryURL(for itemID: UUID) -> URL {
        trashDirectoryURL.appendingPathComponent(itemID.uuidString, isDirectory: true)
    }

    func itemFileURL(for item: TrashItem) -> URL {
        itemDirectoryURL(for: item.id).appendingPathComponent(item.fileName)
    }

    func itemThumbnailURL(for item: TrashItem) -> URL {
        itemDirectoryURL(for: item.id).appendingPathComponent("thumbnail.jpg")
    }

    // MARK: - テスト用フォールトインジェクションフック

    var faultInjectionBeforePhysicalMove: (() throws -> Void)? = nil
    var faultInjectionBeforeMetadataCommit: (() throws -> Void)? = nil
    var faultInjectionBeforeRestorePhysicalMove: (() throws -> Void)? = nil

    // MARK: - 初期化とライフサイクル

    init(customTrashDirectoryURL: URL? = nil) {
        self.customTrashDirectoryURL = customTrashDirectoryURL
        trashThumbnailCache.countLimit = 100
        trashThumbnailCache.totalCostLimit = 40 * 1024 * 1024

        loadMetadataSafely()
        reconcileIncompleteTransactions()
        purgeExpiredItems()

        // アプリフォアグラウンド復帰時に期限切れを自動パージ
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    @objc private func handleAppForeground() {
        purgeExpiredItems()
    }

    // MARK: - サムネイル取得・永続化

    /// ゴミ箱内アイテムのサムネイル取得（非公開領域に永続化、再起動後も安定表示）
    /// - Note: 一般ファイル（isGeneralFile == true）に対しては動画サムネイル生成は一切行わない
    func loadThumbnail(for item: TrashItem) async -> UIImage? {
        guard item.isVideo || item.isFolder else { return nil }

        let cacheKey = item.id.uuidString as NSString
        if let cached = trashThumbnailCache.object(forKey: cacheKey) {
            return cached
        }

        let thumbURL = itemThumbnailURL(for: item)

        // 1. ゴミ箱専用ディレクトリ内のサムネイルファイルが存在すれば直接読み込み
        if fileManager.fileExists(atPath: thumbURL.path),
           let data = try? Data(contentsOf: thumbURL),
           let img = UIImage(data: data) {
            let cost = Int(img.size.width * img.size.height * 4)
            trashThumbnailCache.setObject(img, forKey: cacheKey, cost: cost)
            return img
        }

        // 2. なければ実ファイルから非同期生成して保存
        let videoURL = itemFileURL(for: item)
        if let generated = await VideoThumbnailManager.shared.generateThumbnail(forFileURL: videoURL) {
            let cost = Int(generated.size.width * generated.size.height * 4)
            trashThumbnailCache.setObject(generated, forKey: cacheKey, cost: cost)
            if let jpegData = generated.jpegData(compressionQuality: 0.75) {
                try? jpegData.write(to: thumbURL, options: .atomic)
            }
            return generated
        }

        return nil
    }

    // MARK: - 二重操作ロック管理

    private func isProcessing(_ id: UUID) -> Bool {
        processingItemIDs.contains(id)
    }

    private func setProcessing(_ id: UUID, active: Bool) {
        if active {
            processingItemIDs.insert(id)
        } else {
            processingItemIDs.remove(id)
        }
    }

    /// ファイル移動失敗・メタデータ書き込み失敗時の安全ロールバック
    /// - Returns: 移動元へのロールバックが確認できた場合は true（ゴミ箱側一時ディレクトリを安全に破棄可能）。
    ///            ロールバックに失敗した場合は false（実データ消失を防ぐためゴミ箱内ファイルを残す）。
    @discardableResult
    private func safelyRollbackMoveOrPreserve(
        sourceURL: URL,
        destURL: URL,
        itemDir: URL
    ) -> Bool {
        let sourceExistsBefore = fileManager.fileExists(atPath: sourceURL.path)
        let destExistsBefore = fileManager.fileExists(atPath: destURL.path)

        // もし移動先が存在しないなら、元データは移動していない（または移動前に失敗）
        if !destExistsBefore {
            if let contents = try? fileManager.contentsOfDirectory(atPath: itemDir.path), contents.isEmpty {
                try? fileManager.removeItem(at: itemDir)
            }
            return true
        }

        // 移動先にファイルが存在する場合
        if !sourceExistsBefore {
            // 移動元に戻すロールバックを試行
            do {
                try fileManager.moveItem(at: destURL, to: sourceURL)
            } catch {
                print("[TrashManager] Rollback moveItem failed: \(error)")
            }
        }

        let sourceExistsAfter = fileManager.fileExists(atPath: sourceURL.path)
        let destExistsAfter = fileManager.fileExists(atPath: destURL.path)

        if sourceExistsAfter {
            // 移動元への復元が確認できた場合のみ、ゴミ箱側の一時ディレクトリを削除可能
            if !destExistsAfter {
                try? fileManager.removeItem(at: itemDir)
                return true
            } else {
                // 移動元と移動先の両方に実ファイルが存在する場合：
                // 移動元ファイルのサイズや存在のみを理由に移動先ファイルを削除してはならない。
                // 同一内容や所有関係が証明できない限り両方保持し、競合状態として扱う。
                print("[TrashManager] CONFLICT: Both sourceURL (\(sourceURL.path)) and destURL (\(destURL.path)) exist. Preserving both files to prevent data loss.")
                return false
            }
        } else {
            // 移動元に実ファイルが存在しない！
            // ロールバックに失敗したため、実データ消失を防ぐためゴミ箱内の実ファイルは絶対に削除してはならない！
            print("[TrashManager] CRITICAL: Rollback failed to restore file to sourceURL. Preserving file at destURL: \(destURL.path)")
            return false
        }
    }

    // MARK: - トランザクション管理と障害復旧 (Phase S3)

    private func recordTransaction(_ tx: TrashTransaction) {
        let fileURL = transactionFileURL(for: tx.trashID)
        if let data = try? JSONEncoder().encode(tx) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func removeTransaction(trashID: UUID) {
        let fileURL = transactionFileURL(for: trashID)
        try? fileManager.removeItem(at: fileURL)
    }

    /// ゴミ箱内フォルダのマニフェストを安全に取得（破損・欠損・旧形式不一致時は nil を返す）
    func loadFolderManifest(for itemID: UUID) -> FolderTrashManifest? {
        let manifestURL = itemDirectoryURL(for: itemID).appendingPathComponent("folder_manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path),
              let data = try? Data(contentsOf: manifestURL) else {
            return nil
        }
        return try? JSONDecoder().decode(FolderTrashManifest.self, from: data)
    }

    /// 途中クラッシュ・強制終了による未完了トランザクションを検出し、安全に整合性を回復する
    func reconcileIncompleteTransactions(
        downloads: DownloadCenter? = nil,
        folderManager: VideoFolderManager? = nil,
        zipManager: ZipArchiveManager? = nil
    ) {
        let txDir = transactionsDirectoryURL
        guard fileManager.fileExists(atPath: txDir.path),
              let files = try? fileManager.contentsOfDirectory(atPath: txDir.path) else {
            return
        }

        let resolvedDownloads = downloads ?? (Thread.isMainThread ? MainActor.assumeIsolated { DownloadCenter.shared } : nil)
        let resolvedFolderMgr = folderManager ?? (Thread.isMainThread ? MainActor.assumeIsolated { VideoFolderManager.shared } : nil)
        let resolvedZipMgr = zipManager ?? (Thread.isMainThread ? MainActor.assumeIsolated { ZipArchiveManager.shared } : nil)

        for file in files where file.hasSuffix(".json") {
            let fileURL = txDir.appendingPathComponent(file)
            guard let data = try? Data(contentsOf: fileURL),
                  let tx = try? JSONDecoder().decode(TrashTransaction.self, from: data) else {
                continue
            }

            let itemDir = itemDirectoryURL(for: tx.trashID)

            switch tx.operation {
            case .moveToTrash:
                switch tx.phase {
                case .manifestVerified:
                    // 物理移動前（または移動失敗）：移動元にフォルダが残っていればゴミ箱側の一時ディレクトリを破棄
                    let sourceURL = URL(fileURLWithPath: tx.sourcePath)
                    if fileManager.fileExists(atPath: sourceURL.path) {
                        try? fileManager.removeItem(at: itemDir)
                        try? fileManager.removeItem(at: fileURL)
                    }
                case .physicalMoved:
                    // 物理移動は成功したがメタデータ保存前：マニフェストが存在すればTrashItemを再構成してゴミ箱に登録
                    let manifestURL = itemDir.appendingPathComponent("folder_manifest.json")
                    if fileManager.fileExists(atPath: manifestURL.path),
                       let mData = try? Data(contentsOf: manifestURL),
                       let manifest = try? JSONDecoder().decode(FolderTrashManifest.self, from: mData) {
                        if !items.contains(where: { $0.id == tx.trashID }) {
                            let retention = Thread.isMainThread ? MainActor.assumeIsolated { AppSettingsManager.shared.trashRetentionPeriod } : .threeDays
                            let expiresAt = retention.timeInterval.map { tx.timestamp.addingTimeInterval($0) }
                            let count = manifest.videos.count + manifest.generalFiles.count + manifest.unregisteredFiles.count
                            let restoredItem = TrashItem(
                                id: tx.trashID,
                                originalVideoID: tx.trashID,
                                originalTitle: tx.folderName,
                                originalRelativePath: "Documents/Downloads/\(tx.folderName)",
                                originalFolderName: "",
                                format: .mp4,
                                byteSize: manifest.totalByteSize,
                                sourceHost: nil,
                                sourcePageURL: nil,
                                deletedAt: tx.timestamp,
                                expiresAt: expiresAt,
                                fileName: tx.folderName,
                                isFavorite: false,
                                payloadKind: .folder,
                                fileExtension: nil,
                                relativeSubpath: nil,
                                folderItemCount: count
                            )
                            items.insert(restoredItem, at: 0)
                            try? writeMetadataToDisk(items)

                            DispatchQueue.main.async {
                                for vRec in manifest.videos {
                                    resolvedDownloads?.removeSavedVideoWithoutDeletingFile(id: vRec.video.id)
                                    resolvedFolderMgr?.removeVideoFromFolder(videoID: vRec.video.id)
                                }
                                for gRec in manifest.generalFiles {
                                    resolvedZipMgr?.removeManagedFileFromIndex(id: gRec.file.id)
                                }
                                resolvedFolderMgr?.unregisterLogicalFolderIfNeeded(tx.folderName)
                            }
                        }
                        try? fileManager.removeItem(at: fileURL)
                    }
                case .metadataCommitted:
                    try? fileManager.removeItem(at: fileURL)
                }

            case .restore:
                switch tx.phase {
                case .manifestVerified:
                    try? fileManager.removeItem(at: fileURL)
                case .physicalMoved:
                    let destURL = URL(fileURLWithPath: tx.destinationPath)
                    let manifestURL = itemDir.appendingPathComponent("folder_manifest.json")
                    if fileManager.fileExists(atPath: destURL.path),
                       let mData = try? Data(contentsOf: manifestURL),
                       let manifest = try? JSONDecoder().decode(FolderTrashManifest.self, from: mData) {
                        items.removeAll { $0.id == tx.trashID }
                        try? writeMetadataToDisk(items)
                        try? fileManager.removeItem(at: itemDir)
                        try? fileManager.removeItem(at: fileURL)

                        let restoredFolderName = destURL.lastPathComponent
                        DispatchQueue.main.async {
                            resolvedFolderMgr?.registerLogicalFolderIfNeeded(restoredFolderName)
                            for vRec in manifest.videos {
                                var v = vRec.video
                                if !v.isHLS {
                                    v.relativePath = "Documents/Downloads/\(restoredFolderName)/\(vRec.relativeSubpath)"
                                }
                                resolvedDownloads?.restoreSavedVideo(v)
                                resolvedFolderMgr?.restoreVideoToFolder(v, targetFolder: restoredFolderName)
                            }
                            for gRec in manifest.generalFiles {
                                var f = gRec.file
                                f.relativePath = "Documents/Downloads/\(restoredFolderName)/\(gRec.relativeSubpath)"
                                f.folderName = restoredFolderName
                                resolvedZipMgr?.restoreManagedFileToIndex(f)
                            }
                        }
                    }
                case .metadataCommitted:
                    try? fileManager.removeItem(at: itemDir)
                    try? fileManager.removeItem(at: fileURL)
                }
            }
        }
    }

    @discardableResult
    func moveToTrash(
        video: SavedVideo,
        folderName: String,
        downloads: DownloadCenter,
        folderManager: VideoFolderManager
    ) async -> Result<TrashItem, Error> {
        let videoID = video.id

        // 二重タップ・競合防止チェック
        let alreadyProcessing = await MainActor.run { () -> Bool in
            if isProcessing(videoID) { return true }
            setProcessing(videoID, active: true)
            return false
        }
        if alreadyProcessing {
            return .failure(NSError(domain: "TrashManager", code: 409, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("This video is currently being processed.", comment: "")
            ]))
        }

        defer {
            Task { @MainActor in
                self.setProcessing(videoID, active: false)
            }
        }

        let sourceURL = video.fileURL
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            return .failure(NSError(domain: "TrashManager", code: 404, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("Target file was not found on device.", comment: "")
            ]))
        }

        let trashID = UUID()
        let itemDir = itemDirectoryURL(for: trashID)
        let fileName = sourceURL.lastPathComponent
        let destURL = itemDir.appendingPathComponent(fileName)

        // 移動前のキャッシュサムネイルを取得
        let preCachedThumb = VideoThumbnailManager.shared.cachedThumbnail(for: video)
        let retentionPeriod = await MainActor.run { AppSettingsManager.shared.trashRetentionPeriod }

        return await withCheckedContinuation { continuation in
            ioQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: .failure(NSError(domain: "TrashManager", code: 500, userInfo: [
                        NSLocalizedDescriptionKey: NSLocalizedString("Manager was deallocated.", comment: "")
                    ])))
                    return
                }

                do {
                    // 1. ゴミ箱内の一意ディレクトリ作成
                    try self.fileManager.createDirectory(at: itemDir, withIntermediateDirectories: true)

                    // 2. 実ファイルまたはHLSディレクトリ一式をゴミ箱へ移動
                    try self.fileManager.moveItem(at: sourceURL, to: destURL)

                    // 3. サムネイル画像をゴミ箱内ディレクトリに永続保存（再起動後も表示維持）
                    let thumbDest = itemDir.appendingPathComponent("thumbnail.jpg")
                    if let thumb = preCachedThumb,
                       let jpegData = thumb.jpegData(compressionQuality: 0.75) {
                        try? jpegData.write(to: thumbDest, options: .atomic)
                        let cacheKey = trashID.uuidString as NSString
                        let cost = Int(thumb.size.width * thumb.size.height * 4)
                        self.trashThumbnailCache.setObject(thumb, forKey: cacheKey, cost: cost)
                    }

                    let now = Date()
                    let expiresAt = retentionPeriod.timeInterval.map { now.addingTimeInterval($0) }
                    let trashItem = TrashItem(
                        id: trashID,
                        originalVideoID: video.id,
                        originalTitle: video.title,
                        originalRelativePath: video.relativePath,
                        originalFolderName: folderName,
                        format: video.format,
                        byteSize: video.byteSize,
                        sourceHost: video.sourceHost,
                        sourcePageURL: video.sourcePageURL,
                        deletedAt: now,
                        expiresAt: expiresAt,
                        fileName: fileName,
                        isFavorite: video.isFavorite,
                        payloadKind: .video,
                        fileExtension: nil,
                        relativeSubpath: nil
                    )

                    // 4. メタデータ永続化（失敗時は直ちにファイル移動をロールバック）
                    var updatedItems = self.items
                    updatedItems.insert(trashItem, at: 0)
                    do {
                        try self.writeMetadataToDisk(updatedItems)
                    } catch {
                        let rollbackSucceeded = self.safelyRollbackMoveOrPreserve(
                            sourceURL: sourceURL,
                            destURL: destURL,
                            itemDir: itemDir
                        )
                        let errorMsg: String
                        if rollbackSucceeded {
                            errorMsg = String(format: NSLocalizedString("Failed to save metadata; safely cancelled move: %@", comment: ""), error.localizedDescription)
                        } else {
                            errorMsg = String(format: NSLocalizedString("Failed to save metadata and rollback failed. File is preserved in trash directory: %@", comment: ""), error.localizedDescription)
                        }
                        continuation.resume(returning: .failure(NSError(domain: "TrashManager", code: 501, userInfo: [
                            NSLocalizedDescriptionKey: errorMsg
                        ])))
                        return
                    }

                    // 5. メタデータ保存成功後に初めて通常一覧から除外
                    DispatchQueue.main.async {
                        self.items = updatedItems
                        downloads.removeSavedVideoWithoutDeletingFile(id: video.id)
                        folderManager.removeVideoFromFolder(videoID: video.id)
                        VideoThumbnailManager.shared.invalidateCache(for: video)
                        continuation.resume(returning: .success(trashItem))
                    }
                } catch {
                    _ = self.safelyRollbackMoveOrPreserve(
                        sourceURL: sourceURL,
                        destURL: destURL,
                        itemDir: itemDir
                    )
                    continuation.resume(returning: .failure(error))
                }
            }
        }
    }

    // MARK: - 一般ファイルのゴミ箱移動 (Phase F2-B)

    @discardableResult
    func moveToTrash(
        managedFile: ManagedFileItem,
        zipManager: ZipArchiveManager
    ) async -> Result<TrashItem, Error> {
        let fileID = managedFile.id

        // 二重タップ・競合防止チェック
        let alreadyProcessing = await MainActor.run { () -> Bool in
            if isProcessing(fileID) { return true }
            setProcessing(fileID, active: true)
            return false
        }
        if alreadyProcessing {
            return .failure(NSError(domain: "TrashManager", code: 409, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("This file is currently being processed.", comment: "")
            ]))
        }

        defer {
            Task { @MainActor in
                self.setProcessing(fileID, active: false)
            }
        }

        let sourceURL = await MainActor.run { zipManager.resolveFileURL(for: managedFile) }
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            return .failure(NSError(domain: "TrashManager", code: 404, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("Target file was not found on device.", comment: "")
            ]))
        }

        // Vault領域・一時復号領域の保護
        if FileClassification.isInsideVaultOrTempArea(sourceURL) {
            return .failure(NSError(domain: "TrashManager", code: 403, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("Cannot operate on files inside the Private Vault.", comment: "")
            ]))
        }

        let trashID = UUID()
        let itemDir = itemDirectoryURL(for: trashID)
        let fileName = sourceURL.lastPathComponent
        let destURL = itemDir.appendingPathComponent(fileName)

        let retentionPeriod = await MainActor.run { AppSettingsManager.shared.trashRetentionPeriod }

        return await withCheckedContinuation { continuation in
            ioQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: .failure(NSError(domain: "TrashManager", code: 500, userInfo: [
                        NSLocalizedDescriptionKey: NSLocalizedString("Manager was deallocated.", comment: "")
                    ])))
                    return
                }

                do {
                    // 1. ゴミ箱内の一意ディレクトリ作成
                    try self.fileManager.createDirectory(at: itemDir, withIntermediateDirectories: true)

                    // 2. 実ファイルをゴミ箱へ物理移動
                    try self.fileManager.moveItem(at: sourceURL, to: destURL)

                    let now = Date()
                    let expiresAt = retentionPeriod.timeInterval.map { now.addingTimeInterval($0) }
                    let trashItem = TrashItem(
                        id: trashID,
                        originalVideoID: managedFile.id,
                        originalTitle: managedFile.title,
                        originalRelativePath: managedFile.relativePath,
                        originalFolderName: managedFile.folderName,
                        format: .mp4, // 互換性ダミー値（payloadKind == .generalFile で判別）
                        byteSize: managedFile.byteSize,
                        sourceHost: nil,
                        sourcePageURL: nil,
                        deletedAt: now,
                        expiresAt: expiresAt,
                        fileName: fileName,
                        isFavorite: false,
                        payloadKind: .generalFile,
                        fileExtension: managedFile.fileExtension,
                        relativeSubpath: managedFile.relativeSubpath
                    )

                    // 3. メタデータ永続化（失敗時は直ちにファイル移動をロールバック）
                    var updatedItems = self.items
                    updatedItems.insert(trashItem, at: 0)
                    do {
                        try self.writeMetadataToDisk(updatedItems)
                    } catch {
                        let rollbackSucceeded = self.safelyRollbackMoveOrPreserve(
                            sourceURL: sourceURL,
                            destURL: destURL,
                            itemDir: itemDir
                        )
                        let errorMsg: String
                        if rollbackSucceeded {
                            errorMsg = String(format: NSLocalizedString("Failed to save metadata; safely cancelled move: %@", comment: ""), error.localizedDescription)
                        } else {
                            errorMsg = String(format: NSLocalizedString("Failed to save metadata and rollback failed. File is preserved in trash directory: %@", comment: ""), error.localizedDescription)
                        }
                        continuation.resume(returning: .failure(NSError(domain: "TrashManager", code: 501, userInfo: [
                            NSLocalizedDescriptionKey: errorMsg
                        ])))
                        return
                    }

                    // 4. メタデータ保存成功後に ZipArchiveManager から除外
                    DispatchQueue.main.async {
                        self.items = updatedItems
                        zipManager.removeManagedFileFromIndex(id: managedFile.id)
                        continuation.resume(returning: .success(trashItem))
                    }
                } catch {
                    _ = self.safelyRollbackMoveOrPreserve(
                        sourceURL: sourceURL,
                        destURL: destURL,
                        itemDir: itemDir
                    )
                    continuation.resume(returning: .failure(error))
                }
            }
        }
    }

    // MARK: - フォルダ一括ゴミ箱移動 (Phase S3)

    @discardableResult
    func moveToTrash(
        folderName rawName: String,
        downloads: DownloadCenter,
        folderManager: VideoFolderManager,
        zipManager: ZipArchiveManager,
        customRootURL: URL? = nil
    ) async -> Result<TrashItem, Error> {
        let clean = VideoFolderManager.sanitizedFolderName(rawName)
        guard !clean.isEmpty else {
            return .failure(NSError(domain: "TrashManager", code: 400, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("Invalid folder name.", comment: "")
            ]))
        }

        let downloadsRoot: URL
        do {
            if let customRoot = customRootURL {
                try fileManager.createDirectory(at: customRoot, withIntermediateDirectories: true)
                downloadsRoot = customRoot
            } else {
                downloadsRoot = try VideoFolderManager.ensureDownloadsDirectory()
            }
        } catch {
            return .failure(error)
        }

        let sourceFolderURL = downloadsRoot.appendingPathComponent(clean, isDirectory: true)
        guard fileManager.fileExists(atPath: sourceFolderURL.path) else {
            return .failure(NSError(domain: "TrashManager", code: 404, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("Target folder was not found on device.", comment: "")
            ]))
        }

        // Vault領域の保護
        if FileClassification.isInsideVaultOrTempArea(sourceFolderURL) {
            return .failure(NSError(domain: "TrashManager", code: 403, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("Cannot operate on files inside the Private Vault.", comment: "")
            ]))
        }

        let trashID = UUID()

        // 二重タップ・排他ロック
        let alreadyProcessing = await MainActor.run { () -> Bool in
            if isProcessing(trashID) { return true }
            setProcessing(trashID, active: true)
            return false
        }
        if alreadyProcessing {
            return .failure(NSError(domain: "TrashManager", code: 409, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("This item is currently being processed.", comment: "")
            ]))
        }

        defer {
            Task { @MainActor in
                self.setProcessing(trashID, active: false)
            }
        }

        let itemDir = itemDirectoryURL(for: trashID)
        let destFolderURL = itemDir.appendingPathComponent(clean, isDirectory: true)
        let retentionPeriod = await MainActor.run { AppSettingsManager.shared.trashRetentionPeriod }

        // フォルダ配下の全アイテム収集
        let affectedVideos = await MainActor.run {
            downloads.saved.filter { folderManager.folderName(for: $0) == clean }
        }
        let affectedGeneralFiles = await MainActor.run {
            zipManager.managedFiles.filter { $0.folderName == clean || $0.normalizedRelativePath.hasPrefix("Documents/Downloads/\(clean)/") }
        }
        let managedFileURLs: [UUID: URL] = await MainActor.run {
            var dict: [UUID: URL] = [:]
            for f in affectedGeneralFiles {
                dict[f.id] = zipManager.resolveFileURL(for: f)
            }
            return dict
        }

        return await withCheckedContinuation { continuation in
            ioQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: .failure(NSError(domain: "TrashManager", code: 500, userInfo: [
                        NSLocalizedDescriptionKey: NSLocalizedString("Manager was deallocated.", comment: "")
                    ])))
                    return
                }

                do {
                    // 1. ゴミ箱内一意ディレクトリ作成
                    try self.fileManager.createDirectory(at: itemDir, withIntermediateDirectories: true)

                    // 2. 物理走査：未登録物理ファイル・空サブフォルダ構造・総容量の算出
                    var registeredSourcePaths = Set<String>()
                    var videoRecords: [TrashFolderVideoRecord] = []
                    var externalHLSRecords: [TrashFolderExternalHLSAssetRecord] = []

                    let sourcePrefix = sourceFolderURL.standardizedFileURL.resolvingSymlinksInPath().path
                    let prefixWithSlash = sourcePrefix.hasSuffix("/") ? sourcePrefix : sourcePrefix + "/"

                    func resolveVideoSourceURL(_ video: SavedVideo) -> URL {
                        if let customRoot = customRootURL {
                            let norm = FileClassification.normalizedRelativePath(video.relativePath)
                            let prefix = "Documents/Downloads/"
                            if norm.hasPrefix(prefix) {
                                let subRel = String(norm.dropFirst(prefix.count))
                                return customRoot.appendingPathComponent(subRel)
                            }
                        }
                        return video.fileURL
                    }

                    func resolveManagedFileSourceURL(_ file: ManagedFileItem) -> URL {
                        if let customRoot = customRootURL {
                            let norm = file.normalizedRelativePath
                            let prefix = "Documents/Downloads/"
                            if norm.hasPrefix(prefix) {
                                let subRel = String(norm.dropFirst(prefix.count))
                                return customRoot.appendingPathComponent(subRel)
                            }
                        }
                        return managedFileURLs[file.id] ?? downloadsRoot.appendingPathComponent(clean).appendingPathComponent(file.relativeSubpath ?? file.title)
                    }

                    for v in affectedVideos {
                        let vURL = resolveVideoSourceURL(v).standardizedFileURL.resolvingSymlinksInPath()
                        let vPath = vURL.path
                        registeredSourcePaths.insert(vPath)
                        if vPath.hasPrefix(prefixWithSlash) {
                            let sub = String(vPath.dropFirst(prefixWithSlash.count))
                            videoRecords.append(TrashFolderVideoRecord(video: v, relativeSubpath: sub))
                        } else {
                            // HLS等の外部パッケージ
                            if v.isHLS && self.fileManager.fileExists(atPath: vURL.path) {
                                let extPkgName = "\(v.id.uuidString).movpkg"
                                externalHLSRecords.append(TrashFolderExternalHLSAssetRecord(
                                    videoID: v.id,
                                    originalRelativePath: v.relativePath,
                                    trashPackageSubpath: extPkgName
                                ))
                            }
                            videoRecords.append(TrashFolderVideoRecord(video: v, relativeSubpath: v.fileURL.lastPathComponent))
                        }
                    }

                    var generalFileRecords: [TrashFolderGeneralFileRecord] = []
                    for f in affectedGeneralFiles {
                        let fURL = resolveManagedFileSourceURL(f).standardizedFileURL.resolvingSymlinksInPath()
                        let fCanon = fURL.path
                        registeredSourcePaths.insert(fCanon)
                        let sub = fCanon.hasPrefix(prefixWithSlash) ? String(fCanon.dropFirst(prefixWithSlash.count)) : (f.relativeSubpath ?? f.title)
                        generalFileRecords.append(TrashFolderGeneralFileRecord(file: f, relativeSubpath: sub))
                    }

                    var unregisteredRecords: [TrashFolderUnregisteredFileRecord] = []
                    var emptySubdirectories: [String] = []
                    var totalByteSize: Int64 = 0

                    if let enumerator = self.fileManager.enumerator(
                        at: sourceFolderURL,
                        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
                        options: [.skipsHiddenFiles]
                    ) {
                        for case let fileURL as URL in enumerator {
                            let rVals = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
                            let canon = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
                            let sub = canon.hasPrefix(prefixWithSlash) ? String(canon.dropFirst(prefixWithSlash.count)) : fileURL.lastPathComponent

                            if rVals?.isDirectory == true {
                                // .movpkg (HLSパッケージ) の内部ファイルは単一パッケージとして扱い再帰下降しない
                                let lowerExt = fileURL.pathExtension.lowercased()
                                if lowerExt == "movpkg" || fileURL.lastPathComponent.hasSuffix(".movpkg") {
                                    enumerator.skipDescendants()
                                    if !registeredSourcePaths.contains(canon) {
                                        let size = Int64(rVals?.fileSize ?? 0)
                                        totalByteSize += size
                                        unregisteredRecords.append(TrashFolderUnregisteredFileRecord(relativeSubpath: sub, byteSize: size))
                                    }
                                    continue
                                }

                                if let contents = try? self.fileManager.contentsOfDirectory(atPath: fileURL.path), contents.isEmpty {
                                    emptySubdirectories.append(sub)
                                }
                            } else if rVals?.isRegularFile == true {
                                let size = Int64(rVals?.fileSize ?? 0)
                                totalByteSize += size
                                if !registeredSourcePaths.contains(canon) {
                                    unregisteredRecords.append(TrashFolderUnregisteredFileRecord(relativeSubpath: sub, byteSize: size))
                                }
                            }
                        }
                    }

                    // 3. マニフェスト作成とアトミック保存・検証
                    let manifest = FolderTrashManifest(
                        version: FolderTrashManifest.currentVersion,
                        folderID: trashID,
                        originalFolderName: clean,
                        deletedAt: Date(),
                        totalByteSize: totalByteSize,
                        videos: videoRecords,
                        generalFiles: generalFileRecords,
                        unregisteredFiles: unregisteredRecords,
                        emptySubdirectories: emptySubdirectories,
                        externalHLSAssets: externalHLSRecords.isEmpty ? nil : externalHLSRecords
                    )
                    let manifestURL = itemDir.appendingPathComponent("folder_manifest.json")
                    let mData = try JSONEncoder().encode(manifest)
                    try mData.write(to: manifestURL, options: .atomic)

                    // 書き込み検証
                    guard let verifyData = try? Data(contentsOf: manifestURL),
                          (try? JSONDecoder().decode(FolderTrashManifest.self, from: verifyData)) != nil else {
                        throw NSError(domain: "TrashManager", code: 500, userInfo: [
                            NSLocalizedDescriptionKey: NSLocalizedString("Failed to verify folder manifest integrity.", comment: "")
                        ])
                    }

                    // 4. トランザクション記録: manifestVerified
                    var tx = TrashTransaction(
                        transactionID: UUID(),
                        trashID: trashID,
                        folderName: clean,
                        operation: .moveToTrash,
                        phase: .manifestVerified,
                        sourcePath: sourceFolderURL.path,
                        destinationPath: destFolderURL.path,
                        timestamp: Date()
                    )
                    self.recordTransaction(tx)

                    if let hook = self.faultInjectionBeforePhysicalMove {
                        try hook()
                    }

                    // 5. 物理ディレクトリ移動
                    try self.fileManager.moveItem(at: sourceFolderURL, to: destFolderURL)

                    // 外部HLSパッケージ移動（存在する場合）
                    if !externalHLSRecords.isEmpty {
                        let hlsDir = itemDir.appendingPathComponent("external_hls", isDirectory: true)
                        try? self.fileManager.createDirectory(at: hlsDir, withIntermediateDirectories: true)
                        for extRecord in externalHLSRecords {
                            let origURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(extRecord.originalRelativePath)
                            let hlsDest = hlsDir.appendingPathComponent(extRecord.trashPackageSubpath)
                            if self.fileManager.fileExists(atPath: origURL.path) {
                                try? self.fileManager.moveItem(at: origURL, to: hlsDest)
                            }
                        }
                    }

                    // 代表サムネイル保存
                    if let firstVid = affectedVideos.first {
                        let thumbDest = itemDir.appendingPathComponent("thumbnail.jpg")
                        if let cached = VideoThumbnailManager.shared.cachedThumbnail(for: firstVid),
                           let jData = cached.jpegData(compressionQuality: 0.75) {
                            try? jData.write(to: thumbDest, options: .atomic)
                            self.trashThumbnailCache.setObject(cached, forKey: trashID.uuidString as NSString)
                        }
                    }

                    // トランザクション更新: physicalMoved
                    tx.phase = .physicalMoved
                    self.recordTransaction(tx)

                    if let hook = self.faultInjectionBeforeMetadataCommit {
                        try hook()
                    }

                    // 6. メタデータ永続化
                    let now = Date()
                    let expiresAt = retentionPeriod.timeInterval.map { now.addingTimeInterval($0) }
                    let totalCount = videoRecords.count + generalFileRecords.count + unregisteredRecords.count

                    let trashItem = TrashItem(
                        id: trashID,
                        originalVideoID: trashID,
                        originalTitle: clean,
                        originalRelativePath: "Documents/Downloads/\(clean)",
                        originalFolderName: "",
                        format: .mp4,
                        byteSize: totalByteSize,
                        sourceHost: nil,
                        sourcePageURL: nil,
                        deletedAt: now,
                        expiresAt: expiresAt,
                        fileName: clean,
                        isFavorite: false,
                        payloadKind: .folder,
                        fileExtension: nil,
                        relativeSubpath: nil,
                        folderItemCount: totalCount
                    )

                    var updatedItems = self.items
                    updatedItems.insert(trashItem, at: 0)

                    do {
                        try self.writeMetadataToDisk(updatedItems)
                    } catch {
                        // メタデータ保存失敗時は物理ロールバック
                        try? self.fileManager.moveItem(at: destFolderURL, to: sourceFolderURL)
                        try? self.fileManager.removeItem(at: itemDir)
                        self.removeTransaction(trashID: trashID)
                        continuation.resume(returning: .failure(error))
                        return
                    }

                    // トランザクション更新: metadataCommitted
                    tx.phase = .metadataCommitted
                    self.recordTransaction(tx)

                    // 7. インデックス除外と後処理
                    DispatchQueue.main.async {
                        self.items = updatedItems
                        for v in affectedVideos {
                            downloads.removeSavedVideoWithoutDeletingFile(id: v.id)
                            folderManager.removeVideoFromFolder(videoID: v.id)
                            VideoThumbnailManager.shared.invalidateCache(for: v)
                        }
                        for f in affectedGeneralFiles {
                            zipManager.removeManagedFileFromIndex(id: f.id)
                        }
                        folderManager.unregisterLogicalFolderIfNeeded(clean)

                        self.removeTransaction(trashID: trashID)
                        continuation.resume(returning: .success(trashItem))
                    }
                } catch {
                    // ロールバック
                    if self.fileManager.fileExists(atPath: destFolderURL.path) && !self.fileManager.fileExists(atPath: sourceFolderURL.path) {
                        try? self.fileManager.moveItem(at: destFolderURL, to: sourceFolderURL)
                    }
                    try? self.fileManager.removeItem(at: itemDir)
                    self.removeTransaction(trashID: trashID)
                    continuation.resume(returning: .failure(error))
                }
            }
        }
    }

    // MARK: - 動画の復元（非同期・ロールバック完備・相対パス再構築）

    @discardableResult
    func restore(
        item: TrashItem,
        downloads: DownloadCenter,
        folderManager: VideoFolderManager
    ) async -> Result<SavedVideo, Error> {
        let itemID = item.id

        // 二重タップ・競合防止チェック
        let alreadyProcessing = await MainActor.run { () -> Bool in
            if isProcessing(itemID) { return true }
            setProcessing(itemID, active: true)
            return false
        }
        if alreadyProcessing {
            return .failure(NSError(domain: "TrashManager", code: 409, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("This video is currently being processed.", comment: "")
            ]))
        }

        defer {
            Task { @MainActor in
                self.setProcessing(itemID, active: false)
            }
        }

        let sourceURL = itemFileURL(for: item)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            return .failure(NSError(domain: "TrashManager", code: 404, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("Actual file in Trash was not found.", comment: "")
            ]))
        }

        return await withCheckedContinuation { continuation in
            ioQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: .failure(NSError(domain: "TrashManager", code: 500, userInfo: [
                        NSLocalizedDescriptionKey: NSLocalizedString("Manager was deallocated.", comment: "")
                    ])))
                    return
                }

                do {
                    let docs = self.fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    let downloadsDir = docs.appendingPathComponent("Downloads", isDirectory: true)
                    try self.fileManager.createDirectory(at: downloadsDir, withIntermediateDirectories: true)

                    let destURL: URL
                    let cleanFolder = VideoFolderManager.sanitizedFolderName(item.originalFolderName)

                    if item.format == .hls {
                        // HLS（.movpkg一式）の復元:
                        let originalFull = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                            .appendingPathComponent(item.originalRelativePath)
                        let parentDir = originalFull.deletingLastPathComponent()

                        let baseTargetDir: URL
                        if self.fileManager.fileExists(atPath: parentDir.path) || (try? self.fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)) != nil {
                            baseTargetDir = parentDir
                        } else {
                            baseTargetDir = downloadsDir
                        }

                        let ext = sourceURL.pathExtension
                        let baseName = sourceURL.deletingPathExtension().lastPathComponent
                        destURL = FileNaming.uniqueDestination(
                            in: baseTargetDir,
                            baseName: baseName.isEmpty ? "HLSVideo" : baseName,
                            fileExtension: ext.isEmpty ? "movpkg" : ext
                        )
                    } else {
                        // MP4 / MOV 等の復元:
                        let targetDir: URL
                        if !cleanFolder.isEmpty {
                            let folderDir = downloadsDir.appendingPathComponent(cleanFolder, isDirectory: true)
                            try self.fileManager.createDirectory(at: folderDir, withIntermediateDirectories: true)
                            targetDir = folderDir
                        } else {
                            targetDir = downloadsDir
                        }

                        let ext = sourceURL.pathExtension
                        let baseName = sourceURL.deletingPathExtension().lastPathComponent
                        destURL = FileNaming.uniqueDestination(
                            in: targetDir,
                            baseName: baseName.isEmpty ? "RestoredVideo" : baseName,
                            fileExtension: ext.isEmpty ? item.format.rawValue : ext
                        )
                    }

                    // 新しい相対パスを計算
                    guard let newRelativePath = SavedVideo.relativePath(for: destURL) else {
                        throw NSError(domain: "TrashManager", code: 500, userInfo: [
                            NSLocalizedDescriptionKey: NSLocalizedString("Failed to determine destination path for restore.", comment: "")
                        ])
                    }

                    // 1. 実ファイルを復元先へ移動
                    try self.fileManager.moveItem(at: sourceURL, to: destURL)

                    // 2. メタデータから削除して保存（失敗時はロールバック）
                    var updatedItems = self.items
                    updatedItems.removeAll { $0.id == item.id }
                    do {
                        try self.writeMetadataToDisk(updatedItems)
                    } catch {
                        try? self.fileManager.moveItem(at: destURL, to: sourceURL)
                        continuation.resume(returning: .failure(NSError(domain: "TrashManager", code: 502, userInfo: [
                            NSLocalizedDescriptionKey: String(format: NSLocalizedString("Failed to update metadata; safely cancelled restore: %@", comment: ""), error.localizedDescription)
                        ])))
                        return
                    }

                    // 3. ゴミ箱一時ディレクトリ（サムネイル画像含む）を片付け
                    let itemDir = self.itemDirectoryURL(for: item.id)
                    try? self.fileManager.removeItem(at: itemDir)
                    self.trashThumbnailCache.removeObject(forKey: item.id.uuidString as NSString)

                    // 4. メタデータ永続化成功後に通常一覧とフォルダ管理へ登録
                    let restoredVideo = SavedVideo(
                        id: item.originalVideoID,
                        title: item.originalTitle,
                        relativePath: newRelativePath,
                        format: item.format,
                        sourceHost: item.sourceHost,
                        createdAt: Date(),
                        byteSize: (try? self.fileManager.attributesOfItem(atPath: destURL.path)[.size] as? Int64) ?? item.byteSize ?? 0,
                        sourcePageURL: item.sourcePageURL,
                        isFavorite: item.isFavorite ?? false
                    )

                    DispatchQueue.main.async {
                        self.items = updatedItems
                        downloads.restoreSavedVideo(restoredVideo)
                        if !cleanFolder.isEmpty {
                            folderManager.restoreVideoToFolder(restoredVideo, targetFolder: cleanFolder)
                        }
                        continuation.resume(returning: .success(restoredVideo))
                    }
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
    }

    // MARK: - 一般ファイルの復元 (Phase F2-B)

    @discardableResult
    func restoreGeneralFile(
        item: TrashItem,
        zipManager: ZipArchiveManager,
        folderManager: VideoFolderManager
    ) async -> Result<ManagedFileItem, Error> {
        guard item.isGeneralFile else {
            return .failure(NSError(domain: "TrashManager", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "Item is not a general file."
            ]))
        }

        let itemID = item.id

        // 二重タップ・競合防止チェック
        let alreadyProcessing = await MainActor.run { () -> Bool in
            if isProcessing(itemID) { return true }
            setProcessing(itemID, active: true)
            return false
        }
        if alreadyProcessing {
            return .failure(NSError(domain: "TrashManager", code: 409, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("This file is currently being processed.", comment: "")
            ]))
        }

        defer {
            Task { @MainActor in
                self.setProcessing(itemID, active: false)
            }
        }

        let sourceURL = itemFileURL(for: item)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            return .failure(NSError(domain: "TrashManager", code: 404, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("Actual file in Trash was not found.", comment: "")
            ]))
        }

        let downloadsDir = await MainActor.run { zipManager.downloadsRootURL }

        return await withCheckedContinuation { continuation in
            ioQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: .failure(NSError(domain: "TrashManager", code: 500, userInfo: [
                        NSLocalizedDescriptionKey: NSLocalizedString("Manager was deallocated.", comment: "")
                    ])))
                    return
                }

                do {
                    try self.fileManager.createDirectory(at: downloadsDir, withIntermediateDirectories: true)

                    let cleanFolder = VideoFolderManager.sanitizedFolderName(item.originalFolderName)
                    let targetDir: URL
                    if !cleanFolder.isEmpty {
                        let folderDir = downloadsDir.appendingPathComponent(cleanFolder, isDirectory: true)
                        if !self.fileManager.fileExists(atPath: folderDir.path) {
                            try self.fileManager.createDirectory(at: folderDir, withIntermediateDirectories: true)
                        }
                        DispatchQueue.main.async {
                            folderManager.registerLogicalFolderIfNeeded(cleanFolder)
                        }

                        if let subpath = item.relativeSubpath, !subpath.isEmpty {
                            let subDir = folderDir.appendingPathComponent(subpath, isDirectory: true)
                            try self.fileManager.createDirectory(at: subDir, withIntermediateDirectories: true)
                            targetDir = subDir
                        } else {
                            targetDir = folderDir
                        }
                    } else {
                        targetDir = downloadsDir
                    }

                    let ext = item.fileExtension ?? sourceURL.pathExtension
                    let baseName = item.originalTitle.isEmpty ? sourceURL.deletingPathExtension().lastPathComponent : item.originalTitle
                    // 上書き禁止：同名存在時は (1) 等を付与して安全共存
                    let destURL = FileNaming.uniqueDestination(
                        in: targetDir,
                        baseName: baseName,
                        fileExtension: ext.isEmpty ? "bin" : ext
                    )

                    guard let newRelativePath = FileClassification.normalizedContainerRelativePath(for: destURL, customRootURL: downloadsDir) else {
                        throw NSError(domain: "TrashManager", code: 500, userInfo: [
                            NSLocalizedDescriptionKey: NSLocalizedString("Failed to determine destination path for restore.", comment: "")
                        ])
                    }

                    // 1. 実ファイルを復元先へ移動
                    try self.fileManager.moveItem(at: sourceURL, to: destURL)

                    // 2. メタデータから削除して保存（失敗時はロールバック）
                    var updatedItems = self.items
                    updatedItems.removeAll { $0.id == item.id }
                    do {
                        try self.writeMetadataToDisk(updatedItems)
                    } catch {
                        try? self.fileManager.moveItem(at: destURL, to: sourceURL)
                        continuation.resume(returning: .failure(NSError(domain: "TrashManager", code: 502, userInfo: [
                            NSLocalizedDescriptionKey: String(format: NSLocalizedString("Failed to update metadata; safely cancelled restore: %@", comment: ""), error.localizedDescription)
                        ])))
                        return
                    }

                    // 3. ゴミ箱一時ディレクトリを片付け
                    let itemDir = self.itemDirectoryURL(for: item.id)
                    try? self.fileManager.removeItem(at: itemDir)
                    self.trashThumbnailCache.removeObject(forKey: item.id.uuidString as NSString)

                    // 4. メタデータ永続化成功後に ZipArchiveManager へ復元登録（UUIDは100%維持！）
                    let restoredFile = ManagedFileItem(
                        id: item.originalVideoID,
                        title: destURL.deletingPathExtension().lastPathComponent,
                        relativePath: newRelativePath,
                        fileExtension: ext,
                        createdAt: Date(),
                        byteSize: (try? self.fileManager.attributesOfItem(atPath: destURL.path)[.size] as? Int64) ?? item.byteSize ?? 0,
                        folderName: cleanFolder,
                        relativeSubpath: item.relativeSubpath
                    )

                    DispatchQueue.main.async {
                        self.items = updatedItems
                        zipManager.restoreManagedFileToIndex(restoredFile)
                        continuation.resume(returning: .success(restoredFile))
                    }
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
    }

    // MARK: - フォルダの復元（非同期・安全な競合解決・ロールバック完備） (Phase S3)

    @discardableResult
    func restoreFolder(
        item: TrashItem,
        downloads: DownloadCenter,
        folderManager: VideoFolderManager,
        zipManager: ZipArchiveManager,
        resolution: FolderRestoreConflictResolution = .rename,
        customRootURL: URL? = nil
    ) async -> Result<String, Error> {
        guard item.isFolder else {
            return .failure(NSError(domain: "TrashManager", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "Item is not a folder."
            ]))
        }

        let itemID = item.id
        let alreadyProcessing = await MainActor.run { () -> Bool in
            if isProcessing(itemID) { return true }
            setProcessing(itemID, active: true)
            return false
        }
        if alreadyProcessing {
            return .failure(NSError(domain: "TrashManager", code: 409, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("This item is currently being processed.", comment: "")
            ]))
        }

        defer {
            Task { @MainActor in
                self.setProcessing(itemID, active: false)
            }
        }

        let itemDir = itemDirectoryURL(for: itemID)
        let sourceFolderInTrash = itemDir.appendingPathComponent(item.fileName, isDirectory: true)

        guard fileManager.fileExists(atPath: sourceFolderInTrash.path) else {
            return .failure(NSError(domain: "TrashManager", code: 404, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("Actual folder in Trash was not found.", comment: "")
            ]))
        }

        guard let manifest = loadFolderManifest(for: itemID) else {
            return .failure(NSError(domain: "TrashManager", code: 500, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("Folder manifest is corrupted or missing.", comment: "")
            ]))
        }

        let downloadsRoot: URL
        do {
            if let customRoot = customRootURL {
                try fileManager.createDirectory(at: customRoot, withIntermediateDirectories: true)
                downloadsRoot = customRoot
            } else {
                downloadsRoot = try VideoFolderManager.ensureDownloadsDirectory()
            }
        } catch {
            return .failure(error)
        }

        let cleanOriginal = VideoFolderManager.sanitizedFolderName(manifest.originalFolderName.isEmpty ? item.fileName : manifest.originalFolderName)
        var targetFolderName = cleanOriginal
        let initialTargetURL = downloadsRoot.appendingPathComponent(cleanOriginal, isDirectory: true)

        // 競合チェック
        if fileManager.fileExists(atPath: initialTargetURL.path) {
            switch resolution {
            case .cancel:
                return .failure(NSError(domain: "TrashManager", code: 409, userInfo: [
                    NSLocalizedDescriptionKey: NSLocalizedString("Restore cancelled due to name conflict.", comment: "")
                ]))
            case .rename:
                var counter = 1
                while true {
                    let candidate = "\(cleanOriginal) (\(counter))"
                    let candURL = downloadsRoot.appendingPathComponent(candidate, isDirectory: true)
                    if !fileManager.fileExists(atPath: candURL.path) {
                        targetFolderName = candidate
                        break
                    }
                    counter += 1
                }
            }
        }

        let targetFolderURL = downloadsRoot.appendingPathComponent(targetFolderName, isDirectory: true)

        return await withCheckedContinuation { continuation in
            ioQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: .failure(NSError(domain: "TrashManager", code: 500, userInfo: [
                        NSLocalizedDescriptionKey: NSLocalizedString("Manager was deallocated.", comment: "")
                    ])))
                    return
                }

                // 1. トランザクション記録
                var tx = TrashTransaction(
                    transactionID: UUID(),
                    trashID: itemID,
                    folderName: targetFolderName,
                    operation: .restore,
                    phase: .manifestVerified,
                    sourcePath: sourceFolderInTrash.path,
                    destinationPath: targetFolderURL.path,
                    timestamp: Date()
                )
                self.recordTransaction(tx)

                if let hook = self.faultInjectionBeforeRestorePhysicalMove {
                    do { try hook() } catch {
                        self.removeTransaction(trashID: itemID)
                        continuation.resume(returning: .failure(error))
                        return
                    }
                }

                do {
                    // 2. 物理ディレクトリを復元先へ移動
                    try self.fileManager.moveItem(at: sourceFolderInTrash, to: targetFolderURL)

                    // 外部HLSパッケージの復元
                    if let externalHLS = manifest.externalHLSAssets {
                        let hlsDir = itemDir.appendingPathComponent("external_hls", isDirectory: true)
                        for extRec in externalHLS {
                            let extSource = hlsDir.appendingPathComponent(extRec.trashPackageSubpath)
                            let origURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(extRec.originalRelativePath)
                            if self.fileManager.fileExists(atPath: extSource.path) {
                                try? self.fileManager.createDirectory(at: origURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                                try? self.fileManager.moveItem(at: extSource, to: origURL)
                            }
                        }
                    }

                    tx.phase = .physicalMoved
                    self.recordTransaction(tx)

                    // 3. メタデータから削除
                    var updatedItems = self.items
                    updatedItems.removeAll { $0.id == itemID }
                    do {
                        try self.writeMetadataToDisk(updatedItems)
                    } catch {
                        // メタデータ保存失敗時はゴミ箱へロールバック
                        try? self.fileManager.moveItem(at: targetFolderURL, to: sourceFolderInTrash)
                        self.removeTransaction(trashID: itemID)
                        continuation.resume(returning: .failure(error))
                        return
                    }

                    tx.phase = .metadataCommitted
                    self.recordTransaction(tx)

                    // 4. ゴミ箱一時領域を消去
                    try? self.fileManager.removeItem(at: itemDir)
                    self.trashThumbnailCache.removeObject(forKey: itemID.uuidString as NSString)

                    // 5. 各インデックスへ再登録（UUIDおよびメタデータを100%保持）
                    DispatchQueue.main.async {
                        self.items = updatedItems
                        folderManager.registerLogicalFolderIfNeeded(targetFolderName)

                        for vRec in manifest.videos {
                            var v = vRec.video
                            if v.isHLS {
                                v.relativePath = vRec.video.relativePath
                            } else {
                                v.relativePath = "Documents/Downloads/\(targetFolderName)/\(vRec.relativeSubpath)"
                            }
                            downloads.restoreSavedVideo(v)
                            folderManager.restoreVideoToFolder(v, targetFolder: targetFolderName)
                        }

                        for fRec in manifest.generalFiles {
                            var f = fRec.file
                            f.relativePath = "Documents/Downloads/\(targetFolderName)/\(fRec.relativeSubpath)"
                            f.folderName = targetFolderName
                            zipManager.restoreManagedFileToIndex(f)
                        }

                        self.removeTransaction(trashID: itemID)
                        continuation.resume(returning: .success(targetFolderName))
                    }
                } catch {
                    // ロールバック
                    if self.fileManager.fileExists(atPath: targetFolderURL.path) && !self.fileManager.fileExists(atPath: sourceFolderInTrash.path) {
                        try? self.fileManager.moveItem(at: targetFolderURL, to: sourceFolderInTrash)
                    }
                    self.removeTransaction(trashID: itemID)
                    continuation.resume(returning: .failure(error))
                }
            }
        }
    }

    // MARK: - 動画・一般ファイルの統合復元 (Phase F2-B & S3)

    enum RestoreResult {
        case video(SavedVideo)
        case generalFile(ManagedFileItem)
        case folder(String)
    }

    @discardableResult
    func restore(
        item: TrashItem,
        downloads: DownloadCenter,
        folderManager: VideoFolderManager,
        zipManager: ZipArchiveManager
    ) async -> Result<RestoreResult, Error> {
        if item.isFolder {
            let res = await restoreFolder(item: item, downloads: downloads, folderManager: folderManager, zipManager: zipManager)
            switch res {
            case .success(let folderName): return .success(.folder(folderName))
            case .failure(let err): return .failure(err)
            }
        } else if item.isGeneralFile {
            let res = await restoreGeneralFile(item: item, zipManager: zipManager, folderManager: folderManager)
            switch res {
            case .success(let file): return .success(.generalFile(file))
            case .failure(let err): return .failure(err)
            }
        } else {
            let res = await restore(item: item, downloads: downloads, folderManager: folderManager)
            switch res {
            case .success(let video): return .success(.video(video))
            case .failure(let err): return .failure(err)
            }
        }
    }

    // MARK: - 個別の完全削除（非同期・サムネイルも消去）

    @discardableResult
    func deletePermanently(item: TrashItem) async -> Result<Void, Error> {
        let itemID = item.id

        let alreadyProcessing = await MainActor.run { () -> Bool in
            if isProcessing(itemID) { return true }
            setProcessing(itemID, active: true)
            return false
        }
        if alreadyProcessing {
            return .failure(NSError(domain: "TrashManager", code: 409, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("This file is currently being processed.", comment: "")
            ]))
        }

        defer {
            Task { @MainActor in
                self.setProcessing(itemID, active: false)
            }
        }

        return await withCheckedContinuation { continuation in
            ioQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: .failure(NSError(domain: "TrashManager", code: 500, userInfo: [
                        NSLocalizedDescriptionKey: NSLocalizedString("Manager was deallocated.", comment: "")
                    ])))
                    return
                }

                let itemDir = self.itemDirectoryURL(for: item.id)
                do {
                    // 1. 実ファイルおよびサムネイルを含むアイテムディレクトリを一括完全削除
                    if self.fileManager.fileExists(atPath: itemDir.path) {
                        try self.fileManager.removeItem(at: itemDir)
                    }
                    self.trashThumbnailCache.removeObject(forKey: item.id.uuidString as NSString)
                    self.removeTransaction(trashID: item.id)

                    // 2. メタデータを更新
                    var updatedItems = self.items
                    updatedItems.removeAll { $0.id == item.id }
                    try self.writeMetadataToDisk(updatedItems)

                    DispatchQueue.main.async {
                        self.items = updatedItems
                        continuation.resume(returning: .success(()))
                    }
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
    }

    // MARK: - ゴミ箱を空にする（非同期・サムネイルも一括消去）

    @discardableResult
    func emptyTrash() async -> Result<Void, Error> {
        let currentItems = await MainActor.run { items }
        guard !currentItems.isEmpty else { return .success(()) }

        return await withCheckedContinuation { continuation in
            ioQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: .failure(NSError(domain: "TrashManager", code: 500, userInfo: [
                        NSLocalizedDescriptionKey: NSLocalizedString("Manager was deallocated.", comment: "")
                    ])))
                    return
                }

                var remainingItems: [TrashItem] = []
                var firstError: Error?

                for item in currentItems {
                    let itemDir = self.itemDirectoryURL(for: item.id)
                    do {
                        if self.fileManager.fileExists(atPath: itemDir.path) {
                            try self.fileManager.removeItem(at: itemDir)
                        }
                        self.trashThumbnailCache.removeObject(forKey: item.id.uuidString as NSString)
                        self.removeTransaction(trashID: item.id)
                    } catch {
                        firstError = error
                        remainingItems.append(item)
                    }
                }

                do {
                    try self.writeMetadataToDisk(remainingItems)
                } catch {
                    if firstError == nil { firstError = error }
                }

                DispatchQueue.main.async {
                    self.items = remainingItems
                    if let err = firstError {
                        continuation.resume(returning: .failure(err))
                    } else {
                        continuation.resume(returning: .success(()))
                    }
                }
            }
        }
    }

    // MARK: - 自動期限切れパージ（設定保持期間経過・競合保護）

    func purgeExpiredItems() {
        ioQueue.async { [weak self] in
            guard let self = self else { return }

            // 期限切れかつ現在UI操作中ではないアイテムを抽出（自動削除しないアイテムは除外）
            let candidates = self.items.filter { $0.isExpired }
            guard !candidates.isEmpty else { return }

            var successfullyDeletedIDs = Set<UUID>()
            for item in candidates {
                // UIで復元・削除操作中のアイテムはスキップして競合防止
                if self.isProcessing(item.id) { continue }

                // ユーザーファイル保護: マニフェスト破損・欠損のフォルダは自動削除から厳格に除外
                if item.isFolder {
                    guard let _ = self.loadFolderManifest(for: item.id) else {
                        print("[TrashManager] WARNING: Skipping auto-purge for folder item \(item.id) because manifest is corrupted or missing. Preserving files to prevent data loss.")
                        continue
                    }
                }

                let itemDir = self.itemDirectoryURL(for: item.id)
                do {
                    if self.fileManager.fileExists(atPath: itemDir.path) {
                        try self.fileManager.removeItem(at: itemDir)
                    }
                    self.trashThumbnailCache.removeObject(forKey: item.id.uuidString as NSString)
                    self.removeTransaction(trashID: item.id)
                    successfullyDeletedIDs.insert(item.id)
                } catch {
                    print("[TrashManager] Failed to auto-purge item \(item.id): \(error)")
                }
            }

            guard !successfullyDeletedIDs.isEmpty else { return }

            var updatedItems = self.items
            updatedItems.removeAll { successfullyDeletedIDs.contains($0.id) }
            try? self.writeMetadataToDisk(updatedItems)

            DispatchQueue.main.async {
                self.items = updatedItems
            }
        }
    }

    // MARK: - メタデータ永続化と安全保護機構

    private func writeMetadataToDisk(_ list: [TrashItem]) throws {
        let data = try JSONEncoder().encode(list)
        try data.write(to: metadataFileURL, options: .atomic)
    }

    /// メタデータを安全に読み込み。
    /// 破損時やデコード失敗時でも「ゴミ箱が空」として扱わず、残存ファイルを保護・復元する。
    private func loadMetadataSafely() {
        let fileURL = metadataFileURL
        guard fileManager.fileExists(atPath: fileURL.path) else {
            items = scanAndRecoverOrphanedFiles()
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let loaded = try JSONDecoder().decode([TrashItem].self, from: data)
            items = loaded
        } catch {
            print("[TrashManager] Metadata decoding failed: \(error). Preserving existing trash files.")
            let backupURL = fileURL.deletingLastPathComponent()
                .appendingPathComponent("trash_metadata_corrupted_\(Int(Date().timeIntervalSince1970)).json")
            try? fileManager.copyItem(at: fileURL, to: backupURL)

            items = scanAndRecoverOrphanedFiles()
        }
    }

    /// メタデータ損失時やファイル不整合時に、Trash/ ディレクトリ内の実ファイルから安全に復旧する
    private func scanAndRecoverOrphanedFiles() -> [TrashItem] {
        let trashDir = trashDirectoryURL
        guard let subdirs = try? fileManager.contentsOfDirectory(at: trashDir, includingPropertiesForKeys: [.creationDateKey]) else {
            return []
        }

        var recovered: [TrashItem] = []
        for dir in subdirs where dir.hasDirectoryPath {
            if dir.lastPathComponent == "transactions" { continue }
            guard let id = UUID(uuidString: dir.lastPathComponent) else { continue }

            // フォルダマニフェストが存在する場合はフォルダアイテムとして救済
            let manifestURL = dir.appendingPathComponent("folder_manifest.json")
            if fileManager.fileExists(atPath: manifestURL.path),
               let mData = try? Data(contentsOf: manifestURL),
               let manifest = try? JSONDecoder().decode(FolderTrashManifest.self, from: mData) {
                let count = manifest.videos.count + manifest.generalFiles.count + manifest.unregisteredFiles.count
                let item = TrashItem(
                    id: id,
                    originalVideoID: manifest.folderID,
                    originalTitle: manifest.originalFolderName,
                    originalRelativePath: "Documents/Downloads/\(manifest.originalFolderName)",
                    originalFolderName: "",
                    format: .mp4,
                    byteSize: manifest.totalByteSize,
                    sourceHost: nil,
                    sourcePageURL: nil,
                    deletedAt: manifest.deletedAt,
                    expiresAt: nil, // 救済ファイルは保護のため自動削除なし
                    fileName: manifest.originalFolderName,
                    isFavorite: false,
                    payloadKind: .folder,
                    fileExtension: nil,
                    relativeSubpath: nil,
                    folderItemCount: count
                )
                recovered.append(item)
                continue
            }

            guard let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]),
                  let firstFile = files.first(where: { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "thumbnail.jpg" && $0.lastPathComponent != "folder_manifest.json" && $0.lastPathComponent != "transaction.json" }) else {
                continue
            }

            let fileName = firstFile.lastPathComponent
            let isHLS = fileName.hasSuffix(".movpkg") || (try? firstFile.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let ext = firstFile.pathExtension.lowercased()

            // 種別判定: 動画形式か一般ファイルか（種別不明の孤立ファイルを誤って動画と判定しない）
            let videoExtensions = ["mp4", "m4v", "mov", "webm", "m3u8", "movpkg", "jpeg", "jpg", "png", "gif", "heic"]
            let isVideoPayload = isHLS || videoExtensions.contains(ext)

            let payloadKind: TrashPayloadKind = isVideoPayload ? .video : .generalFile
            let format: SavedVideo.Format = isHLS ? .hls : (SavedVideo.Format(rawValue: ext) ?? .mp4)

            let attrs = try? fileManager.attributesOfItem(atPath: firstFile.path)
            let byteSize = attrs?[.size] as? Int64
            let deletedAt = (attrs?[.creationDate] as? Date) ?? Date()
            // 救済ファイルは元の削除日時や保持設定が不明なため、作成日時を根拠に期限を決めず自動削除対象から除外（保護）
            let expiresAt: Date? = nil

            let item = TrashItem(
                id: id,
                originalVideoID: UUID(),
                originalTitle: firstFile.deletingPathExtension().lastPathComponent,
                originalRelativePath: "Documents/Downloads/\(fileName)",
                originalFolderName: "",
                format: format,
                byteSize: byteSize,
                sourceHost: nil,
                sourcePageURL: nil,
                deletedAt: deletedAt,
                expiresAt: expiresAt,
                fileName: fileName,
                isFavorite: false,
                payloadKind: payloadKind,
                fileExtension: isVideoPayload ? nil : ext,
                relativeSubpath: nil
            )
            recovered.append(item)
        }

        if !recovered.isEmpty {
            try? writeMetadataToDisk(recovered)
        }
        return recovered
    }
}
