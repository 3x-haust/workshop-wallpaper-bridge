import Foundation
import XCTest
@testable import WorkshopWallpaperBridgeApp

final class WallpaperPlayerSuspensionTests: XCTestCase {
    func testNoopScreenParameterNotificationDoesNotNeedWindowReopen() {
        // Given
        let frames = [
            CGRect(x: 0, y: 0, width: 1470, height: 956),
            CGRect(x: -1440, y: 0, width: 1440, height: 900)
        ]

        // Then
        XCTAssertFalse(WallpaperScreenFrames.shouldReopenWindows(previous: frames, current: frames))
    }

    func testNoopScreenParameterNotificationReassertsDesktopWindowOrder() throws {
        // Given
        let source = try String(contentsOfFile: "Sources/WorkshopWallpaperBridgeApp/WallpaperPlayer.swift")
        let start = try XCTUnwrap(source.range(of: "private func reopenAfterScreenFrameChange()"))
        let end = try XCTUnwrap(source.range(of: "enum WallpaperScreenFrames", range: start.lowerBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        // Then
        XCTAssertTrue(body.contains("reassertWallpaperWindowOrder()"))
        XCTAssertFalse(body.contains("try play("))
        XCTAssertFalse(body.contains("closeWindows()"))
    }

    func testActiveApplicationChangesReassertDesktopWindowOrder() throws {
        // Given
        let source = try String(contentsOfFile: "Sources/WorkshopWallpaperBridgeApp/WallpaperPlayer.swift")
        let start = try XCTUnwrap(source.range(of: "private func startLifecycleObservers()"))
        let end = try XCTUnwrap(source.range(of: "private func stopLifecycleObservers()", range: start.lowerBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        // Then
        XCTAssertTrue(body.contains("NSWorkspace.didActivateApplicationNotification"))
        XCTAssertTrue(body.contains("scheduleWallpaperWindowOrderReassertion()"))
    }

    func testActiveSpaceChangesReassertDesktopWindowOrder() throws {
        // Given
        let source = try String(contentsOfFile: "Sources/WorkshopWallpaperBridgeApp/WallpaperPlayer.swift")
        let start = try XCTUnwrap(source.range(of: "private func startLifecycleObservers()"))
        let end = try XCTUnwrap(source.range(of: "private func stopLifecycleObservers()", range: start.lowerBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        // Then
        XCTAssertTrue(body.contains("NSWorkspace.activeSpaceDidChangeNotification"))
        XCTAssertTrue(body.contains("scheduleWallpaperWindowOrderReassertion()"))
    }

    func testAutoPauseUsesDelayedSuspensionToAvoidDockSwitchFlicker() throws {
        // Given
        let source = try String(contentsOfFile: "Sources/WorkshopWallpaperBridgeApp/WallpaperPlayer.swift")

        // Then
        XCTAssertTrue(source.contains("private var pendingAutoSuspension"))
        XCTAssertTrue(source.contains("scheduleAutoSuspension()"))
        XCTAssertTrue(source.contains("cancelPendingAutoSuspension()"))
        XCTAssertTrue(source.contains(".now() + 1.5"))
    }

    func testActiveApplicationChangesReevaluateVisibilityBeforeReassertingOrder() throws {
        // Given
        let source = try String(contentsOfFile: "Sources/WorkshopWallpaperBridgeApp/WallpaperPlayer.swift")
        let start = try XCTUnwrap(source.range(of: "private func scheduleWallpaperWindowOrderReassertion()"))
        let end = try XCTUnwrap(source.range(of: "enum WallpaperScreenFrames", range: start.lowerBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        // Then
        XCTAssertTrue(body.contains("updateVisibilityState()"))
        XCTAssertTrue(body.contains("reassertWallpaperWindowOrder()"))
    }

    func testActiveApplicationChangesWakeSuspendedWallpaperBeforeDelayedPause() throws {
        // Given
        let source = try String(contentsOfFile: "Sources/WorkshopWallpaperBridgeApp/WallpaperPlayer.swift")
        let start = try XCTUnwrap(source.range(of: "private func wakeWallpaperForAppTransition()"))
        let end = try XCTUnwrap(source.range(of: "enum WallpaperScreenFrames", range: start.lowerBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        // Then
        XCTAssertTrue(body.contains("cancelPendingAutoSuspension()"))
        XCTAssertTrue(body.contains("setSuspended(false)"))
        XCTAssertTrue(body.contains("updateVisibilityState()"))
    }

    func testWallpaperWindowsJoinFullscreenAppSpaces() throws {
        // Given
        let source = try String(contentsOfFile: "Sources/WorkshopWallpaperBridgeApp/WallpaperPlayer.swift")

        // Then
        XCTAssertTrue(source.contains(".canJoinAllSpaces"))
        XCTAssertTrue(source.contains(".fullScreenAuxiliary"))
    }

    func testRealScreenFrameChangeStillReopensWallpaperWindows() {
        // Given
        let previous = [
            CGRect(x: 0, y: 0, width: 1470, height: 956)
        ]
        let current = [
            CGRect(x: 0, y: 0, width: 1728, height: 1117)
        ]

        // Then
        XCTAssertTrue(WallpaperScreenFrames.shouldReopenWindows(previous: previous, current: current))
    }

    func testReorderedScreenFramesDoNotReopenWallpaperWindows() {
        // Given
        let previous = [
            CGRect(x: 0, y: 0, width: 1470, height: 956),
            CGRect(x: -1440, y: 0, width: 1440, height: 900)
        ]
        let current = Array(previous.reversed())

        // Then
        XCTAssertFalse(WallpaperScreenFrames.shouldReopenWindows(previous: previous, current: current))
    }

    func testScreenCountChangeReopensWallpaperWindows() {
        // Given
        let previous = [
            CGRect(x: 0, y: 0, width: 1470, height: 956),
            CGRect(x: -1440, y: 0, width: 1440, height: 900)
        ]
        let current = [
            CGRect(x: 0, y: 0, width: 1470, height: 956)
        ]

        // Then
        XCTAssertTrue(WallpaperScreenFrames.shouldReopenWindows(previous: previous, current: current))
    }

    func testAutoPauseDoesNotHideWallpaperWindow() throws {
        // Given
        let source = try String(contentsOfFile: "Sources/WorkshopWallpaperBridgeApp/WallpaperPlayer.swift")

        // Then
        XCTAssertFalse(
            source.contains("window.orderOut(nil)"),
            "Auto-pause should pause wallpaper media, not hide the desktop-layer wallpaper window."
        )
    }

    func testDisplayModeChangeDoesNotRecreateWallpaperWindows() throws {
        // Given
        let source = try String(contentsOfFile: "Sources/WorkshopWallpaperBridgeApp/WallpaperPlayer.swift")
        let start = try XCTUnwrap(source.range(of: "func setDisplayMode"))
        let end = try XCTUnwrap(source.range(of: "func setAutoPauseWhenCovered"))
        let body = String(source[start.lowerBound..<end.lowerBound])

        // Then
        XCTAssertFalse(body.contains("reopen("))
        XCTAssertFalse(body.contains("closeWindows("))
    }

    func testWindowClosePreparesWallpaperContentBeforeClosing() throws {
        // Given
        let source = try String(contentsOfFile: "Sources/WorkshopWallpaperBridgeApp/WallpaperPlayer.swift")
        let windowStart = try XCTUnwrap(source.range(of: "private final class WallpaperWindow"))
        let start = try XCTUnwrap(source.range(of: "func close()", range: windowStart.lowerBound..<source.endIndex))
        let end = try XCTUnwrap(source.range(of: "func setSuspended", range: start.lowerBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        // Then
        XCTAssertTrue(body.contains("prepareForClose()"))
        XCTAssertTrue(body.contains("window.contentView = nil"))
    }

    func testWallpaperWindowsDisableAppKitWindowAnimations() throws {
        // Given
        let source = try String(contentsOfFile: "Sources/WorkshopWallpaperBridgeApp/WallpaperPlayer.swift")

        // Then
        XCTAssertTrue(source.contains("window.animationBehavior = .none"))
    }

    func testWallpaperWindowsAreNotReleasedByAppKitWhenClosed() throws {
        // Given
        let source = try String(contentsOfFile: "Sources/WorkshopWallpaperBridgeApp/WallpaperPlayer.swift")

        // Then
        XCTAssertTrue(source.contains("window.isReleasedWhenClosed = false"))
    }

    func testWallpaperWindowCanReassertOrderWithoutRecreatingContent() throws {
        // Given
        let source = try String(contentsOfFile: "Sources/WorkshopWallpaperBridgeApp/WallpaperPlayer.swift")
        let windowStart = try XCTUnwrap(source.range(of: "private final class WallpaperWindow"))
        let start = try XCTUnwrap(source.range(of: "func reassertDesktopOrder()", range: windowStart.lowerBound..<source.endIndex))
        let end = try XCTUnwrap(source.range(of: "func close()", range: start.lowerBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        // Then
        XCTAssertTrue(body.contains("window.orderFrontRegardless()"))
        XCTAssertFalse(body.contains("makeContentView"))
        XCTAssertFalse(body.contains("close()"))
    }

    func testSceneWallpaperReceivesPreviewFallback() throws {
        // Given
        let playerSource = try String(contentsOfFile: "Sources/WorkshopWallpaperBridgeApp/WallpaperPlayer.swift")
        let sceneSource = try String(contentsOfFile: "Sources/WorkshopWallpaperBridgeApp/SceneWallpaperView.swift")

        // Then
        XCTAssertTrue(playerSource.contains("let previewURL = asset.thumbnail.map { URL(filePath: $0) }"))
        XCTAssertTrue(playerSource.contains("previewURL: previewURL"))
        XCTAssertTrue(sceneSource.contains("private let previewLayer = CALayer()"))
        XCTAssertTrue(sceneSource.contains("sceneLayer.backgroundColor = nil"))
    }

    func testVideoWallpaperKeepsStillFallbackBehindPlayerLayer() throws {
        // Given
        let playerSource = try String(contentsOfFile: "Sources/WorkshopWallpaperBridgeApp/WallpaperPlayer.swift")
        let videoSource = try String(contentsOfFile: "Sources/WorkshopWallpaperBridgeApp/VideoWallpaperView.swift")

        // Then
        XCTAssertTrue(playerSource.contains("let fallbackImageURL = try? StillWallpaperImageProvider().stillImageURL(for: asset)"))
        XCTAssertTrue(playerSource.contains("fallbackImageURL: fallbackImageURL"))
        XCTAssertTrue(videoSource.contains("private let fallbackLayer = CALayer()"))
        XCTAssertTrue(videoSource.contains("layer?.addSublayer(fallbackLayer)"))
        XCTAssertTrue(videoSource.contains("layer?.addSublayer(playerLayer)"))
    }

    func testSceneWallpaperAppliesTransformAndOpacityAnimationChannels() throws {
        // Given
        let source = try String(contentsOfFile: "Sources/WorkshopWallpaperBridgeApp/SceneWallpaperView.swift")

        // Then
        XCTAssertTrue(source.contains(#"CAKeyframeAnimation(keyPath: "position")"#))
        XCTAssertTrue(source.contains(#"CAKeyframeAnimation(keyPath: "transform.scale.x")"#))
        XCTAssertTrue(source.contains(#"CAKeyframeAnimation(keyPath: "transform.scale.y")"#))
        XCTAssertTrue(source.contains(#"CAKeyframeAnimation(keyPath: "transform.rotation.z")"#))
        XCTAssertTrue(source.contains(#"CAKeyframeAnimation(keyPath: "opacity")"#))
    }
}
