# Production readiness — ScreenRec Pro iOS

## Integration audit

| Integration | Status | Notes |
|---|---|---|
| Firebase Core | Ready | `FirebaseApp.configure()` in `AppDelegate`; `GoogleService-Info.plist` for project `yourmob-screen-recorder-ios`, bundle `com.ol.mob.screen.recorder.app` |
| Crashlytics | Ready | SDK linked, collection enabled, dSYM upload run script present; debug Settings row to test a crash |
| Analytics | Ready | Purchase events logged via Firebase Analytics |
| Remote Config | Ready | `RemoteConfigManager` — defaults match current product behaviour; create matching keys in Firebase Console |
| Adjust MMP | Ready | Same tokens as Android (`c33a9frama68` + events). Add an **iOS platform** under that Adjust app (or replace the token) |
| AdMob app ID | Ready | `ca-app-pub-9297250663056879~9981107737` in `Info.plist` + `AdConfig` |
| AdMob unit IDs | Ready | Live iOS units in `#else` of `AdConfig`; Debug always uses Google sample units |
| App Store numeric ID | **Missing** | Set `AppConfig.appStoreID` once App Store Connect creates the app record |

## Remote Config keys (create in Firebase Console)

| Key | Type | Default |
|---|---|---|
| `ads_enabled` | Boolean | `true` |
| `app_open_enabled` | Boolean | `true` |
| `interstitial_exit_interval` | Number | `2` |
| `reward_ads_needed` | Number | `3` |
| `reward_unlock_hours` | Number | `24` |
| `min_app_version` | String | `1.0.0` |
| `paywall_soft_prompt` | Boolean | `true` |

## Before Archive / App Store submit

1. Paste Apple ID into `AppConfig.appStoreID`.
2. Confirm Adjust dashboard has the iOS app / platform for token `c33a9frama68` (or update `AdjustConfigTokens.appToken`).
3. In Firebase Console for `yourmob-screen-recorder-ios`: enable Crashlytics, Analytics, Remote Config; publish the keys above.
4. App Store Connect: create IAP products with the IDs in `ProductID`.
5. AdMob: link the iOS app to its App Store listing; publish GDPR message (UMP); refresh `SKAdNetworkItems` from Google if needed.
6. Archive a **Release** build on a Mac with Xcode 16+ (this zip was not compiled on Windows).
7. Upload dSYMs (Crashlytics run script does this when archiving with network).

## Open in Xcode

Open `ScreenRecPro.xcodeproj`. First resolve packages (Firebase, Google Mobile Ads, UMP, Adjust). Sign all three targets with your Team.
