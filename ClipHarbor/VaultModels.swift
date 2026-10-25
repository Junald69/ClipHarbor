import Foundation

/// Private Vault内に保護・暗号化された動画アイテムモデル
struct VaultItem: Identifiable, Codable, Equatable {
    let id: UUID                     // Vault内管理用の一意ID
    let originalVideoID: UUID        // 元のSavedVideo.id
    let originalTitle: String        // 表示用タイトル
    let originalFileName: String     // 元のファイル名（例: sample.mp4）
    let originalRelativePath: String // 元の相対パス（復元時の参照用）
    let originalFolderName: String   // 元のフォルダ名
    let format: SavedVideo.Format    // MP4 / MOV / M4V / WebM
    let byteSize: Int64?             // 暗号化前の実ファイルサイズ
    let sourceHost: String?          // 配信元ホスト
    let sourcePageURL: String?       // 元WebページURL
    let createdAt: Date              // 動画の元の作成・保存日時
    let vaultAddedAt: Date           // Vaultへの移動日時

    /// 表示用のファイルサイズ文字列
    var formattedSize: String {
        guard let size = byteSize else { return "不明" }
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
    case fileOperationFailed(String)

    var errorDescription: String? {
        switch self {
        case .passcodeTooShort:
            return "パスコードは6桁以上の数字で設定してください。"
        case .passcodeMismatch:
            return "確認用のパスコードが一致しません。"
        case .wrongPasscode:
            return "パスコードが正しくありません。"
        case .lockedOut(let sec):
            let minutes = (sec + 59) / 60
            return "試行回数の上限を超えました。あと \(minutes) 分後に再試行してください。"
        case .notInitialized:
            return "Private Vaultは初期設定されていません。"
        case .alreadyInitialized:
            return "Private Vaultはすでに設定済みです。"
        case .masterKeyMissing:
            return "暗号化マスター鍵が見つかりません。"
        case .biometricFailed(let msg):
            return "生体認証に失敗しました: \(msg)"
        case .biometricNotAvailable:
            return "端末の生体認証（Face ID / Touch ID）が利用できません。"
        case .fileNotFound:
            return "対象の動画ファイルが見つかりません。"
        case .hlsNotSupportedYet:
            return "オフラインHLS形式の保護は今後のアップデートで対応予定です。現在はMP4/MOV形式のみ保護可能です。"
        case .encryptionFailed(let msg):
            return "暗号化処理に失敗しました: \(msg)"
        case .decryptionFailed(let msg):
            return "復号処理に失敗しました: \(msg)"
        case .integrityCheckFailed:
            return "暗号化データの改ざんまたは破損を検出しました。"
        case .fileOperationFailed(let msg):
            return "ファイル操作に失敗しました: \(msg)"
        }
    }
}
