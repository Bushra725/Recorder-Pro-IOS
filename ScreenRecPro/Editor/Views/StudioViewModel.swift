import AVFoundation
import CryptoKit
import SwiftUI

/// Tools, same set and grouping as Android's StudioToolbar.
enum StudioTool: String, Identifiable, CaseIterable {
    // project level
    case edit, audio, text, sticker, effect, filter, format, canvas, adjust, captions, watermark
    // clip level
    case split, speed, volume, delete, duplicate, rotate, crop, reverse
    // merge
    case duration

    var id: String { rawValue }

    static let projectTools: [StudioTool] = [.edit, .split, .audio, .text, .sticker, .captions, .effect, .filter,
                                             .format, .canvas, .adjust, .watermark]
    static let clipTools: [StudioTool] = [.split, .speed, .volume, .duplicate, .reverse, .rotate, .crop,
                                          .filter, .effect, .delete]
    static let mergeTools: [StudioTool] = [.duration, .crop, .volume, .text, .audio, .captions]

    var icon: String {
        switch self {
        case .edit: return "scissors"
        case .audio: return "music.note"
        case .text: return "textformat"
        case .sticker: return "face.smiling"
        case .effect: return "sparkles"
        case .filter: return "camera.filters"
        case .format: return "aspectratio"
        case .canvas: return "square.dashed"
        case .adjust: return "slider.horizontal.3"
        case .captions: return "captions.bubble"
        case .watermark: return "drop"
        case .split: return "square.split.2x1"
        case .speed: return "speedometer"
        case .volume: return "speaker.wave.2"
        case .delete: return "trash"
        case .duplicate: return "plus.square.on.square"
        case .rotate: return "rotate.right"
        case .crop: return "crop"
        case .reverse: return "backward"
        case .duration: return "clock"
        }
    }

    var labelKey: String {
        switch self {
        case .edit: return "tool_edit"
        case .audio: return "tool_audio"
        case .text: return "tool_text"
        case .sticker: return "tool_stickers"
        case .effect: return "tool_effects"
        case .filter: return "tool_filter"
        case .format: return "tool_format"
        case .canvas: return "tool_canvas"
        case .adjust: return "tool_adjust"
        case .captions: return "auto_captions"
        case .watermark: return "tool_watermark"
        case .split: return "tool_split"
        case .speed: return "tool_speed"
        case .volume: return "tool_volume"
        case .delete: return "delete"
        case .duplicate: return "tool_duplicate"
        case .rotate: return "tool_rotate"
        case .crop: return "tool_crop"
        case .reverse: return "tool_reverse"
        case .duration: return "tool_duration"
        }
    }

    /// Tools that act immediately instead of opening a panel.
    var isImmediate: Bool { [.split, .delete, .duplicate, .reverse, .edit, .watermark].contains(self) }
}

@MainActor
final class StudioViewModel: ObservableObject {
    let mode: StudioMode
    let primaryURL: URL

    @Published private(set) var history: HistoryStack
    @Published var playheadMs: Int64 = 0
    @Published var isPlaying = false
    @Published var selectedClipID: Int64?
    @Published var panel: StudioTool?
    @Published var selectedTextID: Int64?
    @Published var busyMessage: String?
    @Published var progress: Double?
    @Published var notice: String?
    @Published var loaded = false
    @Published var exportedURL: URL?
    @Published var previewAspect: CGFloat = 9.0 / 16.0
    @Published var exportShortEdge: CGFloat = 1080

    let player = AVPlayer()
    private var project: BuiltProject?
    private var structuralKey = ""
    private var timeObserver: Any?
    private var rebuildTask: Task<Void, Never>?
    private(set) var originalDurationMs: Int64 = 0
    var scrubbing = false

    var state: StudioState { history.current }
    var totalMs: Int64 { state.timeline.totalMs }
    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    var toolLevelClip: Bool { selectedClipID != nil }

    var tools: [StudioTool] {
        if mode == .merge && selectedClipID == nil { return StudioTool.mergeTools }
        return selectedClipID != nil ? StudioTool.clipTools : StudioTool.projectTools
    }

