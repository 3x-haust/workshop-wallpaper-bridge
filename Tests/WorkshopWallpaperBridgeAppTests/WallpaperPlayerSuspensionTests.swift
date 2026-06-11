import Foundation
import XCTest
import WorkshopWallpaperCore
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

    func testWallpaperWindowFrameExtendsBehindMenuBarAndDockForContinuousBackdrop() {
        // Given
        let screenFrame = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let visibleFrame = CGRect(x: 0, y: 80, width: 1470, height: 846)

        // When
        let frame = WallpaperScreenFrames.wallpaperFrame(screenFrame: screenFrame, visibleFrame: visibleFrame)

        // Then
        XCTAssertEqual(frame, screenFrame)
    }

    func testWallpaperWindowDoesNotInjectSyntheticBackgroundColorIntoMenuBarBackdrop() throws {
        // Given
        let source = try String(contentsOfFile: "Sources/WorkshopWallpaperBridgeApp/WallpaperPlayer.swift")
        let windowStart = try XCTUnwrap(source.range(of: "private final class WallpaperWindow"))
        let initStart = try XCTUnwrap(source.range(of: "init(asset:", range: windowStart.lowerBound..<source.endIndex))
        let initEnd = try XCTUnwrap(source.range(of: "func show()", range: initStart.lowerBound..<source.endIndex))
        let body = String(source[initStart.lowerBound..<initEnd.lowerBound])

        // Then
        XCTAssertTrue(body.contains("window.isOpaque = false"))
        XCTAssertTrue(body.contains("window.backgroundColor = .clear"))
        XCTAssertFalse(body.contains("window.backgroundColor = .black"))
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

    func testScenePlaybackPrefersNativeRendererOverRenderCache() throws {
        // Given
        let source = try String(contentsOfFile: "Sources/WorkshopWallpaperBridgeApp/WallpaperPlayer.swift")
        let sceneStart = try XCTUnwrap(source.range(of: "case .scene:"))
        let sceneEnd = try XCTUnwrap(source.range(of: "case .unknown:", range: sceneStart.lowerBound..<source.endIndex))
        let sceneBody = String(source[sceneStart.lowerBound..<sceneEnd.lowerBound])

        // Then
        XCTAssertTrue(sceneBody.contains("return try SceneWallpaperView("))
        XCTAssertFalse(sceneBody.contains("SceneRenderCache.existingVideoURL"))
        XCTAssertFalse(sceneBody.contains("return VideoWallpaperView("))
    }

    @MainActor
    func testSceneWallpaperInitializesTextOnlySceneWithoutPreviewOrTextures() throws {
        // Given
        let root = try Self.makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let packageURL = root.appending(path: "text-only.pkg")
        try Self.writeScenePackage(
            to: packageURL,
            sceneJSON: #"{"objects":[{"text":{"value":"HELLO"},"size":"320 120"}]}"#
        )

        // When
        let view = try SceneWallpaperView(
            url: packageURL,
            previewURL: nil,
            frame: CGRect(x: 0, y: 0, width: 640, height: 360),
            displayMode: .fit
        )
        view.prepareForClose()

        // Then
        XCTAssertEqual(view.frame.size, CGSize(width: 640, height: 360))
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

    func testSceneWallpaperUsesSharedDisplayLayoutAndLayerDepth() throws {
        // Given
        let source = try String(contentsOfFile: "Sources/WorkshopWallpaperBridgeApp/SceneWallpaperView.swift")

        // Then
        XCTAssertTrue(source.contains("WallpaperContentLayout.scaledContentFrame"))
        XCTAssertTrue(source.contains("layer.zPosition = plan.origin.z"))
    }

    func testSceneWallpaperRendersTextLayersAndKnownWaterEffects() throws {
        // Given
        let source = try String(contentsOfFile: "Sources/WorkshopWallpaperBridgeApp/SceneWallpaperView.swift")

        // Then
        XCTAssertTrue(source.contains("CATextLayer()"))
        XCTAssertTrue(source.contains("dynamicTextLayers.append"))
        XCTAssertTrue(source.contains("Timer.scheduledTimer"))
        XCTAssertTrue(source.contains("includeScripted: false"))
        XCTAssertTrue(source.contains("plan.effectSettings"))
        XCTAssertTrue(source.contains("opacityMultiplier(for: layerPlan)"))
        XCTAssertTrue(source.contains("opacityMultiplier(for: plan)"))
    }

    func testSceneWallpaperUsesShaderDerivedWaterWaveRenderingInsteadOfLayerDrift() throws {
        // Given
        let source = try String(contentsOfFile: "Sources/WorkshopWallpaperBridgeApp/SceneWallpaperView.swift")

        // Then
        XCTAssertTrue(source.contains("CIKernel"))
        XCTAssertTrue(source.contains("weWaterWaves"))
        XCTAssertTrue(source.contains("shaderEffectLayers.append"))
        XCTAssertTrue(source.contains("startSceneTickSourceIfNeeded"))
        XCTAssertFalse(source.contains(#"CAKeyframeAnimation(keyPath: "transform.translation.y")"#))
        XCTAssertFalse(source.contains(#"CAKeyframeAnimation(keyPath: "transform.translation.x")"#))
        XCTAssertFalse(source.contains(#"layer.add(animation, forKey: "\(keyPrefix)-effect-rotation")"#))
    }

    func testSceneWallpaperRendersParsedWaterShaderEffects() {
        // Given
        let effects = [
            SceneLayerEffectSetting(effect: .waterFlow),
            SceneLayerEffectSetting(effect: .waterWaves),
            SceneLayerEffectSetting(effect: .waterRipple),
            SceneLayerEffectSetting(effect: .scroll),
            SceneLayerEffectSetting(effect: .bloom),
            SceneLayerEffectSetting(effect: .blur),
            SceneLayerEffectSetting(effect: .chromaticAberration),
            SceneLayerEffectSetting(effect: .clouds),
            SceneLayerEffectSetting(effect: .godRays),
            SceneLayerEffectSetting(effect: .localContrast),
            SceneLayerEffectSetting(effect: .materialColor),
            SceneLayerEffectSetting(effect: .shake),
            SceneLayerEffectSetting(effect: .spin),
            SceneLayerEffectSetting(effect: .shine),
            SceneLayerEffectSetting(effect: .opacity),
            SceneLayerEffectSetting(effect: .pulse)
        ]

        // When
        let rendered = SceneWallpaperView.shaderRenderableEffects(from: effects).map(\.effect)

        // Then
        XCTAssertEqual(rendered, [
            .waterFlow,
            .waterWaves,
            .waterRipple,
            .scroll,
            .bloom,
            .blur,
            .chromaticAberration,
            .godRays,
            .localContrast,
            .materialColor
        ])
    }

    func testSceneWallpaperRefreshesSceneScriptTextLayers() throws {
        // Given
        let source = try String(contentsOfFile: "Sources/WorkshopWallpaperBridgeApp/SceneWallpaperView.swift")

        // Then
        XCTAssertTrue(source.contains("SceneScriptTextEvaluator(script:"))
        XCTAssertTrue(source.contains("text.script != nil"))
        XCTAssertTrue(source.contains("SceneScriptRuntime("))
        XCTAssertTrue(source.contains("refreshSceneTickDrivenLayers"))
        XCTAssertTrue(source.contains("tick.frameTime"))
        XCTAssertFalse(source.contains("1.0 / 24.0"))
    }

    func testSceneWallpaperSuspensionPausesAndResumesSceneTickSource() throws {
        // Given
        let source = try String(contentsOfFile: "Sources/WorkshopWallpaperBridgeApp/SceneWallpaperView.swift")
        let start = try XCTUnwrap(source.range(of: "func setPlaybackSuspended"))
        let end = try XCTUnwrap(source.range(of: "func setDisplayMode", range: start.lowerBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        // Then
        XCTAssertTrue(body.contains("sceneTickSource.suspend()"))
        XCTAssertTrue(body.contains("sceneTickSource.resume()"))
        XCTAssertTrue(body.contains("startSceneTickSourceIfNeeded()"))
    }

    func testSceneWallpaperCloseInvalidatesSceneTickSource() throws {
        // Given
        let source = try String(contentsOfFile: "Sources/WorkshopWallpaperBridgeApp/SceneWallpaperView.swift")
        let start = try XCTUnwrap(source.range(of: "func prepareForClose()"))
        let end = try XCTUnwrap(source.range(of: "private func configureSceneLayer", range: start.lowerBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        // Then
        XCTAssertTrue(body.contains("sceneTickSource.invalidate()"))
        XCTAssertFalse(body.contains("shaderEffectTimer"))
    }

    func testSceneWallpaperAnimatesParsedLayerEffects() {
        // Given
        let effects = [
            SceneLayerEffectSetting(effect: .shake),
            SceneLayerEffectSetting(effect: .spin),
            SceneLayerEffectSetting(effect: .shine),
            SceneLayerEffectSetting(effect: .pulse),
            SceneLayerEffectSetting(effect: .waterFlow),
            SceneLayerEffectSetting(effect: .waterRipple),
            SceneLayerEffectSetting(effect: .bloom),
            SceneLayerEffectSetting(effect: .opacity)
        ]

        // When
        let animated = effects.map { SceneWallpaperView.isLayerAnimatedEffect($0.effect) }

        // Then
        XCTAssertEqual(animated, [true, true, true, true, false, false, false, false])
    }

    func testSceneWallpaperSkipsEffectAnimationsThatConflictWithSceneKeyframes() {
        // Then
        XCTAssertFalse(SceneWallpaperView.shouldAnimateLayerEffect(.spin, hasAngleAnimation: true, hasAlphaAnimation: false))
        XCTAssertFalse(SceneWallpaperView.shouldAnimateLayerEffect(.shine, hasAngleAnimation: false, hasAlphaAnimation: true))
        XCTAssertFalse(SceneWallpaperView.shouldAnimateLayerEffect(.pulse, hasAngleAnimation: false, hasAlphaAnimation: true))
        XCTAssertTrue(SceneWallpaperView.shouldAnimateLayerEffect(.shake, hasAngleAnimation: true, hasAlphaAnimation: true))
        XCTAssertTrue(SceneWallpaperView.shouldAnimateLayerEffect(.spin, hasAngleAnimation: false, hasAlphaAnimation: false))
        XCTAssertTrue(SceneWallpaperView.shouldAnimateLayerEffect(.shine, hasAngleAnimation: false, hasAlphaAnimation: false))
        XCTAssertTrue(SceneWallpaperView.shouldAnimateLayerEffect(.pulse, hasAngleAnimation: false, hasAlphaAnimation: false))
    }

    func testSceneWallpaperDerivesEffectAnimationTimingFromShaderSpeed() {
        // Given
        let fastSpin = SceneLayerEffectSetting(effect: .spin, speed: 2)
        let staticShake = SceneLayerEffectSetting(effect: .shake, speed: 0, strength: 0.2)
        let strongShake = SceneLayerEffectSetting(
            effect: .shake,
            speed: 1,
            strength: 0.4,
            direction: SceneVector3(x: 1, y: 0, z: 0)
        )

        // When
        let spinDuration = SceneWallpaperView.layerEffectDuration(for: fastSpin, defaultDuration: 8)
        let staticDuration = SceneWallpaperView.layerEffectDuration(for: staticShake, defaultDuration: 1)
        let shakeOffsets = SceneWallpaperView.shakeOffsets(for: strongShake, layerSize: CGSize(width: 200, height: 100))

        // Then
        XCTAssertEqual(spinDuration, 4, accuracy: 0.000_001)
        XCTAssertEqual(staticDuration, 1, accuracy: 0.000_001)
        XCTAssertEqual(shakeOffsets.count, 5)
        XCTAssertEqual(shakeOffsets[1].x, 0, accuracy: 0.000_001)
        XCTAssertEqual(shakeOffsets[1].y, -8, accuracy: 0.000_001)
    }

    func testSceneWallpaperScrollUsesSpeedDirectionWhenAxisSpeedsAreMissing() {
        // Given
        let directionalScroll = SceneLayerEffectSetting(
            effect: .scroll,
            speed: 0.4,
            direction: SceneVector3(x: 0, y: -2, z: 0)
        )
        let explicitAxisScroll = SceneLayerEffectSetting(
            effect: .scroll,
            speed: 0.4,
            speedX: 0,
            speedY: -0.35,
            direction: SceneVector3(x: 1, y: 0, z: 0)
        )

        // When
        let directional = SceneWallpaperView.scrollAxisSpeeds(for: directionalScroll)
        let explicit = SceneWallpaperView.scrollAxisSpeeds(for: explicitAxisScroll)

        // Then
        XCTAssertEqual(directional.x, 0, accuracy: 0.000_001)
        XCTAssertEqual(directional.y, -0.4, accuracy: 0.000_001)
        XCTAssertEqual(explicit.x, 0, accuracy: 0.000_001)
        XCTAssertEqual(explicit.y, -0.35, accuracy: 0.000_001)
    }

    func testSceneTickClockStopsWhileSuspended() throws {
        // Given
        var clock = SceneTickClock()

        // When
        let firstTick = clock.advance(by: 0.25)
        clock.suspend()
        let suspendedTick = clock.advance(by: 10)
        clock.resume()
        let resumedTick = clock.advance(by: 0.5)

        // Then
        XCTAssertEqual(try XCTUnwrap(firstTick).elapsedTime, 0.25, accuracy: 0.000_001)
        XCTAssertNil(suspendedTick)
        XCTAssertEqual(try XCTUnwrap(resumedTick).elapsedTime, 0.75, accuracy: 0.000_001)
        XCTAssertEqual(clock.elapsedTime, 0.75, accuracy: 0.000_001)
    }

    @MainActor
    func testSceneTickClockInvalidatesOnClose() throws {
        // Given
        let root = try Self.makeTempDirectory()
        let packageURL = root.appending(path: "text-only.pkg")
        let tickSource = TestSceneTickSource()
        try Self.writeScenePackage(
            to: packageURL,
            sceneJSON: #"{"objects":[{"text":{"value":"HELLO"},"size":"320 120"}]}"#
        )
        let view = try SceneWallpaperView(
            url: packageURL,
            previewURL: nil,
            frame: CGRect(x: 0, y: 0, width: 640, height: 360),
            displayMode: .fit,
            sceneTickSource: tickSource
        )

        // When
        view.prepareForClose()

        // Then
        XCTAssertTrue(tickSource.didInvalidate)
        XCTAssertFalse(tickSource.isRunning)
    }

    func testSceneShaderEffectClockDoesNotAdvanceWhileSuspended() throws {
        // When
        var clock = SceneTickClock()
        _ = clock.advance(by: 4.5)
        clock.suspend()
        let suspendedTick = clock.advance(by: 60)
        let suspendedTime = clock.elapsedTime
        clock.resume()
        let runningTick = clock.advance(by: 3.25)

        // Then
        XCTAssertNil(suspendedTick)
        XCTAssertEqual(suspendedTime, 4.5, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(runningTick).elapsedTime, 7.75, accuracy: 0.000_001)
    }

    private static func makeTempDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "wwb-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func writeScenePackage(to url: URL, sceneJSON: String) throws {
        var data = Data()
        data.appendLengthPrefixedString("PKGV0007")
        data.appendInt32(1)
        data.appendLengthPrefixedString("scene.json")
        data.appendInt32(0)
        data.appendInt32(Data(sceneJSON.utf8).count)
        data.append(Data(sceneJSON.utf8))
        try data.write(to: url, options: [.atomic])
    }
}

@MainActor
private final class TestSceneTickSource: SceneTickSource {
    private var clock = SceneTickClock()
    private(set) var isRunning = false
    private(set) var didInvalidate = false
    var onTick: ((SceneTick) -> Void)?

    var elapsedTime: TimeInterval {
        clock.elapsedTime
    }

    var frameTime: TimeInterval {
        clock.frameTime
    }

    func start() {
        guard !didInvalidate else {
            return
        }
        isRunning = true
    }

    func stop() {
        isRunning = false
    }

    func suspend() {
        clock.suspend()
        isRunning = false
    }

    func resume() {
        clock.resume()
    }

    func reset() {
        clock.reset()
        isRunning = false
    }

    func invalidate() {
        clock.invalidate()
        isRunning = false
        didInvalidate = true
        onTick = nil
    }

    func advance(by delta: TimeInterval) {
        guard isRunning, let tick = clock.advance(by: delta) else {
            return
        }
        onTick?(tick)
    }
}

private extension Data {
    mutating func appendInt32(_ value: Int) {
        var raw = Int32(value).littleEndian
        Swift.withUnsafeBytes(of: &raw) { append(contentsOf: $0) }
    }

    mutating func appendLengthPrefixedString(_ string: String) {
        let bytes = Data(string.utf8)
        appendInt32(bytes.count)
        append(bytes)
    }
}
