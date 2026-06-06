import Foundation
import XCTest
@testable import WorkshopWallpaperBridgeApp

final class UpdateCheckerTests: XCTestCase {
    func testReleaseVersionComparesSemanticComponents() {
        XCTAssertGreaterThan(AppReleaseVersion("v1.10.0"), AppReleaseVersion("1.9.9"))
        XCTAssertEqual(AppReleaseVersion("v1.2.0"), AppReleaseVersion("1.2"))
        XCTAssertLessThan(AppReleaseVersion("1.1.9"), AppReleaseVersion("1.2.0"))
    }

    func testGitHubReleaseResultSelectsDmgAssetWhenNewerVersionExists() throws {
        // Given
        let json = """
        {
          "tag_name": "v1.2.0",
          "html_url": "https://example.com/releases/tag/v1.2.0",
          "assets": [
            {
              "name": "WorkshopWallpaperBridge-macOS-arm64.dmg.sha256",
              "browser_download_url": "https://example.com/checksum"
            },
            {
              "name": "WorkshopWallpaperBridge-macOS-arm64.dmg",
              "browser_download_url": "https://example.com/app.dmg"
            }
          ]
        }
        """

        // When
        let result = try GitHubReleaseUpdateChecker.result(from: Data(json.utf8), currentVersion: "1.1.0")

        // Then
        guard case .updateAvailable(let update) = result else {
            return XCTFail("Expected updateAvailable")
        }
        XCTAssertEqual(update.version, "1.2.0")
        XCTAssertEqual(update.tagName, "v1.2.0")
        XCTAssertEqual(update.releaseURL.absoluteString, "https://example.com/releases/tag/v1.2.0")
        XCTAssertEqual(update.downloadURL?.absoluteString, "https://example.com/app.dmg")
    }

    func testGitHubReleaseResultReportsUpToDateWhenInstalledVersionMatchesLatest() throws {
        // Given
        let json = """
        {
          "tag_name": "v1.1.1",
          "html_url": "https://example.com/releases/tag/v1.1.1",
          "assets": []
        }
        """

        // When
        let result = try GitHubReleaseUpdateChecker.result(from: Data(json.utf8), currentVersion: "1.1.1")

        // Then
        XCTAssertEqual(result, .upToDate(currentVersion: "1.1.1", latestVersion: "1.1.1"))
    }

    func testGitHubReleaseResultFallsBackToDirectDmgDownloadWhenAssetListIsMissing() throws {
        // Given
        let json = """
        {
          "tag_name": "v1.2.0",
          "html_url": "https://example.com/releases/tag/v1.2.0",
          "assets": []
        }
        """

        // When
        let result = try GitHubReleaseUpdateChecker.result(from: Data(json.utf8), currentVersion: "1.1.1")

        // Then
        guard case .updateAvailable(let update) = result else {
            return XCTFail("Expected updateAvailable")
        }
        XCTAssertEqual(
            update.downloadURL?.absoluteString,
            "https://github.com/3x-haust/workshop-wallpaper-bridge/releases/download/v1.2.0/WorkshopWallpaperBridge-macOS-arm64.dmg"
        )
    }
}
