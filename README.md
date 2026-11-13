# ScreenRec Pro for iOS

This is a native **Swift / SwiftUI** port of the Android app (Kotlin + Compose, v6). It has the same screens, the same settings and the same monetisation rules, and it ships in all eight languages.

| | |
|---|---|
| Bundle ID | `com.ol.mob.screen.recorder.app` |
| Broadcast extension | `com.ol.mob.screen.recorder.app.broadcast` |
| Live Activity extension | `com.ol.mob.screen.recorder.app.liveactivity` |
| App Group | `group.com.ol.mob.screen.recorder.app` |
| Minimum iOS | 16.0 (the Live Activity needs 16.2; its buttons need 17) |
| Xcode | 16 or newer |
| Packages (Swift Package Manager) | Firebase 12 (Core, Crashlytics, Analytics, Remote Config), Google Mobile Ads 12, User Messaging Platform 3, Adjust SDK 5 |

## Why native Swift (not Flutter or React Native)

Screen recording on iOS works through a **Broadcast Upload Extension**, which is a separate native process with a 50 MB memory limit. It has to be written in Swift whichever framework the app uses. Several other features are also built on native frameworks:

- **Editor:** AVFoundation and Core Image
- **Subscriptions:** StoreKit 2
- **Lock Screen and Dynamic Island controls:** ActivityKit
- **Auto Captions:** the Speech framework

A cross-platform layer would have meant bridging every one of these. The `screenrec_pro/` Flutter folder in your Android zip only covered the basics, so it was not used.

## Open and run

1. Open `ScreenRecPro.xcodeproj`. Xcode then fetches the three Swift packages, which takes a minute the first time.
2. Select each of the three targets (**ScreenRecPro**, **ScreenRecBroadcast**, **ScreenRecLiveActivity**). Under *Signing & Capabilities*, choose your Team. Automatic signing registers the App Group for you.
3. Run on a **real iPhone**. The broadcast extension does not record in the Simulator.
4. The scheme already points at `ScreenRecPro.storekit`, so the paywall shows prices and purchases work locally. If Xcode says it can't find the file, set it again under *Edit Scheme › Run › Options › StoreKit Configuration*.

Firebase, Adjust and ads are wired for production (see `PRODUCTION.md` for the full checklist):

- `FirebaseApp.configure()` runs in `AppDelegate` (Crashlytics + Analytics + Remote Config).
- Your `GoogleService-Info.plist` is included.
- The dSYM upload run script is set up for Crashlytics.
- Adjust MMP starts at launch (same tokens as Android); ad impressions / revenue / trial unlocks are tracked.
- Debug builds show a **Test Crashlytics crash** row at the bottom of Settings.

## Before you submit to the App Store

1. **In-app purchases** (App Store Connect › your app):
   - Create a subscription group called "ScreenRec PRO" with two subscriptions:
     - `com.ol.mob.screen.recorder.app.pro.monthly`, 1 month, $9.99
     - `com.ol.mob.screen.recorder.app.pro.yearly`, 1 year, $59.99
   - Create one non-consumable: `com.ol.mob.screen.recorder.app.pro.lifetime`, $39.99.
   - These are the same prices as on Android. The IDs are also in `Core/AppConfig.swift`.
2. **App ID:** once the app record exists, paste its numeric Apple ID into `AppConfig.appStoreID`. "Share app" and "Rate" use it. Until then they link to your developer page.
3. **AdMob:**
   - The real iOS ad units you sent are in `AppConfig.swift`. Release builds use them; Debug builds always use Google's test units.
   - In AdMob, link the iOS app to its App Store listing once it is live.
   - Add `app-ads.txt` to your website.
   - Refresh `SKAdNetworkItems` in `Info.plist` from Google's current list.
   - Create a GDPR message under **Privacy & messaging**. The consent form (UMP) appears automatically for EEA/UK users, followed by the App Tracking Transparency prompt.
