import AVFoundation
import UIKit

/// Export helpers: the full studio render, plain trims, and post-capture finishing.
enum Exporter {
    enum Failure: LocalizedError {
        case failed(String?)
        var errorDescription: String? { L("export_failed") }
    }

    /// Renders a studio project to an .mp4 in the work folder.
    static func export(_ state: StudioState, shortEdge: CGFloat, watermarkLabel: String?,
                       progress: @escaping (Double) -> Void) async throws -> URL {
        let project = try await ProjectBuilder.build(state, maxShortEdge: shortEdge, includeOverlays: true,
                                                     watermarkLabel: watermarkLabel)
        let out = MediaLibrary.tempURL(ext: "mp4")
        try await run(asset: project.composition, videoComposition: project.videoComposition,
                      audioMix: project.audioMix, preset: AVAssetExportPresetHighestQuality,
                      to: out, timeRange: nil, progress: progress)
        return out
    }

    /// Lossless cut (no re-encode) when possible.
    static func trim(_ url: URL, startMs: Int64, endMs: Int64,
                     progress: @escaping (Double) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let out = MediaLibrary.tempURL(ext: "mp4")
        let range = CMTimeRange(start: CMTime(value: startMs, timescale: 1000),
                                end: CMTime(value: endMs, timescale: 1000))
        do {
            try await run(asset: asset, videoComposition: nil, audioMix: nil,
                          preset: AVAssetExportPresetPassthrough, to: out, timeRange: range, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: out)
            try await run(asset: asset, videoComposition: nil, audioMix: nil,
                          preset: AVAssetExportPresetHighestQuality, to: out, timeRange: range, progress: progress)
        }
        return out
    }

    static func run(asset: AVAsset, videoComposition: AVVideoComposition?, audioMix: AVAudioMix?,
                    preset: String, to out: URL, timeRange: CMTimeRange?,
                    progress: @escaping (Double) -> Void) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw Failure.failed("session")
        }
        try? FileManager.default.removeItem(at: out)
        session.outputURL = out
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        session.videoComposition = videoComposition
        session.audioMix = audioMix
        session.audioTimePitchAlgorithm = .spectral
        if let timeRange { session.timeRange = timeRange }

        let poll = Task {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        await session.export()
        poll.cancel()
        progress(1)
        guard session.status == .completed else {
            throw Failure.failed(session.error?.localizedDescription)
        }
    }

    /// Finishing pass for a raw capture from the broadcast extension:
    /// rotation, region crop, watermark, and mixing app + mic audio into one track.
    /// Falls back to a straight remux when none of that is needed.
    static func finishCapture(_ url: URL, sidecar: CaptureSidecar?, watermark: String?) async throws -> URL {
        let region = sidecar.flatMap { SharedFormat.region(from: $0.region) }
        let rotation = sidecar?.rotationDeg ?? 0
        let audioTracks = sidecar?.audioTracks ?? 1
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        guard duration.seconds > 0.3, !(try await asset.loadTracks(withMediaType: .video)).isEmpty else {
            throw Failure.failed("empty")
        }

        let needsRender = region != nil || rotation != 0 || watermark != nil
        if !needsRender && audioTracks <= 1 {
            let out = MediaLibrary.tempURL(ext: "mp4")
            try await run(asset: asset, videoComposition: nil, audioMix: nil,
                          preset: AVAssetExportPresetPassthrough, to: out, timeRange: nil, progress: { _ in })
            return out
        }
        if !needsRender {
            // Two audio tracks (app + mic): an export session mixes them into one.
            let out = MediaLibrary.tempURL(ext: "mp4")
            let composition = AVMutableComposition()
            let range = CMTimeRange(start: .zero, duration: duration)
            if let v = try await asset.loadTracks(withMediaType: .video).first,
               let cv = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try cv.insertTimeRange(range, of: v, at: .zero)
                cv.preferredTransform = try await v.load(.preferredTransform)
            }
            for a in try await asset.loadTracks(withMediaType: .audio) {
                if let ca = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    try ca.insertTimeRange(range, of: a, at: .zero)
                }
            }
            try await run(asset: composition, videoComposition: nil, audioMix: nil,
                          preset: AVAssetExportPresetHighestQuality, to: out, timeRange: nil, progress: { _ in })
            return out
        }

        var state = StudioState.single(url: url, durationMs: Int64(duration.seconds * 1000))
        state.regionCrop = region
        state.rotationDeg = rotation
        let size = await ProjectBuilder.uprightSize(url) ?? CGSize(width: 720, height: 1280)
        // Keep the capture's own resolution.
        let short = min(size.width, size.height)
        let project = try await ProjectBuilder.build(state, maxShortEdge: short, includeOverlays: true,
                                                     watermarkLabel: watermark)
        // Mix every audio track of the capture, not just the first.
        let extraAudio = try await asset.loadTracks(withMediaType: .audio).dropFirst()
        for a in extraAudio {
            if let ca = project.composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try? ca.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: a, at: .zero)
            }
        }
        let out = MediaLibrary.tempURL(ext: "mp4")
        try await run(asset: project.composition, videoComposition: project.videoComposition, audioMix: nil,
                      preset: AVAssetExportPresetHighestQuality, to: out, timeRange: nil, progress: { _ in })
        return out
    }
}
