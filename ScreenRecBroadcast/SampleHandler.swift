import ReplayKit
import AVFoundation
import CoreImage
import CoreMotion
import UIKit

/// Broadcast Upload Extension: the part of the app that actually records the
/// whole screen, including other apps. iOS starts it from the system broadcast
/// sheet (our Record button opens that sheet) or from Control Center.
///
/// Mirrors Android's RecorderService + ScreenEncoder + AudioEngine:
///   * resolution / fps / bitrate / encoder from Settings
///   * audio source: mute, mic, internal (app audio), or both
///   * pause / resume, stop, screenshot — driven by the Live Activity buttons
///   * timed recording (auto-stop), shake to stop
///   * "auto repair": fragmented .mov so a killed extension still leaves a playable file
///
/// Runs with a 50 MB memory ceiling, so nothing here buffers frames.
final class SampleHandler: RPBroadcastSampleHandler {

    // MARK: settings snapshot (read once at start)
    private var targetShortEdge = 720
    private var fps = 30
    private var bitrate = 8_000_000
    private var audioSource = "MUTE"
    private var lockPortrait = false
    private var advancedEncoder = false
    private var autoRepair = true
    private var limitSeconds = 0
    private var region = ""
    private var skipUntil = Date.distantPast

    // MARK: writer state — only touched on `queue`
    private let queue = DispatchQueue(label: "screenrec.broadcast.writer")
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var appAudioInput: AVAssetWriterInput?
    private var micAudioInput: AVAssetWriterInput?
    private var outputURL: URL?
    private var sessionStart: CMTime?
    private var lastVideoPTS: CMTime = .invalid
    private var lastAppendedVideoPTS: CMTime = .invalid
    private var pauseOffset: CMTime = .zero
    private var paused = false
    private var resumePending = false
    private var finalized = false
    private var screenshotRequested = false
    private var orientationVotes: [Int: Int] = [:]

    // MARK: misc
    private let events = DarwinObserver()
    private var heartbeat: DispatchSourceTimer?
    private var exitRequested = false   // main thread only
    private var limitHit = false        // writer queue only
    private let motion = CMMotionManager()
    private var lastShakeAt: Date?
    private lazy var ciContext = CIContext(options: [.cacheIntermediates: false])

    // MARK: - Lifecycle

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let d = AppGroup.defaults
        targetShortEdge = d.object(forKey: SharedKeys.resolution) as? Int ?? 720
        fps = max(15, d.object(forKey: SharedKeys.fps) as? Int ?? 30)
        bitrate = max(1_000_000, d.object(forKey: SharedKeys.bitrate) as? Int ?? 8_000_000)
        audioSource = d.string(forKey: SharedKeys.audioSource) ?? "MUTE"
        lockPortrait = d.string(forKey: SharedKeys.orientation) == "PORTRAIT"
        advancedEncoder = d.string(forKey: SharedKeys.recordingMode) == "ADVANCED"
        autoRepair = d.object(forKey: SharedKeys.autoRepair) as? Bool ?? true

        // A pending request (timer, region) only applies if the app wrote it
        // moments ago. Starting from Control Center gives a plain recording.
        let requestedAt = d.double(forKey: SharedKeys.pendingRequestedAt)
        if requestedAt > 0, Date().timeIntervalSince1970 - requestedAt < 180 {
            limitSeconds = d.integer(forKey: SharedKeys.pendingLimitSeconds)
            region = d.string(forKey: SharedKeys.pendingRegion) ?? ""
        }
        d.removeObject(forKey: SharedKeys.pendingRequestedAt)
        d.removeObject(forKey: SharedKeys.pendingLimitSeconds)
        d.removeObject(forKey: SharedKeys.pendingRegion)

        // The system sheet already counts down 3 s. A longer countdown setting
        // (5 s, 10 s) drops the extra seconds here.
        let countdown = d.object(forKey: SharedKeys.countdown) as? Int ?? 3
        skipUntil = Date().addingTimeInterval(TimeInterval(max(0, countdown - 3)))

        let now = Date().timeIntervalSince1970
        d.set(LiveStatus.recording.rawValue, forKey: SharedKeys.liveStatus)
        d.set(now + max(0, skipUntil.timeIntervalSince1970 - now), forKey: SharedKeys.liveStartedAt)
        d.set(0.0, forKey: SharedKeys.livePausedTotal)
        d.set(0.0, forKey: SharedKeys.livePausedAt)
        d.set(now, forKey: SharedKeys.liveHeartbeat)

