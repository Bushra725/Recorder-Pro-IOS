import Foundation
import StoreKit
import UIKit
import FirebaseAnalytics

/// Port of Android's BillingManager + ProState, on StoreKit 2.
///
/// * Entitlement is written only from a *verified* transaction. StoreKit 2
///   checks Apple's JWS signature on device, which replaces Android's server
///   round-trip to the Play Developer API.
/// * "Ask to Buy" / deferred payments come back as `.pending` and grant nothing.
/// * Purchased PRO and rewarded / daily-bonus PRO stay in separate flags
///   (`Prefs.isPro` vs `Prefs.rewardUnlockUntil`) so a store refresh can never
///   revoke an unlock the user earned.
@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    enum Outcome { case purchased, pending, cancelled, failed(String) }

    @Published private(set) var products: [String: Product] = [:]
    @Published private(set) var loadingProducts = false
    @Published private(set) var autoRenewing = true
    @Published private(set) var checking = false
    /// Bumped whenever any PRO source changes, so views re-read `hasPro`.
    @Published private(set) var revision = 0

    private var updatesTask: Task<Void, Never>?
    private var expiryTimer: Timer?

    var hasPro: Bool { Prefs.shared.hasProAccess }
    var isPurchased: Bool { Prefs.shared.isPro }
    var activeSku: String { Prefs.shared.proSku }

    var rewardHoursLeft: Int {
        let left = Prefs.shared.rewardUnlockUntil - Date().timeIntervalSince1970
        return max(0, Int((left / 3600).rounded(.up)))
    }

    func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task.detached { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let t) = update { await t.finish() }
                await self?.refresh()
            }
        }
        Task {
            await loadProducts()
            await refresh()
        }
        scheduleExpiryCheck()
    }

    func loadProducts() async {
        loadingProducts = true
        defer { loadingProducts = false }
        do {
            let list = try await Product.products(for: ProductID.all)
            products = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        } catch {
            products = [:]
        }
    }

    func price(_ id: String) -> String? { products[id]?.displayPrice }

    /// Re-reads current entitlements. Lifetime wins over yearly over monthly.
    func refresh() async {
        checking = true
        defer { checking = false; bump() }
        var owned: Set<String> = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let t) = result, t.revocationDate == nil else { continue }
            if let exp = t.expirationDate, exp < Date() { continue }
            owned.insert(t.productID)
        }
        let sku: String
        if owned.contains(ProductID.lifetime) { sku = ProductID.lifetime }
        else if owned.contains(ProductID.yearly) { sku = ProductID.yearly }
        else if owned.contains(ProductID.monthly) { sku = ProductID.monthly }
        else { sku = "" }
        Prefs.shared.isPro = !sku.isEmpty
        Prefs.shared.proSku = sku
        if sku == ProductID.lifetime || sku.isEmpty {
            autoRenewing = false
        } else if let subscription = products[sku]?.subscription,
                  let statuses = try? await subscription.status,
                  let status = statuses.first,
                  case .verified(let renewal) = status.renewalInfo {
            autoRenewing = renewal.willAutoRenew
        }
    }

    func purchase(_ id: String) async -> Outcome {
        if products.isEmpty { await loadProducts() }
        guard let product = products[id] else { return .failed(L("ios_plan_unavailable")) }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                guard case .verified(let t) = verification else {
                    return .failed(L("purchase_verify_failed"))
                }
                await t.finish()
                await refresh()
                Analytics.logEvent(AnalyticsEventPurchase, parameters: [
                    AnalyticsParameterItemID: id,
                    AnalyticsParameterPrice: NSDecimalNumber(decimal: product.price).doubleValue,
                    AnalyticsParameterCurrency: product.priceFormatStyle.currencyCode
                ])
                return .purchased
            case .pending:
                return .pending
            case .userCancelled:
                return .cancelled
            @unknown default:
                return .cancelled
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func restore() async {
        try? await AppStore.sync()
        await refresh()
    }

    func manageSubscriptions() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        Task { try? await AppStore.showManageSubscriptions(in: scene) }
    }

    // MARK: - Earned unlocks (rewarded video, daily bonus)

    func grantUnlock(seconds: TimeInterval) {
        let p = Prefs.shared
        let base = max(p.rewardUnlockUntil, Date().timeIntervalSince1970)
        p.rewardUnlockUntil = base + seconds
        AdjustTracker.startTrial()
        bump()
        scheduleExpiryCheck()
    }

    /// Re-renders when a temporary unlock runs out while the app is open.
    private func scheduleExpiryCheck() {
        expiryTimer?.invalidate()
        let left = Prefs.shared.rewardUnlockUntil - Date().timeIntervalSince1970
        guard left > 0 else { return }
        expiryTimer = Timer.scheduledTimer(withTimeInterval: left + 1, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.bump() }
        }
    }

    func bump() { revision &+= 1 }
}
