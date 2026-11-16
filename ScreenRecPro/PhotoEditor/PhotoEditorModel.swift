import CoreImage
import SwiftUI
import UIKit

/// Brush tools. Port of Android's PhotoDraw / BrushService tool set.
enum BrushTool: String, CaseIterable, Identifiable {
    case pen, marker, rect, oval, arrow, eraser
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .pen: return "pencil.tip"
        case .marker: return "highlighter"
        case .rect: return "rectangle"
        case .oval: return "oval"
        case .arrow: return "arrow.up.right"
        case .eraser: return "eraser"
        }
    }
    var labelKey: String {
        switch self {
        case .pen: return "brush_tool_pen"
        case .marker: return "brush_tool_marker"
        case .rect: return "brush_tool_rect"
        case .oval: return "brush_tool_oval"
        case .arrow: return "brush_tool_arrow"
        case .eraser: return "brush_tool_eraser"
        }
    }
    var isShape: Bool { self == .rect || self == .oval || self == .arrow }
}

/// One mark, stored as geometry (not pixels): undo is one line, memory stays
/// flat however long you draw, and shapes rubber-band without allocations.
struct Stroke: Identifiable, Equatable {
    let id = UUID()
    var tool: BrushTool
    var points: [CGPoint]          // normalised 0…1 in image space
    var colorARGB: UInt32
    var width: CGFloat             // fraction of the image's short side
    var fill: Bool

    static func == (a: Stroke, b: Stroke) -> Bool { a.id == b.id && a.points == b.points }

    /// Draws into any CGContext whose user space is `size` (image pixels or view points).
    func draw(in ctx: CGContext, size: CGSize) {
        guard let first = points.first else { return }
        let short = min(size.width, size.height)
        let lw = max(1, width * short * (tool == .marker ? 3 : 1))
        let color = UIColor(argb: colorARGB).withAlphaComponent(tool == .marker ? 0.35 : 1).cgColor
        func p(_ n: CGPoint) -> CGPoint { CGPoint(x: n.x * size.width, y: n.y * size.height) }

        ctx.saveGState()
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(lw)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch tool {
        case .pen, .marker:
            let path = CGMutablePath()
            path.move(to: p(first))
            if points.count == 1 {
                path.addLine(to: p(first))
            } else {
                // Quadratic through midpoints: a fast swipe draws a curve, not corners.
                for i in 1..<points.count {
                    let a = p(points[i - 1]), b = p(points[i])
                    path.addQuadCurve(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), control: a)
                }
                path.addLine(to: p(points[points.count - 1]))
            }
            ctx.addPath(path)
            ctx.strokePath()
        case .rect, .oval:
            guard let last = points.last else { break }
            let a = p(first), b = p(last)
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            if tool == .rect { ctx.addRect(r) } else { ctx.addEllipse(in: r) }
            if fill { ctx.fillPath() } else { ctx.strokePath() }
        case .arrow:
            guard let last = points.last else { break }
            let a = p(first), b = p(last)
            ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
            let angle = atan2(b.y - a.y, b.x - a.x)
            let head = max(lw * 3.2, 14)
            let left = CGPoint(x: b.x - head * cos(angle - .pi / 7), y: b.y - head * sin(angle - .pi / 7))
            let right = CGPoint(x: b.x - head * cos(angle + .pi / 7), y: b.y - head * sin(angle + .pi / 7))
            ctx.move(to: b); ctx.addLine(to: left); ctx.addLine(to: right); ctx.closePath()
            ctx.fillPath()
        case .eraser:
            break
        }
        ctx.restoreGState()
    }

    /// Eraser hit test (whole marks, not pixels — like Android).
    func hit(_ n: CGPoint, radius: CGFloat) -> Bool {
        if tool.isShape, let a = points.first, let b = points.last {
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            return r.insetBy(dx: -radius, dy: -radius).contains(n)
        }
        return points.contains { hypot($0.x - n.x, $0.y - n.y) < radius }
    }
}

