import Foundation
import UIKit
import AVFoundation

/// 動画サムネイルと再生時間の非同期生成・メモリキャッシュ管理マネージャー
/// - メインスレッドを一切ブロックせず、バックグラウンド優先度（utility）で生成
/// - iOS 16+ のネイティブ非同期 API（generator.image(at:)）を活用
/// - NSCache を用いてスクロール時の再生成を抑制
/// - フォルダ移動や名前変更時にも一貫したキャッシュキー（video.id.uuidString）
/// - HLS (.movpkg) や破損動画の場合は安全にプレースホルダー表示へフォールバック
/// - 動画ファイルの削除時にキャッシュを無効化
final class VideoThumbnailManager: ObservableObject {
    static let shared = VideoThumbnailManager()

    private let thumbnailCache = NSCache<NSString, UIImage>()
    private var durationCache: [UUID: Double] = [:]
    private var inFlightThumbnailTasks: [UUID: Task<UIImage?, Never>] = [:]
    private let lock = NSLock()
    private let maxDurationEntries = 500

    private init() {
        thumbnailCache.countLimit = 150
        thumbnailCache.totalCostLimit = 80 * 1024 * 1024 // 80MB 目安
    }

    // MARK: - キャッシュキー（動画IDベースで移動・リネームに不変）

    private func cacheKey(for video: SavedVideo) -> NSString {
        video.id.uuidString as NSString
    }

    // MARK: - 同期読み出し（キャッシュ済みのみ）

    /// キャッシュ済みのサムネイルを同期取得（存在しない場合は nil）
    func cachedThumbnail(for video: SavedVideo) -> UIImage? {
        thumbnailCache.object(forKey: cacheKey(for: video))
    }

    /// キャッシュ済みの再生時間（秒）を同期取得（未取得時は nil）
    func cachedDuration(for video: SavedVideo) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return durationCache[video.id]
    }

    /// フォーマット済みの再生時間文字列
    func formattedDuration(for video: SavedVideo) -> String? {
        guard let seconds = cachedDuration(for: video) else { return nil }
        return Self.formatDuration(seconds)
    }

    // MARK: - スレッドセーフ同期ヘルパー

    private func getOrStartTask(for id: UUID, taskFactory: () -> Task<UIImage?, Never>) -> (Task<UIImage?, Never>, Bool) {
        lock.lock()
        defer { lock.unlock() }
        if let existing = inFlightThumbnailTasks[id] {
            return (existing, false)
        }
        let task = taskFactory()
        inFlightThumbnailTasks[id] = task
        return (task, true)
    }

    private func finishTask(for id: UUID, key: NSString, image: UIImage?) {
        lock.lock()
        defer { lock.unlock() }
        inFlightThumbnailTasks.removeValue(forKey: id)
        if let image = image {
            let cost = Int(image.size.width * image.size.height * 4)
            thumbnailCache.setObject(image, forKey: key, cost: cost)
        }
    }

    private func storeDuration(_ seconds: Double, for id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if durationCache.count >= maxDurationEntries {
            durationCache.removeAll()
        }
        durationCache[id] = seconds
    }

    // MARK: - 非同期取得

    /// サムネイルを非同期取得（キャッシュがあれば即座に返却、メインスレッド非同期）
    func loadThumbnail(for video: SavedVideo) async -> UIImage? {
        if Task.isCancelled { return nil }

        let key = cacheKey(for: video)
        if let cached = thumbnailCache.object(forKey: key) {
            return cached
        }

        // 重複タスク管理ヘルパー（非同期コンテキストでの直接lock回避）
        let (task, _) = getOrStartTask(for: video.id) {
            Task.detached(priority: .utility) { [weak self] () -> UIImage? in
                guard let self = self else { return nil }
                return await self.generateThumbnail(for: video)
            }
        }

        let image = await task.value
        finishTask(for: video.id, key: key, image: image)
        return image
    }

    /// 再生時間を非同期取得
    func loadDuration(for video: SavedVideo) async -> Double? {
        if Task.isCancelled { return nil }

        if let cached = cachedDuration(for: video) {
            return cached
        }

        let fileURL = video.fileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        let asset = AVURLAsset(url: fileURL)
        let seconds: Double
        if #available(iOS 16.0, *) {
            if let cmTime = try? await asset.load(.duration) {
                seconds = CMTimeGetSeconds(cmTime)
            } else {
                seconds = CMTimeGetSeconds(asset.duration)
            }
        } else {
            seconds = CMTimeGetSeconds(asset.duration)
        }

        guard seconds > 0, !seconds.isNaN, !seconds.isInfinite else { return nil }
        storeDuration(seconds, for: video.id)
        return seconds
    }

    /// フォルダ内のモザイクプレビュー用サムネイル（最大 limit 枚）
    func loadMosaicThumbnails(for videos: [SavedVideo], limit: Int = 3) async -> [UIImage] {
        let targetVideos = Array(videos.prefix(limit))
        var images: [UIImage] = []
        for v in targetVideos {
            if Task.isCancelled { break }
            if let img = await loadThumbnail(for: v) {
                images.append(img)
            }
        }
        return images
    }

    // MARK: - キャッシュ無効化

    /// 特定動画のキャッシュを無効化（削除時など）
    func invalidateCache(for video: SavedVideo) {
        lock.lock()
        thumbnailCache.removeObject(forKey: cacheKey(for: video))
        durationCache.removeValue(forKey: video.id)
        inFlightThumbnailTasks.removeValue(forKey: video.id)
        lock.unlock()
    }

    /// 全キャッシュのクリア（メモリ解放）
    func clearAllCache() {
        lock.lock()
        thumbnailCache.removeAllObjects()
        durationCache.removeAll()
        inFlightThumbnailTasks.removeAll()
        lock.unlock()
    }

    // MARK: - サムネイル生成ロジック

    private func generateThumbnail(for video: SavedVideo) async -> UIImage? {
        await generateThumbnail(forFileURL: video.fileURL)
    }

    /// 任意の動画ファイルURLからサムネイルを非同期生成（ゴミ箱内動画など非公開ファイルにも対応）
    func generateThumbnail(forFileURL fileURL: URL) async -> UIImage? {
        if Task.isCancelled { return nil }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        // HLS (.movpkg) はディレクトリ構造により AVAssetImageGenerator が失敗することがあるため
        // 安全にハンドリングして nil を返す（UI側で安全なプレースホルダーを表示）
        let asset = AVURLAsset(url: fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 400, height: 400) // メモリ肥大化防止

        let candidates = [
            CMTime(seconds: 1.0, preferredTimescale: 600),
            CMTime.zero
        ]

        for time in candidates {
            if Task.isCancelled { return nil }

            if #available(iOS 16.0, *) {
                // iOS 16+ のネイティブ非同期 API
                if let (cgImage, _) = try? await generator.image(at: time) {
                    return UIImage(cgImage: cgImage)
                }
            } else {
                if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                    return UIImage(cgImage: cgImage)
                }
            }
        }
        return nil
    }

    // MARK: - フォーマットヘルパー

    static func formatDuration(_ seconds: Double) -> String {
        guard seconds > 0, !seconds.isNaN, !seconds.isInfinite else {
            return "不明"
        }
        let totalSeconds = Int(seconds.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%02d:%02d", minutes, secs)
        }
    }
}
