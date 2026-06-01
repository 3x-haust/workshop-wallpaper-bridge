import XCTest
@testable import WorkshopWallpaperBridgeApp

final class SettingsWindowPlacementTests: XCTestCase {
    func testSettingsWindowCentersOnMainScreenWhenCreated() {
        // Given
        let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let windowSize = CGSize(width: 980, height: 640)

        // When
        let frame = SettingsWindowPlacement.centeredFrame(windowSize: windowSize, screenFrame: screenFrame)

        // Then
        XCTAssertEqual(frame.origin.x, 230)
        XCTAssertEqual(frame.origin.y, 130)
        XCTAssertEqual(frame.size.width, 980)
        XCTAssertEqual(frame.size.height, 640)
    }

    func testSettingsWindowCentersUsingMinimumSizeWhenCurrentFrameIsZero() {
        // Given
        let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)

        // When
        let frame = SettingsWindowPlacement.centeredFrame(
            windowSize: .zero,
            minimumWindowSize: CGSize(width: 980, height: 640),
            screenFrame: screenFrame
        )

        // Then
        XCTAssertEqual(frame.origin.x, 230)
        XCTAssertEqual(frame.origin.y, 130)
        XCTAssertEqual(frame.size.width, 980)
        XCTAssertEqual(frame.size.height, 640)
    }

    func testPreferredScreenUsesMouseLocationScreen() {
        // Given
        let left = CGRect(x: -1470, y: 0, width: 1470, height: 956)
        let right = CGRect(x: 0, y: 0, width: 1470, height: 956)

        // When
        let selected = SettingsWindowPlacement.preferredScreenFrame(
            mouseLocation: CGPoint(x: -200, y: 500),
            screenFrames: [right, left],
            fallback: right
        )

        // Then
        XCTAssertEqual(selected, left)
    }
}
