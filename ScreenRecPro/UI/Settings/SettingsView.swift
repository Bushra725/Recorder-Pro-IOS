import SwiftUI

/// Port of Android's SettingsTab, section for section. Rows that have no iOS
/// meaning (battery optimisation, "show touches" developer option, overlay
/// permission) are left out; the floating ball + notification bar rows become
/// the single "Live controls" row.
struct SettingsView: View {
    let onOpenLanguages: () -> Void
    let onOpenAchievements: () -> Void

    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var store = Store.shared
    @ObservedObject private var localizer = Localizer.shared
    @State private var option: OptionKind?
    @State private var editingWatermark = false
    @State private var watermarkDraft = ""
    @State private var showPrivacy = false
    @State private var share = false

    enum OptionKind: String, Identifiable { case audio, resolution, fps, orientation, mode, countdown, theme; var id: String { rawValue } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    proBanner
                    if !store.hasPro { NativeAdCard().padding(.horizontal, 16).padding(.bottom, 8) }

                    if store.isPurchased && store.activeSku != ProductID.lifetime {
                        header(L("manage_subscription"))
                        row("xmark.circle", L("cancel_subscription"),
                            sub: store.checking ? L("ios_checking_subscription")
                                : store.autoRenewing ? L("ios_sub_status_renewing") : L("ios_sub_status_cancelled_active")) {
                            store.manageSubscriptions()
                        }
                        row("creditcard", L("update_payment_method"), sub: L("manage_subscription")) { store.manageSubscriptions() }
                        row("arrow.triangle.2.circlepath", L("manage_auto_renewal"), sub: L("ios_cancel_subscription_hint")) {
                            store.manageSubscriptions()
                        }
                    }

                }
                Group {
                    header(L("section_recording_method"))
                    toggle("platter.2.filled.iphone", L("ios_setting_live_controls"), sub: L("ios_setting_live_controls_sub"),
                           value: Binding(get: { prefs.liveControls }, set: { prefs.liveControls = $0 }))

                    header(L("section_video"))
                    row("waveform", L("setting_audio"), value: audioLabel(prefs.audioSource)) { option = .audio }
                    row("rectangle.on.rectangle", L("setting_resolution"), value: resolutionLabel(prefs.resolution)) { option = .resolution }
                    row("speedometer", L("setting_fps"), value: "\(prefs.fps) fps") { option = .fps }
                    row("rotate.right", L("setting_orientation"),
                        value: prefs.orientation == Prefs.orientPortrait ? L("orient_portrait") : L("orient_auto")) { option = .orientation }

                }
                Group {
                    header(L("section_watermark"))
                    toggle("drop", L("setting_watermark"),
                           sub: prefs.watermark ? L("setting_watermark_on") : L("setting_watermark_off"),
                           value: Binding(get: { prefs.watermark }, set: { on in
                               if !on && !store.hasPro { Router.shared.paywall = .watermark; return }
                               prefs.watermark = on
                           }), pro: !store.hasPro)
                    if prefs.watermark {
                        row("textformat", L("setting_watermark_text"),
                            value: prefs.watermarkText.isEmpty ? L("app_name") : prefs.watermarkText) {
                            watermarkDraft = prefs.watermarkText
                            editingWatermark = true
                        }
                    }

                    header(L("section_control"))
                    row("slider.horizontal.below.rectangle", L("setting_recording_mode"),
                        value: prefs.isAdvancedCapture ? L("advanced_mode") : L("normal_mode")) { option = .mode }
                    row("timer", L("setting_countdown"),
                        value: prefs.countdown == 0 ? L("off") : "\(prefs.countdown) s") { option = .countdown }
                    toggle("iphone.radiowaves.left.and.right", L("setting_shake_to_stop"), sub: L("ios_shake_sub"),
                           value: Binding(get: { prefs.shakeToStop }, set: { prefs.shakeToStop = $0 }))
                    toggle("eye.slash", L("setting_hide_result"), sub: nil,
                           value: Binding(get: { prefs.hideResultPopup }, set: { on in
                               if !store.hasPro { Router.shared.paywall = .general; return }
                               prefs.hideResultPopup = on
                           }), pro: !store.hasPro)
                    toggle("bell.slash", L("setting_hide_toasts"), sub: L("ios_hide_toasts_sub"),
                           value: Binding(get: { prefs.hideToasts }, set: { prefs.hideToasts = $0 }))

                }
                Group {
                    header(L("section_feedback"))
                    toggle("speaker.wave.2", L("setting_sounds"), sub: L("setting_sounds_sub"),
                           value: Binding(get: { prefs.soundEffects }, set: { prefs.soundEffects = $0; if $0 { SoundFx.tick() } }))
                    toggle("hand.tap", L("setting_haptics"), sub: L("setting_haptics_sub"),
                           value: Binding(get: { prefs.haptics }, set: { prefs.haptics = $0 }))
                    row("trophy", L("achievements"), sub: L("setting_achievements_sub"), action: onOpenAchievements)

                    header(L("section_repair"))
                    toggle("bandage", L("setting_auto_repair"), sub: L("ios_auto_repair_sub"),
                           value: Binding(get: { prefs.autoRepair }, set: { prefs.autoRepair = $0 }))

                }
                Group {
                    header(L("section_others"))
                    row("globe", L("language"), sub: languageSubtitle, action: onOpenLanguages)
                    toggle("photo.on.rectangle", L("setting_save_to_gallery"),
                           sub: prefs.saveToGallery ? L("ios_save_to_gallery_on") : L("setting_save_to_gallery_off"),
                           value: Binding(get: { prefs.saveToGallery }, set: { prefs.saveToGallery = $0 }))
                    row("folder", L("setting_save_location"), sub: L("ios_save_location_value")) {
                        if let url = URL(string: "shareddocuments://" + MediaLibrary.root.path) {
                            UIApplication.shared.open(url)
                        }
                    }
                    toggle("trash", L("setting_trash"), sub: L("setting_trash_sub"),
                           value: Binding(get: { prefs.trashEnabled }, set: { prefs.trashEnabled = $0 }))
                    row("circle.lefthalf.filled", L("setting_theme"), value: themeLabel) { option = .theme }
                }
                Group {
                    row("arrow.clockwise", L("restore_purchases")) {
                        Task {
                            RecordingController.shared.notice = L("ios_restore_started")
                            await store.restore()
                        }
                    }
                    row("square.and.arrow.up", L("share"), sub: L("setting_share_sub")) { share = true }
                    row("star", L("ios_rate_app")) {
                        if let url = AppConfig.writeReviewURL { UIApplication.shared.open(url) }
                        else { Engagement.shared.maybeRequestReview() }
                    }
                    row("envelope", L("send_feedback"), sub: AppConfig.supportEmail) { Feedback.email() }
                    row("hand.raised", L("setting_privacy"), sub: L("setting_privacy_sub")) { showPrivacy = true }
                    row("info.circle", L("setting_version"), value: AppConfig.version) {}
                    #if DEBUG
                    // Firebase Crashlytics wiring check (debug builds only).
                    row("ant", "Test Crashlytics crash", sub: "Debug builds only") {
                        fatalError("Crash was triggered")
                    }
                    #endif
                }
            }
            .padding(.bottom, 120)
        }
        .sheet(item: $option) { kind in optionSheet(kind) }
        .sheet(isPresented: $share) { ShareSheet(items: [AppConfig.appStoreURL]) }
        .sheet(isPresented: $showPrivacy) { PrivacySheet() }
        .alert(L("setting_watermark_text"), isPresented: $editingWatermark) {
            TextField(L("app_name"), text: $watermarkDraft)
            Button(L("save")) { prefs.watermarkText = String(watermarkDraft.prefix(40)) }
            Button(L("cancel"), role: .cancel) {}
        } message: { Text(L("watermark_text_hint")) }
    }

    // MARK: - Banner

    private var proBanner: some View {
        Button { Router.shared.paywall = .general } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(store.isPurchased ? L("pro_active") : store.hasPro ? L("pro_trial_active") : "PRO")
                    .font(.title2.bold())
                Text(store.isPurchased ? L("pro_thanks")
                     : store.hasPro ? L("pro_trial_left", store.rewardHoursLeft)
                     : L("pro_pitch", store.price(ProductID.monthly) ?? "$9.99"))
                    .font(.subheadline)
                    .multilineTextAlignment(.leading)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(Brand.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(16)
    }

    // MARK: - Rows

    private func header(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(Brand.primary)
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 6)
    }

    private func row(_ icon: String, _ title: String, sub: String? = nil, value: String? = nil,
                     action: @escaping () -> Void) -> some View {
        Button { SoundFx.tick(); action() } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).frame(width: 26).foregroundStyle(Brand.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(Brand.text)
                    if let sub { Text(sub).font(.caption).foregroundStyle(Brand.textMuted).multilineTextAlignment(.leading) }
                }
                Spacer()
                if let value { Text(value).font(.subheadline).foregroundStyle(Brand.textMuted).lineLimit(1) }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
    }

    private func toggle(_ icon: String, _ title: String, sub: String?, value: Binding<Bool>,
                        pro: Bool = false) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).frame(width: 26).foregroundStyle(Brand.primary)
            VStack(alignment: .leading, spacing: 2) {
                HStack { Text(title).foregroundStyle(Brand.text); if pro { ProBadge() } }
                if let sub { Text(sub).font(.caption).foregroundStyle(Brand.textMuted) }
            }
            Spacer()
            Toggle("", isOn: value).labelsHidden().tint(Brand.primary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - Option sheets

    @ViewBuilder private func optionSheet(_ kind: OptionKind) -> some View {
        switch kind {
        case .audio:
            OptionSheet(title: L("setting_audio"), options: [
                .init(Prefs.audioMute, L("audio_mute")), .init(Prefs.audioMic, L("audio_external")),
                .init(Prefs.audioInternal, L("audio_internal")), .init(Prefs.audioBoth, L("audio_both"))
            ], selected: prefs.audioSource) { prefs.audioSource = $0 }
        case .resolution:
            OptionSheet(title: L("setting_resolution"), options: [
                .init("480", "SD (480P)"), .init("720", "HD (720P)"),
                .init("1080", "Full HD (1080P)", locked: !store.isPurchased),
                .init("1440", "2K (1440P)", locked: !store.isPurchased),
                .init("0", L("native_res"), locked: !store.isPurchased)
            ], selected: String(prefs.resolution)) { v in
                let r = Int(v) ?? 720
                if !store.isPurchased && Prefs.isPremiumResolution(r) { Router.shared.paywall = .quality; return }
                prefs.resolution = r
            }
        case .fps:
            OptionSheet(title: L("setting_fps"), options: [
                .init("24", "24 fps"), .init("30", "30 fps"),
                .init("48", "48 fps", locked: !store.hasPro), .init("60", "60 fps", locked: !store.hasPro)
            ], selected: String(prefs.fps)) { v in
                let f = Int(v) ?? 30
                if f > 30 && !store.hasPro { Router.shared.paywall = .quality; return }
                prefs.fps = f
            }
        case .orientation:
            OptionSheet(title: L("setting_orientation"), options: [
                .init(Prefs.orientAuto, L("orient_auto")), .init(Prefs.orientPortrait, L("orient_portrait"))
            ], selected: prefs.orientation) { prefs.orientation = $0 }
        case .mode:
            OptionSheet(title: L("setting_recording_mode"), options: [
                .init(Prefs.modeNormal, L("normal_mode"), sub: L("ios_mode_normal_sub")),
                .init(Prefs.modeAdvanced, L("advanced_mode"), sub: L("ios_mode_advanced_sub"))
            ], selected: prefs.recordingMode) { prefs.recordingMode = $0 }
        case .countdown:
            OptionSheet(title: L("setting_countdown"), options: [
                .init("3", "3 s"), .init("5", "5 s"), .init("10", "10 s")
            ], selected: String(max(3, prefs.countdown)), footer: L("ios_countdown_note")) { prefs.countdown = Int($0) ?? 3 }
        case .theme:
            OptionSheet(title: L("setting_theme"), options: [
                .init(Prefs.themeLight, L("theme_light")), .init(Prefs.themeDark, L("theme_dark")),
                .init(Prefs.themeSystem, L("system_default"))
            ], selected: prefs.theme) { prefs.theme = $0 }
        }
    }

    private var themeLabel: String {
        switch prefs.theme {
        case Prefs.themeLight: return L("theme_light")
        case Prefs.themeDark: return L("theme_dark")
        default: return L("system_default")
        }
    }

    private var languageSubtitle: String {
        localizer.isFollowingSystem
            ? L("language_following_device", localizer.current.nativeName)
            : localizer.current.nativeName
    }

    private func audioLabel(_ v: String) -> String {
        switch v {
        case Prefs.audioMic: return L("audio_external")
        case Prefs.audioInternal: return L("audio_internal")
        case Prefs.audioBoth: return L("audio_both")
        default: return L("audio_mute")
        }
    }

    private func resolutionLabel(_ v: Int) -> String {
        v == 0 ? L("native_res") : "\(v)P"
    }
}

