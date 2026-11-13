import CoreImage
import Foundation

/// Port of Android's `edit/studio/LookCatalog.kt` — one catalog, used by the
/// live preview, the thumbnails and the exported file, so all three agree.
///
/// A look is a few grading parameters, applied in Android's order
/// (contrast → saturation → channel gain; they do not commute):
///   contrast   -1…1, 0 = identity
///   saturation -100…100, 0 = identity
///   r, g, b    per-channel gain, 1 = identity
///   gain       overall brightness gain, 1 = identity
enum LookCategory: String, CaseIterable, Identifiable {
    case original, portrait, film, retro, mood, bw
    var id: String { rawValue }
    var labelKey: String {
        switch self {
        case .original: return "look_cat_original"
        case .portrait: return "look_cat_portrait"
        case .film: return "look_cat_film"
        case .retro: return "look_cat_retro"
        case .mood: return "look_cat_mood"
        case .bw: return "look_cat_bw"
        }
    }
}

struct Look: Identifiable, Equatable {
    let id: String
    let nameKey: String
    let category: LookCategory
    var contrast: Double = 0
    var saturation: Double = 0
    var r: Double = 1
    var g: Double = 1
    var b: Double = 1
    var gain: Double = 1

    var isNone: Bool { id == "none" }
}

enum LookCatalog {
    static let none = Look(id: "none", nameKey: "look_none", category: .original)

    static let filters: [Look] = [
        Look(id: "vivid", nameKey: "look_vivid", category: .original, contrast: 0.42, saturation: 35),
        Look(id: "natural", nameKey: "look_natural", category: .original, contrast: 0.10, saturation: 8),
        Look(id: "crisp", nameKey: "look_crisp", category: .original, contrast: 0.26, saturation: 14, gain: 1.03),
        Look(id: "bright", nameKey: "look_bright", category: .original, contrast: 0.08, saturation: 6, gain: 1.16),
        Look(id: "soft", nameKey: "look_soft", category: .original, contrast: -0.12, saturation: -6, gain: 1.06),
        Look(id: "clear", nameKey: "look_clear", category: .original, contrast: 0.18, saturation: 20, r: 0.98, b: 1.04),

        Look(id: "warm", nameKey: "look_warm", category: .portrait, r: 1.45, g: 1.08, b: 0.62),
        Look(id: "fresh", nameKey: "look_fresh", category: .portrait, contrast: 0.08, saturation: 10, r: 1.06, g: 1.02, b: 0.98),
        Look(id: "rosy", nameKey: "look_rosy", category: .portrait, saturation: 6, r: 1.14, g: 0.98, b: 1.02, gain: 1.04),
        Look(id: "peach", nameKey: "look_peach", category: .portrait, contrast: -0.06, saturation: 4, r: 1.16, g: 1.04, b: 0.92),
        Look(id: "honey", nameKey: "look_honey", category: .portrait, contrast: 0.06, saturation: 12, r: 1.18, g: 1.06, b: 0.82),

        Look(id: "kodak", nameKey: "look_kodak", category: .film, contrast: 0.20, saturation: -6, r: 1.12, g: 1.02, b: 0.90),
        Look(id: "fuji", nameKey: "look_fuji", category: .film, contrast: 0.16, saturation: 4, r: 0.94, g: 1.06, b: 1.02),
        Look(id: "cine", nameKey: "look_cine", category: .film, contrast: 0.30, saturation: -10, r: 0.96, g: 1.0, b: 1.10),
        Look(id: "indie", nameKey: "look_indie", category: .film, contrast: -0.10, saturation: -14, r: 1.04, g: 1.0, b: 1.06),

        Look(id: "retro70", nameKey: "look_retro70", category: .retro, contrast: -0.08, saturation: -8, r: 1.22, g: 1.04, b: 0.74),
        Look(id: "faded", nameKey: "look_faded", category: .retro, contrast: -0.24, saturation: -18, gain: 1.08),
        Look(id: "polaroid", nameKey: "look_polaroid", category: .retro, contrast: -0.14, saturation: -4, r: 1.10, g: 1.06, b: 0.94, gain: 1.05),
        Look(id: "sepia", nameKey: "look_sepia", category: .retro, saturation: -78, r: 1.28, g: 1.06, b: 0.74),

        Look(id: "cool", nameKey: "look_cool", category: .mood, r: 0.62, g: 1.05, b: 1.48),
        Look(id: "moody", nameKey: "look_moody", category: .mood, contrast: 0.34, saturation: -16, r: 0.92, g: 0.94, b: 1.02, gain: 0.94),
        Look(id: "teal", nameKey: "look_teal", category: .mood, contrast: 0.22, saturation: 8, r: 0.86, g: 1.06, b: 1.12),
        Look(id: "amber", nameKey: "look_amber", category: .mood, contrast: 0.18, saturation: 14, r: 1.26, g: 1.02, b: 0.78),
        Look(id: "dusk", nameKey: "look_dusk", category: .mood, contrast: 0.12, saturation: -8, r: 1.10, g: 0.94, b: 1.14, gain: 0.96),

        Look(id: "mono", nameKey: "look_mono", category: .bw, saturation: -100),
        Look(id: "ink", nameKey: "look_ink", category: .bw, contrast: 0.46, saturation: -100),
        Look(id: "silver", nameKey: "look_silver", category: .bw, contrast: -0.14, saturation: -100, gain: 1.10)
    ]

