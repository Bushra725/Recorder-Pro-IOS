import SwiftUI

/// Port of Android's PhotoEditActivity: crop & rotate, filters, text, brush,
/// stickers. Also hosts the iOS "Brush" tool (Android draws over other apps;
/// iOS cannot, so the brush annotates a screenshot / photo instead — same
/// tool set as Android's `PhotoBrushBar`).
struct PhotoEditorView: View {
    @StateObject private var m: PhotoEditorModel
    @State private var confirmLeave = false
    @State private var addingText = false
    @State private var draft = ""
    @State private var stickerPack: StickerPack = .trending
    @State private var showSaved = false
    /// Colour + size sheet, matching Android's palette toggle on PhotoBrushBar.
    @State private var showBrushPalette = false
    private let startWithBrush: Bool

    init(url: URL, startWithBrush: Bool) {
        self.startWithBrush = startWithBrush
        _m = StateObject(wrappedValue: PhotoEditorModel(url: url, startWithBrush: startWithBrush))
        // Match Android: colour/size is a toggle, but open it when Brush is the entry point.
        _showBrushPalette = State(initialValue: startWithBrush)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            canvas.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let panel = m.panel { panelView(panel).transition(.move(edge: .bottom)) }
            tools
            AdBanner(slot: .editor)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.2), value: m.panel)
        .toast($m.notice)
        .overlay { if m.busy { WorkingOverlay(message: L("please_wait")) } }
        .task { await m.load() }
        .confirmationDialog(L("leave_editor_title"), isPresented: $confirmLeave, titleVisibility: .visible) {
            Button(L("save_to_gallery")) { Task { if await m.save() != nil { close() } } }
            Button(L("discard"), role: .destructive) { close() }
            Button(L("cancel"), role: .cancel) {}
        }
        .alert(L("add_text"), isPresented: $addingText) {
            TextField(L("your_text"), text: $draft)
            Button(L("add")) {
                let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                m.addText(t.isEmpty ? L("photo_default_text") : t)
            }
            Button(L("cancel"), role: .cancel) {}
        }
        .alert(L("trim_saved_title"), isPresented: $showSaved) {
            Button(L("done"), role: .cancel) { close() }
        } message: { Text(L("ios_export_saved_body")) }
    }

    private func close() { Router.shared.closeFeature() }

    private var topBar: some View {
        HStack {
            Button { if m.hasEdits { confirmLeave = true } else { close() } } label: { Image(systemName: "xmark").font(.title3) }
            Spacer()
            Text(startWithBrush ? L("tool_brush") : L("edit_photo")).font(.headline)
            Spacer()
            Button {
                Task { if await m.save() != nil { showSaved = true } }
            } label: {
                Text(L("save")).font(.subheadline.bold())
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Brand.primary, in: Capsule())
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    // MARK: - Canvas

    private var canvas: some View {
        GeometryReader { geo in
            if let img = m.preview {
                let size = fit(img.size, in: geo.size)
                ZStack {
                    Image(uiImage: img).resizable().frame(width: size.width, height: size.height)
                    // Tap empty photo to deselect — behind overlays so drag/pinch still work.
                    Color.clear
                        .frame(width: size.width, height: size.height)
                        .contentShape(Rectangle())
                        .onTapGesture { m.selectedTextID = nil }
                    StrokeLayer(strokes: m.strokes, live: m.live)
                        .frame(width: size.width, height: size.height)
                        .allowsHitTesting(false)
                    ForEach(m.texts) { item in
                        PhotoTextItemView(m: m, item: item, frame: size)
                    }
                    .frame(width: size.width, height: size.height)
                    if m.panel == .brush {
                        Color.white.opacity(0.001)
                            .frame(width: size.width, height: size.height)
                            .gesture(DragGesture(minimumDistance: 0)
                                .onChanged { g in
                                    let n = CGPoint(x: g.location.x / size.width, y: g.location.y / size.height)
                                    if m.live == nil { m.brushBegan(at: n) } else { m.brushMoved(to: n) }
                                }
                                .onEnded { _ in m.brushEnded() })
                    }
                }
                .frame(width: size.width, height: size.height)
                // Two-finger pinch anywhere on the photo resizes the selected text/sticker
                // (same idea as Android `pinchSelectedOverlay`).
                .simultaneousGesture(selectedOverlayPinch(frame: size))
                .frame(width: geo.size.width, height: geo.size.height)
            } else {
                ProgressView().frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .padding(8)
    }

    private func selectedOverlayPinch(frame: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                guard m.panel != .brush, let id = m.selectedTextID,
                      let item = m.texts.first(where: { $0.id == id }) else { return }
                if m.pinchBaseSize == nil { m.pinchBaseSize = item.size }
                let base = m.pinchBaseSize ?? item.size
                m.updateText(id, staged: true) {
                    $0.size = min(0.55, max(0.02, base * Double(scale)))
                }
            }
            .onEnded { _ in m.pinchBaseSize = nil }
    }

    private func fit(_ s: CGSize, in box: CGSize) -> CGSize {
        guard s.width > 0, s.height > 0 else { return box }
        let k = min(box.width / s.width, box.height / s.height)
        return CGSize(width: s.width * k, height: s.height * k)
    }

    // MARK: - Tools

    private var tools: some View {
        HStack {
            ForEach(PhotoEditorModel.Panel.allCases) { p in
                Button {
                    SoundFx.tick()
                    m.panel = m.panel == p ? nil : p
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: p.icon).font(.system(size: 19))
                        Text(L(p.labelKey)).font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(m.panel == p ? Brand.accent : .white)
                }
            }
        }
        .padding(.vertical, 10)
        .background(Color(white: 0.08))
    }

    @ViewBuilder private func panelView(_ p: PhotoEditorModel.Panel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch p {
            case .crop: cropPanel
            case .filter: filterPanel
            case .text: textPanel
            case .brush: brushPanel
            case .sticker:
                StickerGrid(pack: $stickerPack) { s in m.addText(s.text, template: s.item) }
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: p == .brush && showBrushPalette ? 260 : 300)
        .background(Color(white: 0.11), in: UnevenTopCorners())
        .onChange(of: m.panel) { panel in
            if panel == .brush, startWithBrush { showBrushPalette = true }
        }
    }

    private var cropPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach([Ratio.original, Ratio(w: 1, h: 1), Ratio(w: 4, h: 5), Ratio(w: 9, h: 16),
                             Ratio(w: 16, h: 9), Ratio(w: 4, h: 3), Ratio(w: 3, h: 4)], id: \.self) { r in
                        Chip(title: r.label, selected: m.cropRatio == r) { m.setGeometry { m.cropRatio = r } }
                    }
                }
            }
            HStack {
                Chip(title: L("tool_rotate"), selected: false) { m.setGeometry { m.rotation = (m.rotation + 90) % 360 } }
                Chip(title: L("tool_flip"), selected: m.flipX) { m.setGeometry { m.flipX.toggle() } }
            }
        }
    }

    @State private var lookCategory: LookCategory = .original

    private var filterPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(LookCatalog.categories(of: LookCatalog.filters)) { c in
                        Button(L(c.labelKey)) { lookCategory = c }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(lookCategory == c ? .white : .white.opacity(0.5))
                    }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach([LookCatalog.none] + LookCatalog.looks(LookCatalog.filters, in: lookCategory)) { look in
                        Button { m.setGeometry { m.filter = look.id } } label: {
                            VStack(spacing: 4) {
                                LookThumb(image: m.thumb, look: look, strength: 1)
                                    .frame(width: 60, height: 60).clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(m.filter == look.id ? Brand.accent : .clear, lineWidth: 2))
                                Text(L(look.nameKey)).font(.caption2).lineLimit(1)
                            }
                            .frame(width: 64)
                        }
                    }
                }
            }
            if m.filter != "none" {
                Slider(value: Binding(get: { m.filterStrength }, set: { v in m.filterStrength = v }), in: 0...1) { editing in
                    if !editing { m.rebuild() }
                }
                .tint(Brand.accent)
            }
        }
    }

    @ViewBuilder private var textPanel: some View {
        if let item = m.selectedText {
            ScrollView { TextStyleEditor(vm: m, item: item) }
        } else {
            Button { draft = ""; addingText = true } label: {
                Label(L("add_text"), systemImage: "plus").font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(Brand.primary, in: RoundedRectangle(cornerRadius: 10))
            }
            Hint(key: "drag_text_hint")
        }
    }

    /// Port of Android `PhotoBrushBar`: scrollable tools, then an optional
    /// colour / size palette opened by the palette button.
    private var brushPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(BrushTool.allCases) { t in
                        brushIcon(
                            system: t.icon,
                            label: L(t.labelKey),
                            selected: m.brushTool == t,
                            danger: t == .eraser && m.brushTool == .eraser
                        ) { m.brushTool = t }
                    }
                    brushIcon(
                        system: m.brushFill ? "square.fill" : "square.dashed",
                        label: L("brush_tool_fill"),
                        selected: m.brushFill
                    ) { m.brushFill.toggle() }
                    brushIcon(
                        system: "paintpalette.fill",
                        label: L("brush_tool_color"),
                        selected: showBrushPalette
                    ) { showBrushPalette.toggle() }
                    brushIcon(
                        system: "arrow.uturn.backward",
                        label: L("undo"),
                        selected: false,
                        enabled: !m.strokes.isEmpty
                    ) { m.undoStroke() }
                    .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                        m.clearStrokes()
                    })
                }
                .padding(.vertical, 2)
            }

            if showBrushPalette {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Brand.brushSwatches, id: \.self) { c in
                            Circle().fill(Color(UIColor(argb: c))).frame(width: 28, height: 28)
                                .overlay(Circle().stroke(
                                    m.brushColor == c ? Color.white : Color.white.opacity(0.35),
                                    lineWidth: m.brushColor == c ? 3 : 1
                                ))
                                .onTapGesture { m.brushColor = c }
                        }
                    }
                }
                Text(L("brush_size")).font(.caption.weight(.semibold))
                HStack(spacing: 10) {
                    Slider(value: $m.brushWidth, in: 0.006...0.045).tint(Brand.primary)
                    Circle()
                        .fill(Color(UIColor(argb: m.brushColor)))
                        .frame(width: max(6, m.brushWidth * 500), height: max(6, m.brushWidth * 500))
                        .frame(width: 28, height: 28)
                }
            }

            Hint(key: "photo_draw_hint")
        }
    }

    private func brushIcon(
        system: String,
        label: String,
        selected: Bool,
        danger: Bool = false,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: system)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .background(
                        selected ? Brand.primary.opacity(0.22) : Color.clear,
                        in: Circle()
                    )
                    .foregroundStyle(
                        !enabled ? Color.white.opacity(0.35)
                            : danger ? Brand.record
                            : selected ? Brand.primary
                            : Color.white
                    )
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(selected ? Brand.primary : Color.white.opacity(0.7))
                    .lineLimit(1)
                    .frame(width: 56)
            }
        }
        .disabled(!enabled)
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Renders strokes with Core Graphics so preview and export share one drawing routine.
private struct StrokeLayer: View {
    let strokes: [Stroke]
    let live: Stroke?

