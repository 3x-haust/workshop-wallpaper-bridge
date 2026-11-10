import AppKit
import XCTest
import WorkshopWallpaperCore
@testable import WorkshopWallpaperBridgeApp

@MainActor
final class WallpaperReplacementTests: XCTestCase {
    func testRejectedAssetKeepsCurrentWindowsAndPlaybackSettings() throws {
        for missingEntrypoint in [false, true] {
            let harness = Harness()
            let player = harness.player()
            defer { player.stop() }
            try player.play(asset: asset("current"), autoPauseWhenCovered: false,
                            displayMode: .fill, audioEnabled: true, audioVolume: 0.75)
            let original = harness.windows
            let rejected = asset("rejected", supportStatus: missingEntrypoint ? .playable : .unsupported,
                                 missingEntrypoint: missingEntrypoint)

            XCTAssertThrowsError(try player.play(asset: rejected, autoPauseWhenCovered: false,
                                                 displayMode: .fit, audioEnabled: false, audioVolume: 0.1))

            XCTAssertEqual(original.map(\.closeCount), [0, 0])
            XCTAssertEqual(harness.requests.count, 2, "Validation must precede window creation")
            player.setInteractionEnabled(true)
            XCTAssertTrue(original.allSatisfy { $0.interactionEnabled })
            player.refreshIfNeeded(afterSceneVideoRenderFor: "current")
            XCTAssertEqual(harness.requests.count, 4, "The current asset must survive a rejected replacement")
            XCTAssertEqual(harness.requests.last?.assetID, "current")
            XCTAssertEqual(harness.requests.last?.displayMode, .fill)
            XCTAssertEqual(harness.requests.last?.audioEnabled, false)
            XCTAssertEqual(harness.requests.last?.audioVolume, 0.75)
            XCTAssertEqual(harness.windows.suffix(2).map(\.audioEnabled), [true, true])
            XCTAssertEqual(harness.windows.suffix(2).map(\.audioVolume), [0.75, 0.75])
        }
    }

    func testFirstWindowPreparationFailureKeepsCurrentPlayback() throws {
        let harness = Harness()
        let player = harness.player()
        defer { player.stop() }
        try player.play(asset: asset("current"), autoPauseWhenCovered: false)
        let original = harness.windows
        harness.failAtRequest = 3

        XCTAssertThrowsError(try player.play(asset: asset("replacement"), autoPauseWhenCovered: false)) {
            XCTAssertEqual($0 as? PreparationError, .failed)
        }

        XCTAssertEqual(original.map(\.closeCount), [0, 0])
        player.setAudioSettings(enabled: true, volume: 0.25)
        XCTAssertEqual(original.map(\.audioVolume), [0.25, 0.25])
    }

    func testLaterScreenFailureClosesOnlyPreparedReplacementWindows() throws {
        let harness = Harness()
        let player = harness.player()
        defer { player.stop() }
        try player.play(asset: asset("current"), autoPauseWhenCovered: false)
        let original = harness.windows
        harness.failAtRequest = 4

        XCTAssertThrowsError(try player.play(asset: asset("replacement"), autoPauseWhenCovered: false))

        XCTAssertEqual(original.map(\.closeCount), [0, 0])
        let partial = try XCTUnwrap(harness.windows.last)
        XCTAssertEqual(partial.closeCount, 1, "Partially prepared content must run its close lifecycle")
        XCTAssertEqual(partial.showCount, 0)
        player.setDisplayMode(.stretch)
        XCTAssertEqual(original.map(\.displayMode), [.stretch, .stretch])
        XCTAssertNil(partial.displayMode, "Failed candidates must not remain active")
    }

