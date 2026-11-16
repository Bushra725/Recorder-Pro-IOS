import AVFoundation
import AVKit
import SwiftUI

/// The CapCut-style studio. Port of Android's VideoEditorActivity (and of
/// AiEditActivity / CaptionActivity / merge, which open it on another panel).
///
///   ┌ ✕          1080P ▾         Export ┐
///   │            preview               │  tap to play/pause, drag text here
///   │ ▶ 00:04.2 / 00:15.0        ↶   ↷ │
///   │ ruler · filmstrip · audio · text │  fixed playhead, film scrolls under it
///   │ tool panel (when open)           │
///   └ two-level toolbar ───────────────┘
struct StudioView: View {
    @StateObject private var vm: StudioViewModel
    @State private var confirmLeave = false
    @State private var showSaved = false
    @State private var playExported: URL?

    init(urls: [URL], mode: StudioMode) {
        _vm = StateObject(wrappedValue: StudioViewModel(urls: urls, mode: mode))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if vm.mode == .merge && !Store.shared.hasPro { AdBanner(slot: .editor) }
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            transport
            if vm.panel == nil {
                StudioTimeline(vm: vm)
                    .frame(height: 170)
            }
            if let panel = vm.panel {
                ToolPanelView(vm: vm, tool: panel)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            toolStrip
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.2), value: vm.panel)
        .toast($vm.notice)
        .overlay {
            if let msg = vm.busyMessage { WorkingOverlay(message: msg, progress: vm.progress) }
        }
        .task { await vm.load() }
        .onDisappear { vm.teardown() }
        .confirmationDialog(L("leave_editor_title"), isPresented: $confirmLeave, titleVisibility: .visible) {
            Button(L("save_to_gallery")) { Task { await vm.export(); if vm.exportedURL != nil { showSaved = true } } }
            Button(L("save_as_draft")) { vm.saveDraft(); vm.notice = L("draft_saved"); close() }
            Button(L("discard"), role: .destructive) { vm.deleteDraft(); close() }
            Button(L("cancel"), role: .cancel) {}
        } message: { Text(L("leave_editor_body")) }
        .alert(L("trim_saved_title"), isPresented: $showSaved) {
            Button(L("play")) { playExported = vm.exportedURL }
            Button(L("done"), role: .cancel) { close() }
        } message: { Text(L("ios_export_saved_body")) }
        .fullScreenCover(item: Binding(get: { playExported.map(IdentifiedURL.init) },
                                       set: { playExported = $0?.url })) { item in
            InlinePlayer(url: item.url) { playExported = nil; close() }
        }
    }

    private func close() {
        vm.teardown()
        Router.shared.closeFeature()
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button {
                if vm.isDirty { confirmLeave = true } else { close() }
            } label: { Image(systemName: "xmark").font(.title3) }
            Spacer()
            Menu {
                Button("720P") { vm.exportShortEdge = 720 }
                Button("1080P") { vm.exportShortEdge = 1080 }
                Button(Store.shared.isPurchased ? "2K (1440P)" : "2K (1440P) — PRO") {
                    if Store.shared.isPurchased { vm.exportShortEdge = 1440 } else { Router.shared.paywall = .quality }
                }
            } label: {
                HStack(spacing: 4) { Text(vm.exportLabel); Image(systemName: "chevron.down").font(.caption) }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.white.opacity(0.12), in: Capsule())
            }
            Spacer()
            Button {
                Task {
                    await vm.export()
                    if vm.exportedURL != nil { showSaved = true }
                }
            } label: {
                Label(L("export"), systemImage: "square.and.arrow.up")
                    .font(.subheadline.weight(.bold))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Brand.primary, in: Capsule())
            }
            .disabled(!vm.loaded)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Preview

    private var preview: some View {
        GeometryReader { geo in
            let size = fitted(aspect: vm.previewAspect, in: geo.size)
            ZStack {
                PlayerLayerView(player: vm.player)
                    .frame(width: size.width, height: size.height)
                    .onTapGesture {
                        vm.selectedTextID = nil
                        vm.togglePlay()
                    }
                OverlayEditorLayer(vm: vm, frameSize: size)
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .simultaneousGesture(studioOverlayPinch(frame: size))
                if !vm.isPlaying && vm.loaded && vm.selectedTextID == nil {
                    Image(systemName: "play.fill").font(.system(size: 40)).foregroundStyle(.white.opacity(0.75))
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .padding(.vertical, 6)
    }

    private func studioOverlayPinch(frame: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                guard let id = vm.selectedTextID, let item = vm.state.texts.first(where: { $0.id == id }) else { return }
                if vm.pinchBaseSize == nil { vm.pinchBaseSize = item.size }
                let base = vm.pinchBaseSize ?? item.size
                vm.updateText(id, staged: true) {
                    $0.size = min(0.55, max(0.02, base * Double(scale)))
                }
            }
            .onEnded { _ in
                vm.pinchBaseSize = nil
                vm.commitStaged()
            }
    }

    private func fitted(aspect: CGFloat, in box: CGSize) -> CGSize {
        guard aspect > 0, box.width > 0, box.height > 0 else { return box }
        return box.width / box.height > aspect
            ? CGSize(width: box.height * aspect, height: box.height)
            : CGSize(width: box.width, height: box.width / aspect)
    }

    // MARK: - Transport

    private var transport: some View {
        HStack(spacing: 16) {
            Button { vm.togglePlay() } label: {
                Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill").font(.title3)
            }
            Text("\(Format.preciseDuration(vm.playheadMs)) / \(Format.preciseDuration(vm.totalMs))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))
            Spacer()
            Button { vm.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!vm.canUndo).accessibilityLabel(L("undo"))
            Button { vm.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!vm.canRedo).accessibilityLabel(L("redo"))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Toolbar

    private var toolStrip: some View {
        HStack(spacing: 0) {
            if vm.selectedClipID != nil {
                Button {
                    vm.selectedClipID = nil
                    vm.panel = nil
                } label: {
                    Image(systemName: "chevron.left").font(.title3.weight(.semibold))
                        .frame(width: 44, height: 64)
                }
                .foregroundStyle(.white)
                .accessibilityLabel(L("back"))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(vm.tools) { tool in
                        Button { vm.tap(tool) } label: {
                            VStack(spacing: 5) {
                                Image(systemName: tool.icon).font(.system(size: 19))
                                Text(L(tool.labelKey)).font(.caption2).lineLimit(1)
                            }
                            .frame(width: 64, height: 60)
                            .foregroundStyle(vm.panel == tool ? Brand.accent : .white)
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
        }
        .frame(height: 70)
        .background(Color(white: 0.08).ignoresSafeArea(edges: .bottom))
    }
}

/// AVPlayerLayer host. Texts and stickers are SwiftUI views on top of it.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ uiView: LayerView, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
    }
}

struct IdentifiedURL: Identifiable {
    let url: URL
    var id: URL { url }
}

struct InlinePlayer: View {
    let url: URL
    let onClose: () -> Void
    @State private var player = AVPlayer()

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            VideoPlayer(player: player)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.title3).foregroundStyle(.white)
                    .padding(12).background(.black.opacity(0.4), in: Circle())
            }
            .padding()
        }
        .onAppear { player.replaceCurrentItem(with: AVPlayerItem(url: url)); player.play() }
        .onDisappear { player.pause() }
    }
}

/// Draggable / pinchable / rotatable text and sticker items over the preview.
/// Android: "Drag with one finger to move. Pinch with two fingers to enlarge."
struct OverlayEditorLayer: View {
    @ObservedObject var vm: StudioViewModel
    let frameSize: CGSize

    var body: some View {
        ZStack {
            ForEach(vm.state.texts.filter { $0.visible(at: vm.playheadMs) || $0.id == vm.selectedTextID }) { item in
                OverlayItemView(vm: vm, item: item, frameSize: frameSize)
            }
        }
        .frame(width: frameSize.width, height: frameSize.height)
    }
}

private struct OverlayItemView: View {
    @ObservedObject var vm: StudioViewModel
    let item: TextItem
    let frameSize: CGSize

    @State private var dragStart: CGPoint?
    @State private var handleBase: Double?

    var body: some View {
        let selected = vm.selectedTextID == item.id
        let image = TextRenderer.image(for: item, frameHeight: frameSize.height * UIScreen.main.scale)
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
                Button { vm.deleteText(item.id) } label: {
                    Image(systemName: "xmark.circle.fill").font(.title3)
                        .foregroundStyle(.white, Brand.record)
                }
                .offset(x: w / 2 + 4, y: -h / 2 - 4)
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
                                vm.selectedTextID = item.id
                            }
                            guard let base = handleBase else { return }
                            let delta = (g.translation.width + g.translation.height)
                                / max(120, min(frameSize.width, frameSize.height) * 0.35)
                            vm.updateText(item.id, staged: true) {
                                $0.size = min(0.55, max(0.02, base * Double(1 + delta)))
                            }
                        }
                        .onEnded { _ in handleBase = nil; vm.commitStaged() })
            }
        }
        .frame(width: w + 24, height: h + 24)
        .contentShape(Rectangle())
        .rotationEffect(.degrees(item.rotation))
        .position(x: item.x * frameSize.width, y: item.y * frameSize.height)
        .highPriorityGesture(
            DragGesture(minimumDistance: 3)
                .onChanged { g in
                    if dragStart == nil {
                        dragStart = CGPoint(x: item.x, y: item.y)
                        vm.selectedTextID = item.id
                        vm.panel = item.kind == .sticker ? .sticker
                            : item.kind == .caption ? .captions : .text
                    }
                    guard let s = dragStart else { return }
                    vm.updateText(item.id, staged: true) {
                        $0.x = min(0.95, max(0.05, s.x + g.translation.width / frameSize.width))
                        $0.y = min(0.95, max(0.05, s.y + g.translation.height / frameSize.height))
                    }
                }
                .onEnded { _ in dragStart = nil; vm.commitStaged() }
        )
        .onTapGesture {
            SoundFx.tick()
            vm.selectedTextID = item.id
            vm.panel = item.kind == .sticker ? .sticker : item.kind == .caption ? .captions : .text
        }
    }
}
