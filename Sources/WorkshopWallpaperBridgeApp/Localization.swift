import Foundation

/// User-selectable UI language for the settings window.
///
/// `system` follows the user's macOS language preference (falling back to
/// English unless the preferred language is Korean or Simplified Chinese).
/// Picking a specific language pins the UI regardless of the system setting.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case korean = "ko"
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .korean: return "한국어"
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        }
    }

    fileprivate var resolvedLanguageCode: String {
        switch self {
        case .system:
            return Self.bundledLanguageCode(forPreferredLanguages: Locale.preferredLanguages)
        case .korean:
            return "ko"
        case .simplifiedChinese:
            return "zh-Hans"
        case .english:
            return "en"
        }
    }

    /// Maps a macOS preferred-language list onto a bundled `.lproj` code.
    static func bundledLanguageCode(forPreferredLanguages preferredLanguages: [String]) -> String {
        let preferred = preferredLanguages.first ?? "en"
        let normalized = preferred.replacingOccurrences(of: "_", with: "-").lowercased()
        if normalized.hasPrefix("ko") {
            return "ko"
        }
        if isSimplifiedChinese(normalized) {
            return "zh-Hans"
        }
        return "en"
    }

    private static func isSimplifiedChinese(_ identifier: String) -> Bool {
        if identifier.hasPrefix("zh-hans") || identifier.hasPrefix("zh-cn") || identifier.hasPrefix("zh-sg") {
            return true
        }
        if identifier.hasPrefix("zh-hant")
            || identifier.hasPrefix("zh-tw")
            || identifier.hasPrefix("zh-hk")
            || identifier.hasPrefix("zh-mo") {
            return false
        }
        return identifier == "zh"
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
    private static let resourceBundle: Bundle = {
        resolveResourceBundle(candidates: resourceBundleCandidates()) ?? .module
    }()

    static func string(_ key: String, language: AppLanguage) -> String {
        bundle(for: language).localizedString(forKey: key, value: key, table: nil)
    }

    static func resourceBundleCandidates(
        bundleURL: URL = Bundle.main.bundleURL,
        resourceURL: URL? = Bundle.main.resourceURL
    ) -> [URL] {
        let bundleName = "WorkshopWallpaperBridge_WorkshopWallpaperBridgeApp.bundle"
        var candidates: [URL] = []
        if let resourceURL {
            candidates.append(resourceURL.appending(path: bundleName, directoryHint: .isDirectory))
        }
        candidates.append(bundleURL.appending(path: bundleName, directoryHint: .isDirectory))
        return candidates
    }

    static func resolveResourceBundle(candidates: [URL]) -> Bundle? {
        candidates.lazy.compactMap(Bundle.init(url:)).first
    }

    private static func bundle(for language: AppLanguage) -> Bundle {
        let code = language.resolvedLanguageCode
        if let cached = bundleCache[code] {
            return cached
        }
        let resolved: Bundle
        if let path = resourceBundle.path(forResource: code, ofType: "lproj"),
           let languageBundle = Bundle(path: path) {
            resolved = languageBundle
        } else {
            resolved = resourceBundle
        }
        bundleCache[code] = resolved
        return resolved
    }
}
