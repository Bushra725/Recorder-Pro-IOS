import StoreKit
import SwiftUI

/// Port of Android's `ui/Paywall.kt`: header says *why* it opened, six
/// benefits, three plans, the 3-video rewarded unlock, restore purchases.
/// Adds what App Review requires next to subscriptions: price + period on
/// every plan, auto-renew terms, Terms of Use and Privacy Policy links.
struct PaywallView: View {
    let reason: ProFeature

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = Store.shared
    @ObservedObject private var ads = AdsManager.shared
    @ObservedObject private var prefs = Prefs.shared
    @State private var selected = ProductID.yearly
    @State private var busy = false
    @State private var message: String?
    @State private var watchingAd = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    benefits
                    plans
                    Button {
                        Task { await buy() }
                    } label: {
                        if busy { ProgressView().tint(.white) } else { Text(ctaTitle) }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(busy || store.products[selected] == nil || store.activeSku == selected)
                    .padding(.horizontal, 20)

                    if !store.isPurchased { rewardSection }

                    Button(L("restore_purchases")) {
                        Task {
                            busy = true
                            await store.restore()
                            busy = false
                            if store.isPurchased { dismiss() } else { message = L("ios_nothing_to_restore") }
                        }
                    }
                    .font(.subheadline.weight(.semibold))

                    legal
                    Button(L("maybe_later")) { dismiss() }
                        .foregroundStyle(Brand.textMuted)
                        .padding(.bottom, 30)
                }
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline).foregroundStyle(.white)
                    .frame(width: 34, height: 34).background(.black.opacity(0.25), in: Circle())
            }
            .padding(16)
            .accessibilityLabel(L("close"))
        }
        .background(Brand.background.ignoresSafeArea())
        .toast($message)
        .task {
            if store.products.isEmpty { await store.loadProducts() }
            if !store.activeSku.isEmpty { selected = store.activeSku }
            ads.preload()
        }
    }

    private var ctaTitle: String {
        if store.activeSku == selected { return L("already_this_plan") }
        if store.isPurchased { return L("switch_to_plan") }
        return L("ios_continue")
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "crown.fill").font(.system(size: 44)).foregroundStyle(Brand.pro)
            Text(L("paywall_title")).font(.largeTitle.bold()).foregroundStyle(.white)
            Text(L(reason.reasonKey)).font(.headline).foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center).padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 50)
        .padding(.bottom, 26)
        .background(Brand.gradient)
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 12) {
            benefit("nosign", "pro_no_ads")
            benefit("drop.fill", "pro_no_watermark")
            benefit("sparkles", "pro_ai_edit")
            benefit("4k.tv", "pro_quality")
            benefit("mic.fill", "pro_audio")
            benefit("bolt.fill", "pro_priority")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
    }

    private func benefit(_ icon: String, _ key: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Brand.primary).frame(width: 24)
            Text(L(key)).foregroundStyle(Brand.text)
        }
    }

    private var plans: some View {
        VStack(spacing: 10) {
            plan(ProductID.monthly, L("plan_monthly"), L("per_month"), L("plan_monthly_note"), badge: L("badge_popular"))
            plan(ProductID.yearly, L("plan_yearly"), L("per_year"), L("plan_yearly_note"), badge: L("badge_best_value"))
            plan(ProductID.lifetime, L("plan_lifetime"), L("once"), L("plan_lifetime_note"), badge: nil)
            if store.loadingProducts { Text(L("loading_plans")).font(.caption).foregroundStyle(Brand.textMuted) }
        }
        .padding(.horizontal, 20)
    }

    private func plan(_ id: String, _ title: String, _ period: String, _ note: String, badge: String?) -> some View {
        let isSelected = selected == id
        let isCurrent = store.activeSku == id
        return Button { SoundFx.tick(); selected = id } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title).font(.headline).foregroundStyle(Brand.text)
                        if isCurrent {
                            tag(L("current_plan_badge"), Brand.accent)
                        } else if let badge {
                            tag(badge, Brand.primary)
                        }
                    }
                    Text(note).font(.caption).foregroundStyle(Brand.textMuted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(store.price(id) ?? "—").font(.headline).foregroundStyle(Brand.text)
                    Text(period).font(.caption).foregroundStyle(Brand.textMuted)
                }
            }
            .padding(16)
            .background(Brand.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isSelected ? Brand.primary : Brand.outline, lineWidth: isSelected ? 2 : 1))
        }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.heavy)).foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2).background(color, in: Capsule())
    }

    private var rewardSection: some View {
        VStack(spacing: 10) {
            Text(L("reward_title")).font(.headline)
            Text(L("reward_subtitle", Prefs.rewardAdsNeeded)).font(.caption).foregroundStyle(Brand.textMuted)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                ForEach(0..<Prefs.rewardAdsNeeded, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 10)
                        .fill(i < prefs.rewardProgress ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Brand.surfaceHigh))
                        .frame(height: 44)
                        .overlay(Image(systemName: i < prefs.rewardProgress ? "checkmark" : "play.fill")
                            .foregroundStyle(i < prefs.rewardProgress ? .white : Brand.textMuted))
                }
            }
            Button {
                watchingAd = true
                ads.showRewarded { earned in
                    watchingAd = false
                    guard earned else { message = L("reward_not_ready"); return }
                    if ads.creditRewardedVideo() {
                        message = L("reward_unlocked")
                        onMain(after: 1.2) { dismiss() }
                    } else {
                        message = L("reward_progress_toast", Prefs.rewardAdsNeeded - prefs.rewardProgress)
                    }
                }
            } label: {
                Label(ads.rewardedLoading && !ads.isRewardedReady ? L("reward_loading") : L("reward_watch_cta"),
                      systemImage: "play.rectangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Brand.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }
            .disabled(watchingAd)
        }
        .padding(16)
        .card()
        .padding(.horizontal, 20)
    }

    private var legal: some View {
        VStack(spacing: 8) {
            Text(L("ios_paywall_legal")).font(.caption2).foregroundStyle(Brand.textMuted)
                .multilineTextAlignment(.center)
            HStack(spacing: 16) {
                Link(L("ios_terms_of_use"), destination: AppConfig.termsURL)
                Link(L("setting_privacy"), destination: AppConfig.privacyPolicyURL)
            }
            .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 24)
    }

    private func buy() async {
        busy = true
        defer { busy = false }
        switch await store.purchase(selected) {
        case .purchased:
            SoundFx.reward()
            if selected == ProductID.lifetime, store.autoRenewing {
                message = L("ios_lifetime_bought_cancel_sub")
            }
            dismiss()
        case .pending:
            message = L("ios_purchase_pending")
        case .cancelled:
            message = L("purchase_cancelled")
        case .failed(let text):
            message = text
        }
    }
}
