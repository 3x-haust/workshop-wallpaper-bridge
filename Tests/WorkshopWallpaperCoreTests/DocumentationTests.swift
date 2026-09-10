import XCTest

final class DocumentationTests: XCTestCase {
    func testEnglishReadmeUsesConciseOpenSourceStructure() throws {
        let readme = try String(contentsOfFile: "README.md")
        let expectedHeadings = [
            "## Quick Links",
            "## Demo",
            "## Download",
            "## Use It",
            "## What Works",
            "## Screen Saver",
            "## Build From Source",
            "## CLI",
            "## Troubleshooting",
            "## Project Boundaries",
            "## Maintainers And Contributors",
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
            "## 빠른 링크",
            "## 데모",
            "## 다운로드",
            "## 사용 방법",
            "## 지원 범위",
            "## 화면 보호기",
            "## 소스에서 빌드",
            "## CLI",
            "## 문제 해결",
            "## 프로젝트 경계",
            "## 메인테이너와 기여자",
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
            XCTAssertTrue(readme.contains("dev-di-tto"))
            XCTAssertTrue(readme.contains("ohjack83-lab"))
            XCTAssertTrue(readme.contains("~/Library/Application Support/WorkshopWallpaperBridge"))
        }
    }

    func testDownloadSiteUsesLatestReleaseAsset() throws {
        let site = try String(contentsOfFile: "docs/index.html")
        let releaseAPI = "https://api.github.com/repos/3x-haust/" +
            "workshop-wallpaper-bridge/releases/latest"
        let directDownload = "https://github.com/3x-haust/workshop-wallpaper-bridge/" +
            "releases/latest/download/WorkshopWallpaperBridge-macOS-arm64.dmg"

        XCTAssertTrue(site.contains(releaseAPI))
        XCTAssertTrue(site.contains(directDownload))
        XCTAssertTrue(site.contains("WorkshopWallpaperBridge-macOS-arm64.dmg"))
        XCTAssertTrue(site.contains("assets/workshop-wallpaper-bridge-demo.gif"))
        XCTAssertTrue(site.contains("id=\"demo-toggle\""))
        XCTAssertTrue(site.contains("aria-controls=\"demo-animation\""))
        XCTAssertTrue(site.contains("demoAnimation.hidden"))
        XCTAssertTrue(site.contains("latest-release-download"))
        XCTAssertTrue(site.contains("download"))
        XCTAssertTrue(site.contains("ad-hoc signed"))
        XCTAssertTrue(site.contains("xattr -r -d com.apple.quarantine"))
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

    func testReleaseWorkflowPublishesReleaseArchiveAndChecksum() throws {
        let workflow = try String(contentsOfFile: ".github/workflows/release.yml")
        let releaseNotesScript = try String(contentsOfFile: "Scripts/render-release-notes.sh")

        XCTAssertTrue(workflow.contains("Scripts/package-app.sh"))
        XCTAssertTrue(workflow.contains("Scripts/render-release-notes.sh"))
        XCTAssertTrue(workflow.contains("artifact_name=\"$(basename \"$artifact\")\""))
        XCTAssertTrue(workflow.contains("shasum -a 256 \"$artifact_name\""))
        XCTAssertTrue(workflow.contains("gh release upload"))
        XCTAssertTrue(workflow.contains("gh release edit"))
        XCTAssertTrue(releaseNotesScript.contains("<!-- unsigned-install:start -->"))
        XCTAssertTrue(releaseNotesScript.contains("<!-- unsigned-install:end -->"))
        XCTAssertTrue(releaseNotesScript.contains("xattr -r -d com.apple.quarantine"))
        XCTAssertTrue(workflow.contains("[ \"$existing_notes\" != \"$updated_notes\" ]"))
        XCTAssertTrue(workflow.contains("-name \"*.dmg\""))
        XCTAssertTrue(workflow.contains("-name \"*.zip\""))
        XCTAssertTrue(workflow.contains("RELEASE_ARTIFACT"))
        XCTAssertTrue(workflow.contains("RELEASE_CHECKSUM"))
        XCTAssertTrue(workflow.contains("SIGNING_AVAILABLE"))
        XCTAssertTrue(workflow.contains("contents: write"))
    }

    func testReleaseWorkflowRejectsUnsafeDispatchTags() throws {
        let workflow = try String(contentsOfFile: ".github/workflows/release.yml")

        XCTAssertTrue(workflow.contains("format('refs/tags/{0}', inputs.tag)"))
        XCTAssertTrue(workflow.contains("REQUESTED_TAG:"))
        XCTAssertTrue(workflow.contains("[[ ! \"$tag\" =~ ^v[0-9]+\\.[0-9]+\\.[0-9]+$ ]]"))
        XCTAssertFalse(workflow.contains("tag=\"${{ inputs.tag }}\""))
    }

    func testReleaseWorkflowSupportsSigningWhenSecretsExistAndUnsignedFallbackOtherwise() throws {
        let workflow = try String(contentsOfFile: ".github/workflows/release.yml")
        let unsignedWarning = "Release signing secrets are absent; " +
            "publishing a DMG with an ad-hoc signed app"
        let signingEnvironment = [
            "SIGN_IDENTITY: ${{ steps.signing.outputs.available == 'true' && " +
                "'Developer ID Application' || '' }}",
            "NOTARY_PROFILE: ${{ steps.signing.outputs.available == 'true' && " +
                "'workshop-wallpaper-bridge-notary' || '' }}",
            "REQUIRE_SIGNING: ${{ steps.signing.outputs.available == 'true' && '1' || '0' }}",
            "REQUIRE_NOTARIZATION: ${{ steps.signing.outputs.available == 'true' && '1' || '0' }}"
        ]

        XCTAssertTrue(workflow.contains("Resolve release signing mode"))
        XCTAssertTrue(workflow.contains("available=false"))
        XCTAssertTrue(workflow.contains(unsignedWarning))
        XCTAssertTrue(workflow.contains("MACOS_DEVELOPER_ID_APPLICATION_CERTIFICATE_BASE64"))
        XCTAssertTrue(workflow.contains("MACOS_DEVELOPER_ID_APPLICATION_CERTIFICATE_PASSWORD"))
        XCTAssertTrue(workflow.contains("MACOS_NOTARY_APPLE_ID"))
        XCTAssertTrue(workflow.contains("MACOS_NOTARY_TEAM_ID"))
        XCTAssertTrue(workflow.contains("MACOS_NOTARY_PASSWORD"))
        XCTAssertTrue(workflow.contains("is required when any release signing secret is configured"))
        XCTAssertTrue(workflow.contains("xcrun notarytool store-credentials"))
        XCTAssertTrue(workflow.contains("if: steps.signing.outputs.available == 'true'"))
        for environmentVariable in signingEnvironment {
            XCTAssertTrue(workflow.contains(environmentVariable))
        }
    }

    func testProfileRosterIsGeneratedFromGitHubMetadata() throws {
        let english = try String(contentsOfFile: "README.md")
        let korean = try String(contentsOfFile: "README.ko.md")
        let workflow = try String(contentsOfFile: ".github/workflows/update-profile-roster.yml")
        let script = try String(contentsOfFile: "Scripts/update-profile-roster.mjs")
        let maintenanceNotes = try String(contentsOfFile: "docs/open-source-maintenance.md")

        for readme in [english, korean] {
            XCTAssertTrue(readme.contains("<!-- profile-roster:start -->"))
            XCTAssertTrue(readme.contains("<!-- profile-roster:end -->"))
            XCTAssertTrue(readme.contains("avatars.githubusercontent.com"))
        }

        XCTAssertTrue(workflow.contains("node Scripts/update-profile-roster.mjs"))
        XCTAssertTrue(workflow.contains("contents: write"))
        XCTAssertTrue(workflow.contains("pull-requests: write"))
        XCTAssertTrue(workflow.contains("automation/update-profile-roster"))
        XCTAssertTrue(workflow.contains("gh pr create"))
        XCTAssertTrue(maintenanceNotes.contains("creates or reuses a pull request"))
        XCTAssertTrue(maintenanceNotes.contains("intentionally omits commit counts"))
        XCTAssertTrue(script.contains("/collaborators?affiliation=direct&per_page=100"))
        XCTAssertTrue(script.contains("permissions.push === true"))
        XCTAssertTrue(script.contains("/contributors?anon=false&per_page=100"))
        XCTAssertFalse(script.contains("contributionLabel"))
    }

    func testPackagingScriptVerifiesNotarizedQuarantinedApp() throws {
        let script = try String(contentsOfFile: "Scripts/package-app.sh")

        XCTAssertTrue(script.contains("REQUIRE_NOTARIZATION=\"${REQUIRE_NOTARIZATION:-0}\""))
        XCTAssertTrue(script.contains("verify_gatekeeper_accepts_quarantined_app_from_dmg"))
        XCTAssertTrue(script.contains("spctl --assess --type execute"))
        XCTAssertTrue(script.contains("com.apple.quarantine"))
    }

    func testPackagingScriptAdHocSignsUnsignedAppAfterAddingResources() throws {
        let script = try String(contentsOfFile: "Scripts/package-app.sh")
        let resourceDestination = "RESOURCE_BUNDLE_DESTINATION=\"$RESOURCES_DIR/" +
            "WorkshopWallpaperBridge_WorkshopWallpaperBridgeApp.bundle\""
        let signedDylib = "codesign --force --options runtime --timestamp " +
            "--sign \"$SIGN_IDENTITY\" \"$dylib\""

        XCTAssertTrue(script.contains(resourceDestination))
        XCTAssertTrue(script.contains(signedDylib))
        XCTAssertTrue(script.contains("codesign --force --sign - \"$MACOS_DIR/wwbctl\""))
        XCTAssertTrue(script.contains("codesign --force --sign - \"$MACOS_DIR/Workshop Wallpaper Bridge\""))
        XCTAssertTrue(script.contains("codesign --force --sign - \"$SAVER_DIR\""))
        XCTAssertTrue(script.contains("codesign --force --sign - \"$APP_DIR\""))
        XCTAssertTrue(script.contains("codesign --verify --strict --verbose=2 \"$SAVER_DIR\""))
        XCTAssertTrue(script.contains("codesign --verify --deep --strict --verbose=2 \"$APP_DIR\""))
    }

    func testPackagedAppDefaultsToCurrentReleaseVersion() throws {
        let script = try String(contentsOfFile: "Scripts/package-app.sh")

        XCTAssertTrue(script.contains("APP_VERSION=\"${APP_VERSION:-1.4.1}\""))
        XCTAssertTrue(script.contains("BUNDLE_VERSION=\"${BUNDLE_VERSION:-13}\""))
    }

    func testFrameDiffScriptBoundsImageAllocationBeforeDecodingPixels() throws {
        let script = try String(contentsOfFile: "Scripts/scene-frame-diff.swift")

        XCTAssertTrue(script.contains("maximumImagePixels"))
        XCTAssertTrue(script.contains("checkedPixelCount"))
        XCTAssertTrue(script.contains("imageTooLarge"))
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
