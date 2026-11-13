import AVFoundation
import CoreImage
import UIKit

/// Turns a `StudioState` into an AVComposition + video composition + audio mix.
/// The same output drives the preview player and the export session.
struct BuiltProject {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let audioMix: AVMutableAudioMix?
    let specBox: SpecBox
    let renderSize: CGSize
}

enum ProjectError: LocalizedError {
    case noVideo
    case unreadable
    var errorDescription: String? { L("video_open_failed") }
}

enum ProjectBuilder {
    static func ms(_ v: Int64) -> CMTime { CMTime(value: v, timescale: 1000) }

    /// - Parameters:
    ///   - maxShortEdge: output short edge cap (preview ≈ 720, export 720/1080/1440).
    ///   - includeOverlays: false for the live preview (texts are SwiftUI views there).
    static func build(_ state: StudioState, maxShortEdge: CGFloat, includeOverlays: Bool,
                      watermarkLabel: String?) async throws -> BuiltProject {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw ProjectError.unreadable }

        // First pass: work out the content size from the first video clip (or photo).
        var contentSource: CGSize = .zero
        for clip in state.timeline.clips {
            if clip.isImage, let img = UIImage(contentsOfFile: clip.mediaURL.path) {
                contentSource = img.size.applying(CGAffineTransform(scaleX: img.scale, y: img.scale))
                break
            }
            if let size = await uprightSize(clip.mediaURL) { contentSource = size; break }
        }
        guard contentSource.width > 0 else { throw ProjectError.noVideo }
        let content = FramePipeline.contentSize(source: contentSource, state: state)
        let renderSize = FramePipeline.renderSize(content: content, ratio: state.ratio, maxShortEdge: maxShortEdge)

        let spec = RenderSpec(state: state, renderSize: renderSize,
                              includeOverlays: includeOverlays, watermarkLabel: watermarkLabel)
        let box = SpecBox(spec)

        var instructions: [ClipInstruction] = []
        var cursor = CMTime.zero
        var hasAnyAudio = false
        var fps: Float = 30