    func testSuccessfulReplacementPreparesEveryScreenBeforeClosingCurrentWindows() throws {
        let harness = Harness()
        let player = harness.player()
        defer { player.stop() }
        try player.play(asset: asset("current"), autoPauseWhenCovered: false)
        player.setInteractionEnabled(true)
        harness.events.removeAll()

        try player.play(asset: asset("replacement"), autoPauseWhenCovered: false,
                        displayMode: .fill, audioEnabled: true, audioVolume: 0.6)

        XCTAssertEqual(harness.events, ["prepare-3", "prepare-4", "close-1", "close-2", "show-3", "show-4"])
        XCTAssertEqual(harness.windows.map(\.closeCount), [1, 1, 0, 0])
        XCTAssertTrue(harness.windows.suffix(2).allSatisfy { $0.interactionEnabled })
        XCTAssertEqual(harness.requests.suffix(2).map(\.audioEnabled), [false, false])
        XCTAssertEqual(harness.requests.suffix(2).map(\.audioVolume), [0.6, 0.6])
        XCTAssertEqual(harness.windows.suffix(2).map(\.audioEnabled), [true, true])
        XCTAssertEqual(harness.windows.suffix(2).map(\.audioVolume), [0.6, 0.6])
        player.stop()
        XCTAssertEqual(harness.windows.map(\.closeCount), [1, 1, 1, 1])
    }

    func testSceneRefreshFailurePreservesCurrentWindowsAndCleansPartialPreparation() throws {
        let harness = Harness()
        let player = harness.player()
        defer { player.stop() }
        try player.play(asset: asset("current"), autoPauseWhenCovered: false)
        harness.failAtRequest = 4

        player.refreshIfNeeded(afterSceneVideoRenderFor: "current")

        XCTAssertEqual(harness.windows.map(\.closeCount), [0, 0, 1])
        XCTAssertEqual(harness.windows.map(\.showCount), [1, 1, 0])
        harness.failAtRequest = nil
        player.refreshIfNeeded(afterSceneVideoRenderFor: "current")
        XCTAssertEqual(harness.requests.count, 6)
        XCTAssertEqual(harness.windows.map(\.closeCount), [1, 1, 1, 0, 0])
    }

    func testWakeReopenFailurePreservesCurrentWindowsAndAllowsRetry() throws {
        let harness = Harness()
        let player = harness.player()
        defer { player.stop() }
        try player.play(asset: asset("current"), autoPauseWhenCovered: false)
        harness.failAtRequest = 4

        player.reopenAfterWake()

        XCTAssertEqual(harness.windows.map(\.closeCount), [0, 0, 1])
        harness.failAtRequest = nil
        player.reopenAfterWake()
        XCTAssertEqual(harness.windows.map(\.closeCount), [1, 1, 1, 0, 0])
    }

    func testReplacementWaitsForEveryScreenBeforeReadyEvent() throws {
        let harness = Harness()
        let player = harness.player()
        defer { player.stop() }
        try player.play(asset: asset("current"), autoPauseWhenCovered: false)
        harness.automaticallyReady = false
        var events: [WallpaperPlaybackEvent] = []
        player.setPlaybackStatusHandler { events.append($0) }

        try player.play(asset: asset("replacement"), autoPauseWhenCovered: false)
        XCTAssertEqual(harness.windows.map(\.closeCount), [0, 0, 0, 0])
        XCTAssertEqual(harness.windows.map(\.showCount), [1, 1, 0, 0])
        XCTAssertEqual(events, [])
        harness.windows[2].complete(.success(()))
        XCTAssertEqual(harness.windows.map(\.closeCount), [0, 0, 0, 0])
        XCTAssertEqual(events, [])
        harness.windows[3].complete(.success(()))

        XCTAssertEqual(harness.windows.map(\.closeCount), [1, 1, 0, 0])
        XCTAssertEqual(harness.windows.map(\.showCount), [1, 1, 1, 1])
        XCTAssertEqual(events, [.ready(assetID: "replacement")])
        harness.windows[3].complete(.success(()))
        XCTAssertEqual(events.count, 1)
    }