    var body: some View {
        Canvas { context, size in
            context.withCGContext { cg in
                for s in strokes { s.draw(in: cg, size: size) }
                live?.draw(in: cg, size: size)
            }
        }
    }
}

/// Text / sticker overlay: one-finger drag to move, corner handle or pinch to enlarge.
private struct PhotoTextItemView: View {
    @ObservedObject var m: PhotoEditorModel
    let item: TextItem
    let frame: CGSize
    @State private var dragOrigin: CGPoint?
    @State private var handleBase: Double?
    @State private var handleOrigin: CGPoint?

    var body: some View {
        let image = TextRenderer.image(for: item, frameHeight: frame.height * UIScreen.main.scale)
        let selected = m.selectedTextID == item.id
        let w = max(44, image.size.width / UIScreen.main.scale)
        let h = max(44, image.size.height / UIScreen.main.scale)
        ZStack {
            Image(uiImage: image)
                .resizable()
                .frame(width: image.size.width / UIScreen.main.scale,
                       height: image.size.height / UIScreen.main.scale)
            if selected {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Brand.accent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    .frame(width: w + 8, height: h + 8)
                Button {
                    m.deleteText(item.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white, Brand.record)
                }
                .offset(x: w / 2 + 4, y: -h / 2 - 4)
                // Bottom-trailing handle: drag with one finger to enlarge / shrink.
                Circle()
                    .fill(Color.white)
                    .frame(width: 22, height: 22)
                    .overlay(Circle().stroke(Brand.primary, lineWidth: 2))
                    .overlay(Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Brand.primary))
                    .offset(x: w / 2 + 4, y: h / 2 + 4)
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            if handleBase == nil {
                                handleBase = item.size
                                handleOrigin = g.location
                                m.selectedTextID = item.id
                            }
                            guard let base = handleBase else { return }
                            let delta = (g.translation.width + g.translation.height) / max(120, min(frame.width, frame.height) * 0.35)
                            m.updateText(item.id, staged: true) {
                                $0.size = min(0.55, max(0.02, base * Double(1 + delta)))
                            }
                        }
                        .onEnded { _ in handleBase = nil; handleOrigin = nil })
            }
        }
        .frame(width: w + 24, height: h + 24)
        .contentShape(Rectangle())
        .rotationEffect(.degrees(item.rotation))
        .position(x: item.x * frame.width, y: item.y * frame.height)
        .highPriorityGesture(
            DragGesture(minimumDistance: 3)
                .onChanged { g in
                    if dragOrigin == nil {
                        dragOrigin = CGPoint(x: item.x, y: item.y)
                        m.selectedTextID = item.id
                        m.panel = item.kind == .sticker ? .sticker : .text
                    }
                    guard let origin = dragOrigin else { return }
                    m.updateText(item.id, staged: true) {
                        $0.x = min(0.95, max(0.05, origin.x + g.translation.width / frame.width))
                        $0.y = min(0.95, max(0.05, origin.y + g.translation.height / frame.height))
                    }
                }
                .onEnded { _ in dragOrigin = nil }
        )
        .onTapGesture {
            SoundFx.tick()
            m.selectedTextID = item.id
            m.panel = item.kind == .sticker ? .sticker : .text
        }
        .allowsHitTesting(m.panel != .brush)
    }
}

extension Thumbnails {
    static func shrink(_ image: UIImage, to side: CGFloat) -> UIImage {
        let k = min(1, side / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * k, height: image.size.height * k)
        return UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
}
