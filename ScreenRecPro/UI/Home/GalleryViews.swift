import SwiftUI

/// Port of Android's VideoTab: record bar, storage chip, recordings grouped by day.
struct VideoTabView: View {
    let onRecord: () -> Void
    @ObservedObject private var library = MediaLibrary.shared
    @ObservedObject private var rec = RecordingController.shared
    @State private var actionItem: MediaItem?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                BigRecordButton(onRecord: onRecord)
                StorageChip()
                if library.videos.isEmpty {
                    EmptyState(icon: "video.badge.plus", title: L("first_video_title"), subtitle: L("ios_first_video_body"))
                } else {
                    ForEach(groups, id: \.title) { group in
                        Text(group.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Brand.textMuted)
                            .padding(.top, 6)
                        ForEach(group.items) { item in
                            VideoRow(item: item, onMore: { actionItem = item })
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 110)
        }
        .refreshable { library.reload() }
        .sheet(item: $actionItem) { item in MediaActionSheet(item: item).presentationDetents([.medium]) }
    }

    private var groups: [(title: String, items: [MediaItem])] {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Localizer.shared.locale
        f.dateStyle = .medium
        var out: [(String, [MediaItem])] = []
        for item in library.videos {
            let title = cal.isDateInToday(item.createdAt) ? L("date_today") : f.string(from: item.createdAt)
            if let i = out.firstIndex(where: { $0.0 == title }) { out[i].1.append(item) }
            else { out.append((title, [item])) }
        }
        return out.map { (title: $0.0, items: $0.1) }
    }
}

struct BigRecordButton: View {
    let onRecord: () -> Void
    @ObservedObject private var rec = RecordingController.shared

    var body: some View {
        Button {
            SoundFx.tapHaptic()
            if rec.isBusy { rec.stop() } else { onRecord() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: rec.isBusy ? "stop.fill" : "record.circle.fill").font(.title2)
                Text(rec.isBusy ? L("action_stop") : L("action_record")).font(.title3.weight(.bold))
                if rec.isBusy {
                    Text(Format.duration(Int64(rec.elapsed * 1000)))
                        .font(.title3.monospacedDigit())
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(rec.isBusy ? AnyShapeStyle(Brand.record) : AnyShapeStyle(Brand.gradient),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: Brand.primary.opacity(0.3), radius: 10, y: 6)
        }
        .padding(.top, 4)
    }
}

struct StorageChip: View {
    @ObservedObject private var library = MediaLibrary.shared
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "internaldrive")
            Text(L("ios_storage_free", Format.size(library.usedBytes), Format.size(library.freeBytes)))
        }
        .font(.caption)
        .foregroundStyle(Brand.textMuted)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Brand.surfaceHigh, in: Capsule())
    }
}

struct VideoRow: View {
    let item: MediaItem
    let onMore: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                ThumbnailView(url: item.url, maxSide: 240)
                    .frame(width: 104, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(Format.duration(item.durationMs))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                    .padding(4)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(1).foregroundStyle(Brand.text)
                Text([Format.resolution(item.pixelSize), Format.size(item.sizeBytes)]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(Brand.textMuted)
            }
            Spacer()
            Button { Router.shared.open(.trim(urls: [item.url], mode: .trim)) } label: {
                Image(systemName: "scissors").foregroundStyle(Brand.primary)
            }
            .buttonStyle(.borderless)
            Button(action: onMore) {
                Image(systemName: "ellipsis").rotationEffect(.degrees(90)).foregroundStyle(Brand.textMuted)
                    .frame(width: 28, height: 36)
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .card()
        .contentShape(Rectangle())
        .onTapGesture { Router.shared.open(.player(item.url)) }
    }
}

/// Port of Android's PhotoTab: a grid of screenshots, GIFs and edited photos.
struct PhotoTabView: View {
    let onImport: () -> Void
    @ObservedObject private var library = MediaLibrary.shared
    @State private var actionItem: MediaItem?
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Button(action: onImport) {
                    Label(L("ios_import_screenshots"), systemImage: "square.and.arrow.down")
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.top, 4)
                if library.photos.isEmpty {
                    EmptyState(icon: "camera.viewfinder", title: L("action_screenshot"), subtitle: L("ios_screenshot_hint"))
                } else {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(library.photos) { item in
                            ThumbnailView(url: item.url, maxSide: 360)
                                .aspectRatio(0.75, contentMode: .fill)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(alignment: .topLeading) {
                                    if item.kind == .gif {
                                        Text("GIF").font(.caption2.bold()).foregroundStyle(.white)
                                            .padding(4).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                                            .padding(5)
                                    }
                                }
                                .onTapGesture { Router.shared.open(.photoViewer(item.url)) }
                                .onLongPressGesture { actionItem = item }
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 110)
        }
        .refreshable { library.reload() }
        .sheet(item: $actionItem) { item in MediaActionSheet(item: item).presentationDetents([.medium]) }
    }
}

