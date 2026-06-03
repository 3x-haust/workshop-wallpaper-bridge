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
