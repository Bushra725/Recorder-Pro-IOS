import AVFoundation
import AVKit
import CoreImage
import SwiftUI

/// iOS counterpart of Android's FacecamService.
///
/// Android floats a camera bubble over other apps while recording. iOS does not
/// allow camera access from the background, so the facecam is added the way
/// iOS reaction apps do it: the recording plays here while the front camera
/// films you in a bubble you can drag and resize; both are then composited
/// into one video.
struct FacecamRecorderView: View {
    let videoURL: URL
    @StateObject private var cam = FacecamCamera()
    @State private var player = AVPlayer()
    @State private var bubbleCenter = CGPoint(x: 0.78, y: 0.2)
    @State private var bubbleSize: CGFloat = 0.32       // fraction of the frame width
    @State private var dragStart: CGPoint?
    @State private var videoAspect: CGFloat = 9.0 / 16.0
    @State private var recording = false
    @State private var busy: String?
    @State private var progress: Double?
    @State private var notice: String?
    @State private var saved = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                GeometryReader { geo in
                    let size = fit(videoAspect, geo.size)
                    let bubbleSide = size.width * bubbleSize
                    ZStack(alignment: .topLeading) {
                        VideoPlayer(player: player).disabled(true)
                            .frame(width: size.width, height: size.height)
                        ZStack(alignment: .top) {
                            CameraPreview(session: cam.session, mirrored: cam.isFront)
                                .frame(width: bubbleSide, height: bubbleSide)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Color.white, lineWidth: 3))
                                .shadow(radius: 6)
                                .gesture(DragGesture().onChanged { g in
                                    if dragStart == nil { dragStart = bubbleCenter }
                                    guard let s = dragStart else { return }
                                    bubbleCenter = CGPoint(
                                        x: min(1, max(0, s.x + g.translation.width / size.width)),
                                        y: min(1, max(0, s.y + g.translation.height / size.height))
                                    )
                                }.onEnded { _ in dragStart = nil })
                            // Camera flip on top of the bubble (Android uses double-tap).
                            Button {
                                SoundFx.tick()
                                cam.switchCamera()
                            } label: {
                                Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(8)
                                    .background(.black.opacity(0.55), in: Circle())
                                    .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L("ios_facecam_switch"))
                            .disabled(recording || !cam.ready || cam.switching)
                            .opacity(recording ? 0.35 : 1)
                            .offset(y: -6)
                        }
                        .frame(width: bubbleSide, height: bubbleSide)
                        .position(x: bubbleCenter.x * size.width, y: bubbleCenter.y * size.height)
                    }
                    .frame(width: size.width, height: size.height)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
                HStack {
                    Image(systemName: "circle.circle")
                    Slider(value: $bubbleSize, in: 0.18...0.5).tint(Brand.accent)
                }
                .padding(.horizontal, 20)
                .disabled(recording)

                Text(L("ios_facecam_hint")).font(.caption).foregroundStyle(Brand.textMuted)
                    .multilineTextAlignment(.center).padding(.horizontal)

                Button { recording ? stop() : start() } label: {
                    Label(recording ? L("action_stop") : L("action_record"),
                          systemImage: recording ? "stop.fill" : "record.circle")
                }
                .buttonStyle(PrimaryButtonStyle(color: recording ? Brand.record : Brand.primary))
                .padding(.horizontal, 20)
                .disabled(!cam.ready)
            }
            .padding(.vertical, 10)
            .navigationTitle(L("tool_facecam"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { cam.stopSession(); player.pause(); Router.shared.closeFeature() } label: { Image(systemName: "xmark") }
                }
            }
        }
        .toast($notice)
        .overlay { if let busy { WorkingOverlay(message: busy, progress: progress) } }
        .task {
            let info = await Task.detached { [videoURL] in VideoMeta.read(videoURL) }.value
            if info.size.height > 0 { videoAspect = info.size.width / info.size.height }
            player.replaceCurrentItem(with: AVPlayerItem(url: videoURL))
            await cam.configure()
            if !cam.ready { notice = L("facecam_camera_required") }
        }
        .onDisappear { cam.stopSession(); player.pause() }
        .alert(L("trim_saved_title"), isPresented: $saved) {
            Button(L("done"), role: .cancel) { Router.shared.closeFeature() }
        } message: { Text(L("ios_export_saved_body")) }
    }

    private func fit(_ aspect: CGFloat, _ box: CGSize) -> CGSize {
        box.width / max(1, box.height) > aspect
            ? CGSize(width: box.height * aspect, height: box.height)
            : CGSize(width: box.width, height: box.width / aspect)
    }

    private func start() {
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .videoRecording,
                                                         options: [.defaultToSpeaker, .allowBluetoothA2DP])
        player.seek(to: .zero)
        recording = true
        cam.startRecording()
        player.play()
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                               object: player.currentItem, queue: .main) { _ in
            if recording { stop() }
        }
    }

    private func stop() {
        recording = false
        player.pause()
        let center = bubbleCenter, size = bubbleSize
        cam.stopRecording { cameraURL, offset in
            guard let cameraURL else { notice = L("camera_unavailable"); return }
            Task { @MainActor in
                busy = L("exporting")
                progress = 0
                do {
                    let out = try await FacecamComposer.export(main: videoURL, camera: cameraURL,
                                                               cameraOffset: offset, center: center, size: size) { p in
                        Task { @MainActor in progress = p }
                    }
                    _ = await MediaLibrary.shared.addVideo(from: out, move: true, prefix: "Facecam")
                    Engagement.shared.onEditCompleted()
                    busy = nil; progress = nil
                    saved = true
                } catch {
                    busy = nil; progress = nil
                    notice = L("export_failed")
                }
                try? FileManager.default.removeItem(at: cameraURL)
            }
        }
    }
}

