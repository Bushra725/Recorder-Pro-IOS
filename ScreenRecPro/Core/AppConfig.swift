import Foundation

/// Single place for store, ad and link configuration.
enum AppConfig {
    static let bundleID = "com.ol.mob.screen.recorder.app"
    static let broadcastExtensionID = "com.ol.mob.screen.recorder.app.broadcast"

    static let privacyPolicyURL = URL(string: "https://sites.google.com/view/occessstudiollc/privacy-policy")!
    /// Apple's standard EULA. App Review requires a Terms of Use link next to subscriptions.
    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let supportEmail = "hello@theoccess.com"
    static let developerAppsURL = URL(string: "https://apps.apple.com/ph/developer/occess-studio-llc/id1767799636")!

    /// App Store Connect › App Information › Apple ID (numeric).
    /// Required for Share / Rate deep links. Leave empty until the ASC record exists.
    static let appStoreID = ""

    static var appStoreURL: URL {
        appStoreID.isEmpty
            ? developerAppsURL
            : URL(string: "https://apps.apple.com/app/id\(appStoreID)")!
    }

    static var writeReviewURL: URL? {
        appStoreID.isEmpty ? nil : URL(string: "https://apps.apple.com/app/id\(appStoreID)?action=write-review")
    }

    static var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}

/// StoreKit product ids. Create these in App Store Connect › In-App Purchases /
/// Subscriptions with exactly these ids (both subscriptions in one group).
enum ProductID {
    static let monthly = "com.ol.mob.screen.recorder.app.pro.monthly"
    static let yearly = "com.ol.mob.screen.recorder.app.pro.yearly"
    static let lifetime = "com.ol.mob.screen.recorder.app.pro.lifetime"
    static let all = [monthly, yearly, lifetime]
}

/// AdMob ids for the iOS app. Debug builds always use Google's sample units —
/// requesting live ads from a development build is invalid traffic.
enum AdConfig {
    static let appID = "ca-app-pub-9297250663056879~9981107737"

    #if DEBUG
    static let appOpen = "ca-app-pub-3940256099942544/5575463023"
    static let banner1 = "ca-app-pub-3940256099942544/2435281174"
    static let banner2 = "ca-app-pub-3940256099942544/2435281174"
    static let interstitial1 = "ca-app-pub-3940256099942544/4411468910"
    static let interstitial2 = "ca-app-pub-3940256099942544/4411468910"
    static let native = "ca-app-pub-3940256099942544/3986624511"
    static let rewarded = "ca-app-pub-3940256099942544/1712485313"
    static let rewardedInterstitial = "ca-app-pub-3940256099942544/6978759866"
    #else
    static let appOpen = "ca-app-pub-9297250663056879/3343226396"
    static let banner1 = "ca-app-pub-9297250663056879/2245767144"
    static let banner2 = "ca-app-pub-9297250663056879/9932685470"
    static let interstitial1 = "ca-app-pub-9297250663056879/1532431213"
    static let interstitial2 = "ca-app-pub-9297250663056879/9441730880"
    static let native = "ca-app-pub-9297250663056879/5801868778"
    static let rewarded = "ca-app-pub-9297250663056879/3175705432"
    static let rewardedInterstitial = "ca-app-pub-9297250663056879/9406392661"
    #endif
}

/// Adjust MMP. Same dashboard tokens as Android (`c33a9frama68`). Create an
/// iOS platform under that Adjust app (or paste a dedicated iOS app token).
enum AdjustConfigTokens {
    static let appToken = "c33a9frama68"
    static let adImpression = "hort3l"
    static let adRevenue = "hlmv45"
    static let startTrial = "nair7v"
}
