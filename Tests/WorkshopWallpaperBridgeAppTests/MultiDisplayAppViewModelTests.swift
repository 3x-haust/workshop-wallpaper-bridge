import Foundation
import XCTest
@testable import WorkshopWallpaperBridgeApp
import WorkshopWallpaperCore

@MainActor
final class MultiDisplayAppViewModelTests: XCTestCase {
    func testChangingAndStoppingSecondDisplayLeavesFirstDisplayPlayingUnchanged() throws {
        let fixture = try makeFixture()
        let model = fixture.model
        play("first", on: "A", model: model)
        model.applySelectedDisplayMode(.fill)
        let firstAssignment = try XCTUnwrap(model.displayAssignments["A"])

        play("second", on: "B", model: model)
        model.applySelectedDisplayMode(.fit)
        model.stopSelectedPlayback()

        XCTAssertEqual(model.displayAssignments["A"], firstAssignment)
        XCTAssertEqual(fixture.player.activeAssignments["A"], firstAssignment)
        XCTAssertEqual(model.displayAssignments["B"], assignment("second", mode: .fit, playing: false))
        XCTAssertNil(fixture.player.activeAssignments["B"])
        XCTAssertEqual(fixture.player.stopTargets, [["B"]])
        XCTAssertEqual(fixture.player.playCalls.map(\.displayIDs), [["A"], ["B"]])
        XCTAssertEqual(fixture.player.modeCalls.last, .init(mode: .fit, displayIDs: ["B"]))
        XCTAssertEqual(try savedAssignments(fixture.defaults), model.displayAssignments)
        XCTAssertEqual(fixture.player.globalStopCount, 0)
    }

    func testSelectingDisplaysOnlyReadsTheirModesWithoutChangingPlaybackOrPreferences() throws {
        let fixture = try makeFixture()
        let model = fixture.model
        play("first", on: "A", model: model)
        model.applySelectedDisplayMode(.fill)
        play("second", on: "B", model: model)
        model.applySelectedDisplayMode(.fit)
        let assignments = model.displayAssignments
        let saved = fixture.defaults.data(forKey: "displayWallpaperAssignments")
        let savedMode = fixture.defaults.string(forKey: "displayMode")
        let modeCalls = fixture.player.modeCalls
        let playCalls = fixture.player.playCalls

        model.selectedDisplayID = "A"
        XCTAssertEqual(model.selectedDisplayIDs, ["A"])
        XCTAssertEqual(model.selectedDisplayMode, .fill)
        model.selectedDisplayID = "B"
        XCTAssertEqual(model.selectedDisplayMode, .fit)
        model.selectedDisplayID = ""
        XCTAssertEqual(model.selectedDisplayIDs, ["A", "B"])
        XCTAssertNil(model.selectedDisplayMode)
        model.applySelectedDisplayMode(nil)

        XCTAssertEqual(model.connectedDisplays.map(\.id), ["A", "B"])
        XCTAssertEqual(model.displayAssignments, assignments)
        XCTAssertEqual(fixture.player.modeCalls, modeCalls)
        XCTAssertEqual(fixture.player.playCalls, playCalls)
        XCTAssertEqual(fixture.defaults.data(forKey: "displayWallpaperAssignments"), saved)
        XCTAssertEqual(fixture.defaults.string(forKey: "displayMode"), savedMode)
    }

    func testApplyingModeToAllConnectedDisplaysResolvesMixedModes() throws {
        let fixture = try makeFixture()
        play("first", on: "A", model: fixture.model)
        fixture.model.applySelectedDisplayMode(.fill)
        play("second", on: "B", model: fixture.model)
        fixture.model.applySelectedDisplayMode(.fit)
        fixture.model.selectedDisplayID = ""
        XCTAssertNil(fixture.model.selectedDisplayMode)

        fixture.model.applySelectedDisplayMode(.fill)

        XCTAssertEqual(fixture.model.selectedDisplayMode, .fill)
        XCTAssertEqual(fixture.model.displayAssignments["A"], assignment("first", mode: .fill))
        XCTAssertEqual(fixture.model.displayAssignments["B"], assignment("second", mode: .fill))
        XCTAssertEqual(fixture.player.modeCalls.last, .init(mode: .fill, displayIDs: ["A", "B"]))
        XCTAssertEqual(try savedAssignments(fixture.defaults), fixture.model.displayAssignments)
    }