/// Front / back camera + mic into a movie file.
@MainActor
final class FacecamCamera: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "facecam.session")
    /// Only touched on `queue`.
    private var videoInput: AVCaptureDeviceInput?
    @Published private(set) var ready = false
    @Published private(set) var isFront = true
    @Published private(set) var switching = false
    private var requestedAt = Date()
    private var startedAt: Date?
    private var completion: ((URL?, TimeInterval) -> Void)?

    func configure() async {
        guard await AVCaptureDevice.requestAccess(for: .video) else { return }
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        let ok = await installCamera(position: .front, includeMic: true)
        ready = ok
        isFront = true
    }

    /// Flip between front and back — same as Android Facecam double-tap flip.
    func switchCamera() {
        guard ready, !switching, !output.isRecording else { return }
        let next: AVCaptureDevice.Position = isFront ? .back : .front
        switching = true
        Task {
            let ok = await installCamera(position: next, includeMic: false)
            if ok { isFront = next == .front }
            switching = false
        }
    }

    private func installCamera(position: AVCaptureDevice.Position, includeMic: Bool) async -> Bool {
        let session = self.session, output = self.output
        return await withCheckedContinuation { cont in
            queue.async {
                session.beginConfiguration()
                if includeMic { session.sessionPreset = .high }
                if let current = self.videoInput {
                    session.removeInput(current)
                    self.videoInput = nil
                }
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
                        ?? AVCaptureDevice.default(for: .video),
                      let input = try? AVCaptureDeviceInput(device: device),
                      session.canAddInput(input) else {
                    session.commitConfiguration()
                    cont.resume(returning: false)
                    return
                }
                session.addInput(input)
                self.videoInput = input
                if includeMic {
                    if let mic = AVCaptureDevice.default(for: .audio),
                       let micIn = try? AVCaptureDeviceInput(device: mic), session.canAddInput(micIn) {
                        session.addInput(micIn)
                    }
                    if session.canAddOutput(output) { session.addOutput(output) }
                }
                if let conn = output.connection(with: .video) {
                    if conn.isVideoMirroringSupported {
                        conn.automaticallyAdjustsVideoMirroring = false
                        conn.isVideoMirrored = position == .front
                    }
                    if conn.isVideoOrientationSupported { conn.videoOrientation = .portrait }
                }
                session.commitConfiguration()
                if includeMic, !session.isRunning { session.startRunning() }
                cont.resume(returning: true)
            }
        }
    }

    func startRecording() {
        let url = MediaLibrary.tempURL(ext: "mov")
        requestedAt = Date()
        startedAt = nil
        let output = self.output
        queue.async { output.startRecording(to: url, recordingDelegate: self) }
    }

    func stopRecording(_ done: @escaping (URL?, TimeInterval) -> Void) {
        completion = done
        let output = self.output
        queue.async { output.stopRecording() }
    }

    func stopSession() {
        let session = self.session
        queue.async { if session.isRunning { session.stopRunning() } }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL,
                                from connections: [AVCaptureConnection]) {
        Task { @MainActor in self.startedAt = Date() }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection], error: Error?) {
        Task { @MainActor in
            // How late the camera started relative to the video starting to play.
            let offset = max(0, (self.startedAt ?? self.requestedAt).timeIntervalSince(self.requestedAt))
            let ok = error == nil || FileManager.default.fileExists(atPath: outputFileURL.path)
            self.completion?(ok ? outputFileURL : nil, offset)
            self.completion = nil
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var mirrored: Bool = true

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.preview.session = session
        v.preview.videoGravity = .resizeAspectFill
        v.backgroundColor = .darkGray
        applyMirror(v.preview)
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        applyMirror(uiView.preview)
    }

    private func applyMirror(_ layer: AVCaptureVideoPreviewLayer) {
        guard let conn = layer.connection, conn.isVideoMirroringSupported else { return }
        conn.automaticallyAdjustsVideoMirroring = false
        conn.isVideoMirrored = mirrored
    }
}

