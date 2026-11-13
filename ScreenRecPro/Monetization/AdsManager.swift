import AppTrackingTransparency
import GoogleMobileAds
import UIKit
import UserMessagingPlatform

/// Port of Android's `ads/AdsManager.kt` + `AppOpenManager.kt`.
///
/// Policy, unchanged from Android:
///  * Interstitials only when the user *leaves* a finished feature (editor,
///    player, photo viewer, trim …) — on every 2nd leave, never before an action.
///  * Rewarded: 3 completed videos → 24 h of PRO. Credit comes only from the
///    SDK's reward callback, never from dismissal.
///  * App-open ad at launch and when returning to the app, at most one
///    full-screen ad every 8 s, never while recording.
///  * PRO users see nothing, checked at every entry point.
@MainActor
final class AdsManager: NSObject, ObservableObject {
    static let shared = AdsManager()

    @Published private(set) var sdkReady = false
    @Published private(set) var rewardedLoading = false

    private var interstitials: [InterstitialAd] = []
    private var rewarded: RewardedAd?
    private var rewardedInterstitial: RewardedInterstitialAd?
    private var appOpen: AppOpenAd?
    private var appOpenLoadedAt: Date?
    private var loadingAppOpen = false

    private var featureExits = 0
    private var adOwed = false
    private var fullscreenShowing = false
    private var lastFullscreenAt = Date.distantPast
    private var suppressUntil = Date.distantPast
    private var pendingDone: (() -> Void)?
    private var rewardEarned = false
    private var rewardCompletion: ((Bool) -> Void)?

    private static let cooldown: TimeInterval = 8
    private static let appOpenMaxAge: TimeInterval = 4 * 60 * 60

    private var adsAllowed: Bool {
        !Prefs.shared.hasProAccess && sdkReady && RemoteConfigManager.shared.adsEnabled
    }

    private var exitsPerInterstitial: Int {
        RemoteConfigManager.shared.interstitialExitInterval
    }

    // MARK: - Start-up: consent (UMP) → ATT → SDK