    func testRotationOnFirstDisplayCoexistsWithFixedSecondDisplayAfterRelaunch() throws {
        let fixture = try makeFixture()
        play("second", on: "B", model: fixture.model)
        fixture.model.applySelectedDisplayMode(.fill)
        startRotation(on: "A", assetID: "first", model: fixture.model)
        fixture.model.applySelectedDisplayMode(.fit)
        let fixedAssignment = try XCTUnwrap(fixture.model.displayAssignments["B"])

        fixture.model.advanceRotation()

        XCTAssertEqual(fixture.model.rotationDisplayIDs, ["A"])
        XCTAssertEqual(fixture.model.displayAssignments["B"], fixedAssignment)
        XCTAssertEqual(fixture.player.activeAssignments["B"], fixedAssignment)
        let player = MultiDisplayPlayerSpy()
        let restored = makeModel(store: fixture.store, defaults: fixture.defaults, player: player)

        XCTAssertTrue(restored.rotationEnabled)
        XCTAssertEqual(restored.rotationDisplayIDs, ["A"])
        XCTAssertEqual(restored.displayAssignments["B"], fixedAssignment)
        XCTAssertEqual(player.activeAssignments["B"], fixedAssignment)
        XCTAssertEqual(restored.displayAssignments["A"]?.displayMode, .fit)
        XCTAssertEqual(restored.displayAssignments["A"]?.isPlaying, true)
        XCTAssertEqual(player.playCalls.filter { $0.displayIDs.contains("B") }, [
            .init(assetID: "second", displayIDs: ["B"], mode: .fill)
        ])
        restored.advanceRotation()
        XCTAssertEqual(player.playCalls.last?.displayIDs, ["A"])
        XCTAssertEqual(player.activeAssignments["B"], fixedAssignment)
    }

    func testManualPlaybackOnSecondDisplayRemovesOnlyThatDisplayFromAllDisplayRotation() throws {
        let fixture = try makeFixture()
        startRotation(on: "", assetID: "first", model: fixture.model)
        let firstAssignment = fixture.model.displayAssignments["A"]

        play("third", on: "B", model: fixture.model)

        XCTAssertTrue(fixture.model.rotationEnabled)
        XCTAssertEqual(fixture.model.rotationDisplayIDs, ["A"])
        XCTAssertEqual(fixture.defaults.stringArray(forKey: "rotationDisplayIDs"), ["A"])
        XCTAssertEqual(fixture.model.displayAssignments["A"], firstAssignment)
        XCTAssertEqual(fixture.model.displayAssignments["B"], assignment("third"))
        fixture.model.advanceRotation()
        XCTAssertEqual(fixture.player.playCalls.last?.displayIDs, ["A"])
        XCTAssertEqual(fixture.model.displayAssignments["B"], assignment("third"))
        XCTAssertEqual(fixture.player.activeAssignments["B"], assignment("third"))
    }

    func testStoppingSecondDisplayRemovesOnlyThatDisplayFromAllDisplayRotation() throws {
        let fixture = try makeFixture()
        startRotation(on: "", assetID: "first", model: fixture.model)
        let firstAssignment = fixture.model.displayAssignments["A"]
        fixture.model.selectedDisplayID = "B"

        fixture.model.stopSelectedPlayback()

        XCTAssertTrue(fixture.model.rotationEnabled)
        XCTAssertEqual(fixture.model.rotationDisplayIDs, ["A"])
        XCTAssertEqual(fixture.defaults.stringArray(forKey: "rotationDisplayIDs"), ["A"])
        XCTAssertEqual(fixture.model.displayAssignments["A"], firstAssignment)
        XCTAssertEqual(fixture.model.displayAssignments["B"], assignment("first", playing: false))
        XCTAssertEqual(fixture.player.stopTargets, [["B"]])
        fixture.model.advanceRotation()
        XCTAssertEqual(fixture.player.playCalls.last?.displayIDs, ["A"])
        XCTAssertEqual(fixture.model.displayAssignments["B"]?.isPlaying, false)
        XCTAssertNil(fixture.player.activeAssignments["B"])
    }

    func testChangingSelectionDuringRotationDoesNotMoveItsPlaybackTargets() throws {
        let fixture = try makeFixture()
        startRotation(on: "A", assetID: "first", model: fixture.model)
        let calls = fixture.player.playCalls

        fixture.model.selectedDisplayID = "B"
        XCTAssertEqual(fixture.player.playCalls, calls)
        fixture.model.advanceRotation()
        fixture.model.selectedDisplayID = ""
        fixture.model.advanceRotation()

        XCTAssertEqual(fixture.model.rotationDisplayIDs, ["A"])
        XCTAssertEqual(fixture.player.playCalls.map(\.displayIDs), [["A"], ["A"], ["A"]])
        XCTAssertNil(fixture.model.displayAssignments["B"])
        XCTAssertEqual(fixture.defaults.stringArray(forKey: "rotationDisplayIDs"), ["A"])
    }