    static let effects: [Look] = [
        Look(id: "film", nameKey: "effect_film", category: .film, contrast: 0.22, saturation: -18),
        Look(id: "noir", nameKey: "effect_noir", category: .film, contrast: 0.52, saturation: -100, gain: 0.96),
        Look(id: "bleach", nameKey: "effect_bleach", category: .film, contrast: 0.40, saturation: -46, gain: 1.10),

        Look(id: "vintage", nameKey: "effect_vintage", category: .retro, saturation: -12, r: 1.28, g: 1.08, b: 0.62),
        Look(id: "fade", nameKey: "effect_fade", category: .retro, contrast: -0.22, r: 0.86, g: 0.86, b: 0.90),
        Look(id: "haze", nameKey: "effect_haze", category: .retro, contrast: -0.30, saturation: -10, r: 1.06, g: 1.04, b: 1.0, gain: 1.12),

        Look(id: "dramatic", nameKey: "effect_dramatic", category: .mood, contrast: 0.55, r: 0.92, g: 0.92, b: 0.88),
        Look(id: "dream", nameKey: "effect_dream", category: .mood, saturation: 12, r: 0.78, g: 1.05, b: 1.28),
        Look(id: "frost", nameKey: "effect_frost", category: .mood, contrast: 0.14, saturation: -20, r: 0.88, g: 1.0, b: 1.22, gain: 1.06),
        Look(id: "sunset", nameKey: "effect_sunset", category: .mood, contrast: 0.10, saturation: 18, r: 1.34, g: 0.98, b: 0.76),
        Look(id: "midnight", nameKey: "effect_midnight", category: .mood, contrast: 0.30, saturation: -24, r: 0.82, g: 0.90, b: 1.18, gain: 0.88),

        Look(id: "glow", nameKey: "effect_glow", category: .portrait, saturation: 22, r: 1.18, g: 1.18, b: 1.18),
        Look(id: "blush", nameKey: "effect_blush", category: .portrait, contrast: -0.08, saturation: 10, r: 1.16, g: 1.0, b: 1.04, gain: 1.06),
        Look(id: "neon", nameKey: "effect_neon", category: .mood, contrast: 0.36, saturation: 58, r: 1.08, g: 0.96, b: 1.20)
    ]

    private static let filtersByID = Dictionary(uniqueKeysWithValues: filters.map { ($0.id, $0) })
    private static let effectsByID = Dictionary(uniqueKeysWithValues: effects.map { ($0.id, $0) })

    static func filter(_ id: String?) -> Look { id.flatMap { filtersByID[$0] } ?? none }
    static func effect(_ id: String?) -> Look { id.flatMap { effectsByID[$0] } ?? none }

    static func categories(of looks: [Look]) -> [LookCategory] {
        LookCategory.allCases.filter { cat in looks.contains { $0.category == cat } }
    }

    static func looks(_ looks: [Look], in category: LookCategory) -> [Look] {
        looks.filter { $0.category == category }
    }

