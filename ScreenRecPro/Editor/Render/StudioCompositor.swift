import AVFoundation
import CoreImage

/// One instruction per clip on the timeline.
final class ClipInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    let trackID: CMPersistentTrackID
    let sourceTransform: CGAffineTransform
    /// Set for photo clips (merge): drawn instead of the source frame.
    let still: CIImage?
    let clipMatrix: ColorMatrix
    let specBox: SpecBox

    init(timeRange: CMTimeRange, trackID: CMPersistentTrackID, sourceTransform: CGAffineTransform,
         still: CIImage?, clipMatrix: ColorMatrix, specBox: SpecBox) {
        self.timeRange = timeRange
        self.trackID = trackID
        self.requiredSourceTrackIDs = [NSNumber(value: trackID)]
        self.sourceTransform = sourceTransform
        self.still = still
        self.clipMatrix = clipMatrix
        self.specBox = specBox
    }
}

/// Custom compositor: every preview frame and every exported frame goes
/// through `FramePipeline.compose`, so what the user sees is what exports —
/// the same guarantee Android's v6 LookCatalog refactor was after.
final class StudioCompositor: NSObject, AVVideoCompositing {
    private let renderQueue = DispatchQueue(label: "studio.compositor")
    private var renderContext: AVVideoCompositionRenderContext?
    private var cancelled = false

    var sourcePixelBufferAttributes: [String: Any]? {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: Any] {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        renderQueue.sync { renderContext = newRenderContext }
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async {
            if self.cancelled {
                request.finishCancelledRequest()
                return
            }
            guard let instruction = request.videoCompositionInstruction as? ClipInstruction,
                  let out = self.renderContext?.newPixelBuffer() else {
                request.finish(with: NSError(domain: "StudioCompositor", code: -1))
                return
            }
            let spec = instruction.specBox.spec
            let timeMs = Int64(CMTimeGetSeconds(request.compositionTime) * 1000)

            var source: CIImage
            if let still = instruction.still {
                source = still
            } else if let buffer = request.sourceFrame(byTrackID: instruction.trackID) {
                source = FramePipeline.upright(CIImage(cvPixelBuffer: buffer), transform: instruction.sourceTransform)
            } else {
                source = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: spec.renderSize))
            }

            let frame = FramePipeline.compose(source: source, clipMatrix: instruction.clipMatrix,
                                              spec: spec, timeMs: timeMs)
            FramePipeline.context.render(frame, to: out,
                                         bounds: CGRect(origin: .zero, size: spec.renderSize),
                                         colorSpace: FramePipeline.workingSpace)
            request.finish(withComposedVideoFrame: out)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        renderQueue.sync { cancelled = true }
        renderQueue.async { self.cancelled = false }
    }
}
