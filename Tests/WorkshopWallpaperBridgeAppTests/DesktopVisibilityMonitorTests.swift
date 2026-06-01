import CoreGraphics
import XCTest
@testable import WorkshopWallpaperBridgeApp

final class DesktopVisibilityMonitorTests: XCTestCase {
    func testFinderDesktopHostDoesNotPausePlayback() {
        // Given
        let windows = [
            DesktopVisibilityMonitor.WindowSnapshot(
                ownerName: "Finder",
                processId: 100,
                layer: 0,
                alpha: 1,
                bounds: CGRect(x: 0, y: 33, width: 1470, height: 923)
            )
        ]

        // When
        let visible = DesktopVisibilityMonitor.isDesktopVisible(windows: windows, currentProcessId: 200)

        // Then
        XCTAssertTrue(visible)
    }

    func testStageManagerShelfDoesNotPausePlayback() {
        // Given
        let windows = [
            DesktopVisibilityMonitor.WindowSnapshot(
                ownerName: "WindowManager",
                processId: 100,
                layer: 0,
                alpha: 1,
                bounds: CGRect(x: 15, y: 420, width: 144, height: 149)
            )
        ]

        // When
        let visible = DesktopVisibilityMonitor.isDesktopVisible(windows: windows, currentProcessId: 200)

        // Then
        XCTAssertTrue(visible)
    }

    func testLargeUserAppWindowPausesPlayback() {
        // Given
        let windows = [
            DesktopVisibilityMonitor.WindowSnapshot(
                ownerName: "Code",
                processId: 100,
                layer: 0,
                alpha: 1,
                bounds: CGRect(x: 100, y: 100, width: 900, height: 700)
            )
        ]

        // When
        let visible = DesktopVisibilityMonitor.isDesktopVisible(windows: windows, currentProcessId: 200)

        // Then
        XCTAssertFalse(visible)
    }

    func testCurrentAppSettingsWindowDoesNotPausePlayback() {
        // Given
        let windows = [
            DesktopVisibilityMonitor.WindowSnapshot(
                ownerName: "Workshop Wallpaper Bridge",
                processId: 200,
                layer: 0,
                alpha: 1,
                bounds: CGRect(x: 100, y: 100, width: 980, height: 640)
            )
        ]

        // When
        let visible = DesktopVisibilityMonitor.isDesktopVisible(windows: windows, currentProcessId: 200)

        // Then
        XCTAssertTrue(visible)
    }
}
