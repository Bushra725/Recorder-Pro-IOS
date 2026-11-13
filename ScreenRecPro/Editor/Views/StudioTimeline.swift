import SwiftUI

/// Port of Android's `studio/Timeline.kt`.
///
/// The playhead does not move: it is a fixed line down the centre and the
/// tracks slide under it. Scroll offset and playback position are the same
/// number in different units (ms × pxPerMs). While a finger is down the drag
/// owns the position; otherwise the player does — that arbitration is what
/// keeps the strip from stuttering.
struct StudioTimeline: View {
    @ObservedObject var vm: StudioViewModel
    @State private var pxPerMs: CGFloat = 0.06       // 60 pt per second
    @State private var dragStartMs: Int64?
    @State private var zoomStart: CGFloat?
    @State private var trimStart: Clip?

    private let thumbHeight: CGFloat = 52

    var body: some View {
        GeometryReader { geo in
            let center = geo.size.width / 2
            let offset = center - CGFloat(vm.playheadMs) * pxPerMs
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 6) {
                    ruler
                    clipsRow
                    audioRow
                    overlayRow
                }
                .offset(x: offset)
                .padding(.top, 4)

                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
                    .position(x: center, y: geo.size.height / 2)
                    .allowsHitTesting(false)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { g in
                        if dragStartMs == nil { dragStartMs = vm.playheadMs; vm.beginScrub() }
                        let delta = Int64(-g.translation.width / pxPerMs)
                        vm.seek(to: (dragStartMs ?? 0) + delta)
                    }
                    .onEnded { _ in dragStartMs = nil; vm.endScrub() }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { m in
                        if zoomStart == nil { zoomStart = pxPerMs }
                        pxPerMs = min(0.4, max(0.008, (zoomStart ?? 0.06) * m))
                    }
                    .onEnded { _ in zoomStart = nil }
            )
        }
        .background(Color(white: 0.06))
    }

    // MARK: rows

    private var ruler: some View {
        let total = max(vm.totalMs, 1)
        let stepMs: Int64 = pxPerMs > 0.12 ? 1000 : pxPerMs > 0.04 ? 2000 : pxPerMs > 0.02 ? 5000 : 10000
        return ZStack(alignment: .topLeading) {
            ForEach(Array(stride(from: Int64(0), through: total, by: stepMs)), id: \.self) { t in
                Text(Format.duration(t))
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
                    .offset(x: CGFloat(t) * pxPerMs - 10)
            }
        }
        .frame(width: CGFloat(total) * pxPerMs, height: 12, alignment: .topLeading)
    }

    private var clipsRow: some View {
        HStack(spacing: 2) {
            ForEach(vm.state.timeline.clips) { clip in
                clipView(clip)
            }
        }
        .frame(height: thumbHeight)
    }

    private func clipView(_ clip: Clip) -> some View {
        let width = max(8, CGFloat(clip.timelineDurationMs) * pxPerMs)
        let count = max(1, Int(ceil(width / 48)))
        let selected = vm.selectedClipID == clip.id
        return ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { i in
                    let srcMs = clip.isImage ? 0 : clip.inMs + clip.sourceDurationMs * Int64(i) / Int64(count)
                    ThumbnailView(url: clip.mediaURL, ms: (srcMs / 500) * 500, maxSide: 120)
                        .frame(width: width / CGFloat(count), height: thumbHeight)
                        .clipped()
                }
            }
            .frame(width: width, height: thumbHeight)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 3) {
                    if clip.speed != 1 { Text("\(clip.speed, specifier: "%.2g")x") }
                    if clip.reversed { Image(systemName: "backward.fill") }
                    if !clip.filter.isEmpty || !clip.effect.isEmpty { Image(systemName: "camera.filters") }
                }
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(3)
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.white : .clear, lineWidth: 2))

            if selected && !clip.isImage {
                trimHandle(clip, leading: true).offset(x: -10)
                trimHandle(clip, leading: false).offset(x: width - 10)
            }
        }
        .frame(width: width, height: thumbHeight, alignment: .leading)
        .onTapGesture {
            SoundFx.tick()
            vm.selectedClipID = selected ? nil : clip.id
            vm.panel = nil
        }
    }

    /// Per-clip trim handles (Android's trim-by-handle on the selected clip).
    private func trimHandle(_ clip: Clip, leading: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.white)
            .frame(width: 20, height: thumbHeight)
            .overlay(Image(systemName: leading ? "chevron.compact.left" : "chevron.compact.right")
                .font(.system(size: 14, weight: .bold)).foregroundStyle(.black))
            .highPriorityGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { g in
                        if trimStart == nil { trimStart = clip }
                        guard let start = trimStart else { return }
                        let deltaSrc = Int64(Double(g.translation.width / pxPerMs) * start.speed)
                        vm.updateClip({ c in
                            if leading {
                                c.inMs = max(0, min(start.outMs - Timeline.minClipMs, start.inMs + deltaSrc))
                            } else {
                                c.outMs = max(start.inMs + Timeline.minClipMs, start.outMs + deltaSrc)
                                c.outMs = min(c.outMs, max(start.outMs, vm.sourceDurationLimit(for: c)))
                            }
                        }, staged: true)
                    }
                    .onEnded { _ in trimStart = nil; vm.commitStaged() }
            )
    }

    private var audioRow: some View {
        HStack(spacing: 0) {
            if let music = vm.state.musicURL {
                let len = (vm.state.musicEndMs > vm.state.musicStartMs ? vm.state.musicEndMs - vm.state.musicStartMs : vm.totalMs)
                Color.clear.frame(width: CGFloat(vm.state.musicOffsetMs) * pxPerMs, height: 1)
                Label(music.deletingPathExtension().lastPathComponent, systemImage: "music.note")
                    .font(.caption2).lineLimit(1)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .frame(width: max(30, CGFloat(min(len, vm.totalMs - vm.state.musicOffsetMs)) * pxPerMs),
                           height: 22, alignment: .leading)
                    .background(Color.teal.opacity(0.55), in: RoundedRectangle(cornerRadius: 5))
                    .onTapGesture { vm.panel = .audio }
            } else {
                Button { vm.selectedClipID = nil; vm.panel = .audio } label: {
                    Label(L("timeline_add_audio"), systemImage: "plus")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                }
                .foregroundStyle(.white)
            }
        }
        .frame(height: 22)
    }

    private var overlayRow: some View {
        ZStack(alignment: .topLeading) {
            ForEach(vm.state.texts) { item in
                let end = min(item.endMs, vm.totalMs)
                let color: Color = item.kind == .sticker ? .orange : item.kind == .caption ? .pink : Brand.primary
                Text(item.text)
                    .font(.caption2).lineLimit(1)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .frame(width: max(16, CGFloat(end - item.startMs) * pxPerMs), height: 20, alignment: .leading)
                    .background(color.opacity(vm.selectedTextID == item.id ? 1 : 0.6), in: RoundedRectangle(cornerRadius: 4))
                    .offset(x: CGFloat(item.startMs) * pxPerMs, y: item.kind == .caption ? 22 : 0)
                    .onTapGesture {
                        vm.selectedTextID = item.id
                        vm.panel = item.kind == .sticker ? .sticker : item.kind == .caption ? .captions : .text
                    }
            }
        }
        .frame(width: max(1, CGFloat(vm.totalMs) * pxPerMs), height: 42, alignment: .topLeading)
    }
}

extension StudioViewModel {
    /// Length of a clip's source file, for clamping the out-handle.
    func sourceDurationLimit(for clip: Clip) -> Int64 {
        if clip.mediaURL == primaryURL && originalDurationMs > 0 { return originalDurationMs }
        return VideoMeta.read(clip.mediaURL).durationMs
    }
}
