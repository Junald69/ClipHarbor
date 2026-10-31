import Foundation
import UIKit
import ZIPFoundation

// MARK: - ファイル排他分類（Single Source of Truth）

/// アプリ管理対象ファイルの排他分類ルール
/// - 同一ファイルが `SavedVideo` と `ManagedFileItem` の双方に重複登録されることを型レベルで防止する
/// - HLS `.movpkg` パッケージ内部の断片ファイルや隠しファイル、Vault領域を除外する
enum FileClassification: Equatable {
    case excluded
    case media(SavedVideo.Format)
    case generalFile(ext: String)

    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "webm"]
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "heic"]
    static let mediaExtensions: Set<String> = videoExtensions.union(imageExtensions)

    /// ファイルURLを排他的に分類する
    static func classify(url: URL) -> FileClassification {
        let lastComponent = url.lastPathComponent
        guard !lastComponent.isEmpty,
              !lastComponent.hasPrefix("."),
              lastComponent != "__MACOSX" else {
            return .excluded
        }

        // パス内に __MACOSX、.movpkg、Vault、.playback_temp が含まれる場合は除外
        let pathComponents = url.standardizedFileURL.pathComponents
        for component in pathComponents {
            let lower = component.lowercased()
            if component == "__MACOSX" || lower.hasSuffix(".movpkg") || lower == ".playback_temp" {
                return .excluded
            }
            if component.hasPrefix(".") && component != "." && component != ".." && !component.hasPrefix(".Trash") {
                // システム隠しディレクトリ配下は除外（ただしテスト用一時ディレクトリ等は許容するため Downloads 基準でも判定）
                if lower == ".ds_store" || lower == ".localized" {
                    return .excluded
                }
            }
        }

        if isInsideVaultOrTempArea(url) {
            return .excluded
        }

        let ext = url.pathExtension.lowercased()
        switch ext {
        case "mp4": return .media(.mp4)
        case "m4v": return .media(.m4v)
        case "mov": return .media(.mov)
        case "webm": return .media(.webm)
        case "jpg", "jpeg": return .media(.jpeg)
        case "png": return .media(.png)
        case "gif": return .media(.gif)
        case "heic": return .media(.heic)
        case "movpkg": return .excluded
        default:
            return .generalFile(ext: ext)
        }
    }

    /// Private Vault 領域・一時復号再生領域・Trash 領域かどうかを判定
    static func isInsideVaultOrTempArea(_ url: URL) -> Bool {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath().path
        let components = canonical.split(separator: "/").map(String.init)
        if components.contains(".playback_temp") || components.contains("ZipWorkStaging") {
            return true
        }
        if let appSupportIdx = components.firstIndex(of: "Application Support"),
           components.count > appSupportIdx + 1 {
            let sub = components[appSupportIdx + 1]
            if sub == "Vault" || sub == "Trash" {
                return true
            }
        }
        if url.pathExtension.lowercased() == "vault" {
            return true
        }
        return false
    }

    /// コンテナ相対パスを正規化して返す（重複排除・UUID維持のキーとして使用）
    static func normalizedRelativePath(_ rawRelativePath: String) -> String {
        let unified = rawRelativePath.replacingOccurrences(of: "\\", with: "/")
        let parts = unified.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." }
        return parts.joined(separator: "/").precomposedStringWithCanonicalMapping
    }

    /// 実ファイルURLから正規化済みコンテナ相対パスを算出する
    static func normalizedContainerRelativePath(for url: URL, customRootURL: URL? = nil) -> String? {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        if let customRoot = customRootURL?.standardizedFileURL.resolvingSymlinksInPath() {
            let rootPath = customRoot.path
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            if canonical.path.hasPrefix(prefix) {
                let sub = String(canonical.path.dropFirst(prefix.count))
                return normalizedRelativePath("Documents/Downloads/" + sub)
            }
        }
        guard let rel = SavedVideo.relativePath(for: canonical) else { return nil }
        return normalizedRelativePath(rel)
    }

    /// 相対パスから所属トップフォルダ名とフォルダ内相対サブパス（ネスト階層）を抽出する
    /// 例: `Documents/Downloads/旅行動画/Day1/clip.mp4` -> `(folderName: "旅行動画", subpath: "Day1")`
    static func extractFolderAndSubpath(fromRelativePath relativePath: String) -> (folderName: String, subfolderPrefix: String?) {
        let normalized = normalizedRelativePath(relativePath)
        let components = normalized.split(separator: "/").map(String.init)
        guard let dlIndex = components.firstIndex(of: "Downloads") else {
            return ("", nil)
        }
        // Documents / Downloads / <File> -> 未分類直下
        guard components.count >= dlIndex + 3 else {
            return ("", nil)
        }
        let rawFolder = components[dlIndex + 1]
        let cleanFolder = VideoFolderManager.sanitizedFolderName(rawFolder)
        guard !cleanFolder.isEmpty else {
            return ("", nil)
        }
        if components.count > dlIndex + 3 {
            let subComponents = components[(dlIndex + 2)..<(components.count - 1)]
            let prefix = subComponents.joined(separator: "/")
            return (cleanFolder, prefix.isEmpty ? nil : prefix)
        }
        return (cleanFolder, nil)
    }
}

extension SavedVideo {
    /// フォルダ内のサブディレクトリ階層にある場合の相対サブフォルダ表示（例: `"Day1"` または `"Day1/Photos"`）
    var displaySubfolderPrefix: String? {
        guard !isHLS else { return nil }
        return FileClassification.extractFolderAndSubpath(fromRelativePath: relativePath).subfolderPrefix
    }
}

// MARK: - 一般ファイル・ZIP管理モデル

/// ZIPアーカイブおよび展開された非メディア一般ファイルの管理モデル
/// - `SavedVideo`（動画・画像専用）とは明確に分離し、プレイヤーやサムネイル生成器へ渡らない構造を保証する
struct ManagedFileItem: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var title: String
    var relativePath: String
    var fileExtension: String
    var createdAt: Date
    var byteSize: Int64
    var folderName: String
    var relativeSubpath: String?

    var isZip: Bool {
        fileExtension.lowercased() == "zip"
    }

    var formatLabel: String {
        let clean = fileExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "FILE" : clean.uppercased()
    }

    /// ファイル種別に応じた SF Symbols アイコン名
    var sfSymbolName: String {
        switch fileExtension.lowercased() {
        case "zip":
            return "doc.zipper"
        case "pdf":
            return "doc.richtext.fill"
        case "txt", "md", "rtf", "log", "json", "xml", "csv", "yml", "yaml":
            return "doc.text.fill"
        case "mp3", "m4a", "wav", "aac", "flac", "ogg":
            return "waveform"
        case "html", "htm":
            return "globe"
        default:
            return "doc.fill"
        }
    }

    /// サブフォルダ内にネストされている場合の表示用プレフィックス（例: `"Day1/Docs"`）
    var displaySubfolderPrefix: String? {
        if let sub = relativeSubpath, !sub.isEmpty {
            return sub
        }
        return FileClassification.extractFolderAndSubpath(fromRelativePath: relativePath).subfolderPrefix
    }

    /// 現在のコンテナ基準での実ファイルURL
    var fileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(relativePath)
    }

    /// 実ファイルが存在するか
    var fileExists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// 正規化済み相対パス
    var normalizedRelativePath: String {
        FileClassification.normalizedRelativePath(relativePath)
    }
}

/// 物理移動・リネーム操作前の復旧ジャーナルレコード（Phase F2-A 障害復旧・UUID保全用）
struct ManagedFilePendingOperation: Codable, Equatable {
    enum Kind: String, Codable {
        case rename
        case move
    }
    let operationID: UUID
    let itemID: UUID
    let kind: Kind
    let sourceRelativePath: String
    let destinationRelativePath: String
    let originalTitle: String
    let destinationTitle: String
    let originalFolderName: String
    let destinationFolderName: String
    let fileExtension: String
    let createdAt: Date
}

// MARK: - セキュリティ制限・エラー・進捗モデル

/// ZIP展開時のセキュリティ制限設定（XCTest からカスタム制限を注入可能）
struct ZipSecurityLimits: Equatable, Sendable {
    /// アーカイブ内の最大エントリ数上限
    var maxEntryCount: Int = 2_000
    /// 1ファイルあたりの最大非圧縮サイズ上限（デフォルト 2 GB）
    var maxSingleFileBytes: Int64 = 2 * 1024 * 1024 * 1024
    /// アーカイブ全体の合計非圧縮サイズ上限（デフォルト 4 GB）
    var maxTotalUncompressedBytes: Int64 = 4 * 1024 * 1024 * 1024
    /// 圧縮率チェックを適用する最小非圧縮サイズ（デフォルト 64 MB：小さい正常テキスト等の誤拒否を防止）
    var suspiciousRatioMinUncompressedBytes: Int64 = 64 * 1024 * 1024
    /// 上記サイズ以上のファイルに対する最大許容圧縮率（デフォルト 1,000倍）
    var maxSuspiciousCompressionRatio: Double = 1_000.0
    /// 展開時に必要な空き容量の安全マージン（デフォルト 64 MB）
    var requiredFreeSpaceMarginBytes: Int64 = 64 * 1024 * 1024

    static let standard = ZipSecurityLimits()
}

/// ZIP操作のエラー定義
enum ZipOperationError: LocalizedError, Equatable {
    case fileNotFound
    case invalidArchive
    case passwordProtected
    case maliciousPathDetected(String)
    case symlinkNotAllowed(String)
    case conflictingEntries(String)
    case entryCountLimitExceeded(Int)
    case uncompressedSizeLimitExceeded(Int64)
    case suspiciousCompressionRatio
    case insufficientDiskSpace
    case corruptedArchive
    case unsupportedSourceForCompression(String)
    case operationInProgress
    case cancelled
    case ioError(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return NSLocalizedString("Target file could not be found.", comment: "")
        case .invalidArchive:
            return NSLocalizedString("The ZIP file is invalid or empty.", comment: "")
        case .passwordProtected:
            return NSLocalizedString("Password-protected ZIP files are not supported.", comment: "")
        case .maliciousPathDetected:
            return NSLocalizedString("Rejected ZIP archive because it contains an unsafe file path.", comment: "")
        case .symlinkNotAllowed:
            return NSLocalizedString("Rejected ZIP archive because symbolic links are not allowed.", comment: "")
        case .conflictingEntries:
            return NSLocalizedString("Rejected ZIP archive because it contains duplicate or conflicting paths.", comment: "")
        case .entryCountLimitExceeded(let maxCount):
            return String(format: NSLocalizedString("ZIP archive contains too many files (limit: %lld).", comment: ""), maxCount)
        case .uncompressedSizeLimitExceeded:
            return NSLocalizedString("ZIP extracted size exceeds the safety limit.", comment: "")
        case .suspiciousCompressionRatio:
            return NSLocalizedString("Rejected ZIP archive due to an abnormal compression ratio (potential ZIP Bomb).", comment: "")
        case .insufficientDiskSpace:
            return NSLocalizedString("Not enough free storage space to complete the ZIP operation.", comment: "")
        case .corruptedArchive:
            return NSLocalizedString("The ZIP file is corrupted (CRC mismatch or damaged header).", comment: "")
        case .unsupportedSourceForCompression(let reason):
            return reason
        case .operationInProgress:
            return NSLocalizedString("Another ZIP operation is currently in progress.", comment: "")
        case .cancelled:
            return NSLocalizedString("ZIP operation was cancelled.", comment: "")
        case .ioError(let detail):
            return detail
        }
    }
}

/// 進行中のZIP操作状態（UIバナー・進捗シート表示用）
struct ZipOperationStatus: Identifiable, Equatable {
    enum Kind: Equatable {
        case extracting
        case compressing
    }

    let id: UUID
    let kind: Kind
    let targetTitle: String
    var fractionCompleted: Double
    var currentEntryName: String
}

/// スレッドセーフなキャンセルフラグ
final class ZipCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var _isCancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCancelled
    }

    func cancel() {
        lock.lock()
        _isCancelled = true
        lock.unlock()
    }
}

