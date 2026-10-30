import Foundation
import UIKit
import Combine
import LocalAuthentication
import CryptoKit
import AVFoundation

/// Private Vault（非公開保管庫）の管理マネージャー
/// - アプリ内部安全領域 (Library/Application Support/Vault) における完全暗号化ストレージ
/// - パスコード / 生体認証（Face ID / Touch ID）によるロック解除
/// - 試行回数制限・ロックアウト機構
/// - 安全な一時ファイル再生ライフサイクル管理
/// - 整合性を保護するアトミックな移動・復元処理
// MARK: - 依存関係プロトコル（テストデータ完全分離用）

@MainActor
protocol VaultDownloadManaging: AnyObject {
    func removeSavedVideoWithoutDeletingFile(id: UUID)
    func restoreSavedVideoThrowing(_ video: SavedVideo) throws
}

@MainActor
protocol VaultFolderManaging: AnyObject {
    func folderName(for video: SavedVideo) -> String
    func removeVideoFromFolder(videoID: UUID)
    func restoreVideoToFolder(_ video: SavedVideo, targetFolder: String)
}

@MainActor
protocol VaultThumbnailManaging: AnyObject {
    func cachedThumbnail(for video: SavedVideo) -> UIImage?
    func cacheThumbnail(_ image: UIImage, for video: SavedVideo)
    func invalidateCache(for video: SavedVideo)
}

@MainActor
final class VaultManager: ObservableObject {
    static let shared = VaultManager()

    // MARK: - Published状態
    @Published private(set) var isInitialized: Bool = false
    @Published private(set) var isUnlocked: Bool = false
    @Published private(set) var items: [VaultItem] = []
    @Published private(set) var isBiometricsEnabled: Bool = false
    @Published private(set) var failedAttempts: Int = 0
    @Published private(set) var lockoutUntil: Date? = nil
    @Published var isProcessing: Bool = false
    @Published var processingProgress: Double = 0.0
    @Published var processingMessage: String = ""
    @Published var isPrivacyShieldActive: Bool = false
    /// ロックやセッション切替時に刷新される世代トークン（非同期タスクの遅延反映を防止）
    @Published private(set) var sessionToken = UUID()

    // MARK: - 内部プロパティ
    private var masterKey: SymmetricKey?
    private let thumbnailCache = NSCache<NSUUID, UIImage>()
    private var cancellables = Set<AnyCancellable>()

    // MARK: - 依存関係・ディレクトリ設定
    private let fileManager = FileManager.default
    private let customBaseDirectory: URL?
    private let customDownloadsDirectory: URL?
    let isTestInstance: Bool
    private let keychainStorage: VaultKeychainStorageProtocol
    private let defaults: UserDefaults

    private var vaultDirectory: URL {
        if let custom = customBaseDirectory {
            return custom.appendingPathComponent("Vault", isDirectory: true)
        }
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Vault", isDirectory: true)
    }

    private var itemsDirectory: URL {
        vaultDirectory.appendingPathComponent("items", isDirectory: true)
    }

    private var playbackTempDirectory: URL {
        vaultDirectory.appendingPathComponent(".playback_temp", isDirectory: true)
    }

    private var masterKeyFileURL: URL {
        vaultDirectory.appendingPathComponent("vault_master_key.enc")
    }

    private var indexFileURL: URL {
        vaultDirectory.appendingPathComponent("vault_index.enc")
    }

    private let biometricsPrefKey = "VaultManager.isBiometricsEnabled"
    private let failedAttemptsPrefKey = "VaultManager.failedAttempts"
    private let lockoutUntilPrefKey = "VaultManager.lockoutUntil"

    // MARK: - 初期化
    init(
        baseDirectory: URL? = nil,
        downloadsDirectory: URL? = nil,
        keychainStorage: VaultKeychainStorageProtocol? = nil,
        userDefaults: UserDefaults? = nil
    ) {
        self.customBaseDirectory = baseDirectory
        self.customDownloadsDirectory = downloadsDirectory
        self.isTestInstance = (baseDirectory != nil)

        if let customKeychain = keychainStorage {
            self.keychainStorage = customKeychain
        } else if baseDirectory != nil {
            // テストインスタンスはデフォルトでインメモリモックストレージを使用（本番Keychainへの接触を防止）
            self.keychainStorage = MockVaultKeychainStorage()
        } else {
            self.keychainStorage = ProductionVaultKeychainStorage()
        }

        if let customDefaults = userDefaults {
            self.defaults = customDefaults
        } else if baseDirectory != nil {
            let suite = "com.clipharbor.test.vault.\(UUID().uuidString)"
            self.defaults = UserDefaults(suiteName: suite) ?? .standard
        } else {
            self.defaults = .standard
        }

        setupDirectories()
        loadPersistedState()
        if !isTestInstance {
            setupLifecycleObservers()
        }
        cleanupPlaybackTemp() // 起動時に前回の再生残骸を確実に消去
    }

