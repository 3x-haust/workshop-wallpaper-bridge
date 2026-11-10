import Foundation
import XCTest
@testable import WorkshopWallpaperBridgeApp

final class WorkshopSearchFiltersTests: XCTestCase {
    func testDefaultsRequireEveryoneAndExcludeOtherAgeTags() {
        let filters = WorkshopSearchFilters()

        XCTAssertEqual(filters.includedTags, ["Everyone"])
        XCTAssertEqual(filters.excludedTags, ["Questionable", "Mature"])
        XCTAssertEqual(filters.tagGroups, [["Everyone"]])
        XCTAssertEqual(filters.selectedCount, 3)
        XCTAssertEqual(filters.ageSummaryKey, "workshop.filter.age.everyoneOnly")
    }

    func testIncludedTagsAreORWithinCategoriesAndANDAcrossCategories() {
        var filters = WorkshopSearchFilters()
        for tag in ["Video", "Scene", "Anime", "Nature", "1920 x 1080", "3840 x 2160"] {
            filters.setSelection(.include, for: tag)
        }

        XCTAssertEqual(filters.tagGroups, [
            ["Scene", "Video"], ["Everyone"], ["Anime", "Nature"], ["1920 x 1080", "3840 x 2160"]
        ])
    }

    func testEachMiscellaneousFeatureIsAnIndependentANDGroup() {
        var filters = WorkshopSearchFilters()
        for tag in ["Audio responsive", "Customizable", "HDR"] { filters.setSelection(.include, for: tag) }
        filters.setSelection(.exclude, for: "Approved")

        XCTAssertEqual(filters.tagGroups, [["Audio responsive"], ["Customizable"], ["HDR"], ["Everyone"]])
        XCTAssertEqual(filters.excludedTags, ["Approved", "Mature", "Questionable"])
    }

    func testMultipleAgeTagsCanBeIncludedWithoutImplicitRestrictions() {
        var filters = WorkshopSearchFilters()
        filters.setSelection(.include, for: "Questionable")
        filters.setSelection(.include, for: "Mature")

        XCTAssertEqual(filters.tagGroups, [["Everyone", "Mature", "Questionable"]])
        XCTAssertEqual(filters.excludedTags, [])
        XCTAssertEqual(filters.ageSummaryKey, "workshop.filter.age.custom")
    }

    func testEveryTagTransitionKeepsIncludeAndExcludeMutuallyExclusive() {
        for tag in WorkshopSearchFilters.allTags.sorted() {
            for initial in WorkshopSearchFilters.Selection.allCases {
                for next in WorkshopSearchFilters.Selection.allCases {
                    var filters = WorkshopSearchFilters()
                    filters.setSelection(initial, for: tag)

                    filters.setSelection(next, for: tag)

                    XCTAssertEqual(filters.selection(for: tag), next, tag)
                    XCTAssertEqual(filters.includedTags.contains(tag), next == .include, tag)
                    XCTAssertEqual(filters.excludedTags.contains(tag), next == .exclude, tag)
                    XCTAssertTrue(filters.includedTags.isDisjoint(with: filters.excludedTags), tag)
                }
            }
        }
    }

    func testUnknownTagsCannotBeSelected() {
        var filters = WorkshopSearchFilters()
        filters.setSelection(.include, for: "Unknown tag")
        filters.setSelection(.exclude, for: "everyone")

        XCTAssertEqual(filters, WorkshopSearchFilters())
    }

    func testNormalizationRemovesUnknownTagsAndGivesExclusionsPrecedence() {
        var filters = WorkshopSearchFilters()
        filters.includedTags = ["Everyone", "Anime", "Mature", "Unknown tag"]
        filters.excludedTags = ["Mature", "Questionable", "Anime", "Unknown tag"]

        let normalized = filters.normalized()

        XCTAssertEqual(normalized.includedTags, ["Everyone"])
        XCTAssertEqual(normalized.excludedTags, ["Mature", "Questionable", "Anime"])
        XCTAssertEqual(normalized.normalized(), normalized)
        XCTAssertEqual(filters.tagGroups, [["Everyone"]])
        XCTAssertEqual(filters.selectedCount, 4)
        XCTAssertTrue(filters.includedTags.contains("Unknown tag"), "Normalization must return a value, not mutate its input.")
    }