// MARK: - ZIPバイナリヘッダ検査器（暗号化ビット・EOCD件数整合性チェック）

enum ZipBinaryInspector {
    private static let localFileHeaderSig: UInt32 = 0x04034b50
    private static let centralDirHeaderSig: UInt32 = 0x02014b50
    private static let eocdSig: UInt32 = 0x06054b50

    struct HeaderInspectionResult {
        let expectedEntryCount: Int
        let hasEncryptedEntry: Bool
    }

    /// ZIPファイルのバイナリヘッダを走査し、パスワード保護（Bit 0 / Bit 6 / WinZip AES Method 99）およびEOCDエントリ数を検査する
    static func inspectArchiveHeaders(at url: URL) throws -> HeaderInspectionResult {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ZipOperationError.fileNotFound
        }
        defer { try? handle.close() }

        let fileSize = Int64((try? handle.seekToEnd()) ?? 0)
        guard fileSize >= 22 else {
            throw ZipOperationError.invalidArchive
        }

        // 先頭シグネチャ確認（PK\x03\x04 または 空ZIP PK\x05\x06）
        try handle.seek(toOffset: 0)
        guard let headData = try handle.read(upToCount: 30), headData.count >= 4 else {
            throw ZipOperationError.invalidArchive
        }
        let firstSig = readUInt32LE(headData, offset: 0)
        if firstSig == localFileHeaderSig && headData.count >= 30 {
            let gpFlag = readUInt16LE(headData, offset: 6)
            let method = readUInt16LE(headData, offset: 8)
            if (gpFlag & 0x0001) != 0 || (gpFlag & 0x0040) != 0 || method == 99 {
                return HeaderInspectionResult(expectedEntryCount: 0, hasEncryptedEntry: true)
            }
        } else if firstSig != eocdSig {
            throw ZipOperationError.invalidArchive
        }

        // 末尾最大 65,557 バイトから EOCD (0x06054b50) を検索
        let searchLen = Int(min(fileSize, 65_557))
        let searchStart = UInt64(fileSize - Int64(searchLen))
        try handle.seek(toOffset: searchStart)
        guard let tailData = try handle.read(upToCount: searchLen), tailData.count >= 22 else {
            throw ZipOperationError.corruptedArchive
        }

        var eocdOffsetInTail: Int? = nil
        var i = tailData.count - 22
        while i >= 0 {
            if readUInt32LE(tailData, offset: i) == eocdSig {
                eocdOffsetInTail = i
                break
            }
            i -= 1
        }
        guard let eocdPos = eocdOffsetInTail else {
            throw ZipOperationError.corruptedArchive
        }

        let totalEntries = Int(readUInt16LE(tailData, offset: eocdPos + 10))
        let cdSize = UInt64(readUInt32LE(tailData, offset: eocdPos + 12))
        let cdOffset = UInt64(readUInt32LE(tailData, offset: eocdPos + 16))

        // ZIP64 でない通常の Central Directory を走査して全エントリの暗号化フラグを確認
        if totalEntries > 0 && cdOffset != 0xFFFF_FFFF && cdOffset + cdSize <= UInt64(fileSize) {
            try handle.seek(toOffset: cdOffset)
            let maxRead = Int(min(cdSize, 4 * 1024 * 1024)) // 最大4MBまでCDヘッダを読み取り検査
            if let cdData = try handle.read(upToCount: maxRead) {
                var pos = 0
                var scanned = 0
                while pos + 46 <= cdData.count && scanned < totalEntries {
                    let sig = readUInt32LE(cdData, offset: pos)
                    guard sig == centralDirHeaderSig else {
                        throw ZipOperationError.corruptedArchive
                    }
                    let gpFlag = readUInt16LE(cdData, offset: pos + 8)
                    let method = readUInt16LE(cdData, offset: pos + 10)
                    if (gpFlag & 0x0001) != 0 || (gpFlag & 0x0040) != 0 || method == 99 {
                        return HeaderInspectionResult(expectedEntryCount: totalEntries, hasEncryptedEntry: true)
                    }
                    let nameLen = Int(readUInt16LE(cdData, offset: pos + 28))
                    let extraLen = Int(readUInt16LE(cdData, offset: pos + 30))
                    let commentLen = Int(readUInt16LE(cdData, offset: pos + 32))
                    pos += 46 + nameLen + extraLen + commentLen
                    scanned += 1
                }
            }
        }

        return HeaderInspectionResult(expectedEntryCount: totalEntries, hasEncryptedEntry: false)
    }

    private static func readUInt16LE(_ data: Data, offset: Int) -> UInt16 {
        let b0 = UInt16(data[data.startIndex + offset])
        let b1 = UInt16(data[data.startIndex + offset + 1]) << 8
        return b0 | b1
    }

    private static func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        let b0 = UInt32(data[data.startIndex + offset])
        let b1 = UInt32(data[data.startIndex + offset + 1]) << 8
        let b2 = UInt32(data[data.startIndex + offset + 2]) << 16
        let b3 = UInt32(data[data.startIndex + offset + 3]) << 24
        return b0 | b1 | b2 | b3
    }
}

// MARK: - スレッドセーフな進行中ジョブ登録簿（nonisolated）

private enum ZipOperationRegistry {
    private static let lock = NSLock()
    private static var activeIDs: Set<UUID> = []

    static func register(_ id: UUID) {
        lock.lock()
        activeIDs.insert(id)
        lock.unlock()
    }

    static func unregister(_ id: UUID) {
        lock.lock()
        activeIDs.remove(id)
        lock.unlock()
    }

    static func isActive(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeIDs.contains(id)
    }

    static var hasAnyActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !activeIDs.isEmpty
    }
}

// MARK: - ZIPアーカイブ・一般ファイル管理マネージャー

@MainActor
final class ZipArchiveManager: ObservableObject {
    static let shared = ZipArchiveManager()

    nonisolated static let managedFilesKey = "clipHarborManagedFilesV1"
    nonisolated static let pendingOperationKey = "clipHarborPendingManagedFileOpV1"
    nonisolated private static let streamBufferSize = 32 * 1024

    @Published private(set) var managedFiles: [ManagedFileItem] = []
    @Published private(set) var activeOperation: ZipOperationStatus? = nil

    private let userDefaults: UserDefaults
    private let customDownloadsRootURL: URL?
    private let customStagingRootURL: URL?

    private var activeCancellationToken: ZipCancellationToken? = nil

    /// 一時的なファイル不在でメタデータを即座に消さないための不在確認カウンタ
    private var missingCheckCounts: [UUID: Int] = [:]

    init(
        userDefaults: UserDefaults = .standard,
        customDownloadsRootURL: URL? = nil,
        customStagingRootURL: URL? = nil
    ) {
        self.userDefaults = userDefaults
        self.customDownloadsRootURL = customDownloadsRootURL
        self.customStagingRootURL = customStagingRootURL
        loadPersistedManagedFiles()
        recoverPendingOperationsIfNeeded()

        let stagingRoot = self.stagingRootDirectoryURL
        Task.detached(priority: .utility) {
            Self.cleanupOrphanedStagingDirectories(at: stagingRoot)
        }
    }

    // MARK: - ディレクトリ解決

    var downloadsRootURL: URL {
        if let custom = customDownloadsRootURL {
            try? FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
            return custom
        }
        return (try? VideoFolderManager.ensureDownloadsDirectory())
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads", isDirectory: true)
    }

