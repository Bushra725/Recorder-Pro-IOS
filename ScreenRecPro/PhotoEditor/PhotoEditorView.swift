import SwiftUI

/// Port of Android's PhotoEditActivity: crop & rotate, filters, text, brush,
/// stickers. Also hosts the iOS "Brush" tool (Android draws over other apps;
/// iOS cannot, so the brush annotates a screenshot instead).
struct PhotoEditorView: View {
    @StateObject private var m: PhotoEditorModel
    @State private var confirmLeave = false
    @State private var addingText = false
    @State private var draft = ""
    @State private var stickerPack: StickerPack = .trending
    @State private var showSaved = false
    @State private var showPalette = false

    init(url: URL, startWithBrush: Bool) {
        _m = StateObject(wrappedValue: PhotoEditorModel(url: url, startWithBrush: startWithBrush))
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
            Text(L("edit_photo")).font(.headline)
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
                .frame(width: geo.size.width, height: geo.size.height)
            } else {
                ProgressView().frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .padding(8)
        .contentShape(Rectangle())
        .onTapGesture { m.selectedTextID = nil }
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
        .frame(maxHeight: 300)
        .background(Color(white: 0.11), in: UnevenTopCorners())
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

    private var brushPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(BrushTool.allCases) { t in
                    Button { m.brushTool = t } label: {
                        Image(systemName: t.icon)
                            .frame(width: 40, height: 36)
                            .background(m.brushTool == t ? Color.orange.opacity(0.25) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(m.brushTool == t ? .orange : .white)
                    }
                    .accessibilityLabel(L(t.labelKey))
                }
                Button { m.brushFill.toggle() } label: {
                    Image(systemName: m.brushFill ? "square.fill" : "square")
                        .frame(width: 40, height: 36)
                        .foregroundStyle(m.brushFill ? .orange : .white)
                }
                .accessibilityLabel(L("brush_tool_fill"))
                Spacer()
                Button { m.undoStroke() } label: { Image(systemName: "arrow.uturn.backward") }
                    .simultaneousGesture(LongPressGesture().onEnded { _ in m.clearStrokes() })
                    .accessibilityLabel(L("undo"))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Brand.brushSwatches, id: \.self) { c in
                        Circle().fill(Color(UIColor(argb: c))).frame(width: 30, height: 30)
                            .overlay(Circle().stroke(m.brushColor == c ? Brand.accent : .white.opacity(0.3),
                                                     lineWidth: m.brushColor == c ? 3 : 1))
                            .onTapGesture { m.brushColor = c }
                    }
                }
            }
            HStack {
                Text(L("brush_size")).font(.caption)
                Slider(value: $m.brushWidth, in: 0.004...0.05).tint(Brand.accent)
                Circle().fill(Color(UIColor(argb: m.brushColor)))
                    .frame(width: max(4, m.brushWidth * 400), height: max(4, m.brushWidth * 400))
                    .frame(width: 24, height: 24)
            }
            Hint(key: "photo_draw_hint")
        }
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

private struct PhotoTextItemView: View {
    @ObservedObject var m: PhotoEditorModel
    let item: TextItem
    let frame: CGSize
    @State private var start: CGPoint?
    @State private var scaleStart: Double?

    var body: some View {
        let image = TextRenderer.image(for: item, frameHeight: frame.height * UIScreen.main.scale)
        let selected = m.selectedTextID == item.id
        Image(uiImage: image)
            .resizable()
            .frame(width: image.size.width / UIScreen.main.scale, height: image.size.height / UIScreen.main.scale)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? Brand.accent : .clear, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])))
            .rotationEffect(.degrees(item.rotation))
            .position(x: item.x * frame.width, y: item.y * frame.height)
            .gesture(DragGesture()
                .onChanged { g in
                    if start == nil { start = CGPoint(x: item.x, y: item.y); m.selectedTextID = item.id }
                    guard let s = start else { return }
                    m.updateText(item.id, staged: true) {
                        $0.x = min(1, max(0, s.x + g.translation.width / frame.width))
                        $0.y = min(1, max(0, s.y + g.translation.height / frame.height))
                    }
                }
                .onEnded { _ in start = nil }
                .simultaneously(with: MagnificationGesture()
                    .onChanged { v in
                        if scaleStart == nil { scaleStart = item.size }
                        m.updateText(item.id, staged: true) { $0.size = min(0.4, max(0.015, (scaleStart ?? 0.06) * Double(v))) }
                    }
                    .onEnded { _ in scaleStart = nil }))
            .onTapGesture {
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
