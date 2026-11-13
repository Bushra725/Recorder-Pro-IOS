import AVFoundation
import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers

/// One file in the app's library.
struct MediaItem: Identifiable, Hashable {
    enum Kind: String { case video, photo, gif }

    let url: URL
    let kind: Kind
    var name: String
    var createdAt: Date
    var sizeBytes: Int64
    var durationMs: Int64 = 0
    var pixelSize: CGSize = .zero

    var id: URL { url }
    var isVideo: Bool { kind == .video }
}

/// Port of Android's `data/MediaRepository.kt`.
///
/// Android writes through MediaStore into Movies/ScreenRecPro and
/// Pictures/ScreenRecPro. iOS has no shared folder like that, so the library is
/// the app's own Documents/ScreenRecPro (visible in the Files app because
/// UIFileSharingEnabled is on), and — when "Save to gallery" is on — every new
/// file is also copied into Photos.
@MainActor
final class MediaLibrary: ObservableObject {
    static let shared = MediaLibrary()

    @Published private(set) var videos: [MediaItem] = []
    @Published private(set) var photos: [MediaItem] = []
    @Published private(set) var trash: [MediaItem] = []
    @Published private(set) var usedBytes: Int64 = 0

    nonisolated static var root: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("ScreenRecPro", isDirectory: true)
    }
    nonisolated static var videosDir: URL { ensure(root.appendingPathComponent("Videos", isDirectory: true)) }
    nonisolated static var photosDir: URL { ensure(root.appendingPathComponent("Photos", isDirectory: true)) }
    nonisolated static var trashDir: URL {
        // Library/, not Documents/: deleted files should not show in the Files app.
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return ensure(lib.appendingPathComponent("Trash", isDirectory: true))
    }
    nonisolated static var draftsDir: URL {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return ensure(lib.appendingPathComponent("Drafts", isDirectory: true))
    }
    nonisolated static var workDir: URL {
        ensure(FileManager.default.temporaryDirectory.appendingPathComponent("work", isDirectory: true))
    }

    nonisolated private static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    nonisolated static func newVideoURL(prefix: String = "ScreenRecPro") -> URL {
        videosDir.appendingPathComponent("\(prefix)_\(SharedFormat.stamp()).mp4").uniqued()
    }

    nonisolated static func newPhotoURL(ext: String = "png", prefix: String = "Screenshot") -> URL {
        photosDir.appendingPathComponent("\(prefix)_\(SharedFormat.stamp()).\(ext)").uniqued()
    }

    nonisolated static func tempURL(ext: String) -> URL {
        workDir.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }

    private init() {}

    // MARK: - Loading

    func reload() {
        Task.detached(priority: .userInitiated) {
            let videos = Self.scan(Self.videosDir, kinds: [.video])
            let photos = Self.scan(Self.photosDir, kinds: [.photo, .gif])
            let trash = Self.scan(Self.trashDir, kinds: [.video, .photo, .gif])
            let used = (videos + photos).reduce(Int64(0)) { $0 + $1.sizeBytes }
            await MainActor.run {
                self.videos = videos
                self.photos = photos
                self.trash = trash
                self.usedBytes = used
            }
        }
    }

    nonisolated private static func scan(_ dir: URL, kinds: [MediaItem.Kind]) -> [MediaItem] {
        let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey, .isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                                   options: [.skipsHiddenFiles])) ?? []
        var out: [MediaItem] = []
        for url in files {
            guard let kind = kindOf(url), kinds.contains(kind) else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            var item = MediaItem(url: url, kind: kind,
                                 name: url.deletingPathExtension().lastPathComponent,
                                 createdAt: values?.creationDate ?? Date(),
                                 sizeBytes: Int64(values?.fileSize ?? 0))
            if kind == .video {
                let meta = VideoMeta.read(url)
                item.durationMs = meta.durationMs
                item.pixelSize = meta.size
            } else if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                let w = props[kCGImagePropertyPixelWidth] as? CGFloat ?? 0
                let h = props[kCGImagePropertyPixelHeight] as? CGFloat ?? 0
                item.pixelSize = CGSize(width: w, height: h)
            }
            out.append(item)
        }
        return out.sorted { $0.createdAt > $1.createdAt }
    }

    nonisolated static func kindOf(_ url: URL) -> MediaItem.Kind? {
        switch url.pathExtension.lowercased() {
        case "mp4", "mov", "m4v": return .video
        case "png", "jpg", "jpeg", "heic": return .photo
        case "gif": return .gif
        default: return nil
        }
    }

    // MARK: - Adding

    /// Moves (or copies) a finished video into the library and, if enabled, Photos.
    @discardableResult
    func addVideo(from src: URL, move: Bool = true, prefix: String = "ScreenRecPro") async -> URL? {
        let dst = Self.newVideoURL(prefix: prefix)
        do {
            if move { try FileManager.default.moveItem(at: src, to: dst) }
            else { try FileManager.default.copyItem(at: src, to: dst) }
        } catch {
            return nil
        }
        if Prefs.shared.saveToGallery { await Self.saveToPhotos(dst, isVideo: true) }
        reload()
        return dst
    }

    @discardableResult
    func addImage(_ image: UIImage, prefix: String = "Screenshot") async -> URL? {
        guard let data = image.pngData() else { return nil }
        return await addImageData(data, ext: "png", prefix: prefix)
    }

    @discardableResult
    func addImageData(_ data: Data, ext: String, prefix: String) async -> URL? {
        let dst = Self.newPhotoURL(ext: ext, prefix: prefix)
        do { try data.write(to: dst) } catch { return nil }
        if Prefs.shared.saveToGallery { await Self.saveToPhotos(dst, isVideo: false) }
        reload()
        return dst
    }

    /// Saves into the Photos library with add-only access (no read access to
    /// the user's other pictures is ever requested).
    nonisolated static func saveToPhotos(_ url: URL, isVideo: Bool) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return }
        try? await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            let opts = PHAssetResourceCreationOptions()
            opts.originalFilename = url.lastPathComponent
            req.addResource(with: isVideo ? .video : .photo, fileURL: url, options: opts)
        }
    }

    // MARK: - Editing the library

    func rename(_ item: MediaItem, to newName: String) -> Bool {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        guard !clean.isEmpty else { return false }
        let dst = item.url.deletingLastPathComponent()
            .appendingPathComponent(clean).appendingPathExtension(item.url.pathExtension)
        guard !FileManager.default.fileExists(atPath: dst.path) else { return false }
        do { try FileManager.default.moveItem(at: item.url, to: dst) } catch { return false }
        reload()
        return true
    }

    /// Moves to Trash (kept 24 h) when the Trash setting is on, else deletes.
    func delete(_ items: [MediaItem]) {
        for item in items {
            if Prefs.shared.trashEnabled {
                let dst = Self.trashDir.appendingPathComponent(item.url.lastPathComponent).uniqued()
                try? FileManager.default.moveItem(at: item.url, to: dst)
                // Remember when it was trashed; creation date stays the original's.
                try? (dst as NSURL).setResourceValue(Date(), forKey: .contentModificationDateKey)
            } else {
                try? FileManager.default.removeItem(at: item.url)
            }
        }
        reload()
    }

    func restore(_ item: MediaItem) {
        let dir = item.kind == .video ? Self.videosDir : Self.photosDir
        try? FileManager.default.moveItem(at: item.url, to: dir.appendingPathComponent(item.url.lastPathComponent).uniqued())
        reload()
    }

    func deleteForever(_ item: MediaItem) {
        try? FileManager.default.removeItem(at: item.url)
        reload()
    }

    /// Empties trash entries older than 24 hours. Called at launch.
    nonisolated static func purgeTrash() {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: trashDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in files {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if date < cutoff { try? FileManager.default.removeItem(at: url) }
        }
        // Scratch files from interrupted exports.
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("work"))
    }

    var freeBytes: Int64 {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}