    var stagingRootDirectoryURL: URL {
        if let custom = customStagingRootURL {
            try? FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
            return custom
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("ZipWorkStaging", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    // MARK: - ステージング領域の安全な回収（進行中ジョブを絶対に巻き込まない）

    private static func registerActiveOperation(_ id: UUID) {
        ZipOperationRegistry.register(id)
    }

    private static func unregisterActiveOperation(_ id: UUID) {
        ZipOperationRegistry.unregister(id)
    }

    static var hasAnyActiveOperation: Bool {
        ZipOperationRegistry.hasAnyActive
    }

    /// 強制終了等で残った孤児ステージングディレクトリのみを安全に削除する
    nonisolated static func cleanupOrphanedStagingDirectories(at stagingRoot: URL) {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: stagingRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for child in children {
            let name = child.lastPathComponent
            if let opID = UUID(uuidString: name), ZipOperationRegistry.isActive(opID) {
                // 実行中のジョブは絶対に削除しない
                continue
            }
            try? fm.removeItem(at: child)
        }
    }

    // MARK: - フィルタリング・一覧取得

    /// 指定されたフォルダフィルタに属する一般ファイル（ZIP含む）を返す
    func managedFiles(in filter: VideoFolderManager.FolderFilter) -> [ManagedFileItem] {
        switch filter {
        case .all:
            return managedFiles
        case .uncategorized:
            return managedFiles.filter { $0.folderName.isEmpty }
        case .folder(let name):
            let clean = VideoFolderManager.sanitizedFolderName(name)
            return managedFiles.filter { $0.folderName == clean }
        }
    }

    /// ファイルURL解決（カスタムテストルート対応）
    func resolveFileURL(for item: ManagedFileItem) -> URL {
        if let customRoot = customDownloadsRootURL {
            let norm = item.normalizedRelativePath
            let prefix = "Documents/Downloads/"
            if norm.hasPrefix(prefix) {
                let relToDownloads = String(norm.dropFirst(prefix.count))
                return customRoot.appendingPathComponent(relToDownloads)
            }
        }
        return item.fileURL
    }

    // MARK: - ファイルシステムとの整合性スキャン（重複排除・UUID維持・多階層対応）

    /// `Documents/Downloads`（および全サブフォルダ階層）をスキャンし、
    /// メディアファイルは `DownloadCenter`（`SavedVideo`）へ、ZIP・一般ファイルは `managedFiles`（`ManagedFileItem`）へ排他登録する
    func syncWithFileSystem(
        downloads: DownloadCenter,
        folderManager: VideoFolderManager,
        confirmedPruneMissing: Bool = false
    ) {
        recoverPendingOperationsIfNeeded()
        let fm = FileManager.default
        let root = downloadsRootURL

        // 1. 既存の SavedVideo の正規化相対パスおよび標準化フルパス集合を取得
        var registeredMediaRelPaths = Set(downloads.saved.map {
            FileClassification.normalizedRelativePath($0.relativePath)
        })
        var registeredMediaFullPaths = Set(downloads.saved.map {
            $0.fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        })

        // 2. 既存の ManagedFileItem を正規化相対パスでマップ化（UUID・createdAt を保持するため）
        var existingManagedByRelPath: [String: ManagedFileItem] = [:]
        for item in managedFiles {
            existingManagedByRelPath[item.normalizedRelativePath] = item
        }

        var discoveredManagedRelPaths: Set<String> = []
        var updatedManagedList: [ManagedFileItem] = []

        // スキャン対象ディレクトリ（Downloads配下の再帰走査 ＋ 標準運用時は Documents 直下のファイル）
        var candidateFileURLs: [URL] = []

        if let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            while let fileURL = enumerator.nextObject() as? URL {
                let lastComponent = fileURL.lastPathComponent
                let lowerName = lastComponent.lowercased()

                // __MACOSX や .movpkg（HLSパッケージ）は内部へ再帰進入しない
                if lastComponent == "__MACOSX" || lowerName.hasSuffix(".movpkg") || lastComponent.hasPrefix(".") {
                    enumerator.skipDescendants()
                    continue
                }

                let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true {
                    continue
                }
                if values?.isDirectory == true {
                    continue
                }
                if values?.isRegularFile == true {
                    candidateFileURLs.append(fileURL)
                }
            }
        }

        // Documents 直下に置かれたファイルもチェック（カスタムテストルート未指定時のみ）
        if customDownloadsRootURL == nil {
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            if let docsItems = try? fm.contentsOfDirectory(
                at: docs,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) {
                for url in docsItems {
                    let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                    if vals?.isSymbolicLink == true || vals?.isDirectory == true {
                        continue
                    }
                    if vals?.isRegularFile == true {
                        candidateFileURLs.append(url)
                    }
                }
            }
        }

        // 3. 検出した各ファイルを排他分類に従って振り分け
        for fileURL in candidateFileURLs {
            let classification = FileClassification.classify(url: fileURL)
            guard classification != .excluded else { continue }

            let canonicalFullPath = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
            guard let normRelPath = FileClassification.normalizedContainerRelativePath(for: fileURL, customRootURL: customDownloadsRootURL) else {
                continue
            }

            let attrs = (try? fm.attributesOfItem(atPath: fileURL.path)) ?? [:]
            let byteSize = (attrs[.size] as? Int64) ?? 0
            let creationDate = (attrs[.creationDate] as? Date) ?? Date()
            let (folderName, subfolderPrefix) = FileClassification.extractFolderAndSubpath(fromRelativePath: normRelPath)

            switch classification {
            case .excluded:
                continue

            case .media(let mediaFormat):
                // メディアファイルは SavedVideo 側のみに登録（サイズ > 0）
                guard byteSize > 0 else { continue }
                if !registeredMediaRelPaths.contains(normRelPath) && !registeredMediaFullPaths.contains(canonicalFullPath) {
                    let title = fileURL.deletingPathExtension().lastPathComponent
                    let newVideo = SavedVideo(
                        id: UUID(),
                        title: title.isEmpty ? "Media" : title,
                        relativePath: normRelPath,
                        format: mediaFormat,
                        sourceHost: nil,
                        createdAt: creationDate,
                        byteSize: byteSize,
                        sourcePageURL: nil,
                        isFavorite: false
                    )
                    downloads.addSaved(newVideo)
                    if !folderName.isEmpty {
                        folderManager.setFolderName(folderName, for: newVideo)
                    }
                    registeredMediaRelPaths.insert(normRelPath)
                    registeredMediaFullPaths.insert(canonicalFullPath)
                }

            case .generalFile(let ext):
                // SavedVideo に既に登録されているパスは絶対に ManagedFileItem に重複登録しない
                guard !registeredMediaRelPaths.contains(normRelPath),
                      !registeredMediaFullPaths.contains(canonicalFullPath),
                      !discoveredManagedRelPaths.contains(normRelPath) else {
                    continue
                }
                discoveredManagedRelPaths.insert(normRelPath)

                let title = fileURL.deletingPathExtension().lastPathComponent
                let displayTitle = title.isEmpty ? fileURL.lastPathComponent : title

                if var existing = existingManagedByRelPath[normRelPath] {
                    // 既存UUIDとcreatedAtを維持し、サイズ・フォルダ情報のみ最新化
                    existing.byteSize = byteSize
                    existing.folderName = folderName
                    existing.relativeSubpath = subfolderPrefix
                    missingCheckCounts[existing.id] = nil
                    updatedManagedList.append(existing)
                } else {
                    let newItem = ManagedFileItem(
                        id: UUID(),
                        title: displayTitle,
                        relativePath: normRelPath,
                        fileExtension: ext.lowercased(),
                        createdAt: creationDate,
                        byteSize: byteSize,
                        folderName: folderName,
                        relativeSubpath: subfolderPrefix
                    )
                    updatedManagedList.append(newItem)
                }
            }
        }

        // 4. 既存インデックスのうち今回見つからなかったアイテムの保護判定
        // 一時的なファイル不在で即時削除せず、ZIP操作中でないこと＆連続不在（または明示的削除要求）を確認する
        let isBusy = Self.hasAnyActiveOperation || activeOperation != nil
        for oldItem in managedFiles where !discoveredManagedRelPaths.contains(oldItem.normalizedRelativePath) {
            // メディア側に移行していた場合は除外
            if registeredMediaRelPaths.contains(oldItem.normalizedRelativePath) {
                missingCheckCounts[oldItem.id] = nil
                continue
            }
            if isBusy {
                // ファイル操作進行中は既存メタデータを保護
                updatedManagedList.append(oldItem)
                continue
            }
            let count = (missingCheckCounts[oldItem.id] ?? 0) + 1
            missingCheckCounts[oldItem.id] = count
            let actualURL = resolveFileURL(for: oldItem)
            let parentExists = fm.fileExists(atPath: actualURL.deletingLastPathComponent().path)
            if !confirmedPruneMissing && count < 2 && parentExists {
                // 単発の一時不在では保持
                updatedManagedList.append(oldItem)
            } else {
                missingCheckCounts[oldItem.id] = nil
            }
        }

        updatedManagedList.sort { $0.createdAt > $1.createdAt }
        if updatedManagedList != managedFiles {
            managedFiles = updatedManagedList
            persistManagedFiles()
        }
    }

    // MARK: - フォルダ名変更・削除時の連携（F1 多階層安全処理）

    /// フォルダ名変更時に、当該フォルダ配下（サブフォルダ内含む）の全 `ManagedFileItem` のパスを更新する
    func handleFolderRenamed(from oldFolderName: String, to newFolderName: String) {
        let cleanOld = VideoFolderManager.sanitizedFolderName(oldFolderName)
        let cleanNew = VideoFolderManager.sanitizedFolderName(newFolderName)
        guard !cleanOld.isEmpty, !cleanNew.isEmpty, cleanOld != cleanNew else { return }

        var changed = false
        let oldPrefix = "Documents/Downloads/\(cleanOld)/"
        let newPrefix = "Documents/Downloads/\(cleanNew)/"

        for idx in managedFiles.indices {
            let norm = managedFiles[idx].normalizedRelativePath
            if managedFiles[idx].folderName == cleanOld || norm.hasPrefix(oldPrefix) {
                if norm.hasPrefix(oldPrefix) {
                    let tail = String(norm.dropFirst(oldPrefix.count))
                    let updatedRel = FileClassification.normalizedRelativePath(newPrefix + tail)
                    managedFiles[idx].relativePath = updatedRel
                    managedFiles[idx].relativeSubpath = FileClassification.extractFolderAndSubpath(fromRelativePath: updatedRel).subfolderPrefix
                }
                managedFiles[idx].folderName = cleanNew
                changed = true
            }
        }

        if changed {
            persistManagedFiles()
        }
    }

    /// フォルダ削除確定時（またはロールバック失敗による部分移動時）に、退避が完了した特定の `ManagedFileItem` のメタデータを未分類（Downloads直下）へ更新する
    func applyEvacuatedManagedFileUpdate(id: UUID, newTitle: String, newRelativePath: String) {
        guard let idx = managedFiles.firstIndex(where: { $0.id == id }) else { return }
        managedFiles[idx].title = newTitle
        managedFiles[idx].relativePath = FileClassification.normalizedRelativePath(newRelativePath)
        managedFiles[idx].folderName = ""
        managedFiles[idx].relativeSubpath = nil
        persistManagedFiles()
    }

    /// フォルダ削除時に、当該フォルダ配下（サブフォルダ内含む）の全 `ManagedFileItem` を未分類（Downloads直下）へ同名衝突回避付きで退避する
    func evacuateManagedFilesForDeletedFolder(_ folderName: String) {
        let clean = VideoFolderManager.sanitizedFolderName(folderName)
        guard !clean.isEmpty else { return }

        let root = downloadsRootURL
        let fm = FileManager.default
        var changed = false

        for idx in managedFiles.indices where managedFiles[idx].folderName == clean {
            let item = managedFiles[idx]
            let currentURL = resolveFileURL(for: item)
            if fm.fileExists(atPath: currentURL.path) {
                let baseName = FileNaming.sanitizedBaseName(item.title)
                let destURL = FileNaming.uniqueDestination(
                    in: root,
                    baseName: baseName.isEmpty ? "File" : baseName,
                    fileExtension: item.fileExtension
                )
                if (try? fm.moveItem(at: currentURL, to: destURL)) != nil,
                   let newRel = FileClassification.normalizedContainerRelativePath(for: destURL, customRootURL: customDownloadsRootURL) {
                    managedFiles[idx].relativePath = newRel
                    managedFiles[idx].title = destURL.deletingPathExtension().lastPathComponent
                    managedFiles[idx].folderName = ""
                    managedFiles[idx].relativeSubpath = nil
                    changed = true
                }
            } else {
                managedFiles[idx].folderName = ""
                managedFiles[idx].relativeSubpath = nil
                changed = true
            }
        }

        if changed {
            persistManagedFiles()
        }
    }

    // MARK: - 一般ファイルの名前変更・フォルダ移動（Phase F2-A）

    /// 一般ファイル（ZIP・PDF・TXT等）の名前を変更する（拡張子は固定し、ベース名のみを変更）
    /// - Parameters:
    ///   - item: 対象の ManagedFileItem
    ///   - rawNewTitle: ユーザーが入力した新しいタイトル（拡張子を含まないベース名）
    /// - Returns: 更新された ManagedFileItem（UUIDは100%維持）
    @discardableResult
    func renameManagedFile(
        _ item: ManagedFileItem,
        to rawNewTitle: String
    ) throws -> ManagedFileItem {
        let cleanNewBase = FileNaming.sanitizedBaseName(rawNewTitle)
        guard !cleanNewBase.isEmpty else {
            throw VideoFolderManager.FolderError.emptyName
        }

        // Unicode正規化と大文字小文字違いを考慮した同一判定（no-op）
        let normCurrent = item.title.precomposedStringWithCanonicalMapping
        let normNew = cleanNewBase.precomposedStringWithCanonicalMapping
        if normCurrent == normNew {
            return item
        }

        let fm = FileManager.default
        let sourceURL = resolveFileURL(for: item)
        guard fm.fileExists(atPath: sourceURL.path) else {
            throw VideoFolderManager.FolderError.fileOperationFailed(
                NSLocalizedString("Source file not found.", comment: "")
            )
        }

        // 境界チェック: Vault / Trash / 一時復号再生領域のアクセスを厳格に禁止
        if FileClassification.isInsideVaultOrTempArea(sourceURL) {
            throw VideoFolderManager.FolderError.fileOperationFailed(
                NSLocalizedString("Cannot operate on files inside the Private Vault.", comment: "")
            )
        }

        let parentDir = sourceURL.deletingLastPathComponent()
        let destURL = parentDir.appendingPathComponent(cleanNewBase).appendingPathExtension(item.fileExtension)

        // 宛先がDownloads管理領域内であることを境界検証
        let canonicalDest = destURL.standardizedFileURL.resolvingSymlinksInPath().path
        let canonicalRoot = downloadsRootURL.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = canonicalRoot.hasSuffix("/") ? canonicalRoot : canonicalRoot + "/"
        guard canonicalDest.hasPrefix(prefix) || canonicalDest == canonicalRoot else {
            throw VideoFolderManager.FolderError.fileOperationFailed(
                NSLocalizedString("Destination path is invalid.", comment: "")
            )
        }

        // 同一親ディレクトリ内で同名ファイルが既に存在する場合は上書きを阻止
        if destURL.path.caseInsensitiveCompare(sourceURL.path) != .orderedSame && fm.fileExists(atPath: destURL.path) {
            throw VideoFolderManager.FolderError.alreadyExists
        }

        guard let destRelative = FileClassification.normalizedContainerRelativePath(for: destURL, customRootURL: customDownloadsRootURL) else {
            throw VideoFolderManager.FolderError.fileOperationFailed(
                NSLocalizedString("Destination path is invalid.", comment: "")
            )
        }

        // 移動前に障害復旧ジャーナルを記録
        let op = ManagedFilePendingOperation(
            operationID: UUID(),
            itemID: item.id,
            kind: .rename,
            sourceRelativePath: item.normalizedRelativePath,
            destinationRelativePath: destRelative,
            originalTitle: item.title,
            destinationTitle: cleanNewBase,
            originalFolderName: item.folderName,
            destinationFolderName: item.folderName,
            fileExtension: item.fileExtension,
            createdAt: item.createdAt
        )
        try recordPendingOperation(op)

        // 物理リネーム実行
        do {
            try fm.moveItem(at: sourceURL, to: destURL)
        } catch {
            clearPendingOperation()
            throw VideoFolderManager.FolderError.fileOperationFailed(
                String(format: NSLocalizedString("Failed to rename file: %@", comment: ""), error.localizedDescription)
            )
        }

        // 物理移動の成立確認
        guard fm.fileExists(atPath: destURL.path) && !fm.fileExists(atPath: sourceURL.path) else {
            if fm.fileExists(atPath: destURL.path) && fm.fileExists(atPath: sourceURL.path) {
                clearPendingOperation()
                throw VideoFolderManager.FolderError.fileOperationFailed(
                    NSLocalizedString("Failed to rename file due to duplicate files.", comment: "")
                )
            }
            try? fm.moveItem(at: destURL, to: sourceURL)
            clearPendingOperation()
            throw VideoFolderManager.FolderError.fileOperationFailed(
                NSLocalizedString("Failed to rename file.", comment: "")
            )
        }

        // メタデータ更新（UUID・createdAt・サイズ・フォルダ・サブパスは100%維持）
        guard let idx = managedFiles.firstIndex(where: { $0.id == item.id }) else {
            clearPendingOperation()
            throw VideoFolderManager.FolderError.fileOperationFailed(
                NSLocalizedString("Item not found in index.", comment: "")
            )
        }

        let previousItem = managedFiles[idx]
        managedFiles[idx].title = cleanNewBase
        managedFiles[idx].relativePath = destRelative

        do {
            try persistManagedFilesThrowing()
        } catch {
            // メタデータ保存失敗時は物理ロールバック
            try? fm.moveItem(at: destURL, to: sourceURL)
            managedFiles[idx] = previousItem
            clearPendingOperation()
            throw VideoFolderManager.FolderError.fileOperationFailed(
                String(format: NSLocalizedString("Failed to save file metadata: %@", comment: ""), error.localizedDescription)
            )
        }

        clearPendingOperation()
        return managedFiles[idx]
    }

    /// 一般ファイル（ZIP・PDF・TXT等）を指定フォルダ（空文字なら未分類 Downloads 直下）へ移動する
    /// - Parameters:
    ///   - item: 移動対象の ManagedFileItem
    ///   - rawTargetFolderName: 移動先フォルダ名（空文字なら未分類）
    ///   - folderManager: フォルダ実在確認・作成用の VideoFolderManager
    /// - Returns: 更新された ManagedFileItem（UUIDは100%維持）
    @discardableResult
    func moveManagedFile(
        _ item: ManagedFileItem,
        toFolder rawTargetFolderName: String,
        folderManager: VideoFolderManager
    ) throws -> ManagedFileItem {
        let cleanTarget = VideoFolderManager.sanitizedFolderName(rawTargetFolderName)
        let currentFolder = VideoFolderManager.sanitizedFolderName(item.folderName)

        // 同じ管理フォルダを選んだ場合は no-op（サブフォルダ階層構造を破壊せず維持）
        if cleanTarget.precomposedStringWithCanonicalMapping.caseInsensitiveCompare(currentFolder.precomposedStringWithCanonicalMapping) == .orderedSame {
            return item
        }

        let fm = FileManager.default
        let sourceURL = resolveFileURL(for: item)
        guard fm.fileExists(atPath: sourceURL.path) else {
            throw VideoFolderManager.FolderError.fileOperationFailed(
                NSLocalizedString("Source file not found.", comment: "")
            )
        }

        // 境界チェック: Vault / Trash / 一時復号再生領域のアクセスを厳格に禁止
        if FileClassification.isInsideVaultOrTempArea(sourceURL) {
            throw VideoFolderManager.FolderError.fileOperationFailed(
                NSLocalizedString("Cannot operate on files inside the Private Vault.", comment: "")
            )
        }

        // 移動先ディレクトリの特定
        let targetDir: URL
        var didCreateFolder = false
        if cleanTarget.isEmpty {
            targetDir = downloadsRootURL
        } else {
            if customDownloadsRootURL != nil {
                targetDir = downloadsRootURL.appendingPathComponent(cleanTarget, isDirectory: true)
                if !fm.fileExists(atPath: targetDir.path) {
                    try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
                    didCreateFolder = true
                }
                folderManager.registerLogicalFolderIfNeeded(cleanTarget)
            } else {
                let existed = folderManager.folders.contains(cleanTarget)
                do {
                    targetDir = try VideoFolderManager.ensureSubfolder(named: cleanTarget)
                    if !existed {
                        didCreateFolder = true
                        _ = folderManager.createFolder(name: cleanTarget)
                    }
                } catch {
                    throw VideoFolderManager.FolderError.fileOperationFailed(
                        NSLocalizedString("Failed to access destination folder.", comment: "")
                    )
                }
            }
        }

        // 移動先でのファイルURL生成（重複時は "(1)" 等の連番で安全に衝突回避）
        let destURL = Self.uniqueFileDestination(in: targetDir, baseName: item.title, fileExtension: item.fileExtension)

        // 宛先がDownloads管理領域内であることを境界検証
        let canonicalDest = destURL.standardizedFileURL.resolvingSymlinksInPath().path
        let canonicalRoot = downloadsRootURL.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = canonicalRoot.hasSuffix("/") ? canonicalRoot : canonicalRoot + "/"
        guard canonicalDest.hasPrefix(prefix) || canonicalDest == canonicalRoot else {
            throw VideoFolderManager.FolderError.fileOperationFailed(
                NSLocalizedString("Destination path is invalid.", comment: "")
            )
        }

        // 物理移動直前にも宛先ファイルの存在を再確認（上書き絶対防止）
        guard !fm.fileExists(atPath: destURL.path) else {
            throw VideoFolderManager.FolderError.alreadyExists
        }

        guard let destRelative = FileClassification.normalizedContainerRelativePath(for: destURL, customRootURL: customDownloadsRootURL) else {
            throw VideoFolderManager.FolderError.fileOperationFailed(
                NSLocalizedString("Destination path is invalid.", comment: "")
            )
        }

        // 移動前に障害復旧ジャーナルを記録
        let op = ManagedFilePendingOperation(
            operationID: UUID(),
            itemID: item.id,
            kind: .move,
            sourceRelativePath: item.normalizedRelativePath,
            destinationRelativePath: destRelative,
            originalTitle: item.title,
            destinationTitle: destURL.deletingPathExtension().lastPathComponent,
            originalFolderName: item.folderName,
            destinationFolderName: cleanTarget,
            fileExtension: item.fileExtension,
            createdAt: item.createdAt
        )
        try recordPendingOperation(op)

        // 物理移動実行
        do {
            try fm.moveItem(at: sourceURL, to: destURL)
        } catch {
            if didCreateFolder {
                let contents = (try? fm.contentsOfDirectory(atPath: targetDir.path)) ?? []
                if contents.isEmpty {
                    try? fm.removeItem(at: targetDir)
                }
            }
            clearPendingOperation()
            throw VideoFolderManager.FolderError.fileOperationFailed(
                String(format: NSLocalizedString("Failed to move file: %@", comment: ""), error.localizedDescription)
            )
        }

        // 物理移動成立確認
        guard fm.fileExists(atPath: destURL.path) && !fm.fileExists(atPath: sourceURL.path) else {
            if fm.fileExists(atPath: destURL.path) && fm.fileExists(atPath: sourceURL.path) {
                clearPendingOperation()
                throw VideoFolderManager.FolderError.fileOperationFailed(
                    NSLocalizedString("File move conflict occurred.", comment: "")
                )
            }
            try? fm.moveItem(at: destURL, to: sourceURL)
            if didCreateFolder {
                let contents = (try? fm.contentsOfDirectory(atPath: targetDir.path)) ?? []
                if contents.isEmpty { try? fm.removeItem(at: targetDir) }
            }
            clearPendingOperation()
            throw VideoFolderManager.FolderError.fileOperationFailed(
                NSLocalizedString("Failed to move file.", comment: "")
            )
        }

        // 移動元の空になった中間ディレクトリを安全に削除（管理フォルダ境界内のみ）
        Self.cleanEmptyIntermediateDirectoriesSafely(
            from: sourceURL.deletingLastPathComponent(),
            boundedBy: downloadsRootURL,
            folderName: currentFolder
        )

        // メタデータ更新（UUID維持、folderName更新、親直下配置のためrelativeSubpath=nil）
        guard let idx = managedFiles.firstIndex(where: { $0.id == item.id }) else {
            clearPendingOperation()
            throw VideoFolderManager.FolderError.fileOperationFailed(
                NSLocalizedString("Item not found in index.", comment: "")
            )
        }

        let previousItem = managedFiles[idx]
        managedFiles[idx].title = destURL.deletingPathExtension().lastPathComponent
        managedFiles[idx].folderName = cleanTarget
        managedFiles[idx].relativeSubpath = nil
        managedFiles[idx].relativePath = destRelative

        do {
            try persistManagedFilesThrowing()
        } catch {
            // メタデータ保存失敗時は物理ロールバック
            try? fm.moveItem(at: destURL, to: sourceURL)
            managedFiles[idx] = previousItem
            clearPendingOperation()
            throw VideoFolderManager.FolderError.fileOperationFailed(
                String(format: NSLocalizedString("Failed to save file metadata: %@", comment: ""), error.localizedDescription)
            )
        }

        clearPendingOperation()
        return managedFiles[idx]
    }

    // MARK: - 外部ZIPファイルのインポート（ストリーミングコピー・メモリ一括読込なし）

    @discardableResult
    func importExternalFile(
        from sourceURL: URL,
        targetFolderName: String,
        downloads: DownloadCenter,
        folderManager: VideoFolderManager
    ) throws -> ManagedFileItem {
        let ext = sourceURL.pathExtension.lowercased()
        guard ext == "zip" else {
            throw ZipOperationError.invalidArchive
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: sourceURL.path) else {
            throw ZipOperationError.fileNotFound
        }

        let cleanFolder = VideoFolderManager.sanitizedFolderName(targetFolderName)
        let targetDir: URL
        if cleanFolder.isEmpty {
            targetDir = downloadsRootURL
        } else {
            if !folderManager.folders.contains(cleanFolder) {
                _ = folderManager.createFolder(name: cleanFolder)
            }
            targetDir = downloadsRootURL.appendingPathComponent(cleanFolder, isDirectory: true)
            try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        }

        let rawBaseName = sourceURL.deletingPathExtension().lastPathComponent
        let cleanBase = FileNaming.sanitizedBaseName(rawBaseName)
        let destURL = FileNaming.uniqueDestination(
            in: targetDir,
            baseName: cleanBase.isEmpty ? "Archive" : cleanBase,
            fileExtension: "zip"
        )

        // Data(contentsOf:) を使わず FileManager.copyItem でストリームコピー
        try fm.copyItem(at: sourceURL, to: destURL)

        let attrs = (try? fm.attributesOfItem(atPath: destURL.path)) ?? [:]
        let byteSize = (attrs[.size] as? Int64) ?? 0
        guard let normRel = FileClassification.normalizedContainerRelativePath(for: destURL, customRootURL: customDownloadsRootURL) else {
            try? fm.removeItem(at: destURL)
            throw ZipOperationError.ioError(NSLocalizedString("Failed to resolve imported file path.", comment: ""))
        }

        let newItem = ManagedFileItem(
            id: UUID(),
            title: destURL.deletingPathExtension().lastPathComponent,
            relativePath: normRel,
            fileExtension: "zip",
            createdAt: Date(),
            byteSize: byteSize,
            folderName: cleanFolder,
            relativeSubpath: nil
        )

        managedFiles.insert(newItem, at: 0)
        persistManagedFiles()
        folderManager.syncWithFileSystemAndSavedVideos()
        return newItem
    }

    // MARK: - 進行中ジョブのキャンセル

    func cancelCurrentOperation() {
        activeCancellationToken?.cancel()
    }

    // MARK: - ZIP展開（ステージング・ディレクトリ境界検証・重複/型衝突拒否・実行時サイズ制限・CRC検証）

    /// ZIPファイルを新しいフォルダへ安全に展開する
    /// - Returns: 作成された展開先フォルダ名
    @discardableResult
    func extractZip(
        item: ManagedFileItem,
        downloads: DownloadCenter,
        folderManager: VideoFolderManager,
        limits: ZipSecurityLimits = .standard
    ) async throws -> String {
        guard activeOperation == nil else {
            throw ZipOperationError.operationInProgress
        }

        let sourceZipURL = resolveFileURL(for: item)
        guard FileManager.default.fileExists(atPath: sourceZipURL.path) else {
            throw ZipOperationError.fileNotFound
        }

        let opID = UUID()
        let token = ZipCancellationToken()
        activeCancellationToken = token
        Self.registerActiveOperation(opID)

        activeOperation = ZipOperationStatus(
            id: opID,
            kind: .extracting,
            targetTitle: item.title,
            fractionCompleted: 0.0,
            currentEntryName: item.title
        )

        defer {
            Self.unregisterActiveOperation(opID)
            activeCancellationToken = nil
            activeOperation = nil
        }

        let stagingRoot = stagingRootDirectoryURL
        let downloadsRoot = downloadsRootURL
        let baseFolderName = FileNaming.sanitizedBaseName(item.title).isEmpty ? "Extracted" : FileNaming.sanitizedBaseName(item.title)

        // ZIPファイルが存在する親ディレクトリ（同階層への展開先親ディレクトリ）を特定し、Downloads管理領域内であることを厳格検証
        let targetParentDir = sourceZipURL.deletingLastPathComponent()
        let canonicalDownloadsRoot = downloadsRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let canonicalDownloadsPrefix = canonicalDownloadsRoot.hasSuffix("/") ? canonicalDownloadsRoot : canonicalDownloadsRoot + "/"
        let canonicalTargetParent = targetParentDir.standardizedFileURL.resolvingSymlinksInPath().path

        guard (canonicalTargetParent == canonicalDownloadsRoot || canonicalTargetParent.hasPrefix(canonicalDownloadsPrefix)),
              !FileClassification.isInsideVaultOrTempArea(targetParentDir) else {
            throw ZipOperationError.maliciousPathDetected(sourceZipURL.lastPathComponent)
        }

        // トップレベル（Downloads直下）にあるZIPかどうかを判定
        let isTopLevelParent = (canonicalTargetParent == canonicalDownloadsRoot)
            && item.folderName.isEmpty
            && (item.relativeSubpath == nil || item.relativeSubpath?.isEmpty == true)

        // バックグラウンドタスクで展開・全検証を実行（メインスレッドを占有しない）
        let extractedFolderName: String = try await Task.detached(priority: .userInitiated) { [weak self] in
            let fm = FileManager.default
            let opStagingDir = stagingRoot.appendingPathComponent(opID.uuidString, isDirectory: true)
            let stagingExtractRoot = opStagingDir.appendingPathComponent("content", isDirectory: true)

            // 失敗・キャンセル時はステージングディレクトリを確実に完全除去
            defer {
                try? fm.removeItem(at: opStagingDir)
            }

            try fm.createDirectory(at: stagingExtractRoot, withIntermediateDirectories: true)

            // 1. バイナリヘッダ事前検査（パスワード保護・破損チェック）
            let headerInfo = try ZipBinaryInspector.inspectArchiveHeaders(at: sourceZipURL)
            if headerInfo.hasEncryptedEntry {
                throw ZipOperationError.passwordProtected
            }

            // 2. ZIPFoundation Archive オープン
            let archive: Archive
            do {
                archive = try Archive(url: sourceZipURL, accessMode: .read)
            } catch {
                throw ZipOperationError.corruptedArchive
            }

            let allEntries = Array(archive)
            // EOCD に記録されたエントリ数より少ない場合、Entry.init? が暗号化または破損により nil を返したことを意味する
            if headerInfo.expectedEntryCount > 0 && allEntries.count < headerInfo.expectedEntryCount {
                throw ZipOperationError.corruptedArchive
            }
            guard !allEntries.isEmpty else {
                throw ZipOperationError.invalidArchive
            }

            // 3. 事前検証フェーズ（パス安全性、シンボリックリンク、重複・ファイル/ディレクトリ型衝突、件数、宣言サイズ、圧縮率）
            let canonicalStagingRoot = stagingExtractRoot.standardizedFileURL.resolvingSymlinksInPath().path
            let canonicalStagingPrefix = canonicalStagingRoot.hasSuffix("/") ? canonicalStagingRoot : canonicalStagingRoot + "/"

            var seenFilePathsLower: Set<String> = []
            var seenDirectoryPathsLower: Set<String> = []
            var declaredTotalUncompressed: Int64 = 0
            var validEntriesToExtract: [(entry: Entry, sanitizedRelPath: String, destURL: URL)] = []

            for entry in allEntries {
                if Task.isCancelled || token.isCancelled {
                    throw ZipOperationError.cancelled
                }

                let rawPath = entry.path

                // シンボリックリンクは即時拒否
                if entry.type == .symlink {
                    throw ZipOperationError.symlinkNotAllowed(rawPath)
                }
                if (entry.fileAttributes[.type] as? FileAttributeType) == .typeSymbolicLink {
                    throw ZipOperationError.symlinkNotAllowed(rawPath)
                }

                // ヌルバイト・バックスラッシュ・空パス・絶対パス拒否
                if rawPath.isEmpty || rawPath.contains("\0") || rawPath.contains("\\") {
                    throw ZipOperationError.maliciousPathDetected(rawPath)
                }
                if rawPath.hasPrefix("/") || rawPath.hasPrefix("~") || rawPath.range(of: #"^[A-Za-z]:"#, options: .regularExpression) != nil {
                    throw ZipOperationError.maliciousPathDetected(rawPath)
                }

                let rawComponents = rawPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
                var cleanComponents: [String] = []
                for (compIdx, comp) in rawComponents.enumerated() {
                    if comp.isEmpty {
                        // 末尾の "/"（ディレクトリ表現）以外は不正な連続スラッシュとして拒否
                        if compIdx == rawComponents.count - 1 && entry.type == .directory {
                            continue
                        }
                        if compIdx < rawComponents.count - 1 {
                            throw ZipOperationError.maliciousPathDetected(rawPath)
                        }
                        continue
                    }
                    if comp == "." || comp == ".." {
                        throw ZipOperationError.maliciousPathDetected(rawPath)
                    }
                    cleanComponents.append(comp.precomposedStringWithCanonicalMapping)
                }

                guard !cleanComponents.isEmpty else { continue }

                // macOS 固有のメタデータエントリ（__MACOSX / .DS_Store）はスキップ
                if cleanComponents.first == "__MACOSX" || cleanComponents.last == ".DS_Store" {
                    continue
                }

                // 隠しファイル（"."始まり）が含まれる不正エントリを拒否
                if cleanComponents.contains(where: { $0.hasPrefix(".") }) {
                    throw ZipOperationError.maliciousPathDetected(rawPath)
                }

                let sanitizedRelPath = cleanComponents.joined(separator: "/")
                let lowerRelPath = sanitizedRelPath.lowercased()

                // ディレクトリ境界を考慮した正規化パス検証
                let destURL = stagingExtractRoot.appendingPathComponent(sanitizedRelPath, isDirectory: entry.type == .directory)
                let canonicalDest = destURL.standardizedFileURL.resolvingSymlinksInPath().path
                guard canonicalDest.hasPrefix(canonicalStagingPrefix),
                      canonicalDest.count > canonicalStagingPrefix.count else {
                    throw ZipOperationError.maliciousPathDetected(rawPath)
                }

                // 重複パスおよびファイル・ディレクトリの型衝突検証
                switch entry.type {
                case .file:
                    if seenFilePathsLower.contains(lowerRelPath) || seenDirectoryPathsLower.contains(lowerRelPath) {
                        throw ZipOperationError.conflictingEntries(sanitizedRelPath)
                    }
                    // すべての親ディレクトリパスが既存のファイルと衝突していないか確認
                    if cleanComponents.count > 1 {
                        for depth in 1..<(cleanComponents.count) {
                            let ancestor = cleanComponents.prefix(depth).joined(separator: "/").lowercased()
                            if seenFilePathsLower.contains(ancestor) {
                                throw ZipOperationError.conflictingEntries(sanitizedRelPath)
                            }
                            seenDirectoryPathsLower.insert(ancestor)
                        }
                    }
                    seenFilePathsLower.insert(lowerRelPath)

                case .directory:
                    if seenFilePathsLower.contains(lowerRelPath) {
                        throw ZipOperationError.conflictingEntries(sanitizedRelPath)
                    }
                    for depth in 1...cleanComponents.count {
                        let ancestor = cleanComponents.prefix(depth).joined(separator: "/").lowercased()
                        if seenFilePathsLower.contains(ancestor) {
                            throw ZipOperationError.conflictingEntries(sanitizedRelPath)
                        }
                        seenDirectoryPathsLower.insert(ancestor)
                    }

                case .symlink:
                    throw ZipOperationError.symlinkNotAllowed(rawPath)
                }

                // エントリ件数上限検証
                if seenFilePathsLower.count > limits.maxEntryCount {
                    throw ZipOperationError.entryCountLimitExceeded(limits.maxEntryCount)
                }

                // ヘッダ宣言サイズ・圧縮率の事前検証
                let uncompressed = Int64(clamping: entry.uncompressedSize)
                let compressed = Int64(clamping: entry.compressedSize)

                if uncompressed > limits.maxSingleFileBytes {
                    throw ZipOperationError.uncompressedSizeLimitExceeded(uncompressed)
                }
                declaredTotalUncompressed += uncompressed
                if declaredTotalUncompressed > limits.maxTotalUncompressedBytes {
                    throw ZipOperationError.uncompressedSizeLimitExceeded(declaredTotalUncompressed)
                }

                // 誤拒否を防ぎつつ明確な ZIP Bomb を拒否する複合圧縮率チェック
                if uncompressed >= limits.suspiciousRatioMinUncompressedBytes {
                    let ratio = Double(uncompressed) / Double(max(1, compressed))
                    if ratio > limits.maxSuspiciousCompressionRatio {
                        throw ZipOperationError.suspiciousCompressionRatio
                    }
                }

                validEntriesToExtract.append((entry, sanitizedRelPath, destURL))
            }

            guard !seenFilePathsLower.isEmpty else {
                throw ZipOperationError.invalidArchive
            }

            // 4. 空き容量チェック
            if let freeSpace = Self.availableDiskSpace(at: downloadsRoot) {
                let required = declaredTotalUncompressed + limits.requiredFreeSpaceMarginBytes
                if freeSpace < required {
                    throw ZipOperationError.insufficientDiskSpace
                }
            }

            // 5. チャンク単位の実行時バイト計測＋CRC32検証付き展開
            var runtimeTotalBytesWritten: Int64 = 0
            var runtimeExtractedFileCount: Int = 0
            let totalEntriesCount = max(1, validEntriesToExtract.count)
            var lastUIUpdateTime = Date.distantPast

            for (index, itemToExtract) in validEntriesToExtract.enumerated() {
                if Task.isCancelled || token.isCancelled {
                    throw ZipOperationError.cancelled
                }

                let entry = itemToExtract.entry
                let destURL = itemToExtract.destURL

                switch entry.type {
                case .directory:
                    try fm.createDirectory(at: destURL, withIntermediateDirectories: true)

                case .file:
                    runtimeExtractedFileCount += 1
                    if runtimeExtractedFileCount > limits.maxEntryCount {
                        throw ZipOperationError.entryCountLimitExceeded(limits.maxEntryCount)
                    }

                    let parentDir = destURL.deletingLastPathComponent()
                    try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)

                    // 親ディレクトリを含めシンボリックリンクが紛れ込んでいないか再確認
                    let canonicalParent = parentDir.standardizedFileURL.resolvingSymlinksInPath().path
                    guard canonicalParent == canonicalStagingRoot || canonicalParent.hasPrefix(canonicalStagingPrefix) else {
                        throw ZipOperationError.maliciousPathDetected(itemToExtract.sanitizedRelPath)
                    }

                    guard fm.createFile(atPath: destURL.path, contents: nil) else {
                        throw ZipOperationError.ioError(NSLocalizedString("Failed to create extracted file.", comment: ""))
                    }

                    let writeHandle = try FileHandle(forWritingTo: destURL)
                    var entryBytesWritten: Int64 = 0

                    do {
                        let computedCRC = try archive.extract(
                            entry,
                            bufferSize: Self.streamBufferSize,
                            skipCRC32: false,
                            progress: nil
                        ) { chunk in
                            if Task.isCancelled || token.isCancelled {
                                throw ZipOperationError.cancelled
                            }

                            let chunkLen = Int64(chunk.count)
                            entryBytesWritten += chunkLen
                            runtimeTotalBytesWritten += chunkLen

                            // ヘッダ偽装を含む実サイズ上限超過を書き込み前に即時停止
                            if entryBytesWritten > limits.maxSingleFileBytes {
                                throw ZipOperationError.uncompressedSizeLimitExceeded(entryBytesWritten)
                            }
                            if runtimeTotalBytesWritten > limits.maxTotalUncompressedBytes {
                                throw ZipOperationError.uncompressedSizeLimitExceeded(runtimeTotalBytesWritten)
                            }

                            // 実行中に宣言サイズを大きく超えて膨張するヘッダ偽装 ZIP Bomb も検知
                            if entryBytesWritten >= limits.suspiciousRatioMinUncompressedBytes {
                                let compressed = max(1, Int64(clamping: entry.compressedSize))
                                let runtimeRatio = Double(entryBytesWritten) / Double(compressed)
                                if runtimeRatio > limits.maxSuspiciousCompressionRatio {
                                    throw ZipOperationError.suspiciousCompressionRatio
                                }
                            }

                            try writeHandle.write(contentsOf: chunk)

                            let now = Date()
                            if now.timeIntervalSince(lastUIUpdateTime) >= 0.1 {
                                lastUIUpdateTime = now
                                let fraction: Double
                                if declaredTotalUncompressed > 0 {
                                    fraction = min(0.95, Double(runtimeTotalBytesWritten) / Double(declaredTotalUncompressed))
                                } else {
                                    fraction = min(0.95, Double(index) / Double(totalEntriesCount))
                                }
                                let entryName = destURL.lastPathComponent
                                Task { @MainActor [weak self] in
                                    guard let self = self, self.activeOperation?.id == opID else { return }
                                    self.activeOperation?.fractionCompleted = fraction
                                    self.activeOperation?.currentEntryName = entryName
                                }
                            }
                        }
                        try writeHandle.close()
                        // CRC32 チェックサムの厳格な一致検証
                        guard computedCRC == entry.checksum else {
                            throw ZipOperationError.corruptedArchive
                        }
                    } catch let zipErr as ZipOperationError {
                        try? writeHandle.close()
                        throw zipErr
                    } catch let archiveErr as Archive.ArchiveError {
                        try? writeHandle.close()
                        switch archiveErr {
                        case .cancelledOperation:
                            throw ZipOperationError.cancelled
                        case .uncontainedSymlink:
                            throw ZipOperationError.symlinkNotAllowed(itemToExtract.sanitizedRelPath)
                        case .invalidEntryPath:
                            throw ZipOperationError.maliciousPathDetected(itemToExtract.sanitizedRelPath)
                        default:
                            throw ZipOperationError.corruptedArchive
                        }
                    } catch {
                        try? writeHandle.close()
                        throw ZipOperationError.corruptedArchive
                    }

                case .symlink:
                    throw ZipOperationError.symlinkNotAllowed(itemToExtract.sanitizedRelPath)
                }
            }

            if Task.isCancelled || token.isCancelled {
                throw ZipOperationError.cancelled
            }

            // 6. 全エントリの展開＋CRC検証が完了したため、ZIPと同じ階層内の最終配置先フォルダ名を決定し、境界検証のうえアトミックに移動
            let finalFolderURL = Self.uniqueDirectoryDestination(in: targetParentDir, baseName: baseFolderName)
            let canonicalFinalFolder = finalFolderURL.standardizedFileURL.resolvingSymlinksInPath().path
            guard canonicalFinalFolder.hasPrefix(canonicalDownloadsPrefix),
                  canonicalFinalFolder.count > canonicalDownloadsPrefix.count,
                  !FileClassification.isInsideVaultOrTempArea(finalFolderURL) else {
                throw ZipOperationError.maliciousPathDetected(baseFolderName)
            }
            let finalFolderName = finalFolderURL.lastPathComponent

            try fm.moveItem(at: stagingExtractRoot, to: finalFolderURL)
            return finalFolderName
        }.value

        // 7. 展開されたフォルダおよび内部の全ファイル（動画・画像・一般ファイル）をインデックスへ同期
        // ZIPがトップレベルにある場合のみ新しいトップレベル管理フォルダを登録し、既存フォルダ内展開では不要なトップレベルフォルダを作らない
        if isTopLevelParent {
            if customDownloadsRootURL == nil {
                _ = folderManager.createFolder(name: extractedFolderName)
            } else {
                folderManager.registerLogicalFolderIfNeeded(extractedFolderName)
            }
        }
        if customDownloadsRootURL == nil {
            folderManager.syncWithFileSystemAndSavedVideos()
        }
        syncWithFileSystem(downloads: downloads, folderManager: folderManager)

        return extractedFolderName
    }

    // MARK: - フォルダ単位のZIP圧縮（Phase F1）

    /// 指定された管理フォルダ配下の全ファイル（ネスト階層を含む）を `.zip` に圧縮する（元のフォルダ・元ファイルは保持）
    /// - Note: HLS（`.movpkg`）が論理所属または物理ファイルとして1件でも含まれる場合は圧縮を中止してエラーを投げる。
    @discardableResult
    func compressFolder(
        named rawFolderName: String,
        downloads: DownloadCenter,
        folderManager: VideoFolderManager
    ) async throws -> ManagedFileItem {
        guard activeOperation == nil else {
            throw ZipOperationError.operationInProgress
        }

        let cleanFolder = VideoFolderManager.sanitizedFolderName(rawFolderName)
        guard !cleanFolder.isEmpty else {
            throw ZipOperationError.fileNotFound
        }

        let root = downloadsRootURL
        let folderURL = root.appendingPathComponent(cleanFolder, isDirectory: true)
        guard FileNaming.isDirectChild(folderURL, of: root),
              !FileClassification.isInsideVaultOrTempArea(folderURL) else {
            throw ZipOperationError.maliciousPathDetected(cleanFolder)
        }

        // 1. 論理フォルダ所属のHLS動画チェック（一部のみ圧縮して成功扱いにすることを厳格防止）
        let hasLogicalHLS = downloads.saved.contains { video in
            folderManager.folderName(for: video) == cleanFolder &&
            (video.isHLS || video.format == .hls || video.fileURL.pathExtension.lowercased() == "movpkg")
        }
        if hasLogicalHLS {
            throw ZipOperationError.unsupportedSourceForCompression(
                NSLocalizedString("This folder contains HLS videos that cannot be compressed into a ZIP archive.", comment: "")
            )
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: folderURL.path) else {
            throw ZipOperationError.fileNotFound
        }
        if (try? folderURL.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            throw ZipOperationError.symlinkNotAllowed(cleanFolder)
        }

        // 2. 圧縮開始前に対象フォルダ内の全項目を再帰走査・検証（HLS .movpkg、シンボリックリンク、Vault領域の排除）
        let canonicalFolderRoot = folderURL.standardizedFileURL.resolvingSymlinksInPath().path
        let canonicalFolderPrefix = canonicalFolderRoot.hasSuffix("/") ? canonicalFolderRoot : canonicalFolderRoot + "/"

        struct FolderEntrySource: Sendable {
            let sourceURL: URL
            let relativeEntryPath: String
            let fileSize: Int64
        }

        var entriesToCompress: [FolderEntrySource] = []
        var totalSourceBytes: Int64 = 0

        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        if let enumerator = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: resourceKeys,
            options: []
        ) {
            for case let itemURL as URL in enumerator {
                let rawValues = try? itemURL.resourceValues(forKeys: Set(resourceKeys))

                // シンボリックリンクは辿らず即座に拒否
                if rawValues?.isSymbolicLink == true {
                    throw ZipOperationError.symlinkNotAllowed(itemURL.lastPathComponent)
                }

                // Private Vault / 一時再生領域の混入を拒否
                if FileClassification.isInsideVaultOrTempArea(itemURL) {
                    throw ZipOperationError.unsupportedSourceForCompression(
                        NSLocalizedString("Private Vault files cannot be compressed into normal ZIP archives.", comment: "")
                    )
                }

                // 物理的な HLS (.movpkg) パッケージがフォルダ内に存在する場合も明確なエラーで中止
                let lowerName = itemURL.lastPathComponent.lowercased()
                let lowerPath = itemURL.path.lowercased()
                if itemURL.pathExtension.lowercased() == "movpkg" || lowerPath.contains(".movpkg/") {
                    throw ZipOperationError.unsupportedSourceForCompression(
                        NSLocalizedString("This folder contains HLS videos that cannot be compressed into a ZIP archive.", comment: "")
                    )
                }

                // システムメタデータディレクトリ (__MACOSX) や隠しディレクトリはスキップ
                if lowerName == "__macosx" || lowerName == ".ds_store" || lowerName.hasPrefix(".") {
                    if rawValues?.isDirectory == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }

                let canonicalItem = itemURL.standardizedFileURL.resolvingSymlinksInPath().path
                guard canonicalItem.hasPrefix(canonicalFolderPrefix),
                      canonicalItem.count > canonicalFolderPrefix.count else {
                    throw ZipOperationError.maliciousPathDetected(itemURL.lastPathComponent)
                }

                let relPath = String(canonicalItem.dropFirst(canonicalFolderPrefix.count))
                    .replacingOccurrences(of: "\\", with: "/")
                let components = relPath.split(separator: "/").map(String.init)
                guard !components.isEmpty,
                      !components.contains(".."),
                      !components.contains("."),
                      !components.contains(where: { $0.hasPrefix(".") || $0.lowercased() == "__macosx" }) else {
                    continue
                }

                if rawValues?.isRegularFile == true {
                    let ext = itemURL.pathExtension.lowercased()
                    // ダウンロード途中の一時ファイルは除外
                    if ["tmp", "part", "crdownload", "download"].contains(ext) {
                        continue
                    }
                    let fSize = Int64(rawValues?.fileSize ?? 0)
                    let joinedRel = components.joined(separator: "/")
                    entriesToCompress.append(FolderEntrySource(
                        sourceURL: itemURL,
                        relativeEntryPath: joinedRel,
                        fileSize: fSize
                    ))
                    totalSourceBytes += fSize
                }
            }
        }

        entriesToCompress.sort {
            $0.relativeEntryPath.localizedStandardCompare($1.relativeEntryPath) == .orderedAscending
        }

        guard !entriesToCompress.isEmpty else {
            throw ZipOperationError.unsupportedSourceForCompression(
                NSLocalizedString("This folder is empty and cannot be compressed.", comment: "")
            )
        }

        if let freeSpace = Self.availableDiskSpace(at: root),
           freeSpace < totalSourceBytes + 32 * 1024 * 1024 {
            throw ZipOperationError.insufficientDiskSpace
        }

        let opID = UUID()
        let token = ZipCancellationToken()
        activeCancellationToken = token
        Self.registerActiveOperation(opID)

        activeOperation = ZipOperationStatus(
            id: opID,
            kind: .compressing,
            targetTitle: cleanFolder,
            fractionCompleted: 0.0,
            currentEntryName: cleanFolder
        )

        defer {
            Self.unregisterActiveOperation(opID)
            activeCancellationToken = nil
            activeOperation = nil
        }

        let stagingRoot = stagingRootDirectoryURL
        let capturedEntries = entriesToCompress
        let capturedTotalBytes = max(1, totalSourceBytes)

        let finalZipURL: URL = try await Task.detached(priority: .userInitiated) { [weak self] in
            let fileManager = FileManager.default
            let opStagingDir = stagingRoot.appendingPathComponent(opID.uuidString, isDirectory: true)
            let stagingZipURL = opStagingDir.appendingPathComponent("output.zip")

            defer {
                try? fileManager.removeItem(at: opStagingDir)
            }

            try fileManager.createDirectory(at: opStagingDir, withIntermediateDirectories: true)

            let archive: Archive
            do {
                archive = try Archive(url: stagingZipURL, accessMode: .create)
            } catch {
                throw ZipOperationError.ioError(NSLocalizedString("Failed to initialize ZIP archive.", comment: ""))
            }

            var cumulativeBytesRead: Int64 = 0
            var lastUIUpdate = Date.distantPast

            for (idx, entrySource) in capturedEntries.enumerated() {
                if Task.isCancelled || token.isCancelled {
                    throw ZipOperationError.cancelled
                }

                guard fileManager.fileExists(atPath: entrySource.sourceURL.path) else {
                    throw ZipOperationError.fileNotFound
                }

                let modDate = ((try? fileManager.attributesOfItem(atPath: entrySource.sourceURL.path))?[.modificationDate] as? Date) ?? Date()
                let readHandle: FileHandle
                do {
                    readHandle = try FileHandle(forReadingFrom: entrySource.sourceURL)
                } catch {
                    throw ZipOperationError.fileNotFound
                }
                defer { try? readHandle.close() }

                do {
                    try archive.addEntry(
                        with: entrySource.relativeEntryPath,
                        type: .file,
                        uncompressedSize: entrySource.fileSize,
                        modificationDate: modDate,
                        permissions: 0o644,
                        compressionMethod: .deflate,
                        bufferSize: Self.streamBufferSize,
                        progress: nil
                    ) { position, size in
                        if Task.isCancelled || token.isCancelled {
                            throw Archive.ArchiveError.cancelledOperation
                        }
                        try readHandle.seek(toOffset: UInt64(position))
                        let data = (try readHandle.read(upToCount: size)) ?? Data()
                        cumulativeBytesRead += Int64(data.count)

                        let now = Date()
                        if now.timeIntervalSince(lastUIUpdate) >= 0.08 {
                            lastUIUpdate = now
                            let byteFrac = Double(cumulativeBytesRead) / Double(capturedTotalBytes)
                            let countFrac = Double(idx + 1) / Double(capturedEntries.count)
                            let frac = min(0.95, max(byteFrac, countFrac * 0.2))
                            let currentName = entrySource.sourceURL.lastPathComponent
                            Task { @MainActor [weak self] in
                                guard let self = self, self.activeOperation?.id == opID else { return }
                                self.activeOperation?.fractionCompleted = frac
                                self.activeOperation?.currentEntryName = currentName
                            }
                        }
                        return data
                    }
                } catch Archive.ArchiveError.cancelledOperation {
                    throw ZipOperationError.cancelled
                } catch let zipErr as ZipOperationError {
                    throw zipErr
                } catch {
                    throw ZipOperationError.ioError(error.localizedDescription)
                }
            }

            if Task.isCancelled || token.isCancelled {
                throw ZipOperationError.cancelled
            }

            let destURL = Self.uniqueFileDestination(
                in: root,
                baseName: cleanFolder,
                fileExtension: "zip"
            )
            guard FileNaming.isDirectChild(destURL, of: root) else {
                throw ZipOperationError.maliciousPathDetected(cleanFolder)
            }

            try fileManager.moveItem(at: stagingZipURL, to: destURL)
            return destURL
        }.value

        let attrs = (try? fm.attributesOfItem(atPath: finalZipURL.path)) ?? [:]
        let zipByteSize = (attrs[.size] as? Int64) ?? 0
        guard let normRel = FileClassification.normalizedContainerRelativePath(for: finalZipURL, customRootURL: customDownloadsRootURL) else {
            throw ZipOperationError.ioError(NSLocalizedString("Failed to register created ZIP file.", comment: ""))
        }

        let createdItem = ManagedFileItem(
            id: UUID(),
            title: finalZipURL.deletingPathExtension().lastPathComponent,
            relativePath: normRel,
            fileExtension: "zip",
            createdAt: Date(),
            byteSize: zipByteSize,
            folderName: "",
            relativeSubpath: nil
        )

        managedFiles.removeAll { $0.normalizedRelativePath == normRel }
        managedFiles.insert(createdItem, at: 0)
        persistManagedFiles()
        return createdItem
    }