    func testRotationKeepsEachDisplaysModeWhenAdvancing() throws {
        let fixture = try makeFixture()
        play("first", on: "A", model: fixture.model)
        fixture.model.applySelectedDisplayMode(.fill)
        play("second", on: "B", model: fixture.model)
        fixture.model.applySelectedDisplayMode(.fit)
        startRotation(on: "", assetID: "first", model: fixture.model)

        fixture.model.advanceRotation()

        XCTAssertEqual(fixture.model.displayAssignments["A"], assignment("second", mode: .fill))
        XCTAssertEqual(fixture.model.displayAssignments["B"], assignment("second", mode: .fit))
        XCTAssertEqual(fixture.player.activeAssignments, [
            "A": assignment("second", mode: .fill), "B": assignment("second", mode: .fit)
        ])
        XCTAssertEqual(try savedAssignments(fixture.defaults), fixture.player.activeAssignments)
    }

    func testStoppedAndDisconnectedAssignmentsSurviveRelaunchWithoutRestartingStoppedDisplay() throws {
        let fixture = try makeFixture()
        play("first", on: "A", model: fixture.model)
        fixture.model.applySelectedDisplayMode(.fill)
        fixture.model.stopSelectedPlayback()
        play("second", on: "B", model: fixture.model)
        fixture.model.applySelectedDisplayMode(.fit)
        let assignments = fixture.model.displayAssignments
        let player = MultiDisplayPlayerSpy()

        let disconnected = makeModel(
            store: fixture.store, defaults: fixture.defaults, player: player,
            displays: [makeDisplay("A")]
        )

        XCTAssertEqual(disconnected.connectedDisplays.map(\.id), ["A"])
        XCTAssertEqual(disconnected.displayAssignments, assignments)
        XCTAssertEqual(try savedAssignments(fixture.defaults), assignments)
        XCTAssertFalse(player.playCalls.contains { $0.displayIDs.contains("A") })
        let reconnectedPlayer = MultiDisplayPlayerSpy()
        let reconnected = makeModel(store: fixture.store, defaults: fixture.defaults, player: reconnectedPlayer)
        XCTAssertEqual(reconnected.displayAssignments, assignments)
        XCTAssertEqual(reconnectedPlayer.playCalls, [
            .init(assetID: "second", displayIDs: ["B"], mode: .fit)
        ])
        XCTAssertNil(reconnectedPlayer.activeAssignments["A"])
    }

    func testStoppingAllPlaybackPersistsStoppedAssignmentsAndPreventsRotationRestore() throws {
        let fixture = try makeFixture()
        startRotation(on: "", assetID: "first", model: fixture.model)
        fixture.model.selectedDisplayID = "B"

        fixture.model.stopPlayback()

        XCTAssertFalse(fixture.model.rotationEnabled)
        XCTAssertEqual(fixture.model.rotationDisplayIDs, [])
        XCTAssertFalse(fixture.defaults.bool(forKey: "rotationEnabled"))
        XCTAssertEqual(fixture.player.globalStopCount, 1)
        XCTAssertEqual(fixture.model.displayAssignments["A"], assignment("first", playing: false))
        XCTAssertEqual(fixture.model.displayAssignments["B"], assignment("first", playing: false))
        let player = MultiDisplayPlayerSpy()
        let restored = makeModel(store: fixture.store, defaults: fixture.defaults, player: player)
        XCTAssertFalse(restored.rotationEnabled)
        XCTAssertEqual(restored.displayAssignments, fixture.model.displayAssignments)
        XCTAssertEqual(player.playCalls, [])
    }

    func testLegacyLastPlayedWallpaperMigratesToConnectedDisplayAssignments() throws {
        let store = try makeStore()
        let defaults = try makeUserDefaults()
        defaults.set("second", forKey: "lastPlayedAssetId")
        defaults.set(WallpaperDisplayMode.fill.rawValue, forKey: "displayMode")
        let player = MultiDisplayPlayerSpy()

        let model = makeModel(store: store, defaults: defaults, player: player)

        XCTAssertEqual(player.activeAssignments, [
            "A": assignment("second", mode: .fill), "B": assignment("second", mode: .fill)
        ])
        XCTAssertEqual(model.displayAssignments, [
            "A": assignment("second", mode: .fill), "B": assignment("second", mode: .fill)
        ])
        XCTAssertEqual(try savedAssignments(defaults), model.displayAssignments)
        XCTAssertFalse(model.rotationEnabled)
        XCTAssertEqual(player.activeAssignments, model.displayAssignments)
    }

