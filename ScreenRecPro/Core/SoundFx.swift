import AVFoundation
import UIKit

/// Port of Android's `core/SoundFx.kt`: every UI sound is synthesised at
/// runtime from a few sine partials with an exponential decay — no audio
/// files shipped. Retune a cue by editing two numbers.
///
/// Uses the `.ambient` session category: mixes with other audio and respects
/// the silent switch, as UI sounds should.
enum SoundFx {
    private struct Partial { let hz: Double; let gain: Double; let startMs: Int }

    private static let launchCue = [Partial(hz: 523.25, gain: 0.55, startMs: 0),
                                    Partial(hz: 783.99, gain: 0.50, startMs: 90),
                                    Partial(hz: 1046.50, gain: 0.35, startMs: 180)]
    private static let startCue = [Partial(hz: 659.25, gain: 0.6, startMs: 0),
                                   Partial(hz: 987.77, gain: 0.5, startMs: 70)]
    private static let stopCue = [Partial(hz: 783.99, gain: 0.6, startMs: 0),
                                  Partial(hz: 523.25, gain: 0.5, startMs: 70)]
    private static let rewardCue = [Partial(hz: 523.25, gain: 0.45, startMs: 0),
                                    Partial(hz: 659.25, gain: 0.45, startMs: 70),
                                    Partial(hz: 783.99, gain: 0.45, startMs: 140),
                                    Partial(hz: 1046.50, gain: 0.40, startMs: 210)]
    private static let tickCue = [Partial(hz: 1318.51, gain: 0.35, startMs: 0)]
    private static let dismissCue = [Partial(hz: 330, gain: 0.5, startMs: 0),
                                     Partial(hz: 220, gain: 0.45, startMs: 60)]
    private static let shutterCue = [Partial(hz: 1900, gain: 0.72, startMs: 0),
                                     Partial(hz: 950, gain: 0.40, startMs: 28),
                                     Partial(hz: 1700, gain: 0.55, startMs: 85)]

    static func launch() { play(launchCue, 520) }
    static func recordStart() { confirmHaptic(); play(startCue, 340) }
    static func recordStop() { confirmHaptic(); play(stopCue, 340) }
    static func reward() { confirmHaptic(); play(rewardCue, 700) }
    static func tick() { tapHaptic(); play(tickCue, 140) }
    static func dismiss() { dismissHaptic(); play(dismissCue, 300) }
    static func shutter() { tapHaptic(); play(shutterCue, 220) }

    static func tapHaptic() { haptic(.light) }
    static func confirmHaptic() { haptic(.medium) }
    static func dismissHaptic() { haptic(.rigid) }

    private static func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard Prefs.shared.haptics else { return }
        DispatchQueue.main.async { UIImpactFeedbackGenerator(style: style).impactOccurred() }
    }

    // MARK: - Synthesis

    private static let sampleRate: Double = 44_100
    private static let engine = AVAudioEngine()
    private static let player = AVAudioPlayerNode()
    private static let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private static let queue = DispatchQueue(label: "soundfx")
    private static var ready = false
    private static var cache: [Int: AVAudioPCMBuffer] = [:]

    private static func prepare() -> Bool {
        if ready { return true }
        do {
            let session = AVAudioSession.sharedInstance()
            // Do not downgrade a .playback session the player/editor set up.
            if session.category == .soloAmbient {
                try session.setCategory(.ambient, options: [.mixWithOthers])
            }
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            try engine.start()
            ready = true
        } catch {
            ready = false
        }
        return ready
    }

    private static func play(_ partials: [Partial], _ durationMs: Int) {
        guard Prefs.shared.soundEffects else { return }
        queue.async {
            guard prepare() else { return }
            if !engine.isRunning { try? engine.start() }
            let key = partials.map { Int($0.hz) }.reduce(durationMs) { $0 &* 31 &+ $1 }
            let buffer = cache[key] ?? render(partials, durationMs)
            cache[key] = buffer
            guard let buffer else { return }
            player.scheduleBuffer(buffer, at: nil, options: [])
            if !player.isPlaying { player.play() }
        }
    }

    private static func render(_ partials: [Partial], _ durationMs: Int) -> AVAudioPCMBuffer? {
        let total = Int(sampleRate) * durationMs / 1000
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)),
              let out = buf.floatChannelData?[0] else { return nil }
        buf.frameLength = AVAudioFrameCount(total)
        for i in 0..<total { out[i] = 0 }

        for p in partials {
            let offset = Int(sampleRate) * p.startMs / 1000
            let tail = max(1, total - offset)
            // 5 time constants over the remaining length: inaudible by the end.
            let decay = 5.0 / Double(tail)
            guard offset < total else { continue }
            for i in offset..<total {
                let n = Double(i - offset)
                let env = exp(-decay * n)
                let phase = 2.0 * Double.pi * p.hz * n / sampleRate
                // A touch of 2nd and 3rd harmonic gives the "struck" quality.
                let s = (sin(phase) + 0.30 * sin(2 * phase) + 0.12 * sin(3 * phase)) / 1.42
                out[i] = max(-1, min(1, out[i] + Float(s * env * p.gain * 0.8)))
            }
        }
        // 2 ms fade at both ends: a step from/to a non-zero sample clicks.
        let fade = Int(sampleRate * 0.002)
        for i in 0..<min(fade, total) {
            let g = Float(i) / Float(fade)
            out[i] *= g
            out[total - 1 - i] *= g
        }
        return buf
    }
}
