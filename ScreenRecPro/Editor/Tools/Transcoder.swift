import AVFoundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Video Compress (single and batch). Port of TrimActivity's compress mode:
/// pick High / Medium / Low and an output resolution, see the estimated size,
/// then re-encode with an explicit bitrate. AVAssetExportSession presets cannot
/// target a bitrate, so this is a reader → writer pipeline.
enum Transcoder {
    enum Quality: String, CaseIterable, Identifiable {
        case high, medium, low
        var id: String { rawValue }
        var labelKey: String {
            switch self {
            case .high: return "compress_quality_high"
            case .medium: return "compress_quality_medium"
            case .low: return "compress_quality_low"
            }
        }
        /// Fraction of a sensible bitrate for the output resolution.
        var factor: Double { self == .high ? 0.75 : self == .medium ? 0.5 : 0.3 }
    }

    static let audioBitrate = 64_000

    /// Bits per second for `size` at `quality`, never above the source's own rate.
    static func videoBitrate(for size: CGSize, quality: Quality, sourceBitrate: Float) -> Int {
        let pixels = Double(size.width * size.height)
        let reference = pixels * 30 * 0.12            // ~0.12 bits per pixel per frame at 30 fps
        var rate = reference * quality.factor * 2
        if sourceBitrate > 0 { rate = min(rate, Double(sourceBitrate) * (quality.factor + 0.1)) }
        return max(250_000, Int(rate))
    }

    static func outputSize(source: CGSize, shortEdge: Int) -> CGSize {
        let short = min(source.width, source.height)
        guard shortEdge > 0, CGFloat(shortEdge) < short else { return evenSize(source) }
        let scale = CGFloat(shortEdge) / short
        return evenSize(CGSize(width: source.width * scale, height: source.height * scale))
    }

    static func evenSize(_ s: CGSize) -> CGSize {
        CGSize(width: max(2, (s.width / 2).rounded() * 2), height: max(2, (s.height / 2).rounded() * 2))
    }

    static func estimatedBytes(durationMs: Int64, videoBitrate: Int) -> Int64 {
        Int64(Double(videoBitrate + audioBitrate) * Double(durationMs) / 1000 / 8)
    }

    static func compress(_ url: URL, shortEdge: Int, quality: Quality,
                         progress: @escaping (Double) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let vTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw Exporter.Failure.failed("no video")
        }
        let duration = try await asset.load(.duration)
        let natural = try await vTrack.load(.naturalSize)
        let transform = try await vTrack.load(.preferredTransform)
        let srcRate = try await vTrack.load(.estimatedDataRate)
        let fps = try await vTrack.load(.nominalFrameRate)
        let upright = CGRect(origin: .zero, size: natural).applying(transform).size
        let uprightSize = CGSize(width: abs(upright.width), height: abs(upright.height))
        let outSize = outputSize(source: uprightSize, shortEdge: shortEdge)
        let bitrate = videoBitrate(for: outSize, quality: quality, sourceBitrate: srcRate)

        let reader = try AVAssetReader(asset: asset)
        // Composition output applies the rotation and the scale for us.
        let vc = AVMutableVideoComposition()
        vc.renderSize = outSize
        vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(15, min(60, fps.rounded()))))
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: vTrack)
        let scale = outSize.width / uprightSize.width
        layer.setTransform(transform.concatenating(CGAffineTransform(scaleX: scale, y: scale)), at: .zero)
        instruction.layerInstructions = [layer]
        vc.instructions = [instruction]

        let vOut = AVAssetReaderVideoCompositionOutput(videoTracks: [vTrack], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ])
        vOut.videoComposition = vc
        guard reader.canAdd(vOut) else { throw Exporter.Failure.failed("reader") }
        reader.add(vOut)

        var aOut: AVAssetReaderTrackOutput?
        if let aTrack = try await asset.loadTracks(withMediaType: .audio).first {
            let o = AVAssetReaderTrackOutput(track: aTrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            if reader.canAdd(o) { reader.add(o); aOut = o }
        }

        let out = MediaLibrary.tempURL(ext: "mp4")
        let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(outSize.width),
            AVVideoHeightKey: Int(outSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ])
        vIn.expectsMediaDataInRealTime = false
        writer.add(vIn)
        var aIn: AVAssetWriterInput?
        if aOut != nil {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: audioBitrate
            ])
            a.expectsMediaDataInRealTime = false
            if writer.canAdd(a) { writer.add(a); aIn = a }
        }

        guard reader.startReading(), writer.startWriting() else { throw Exporter.Failure.failed("start") }
        writer.startSession(atSourceTime: .zero)
        let total = max(0.001, duration.seconds)

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await pump(output: vOut, input: vIn) { t in progress(min(0.99, t / total)) } }
            if let aOut, let aIn { group.addTask { await pump(output: aOut, input: aIn, onTime: nil) } }
        }

        if reader.status == .failed { writer.cancelWriting(); throw Exporter.Failure.failed("read") }
        await writer.finishWriting()
        guard writer.status == .completed else { throw Exporter.Failure.failed("write") }
        progress(1)
        return out
    }

    private static func pump(output: AVAssetReaderOutput, input: AVAssetWriterInput,
                             onTime: ((Double) -> Void)?) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let queue = DispatchQueue(label: "transcode.\(input.mediaType.rawValue)")
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    if let sample = output.copyNextSampleBuffer() {
                        if !input.append(sample) { input.markAsFinished(); cont.resume(); return }
                        onTime?(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
                    } else {
                        input.markAsFinished()
                        cont.resume()
                        return
                    }
                }
            }
        }
    }
}

/// Video to GIF. Port of `edit/GifEncoder.kt`, on ImageIO.
enum GifMaker {
    static let maxRangeMs: Int64 = 30_000

    static func make(_ url: URL, startMs: Int64, endMs: Int64, fps: Int = 10, maxSide: CGFloat = 480,
                     progress: @escaping (Double) -> Void) async throws -> URL {
        let end = min(endMs, startMs + maxRangeMs)
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxSide, height: maxSide)
        gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)

        let step = 1000 / Int64(fps)
        let times = stride(from: startMs, to: end, by: Int(step)).map { CMTime(value: $0, timescale: 1000) }
        guard !times.isEmpty else { throw Exporter.Failure.failed("range") }

        let out = MediaLibrary.tempURL(ext: "gif")
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString,
                                                         times.count, nil) else {
            throw Exporter.Failure.failed("gif")
        }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFDelayTime: 1.0 / Double(fps),
            kCGImagePropertyGIFUnclampedDelayTime: 1.0 / Double(fps)
        ]] as CFDictionary

        for (i, t) in times.enumerated() {
            try Task.checkCancellation()
            let cg = try gen.copyCGImage(at: t, actualTime: nil)
            CGImageDestinationAddImage(dest, cg, frameProps)
            progress(Double(i + 1) / Double(times.count))
            await Task.yield()
        }
        guard CGImageDestinationFinalize(dest) else { throw Exporter.Failure.failed("finalize") }
        return out
    }
}