    func testLegacyRotationWithoutTargetKeyMigratesOnceToConnectedDisplays() throws {
        let store = try makeStore()
        let defaults = try makeUserDefaults()
        defaults.set(true, forKey: "rotationEnabled")
        defaults.set("third", forKey: "lastPlayedAssetId")
        XCTAssertNil(defaults.object(forKey: "rotationDisplayIDs"))
        let player = MultiDisplayPlayerSpy()

        let model = makeModel(store: store, defaults: defaults, player: player)

        XCTAssertTrue(model.rotationEnabled)
        XCTAssertEqual(model.rotationDisplayIDs, ["A", "B"])
        XCTAssertEqual(defaults.stringArray(forKey: "rotationDisplayIDs"), ["A", "B"])
        XCTAssertEqual(player.activeAssignments, [
            "A": assignment("first"), "B": assignment("first")
        ])
        XCTAssertEqual(model.displayAssignments, player.activeAssignments)
        XCTAssertEqual(try savedAssignments(defaults), player.activeAssignments)
        let restoredPlayer = MultiDisplayPlayerSpy()
        let restored = makeModel(
            store: store, defaults: defaults, player: restoredPlayer,
            displays: [makeDisplay("A"), makeDisplay("B"), makeDisplay("C")]
        )
        XCTAssertEqual(restored.rotationDisplayIDs, ["A", "B"])
        XCTAssertFalse(restoredPlayer.playCalls.contains { $0.displayIDs.contains("C") })
        XCTAssertNil(restored.displayAssignments["C"])
    }

    func testFailedManualPlaybackPreservesAssignmentsAndRotationTargets() throws {
        let fixture = try makeFixture()
        startRotation(on: "", assetID: "first", model: fixture.model)
        let assignments = fixture.model.displayAssignments
        let saved = fixture.defaults.data(forKey: "displayWallpaperAssignments")
        let remembered = fixture.defaults.string(forKey: "lastPlayedAssetId")
        fixture.player.failingAssetIDs = ["third"]

        play("third", on: "B", model: fixture.model)

        XCTAssertEqual(fixture.model.status, "playback failed")
        XCTAssertEqual(fixture.player.playCalls.last, .init(assetID: "third", displayIDs: ["B"], mode: .fit))
        XCTAssertEqual(fixture.model.displayAssignments, assignments)
        XCTAssertEqual(fixture.player.activeAssignments, assignments)
        XCTAssertEqual(fixture.defaults.data(forKey: "displayWallpaperAssignments"), saved)
        XCTAssertEqual(fixture.defaults.string(forKey: "lastPlayedAssetId"), remembered)
        XCTAssertTrue(fixture.model.rotationEnabled)
        XCTAssertTrue(fixture.defaults.bool(forKey: "rotationEnabled"))
        XCTAssertEqual(fixture.model.rotationDisplayIDs, ["A", "B"])
        XCTAssertEqual(fixture.defaults.stringArray(forKey: "rotationDisplayIDs"), ["A", "B"])
        fixture.model.advanceRotation()
        XCTAssertEqual(fixture.player.activeAssignments, [
            "A": assignment("second"), "B": assignment("second")
        ])
        XCTAssertEqual(fixture.model.displayAssignments, fixture.player.activeAssignments)
        XCTAssertEqual(try savedAssignments(fixture.defaults), fixture.player.activeAssignments)
    }

    func testUnassignedDisplaysRememberModesBeforeFirstPlayAndAcrossRelaunch() throws {
        let fixture = try makeFixture()
        fixture.model.selectedDisplayID = "A"
        fixture.model.applySelectedDisplayMode(.fill)
        fixture.model.selectedDisplayID = "B"
        fixture.model.applySelectedDisplayMode(.fit)
        fixture.model.selectedDisplayID = "A"
        XCTAssertEqual(fixture.model.selectedDisplayMode, .fill)
        XCTAssertEqual(fixture.player.playCalls, [])

        let player = MultiDisplayPlayerSpy()
        let restored = makeModel(store: fixture.store, defaults: fixture.defaults, player: player)
        restored.selectedDisplayID = "A"
        XCTAssertEqual(restored.selectedDisplayMode, .fill)
        restored.selectedDisplayID = "B"
        XCTAssertEqual(restored.selectedDisplayMode, .fit)
        XCTAssertEqual(player.playCalls, [], "A saved display mode is not a playback assignment.")
        play("first", on: "A", model: restored)
        XCTAssertEqual(player.activeAssignments["A"], assignment("first", mode: .fill))
    }

