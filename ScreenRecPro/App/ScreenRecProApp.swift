import FirebaseCore
import FirebaseCrashlytics
import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Firebase first (Crashlytics, Analytics, Remote Config).
        FirebaseApp.configure()
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(true)
        RemoteConfigManager.shared.start()
        AdjustTracker.start()

        MediaLibrary.purgeTrash()
        Store.shared.start()
        return true
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        // Portrait, like every Android activity in the original.
        .portrait
    }
}

@main
struct ScreenRecProApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Splash → onboarding (first run) → home. Owns theme, language and the
/// foreground hooks (sync with the extension, collect new files, app-open ad).
struct RootView: View {
    enum Stage { case splash, onboarding, main }

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var localizer = Localizer.shared
    @StateObject private var prefs = Prefs.shared
    @State private var stage: Stage = .splash
    @State private var wentToBackground = false

    var body: some View {
        Group {
            switch stage {
            case .splash:
                SplashView { finishSplash() }
            case .onboarding:
                OnboardingView { stage = .main }
            case .main:
                HomeView()
            }
        }
        .id(localizer.tag)                         // instant language switch
        .environment(\.locale, localizer.locale)
        .environment(\.layoutDirection, localizer.layoutDirection)
        .preferredColorScheme(colorScheme)
        .tint(Brand.primary)
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                RecordingController.shared.sync()
                PostProcessor.shared.collect()
                MediaLibrary.shared.reload()
                if wentToBackground, stage == .main {
                    AdsManager.shared.showAppOpenIfAvailable()
                }
                wentToBackground = false
            case .background:
                wentToBackground = true
            default:
                break
            }
        }
    }

    private var colorScheme: ColorScheme? {
        switch prefs.theme {
        case Prefs.themeLight: return .light
        case Prefs.themeDark: return .dark
        default: return nil
        }
    }

    private func finishSplash() {
        AdsManager.shared.start()
        if !prefs.onboardingDone {
            stage = .onboarding
        } else {
            // The splash already took ~1.4 s; show a ready app-open ad on top of home.
            stage = .main
            onMain(after: 1.2) {
                AdsManager.shared.showAppOpenIfAvailable()
            }
        }
    }
}

/// Port of Android's SplashActivity: a record dot with two expanding rings and
/// the launch chime, while StoreKit and the ad SDK warm up.
struct SplashView: View {
    let onDone: () -> Void
    @State private var pulse = false
    @State private var appear = false

    var body: some View {
        ZStack {
            Brand.gradient.ignoresSafeArea()
            VStack(spacing: 22) {
                ZStack {
                    ForEach(0..<2) { i in
                        Circle()
                            .stroke(Color.white.opacity(0.7), lineWidth: 3)
                            .frame(width: 92, height: 92)
                            .scaleEffect(pulse ? 2.1 : 0.9)
                            .opacity(pulse ? 0 : 0.9)
                            .animation(.easeOut(duration: 1.1).delay(Double(i) * 0.3), value: pulse)
                    }
                    Circle().fill(Color.white).frame(width: 92, height: 92)
                    Circle().fill(Brand.record).frame(width: 40, height: 40)
                }
                .scaleEffect(appear ? 1 : 0.6)
                Text(L("app_name"))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(L("splash_tagline"))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .opacity(appear ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { appear = true }
            pulse = true
            SoundFx.launch()
            onMain(after: 1.4) { onDone() }
        }
    }
}