// MARK: - Compositing

final class PiPInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let mainID: CMPersistentTrackID
    let camID: CMPersistentTrackID
    let mainTransform: CGAffineTransform
    let camTransform: CGAffineTransform
    let center: CGPoint
    let size: CGFloat
    let renderSize: CGSize

    init(range: CMTimeRange, mainID: CMPersistentTrackID, camID: CMPersistentTrackID,
         mainTransform: CGAffineTransform, camTransform: CGAffineTransform,
         center: CGPoint, size: CGFloat, renderSize: CGSize) {
        timeRange = range
        requiredSourceTrackIDs = [NSNumber(value: mainID), NSNumber(value: camID)]
        self.mainID = mainID; self.camID = camID
        self.mainTransform = mainTransform; self.camTransform = camTransform
        self.center = center; self.size = size; self.renderSize = renderSize
    }
}

final class PiPCompositor: NSObject, AVVideoCompositing {
    private var context: AVVideoCompositionRenderContext?
    private let queue = DispatchQueue(label: "pip.compositor")

    var sourcePixelBufferAttributes: [String: Any]? {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]]
    }
    var requiredPixelBufferAttributesForRenderContext: [String: Any] {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        queue.sync { context = newRenderContext }
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async {
            guard let ins = request.videoCompositionInstruction as? PiPInstruction,
                  let out = self.context?.newPixelBuffer(),
                  let mainBuf = request.sourceFrame(byTrackID: ins.mainID) else {
                request.finish(with: NSError(domain: "PiP", code: -1)); return
            }
            let rect = CGRect(origin: .zero, size: ins.renderSize)
            let main = FramePipeline.upright(CIImage(cvPixelBuffer: mainBuf), transform: ins.mainTransform)
            var frame = FramePipeline.fit(main, into: rect, canvas: "black")

            if let camBuf = request.sourceFrame(byTrackID: ins.camID) {
                var cam = FramePipeline.upright(CIImage(cvPixelBuffer: camBuf), transform: ins.camTransform)
                let side = min(cam.extent.width, cam.extent.height)
                cam = FramePipeline.normalized(cam.cropped(to: CGRect(x: (cam.extent.width - side) / 2,
                                                                       y: (cam.extent.height - side) / 2,
                                                                       width: side, height: side)))
                let d = ins.size * ins.renderSize.width
                cam = cam.transformed(by: CGAffineTransform(scaleX: d / side, y: d / side))
                let r = d / 2
                let mask = CIFilter(name: "CIRadialGradient", parameters: [
                    "inputCenter": CIVector(x: r, y: r), "inputRadius0": r - 1.5, "inputRadius1": r,
                    "inputColor0": CIColor.white, "inputColor1": CIColor.clear
                ])?.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: d, height: d))
                if let mask {
                    // Soft 1.5 px edge; corners outside the circle stay transparent.
                    let bubble = cam.applyingFilter("CIBlendWithMask", parameters: [
                        kCIInputBackgroundImageKey: CIImage.empty(),
                        kCIInputMaskImageKey: mask])
                    let x = ins.center.x * ins.renderSize.width - r
                    let y = (1 - ins.center.y) * ins.renderSize.height - r
                    frame = bubble.transformed(by: CGAffineTransform(translationX: x, y: y)).composited(over: frame)
                }
            }
            FramePipeline.context.render(frame.cropped(to: rect), to: out, bounds: rect,
                                         colorSpace: FramePipeline.workingSpace)
            request.finish(withComposedVideoFrame: out)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}
}

