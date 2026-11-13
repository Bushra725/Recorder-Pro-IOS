import ActivityKit
import SwiftUI
import WidgetKit

@main
struct ScreenRecWidgets: WidgetBundle {
    var body: some Widget {
        // Target's minimum is iOS 16.2, the first release with ActivityContent.
        RecordingLiveActivity()
    }
}

private let brand = Color(red: 0x5B / 255, green: 0x4B / 255, blue: 0xF5 / 255)
private let accent = Color(red: 0x00 / 255, green: 0xD3 / 255, blue: 0xB8 / 255)
private let recRed = Color(red: 1, green: 0.23, blue: 0.19)

/// Lock Screen banner + Dynamic Island. Same five jobs Android's notification
/// control bar and floating HUD do: show the timer, pause/resume, screenshot, stop.
@available(iOS 16.2, *)
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.82))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        RecDot(paused: context.state.paused)
                        TimerText(state: context.state)
                            .font(.system(.title3, design: .rounded).monospacedDigit().weight(.semibold))
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("app_name")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ControlsRow(paused: context.state.paused)
                        .padding(.top, 6)
                }
            } compactLeading: {
                RecDot(paused: context.state.paused)
            } compactTrailing: {
                TimerText(state: context.state)
                    .font(.caption.monospacedDigit())
                    .frame(maxWidth: 52)
            } minimal: {
                RecDot(paused: context.state.paused)
            }
            .keylineTint(recRed)
        }
    }
}

@available(iOS 16.2, *)
private struct LockScreenView: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                RecDot(paused: state.paused)
                Text(LocalizedStringKey(state.paused ? "action_pause" : "notif_bar_title"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                TimerText(state: state)
                    .font(.system(.title2, design: .rounded).monospacedDigit().weight(.bold))
                    .foregroundStyle(.white)
            }
            ControlsRow(paused: state.paused)
        }
        .padding(16)
    }
}

@available(iOS 16.2, *)
private struct TimerText: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        if state.paused {
            Text(Self.format(state.pausedElapsed))
        } else {
            Text(timerInterval: state.effectiveStart...Date.distantFuture, countsDown: false)
                .multilineTextAlignment(.trailing)
        }
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

private struct RecDot: View {
    let paused: Bool
    var body: some View {
        Image(systemName: paused ? "pause.circle.fill" : "record.circle.fill")
            .foregroundStyle(paused ? .orange : recRed)
    }
}

/// Interactive buttons need iOS 17 (App Intents in widgets). On 16.x the
/// activity still shows the live timer and tapping it opens the app.
private struct ControlsRow: View {
    let paused: Bool

    var body: some View {
        if #available(iOS 17.0, *) {
            HStack(spacing: 10) {
                Button(intent: TogglePauseRecordingIntent()) {
                    Label(LocalizedStringKey(paused ? "ios_resume" : "action_pause"),
                          systemImage: paused ? "play.fill" : "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .tint(brand)
                Button(intent: ScreenshotDuringRecordingIntent()) {
                    Label("action_screenshot", systemImage: "camera.fill")
                        .frame(maxWidth: .infinity)
                }
                .tint(accent)
                Button(intent: StopRecordingIntent()) {
                    Label("action_stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .tint(recRed)
            }
            .buttonStyle(.borderedProminent)
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.semibold))
        } else {
            Text("ios_open_app_to_stop")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