    func testAsyncLoadFailureKeepsCurrentPlaybackAndClosesEntireCandidateBatch() throws {
        let harness = Harness()
        let player = harness.player()
        defer { player.stop() }
        try player.play(asset: asset("current"), autoPauseWhenCovered: false,
                        displayMode: .fill, audioEnabled: true, audioVolume: 0.75)
        harness.automaticallyReady = false
        var events: [WallpaperPlaybackEvent] = []
        player.setPlaybackStatusHandler { events.append($0) }
        try player.play(asset: asset("replacement"), autoPauseWhenCovered: false,
                        displayMode: .fit, audioEnabled: false, audioVolume: 0.1)
        harness.windows[2].complete(.success(()))

        harness.windows[3].complete(.failure(WallpaperPreparationError(message: "load failed")))

        XCTAssertEqual(harness.windows.map(\.closeCount), [0, 0, 1, 1])
        XCTAssertEqual(harness.windows.map(\.showCount), [1, 1, 0, 0])
        XCTAssertEqual(events, [.failed(assetID: "replacement", message: "load failed")])
        harness.automaticallyReady = true
        player.refreshIfNeeded(afterSceneVideoRenderFor: "current")
        XCTAssertEqual(harness.requests.last?.assetID, "current")
        XCTAssertEqual(harness.requests.last?.displayMode, .fill)
        XCTAssertEqual(harness.requests.last?.audioEnabled, false)
        XCTAssertEqual(harness.requests.last?.audioVolume, 0.75)
        XCTAssertEqual(harness.windows.suffix(2).map(\.audioEnabled), [true, true])
        XCTAssertEqual(harness.windows.suffix(2).map(\.audioVolume), [0.75, 0.75])
    }

    func testSupersedingSameAssetIgnoresOldReadinessAndFailureCallbacks() throws {
        let harness = Harness()
        let player = harness.player()
        defer { player.stop() }
        harness.automaticallyReady = false
        var events: [WallpaperPlaybackEvent] = []
        player.setPlaybackStatusHandler { events.append($0) }
        try player.play(asset: asset("same"), autoPauseWhenCovered: false)
        try player.play(asset: asset("same"), autoPauseWhenCovered: false)

        harness.windows[0].complete(.success(()))
        harness.windows[1].complete(.failure(PreparationError.failed))

        XCTAssertEqual(harness.windows.map(\.closeCount), [1, 1, 0, 0])
        XCTAssertEqual(events, [])
        harness.windows[2].complete(.success(()))
        harness.windows[3].complete(.success(()))
        XCTAssertEqual(events, [.ready(assetID: "same")])
    }

    func testStopClosesPendingWindowsAndIgnoresLateCallbacks() throws {
        let harness = Harness()
        let player = harness.player()
        harness.automaticallyReady = false
        var events: [WallpaperPlaybackEvent] = []
        player.setPlaybackStatusHandler { events.append($0) }
        try player.play(asset: asset("pending"), autoPauseWhenCovered: false)

        player.stop()
        harness.windows[0].complete(.success(()))
        harness.windows[1].complete(.failure(PreparationError.failed))

        XCTAssertEqual(harness.windows.map(\.closeCount), [1, 1])
        XCTAssertEqual(harness.windows.map(\.showCount), [0, 0])
        XCTAssertEqual(events, [])
    }

    func testCancelPendingPlaybackPreservesCurrentWindowsAndIgnoresLateCallbacks() throws {
        let harness = Harness()
        let player = harness.player()
        defer { player.stop() }
        try player.play(asset: asset("current"), autoPauseWhenCovered: false,
                        displayMode: .fill, audioEnabled: true, audioVolume: 0.75)
        harness.automaticallyReady = false
        var events: [WallpaperPlaybackEvent] = []
        player.setPlaybackStatusHandler { events.append($0) }
        try player.play(asset: asset("pending"), autoPauseWhenCovered: false)
        harness.windows[2].complete(.success(()))

        let playing: any WallpaperPlaying = player
        playing.cancelPendingPlayback()

        XCTAssertEqual(harness.windows.map(\.closeCount), [0, 0, 1, 1])
        XCTAssertEqual(harness.windows.map(\.showCount), [1, 1, 0, 0])
        harness.windows[3].complete(.success(()))
        harness.windows[2].complete(.failure(PreparationError.failed))
        XCTAssertEqual(harness.windows.map(\.closeCount), [0, 0, 1, 1])
        XCTAssertEqual(harness.windows.map(\.showCount), [1, 1, 0, 0])
        XCTAssertEqual(events, [])
        XCTAssertEqual(harness.windows.prefix(2).map(\.audioEnabled), [true, true])
        XCTAssertEqual(harness.windows.prefix(2).map(\.audioVolume), [0.75, 0.75])

        playing.cancelPendingPlayback()
        XCTAssertEqual(harness.windows.map(\.closeCount), [0, 0, 1, 1])
        harness.automaticallyReady = true
        player.refreshIfNeeded(afterSceneVideoRenderFor: "current")
        XCTAssertEqual(harness.requests.last?.assetID, "current")
        XCTAssertEqual(harness.requests.last?.displayMode, .fill)
        XCTAssertEqual(harness.windows.map(\.closeCount), [1, 1, 1, 1, 0, 0])
        XCTAssertEqual(events, [.ready(assetID: "current")])
    }

