import AVFoundation
import Speech

/// Auto Captions. Port of Android's `edit/asr/*` (Whisper via ONNX).
///
/// iOS ships speech recognition in the OS, so there is no model download:
/// Apple's on-device recogniser is used when the language supports it, the
/// server one otherwise. Words come back with timestamps and are grouped into
/// short YouTube-style lines, then mapped from source time to timeline time so
/// trims, splits and speed changes are respected.
enum SpeechCaptioner {
    enum Failure: LocalizedError {
        case denied, noAudio, unavailable
        var errorDescription: String? {
            switch self {
            case .denied: return L("ios_speech_denied")
            case .noAudio: return L("video_has_no_volume")
            case .unavailable: return L("captions_model_failed")
            }
        }
    }

    /// The languages offered in the picker (same six as Android).
    static let languages: [(code: String, labelKey: String)] = [
        ("en", "captions_lang_en"), ("es", "captions_lang_es"), ("fr", "captions_lang_fr"),
        ("de", "captions_lang_de"), ("hi", "captions_lang_hi"), ("pt", "captions_lang_pt")
    ]

    static func localeID(_ code: String) -> String {
        switch code {
        case "en": return "en-US"
        case "es": return "es-ES"
        case "fr": return "fr-FR"
        case "de": return "de-DE"
        case "hi": return "hi-IN"
        case "pt": return "pt-BR"
        default: return code
        }
    }

    static func captions(for timeline: Timeline, language: String) async throws -> [TextItem] {
        try await authorize()
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID(language))),
              recognizer.isAvailable else { throw Failure.unavailable }

        var out: [TextItem] = []
        var seen = Set<URL>()
        for clip in timeline.clips where !clip.isImage && !clip.reversed && !seen.contains(clip.mediaURL) {
            seen.insert(clip.mediaURL)
            let asset = AVURLAsset(url: clip.mediaURL)
            guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else { continue }
            let audioURL = try await extractAudio(asset)
            defer { try? FileManager.default.removeItem(at: audioURL) }
            let segments = try await recognize(audioURL, recognizer: recognizer)
            for line in group(segments) {
                guard let start = timeline.sourceToTimeline(line.startMs, url: clip.mediaURL) else { continue }
                let end = timeline.sourceToTimeline(line.endMs, url: clip.mediaURL) ?? start + 1500
                out.append(captionItem(line.text, start: start, end: max(start + 400, end)))
            }
        }
        if out.isEmpty && seen.isEmpty { throw Failure.noAudio }
        return out.sorted { $0.startMs < $1.startMs }
    }

    static func captionItem(_ text: String, start: Int64, end: Int64) -> TextItem {
        var item = TextItem(text: text)
        item.kind = .caption
        item.x = 0.5
        item.y = 0.82
        item.size = 0.042
        item.outline = false
        item.bgARGB = 0x99000000
        item.bgPad = 0.3
        item.startMs = start
        item.endMs = end
        return item
    }

    private static func authorize() async throws {
        let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard status == .authorized else { throw Failure.denied }
    }

    private static func extractAudio(_ asset: AVAsset) async throws -> URL {
        let out = MediaLibrary.tempURL(ext: "m4a")
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw Failure.noAudio
        }
        session.outputURL = out
        session.outputFileType = .m4a
        await session.export()
        guard session.status == .completed else { throw Failure.noAudio }
        return out
    }

    private struct Word { let text: String; let startMs: Int64; let endMs: Int64 }
    private struct Line { let text: String; let startMs: Int64; let endMs: Int64 }

    private static func recognize(_ url: URL, recognizer: SFSpeechRecognizer) async throws -> [Word] {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        if #available(iOS 16.0, *) { request.addsPunctuation = true }

        return try await withCheckedThrowingContinuation { cont in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let result, result.isFinal {
                    finished = true
                    let words = result.bestTranscription.segments.map {
                        Word(text: $0.substring,
                             startMs: Int64($0.timestamp * 1000),
                             endMs: Int64(($0.timestamp + $0.duration) * 1000))
                    }
                    cont.resume(returning: words)
                } else if let error {
                    finished = true
                    // "No speech detected" is an error on iOS; treat it as an empty result.
                    let ns = error as NSError
                    if ns.domain == "kAFAssistantErrorDomain" && (ns.code == 1110 || ns.code == 203) {
                        cont.resume(returning: [])
                    } else {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Lines of ≤ 32 characters / ≤ 3.5 s, broken at pauses longer than 0.8 s.
    private static func group(_ words: [Word]) -> [Line] {
        var lines: [Line] = []
        var current: [Word] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            lines.append(Line(text: current.map(\.text).joined(separator: " "),
                              startMs: first.startMs, endMs: last.endMs + 250))
            current.removeAll()
        }
        for w in words {
            if let first = current.first, let last = current.last {
                let text = (current.map(\.text) + [w.text]).joined(separator: " ")
                if text.count > 32 || w.startMs - last.endMs > 800 || w.endMs - first.startMs > 3500 { flush() }
            }
            current.append(w)
        }
        flush()
        return lines
    }
}
