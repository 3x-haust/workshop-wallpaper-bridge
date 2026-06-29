import Foundation
import XCTest
@testable import WorkshopWallpaperBridgeApp
import WorkshopWallpaperCore

@MainActor
final class AppViewModelRotationTests: XCTestCase {
    // MARK: Rotation target filtering

    func testPlayableLibraryAssetsExcludesNonPlayableItems() throws {
        // Given
        let model = makeModel(defaults: try makeUserDefaults())
        model.libraryAssets = [
            makeAsset(id: "a", status: .playable),
            makeAsset(id: "b", status: .needsConversion),
            makeAsset(id: "c", status: .unsupported),
            makeAsset(id: "d", status: .playable)
        ]

        // Then
        XCTAssertEqual(model.playableLibraryAssets.map(\.id), ["a", "d"])
    }

    // MARK: Settings persistence

    func testRotationShufflePersistsWhenToggled() throws {
        // Given
        let defaults = try makeUserDefaults()
        let model = makeModel(defaults: defaults)

        // When
        model.rotationShuffle = true

        // Then
        XCTAssertTrue(defaults.bool(forKey: "rotationShuffle"))
    }

    func testRotationIntervalPersistsWhenChanged() throws {
        // Given
        let defaults = try makeUserDefaults()
        let model = makeModel(defaults: defaults)

        // When
        model.rotationInterval = 1800

        // Then
        XCTAssertEqual(defaults.double(forKey: "rotationInterval"), 1800)
    }

    func testInitRestoresShuffleAndIntervalPreferences() throws {
        // Given
        let defaults = try makeUserDefaults()
        defaults.set(true, forKey: "rotationShuffle")
        defaults.set(900, forKey: "rotationInterval")

        // When
        let model = makeModel(defaults: defaults)

        // Then
        XCTAssertTrue(model.rotationShuffle)
        XCTAssertEqual(model.rotationInterval, 900)
    }

    // MARK: Restore separation (settings restore vs. playback resume)

    func testRestoringRotationWithoutPlayableAssetsDoesNotEnable() throws {
        // Given a persisted "rotation on" state but an empty library.
        let defaults = try makeUserDefaults()
        defaults.set(true, forKey: "rotationEnabled")

        // When the model loads (empty store, no playable assets).
        let model = makeModel(defaults: defaults)

        // Then rotation does not resume and the stale "enabled" flag is cleared.
        XCTAssertFalse(model.rotationEnabled)
        XCTAssertFalse(defaults.bool(forKey: "rotationEnabled"))
    }

    // MARK: Empty / non-playable library safety

    func testEnablingRotationWithoutPlayableAssetsTurnsItselfOff() throws {
        // Given a library that has only non-playable items.
        let defaults = try makeUserDefaults()
        let model = makeModel(defaults: defaults)
        model.libraryAssets = [makeAsset(id: "x", status: .needsConversion)]

        // When the user turns rotation on.
        model.rotationEnabled = true

        // Then it turns itself back off, clears the preference, and explains why.
        XCTAssertFalse(model.rotationEnabled)
        XCTAssertFalse(defaults.bool(forKey: "rotationEnabled"))
        XCTAssertEqual(
            model.status,
            "Import or add a playable wallpaper before starting rotation."
        )
    }

    // MARK: Helpers

    private func makeModel(defaults: UserDefaults) -> AppViewModel {
        AppViewModel(
            store: makeStore(),
            loginItemController: MockLoginItemController(),
            userDefaults: defaults
        )
    }

    private func makeStore() -> LibraryStore {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return LibraryStore(root: root)
    }

    private func makeUserDefaults() throws -> UserDefaults {
        let suiteName = "WorkshopWallpaperBridgeRotationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    private func makeAsset(id: String, status: SupportStatus) -> WallpaperAsset {
        WallpaperAsset(
            id: id,
            title: "Asset \(id)",
            kind: .video,
            supportStatus: status,
            source: .localSteamWorkshop,
            projectDirectory: "/tmp/\(id)",
            entrypoint: "/tmp/\(id)/loop.mp4",
            thumbnail: nil,
            workshopId: id,
            redistributionAllowed: false,
            issues: []
        )
    }
}

@MainActor
private final class MockLoginItemController: LoginItemManaging {
    var isEnabled = false

    func setEnabled(_ enabled: Bool) throws {
        isEnabled = enabled
    }

    func openSystemSettings() {}
}