    // MARK: - 単体ファイルのZIP圧縮（Phase F1）

    /// 単体の `SavedVideo`（動画・画像）を同じフォルダ内に `.zip` 圧縮する（元のファイルは保持）
    @discardableResult
    func compressSingleVideo(
        _ video: SavedVideo,
        downloads: DownloadCenter,
        folderManager: VideoFolderManager
    ) async throws -> ManagedFileItem {
        if video.isHLS || video.format == .hls || video.fileURL.pathExtension.lowercased() == "movpkg" {
            throw ZipOperationError.unsupportedSourceForCompression(
                NSLocalizedString("HLS streaming packages (.movpkg) cannot be compressed to ZIP.", comment: "")
            )
        }
        let sourceURL = video.fileURL
        let folderName = folderManager.folderName(for: video)
        return try await compressSingleFileAtURL(
            sourceURL: sourceURL,
            preferredBaseName: video.title,
            folderName: folderName,
            downloads: downloads,
            folderManager: folderManager
        )
    }

    /// 単体の一般ファイル（非ZIPの `ManagedFileItem`）を同じフォルダ内に `.zip` 圧縮する
    @discardableResult
    func compressSingleManagedFile(
        _ item: ManagedFileItem,
        downloads: DownloadCenter,
        folderManager: VideoFolderManager
    ) async throws -> ManagedFileItem {
        let sourceURL = resolveFileURL(for: item)
        return try await compressSingleFileAtURL(
            sourceURL: sourceURL,
            preferredBaseName: item.title,
            folderName: item.folderName,
            downloads: downloads,
            folderManager: folderManager
        )
    }

