import SwiftUI

/// Why the paywall opened — the header says so (Android's ProFeature).
enum ProFeature: String, Identifiable {
    case general, watermark, aiEdit, quality, noAds
    var id: String { rawValue }
    var reasonKey: String {
        switch self {
        case .general: return "paywall_reason_general"
        case .watermark: return "paywall_reason_watermark"
        case .aiEdit: return "paywall_reason_ai_edit"
        case .quality: return "paywall_reason_quality"
        case .noAds: return "paywall_reason_no_ads"
        }
    }
}

/// How the video studio opens. Android has separate activities for these
/// (VideoEditorActivity, AiEditActivity, CaptionActivity, merge); here they
/// are one studio that starts on a different panel / toolbar.
enum StudioMode: Equatable {
    case edit
    case ai          // "Edit with AI": text + emoji with suggestions (PRO)
    case captions    // "Auto Captions"
    case merge       // "Merge Video & Photo"
    case facecam     // reaction overlay
}

enum TrimMode: String { case trim, compress, gif }

/// Full-screen destinations.
enum Route: Identifiable {
    case studio(urls: [URL], mode: StudioMode)
    case trim(urls: [URL], mode: TrimMode)
    case player(URL)
    case photoViewer(URL)
    case photoEditor(URL, startWithBrush: Bool)
    case facecam(URL)
    case trash

    var id: String {
        switch self {
        case .studio(let urls, let mode): return "studio\(urls)\(mode)"
        case .trim(let urls, let mode): return "trim\(urls)\(mode.rawValue)"
        case .player(let u): return "player\(u)"
        case .photoViewer(let u): return "photo\(u)"
        case .photoEditor(let u, let b): return "photoedit\(u)\(b)"
        case .facecam(let u): return "facecam\(u)"
        case .trash: return "trash"
        }
    }
}

@MainActor
final class Router: ObservableObject {
    static let shared = Router()
    @Published var route: Route?
    @Published var paywall: ProFeature?

    func open(_ r: Route) {
        SoundFx.tapHaptic()
        route = r
    }

    /// Closes the current screen and counts it as a "leave" for the interstitial cadence.
    func closeFeature() {
        route = nil
        onMain(after: 0.45) {
            AdsManager.shared.showReturnInterstitial()
        }
    }
}

/// Lightweight toast at the top of the screen.
struct ToastView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Brand.primary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}

extension View {
    /// Shows `text` as a toast for 2.5 s, then clears it.
    func toast(_ text: Binding<String?>) -> some View {
        overlay(alignment: .top) {
            if let t = text.wrappedValue {
                ToastView(text: t)
                    .task(id: t) {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        withAnimation { text.wrappedValue = nil }
                    }
            }
        }
        .animation(.spring(), value: text.wrappedValue)
    }
}

/// Runs `body` on the main actor after a delay. Used instead of
/// DispatchQueue.main.asyncAfter so main-actor calls inside are checked.
@MainActor
func onMain(after seconds: Double, _ body: @escaping @MainActor () -> Void) {
    Task { @MainActor in
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        body()
    }
}
