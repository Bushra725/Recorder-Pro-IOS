import UIKit
import CoreImage

/// Port of Android's `OverlayFactory.renderText` / `watermark`.
///
/// Text and emoji are rasterised with UIKit's text stack (the same one that
/// draws colour emoji everywhere else on the phone), then composited by Core
/// Image. Outline and shadow are extra draw passes, as on Android.
enum TextRenderer {
    struct FontOption: Identifiable {
        let id: String
        let label: String
    }

    static let fonts: [FontOption] = [
        FontOption(id: "sans", label: "System"),
        FontOption(id: "medium", label: "Medium"),
        FontOption(id: "black", label: "Heavy"),
        FontOption(id: "serif", label: "Serif"),
        FontOption(id: "cursive", label: "Hand"),
        FontOption(id: "condensed", label: "Condensed"),
        FontOption(id: "mono", label: "Mono"),
        FontOption(id: "casual", label: "Marker"),
        FontOption(id: "seasrn", label: "Futura"),
        FontOption(id: "script", label: "Script")
    ]

    static func font(_ id: String, size: CGFloat, bold: Bool) -> UIFont {
        func named(_ n: String) -> UIFont? { UIFont(name: n, size: size) }
        let f: UIFont?
        switch id {
        case "medium": f = .systemFont(ofSize: size, weight: .medium)
        case "black": f = named("AvenirNext-Heavy") ?? .systemFont(ofSize: size, weight: .black)
        case "serif": f = named(bold ? "Georgia-Bold" : "Georgia")
        case "cursive": f = named("Noteworthy-Bold")
        case "condensed": f = named("AvenirNextCondensed-Bold")
        case "mono": f = named(bold ? "Menlo-Bold" : "Menlo-Regular")
        case "casual": f = named("MarkerFelt-Wide")
        case "seasrn": f = named("Futura-CondensedMedium")
        case "script": f = named("SnellRoundhand-Bold")
        default: f = .systemFont(ofSize: size, weight: bold ? .bold : .regular)
        }
        return f ?? .systemFont(ofSize: size, weight: bold ? .bold : .regular)
    }

    private static let cache = NSCache<NSString, UIImage>()

    /// Renders `item` for a frame `frameHeight` px tall. Cached by style + size.
    static func image(for item: TextItem, frameHeight: CGFloat) -> UIImage {
        let key = "\(item.styleKey)|\(Int(item.size * 1000))|\(Int(frameHeight))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let img = render(item, fontSize: max(6, CGFloat(item.size) * frameHeight))
        cache.setObject(img, forKey: key)
        return img
    }

    static func render(_ item: TextItem, fontSize: CGFloat) -> UIImage {
        let font = font(item.fontID, size: fontSize, bold: item.bold)
        let para = NSMutableParagraphStyle()
        para.alignment = item.align == .left ? .left : item.align == .right ? .right : .center
        para.lineSpacing = CGFloat(item.lineSpacing) * fontSize

        let fill = UIColor(argb: item.colorARGB)
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: fill,
            .paragraphStyle: para,
            .kern: CGFloat(item.letterSpacing) * fontSize
        ]
        let text = item.text.isEmpty ? " " : item.text
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: fontSize * 30, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil
        ).integral

        let strokePx = item.outline ? CGFloat(item.outlineWidth) * fontSize * 0.5 : 0
        let hasBg = (item.bgARGB >> 24) != 0 && item.bgOpacity > 0
        let pad = hasBg ? CGFloat(item.bgPad) * fontSize : 0
        let shadowRoom = item.shadow ? CGFloat(item.shadowBlur + max(abs(item.shadowDX), abs(item.shadowDY))) * fontSize / 24 : 0
        let margin = ceil(strokePx + pad + shadowRoom + 2)
        let size = CGSize(width: bounds.width + margin * 2, height: bounds.height + margin * 2)
        let textRect = CGRect(x: margin, y: margin, width: bounds.width, height: bounds.height)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            cg.setAlpha(CGFloat(item.opacity))
            cg.beginTransparencyLayer(auxiliaryInfo: nil)

            if hasBg {
                let bgRect = textRect.insetBy(dx: -pad, dy: -pad * 0.6)
                let bg = UIColor(argb: item.bgARGB).withAlphaComponent(
                    CGFloat((item.bgARGB >> 24) & 0xFF) / 255 * CGFloat(item.bgOpacity))
                bg.setFill()
                UIBezierPath(roundedRect: bgRect, cornerRadius: min(bgRect.height / 2, fontSize * 0.35)).fill()
            }

            if item.shadow {
                let shadow = NSShadow()
                shadow.shadowColor = UIColor(argb: item.shadowARGB)
                shadow.shadowBlurRadius = CGFloat(item.shadowBlur) * fontSize / 24
                shadow.shadowOffset = CGSize(width: CGFloat(item.shadowDX) * fontSize / 24,
                                             height: CGFloat(item.shadowDY) * fontSize / 24)
                var s = attrs
                s[.shadow] = shadow
                (text as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading],
                                        attributes: s, context: nil)
            }

            if item.outline && strokePx > 0 {
                var o = attrs
                o[.strokeColor] = UIColor(argb: item.outlineARGB)
                // Positive stroke width = stroke only, in percent of font size.
                o[.strokeWidth] = (strokePx * 2) / fontSize * 100
                (text as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading],
                                        attributes: o, context: nil)
            }

            attrs[.foregroundColor] = fill
            (text as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading],
                                    attributes: attrs, context: nil)
            cg.endTransparencyLayer()
        }
        return image
    }

    /// The app watermark pill: brand indigo, white bold text.
    static func watermark(_ label: String, frameHeight: CGFloat) -> UIImage {
        let key = "wm|\(label)|\(Int(frameHeight))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let fontSize = max(10, frameHeight * 0.022)
        let font = UIFont.systemFont(ofSize: fontSize, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
        let textSize = (label as NSString).size(withAttributes: attrs)
        let padH = fontSize * 0.38 * 2, padV = fontSize * 0.24 * 2
        let size = CGSize(width: ceil(textSize.width + padH * 2), height: ceil(textSize.height + padV * 2))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let img = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            Brand.uiPrimary.withAlphaComponent(0.94).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2).fill()
            (label as NSString).draw(at: CGPoint(x: padH, y: padV), withAttributes: attrs)
        }
        cache.setObject(img, forKey: key)
        return img
    }
}
