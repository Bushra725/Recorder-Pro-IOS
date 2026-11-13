import Foundation
import Combine
import CoreGraphics

/// Port of Android's `core/Prefs.kt`. Every user-facing setting lives here.
///
/// Stored in the App Group suite so the Broadcast Upload Extension reads the
/// capture settings (resolution, fps, audio …) at the moment a recording starts.
final class Prefs: ObservableObject {
    static let shared = Prefs()

    let d = AppGroup.defaults

    // MARK: constants
    static let audioMute = "MUTE"
    static let audioMic = "MIC"
    static let audioInternal = "INTERNAL"
    static let audioBoth = "MIC_AND_INTERNAL"

    static let orientAuto = "AUTO"
    static let orientPortrait = "PORTRAIT"

    static let themeLight = "LIGHT"
    static let themeDark = "DARK"
    static let themeSystem = "SYSTEM"

    static let modeNormal = "NORMAL"
    static let modeAdvanced = "ADVANCED"

    static let onboardingRevision = 2
    static let rewardAdsNeeded = 3
    static let rewardUnlockSeconds: TimeInterval = 24 * 60 * 60

    static func isPremiumResolution(_ v: Int) -> Bool { v == 0 || v > 720 }

    private init() {
        d.register(defaults: [
            SharedKeys.resolution: 720,
            SharedKeys.fps: 30,
            SharedKeys.bitrate: 8_000_000,
            SharedKeys.audioSource: Prefs.audioMute,
            SharedKeys.orientation: Prefs.orientAuto,
            SharedKeys.countdown: 3,
            SharedKeys.recordingMode: Prefs.modeNormal,
            SharedKeys.autoRepair: true,
            "trash": true,
            "theme": Prefs.themeSystem,
            "sound_fx": true,
            "haptics": true,
            "save_gallery": true,
            "live_controls": true,
            "captions_lang": "en"
        ])
    }

    private func store(_ value: Any?, _ key: String) {
        objectWillChange.send()
        d.set(value, forKey: key)
    }

    // MARK: capture

    /// Short-edge px: 480, 720, 1080, 1440, or 0 = native. 1080p+ needs a purchase.
    var resolution: Int {
        get { d.integer(forKey: SharedKeys.resolution) }
        set {
            if !isPro && Prefs.isPremiumResolution(newValue) { return }
            store(newValue, SharedKeys.resolution)
            bitrate = Prefs.bitrate(forResolution: newValue)
        }
    }

    static func bitrate(forResolution v: Int) -> Int {
        switch v {
        case 480: return 3_000_000
        case 720: return 8_000_000
        case 1080: return 14_000_000
        case 1440: return 24_000_000
        default: return 16_000_000
        }
    }

    var fps: Int {
        get { d.integer(forKey: SharedKeys.fps) }
        set { if newValue > 30 && !hasProAccess { return }; store(newValue, SharedKeys.fps) }
    }

    var bitrate: Int {
        get { d.integer(forKey: SharedKeys.bitrate) }
        set { store(newValue, SharedKeys.bitrate) }
    }

    var audioSource: String {
        get { d.string(forKey: SharedKeys.audioSource) ?? Prefs.audioMute }
        set { store(newValue, SharedKeys.audioSource) }
    }

    var orientation: String {
        get { d.string(forKey: SharedKeys.orientation) ?? Prefs.orientAuto }
        set { store(newValue, SharedKeys.orientation) }
    }

    var countdown: Int {
        get { d.integer(forKey: SharedKeys.countdown) }
        set { store(newValue, SharedKeys.countdown) }
    }

    var shakeToStop: Bool {
        get { d.bool(forKey: SharedKeys.shakeToStop) }
        set { store(newValue, SharedKeys.shakeToStop) }
    }

    /// NORMAL keeps the Lock Screen / Dynamic Island controls and H.264.
    /// ADVANCED hides them and records HEVC (sharper at the same bitrate).
    var recordingMode: String {
        get { d.string(forKey: SharedKeys.recordingMode) == Prefs.modeAdvanced ? Prefs.modeAdvanced : Prefs.modeNormal }
        set { store(newValue, SharedKeys.recordingMode) }
    }

    var isAdvancedCapture: Bool { recordingMode == Prefs.modeAdvanced }

    var autoRepair: Bool {
        get { d.bool(forKey: SharedKeys.autoRepair) }
        set { store(newValue, SharedKeys.autoRepair) }
    }

    /// iOS replacement for Android's floating ball + notification control bar.
    var liveControls: Bool {
        get { d.bool(forKey: "live_controls") }
        set { store(newValue, "live_controls") }
    }

    var hideResultPopup: Bool {
        get { d.bool(forKey: "hide_result") }
        set { store(newValue, "hide_result") }
    }

    var hideToasts: Bool {
        get { d.bool(forKey: "hide_toast") }
        set { store(newValue, "hide_toast") }
    }

    var trashEnabled: Bool {
        get { d.bool(forKey: "trash") }
        set { store(newValue, "trash") }
    }