    func testRejectedNewRequestCancelsPendingReplacementWithoutClosingCurrentWindows() throws {
        let harness = Harness()
        let player = harness.player()
        defer { player.stop() }
        try player.play(asset: asset("current"), autoPauseWhenCovered: false)
        harness.automaticallyReady = false
        try player.play(asset: asset("pending"), autoPauseWhenCovered: false)

        XCTAssertThrowsError(try player.play(asset: asset("unsupported", supportStatus: .unsupported)))
        harness.windows[2].complete(.success(()))
        harness.windows[3].complete(.success(()))

        XCTAssertEqual(harness.windows.map(\.closeCount), [0, 0, 1, 1])
        XCTAssertEqual(harness.windows.map(\.showCount), [1, 1, 0, 0])
    }

    func testSceneRefreshDoesNotSupersedeNewPendingSelection() throws {
        let harness = Harness()
        let player = harness.player()
        defer { player.stop() }
        try player.play(asset: asset("current"), autoPauseWhenCovered: false)
        harness.automaticallyReady = false
        try player.play(asset: asset("pending"), autoPauseWhenCovered: false)

        player.refreshIfNeeded(afterSceneVideoRenderFor: "current")

        XCTAssertEqual(harness.requests.count, 4)
        XCTAssertEqual(harness.windows.map(\.closeCount), [0, 0, 0, 0])
    }

    func testPendingCandidatesStayMutedUntilEveryScreenIsReadyAndUseLatestAudioSettings() throws {
        let harness = Harness()
        let player = harness.player()
        defer { player.stop() }
        try player.play(asset: asset("current"), autoPauseWhenCovered: false,
                        audioEnabled: true, audioVolume: 0.75)
        let original = harness.windows
        harness.automaticallyReady = false

        try player.play(asset: asset("replacement"), autoPauseWhenCovered: false,
                        audioEnabled: true, audioVolume: 0.2)
        let candidates = Array(harness.windows.suffix(2))

        XCTAssertEqual(harness.requests.suffix(2).map(\.audioEnabled), [false, false],
                       "Window preparation must start muted, before content can begin playing")
        XCTAssertEqual(original.map(\.audioEnabled), [true, true])
        XCTAssertEqual(original.map(\.audioVolume), [0.75, 0.75])
        XCTAssertEqual(candidates.map(\.audioEnabled), [false, false])
        candidates[0].complete(.success(()))
        XCTAssertEqual(candidates.map(\.audioEnabled), [false, false])
        XCTAssertEqual(original.map(\.closeCount), [0, 0])

        player.setAudioSettings(enabled: true, volume: 0.9)
        XCTAssertEqual(original.map(\.audioVolume), [0.9, 0.9])
        XCTAssertEqual(candidates.map(\.audioEnabled), [false, false])
        XCTAssertEqual(candidates.map(\.showCount), [0, 0])
        candidates[1].complete(.success(()))

        XCTAssertEqual(original.map(\.closeCount), [1, 1])
        XCTAssertEqual(candidates.map(\.audioEnabled), [true, true])
        XCTAssertEqual(candidates.map(\.audioVolume), [0.9, 0.9])
        XCTAssertEqual(candidates.map(\.showCount), [1, 1])
    }

