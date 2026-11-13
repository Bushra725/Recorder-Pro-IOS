import Foundation
import CoreGraphics

/// Everything the app, the Broadcast Upload Extension and the Live Activity
/// widget have to agree on. Compiled into all three targets.
///
/// The broadcast extension is a separate process with a 50 MB memory ceiling.
/// It cannot see the app's UserDefaults or Documents folder, so the two talk
/// through the App Group container (files + a shared UserDefaults suite) and
/// Darwin notifications (fire-and-forget pings between processes).
enum AppGroup {
    static let id = "group.com.ol.mob.screen.recorder.app"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: id) ?? .standard
    }

    static var container: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
            ?? FileManager.default.temporaryDirectory
    }

    /// Finished captures land here; the app's PostProcessor moves them into the library.
    static var inbox: URL {
        let url = container.appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Screenshots taken from inside a running broadcast.
    static var screenshotInbox: URL {
        let url = container.appendingPathComponent("ScreenshotInbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// UserDefaults keys shared across processes. The app's `Prefs` writes these,
/// the extension reads them at `broadcastStarted`.
enum SharedKeys {
    // capture settings
    static let resolution = "res"            // short edge px, 0 = native
    static let fps = "fps"
    static let bitrate = "bitrate"
    static let audioSource = "audio"         // MUTE | MIC | INTERNAL | MIC_AND_INTERNAL
    static let orientation = "orient"        // AUTO | PORTRAIT
    static let recordingMode = "rec_mode"    // NORMAL | ADVANCED
    static let countdown = "countdown"
    static let shakeToStop = "shake"
    static let autoRepair = "auto_repair"

    // per-recording request, written right before the broadcast picker opens
    static let pendingLimitSeconds = "pending_limit_s"
    static let pendingRegion = "pending_region"     // "x,y,w,h" normalised, or ""
    static let pendingRequestedAt = "pending_req_at"

    // live state, written by the extension
    static let liveStatus = "live_status"           // idle | recording | paused
    static let liveStartedAt = "live_started_at"    // epoch seconds
    static let livePausedTotal = "live_paused_total"
    static let livePausedAt = "live_paused_at"
    static let liveHeartbeat = "live_heartbeat"
}

enum LiveStatus: String {
    case idle, recording, paused
}

/// Cross-process pings. Darwin notifications carry no payload; the payload,
/// if any, is in the shared defaults.
enum DarwinEvent: String, CaseIterable {
    // app -> extension
    case pause = "com.ol.mob.screen.recorder.app.pause"
    case resume = "com.ol.mob.screen.recorder.app.resume"
    case stop = "com.ol.mob.screen.recorder.app.stop"
    case screenshot = "com.ol.mob.screen.recorder.app.screenshot"
    // extension -> app
    case started = "com.ol.mob.screen.recorder.app.started"
    case finished = "com.ol.mob.screen.recorder.app.finished"
    case stateChanged = "com.ol.mob.screen.recorder.app.statechanged"
    case screenshotSaved = "com.ol.mob.screen.recorder.app.shotsaved"

    func post() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(rawValue as CFString),
            nil, nil, true
        )
    }
}

/// Small helper that turns Darwin notifications into closures.
final class DarwinObserver {
    private var handlers: [String: () -> Void] = [:]

    func observe(_ event: DarwinEvent, _ handler: @escaping () -> Void) {
        handlers[event.rawValue] = handler
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            { _, observer, name, _, _ in
                guard let observer, let name else { return }
                let me = Unmanaged<DarwinObserver>.fromOpaque(observer).takeUnretainedValue()
                let key = name.rawValue as String
                DispatchQueue.main.async { me.handlers[key]?() }
            },
            event.rawValue as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque()
        )
    }
}

/// Sidecar written next to every finished capture so the app knows how to
/// post-process it (region crop, rotation, what the user asked for).
struct CaptureSidecar: Codable {
    var fileName: String
    var durationMs: Int64
    var region: String          // "" or "x,y,w,h" normalised
    var rotationDeg: Int        // clockwise rotation to make it upright
    var audioTracks: Int
    var finishedCleanly: Bool
    var createdAt: Date
}

enum SharedFormat {
    static func stamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: date)
    }

    static func region(from string: String) -> CGRect? {
        let parts = string.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4, parts[2] > 0.02, parts[3] > 0.02 else { return nil }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    static func string(from region: CGRect?) -> String {
        guard let r = region else { return "" }
        return String(format: "%.4f,%.4f,%.4f,%.4f", r.minX, r.minY, r.width, r.height)
    }
}