@MainActor
final class PhotoEditorModel: ObservableObject, TextStyleTarget {
    enum Panel: String, CaseIterable, Identifiable {
        case crop, filter, text, brush, sticker
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .crop: return "crop.rotate"
            case .filter: return "camera.filters"
            case .text: return "textformat"
            case .brush: return "scribble.variable"
            case .sticker: return "face.smiling"
            }
        }
        var labelKey: String {
            switch self {
            case .crop: return "tool_crop"
            case .filter: return "tool_filter"
            case .text: return "tool_text"
            case .brush: return "tool_brush"
            case .sticker: return "tool_stickers"
            }
        }
    }

    let url: URL
    @Published private(set) var source: UIImage?
    @Published private(set) var preview: UIImage?
    /// Small copy for the filter tiles.
    @Published private(set) var thumb: UIImage?
    @Published var rotation = 0
    @Published var flipX = false
    @Published var cropRatio: Ratio = .original
    @Published var filter = "none"
    @Published var filterStrength = 1.0
    @Published var texts: [TextItem] = []
    @Published var selectedTextID: Int64?
    @Published var strokes: [Stroke] = []
    @Published var live: Stroke?
    @Published var panel: Panel?
    @Published var brushTool: BrushTool = .pen
    @Published var brushColor: UInt32 = Brand.brushSwatches[2]
    @Published var brushWidth: CGFloat = 0.014
    @Published var brushFill = false
    @Published var busy = false
    @Published var notice: String?
    /// Base size while a two-finger pinch is in progress on the canvas.
    var pinchBaseSize: Double?
    private var geometryDirty = false
    private var staged: [TextItem]?

    init(url: URL, startWithBrush: Bool) {
        self.url = url
        if startWithBrush { panel = .brush }
    }

    func load() async {
        let img = await Task.detached { [url] in Thumbnails.downsampledImage(url, maxSide: 2560) }.value
        source = img
        thumb = img.map { Thumbnails.shrink($0, to: 140) }
        rebuild()
    }

    var hasEdits: Bool { geometryDirty || !texts.isEmpty || !strokes.isEmpty }

    /// Geometry + look → preview image.
    func rebuild() {
        guard let src = source, let cg = src.cgImage else { return }
        var img = FramePipeline.geometry(CIImage(cgImage: cg), regionCrop: nil, rotationDeg: rotation,
                                         flipX: flipX, cropRatio: cropRatio, cropInset: 0)
        img = LookCatalog.matrix(for: LookCatalog.filter(filter), strength: filterStrength).apply(to: img)
        if let out = FramePipeline.context.createCGImage(img, from: img.extent) {
            preview = UIImage(cgImage: out)
        }
    }

    func setGeometry(_ change: () -> Void) {
        change()
        geometryDirty = true
        rebuild()
    }

    // MARK: text (TextStyleTarget)

    func addText(_ text: String, template: TextItem? = nil) {
        var item = template ?? TextItem(text: text)
        item.id = makeClipID()
        item.text = text
        item.startMs = 0
        item.endMs = .max
        texts.append(item)
        selectedTextID = item.id
    }

    func updateText(_ id: Int64, staged: Bool, _ transform: (inout TextItem) -> Void) {
        guard let i = texts.firstIndex(where: { $0.id == id }) else { return }
        transform(&texts[i])
    }

    func commitStaged() {}

    func deleteText(_ id: Int64) {
        texts.removeAll { $0.id == id }
        selectedTextID = nil
    }

    var selectedText: TextItem? { selectedTextID.flatMap { id in texts.first { $0.id == id } } }

    // MARK: brush

    func brushBegan(at n: CGPoint) {
        if brushTool == .eraser { erase(at: n); return }
        live = Stroke(tool: brushTool, points: [n], colorARGB: brushColor, width: brushWidth, fill: brushFill)
    }

    func brushMoved(to n: CGPoint) {
        if brushTool == .eraser { erase(at: n); return }
        guard var s = live else { return }
        if s.tool.isShape {
            s.points = [s.points[0], n]
        } else if let last = s.points.last, hypot(last.x - n.x, last.y - n.y) > 0.002 {
            s.points.append(n)
        }
        live = s
    }

    func brushEnded() {
        if let s = live { strokes.append(s) }
        live = nil
    }

    private func erase(at n: CGPoint) {
        let radius = max(brushWidth, 0.03)
        strokes.removeAll { $0.hit(n, radius: radius) }
    }

    func undoStroke() { if !strokes.isEmpty { strokes.removeLast() } }
    func clearStrokes() { strokes.removeAll() }

    // MARK: save

    func save() async -> URL? {
        guard let base = preview, let cg = base.cgImage else { return nil }
        busy = true
        defer { busy = false }
        let size = CGSize(width: cg.width, height: cg.height)
        let strokes = self.strokes
        let texts = self.texts
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let final = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            base.draw(in: CGRect(origin: .zero, size: size))
            for s in strokes { s.draw(in: ctx.cgContext, size: size) }
            for t in texts {
                let img = TextRenderer.image(for: t, frameHeight: size.height)
                let c = ctx.cgContext
                c.saveGState()
                c.translateBy(x: t.x * size.width, y: t.y * size.height)
                c.rotate(by: CGFloat(t.rotation) * .pi / 180)
                img.draw(in: CGRect(x: -img.size.width / 2, y: -img.size.height / 2,
                                    width: img.size.width, height: img.size.height))
                c.restoreGState()
            }
        }
        let saved = await MediaLibrary.shared.addImage(final, prefix: "Edited")
        if saved != nil { Engagement.shared.onEditCompleted() }
        return saved
    }
}