extension URL {
    /// Appends " (2)", " (3)" … until the path is free.
    func uniqued() -> URL {
        guard FileManager.default.fileExists(atPath: path) else { return self }
        let base = deletingPathExtension().lastPathComponent
        let ext = pathExtension
        let dir = deletingLastPathComponent()
        var n = 2
        while true {
            let candidate = dir.appendingPathComponent("\(base) (\(n))").appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}

enum VideoMeta {
    struct Info { var durationMs: Int64; var size: CGSize; var hasAudio: Bool; var bitrate: Float; var fps: Float }

    /// Synchronous metadata read (fine off the main thread).
    static func read(_ url: URL) -> Info {
        let asset = AVURLAsset(url: url)
        let duration = CMTimeGetSeconds(asset.duration)
        let track = asset.tracks(withMediaType: .video).first
        var size = CGSize.zero
        if let t = track {
            let r = CGRect(origin: .zero, size: t.naturalSize).applying(t.preferredTransform)
            size = CGSize(width: abs(r.width), height: abs(r.height))
        }
        return Info(durationMs: duration.isFinite ? Int64(duration * 1000) : 0,
                    size: size,
                    hasAudio: !asset.tracks(withMediaType: .audio).isEmpty,
                    bitrate: track?.estimatedDataRate ?? 0,
                    fps: track?.nominalFrameRate ?? 30)
    }
}

enum Format {
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func duration(_ ms: Int64) -> String {
        let s = Int(ms / 1000)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }

    static func preciseDuration(_ ms: Int64) -> String {
        let s = Int(ms / 1000)
        return String(format: "%02d:%02d.%d", s / 60, s % 60, Int((ms % 1000) / 100))
    }

    /// "1080P" style label from pixel size (short edge).
    static func resolution(_ size: CGSize) -> String {
        let short = Int(min(size.width, size.height))
        guard short > 0 else { return "" }
        return "\(short)P"
    }
}
