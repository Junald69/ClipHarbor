import SwiftUI
import AVFoundation
import UIKit

/// 保存済み動画からサムネイル画像を非同期生成し、メモリ上にキャッシュする。
@MainActor
final class VideoThumbnailGenerator {
    static let shared = VideoThumbnailGenerator()

    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    private init() {
        cache.countLimit = 120
    }

    func cachedImage(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func invalidate(for key: String) {
        cache.removeObject(forKey: key as NSString)
        inFlight[key]?.cancel()
        inFlight[key] = nil
    }

    func thumbnail(for video: SavedVideo) async -> UIImage? {
        let key = video.id.uuidString
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }
        if let existingTask = inFlight[key] {
            return await existingTask.value
        }
        // HLS(.movpkg)はAVAssetImageGeneratorで開くと再生・検証処理と競合する場合があるため、直接ファイル(MP4等)のみサムネイル生成する
        guard !video.isHLS, video.fileExists else { return nil }
        let fileURL = video.fileURL

        let task = Task.detached(priority: .utility) { () -> UIImage? in
            let asset = AVURLAsset(url: fileURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240, height: 160)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)

            let candidateTimes = [
                CMTime(seconds: 1.0, preferredTimescale: 600),
                CMTime(seconds: 0.1, preferredTimescale: 600),
                .zero
            ]
            for t in candidateTimes {
                if Task.isCancelled { return nil }
                if let (cgImage, _) = try? await generator.image(at: t) {
                    return UIImage(cgImage: cgImage)
                }
            }
            return nil
        }

        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image = image {
            cache.setObject(image, forKey: key as NSString)
        }
        return image
    }
}

/// 保存済み動画のサムネイル表示ビュー
struct SavedVideoThumbnailView: View {
    let video: SavedVideo
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.secondary.opacity(0.14)
                    Image(systemName: video.isHLS ? "play.square.stack" : "film")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }

            Text(video.format.label)
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(.white)
                .padding(4)
        }
        .frame(width: 84, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
        )
        .task(id: video.id) {
            if let cached = VideoThumbnailGenerator.shared.cachedImage(for: video.id.uuidString) {
                image = cached
            } else {
                image = await VideoThumbnailGenerator.shared.thumbnail(for: video)
            }
        }
    }
}
