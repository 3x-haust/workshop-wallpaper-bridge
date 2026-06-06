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

    func testScaledContentFrameMatchesFitFillStretchSceneLayout() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let sceneSize = CGSize(width: 400, height: 200)

        XCTAssertEqual(
            WallpaperContentLayout.scaledContentFrame(for: sceneSize, in: bounds, displayMode: .fit),
            CGRect(x: 0, y: 0, width: 1000, height: 500)
        )
        XCTAssertEqual(
            WallpaperContentLayout.scaledContentFrame(for: sceneSize, in: bounds, displayMode: .fill),
            CGRect(x: 0, y: 0, width: 1000, height: 500)
        )
        XCTAssertEqual(
            WallpaperContentLayout.scaledContentFrame(for: sceneSize, in: bounds, displayMode: .stretch),
            CGRect(x: 0, y: 0, width: 1000, height: 500)
        )

        let tallSceneSize = CGSize(width: 400, height: 400)
        XCTAssertEqual(
            WallpaperContentLayout.scaledContentFrame(for: tallSceneSize, in: bounds, displayMode: .fit),
            CGRect(x: 250, y: 0, width: 500, height: 500)
        )
        XCTAssertEqual(
            WallpaperContentLayout.scaledContentFrame(for: tallSceneSize, in: bounds, displayMode: .fill),
            CGRect(x: 0, y: -250, width: 1000, height: 1000)
        )
        XCTAssertEqual(
            WallpaperContentLayout.scaledContentFrame(for: tallSceneSize, in: bounds, displayMode: .stretch),
            CGRect(x: 0, y: 0, width: 1000, height: 500)
        )
    }
}
