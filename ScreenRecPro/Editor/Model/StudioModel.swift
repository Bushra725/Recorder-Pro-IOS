import Foundation
import CoreGraphics

/// Port of Android's `edit/studio/StudioModel.kt`.
///
/// The timeline is an ordered list of clips, each pointing at a range of a
/// source file (or a still photo). Split, delete, duplicate, reorder, speed and
/// reverse are all pure functions on this list, which is what makes undo/redo
/// a stack of immutable states.

private var nextClipID: Int64 = 1
private let idLock = NSLock()
func makeClipID() -> Int64 {
    idLock.lock(); defer { idLock.unlock() }
    nextClipID += 1
    return nextClipID
}

struct Clip: Identifiable, Equatable, Codable {
    var id: Int64 = makeClipID()
    var inMs: Int64
    var outMs: Int64
    var speed: Double = 1
    var reversed: Bool = false
    var filter: String = ""
    var effect: String = ""
    /// Source file. Every clip carries its own URL so merged projects work.
    var mediaURL: URL
    var isImage: Bool = false

    var sourceDurationMs: Int64 { max(0, outMs - inMs) }
    var timelineDurationMs: Int64 {
        speed <= 0 ? sourceDurationMs : max(0, Int64((Double(sourceDurationMs) / speed).rounded()))
    }
}

struct Timeline: Equatable, Codable {
    var clips: [Clip]

    static let minClipMs: Int64 = 200

    var totalMs: Int64 { clips.reduce(0) { $0 + $1.timelineDurationMs } }

    func index(of id: Int64) -> Int? { clips.firstIndex { $0.id == id } }
    func clip(_ id: Int64) -> Clip? { clips.first { $0.id == id } }

    func timelineStart(of index: Int) -> Int64 {
        clips.prefix(max(0, min(index, clips.count))).reduce(0) { $0 + $1.timelineDurationMs }
    }

    func clipIndex(at ms: Int64) -> Int? {
        guard !clips.isEmpty else { return nil }
        var acc: Int64 = 0
        for (i, c) in clips.enumerated() {
            acc += c.timelineDurationMs
            if ms < acc { return i }
        }
        return clips.count - 1
    }

    /// Timeline position -> position inside that clip's source file.
    func timelineToSource(_ ms: Int64) -> Int64 {
        guard let i = clipIndex(at: ms) else { return 0 }
        let c = clips[i]
        let into = max(0, ms - timelineStart(of: i))
        let src = Int64(Double(into) * c.speed)
        return c.reversed ? c.outMs - src : c.inMs + src
    }

    /// Source position of `url` -> every timeline position showing it (used by captions).
    func sourceToTimeline(_ srcMs: Int64, url: URL) -> Int64? {
        for (i, c) in clips.enumerated() where c.mediaURL == url && !c.isImage {
            guard srcMs >= c.inMs, srcMs <= c.outMs else { continue }
            let into = c.reversed ? c.outMs - srcMs : srcMs - c.inMs
            return timelineStart(of: i) + Int64(Double(into) / max(0.01, c.speed))
        }
        return nil
    }

    // MARK: mutations

    func split(at ms: Int64) -> Timeline {
        guard let i = clipIndex(at: ms) else { return self }
        let c = clips[i]
        let into = max(0, ms - timelineStart(of: i))
        let delta = Int64(Double(into) * c.speed)
        var cut = c.reversed ? c.outMs - delta : c.inMs + delta
        // Playhead on an edge (usually 00:00): split at the middle instead of failing.
        if cut - c.inMs < Self.minClipMs || c.outMs - cut < Self.minClipMs {
            cut = c.inMs + c.sourceDurationMs / 2
        }
        guard cut - c.inMs >= Self.minClipMs, c.outMs - cut >= Self.minClipMs else { return self }
        var left = c, right = c
        right.id = makeClipID()
        if c.reversed {
            left.inMs = cut; right.outMs = cut
        } else {
            left.outMs = cut; right.inMs = cut
        }
        var out = clips
        out[i] = left
        out.insert(right, at: i + 1)
        return Timeline(clips: out)
    }

    func remove(_ id: Int64) -> Timeline {
        guard clips.count > 1 else { return self }
        return Timeline(clips: clips.filter { $0.id != id })
    }

    func duplicate(_ id: Int64) -> (Timeline, Int64)? {
        guard let i = index(of: id) else { return nil }
        var copy = clips[i]
        copy.id = makeClipID()
        var out = clips
        out.insert(copy, at: i + 1)
        return (Timeline(clips: out), copy.id)
    }

    func update(_ id: Int64, _ transform: (inout Clip) -> Void) -> Timeline {
        guard let i = index(of: id) else { return self }
        var out = clips
        transform(&out[i])
        return Timeline(clips: out)
    }

    func move(_ id: Int64, by delta: Int) -> Timeline {
        guard let i = index(of: id) else { return self }
        let j = max(0, min(clips.count - 1, i + delta))
        guard i != j else { return self }
        var out = clips
        let c = out.remove(at: i)
        out.insert(c, at: j)
        return Timeline(clips: out)
    }

    func appending(_ clip: Clip) -> Timeline { Timeline(clips: clips + [clip]) }
}

/// A text, sticker or caption placed on the video. Port of Android's
/// `OverlayFactory.TextItem` with the full style set of `TextStyleSheet`.
struct TextItem: Identifiable, Equatable, Codable, Hashable {
    enum Kind: String, Codable { case text, sticker, caption }
    enum Align: Int, Codable { case left, center, right }

