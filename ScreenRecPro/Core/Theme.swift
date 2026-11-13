import SwiftUI
import UIKit

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }

    /// Light/dark pair, resolved by the trait collection.
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }

    var argb: UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        func c(_ v: CGFloat) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
        return (c(a) << 24) | (c(r) << 16) | (c(g) << 8) | c(b)
    }

    convenience init(argb: UInt32) {
        self.init(red: CGFloat((argb >> 16) & 0xFF) / 255,
                  green: CGFloat((argb >> 8) & 0xFF) / 255,
                  blue: CGFloat(argb & 0xFF) / 255,
                  alpha: CGFloat((argb >> 24) & 0xFF) / 255)
    }
}

/// Same palette as Android's `ui/theme/Color.kt`. Single place to retheme the app.
enum Brand {
    static let primary = Color(hex: 0x5B4BF5)
    static let primaryDark = Color(hex: 0x3B2ED6)
    static let primaryLight = Color(hex: 0xEDEBFF)
    static let accent = Color(hex: 0x00D3B8)
    static let accentSoft = Color(hex: 0xE0FBF6)
    static let pro = Color(hex: 0xF6C445)
    static let record = Color(hex: 0xFF3B30)
    static let generate = Color(hex: 0xF3C9A2)

    static let uiPrimary = UIColor(hex: 0x5B4BF5)

    static let gradient = LinearGradient(colors: [primary, accent],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)

    static let background = Color.dynamic(light: 0xF6F6F9, dark: 0x101014)
    static let surface = Color.dynamic(light: 0xFFFFFF, dark: 0x1A1A21)
    static let surfaceHigh = Color.dynamic(light: 0xEFEFF4, dark: 0x24242D)
    static let outline = Color.dynamic(light: 0xE4E4EC, dark: 0x2C2C36)
    static let text = Color.dynamic(light: 0x15151C, dark: 0xF2F2F5)
    static let textMuted = Color.dynamic(light: 0x6B6B78, dark: 0x9A9AA6)

    /// Text / sticker colour swatches (editor).
    static let editSwatches: [UInt32] = [
        0xFFFFFFFF, 0xFF111111, 0xFFE53935, 0xFFFF9800, 0xFFFFEE58,
        0xFF4CAF50, 0xFF26A69A, 0xFF26C6DA, 0xFF42A5F5, 0xFF7E57C2
    ]

    /// Brush colours (photo brush).
    static let brushSwatches: [UInt32] = [
        0xFFFFFFFF, 0xFF1A1A1A, 0xFFFF3B30, 0xFFFFD400,
        0xFF34C759, 0xFF2F9BFF, 0xFFFF2D9E, 0xFF00D3B8
    ]

    static func canvasColor(_ id: String) -> UIColor {
        switch id {
        case "black": return .black
        case "white": return UIColor(hex: 0xF4F4F6)
        case "blur": return UIColor(hex: 0x3A3A48)
        case "blur_dark": return UIColor(hex: 0x16161C)
        case "green": return UIColor(hex: 0x1B5E20)
        case "blue": return UIColor(hex: 0x0D47A1)
        default: return .black
        }
    }
}

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Brand.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Brand.outline, lineWidth: 1))
    }
}

extension View {
    func card() -> some View { modifier(CardStyle()) }
}

struct PrimaryButtonStyle: ButtonStyle {
    var color: Color = Brand.primary
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(color.opacity(configuration.isPressed ? 0.8 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