        events.observe(.pause) { [weak self] in self?.setPaused(true) }
        events.observe(.resume) { [weak self] in self?.setPaused(false) }
        events.observe(.stop) { [weak self] in
            self?.finishAndExit(message: NSLocalizedString("ios_broadcast_saved", comment: ""))
        }
        events.observe(.screenshot) { [weak self] in
            self?.queue.async { self?.screenshotRequested = true }
        }

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler {
            AppGroup.defaults.set(Date().timeIntervalSince1970, forKey: SharedKeys.liveHeartbeat)
        }
        timer.resume()
        heartbeat = timer

        if d.bool(forKey: SharedKeys.shakeToStop) { startShakeDetection() }
        DarwinEvent.started.post()
    }

    override func broadcastPaused() { setPaused(true) }
    override func broadcastResumed() { setPaused(false) }

    override func broadcastFinished() {
        // Stopped from the red status pill or Control Center. The process may be
        // torn down as soon as this returns, so wait for the file to close.
        let done = DispatchSemaphore(value: 0)
        queue.async { self.finalize { done.signal() } }
        _ = done.wait(timeout: .now() + 10)
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                      with sampleBufferType: RPSampleBufferType) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        queue.sync {
            guard !finalized, Date() >= skipUntil else { return }
            switch sampleBufferType {
            case .video: handleVideo(sampleBuffer)
            case .audioApp:
                if audioSource == "INTERNAL" || audioSource == "MIC_AND_INTERNAL" {
                    handleAudio(sampleBuffer, input: appAudioInput)
                }
            case .audioMic:
                if audioSource == "MIC" || audioSource == "MIC_AND_INTERNAL" {
                    handleAudio(sampleBuffer, input: micAudioInput)
                }
            @unknown default: break
            }
        }
    }

    // MARK: - Video

    private func handleVideo(_ sample: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let orientation = Self.orientation(of: sample)

        if writer == nil { setUpWriter(width: CVPixelBufferGetWidth(pixelBuffer),
                                       height: CVPixelBufferGetHeight(pixelBuffer),
                                       firstPTS: pts) }
        guard let writer, writer.status == .writing,
              let videoInput, let adaptor, let start = sessionStart else { return }

        if paused { return }
        if resumePending {
            // Close the gap left by the pause: everything after this point
            // moves back by (gap - one frame) so playback is seamless.
            if lastVideoPTS.isValid {
                let frame = CMTime(value: 1, timescale: CMTimeScale(fps))
                let gap = CMTimeSubtract(CMTimeSubtract(pts, lastVideoPTS), frame)
                if gap > .zero { pauseOffset = CMTimeAdd(pauseOffset, gap) }
            }
            resumePending = false
        }
        lastVideoPTS = pts
        let outPTS = CMTimeSubtract(pts, pauseOffset)

        if screenshotRequested {
            screenshotRequested = false
            saveScreenshot(pixelBuffer, orientation: orientation)
        }

        // Frame-rate cap: ReplayKit delivers up to 60 fps (only when something changes).
        if lastAppendedVideoPTS.isValid {
            let minGap = 0.9 / Double(fps)
            if CMTimeGetSeconds(CMTimeSubtract(outPTS, lastAppendedVideoPTS)) < minGap { return }
        }
        guard videoInput.isReadyForMoreMediaData else { return }
        if adaptor.append(pixelBuffer, withPresentationTime: outPTS) {
            lastAppendedVideoPTS = outPTS
            if !lockPortrait { orientationVotes[orientation, default: 0] += 1 }
        }

        if limitSeconds > 0, !limitHit {
            let elapsed = CMTimeGetSeconds(CMTimeSubtract(outPTS, start))
            if elapsed >= Double(limitSeconds) {
                limitHit = true
                DispatchQueue.main.async {
                    self.finishAndExit(message: NSLocalizedString("ios_broadcast_timer_done", comment: ""))
                }
            }
        }
    }

    private func setUpWriter(width: Int, height: Int, firstPTS: CMTime) {
        let shortEdge = min(width, height)
        let scale = targetShortEdge <= 0 ? 1.0 : min(1.0, Double(targetShortEdge) / Double(shortEdge))
        let outW = Self.even(Double(width) * scale)
        let outH = Self.even(Double(height) * scale)

        let ext = autoRepair ? "mov" : "mp4"
        let url = AppGroup.inbox.appendingPathComponent("rec_\(SharedFormat.stamp()).\(ext)")
        try? FileManager.default.removeItem(at: url)

        guard let w = try? AVAssetWriter(outputURL: url, fileType: autoRepair ? .mov : .mp4) else { return }
        if autoRepair {
            // Fragmented movie: if the extension is killed (memory, crash) the
            // file written so far is still playable — Android's "Auto Repair".
            w.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        }

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: fps * 2,
            AVVideoAllowFrameReorderingKey: false
        ]
        let codec: AVVideoCodecType
        if advancedEncoder {
            codec = .hevc
        } else {
            codec = .h264
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: outW,
            AVVideoHeightKey: outH,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: compression
        ]
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vIn.expectsMediaDataInRealTime = true
        guard w.canAdd(vIn) else { return }
        w.add(vIn)

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000
        ]
        if audioSource == "INTERNAL" || audioSource == "MIC_AND_INTERNAL" {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            a.expectsMediaDataInRealTime = true
            if w.canAdd(a) { w.add(a); appAudioInput = a }
        }
        if audioSource == "MIC" || audioSource == "MIC_AND_INTERNAL" {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            a.expectsMediaDataInRealTime = true
            if w.canAdd(a) { w.add(a); micAudioInput = a }
        }

        guard w.startWriting() else { return }
        w.startSession(atSourceTime: firstPTS)
        writer = w
        videoInput = vIn
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: nil)
        outputURL = url
        sessionStart = firstPTS
    }

    // MARK: - Audio

    private func handleAudio(_ sample: CMSampleBuffer, input: AVAssetWriterInput?) {
        guard let input, let writer, writer.status == .writing,
              let start = sessionStart, !paused, !resumePending else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts >= start, input.isReadyForMoreMediaData else { return }
        if pauseOffset == .zero {
            input.append(sample)
        } else if let shifted = Self.retimed(sample, by: pauseOffset) {
            input.append(shifted)
        }
    }

    // MARK: - Pause / stop

    private func setPaused(_ value: Bool) {
        queue.async {
            guard !self.finalized, self.paused != value else { return }
            self.paused = value
            let d = AppGroup.defaults
            let now = Date().timeIntervalSince1970
            if value {
                d.set(now, forKey: SharedKeys.livePausedAt)
                d.set(LiveStatus.paused.rawValue, forKey: SharedKeys.liveStatus)
            } else {
                self.resumePending = true
                let pausedAt = d.double(forKey: SharedKeys.livePausedAt)
                if pausedAt > 0 {
                    d.set(d.double(forKey: SharedKeys.livePausedTotal) + (now - pausedAt),
                          forKey: SharedKeys.livePausedTotal)
                }
                d.set(0.0, forKey: SharedKeys.livePausedAt)
                d.set(LiveStatus.recording.rawValue, forKey: SharedKeys.liveStatus)
            }
            DarwinEvent.stateChanged.post()
        }
    }

    /// Stops the broadcast from inside the extension (Live Activity Stop button,
    /// timer reached, shake). The file is closed first; then the system is told
    /// to end the broadcast and shows `message` to the user.
    private func finishAndExit(message: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.finishAndExit(message: message) }
            return
        }
        guard !exitRequested else { return }
        exitRequested = true
        queue.async {
            self.finalize {
                DispatchQueue.main.async {
                    let error = NSError(domain: "ScreenRecPro", code: 0,
                                        userInfo: [NSLocalizedDescriptionKey: message])
                    self.finishBroadcastWithError(error)
                }
            }
        }
    }

    /// Must be called on `queue`.
    private func finalize(_ completion: @escaping () -> Void) {
        guard !finalized else { completion(); return }
        finalized = true
        DispatchQueue.main.async {
            self.heartbeat?.cancel()
            self.motion.stopAccelerometerUpdates()
        }

        let d = AppGroup.defaults
        let durationMs: Int64
        if let start = sessionStart, lastAppendedVideoPTS.isValid {
            durationMs = Int64(CMTimeGetSeconds(CMTimeSubtract(lastAppendedVideoPTS, start)) * 1000)
        } else {
            durationMs = 0
        }

        let wrapUp: (Bool) -> Void = { clean in
            if let url = self.outputURL {
                let rotation = self.lockPortrait ? 0 : self.dominantRotation()
                let tracks = (self.appAudioInput != nil ? 1 : 0) + (self.micAudioInput != nil ? 1 : 0)
                let sidecar = CaptureSidecar(
                    fileName: url.lastPathComponent,
                    durationMs: durationMs,
                    region: self.region,
                    rotationDeg: rotation,
                    audioTracks: tracks,
                    finishedCleanly: clean,
                    createdAt: Date()
                )
                if let data = try? JSONEncoder().encode(sidecar) {
                    try? data.write(to: url.appendingPathExtension("json"))
                }
            }
            d.set(LiveStatus.idle.rawValue, forKey: SharedKeys.liveStatus)
            d.set(0.0, forKey: SharedKeys.liveStartedAt)
            d.set(0.0, forKey: SharedKeys.livePausedAt)
            d.set(0.0, forKey: SharedKeys.liveHeartbeat)
            DarwinEvent.finished.post()
            completion()
        }

        guard let writer, writer.status == .writing else {
            // Nothing (or nothing valid) was written.
            if let url = outputURL, writer?.status != .writing {
                // Keep a fragmented partial file for auto repair; drop anything else.
                if !autoRepair { try? FileManager.default.removeItem(at: url); outputURL = nil }
            }
            wrapUp(false)
            return
        }
        if lastAppendedVideoPTS.isValid { writer.endSession(atSourceTime: lastAppendedVideoPTS) }
        videoInput?.markAsFinished()
        appAudioInput?.markAsFinished()
        micAudioInput?.markAsFinished()
        writer.finishWriting {
            let ok = writer.status == .completed
            if !self.lastAppendedVideoPTS.isValid, let url = self.outputURL {
                try? FileManager.default.removeItem(at: url)
                self.outputURL = nil
            }
            wrapUp(ok)
        }
    }

    // MARK: - Screenshot

    private func saveScreenshot(_ pixelBuffer: CVPixelBuffer, orientation: Int) {
        let oriented = CIImage(cvPixelBuffer: pixelBuffer)
            .oriented(CGImagePropertyOrientation(rawValue: UInt32(orientation)) ?? .up)
        guard let cg = ciContext.createCGImage(oriented, from: oriented.extent),
              let data = UIImage(cgImage: cg).pngData() else { return }
        let url = AppGroup.screenshotInbox.appendingPathComponent("shot_\(SharedFormat.stamp()).png")
        try? data.write(to: url)
        DarwinEvent.screenshotSaved.post()
    }

    // MARK: - Shake to stop

    private func startShakeDetection() {
        guard motion.isAccelerometerAvailable else { return }
        motion.accelerometerUpdateInterval = 1.0 / 30.0
        motion.startAccelerometerUpdates(to: OperationQueue()) { [weak self] data, _ in
            guard let self, let a = data?.acceleration else { return }
            let g = sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
            guard g > 2.7 else { return }
            let now = Date()
            // Two distinct shakes within 1.5 s, like Android's ShakeDetector.
            if let last = self.lastShakeAt, now.timeIntervalSince(last) > 0.25,
               now.timeIntervalSince(last) < 1.5 {
                self.lastShakeAt = nil
                DispatchQueue.main.async {
                    self.finishAndExit(message: NSLocalizedString("ios_broadcast_saved", comment: ""))
                }
            } else if self.lastShakeAt == nil || now.timeIntervalSince(self.lastShakeAt!) >= 1.5 {
                self.lastShakeAt = now
            }
        }
    }

    // MARK: - Helpers

    private static func orientation(of sample: CMSampleBuffer) -> Int {
        guard let value = CMGetAttachment(sample, key: RPVideoSampleOrientationKey as CFString,
                                          attachmentModeOut: nil) as? NSNumber else {
            return Int(CGImagePropertyOrientation.up.rawValue)
        }
        return value.intValue
    }

    /// Clockwise degrees that turn the stored frames upright, chosen by which
    /// orientation the recording spent the most frames in.
    private func dominantRotation() -> Int {
        guard let top = orientationVotes.max(by: { $0.value < $1.value })?.key,
              let o = CGImagePropertyOrientation(rawValue: UInt32(top)) else { return 0 }
        switch o {
        case .right, .rightMirrored: return 90
        case .down, .downMirrored: return 180
        case .left, .leftMirrored: return 270
        default: return 0
        }
    }

    private static func even(_ v: Double) -> Int {
        max(2, Int((v / 2).rounded()) * 2)
    }

    private static func retimed(_ sample: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return nil }
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for i in 0..<timing.count {
            timing[i].presentationTimeStamp = CMTimeSubtract(timing[i].presentationTimeStamp, offset)
            if timing[i].decodeTimeStamp.isValid {
                timing[i].decodeTimeStamp = CMTimeSubtract(timing[i].decodeTimeStamp, offset)
            }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
                                              sampleTimingEntryCount: count, sampleTimingArray: &timing,
                                              sampleBufferOut: &out)
        return out
    }
}
