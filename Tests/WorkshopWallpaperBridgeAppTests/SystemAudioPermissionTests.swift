import AppKit
import XCTest
@testable import WorkshopWallpaperBridgeApp

@MainActor
final class SystemAudioPermissionTests: XCTestCase {
    private final class Capture: SystemAudioCapturing {
        var stops = 0
        var onStop: (@MainActor () async -> Void)?
        func stop() async { stops += 1; await onStop?() }
    }

    func testTerminalErrorRejectsLateSamplesAndPendingStartup() async {
        let capture = Capture()
        let starting = expectation(description: "Starting capture")
        let failed = expectation(description: "Terminal error delivered")
        var complete: CheckedContinuation<any SystemAudioCapturing, any Error>?
        var receive: (@Sendable (WallpaperAudioSpectrum) -> Void)?
        var stopped: (@Sendable (String) -> Void)?
        let audio = SystemAudioAnalysis(permissionCheck: { true }, permissionRequest: { false },
            openSettings: {}, automaticallyRefreshPermission: false, startCapture: { sample, failure in
                receive = sample; stopped = failure
                return try await withCheckedThrowingContinuation { complete = $0; starting.fulfill() }
            })
        let observation = audio.$status.filter { !$0.isEmpty }.prefix(1).sink { _ in failed.fulfill() }
        defer { observation.cancel() }
        audio.setEnabled(true)
        let consumer = audio.acquire()
        await fulfillment(of: [starting], timeout: 2)
        stopped?("Capture ended")
        await fulfillment(of: [failed], timeout: 2)
        receive?(WallpaperAudioSpectrum(left: Array(repeating: 1, count: 64), right: Array(repeating: 1, count: 64)))
        complete?.resume(returning: capture)
        await audio.waitForTransition()
        XCTAssertEqual(capture.stops, 1, "A terminally failed startup must be stopped instead of installed")
        XCTAssertEqual(audio.currentSpectrum.left, Array(repeating: 0, count: 64))
        audio.release(consumer)
        audio.setEnabled(false)
        await audio.waitForTransition()
    }

    func testReplacementWaitsForSuspendedStopAndRejectsOldErrors() async {
        let capture = Capture(), next = Capture()
        let stopping = expectation(description: "Old capture stopping")
        var finishStop: CheckedContinuation<Void, Never>?
        capture.onStop = { await withCheckedContinuation { finishStop = $0; stopping.fulfill() } }
        var starts = 0
        var oldFailure: (@Sendable (String) -> Void)?
        let audio = SystemAudioAnalysis(permissionCheck: { true }, permissionRequest: { false },
            openSettings: {}, automaticallyRefreshPermission: false, startCapture: { _, failure in
                starts += 1
                if starts == 1 { oldFailure = failure; return capture }
                return next
            })
        audio.setEnabled(true)
        let consumer = audio.acquire()
        await audio.waitForTransition()
        audio.setEnabled(false)
        await fulfillment(of: [stopping], timeout: 2)
        audio.setEnabled(true)
        oldFailure?("Obsolete error")
        XCTAssertEqual(starts, 1)
        finishStop?.resume()
        await audio.waitForTransition()
        XCTAssertEqual(starts, 2)
        XCTAssertTrue(audio.status.isEmpty)
        audio.release(consumer)
        audio.setEnabled(false)
        await audio.waitForTransition()
        XCTAssertEqual(next.stops, 1)
    }

    func testDeniedPermissionNeverStartsCaptureOrPromptsDuringPlayback() async {
        var starts = 0, requests = 0, settings = 0
        let audio = SystemAudioAnalysis(permissionCheck: { false }, permissionRequest: { requests += 1; return false },
            openSettings: { settings += 1 }, automaticallyRefreshPermission: false,
            startCapture: { _, _ in starts += 1; return Capture() })
        audio.setEnabled(true)
        for _ in 0..<4 {
            let consumer = audio.acquire()
            audio.refreshPermission()
            audio.setEnabled(true)
            audio.release(consumer)
        }
        await audio.waitForTransition()
        XCTAssertTrue(audio.needsPermission)
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(settings, 0)
        audio.setEnabled(false)
        XCTAssertFalse(audio.needsPermission)
    }