    @discardableResult
    func compressSingleFileAtURL(
        sourceURL: URL,
        preferredBaseName: String,
        folderName: String,
        downloads: DownloadCenter,
        folderManager: VideoFolderManager
    ) async throws -> ManagedFileItem {
        guard activeOperation == nil else {
            throw ZipOperationError.operationInProgress
        }

        // Private Vault 領域・一時復号領域・HLS .movpkg・シンボリックリンクの圧縮を厳格に拒否
        if FileClassification.isInsideVaultOrTempArea(sourceURL) {
            throw ZipOperationError.unsupportedSourceForCompression(
                NSLocalizedString("Private Vault files cannot be compressed into normal ZIP archives.", comment: "")
            )
        }
        if sourceURL.pathExtension.lowercased() == "movpkg" {
            throw ZipOperationError.unsupportedSourceForCompression(
                NSLocalizedString("HLS streaming packages (.movpkg) cannot be compressed to ZIP.", comment: "")
            )
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: sourceURL.path) else {
            throw ZipOperationError.fileNotFound
        }
        let resourceValues = try? sourceURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        if resourceValues?.isSymbolicLink == true {
            throw ZipOperationError.symlinkNotAllowed(sourceURL.lastPathComponent)
        }
        guard resourceValues?.isRegularFile == true else {
            throw ZipOperationError.unsupportedSourceForCompression(
                NSLocalizedString("Only regular files can be compressed in this operation.", comment: "")
            )
        }

        let sourceSize = Int64(resourceValues?.fileSize ?? 0)
        if let freeSpace = Self.availableDiskSpace(at: downloadsRootURL),
           freeSpace < sourceSize + 32 * 1024 * 1024 {
            throw ZipOperationError.insufficientDiskSpace
        }

        let opID = UUID()
        let token = ZipCancellationToken()
        activeCancellationToken = token
        Self.registerActiveOperation(opID)

        let cleanBase = FileNaming.sanitizedBaseName(preferredBaseName).isEmpty
            ? FileNaming.sanitizedBaseName(sourceURL.deletingPathExtension().lastPathComponent)
            : FileNaming.sanitizedBaseName(preferredBaseName)
        let archiveBaseName = cleanBase.isEmpty ? "Archive" : cleanBase

        activeOperation = ZipOperationStatus(
            id: opID,
            kind: .compressing,
            targetTitle: archiveBaseName,
            fractionCompleted: 0.0,
            currentEntryName: sourceURL.lastPathComponent
        )

        defer {
            Self.unregisterActiveOperation(opID)
            activeCancellationToken = nil
            activeOperation = nil
        }

        let stagingRoot = stagingRootDirectoryURL
        let parentDir = sourceURL.deletingLastPathComponent()

        let finalZipURL: URL = try await Task.detached(priority: .userInitiated) { [weak self] in
            let fileManager = FileManager.default
            let opStagingDir = stagingRoot.appendingPathComponent(opID.uuidString, isDirectory: true)
            let stagingZipURL = opStagingDir.appendingPathComponent("output.zip")

            defer {
                try? fileManager.removeItem(at: opStagingDir)
            }

            try fileManager.createDirectory(at: opStagingDir, withIntermediateDirectories: true)

            let archive: Archive
            do {
                archive = try Archive(url: stagingZipURL, accessMode: .create)
            } catch {
                throw ZipOperationError.ioError(NSLocalizedString("Failed to initialize ZIP archive.", comment: ""))
            }

            let entryName = sourceURL.lastPathComponent
            let modDate = ((try? fileManager.attributesOfItem(atPath: sourceURL.path))?[.modificationDate] as? Date) ?? Date()

            let readHandle: FileHandle
            do {
                readHandle = try FileHandle(forReadingFrom: sourceURL)
            } catch {
                throw ZipOperationError.fileNotFound
            }
            defer { try? readHandle.close() }

            var bytesReadTotal: Int64 = 0
            var lastUIUpdate = Date.distantPast

            do {
                try archive.addEntry(
                    with: entryName,
                    type: .file,
                    uncompressedSize: sourceSize,
                    modificationDate: modDate,
                    permissions: 0o644,
                    compressionMethod: .deflate,
                    bufferSize: Self.streamBufferSize,
                    progress: nil
                ) { position, size in
                    if Task.isCancelled || token.isCancelled {
                        throw Archive.ArchiveError.cancelledOperation
                    }
                    try readHandle.seek(toOffset: UInt64(position))
                    let data = (try readHandle.read(upToCount: size)) ?? Data()
                    bytesReadTotal += Int64(data.count)

                    let now = Date()
                    if now.timeIntervalSince(lastUIUpdate) >= 0.1 {
                        lastUIUpdate = now
                        let frac = sourceSize > 0 ? min(0.95, Double(bytesReadTotal) / Double(sourceSize)) : 0.5
                        Task { @MainActor [weak self] in
                            guard let self = self, self.activeOperation?.id == opID else { return }
                            self.activeOperation?.fractionCompleted = frac
                        }
                    }
                    return data
                }
            } catch Archive.ArchiveError.cancelledOperation {
                throw ZipOperationError.cancelled
            } catch let zipErr as ZipOperationError {
                throw zipErr
            } catch {
                throw ZipOperationError.ioError(error.localizedDescription)
            }

            if Task.isCancelled || token.isCancelled {
                throw ZipOperationError.cancelled
            }

            let destURL = Self.uniqueFileDestination(
                in: parentDir,
                baseName: archiveBaseName,
                fileExtension: "zip"
            )
            try fileManager.moveItem(at: stagingZipURL, to: destURL)
            return destURL
        }.value

        let attrs = (try? fm.attributesOfItem(atPath: finalZipURL.path)) ?? [:]
        let zipByteSize = (attrs[.size] as? Int64) ?? 0
        guard let normRel = FileClassification.normalizedContainerRelativePath(for: finalZipURL, customRootURL: customDownloadsRootURL) else {
            throw ZipOperationError.ioError(NSLocalizedString("Failed to register created ZIP file.", comment: ""))
        }

        let (resolvedFolder, subfolderPrefix) = FileClassification.extractFolderAndSubpath(fromRelativePath: normRel)
        let effectiveFolder = resolvedFolder.isEmpty ? VideoFolderManager.sanitizedFolderName(folderName) : resolvedFolder

        let createdItem = ManagedFileItem(
            id: UUID(),
            title: finalZipURL.deletingPathExtension().lastPathComponent,
            relativePath: normRel,
            fileExtension: "zip",
            createdAt: Date(),
            byteSize: zipByteSize,
            folderName: effectiveFolder,
            relativeSubpath: subfolderPrefix
        )

        managedFiles.removeAll { $0.normalizedRelativePath == normRel }
        managedFiles.insert(createdItem, at: 0)
        persistManagedFiles()
        return createdItem
    }