4. **Privacy:**
   - The privacy link is `https://sites.google.com/view/occessstudiollc/privacy-policy`.
   - `PrivacyInfo.xcprivacy` declares crash data, the advertising identifier (for ads), and the required-reason APIs.
   - Fill in App Store Connect's privacy labels to match.
   - Mention in your policy that screen content stays on the device.
5. **Review notes:** tell App Review that recording starts with **Record → Start Broadcast**, and that the Live Activity controls pause and stop the broadcast.

## What's the same as Android

| Android | iOS |
|---|---|
| Splash with record-dot animation and chime | Same animation and same synthesised chime |
| 4-page onboarding with language picker | Same |
| Video / Photo / Edit / Settings tabs, centre **+** | Same |
| Audio choice on every recording (internal, mic, both, mute) | Same. Internal audio is the apps' sound. iOS has you switch the mic on in its own sheet, so the dialog tells the user to. |
| Resolution 480 / 720 / 1080 / 2K / native, 24–60 fps, bitrate per resolution | Same, with the same PRO gates |
| Orientation Auto / Portrait | Same (picks the orientation the recording spent the most time in) |
| Normal / Advanced recording mode | Normal: H.264 with on-screen controls. Advanced: HEVC with no controls. |
| Countdown, timed recording, region recording | Same. Region is cropped after capture, as on Android. |
| Pause / resume / stop / screenshot during recording | From the Lock Screen and Dynamic Island, from the in-app banner, or from iOS's red status pill |
| Shake to stop | Same (iOS may not deliver motion data to the extension; this is best-effort) |
| Auto repair | Writes a fragmented movie, so a killed recorder still leaves a playable file |
| Watermark (forced for free users, custom text for PRO) | Same, burned in after capture |
| Save to gallery | Saves to Photos (add-only permission). Files also appear in the Files app. |
| Trash, kept for 24 h | Same, plus a Trash screen with Restore |
| CapCut-style editor: fixed playhead, filmstrip, pinch zoom, two-level toolbar, undo/redo (40) | Same. Preview and export go through one renderer. |
| Split, delete, copy, reorder, per-clip speed, volume, rotate, flip, crop + zoom, trim handles | Same |
| Reverse | **Real frame reversal.** Android only reversed clip order. |
| 27 filters + 14 effects, category tabs, thumbnails of your own video, intensity, time range | Same catalogue and the same colour maths |
| Format (9:16, 16:9, 1:1, 4:5, 4:3) + canvas (colours, blur, dark blur) | Same |
| Adjust (brightness, contrast, saturation, warmth) | Same |
| Text with full style sheet, stickers (4 packs), timing on the timeline | Same packs and fonts mapped to iOS fonts |
| Auto Captions in 6 languages | Apple's speech recognition (on-device where supported). No model download. |
| Music: pick, trim, place, volume | From Files, or the soundtrack of any video |
| Edit with AI, Merge video & photo, Trim, Compress (batch), Video → GIF, File transfer, Other apps | Same, with the same PRO gates |
| Photo editor: crop, rotate, flip, filters, text, brush, stickers | Same, with all 27 filters (Android had 5) |
| Paywall: 3 plans, 6 benefits, 3 rewarded videos = 24 h PRO, restore | Same, plus the terms Apple requires |
| Ads: app open, 2 banners, native, 2 interstitials (every 2nd exit), rewarded, rewarded interstitial | Same placements and the same cadence |
| Streaks, 9 achievements, daily bonus (2–6 h), stats strip | Same |
| Rating prompt | Apple's system prompt, after 5 recordings and 1 achievement. Apple forbids the Android-style "5 stars → store" dialog. |
| 8 languages, auto-detect + in-app override, Arabic RTL | Same. Generated from your Android `strings.xml`, plus 60 new iOS strings translated into all 8. |
| Theme, sounds, haptics, feedback email, share, privacy dialog | Same |
| Firebase Crashlytics | Same |

## What iOS does not allow, and what replaces it

Apple doesn't let any app draw over other apps or use the camera from the background. These Android features have no direct equivalent:

