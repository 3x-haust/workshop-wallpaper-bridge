import AppKit
import XCTest
import WorkshopWallpaperCore
@testable import WorkshopWallpaperBridgeApp

@MainActor
final class MultiDisplayPlaybackTests: XCTestCase {
    private let left = WallpaperDisplay(id: "left", name: "Retina", frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2, isPrimary: true)
    private let right = WallpaperDisplay(id: "right", name: "External", frame: CGRect(x: 1512, y: -300, width: 2560, height: 1440), scale: 1, isPrimary: false)

    func testReplacingOneDisplayKeepsTheOtherPlayerForEverySupportedType() throws {
        for kind in [WallpaperKind.video, .web, .image, .scene] {
            let sessions = makeSessions()
            _ = sessions.reconcile([left, right])
            try sessions.play(asset: asset("first", kind: kind), on: [left.id, right.id], mode: .fit)
            let originalLeft = try XCTUnwrap(sessions.windows[left.id] as? WindowSpy)
            let originalRight = try XCTUnwrap(sessions.windows[right.id] as? WindowSpy)

            try sessions.play(asset: asset("second", kind: kind), on: [right.id], mode: .fill)

            XCTAssertTrue(sessions.windows[left.id] === originalLeft)
            XCTAssertFalse(originalLeft.closed)
            XCTAssertTrue(originalRight.closed)
            XCTAssertEqual(sessions.assignments[left.id]?.asset.id, "first")
            XCTAssertEqual(sessions.assignments[right.id]?.asset.id, "second")
            sessions.stop(on: [left.id, right.id])
        }
    }

    func testFailedBatchPreservesEveryPreviousWindowAndAssignment() throws {
        var created: [WindowSpy] = []
        let sessions = DisplayPlaybackSessions { asset, display, _ in
            if asset.id == "bad", display.id == "right" { throw PlaybackError.invalidImage }
            let window = WindowSpy()
            created.append(window)
            return window
        }
        _ = sessions.reconcile([left, right])
        try sessions.play(asset: asset("original"), on: [left.id, right.id], mode: .fit)
        let previous = sessions.windows

        XCTAssertThrowsError(try sessions.play(asset: asset("bad"), on: [left.id, right.id], mode: .fill))

        XCTAssertTrue(sessions.windows[left.id] === previous[left.id])
        XCTAssertTrue(sessions.windows[right.id] === previous[right.id])
        XCTAssertEqual(sessions.assignments.values.map(\.asset.id), ["original", "original"])
        XCTAssertTrue(created.last?.closed == true, "Prepared replacements must be disposed after a batch failure.")
    }

    func testDisconnectReconnectRestoresOnlyMatchingIdentityWithoutRestartingOtherDisplay() throws {
        let sessions = makeSessions()
        _ = sessions.reconcile([left, right])
        try sessions.play(asset: asset("left-video"), on: [left.id], mode: .fit)
        try sessions.play(asset: asset("right-web", kind: .web), on: [right.id], mode: .stretch)
        let leftWindow = try XCTUnwrap(sessions.windows[left.id] as? WindowSpy)
        let rightWindow = try XCTUnwrap(sessions.windows[right.id] as? WindowSpy)

        XCTAssertEqual(sessions.reconcile([left]), [])
        XCTAssertTrue(rightWindow.closed)
        XCTAssertEqual(sessions.assignments[right.id]?.asset.id, "right-web")
        let replacementMonitor = WallpaperDisplay(id: "new", name: right.name, frame: right.frame, scale: 1, isPrimary: false)
        _ = sessions.reconcile([left, replacementMonitor])
        XCTAssertNil(sessions.windows[replacementMonitor.id], "A new monitor at an old position must not inherit its wallpaper.")
        XCTAssertEqual(sessions.reconcile([right, left]), [])

        XCTAssertTrue(sessions.windows[left.id] === leftWindow)
        XCTAssertFalse(sessions.windows[right.id] === rightWindow)
        XCTAssertEqual(sessions.assignments[right.id]?.mode, .stretch)
    }

    func testPrimaryLayoutAndScaleChangesResizeWithoutReplacingPlayers() throws {
        let sessions = makeSessions()
        _ = sessions.reconcile([left, right])
        try sessions.play(asset: asset("same"), on: [left.id, right.id], mode: .fill)
        let leftWindow = try XCTUnwrap(sessions.windows[left.id] as? WindowSpy)
        let rightWindow = try XCTUnwrap(sessions.windows[right.id] as? WindowSpy)
        let changedLeft = WallpaperDisplay(id: left.id, name: left.name, frame: CGRect(x: -1512, y: 900, width: 1512, height: 982), scale: 1, isPrimary: false)
        let changedRight = WallpaperDisplay(id: right.id, name: right.name, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), scale: 2, isPrimary: true)

        _ = sessions.reconcile([changedRight, changedLeft])