/// Port of Android's MediaActionSheet.
struct MediaActionSheet: View {
    let item: MediaItem
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = Store.shared
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false
    @State private var share = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ThumbnailView(url: item.url, maxSide: 200).frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading) {
                    Text(item.name).font(.headline).lineLimit(1)
                    Text(Format.size(item.sizeBytes)).font(.caption).foregroundStyle(Brand.textMuted)
                }
            }
            .padding(20)
            Divider()
            action("square.and.arrow.up", L("share")) { share = true }
            if item.isVideo {
                action("sparkles", L("edit_with_ai"), pro: !store.hasPro) {
                    open(.studio(urls: [item.url], mode: .ai), proReason: .aiEdit)
                }
                action("film", L("edit_video")) { open(.studio(urls: [item.url], mode: .edit)) }
                action("scissors", L("trim_video")) { open(.trim(urls: [item.url], mode: .trim)) }
                action("arrow.down.right.and.arrow.up.left", L("compress"), pro: !store.hasPro) {
                    open(.trim(urls: [item.url], mode: .compress), proReason: .general)
                }
            } else if item.kind == .photo {
                action("slider.horizontal.3", L("edit_photo")) { open(.photoEditor(item.url, startWithBrush: false)) }
            }
            action("pencil", L("rename")) { newName = item.name; renaming = true }
            action("trash", L("delete"), danger: true) { confirmDelete = true }
            Spacer()
        }
        .sheet(isPresented: $share) { ShareSheet(items: [item.url]) }
        .alert(L("rename"), isPresented: $renaming) {
            TextField(L("rename"), text: $newName)
            Button(L("save")) {
                if !MediaLibrary.shared.rename(item, to: newName) {
                    RecordingController.shared.notice = L("rename_failed")
                }
                dismiss()
            }
            Button(L("cancel"), role: .cancel) {}
        }
        .confirmationDialog(L("delete"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(L("delete"), role: .destructive) {
                SoundFx.dismiss()
                MediaLibrary.shared.delete([item])
                dismiss()
            }
        } message: {
            Text(Prefs.shared.trashEnabled ? L("setting_trash_sub") : item.name)
        }
    }

    private func open(_ route: Route, proReason: ProFeature? = nil) {
        dismiss()
        onMain(after: 0.35) {
            if let proReason, !Store.shared.hasPro { Router.shared.paywall = proReason }
            else { Router.shared.open(route) }
        }
    }

    private func action(_ icon: String, _ title: String, pro: Bool = false, danger: Bool = false,
                        _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 14) {
                Image(systemName: icon).frame(width: 24)
                Text(title)
                if pro { ProBadge() }
                Spacer()
            }
            .foregroundStyle(danger ? Brand.record : Brand.text)
            .padding(.horizontal, 20)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(Brand.primary.opacity(0.6))
            Text(title).font(.headline).foregroundStyle(Brand.text)
            Text(subtitle).font(.subheadline).foregroundStyle(Brand.textMuted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 24)
    }
}

/// Trash: files deleted in the last 24 hours. Restore or delete forever.
struct TrashView: View {
    @ObservedObject private var library = MediaLibrary.shared

    var body: some View {
        NavigationStack {
            List {
                if library.trash.isEmpty {
                    Text(L("setting_trash_sub")).foregroundStyle(Brand.textMuted)
                }
                ForEach(library.trash) { item in
                    HStack(spacing: 12) {
                        ThumbnailView(url: item.url, maxSide: 160).frame(width: 64, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Text(item.name).lineLimit(1)
                        Spacer()
                        Button { library.restore(item) } label: { Image(systemName: "arrow.uturn.backward") }
                            .buttonStyle(.borderless)
                    }
                    .swipeActions {
                        Button(role: .destructive) { library.deleteForever(item) } label: {
                            Label(L("delete"), systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(L("setting_trash"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("close")) { Router.shared.closeFeature() }
                }
            }
        }
        .onAppear { library.reload() }
    }
}