    /// The colour matrix for a look at `strength` (0…1). Strength moves each
    /// *parameter* toward identity, so half-strength Mono is half desaturated
    /// rather than washed out.
    static func matrix(for look: Look, strength: Double) -> ColorMatrix {
        var m = ColorMatrix.identity
        guard !look.isNone, strength > 0 else { return m }
        let s = min(1, max(0, strength))

        let c = look.contrast * s
        if c != 0 { m = m.concat(.contrast(c)) }

        if look.saturation != 0 {
            let full = max(0, 1 + look.saturation / 100)
            m = m.concat(.saturation(lerp(1, full, s)))
        }

        let r = lerp(1, look.r * look.gain, s)
        let g = lerp(1, look.g * look.gain, s)
        let b = lerp(1, look.b * look.gain, s)
        if r != 1 || g != 1 || b != 1 { m = m.concat(.scale(r, g, b)) }
        return m
    }

    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
}

/// 4×5 colour matrix in Android's layout (rows R, G, B, A; columns r, g, b, a, offset),
/// with offsets in 0…1 units instead of 0…255.
struct ColorMatrix: Equatable {
    var m: [Double]   // 20 values

    static let identity = ColorMatrix(m: [1, 0, 0, 0, 0,
                                          0, 1, 0, 0, 0,
                                          0, 0, 1, 0, 0,
                                          0, 0, 0, 1, 0])

    var isIdentity: Bool { self == .identity }

    static func scale(_ r: Double, _ g: Double, _ b: Double) -> ColorMatrix {
        ColorMatrix(m: [r, 0, 0, 0, 0,
                        0, g, 0, 0, 0,
                        0, 0, b, 0, 0,
                        0, 0, 0, 1, 0])
    }

    /// Android: scale = 1 + c, translate = 128 * (1 - scale) on 0…255.
    static func contrast(_ c: Double) -> ColorMatrix {
        let s = 1 + c
        let t = 0.5 * (1 - s)
        return ColorMatrix(m: [s, 0, 0, 0, t,
                               0, s, 0, 0, t,
                               0, 0, s, 0, t,
                               0, 0, 0, 1, 0])
    }

    /// Same luminance weights as android.graphics.ColorMatrix.setSaturation.
    static func saturation(_ sat: Double) -> ColorMatrix {
        let inv = 1 - sat
        let r = 0.213 * inv, g = 0.715 * inv, b = 0.072 * inv
        return ColorMatrix(m: [r + sat, g, b, 0, 0,
                               r, g + sat, b, 0, 0,
                               r, g, b + sat, 0, 0,
                               0, 0, 0, 1, 0])
    }

    static func brightness(_ v: Double) -> ColorMatrix {
        ColorMatrix(m: [1, 0, 0, 0, v,
                        0, 1, 0, 0, v,
                        0, 0, 1, 0, v,
                        0, 0, 0, 1, 0])
    }

    /// `self` then `next` (like Android's postConcat): result = next × self.
    func concat(_ next: ColorMatrix) -> ColorMatrix {
        var out = [Double](repeating: 0, count: 20)
        let a = next.m, b = m
        for row in 0..<4 {
            for col in 0..<5 {
                var v = 0.0
                for k in 0..<4 { v += a[row * 5 + k] * b[k * 5 + col] }
                if col == 4 { v += a[row * 5 + 4] }
                out[row * 5 + col] = v
            }
        }
        return ColorMatrix(m: out)
    }

    func apply(to image: CIImage) -> CIImage {
        guard !isIdentity else { return image }
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: m[0], y: m[1], z: m[2], w: m[3]),
            "inputGVector": CIVector(x: m[5], y: m[6], z: m[7], w: m[8]),
            "inputBVector": CIVector(x: m[10], y: m[11], z: m[12], w: m[13]),
            "inputAVector": CIVector(x: m[15], y: m[16], z: m[17], w: m[18]),
            "inputBiasVector": CIVector(x: m[4], y: m[9], z: m[14], w: m[19])
        ])
    }

    /// Editor "Adjust" panel: brightness, contrast, saturation, warmth (-1…1 each).
    static func adjust(brightness: Double, contrast: Double, saturation: Double, warmth: Double) -> ColorMatrix {
        var m = ColorMatrix.identity
        if brightness != 0 { m = m.concat(.brightness(brightness * 0.25)) }
        if contrast != 0 { m = m.concat(.contrast(contrast * 0.5)) }
        if saturation != 0 { m = m.concat(.saturation(max(0, 1 + saturation))) }
        if warmth != 0 { m = m.concat(.scale(1 + warmth * 0.18, 1 + warmth * 0.03, 1 - warmth * 0.18)) }
        return m
    }
}
