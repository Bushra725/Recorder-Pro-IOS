import SwiftUI

/// Port of Android's EditTab: a two-column grid of editing tools.
struct EditTabView: View {
    @ObservedObject private var store = Store.shared
    @State private var purpose: MediaPickerPurpose?
    @State private var shareURLs: [URL] = []

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                tile("sparkles", L("edit_with_ai"), pro: true, highlight: true) { gated(.aiEdit, .aiEdit) }
                tile("film", L("edit_video")) { purpose = .editVideo }
                tile("scissors", L("trim_video")) { purpose = .trim }
                tile("arrow.down.right.and.arrow.up.left", L("video_compress"), pro: true) { gated(.compress, .general) }
                tile("square.stack.3d.up", L("merge_video")) { purpose = .merge }
                tile("captions.bubble", L("auto_captions"), pro: true) { gated(.captions, .aiEdit) }
                tile("photo", L("edit_photo")) { purpose = .editPhoto }
                tile("photo.stack", L("video_to_gif"), pro: true) { gated(.gif, .general) }
                tile("arrow.up.arrow.down.circle", L("file_transfer")) { purpose = .fileTransfer }
                tile("square.grid.2x2", L("other_apps")) {
                    UIApplication.shared.open(AppConfig.developerAppsURL)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 110)
        }
        .sheet(item: $purpose) { p in
            MediaPickerSheet(purpose: p) { urls in
                purpose = nil
                route(urls, for: p)
            }
        }
        .sheet(isPresented: Binding(get: { !shareURLs.isEmpty }, set: { if !$0 { shareURLs = [] } })) {
            ShareSheet(items: shareURLs)
        }
    }

    private func gated(_ p: MediaPickerPurpose, _ reason: ProFeature) {
        if store.hasPro { purpose = p } else { Router.shared.paywall = reason }
    }

    private func route(_ urls: [URL], for p: MediaPickerPurpose) {
        guard let first = urls.first else { return }
        let r = Router.shared
        switch p {
        case .editVideo: r.open(.studio(urls: [first], mode: .edit))
        case .aiEdit: r.open(.studio(urls: [first], mode: .ai))
        case .captions: r.open(.studio(urls: [first], mode: .captions))
        case .merge:
            if urls.count < 2 { RecordingController.shared.notice = L("merge_need_two") }
            else { r.open(.studio(urls: urls, mode: .merge)) }
        case .trim: r.open(.trim(urls: [first], mode: .trim))
        case .compress: r.open(.trim(urls: urls, mode: .compress))
        case .gif: r.open(.trim(urls: [first], mode: .gif))
        case .editPhoto, .brushPhoto: r.open(.photoEditor(first, startWithBrush: p == .brushPhoto))
        case .fileTransfer: shareURLs = urls
        case .facecam: r.open(.facecam(first))
        case .importScreenshots: break
        }
    }

    private func tile(_ icon: String, _ title: String, pro: Bool = false, highlight: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button { SoundFx.tick(); action() } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: icon)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(highlight ? .white : Brand.primary)
                        .frame(width: 46, height: 46)
                        .background(highlight ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Brand.primary.opacity(0.1)),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Spacer()
                    if pro && !store.hasPro { ProBadge() }
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.text)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
            }
            .padding(14)
            .card()
        }
    }
}