    // MARK: - ディレクトリ準備・保護設定
    private func setupDirectories() {
        do {
            try fileManager.createDirectory(at: vaultDirectory, withIntermediateDirectories: true, attributes: [
                .protectionKey: FileProtectionType.complete
            ])
            try fileManager.createDirectory(at: itemsDirectory, withIntermediateDirectories: true, attributes: [
                .protectionKey: FileProtectionType.complete
            ])
            try fileManager.createDirectory(at: playbackTempDirectory, withIntermediateDirectories: true, attributes: [
                .protectionKey: FileProtectionType.complete
            ])

            // iCloud / iTunesバックアップ対象外に設定
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var dirURL = vaultDirectory
            try dirURL.setResourceValues(values)
        } catch {
            print("[VaultManager] ディレクトリ初期化失敗: \(error.localizedDescription)")
        }
    }

    private func loadPersistedState() {
        isInitialized = fileManager.fileExists(atPath: masterKeyFileURL.path)
        isBiometricsEnabled = defaults.bool(forKey: biometricsPrefKey)
        failedAttempts = defaults.integer(forKey: failedAttemptsPrefKey)

        if let lockoutTimestamp = defaults.object(forKey: lockoutUntilPrefKey) as? Date {
            if lockoutTimestamp > Date() {
                lockoutUntil = lockoutTimestamp
            } else {
                // ロックアウト期限が過ぎている場合はリセット
                clearLockout()
            }
        }
    }

    // MARK: - ライフサイクル監視 (プライバシー保護・バックグラウンド時自動ロック)
    private func setupLifecycleObservers() {
        // App Switcher等でバックグラウンド直前にプライバシーシールドを表示
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in
                guard let self = self else { return }
                if self.isUnlocked {
                    self.isPrivacyShieldActive = true
                }
            }
            .store(in: &cancellables)

