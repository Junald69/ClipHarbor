import Foundation
import CryptoKit
import UIKit

// MARK: - テスト用モック（本番データ・UserDefaults・実ファイル隔離）

final class MockDownloadManager: VaultDownloadManaging {
    var savedVideos: [UUID: SavedVideo] = [:]
    var persistShouldFail: Bool = false
    var removeCalledForIDs: [UUID] = []

    func removeSavedVideoWithoutDeletingFile(id: UUID) {
        removeCalledForIDs.append(id)
        savedVideos.removeValue(forKey: id)
    }

    func restoreSavedVideoThrowing(_ video: SavedVideo) throws {
        if persistShouldFail {
            throw NSError(domain: "MockDownloadManager", code: 500, userInfo: [
                NSLocalizedDescriptionKey: "Simulated persistSaved failure"
            ])
        }
        savedVideos[video.id] = video
    }
}

final class MockFolderManager: VaultFolderManaging {
    var folderMap: [UUID: String] = [:]
    var removedVideoIDs: [UUID] = []

    func folderName(for video: SavedVideo) -> String {
        folderMap[video.id] ?? ""
    }

    func removeVideoFromFolder(videoID: UUID) {
        removedVideoIDs.append(videoID)
        folderMap.removeValue(forKey: videoID)
    }

    func restoreVideoToFolder(_ video: SavedVideo, targetFolder: String) {
        folderMap[video.id] = targetFolder
    }
}

/// Vaultデータ保全・整合性保護のための障害注入テスト基盤
/// - 注: ユーザーの実Vault領域、本番Keychain、本番UserDefaults、実Documents/Downloadsには一切アクセスせず、
///   専用の一時ディレクトリ（temporaryDirectory）およびモック依存関係内で完結します。
enum VaultFaultInjectionTests {

    /// 安全なテスト専用分離環境を生成
    static func createIsolatedEnvironment() throws -> (
        baseDir: URL,
        vault: VaultManager,
        downloadsDir: URL,
        mockDownloads: MockDownloadManager,
        mockFolders: MockFolderManager
    ) {
        // 安全防護サーキットブレーカー: 本番Keychainアクセスを物理遮断
        VaultCrypto.allowProductionKeychainAccess = false

        let fileManager = FileManager.default
        let baseDir = fileManager.temporaryDirectory.appendingPathComponent("VaultIsolatedTest_\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: baseDir, withIntermediateDirectories: true)

        let downloadsDir = baseDir.appendingPathComponent("IsolatedDownloads", isDirectory: true)
        try fileManager.createDirectory(at: downloadsDir, withIntermediateDirectories: true)

        let mockDownloads = MockDownloadManager()
        let mockFolders = MockFolderManager()

        let vault = VaultManager(baseDirectory: baseDir, downloadsDirectory: downloadsDir)
        try vault.setupPasscode("123456", confirmPasscode: "123456", enableBiometrics: false)

        return (baseDir, vault, downloadsDir, mockDownloads, mockFolders)
    }

    /// テスト用のダミー動画ファイルを一時領域に生成
    static func createDummyFile(in dir: URL, name: String, byteCount: Int = 2048) throws -> URL {
        let fileURL = dir.appendingPathComponent(name)
        let dummyData = Data(repeating: 0x41, count: byteCount)
        try dummyData.write(to: fileURL, options: .atomic)
        return fileURL
    }
}
