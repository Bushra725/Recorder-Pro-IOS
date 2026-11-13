import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif
#if canImport(AppIntents)
import AppIntents
#endif

/// The iOS stand-in for Android's floating ball, recording HUD and the
/// notification control bar. iOS does not let an app draw over other apps, so
/// the controls live on the Lock Screen and in the Dynamic Island instead.
///
/// Compiled into the app (which starts / updates / ends the activity) and the
/// widget extension (which draws it).
#if canImport(ActivityKit)
@available(iOS 16.1, *)
struct RecordingActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// Wall-clock start shifted forward by the time spent paused, so
        /// `Text(timerInterval:)` keeps counting correctly without updates.
        var effectiveStart: Date
        var paused: Bool
        /// Frozen elapsed seconds while paused.
        var pausedElapsed: TimeInterval
        var limitSeconds: Int
    }

    var appName: String
}
#endif

/// Elapsed recording time, excluding pauses, read from the shared defaults.
enum LiveClock {
    static func elapsed(now: Date = Date()) -> TimeInterval {
        let d = AppGroup.defaults
        let started = d.double(forKey: SharedKeys.liveStartedAt)
        guard started > 0 else { return 0 }
        let pausedTotal = d.double(forKey: SharedKeys.livePausedTotal)
        let pausedAt = d.double(forKey: SharedKeys.livePausedAt)
        let end = pausedAt > 0 ? pausedAt : now.timeIntervalSince1970
        return max(0, end - started - pausedTotal)
    }

    static var status: LiveStatus {
        LiveStatus(rawValue: AppGroup.defaults.string(forKey: SharedKeys.liveStatus) ?? "") ?? .idle
    }

    /// True when the extension wrote a heartbeat in the last few seconds.
    /// Protects against a stale "recording" flag left behind by a crashed extension.
    static var isExtensionAlive: Bool {
        let beat = AppGroup.defaults.double(forKey: SharedKeys.liveHeartbeat)
        return beat > 0 && Date().timeIntervalSince1970 - beat < 6
    }
}

#if canImport(AppIntents) && canImport(ActivityKit)
// MARK: - Buttons on the Live Activity (iOS 17+)
//
// A LiveActivityIntent's perform() runs inside the app's process, even when the
// app is in the background, so it can talk to the extension over Darwin
// notifications and update the activity itself.

@available(iOS 17.0, *)
struct TogglePauseRecordingIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "action_pause"
    static var isDiscoverable: Bool = false

    init() {}

    func perform() async throws -> some IntentResult {
        let paused = LiveClock.status == .paused
        (paused ? DarwinEvent.resume : DarwinEvent.pause).post()
        await RecordingActivityUpdater.apply(paused: !paused)
        return .result()
    }
}

@available(iOS 17.0, *)
struct StopRecordingIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "action_stop"
    static var isDiscoverable: Bool = false

    init() {}

    func perform() async throws -> some IntentResult {
        DarwinEvent.stop.post()
        await RecordingActivityUpdater.endAll()
        return .result()
    }
}

@available(iOS 17.0, *)
struct ScreenshotDuringRecordingIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "action_screenshot"
    static var isDiscoverable: Bool = false

    init() {}

    func perform() async throws -> some IntentResult {
        DarwinEvent.screenshot.post()
        return .result()
    }
}
#endif

#if canImport(ActivityKit)
enum RecordingActivityUpdater {
    static func apply(paused: Bool) async {
        guard #available(iOS 16.2, *) else { return }
        let elapsed = LiveClock.elapsed()
        for activity in Activity<RecordingActivityAttributes>.activities {
            var state = activity.content.state
            state.paused = paused
            state.pausedElapsed = elapsed
            state.effectiveStart = Date().addingTimeInterval(-elapsed)
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    static func endAll() async {
        guard #available(iOS 16.2, *) else { return }
        for activity in Activity<RecordingActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
#endif
