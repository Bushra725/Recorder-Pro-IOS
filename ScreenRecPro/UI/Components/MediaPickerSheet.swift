import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// What a pick is for. Decides which media types and whether multi-select.
enum MediaPickerPurpose: String, Identifiable {
    case editVideo, aiEdit, trim, compress, merge, captions, editPhoto, gif, fileTransfer
    case brushPhoto, facecam, importScreenshots

    var id: String { rawValue }
    var videos: Bool { ![.editPhoto, .brushPhoto, .importScreenshots].contains(self) }
    var photos: Bool { [.editPhoto, .brushPhoto, .importScreenshots, .merge, .fileTransfer].contains(self) }
    var multi: Bool { [.compress, .merge, .fileTransfer, .importScreenshots].contains(self) }
    /// Screenshots come from Photos; there is nothing in the library to pick yet.
    var photosOnly: Bool { self == .importScreenshots }

    var hintKey: String? {
        switch self {
        case .compress: return "compress_pick_hint"
        case .merge: return "merge_need_two"
        default: return nil
        }
    }
}

/// Android opens the system picker for every Edit-tab tool. On iOS the user
/// can pick from this app's own recordings or from Photos.
struct MediaPickerSheet: View {
    let purpose: MediaPickerPurpose
    let onPicked: ([URL]) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var library = MediaLibrary.shared
    @State private var selected: [URL] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var loading = false

    private var items: [MediaItem] {
        var list: [MediaItem] = []
        if purpose.videos { list += library.videos }
        if purpose.photos { list += library.photos.filter { $0.kind == .photo } }
        return list.sorted { $0.createdAt > $1.createdAt }
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    PhotosPicker(selection: $photoItems,
                                 maxSelectionCount: purpose.multi ? 20 : 1,
                                 matching: filter) {
                        Label(L("ios_choose_from_photos"), systemImage: "photo.on.rectangle.angled")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Brand.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                    }
                    if let hint = purpose.hintKey {
                        Text(L(hint)).font(.footnote).foregroundStyle(Brand.textMuted)
                    }
                    if purpose.multi && !selected.isEmpty {
                        Text("\(selected.count)").font(.headline.monospacedDigit()).padding(.top, 4)
                        LazyVGrid(columns: columns, spacing: 4) {
                            ForEach(selected, id: \.path) { url in
                                selectedCell(url)
                            }
                        }
                    }
                    if !purpose.photosOnly && !items.isEmpty {
                        Text(L("app_name")).font(.headline).padding(.top, 4)
                        LazyVGrid(columns: columns, spacing: 4) {
                            ForEach(items) { item in cell(item) }
                        }
                    }
                }
                .padding(16)
            }
            .background(Brand.background.ignoresSafeArea())
            .overlay { if loading { WorkingOverlay(message: L("please_wait")) } }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("cancel")) { dismiss() } }
                if purpose.multi {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L("done")) { finish(selected) }.disabled(selected.isEmpty)
                    }
                }
            }
            .onChange(of: photoItems) { items in
                guard !items.isEmpty else { return }
                Task { await importFromPhotos(items) }
            }
        }
        .background(Brand.background)
        .onAppear { AdsManager.shared.suppressAppOpenBriefly(120) }
    }

    private var title: String {
        switch purpose {
        case .editVideo: return L("edit_video")
        case .aiEdit: return L("edit_with_ai")
        case .trim: return L("trim_video")
        case .compress: return L("video_compress")
        case .merge: return L("merge_video")
        case .captions: return L("auto_captions")
        case .editPhoto: return L("edit_photo")
        case .brushPhoto: return L("tool_brush")
        case .gif: return L("video_to_gif")
        case .fileTransfer: return L("file_transfer")
        case .facecam: return L("tool_facecam")
        case .importScreenshots: return L("ios_import_screenshots")
        }
    }

    private var filter: PHPickerFilter {
        switch (purpose.videos, purpose.photos) {
        case (true, true): return .any(of: [.videos, .images])
        case (true, false): return .videos
        default: return purpose == .importScreenshots ? .any(of: [.screenshots, .images]) : .images
        }
    }

    private func cell(_ item: MediaItem) -> some View {
        let index = selected.firstIndex(of: item.url)
        return thumb(url: item.url, durationMs: item.isVideo ? item.durationMs : nil, index: index)
            .onTapGesture {
                SoundFx.tick()
                if purpose.multi {
                    if let index { selected.remove(at: index) } else { selected.append(item.url) }
                } else {
                    finish([item.url])
                }
            }
    }

    private func selectedCell(_ url: URL) -> some View {
        let index = selected.firstIndex(of: url)
        return thumb(url: url, durationMs: nil, index: index)
            .onTapGesture {
                SoundFx.tick()
                if let index { selected.remove(at: index) }
            }
    }

    /// Square grid tile. `.fit` (not `.fill`) on the container keeps portrait
    /// frames from collapsing into a thin floating strip.
    private func thumb(url: URL, durationMs: Int64?, index: Int?) -> some View {
        ThumbnailView(url: url, maxSide: 300)
            .frame(minWidth: 0, maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topTrailing) {
                if purpose.multi {
                    ZStack {
                        Circle().fill(index != nil ? Brand.primary : Color.black.opacity(0.35)).frame(width: 24, height: 24)
                        if let index { Text("\(index + 1)").font(.caption.bold()).foregroundStyle(.white) }
                    }
                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
                    .padding(6)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let durationMs {
                    Text(Format.duration(durationMs)).font(.caption2.bold()).foregroundStyle(.white)
                        .padding(3).background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4)).padding(4)
                }
            }
    }

    private func importFromPhotos(_ items: [PhotosPickerItem]) async {
        loading = true
        var urls: [URL] = []
        for item in items {
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }),
               let movie = try? await item.loadTransferable(type: PickedMovie.self) {
                urls.append(movie.url)
            } else if let data = try? await item.loadTransferable(type: Data.self) {
                let isPNG = item.supportedContentTypes.contains { $0.conforms(to: .png) }
                let url = MediaLibrary.tempURL(ext: isPNG ? "png" : "jpg")
                if isPNG {
                    try? data.write(to: url)
                } else if let img = UIImage(data: data), let jpg = img.jpegData(compressionQuality: 0.95) {
                    try? jpg.write(to: url)
                }
                if FileManager.default.fileExists(atPath: url.path) { urls.append(url) }
            }
        }
        loading = false
        photoItems = []
        if purpose.multi && !purpose.photosOnly {
            selected += urls
            if !urls.isEmpty && purpose != .merge && purpose != .compress { finish(selected) }
        } else if !urls.isEmpty {
            finish(urls)
        }
    }

    private func finish(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onPicked(urls) }
    }
}

/// A video file copied out of Photos into the work folder.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dst = MediaLibrary.tempURL(ext: ext)
            try FileManager.default.copyItem(at: received.file, to: dst)
            return PickedMovie(url: dst)
        }
    }
}
