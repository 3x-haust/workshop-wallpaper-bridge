import Foundation
import XCTest
@testable import WorkshopWallpaperBridgeApp
import WorkshopWallpaperCore

@MainActor
final class AppViewModelTests: XCTestCase {
    func testScanSourceReturnsImmediatelyWhileBackgroundScanRuns() async throws {
        // Given
        let scanned = ScanResult(root: "/slow", generatedAt: Date(), assets: [])
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            userDefaults: try makeUserDefaults(),
            operations: AppViewModelOperations(
                scan: { _ in
                    Thread.sleep(forTimeInterval: 0.15)
                    return scanned
                }
            )
        )
        model.sourcePath = "/slow"

        // When
        model.scanSource()

        // Then
        XCTAssertTrue(model.isWorking)
        XCTAssertEqual(model.status, "Scanning /slow...")
        await waitForWorkToFinish(model)
        XCTAssertTrue(model.scannedAssets.isEmpty)
        XCTAssertEqual(model.status, "Found 0 project(s).")
    }

    func testImportSelectedImportsMultipleScannedAssets() async throws {
        // Given
        let sourceRoot = try makeTempDirectory()
        let first = try makeScannedProject(root: sourceRoot, id: "first", title: "First Loop")
        let second = try makeScannedProject(root: sourceRoot, id: "second", title: "Second Loop")
        let store = LibraryStore(root: try makeTempDirectory())
        let model = AppViewModel(
            store: store,
            loginItemController: MockLoginItemController(),
            userDefaults: try makeUserDefaults()
        )
        model.scannedAssets = [first, second]
        model.selectScannedAssets([first.id, second.id])

        // When
        model.importSelected()
        await waitForWorkToFinish(model)
        let manifest = try store.load()

        // Then
        XCTAssertEqual(Set(manifest.assets.map(\.id)), [first.id, second.id])
        XCTAssertEqual(model.selectedLibraryAssetIds, [first.id, second.id])
        XCTAssertEqual(model.status, "Imported 2 projects.")
        for asset in manifest.assets {
            XCTAssertTrue(FileManager.default.fileExists(atPath: asset.projectDirectory))
            XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(asset.entrypoint)))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.projectDirectory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.projectDirectory))
    }

    func testSelectScannedAssetsIgnoresMissingIds() throws {
        // Given
        let sourceRoot = try makeTempDirectory()
        let asset = try makeScannedProject(root: sourceRoot, id: "one", title: "One")
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            userDefaults: try makeUserDefaults()
        )
        model.scannedAssets = [asset]

        // When
        model.selectScannedAssets([asset.id, "missing"])

        // Then
        XCTAssertEqual(model.selectedScannedAssetIds, [asset.id])
        XCTAssertEqual(model.selectedScannedAssetId, asset.id)
    }

    func testInitSelectsFirstLibraryAssetWhenAvailable() throws {
        // Given
        let sourceRoot = try makeTempDirectory()
        let video = sourceRoot.appending(path: "clip.mp4")
        FileManager.default.createFile(atPath: video.path, contents: Data([1]))
        let store = LibraryStore(root: try makeTempDirectory())
        let imported = try store.importVideoFile(video)

        // When
        let model = AppViewModel(
            store: store,
            loginItemController: MockLoginItemController(),
            userDefaults: try makeUserDefaults()
        )

        // Then
        XCTAssertEqual(model.selectedLibraryAssetId, imported.id)
        XCTAssertEqual(model.selectedLibraryAsset, imported)
    }

    func testRemoveSelectedLibraryAssetDeletesImportedCopy() async throws {
        // Given
        let sourceRoot = try makeTempDirectory()
        let video = sourceRoot.appending(path: "clip.mp4")
        FileManager.default.createFile(atPath: video.path, contents: Data([1]))
        let store = LibraryStore(root: try makeTempDirectory())
        let imported = try store.importVideoFile(video)
        let model = AppViewModel(
            store: store,
            loginItemController: MockLoginItemController(),
            userDefaults: try makeUserDefaults()
        )
        model.selectedLibraryAssetId = imported.id

        // When
        model.removeSelectedLibraryAsset()
        await waitForWorkToFinish(model)
        let manifest = try store.load()

        // Then
        XCTAssertTrue(model.libraryAssets.isEmpty)
        XCTAssertNil(model.selectedLibraryAssetId)
        XCTAssertTrue(manifest.assets.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.projectDirectory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.path))
    }

    func testRemoveSelectedLibraryAssetsDeletesMultipleImportedCopies() async throws {
        // Given
        let sourceRoot = try makeTempDirectory()
        let firstVideo = sourceRoot.appending(path: "first.mp4")
        let secondVideo = sourceRoot.appending(path: "second.mp4")
        FileManager.default.createFile(atPath: firstVideo.path, contents: Data([1]))
        FileManager.default.createFile(atPath: secondVideo.path, contents: Data([2]))
        let store = LibraryStore(root: try makeTempDirectory())
        let first = try store.importVideoFile(firstVideo)
        let second = try store.importVideoFile(secondVideo)
        let model = AppViewModel(
            store: store,
            loginItemController: MockLoginItemController(),
            userDefaults: try makeUserDefaults()
        )
        model.selectLibraryAssets([first.id, second.id])

        // When
        model.removeSelectedLibraryAssets()
        await waitForWorkToFinish(model)
        let manifest = try store.load()

        // Then
        XCTAssertTrue(model.libraryAssets.isEmpty)
        XCTAssertTrue(model.selectedLibraryAssetIds.isEmpty)
        XCTAssertTrue(manifest.assets.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.projectDirectory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.projectDirectory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstVideo.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondVideo.path))
    }

    func testLaunchAtLoginToggleRegistersLoginItem() throws {
        // Given
        let loginItems = MockLoginItemController()
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: loginItems,
            userDefaults: try makeUserDefaults()
        )

        // When
        model.launchAtLogin = true

        // Then
        XCTAssertTrue(loginItems.isEnabled)
        XCTAssertEqual(loginItems.requestedValues, [true])
        XCTAssertEqual(model.status, "Workshop Wallpaper Bridge will open at login.")
    }

    func testLaunchAtLoginToggleRevertsWhenControllerThrows() throws {
        // Given
        let loginItems = MockLoginItemController()
        loginItems.error = TestError.expected
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: loginItems,
            userDefaults: try makeUserDefaults()
        )

        // When
        model.launchAtLogin = true

        // Then
        XCTAssertFalse(model.launchAtLogin)
        XCTAssertFalse(loginItems.isEnabled)
        XCTAssertEqual(loginItems.requestedValues, [true])
        XCTAssertTrue(model.status.contains("Open at login could not be changed"))
    }

    func testInitRestoresDisplayPreferences() throws {
        // Given
        let defaults = try makeUserDefaults()
        defaults.set("fill", forKey: "displayMode")
        defaults.set(false, forKey: "autoPauseWhenCovered")

        // When
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            userDefaults: defaults
        )

        // Then
        XCTAssertEqual(model.displayMode, .fill)
        XCTAssertFalse(model.autoPauseWhenCovered)
    }

    func testInitRestoresLockScreenAnimationPreferenceWithoutInstalling() throws {
        // Given
        let defaults = try makeUserDefaults()
        defaults.set(true, forKey: "lockScreenAnimationEnabled")
        let lockScreen = MockLockScreenAnimationController()

        // When
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            lockScreenAnimationController: lockScreen,
            userDefaults: defaults
        )

        // Then
        XCTAssertTrue(model.lockScreenAnimationEnabled)
        XCTAssertEqual(lockScreen.enabledRequests, [true])
    }

    func testLockScreenAnimationToggleInstallsScreenSaverAndPersistsPreference() throws {
        // Given
        let defaults = try makeUserDefaults()
        let lockScreen = MockLockScreenAnimationController()
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            lockScreenAnimationController: lockScreen,
            userDefaults: defaults
        )

        // When
        model.lockScreenAnimationEnabled = true

        // Then
        XCTAssertEqual(lockScreen.enabledRequests, [true])
        XCTAssertTrue(defaults.bool(forKey: "lockScreenAnimationEnabled"))
        XCTAssertTrue(model.status.contains("Installed the Lock Screen screen saver"))
    }

    func testStopPlaybackClearsLastPlayedWallpaperPreference() throws {
        // Given
        let defaults = try makeUserDefaults()
        defaults.set("last-wallpaper", forKey: "lastPlayedAssetId")
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            userDefaults: defaults
        )

        // When
        model.stopPlayback()

        // Then
        XCTAssertNil(defaults.string(forKey: "lastPlayedAssetId"))
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func makeUserDefaults() throws -> UserDefaults {
        let suiteName = "WorkshopWallpaperBridgeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    private func waitForWorkToFinish(
        _ model: AppViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if !model.isWorking {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for background work to finish.", file: file, line: line)
    }

    private func makeScannedProject(root: URL, id: String, title: String) throws -> WallpaperAsset {
        let project = root.appending(path: id)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let entrypoint = project.appending(path: "loop.mp4")
        try Data([1]).write(to: entrypoint)
        return WallpaperAsset(
            id: id,
            title: title,
            kind: .video,
            supportStatus: .playable,
            source: .localSteamWorkshop,
            projectDirectory: project.path,
            entrypoint: entrypoint.path,
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
    var requestedValues: [Bool] = []
    var error: Error?

    func setEnabled(_ enabled: Bool) throws {
        requestedValues.append(enabled)
        if let error {
            throw error
        }
        isEnabled = enabled
    }

    func openSystemSettings() {}
}

@MainActor
private final class MockLockScreenAnimationController: LockScreenAnimationManaging {
    var enabledRequests: [Bool] = []
    var updatedAssetIds: [String?] = []
    var didOpenSettings = false
    var error: Error?

    func setEnabled(_ enabled: Bool, activeAsset: WallpaperAsset?, displayMode: WallpaperDisplayMode) throws {
        if let error {
            throw error
        }
        enabledRequests.append(enabled)
        updatedAssetIds.append(activeAsset?.id)
    }

    func updateActiveAsset(_ asset: WallpaperAsset?, displayMode: WallpaperDisplayMode) throws {
        if let error {
            throw error
        }
        updatedAssetIds.append(asset?.id)
    }

    func openScreenSaverSettings() {
        didOpenSettings = true
    }
}

private enum TestError: Error {
    case expected
}
