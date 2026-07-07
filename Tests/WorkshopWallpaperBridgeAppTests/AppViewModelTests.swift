import Foundation
import XCTest
@testable import WorkshopWallpaperBridgeApp
import WorkshopWallpaperCore

@MainActor
final class AppViewModelTests: XCTestCase {
    func testImportSelectedImportsMultipleScannedAssets() throws {
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

    func testSceneVideoRenderCompletionBumpsRevisionSoLibraryRowsRefresh() throws {
        // Given
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            userDefaults: try makeUserDefaults()
        )
        let sceneRoot = try makeTempDirectory()
        let entrypoint = sceneRoot.appending(path: "scene.pkg")
        try Data([1]).write(to: entrypoint)
        let scene = WallpaperAsset(
            id: "scene-1",
            title: "Scene",
            kind: .scene,
            supportStatus: .playable,
            source: .localSteamWorkshop,
            projectDirectory: sceneRoot.path,
            entrypoint: entrypoint.path,
            thumbnail: nil,
            workshopId: nil,
            redistributionAllowed: false,
            issues: []
        )
        model.libraryAssets = [scene]

        // Then (before any render, the row shows the "renders on first play"
        // badge because there's no cached video yet)
        XCTAssertEqual(LibraryRowStatusResolver.status(for: scene), .needsFirstRender)
        let revisionBeforeRender = model.sceneVideoRenderRevision

        // When a render completes and lands a fresh cache entry
        let previousCacheDirectory = SceneVideoCache.overrideCacheDirectoryURL
        let cacheDirectory = sceneRoot.appending(path: "SceneVideoCache")
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try Data([1]).write(to: cacheDirectory.appending(path: "\(scene.id).mp4"))
        SceneVideoCache.overrideCacheDirectoryURL = cacheDirectory
        addTeardownBlock {
            SceneVideoCache.overrideCacheDirectoryURL = previousCacheDirectory
        }
        model.handleSceneVideoRenderCompletion(assetId: scene.id)

        // Then
        XCTAssertEqual(model.sceneVideoRenderRevision, revisionBeforeRender + 1)
        XCTAssertEqual(LibraryRowStatusResolver.status(for: scene), .playable)
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

    func testRemoveSelectedLibraryAssetDeletesImportedCopy() throws {
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
        let manifest = try store.load()

        // Then
        XCTAssertTrue(model.libraryAssets.isEmpty)
        XCTAssertNil(model.selectedLibraryAssetId)
        XCTAssertTrue(manifest.assets.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.projectDirectory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.path))
    }

    func testRemoveSelectedLibraryAssetsDeletesMultipleImportedCopies() throws {
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

    func testRequestRemoveSelectedLibraryAssetsSetsPendingConfirmationWithoutDeleting() throws {
        // Given
        let sourceRoot = try makeTempDirectory()
        let video = sourceRoot.appending(path: "keep-until-confirmed.mp4")
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
        model.requestRemoveSelectedLibraryAssets()

        // Then
        XCTAssertEqual(model.pendingLibraryRemoval?.assetIds, [imported.id])
        XCTAssertEqual(model.pendingLibraryRemoval?.title, imported.title)
        XCTAssertFalse(model.libraryAssets.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.projectDirectory))
    }

