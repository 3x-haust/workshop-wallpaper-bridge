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

    func testStageManagerAppThumbnailDoesNotPausePlayback() {
        // Given
        let windows = [
            DesktopVisibilityMonitor.WindowSnapshot(
                ownerName: "Code",
                processId: 100,
                layer: 0,
                alpha: 1,
                bounds: CGRect(x: 15, y: 420, width: 127, height: 149)
            )
        ]

        // When
        let visible = DesktopVisibilityMonitor.isDesktopVisible(
            windows: windows,
            currentProcessId: 200,
            screenFrames: [CGRect(x: 0, y: 0, width: 1470, height: 956)]
        )

        // Then
        XCTAssertTrue(visible)
    }

    func testSmallCenteredUserWindowStillPausesPlayback() {
        // Given
        let windows = [
            DesktopVisibilityMonitor.WindowSnapshot(
                ownerName: "Code",
                processId: 100,
                layer: 0,
                alpha: 1,
                bounds: CGRect(x: 520, y: 320, width: 220, height: 220)
            )
        ]

        // When
        let visible = DesktopVisibilityMonitor.isDesktopVisible(
            windows: windows,
            currentProcessId: 200,
            screenFrames: [CGRect(x: 0, y: 0, width: 1470, height: 956)]
        )

        // Then
        XCTAssertFalse(visible)
    }

    func testContinuityAndHandoffSystemWindowsDoNotPausePlayback() {
        // Given
        let windows = [
            DesktopVisibilityMonitor.WindowSnapshot(
                ownerName: "ContinuityCaptureAgent",
                processId: 100,
                layer: 0,
                alpha: 1,
                bounds: CGRect(x: 0, y: 0, width: 390, height: 844)
            ),
            DesktopVisibilityMonitor.WindowSnapshot(
                ownerName: "Handoff",
                processId: 101,
                layer: 0,
                alpha: 1,
                bounds: CGRect(x: 0, y: 0, width: 390, height: 844)
            )
        ]

        // When
        let visible = DesktopVisibilityMonitor.isDesktopVisible(windows: windows, currentProcessId: 200)

        // Then
        XCTAssertTrue(
            visible,
            "Continuity and Handoff system windows should not pause desktop wallpaper playback."
        )
    }

    func testAdditionalContinuitySystemWindowsDoNotPausePlayback() {
        let ownerNames = [
            "AirPlayUIAgent",
            "Continuity",
            "Continuity Camera",
            "ControlCenter"
        ]

        for ownerName in ownerNames {
            let windows = [
                DesktopVisibilityMonitor.WindowSnapshot(
                    ownerName: ownerName,
                    processId: 100,
                    layer: 0,
                    alpha: 1,
                    bounds: CGRect(x: 0, y: 0, width: 390, height: 844)
                )
            ]

            let visible = DesktopVisibilityMonitor.isDesktopVisible(windows: windows, currentProcessId: 200)

            XCTAssertTrue(visible, "\(ownerName) should not pause desktop wallpaper playback.")
        }
    }

    func testUserWindowsWithContinuityLikeNamesStillPausePlayback() {
        let ownerNames = [
            "Continuity Studio",
            "Handoff Notes",
            "iPhone Hotspot Preview"
        ]

        for ownerName in ownerNames {
            let windows = [
                DesktopVisibilityMonitor.WindowSnapshot(
                    ownerName: ownerName,
                    processId: 100,
                    layer: 0,
                    alpha: 1,
                    bounds: CGRect(x: 0, y: 0, width: 900, height: 700)
                )
            ]

            let visible = DesktopVisibilityMonitor.isDesktopVisible(windows: windows, currentProcessId: 200)

            XCTAssertFalse(visible, "\(ownerName) should still pause desktop wallpaper playback.")
        }
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
