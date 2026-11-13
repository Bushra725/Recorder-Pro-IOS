import SwiftUI

/// Port of Android's `edit/PhotoStickers.kt` — same four packs, same labels.
enum StickerPack: String, CaseIterable, Identifiable {
    case trending, cute, quotes, emoji
    var id: String { rawValue }
    var labelKey: String {
        switch self {
        case .trending: return "sticker_trending"
        case .cute: return "sticker_cute"
        case .quotes: return "sticker_quotes"
        case .emoji: return "sticker_emoji"
        }
    }
}

struct Sticker: Identifiable, Hashable {
    let text: String
    let pack: StickerPack
    var size: Double = 0.075
    var colorARGB: UInt32 = 0xFFFFFFFF
    var fontID = "sans"
    var outline = false
    var bgARGB: UInt32 = 0
    var shadow = false
    var id: String { pack.rawValue + text }

    /// The overlay item it drops onto the canvas.
    var item: TextItem {
        var t = TextItem(text: text)
        t.kind = .sticker
        t.y = 0.56
        t.size = size
        t.colorARGB = colorARGB
        t.fontID = fontID
        t.outline = outline
        t.bgARGB = bgARGB
        t.shadow = shadow
        t.bold = true
        return t
    }
}

enum StickerCatalog {
    static let emoji = ["😀", "😂", "🥰", "😎", "🤔", "😱", "🥳", "😭",
                        "🔥", "💯", "✨", "⭐", "❤️", "👍", "👎", "👏",
                        "🎉", "🎯", "💡", "⚡", "🚀", "🏆", "💰", "🎮",
                        "📢", "👀", "🙌", "🤯", "😴", "🤝", "✅", "❌"]

    static let all: [Sticker] = {
        var out: [Sticker] = []
        func add(_ pack: StickerPack, size: Double, color: UInt32, font: String, bg: UInt32,
                 shadow: Bool, _ labels: [String]) {
            out += labels.map { Sticker(text: $0, pack: pack, size: size, colorARGB: color,
                                        fontID: font, bgARGB: bg, shadow: shadow) }
        }
        add(.trending, size: 0.05, color: 0xFFFFFFFF, font: "cursive", bg: 0, shadow: true,
            ["✨ main character", "💅 slay", "🌸 soft life", "🎀 coquette",
             "🦋 that girl", "🍒 cherry coded", "⭐ it's giving", "🌙 night owl"])
        add(.trending, size: 0.046, color: 0xFFFF7AB6, font: "condensed", bg: 0, shadow: true,
            ["POV", "GRWM", "IYKYK", "OTP"])
        add(.cute, size: 0.075, color: 0xFFFFFFFF, font: "sans", bg: 0, shadow: false,
            ["🩷", "💖", "💗", "💕", "🫶", "🥰", "🐱", "🐰",
             "🌸", "🌼", "🍓", "🧁", "☁️", "⭐", "🌈", "🧸"])
        add(.quotes, size: 0.042, color: 0xFF15151C, font: "script", bg: 0xFFF4F4F6, shadow: false,
            ["good vibes only", "romanticize it", "do it scared", "made with love",
             "stay golden", "be the vibe", "collect moments", "you got this"])
        add(.emoji, size: 0.1, color: 0xFFFFFFFF, font: "sans", bg: 0, shadow: false, emoji)
        return out
    }()
}

/// Pack chips + 4-column grid.
struct StickerGrid: View {
    @Binding var pack: StickerPack
    let onAdd: (Sticker) -> Void
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(StickerPack.allCases) { p in
                        Chip(title: L(p.labelKey), selected: pack == p) { pack = p }
                    }
                }
            }
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(StickerCatalog.all.filter { $0.pack == pack }) { s in
                        Button { SoundFx.tick(); onAdd(s) } label: {
                            Text(s.text)
                                .font(.system(size: pack == .emoji || pack == .cute ? 26 : 12, weight: .semibold))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
            .frame(maxHeight: 200)
        }
    }
}