    func testPersistedDecodeNormalizesAndDeduplicatesTags() throws {
        let data = Data(#"{"includedTags":["Everyone","Anime","Anime","Mature","unknown"],"excludedTags":["Mature","Questionable","unknown"]}"#.utf8)

        let filters = try JSONDecoder().decode(WorkshopSearchFilters.self, from: data)

        XCTAssertEqual(filters.includedTags, ["Everyone", "Anime"])
        XCTAssertEqual(filters.excludedTags, ["Mature", "Questionable"])
        XCTAssertEqual(try JSONDecoder().decode(WorkshopSearchFilters.self, from: JSONEncoder().encode(filters)), filters)
    }

    func testMissingPersistedFieldsUseSafeDefaultsButExplicitEmptyFieldsStayEmpty() throws {
        let missing = try JSONDecoder().decode(WorkshopSearchFilters.self, from: Data("{}".utf8))
        let empty = try JSONDecoder().decode(WorkshopSearchFilters.self, from: Data(#"{"includedTags":[],"excludedTags":[]}"#.utf8))

        XCTAssertEqual(missing, WorkshopSearchFilters())
        XCTAssertEqual(empty.includedTags, [])
        XCTAssertEqual(empty.excludedTags, [])
        XCTAssertEqual(empty.tagGroups, [])
        XCTAssertEqual(empty.selectedCount, 0)
        XCTAssertEqual(empty.ageSummaryKey, "workshop.filter.age.any")
    }

    func testMalformedPersistedTagsFailDecodeRatherThanSilentlyBroadeningSearch() {
        for json in [#"{"includedTags":"Everyone"}"#, #"{"excludedTags":[42]}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(WorkshopSearchFilters.self, from: Data(json.utf8)))
        }
    }

    func testResetRestoresSafeDefaultsAfterCustomSelections() {
        var filters = WorkshopSearchFilters()
        filters.setSelection(.exclude, for: "Everyone")
        filters.setSelection(.include, for: "Mature")
        filters.setSelection(.include, for: "HDR")

        filters.reset()

        XCTAssertEqual(filters, WorkshopSearchFilters())
    }

    func testCatalogHasAllOfficialCategoriesAndUniqueTagsAndLocalizationKeys() {
        let categories = WorkshopSearchFilters.Category.allCases
        let tags = categories.flatMap(\.tags)
        let keys = tags.map(WorkshopSearchFilters.localizationKey(for:))

        XCTAssertEqual(categories.map(\.rawValue), ["miscellaneous", "type", "ageRating", "genre", "resolution"])
        XCTAssertEqual(categories.map { $0.tags.count }, [10, 4, 3, 25, 25])
        XCTAssertEqual(tags.count, 67)
        XCTAssertEqual(Set(tags).count, tags.count)
        XCTAssertEqual(Set(keys).count, tags.count)
        XCTAssertEqual(WorkshopSearchFilters.Category.ageRating.tags, ["Everyone", "Questionable", "Mature"])
        XCTAssertFalse(tags.contains("Image"), "Image is an asset type, not a wallpaper type tag.")
    }

    @MainActor
    func testEveryCatalogAndFilterViewKeyResolvesInEnglishAndKorean() throws {
        var keys = Set(WorkshopSearchFilters.allTags.map(WorkshopSearchFilters.localizationKey(for:)))
        keys.formUnion(WorkshopSearchFilters.Category.allCases.map(\.localizationKey))
        keys.formUnion(WorkshopSearchFilters.Selection.allCases.map(\.localizationKey))
        keys.formUnion(["workshop.filter.age.everyoneOnly", "workshop.filter.age.custom", "workshop.filter.age.any"])
        let appDirectory = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/WorkshopWallpaperBridgeApp")
        let pattern = try NSRegularExpression(pattern: #""((?:workshop|common)\.[A-Za-z0-9.]+)""#)
        for file in ["WorkshopFiltersView.swift", "WorkshopTabView.swift"] {
            let source = try String(contentsOf: appDirectory.appending(path: file), encoding: .utf8)
            for match in pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                let range = try XCTUnwrap(Range(match.range(at: 1), in: source))
                keys.insert(String(source[range]))
            }
        }

        for language in [AppLanguage.english, .korean] {
            for key in keys.sorted() {
                let text = Localization.string(key, language: language)
                XCTAssertNotEqual(text, key, "Missing \(language.rawValue) translation: \(key)")
                XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, key)
            }
        }
        XCTAssertEqual(Localization.string("workshop.filter.tag.everyone", language: .korean), "전체 이용가")
        XCTAssertEqual(Localization.string("workshop.filter.tag.questionable", language: .korean), "주의 필요")
        XCTAssertEqual(Localization.string("workshop.filter.tag.mature", language: .korean), "성인")
    }
}