    var selectedClip: Clip? { selectedClipID.flatMap { state.timeline.clip($0) } }

    init(urls: [URL], mode: StudioMode) {
        self.mode = mode
        self.primaryURL = urls.first ?? URL(fileURLWithPath: "/dev/null")
        // Placeholder until durations are read in `load()`.
        history = HistoryStack(StudioState(timeline: Timeline(clips: urls.map {
            Clip(inMs: 0, outMs: 3000, mediaURL: $0, isImage: MediaLibrary.kindOf($0) != .video)
        })))
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playback)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            Task { @MainActor in
                guard let self, !self.scrubbing else { return }
                self.playheadMs = Int64(t.seconds * 1000)
                if self.isPlaying && self.playheadMs >= self.totalMs - 30 {
                    self.isPlaying = false
                }
            }
        }
    }

    func teardown() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        rebuildTask?.cancel()
    }

    // MARK: - Load

    func load() async {
        var clips: [Clip] = []
        for c in state.timeline.clips {
            var clip = c
            if c.isImage {
                clip.inMs = 0; clip.outMs = 3000
            } else {
                let meta = await Task.detached { VideoMeta.read(c.mediaURL) }.value
                clip.outMs = max(Timeline.minClipMs, meta.durationMs)
                if clips.isEmpty, meta.size.width > 0 { previewAspect = meta.size.width / meta.size.height }
            }
            clips.append(clip)
        }
        originalDurationMs = clips.first?.outMs ?? 0
        var initial = StudioState(timeline: Timeline(clips: clips))
        if let draft = loadDraft() {
            initial = draft
            notice = L("ios_draft_restored")
        }
        history = HistoryStack(initial)
        if clips.first?.isImage == true, let img = UIImage(contentsOfFile: primaryURL.path), img.size.height > 0 {
            previewAspect = img.size.width / img.size.height
        }
        switch mode {
        case .ai: panel = .text
        case .captions: panel = .captions
        default: break
        }
        await rebuild(force: true)
        loaded = true
    }

    // MARK: - State changes

    func commit(_ next: StudioState) {
        history.push(next)
        objectWillChange.send()
        stateChanged()
    }

    /// Continuous gestures: preview the change, push one undo step on release.
    func stage(_ next: StudioState) {
        history.stage(next)
        objectWillChange.send()
        stateChanged()
    }

    func commitStaged() {
        history.commitStaged()
        objectWillChange.send()
    }

    func undo() { history.undo(); objectWillChange.send(); validateSelection(); stateChanged() }
    func redo() { history.redo(); objectWillChange.send(); validateSelection(); stateChanged() }

    private func validateSelection() {
        if let id = selectedClipID, state.timeline.clip(id) == nil { selectedClipID = nil }
        if let id = selectedTextID, !state.texts.contains(where: { $0.id == id }) { selectedTextID = nil }
    }

    private func stateChanged() {
        let key = Self.structuralKey(state)
        if key != structuralKey {
            rebuildTask?.cancel()
            rebuildTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled else { return }
                await self?.rebuild(force: false)
            }
        } else {
            refreshLook()
        }
    }

    /// Anything that changes the composition itself (not just colours / overlays).
    private static func structuralKey(_ s: StudioState) -> String {
        let clips = s.timeline.clips.map {
            "\($0.id):\($0.inMs)-\($0.outMs)x\($0.speed)r\($0.reversed)f\($0.filter)e\($0.effect)"
        }.joined(separator: ",")
        return "\(clips)|\(s.volume)|\(s.rotationDeg)|\(s.flipX)|\(s.cropInset)|\(s.cropRatio.w):\(s.cropRatio.h)|" +
            "\(s.ratio.w):\(s.ratio.h)|\(s.canvas)|\(s.musicURL?.path ?? "")|\(s.musicStartMs)|\(s.musicEndMs)|" +
            "\(s.musicOffsetMs)|\(s.musicVolume)"
    }

    private func rebuild(force: Bool) async {
        let key = Self.structuralKey(state)
        guard force || key != structuralKey else { return }
        let needsReverse = state.timeline.clips.contains { $0.reversed && !ReverseEngine.isCached($0) }
        if needsReverse { busyMessage = L("please_wait") }
        do {
            let built = try await ProjectBuilder.build(state, maxShortEdge: 720, includeOverlays: false,
                                                       watermarkLabel: nil)
            busyMessage = nil
            structuralKey = key
            project = built
            previewAspect = built.renderSize.width / max(1, built.renderSize.height)
            let item = AVPlayerItem(asset: built.composition)
            item.videoComposition = built.videoComposition
            item.audioMix = built.audioMix
            item.audioTimePitchAlgorithm = .spectral
            let resumeAt = min(playheadMs, max(0, totalMs - 40))
            player.replaceCurrentItem(with: item)
            await player.seek(to: ProjectBuilder.ms(resumeAt), toleranceBefore: .zero, toleranceAfter: .zero)
            if isPlaying { player.play() }
        } catch {
            busyMessage = nil
            notice = error.localizedDescription
        }
    }

    /// Colour-only change: swap the spec under the running compositor.
    private func refreshLook() {
        guard let project else { return }
        project.specBox.spec = RenderSpec(state: state, renderSize: project.renderSize,
                                          includeOverlays: false, watermarkLabel: nil)
        if !isPlaying, let item = player.currentItem {
            // Re-request the current frame through the compositor.
            item.videoComposition = project.videoComposition.mutableCopy() as? AVVideoComposition
        }
    }

    // MARK: - Transport

    func togglePlay() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if playheadMs >= totalMs - 60 { seek(to: 0) }
            player.play()
            isPlaying = true
        }
    }

    func seek(to ms: Int64) {
        let clamped = max(0, min(totalMs, ms))
        playheadMs = clamped
        player.seek(to: ProjectBuilder.ms(clamped), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func beginScrub() {
        scrubbing = true
        if isPlaying { player.pause(); isPlaying = false }
    }

    func endScrub() { scrubbing = false }

    // MARK: - Tools

    func tap(_ tool: StudioTool) {
        SoundFx.tick()
        switch tool {
        case .edit:
            selectedClipID = state.timeline.clipIndex(at: playheadMs).map { state.timeline.clips[$0].id }
            panel = nil
        case .split:
            let next = state.timeline.split(at: playheadMs)
            if next == state.timeline { notice = L("split_too_close") }
            else { var s = state; s.timeline = next; commit(s) }
        case .delete:
            guard let id = selectedClipID else { return }
            if state.timeline.clips.count <= 1 { notice = L("cannot_delete_last"); return }
            var s = state; s.timeline = s.timeline.remove(id); commit(s)
            selectedClipID = nil
        case .duplicate:
            guard let id = selectedClipID, let result = state.timeline.duplicate(id) else { return }
            var s = state; s.timeline = result.0; commit(s)
            selectedClipID = result.1
            notice = L("clip_copied")
        case .reverse:
            Task { await reverseSelected() }
        case .watermark:
            if Store.shared.hasPro {
                Prefs.shared.watermark = false
                notice = L("watermark_removed_future")
            } else {
                Router.shared.paywall = .watermark
            }
        default:
            panel = panel == tool ? nil : tool
        }
    }

    private func reverseSelected() async {
        guard let id = selectedClipID ?? state.timeline.clipIndex(at: playheadMs).map({ state.timeline.clips[$0].id }),
              let clip = state.timeline.clip(id), !clip.isImage else { return }
        if !clip.reversed && !ReverseEngine.isCached(clip) {
            busyMessage = L("please_wait")
            progress = 0
            do {
                _ = try await ReverseEngine.reversed(clip) { p in
                    Task { @MainActor in self.progress = p }
                }
            } catch {
                busyMessage = nil; progress = nil
                notice = L("reverse_failed")
                return
            }
            busyMessage = nil; progress = nil
        }
        var s = state
        s.timeline = s.timeline.update(id) { $0.reversed.toggle() }
        commit(s)
        notice = clip.reversed ? L("clip_unreversed") : L("clip_reversed")
    }

    func updateClip(_ transform: (inout Clip) -> Void, staged: Bool = false) {
        guard let id = selectedClipID else { return }
        var s = state
        s.timeline = s.timeline.update(id, transform)
        staged ? stage(s) : commit(s)
    }

    // MARK: - Overlays

    /// Visible window for a new overlay: 3 s from the playhead (Android's defaultOverlayWindow).
    func defaultWindow(_ length: Int64 = 3000) -> (Int64, Int64) {
        let total = max(80, totalMs)
        let start = max(0, min(total, playheadMs))
        let end = min(total, start + length)
        return end - start >= 80 ? (start, end) : (max(0, end - length), max(end, 80))
    }

    func addText(_ text: String, kind: TextItem.Kind = .text, template: TextItem? = nil) {
        var item = template ?? TextItem(text: text)
        item.id = makeClipID()
        item.text = text
        item.kind = kind
        let (a, b) = defaultWindow()
        item.startMs = a
        item.endMs = b
        if kind == .sticker && template == nil { item.size = 0.1; item.outline = false }
        var s = state
        s.texts.append(item)
        commit(s)
        selectedTextID = item.id
    }

    func updateText(_ id: Int64, staged: Bool = false, _ transform: (inout TextItem) -> Void) {
        guard let i = state.texts.firstIndex(where: { $0.id == id }) else { return }
        var s = state
        transform(&s.texts[i])
        staged ? stage(s) : commit(s)
    }

    func deleteText(_ id: Int64) {
        var s = state
        s.texts.removeAll { $0.id == id }
        commit(s)
        selectedTextID = nil
    }

    var selectedText: TextItem? { selectedTextID.flatMap { id in state.texts.first { $0.id == id } } }

    // MARK: - Captions

    func generateCaptions(language: String) async {
        guard Store.shared.hasPro else { Router.shared.paywall = .aiEdit; return }
        busyMessage = L("captions_listening")
        progress = nil
        defer { busyMessage = nil }
        do {
            let lines = try await SpeechCaptioner.captions(for: state.timeline, language: language)
            if lines.isEmpty { notice = L("captions_no_speech"); return }
            var s = state
            s.texts.removeAll { $0.kind == .caption }
            s.texts += lines
            commit(s)
            notice = L("captions_added", lines.count)
        } catch let e as SpeechCaptioner.Failure {
            notice = e.localizedDescription
        } catch {
            notice = L("captions_model_failed")
        }
    }

    // MARK: - Export

    var exportLabel: String { "\(Int(exportShortEdge))P" }

    func export() async {
        player.pause(); isPlaying = false
        busyMessage = L("exporting")
        progress = 0
        do {
            let out = try await Exporter.export(state, shortEdge: exportShortEdge, watermarkLabel: nil) { p in
                Task { @MainActor in self.progress = p }
            }
            let saved = await MediaLibrary.shared.addVideo(from: out, move: true, prefix: "Edited")
            busyMessage = nil; progress = nil
            exportedURL = saved
            Engagement.shared.onEditCompleted()
            if state.texts.contains(where: { $0.kind != .caption }) || mode == .ai {
                Engagement.shared.onAiEditCompleted()
            }
            deleteDraft()
        } catch {
            busyMessage = nil; progress = nil
            notice = L("export_failed")
        }
    }

    var isDirty: Bool { state.isDirty(originalDurationMs: originalDurationMs) }

    // MARK: - Drafts

    private var draftURL: URL {
        let key = mode == .merge ? state.timeline.clips.map(\.mediaURL.path).joined() : primaryURL.path
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(20)
        return MediaLibrary.draftsDir.appendingPathComponent("draft_\(hash).json")
    }

    func saveDraft() {
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: draftURL) }
    }

    private func loadDraft() -> StudioState? {
        guard mode == .edit, let data = try? Data(contentsOf: draftURL),
              let s = try? JSONDecoder().decode(StudioState.self, from: data),
              s.timeline.clips.allSatisfy({ FileManager.default.fileExists(atPath: $0.mediaURL.path) })
        else { return nil }
        return s
    }

    func deleteDraft() { try? FileManager.default.removeItem(at: draftURL) }
}