    var theme: String {
        get { d.string(forKey: "theme") ?? Prefs.themeSystem }
        set { store(newValue, "theme") }
    }

    var saveToGallery: Bool {
        get { d.bool(forKey: "save_gallery") }
        set { store(newValue, "save_gallery") }
    }

    var captionsLanguage: String {
        get { d.string(forKey: "captions_lang") ?? "en" }
        set { store(newValue, "captions_lang") }
    }

    // MARK: watermark

    /// Forced on for free users. PRO defaults to off.
    var watermark: Bool {
        get { hasProAccess ? d.bool(forKey: "watermark") : true }
        set {
            if !newValue && !hasProAccess { return }
            store(newValue, "watermark")
        }
    }

    var watermarkText: String {
        get { d.string(forKey: "watermark_text") ?? "" }
        set { store(newValue, "watermark_text") }
    }

    var watermarkLabel: String {
        let t = watermarkText.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? L("app_name") : t
    }

    // MARK: onboarding & feedback

    var onboardingDone: Bool {
        get { d.bool(forKey: "onboarded") && d.integer(forKey: "onboard_rev") >= Prefs.onboardingRevision }
        set {
            store(newValue, "onboarded")
            store(Prefs.onboardingRevision, "onboard_rev")
        }
    }

    var soundEffects: Bool {
        get { d.bool(forKey: "sound_fx") }
        set { store(newValue, "sound_fx") }
    }

    var haptics: Bool {
        get { d.bool(forKey: "haptics") }
        set { store(newValue, "haptics") }
    }

    var firstRecordPromptShown: Bool {
        get { d.bool(forKey: "first_prompt") }
        set { store(newValue, "first_prompt") }
    }

    var reviewRequested: Bool {
        get { d.bool(forKey: "rated") }
        set { store(newValue, "rated") }
    }

    // MARK: monetisation (written by Entitlements / AdsManager)

    /// True only while StoreKit reports an active subscription or the lifetime purchase.
    var isPro: Bool {
        get { d.bool(forKey: "pro") }
        set { store(newValue, "pro") }
    }

    var proSku: String {
        get { d.string(forKey: "pro_sku") ?? "" }
        set { store(newValue, "pro_sku") }
    }

    /// Epoch seconds until which a rewarded / daily-bonus unlock is valid.
    /// Kept apart from `isPro` so a store refresh can never revoke an earned unlock.
    var rewardUnlockUntil: TimeInterval {
        get { d.double(forKey: "reward_until") }
        set { store(newValue, "reward_until") }
    }

    var rewardProgress: Int {
        get { d.integer(forKey: "reward_progress") }
        set { store(newValue, "reward_progress") }
    }

    var hasProAccess: Bool {
        isPro || rewardUnlockUntil > Date().timeIntervalSince1970
    }

    /// 1080p, 2K and native are tied to a purchase, not a trial.
    var captureResolution: Int {
        let v = d.integer(forKey: SharedKeys.resolution)
        return !isPro && Prefs.isPremiumResolution(v) ? 720 : v
    }

    // MARK: engagement

    var totalRecordings: Int {
        get { d.integer(forKey: "total_rec") }
        set { store(newValue, "total_rec") }
    }

    var totalRecordedMs: Int64 {
        get { Int64(d.double(forKey: "total_ms")) }
        set { store(Double(newValue), "total_ms") }
    }

    var streakDays: Int {
        get { d.integer(forKey: "streak") }
        set { store(newValue, "streak") }
    }

    var bestStreakDays: Int {
        get { d.integer(forKey: "best_streak") }
        set { store(newValue, "best_streak") }
    }

    var lastActiveDay: Int {
        get { d.integer(forKey: "last_day") }
        set { store(newValue, "last_day") }
    }

    var lastDailyClaimDay: Int {
        get { d.integer(forKey: "daily_claim") }
        set { store(newValue, "daily_claim") }
    }

    var achievements: Set<String> {
        get { Set(d.stringArray(forKey: "achievements") ?? []) }
        set { store(Array(newValue), "achievements") }
    }

    var editsCompleted: Int {
        get { d.integer(forKey: "edits_done") }
        set { store(newValue, "edits_done") }
    }

    /// Before each capture: push the effective (entitlement-checked) settings
    /// where the extension will read them.
    func publishCaptureSettings(limitSeconds: Int, region: CGRect?) {
        // The extension reads SharedKeys.resolution; keep it entitlement-safe.
        if !isPro && Prefs.isPremiumResolution(d.integer(forKey: SharedKeys.resolution)) {
            d.set(720, forKey: SharedKeys.resolution)
        }
        if !hasProAccess && fps > 30 { d.set(30, forKey: SharedKeys.fps) }
        d.set(limitSeconds, forKey: SharedKeys.pendingLimitSeconds)
        d.set(SharedFormat.string(from: region), forKey: SharedKeys.pendingRegion)
        d.set(Date().timeIntervalSince1970, forKey: SharedKeys.pendingRequestedAt)
    }
}