    func start() {
        let params = RequestParameters()
        ConsentInformation.shared.requestConsentInfoUpdate(with: params) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let vc = UIApplication.topViewController() {
                    ConsentForm.loadAndPresentIfRequired(from: vc) { _ in
                        Task { @MainActor in self.afterConsent() }
                    }
                } else {
                    self.afterConsent()
                }
            }
        }
    }

    private func afterConsent() {
        guard ConsentInformation.shared.canRequestAds else { return }
        // ATT after the consent form, and only once the app is active.
        onMain(after: 0.6) {
            ATTrackingManager.requestTrackingAuthorization { status in
                AdjustTracker.updateTrackingConsent(status)
                Task { @MainActor in self.startSDK() }
            }
        }
    }

    private func startSDK() {
        guard !sdkReady else { return }
        MobileAds.shared.start { [weak self] _ in
            Task { @MainActor in
                self?.sdkReady = true
                self?.preload()
            }
        }
    }

    func preload() {
        guard adsAllowed else { return }
        if interstitials.count < 2 {
            loadInterstitial(AdConfig.interstitial1)
            loadInterstitial(AdConfig.interstitial2)
        }
        if rewarded == nil { loadRewarded() }
        if rewardedInterstitial == nil { loadRewardedInterstitial() }
        if appOpen == nil { loadAppOpen() }
    }

    // MARK: - Loading

    private func loadInterstitial(_ unit: String) {
        InterstitialAd.load(with: unit, request: Request()) { [weak self] ad, _ in
            Task { @MainActor in
                guard let self, let ad else { return }
                ad.fullScreenContentDelegate = self
                ad.paidEventHandler = { value in
                    AdjustTracker.paid(
                        value: value,
                        format: "interstitial",
                        unitId: unit,
                        network: ad.responseInfo.loadedAdNetworkResponseInfo?.adNetworkClassName
                    )
                }
                if self.interstitials.count < 2 { self.interstitials.append(ad) }
            }
        }
    }

    private func loadRewarded() {
        rewardedLoading = true
        RewardedAd.load(with: AdConfig.rewarded, request: Request()) { [weak self] ad, _ in
            Task { @MainActor in
                self?.rewardedLoading = false
                guard let ad else { return }
                ad.fullScreenContentDelegate = self
                ad.paidEventHandler = { value in
                    AdjustTracker.paid(
                        value: value,
                        format: "rewarded",
                        unitId: AdConfig.rewarded,
                        network: ad.responseInfo.loadedAdNetworkResponseInfo?.adNetworkClassName
                    )
                }
                self?.rewarded = ad
            }
        }
    }

    private func loadRewardedInterstitial() {
        RewardedInterstitialAd.load(with: AdConfig.rewardedInterstitial, request: Request()) { [weak self] ad, _ in
            Task { @MainActor in
                guard let ad else { return }
                ad.fullScreenContentDelegate = self
                ad.paidEventHandler = { value in
                    AdjustTracker.paid(
                        value: value,
                        format: "rewarded_interstitial",
                        unitId: AdConfig.rewardedInterstitial,
                        network: ad.responseInfo.loadedAdNetworkResponseInfo?.adNetworkClassName
                    )
                }
                self?.rewardedInterstitial = ad
            }
        }
    }

    private func loadAppOpen() {
        guard !loadingAppOpen else { return }
        loadingAppOpen = true
        AppOpenAd.load(with: AdConfig.appOpen, request: Request()) { [weak self] ad, _ in
            Task { @MainActor in
                guard let self else { return }
                self.loadingAppOpen = false
                guard let ad else {
                    self.appOpen = nil
                    self.appOpenLoadedAt = nil
                    return
                }
                ad.fullScreenContentDelegate = self
                ad.paidEventHandler = { value in
                    AdjustTracker.paid(
                        value: value,
                        format: "app_open",
                        unitId: AdConfig.appOpen,
                        network: ad.responseInfo.loadedAdNetworkResponseInfo?.adNetworkClassName
                    )
                }
                self.appOpen = ad
                self.appOpenLoadedAt = Date()
            }
        }
    }

    // MARK: - Guards

    var isFullscreenActive: Bool { fullscreenShowing }

    /// Call before opening a share sheet / picker so coming back is not
    /// "returning to the app".
    func suppressAppOpenBriefly(_ seconds: TimeInterval = 20) {
        suppressUntil = Date().addingTimeInterval(seconds)
    }

    private func canShowFullscreen() -> Bool {
        guard adsAllowed, !fullscreenShowing else { return false }
        guard Date().timeIntervalSince(lastFullscreenAt) > Self.cooldown else { return false }
        guard LiveClock.status == .idle || !LiveClock.isExtensionAlive else { return false }
        return UIApplication.topViewController() != nil
    }

    // MARK: - App open

    func showAppOpenIfAvailable(onDone: @escaping () -> Void = {}) {
        // Never right after a recording: the user came back to see their video.
        guard RemoteConfigManager.shared.appOpenEnabled,
              canShowFullscreen(), Date() > suppressUntil,
              !PostProcessor.hasPendingCaptures, !PostProcessor.shared.working,
              PostProcessor.shared.lastVideo == nil,
              let ad = appOpen, let at = appOpenLoadedAt,
              Date().timeIntervalSince(at) < Self.appOpenMaxAge,
              let vc = UIApplication.topViewController() else {
            if appOpen == nil { loadAppOpen() }
            onDone()
            return
        }
        appOpen = nil
        pendingDone = onDone
        AdjustTracker.impression(format: "app_open", unitId: AdConfig.appOpen)
        ad.present(from: vc)
    }

    // MARK: - Interstitial on leaving a feature

    /// Counts a leave from a feature; on every 2nd one shows an interstitial,
    /// then calls `onDone`. Free leaves call `onDone` immediately.
    func showReturnInterstitial(onDone: @escaping () -> Void = {}) {
        guard adsAllowed else { onDone(); return }
        featureExits += 1
        let due = adOwed || featureExits % exitsPerInterstitial == 0
        guard due else { onDone(); return }
        guard canShowFullscreen(), !interstitials.isEmpty,
              let vc = UIApplication.topViewController() else {
            adOwed = true
            preload()
            onDone()
            return
        }
        adOwed = false
        let ad = interstitials.removeFirst()
        pendingDone = onDone
        AdjustTracker.impression(format: "interstitial", unitId: ad.adUnitID)
        ad.present(from: vc)
    }

    /// Shows an owed interstitial when the home screen reappears.
    func maybeShowOwedInterstitial() {
        guard adOwed, canShowFullscreen(), !interstitials.isEmpty,
              let vc = UIApplication.topViewController() else { return }
        adOwed = false
        let ad = interstitials.removeFirst()
        AdjustTracker.impression(format: "interstitial", unitId: ad.adUnitID)
        ad.present(from: vc)
    }

    // MARK: - Rewarded

    var isRewardedReady: Bool { rewarded != nil || rewardedInterstitial != nil }

    /// `completion(true)` only when the SDK reported the reward.
    func showRewarded(completion: @escaping (Bool) -> Void) {
        guard sdkReady, let vc = UIApplication.topViewController() else { completion(false); return }
        rewardEarned = false
        rewardCompletion = completion
        if let ad = rewarded {
            rewarded = nil
            AdjustTracker.impression(format: "rewarded", unitId: AdConfig.rewarded)
            ad.present(from: vc) { [weak self] in
                Task { @MainActor in self?.rewardEarned = true }
            }
        } else if let ad = rewardedInterstitial {
            rewardedInterstitial = nil
            AdjustTracker.impression(format: "rewarded_interstitial", unitId: AdConfig.rewardedInterstitial)
            ad.present(from: vc) { [weak self] in
                Task { @MainActor in self?.rewardEarned = true }
            }
        } else {
            rewardCompletion = nil
            loadRewarded()
            loadRewardedInterstitial()
            completion(false)
        }
    }

    /// One completed rewarded video toward the 3-video unlock.
    /// Returns true when this video completed the set.
    @discardableResult
    func creditRewardedVideo() -> Bool {
        let p = Prefs.shared
        let needed = RemoteConfigManager.shared.rewardAdsNeeded
        p.rewardProgress += 1
        if p.rewardProgress >= needed {
            p.rewardProgress = 0
            let hours = RemoteConfigManager.shared.rewardUnlockHours
            Store.shared.grantUnlock(seconds: TimeInterval(hours * 3600))
            SoundFx.reward()
            return true
        }
        return false
    }

    fileprivate func fullscreenEnded() {
        fullscreenShowing = false
        lastFullscreenAt = Date()
        let done = pendingDone
        pendingDone = nil
        done?()
        if let cb = rewardCompletion {
            rewardCompletion = nil
            let earned = rewardEarned
            // The reward callback can land just after dismissal.
            onMain(after: 0.3) {
                cb(earned || self.rewardEarned)
                self.rewardEarned = false
            }
        }
        preload()
    }
}

extension AdsManager: FullScreenContentDelegate {
    nonisolated func adWillPresentFullScreenContent(_ ad: FullScreenPresentingAd) {
        Task { @MainActor in self.fullscreenShowing = true }
    }

    nonisolated func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
        Task { @MainActor in self.fullscreenEnded() }
    }

    nonisolated func ad(_ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        Task { @MainActor in self.fullscreenEnded() }
    }
}

extension UIApplication {
    static func topViewController(_ base: UIViewController? = nil) -> UIViewController? {
        let root = base ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?.rootViewController
        if let nav = root as? UINavigationController { return topViewController(nav.visibleViewController) }
        if let tab = root as? UITabBarController { return topViewController(tab.selectedViewController) }
        if let presented = root?.presentedViewController, !presented.isBeingDismissed {
            return topViewController(presented)
        }
        return root
    }
}
