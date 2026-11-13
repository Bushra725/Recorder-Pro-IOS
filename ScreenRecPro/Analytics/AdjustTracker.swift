import AdjustSdk
import AppTrackingTransparency
import Foundation
import GoogleMobileAds

/// Port of Android `analytics/AdjustTracker.kt`.
///
/// Tokens live in `AdjustConfigTokens`. Debug → Adjust sandbox; Release → production.
enum AdjustTracker {
    private static let sourceAdMob = "admob_sdk"
    private static var started = false

    static func start() {
        guard !started else { return }
        started = true
        #if DEBUG
        let environment = ADJEnvironmentSandbox
        #else
        let environment = ADJEnvironmentProduction
        #endif
        guard let config = ADJConfig(
            appToken: AdjustConfigTokens.appToken,
            environment: environment
        ) else { return }
        #if DEBUG
        config.logLevel = ADJLogLevel.verbose
        #else
        config.logLevel = ADJLogLevel.warn
        #endif
        Adjust.initSdk(config)
    }

    /// Call after ATT so Adjust can attach IDFA when tracking is allowed.
    static func updateTrackingConsent(_ status: ATTrackingManager.AuthorizationStatus) {
        switch status {
        case .authorized:
            Adjust.trackMeasurementConsent(true)
        case .denied, .restricted:
            Adjust.trackMeasurementConsent(false)
        default:
            break
        }
    }

    static func impression(format: String, unitId: String) {
        guard let event = ADJEvent(eventToken: AdjustConfigTokens.adImpression) else { return }
        event.addCallbackParameter("ad_format", value: format)
        event.addCallbackParameter("ad_unit", value: unitId)
        Adjust.trackEvent(event)
    }

    static func paid(value: AdValue, format: String, unitId: String, network: String?) {
        let amount = value.value.doubleValue
        let currency = value.currencyCode.isEmpty ? "USD" : value.currencyCode

        if let revenue = ADJAdRevenue(source: sourceAdMob) {
            revenue.setRevenue(amount, currency: currency)
            revenue.adRevenueUnit = unitId
            revenue.adRevenuePlacement = format
            if let network, !network.isEmpty {
                revenue.adRevenueNetwork = network
            }
            Adjust.trackAdRevenue(revenue)
        }

        guard let event = ADJEvent(eventToken: AdjustConfigTokens.adRevenue) else { return }
        event.setRevenue(amount, currency: currency)
        event.addCallbackParameter("ad_format", value: format)
        event.addCallbackParameter("ad_unit", value: unitId)
        if let network, !network.isEmpty {
            event.addCallbackParameter("ad_network", value: network)
        }
        Adjust.trackEvent(event)
    }

    static func startTrial() {
        guard let event = ADJEvent(eventToken: AdjustConfigTokens.startTrial) else { return }
        Adjust.trackEvent(event)
    }
}