enum FacecamComposer {
    static func export(main: URL, camera: URL, cameraOffset: TimeInterval, center: CGPoint, size: CGFloat,
                       progress: @escaping (Double) -> Void) async throws -> URL {
        let mainAsset = AVURLAsset(url: main)
        let camAsset = AVURLAsset(url: camera)
        guard let mv = try await mainAsset.loadTracks(withMediaType: .video).first,
              let cv = try await camAsset.loadTracks(withMediaType: .video).first else {
            throw Exporter.Failure.failed("tracks")
        }
        let composition = AVMutableComposition()
        let mainDur = try await mainAsset.load(.duration)
        let camDur = try await camAsset.load(.duration)
        let offset = CMTime(seconds: cameraOffset, preferredTimescale: 600)
        let total = min(mainDur, CMTimeAdd(camDur, offset))

        guard let tMain = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let tCam = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw Exporter.Failure.failed("composition") }
        try tMain.insertTimeRange(CMTimeRange(start: .zero, duration: total), of: mv, at: .zero)
        try tCam.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeSubtract(total, offset)), of: cv, at: offset)

        for a in try await mainAsset.loadTracks(withMediaType: .audio) {
            let t = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            try? t?.insertTimeRange(CMTimeRange(start: .zero, duration: total), of: a, at: .zero)
        }
        for a in try await camAsset.loadTracks(withMediaType: .audio) {
            let t = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            try? t?.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeSubtract(total, offset)), of: a, at: offset)
        }

        let mainSize = await ProjectBuilder.uprightSize(main) ?? CGSize(width: 720, height: 1280)
        let renderSize = FramePipeline.renderSize(content: mainSize, ratio: .original, maxShortEdge: 1080)
        let mainT = try await mv.load(.preferredTransform)
        let camT = try await cv.load(.preferredTransform)

        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = PiPCompositor.self
        vc.renderSize = renderSize
        vc.frameDuration = CMTime(value: 1, timescale: 30)
        // Before the camera starts, a camera-less instruction would need a different
        // track list; the camera track simply has no frame there, which the compositor handles.
        vc.instructions = [PiPInstruction(range: CMTimeRange(start: .zero, duration: total),
                                          mainID: tMain.trackID, camID: tCam.trackID,
                                          mainTransform: mainT, camTransform: camT,
                                          center: center, size: size, renderSize: renderSize)]
        let out = MediaLibrary.tempURL(ext: "mp4")
        try await Exporter.run(asset: composition, videoComposition: vc, audioMix: nil,
                               preset: AVAssetExportPresetHighestQuality, to: out, timeRange: nil, progress: progress)
        return out
    }
}
