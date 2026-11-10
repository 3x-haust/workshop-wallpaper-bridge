import Foundation
import XCTest
import WorkshopWallpaperCore
@testable import WorkshopWallpaperBridgeApp

final class WorkshopLocalizationTests: XCTestCase {
    private var appDirectory: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/WorkshopWallpaperBridgeApp")
    }

    @MainActor
    func testEveryWorkshopViewAndModelKeyResolvesInBothLanguages() throws {
        var requiredKeys: Set<String> = ["tab.workshop"]
        let literalKey = try NSRegularExpression(pattern: #""(workshop\.[A-Za-z0-9.]+)""#)
        for file in ["WorkshopTabView.swift", "WorkshopViewModel.swift"] {
            let source = try String(contentsOf: appDirectory.appending(path: file), encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            for match in literalKey.matches(in: source, range: range) {
                let keyRange = try XCTUnwrap(Range(match.range(at: 1), in: source))
                requiredKeys.insert(String(source[keyRange]))
            }
        }
        // These keys are composed at runtime rather than written as literals.
        requiredKeys.formUnion(["login", "search", "details", "download"].map { "workshop.working.\($0)" })
        requiredKeys.formUnion(["emailCode", "twoFactor", "mobileApproval"].map { "workshop.auth.\($0)" })
        requiredKeys.formUnion(SupportStatus.allCases.map { "workshop.support.\($0.rawValue)" })
        XCTAssertGreaterThan(requiredKeys.count, 70, "The Workshop source key scan must not silently stop matching.")

        for (code, language) in [("en", AppLanguage.english), ("ko", AppLanguage.korean)] {
            let table = try localizedTable(code)
            for key in requiredKeys.sorted() {
                let value = try XCTUnwrap(table[key], "Missing \(code) translation: \(key)")
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty \(code) translation: \(key)")
                XCTAssertEqual(Localization.string(key, language: language), value, "Bundled \(code) translation: \(key)")
            }
        }
    }

    func testEnglishAndKoreanWorkshopTablesHaveIdenticalKeysAndFormatArguments() throws {
        let english = try localizedTable("en")
        let korean = try localizedTable("ko")
        let keys = Set(english.keys.filter { $0.hasPrefix("workshop.") || $0 == "tab.workshop" })
        XCTAssertEqual(keys, Set(korean.keys.filter { $0.hasPrefix("workshop.") || $0 == "tab.workshop" }))
        let formatArgument = try NSRegularExpression(pattern: #"%(?:\d+\$)?(?:ld|@)"#)
        func arguments(in text: String) -> [String] {
            formatArgument.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
                String(text[Range($0.range, in: text)!])
            }
        }
        for key in keys.sorted() {
            let englishValue = try XCTUnwrap(english[key])
            let koreanValue = try XCTUnwrap(korean[key])
            XCTAssertEqual(arguments(in: englishValue), arguments(in: koreanValue), "Format arguments differ for \(key)")
        }
    }

    private func localizedTable(_ language: String) throws -> [String: String] {
        let url = appDirectory.appending(path: "Resources/\(language).lproj/Localizable.strings")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }
}
