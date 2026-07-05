import AppKit
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
        XCTAssertTrue(sceneBody.contains("SceneWallpaperContentFactory.makeSceneContentView"))
        XCTAssertFalse(sceneBody.contains("SceneRenderCache.existingVideoURL"))
        XCTAssertFalse(sceneBody.contains("return VideoWallpaperView("))
    }

    func testScenePlaybackRealtimeRendererWindowCodeHasBeenRemoved() throws {
        // Given
        let source = try String(contentsOfFile: "Sources/WorkshopWallpaperBridgeApp/WallpaperPlayer.swift")

        // Then
        XCTAssertFalse(source.contains("ExternalSceneRendererView"))
        XCTAssertFalse(source.contains("SceneEngineProcessController"))
        XCTAssertFalse(source.contains("--macos-wallpaper-window"))
    }

    @MainActor
    func testScenePlaybackUsesFreshCachedVideoWhenAvailable() throws {
        // Given
        let root = try Self.makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let packageURL = root.appending(path: "scene.pkg")
        try Self.writeScenePackage(
            to: packageURL,
            sceneJSON: #"{"objects":[{"text":{"value":"HELLO"},"size":"320 120"}]}"#
        )
        let asset = Self.sceneAsset(root: root, entrypoint: packageURL)
        let cacheDirectory = root.appending(path: "SceneVideoCache")
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let cachedVideoURL = cacheDirectory.appending(path: "\(asset.id).mp4")
        try "fake-cached-video".write(to: cachedVideoURL, atomically: true, encoding: .utf8)
        let previousCacheDirectory = SceneVideoCache.overrideCacheDirectoryURL
        SceneVideoCache.overrideCacheDirectoryURL = cacheDirectory
        defer {
            SceneVideoCache.overrideCacheDirectoryURL = previousCacheDirectory
        }

        // When
        let view = try SceneWallpaperContentFactory.makeSceneContentView(
            asset: asset,
            url: packageURL,
            frame: CGRect(x: 0, y: 0, width: 640, height: 360),
            displayMode: .fit
        )
        (view as? WallpaperContentLifecycle)?.prepareForClose()

        // Then
        XCTAssertTrue(view is VideoWallpaperView)
        XCTAssertNil(SceneWallpaperContentFactory.lastDiagnostic)
    }

    /// Scene wallpapers are a rendered loop meant to cover the whole
    /// desktop, so cached scene videos must always play with fill/aspect-
    /// fill gravity, even when the app's general display-mode preference is
    /// set to `.fit` (as passed in below).
    @MainActor
    func testScenePlaybackForcesFillGravityForCachedVideoRegardlessOfDisplayMode() throws {
        // Given
        let root = try Self.makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let packageURL = root.appending(path: "scene.pkg")
        try Self.writeScenePackage(
            to: packageURL,
            sceneJSON: #"{"objects":[{"text":{"value":"HELLO"},"size":"320 120"}]}"#
        )
        let asset = Self.sceneAsset(root: root, entrypoint: packageURL)
        let cacheDirectory = root.appending(path: "SceneVideoCache")
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let cachedVideoURL = cacheDirectory.appending(path: "\(asset.id).mp4")
        try "fake-cached-video".write(to: cachedVideoURL, atomically: true, encoding: .utf8)
        let previousCacheDirectory = SceneVideoCache.overrideCacheDirectoryURL
        SceneVideoCache.overrideCacheDirectoryURL = cacheDirectory
        defer {
            SceneVideoCache.overrideCacheDirectoryURL = previousCacheDirectory
        }

        // When
        let view = try SceneWallpaperContentFactory.makeSceneContentView(
            asset: asset,
            url: packageURL,
            frame: CGRect(x: 0, y: 0, width: 640, height: 360),
            displayMode: .fit
        )
        defer {
            (view as? WallpaperContentLifecycle)?.prepareForClose()
        }

        // Then
        let videoView = try XCTUnwrap(view as? VideoWallpaperView)
        XCTAssertEqual(videoView.playerLayer.videoGravity, .resizeAspectFill)
    }

    @MainActor
    func testScenePlaybackFallsBackToNativeWhenSceneEngineAssetsAreMissing() throws {
        // Given
        let root = try Self.makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let packageURL = root.appending(path: "scene.pkg")
        try Self.writeScenePackage(
            to: packageURL,
            sceneJSON: #"{"objects":[{"text":{"value":"HELLO"},"size":"320 120"}]}"#
        )
        let rendererURL = root.appending(path: "scene-engine-renderer")
        try "#!/bin/sh\nexit 0\n".write(to: rendererURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rendererURL.path)
        let asset = Self.sceneAsset(root: root, entrypoint: packageURL)
        let previousRendererPath = SceneEngineRendererConfiguration.overrideExecutablePath
        let previousAssetsPath = SceneEngineRendererConfiguration.overrideAssetsPath
        let previousCacheDirectory = SceneVideoCache.overrideCacheDirectoryURL
        SceneEngineRendererConfiguration.overrideExecutablePath = rendererURL.path
        SceneEngineRendererConfiguration.overrideAssetsPath = root.appending(path: "missing-assets").path
        SceneVideoCache.overrideCacheDirectoryURL = root.appending(path: "SceneVideoCache")
        defer {
            SceneEngineRendererConfiguration.overrideExecutablePath = previousRendererPath
            SceneEngineRendererConfiguration.overrideAssetsPath = previousAssetsPath
            SceneVideoCache.overrideCacheDirectoryURL = previousCacheDirectory
        }

        // When
        let view = try SceneWallpaperContentFactory.makeSceneContentView(
            asset: asset,
            url: packageURL,
            frame: CGRect(x: 0, y: 0, width: 640, height: 360),
            displayMode: .fit
        )
        (view as? WallpaperContentLifecycle)?.prepareForClose()

        // Then
        XCTAssertTrue(view is SceneWallpaperView)
        XCTAssertEqual(
            SceneWallpaperContentFactory.lastDiagnostic,
            "scene video rendering skipped: Wallpaper Engine assets folder"
        )
    }

    @MainActor
    func testScenePlaybackFallsBackToNativeWhenRendererIsMissingOrNotExecutable() throws {
        // Given
        let root = try Self.makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let packageURL = root.appending(path: "scene.pkg")
        try Self.writeScenePackage(
            to: packageURL,
            sceneJSON: #"{"objects":[{"text":{"value":"HELLO"},"size":"320 120"}]}"#
        )
        let missingRendererURL = root.appending(path: "missing-renderer")
        let rendererURL = root.appending(path: "scene-engine-renderer")
        try "#!/bin/sh\nexit 0\n".write(to: rendererURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: rendererURL.path)
        let assetsDirectory = try Self.writeSceneEngineAssetsFixture(in: root)
        let asset = Self.sceneAsset(root: root, entrypoint: packageURL)
        let previousRendererPath = SceneEngineRendererConfiguration.overrideExecutablePath
        let previousAssetsPath = SceneEngineRendererConfiguration.overrideAssetsPath
        let previousCacheDirectory = SceneVideoCache.overrideCacheDirectoryURL
        SceneEngineRendererConfiguration.overrideAssetsPath = assetsDirectory.path
        SceneVideoCache.overrideCacheDirectoryURL = root.appending(path: "SceneVideoCache")
        defer {
            SceneEngineRendererConfiguration.overrideExecutablePath = previousRendererPath
            SceneEngineRendererConfiguration.overrideAssetsPath = previousAssetsPath
            SceneVideoCache.overrideCacheDirectoryURL = previousCacheDirectory
        }

        // When
        SceneEngineRendererConfiguration.overrideExecutablePath = missingRendererURL.path
        let missingView = try SceneWallpaperContentFactory.makeSceneContentView(
            asset: asset,
            url: packageURL,
            frame: CGRect(x: 0, y: 0, width: 640, height: 360),
            displayMode: .fit
        )
        (missingView as? WallpaperContentLifecycle)?.prepareForClose()
        SceneEngineRendererConfiguration.overrideExecutablePath = rendererURL.path
        let nonExecutableView = try SceneWallpaperContentFactory.makeSceneContentView(
            asset: asset,
            url: packageURL,
            frame: CGRect(x: 0, y: 0, width: 640, height: 360),
            displayMode: .fit
        )
        (nonExecutableView as? WallpaperContentLifecycle)?.prepareForClose()

        // Then
        XCTAssertTrue(missingView is SceneWallpaperView)
        XCTAssertTrue(nonExecutableView is SceneWallpaperView)
    }

    func testSceneVideoRendererBuildsRecordingAndFfmpegArguments() {
        // Given
        let configuration = SceneVideoRenderConfiguration(
            assetId: "MjQ2ODQ4OTIyMw",
            projectDirectory: URL(filePath: "/tmp/scene-project"),
            assetsDirectory: URL(filePath: "/tmp/wallpaper-engine-assets"),
            rendererURL: URL(filePath: "/tmp/wwb-scene-renderer"),
            size: CGSize(width: 1920, height: 1080),
            fps: 30,
            seconds: 10
        )
        let recordDirectory = URL(filePath: "/tmp/scene-record")

        // When
        let recordingArguments = SceneVideoRenderer.recordingArguments(
            recordDirectory: recordDirectory,
            configuration: configuration
        )
        // 10s @ 30fps = 300 frames, comfortably more than the 2*36 = 72
        // frames the default 1.2s crossfade needs, so this exercises the
        // crossfade branch.
        let ffmpegArguments = SceneVideoRenderer.ffmpegArguments(
            framesDirectory: recordDirectory,
            fps: configuration.fps,
            recordedFrameCount: 300,
            outputURL: URL(filePath: "/tmp/scene-record/output.mp4")
        )

        // Then
        XCTAssertEqual(recordingArguments, [
            "--window",
            "0x0x1920x1080",
            "--silent",
            "--noautomute",
            "--no-audio-processing",
            "--disable-mouse",
            "--record-dir",
            "/tmp/scene-record",
            "--record-seconds",
            "10",
            "--record-fps",
            "30",
            "--assets-dir",
            "/tmp/wallpaper-engine-assets",
            "/tmp/scene-project"
        ])
        // K = round(1.2 * 30) = 36 crossfade frames.
        // offset = (300 - 2*36) / 30 = 228 / 30 = 7.6s.
        // duration = 36 / 30 = 1.2s.
        // output length = offset + duration = 8.8s = (300 - 36) / 30. ✓
        XCTAssertEqual(ffmpegArguments, [
            "-y",
            "-framerate",
            "30",
            "-i",
            "/tmp/scene-record/frame_%05d.png",
            "-framerate",
            "30",
            "-i",
            "/tmp/scene-record/frame_%05d.png",
            "-filter_complex",
            "[0:v]trim=start_frame=36,setpts=PTS-STARTPTS[main];"
                + "[1:v]trim=end_frame=36,setpts=PTS-STARTPTS[head];"
                + "[main][head]xfade=transition=fade:duration=1.200:offset=7.600[out]",
            "-map",
            "[out]",
            "-c:v",
            "libx264",
            "-pix_fmt",
            "yuv420p",
            "-crf",
            "18",
            "-movflags",
            "+faststart",
            "/tmp/scene-record/output.mp4"
        ])
    }

    func testSceneVideoFfmpegArgumentsFallsBackToPlainEncodeWhenTooShortToCrossfade() {
        // Given: only 4 recorded frames, far too few for the default 1.2s
        // (36-frame @ 30fps) crossfade window to fit twice over.
        let ffmpegArguments = SceneVideoRenderer.ffmpegArguments(
            framesDirectory: URL(filePath: "/tmp/scene-record"),
            fps: 30,
            recordedFrameCount: 4,
            outputURL: URL(filePath: "/tmp/scene-record/output.mp4")
        )

        // Then: falls back to a single-input, filter-free encode rather than
        // building an invalid (negative-offset) xfade graph.
        XCTAssertEqual(ffmpegArguments, [
            "-y",
            "-framerate",
            "30",
            "-i",
            "/tmp/scene-record/frame_%05d.png",
            "-c:v",
            "libx264",
            "-pix_fmt",
            "yuv420p",
            "-crf",
            "18",
            "-movflags",
            "+faststart",
            "/tmp/scene-record/output.mp4"
        ])
    }

    func testSceneVideoLoopCrossfadeMathProducesSeamlessLoopDuration() {
        // Given: a 20s @ 30fps recording (the app's default configuration).
        let fps = 30
        let totalFrameCount = 600

        // When
        let crossfadeFrameCount = SceneVideoLoopCrossfade.frameCount(totalFrameCount: totalFrameCount, fps: fps)
        let offsetSeconds = SceneVideoLoopCrossfade.offsetSeconds(
            totalFrameCount: totalFrameCount,
            crossfadeFrameCount: crossfadeFrameCount,
            fps: fps
        )
        let outputSeconds = SceneVideoLoopCrossfade.outputSeconds(
            totalFrameCount: totalFrameCount,
            crossfadeFrameCount: crossfadeFrameCount,
            fps: fps
        )

        // Then
        XCTAssertEqual(crossfadeFrameCount, 36) // round(1.2 * 30)
        XCTAssertEqual(offsetSeconds, (600.0 - 72.0) / 30.0, accuracy: 0.0001)
        // The crossfade's own output duration formula (offset + duration of
        // the transition) must equal totalSeconds - crossfadeSeconds, i.e.
        // the recorded clip minus exactly one crossfade window.
        let crossfadeSeconds = Double(crossfadeFrameCount) / Double(fps)
        XCTAssertEqual(offsetSeconds + crossfadeSeconds, outputSeconds, accuracy: 0.0001)
        XCTAssertEqual(outputSeconds, 20.0 - 1.2, accuracy: 0.0001)

        // Too-short recordings disable crossfading rather than producing a
        // negative offset.
        XCTAssertEqual(SceneVideoLoopCrossfade.frameCount(totalFrameCount: 2, fps: 2), 0)
        XCTAssertEqual(SceneVideoLoopCrossfade.frameCount(totalFrameCount: 0, fps: 30), 0)
    }

    func testSceneVideoRenderConfigurationDefaultsToTwentySecondsForLessFrequentLoopSeam() {
        // Given
        let configuration = SceneVideoRenderConfiguration(
            assetId: "asset",
            projectDirectory: URL(filePath: "/tmp/scene-project"),
            assetsDirectory: URL(filePath: "/tmp/wallpaper-engine-assets"),
            rendererURL: URL(filePath: "/tmp/wwb-scene-renderer"),
            size: CGSize(width: 1920, height: 1080)
        )

        // Then
        XCTAssertEqual(configuration.seconds, 20)
        XCTAssertEqual(configuration.fps, 30)
    }

    func testSceneVideoRenderProgressFractionComputesFramesWrittenOverTarget() {
        // Then
        XCTAssertEqual(SceneVideoRenderProgress.fraction(recordedFrameCount: 0, targetFrameCount: 600), 0)
        XCTAssertEqual(SceneVideoRenderProgress.fraction(recordedFrameCount: 300, targetFrameCount: 600), 0.5)
        XCTAssertEqual(SceneVideoRenderProgress.fraction(recordedFrameCount: 600, targetFrameCount: 600), 1.0)
        // Overshoot (renderer produced extra frames) is clamped rather than exceeding 1.
        XCTAssertEqual(SceneVideoRenderProgress.fraction(recordedFrameCount: 900, targetFrameCount: 600), 1.0)
        // A zero/unknown target is treated as no progress rather than dividing by zero.
        XCTAssertEqual(SceneVideoRenderProgress.fraction(recordedFrameCount: 10, targetFrameCount: 0), 0)
    }

    func testSceneVideoRendererReportsProgressWhileRecordingAndCompletesAtFullProgress() throws {
        guard let ffmpegPath = VideoConverter().ffmpegPath() else {
            throw XCTSkip("ffmpeg is required to encode the scene render fixture.")
        }

        // Given
        let root = try Self.makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let previousCacheDirectory = SceneVideoCache.overrideCacheDirectoryURL
        let cacheDirectory = root.appending(path: "SceneVideoCache")
        SceneVideoCache.overrideCacheDirectoryURL = cacheDirectory
        defer {
            SceneVideoCache.overrideCacheDirectoryURL = previousCacheDirectory
        }

        // A fake renderer that trickles frames out with a short pause between
        // each one, so the progress monitor's polling has a chance to observe
        // partial progress before the process exits.
        let rendererURL = root.appending(path: "fake-scene-renderer")
        let frameImageURL = try Self.writeSolidColorPNG(size: CGSize(width: 32, height: 32))
        let rendererScript = """
        #!/bin/sh
        set -e
        record_dir=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--record-dir" ]; then
            record_dir="$2"
          fi
          shift
        done
        cp "\(frameImageURL.path)" "$record_dir/frame_00001.png"
        sleep 0.4
        cp "\(frameImageURL.path)" "$record_dir/frame_00002.png"
        """
        try rendererScript.write(to: rendererURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rendererURL.path)

        let configuration = SceneVideoRenderConfiguration(
            assetId: "MjQ2ODQ4OTIyMw",
            projectDirectory: root,
            assetsDirectory: root,
            rendererURL: rendererURL,
            size: CGSize(width: 32, height: 32),
            fps: 2,
            seconds: 1
        )

        // When
        let reportedProgress = ProgressRecorder()
        let outputURL = try SceneVideoRenderer.render(
            configuration: configuration,
            ffmpegPath: ffmpegPath,
            progressHandler: { progress in
                reportedProgress.record(progress)
            }
        )

        // Then
        XCTAssertEqual(outputURL, SceneVideoCache.cachedVideoURL(assetId: configuration.assetId))
        let values = reportedProgress.values
        XCTAssertFalse(values.isEmpty, "Expected the progress handler to be invoked at least once.")
        XCTAssertEqual(values.last, 1.0, "Rendering should always finish by reporting full progress.")
        XCTAssertTrue(values.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    func testSceneVideoRecordSizeClampsLongEdgeAndPreservesAspectRatio() {
        // A logical size below the cap is used as-is (already even).
        XCTAssertEqual(
            SceneVideoRecordSize.clampedRecordSize(forLogicalSize: CGSize(width: 1512, height: 982)),
            CGSize(width: 1512, height: 982)
        )

        // A retina display's *physical* pixel size (e.g. doubled 3024x1964)
        // is exactly the case this guards against: it must be clamped down,
        // not recorded at full size.
        let clampedRetina = SceneVideoRecordSize.clampedRecordSize(forLogicalSize: CGSize(width: 3024, height: 1964))
        XCTAssertLessThanOrEqual(max(clampedRetina.width, clampedRetina.height), SceneVideoRecordSize.defaultMaxLongEdge)
        XCTAssertEqual(clampedRetina.width.truncatingRemainder(dividingBy: 2), 0)
        XCTAssertEqual(clampedRetina.height.truncatingRemainder(dividingBy: 2), 0)
        // Aspect ratio should be preserved (within rounding to even pixels).
        XCTAssertEqual(clampedRetina.width / clampedRetina.height, 3024.0 / 1964.0, accuracy: 0.01)

        // A custom cap is honored.
        let clampedCustom = SceneVideoRecordSize.clampedRecordSize(
            forLogicalSize: CGSize(width: 2560, height: 1440),
            maxLongEdge: 1920
        )
        XCTAssertEqual(clampedCustom, CGSize(width: 1920, height: 1080))

        // Degenerate input falls back to a square using the cap.
        XCTAssertEqual(
            SceneVideoRecordSize.clampedRecordSize(forLogicalSize: .zero),
            CGSize(width: SceneVideoRecordSize.defaultMaxLongEdge, height: SceneVideoRecordSize.defaultMaxLongEdge)
        )
    }

    func testSceneVideoCacheDirectoryIsVersionedToInvalidateStaleRenders() {
        // Given
        let previousOverride = SceneVideoCache.overrideCacheDirectoryURL
        SceneVideoCache.overrideCacheDirectoryURL = nil
        defer {
            SceneVideoCache.overrideCacheDirectoryURL = previousOverride
        }

        // When
        let cacheDirectory = SceneVideoCache.cacheDirectoryURL()

        // Then: the cache lives under a version-numbered subdirectory, so
        // bumping `cacheVersion` (done when the render pipeline changes in a
        // way that invalidates old clips, e.g. the record-size fix) causes
        // every previously cached video to simply never be found again.
        XCTAssertEqual(cacheDirectory.lastPathComponent, "v\(SceneVideoCache.cacheVersion)")
        XCTAssertGreaterThanOrEqual(SceneVideoCache.cacheVersion, 2)
    }

    func testSceneVideoCacheFreshnessComparesModificationDates() throws {
        // Given
        let root = try Self.makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let sourceURL = root.appending(path: "scene.pkg")
        try "scene".write(to: sourceURL, atomically: true, encoding: .utf8)
        let cacheURL = root.appending(path: "cached.mp4")

        // Then
        XCTAssertNil(SceneVideoCache.freshCachedVideoURL(assetId: "missing", sourceURL: sourceURL))

        // When the cache is written after the source, it is fresh.
        try "video".write(to: cacheURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(SceneVideoCache.isFresh(cacheURL: cacheURL, sourceURL: sourceURL))

        // When the source is modified after the cache, it is stale.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(3600)],
            ofItemAtPath: sourceURL.path
        )
        XCTAssertFalse(SceneVideoCache.isFresh(cacheURL: cacheURL, sourceURL: sourceURL))
    }

    func testSceneVideoRendererEncodesRecordedFramesIntoCachedMp4() throws {
        guard let ffmpegPath = VideoConverter().ffmpegPath() else {
            throw XCTSkip("ffmpeg is required to encode the scene render fixture.")
        }

        // Given
        let root = try Self.makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let previousCacheDirectory = SceneVideoCache.overrideCacheDirectoryURL
        let cacheDirectory = root.appending(path: "SceneVideoCache")
        SceneVideoCache.overrideCacheDirectoryURL = cacheDirectory
        defer {
            SceneVideoCache.overrideCacheDirectoryURL = previousCacheDirectory
        }

        // A fake renderer script that drops two solid-color PNG frames into
        // the --record-dir it is given, standing in for the real
        // wwb-scene-renderer binary.
        let rendererURL = root.appending(path: "fake-scene-renderer")
        let frameImageURL = try Self.writeSolidColorPNG(size: CGSize(width: 32, height: 32))
        let rendererScript = """
        #!/bin/sh
        set -e
        record_dir=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--record-dir" ]; then
            record_dir="$2"
          fi
          shift
        done
        cp "\(frameImageURL.path)" "$record_dir/frame_00001.png"
        cp "\(frameImageURL.path)" "$record_dir/frame_00002.png"
        """
        try rendererScript.write(to: rendererURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rendererURL.path)

        let configuration = SceneVideoRenderConfiguration(
            assetId: "MjQ2ODQ4OTIyMw",
            projectDirectory: root,
            assetsDirectory: root,
            rendererURL: rendererURL,
            size: CGSize(width: 32, height: 32),
            fps: 2,
            seconds: 1
        )

        // When
        let outputURL = try SceneVideoRenderer.render(configuration: configuration, ffmpegPath: ffmpegPath)

        // Then
        XCTAssertEqual(outputURL, SceneVideoCache.cachedVideoURL(assetId: configuration.assetId))
        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        XCTAssertGreaterThan((attributes[.size] as? Int) ?? 0, 0)
    }

    @MainActor
    func testSceneEngineRendererFallsBackToBundledExecutablePath() throws {
        // Given
        let root = try Self.makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let rendererDirectory = root.appending(path: "Renderers")
        try FileManager.default.createDirectory(at: rendererDirectory, withIntermediateDirectories: true)
        let bundledRendererURL = rendererDirectory.appending(path: "wwb-scene-renderer")
        try "#!/bin/sh\nexit 0\n".write(to: bundledRendererURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledRendererURL.path)
        let previousRendererPath = SceneEngineRendererConfiguration.overrideExecutablePath
        let previousResourceURL = SceneEngineRendererConfiguration.overrideResourceURL
        SceneEngineRendererConfiguration.overrideExecutablePath = nil
        SceneEngineRendererConfiguration.overrideResourceURL = root
        defer {
            SceneEngineRendererConfiguration.overrideExecutablePath = previousRendererPath
            SceneEngineRendererConfiguration.overrideResourceURL = previousResourceURL
        }

        // When
        let resolved = SceneEngineRendererConfiguration.executableURL(environment: [:])

        // Then
        XCTAssertEqual(resolved?.path, bundledRendererURL.path)
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
            .materialColor,
            .spin
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

    private static func writeSolidColorPNG(size: CGSize) throws -> URL {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemBlue.setFill()
        CGRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
            throw XCTSkip("Could not render a PNG fixture frame.")
        }
        let url = FileManager.default.temporaryDirectory
            .appending(path: "wwb-frame-\(UUID().uuidString).png")
        try data.write(to: url)
        return url
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

    private static func writeSceneEngineAssetsFixture(in root: URL) throws -> URL {
        let assetsDirectory = root.appending(path: "wallpaper-engine-assets")
        for relativePath in SceneEngineRendererConfiguration.requiredAssetPaths {
            let fileURL = assetsDirectory.appending(path: relativePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "{}\n".write(to: fileURL, atomically: true, encoding: .utf8)
        }
        return assetsDirectory
    }

    private static func sceneAsset(root: URL, entrypoint: URL) -> WallpaperAsset {
        WallpaperAsset(
            id: root.lastPathComponent,
            title: "Scene",
            kind: .scene,
            supportStatus: .playable,
            source: .localSteamWorkshop,
            projectDirectory: root.path,
            entrypoint: entrypoint.path,
            thumbnail: nil,
            workshopId: nil,
            redistributionAllowed: false,
            issues: []
        )
    }
}

/// Collects progress values reported from the background queue the scene
/// video render progress monitor runs on.
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [Double] = []

    func record(_ value: Double) {
        lock.lock()
        defer { lock.unlock() }
        storedValues.append(value)
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return storedValues
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