    func testGrantedPermissionDoesNotPromptOrRestartAnActiveCapture() async {
        var starts = 0, requests = 0, settings = 0
        let capture = Capture()
        let audio = SystemAudioAnalysis(permissionCheck: { true }, permissionRequest: { requests += 1; return true },
            openSettings: { settings += 1 }, automaticallyRefreshPermission: false,
            startCapture: { _, _ in starts += 1; return capture })
        audio.setEnabled(true)
        let first = audio.acquire()
        await audio.waitForTransition()
        let second = audio.acquire()
        audio.setEnabled(true)
        audio.refreshPermission()
        audio.authorize()
        audio.release(second)
        await audio.waitForTransition()
        XCTAssertFalse(audio.needsPermission)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(capture.stops, 0)
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(settings, 0)
        audio.release(first)
        await audio.waitForTransition()
        XCTAssertEqual(capture.stops, 1)
    }

    func testSettingsGrantAndRevocationAreReflectedWithoutAnotherPrompt() async {
        var granted = false, starts = 0, requests = 0
        let capture = Capture()
        let audio = SystemAudioAnalysis(permissionCheck: { granted }, permissionRequest: { requests += 1; return false },
            openSettings: {}, automaticallyRefreshPermission: false,
            startCapture: { _, _ in starts += 1; return capture })
        audio.setEnabled(true)
        let consumer = audio.acquire()
        await audio.waitForTransition()
        granted = true
        audio.refreshPermission()
        await audio.waitForTransition()
        XCTAssertFalse(audio.needsPermission)
        XCTAssertEqual(starts, 1)
        granted = false
        audio.refreshPermission()
        await audio.waitForTransition()
        XCTAssertTrue(audio.needsPermission)
        XCTAssertEqual(capture.stops, 1)
        XCTAssertEqual(requests, 0)
        audio.release(consumer)
        audio.setEnabled(false)
        await audio.waitForTransition()
    }

    func testOnlyExplicitAuthorizationRequestsMissingPermissionOnce() async {
        var granted = false, requests = 0, settings = 0
        let audio = SystemAudioAnalysis(permissionCheck: { granted }, permissionRequest: { requests += 1; return false },
            openSettings: { settings += 1 }, automaticallyRefreshPermission: false,
            startCapture: { _, _ in Capture() })
        audio.setEnabled(true)
        audio.authorize()
        audio.authorize()
        XCTAssertEqual(requests, 1, "A denied system prompt is not repeatedly requested in the same launch")
        XCTAssertEqual(settings, 2, "Further user actions open the existing Settings entry")
        granted = true
        audio.authorize()
        XCTAssertFalse(audio.needsPermission)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(settings, 2)
        audio.setEnabled(false)
        await audio.waitForTransition()
    }

    func testRevocationWhileStartingStopsTheStaleCapture() async {
        var granted = true
        let capture = Capture()
        let started = expectation(description: "Capture startup pending")
        var continuation: CheckedContinuation<any SystemAudioCapturing, any Error>?
        let audio = SystemAudioAnalysis(permissionCheck: { granted }, permissionRequest: { false },
            openSettings: {}, automaticallyRefreshPermission: false, startCapture: { _, _ in
                try await withCheckedThrowingContinuation { continuation = $0; started.fulfill() }
            })
        audio.setEnabled(true)
        let consumer = audio.acquire()
        await fulfillment(of: [started], timeout: 2)
        granted = false
        audio.refreshPermission()
        continuation?.resume(returning: capture)
        await audio.waitForTransition()
        XCTAssertEqual(capture.stops, 1)
        XCTAssertTrue(audio.needsPermission)
        audio.release(consumer)
        audio.setEnabled(false)
        await audio.waitForTransition()
    }

    func testCaptureFailureWithGrantedPermissionDoesNotAskToAuthorizeAgain() async {
        var starts = 0, requests = 0
        let audio = SystemAudioAnalysis(permissionCheck: { true }, permissionRequest: { requests += 1; return false },
            openSettings: {}, automaticallyRefreshPermission: false, startCapture: { _, _ in
                starts += 1
                throw NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: -3801)
            })
        audio.setEnabled(true)
        let consumer = audio.acquire()
        await audio.waitForTransition()
        XCTAssertFalse(audio.needsPermission)
        XCTAssertEqual(audio.status, "settings.audioReactive.restart")
        audio.refreshPermission()
        audio.setEnabled(true)
        audio.release(consumer)
        let replacement = audio.acquire()
        await audio.waitForTransition()
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(requests, 0)
        audio.retryCapture()
        await audio.waitForTransition()
        XCTAssertEqual(starts, 2, "Only explicit retry restarts a failed capture")
        XCTAssertEqual(requests, 0)
        audio.release(replacement)
        audio.setEnabled(false)
        await audio.waitForTransition()
    }
}
