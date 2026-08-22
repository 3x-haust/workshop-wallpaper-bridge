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
}
