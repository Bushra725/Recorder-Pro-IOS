import AVFoundation
import AVKit
import SwiftUI

/// Port of Android's TrimActivity: one screen, three modes.
///   trim     — range on a filmstrip, lossless cut
///   compress — quality + resolution + live size estimate; several files = batch
///   gif      — range (max 30 s) → animated GIF
struct TrimToolView: View {
    let urls: [URL]
    let mode: TrimMode

    @State private var player = AVPlayer()
    @State private var durationMs: Int64 = 0
    @State private var start: Int64 = 0
    @State private var end: Int64 = 0
    @State private var meta: VideoMeta.Info?
    @State private var quality: Transcoder.Quality = .medium
    @State private var shortEdge = 0           // 0 = original
    @State private var busy: String?
    @State private var progress: Double?
    @State private var notice: String?
    @State private var savedURL: URL?
    @State private var showSaved = false

    private var url: URL { urls[0] }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                VideoPlayer(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)

                if mode != .compress || urls.count == 1 {
                    if mode != .compress { rangeEditor }
                }
                if mode == .compress { compressOptions }

                Button(primaryTitle) { Task { await run() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.horizontal, 20)
                    .disabled(durationMs == 0)
            }
            .padding(.bottom, 12)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { player.pause(); Router.shared.closeFeature() } label: { Image(systemName: "xmark") }
                }
            }
            .safeAreaInset(edge: .bottom) { AdBanner(slot: .editor) }
        }
        .toast($notice)
        .overlay { if let busy { WorkingOverlay(message: busy, progress: progress) } }
        .task { await load() }
        .alert(L("trim_saved_title"), isPresented: $showSaved) {
            if let savedURL, MediaLibrary.kindOf(savedURL) == .video {
                Button(L("play")) { player.replaceCurrentItem(with: AVPlayerItem(url: savedURL)); player.play() }
            }
            Button(L("done"), role: .cancel) { player.pause(); Router.shared.closeFeature() }
        } message: { Text(L("ios_export_saved_body")) }
    }

    private var title: String {
        switch mode {
        case .trim: return L("trim_video")
        case .compress: return urls.count > 1 ? L("batch_compress_count", urls.count) : L("video_compress")
        case .gif: return L("video_to_gif")
        }
    }

    private var primaryTitle: String {
        switch mode {
        case .trim: return L("save")
        case .compress: return urls.count > 1 ? L("batch_compress_cta") : L("compress")
        case .gif: return L("export")
        }
    }

    private func load() async {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        let info = await Task.detached { VideoMeta.read(url) }.value
        meta = info
        durationMs = info.durationMs
        end = mode == .gif ? min(info.durationMs, GifMaker.maxRangeMs) : info.durationMs
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
    }

    // MARK: - Range

    private var rangeEditor: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(0..<8, id: \.self) { i in
                        ThumbnailView(url: url, ms: durationMs * Int64(i) / 8, maxSide: 120)
                            .frame(width: geo.size.width / 8, height: 48)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    let w = geo.size.width
                    let d = Double(max(1, durationMs))
                    let x0 = CGFloat(Double(start) / d) * w
                    let x1 = CGFloat(Double(end) / d) * w
                    ZStack(alignment: .leading) {
                        Color.black.opacity(0.55).frame(width: max(0, x0)).frame(maxWidth: .infinity, alignment: .leading)
                        Color.black.opacity(0.55).frame(width: max(0, w - x1)).offset(x: x1)
                        RoundedRectangle(cornerRadius: 6).stroke(Brand.accent, lineWidth: 3)
                            .frame(width: max(8, x1 - x0)).offset(x: x0)
                        handle.offset(x: x0 - 8).gesture(DragGesture().onChanged { g in
                            let v = Int64(Double(max(0, min(g.location.x, x1 - 10)) / Double(w)) * d)
                            start = max(0, min(v, end - 300))
                            if mode == .gif { end = min(end, start + GifMaker.maxRangeMs) }
                            seek(start)
                        })
                        handle.offset(x: x1 - 8).gesture(DragGesture().onChanged { g in
                            let v = Int64(Double(max(x0 + 10, min(g.location.x, w)) / Double(w)) * d)
                            end = min(durationMs, max(v, start + 300))
                            if mode == .gif { start = max(start, end - GifMaker.maxRangeMs) }
                            seek(end)
                        })
                    }
                    .frame(width: w, height: 48, alignment: .leading)
                }
            }
            .frame(height: 48)
            HStack {
                Text(Format.preciseDuration(start))
                Spacer()
                Text(mode == .gif ? L("gif_total", Format.preciseDuration(end - start)) : Format.preciseDuration(end - start))
                    .foregroundStyle(Brand.primary)
                Spacer()
                Text(Format.preciseDuration(end))
            }
            .font(.caption.monospacedDigit())
            if mode == .trim { Text(L("tool_trim_hint")).font(.caption).foregroundStyle(Brand.textMuted) }
        }
        .padding(.horizontal, 20)
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 4).fill(Brand.accent).frame(width: 16, height: 56)
    }

    private func seek(_ ms: Int64) {
        player.seek(to: CMTime(value: ms, timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - Compress

    private var compressOptions: some View {
        let source = meta?.size ?? .zero
        let srcShort = Int(min(source.width, source.height))
        let options = [0] + [1080, 720, 480].filter { $0 < srcShort }
        let outSize = Transcoder.outputSize(source: source, shortEdge: shortEdge)
        let rate = Transcoder.videoBitrate(for: outSize, quality: quality, sourceBitrate: meta?.bitrate ?? 0)
        let est = Transcoder.estimatedBytes(durationMs: durationMs, videoBitrate: rate)
        let srcBytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)

        return VStack(alignment: .leading, spacing: 10) {
            Text(L("compress_quality")).font(.subheadline.weight(.semibold))
            Picker("", selection: $quality) {
                ForEach(Transcoder.Quality.allCases) { Text(L($0.labelKey)).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(L("compress_resolution")).font(.subheadline.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(options, id: \.self) { o in
                        Button { shortEdge = o } label: {
                            Text(o == 0 ? L("compress_original", srcShort) : "\(o)P")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .foregroundStyle(shortEdge == o ? .white : Brand.text)
                                .background(shortEdge == o ? Brand.primary : Brand.surfaceHigh, in: Capsule())
                        }
                    }
                }
            }
            if urls.count == 1 {
                HStack {
                    Text(L("compress_size_from", Format.size(srcBytes)))
                    Text(L("compress_size_est", Format.size(est))).foregroundStyle(Brand.primary).bold()
                }
                .font(.subheadline)
                Text(shortEdge == 0 ? L("compress_bitrate_only")
                     : L("compress_output", Int(source.width), Int(source.height), Int(outSize.width), Int(outSize.height)))
                    .font(.caption).foregroundStyle(Brand.textMuted)
            } else {
                Text(L("compress_pick_hint")).font(.caption).foregroundStyle(Brand.textMuted)
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Run

    private func run() async {
        player.pause()
        progress = 0
        do {
            switch mode {
            case .trim:
                busy = L("exporting")
                let out = try await Exporter.trim(url, startMs: start, endMs: end) { p in
                    Task { @MainActor in progress = p }
                }
                savedURL = await MediaLibrary.shared.addVideo(from: out, move: true, prefix: "Trimmed")
                Engagement.shared.onEditCompleted()
            case .compress:
                for (i, u) in urls.enumerated() {
                    busy = urls.count > 1 ? L("batch_compress_progress", i + 1, urls.count) : L("exporting")
                    let out = try await Transcoder.compress(u, shortEdge: shortEdge, quality: quality) { p in
                        Task { @MainActor in progress = (Double(i) + p) / Double(urls.count) }
                    }
                    savedURL = await MediaLibrary.shared.addVideo(from: out, move: true, prefix: "Compressed")
                }
                if urls.count > 1 { notice = L("batch_compress_done", urls.count) }
            case .gif:
                busy = L("making_gif")
                let out = try await GifMaker.make(url, startMs: start, endMs: end) { p in
                    Task { @MainActor in progress = p }
                }
                let data = try Data(contentsOf: out)
                savedURL = await MediaLibrary.shared.addImageData(data, ext: "gif", prefix: "GIF")
                try? FileManager.default.removeItem(at: out)
            }
            busy = nil; progress = nil
            showSaved = savedURL != nil
        } catch {
            busy = nil; progress = nil
            notice = mode == .gif ? L("gif_failed") : L("export_failed")
        }
    }
}
