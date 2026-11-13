import AVFoundation
import SwiftUI

/// The "+" sheet. Port of Android's RecordSheet.
struct RecordSheet: View {
    let onRecord: () -> Void
    let onRegion: () -> Void
    let onTimed: () -> Void
    let onLive: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("section_recording")).font(.headline).padding(.top, 20)
            row("record.circle", L("mode_full_screen"), L("mode_full_screen_sub"), action: onRecord)
            row("crop", L("mode_region"), L("ios_mode_region_sub"), action: onRegion)
            row("timer", L("mode_timed"), L("mode_timed_sub"), action: onTimed)
            Text(L("section_live")).font(.headline).padding(.top, 6)
            row("dot.radiowaves.left.and.right", L("tool_live"), L("live_rtmp_sub"), action: onLive)
            Spacer()
        }
        .padding(.horizontal, 20)
    }

    private func row(_ icon: String, _ title: String, _ sub: String, action: @escaping () -> Void) -> some View {
        Button { SoundFx.tick(); action() } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Brand.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(Brand.text)
                    Text(sub).font(.caption).foregroundStyle(Brand.textMuted).multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Brand.textMuted)
            }
            .padding(12)
            .card()
        }
    }
}

/// Hours / minutes / seconds wheel. Port of TimedRecordingDialog.
struct TimedRecordingSheet: View {
    let onStart: (Int) -> Void
    @State private var h = 0
    @State private var m = 1
    @State private var s = 0

    var body: some View {
        VStack(spacing: 12) {
            Text(L("stop_after")).font(.headline).padding(.top, 20)
            Text(L("stop_after_body")).font(.footnote).foregroundStyle(Brand.textMuted)
                .multilineTextAlignment(.center).padding(.horizontal)
            HStack(spacing: 0) {
                wheel($h, 0..<24, L("timer_hours"))
                wheel($m, 0..<60, L("timer_minutes"))
                wheel($s, 0..<60, L("timer_seconds"))
            }
            .frame(height: 160)
            Button(L("start")) { onStart(max(5, h * 3600 + m * 60 + s)) }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 24)
                .disabled(h + m + s == 0)
            Spacer()
        }
    }

    private func wheel(_ value: Binding<Int>, _ range: Range<Int>, _ label: String) -> some View {
        VStack(spacing: 0) {
            Picker(label, selection: value) {
                ForEach(range, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
            }
            .pickerStyle(.wheel)
            Text(label).font(.caption).foregroundStyle(Brand.textMuted)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Port of Android's AudioChoiceDialog. Opens on every path that starts a
/// capture. The microphone permission is asked right after the user picks a
/// source that needs it, so the system prompt arrives with obvious context.
struct AudioChoiceSheet: View {
    let onConfirmed: () -> Void
    @ObservedObject private var prefs = Prefs.shared
    @State private var micDenied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("audio_dialog_body")).foregroundStyle(Brand.textMuted)
                    option(Prefs.audioInternal, "speaker.wave.2.fill", L("audio_internal"), L("ios_audio_internal_sub"))
                    option(Prefs.audioMic, "mic.fill", L("audio_external"), L("audio_external_sub"))
                    option(Prefs.audioBoth, "waveform.badge.mic", L("audio_both"), L("audio_both_sub"))
                    option(Prefs.audioMute, "speaker.slash.fill", L("audio_mute"), L("audio_mute_sub"))

                    if needsMic {
                        Label(L("ios_mic_toggle_hint"), systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(Brand.primary)
                            .padding(12)
                            .background(Brand.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if prefs.audioSource == Prefs.audioInternal || prefs.audioSource == Prefs.audioBoth {
                        Text(L("ios_audio_internal_caveat")).font(.caption).foregroundStyle(Brand.textMuted)
                    }
                    Label(L("ios_broadcast_hint"), systemImage: "hand.tap")
                        .font(.footnote)
                        .foregroundStyle(Brand.textMuted)
                }
                .padding(20)
            }
            .safeAreaInset(edge: .bottom) {
                Button(L("start_recording")) { confirm() }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(20)
                    .background(Brand.background)
            }
            .navigationTitle(L("audio_dialog_title"))
            .navigationBarTitleDisplayMode(.inline)
            .alert(L("mic_denied_title"), isPresented: $micDenied) {
                Button(L("open_settings")) {
                    UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                }
                Button(L("record_muted")) {
                    prefs.audioSource = Prefs.audioMute
                    onConfirmed()
                }
                Button(L("cancel"), role: .cancel) {}
            } message: { Text(L("ios_mic_denied_body")) }
        }
    }

    private var needsMic: Bool {
        prefs.audioSource == Prefs.audioMic || prefs.audioSource == Prefs.audioBoth
    }

    private func option(_ value: String, _ icon: String, _ title: String, _ sub: String) -> some View {
        let selected = prefs.audioSource == value
        return Button {
            SoundFx.tick()
            prefs.audioSource = value
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(selected ? .white : Brand.primary)
                    .frame(width: 44, height: 44)
                    .background(selected ? Brand.primary : Brand.primary.opacity(0.1), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(Brand.text)
                    Text(sub).font(.caption).foregroundStyle(Brand.textMuted)
                }
                Spacer()
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Brand.primary : Brand.outline)
            }
            .padding(12)
            .card()
        }
    }

    private func confirm() {
        guard needsMic else { onConfirmed(); return }
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: onConfirmed()
        case .denied: micDenied = true
        default:
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async {
                    if granted { onConfirmed() } else { micDenied = true }
                }
            }
        }
    }
}

