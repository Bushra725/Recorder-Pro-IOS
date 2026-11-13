import ActivityKit
import AVFoundation
import ReplayKit
import SwiftUI
import UIKit

/// App-side half of recording. Port of Android's RecorderState + the parts of
/// RecorderService / ProjectionRequestActivity that live in the UI process.
///
/// Starting a capture = write the settings to the App Group, then open the
/// system broadcast sheet with our extension pre-selected. Pause / resume /
/// stop / screenshot are Darwin notifications to the extension.
@MainActor
final class RecordingController: ObservableObject {
    static let shared = RecordingController()

    @Published private(set) var status: LiveStatus = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published var notice: String?

    private let events = DarwinObserver()
    private var ticker: Timer?
    private var picker: RPSystemBroadcastPickerView?

    private init() {
        events.observe(.started) { [weak self] in self?.onStarted() }
        events.observe(.stateChanged) { [weak self] in self?.sync() }
        events.observe(.finished) { [weak self] in self?.onFinished() }
        events.observe(.screenshotSaved) { PostProcessor.shared.collect() }
    }

    var isBusy: Bool { status != .idle }

    // MARK: - Start

    /// Opens the system broadcast sheet. `limitSeconds` > 0 is a timed
    /// recording; `region` (normalised) crops the result afterwards.
    func start(limitSeconds: Int = 0, region: CGRect? = nil) {
        Prefs.shared.publishCaptureSettings(limitSeconds: limitSeconds, region: region)
        AdsManager.shared.suppressAppOpenBriefly(60)
        presentBroadcastPicker()
    }

    private func presentBroadcastPicker() {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow) else { return }
        let p = picker ?? RPSystemBroadcastPickerView(frame: CGRect(x: -100, y: -100, width: 44, height: 44))
        p.preferredExtension = AppConfig.broadcastExtensionID
        // The mic switch lives on the system sheet; the user's audio choice decides
        // whether the extension keeps those samples.
        p.showsMicrophoneButton = true
        p.alpha = 0.011
        if p.superview == nil { window.addSubview(p) }
        picker = p
        // The picker exposes no API to open itself; tapping its button is the
        // documented-by-practice way, used by every iOS screen recorder.
        for case let button as UIButton in p.subviews {
            button.sendActions(for: .touchUpInside)
            button.sendActions(for: .allTouchEvents)
            break
        }
    }

    // MARK: - Controls

    func pause() { DarwinEvent.pause.post(); Task { await RecordingActivityUpdater.apply(paused: true) } }
    func resume() { DarwinEvent.resume.post(); Task { await RecordingActivityUpdater.apply(paused: false) } }
    func stop() {
        DarwinEvent.stop.post()
        SoundFx.recordStop()
        Task { await RecordingActivityUpdater.endAll() }
    }
    func screenshot() { DarwinEvent.screenshot.post(); SoundFx.shutter() }

    // MARK: - State

    /// Reconcile with the extension. Called on launch, on foreground and on pings.
    func sync() {
        var s = LiveClock.status
        if s != .idle && !LiveClock.isExtensionAlive {
            // Heartbeat stopped: the extension was killed. Whatever it wrote
            // is picked up by the post-processor (auto repair).
            s = .idle
            AppGroup.defaults.set(LiveStatus.idle.rawValue, forKey: SharedKeys.liveStatus)
        }
        let was = status
        status = s
        elapsed = LiveClock.elapsed()
        if s == .idle {
            ticker?.invalidate(); ticker = nil
            Task { await RecordingActivityUpdater.endAll() }
            if was != .idle { PostProcessor.shared.collect() }
        } else if ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.elapsed = LiveClock.elapsed() }
            }
        }
    }

    private func onStarted() {
        SoundFx.recordStart()
        sync()
        if !Prefs.shared.hideToasts { notice = L("toast_recording_started") }
        picker?.removeFromSuperview()
        picker = nil
        startLiveActivity()
    }

    private func onFinished() {
        sync()
        PostProcessor.shared.collect()
    }

    private func startLiveActivity() {
        guard #available(iOS 16.2, *),
              Prefs.shared.liveControls, !Prefs.shared.isAdvancedCapture,
              ActivityAuthorizationInfo().areActivitiesEnabled,
              Activity<RecordingActivityAttributes>.activities.isEmpty else { return }
        let elapsed = LiveClock.elapsed()
        let state = RecordingActivityAttributes.ContentState(
            effectiveStart: Date().addingTimeInterval(-elapsed),
            paused: false, pausedElapsed: 0,
            limitSeconds: AppGroup.defaults.integer(forKey: SharedKeys.pendingLimitSeconds))
        _ = try? Activity.request(attributes: RecordingActivityAttributes(appName: L("app_name")),
                                  content: ActivityContent(state: state, staleDate: nil),
                                  pushType: nil)
    }
}
