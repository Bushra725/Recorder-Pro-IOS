import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The panel that opens above the toolbar. Port of Android's ToolPanel /
/// LookDock / TextDock / AdjustDock and friends.
struct ToolPanelView: View {
    @ObservedObject var vm: StudioViewModel
    let tool: StudioTool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L(tool.labelKey)).font(.headline)
                Spacer()
                Button {
                    vm.panel = nil
                    vm.selectedTextID = nil
                } label: {
                    Image(systemName: "checkmark").font(.headline)
                        .frame(width: 34, height: 34)
                        .background(Color.white.opacity(0.12), in: Circle())
                }
                .accessibilityLabel(L("done"))
            }
            content
        }
        .foregroundStyle(.white)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 150, maxHeight: 330)
        .background(Color(white: 0.11), in: UnevenTopCorners())
    }

    @ViewBuilder private var content: some View {
        switch tool {
        case .speed: SpeedPanel(vm: vm)
        case .volume: VolumePanel(vm: vm)
        case .rotate: RotatePanel(vm: vm)
        case .crop: CropPanel(vm: vm)
        case .filter: LookDock(vm: vm, effects: false)
        case .effect: LookDock(vm: vm, effects: true)
        case .format: FormatPanel(vm: vm)
        case .canvas: CanvasPanel(vm: vm)
        case .adjust: AdjustPanel(vm: vm)
        case .text: TextPanel(vm: vm)
        case .sticker: StickerPanel(vm: vm)
        case .captions: CaptionsPanel(vm: vm)
        case .audio: AudioPanel(vm: vm)
        case .duration: DurationPanel(vm: vm)
        default: EmptyView()
        }
    }
}

struct UnevenTopCorners: Shape {
    func path(in rect: CGRect) -> Path {
        Path(UIBezierPath(roundedRect: rect, byRoundingCorners: [.topLeft, .topRight],
                          cornerRadii: CGSize(width: 18, height: 18)).cgPath)
    }
}

// MARK: - Shared bits

struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button { SoundFx.tick(); action() } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .foregroundStyle(selected ? .black : .white)
                .background(selected ? Color.white : Color.white.opacity(0.12), in: Capsule())
        }
    }
}

struct Hint: View {
    let key: String
    var body: some View { Text(L(key)).font(.caption).foregroundStyle(.white.opacity(0.6)) }
}

/// Slider that stages while dragging and commits one undo step on release.
struct StagedSlider: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.0f", $0) }
    let onChange: (Double) -> Void
    let onCommit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(format(value)).font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.7))
            }
            Slider(value: Binding(get: { value }, set: onChange), in: range) { editing in
                if !editing { onCommit() }
            }
            .tint(Brand.accent)
        }
    }
}

/// Two-thumb range slider (Android RangeSlider), values in ms.
struct RangeSliderView: View {
    let total: Int64
    let start: Int64
    let end: Int64
    let onChange: (Int64, Int64) -> Void
    let onCommit: () -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width - 24
            let t = Double(max(1, total))
            let x0 = CGFloat(Double(min(start, total)) / t) * w
            let x1 = CGFloat(Double(min(end, total)) / t) * w
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15)).frame(height: 4).padding(.horizontal, 12)
                Capsule().fill(Brand.accent).frame(width: max(0, x1 - x0), height: 4).offset(x: 12 + x0)
                thumb.offset(x: x0).gesture(DragGesture().onChanged { g in
                    let v = Int64(Double(max(0, min(x1 - 8, g.location.x - 12)) / Double(w)) * t)
                    onChange(min(v, end - 80), end)
                }.onEnded { _ in onCommit() })
                thumb.offset(x: x1).gesture(DragGesture().onChanged { g in
                    let v = Int64(Double(max(x0 + 8, min(w, g.location.x - 12)) / Double(w)) * t)
                    onChange(start, max(v, start + 80))
                }.onEnded { _ in onCommit() })
            }
        }
        .frame(height: 28)
    }

    private var thumb: some View {
        Circle().fill(Color.white).frame(width: 24, height: 24).shadow(radius: 2)
    }
}

/// "Entire video / From playhead / This clip" + range.
struct OverlayRangePicker: View {
    @ObservedObject var vm: StudioViewModel
    let start: Int64
    let end: Int64
    let apply: (Int64, Int64, Bool) -> Void   // start, end, staged