    var id: Int64 = makeClipID()
    var text: String
    var kind: Kind = .text
    /// Centre position as a fraction of the output frame, (0,0) top-left.
    var x: Double = 0.5
    var y: Double = 0.5
    /// Font size as a fraction of the output frame height.
    var size: Double = 0.06
    var rotation: Double = 0
    var colorARGB: UInt32 = 0xFFFFFFFF
    var fontID: String = "sans"
    var bold: Bool = true
    var opacity: Double = 1
    var outline: Bool = true
    var outlineARGB: UInt32 = 0xBE000000
    var outlineWidth: Double = 0.14
    var bgARGB: UInt32 = 0
    var bgOpacity: Double = 1
    var bgPad: Double = 0.28
    var shadow: Bool = false
    var shadowARGB: UInt32 = 0xB4000000
    var shadowBlur: Double = 6
    var shadowDX: Double = 4
    var shadowDY: Double = 5
    var letterSpacing: Double = 0
    var lineSpacing: Double = 0
    var align: Align = .center
    var startMs: Int64 = 0
    var endMs: Int64 = .max

    func visible(at ms: Int64) -> Bool { ms >= startMs && ms < endMs }

    /// Everything that changes how the item *looks* (not where or when).
    var styleKey: String {
        "\(text)|\(kind)|\(colorARGB)|\(fontID)|\(bold)|\(outline)|\(outlineARGB)|\(outlineWidth)|\(bgARGB)|\(bgOpacity)|\(bgPad)|\(shadow)|\(shadowARGB)|\(shadowBlur)|\(shadowDX)|\(shadowDY)|\(letterSpacing)|\(lineSpacing)|\(align.rawValue)"
    }
}

struct Ratio: Equatable, Codable, Hashable {
    var w: Int
    var h: Int
    static let original = Ratio(w: 0, h: 0)
    var isOriginal: Bool { w <= 0 || h <= 0 }
    var value: Double { isOriginal ? 0 : Double(w) / Double(h) }
    var label: String { isOriginal ? L("ratio_original") : "\(w):\(h)" }
}

/// The whole editor state. One immutable value per undo step.
struct StudioState: Equatable, Codable {
    var timeline: Timeline
    var volume: Double = 1
    var rotationDeg: Int = 0
    var flipX: Bool = false
    /// Zoom crop: fraction trimmed from every edge (0 … 0.4).
    var cropInset: Double = 0
    var cropRatio: Ratio = .original
    /// Output canvas ("Format").
    var ratio: Ratio = .original
    var canvas: String = "none"
    var filter: String = "none"
    var filterStartMs: Int64 = 0
    var filterEndMs: Int64 = .max
    var filterStrength: Double = 1
    var effect: String = "none"
    var effectStartMs: Int64 = 0
    var effectEndMs: Int64 = .max
    var effectStrength: Double = 1
    var brightness: Double = 0
    var contrast: Double = 0
    var saturation: Double = 0
    var warmth: Double = 0
    var texts: [TextItem] = []
    var musicURL: URL?
    var musicStartMs: Int64 = 0
    var musicEndMs: Int64 = 0
    var musicOffsetMs: Int64 = 0
    var musicVolume: Double = 0.8
    /// Region crop from Region Recording, normalised to the source frame.
    var regionCrop: CGRect?
    var watermark: Bool = false

    init(timeline: Timeline) { self.timeline = timeline }

    static func single(url: URL, durationMs: Int64) -> StudioState {
        StudioState(timeline: Timeline(clips: [Clip(inMs: 0, outMs: max(Timeline.minClipMs, durationMs), mediaURL: url)]))
    }

    func isDirty(originalDurationMs: Int64) -> Bool {
        let c = timeline.clips
        let untouched = c.count == 1 && c[0].inMs <= 0 && c[0].outMs >= originalDurationMs - 10 &&
            c[0].speed == 1 && !c[0].reversed && !c[0].isImage && c[0].filter.isEmpty && c[0].effect.isEmpty
        return !untouched || volume != 1 || rotationDeg != 0 || flipX || cropInset > 0 ||
            !cropRatio.isOriginal || !ratio.isOriginal || filter != "none" || canvas != "none" ||
            effect != "none" || brightness != 0 || contrast != 0 || saturation != 0 || warmth != 0 ||
            !texts.isEmpty || musicURL != nil
    }
}

/// Bounded undo/redo. Continuous gestures `stage` changes and `commit` once on
/// release, so one slider drag is one Undo, not sixty.
struct HistoryStack {
    private(set) var current: StudioState
    private var past: [StudioState] = []
    private var future: [StudioState] = []
    private var stagedFrom: StudioState?
    private static let limit = 40

    init(_ initial: StudioState) { current = initial }

    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    mutating func push(_ next: StudioState) {
        guard next != current else { return }
        stagedFrom = nil
        past.append(current)
        if past.count > Self.limit { past.removeFirst() }
        future.removeAll()
        current = next
    }

    mutating func stage(_ next: StudioState) {
        if stagedFrom == nil { stagedFrom = current }
        current = next
    }

    mutating func commitStaged() {
        guard let from = stagedFrom else { return }
        stagedFrom = nil
        guard from != current else { return }
        past.append(from)
        if past.count > Self.limit { past.removeFirst() }
        future.removeAll()
    }

    mutating func undo() {
        stagedFrom = nil
        guard let prev = past.popLast() else { return }
        future.append(current)
        current = prev
    }

    mutating func redo() {
        stagedFrom = nil
        guard let next = future.popLast() else { return }
        past.append(current)
        current = next
    }
}