    func testSettingsChangedDuringPreparationApplyAtCommit() throws {
        let harness = Harness()
        let player = harness.player()
        defer { player.stop() }
        harness.automaticallyReady = false
        try player.play(asset: asset("pending"), autoPauseWhenCovered: false)

        player.setAudioSettings(enabled: true, volume: 0.9)
        player.setDisplayMode(.stretch)
        player.setInteractionEnabled(true)
        harness.windows.forEach { $0.complete(.success(())) }

        XCTAssertEqual(harness.windows.map(\.audioVolume), [0.9, 0.9])
        XCTAssertEqual(harness.windows.map(\.audioEnabled), [true, true])
        XCTAssertEqual(harness.windows.map(\.displayMode), [.stretch, .stretch])
        XCTAssertTrue(harness.windows.allSatisfy { $0.interactionEnabled })
    }

    private func asset(_ id: String, supportStatus: SupportStatus = .playable,
                       missingEntrypoint: Bool = false) -> WallpaperAsset {
        WallpaperAsset(id: id, title: id, kind: .scene, supportStatus: supportStatus,
                       source: .manualFolder, projectDirectory: "/unused/\(id)",
                       entrypoint: missingEntrypoint ? nil : "/unused/\(id)/scene.json", thumbnail: nil,
                       workshopId: nil, redistributionAllowed: false, issues: [])
    }
}

private enum PreparationError: Error { case failed }

@MainActor
private final class Harness {
    struct Request {
        let assetID: String
        let displayMode: WallpaperDisplayMode
        let audioEnabled: Bool
        let audioVolume: Double
    }
    var requests: [Request] = []
    var windows: [FakeWindow] = []
    var events: [String] = []
    var failAtRequest: Int?
    var automaticallyReady = true

    func player() -> WallpaperPlayer {
        WallpaperPlayer(screenFrames: {
            [CGRect(x: 0, y: 0, width: 100, height: 100),
             CGRect(x: 100, y: 0, width: 100, height: 100)]
        }, makeWindow: { [self] asset, _, _, mode, audio, volume in
            requests.append(Request(assetID: asset.id, displayMode: mode,
                                    audioEnabled: audio, audioVolume: volume))
            let index = requests.count
            events.append("prepare-\(index)")
            if failAtRequest == index { throw PreparationError.failed }
            let window = FakeWindow(index: index, automaticallyReady: automaticallyReady) { [weak self] in self?.events.append($0) }
            window.setAudio(enabled: audio, volume: volume)
            windows.append(window)
            return window
        })
    }
}

@MainActor
private final class FakeWindow: WallpaperWindowControlling {
    let index: Int
    let record: (String) -> Void
    var closeCount = 0
    var showCount = 0
    var interactionEnabled = false
    var displayMode: WallpaperDisplayMode?
    var audioVolume: Double?
    var audioEnabled: Bool?
    let automaticallyReady: Bool
    private var readinessHandler: ((Result<Void, Error>) -> Void)?

    init(index: Int, automaticallyReady: Bool, record: @escaping (String) -> Void) {
        self.index = index
        self.automaticallyReady = automaticallyReady
        self.record = record
    }

    func whenReady(_ completion: @escaping (Result<Void, Error>) -> Void) {
        readinessHandler = completion
        if automaticallyReady { completion(.success(())) }
    }
    func complete(_ result: Result<Void, Error>) { readinessHandler?(result) }
    func show() { showCount += 1; record("show-\(index)") }
    func close() { closeCount += 1; record("close-\(index)") }
    func reassertDesktopOrder() {}
    func setSuspended(_ suspended: Bool) {}
    func setDisplayMode(_ displayMode: WallpaperDisplayMode) { self.displayMode = displayMode }
    func setInteractionEnabled(_ enabled: Bool) { interactionEnabled = enabled }
    func setAudio(enabled: Bool, volume: Double) { audioEnabled = enabled; audioVolume = volume }
}