    var body: some View {
        let total = vm.totalMs
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Chip(title: L("overlay_entire"), selected: start == 0 && end >= total) { apply(0, .max, false) }
                Chip(title: L("overlay_playhead"), selected: false) { apply(vm.playheadMs, .max, false) }
                Chip(title: L("overlay_this_clip"), selected: false) {
                    let tl = vm.state.timeline
                    if let i = tl.clipIndex(at: vm.playheadMs) {
                        let s = tl.timelineStart(of: i)
                        apply(s, s + tl.clips[i].timelineDurationMs, false)
                    }
                }
            }
            RangeSliderView(total: total, start: max(0, min(start, total)), end: max(0, min(end, total)),
                            onChange: { a, b in apply(a, b, true) }, onCommit: { vm.commitStaged() })
            Text(L("timing_range", Int(min(start, total) / 1000), Int(min(end, total) / 1000)))
                .font(.caption2).foregroundStyle(.white.opacity(0.6))
        }
    }
}

// MARK: - Clip panels

private struct SpeedPanel: View {
    @ObservedObject var vm: StudioViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Hint(key: "speed_per_clip_hint")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach([0.25, 0.5, 1, 1.5, 2, 3, 4], id: \.self) { s in
                        Chip(title: "\(s.formatted())x", selected: vm.selectedClip?.speed == s) {
                            if vm.selectedClipID == nil {
                                vm.selectedClipID = vm.state.timeline.clipIndex(at: vm.playheadMs).map { vm.state.timeline.clips[$0].id }
                            }
                            vm.updateClip { $0.speed = s }
                        }
                    }
                }
            }
        }
    }
}

private struct VolumePanel: View {
    @ObservedObject var vm: StudioViewModel
    var body: some View {
        StagedSlider(label: L("tool_volume"), value: vm.state.volume, range: 0...2,
                     format: { L("volume_value", Int($0 * 100)) },
                     onChange: { v in var s = vm.state; s.volume = v; vm.stage(s) },
                     onCommit: { vm.commitStaged() })
    }
}

private struct RotatePanel: View {
    @ObservedObject var vm: StudioViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Hint(key: "rotate_hint")
            HStack {
                Chip(title: L("rotate_now", (vm.state.rotationDeg + 90) % 360), selected: false) {
                    var s = vm.state; s.rotationDeg = (s.rotationDeg + 90) % 360; vm.commit(s)
                }
                Chip(title: L("tool_flip"), selected: vm.state.flipX) {
                    var s = vm.state; s.flipX.toggle(); vm.commit(s)
                }
            }
        }
    }
}

private let ratios: [Ratio] = [.original, Ratio(w: 9, h: 16), Ratio(w: 16, h: 9), Ratio(w: 1, h: 1),
                               Ratio(w: 4, h: 5), Ratio(w: 4, h: 3)]

private struct CropPanel: View {
    @ObservedObject var vm: StudioViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Hint(key: "crop_hint")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(ratios, id: \.self) { r in
                        Chip(title: r.label, selected: vm.state.cropRatio == r) {
                            var s = vm.state; s.cropRatio = r; vm.commit(s)
                        }
                    }
                }
            }
            StagedSlider(label: L("tool_crop"), value: vm.state.cropInset, range: 0...0.4,
                         format: { L("crop_zoom_value", Int(100 / max(0.2, 1 - 2 * $0))) },
                         onChange: { v in var s = vm.state; s.cropInset = v; vm.stage(s) },
                         onCommit: { vm.commitStaged() })
        }
    }
}

private struct FormatPanel: View {
    @ObservedObject var vm: StudioViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Hint(key: "format_hint")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(ratios, id: \.self) { r in
                        Chip(title: r.label, selected: vm.state.ratio == r) {
                            var s = vm.state; s.ratio = r; vm.commit(s)
                        }
                    }
                }
            }
        }
    }
}

private struct CanvasPanel: View {
    @ObservedObject var vm: StudioViewModel
    private let options = ["none", "black", "white", "blur", "blur_dark", "green", "blue"]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Hint(key: "canvas_hint")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(options, id: \.self) { c in
                        Chip(title: label(c), selected: vm.state.canvas == c) {
                            var s = vm.state
                            s.canvas = c
                            // A canvas only shows when the format leaves room around the video.
                            if c != "none" && s.ratio.isOriginal {
                                s.ratio = vm.previewAspect < 1 ? Ratio(w: 1, h: 1) : Ratio(w: 9, h: 16)
                            }
                            vm.commit(s)
                        }
                    }
                }
            }
        }
    }

    private func label(_ id: String) -> String {
        switch id {
        case "black": return L("canvas_black")
        case "white": return L("canvas_white")
        case "blur": return L("canvas_blur")
        case "blur_dark": return L("canvas_blur_dark")
        case "green": return L("canvas_green")
        case "blue": return L("canvas_blue")
        default: return L("none")
        }
    }
}