| Android feature | iOS replacement |
|---|---|
| Floating ball | **Live Activity** on the Lock Screen and Dynamic Island: timer, pause/resume, screenshot, stop. Toggled by the "Controls" tool and in Settings. |
| Notification control bar | Same Live Activity |
| Recording HUD overlay | Live Activity, plus the banner inside the app |
| Brush drawing over other apps | Brush opens on your latest screenshot (photo editor with pen, highlighter, shapes, arrow, fill, eraser, colours, size) |
| Facecam bubble over other apps | **Facecam reaction recorder:** your video plays while the front camera films you in a bubble you can drag and resize, then both are combined into one video |
| Screenshot bubble | During a recording, Screenshot grabs a frame from the live broadcast. Otherwise the app explains the side + volume-up buttons and imports from Photos. |
| "Show touches", "Avoid abnormal stop" (battery), overlay permission | No iOS equivalent, so the rows are removed |
| Countdown "Off" | iOS always shows a 3-second countdown before a broadcast; longer settings add to it |

## Project layout

```
ScreenRecPro.xcodeproj          generated by tools/gen_xcodeproj.py
Shared/                         compiled into the app + both extensions
  AppGroup.swift                shared defaults keys, Darwin notifications, sidecar
  RecordingActivity.swift       Live Activity model + App Intents (pause/stop/screenshot)
ScreenRecBroadcast/             Broadcast Upload Extension (the recorder)
ScreenRecLiveActivity/          Lock Screen / Dynamic Island UI
ScreenRecPro/
  App/            app entry, splash, router
  Core/           Prefs, localisation, theme, synthesised sounds, config (ad ids, product ids)
  Data/           library (files, Photos, trash), thumbnails
  Recording/      broadcast start/stop, post-processing (watermark, region crop, audio mix)
  Editor/         model (timeline, looks), renderer (custom compositor), views, tools
  PhotoEditor/    photo editor + brush
  Facecam/        reaction recorder
  Monetization/   StoreKit 2, AdMob, paywall
  Engagement/     streaks, achievements, daily bonus
  UI/             home, tabs, settings, onboarding, viewers
  Resources/      assets, 8 × Localizable.strings / InfoPlist.strings, Firebase plist, StoreKit file
tools/
  convert_strings.py            Android strings.xml → iOS .strings (re-run after editing Android strings)
  ios_strings.py                iOS-only strings in all 8 languages
  gen_xcodeproj.py              regenerates the Xcode project after adding/removing files
```

## Testing checklist (on a device)

- Record with each audio option. Turn the mic on in the system sheet, then check that both app sound and voice are in the result.
- Pause and resume from the Lock Screen, then stop from the Dynamic Island. Take a screenshot mid-recording.
- Timed recording: it should stop on its own.
- Region recording: check the crop.
- Advanced mode: no Live Activity appears, and the file is HEVC.
- Kill the extension mid-recording (record for a long time, then force-quit from Xcode). With Auto Repair on, the partial video should be recovered.
- Editor: split, speed, reverse, a filter over only part of the video, a 9:16 format with blur canvas, text and stickers, captions, music. The export should look like the preview.
- Merge two videos and one photo.
- Compress (single and batch), make a GIF, use the facecam.
- Buy each plan with the StoreKit file, then restore. Watch three rewarded test ads and check PRO turns on for 24 h.
- Switch the language to Arabic in the app and check the layout mirrors.

## Honest status

No Mac or iOS compiler was available where this was written, so the project has **not been built yet**. Here is what was checked:

- The Xcode project file parses, and every file it references exists.
- Brackets are balanced in all Swift files.
- Every localisation key used in code exists in all 8 languages, with matching `%` placeholders.
- The API names were checked against iOS 16–17, StoreKit 2, Google Mobile Ads 12 and UMP 3.

Expect a handful of small compile fixes on the first build, most likely concurrency warnings or an SDK signature that has drifted. If Xcode reports a package version conflict between Google Mobile Ads and UMP, set UMP's rule to the version Google Mobile Ads asks for.
