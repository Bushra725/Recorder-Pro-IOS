import AVFoundation
import CoreImage
import UIKit

/// Snapshot of everything the compositor needs to draw one frame. Built from
/// a `StudioState`; replaced (not mutated) when the user changes a look so the
/// paused preview can re-render without rebuilding the player item.
struct RenderSpec {
    var renderSize: CGSize
    var canvas: String
    var rotationDeg: Int
    var flipX: Bool
    var cropRatio: Ratio
    var cropInset: Double
    var regionCrop: CGRect?
    var filterMatrix: ColorMatrix
    var filterRange: ClosedRange<Int64>
    var effectMatrix: ColorMatrix
    var effectRange: ClosedRange<Int64>
    var adjustMatrix: ColorMatrix
    var texts: [TextItem]
    var watermarkLabel: String?

    init(state: StudioState, renderSize: CGSize, includeOverlays: Bool, watermarkLabel: String?) {
        self.renderSize = renderSize
        canvas = state.canvas
        rotationDeg = state.rotationDeg
        flipX = state.flipX
        cropRatio = state.cropRatio
        cropInset = state.cropInset
        regionCrop = state.regionCrop
        filterMatrix = LookCatalog.matrix(for: LookCatalog.filter(state.filter), strength: state.filterStrength)
        filterRange = state.filterStartMs...max(state.filterStartMs, state.filterEndMs)
        effectMatrix = LookCatalog.matrix(for: LookCatalog.effect(state.effect), strength: state.effectStrength)
        effectRange = state.effectStartMs...max(state.effectStartMs, state.effectEndMs)
        adjustMatrix = .adjust(brightness: state.brightness, contrast: state.contrast,
                               saturation: state.saturation, warmth: state.warmth)
        texts = includeOverlays ? state.texts : []
        self.watermarkLabel = watermarkLabel
    }
}

/// Thread-safe holder so the compositor (render thread) always reads the latest spec.
final class SpecBox {
    private let lock = NSLock()
    private var _spec: RenderSpec
    init(_ spec: RenderSpec) { _spec = spec }
    var spec: RenderSpec {
        get { lock.lock(); defer { lock.unlock() }; return _spec }
        set { lock.lock(); _spec = newValue; lock.unlock() }
    }
}

/// The per-frame pipeline. Shared by the video compositor, the photo editor and
/// look thumbnails, so preview and export are the same code.
enum FramePipeline {
    static let workingSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Shared GPU context. sRGB *working* space keeps the colour maths in gamma
    /// space, which is what Android's ColorMatrix numbers were tuned in.
    static let context: CIContext = CIContext(options: [
        .workingColorSpace: workingSpace,
        .outputColorSpace: workingSpace,
        .cacheIntermediates: false
    ])

    /// Upright copy of a video frame, given the track's preferredTransform.
    static func upright(_ image: CIImage, transform t: CGAffineTransform) -> CIImage {
        let o: CGImagePropertyOrientation
        if t.a == 0 && t.b == 1 && t.c == -1 && t.d == 0 { o = .right }
        else if t.a == 0 && t.b == -1 && t.c == 1 && t.d == 0 { o = .left }
        else if t.a == -1 && t.d == -1 { o = .down }
        else { o = .up }
        return normalized(image.oriented(o))
    }

    static func normalized(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }

    /// Geometry shared by video and photo: region crop → rotate → flip → crop ratio → zoom.
    static func geometry(_ input: CIImage, regionCrop: CGRect?, rotationDeg: Int, flipX: Bool,
                         cropRatio: Ratio, cropInset: Double) -> CIImage {
        var img = normalized(input)
        if let r = regionCrop {
            let W = img.extent.width, H = img.extent.height
            let rect = CGRect(x: r.minX * W, y: (1 - r.maxY) * H, width: r.width * W, height: r.height * H).integral
            img = normalized(img.cropped(to: rect.intersection(img.extent)))
        }
        switch ((rotationDeg % 360) + 360) % 360 {
        case 90: img = normalized(img.oriented(.right))
        case 180: img = normalized(img.oriented(.down))
        case 270: img = normalized(img.oriented(.left))
        default: break
        }
        if flipX { img = normalized(img.oriented(.upMirrored)) }
        if !cropRatio.isOriginal {
            img = normalized(img.cropped(to: centerRect(of: img.extent.size, ratio: cropRatio.value)))
        }
        if cropInset > 0 {
            let e = img.extent
            let inset = min(0.45, cropInset)
            img = normalized(img.cropped(to: e.insetBy(dx: e.width * inset, dy: e.height * inset)))
        }
        return img
    }

