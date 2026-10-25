import Foundation
import UIKit

/// ゴミ箱内のファイル管理アイテムモデル
struct TrashItem: Identifiable, Codable, Equatable {
    let id: UUID                     // ゴミ箱管理用の一意ID
    let originalVideoID: UUID        // 元のSavedVideo.id
    let originalTitle: String        // 表示名
    let originalRelativePath: String // 元の相対パス
    let originalFolderName: String   // 元のフォルダ名（空文字は未分類）
    let format: SavedVideo.Format    // MP4 / HLS 等
    let byteSize: Int64?             // ファイルサイズ
    let sourceHost: String?          // 配信元ホスト
    let sourcePageURL: String?       // 元WebページURL
    let deletedAt: Date              // ゴミ箱移動日時
    let expiresAt: Date?             // 完全削除予定日時（nilは自動削除なし）
    let fileName: String             // 実際のファイル名またはパッケージ名
    let isFavorite: Bool?            // 元のお気に入り状態

    var isExpired: Bool {
        guard let expiresAt = expiresAt else { return false }
        return Date() >= expiresAt
    }

    /// 完全削除までの残り時間表示
    var remainingTimeDescription: String {
        guard let expiresAt = expiresAt else {
            return "自動削除なし（手動で削除するまで保持）"
        }
        let remaining = expiresAt.timeIntervalSince(Date())
        if remaining <= 0 {
            return "期限切れ (次回起動時などに削除)"
        }
        let totalHours = Int(remaining / 3600)
        let days = totalHours / 24
        let remHours = totalHours % 24
        if days > 0 {
            return "残り \(days)日 \(remHours)時間"
        } else {
            let mins = Int((remaining.truncatingRemainder(dividingBy: 3600)) / 60)
            if totalHours > 0 {
                return "残り \(totalHours)時間 \(mins)分"
            } else {
                return "残り \(max(1, mins))分"
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, originalVideoID, originalTitle, originalRelativePath, originalFolderName
        case format, byteSize, sourceHost, sourcePageURL, deletedAt, expiresAt, fileName, isFavorite
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
        isFavorite: Bool? = false
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

        if container.contains(.expiresAt) {
            expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        } else {
            // 旧データに期限がない場合は、従来どおり削除日時＋72時間とする
            expiresAt = deletedAt.addingTimeInterval(72 * 3600)
        }
    }
}

/// アプリ内ゴミ箱管理マネージャー
/// - 保存先: `Library/Application Support/Trash/`（iOSファイルアプリから不可視、OS自動消去対象外）
/// - サムネイル保存: `Library/Application Support/Trash/<id>/thumbnail.jpg`（非公開領域に永続化、再起動後も表示）
/// - 72時間（3日間）保持後に次回起動時またはフォアグラウンド復帰時にバックグラウンド完全削除
/// - 大容量ファイルの操作はバックグラウンドシリアルキューで実行しメインスレッドを阻害しない
/// - 二重操作防止（処理中アイテムのロック管理）
/// - ロールバック機能（ファイル移動やメタデータ書き込み失敗時に元の状態へ安全復元）
/// - メタデータ破損時でもゴミ箱内ファイルを空と誤認して削除しない安全保護機構
/// - MP4およびオフラインHLS（.movpkg一式）の確実な移動と復元後再生参照に対応
final class TrashManager: ObservableObject {
    static let shared = TrashManager()

    /// 保持期限（72時間）
    static let expirationInterval: TimeInterval = 72 * 3600

    @Published private(set) var items: [TrashItem] = []
    @Published private(set) var processingItemIDs: Set<UUID> = []

    private let fileManager = FileManager.default
    private let ioQueue = DispatchQueue(label: "com.clipharbor.trashmanager.io", qos: .userInitiated)
    private let trashThumbnailCache = NSCache<NSString, UIImage>()

    // MARK: - パス管理

    private static var trashDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let trashDir = appSupport.appendingPathComponent("Trash", isDirectory: true)
        if !FileManager.default.fileExists(atPath: trashDir.path) {
            try? FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        }
        return trashDir
    }

    private static var metadataFileURL: URL {
        trashDirectoryURL.appendingPathComponent("trash_metadata.json")
    }

    private func itemDirectoryURL(for itemID: UUID) -> URL {
        Self.trashDirectoryURL.appendingPathComponent(itemID.uuidString, isDirectory: true)
    }

    func itemFileURL(for item: TrashItem) -> URL {
        itemDirectoryURL(for: item.id).appendingPathComponent(item.fileName)
    }

    func itemThumbnailURL(for item: TrashItem) -> URL {
        itemDirectoryURL(for: item.id).appendingPathComponent("thumbnail.jpg")
    }

    // MARK: - 初期化とライフサイクル

    private init() {
        trashThumbnailCache.countLimit = 100
        trashThumbnailCache.totalCostLimit = 40 * 1024 * 1024

        loadMetadataSafely()
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
    func loadThumbnail(for item: TrashItem) async -> UIImage? {
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

    // MARK: - ゴミ箱へ移動（非同期・サムネイル永続化・ロールバック完備）

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
                NSLocalizedDescriptionKey: "この動画は現在処理中です。"
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
                NSLocalizedDescriptionKey: "対象ファイルが端末内に見つかりません。"
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
                        NSLocalizedDescriptionKey: "マネージャーが破棄されました。"
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
                        isFavorite: video.isFavorite
                    )

                    // 4. メタデータ永続化（失敗時は直ちにファイル移動をロールバック）
                    var updatedItems = self.items
                    updatedItems.insert(trashItem, at: 0)
                    do {
                        try self.writeMetadataToDisk(updatedItems)
                    } catch {
                        // ロールバック: 元の場所へ戻し、一時ディレクトリを削除
                        try? self.fileManager.moveItem(at: destURL, to: sourceURL)
                        try? self.fileManager.removeItem(at: itemDir)
                        continuation.resume(returning: .failure(NSError(domain: "TrashManager", code: 501, userInfo: [
                            NSLocalizedDescriptionKey: "メタデータの保存に失敗したため、移動を安全に取り消しました: \(error.localizedDescription)"
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
                    // 移動失敗時は一時ディレクトリを片付け、元の一覧は一切触らない
                    try? self.fileManager.removeItem(at: itemDir)
                    continuation.resume(returning: .failure(error))
                }
            }
        }
    }

    // MARK: - 復元（非同期・ロールバック完備・相対パス再構築）

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
                NSLocalizedDescriptionKey: "このアイテムは現在処理中です。"
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
                NSLocalizedDescriptionKey: "ゴミ箱内の実ファイルが見つかりません。"
            ]))
        }

        return await withCheckedContinuation { continuation in
            ioQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: .failure(NSError(domain: "TrashManager", code: 500, userInfo: [
                        NSLocalizedDescriptionKey: "マネージャーが破棄されました。"
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
                        // 元の相対パスの親ディレクトリを再構築して復元（不可能な場合はDownloads直下）
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
                        // 元フォルダが存在すればその中へ、存在しなければDownloads直下へ復元
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

                    // 新しい相対パスを計算（過去の絶対パスは一切再利用しない）
                    guard let newRelativePath = SavedVideo.relativePath(for: destURL) else {
                        throw NSError(domain: "TrashManager", code: 500, userInfo: [
                            NSLocalizedDescriptionKey: "復元先パスの算出に失敗しました。"
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
                        // ロールバック: 復元先からゴミ箱へ戻す
                        try? self.fileManager.moveItem(at: destURL, to: sourceURL)
                        continuation.resume(returning: .failure(NSError(domain: "TrashManager", code: 502, userInfo: [
                            NSLocalizedDescriptionKey: "メタデータの更新に失敗したため、復元を安全に取り消しました: \(error.localizedDescription)"
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
                        byteSize: item.byteSize,
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
                NSLocalizedDescriptionKey: "このアイテムは現在処理中です。"
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
                        NSLocalizedDescriptionKey: "マネージャーが破棄されました。"
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
                        NSLocalizedDescriptionKey: "マネージャーが破棄されました。"
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

                let itemDir = self.itemDirectoryURL(for: item.id)
                do {
                    if self.fileManager.fileExists(atPath: itemDir.path) {
                        try self.fileManager.removeItem(at: itemDir)
                    }
                    self.trashThumbnailCache.removeObject(forKey: item.id.uuidString as NSString)
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
        try data.write(to: Self.metadataFileURL, options: .atomic)
    }

    /// メタデータを安全に読み込み。
    /// 破損時やデコード失敗時でも「ゴミ箱が空」として扱わず、残存ファイルを保護・復元する。
    private func loadMetadataSafely() {
        let fileURL = Self.metadataFileURL
        guard fileManager.fileExists(atPath: fileURL.path) else {
            // メタデータファイルが存在しない場合でも、Trashディレクトリ内に実ファイルがあればスキャンして復元
            items = scanAndRecoverOrphanedFiles()
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let loaded = try JSONDecoder().decode([TrashItem].self, from: data)
            items = loaded
        } catch {
            print("[TrashManager] Metadata decoding failed: \(error). Preserving existing trash files.")
            // 破損ファイルのバックアップを作成
            let backupURL = fileURL.deletingLastPathComponent()
                .appendingPathComponent("trash_metadata_corrupted_\(Int(Date().timeIntervalSince1970)).json")
            try? fileManager.copyItem(at: fileURL, to: backupURL)

            // 残存ファイルからメタデータを安全に再構築（ファイルを絶対に消去しない）
            items = scanAndRecoverOrphanedFiles()
        }
    }

    /// メタデータ損失時やファイル不整合時に、Trash/ ディレクトリ内の実ファイルから安全に復旧する
    private func scanAndRecoverOrphanedFiles() -> [TrashItem] {
        let trashDir = Self.trashDirectoryURL
        guard let subdirs = try? fileManager.contentsOfDirectory(at: trashDir, includingPropertiesForKeys: [.creationDateKey]) else {
            return []
        }

        var recovered: [TrashItem] = []
        for dir in subdirs where dir.hasDirectoryPath {
            guard let id = UUID(uuidString: dir.lastPathComponent) else { continue }
            guard let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]),
                  let firstFile = files.first(where: { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "thumbnail.jpg" }) else {
                continue
            }

            let fileName = firstFile.lastPathComponent
            let isHLS = fileName.hasSuffix(".movpkg") || (try? firstFile.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let format: SavedVideo.Format = isHLS ? .hls : .mp4
            let attrs = try? fileManager.attributesOfItem(atPath: firstFile.path)
            let byteSize = attrs?[.size] as? Int64
            let deletedAt = (attrs?[.creationDate] as? Date) ?? Date()
            let expiresAt = deletedAt.addingTimeInterval(72 * 3600)

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
                fileName: fileName
            )
            recovered.append(item)
        }

        if !recovered.isEmpty {
            try? writeMetadataToDisk(recovered)
        }
        return recovered
    }
}
