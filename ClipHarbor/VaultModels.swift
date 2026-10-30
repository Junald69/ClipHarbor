import Foundation

/// Private Vault内に保護・暗号化された動画アイテムモデル
struct VaultItem: Identifiable, Codable, Equatable {
    let id: UUID                     // Vault内管理用の一意ID
    let originalVideoID: UUID        // 元のSavedVideo.id
    var originalTitle: String        // 表示用タイトル（編集・リネーム可能）
    let originalFileName: String     // 元のファイル名（例: sample.mp4）
    let originalRelativePath: String // 元の相対パス（復元時の参照用）
    let originalFolderName: String   // 元のフォルダ名
    let format: SavedVideo.Format    // MP4 / MOV / M4V / WebM
    let byteSize: Int64?             // 暗号化前の実ファイルサイズ
    let sourceHost: String?          // 配信元ホスト
    let sourcePageURL: String?       // 元WebページURL
    let createdAt: Date              // 動画の元の作成・保存日時
    let vaultAddedAt: Date           // Vaultへの移動日時
    var isFavorite: Bool = false     // お気に入り状態（Vault暗号化メタデータに保護）

    init(
        id: UUID,
        originalVideoID: UUID,
        originalTitle: String,
        originalFileName: String,
        originalRelativePath: String,
        originalFolderName: String,
        format: SavedVideo.Format,
        byteSize: Int64?,
        sourceHost: String?,
        sourcePageURL: String?,
        createdAt: Date,
        vaultAddedAt: Date,
        isFavorite: Bool = false
    ) {
        self.id = id
        self.originalVideoID = originalVideoID
        self.originalTitle = originalTitle
        self.originalFileName = originalFileName
        self.originalRelativePath = originalRelativePath
        self.originalFolderName = originalFolderName
        self.format = format
        self.byteSize = byteSize
        self.sourceHost = sourceHost
        self.sourcePageURL = sourcePageURL
        self.createdAt = createdAt
        self.vaultAddedAt = vaultAddedAt
        self.isFavorite = isFavorite
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.originalVideoID = try container.decode(UUID.self, forKey: .originalVideoID)
        self.originalTitle = try container.decode(String.self, forKey: .originalTitle)
        self.originalFileName = try container.decode(String.self, forKey: .originalFileName)
        self.originalRelativePath = try container.decode(String.self, forKey: .originalRelativePath)
        self.originalFolderName = try container.decode(String.self, forKey: .originalFolderName)
        self.format = try container.decode(SavedVideo.Format.self, forKey: .format)
        self.byteSize = try container.decodeIfPresent(Int64.self, forKey: .byteSize)
        self.sourceHost = try container.decodeIfPresent(String.self, forKey: .sourceHost)
        self.sourcePageURL = try container.decodeIfPresent(String.self, forKey: .sourcePageURL)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.vaultAddedAt = try container.decode(Date.self, forKey: .vaultAddedAt)
        self.isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
    }

    /// 表示用のファイルサイズ文字列
    var formattedSize: String {
        guard let size = byteSize else { return NSLocalizedString("Unknown", comment: "") }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    /// 暗号化コンテナファイル名
    var encryptedFileName: String {
        "video.enc"
    }

    /// 暗号化サムネイルファイル名
    var encryptedThumbnailName: String {
        "thumbnail.enc"
    }
}

/// Vault関連のエラー定義
enum VaultError: LocalizedError, Equatable {
    case passcodeTooShort
    case passcodeMismatch
    case wrongPasscode
    case lockedOut(seconds: Int)
    case notInitialized
    case alreadyInitialized
    case masterKeyMissing
    case biometricFailed(String)
    case biometricNotAvailable
    case fileNotFound
    case hlsNotSupportedYet
    case encryptionFailed(String)
    case decryptionFailed(String)
    case integrityCheckFailed
    case sessionExpired
    case fileOperationFailed(String)

    var errorDescription: String? {
        switch self {
        case .passcodeTooShort:
            return NSLocalizedString("Passcode must be at least 6 digits.", comment: "")
        case .passcodeMismatch:
            return NSLocalizedString("Confirmation passcode does not match.", comment: "")
        case .wrongPasscode:
            return NSLocalizedString("Incorrect passcode.", comment: "")
        case .lockedOut(let sec):
            let minutes = max(1, (sec + 59) / 60)
            return String.localizedStringWithFormat(
                NSLocalizedString("vault_error_locked_out %lld", comment: ""),
                Int64(minutes)
            )
        case .notInitialized:
            return NSLocalizedString("Private Vault is not initialized.", comment: "")
        case .alreadyInitialized:
            return NSLocalizedString("Private Vault is already initialized.", comment: "")
        case .masterKeyMissing:
            return NSLocalizedString("Encryption master key not found.", comment: "")
        case .biometricFailed(let msg):
            return String(format: NSLocalizedString("Biometric authentication failed: %@", comment: ""), msg)
        case .biometricNotAvailable:
            return NSLocalizedString("Device biometrics (Face ID / Touch ID) are not available.", comment: "")
        case .fileNotFound:
            return NSLocalizedString("Target video file not found.", comment: "")
        case .hlsNotSupportedYet:
            return NSLocalizedString("Offline HLS format is scheduled for a future update. Only MP4/MOV can be protected currently.", comment: "")
        case .encryptionFailed(let msg):
            return String(format: NSLocalizedString("Encryption failed: %@", comment: ""), msg)
        case .decryptionFailed(let msg):
            return String(format: NSLocalizedString("Decryption failed: %@", comment: ""), msg)
        case .integrityCheckFailed:
            return NSLocalizedString("Detected data corruption or tampering in encrypted file.", comment: "")
        case .sessionExpired:
            return NSLocalizedString("Vault session expired or was locked. Operation cancelled.", comment: "")
        case .fileOperationFailed(let msg):
            return String(format: NSLocalizedString("File operation failed: %@", comment: ""), msg)
        }
    }
}
