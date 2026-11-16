import GoogleMobileAds
import SwiftUI
import UIKit

/// Anchored adaptive banner. Collapses to zero height for PRO users or when
/// no ad was served, so the layout never keeps an empty grey strip.
struct AdBanner: View {
    enum Slot { case home, editor }
    var slot: Slot = .home

    @ObservedObject private var ads = AdsManager.shared
    @ObservedObject private var store = Store.shared
    @State private var loaded = false

    var body: some View {
        GeometryReader { geo in
            if ads.sdkReady && !store.hasPro {
                BannerContainer(unitID: slot == .home ? AdConfig.banner1 : AdConfig.banner2,
                                width: geo.size.width, loaded: $loaded)
            }
        }
        .frame(height: ads.sdkReady && !store.hasPro && loaded ? 60 : 0)
        .clipped()
    }
}

private struct BannerContainer: UIViewRepresentable {
    let unitID: String
    let width: CGFloat
    @Binding var loaded: Bool

    func makeCoordinator() -> Coordinator { Coordinator(loaded: $loaded) }

    func makeUIView(context: Context) -> BannerView {
        let banner = BannerView(adSize: currentOrientationAnchoredAdaptiveBanner(width: max(320, width)))
        banner.adUnitID = unitID
        banner.delegate = context.coordinator
        banner.rootViewController = UIApplication.topViewController()
        banner.paidEventHandler = { value in
            AdjustTracker.paid(
                value: value,
                format: "banner",
                unitId: unitID,
                network: banner.responseInfo.loadedAdNetworkResponseInfo?.adNetworkClassName
            )
        }
        banner.load(Request())
        return banner
    }

    func updateUIView(_ uiView: BannerView, context: Context) {
        if uiView.rootViewController == nil { uiView.rootViewController = UIApplication.topViewController() }
    }

    final class Coordinator: NSObject, BannerViewDelegate {
        var loaded: Binding<Bool>
        init(loaded: Binding<Bool>) { self.loaded = loaded }
        func bannerViewDidReceiveAd(_ bannerView: BannerView) { loaded.wrappedValue = true }
        func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
            loaded.wrappedValue = false
        }
    }
}

/// Native ad card (Settings tab), the counterpart of Android's NativeAdCard.
struct NativeAdCard: View {
    @ObservedObject private var ads = AdsManager.shared
    @ObservedObject private var store = Store.shared
    @State private var ad: NativeAd?
    @State private var loader: NativeLoader?

    var body: some View {
        Group {
            if let ad, !store.hasPro {
                NativeAdViewRep(ad: ad)
                    .frame(maxWidth: .infinity)
                    .frame(height: 300)
                    .card()
            }
        }
        .onAppear(perform: load)
        .onDisappear {
            // Drop the creative so GADMediaView cannot linger on the window
            // after leaving Settings (it was floating over Edit pickers).
            ad = nil
            loader = nil
        }
        .onChange(of: ads.sdkReady) { _ in load() }
    }

    private func load() {
        guard ads.sdkReady, !store.hasPro, ad == nil, loader == nil else { return }
        let l = NativeLoader { self.ad = $0 }
        loader = l
        l.load()
    }
}

final class NativeLoader: NSObject, NativeAdLoaderDelegate {
    private var adLoader: AdLoader?
    private let onAd: (NativeAd) -> Void

    init(onAd: @escaping (NativeAd) -> Void) { self.onAd = onAd }

    func load() {
        let loader = AdLoader(adUnitID: AdConfig.native,
                              rootViewController: UIApplication.topViewController(),
                              adTypes: [.native], options: nil)
        loader.delegate = self
        adLoader = loader
        loader.load(Request())
    }

    func adLoader(_ adLoader: AdLoader, didReceive nativeAd: NativeAd) {
        nativeAd.paidEventHandler = { value in
            AdjustTracker.paid(
                value: value,
                format: "native",
                unitId: AdConfig.native,
                network: nativeAd.responseInfo.loadedAdNetworkResponseInfo?.adNetworkClassName
            )
        }
        DispatchQueue.main.async { self.onAd(nativeAd) }
    }

    func adLoader(_ adLoader: AdLoader, didFailToReceiveAdWithError error: Error) {}
}

private struct NativeAdViewRep: UIViewRepresentable {
    let ad: NativeAd

    func makeUIView(context: Context) -> NativeAdView {
        let view = NativeAdView()
        view.backgroundColor = .clear

        let badge = UILabel()
        badge.text = "Ad"
        badge.font = .systemFont(ofSize: 11, weight: .bold)
        badge.textColor = .white
        badge.backgroundColor = UIColor(hex: 0xF6C445)
        badge.textAlignment = .center
        badge.layer.cornerRadius = 4
        badge.clipsToBounds = true

        let icon = UIImageView()
        icon.layer.cornerRadius = 8
        icon.clipsToBounds = true
        icon.contentMode = .scaleAspectFill

        let headline = UILabel()
        headline.font = .systemFont(ofSize: 16, weight: .semibold)
        headline.numberOfLines = 2

        let body = UILabel()
        body.font = .systemFont(ofSize: 13)
        body.textColor = .secondaryLabel
        body.numberOfLines = 2

        let media = MediaView()
        media.contentMode = .scaleAspectFill
        media.clipsToBounds = true

        let cta = UIButton(type: .system)
        cta.backgroundColor = Brand.uiPrimary
        cta.setTitleColor(.white, for: .normal)
        cta.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        cta.layer.cornerRadius = 10
        cta.isUserInteractionEnabled = false // the SDK handles the tap

        [badge, icon, headline, body, media, cta].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            icon.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            icon.widthAnchor.constraint(equalToConstant: 40),
            icon.heightAnchor.constraint(equalToConstant: 40),
            headline.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            headline.trailingAnchor.constraint(equalTo: badge.leadingAnchor, constant: -8),
            headline.topAnchor.constraint(equalTo: icon.topAnchor),
            badge.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            badge.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            badge.widthAnchor.constraint(equalToConstant: 26),
            body.leadingAnchor.constraint(equalTo: headline.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            body.topAnchor.constraint(equalTo: headline.bottomAnchor, constant: 2),
            media.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            media.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            media.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 10),
            media.heightAnchor.constraint(equalToConstant: 140),
            media.bottomAnchor.constraint(equalTo: cta.topAnchor, constant: -10),
            cta.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            cta.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            cta.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            cta.heightAnchor.constraint(equalToConstant: 44)
        ])

        view.iconView = icon
        view.headlineView = headline
        view.bodyView = body
        view.mediaView = media
        view.callToActionView = cta
        return view
    }

    func updateUIView(_ view: NativeAdView, context: Context) {
        (view.headlineView as? UILabel)?.text = ad.headline
        (view.bodyView as? UILabel)?.text = ad.body
        (view.iconView as? UIImageView)?.image = ad.icon?.image
        view.iconView?.isHidden = ad.icon == nil
        (view.callToActionView as? UIButton)?.setTitle(ad.callToAction, for: .normal)
        view.mediaView?.mediaContent = ad.mediaContent
        view.nativeAd = ad
    }

    static func dismantleUIView(_ view: NativeAdView, coordinator: ()) {
        view.nativeAd = nil
        view.mediaView?.mediaContent = nil
        view.removeFromSuperview()
    }
}
