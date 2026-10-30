import Foundation
import UIKit
import AVFoundation
import ImageIO
import CoreImage

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
    private var failedHLSURLs: Set<URL> = []
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

    /// 既存のサムネイル画像をキャッシュに登録
    func cacheThumbnail(_ image: UIImage, for video: SavedVideo) {
        thumbnailCache.setObject(image, forKey: cacheKey(for: video))
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
        if video.format.isImage { return nil }

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
        failedHLSURLs.remove(video.fileURL)
        durationCache.removeValue(forKey: video.id)
        inFlightThumbnailTasks.removeValue(forKey: video.id)
        lock.unlock()
    }

    /// 全キャッシュのクリア（メモリ解放）
    func clearAllCache() {
        lock.lock()
        thumbnailCache.removeAllObjects()
        failedHLSURLs.removeAll()
        durationCache.removeAll()
        inFlightThumbnailTasks.removeAll()
        lock.unlock()
    }

    // MARK: - サムネイル生成ロジック

    private func generateThumbnail(for video: SavedVideo) async -> UIImage? {
        await generateThumbnail(forFileURL: video.fileURL)
    }

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "heic"]

    /// 任意の動画・画像ファイルURLからサムネイルを非同期生成（ゴミ箱内ファイルなど非公開ファイルにも対応）
    func generateThumbnail(forFileURL fileURL: URL) async -> UIImage? {
        if Task.isCancelled { return nil }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let ext = fileURL.pathExtension.lowercased()
        if Self.imageExtensions.contains(ext) {
            return generateImageThumbnail(forFileURL: fileURL)
        }

        if ext == "movpkg" {
            // 切り分け検証のため、一時的にオフラインHLS (.movpkg) のサムネイル抽出をバイパス
            // HLSExtractionQueue は起動せず、nil を返してプレースホルダーを表示
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

    /// 画像ファイルからメモリ効率の良い縮小サムネイルを生成（原寸画像を展開せず省メモリ処理）
    private func generateImageThumbnail(forFileURL fileURL: URL) -> UIImage? {
        guard let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 400
        ]
        guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgThumb)
    }

    // MARK: - フォーマットヘルパー

    static func formatDuration(_ seconds: Double) -> String {
        guard seconds > 0, !seconds.isNaN, !seconds.isInfinite else {
            return NSLocalizedString("Unknown", comment: "")
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


// MARK: - HLS専用フレーム抽出アクター

/// HLS (.movpkg) からのサムネイル抽出用専用アクター
/// - 同時抽出数を1に制限し、バックグラウンド負荷とデコーダーリソースの競合を防止
/// - 専用の消音 AVPlayer と AVPlayerItemVideoOutput を使用し、メイン再生やシステム音声、PiPに干渉しない
private actor HLSExtractionQueue {
    static let shared = HLSExtractionQueue()
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    func extractThumbnail(from fileURL: URL) async -> UIImage? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        let asset = AVURLAsset(url: fileURL)
        let item = AVPlayerItem(asset: asset)
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: pixelBufferAttributes)
        item.add(videoOutput)

        // 専用の消音 AVPlayer（Coordinatorやメイン再生とは完全分離）
        let player = AVPlayer(playerItem: item)
        player.volume = 0.0
        player.isMuted = true
        player.actionAtItemEnd = .pause

        // 確実な後始末（早期脱出やタイムアウト時もリーク防止）
        defer {
            item.remove(videoOutput)
            player.replaceCurrentItem(with: nil)
        }

        // 1. readyToPlay の待機（タイムアウト: 3.0秒）
        let isReady = await waitForItemReady(item: item, timeoutSeconds: 3.0)
        guard isReady else { return nil }

        // 2. 抽出対象時間（0.5秒または先頭付近）へシーク
        let itemDuration = CMTimeGetSeconds(item.duration)
        let targetSecs: Double
        if !itemDuration.isNaN && !itemDuration.isInfinite && itemDuration > 1.0 {
            targetSecs = min(itemDuration * 0.1, 1.0)
        } else {
            targetSecs = 0.1
        }
        let targetTime = CMTime(seconds: targetSecs, preferredTimescale: 600)

        let didSeek = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                continuation.resume(returning: finished)
            }
        }
        guard didSeek else { return nil }

        // 3. ピクセルバッファの取得待機（最大5回・計0.5秒リトライ）
        for _ in 0..<5 {
            if Task.isCancelled { return nil }
            if videoOutput.hasNewPixelBuffer(forItemTime: targetTime),
               let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: targetTime, itemTimeForDisplay: nil) {
                let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
                if let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) {
                    return UIImage(cgImage: cgImage)
                }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        // hasNewPixelBuffer が false でも copyPixelBuffer を試みる
        if let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: targetTime, itemTimeForDisplay: nil) {
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            if let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) {
                return UIImage(cgImage: cgImage)
            }
        }

        return nil
    }

    private func waitForItemReady(item: AVPlayerItem, timeoutSeconds: Double) async -> Bool {
        if item.status == .readyToPlay { return true }
        if item.status == .failed { return false }

        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for _ in 0..<Int(timeoutSeconds * 10) {
                    if Task.isCancelled { return false }
                    if item.status == .readyToPlay { return true }
                    if item.status == .failed { return false }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                return item.status == .readyToPlay
            }
            return await group.next() ?? false
        }
    }
}


// MARK: - VaultThumbnailManaging Conformance
extension VideoThumbnailManager: VaultThumbnailManaging {}
