import Foundation
import CryptoKit
import CommonCrypto
import Security

/// Private Vault暗号化エンジン
/// - PBKDF2 (SHA-256, 100,000反復) によるパスコードからの鍵導出
/// - AES-256-GCMによるエンベロープ暗号化（マスター鍵の保護）
/// - 大容量動画に対応した1MBチャンク分割ストリーム暗号化（厳格な順序・改ざん検証）
/// - Keychain (ThisDeviceOnly) による生体認証用マスター鍵の安全な保管
final class VaultCrypto {
    static let shared = VaultCrypto()
    private init() {}

    // MARK: - 定数
    private static let pbkdf2Iterations: UInt32 = 100_000
    private static let keyByteCount: Int = 32 // 256-bit AES
    private static let saltByteCount: Int = 32
    private static let streamChunkSize: Int = 1_048_576 // 1MB
    private static let streamMagic: [UInt8] = [0x43, 0x48, 0x56, 0x31] // "CHV1"
    private static let streamSaltSize: Int = 16

    private static let keychainService = "com.clipharbor.app.vault"
    private static let keychainAccount = "master_key_biometric"

    // MARK: - パスコード・鍵導出 (PBKDF2)

    /// ランダムなソルトを生成
    static func generateSalt(count: Int = saltByteCount) -> Data {
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
        }
        return data
    }

    /// 新規マスター暗号化鍵 (256-bit) を生成
    static func generateMasterKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    /// パスコードとソルトからPBKDF2 (SHA-256) で鍵導出
    static func deriveKey(passcode: String, salt: Data, iterations: UInt32 = pbkdf2Iterations) throws -> SymmetricKey {
        guard let passwordData = passcode.data(using: .utf8) else {
            throw VaultError.encryptionFailed("パスコードのUTF-8エンコードに失敗しました。")
        }

        var derivedBytes = Data(repeating: 0, count: keyByteCount)
        let status = derivedBytes.withUnsafeMutableBytes { derivedKeyBytes in
            salt.withUnsafeBytes { saltBytes in
                passwordData.withUnsafeBytes { passBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        derivedKeyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        keyByteCount
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            throw VaultError.encryptionFailed("PBKDF2鍵導出に失敗しました (status: \(status))")
        }

        return SymmetricKey(data: derivedBytes)
    }

    // MARK: - マスター鍵のラッピング構造体

    struct WrappedMasterKey: Codable {
        let salt: Data
        let iterations: UInt32
        let wrappedData: Data // AES-GCM (nonce + ciphertext + tag)
    }

    /// マスター鍵をパスコード由来のKEKでラッピング
    static func wrapMasterKey(_ masterKey: SymmetricKey, passcode: String) throws -> WrappedMasterKey {
        let salt = generateSalt()
        let kek = try deriveKey(passcode: passcode, salt: salt)
        let masterRawData = masterKey.withUnsafeBytes { Data($0) }
        let sealed = try AES.GCM.seal(masterRawData, using: kek)
        guard let combined = sealed.combined else {
            throw VaultError.encryptionFailed("マスター鍵の暗号化パッキングに失敗しました。")
        }
        return WrappedMasterKey(salt: salt, iterations: pbkdf2Iterations, wrappedData: combined)
    }

    /// ラッピングされたマスター鍵をパスコードでアンラップ
    static func unwrapMasterKey(_ wrapped: WrappedMasterKey, passcode: String) throws -> SymmetricKey {
        let kek = try deriveKey(passcode: passcode, salt: wrapped.salt, iterations: wrapped.iterations)
        do {
            let box = try AES.GCM.SealedBox(combined: wrapped.wrappedData)
            let decrypted = try AES.GCM.open(box, using: kek)
            guard decrypted.count == keyByteCount else {
                throw VaultError.integrityCheckFailed
            }
            return SymmetricKey(data: decrypted)
        } catch {
            throw VaultError.wrongPasscode
        }
    }

    // MARK: - メモリ内データ暗号化 (サムネイル・インデックス等)

    /// 小〜中規模データのAES-GCM暗号化
    static func encryptData(_ data: Data, using key: SymmetricKey) throws -> Data {
        do {
            let sealed = try AES.GCM.seal(data, using: key)
            guard let combined = sealed.combined else {
                throw VaultError.encryptionFailed("データの暗号化結合に失敗しました。")
            }
            return combined
        } catch {
            throw VaultError.encryptionFailed(error.localizedDescription)
        }
    }

    /// 小〜中規模データのAES-GCM復号
    static func decryptData(_ data: Data, using key: SymmetricKey) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: data)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw VaultError.decryptionFailed(error.localizedDescription)
        }
    }

    // MARK: - 大容量ストリーム暗号化・復号 (1MBチャンク分割)

    /// 大容量動画ファイルのストリーム暗号化
    /// - パラメータ:
    ///   - sourceURL: 暗号化元の動画ファイルURL
    ///   - destinationURL: 出力先暗号化ファイルURL (.enc)
    ///   - key: マスター暗号化鍵
    ///   - progress: 進捗コールバック (0.0〜1.0)
    static func encryptFile(
        at sourceURL: URL,
        to destinationURL: URL,
        using key: SymmetricKey,
        progress: ((Double) -> Void)? = nil
    ) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw VaultError.fileNotFound
        }

        let sourceAttributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
        let totalBytes = (sourceAttributes[.size] as? Int64) ?? 0

        // 出力先が既に存在する場合は削除
        if fileManager.fileExists(atPath: destinationURL.path) {
            try? fileManager.removeItem(at: destinationURL)
        }

        // 空ファイル作成
        guard fileManager.createFile(atPath: destinationURL.path, contents: nil, attributes: nil) else {
            throw VaultError.fileOperationFailed("暗号化コンテナファイルの作成に失敗しました。")
        }

        let readFileHandle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? readFileHandle.close() }

        let writeFileHandle = try FileHandle(forWritingTo: destinationURL)
        defer { try? writeFileHandle.close() }

        // 1. ヘッダー書き込み: Magic (4B) + StreamSalt (16B) + TotalPlainBytes (8B)
        let streamSalt = generateSalt(count: streamSaltSize)
        var header = Data(streamMagic)
        header.append(streamSalt)
        withUnsafeBytes(of: UInt64(totalBytes).bigEndian) { header.append(contentsOf: $0) }
        try writeFileHandle.write(contentsOf: header)

        var processedBytes: Int64 = 0
        var chunkIndex: UInt64 = 0

        while true {
            autoreleasepool {
                do {
                    guard let chunkData = try readFileHandle.read(upToCount: streamChunkSize), !chunkData.isEmpty else {
                        return
                    }

                    // 関連データ (AEAD): streamSalt + chunkIndex (改ざん・並べ替え防止)
                    var authData = streamSalt
                    withUnsafeBytes(of: UInt64(chunkIndex).bigEndian) { authData.append(contentsOf: $0) }

                    let sealed = try AES.GCM.seal(chunkData, using: key, authenticating: authData)
                    guard let combined = sealed.combined else {
                        throw VaultError.encryptionFailed("チャンク \(chunkIndex) の暗号化結合に失敗しました。")
                    }

                    // チャンク長プレフィックス (UInt32 big-endian) + 暗号化データ (Nonce + Ciphertext + Tag)
                    var chunkLengthData = Data()
                    withUnsafeBytes(of: UInt32(combined.count).bigEndian) { chunkLengthData.append(contentsOf: $0) }

                    try writeFileHandle.write(contentsOf: chunkLengthData)
                    try writeFileHandle.write(contentsOf: combined)

                    processedBytes += Int64(chunkData.count)
                    chunkIndex += 1

                    if totalBytes > 0 {
                        progress?(Double(processedBytes) / Double(totalBytes))
                    }
                } catch {
                    // エラー発生時は中途半端な出力ファイルを削除
                    try? fileManager.removeItem(at: destinationURL)
                }
            }

            // EOF判定
            if processedBytes >= totalBytes {
                break
            }
        }

        progress?(1.0)
    }

    /// 大容量暗号化コンテナファイルのストリーム復号
    /// - パラメータ:
    ///   - sourceURL: 暗号化コンテナURL (.enc)
    ///   - destinationURL: 出力先平文ファイルURL (.mp4等)
    ///   - key: マスター暗号化鍵
    ///   - progress: 進捗コールバック (0.0〜1.0)
    static func decryptFile(
        at sourceURL: URL,
        to destinationURL: URL,
        using key: SymmetricKey,
        progress: ((Double) -> Void)? = nil
    ) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw VaultError.fileNotFound
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            try? fileManager.removeItem(at: destinationURL)
        }

        guard fileManager.createFile(atPath: destinationURL.path, contents: nil, attributes: nil) else {
            throw VaultError.fileOperationFailed("復号出力ファイルの作成に失敗しました。")
        }

        let readFileHandle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? readFileHandle.close() }

        let writeFileHandle = try FileHandle(forWritingTo: destinationURL)
        defer { try? writeFileHandle.close() }

        // 1. ヘッダー検証 (28バイト: Magic 4B + StreamSalt 16B + TotalPlainBytes 8B)
        let headerSize = streamMagic.count + streamSaltSize + 8
        guard let headerData = try readFileHandle.read(upToCount: headerSize), headerData.count == headerSize else {
            try? fileManager.removeItem(at: destinationURL)
            throw VaultError.integrityCheckFailed
        }

        let magicData = headerData.prefix(streamMagic.count)
        guard [UInt8](magicData) == streamMagic else {
            try? fileManager.removeItem(at: destinationURL)
            throw VaultError.integrityCheckFailed
        }

        let streamSalt = headerData.subdata(in: streamMagic.count..<(streamMagic.count + streamSaltSize))
        let totalBytesRaw = headerData.subdata(in: (streamMagic.count + streamSaltSize)..<headerSize)
        let rawTotal = totalBytesRaw.withUnsafeBytes { $0.load(as: UInt64.self) }
        let expectedTotalBytes = UInt64(bigEndian: rawTotal)

        var decryptedBytes: Int64 = 0
        var chunkIndex: UInt64 = 0

        while decryptedBytes < Int64(expectedTotalBytes) {
            var shouldBreak = false
            try autoreleasepool {
                // チャンク長 (4バイト) を読み込む
                guard let lenData = try readFileHandle.read(upToCount: 4), lenData.count == 4 else {
                    shouldBreak = true
                    return
                }

                let rawChunkLen = lenData.withUnsafeBytes { $0.load(as: UInt32.self) }
                let chunkLength = UInt32(bigEndian: rawChunkLen)
                guard chunkLength > 0, chunkLength <= UInt32(streamChunkSize + 128) else {
                    throw VaultError.integrityCheckFailed
                }

                // チャンク実データを読み込む
                guard let combinedData = try readFileHandle.read(upToCount: Int(chunkLength)), combinedData.count == Int(chunkLength) else {
                    throw VaultError.integrityCheckFailed
                }

                // 関連データ (AEAD): streamSalt + chunkIndex
                var authData = streamSalt
                withUnsafeBytes(of: UInt64(chunkIndex).bigEndian) { authData.append(contentsOf: $0) }

                do {
                    let box = try AES.GCM.SealedBox(combined: combinedData)
                    let plainChunk = try AES.GCM.open(box, using: key, authenticating: authData)
                    try writeFileHandle.write(contentsOf: plainChunk)

                    decryptedBytes += Int64(plainChunk.count)
                    chunkIndex += 1

                    if expectedTotalBytes > 0 {
                        progress?(Double(decryptedBytes) / Double(expectedTotalBytes))
                    }
                } catch {
                    throw VaultError.integrityCheckFailed
                }
            }

            if shouldBreak {
                break
            }
        }

        // 平文サイズ整合性検証
        guard decryptedBytes == Int64(expectedTotalBytes) else {
            try? fileManager.removeItem(at: destinationURL)
            throw VaultError.integrityCheckFailed
        }

        progress?(1.0)
    }

    // MARK: - Keychain 生体認証鍵管理 (ThisDeviceOnly)

    private static let productionKeychain = ProductionVaultKeychainStorage()

    /// 生体認証解除用にマスター鍵をKeychainに安全に保存
    static func saveBiometricMasterKey(_ key: SymmetricKey) -> Bool {
        productionKeychain.saveBiometricMasterKey(key)
    }

    /// Keychainから生体認証用マスター鍵を読み出し
    static func loadBiometricMasterKey() -> SymmetricKey? {
        productionKeychain.loadBiometricMasterKey()
    }

    /// Keychainの生体認証用マスター鍵を削除
    @discardableResult
    static func deleteBiometricMasterKey() -> Bool {
        productionKeychain.deleteBiometricMasterKey()
    }
}