private struct AdjustPanel: View {
    @ObservedObject var vm: StudioViewModel
    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                slider("adjust_brightness", \.brightness)
                slider("adjust_contrast", \.contrast)
                slider("adjust_saturation", \.saturation)
                slider("adjust_warmth", \.warmth)
            }
        }
    }

    private func slider(_ key: String, _ path: WritableKeyPath<StudioState, Double>) -> some View {
        StagedSlider(label: L(key), value: vm.state[keyPath: path], range: -1...1,
                     format: { String(format: "%+.0f", $0 * 100) },
                     onChange: { v in var s = vm.state; s[keyPath: path] = v; vm.stage(s) },
                     onCommit: { vm.commitStaged() })
    }
}

private struct DurationPanel: View {
    @ObservedObject var vm: StudioViewModel
    var body: some View {
        let tl = vm.state.timeline
        let clip = vm.selectedClip ?? tl.clipIndex(at: vm.playheadMs).map { tl.clips[$0] }
        if let clip, clip.isImage {
            StagedSlider(label: L("tool_duration"), value: Double(clip.outMs) / 1000, range: 1...10,
                         format: { String(format: "%.1f s", $0) },
                         onChange: { v in
                             var s = vm.state
                             s.timeline = s.timeline.update(clip.id) { $0.outMs = Int64(v * 1000) }
                             vm.stage(s)
                         },
                         onCommit: { vm.commitStaged() })
        } else {
            Hint(key: "ios_duration_photo_only")
        }
    }
}

// MARK: - Filters & effects

/// Category tabs, thumbnails of *this* video's frame with the look applied,
/// and an intensity slider. Clip level → the look applies to the selected clip;
/// project level → whole video or the chosen range.
struct LookDock: View {
    @ObservedObject var vm: StudioViewModel
    let effects: Bool
    @State private var category: LookCategory = .original
    @State private var frame: UIImage?

    private var looks: [Look] { effects ? LookCatalog.effects : LookCatalog.filters }
    private var clipLevel: Bool { vm.selectedClipID != nil }

    private var currentID: String {
        if let c = vm.selectedClip { return (effects ? c.effect : c.filter).isEmpty ? "none" : (effects ? c.effect : c.filter) }
        return effects ? vm.state.effect : vm.state.filter
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(LookCatalog.categories(of: looks)) { cat in
                        Button { category = cat } label: {
                            VStack(spacing: 3) {
                                Text(L(cat.labelKey)).font(.subheadline.weight(.semibold))
                                Rectangle().fill(category == cat ? Brand.accent : .clear).frame(height: 2)
                            }
                            .foregroundStyle(category == cat ? .white : .white.opacity(0.55))
                        }
                    }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    tile(LookCatalog.none)
                    ForEach(LookCatalog.looks(looks, in: category)) { tile($0) }
                }
            }
            if !clipLevel && currentID != "none" {
                StagedSlider(label: L("look_intensity"),
                             value: effects ? vm.state.effectStrength : vm.state.filterStrength, range: 0...1,
                             format: { "\(Int($0 * 100))" },
                             onChange: { v in
                                 var s = vm.state
                                 if effects { s.effectStrength = v } else { s.filterStrength = v }
                                 vm.stage(s)
                             },
                             onCommit: { vm.commitStaged() })
                OverlayRangePicker(vm: vm,
                                   start: effects ? vm.state.effectStartMs : vm.state.filterStartMs,
                                   end: effects ? vm.state.effectEndMs : vm.state.filterEndMs) { a, b, staged in
                    var s = vm.state
                    if effects { s.effectStartMs = a; s.effectEndMs = b } else { s.filterStartMs = a; s.filterEndMs = b }
                    staged ? vm.stage(s) : vm.commit(s)
                }
            }
        }
        .task(id: vm.playheadMs / 1000) {
            // Snap to the nearest second so the thumbnail cache is shared with the filmstrip.
            let tl = vm.state.timeline
            guard let i = tl.clipIndex(at: vm.playheadMs) else { return }
            let clip = tl.clips[i]
            let src = clip.isImage ? 0 : (tl.timelineToSource(vm.playheadMs) / 1000) * 1000
            frame = await Thumbnails.shared.image(for: clip.mediaURL, at: src, maxSide: 160)
        }
    }

    private func tile(_ look: Look) -> some View {
        let selected = currentID == look.id
        return Button {
            SoundFx.tick()
            if clipLevel {
                vm.updateClip { c in
                    if effects { c.effect = look.isNone ? "" : look.id } else { c.filter = look.isNone ? "" : look.id }
                }
            } else {
                var s = vm.state
                if effects { s.effect = look.id } else { s.filter = look.id }
                vm.commit(s)
            }
        } label: {
            VStack(spacing: 4) {
                LookThumb(image: frame, look: look,
                          strength: max(0.35, effects ? vm.state.effectStrength : vm.state.filterStrength))
                    .frame(width: 62, height: 62)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Brand.accent : .clear, lineWidth: 2))
                Text(L(look.nameKey)).font(.caption2).lineLimit(1)
                    .foregroundStyle(selected ? Brand.accent : .white)
                Rectangle().fill(selected ? Brand.accent : .clear).frame(width: 18, height: 2)
            }
            .frame(width: 66)
        }
    }
}

