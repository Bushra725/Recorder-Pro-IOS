import Foundation
import SwiftUI

/// Port of Android's LocaleManager.
///
/// * Auto-detect is not code: iOS picks the right `.lproj` from the device's
///   preferred languages because the folder exists. "System" means *don't
///   override that*.
/// * Manual override loads the chosen `.lproj` bundle directly, so the change
///   is instant (no relaunch). iOS also lists the app under
///   Settings › ScreenRec Pro › Language — both routes work.
final class Localizer: ObservableObject {
    static let shared = Localizer()

    struct Language: Identifiable, Hashable {
        let tag: String          // BCP-47
        let lproj: String        // folder name
        let nativeName: String
        var id: String { tag }
        var isRTL: Bool { tag.hasPrefix("ar") }
    }

    static let supported: [Language] = [
        Language(tag: "en", lproj: "en", nativeName: "English"),
        Language(tag: "es", lproj: "es", nativeName: "Español"),
        Language(tag: "pt-BR", lproj: "pt-BR", nativeName: "Português (Brasil)"),
        Language(tag: "fr", lproj: "fr", nativeName: "Français"),
        Language(tag: "de", lproj: "de", nativeName: "Deutsch"),
        Language(tag: "ar", lproj: "ar", nativeName: "العربية"),
        Language(tag: "hi", lproj: "hi", nativeName: "हिन्दी"),
        Language(tag: "id", lproj: "id", nativeName: "Bahasa Indonesia")
    ]

    static let systemTag = "SYSTEM"

    @Published private(set) var tag: String
    private(set) var bundle: Bundle = .main

    private init() {
        tag = AppGroup.defaults.string(forKey: "lang") ?? Self.systemTag
        bundle = Self.bundle(for: tag)
    }

    func set(_ newTag: String) {
        AppGroup.defaults.set(newTag, forKey: "lang")
        bundle = Self.bundle(for: newTag)
        tag = newTag
    }

    var isFollowingSystem: Bool { tag == Self.systemTag }

    /// The language actually on screen.
    var current: Language {
        if !isFollowingSystem, let l = Self.supported.first(where: { $0.tag == tag }) { return l }
        let preferred = Bundle.main.preferredLocalizations.first ?? "en"
        return Self.supported.first(where: { $0.lproj == preferred })
            ?? Self.supported.first(where: { preferred.hasPrefix($0.tag.prefix(2)) })
            ?? Self.supported[0]
    }

    var locale: Locale { Locale(identifier: current.tag) }

    var layoutDirection: LayoutDirection { current.isRTL ? .rightToLeft : .leftToRight }

    private static func bundle(for tag: String) -> Bundle {
        guard tag != systemTag,
              let lang = supported.first(where: { $0.tag == tag }),
              let path = Bundle.main.path(forResource: lang.lproj, ofType: "lproj"),
              let b = Bundle(path: path) else { return .main }
        return b
    }
}

/// Localised string by Android resource name (same keys on both platforms).
func L(_ key: String) -> String {
    let value = Localizer.shared.bundle.localizedString(forKey: key, value: nil, table: nil)
    if value == key, Localizer.shared.bundle != .main {
        return Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }
    return value
}

/// Localised format string, e.g. `L("streak_days", 3)`.
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), locale: Localizer.shared.locale, arguments: args)
}
