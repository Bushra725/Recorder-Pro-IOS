import AVFoundation
import SwiftUI

/// Port of Android's HomeScreen: top bar with overflow menu, engagement strip,
/// the quick-tools row, four tabs with a centre "+" capture button, banner ad,
/// and every dialog that hangs off the record flow.
struct HomeView: View {
    enum Tab { case video, photo, edit, settings }

    @StateObject private var router = Router.shared
    @ObservedObject private var rec = RecordingController.shared
    @ObservedObject private var post = PostProcessor.shared
    @ObservedObject private var store = Store.shared
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var library = MediaLibrary.shared

    @State private var tab: Tab = .video
    @State private var showRecordSheet = false
    @State private var showTimed = false
    @State private var showAudio = false
    @State private var showRegion = false
    @State private var showAchievements = false
    @State private var showLanguages = false
    @State private var showTutorial = false
    @State private var showFirstPrompt = false
    @State private var showScreenshotHint = false
    @State private var showLiveInfo = false
    @State private var pendingLimit = 0
    @State private var pendingRegion: CGRect?
    @State private var pickerPurpose: MediaPickerPurpose?
    @State private var shareItems: [URL] = []

    var body: some View {
        withAlerts(withSheets(layout))
    }

    /// Split into three chains so the type checker stays fast.
    private var layout: some View {
        VStack(spacing: 0) {
            topBar
            if tab == .video { EngagementStrip(onOpenAchievements: { showAchievements = true }) }
            if tab == .video || tab == .photo { toolsRow }
            if rec.isBusy { RecordingBanner() }

            Group {
                switch tab {
                case .video: VideoTabView(onRecord: { startRecording() })
                case .photo: PhotoTabView(onImport: { pickerPurpose = .importScreenshots })
                case .edit: EditTabView()
                case .settings: SettingsView(onOpenLanguages: { showLanguages = true },
                                             onOpenAchievements: { showAchievements = true })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            AdBanner(slot: .home)
            bottomBar
        }
        .background(Brand.background.ignoresSafeArea())
        .overlay(alignment: .bottomTrailing) { fab }
        .overlay(alignment: .top) { EngagementEventHost() }
        .toast($rec.notice)
        .overlay { if post.working { WorkingOverlay(message: post.workingMessage ?? L("please_wait")) } }
        .onAppear {
            library.reload()
            if !prefs.firstRecordPromptShown && prefs.totalRecordings == 0 { showFirstPrompt = true }
        }
        .onChange(of: router.route == nil) { closed in
            if closed { AdsManager.shared.maybeShowOwedInterstitial() }
        }
    }

    private func withSheets<V: View>(_ content: V) -> some View {
        content
        .sheet(isPresented: $showRecordSheet) {
            // Chained presentations wait for the sheet to finish dismissing.
            RecordSheet(onRecord: { showRecordSheet = false; onMain(after: 0.5) { startRecording() } },
                        onRegion: { showRecordSheet = false; onMain(after: 0.5) { showRegion = true } },
                        onTimed: { showRecordSheet = false; onMain(after: 0.5) { showTimed = true } },
                        onLive: { showRecordSheet = false; onMain(after: 0.5) { showLiveInfo = true } })
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showTimed) {
            TimedRecordingSheet { seconds in
                showTimed = false
                onMain(after: 0.5) { startRecording(limit: seconds) }
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showAudio) {
            AudioChoiceSheet {
                showAudio = false
                let limit = pendingLimit, region = pendingRegion
                pendingLimit = 0
                pendingRegion = nil
                // The system broadcast sheet cannot present while ours is dismissing.
                onMain(after: 0.6) { rec.start(limitSeconds: limit, region: region) }
            }
            .presentationDetents([.large])
        }
        .fullScreenCover(isPresented: $showRegion) {
            RegionPickerView { region in
                showRegion = false
                if let region { onMain(after: 0.6) { startRecording(region: region) } }
            }
        }
        .sheet(isPresented: $showAchievements) { AchievementsSheet() }
        .sheet(isPresented: $showLanguages) { LanguagePicker() }
        .sheet(item: $pickerPurpose) { purpose in
            MediaPickerSheet(purpose: purpose) { urls in
                pickerPurpose = nil
                handlePicked(urls, purpose: purpose)
            }
        }
        .sheet(item: $router.paywall) { reason in PaywallView(reason: reason) }
        .sheet(isPresented: Binding(get: { !shareItems.isEmpty }, set: { if !$0 { shareItems = [] } })) {
            ShareSheet(items: shareItems)
        }
        .fullScreenCover(item: $router.route) { route in destination(route) }
    }

    private func withAlerts<V: View>(_ content: V) -> some View {
        content
        .alert(L("how_to_record"), isPresented: $showTutorial) {
            Button(L("got_it"), role: .cancel) {}
        } message: {
            Text(["ios_tut_1", "ios_tut_2", "ios_tut_3", "ios_tut_4", "ios_tut_5", "ios_tut_6"].map { L($0) }.joined(separator: "\n\n"))
        }
        .alert(L("first_video_title"), isPresented: $showFirstPrompt) {
            Button(L("start_recording")) { prefs.firstRecordPromptShown = true; onMain(after: 0.4) { startRecording() } }
            Button(L("maybe_later"), role: .cancel) { prefs.firstRecordPromptShown = true }
        } message: { Text(L("ios_first_video_body")) }
        .alert(L("action_screenshot"), isPresented: $showScreenshotHint) {
            Button(L("start_recording")) { onMain(after: 0.4) { startRecording() } }
            Button(L("ios_import_screenshots")) { onMain(after: 0.4) { pickerPurpose = .importScreenshots } }
            Button(L("cancel"), role: .cancel) {}
        } message: { Text(L("ios_screenshot_hint")) }
        .alert(L("live_rtmp_title"), isPresented: $showLiveInfo) {
            Button(L("live_youtube_sub")) {
                UIApplication.shared.open(URL(string: "https://studio.youtube.com")!)
            }
            Button(L("start_recording")) { onMain(after: 0.4) { startRecording() } }
            Button(L("cancel"), role: .cancel) {}
        } message: { Text(L("live_rtmp_body")) }
        .alert(L("toast_recording_stopped"), isPresented: Binding(
            get: { post.lastVideo != nil && router.route == nil },
            set: { if !$0 { post.lastVideo = nil } })) {
            Button(L("edit_video")) {
                if let url = post.lastVideo { router.open(.studio(urls: [url], mode: .edit)) }
                post.lastVideo = nil
            }
            Button(L("share")) {
                if let url = post.lastVideo { shareItems = [url] }
                post.lastVideo = nil
            }
            Button(L("save"), role: .cancel) {
                post.lastVideo = nil
                Engagement.shared.maybeRequestReview()
            }
        } message: { Text(L("ios_saved_to_library")) }
        .alert(L("screenshot_saved_title"), isPresented: Binding(
            get: { post.lastScreenshot != nil && post.lastVideo == nil && router.route == nil },
            set: { if !$0 { post.lastScreenshot = nil } })) {
            Button(L("edit_photo")) {
                if let url = post.lastScreenshot { router.open(.photoEditor(url, startWithBrush: false)) }
                post.lastScreenshot = nil
            }
            Button(L("not_now"), role: .cancel) { post.lastScreenshot = nil }
        } message: { Text(L("ios_screenshot_saved_body")) }
    }

    // MARK: - Pieces

    private var topBar: some View {
        HStack {
            Text(L("app_name"))
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(Brand.primary)
            Spacer()
            Button { SoundFx.tick(); tab = .settings } label: {
                Image(systemName: "gearshape").font(.title3)
            }
            .padding(.trailing, 6)
            Menu {
                Button(L("how_to_record")) { showTutorial = true }
                Button(L("achievements")) { showAchievements = true }
                Button(L("language")) { showLanguages = true }
                Button(L("setting_trash")) { router.open(.trash) }
                Button(L("send_feedback")) { Feedback.email() }
                Button(L("share_app")) { shareItems = [AppConfig.appStoreURL] }
                if !store.isPurchased {
                    Button(L("upgrade_to_pro")) { router.paywall = .general }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
        }
        .foregroundStyle(Brand.text)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var toolsRow: some View {
        HStack {
            ToolCircle(icon: "scribble.variable", label: L("tool_brush"), selected: false) {
                // iOS cannot draw over other apps: the brush works on your latest screenshot.
                if let latest = library.photos.first {
                    router.open(.photoEditor(latest.url, startWithBrush: true))
                } else {
                    pickerPurpose = .brushPhoto
                }
            }
            ToolCircle(icon: "person.crop.rectangle", label: L("tool_facecam"), selected: false) {
                pickerPurpose = .facecam
            }
            ToolCircle(icon: "camera.viewfinder", label: L("action_screenshot"), selected: false) {
                if rec.isBusy { rec.screenshot() } else { showScreenshotHint = true }
            }
            ToolCircle(icon: "platter.2.filled.iphone",
                       label: L("ios_tool_live_controls"), selected: prefs.liveControls) {
                prefs.liveControls.toggle()
                rec.notice = prefs.liveControls ? L("ios_live_controls_on") : L("ios_live_controls_off")
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            tabButton(.video, icon: "video", selectedIcon: "video.fill", label: L("tab_video"))
            tabButton(.photo, icon: "photo", selectedIcon: "photo.fill", label: L("tab_photo"))
            Button {
                SoundFx.tapHaptic()
                if rec.isBusy { rec.stop() } else { showRecordSheet = true }
            } label: {
                ZStack {
                    Circle().fill(Brand.gradient).frame(width: 48, height: 48)
                    Image(systemName: rec.isBusy ? "stop.fill" : "plus")
                        .font(.title2.weight(.bold)).foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity)
            }
            .accessibilityLabel(L("new_capture"))
            tabButton(.edit, icon: "scissors", selectedIcon: "scissors", label: L("tab_edit"))
            tabButton(.settings, icon: "gearshape", selectedIcon: "gearshape.fill", label: L("tab_settings"))
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
        .background(Brand.surface.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Divider() }
    }

    private func tabButton(_ t: Tab, icon: String, selectedIcon: String, label: String) -> some View {
        Button {
            SoundFx.tick()
            tab = t
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tab == t ? selectedIcon : icon).font(.system(size: 20))
                Text(label).font(.caption2.weight(.medium))
            }
            .foregroundStyle(tab == t ? Brand.primary : Brand.textMuted)
            .frame(maxWidth: .infinity)
        }
    }

    /// Present on every tab except Video, which has the wide record button.
    @ViewBuilder private var fab: some View {
        if tab != .video {
            Button {
                SoundFx.tapHaptic()
                if rec.isBusy { rec.stop() } else { startRecording() }
            } label: {
                Image(systemName: rec.isBusy ? "stop.fill" : "record.circle.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .background(Brand.primary, in: Circle())
                    .shadow(color: Brand.primary.opacity(0.4), radius: 10, y: 5)
            }
            .padding(.trailing, 20)
            .padding(.bottom, 130)
            .accessibilityLabel(L("action_record"))
        }
    }

    // MARK: - Flow

    /// Every path to a capture goes through the audio chooser first.
    private func startRecording(limit: Int = 0, region: CGRect? = nil) {
        guard !rec.isBusy else { return }
        pendingLimit = limit
        pendingRegion = region
        showAudio = true
    }

    private func handlePicked(_ urls: [URL], purpose: MediaPickerPurpose) {
        guard let first = urls.first else { return }
        switch purpose {
        case .brushPhoto: router.open(.photoEditor(first, startWithBrush: true))
        case .facecam: router.open(.facecam(first))
        case .importScreenshots:
            Task {
                for url in urls {
                    if let data = try? Data(contentsOf: url) {
                        await MediaLibrary.shared.addImageData(data, ext: url.pathExtension.isEmpty ? "png" : url.pathExtension,
                                                               prefix: "Screenshot")
                    }
                }
            }
        default: break
        }
    }

    @ViewBuilder private func destination(_ route: Route) -> some View {
        switch route {
        case .studio(let urls, let mode): StudioView(urls: urls, mode: mode)
        case .trim(let urls, let mode): TrimToolView(urls: urls, mode: mode)
        case .player(let url): PlayerView(url: url)
        case .photoViewer(let url): PhotoViewerView(url: url)
        case .photoEditor(let url, let brush): PhotoEditorView(url: url, startWithBrush: brush)
        case .facecam(let url): FacecamRecorderView(videoURL: url)
        case .trash: TrashView()
        }
    }
}

/// Small persistent strip while a broadcast runs: timer + pause/stop/screenshot.
struct RecordingBanner: View {
    @ObservedObject private var rec = RecordingController.shared

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(rec.status == .paused ? Color.orange : Brand.record).frame(width: 10, height: 10)
            Text(Format.duration(Int64(rec.elapsed * 1000)))
                .font(.system(.headline, design: .rounded).monospacedDigit())
            Spacer()
            Button { rec.status == .paused ? rec.resume() : rec.pause() } label: {
                Image(systemName: rec.status == .paused ? "play.fill" : "pause.fill")
            }
            Button { rec.screenshot() } label: { Image(systemName: "camera.fill") }
            Button { rec.stop() } label: { Image(systemName: "stop.fill").foregroundStyle(Brand.record) }
        }
        .font(.title3)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .card()
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }
}

struct ToolCircle: View {
    let icon: String
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(selected ? .white : Brand.primary)
                    .frame(width: 52, height: 52)
                    .background(selected ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Brand.primary.opacity(0.1)),
                                in: Circle())
                Text(label)
                    .font(.caption)
                    .foregroundStyle(Brand.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

struct WorkingOverlay: View {
    let message: String
    var progress: Double? = nil

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                if let progress {
                    ProgressView(value: progress).frame(width: 180)
                    Text("\(Int(progress * 100))%").font(.headline.monospacedDigit())
                } else {
                    ProgressView().scaleEffect(1.3)
                }
                Text(message).font(.subheadline).multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: 280)
            .background(Brand.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        AdsManager.shared.suppressAppOpenBriefly()
        return UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

enum Feedback {
    static func email() {
        let subject = L("feedback_subject").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let body = "\n\n—\n\(L("app_name")) \(AppConfig.version), iOS \(UIDevice.current.systemVersion), \(UIDevice.current.model)"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "mailto:\(AppConfig.supportEmail)?subject=\(subject)&body=\(body)") {
            AdsManager.shared.suppressAppOpenBriefly()
            UIApplication.shared.open(url)
        }
    }
}