struct OptionSheet: View {
    struct Option: Identifiable {
        let value: String
        let label: String
        var sub: String? = nil
        var locked = false
        var id: String { value }
        init(_ value: String, _ label: String, sub: String? = nil, locked: Bool = false) {
            self.value = value; self.label = label; self.sub = sub; self.locked = locked
        }
    }

    let title: String
    let options: [Option]
    let selected: String
    var footer: String? = nil
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(options) { o in
                        Button {
                            SoundFx.tick()
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { onPick(o.value) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack { Text(o.label).foregroundStyle(Brand.text); if o.locked { ProBadge() } }
                                    if let sub = o.sub { Text(sub).font(.caption).foregroundStyle(Brand.textMuted) }
                                }
                                Spacer()
                                if o.value == selected { Image(systemName: "checkmark").foregroundStyle(Brand.primary) }
                            }
                        }
                    }
                } footer: {
                    if let footer { Text(footer) }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }
}

struct PrivacySheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L("ios_privacy_policy_body"))
                    Text(L("access_terms_title")).font(.headline)
                    Text(L("ios_access_terms_body"))
                    Button(L("open_privacy_policy")) { UIApplication.shared.open(AppConfig.privacyPolicyURL) }
                        .buttonStyle(PrimaryButtonStyle())
                }
                .padding(20)
            }
            .navigationTitle(L("setting_privacy"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("close")) { dismiss() } } }
        }
    }
}