    func testRelaunchRestoresGlobalScreenSaverAssetIndependentlyOfDisplayOrder() throws {
        let fixture = try makeFixture()
        let saver = MultiDisplayScreenSaverSpy()
        let model = makeModel(store: fixture.store, defaults: fixture.defaults, player: fixture.player, screenSaver: saver)
        play("second", on: "A", model: model)
        model.lockScreenAnimationEnabled = true
        play("third", on: "B", model: model)
        XCTAssertEqual(saver.updatedAssetIDs.last, "third")
        let restoredSaver = MultiDisplayScreenSaverSpy()

        let restored = makeModel(store: fixture.store, defaults: fixture.defaults,
            player: MultiDisplayPlayerSpy(), displays: [makeDisplay("B"), makeDisplay("A")], screenSaver: restoredSaver)

        XCTAssertEqual(restored.selectedLibraryAssetId, "third")
        XCTAssertEqual(restoredSaver.enabledAssetIDs, ["third"])
        XCTAssertEqual(restored.displayAssignments["A"]?.assetID, "second")
        XCTAssertEqual(restored.displayAssignments["B"]?.assetID, "third")
    }

    func testRotationUpdatesAndRemembersGlobalScreenSaverAsset() throws {
        let fixture = try makeFixture()
        let saver = MultiDisplayScreenSaverSpy()
        let model = makeModel(store: fixture.store, defaults: fixture.defaults, player: fixture.player, screenSaver: saver)
        play("first", on: "A", model: model)
        model.lockScreenAnimationEnabled = true
        startRotation(on: "A", assetID: "first", model: model)

        model.advanceRotation()

        XCTAssertEqual(saver.updatedAssetIDs.last, "second")
        XCTAssertEqual(fixture.defaults.string(forKey: "lastPlayedAssetId"), "second")
        model.handleSceneVideoRenderCompletion(assetId: "first")
        XCTAssertEqual(saver.updatedAssetIDs.last, "second", "A late render must not change the global active wallpaper.")
    }

    private struct Fixture {
        let store: LibraryStore
        let defaults: UserDefaults
        let player: MultiDisplayPlayerSpy
        let model: AppViewModel
    }

    private func makeFixture() throws -> Fixture {
        let store = try makeStore()
        let defaults = try makeUserDefaults()
        let player = MultiDisplayPlayerSpy()
        return Fixture(store: store, defaults: defaults, player: player,
                       model: makeModel(store: store, defaults: defaults, player: player))
    }

    private func makeModel(
        store: LibraryStore, defaults: UserDefaults, player: MultiDisplayPlayerSpy,
        displays: [WallpaperDisplay]? = nil,
        screenSaver: LockScreenAnimationManaging = MultiDisplayScreenSaverSpy()
    ) -> AppViewModel {
        let connected = displays ?? [makeDisplay("A"), makeDisplay("B")]
        let model = AppViewModel(
            store: store,
            loginItemController: MultiDisplayLoginItemStub(),
            lockScreenAnimationController: screenSaver,
            wallpaperPlayer: player,
            userDefaults: defaults,
            displaysProvider: { connected }
        )
        model.stopRotationTimer()
        return model
    }

    private func play(_ assetID: String, on displayID: String, model: AppViewModel) {
        model.selectedDisplayID = displayID
        model.selectedLibraryAssetId = assetID
        model.playSelected()
    }

    private func startRotation(on displayID: String, assetID: String, model: AppViewModel) {
        model.selectedDisplayID = displayID
        model.selectedLibraryAssetId = assetID
        model.rotationEnabled = true
        model.stopRotationTimer()
    }

    private func assignment(
        _ assetID: String, mode: WallpaperDisplayMode = .fit, playing: Bool = true
    ) -> DisplayWallpaperAssignment {
        DisplayWallpaperAssignment(assetID: assetID, displayMode: mode, isPlaying: playing)
    }

    private func savedAssignments(_ defaults: UserDefaults) throws -> [String: DisplayWallpaperAssignment] {
        let data = try XCTUnwrap(defaults.data(forKey: "displayWallpaperAssignments"))
        return try JSONDecoder().decode([String: DisplayWallpaperAssignment].self, from: data)
    }