// MARK: - VaultKeychainStorageProtocol & Production Implementation

/// Vaultマスター鍵のセキュアストレージプロトコル（本番Keychainとテストモックの完全分離）
protocol VaultKeychainStorageProtocol: AnyObject {
    func saveBiometricMasterKey(_ key: SymmetricKey) -> Bool
    func loadBiometricMasterKey() -> SymmetricKey?
    @discardableResult
    func deleteBiometricMasterKey() -> Bool
}

/// 本番環境用Keychainストレージ（サービス: com.clipharbor.app.vault, アカウント: master_key_biometric）
final class ProductionVaultKeychainStorage: VaultKeychainStorageProtocol {
    private static let keychainService = "com.clipharbor.app.vault"
    private static let keychainAccount = "master_key_biometric"

    func saveBiometricMasterKey(_ key: SymmetricKey) -> Bool {
        let keyData = key.withUnsafeBytes { Data($0) }
        deleteBiometricMasterKey() // 既存のアイテムを削除

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    func loadBiometricMasterKey() -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let keyData = item as? Data, keyData.count == 32 else {
            return nil
        }

        return SymmetricKey(data: keyData)
    }

    @discardableResult
    func deleteBiometricMasterKey() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// テスト用Keychainストレージモック（SecItem APIを一切呼ばず、本番Keychainから完全隔離）
final class MockVaultKeychainStorage: VaultKeychainStorageProtocol {
    var storedKey: SymmetricKey?
    var saveCallCount = 0
    var loadCallCount = 0
    var deleteCallCount = 0

    func saveBiometricMasterKey(_ key: SymmetricKey) -> Bool {
        saveCallCount += 1
        storedKey = key
        return true
    }

    func loadBiometricMasterKey() -> SymmetricKey? {
        loadCallCount += 1
        return storedKey
    }

    @discardableResult
    func deleteBiometricMasterKey() -> Bool {
        deleteCallCount += 1
        storedKey = nil
        return true
    }
}