    // MARK: - 永続化とヘルパー

    private func loadPersistedManagedFiles() {
        guard let data = userDefaults.data(forKey: Self.managedFilesKey),
              let decoded = try? JSONDecoder().decode([ManagedFileItem].self, from: data) else {
            managedFiles = []
            return
        }
        // 正規化相対パスで重複排除しつつ復元
        var seen: Set<String> = []
        var unique: [ManagedFileItem] = []
        for item in decoded {
            let norm = item.normalizedRelativePath
            guard !seen.contains(norm) else { continue }
            seen.insert(norm)
            unique.append(item)
        }
        managedFiles = unique
    }

    func persistManagedFilesThrowing() throws {
        let data = try JSONEncoder().encode(managedFiles)
        userDefaults.set(data, forKey: Self.managedFilesKey)
    }

    private func persistManagedFiles() {
        try? persistManagedFilesThrowing()
    }

    func recordPendingOperation(_ op: ManagedFilePendingOperation) throws {
        let data = try JSONEncoder().encode(op)
        userDefaults.set(data, forKey: Self.pendingOperationKey)
    }

    func clearPendingOperation() {
        userDefaults.removeObject(forKey: Self.pendingOperationKey)
    }

    func loadPendingOperation() -> ManagedFilePendingOperation? {
        guard let data = userDefaults.data(forKey: Self.pendingOperationKey),
              let decoded = try? JSONDecoder().decode(ManagedFilePendingOperation.self, from: data) else {
            return nil
        }
        return decoded
    }

