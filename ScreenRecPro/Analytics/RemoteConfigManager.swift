import FirebaseRemoteConfig
import Foundation

/// Firebase Remote Config for production kill-switches and monetisation knobs.
/// Defaults match the hard-coded Android / iOS behaviour so a failed fetch
/// never changes the product.
@MainActor
final class RemoteConfigManager: ObservableObject {
    static let shared = RemoteConfigManager()

    private let rc = RemoteConfig.remoteConfig()
    @Published private(set) var ready = false

    // Keys — create matching parameters in Firebase Console › Remote Config.
    enum Key {
        static let adsEnabled = "ads_enabled"
        static let appOpenEnabled = "app_open_enabled"
        static let interstitialExitInterval = "interstitial_exit_interval"
        static let rewardAdsNeeded = "reward_ads_needed"
        static let rewardUnlockHours = "reward_unlock_hours"
        static let minAppVersion = "min_app_version"
        static let paywallSoftPrompt = "paywall_soft_prompt"
    }

    var adsEnabled: Bool { rc[Key.adsEnabled].boolValue }
    var appOpenEnabled: Bool { rc[Key.appOpenEnabled].boolValue }
    var interstitialExitInterval: Int {
        max(1, rc[Key.interstitialExitInterval].numberValue.intValue)
    }
    var rewardAdsNeeded: Int {
        max(1, rc[Key.rewardAdsNeeded].numberValue.intValue)
    }
    var rewardUnlockHours: Int {
        max(1, rc[Key.rewardUnlockHours].numberValue.intValue)
    }
    var minAppVersion: String { rc[Key.minAppVersion].stringValue }
    var paywallSoftPrompt: Bool { rc[Key.paywallSoftPrompt].boolValue }

    func start() {
        let settings = RemoteConfigSettings()
        #if DEBUG
        settings.minimumFetchInterval = 0
        #else
        settings.minimumFetchInterval = 3_600
        #endif
        rc.configSettings = settings
        rc.setDefaults([
            Key.adsEnabled: true as NSObject,
            Key.appOpenEnabled: true as NSObject,
            Key.interstitialExitInterval: 2 as NSObject,
            Key.rewardAdsNeeded: 3 as NSObject,
            Key.rewardUnlockHours: 24 as NSObject,
            Key.minAppVersion: "1.0.0" as NSObject,
            Key.paywallSoftPrompt: true as NSObject,
        ])
        Task { await fetch() }
    }

    @discardableResult
    func fetch() async -> Bool {
        do {
            let status = try await rc.fetch()
            if status == .success {
                _ = try await rc.activate()
            }
            ready = true
            return true
        } catch {
            ready = true // still usable via defaults
            return false
        }
    }

    /// True when the installed marketing version is below Remote Config's floor.
    var needsUpdate: Bool {
        compareVersion(AppConfig.versionName, isLessThan: minAppVersion)
    }

    private func compareVersion(_ a: String, isLessThan b: String) -> Bool {
        let left = a.split(separator: ".").compactMap { Int($0) }
        let right = b.split(separator: ".").compactMap { Int($0) }
        let n = max(left.count, right.count)
        for i in 0..<n {
            let x = i < left.count ? left[i] : 0
            let y = i < right.count ? right[i] : 0
            if x != y { return x < y }
        }
        return false
    }
}

extension AppConfig {
    /// Marketing version only (`CFBundleShortVersionString`), for Remote Config.
    static var versionName: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }
}