    static func centerRect(of size: CGSize, ratio: Double) -> CGRect {
        guard ratio > 0 else { return CGRect(origin: .zero, size: size) }
        var w = size.width, h = size.height
        if w / h > ratio { w = h * ratio } else { h = w / ratio }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h).integral
    }

    /// Full frame: `source` must already be upright.
    static func compose(source: CIImage, clipMatrix: ColorMatrix, spec: RenderSpec, timeMs: Int64) -> CIImage {
        var img = geometry(source, regionCrop: spec.regionCrop, rotationDeg: spec.rotationDeg,
                           flipX: spec.flipX, cropRatio: spec.cropRatio, cropInset: spec.cropInset)

        var m = clipMatrix
        if spec.filterRange.contains(timeMs) { m = m.concat(spec.filterMatrix) }
        if spec.effectRange.contains(timeMs) { m = m.concat(spec.effectMatrix) }
        m = m.concat(spec.adjustMatrix)
        img = m.apply(to: img)

        let out = CGRect(origin: .zero, size: spec.renderSize)
        img = fit(img, into: out, canvas: spec.canvas)
        img = overlays(on: img, spec: spec, timeMs: timeMs)
        return img.cropped(to: out)
    }

    static func fit(_ image: CIImage, into out: CGRect, canvas: String) -> CIImage {
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return CIImage(color: .black).cropped(to: out) }
        let scale = min(out.width / e.width, out.height / e.height)
        let w = e.width * scale, h = e.height * scale
        let placed = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: (out.width - w) / 2, y: (out.height - h) / 2))

        // No visible canvas: the content fills the frame.
        if abs(w - out.width) < 2 && abs(h - out.height) < 2 { return placed }

        let background: CIImage
        if canvas == "blur" || canvas == "blur_dark" {
            let fill = max(out.width / e.width, out.height / e.height)
            var bg = image.transformed(by: CGAffineTransform(scaleX: fill, y: fill))
            bg = bg.transformed(by: CGAffineTransform(translationX: (out.width - e.width * fill) / 2,
                                                     y: (out.height - e.height * fill) / 2))
            bg = bg.clampedToExtent().applyingGaussianBlur(sigma: max(12, out.width / 28)).cropped(to: out)
            let dim = canvas == "blur_dark" ? 0.45 : 0.8
            bg = ColorMatrix.scale(dim, dim, dim).apply(to: bg)
            background = bg
        } else {
            background = CIImage(color: CIColor(color: Brand.canvasColor(canvas))).cropped(to: out)
        }
        return placed.composited(over: background)
    }

    static func overlays(on base: CIImage, spec: RenderSpec, timeMs: Int64) -> CIImage {
        var img = base
        let W = spec.renderSize.width, H = spec.renderSize.height
        for item in spec.texts where item.visible(at: timeMs) {
            guard let cg = TextRenderer.image(for: item, frameHeight: H).cgImage else { continue }
            var t = CIImage(cgImage: cg)
            let tw = t.extent.width, th = t.extent.height
            t = t.transformed(by: CGAffineTransform(translationX: -tw / 2, y: -th / 2))
            if item.rotation != 0 {
                t = t.transformed(by: CGAffineTransform(rotationAngle: -CGFloat(item.rotation) * .pi / 180))
            }
            t = t.transformed(by: CGAffineTransform(translationX: CGFloat(item.x) * W,
                                                     y: (1 - CGFloat(item.y)) * H))
            img = t.composited(over: img)
        }
        if let label = spec.watermarkLabel, let cg = TextRenderer.watermark(label, frameHeight: H).cgImage {
            let wm = CIImage(cgImage: cg)
            let margin = min(W, H) * 0.035
            img = wm.transformed(by: CGAffineTransform(translationX: W - wm.extent.width - margin, y: margin))
                .composited(over: img)
        }
        return img
    }

    /// Size of the content after geometry, without decoding a frame.
    static func contentSize(source: CGSize, state: StudioState) -> CGSize {
        let probe = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: source))
        return geometry(probe, regionCrop: state.regionCrop, rotationDeg: state.rotationDeg, flipX: false,
                        cropRatio: state.cropRatio, cropInset: state.cropInset).extent.size
    }

    /// Output frame size: the format ratio (or the content's own), short edge capped.
    static func renderSize(content: CGSize, ratio: Ratio, maxShortEdge: CGFloat) -> CGSize {
        let aspect = ratio.isOriginal ? content.width / max(1, content.height) : CGFloat(ratio.value)
        let contentShort = min(content.width, content.height)
        let short = min(maxShortEdge, max(240, contentShort))
        var w: CGFloat, h: CGFloat
        if aspect >= 1 { h = short; w = short * aspect } else { w = short; h = short / aspect }
        func even(_ v: CGFloat) -> CGFloat { max(16, (v / 2).rounded() * 2) }
        return CGSize(width: even(w), height: even(h))
    }
}