/// A frame of the user's video with the look applied (Android's rememberLookThumb).
struct LookThumb: View {
    let image: UIImage?
    let look: Look
    let strength: Double

    var body: some View {
        ZStack {
            Color.white.opacity(0.08)
            if let rendered { Image(uiImage: rendered).resizable().scaledToFill() }
            if look.isNone { Image(systemName: "nosign").foregroundStyle(.white.opacity(0.8)) }
        }
    }

    private var rendered: UIImage? {
        guard let image, let cg = image.cgImage else { return nil }
        if look.isNone { return image }
        let out = LookCatalog.matrix(for: look, strength: strength).apply(to: CIImage(cgImage: cg))
        guard let res = FramePipeline.context.createCGImage(out, from: out.extent) else { return image }
        return UIImage(cgImage: res)
    }
}

// MARK: - Text

private struct TextPanel: View {
    @ObservedObject var vm: StudioViewModel
    @State private var draft = ""
    @State private var editing = false

    private let suggestions = ["sug_subscribe", "sug_watch", "sug_tip", "sug_wait", "sug_new",
                               "sug_thanks", "sug_follow", "sug_link"]

    var body: some View {
        if let item = vm.selectedText, item.kind == .text {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    TextStyleEditor(vm: vm, item: item)
                    OverlayRangePicker(vm: vm, start: item.startMs, end: item.endMs) { a, b, staged in
                        vm.updateText(item.id, staged: staged) { $0.startMs = a; $0.endMs = b }
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    draft = ""
                    editing = true
                } label: {
                    Label(L("add_text"), systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(Brand.primary, in: RoundedRectangle(cornerRadius: 10))
                }
                if vm.mode == .ai || vm.state.texts.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(suggestions, id: \.self) { key in
                                Chip(title: L(key), selected: false) { vm.addText(L(key)) }
                            }
                        }
                    }
                }
                Hint(key: "drag_text_hint")
            }
            .alert(L("add_text"), isPresented: $editing) {
                TextField(L("your_text"), text: $draft)
                Button(L("add")) {
                    let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { vm.addText(t) }
                }
                Button(L("cancel"), role: .cancel) {}
            }
        }
    }
}

// MARK: - Stickers

private struct StickerPanel: View {
    @ObservedObject var vm: StudioViewModel
    @State private var pack: StickerPack = .trending

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let item = vm.selectedText, item.kind == .sticker {
                HStack {
                    Hint(key: "drag_sticker_hint")
                    Spacer()
                    Button(L("delete")) { vm.deleteText(item.id) }.foregroundStyle(Brand.record)
                }
            }
            StickerGrid(pack: $pack) { sticker in
                vm.addText(sticker.text, kind: .sticker, template: sticker.item)
            }
        }
    }
}

// MARK: - Captions

private struct CaptionsPanel: View {
    @ObservedObject var vm: StudioViewModel
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var store = Store.shared
    @State private var adding = false
    @State private var draft = ""