    func testCancelPendingLibraryRemovalClearsConfirmationWithoutDeleting() throws {
        // Given
        let sourceRoot = try makeTempDirectory()
        let video = sourceRoot.appending(path: "cancel-me.mp4")
        FileManager.default.createFile(atPath: video.path, contents: Data([1]))
        let store = LibraryStore(root: try makeTempDirectory())
        let imported = try store.importVideoFile(video)
        let model = AppViewModel(
            store: store,
            loginItemController: MockLoginItemController(),
            userDefaults: try makeUserDefaults()
        )
        model.selectedLibraryAssetId = imported.id
        model.requestRemoveSelectedLibraryAssets()

        // When
        model.cancelPendingLibraryRemoval()

        // Then
        XCTAssertNil(model.pendingLibraryRemoval)
        XCTAssertFalse(model.libraryAssets.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.projectDirectory))
    }

    func testRequestRemoveSelectedLibraryAssetsWithNoSelectionReportsStatus() throws {
        // Given
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            userDefaults: try makeUserDefaults()
        )

        // When
        model.requestRemoveSelectedLibraryAssets()

        // Then
        XCTAssertNil(model.pendingLibraryRemoval)
        XCTAssertEqual(model.status, "Select a library project first.")
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

    func testSceneAssetsFolderPersistsAndFeedsRendererResolution() throws {
        // Given
        let defaults = try makeUserDefaults()
        let root = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let assetsDirectory = try makeSceneEngineAssetsFixture(in: root.appending(path: "source"))
        let appSupportAssetsDirectory = root.appending(path: "app-support-assets")
        let previousDefaultAssetsDirectory = SceneEngineRendererConfiguration.overrideDefaultAssetsDirectoryURL
        SceneEngineRendererConfiguration.overrideDefaultAssetsDirectoryURL = appSupportAssetsDirectory
        defer {
            SceneEngineRendererConfiguration.overrideDefaultAssetsDirectoryURL = previousDefaultAssetsDirectory
        }
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            userDefaults: defaults
        )

        // When
        model.setSceneAssetsFolder(assetsDirectory)

        // Then
        XCTAssertEqual(model.sceneAssetsDirectory, appSupportAssetsDirectory.path)
        XCTAssertEqual(defaults.string(forKey: "sceneEngineAssetsDirectory"), appSupportAssetsDirectory.path)
        XCTAssertEqual(SceneEngineRendererConfiguration.assetsDirectoryURL(environment: [:])?.path, appSupportAssetsDirectory.path)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: appSupportAssetsDirectory.appending(path: "materials/util/composelayer.json").path
        ))
        XCTAssertTrue(model.sceneAssetsStatus.contains("ready"))
    }

    func testInvalidSceneAssetsFolderIsRejectedWithoutChangingPersistedValue() throws {
        // Given
        let defaults = try makeUserDefaults()
        let root = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let validAssetsDirectory = try makeSceneEngineAssetsFixture(in: root.appending(path: "stored"))
        let invalidDirectory = root.appending(path: "invalid")
        try FileManager.default.createDirectory(at: invalidDirectory, withIntermediateDirectories: true)
        let appSupportAssetsDirectory = root.appending(path: "app-support-assets")
        defaults.set(validAssetsDirectory.path, forKey: "sceneEngineAssetsDirectory")
        let previousDefaultAssetsDirectory = SceneEngineRendererConfiguration.overrideDefaultAssetsDirectoryURL
        SceneEngineRendererConfiguration.overrideDefaultAssetsDirectoryURL = appSupportAssetsDirectory
        defer {
            SceneEngineRendererConfiguration.overrideDefaultAssetsDirectoryURL = previousDefaultAssetsDirectory
        }
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            userDefaults: defaults
        )

        // When
        model.setSceneAssetsFolder(invalidDirectory)

        // Then
        XCTAssertEqual(model.sceneAssetsDirectory, appSupportAssetsDirectory.path)
        XCTAssertEqual(defaults.string(forKey: "sceneEngineAssetsDirectory"), appSupportAssetsDirectory.path)
        XCTAssertEqual(SceneEngineRendererConfiguration.assetsDirectoryURL(environment: [:])?.path, appSupportAssetsDirectory.path)
        XCTAssertTrue(model.status.contains("does not look like a Wallpaper Engine assets folder"))
        XCTAssertTrue(model.status.contains("materials/"))
        XCTAssertTrue(model.status.contains("shaders/"))
    }

    func testStoredSceneAssetsFolderMigratesToDefaultAppSupportLocation() throws {
        // Given
        let defaults = try makeUserDefaults()
        let root = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let storedAssetsDirectory = try makeSceneEngineAssetsFixture(in: root.appending(path: "stored"))
        let appSupportAssetsDirectory = root.appending(path: "app-support-assets")
        defaults.set(storedAssetsDirectory.path, forKey: "sceneEngineAssetsDirectory")
        let previousDefaultAssetsDirectory = SceneEngineRendererConfiguration.overrideDefaultAssetsDirectoryURL
        SceneEngineRendererConfiguration.overrideDefaultAssetsDirectoryURL = appSupportAssetsDirectory
        defer {
            SceneEngineRendererConfiguration.overrideDefaultAssetsDirectoryURL = previousDefaultAssetsDirectory
        }

        // When
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            userDefaults: defaults
        )

        // Then
        XCTAssertEqual(model.sceneAssetsDirectory, appSupportAssetsDirectory.path)
        XCTAssertEqual(defaults.string(forKey: "sceneEngineAssetsDirectory"), appSupportAssetsDirectory.path)
        XCTAssertEqual(SceneEngineRendererConfiguration.assetsDirectoryURL(environment: [:])?.path, appSupportAssetsDirectory.path)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: appSupportAssetsDirectory.appending(path: "materials/util/composelayer.json").path
        ))
    }

    func testSceneAssetsFolderCanBeClearedToDefaultResolution() throws {
        // Given
        let defaults = try makeUserDefaults()
        let root = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let assetsDirectory = try makeSceneEngineAssetsFixture(in: root.appending(path: "stored"))
        let appSupportAssetsDirectory = root.appending(path: "app-support-assets")
        defaults.set(assetsDirectory.path, forKey: "sceneEngineAssetsDirectory")
        let previousDefaultAssetsDirectory = SceneEngineRendererConfiguration.overrideDefaultAssetsDirectoryURL
        SceneEngineRendererConfiguration.overrideDefaultAssetsDirectoryURL = appSupportAssetsDirectory
        defer {
            SceneEngineRendererConfiguration.overrideDefaultAssetsDirectoryURL = previousDefaultAssetsDirectory
        }
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            userDefaults: defaults
        )

        // When
        model.clearSceneAssetsFolder()

        // Then
        XCTAssertEqual(model.sceneAssetsDirectory, "")
        XCTAssertNil(defaults.string(forKey: "sceneEngineAssetsDirectory"))
        XCTAssertNil(SceneEngineRendererConfiguration.overrideAssetsPath)
        XCTAssertTrue(model.sceneAssetsStatus.contains("Not set"))
    }

    func testSceneAssetsEnvironmentOverrideWinsOverUserPreference() throws {
        // Given
        let defaults = try makeUserDefaults()
        let root = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let userAssetsDirectory = try makeSceneEngineAssetsFixture(in: root.appending(path: "stored"))
        let envAssetsDirectory = try makeSceneEngineAssetsFixture(in: root.appending(path: "env"))
        let appSupportAssetsDirectory = root.appending(path: "app-support-assets")
        defaults.set(userAssetsDirectory.path, forKey: "sceneEngineAssetsDirectory")
        let previousDefaultAssetsDirectory = SceneEngineRendererConfiguration.overrideDefaultAssetsDirectoryURL
        SceneEngineRendererConfiguration.overrideDefaultAssetsDirectoryURL = appSupportAssetsDirectory
        defer {
            SceneEngineRendererConfiguration.overrideDefaultAssetsDirectoryURL = previousDefaultAssetsDirectory
        }
        _ = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            userDefaults: defaults
        )

        // When
        let resolved = SceneEngineRendererConfiguration.assetsDirectoryURL(
            environment: [
                SceneEngineRendererConfiguration.assetsEnvironmentVariableName: envAssetsDirectory.path
            ]
        )

        // Then
        XCTAssertEqual(resolved?.path, envAssetsDirectory.path)
    }

    func testInitDefaultsToContinuousPlayback() throws {
        // Given
        let defaults = try makeUserDefaults()

        // When
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            userDefaults: defaults
        )

        // Then
        XCTAssertFalse(model.autoPauseWhenCovered)
    }

    func testInitDefaultsToDisabledWallpaperAudioAtHalfVolume() throws {
        // Given
        let defaults = try makeUserDefaults()

        // When
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            userDefaults: defaults
        )

        // Then: audio defaults off so existing users aren't surprised by
        // wallpapers suddenly making sound.
        XCTAssertFalse(model.wallpaperAudioEnabled)
        XCTAssertEqual(model.wallpaperAudioVolume, 0.5, accuracy: 0.0001)
    }

    func testWallpaperAudioPreferencesPersistAcrossRestarts() throws {
        // Given
        let defaults = try makeUserDefaults()
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            userDefaults: defaults
        )

        // When
        model.wallpaperAudioEnabled = true
        model.wallpaperAudioVolume = 0.85

        // Then
        XCTAssertTrue(defaults.bool(forKey: "wallpaperAudioEnabled"))
        XCTAssertEqual(defaults.double(forKey: "wallpaperAudioVolume"), 0.85, accuracy: 0.0001)

        // And: a freshly constructed view model restores them.
        let restored = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            userDefaults: defaults
        )
        XCTAssertTrue(restored.wallpaperAudioEnabled)
        XCTAssertEqual(restored.wallpaperAudioVolume, 0.85, accuracy: 0.0001)
    }

    func testLanguagePreferencePersistsAcrossRestarts() throws {
        // Given
        let defaults = try makeUserDefaults()
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            userDefaults: defaults
        )
        XCTAssertEqual(model.language, .system)

        // When
        model.language = .korean

        // Then
        XCTAssertEqual(defaults.string(forKey: "language"), "ko")

        // And: a freshly constructed view model restores it.
        let restored = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            userDefaults: defaults
        )
        XCTAssertEqual(restored.language, .korean)
    }

    func testLocalizedStringResolvesDifferentlyByLanguage() throws {
        // Given
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            userDefaults: try makeUserDefaults()
        )

        // When
        model.language = .english
        let english = model.L("tab.library")
        model.language = .korean
        let korean = model.L("tab.library")

        // Then
        XCTAssertEqual(english, "Library")
        XCTAssertEqual(korean, "라이브러리")
        XCTAssertNotEqual(english, korean)
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
        XCTAssertTrue(model.status.contains("Installed and selected"))
    }

    func testInitRestoresAutomaticUpdatePreference() throws {
        // Given
        let defaults = try makeUserDefaults()
        defaults.set(false, forKey: "automaticallyCheckForUpdates")

        // When
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            userDefaults: defaults
        )

        // Then
        XCTAssertFalse(model.automaticallyCheckForUpdates)
    }

    func testManualUpdateCheckReportsAvailableUpdate() async throws {
        // Given
        let update = UpdateRelease(
            version: "1.2.0",
            tagName: "v1.2.0",
            releaseURL: URL(string: "https://example.com/release")!,
            downloadURL: URL(string: "https://example.com/app.dmg")!
        )
        let checker = MockUpdateChecker(result: .updateAvailable(update))
        let opener = MockUpdateURLOpener()
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            updateChecker: checker,
            updateURLOpener: opener,
            currentVersionProvider: { "1.1.0" },
            userDefaults: try makeUserDefaults()
        )

        // When
        await model.checkForUpdatesNow()
        model.openAvailableUpdate()

        // Then
        XCTAssertEqual(checker.requestedVersions, ["1.1.0"])
        XCTAssertEqual(model.availableUpdate, update)
        XCTAssertEqual(model.updateAlert?.title, "Update Available")
        XCTAssertEqual(
            model.updateAlert?.message,
            "Workshop Wallpaper Bridge 1.2.0 is available. Click Download Update to download the latest DMG."
        )
        XCTAssertEqual(opener.openedURLs, [try XCTUnwrap(update.downloadURL)])
        XCTAssertEqual(model.status, "Opened Workshop Wallpaper Bridge 1.2.0 update.")
    }

    func testManualUpdateCheckReportsUpToDateAndClearsAvailableUpdate() async throws {
        // Given
        let checker = MockUpdateChecker(result: .upToDate(currentVersion: "1.1.0", latestVersion: "1.1.0"))
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            updateChecker: checker,
            currentVersionProvider: { "1.1.0" },
            userDefaults: try makeUserDefaults()
        )

        // When
        await model.checkForUpdatesNow()

        // Then
        XCTAssertNil(model.availableUpdate)
        XCTAssertEqual(model.status, "Workshop Wallpaper Bridge is up to date (1.1.0).")
        XCTAssertEqual(model.updateAlert?.title, "Already Up to Date")
        XCTAssertEqual(
            model.updateAlert?.message,
            "Workshop Wallpaper Bridge 1.1.0 is already the latest version."
        )
    }

    func testManualUpdateCheckReportsFailureInAlert() async throws {
        // Given
        let checker = MockUpdateChecker(error: LocalizedTestError.expected)
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            updateChecker: checker,
            currentVersionProvider: { "1.1.0" },
            userDefaults: try makeUserDefaults()
        )

        // When
        await model.checkForUpdatesNow()

        // Then
        XCTAssertEqual(model.status, "Update check failed: Expected update error.")
        XCTAssertEqual(model.updateAlert?.title, "Update Check Failed")
        XCTAssertEqual(model.updateAlert?.message, "Expected update error.")
    }

    func testAutomaticUpdateCheckHonorsPreferenceAndInterval() async throws {
        // Given
        let defaults = try makeUserDefaults()
        let now = Date(timeIntervalSince1970: 100)
        defaults.set(now, forKey: "lastUpdateCheckAt")
        let checker = MockUpdateChecker(
            result: .upToDate(currentVersion: "1.1.0", latestVersion: "1.1.0")
        )
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            updateChecker: checker,
            currentVersionProvider: { "1.1.0" },
            userDefaults: defaults
        )

        // When
        await model.performAutomaticUpdateCheckIfNeeded(now: now.addingTimeInterval(60))
        await model.performAutomaticUpdateCheckIfNeeded(force: true, now: now.addingTimeInterval(60))

        // Then
        XCTAssertEqual(checker.requestedVersions, ["1.1.0"])
    }

    func testAutomaticUpdateCheckCanBeDisabled() async throws {
        // Given
        let defaults = try makeUserDefaults()
        defaults.set(false, forKey: "automaticallyCheckForUpdates")
        let checker = MockUpdateChecker(
            result: .upToDate(currentVersion: "1.1.0", latestVersion: "1.1.0")
        )
        let model = AppViewModel(
            store: LibraryStore(root: try makeTempDirectory()),
            loginItemController: MockLoginItemController(),
            updateChecker: checker,
            currentVersionProvider: { "1.1.0" },
            userDefaults: defaults
        )

        // When
        await model.performAutomaticUpdateCheckIfNeeded(force: true)

        // Then
        XCTAssertTrue(checker.requestedVersions.isEmpty)
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

    private func makeSceneEngineAssetsFixture(in root: URL) throws -> URL {
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

    func openScreenSaverSettings() throws {
        didOpenSettings = true
    }
}

private final class MockUpdateChecker: UpdateChecking {
    let result: UpdateCheckResult?
    let error: Error?
    var requestedVersions: [String] = []

    init(result: UpdateCheckResult) {
        self.result = result
        error = nil
    }

    init(error: Error) {
        result = nil
        self.error = error
    }

    func checkForUpdates(currentVersion: String) async throws -> UpdateCheckResult {
        requestedVersions.append(currentVersion)
        if let error {
            throw error
        }
        return try XCTUnwrap(result)
    }
}

private final class MockUpdateURLOpener: UpdateURLOpening {
    var openedURLs: [URL] = []

    func open(_ url: URL) -> Bool {
        openedURLs.append(url)
        return true
    }
}

private enum TestError: Error {
    case expected
}

private enum LocalizedTestError: LocalizedError {
    case expected

    var errorDescription: String? {
        "Expected update error."
    }
}
