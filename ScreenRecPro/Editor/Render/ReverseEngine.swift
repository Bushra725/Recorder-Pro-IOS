import AVFoundation
import CryptoKit

/// True frame reversal for the Reverse tool.
///
/// Android's v4 editor reversed clip *order* only, because Media3 Transformer
/// has no reverse primitive. AVFoundation lets us do the real thing: decode the
/// clip in short windows from the end backwards and re-encode each window's
/// frames in reverse order. Windows are 0.25 s so memory stays at a few frames.
/// Output is silent (as CapCut's reverse is by default) and cached per range.
enum ReverseEngine {
    enum Failure: LocalizedError {
        case tooLong, failed
        var errorDescription: String? { L("reverse_failed") }
    }

    static let maxDurationMs: Int64 = 3 * 60 * 1000

    private static var dir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("reversed", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func cacheURL(for clip: Clip) -> URL {
        let key = "\(clip.mediaURL.path)|\(clip.inMs)|\(clip.outMs)"
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)
        return dir.appendingPathComponent("rev_\(hash).mp4")
    }

    static func isCached(_ clip: Clip) -> Bool {
        FileManager.default.fileExists(atPath: cacheURL(for: clip).path)
    }

    static func reversed(_ clip: Clip, progress: ((Double) -> Void)? = nil) async throws -> URL {
        let out = cacheURL(for: clip)
        if FileManager.default.fileExists(atPath: out.path) { return out }
        guard clip.sourceDurationMs <= maxDurationMs else { throw Failure.tooLong }

        let asset = AVURLAsset(url: clip.mediaURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.failed }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let nominalFPS = try await track.load(.nominalFrameRate)
        let fps = max(15, min(60, nominalFPS))

        let tmp = out.deletingPathExtension().appendingPathExtension("part.mp4")
        try? FileManager.default.removeItem(at: tmp)
        let writer = try AVAssetWriter(outputURL: tmp, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(natural.width),
            AVVideoHeightKey: Int(natural.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(4_000_000, Int(natural.width * natural.height * 4)),
                AVVideoExpectedSourceFrameRateKey: Int(fps)
            ]
        ])
        input.transform = transform
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else { throw Failure.failed }
        writer.add(input)
        guard writer.startWriting() else { throw Failure.failed }
        writer.startSession(atSourceTime: .zero)

        let window: Int64 = 250
        var windowEnd = clip.outMs
        var lowestWritten = Int64.max   // source ms of the earliest frame already emitted
        let total = Double(max(1, clip.sourceDurationMs))

        while windowEnd > clip.inMs {
            try Task.checkCancellation()
            let windowStart = max(clip.inMs, windowEnd - window)
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(start: CMTime(value: windowStart, timescale: 1000),
                                           end: CMTime(value: windowEnd, timescale: 1000))
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw Failure.failed }
            reader.add(output)
            guard reader.startReading() else { throw Failure.failed }

            var frames: [(Int64, CVPixelBuffer)] = []
            while let sample = output.copyNextSampleBuffer() {
                guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
                let t = Int64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) * 1000)
                // Skip frames already written by the previous (later) window.
                if t >= lowestWritten || t > clip.outMs || t < clip.inMs { continue }
                frames.append((t, pb))
            }
            reader.cancelReading()

            for (t, pb) in frames.sorted(by: { $0.0 > $1.0 }) {
                while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 3_000_000) }
                let outMs = clip.outMs - t
                adaptor.append(pb, withPresentationTime: CMTime(value: outMs, timescale: 1000))
                lowestWritten = min(lowestWritten, t)
            }
            progress?(Double(clip.outMs - windowStart) / total)
            windowEnd = windowStart
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw Failure.failed }
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.moveItem(at: tmp, to: out)
        return out
    }
}