    var body: some View {
        if let item = vm.selectedText, item.kind == .caption {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    TextStyleEditor(vm: vm, item: item)
                    OverlayRangePicker(vm: vm, start: item.startMs, end: item.endMs) { a, b, staged in
                        vm.updateText(item.id, staged: staged) { $0.startMs = a; $0.endMs = b }
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("captions_subtitle")).font(.subheadline)
                Hint(key: "tool_captions_hint")
                HStack {
                    Menu {
                        ForEach(SpeechCaptioner.languages, id: \.code) { lang in
                            Button(L(lang.labelKey)) { prefs.captionsLanguage = lang.code }
                        }
                    } label: {
                        Label(L(SpeechCaptioner.languages.first { $0.code == prefs.captionsLanguage }?.labelKey ?? "captions_lang_en"),
                              systemImage: "globe")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .background(Color.white.opacity(0.12), in: Capsule())
                    }
                    Spacer()
                    Button {
                        Task { await vm.generateCaptions(language: prefs.captionsLanguage) }
                    } label: {
                        HStack(spacing: 6) {
                            Text(L("captions_generate"))
                            if !store.hasPro { ProBadge() }
                        }
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Color(hex: 0x1A1A1A))
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(Brand.generate, in: Capsule())
                    }
                }
                Button { draft = ""; adding = true } label: {
                    Label(L("captions_add"), systemImage: "plus").font(.subheadline)
                }
            }
            .alert(L("captions_add"), isPresented: $adding) {
                TextField(L("caption_hint"), text: $draft)
                Button(L("add")) {
                    let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { return }
                    let (a, b) = vm.defaultWindow(2500)
                    vm.addText(t, kind: .caption, template: SpeechCaptioner.captionItem(t, start: a, end: b))
                }
                Button(L("cancel"), role: .cancel) {}
            }
        }
    }
}

// MARK: - Audio

private struct AudioPanel: View {
    @ObservedObject var vm: StudioViewModel
    @State private var importing = false
    @State private var videoItem: PhotosPickerItem?
    @State private var musicDurationMs: Int64 = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let url = vm.state.musicURL {
                Label(url.deletingPathExtension().lastPathComponent, systemImage: "music.note")
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                StagedSlider(label: L("tool_volume"), value: vm.state.musicVolume, range: 0...1.5,
                             format: { L("volume_value", Int($0 * 100)) },
                             onChange: { v in var s = vm.state; s.musicVolume = v; vm.stage(s) },
                             onCommit: { vm.commitStaged() })
                if musicDurationMs > 0 {
                    StagedSlider(label: L("music_trim"), value: Double(vm.state.musicStartMs) / 1000,
                                 range: 0...max(1, Double(musicDurationMs) / 1000 - 1),
                                 format: { Format.duration(Int64($0 * 1000)) },
                                 onChange: { v in var s = vm.state; s.musicStartMs = Int64(v * 1000); vm.stage(s) },
                                 onCommit: { vm.commitStaged() })
                }
                HStack {
                    Chip(title: L("music_place"), selected: false) {
                        var s = vm.state; s.musicOffsetMs = vm.playheadMs; vm.commit(s)
                    }
                    Chip(title: L("music_replace"), selected: false) { importing = true }
                    Chip(title: L("remove"), selected: false) {
                        var s = vm.state; s.musicURL = nil; s.musicStartMs = 0; s.musicEndMs = 0; s.musicOffsetMs = 0
                        vm.commit(s)
                    }
                }
            } else {
                Text(L("tool_music_none")).font(.subheadline).foregroundStyle(.white.opacity(0.7))
                HStack {
                    Button { importing = true } label: {
                        Label(L("pick_music"), systemImage: "music.note.list")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(Brand.primary, in: Capsule())
                    }
                    PhotosPicker(selection: $videoItem, matching: .videos) {
                        Label(L("ios_audio_from_video"), systemImage: "film")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(Color.white.opacity(0.12), in: Capsule())
                    }
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav, .aiff]) { result in
            guard case .success(let url) = result else { return }
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            let dst = MediaLibrary.tempURL(ext: url.pathExtension.isEmpty ? "m4a" : url.pathExtension)
            try? FileManager.default.copyItem(at: url, to: dst)
            setMusic(dst)
        }
        .onChange(of: videoItem) { item in
            guard let item else { return }
            Task {
                if let movie = try? await item.loadTransferable(type: PickedMovie.self) { setMusic(movie.url) }
                videoItem = nil
            }
        }
        .task(id: vm.state.musicURL) {
            guard let url = vm.state.musicURL else { musicDurationMs = 0; return }
            musicDurationMs = await Task.detached { VideoMeta.read(url).durationMs }.value
        }
        .onAppear { AdsManager.shared.suppressAppOpenBriefly(120) }
    }

    private func setMusic(_ url: URL) {
        var s = vm.state
        s.musicURL = url
        s.musicStartMs = 0
        s.musicEndMs = 0
        s.musicOffsetMs = 0
        vm.commit(s)
        vm.notice = L("tool_music_on")
    }
}