    private func makeDisplay(_ id: String) -> WallpaperDisplay {
        WallpaperDisplay(
            id: id, name: "Display \(id)",
            frame: CGRect(x: id == "A" ? 0 : 1920, y: 0, width: 1920, height: 1080),
            scale: 1, isPrimary: id == "A"
        )
    }

    private func makeStore() throws -> LibraryStore {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root)
        for id in ["first", "second", "third"] {
            let directory = root.appending(path: id)
            try store.replaceAsset(WallpaperAsset(
                id: id, title: "Asset \(id)", kind: .video, supportStatus: .playable,
                source: .localSteamWorkshop, projectDirectory: directory.path,
                entrypoint: directory.appending(path: "loop.mp4").path,
                thumbnail: nil, workshopId: id, redistributionAllowed: false, issues: []
            ))
        }
        return store
    }

    private func makeUserDefaults() throws -> UserDefaults {
        let suiteName = "MultiDisplayAppViewModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: "automaticallyCheckForUpdates")
        defaults.set(false, forKey: "rotationShuffle")
        return defaults
    }
}

@MainActor
private final class MultiDisplayLoginItemStub: LoginItemManaging {
    var isEnabled = false
    func setEnabled(_ enabled: Bool) throws { isEnabled = enabled }
    func openSystemSettings() {}
}

@MainActor
private final class MultiDisplayPlayerSpy: WallpaperPlaying {
    struct PlayCall: Equatable {
        let assetID: String
        let displayIDs: Set<String>
        let mode: WallpaperDisplayMode
    }

    struct ModeCall: Equatable {
        let mode: WallpaperDisplayMode
        let displayIDs: Set<String>
    }

    var failingAssetIDs: Set<String> = []
    private(set) var playCalls: [PlayCall] = []
    private(set) var stopTargets: [Set<String>] = []
    private(set) var modeCalls: [ModeCall] = []
    private(set) var activeAssignments: [String: DisplayWallpaperAssignment] = [:]
    private(set) var globalStopCount = 0

    func play(
        asset: WallpaperAsset, on displayIDs: Set<String>, autoPauseWhenCovered: Bool,
        displayMode: WallpaperDisplayMode, audioEnabled: Bool?, audioVolume: Double?
    ) throws {
        playCalls.append(.init(assetID: asset.id, displayIDs: displayIDs, mode: displayMode))
        if failingAssetIDs.contains(asset.id) { throw MultiDisplayPlaybackError.failure }
        for id in displayIDs {
            activeAssignments[id] = DisplayWallpaperAssignment(
                assetID: asset.id, displayMode: displayMode, isPlaying: true
            )
        }
    }

    func play(
        asset: WallpaperAsset, autoPauseWhenCovered: Bool,
        displayMode: WallpaperDisplayMode, audioEnabled: Bool?, audioVolume: Double?
    ) throws {
        XCTFail("Playback must specify its target displays")
    }

    func stop(on displayIDs: Set<String>) {
        stopTargets.append(displayIDs)
        for id in displayIDs { activeAssignments.removeValue(forKey: id) }
    }

    func stop() {
        globalStopCount += 1
        activeAssignments.removeAll()
    }

    func setDisplayMode(_ mode: WallpaperDisplayMode, on displayIDs: Set<String>) {
        modeCalls.append(.init(mode: mode, displayIDs: displayIDs))
        for id in displayIDs { activeAssignments[id]?.displayMode = mode }
    }

    func setDisplayMode(_ mode: WallpaperDisplayMode) {
        XCTFail("Display mode changes must specify their target displays")
    }

    func setAutoPauseWhenCovered(_ enabled: Bool) {}
}

@MainActor
private final class MultiDisplayScreenSaverSpy: LockScreenAnimationManaging {
    var enabledAssetIDs: [String?] = []
    var updatedAssetIDs: [String?] = []
    func setEnabled(_ enabled: Bool, activeAsset: WallpaperAsset?, displayMode: WallpaperDisplayMode) throws {
        if enabled { enabledAssetIDs.append(activeAsset?.id) }
    }
    func updateActiveAsset(_ asset: WallpaperAsset?, displayMode: WallpaperDisplayMode) throws {
        updatedAssetIDs.append(asset?.id)
    }
    func openScreenSaverSettings() throws {}
}

private enum MultiDisplayPlaybackError: LocalizedError {
    case failure
    var errorDescription: String? { "playback failed" }
}