        XCTAssertTrue(sessions.windows[left.id] === leftWindow)
        XCTAssertTrue(sessions.windows[right.id] === rightWindow)
        XCTAssertEqual(leftWindow.display, changedLeft)
        XCTAssertEqual(rightWindow.display, changedRight)
        _ = sessions.reconcile([changedLeft, changedRight])
        XCTAssertEqual(leftWindow.layoutChanges, 1)
        XCTAssertEqual(rightWindow.layoutChanges, 1)
    }

    func testSleepCoverageAndNewWindowsHaveIndependentSuspensionState() throws {
        let sessions = makeSessions()
        _ = sessions.reconcile([left, right])
        try sessions.play(asset: asset("same"), on: [left.id, right.id], mode: .fit)
        let leftWindow = try XCTUnwrap(sessions.windows[left.id] as? WindowSpy)
        sessions.setCovered([right.id])
        XCTAssertFalse(leftWindow.suspended)
        XCTAssertTrue((sessions.windows[right.id] as? WindowSpy)?.suspended == true)
        sessions.setSleeping(true)
        XCTAssertTrue(leftWindow.suspended)
        sessions.setCovered([])
        XCTAssertTrue(leftWindow.suspended, "Visibility changes must not resume a sleeping display.")
        try sessions.play(asset: asset("replacement"), on: [right.id], mode: .fill)
        XCTAssertTrue((sessions.windows[right.id] as? WindowSpy)?.suspended == true)
        sessions.setSleeping(false)
        XCTAssertFalse(leftWindow.suspended)
        XCTAssertFalse((sessions.windows[right.id] as? WindowSpy)?.suspended == true)
        XCTAssertTrue(sessions.windows[left.id] === leftWindow)
    }

    func testLateSceneRenderCannotReplaceOtherAssetsOrResurrectStoppedDisplay() throws {
        let sessions = makeSessions()
        _ = sessions.reconcile([left, right])
        try sessions.play(asset: asset("scene", kind: .scene), on: [left.id, right.id], mode: .fill)
        try sessions.play(asset: asset("new-video"), on: [right.id], mode: .fit)
        let rightWindow = try XCTUnwrap(sessions.windows[right.id])
        let leftWindow = try XCTUnwrap(sessions.windows[left.id] as? WindowSpy)
        _ = sessions.refreshScene(assetID: "scene")
        XCTAssertTrue(leftWindow.closed)
        XCTAssertTrue(sessions.windows[right.id] === rightWindow)
        sessions.stop(on: [left.id])
        _ = sessions.refreshScene(assetID: "scene")
        _ = sessions.reconcile([left, right])
        XCTAssertNil(sessions.windows[left.id])
        XCTAssertTrue(sessions.windows[right.id] === rightWindow)
    }

    func testReconnectErrorRetainsAssignmentAndHealthyDisplay() throws {
        var failRight = false
        let sessions = DisplayPlaybackSessions { _, display, _ in
            if failRight, display.id == "right" { throw PlaybackError.invalidImage }
            return WindowSpy()
        }
        _ = sessions.reconcile([left, right])
        try sessions.play(asset: asset("same"), on: [left.id, right.id], mode: .fit)
        let leftWindow = try XCTUnwrap(sessions.windows[left.id])
        _ = sessions.reconcile([left])
        failRight = true
        XCTAssertEqual(sessions.reconcile([left, right]).count, 1)
        XCTAssertTrue(sessions.windows[left.id] === leftWindow)
        XCTAssertEqual(sessions.assignments[right.id]?.asset.id, "same")
        failRight = false
        XCTAssertEqual(sessions.reconcile([left, right]), [])
        XCTAssertNotNil(sessions.windows[right.id])
    }

    func testWindowServerCoordinatesSupportAboveBelowAndNegativeOrigins() {
        for (frame, expected) in [
            (CGRect(x: -1000, y: 0, width: 1000, height: 800), CGRect(x: -1000, y: 182, width: 1000, height: 800)),
            (CGRect(x: 0, y: 982, width: 1000, height: 800), CGRect(x: 0, y: -800, width: 1000, height: 800)),
            (CGRect(x: 0, y: -800, width: 1000, height: 800), CGRect(x: 0, y: 982, width: 1000, height: 800))
        ] {
            XCTAssertEqual(DesktopVisibilityMonitor.windowServerFrame(frame, primaryTop: 982), expected)
        }
    }

    private func makeSessions() -> DisplayPlaybackSessions {
        DisplayPlaybackSessions { _, _, _ in WindowSpy() }
    }

    private func asset(_ id: String, kind: WallpaperKind = .video) -> WallpaperAsset {
        WallpaperAsset(id: id, title: id, kind: kind, supportStatus: .playable, source: .localSteamWorkshop,
            projectDirectory: "/fixtures", entrypoint: "/fixtures/\(id)", thumbnail: nil, workshopId: nil,
            redistributionAllowed: false, issues: [])
    }
}

@MainActor
private final class WindowSpy: DisplayWallpaperWindow {
    var closed = false
    var suspended = false
    var display: WallpaperDisplay?
    var layoutChanges = 0
    func show() {}
    func close() { closed = true }
    func updateDisplay(_ display: WallpaperDisplay) { self.display = display; layoutChanges += 1 }
    func setSuspended(_ suspended: Bool) { self.suspended = suspended }
    func setDisplayMode(_ mode: WallpaperDisplayMode) {}
    func setInteractionEnabled(_ enabled: Bool) {}
    func setAudio(enabled: Bool, volume: Double) {}
    func reassertDesktopOrder() {}
}
