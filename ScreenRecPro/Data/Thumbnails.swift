import AVFoundation
import ImageIO
import SwiftUI
import UIKit

/// Byte-bounded thumbnail cache, the iOS counterpart of Android's
/// `studio/Filmstrip.kt` cache. One generator per request; frames are decoded
/// straight to thumbnail size.
final class Thumbnails {
    static let shared = Thumbnails()

    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 48 * 1024 * 1024
        return c
    }()

    func cached(_ url: URL, at ms: Int64, maxSide: CGFloat) -> UIImage? {
        cache.object(forKey: key(url, ms, maxSide))
    }

    func image(for url: URL, at ms: Int64 = 0, maxSide: CGFloat = 320) async -> UIImage? {
        let k = key(url, ms, maxSide)
        if let hit = cache.object(forKey: k) { return hit }
        let img: UIImage?
        if MediaLibrary.kindOf(url) == .video {
            img = await Self.videoFrame(url, ms: ms, maxSide: maxSide)
        } else {
            img = Self.downsampledImage(url, maxSide: maxSide)
        }
        if let img, let cg = img.cgImage {
            cache.setObject(img, forKey: k, cost: cg.bytesPerRow * cg.height)
        }
        return img
    }

    private func key(_ url: URL, _ ms: Int64, _ side: CGFloat) -> NSString {
        "\(url.path)|\(ms)|\(Int(side))" as NSString
    }

    static func videoFrame(_ url: URL, ms: Int64, maxSide: CGFloat) async -> UIImage? {
        await withCheckedContinuation { cont in
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: maxSide, height: maxSide)
            gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
            gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
            let t = NSValue(time: CMTime(value: ms, timescale: 1000))
            // One requested time -> the handler fires exactly once.
            gen.generateCGImagesAsynchronously(forTimes: [t]) { _, cg, _, _, _ in
                cont.resume(returning: cg.map { UIImage(cgImage: $0) })
            }
        }
    }

    static func downsampledImage(_ url: URL, maxSide: CGFloat) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// Async thumbnail view. Always fills the frame the parent proposes — portrait
/// videos used to report their native aspect and collapse to a thin strip in
/// LazyVGrid cells (looking like a floating ad card).
struct ThumbnailView: View {
    let url: URL
    var ms: Int64 = 0
    var maxSide: CGFloat = 320
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Brand.surfaceHigh
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .clipped()
        .task(id: "\(url.path)|\(ms)") {
            image = Thumbnails.shared.cached(url, at: ms, maxSide: maxSide)
            if image == nil { image = await Thumbnails.shared.image(for: url, at: ms, maxSide: maxSide) }
        }
    }
}
