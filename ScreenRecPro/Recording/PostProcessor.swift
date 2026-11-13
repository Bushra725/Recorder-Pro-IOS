import AVFoundation
import UIKit

/// Port of Android's PostProcessService + the result handling in RecorderState.
///
/// The extension drops raw captures into the App Group inbox. When the app is
/// running (or comes back to the foreground) this moves them into the library,
/// burning in the watermark / applying the region crop / mixing app + mic audio
/// on the way, updates streaks and achievements, and raises the result popup.
@MainActor
final class PostProcessor: ObservableObject {
    static let shared = PostProcessor()

    /// The newest finished recording, for the "Edit this video?" popup.
    @Published var lastVideo: URL?
    /// The newest screenshot, for the "Screenshot saved" popup.
    @Published var lastScreenshot: URL?
    @Published private(set) var working = false
    @Published var workingMessage: String?

    private var running = false

    /// True while finished captures are waiting in the App Group inbox.
    nonisolated static var hasPendingCaptures: Bool {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: AppGroup.inbox.path)) ?? []
        return files.contains { $0.hasSuffix(".mov") || $0.hasSuffix(".mp4") }
    }

    func collect() {
        guard !running else { return }
        running = true
        Task {
            await collectScreenshots()
            await collectRecordings()
            running = false
        }
    }

    private func collectScreenshots() async {
        let files = (try? FileManager.default.contentsOfDirectory(at: AppGroup.screenshotInbox,
                                                                   includingPropertiesForKeys: nil)) ?? []
        var newest: URL?
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where file.pathExtension.lowercased() == "png" {
            guard let data = try? Data(contentsOf: file) else { continue }
            if let saved = await MediaLibrary.shared.addImageData(data, ext: "png", prefix: "Screenshot") {
                newest = saved
            }
            try? FileManager.default.removeItem(at: file)
        }
        if let newest {
            if !Prefs.shared.hideToasts { RecordingController.shared.notice = L("toast_screenshot_saved") }
            if !Prefs.shared.hideResultPopup { lastScreenshot = newest }
        }
    }

    private func collectRecordings() async {
        // Never touch a file the extension may still be writing.
        if LiveClock.status != .idle && LiveClock.isExtensionAlive { return }

        let files = (try? FileManager.default.contentsOfDirectory(at: AppGroup.inbox,
                                                                   includingPropertiesForKeys: nil)) ?? []
        let videos = files.filter { ["mov", "mp4"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !videos.isEmpty else { return }

        working = true
        workingMessage = Prefs.shared.watermark ? L("watermark_working_body") : L("please_wait")
        defer { working = false; workingMessage = nil }

        var newest: URL?
        for raw in videos {
            let sidecarURL = raw.appendingPathExtension("json")
            let sidecar = (try? Data(contentsOf: sidecarURL)).flatMap { try? JSONDecoder().decode(CaptureSidecar.self, from: $0) }
            if sidecar == nil && !Prefs.shared.autoRepair {
                cleanup(raw, sidecarURL)
                continue
            }
            if let region = sidecar?.region, !region.isEmpty { workingMessage = L("cropping_region") }
            let watermark = Prefs.shared.watermark ? Prefs.shared.watermarkLabel : nil
            do {
                let finished = try await Exporter.finishCapture(raw, sidecar: sidecar, watermark: watermark)
                if let saved = await MediaLibrary.shared.addVideo(from: finished, move: true) {
                    newest = saved
                    let ms = sidecar?.durationMs ?? VideoMeta.read(saved).durationMs
                    Engagement.shared.onRecordingFinished(durationMs: ms)
                }
            } catch {
                if !Prefs.shared.hideToasts { RecordingController.shared.notice = L("toast_nothing_captured") }
            }
            cleanup(raw, sidecarURL)
        }

        if let newest {
            if Prefs.shared.hideResultPopup {
                if !Prefs.shared.hideToasts { RecordingController.shared.notice = L("toast_saved") }
            } else {
                lastVideo = newest
            }
        }
    }

    private func cleanup(_ raw: URL, _ sidecar: URL) {
        try? FileManager.default.removeItem(at: raw)
        try? FileManager.default.removeItem(at: sidecar)
    }
}
