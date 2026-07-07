import Foundation

/// User-selectable UI language for the settings window.
///
/// `system` follows the user's macOS language preference (falling back to
/// English for anything other than Korean, since those are the only two
/// bundled tables). Picking Korean or English pins the UI regardless of the
/// system setting.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case korean = "ko"
    case english = "en"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .korean: return "한국어"
        case .english: return "English"
        }
    }

    fileprivate var resolvedLanguageCode: String {
        switch self {
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "en"
            return preferred.hasPrefix("ko") ? "ko" : "en"
        case .korean:
            return "ko"
        case .english:
            return "en"
        }
    }
}

/// Looks up localized UI chrome strings from the app's bundled
/// `Localizable.strings` tables, keyed off `AppLanguage` rather than the
/// process-wide system locale. Because the current `AppLanguage` is stored on
/// `AppViewModel` as a `@Published` property, switching languages in the
/// Settings tab re-resolves these strings and redraws the UI immediately,
/// with no relaunch required.
@MainActor
enum Localization {
    private static var bundleCache: [String: Bundle] = [:]

    static func string(_ key: String, language: AppLanguage) -> String {
        bundle(for: language).localizedString(forKey: key, value: key, table: nil)
    }

    private static func bundle(for language: AppLanguage) -> Bundle {
        let code = language.resolvedLanguageCode
        if let cached = bundleCache[code] {
            return cached
        }
        let resolved: Bundle
        if let path = Bundle.module.path(forResource: code, ofType: "lproj"),
           let languageBundle = Bundle(path: path) {
            resolved = languageBundle
        } else {
            resolved = .module
        }
        bundleCache[code] = resolved
        return resolved
    }
}
