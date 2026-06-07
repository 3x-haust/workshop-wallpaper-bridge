import XCTest

final class DocumentationTests: XCTestCase {
    func testEnglishReadmeUsesConciseOpenSourceStructure() throws {
        let readme = try String(contentsOfFile: "README.md")
        let expectedHeadings = [
            "## Demo",
            "## Download",
            "## Use It",
            "## What Works",
            "## Screen Saver",
            "## Build From Source",
            "## CLI",
            "## Troubleshooting",
            "## Project Boundaries",
            "## License"
        ]

        assertHeadings(expectedHeadings, appearInOrderIn: readme)

        let removedSlopHeadings = [
            "## Highlights",
            "## Project Status",
            "## Playback Behavior",
            "## Performance Snapshot",
            "## Screen Saver And Still Wallpaper",
            "## What This App Will Not Do",
            "## Install From Source",
            "## Build A Local App Bundle",
            "## Developer ID Signing And Notarization"
        ]
        for heading in removedSlopHeadings {
            XCTAssertFalse(readme.contains(heading), "README should not keep the old section: \(heading)")
        }
    }

    func testKoreanReadmeMirrorsEnglishStructure() throws {
        let readme = try String(contentsOfFile: "README.ko.md")
        let expectedHeadings = [
            "## 데모",
            "## 다운로드",
            "## 사용 방법",
            "## 지원 범위",
            "## 화면 보호기",
            "## 소스에서 빌드",
            "## CLI",
            "## 문제 해결",
            "## 프로젝트 경계",
            "## 라이선스"
        ]

        assertHeadings(expectedHeadings, appearInOrderIn: readme)

        let removedSlopHeadings = [
            "## 주요 기능",
            "## 프로젝트 상태",
            "## 재생 방식",
            "## 성능 스냅샷",
            "## 화면 보호기와 정적 배경화면",
            "## 하지 않는 것",
            "## 소스에서 실행",
            "## 로컬 앱 번들 만들기",
            "## Developer ID 서명과 공증"
        ]
        for heading in removedSlopHeadings {
            XCTAssertFalse(readme.contains(heading), "Korean README should not keep the old section: \(heading)")
        }
    }

    func testReadmesKeepSafetyAndSupportFacts() throws {
        let english = try String(contentsOfFile: "README.md")
        let korean = try String(contentsOfFile: "README.ko.md")

        for readme in [english, korean] {
            XCTAssertTrue(readme.contains("431960"))
            XCTAssertTrue(readme.contains("MP4"))
            XCTAssertTrue(readme.contains("scene.pkg"))
            XCTAssertTrue(readme.contains("ffmpeg"))
            XCTAssertTrue(readme.contains("Steam Workshop"))
            XCTAssertTrue(readme.contains("DRM"))
            XCTAssertTrue(readme.contains("~/Library/Application Support/WorkshopWallpaperBridge"))
        }
    }

    func testDownloadSiteUsesLatestReleaseAsset() throws {
        let site = try String(contentsOfFile: "docs/index.html")

        XCTAssertTrue(site.contains("https://api.github.com/repos/3x-haust/workshop-wallpaper-bridge/releases/latest"))
        XCTAssertTrue(site.contains("https://github.com/3x-haust/workshop-wallpaper-bridge/releases/latest/download/WorkshopWallpaperBridge-macOS-arm64.dmg"))
        XCTAssertTrue(site.contains("WorkshopWallpaperBridge-macOS-arm64.dmg"))
        XCTAssertTrue(site.contains("assets/workshop-wallpaper-bridge-demo.gif"))
        XCTAssertTrue(site.contains("latest-release-download"))
        XCTAssertTrue(site.contains("download"))
        XCTAssertTrue(site.contains("Use it"))
        XCTAssertTrue(site.contains("steamapps/workshop/content/431960"))
        XCTAssertTrue(site.contains("Play on Desktop"))
    }

    func testCiWorkflowRunsSwiftTests() throws {
        let workflow = try String(contentsOfFile: ".github/workflows/ci.yml")

        XCTAssertTrue(workflow.contains("swift test"))
        XCTAssertTrue(workflow.contains("pull_request"))
        XCTAssertTrue(workflow.contains("push"))
        XCTAssertTrue(workflow.contains("macos-15"))
    }

    func testReleaseWorkflowPublishesDmgAndChecksum() throws {
        let workflow = try String(contentsOfFile: ".github/workflows/release.yml")

        XCTAssertTrue(workflow.contains("Scripts/package-app.sh"))
        XCTAssertTrue(workflow.contains("shasum -a 256"))
        XCTAssertTrue(workflow.contains("gh release upload"))
        XCTAssertTrue(workflow.contains("WorkshopWallpaperBridge-macOS-arm64.dmg"))
        XCTAssertTrue(workflow.contains("contents: write"))
    }

    func testReleaseWorkflowRequiresSignedNotarizedGatekeeperCheckedDmg() throws {
        let workflow = try String(contentsOfFile: ".github/workflows/release.yml")

        XCTAssertTrue(workflow.contains("MACOS_DEVELOPER_ID_APPLICATION_CERTIFICATE_BASE64"))
        XCTAssertTrue(workflow.contains("MACOS_DEVELOPER_ID_APPLICATION_CERTIFICATE_PASSWORD"))
        XCTAssertTrue(workflow.contains("MACOS_NOTARY_APPLE_ID"))
        XCTAssertTrue(workflow.contains("MACOS_NOTARY_TEAM_ID"))
        XCTAssertTrue(workflow.contains("MACOS_NOTARY_PASSWORD"))
        XCTAssertTrue(workflow.contains("xcrun notarytool store-credentials"))
        XCTAssertTrue(workflow.contains("SIGN_IDENTITY: Developer ID Application"))
        XCTAssertTrue(workflow.contains("NOTARY_PROFILE: workshop-wallpaper-bridge-notary"))
        XCTAssertTrue(workflow.contains("REQUIRE_SIGNING: \"1\""))
        XCTAssertTrue(workflow.contains("REQUIRE_NOTARIZATION: \"1\""))
    }

    func testPackagingScriptVerifiesNotarizedQuarantinedApp() throws {
        let script = try String(contentsOfFile: "Scripts/package-app.sh")

        XCTAssertTrue(script.contains("REQUIRE_NOTARIZATION=\"${REQUIRE_NOTARIZATION:-0}\""))
        XCTAssertTrue(script.contains("verify_gatekeeper_accepts_quarantined_app_from_dmg"))
        XCTAssertTrue(script.contains("spctl --assess --type execute"))
        XCTAssertTrue(script.contains("com.apple.quarantine"))
    }

    func testPackagedAppDefaultsToCurrentReleaseVersion() throws {
        let script = try String(contentsOfFile: "Scripts/package-app.sh")

        XCTAssertTrue(script.contains("APP_VERSION=\"${APP_VERSION:-1.1.3}\""))
        XCTAssertTrue(script.contains("BUNDLE_VERSION=\"${BUNDLE_VERSION:-10}\""))
    }

    private func assertHeadings(_ headings: [String], appearInOrderIn readme: String) {
        var searchStart = readme.startIndex
        for heading in headings {
            guard let range = readme.range(of: heading, range: searchStart..<readme.endIndex) else {
                XCTFail("Missing or out-of-order README heading: \(heading)")
                return
            }
            searchStart = range.upperBound
        }
    }
}