    func resolveRelativePathToURL(_ relativePath: String) -> URL {
        let norm = FileClassification.normalizedRelativePath(relativePath)
        if let custom = customDownloadsRootURL {
            let prefix = "Documents/Downloads/"
            if norm.hasPrefix(prefix) {
                let sub = String(norm.dropFirst(prefix.count))
                return custom.appendingPathComponent(sub)
            }
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(norm)
    }

    /// 起動時およびファイルシステム同期前に未完了ジャーナルを走査し、物理ファイル所在地からUUIDとメタデータを安全に復元する
    func recoverPendingOperationsIfNeeded() {
        guard let op = loadPendingOperation() else { return }
        let fm = FileManager.default
        let srcURL = resolveRelativePathToURL(op.sourceRelativePath)
        let dstURL = resolveRelativePathToURL(op.destinationRelativePath)

        let srcExists = fm.fileExists(atPath: srcURL.path)
        let dstExists = fm.fileExists(atPath: dstURL.path)

        if dstExists && !srcExists {
            // 物理移動は成功したがメタデータ保存前または直後にプロセス終了したケース
            if let idx = managedFiles.firstIndex(where: { $0.id == op.itemID }) {
                managedFiles[idx].title = op.destinationTitle
                managedFiles[idx].relativePath = op.destinationRelativePath
                managedFiles[idx].folderName = op.destinationFolderName
                managedFiles[idx].relativeSubpath = FileClassification.extractFolderAndSubpath(fromRelativePath: op.destinationRelativePath).subfolderPrefix
            } else {
                let attrs = (try? fm.attributesOfItem(atPath: dstURL.path)) ?? [:]
                let size = (attrs[.size] as? Int64) ?? 0
                let restored = ManagedFileItem(
                    id: op.itemID,
                    title: op.destinationTitle,
                    relativePath: op.destinationRelativePath,
                    fileExtension: op.fileExtension,
                    createdAt: op.createdAt,
                    byteSize: size,
                    folderName: op.destinationFolderName,
                    relativeSubpath: FileClassification.extractFolderAndSubpath(fromRelativePath: op.destinationRelativePath).subfolderPrefix
                )
                managedFiles.insert(restored, at: 0)
            }
            try? persistManagedFilesThrowing()
            clearPendingOperation()
        } else if srcExists && !dstExists {
            // 物理移動前、またはロールバック済み
            clearPendingOperation()
        } else if srcExists && dstExists {
            // 両方に実ファイルが存在する競合ケース：勝手に削除せず両方保持し、ジャーナルをクリア
            clearPendingOperation()
        } else {
            // 両方不在
            clearPendingOperation()
        }
    }

    /// 移動元親ディレクトリから管理フォルダ直下までの空ディレクトリのみを下から順に安全削除する
    nonisolated static func cleanEmptyIntermediateDirectoriesSafely(
        from directoryURL: URL,
        boundedBy downloadsRootURL: URL,
        folderName: String
    ) {
        let clean = VideoFolderManager.sanitizedFolderName(folderName)
        guard !clean.isEmpty else { return }
        let fm = FileManager.default
        let topFolderURL = downloadsRootURL.appendingPathComponent(clean, isDirectory: true)
        let topPath = topFolderURL.standardizedFileURL.resolvingSymlinksInPath().path

        var current = directoryURL.standardizedFileURL.resolvingSymlinksInPath()
        while current.path != topPath && current.path.hasPrefix(topPath) {
            let contents = (try? fm.contentsOfDirectory(atPath: current.path))?.filter {
                $0 != ".DS_Store" && $0 != "__MACOSX"
            } ?? ["NON_EMPTY"]
            if contents.isEmpty {
                let parent = current.deletingLastPathComponent()
                do {
                    try fm.removeItem(at: current)
                } catch {
                    break
                }
                current = parent
            } else {
                break
            }
        }
    }

    /// 既存ファイルと衝突しない一意のファイルURLを生成する（`archive.zip`, `archive (1).zip`, ...）
    nonisolated static func uniqueFileDestination(in parentDirectory: URL, baseName: String, fileExtension ext: String) -> URL {
        let cleanBase = FileNaming.sanitizedBaseName(baseName).isEmpty ? "Archive" : FileNaming.sanitizedBaseName(baseName)
        let fm = FileManager.default
        var candidate = parentDirectory.appendingPathComponent(cleanBase).appendingPathExtension(ext)
        if !fm.fileExists(atPath: candidate.path) {
            return candidate
        }
        for index in 1...9999 {
            let numbered = "\(cleanBase) (\(index))"
            candidate = parentDirectory.appendingPathComponent(numbered).appendingPathExtension(ext)
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        let fallback = "\(cleanBase)_\(UUID().uuidString.prefix(6))"
        return parentDirectory.appendingPathComponent(fallback).appendingPathExtension(ext)
    }

    /// 既存ディレクトリと衝突しない一意のフォルダURLを生成する（`旅行動画`, `旅行動画 (1)`, ...）
    nonisolated static func uniqueDirectoryDestination(in parentDirectory: URL, baseName: String) -> URL {
        let cleanBase = FileNaming.sanitizedBaseName(baseName).isEmpty ? "Extracted" : FileNaming.sanitizedBaseName(baseName)
        let fm = FileManager.default
        var candidate = parentDirectory.appendingPathComponent(cleanBase, isDirectory: true)
        if !fm.fileExists(atPath: candidate.path) {
            return candidate
        }
        for index in 1...999 {
            let numbered = "\(cleanBase) (\(index))"
            candidate = parentDirectory.appendingPathComponent(numbered, isDirectory: true)
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        let fallback = "\(cleanBase)_\(UUID().uuidString.prefix(6))"
        return parentDirectory.appendingPathComponent(fallback, isDirectory: true)
    }

    nonisolated private static func availableDiskSpace(at url: URL) -> Int64? {
        if let vals = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = vals.volumeAvailableCapacityForImportantUsage, capacity > 0 {
            return capacity
        }
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: url.path),
           let free = attrs[.systemFreeSize] as? Int64 {
            return free
        }
        return nil
    }
}

// MARK: - テスト用ZIPアーカイブ生成ヘルパー（XCTest 検証用）

enum ZipArchiveTestHelper {
    struct TestEntrySpec {
        let path: String
        let data: Data
        let type: Entry.EntryType
        let compressionMethod: CompressionMethod

        static func file(_ path: String, data: Data, compressed: Bool = true) -> TestEntrySpec {
            TestEntrySpec(path: path, data: data, type: .file, compressionMethod: compressed ? .deflate : .none)
        }

        static func directory(_ path: String) -> TestEntrySpec {
            TestEntrySpec(path: path.hasSuffix("/") ? path : path + "/", data: Data(), type: .directory, compressionMethod: .none)
        }

        static func symlink(_ path: String, target: String) -> TestEntrySpec {
            TestEntrySpec(path: path, data: Data(target.utf8), type: .symlink, compressionMethod: .none)
        }
    }

    /// 指定されたエントリ仕様群からテスト用ZIPアーカイブを生成する
    static func createArchive(at zipURL: URL, entries: [TestEntrySpec]) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: zipURL.path) {
            try fm.removeItem(at: zipURL)
        }
        let archive = try Archive(url: zipURL, accessMode: .create)
        for spec in entries {
            let payload = spec.data
            let totalSize = Int64(payload.count)
            try archive.addEntry(
                with: spec.path,
                type: spec.type,
                uncompressedSize: totalSize,
                modificationDate: Date(),
                permissions: spec.type == .directory ? 0o755 : 0o644,
                compressionMethod: spec.compressionMethod,
                bufferSize: 16 * 1024,
                progress: nil
            ) { position, size in
                let start = Int(position)
                guard start < payload.count else { return Data() }
                let end = min(payload.count, start + size)
                return payload.subdata(in: start..<end)
            }
        }
    }