        for clip in state.timeline.clips {
            let target = ms(clip.timelineDurationMs)
            guard target > .zero else { continue }
            let clipMatrix = LookCatalog.matrix(for: LookCatalog.filter(clip.filter), strength: 1)
                .concat(LookCatalog.matrix(for: LookCatalog.effect(clip.effect), strength: 1))

            if clip.isImage {
                let blank = try await BlankVideo.asset()
                guard let blankTrack = try await blank.loadTracks(withMediaType: .video).first else { continue }
                let one = CMTime(value: 1, timescale: 1)
                try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: one), of: blankTrack, at: cursor)
                videoTrack.scaleTimeRange(CMTimeRange(start: cursor, duration: one), toDuration: target)
                audioTrack.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: target))
                let still = loadStill(clip.mediaURL)
                instructions.append(ClipInstruction(timeRange: CMTimeRange(start: cursor, duration: target),
                                                    trackID: videoTrack.trackID, sourceTransform: .identity,
                                                    still: still, clipMatrix: clipMatrix, specBox: box))
                cursor = cursor + target
                continue
            }

            let url = clip.reversed ? try await ReverseEngine.reversed(clip) : clip.mediaURL
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let srcVideo = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let assetDuration = try await asset.load(.duration)
            let transform = try await srcVideo.load(.preferredTransform)
            fps = max(fps, min(60, (try? await srcVideo.load(.nominalFrameRate)) ?? 30))

            var srcRange = clip.reversed
                ? CMTimeRange(start: .zero, duration: ms(clip.sourceDurationMs))
                : CMTimeRange(start: ms(clip.inMs), duration: ms(clip.sourceDurationMs))
            srcRange = srcRange.intersection(CMTimeRange(start: .zero, duration: assetDuration))
            guard srcRange.duration > .zero else { continue }
            let duration = clip.speed == 1 ? srcRange.duration
                : CMTimeMultiplyByFloat64(srcRange.duration, multiplier: 1 / clip.speed)

            try videoTrack.insertTimeRange(srcRange, of: srcVideo, at: cursor)
            if clip.speed != 1 {
                videoTrack.scaleTimeRange(CMTimeRange(start: cursor, duration: srcRange.duration), toDuration: duration)
            }

            if !clip.reversed, let srcAudio = try await asset.loadTracks(withMediaType: .audio).first {
                try audioTrack.insertTimeRange(srcRange, of: srcAudio, at: cursor)
                if clip.speed != 1 {
                    audioTrack.scaleTimeRange(CMTimeRange(start: cursor, duration: srcRange.duration), toDuration: duration)
                }
                hasAnyAudio = true
            } else {
                audioTrack.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: duration))
            }

            instructions.append(ClipInstruction(timeRange: CMTimeRange(start: cursor, duration: duration),
                                                trackID: videoTrack.trackID, sourceTransform: transform,
                                                still: nil, clipMatrix: clipMatrix, specBox: box))
            cursor = cursor + duration
        }

        guard !instructions.isEmpty else { throw ProjectError.noVideo }

        // Instructions must tile the composition exactly; snap the last one to its end.
        let total = composition.duration
        if let last = instructions.last, last.timeRange.end != total, total > last.timeRange.start {
            instructions[instructions.count - 1] = ClipInstruction(
                timeRange: CMTimeRange(start: last.timeRange.start, end: total),
                trackID: last.trackID, sourceTransform: last.sourceTransform,
                still: last.still, clipMatrix: last.clipMatrix, specBox: box)
        }

        var mixParams: [AVMutableAudioMixInputParameters] = []
        if hasAnyAudio {
            let p = AVMutableAudioMixInputParameters(track: audioTrack)
            p.setVolume(Float(state.volume), at: .zero)
            mixParams.append(p)
        } else {
            composition.removeTrack(audioTrack)
        }

        if let musicURL = state.musicURL {
            let music = AVURLAsset(url: musicURL)
            if let srcMusic = try? await music.loadTracks(withMediaType: .audio).first,
               let musicTrack = composition.addMutableTrack(withMediaType: .audio,
                                                            preferredTrackID: kCMPersistentTrackID_Invalid) {
                let musicDuration = (try? await music.load(.duration)) ?? .zero
                let start = ms(state.musicStartMs)
                let end = state.musicEndMs > state.musicStartMs ? ms(state.musicEndMs) : musicDuration
                let at = ms(max(0, state.musicOffsetMs))
                var range = CMTimeRange(start: start, end: min(end, musicDuration))
                // Never run past the end of the video.
                let room = total - at
                if room > .zero {
                    if range.duration > room { range = CMTimeRange(start: range.start, duration: room) }
                    if range.duration > .zero {
                        try? musicTrack.insertTimeRange(range, of: srcMusic, at: at)
                        let p = AVMutableAudioMixInputParameters(track: musicTrack)
                        p.setVolume(Float(state.musicVolume), at: .zero)
                        mixParams.append(p)
                    }
                }
            }
        }

        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = StudioCompositor.self
        vc.renderSize = renderSize
        vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(24, min(60, fps.rounded()))))
        vc.instructions = instructions

        var mix: AVMutableAudioMix?
        if !mixParams.isEmpty {
            let m = AVMutableAudioMix()
            m.inputParameters = mixParams
            mix = m
        }
        return BuiltProject(composition: composition, videoComposition: vc, audioMix: mix,
                            specBox: box, renderSize: renderSize)
    }

    static func loadStill(_ url: URL) -> CIImage? {
        guard let img = Thumbnails.downsampledImage(url, maxSide: 2560), let cg = img.cgImage else { return nil }
        return CIImage(cgImage: cg)
    }

    static func uprightSize(_ url: URL) async -> CGSize? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize),
              let t = try? await track.load(.preferredTransform) else { return nil }
        let r = CGRect(origin: .zero, size: natural).applying(t)
        return CGSize(width: abs(r.width), height: abs(r.height))
    }
}

/// A 1-second black clip, used as the time base for photo clips in a merge
/// (an export session needs real media data under every instruction).
enum BlankVideo {
    private static var cached: AVURLAsset?

    static func asset() async throws -> AVURLAsset {
        if let cached { return cached }
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("blank_1s.mp4")
        if !FileManager.default.fileExists(atPath: url.path) {
            try await write(url)
        }
        let a = AVURLAsset(url: url)
        cached = a
        return a
    }

    private static func write(_ url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for i in 0...30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            guard let pool = adaptor.pixelBufferPool else { break }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pb else { break }
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb) {
                memset(base, 0, CVPixelBufferGetDataSize(pb))
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
    }
}
