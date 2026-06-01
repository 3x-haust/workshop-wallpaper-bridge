import AVFoundation
import CoreGraphics
import QuartzCore
import XCTest
@testable import WorkshopWallpaperBridgeApp

final class WallpaperContentLayoutTests: XCTestCase {
    func testContentFrameUsesWindowSizeWithZeroOrigin() {
        // Given
        let windowFrame = CGRect(x: -1470, y: 34, width: 1470, height: 923)

        // When
        let contentFrame = WallpaperContentLayout.contentFrame(for: windowFrame)

        // Then
        XCTAssertEqual(contentFrame.origin, .zero)
        XCTAssertEqual(contentFrame.size, windowFrame.size)
    }

    func testDisplayModesMapToVideoGravity() {
        XCTAssertEqual(WallpaperContentLayout.videoGravity(for: .fit), .resizeAspect)
        XCTAssertEqual(WallpaperContentLayout.videoGravity(for: .fill), .resizeAspectFill)
        XCTAssertEqual(WallpaperContentLayout.videoGravity(for: .stretch), .resize)
    }

    func testDisplayModesMapToImageContentsGravity() {
        XCTAssertEqual(WallpaperContentLayout.imageContentsGravity(for: .fit), .resizeAspect)
        XCTAssertEqual(WallpaperContentLayout.imageContentsGravity(for: .fill), .resizeAspectFill)
        XCTAssertEqual(WallpaperContentLayout.imageContentsGravity(for: .stretch), .resize)
    }
}