        // バックグラウンドに入った瞬間に完全ロック＆再生一時ファイル消去
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.lock()
                self.isPrivacyShieldActive = false
            }
            .store(in: &cancellables)

        // フォアグラウンド復帰時
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.isPrivacyShieldActive = false
                self.checkLockoutExpiration()
            }
            .store(in: &cancellables)
    }

    // MARK: - ロックアウト管理
    private func registerFailedAttempt() {
        failedAttempts += 1
        defaults.set(failedAttempts, forKey: failedAttemptsPrefKey)

        let lockoutSeconds: Int
        if failedAttempts >= 10 {
            lockoutSeconds = 900 // 15分
        } else if failedAttempts >= 7 {
            lockoutSeconds = 300 // 5分
        } else if failedAttempts >= 5 {
            lockoutSeconds = 60  // 1分
        } else {
            lockoutSeconds = 0
        }

        if lockoutSeconds > 0 {
            let until = Date().addingTimeInterval(TimeInterval(lockoutSeconds))
            lockoutUntil = until
            defaults.set(until, forKey: lockoutUntilPrefKey)
        }
    }

    private func clearLockout() {
        failedAttempts = 0
        lockoutUntil = nil
        defaults.removeObject(forKey: failedAttemptsPrefKey)
        defaults.removeObject(forKey: lockoutUntilPrefKey)
    }

    private func checkLockoutExpiration() {
        if let until = lockoutUntil, until <= Date() {
            clearLockout()
        }
    }

    var remainingLockoutSeconds: Int {
        guard let until = lockoutUntil else { return 0 }
        let remaining = Int(until.timeIntervalSince(Date()))
        return max(0, remaining)
    }

    // MARK: - 初期設定 (パスコード登録)

    /// 初回パスコード設定
    func setupPasscode(_ passcode: String, confirmPasscode: String, enableBiometrics: Bool) throws {
        guard !isInitialized else {
            throw VaultError.alreadyInitialized
        }
        guard passcode.count >= 6 else {
            throw VaultError.passcodeTooShort
        }
        guard passcode == confirmPasscode else {
            throw VaultError.passcodeMismatch
        }

        // 新規マスター鍵生成
        let newMasterKey = VaultCrypto.generateMasterKey()

        // パスコードでラッピングして保存
        let wrapped = try VaultCrypto.wrapMasterKey(newMasterKey, passcode: passcode)
        let encoder = JSONEncoder()
        let wrappedData = try encoder.encode(wrapped)
        try wrappedData.write(to: masterKeyFileURL, options: .atomic)

        // 生体認証設定
        if enableBiometrics {
            if keychainStorage.saveBiometricMasterKey(newMasterKey) {
                isBiometricsEnabled = true
                defaults.set(true, forKey: biometricsPrefKey)
            }
        } else {
            isBiometricsEnabled = false
            defaults.set(false, forKey: biometricsPrefKey)
            keychainStorage.deleteBiometricMasterKey()
        }

        // 空の暗号化インデックスを保存
        self.masterKey = newMasterKey
        self.items = []
        try saveEncryptedIndex()

        self.isInitialized = true
        self.isUnlocked = true
        clearLockout()
    }

    // MARK: - ロック解除

    /// パスコードによるアンロック
    func unlock(with passcode: String) throws {
        checkLockoutExpiration()
        if remainingLockoutSeconds > 0 {
            throw VaultError.lockedOut(seconds: remainingLockoutSeconds)
        }

        guard fileManager.fileExists(atPath: masterKeyFileURL.path) else {
            throw VaultError.notInitialized
        }

        let wrappedData = try Data(contentsOf: masterKeyFileURL)
        let decoder = JSONDecoder()
        let wrapped = try decoder.decode(VaultCrypto.WrappedMasterKey.self, from: wrappedData)

        do {
            let key = try VaultCrypto.unwrapMasterKey(wrapped, passcode: passcode)
            self.masterKey = key
            self.isUnlocked = true
            clearLockout()

            // 生体認証が有効でKeychainに未保存の場合は更新保存
            if isBiometricsEnabled {
                _ = keychainStorage.saveBiometricMasterKey(key)
            }

            try loadEncryptedIndex()
        } catch {
            registerFailedAttempt()
            throw VaultError.wrongPasscode
        }
    }

    /// 生体認証（Face ID / Touch ID）によるアンロック
    func unlockWithBiometrics() async throws {
        checkLockoutExpiration()
        if remainingLockoutSeconds > 0 {
            throw VaultError.lockedOut(seconds: remainingLockoutSeconds)
        }

        guard isBiometricsEnabled else {
            throw VaultError.biometricNotAvailable
        }

        if isTestInstance {
            // テストインスタンス: 本番Keychainをバイパスし、keychainStorageから鍵を取得
            guard let key = keychainStorage.loadBiometricMasterKey() ?? masterKey else {
                throw VaultError.masterKeyMissing
            }
            self.masterKey = key
            self.isUnlocked = true
            clearLockout()
            try loadEncryptedIndex()
            return
        }

        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw VaultError.biometricNotAvailable
        }

        let reason = NSLocalizedString("Unlock Private Vault", comment: "")

        do {
            let success = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
            if success {
                guard let key = keychainStorage.loadBiometricMasterKey() else {
                    // Keychainに見つからない場合はパスコード入力を要求
                    throw VaultError.masterKeyMissing
                }
                self.masterKey = key
                self.isUnlocked = true
                clearLockout()
                try loadEncryptedIndex()
            } else {
                throw VaultError.biometricFailed(NSLocalizedString("Authentication failed.", comment: ""))
            }
        } catch let vaultErr as VaultError {
            throw vaultErr
        } catch {
            throw VaultError.biometricFailed(error.localizedDescription)
        }
    }

    /// ロック実行（メモリ上の鍵を消去し、世代トークンを刷新、再生一時ファイルを消去）
    func lock() {
        sessionToken = UUID()
        masterKey = nil
        isUnlocked = false
        items = []
        thumbnailCache.removeAllObjects()
        cleanupPlaybackTemp()
    }

    // MARK: - パスコード変更・生体認証切替

    /// パスコードの変更
    func changePasscode(currentPasscode: String, newPasscode: String, confirmNewPasscode: String) throws {
        guard let currentKey = masterKey else {
            throw VaultError.notInitialized
        }
        guard newPasscode.count >= 6 else {
            throw VaultError.passcodeTooShort
        }
        guard newPasscode == confirmNewPasscode else {
            throw VaultError.passcodeMismatch
        }

        // 現在のパスコードが正しいか確認
        let wrappedData = try Data(contentsOf: masterKeyFileURL)
        let decoder = JSONDecoder()
        let wrapped = try decoder.decode(VaultCrypto.WrappedMasterKey.self, from: wrappedData)
        _ = try VaultCrypto.unwrapMasterKey(wrapped, passcode: currentPasscode)

        // 新しいパスコードで既存のマスター鍵を再ラッピング
        let newWrapped = try VaultCrypto.wrapMasterKey(currentKey, passcode: newPasscode)
        let encoder = JSONEncoder()
        let newWrappedData = try encoder.encode(newWrapped)
        try newWrappedData.write(to: masterKeyFileURL, options: .atomic)
    }

    /// 生体認証の有効/無効切替
    func setBiometricsEnabled(_ enabled: Bool) {
        guard let key = masterKey else { return }
        if enabled {
            if keychainStorage.saveBiometricMasterKey(key) {
                isBiometricsEnabled = true
                defaults.set(true, forKey: biometricsPrefKey)
            }
        } else {
            keychainStorage.deleteBiometricMasterKey()
            isBiometricsEnabled = false
            defaults.set(false, forKey: biometricsPrefKey)
        }
    }

    // MARK: - インデックスの保存・読み込み

    private func saveEncryptedIndex() throws {
        guard let key = masterKey else {
            throw VaultError.masterKeyMissing
        }

        let encoder = JSONEncoder()
        let plainData = try encoder.encode(items)
        let encryptedData = try VaultCrypto.encryptData(plainData, using: key)
        try encryptedData.write(to: indexFileURL, options: .atomic)
    }

    private func loadEncryptedIndex() throws {
        guard let key = masterKey else {
            throw VaultError.masterKeyMissing
        }

        guard fileManager.fileExists(atPath: indexFileURL.path) else {
            items = []
            return
        }

        let encryptedData = try Data(contentsOf: indexFileURL)
        let plainData = try VaultCrypto.decryptData(encryptedData, using: key)
        let decoder = JSONDecoder()
        items = try decoder.decode([VaultItem].self, from: plainData)
    }

    // MARK: - Vaultへの移動 (アトミック処理)

    /// 通常の動画をVaultへ暗号化移動
    func moveToVault(
        video: SavedVideo,
        sourceURL: URL? = nil,
        downloads: VaultDownloadManaging,
        folderManager: VaultFolderManaging,
        thumbnailManager: VaultThumbnailManaging? = nil
    ) async throws {
        if isTestInstance {
            guard downloads is MockDownloadManager, folderManager is MockFolderManager else {
                throw VaultError.fileOperationFailed("Test instance must be provided with MockDownloadManager and MockFolderManager.")
            }
        }
        let actualThumbnail = thumbnailManager ?? (isTestInstance ? MockThumbnailManager() : VideoThumbnailManager.shared)

        guard let key = masterKey, isUnlocked else {
            throw VaultError.masterKeyMissing
        }

        guard !video.isHLS else {
            throw VaultError.hlsNotSupportedYet
        }

        guard video.format.isVideo else {
            throw VaultError.fileOperationFailed(NSLocalizedString("Image files do not support Vault encryption.", comment: ""))
        }

        let actualSourceURL = sourceURL ?? video.fileURL
        guard fileManager.fileExists(atPath: actualSourceURL.path) else {
            throw VaultError.fileNotFound
        }

        isProcessing = true
        processingProgress = 0.0
        processingMessage = String(format: NSLocalizedString("Encrypting \"%@\"…", comment: ""), video.title)

        let itemID = UUID()
        let itemDir = itemsDirectory.appendingPathComponent(itemID.uuidString, isDirectory: true)

        var isIndexSaved = false
        var isSourceRemoved = false

        do {
            try fileManager.createDirectory(at: itemDir, withIntermediateDirectories: true, attributes: [
                .protectionKey: FileProtectionType.complete
            ])

            let encryptedVideoURL = itemDir.appendingPathComponent("video.enc")

            // ストリーム暗号化実行 (バックグラウンドタスク)
            try await Task.detached(priority: .userInitiated) {
                try VaultCrypto.encryptFile(at: actualSourceURL, to: encryptedVideoURL, using: key)
            }.value

            // 暗号化ファイルの存在およびサイズ検証
            guard fileManager.fileExists(atPath: encryptedVideoURL.path) else {
                throw VaultError.fileOperationFailed(NSLocalizedString("Encrypted file was not created.", comment: ""))
            }
            let encSize = (try? fileManager.attributesOfItem(atPath: encryptedVideoURL.path)[.size] as? Int64) ?? 0
            guard encSize > 0 else {
                throw VaultError.fileOperationFailed(NSLocalizedString("Encrypted file is empty.", comment: ""))
            }

            // サムネイル暗号化
            if let thumbImage = actualThumbnail.cachedThumbnail(for: video),
               let thumbData = thumbImage.jpegData(compressionQuality: 0.8) {
                let encryptedThumbData = try VaultCrypto.encryptData(thumbData, using: key)
                let encryptedThumbURL = itemDir.appendingPathComponent("thumbnail.enc")
                try encryptedThumbData.write(to: encryptedThumbURL, options: .atomic)
            }

            let folderName = folderManager.folderName(for: video)
            let fileName = actualSourceURL.lastPathComponent

            // アイテムメタデータ作成
            let vaultItem = VaultItem(
                id: itemID,
                originalVideoID: video.id,
                originalTitle: video.title,
                originalFileName: fileName,
                originalRelativePath: video.relativePath,
                originalFolderName: folderName,
                format: video.format,
                byteSize: video.byteSize,
                sourceHost: video.sourceHost,
                sourcePageURL: video.sourcePageURL,
                createdAt: video.createdAt,
                vaultAddedAt: Date(),
                isFavorite: video.isFavorite
            )

            // インデックスに追加して保存
            items.insert(vaultItem, at: 0)
            try saveEncryptedIndex()
            isIndexSaved = true

            processingMessage = NSLocalizedString("Safely removing original file…", comment: "")

            // 元平文ファイルの削除（明示的に検証）
            do {
                try fileManager.removeItem(at: actualSourceURL)
                isSourceRemoved = true
            } catch {
                // 平文削除失敗: 元ファイルはディスクに残っている
                // 通常一覧の登録を維持し、Vaultインデックスを安全にロールバック
                items.removeAll(where: { $0.id == itemID })
                do {
                    try saveEncryptedIndex()
                    // インデックスロールバック成功時のみ暗号化原本を破棄して完全ロールバック
                    try? fileManager.removeItem(at: itemDir)
                } catch {
                    // ★インデックスのロールバックに失敗した場合、暗号化原本を無条件に削除しない
                    print("[VaultManager] ロールバック時のインデックス保存失敗: \(error.localizedDescription)。暗号化原本は保護維持します。")
                }
                throw VaultError.fileOperationFailed(
                    String(format: NSLocalizedString("Failed to safely remove original file: %@. Moving to Vault was cancelled.", comment: ""), error.localizedDescription)
                )
            }

            // 元ファイル削除成功後のみ通常一覧から登録解除
            downloads.removeSavedVideoWithoutDeletingFile(id: video.id)
            folderManager.removeVideoFromFolder(videoID: video.id)
            actualThumbnail.invalidateCache(for: video)

            processingProgress = 1.0
            isProcessing = false
        } catch {
            // 平文削除成功後は絶対に暗号原本を削除しない
            if !isSourceRemoved {
                if !isIndexSaved {
                    // インデックス保存前に失敗した場合のみ、不完全なVault内ディレクトリを破棄
                    try? fileManager.removeItem(at: itemDir)
                    items.removeAll(where: { $0.id == itemID })
                }
            }
            isProcessing = false
            throw error
        }
    }

    /// 本番UI用コンビニエンスメソッド（デフォルト依存関係を使用）
    func moveToVault(
        video: SavedVideo,
        downloads: VaultDownloadManaging,
        folderManager: VaultFolderManaging
    ) async throws {
        try await moveToVault(
            video: video,
            sourceURL: nil,
            downloads: downloads,
            folderManager: folderManager,
            thumbnailManager: isTestInstance ? MockThumbnailManager() : VideoThumbnailManager.shared
        )
    }

    /// 複数動画のVaultへの一括移動
    func moveMultipleToVault(
        videos: [SavedVideo],
        downloads: VaultDownloadManaging,
        folderManager: VaultFolderManaging,
        thumbnailManager: VaultThumbnailManaging? = nil
    ) async -> (succeeded: Int, failed: Int) {
        var succeeded = 0
        var failed = 0

        for video in videos {
            do {
                try await moveToVault(
                    video: video,
                    sourceURL: nil,
                    downloads: downloads,
                    folderManager: folderManager,
                    thumbnailManager: thumbnailManager
                )
                succeeded += 1
            } catch {
                failed += 1
                print("[VaultManager] 移動失敗: \(video.title) - \(error.localizedDescription)")
            }
        }

        return (succeeded, failed)
    }

    // MARK: - Vaultからの復元 (アトミック処理)

    /// Vault内の動画を通常フォルダに復元
    func restoreFromVault(
        item: VaultItem,
        targetFolder: String?,
        downloads: VaultDownloadManaging,
        folderManager: VaultFolderManaging,
        thumbnailManager: VaultThumbnailManaging? = nil
    ) async throws {
        if isTestInstance {
            guard downloads is MockDownloadManager, folderManager is MockFolderManager else {
                throw VaultError.fileOperationFailed("Test instance must be provided with MockDownloadManager and MockFolderManager.")
            }
        }
        let actualThumbnail = thumbnailManager ?? (isTestInstance ? MockThumbnailManager() : VideoThumbnailManager.shared)

        guard let key = masterKey, isUnlocked else {
            throw VaultError.masterKeyMissing
        }

        let itemDir = itemsDirectory.appendingPathComponent(item.id.uuidString, isDirectory: true)
        let encryptedVideoURL = itemDir.appendingPathComponent(item.encryptedFileName)
        guard fileManager.fileExists(atPath: encryptedVideoURL.path) else {
            throw VaultError.fileNotFound
        }

        isProcessing = true
        processingProgress = 0.0
        processingMessage = String(format: NSLocalizedString("Decrypting \"%@\"…", comment: ""), item.originalTitle)

        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let downloadsDir = customDownloadsDirectory ?? docs.appendingPathComponent("Downloads", isDirectory: true)
        try fileManager.createDirectory(at: downloadsDir, withIntermediateDirectories: true)

        let cleanFolder = VideoFolderManager.sanitizedFolderName(targetFolder ?? item.originalFolderName)
        let targetDir: URL
        if !cleanFolder.isEmpty {
            targetDir = downloadsDir.appendingPathComponent(cleanFolder, isDirectory: true)
            try fileManager.createDirectory(at: targetDir, withIntermediateDirectories: true)
        } else {
            targetDir = downloadsDir
        }

        let ext = (item.originalFileName as NSString).pathExtension
        let baseName = (item.originalFileName as NSString).deletingPathExtension
        let destURL = FileNaming.uniqueDestination(
            in: targetDir,
            baseName: baseName.isEmpty ? "RestoredVideo" : baseName,
            fileExtension: ext.isEmpty ? item.format.rawValue : ext
        )

        var isRegisteredInDownloads = false
        var isRestoreCommitted = false

        do {
            // 1. ストリーム復号実行
            try await Task.detached(priority: .userInitiated) {
                try VaultCrypto.decryptFile(at: encryptedVideoURL, to: destURL, using: key)
            }.value

            // 復元先平文ファイルの存在・サイズ検証
            guard fileManager.fileExists(atPath: destURL.path) else {
                throw VaultError.fileOperationFailed(NSLocalizedString("Restored file was not created.", comment: ""))
            }
            let restoredSize = (try? fileManager.attributesOfItem(atPath: destURL.path)[.size] as? Int64) ?? 0
            guard restoredSize > 0 else {
                throw VaultError.fileOperationFailed(NSLocalizedString("Restored file is empty.", comment: ""))
            }

            // サムネイル復元（存在する場合）
            var restoredThumbnailImage: UIImage? = nil
            let encryptedThumbURL = itemDir.appendingPathComponent(item.encryptedThumbnailName)
            if fileManager.fileExists(atPath: encryptedThumbURL.path) {
                if let thumbEncData = try? Data(contentsOf: encryptedThumbURL),
                   let thumbPlainData = try? VaultCrypto.decryptData(thumbEncData, using: key),
                   let img = UIImage(data: thumbPlainData) {
                    restoredThumbnailImage = img
                }
            }

            guard let newRelativePath = SavedVideo.relativePath(for: destURL) else {
                throw VaultError.fileOperationFailed(NSLocalizedString("Failed to determine destination path for restore.", comment: ""))
            }

            let restoredVideo = SavedVideo(
                id: item.originalVideoID,
                title: item.originalTitle,
                relativePath: newRelativePath,
                format: item.format,
                sourceHost: item.sourceHost,
                createdAt: Date(),
                byteSize: restoredSize > 0 ? restoredSize : item.byteSize,
                sourcePageURL: item.sourcePageURL,
                isFavorite: item.isFavorite
            )

            processingMessage = NSLocalizedString("Registering into file list…", comment: "")

            // 2. DownloadCenter & FolderManagerへ追加（永続化）
            try downloads.restoreSavedVideoThrowing(restoredVideo)
            isRegisteredInDownloads = true

            if !cleanFolder.isEmpty {
                folderManager.restoreVideoToFolder(restoredVideo, targetFolder: cleanFolder)
            }

            if let thumb = restoredThumbnailImage {
                actualThumbnail.cacheThumbnail(thumb, for: restoredVideo)
            }

            // 3. Vaultインデックス先行更新（暗号化原本はまだ削除しない！）
            let originalIndex = items.firstIndex(where: { $0.id == item.id })
            items.removeAll(where: { $0.id == item.id })
            thumbnailCache.removeObject(forKey: item.id as NSUUID)

            do {
                try saveEncryptedIndex()
            } catch {
                // インデックス保存失敗時:
                // インメモリ状態を復旧し、暗号原本は削除しない。
                if let idx = originalIndex, idx <= items.count {
                    items.insert(item, at: idx)
                } else {
                    items.append(item)
                }
                // ★インデックス保存失敗時に両方のファイルが失われないことを保証
                // destURL は DownloadCenter に登録されているため残す（重複許容）。
                // 平文ファイル destURL をロールバック削除すると原本との両損リスクがあるため削除しない。
                throw error
            }

            // 4. ★Point of No Return: インデックス保存成功
            // これ以降は暗号原本削除フェーズとなり、復元先平文ファイルを決してロールバック削除しない
            isRestoreCommitted = true

            // 5. 最後にVault内の暗号化原本を安全に消去
            try? fileManager.removeItem(at: itemDir)

            processingProgress = 1.0
            isProcessing = false
        } catch {
            // ★原本削除フェーズに入った後 (isRestoreCommitted == true) は復元済み平文ファイルを削除しない！
            // 通常一覧に未登録かつ復元確定前に失敗した場合のみ、不完全な平文ファイルを削除
            if !isRestoreCommitted && !isRegisteredInDownloads {
                try? fileManager.removeItem(at: destURL)
            }
            isProcessing = false
            throw error
        }
    }

    /// 本番UI用コンビニエンスメソッド（デフォルト依存関係を使用）
    func restoreFromVault(
        item: VaultItem,
        targetFolder: String?,
        downloads: VaultDownloadManaging,
        folderManager: VaultFolderManaging
    ) async throws {
        try await restoreFromVault(
            item: item,
            targetFolder: targetFolder,
            downloads: downloads,
            folderManager: folderManager,
            thumbnailManager: isTestInstance ? MockThumbnailManager() : VideoThumbnailManager.shared
        )
    }

    /// 複数アイテムの復元
    func restoreMultipleFromVault(
        items targetItems: [VaultItem],
        targetFolder: String?,
        downloads: VaultDownloadManaging,
        folderManager: VaultFolderManaging,
        thumbnailManager: VaultThumbnailManaging? = nil
    ) async -> (succeeded: Int, failed: Int) {
        var succeeded = 0
        var failed = 0

        for item in targetItems {
            do {
                try await restoreFromVault(
                    item: item,
                    targetFolder: targetFolder,
                    downloads: downloads,
                    folderManager: folderManager,
                    thumbnailManager: thumbnailManager
                )
                succeeded += 1
            } catch {
                failed += 1
                print("[VaultManager] 復元失敗: \(item.originalTitle) - \(error.localizedDescription)")
            }
        }

        return (succeeded, failed)
    }

    // MARK: - 永久削除

    /// Vault内の動画を永久削除
    func deletePermanently(item: VaultItem, expectedSessionToken: UUID? = nil) throws {
        if let token = expectedSessionToken {
            guard isUnlocked, sessionToken == token else {
                throw NSError(domain: "VaultManager", code: 401, userInfo: [
                    NSLocalizedDescriptionKey: NSLocalizedString("Vault session is invalid. Please unlock again.", comment: "")
                ])
            }
        }
        let itemDir = itemsDirectory.appendingPathComponent(item.id.uuidString, isDirectory: true)
        try? fileManager.removeItem(at: itemDir)

        items.removeAll(where: { $0.id == item.id })
        thumbnailCache.removeObject(forKey: item.id as NSUUID)
        try saveEncryptedIndex()
    }

    /// 複数アイテムの永久削除
    func deleteMultiplePermanently(items targetItems: [VaultItem]) throws {
        for item in targetItems {
            let itemDir = itemsDirectory.appendingPathComponent(item.id.uuidString, isDirectory: true)
            try? fileManager.removeItem(at: itemDir)
            thumbnailCache.removeObject(forKey: item.id as NSUUID)
        }
        let targetIDs = Set(targetItems.map { $0.id })
        items.removeAll(where: { targetIDs.contains($0.id) })
        try saveEncryptedIndex()
    }

    // MARK: - お気に入り操作

    /// Vaultアイテムのお気に入り状態を切り替えて暗号化インデックスを更新
    @discardableResult
    func toggleFavorite(for item: VaultItem, expectedSessionToken: UUID) throws -> Bool {
        guard isUnlocked, masterKey != nil else {
            throw VaultError.masterKeyMissing
        }
        guard sessionToken == expectedSessionToken else {
            throw NSError(domain: "VaultManager", code: 401, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("Vault session is invalid. Please unlock again.", comment: "")
            ])
        }
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else {
            throw VaultError.fileNotFound
        }

        let targetState = !items[idx].isFavorite
        items[idx].isFavorite = targetState
        do {
            try saveEncryptedIndex()
            return targetState
        } catch {
            // セッションが変わっていない場合のみ安全にロールバック
            if isUnlocked && sessionToken == expectedSessionToken, items.indices.contains(idx), items[idx].id == item.id {
                items[idx].isFavorite = !targetState
            }
            throw error
        }
    }

    /// Vaultアイテムのタイトルを変更
    func renameVaultItem(_ item: VaultItem, to newTitle: String) throws {
        guard isUnlocked, masterKey != nil else {
            throw VaultError.masterKeyMissing
        }
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else {
            throw VaultError.fileNotFound
        }
        let clean = FileNaming.sanitizedBaseName(newTitle)
        guard !clean.isEmpty else { return }
        items[idx].originalTitle = clean
        try saveEncryptedIndex()
    }

    /// トリミング結果（tempURL）をVault内へ暗号化保存（元アイテムは保持）
    @discardableResult
    func addEncryptedClip(tempURL: URL, clipTitle: String, sourceVaultItem: VaultItem) async throws -> VaultItem {
        guard let key = masterKey, isUnlocked else {
            throw VaultError.masterKeyMissing
        }
        guard fileManager.fileExists(atPath: tempURL.path) else {
            throw VaultError.fileNotFound
        }

        let cleanTitle = FileNaming.sanitizedBaseName(clipTitle)
        let finalTitle = cleanTitle.isEmpty ? "\(sourceVaultItem.originalTitle)_clip" : cleanTitle
        let clipID = UUID()
        let itemDir = itemsDirectory.appendingPathComponent(clipID.uuidString, isDirectory: true)

        try fileManager.createDirectory(at: itemDir, withIntermediateDirectories: true, attributes: [
            .protectionKey: FileProtectionType.complete
        ])

        let encryptedVideoURL = itemDir.appendingPathComponent("video.enc")

        // 暗号化
        try await Task.detached(priority: .userInitiated) {
            try VaultCrypto.encryptFile(at: tempURL, to: encryptedVideoURL, using: key)
        }.value

        // サムネイル生成・暗号化
        let asset = AVURLAsset(url: tempURL)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 400, height: 400)
        if let cgImage = try? gen.copyCGImage(at: .zero, actualTime: nil) {
            let thumbImage = UIImage(cgImage: cgImage)
            if let thumbData = thumbImage.jpegData(compressionQuality: 0.8),
               let encryptedThumbData = try? VaultCrypto.encryptData(thumbData, using: key) {
                let thumbURL = itemDir.appendingPathComponent("thumbnail.enc")
                try? encryptedThumbData.write(to: thumbURL, options: .atomic)
            }
        }

        let fileSize = (try? fileManager.attributesOfItem(atPath: tempURL.path)[.size] as? Int64) ?? 0

        // 一時平文ファイルを安全に消去
        try? fileManager.removeItem(at: tempURL)

        let newVaultItem = VaultItem(
            id: clipID,
            originalVideoID: UUID(),
            originalTitle: finalTitle,
            originalFileName: "\(finalTitle).mp4",
            originalRelativePath: "",
            originalFolderName: sourceVaultItem.originalFolderName,
            format: .mp4,
            byteSize: fileSize,
            sourceHost: sourceVaultItem.sourceHost,
            sourcePageURL: sourceVaultItem.sourcePageURL,
            createdAt: Date(),
            vaultAddedAt: Date(),
            isFavorite: false
        )

        items.insert(newVaultItem, at: 0)
        try saveEncryptedIndex()
        return newVaultItem
    }

    // MARK: - 再生・編集用一時ファイル管理

    /// 再生・編集用に一時ディレクトリに復号してローカルURLを生成
    /// - operationIDおよびsessionTokenを含めることで開き直しや並行処理時の衝突・レースコンディションを完全防止
    func preparePlaybackURL(for item: VaultItem, operationID: UUID = UUID()) throws -> URL {
        guard let key = masterKey, isUnlocked else {
            throw VaultError.masterKeyMissing
        }

        let itemDir = itemsDirectory.appendingPathComponent(item.id.uuidString, isDirectory: true)
        let encryptedVideoURL = itemDir.appendingPathComponent(item.encryptedFileName)
        guard fileManager.fileExists(atPath: encryptedVideoURL.path) else {
            throw VaultError.fileNotFound
        }

        let ext = (item.originalFileName as NSString).pathExtension
        let safeExt = ext.isEmpty ? item.format.rawValue : ext
        let fileName = "\(item.id.uuidString)_\(sessionToken.uuidString)_\(operationID.uuidString).\(safeExt)"
        let tempVideoURL = playbackTempDirectory.appendingPathComponent(fileName)

        if fileManager.fileExists(atPath: tempVideoURL.path) {
            try? fileManager.removeItem(at: tempVideoURL)
        }

        try VaultCrypto.decryptFile(at: encryptedVideoURL, to: tempVideoURL, using: key)

        // ファイル保護を完全保護に設定
        try? fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: tempVideoURL.path)

        // 復号中にロックされた場合の安全確認
        guard isUnlocked, masterKey != nil else {
            try? fileManager.removeItem(at: tempVideoURL)
            throw VaultError.masterKeyMissing
        }

        return tempVideoURL
    }

    /// 一時ファイルを消去
    func cleanupPlaybackTemp(fileURL: URL? = nil, itemID: UUID? = nil) {
        if let fileURL = fileURL {
            try? fileManager.removeItem(at: fileURL)
            return
        }
        if let itemID = itemID {
            let contents = (try? fileManager.contentsOfDirectory(at: playbackTempDirectory, includingPropertiesForKeys: nil)) ?? []
            for url in contents where url.lastPathComponent.hasPrefix(itemID.uuidString) {
                try? fileManager.removeItem(at: url)
            }
        } else {
            let contents = (try? fileManager.contentsOfDirectory(at: playbackTempDirectory, includingPropertiesForKeys: nil)) ?? []
            for url in contents {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    // MARK: - サムネイル取得

    /// 暗号化サムネイルを復号してUIImageとして取得（インメモリキャッシュ対応）
    func thumbnail(for item: VaultItem) -> UIImage? {
        if let cached = thumbnailCache.object(forKey: item.id as NSUUID) {
            return cached
        }

        guard let key = masterKey, isUnlocked else { return nil }

        let itemDir = itemsDirectory.appendingPathComponent(item.id.uuidString, isDirectory: true)
        let encryptedThumbURL = itemDir.appendingPathComponent(item.encryptedThumbnailName)

        guard fileManager.fileExists(atPath: encryptedThumbURL.path),
              let encData = try? Data(contentsOf: encryptedThumbURL),
              let plainData = try? VaultCrypto.decryptData(encData, using: key),
              let image = UIImage(data: plainData) else {
            return nil
        }

        thumbnailCache.setObject(image, forKey: item.id as NSUUID)
        return image
    }

    // MARK: - 整合性診断（検出・診断専用 / 自動削除・変更禁止）

    /// Vault整合性診断結果レポート
    struct VaultIntegrityReport: Equatable {
        /// インデックスに登録されているが実体暗号化ファイル（video.enc）が存在しないID
        let ghostItemIDs: [UUID]
        /// ディスク上に存在するがインデックスに登録されていない孤立ディレクトリID
        let orphanedDirectoryIDs: [UUID]
        /// 異常が検出されたかどうか
        var hasAnomalies: Bool {
            !ghostItemIDs.isEmpty || !orphanedDirectoryIDs.isEmpty
        }
    }

    /// Vaultのファイル実体とインデックスの整合性を診断する（読み取り専用・診断専用）
    /// - 注: 既存データの破壊や誤判定を防ぐため、自動削除・自動修復・上書きは一切行いません。
    @discardableResult
    func checkVaultIntegrity() -> VaultIntegrityReport {
        guard isUnlocked else {
            return VaultIntegrityReport(ghostItemIDs: [], orphanedDirectoryIDs: [])
        }

        let indexedIDs = Set(items.map { $0.id })
        var ghostIDs: [UUID] = []

        // 1. ゴーストインデックスの検出（インデックスにあるが実体暗号化ファイルがない）
        for item in items {
            let itemDir = itemsDirectory.appendingPathComponent(item.id.uuidString, isDirectory: true)
            let encVideoURL = itemDir.appendingPathComponent(item.encryptedFileName)
            if !fileManager.fileExists(atPath: encVideoURL.path) {
                ghostIDs.append(item.id)
            }
        }

        // 2. 孤立暗号化ディレクトリの検出（実体はあるがインデックスにない）
        var orphanIDs: [UUID] = []
        if let subdirs = try? fileManager.contentsOfDirectory(at: itemsDirectory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for dir in subdirs {
                if let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory, isDir {
                    if let uuid = UUID(uuidString: dir.lastPathComponent) {
                        if !indexedIDs.contains(uuid) {
                            orphanIDs.append(uuid)
                        }
                    }
                }
            }
        }

        if !ghostIDs.isEmpty || !orphanIDs.isEmpty {
            print("[VaultManager] 整合性診断: ゴーストエントリ=\(ghostIDs.count)件, 孤立ディレクトリ=\(orphanIDs.count)件 (自動削除は行わず現状維持)")
        }

        return VaultIntegrityReport(ghostItemIDs: ghostIDs, orphanedDirectoryIDs: orphanIDs)
    }
}
