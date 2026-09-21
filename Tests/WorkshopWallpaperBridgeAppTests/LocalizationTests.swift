import Foundation
import XCTest
@testable import WorkshopWallpaperBridgeApp

final class LocalizationTests: XCTestCase {
    @MainActor
    func testPackagedResourceBundleCandidateUsesContentsResourcesBeforeAppRoot() {
        let appURL = URL(filePath: "/Applications/Workshop Wallpaper Bridge.app", directoryHint: .isDirectory)
        let resourcesURL = appURL.appending(path: "Contents/Resources", directoryHint: .isDirectory)

        let candidates = Localization.resourceBundleCandidates(
            bundleURL: appURL,
            resourceURL: resourcesURL
        )

        XCTAssertEqual(
            candidates,
            [
                resourcesURL.appending(
                    path: "WorkshopWallpaperBridge_WorkshopWallpaperBridgeApp.bundle",
                    directoryHint: .isDirectory
                ),
                appURL.appending(
                    path: "WorkshopWallpaperBridge_WorkshopWallpaperBridgeApp.bundle",
                    directoryHint: .isDirectory
                )
            ]
        )
    }

    @MainActor
    func testPackagedResourceBundleResolvesLocalizedStrings() throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let resourcesURL = temporaryDirectory.appending(path: "Contents/Resources", directoryHint: .isDirectory)
        let bundleURL = resourcesURL.appending(
            path: "WorkshopWallpaperBridge_WorkshopWallpaperBridgeApp.bundle",
            directoryHint: .isDirectory
        )
        let koreanURL = bundleURL.appending(path: "ko.lproj", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: koreanURL, withIntermediateDirectories: true)
        try "\"tab.settings\" = \"설정\";\n".write(
            to: koreanURL.appending(path: "Localizable.strings"),
            atomically: true,
            encoding: .utf8
        )

        let candidates = Localization.resourceBundleCandidates(
            bundleURL: temporaryDirectory,
            resourceURL: resourcesURL
        )
        let resolved = try XCTUnwrap(Localization.resolveResourceBundle(candidates: candidates))
        let localizedBundle = try XCTUnwrap(
            resolved.path(forResource: "ko", ofType: "lproj").flatMap(Bundle.init(path:))
        )

        XCTAssertEqual(
            localizedBundle.localizedString(forKey: "tab.settings", value: nil, table: nil),
            "설정"
        )
    }

    func testSystemLanguageMapsKoreanAndSimplifiedChineseOntoBundledTables() {
        XCTAssertEqual(AppLanguage.bundledLanguageCode(forPreferredLanguages: ["ko-KR"]), "ko")
        XCTAssertEqual(AppLanguage.bundledLanguageCode(forPreferredLanguages: ["zh-Hans-CN"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.bundledLanguageCode(forPreferredLanguages: ["zh-CN"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.bundledLanguageCode(forPreferredLanguages: ["zh-SG"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.bundledLanguageCode(forPreferredLanguages: ["zh"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.bundledLanguageCode(forPreferredLanguages: ["zh-Hant-TW"]), "en")
        XCTAssertEqual(AppLanguage.bundledLanguageCode(forPreferredLanguages: ["zh-TW"]), "en")
        XCTAssertEqual(AppLanguage.bundledLanguageCode(forPreferredLanguages: ["en-US"]), "en")
        XCTAssertEqual(AppLanguage.bundledLanguageCode(forPreferredLanguages: ["fr-FR"]), "en")
        XCTAssertEqual(AppLanguage.bundledLanguageCode(forPreferredLanguages: []), "en")
    }

    func testLocalizationTablesShareTheSameKeys() throws {
        let tables = ["en", "ko", "zh-Hans"]
        let keySets = try tables.map { language -> (String, Set<String>) in
            let contents = try String(
                contentsOfFile: "Sources/WorkshopWallpaperBridgeApp/Resources/\(language).lproj/Localizable.strings"
            )
            return (language, localizationKeys(in: contents))
        }
        let englishKeys = try XCTUnwrap(keySets.first?.1)
        XCTAssertFalse(englishKeys.isEmpty)
        for (language, keys) in keySets.dropFirst() {
            XCTAssertEqual(keys, englishKeys, "\(language).lproj is missing or has extra keys")
        }
        XCTAssertTrue(englishKeys.contains("settings.language.simplifiedChinese"))
    }

    private func localizationKeys(in contents: String) -> Set<String> {
        let pattern = #"^\"([^\"]+)\"\s*="#
        let regex = try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        let range = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        return Set(regex.matches(in: contents, range: range).compactMap { match in
            Range(match.range(at: 1), in: contents).map { String(contents[$0]) }
        })
    }
}