struct ProBadge: View {
    var body: some View {
        Text("PRO")
            .font(.caption2.weight(.heavy))
            .foregroundStyle(.black)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Brand.pro, in: Capsule())
    }
}

/// Port of RegionPickerActivity. Drag a rectangle on a phone-shaped frame; the
/// recording is cropped to it afterwards (Android also crops after capture).
struct RegionPickerView: View {
    let onDone: (CGRect?) -> Void
    @State private var rect = CGRect(x: 0.1, y: 0.25, width: 0.8, height: 0.4)
    @State private var dragStart: CGRect?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                Text(L("mode_region")).font(.headline).foregroundStyle(.white).padding(.top, 8)
                Text(L("ios_region_hint")).font(.footnote).foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center).padding(.horizontal)
                GeometryReader { geo in
                    let screen = UIScreen.main.bounds.size
                    let scale = min(geo.size.width / screen.width, geo.size.height / screen.height)
                    let frame = CGSize(width: screen.width * scale, height: screen.height * scale)
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 24).fill(Color.white.opacity(0.08))
                        RoundedRectangle(cornerRadius: 24).stroke(Color.white.opacity(0.3))
                        let r = CGRect(x: rect.minX * frame.width, y: rect.minY * frame.height,
                                       width: rect.width * frame.width, height: rect.height * frame.height)
                        Rectangle()
                            .fill(Brand.primary.opacity(0.25))
                            .overlay(Rectangle().stroke(Brand.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
                            .frame(width: r.width, height: r.height)
                            .offset(x: r.minX, y: r.minY)
                            .gesture(DragGesture().onChanged { g in
                                let start = dragStart ?? rect
                                dragStart = start
                                var n = start
                                n.origin.x = min(max(0, start.minX + g.translation.width / frame.width), 1 - start.width)
                                n.origin.y = min(max(0, start.minY + g.translation.height / frame.height), 1 - start.height)
                                rect = n
                            }.onEnded { _ in dragStart = nil })
                        // resize handle, bottom-right
                        Circle().fill(Brand.accent).frame(width: 28, height: 28)
                            .offset(x: r.maxX - 14, y: r.maxY - 14)
                            .gesture(DragGesture().onChanged { g in
                                let start = dragStart ?? rect
                                dragStart = start
                                var n = start
                                n.size.width = min(max(0.15, start.width + g.translation.width / frame.width), 1 - start.minX)
                                n.size.height = min(max(0.1, start.height + g.translation.height / frame.height), 1 - start.minY)
                                rect = n
                            }.onEnded { _ in dragStart = nil })
                    }
                    .frame(width: frame.width, height: frame.height)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
                HStack(spacing: 12) {
                    Button(L("cancel")) { onDone(nil) }
                        .buttonStyle(PrimaryButtonStyle(color: Color.white.opacity(0.15)))
                    Button(L("start_recording")) { onDone(rect) }
                        .buttonStyle(PrimaryButtonStyle())
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
        }
    }
}
