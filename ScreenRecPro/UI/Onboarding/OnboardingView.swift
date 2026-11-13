import SwiftUI

/// Port of Android's OnboardingScreen: a four-page carousel with the language
/// picker on page one. Android asks for the notification permission on the last
/// page (its control bar is a notification); iOS's equivalent — Live Activity
/// controls — needs no permission, so the last page explains them instead.
struct OnboardingView: View {
    let onDone: () -> Void

    @State private var page = 0
    @State private var showLanguages = false
    @ObservedObject private var localizer = Localizer.shared

    private struct Page {
        let icon: String
        let titleKey: String
        let bodyKey: String
    }

    private let pages = [
        Page(icon: "record.circle", titleKey: "ob1_title", bodyKey: "ob1_body"),
        Page(icon: "waveform", titleKey: "ob2_title", bodyKey: "ios_ob2_body"),
        Page(icon: "dot.radiowaves.left.and.right", titleKey: "ob3_title", bodyKey: "ios_ob3_body"),
        Page(icon: "wand.and.stars", titleKey: "ob4_title", bodyKey: "ob4_body")
    ]

    var body: some View {
        ZStack {
            Brand.background.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    if page == 0 {
                        Button { showLanguages = true } label: {
                            Label(localizer.current.nativeName, systemImage: "globe")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    Spacer()
                    if page < pages.count - 1 {
                        Button(L("skip")) { finish() }
                            .foregroundStyle(Brand.textMuted)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .frame(height: 44)

                TabView(selection: $page) {
                    ForEach(pages.indices, id: \.self) { i in
                        pageView(pages[i]).tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut, value: page)

                HStack(spacing: 8) {
                    ForEach(pages.indices, id: \.self) { i in
                        Capsule()
                            .fill(i == page ? Brand.primary : Brand.outline)
                            .frame(width: i == page ? 22 : 8, height: 8)
                    }
                }
                .animation(.spring(), value: page)
                .padding(.bottom, 20)

                Button(page == pages.count - 1 ? L("get_started") : L("next")) {
                    SoundFx.tick()
                    if page < pages.count - 1 { page += 1 } else { finish() }
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .sheet(isPresented: $showLanguages) { LanguagePicker() }
    }

    private func pageView(_ p: Page) -> some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle().fill(Brand.gradient).frame(width: 180, height: 180)
                    .shadow(color: Brand.primary.opacity(0.35), radius: 24, y: 12)
                Image(systemName: p.icon)
                    .font(.system(size: 76, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text(L(p.titleKey))
                .font(.title.bold())
                .multilineTextAlignment(.center)
                .foregroundStyle(Brand.text)
            Text(L(p.bodyKey))
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(Brand.textMuted)
                .padding(.horizontal, 28)
            Spacer()
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { if page < pages.count - 1 { page += 1 } }
    }

    private func finish() {
        Prefs.shared.onboardingDone = true
        onDone()
    }
}

/// Language list: system default + the eight shipped languages.
struct LanguagePicker: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var localizer = Localizer.shared

    var body: some View {
        NavigationStack {
            List {
                row(tag: Localizer.systemTag,
                    title: L("system_default"),
                    subtitle: L("language_following_device", deviceLanguageName))
                ForEach(Localizer.supported) { lang in
                    row(tag: lang.tag, title: lang.nativeName, subtitle: nil)
                }
            }
            .navigationTitle(L("language"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("close")) { dismiss() } }
            }
        }
    }

    private var deviceLanguageName: String {
        let preferred = Bundle.main.preferredLocalizations.first ?? "en"
        return Localizer.supported.first { $0.lproj == preferred }?.nativeName ?? "English"
    }

    private func row(tag: String, title: String, subtitle: String?) -> some View {
        Button {
            SoundFx.tick()
            localizer.set(tag)
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(Brand.text)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(Brand.textMuted) }
                }
                Spacer()
                if localizer.tag == tag {
                    Image(systemName: "checkmark").foregroundStyle(Brand.primary)
                }
            }
        }
    }
}