    /// パスワード保護ビット（General Purpose Bit Flag Bit 0）が立ったZIPアーカイブを生成する
    static func createPasswordProtectedArchive(at zipURL: URL) throws {
        try createArchive(at: zipURL, entries: [
            .file("secret.txt", data: Data("top secret".utf8), compressed: false)
        ])
        var raw = try Data(contentsOf: zipURL)
        // Local File Header (offset 6..7: General Purpose Bit Flag)
        if raw.count >= 30 {
            raw[6] |= 0x01
        }
        // Central Directory Header (0x02014b50) の General Purpose Bit Flag (offset +8) も設定
        let cdSig: [UInt8] = [0x50, 0x4b, 0x01, 0x02]
        if let range = raw.range(of: Data(cdSig)) {
            let gpIdx = raw.distance(from: raw.startIndex, to: range.lowerBound) + 8
            if gpIdx < raw.count {
                raw[gpIdx] |= 0x01
            }
        }
        try raw.write(to: zipURL, options: .atomic)
    }

    /// ペイロードを改ざんしてCRC32不一致を引き起こす破損ZIPを生成する
    static func createCorruptedCRCArchive(at zipURL: URL) throws {
        let original = Data("Hello ClipHarbor CRC32 Verification Payload!".utf8)
        try createArchive(at: zipURL, entries: [
            .file("corrupted.txt", data: original, compressed: false)
        ])
        var raw = try Data(contentsOf: zipURL)
        guard raw.count >= 30 else { return }
        let nameLen = Int(UInt16(raw[26]) | (UInt16(raw[27]) << 8))
        let extraLen = Int(UInt16(raw[28]) | (UInt16(raw[29]) << 8))
        let dataOffset = 30 + nameLen + extraLen
        if dataOffset < raw.count {
            raw[dataOffset] ^= 0xFF
        }
        try raw.write(to: zipURL, options: .atomic)
    }
}

