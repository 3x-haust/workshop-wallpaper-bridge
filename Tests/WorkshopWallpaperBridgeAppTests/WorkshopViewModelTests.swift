import Foundation
import Combine
import Darwin
import XCTest
@testable import WorkshopWallpaperBridgeApp
import WorkshopWallpaperCore

@MainActor
final class WorkshopViewModelTests: XCTestCase {
    func testLoginNeedsAuthenticatedEventAndIgnoresOldRequest() async throws {
        let fixture = try makeFixture()
        fixture.model.loginQR()
        let request = try XCTUnwrap(fixture.client.commands.last)
        fixture.client.emit(SteamEvent(id: "stale", type: "authenticated", account: "wrong"))
        XCTAssertNil(fixture.model.account)
        fixture.client.emit(SteamEvent(id: request.id, type: "qr", url: "https://s.team/q/1/example"))
        XCTAssertNotNil(fixture.model.qrURL)
        XCTAssertFalse(fixture.model.isAuthenticated)
        fixture.client.emit(SteamEvent(id: request.id, type: "authenticated", account: "test-account"))
        XCTAssertEqual(fixture.model.account, "test-account")
        XCTAssertNil(fixture.model.qrURL)
        XCTAssertFalse(fixture.model.isBusy)
    }

    func testGuardReplyUsesActiveLoginAndPasswordOnlyUsesIPC() throws {
        let fixture = try makeFixture()
        fixture.model.login(username: "test-account", password: "synthetic-password")
        let login = try XCTUnwrap(fixture.client.commands.last)
        XCTAssertEqual(login.command, "loginPassword")
        XCTAssertNotNil(login.password)
        fixture.client.emit(SteamEvent(id: login.id, type: "authPrompt", prompt: "twoFactor"))
        fixture.model.submitGuard("synthetic-code")
        XCTAssertEqual(fixture.client.commands.last?.id, login.id)
        XCTAssertEqual(fixture.client.commands.last?.command, "guard")
        XCTAssertNil(fixture.model.authPrompt)
        XCTAssertFalse(fixture.model.statusKey.contains("synthetic"))
    }

    func testUntrustedQRAndErrorTextCannotAppearAsStatus() async throws {
        let fixture = try makeFixture()
        fixture.model.loginQR()
        let id = try XCTUnwrap(fixture.client.commands.last?.id)
        fixture.client.emit(SteamEvent(id: id, type: "qr", url: "https://attacker.invalid/login"))
        await waitUntil { !fixture.model.isBusy }
        XCTAssertNil(fixture.model.qrURL)
        XCTAssertNil(fixture.model.account)
        XCTAssertEqual(fixture.model.statusKey, "workshop.error.protocol")

        fixture.model.resume()
        let retryID = try XCTUnwrap(fixture.client.commands.last?.id)
        let data = Data("{\"id\":\"\(retryID)\",\"type\":\"error\",\"code\":\"synthetic-secret\",\"message\":\"synthetic-secret\"}".utf8)
        fixture.client.emit(try JSONDecoder().decode(SteamEvent.self, from: data))
        await waitUntil { !fixture.model.isBusy }
        XCTAssertEqual(fixture.model.statusKey, "workshop.error.connection")
    }

    func testCancellationWaitsForExitBeforeRetryAndDropsLateSuccess() async throws {
        let fixture = try makeFixture()
        authenticate(fixture)
        fixture.model.download(item())
        let download = try XCTUnwrap(fixture.client.commands.last)
        fixture.client.holdStop = true
        fixture.model.cancel()
        await waitUntil { fixture.client.stopWaiter != nil }
        XCTAssertTrue(fixture.model.isBusy)
        fixture.model.download(item())
        XCTAssertEqual(fixture.client.commands.count, 2)
        fixture.client.emit(SteamEvent(id: download.id, type: "completed", itemID: "893418273"))
        XCTAssertTrue(fixture.model.downloads.isEmpty)
        fixture.client.finishStop()
        await waitUntil { !fixture.model.isBusy }
        XCTAssertNil(fixture.model.account)
        XCTAssertNotNil(fixture.model.retryItem)
        XCTAssertTrue(fixture.model.downloads.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(download.directory)))
    }

    func testHelperExitCannotPromotePartialDownloadToSuccess() async throws {
        let fixture = try makeFixture()
        authenticate(fixture)
        fixture.model.download(item())
        let directory = URL(filePath: try XCTUnwrap(fixture.client.commands.last?.directory))
        try Data("partial".utf8).write(to: directory.appending(path: "index.html"))
        fixture.client.onExit?()
        await waitUntil { !fixture.model.isBusy }
        XCTAssertTrue(fixture.model.downloads.isEmpty)
        XCTAssertTrue(fixture.library.libraryAssets.isEmpty)
        XCTAssertNil(fixture.player.playedID)
        XCTAssertEqual(fixture.model.statusKey, "workshop.error.connection")
    }

    func testCompletedDownloadAutomaticallyImportsAndRequestsPlayback() async throws {
        let fixture = try makeFixture()
        let download = try await completeDownload(fixture)
        XCTAssertEqual(fixture.model.downloads.map(\.id), [download.id])
        XCTAssertEqual(fixture.model.selectedAsset?.supportStatus, .playable)
        XCTAssertEqual(fixture.library.libraryAssets.map(\.id), [download.id])
        XCTAssertEqual(fixture.player.playedID, download.id)
        XCTAssertEqual(fixture.model.statusKey, "workshop.play.requested")
    }

    func testSelectingDownloadAutomaticallyAppliesExistingLibraryCopy() async throws {
        let fixture = try makeFixture()
        let download = try await completeDownload(fixture)
        fixture.player.playedID = nil
        fixture.model.selectDownload(download.id)
        fixture.model.removeDownloaded(download)
        XCTAssertTrue(FileManager.default.fileExists(atPath: download.directory))
        await waitUntil { !fixture.model.isBusy }
        XCTAssertEqual(fixture.player.playedID, download.id)
        XCTAssertEqual(fixture.library.libraryAssets.count, 1)
    }

    func testPlaybackErrorIsNotReportedAsRequestedPlayback() async throws {
        let fixture = try makeFixture()
        fixture.player.shouldFail = true
        _ = try await completeDownload(fixture)
        XCTAssertNil(fixture.player.playedID)
        XCTAssertEqual(fixture.model.statusKey, "workshop.error.play")
        XCTAssertEqual(fixture.library.libraryAssets.count, 1)
        XCTAssertEqual(fixture.player.stopCount, 0)
    }

    func testDuplicateImportPreservesExistingLibraryAndConvertedFiles() async throws {
        let fixture = try makeFixture()
        let download = try await completeDownload(fixture)
        fixture.model.importSelected()
        await waitUntil { !fixture.model.isBusy }
        let imported = try XCTUnwrap(fixture.library.libraryAssets.first)
        let cache = URL(filePath: imported.projectDirectory).appending(path: "wwb-converted.mp4")
        try Data("cached-video".utf8).write(to: cache)
        fixture.model.importSelected()
        await waitUntil { !fixture.model.isBusy }
        XCTAssertEqual(try Data(contentsOf: cache), Data("cached-video".utf8))
        XCTAssertEqual(fixture.library.libraryAssets.count, 1)
        fixture.model.removeDownloaded(download)
        XCTAssertEqual(fixture.library.libraryAssets.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
    }

    func testLibraryBusyGateRejectsWorkshopImport() async throws {
        let fixture = try makeFixture()
        fixture.library.isWorking = true
        _ = try await completeDownload(fixture)
        XCTAssertFalse(fixture.model.isBusy)
        XCTAssertTrue(fixture.library.libraryAssets.isEmpty)
        XCTAssertNil(fixture.player.playedID)
        XCTAssertEqual(fixture.model.statusKey, "workshop.error.busy")
        fixture.library.isWorking = false
    }

    func testLogoutRetainsCredentialsAndDeleteWaitsForHelperExit() async throws {
        let fixture = try makeFixture()
        let credential = fixture.root.appending(path: "Steam/credentials.json")
        try FileManager.default.createDirectory(at: credential.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("synthetic-credentials".utf8).write(to: credential)
        authenticate(fixture)
        fixture.model.logout()
        await waitUntil { !fixture.model.isBusy }
        XCTAssertNil(fixture.model.account)
        XCTAssertTrue(fixture.model.hasSavedSession)
        XCTAssertTrue(FileManager.default.fileExists(atPath: credential.path))
        fixture.client.holdStop = true
        fixture.model.deleteSavedAuthentication()
        await waitUntil { fixture.client.stopWaiter != nil }
        XCTAssertTrue(FileManager.default.fileExists(atPath: credential.path))
        fixture.client.finishStop()
        await waitUntil { !fixture.model.isBusy }
        XCTAssertFalse(FileManager.default.fileExists(atPath: credential.path))
        XCTAssertFalse(fixture.model.hasSavedSession)
    }

    func testSavedCredentialDeletionRejectsSymlink() throws {
        let root = try temporaryDirectory()
        let outside = root.appending(path: "outside")
        try Data("preserve".utf8).write(to: outside)
        let directory = root.appending(path: "Steam")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directory.appending(path: "credentials.json"), withDestinationURL: outside)
        let storage = SteamAuthenticationStorage(directory: directory)
        XCTAssertFalse(storage.hasSavedSession)
        XCTAssertThrowsError(try storage.deleteSavedSession())
        XCTAssertEqual(try Data(contentsOf: outside), Data("preserve".utf8))
    }

    func testSavedCredentialDeletionRejectsDirectoriesWithoutRemovingContents() throws {
        for name in ["credentials.json", "credentials.json.tmp"] {
            let root = try temporaryDirectory()
            let directory = root.appending(path: "Steam")
            let invalid = directory.appending(path: name)
            try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
            let unrelated = invalid.appending(path: "preserve.txt")
            try Data("preserve".utf8).write(to: unrelated)
            let otherName = name == "credentials.json" ? "credentials.json.tmp" : "credentials.json"
            let other = directory.appending(path: otherName)
            try Data("synthetic".utf8).write(to: other)
            let storage = SteamAuthenticationStorage(directory: directory)

            XCTAssertThrowsError(try storage.deleteSavedSession(), name)
            XCTAssertEqual(try Data(contentsOf: unrelated), Data("preserve".utf8), name)
            XCTAssertEqual(try Data(contentsOf: other), Data("synthetic".utf8), "Validate both targets before deleting either")
        }
    }

    func testIdleDisconnectClearsLoginStateAndReconnectCanStart() throws {
        let fixture = try makeFixture()
        authenticate(fixture)
        fixture.client.emit(SteamEvent(id: "", type: "disconnected"))
        XCTAssertNil(fixture.model.account)
        XCTAssertEqual(fixture.model.statusKey, "workshop.disconnected")
        fixture.model.resume()
        fixture.client.emit(SteamEvent(id: "", type: "disconnected"))
        XCTAssertEqual(fixture.model.operation, "login")
    }

    func testAuthenticationDeletionAlsoRemovesInterruptedSaveButNotOtherFiles() throws {
        let root = try temporaryDirectory()
        let directory = root.appending(path: "Steam")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let interrupted = directory.appending(path: "credentials.json.tmp")
        let unrelated = directory.appending(path: "unrelated")
        try Data("synthetic".utf8).write(to: interrupted)
        try Data("preserve".utf8).write(to: unrelated)
        let storage = SteamAuthenticationStorage(directory: directory)
        XCTAssertFalse(storage.hasSavedSession)
        XCTAssertTrue(storage.hasStoredAuthentication)
        try storage.deleteSavedSession()
        XCTAssertFalse(storage.hasStoredAuthentication)
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("preserve".utf8))
    }

    func testSearchPaginationUsesServerPageSizeRatherThanFilteredItemCount() throws {
        let fixture = try makeFixture()
        authenticate(fixture)
        fixture.model.search(page: 2)
        fixture.client.emit(SteamEvent(id: fixture.client.commands.last!.id, type: "items", items: [item()], total: 41, page: 2, pageSize: 20))
        XCTAssertTrue(fixture.model.hasNextPage)
        fixture.model.search(page: 3)
        fixture.client.emit(SteamEvent(id: fixture.client.commands.last!.id, type: "items", items: [item()], total: 41, page: 3, pageSize: 20))
        XCTAssertFalse(fixture.model.hasNextPage)
        fixture.model.search(page: 1)
        fixture.client.emit(SteamEvent(id: fixture.client.commands.last!.id, type: "items", items: [], total: 41, page: 1, pageSize: 20))
        XCTAssertTrue(fixture.model.hasNextPage, "Filtered collections must not hide subsequent pages")
    }

    func testFiltersReachServerResetPageAndSerializeLateSearchResponses() throws {
        let fixture = try makeFixture()
        authenticate(fixture)
        fixture.model.search(page: 3)
        let previous = try XCTUnwrap(fixture.client.commands.last)
        fixture.model.sort = "recent"
        fixture.model.kindFilter = "scene"
        fixture.model.genreFilter = "Nature"
        fixture.model.applyFilters()
        XCTAssertEqual(fixture.client.commands.last?.id, previous.id)
        fixture.client.emit(SteamEvent(id: previous.id, type: "items", items: [item()], total: 60, page: 3, pageSize: 20))
        let filtered = try XCTUnwrap(fixture.client.commands.last)
        XCTAssertNotEqual(filtered.id, previous.id)
        XCTAssertEqual(filtered.page, 1)
        XCTAssertEqual(filtered.sort, "recent")
        XCTAssertEqual(filtered.kind, "scene")
        XCTAssertEqual(filtered.genre, "Nature")
        XCTAssertTrue(fixture.model.items.isEmpty)
        fixture.client.emit(SteamEvent(id: previous.id, type: "items", items: [item()], page: 3))
        XCTAssertTrue(fixture.model.isBusy)
        fixture.client.emit(SteamEvent(id: filtered.id, type: "items", items: [], total: 0, page: 1, pageSize: 20))
        XCTAssertEqual(fixture.model.page, 1)
        XCTAssertFalse(fixture.model.isBusy)
        fixture.model.search(page: 2)
        XCTAssertEqual(fixture.client.commands.last?.genre, "Nature")
    }

    func testUnsupportedDownloadIsImportedWithoutPlaybackOrStop() async throws {
        let fixture = try makeFixture()
        _ = try await completeDownload(fixture, project: #"{"title":"Fixture","type":"application","file":"test.exe"}"#)
        XCTAssertEqual(fixture.library.libraryAssets.count, 1)
        XCTAssertNil(fixture.player.playedID)
        XCTAssertEqual(fixture.player.stopCount, 0)
        XCTAssertEqual(fixture.model.statusKey, "workshop.play.unsupported")
    }

    func testInvalidCompletedProjectNeverImportsOrApplies() async throws {
        let fixture = try makeFixture()
        authenticate(fixture)
        fixture.model.download(item())
        let command = try XCTUnwrap(fixture.client.commands.last)
        fixture.client.emit(SteamEvent(id: command.id, type: "completed", itemID: item().id))
        await waitUntil { !fixture.model.isBusy }
        XCTAssertTrue(fixture.model.downloads.isEmpty)
        XCTAssertTrue(fixture.library.libraryAssets.isEmpty)
        XCTAssertNil(fixture.player.playedID)
        XCTAssertEqual(fixture.model.statusKey, "workshop.error.project")
    }

    func testScanErrorDoesNotApplyEvenWhenLibraryCopyExists() async throws {
        let fixture = try makeFixture()
        let download = try await completeDownload(fixture)
        fixture.player.playedID = nil
        try Data("invalid".utf8).write(to: URL(filePath: download.directory).appending(path: "project.json"))
        fixture.model.selectDownload(download.id)
        await waitUntil { !fixture.model.isBusy }
        XCTAssertNil(fixture.player.playedID)
        XCTAssertEqual(fixture.player.stopCount, 0)
        XCTAssertEqual(fixture.model.statusKey, "workshop.error.project")
    }

    func testImportErrorKeepsCompletedDownloadWithoutClaimingPlayback() async throws {
        let fixture = try makeFixture()
        try Data("invalid".utf8).write(to: fixture.root.appending(path: "library.json"))
        _ = try await completeDownload(fixture)
        XCTAssertEqual(fixture.model.downloads.count, 1)
        XCTAssertTrue(fixture.library.libraryAssets.isEmpty)
        XCTAssertNil(fixture.player.playedID)
        XCTAssertEqual(fixture.model.statusKey, "workshop.error.import")
    }

    func testCancelDuringFinalizationRetainsDownloadWithoutApplying() async throws {
        let fixture = try makeFixture()
        try startCompletedDownload(fixture)
        XCTAssertEqual(fixture.model.operation, "finalizing")
        fixture.model.cancel()
        XCTAssertTrue(fixture.model.isBusy)
        await waitUntil { !fixture.model.isBusy }
        XCTAssertEqual(fixture.model.downloads.count, 1)
        XCTAssertTrue(fixture.library.libraryAssets.isEmpty)
        XCTAssertNil(fixture.player.playedID)
        XCTAssertEqual(fixture.model.statusKey, "workshop.cancelled")
    }

    func testLibrarySelectionDuringDownloadPreventsLateAutoApply() async throws {
        let fixture = try makeFixture()
        try startCompletedDownload(fixture)
        fixture.library.selectLibraryAssets([])
        await waitUntil { !fixture.model.isBusy }
        XCTAssertEqual(fixture.model.downloads.count, 1)
        XCTAssertTrue(fixture.library.selectedLibraryAssetIds.isEmpty)
        XCTAssertNil(fixture.player.playedID)
    }

    func testSelectionDuringImportIsPreservedAndDownloadCannotBeRemovedOrRestarted() async throws {
        let fixture = try makeFixture()
        var checked = false
        let observation = fixture.library.$importProgress.sink { progress in
            guard progress?.completed == 0, let download = fixture.model.selectedDownload else { return }
            checked = true
            fixture.library.selectLibraryAssets([])
            fixture.model.removeDownloaded(download)
            fixture.model.download(self.item())
            XCTAssertTrue(FileManager.default.fileExists(atPath: download.directory))
            XCTAssertEqual(fixture.client.commands.count, 2)
        }
        _ = try await completeDownload(fixture)
        withExtendedLifetime(observation) {}
        XCTAssertTrue(checked)
        XCTAssertTrue(fixture.library.selectedLibraryAssetIds.isEmpty)
        XCTAssertEqual(fixture.library.libraryAssets.count, 1)
        XCTAssertNil(fixture.player.playedID)
    }

    func testCancelDuringImportWaitsForWriteButNeverApplies() async throws {
        let fixture = try makeFixture()
        let observation = fixture.library.$importProgress.sink { progress in
            if progress?.completed == 0 { fixture.model.cancel() }
        }
        _ = try await completeDownload(fixture)
        withExtendedLifetime(observation) {}
        XCTAssertFalse(fixture.library.isWorking)
        XCTAssertEqual(fixture.library.libraryAssets.count, 1)
        XCTAssertNil(fixture.player.playedID)
        XCTAssertEqual(fixture.model.statusKey, "workshop.cancelled")
    }

    func testNewestDownloadSelectionSupersedesPendingScan() async throws {
        let fixture = try makeFixture()
        let first = try await completeDownload(fixture)
        let secondItem = WorkshopItem(id: "893418274", title: "Second", description: "", previewURL: nil, kind: "web", size: nil)
        fixture.model.download(secondItem)
        let command = try XCTUnwrap(fixture.client.commands.last)
        let directory = URL(filePath: try XCTUnwrap(command.directory))
        try writeProject(directory)
        fixture.client.emit(SteamEvent(id: command.id, type: "completed", itemID: secondItem.id))
        fixture.player.playedID = nil
        fixture.model.selectDownload(first.id)
        await waitUntil { !fixture.model.isBusy }
        XCTAssertEqual(fixture.model.downloads.count, 2)
        XCTAssertEqual(fixture.player.playedID, first.id)
        XCTAssertEqual(fixture.model.selectedDownloadID, first.id)
        XCTAssertEqual(fixture.library.libraryAssets.map(\.id), [first.id])
    }

    func testAcceptedPlaybackIsRememberedOnlyAfterReadyEvent() async throws {
        let fixture = try makeFixture()
        let download = try await completeDownload(fixture)
        XCTAssertNil(fixture.library.activeWallpaperAssetID)
        XCTAssertNil(fixture.defaults.string(forKey: "lastPlayedAssetId"))
        XCTAssertEqual(fixture.library.status, fixture.library.L("workshop.play.requested"))
        XCTAssertEqual(fixture.model.statusKey, "workshop.play.requested")

        fixture.player.handler?(.ready(assetID: download.id))
        XCTAssertEqual(fixture.library.activeWallpaperAssetID, download.id)
        XCTAssertEqual(fixture.defaults.string(forKey: "lastPlayedAssetId"), download.id)
        XCTAssertEqual(fixture.model.statusKey, "workshop.play.ready")
    }

    func testAsynchronousFailurePreservesPreviouslyReadyWallpaperAndPreference() async throws {
        let fixture = try makeFixture()
        let download = try await completeDownload(fixture)
        fixture.player.handler?(.ready(assetID: download.id))
        let original = try XCTUnwrap(fixture.library.libraryAssets.first)
        let second = WallpaperAsset(id: "893418274", title: "Second", kind: original.kind,
                                    supportStatus: .playable, source: original.source,
                                    projectDirectory: original.projectDirectory, entrypoint: original.entrypoint,
                                    thumbnail: nil, workshopId: nil, redistributionAllowed: false, issues: [])
        fixture.library.libraryAssets.append(second)
        XCTAssertTrue(fixture.library.selectAndApplyLibraryAsset(second.id))
        fixture.player.handler?(.failed(assetID: second.id, message: "Synthetic load failure"))
        XCTAssertEqual(fixture.library.activeWallpaperAssetID, download.id)
        XCTAssertEqual(fixture.defaults.string(forKey: "lastPlayedAssetId"), download.id)
        XCTAssertEqual(fixture.library.status, "Synthetic load failure")
        XCTAssertEqual(fixture.player.stopCount, 0)
        fixture.player.handler?(.ready(assetID: second.id))
        XCTAssertEqual(fixture.library.activeWallpaperAssetID, download.id)
    }

    func testNewSelectionOrCancellationDiscardsPendingPlaybackWithoutStoppingActiveWallpaper() async throws {
        for action in ["unsupported", "multiple", "cancel"] {
            let fixture = try makeFixture()
            let download = try await completeDownload(fixture)
            fixture.player.finishPendingPlayback()
            let original = try XCTUnwrap(fixture.library.libraryAssets.first)
            let pending = WallpaperAsset(id: "pending", title: "Pending", kind: original.kind,
                                         supportStatus: .playable, source: original.source,
                                         projectDirectory: original.projectDirectory, entrypoint: original.entrypoint,
                                         thumbnail: nil, workshopId: nil, redistributionAllowed: false, issues: [])
            let unsupported = WallpaperAsset(id: "unsupported", title: "Unsupported", kind: original.kind,
                                             supportStatus: .unsupported, source: original.source,
                                             projectDirectory: original.projectDirectory, entrypoint: original.entrypoint,
                                             thumbnail: nil, workshopId: nil, redistributionAllowed: false, issues: [])
            fixture.library.libraryAssets += [pending, unsupported]
            XCTAssertTrue(fixture.library.selectAndApplyLibraryAsset(pending.id))
            XCTAssertEqual(fixture.player.pendingID, pending.id)

            switch action {
            case "unsupported": XCTAssertFalse(fixture.library.selectAndApplyLibraryAsset(unsupported.id))
            case "multiple": fixture.library.selectLibraryAssets([download.id, pending.id])
            default:
                fixture.model.search()
                XCTAssertTrue(fixture.model.canCancel)
                fixture.model.cancel()
            }
            let statusAfterSelection = fixture.library.status
            XCTAssertNil(fixture.player.pendingID, action)
            fixture.player.finishPendingPlayback()
            // A callback already queued by a cancelled request must also be ignored.
            fixture.player.handler?(.ready(assetID: pending.id))
            fixture.player.handler?(.failed(assetID: pending.id, message: "Stale failure"))

            XCTAssertEqual(fixture.player.activeID, download.id, action)
            XCTAssertEqual(fixture.library.activeWallpaperAssetID, download.id, action)
            XCTAssertEqual(fixture.defaults.string(forKey: "lastPlayedAssetId"), download.id, action)
            XCTAssertEqual(fixture.library.status, statusAfterSelection, action)
            XCTAssertEqual(fixture.player.stopCount, 0, action)
        }
    }

    func testStaleAndStoppedReadinessEventsCannotChangeActiveWallpaper() async throws {
        let fixture = try makeFixture()
        let download = try await completeDownload(fixture)
        fixture.player.handler?(.ready(assetID: "stale"))
        XCTAssertNil(fixture.library.activeWallpaperAssetID)
        fixture.library.stopPlayback()
        fixture.player.handler?(.ready(assetID: download.id))
        XCTAssertNil(fixture.library.activeWallpaperAssetID)
        XCTAssertNil(fixture.defaults.string(forKey: "lastPlayedAssetId"))
    }

    func testWorkshopAsynchronousLoadFailureIsNotReady() async throws {
        let fixture = try makeFixture()
        let download = try await completeDownload(fixture)
        fixture.player.handler?(.failed(assetID: download.id, message: "Synthetic load failure"))
        XCTAssertEqual(fixture.model.statusKey, "workshop.error.play")
        XCTAssertNil(fixture.library.activeWallpaperAssetID)
        XCTAssertNil(fixture.defaults.string(forKey: "lastPlayedAssetId"))
    }

    func testSynchronousReadyCallbackIsNotOverwrittenByRequestedStatus() async throws {
        let fixture = try makeFixture()
        fixture.player.readySynchronously = true
        let download = try await completeDownload(fixture)
        XCTAssertEqual(fixture.model.statusKey, "workshop.play.ready")
        XCTAssertEqual(fixture.library.activeWallpaperAssetID, download.id)
    }

    func testDirectLibrarySelectionAppliesButMultiSelectionDoesNot() async throws {
        let fixture = try makeFixture()
        let download = try await completeDownload(fixture)
        fixture.player.playedID = nil
        fixture.library.selectLibraryAssets([download.id])
        XCTAssertNil(fixture.player.playedID)
        XCTAssertTrue(fixture.library.selectAndApplyLibraryAsset(download.id))
        XCTAssertEqual(fixture.player.playedID, download.id)
        fixture.player.shouldFail = true
        XCTAssertFalse(fixture.library.selectAndApplyLibraryAsset(download.id))
        XCTAssertFalse(fixture.library.selectAndApplyLibraryAsset("absent"))
    }

    func testWorkshopIDsMustBeASingleNonzeroUInt64DecimalComponent() {
        for value in ["", "0", "../1", "/1", "1/2", "-1", "１２３", "18446744073709551616"] {
            XCTAssertFalse(WorkshopViewModel.validID(value), value)
        }
        XCTAssertTrue(WorkshopViewModel.validID("893418273"))
    }

    private struct Fixture {
        let root: URL
        let library: AppViewModel
        let model: WorkshopViewModel
        let client: FakeSteamClient
        let player: WorkshopTestPlayer
        let defaults: UserDefaults
    }

    private func makeFixture() throws -> Fixture {
        let root = try temporaryDirectory()
        let suite = "WorkshopViewModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let player = WorkshopTestPlayer()
        let library = AppViewModel(store: LibraryStore(root: root), loginItemController: WorkshopLoginItems(), wallpaperPlayer: player, userDefaults: defaults)
        let client = FakeSteamClient()
        return Fixture(root: root, library: library, model: WorkshopViewModel(library: library, root: root, client: client), client: client, player: player, defaults: defaults)
    }

    private func temporaryDirectory() throws -> URL {
        let path = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(path) }
        let root = URL(filePath: String(cString: path)).appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func item() -> WorkshopItem {
        WorkshopItem(id: "893418273", title: "Fixture", description: "Local test fixture", previewURL: nil, kind: "web", size: nil)
    }

    private func authenticate(_ fixture: Fixture) {
        fixture.model.loginQR()
        fixture.client.emit(SteamEvent(id: fixture.client.commands.last!.id, type: "authenticated", account: "test-account"))
    }

    private func completeDownload(_ fixture: Fixture, project: String? = nil) async throws -> WorkshopDownload {
        try startCompletedDownload(fixture, project: project)
        await waitUntil { !fixture.model.isBusy && fixture.model.selectedAsset != nil }
        return try XCTUnwrap(fixture.model.selectedDownload)
    }

    private func startCompletedDownload(_ fixture: Fixture, project: String? = nil) throws {
        authenticate(fixture)
        fixture.model.download(item())
        let command = try XCTUnwrap(fixture.client.commands.last)
        let directory = URL(filePath: try XCTUnwrap(command.directory))
        try writeProject(directory, project: project)
        fixture.client.emit(SteamEvent(id: command.id, type: "completed", itemID: item().id))
    }

    private func writeProject(_ directory: URL, project: String? = nil) throws {
        try Data((project ?? #"{"title":"Fixture","type":"web","file":"index.html"}"#).utf8).write(to: directory.appending(path: "project.json"))
        try Data("<html>Local fixture</html>".utf8).write(to: directory.appending(path: "index.html"))
        if project != nil { try Data("synthetic executable".utf8).write(to: directory.appending(path: "test.exe")) }
    }

    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(predicate(), "Expected asynchronous operation to finish", file: file, line: line)
    }
}

@MainActor
private final class FakeSteamClient: SteamHelperTransport {
    var onEvent: ((SteamEvent) -> Void)?
    var onExit: (() -> Void)?
    var commands: [SteamCommand] = []
    var holdStop = false
    var stopWaiter: CheckedContinuation<Void, Never>?
    func send(_ command: SteamCommand) throws { commands.append(command) }
    func emit(_ event: SteamEvent) { onEvent?(event) }
    func stop() async {
        if holdStop { await withCheckedContinuation { stopWaiter = $0 } }
        onExit?()
    }
    func finishStop() {
        holdStop = false
        stopWaiter?.resume()
        stopWaiter = nil
    }
}

@MainActor
private final class WorkshopTestPlayer: WallpaperPlaying {
    var playedID: String?
    var shouldFail = false
    var stopCount = 0
    var readySynchronously = false
    var pendingID: String?
    var activeID: String?
    func cancelPendingPlayback() { pendingID = nil }
    func finishPendingPlayback() {
        guard let id = pendingID else { return }
        pendingID = nil
        activeID = id
        handler?(.ready(assetID: id))
    }
    var handler: ((WallpaperPlaybackEvent) -> Void)?
    func setPlaybackStatusHandler(_ handler: @escaping (WallpaperPlaybackEvent) -> Void) { self.handler = handler }
    func play(asset: WallpaperAsset, autoPauseWhenCovered: Bool, displayMode: WallpaperDisplayMode, audioEnabled: Bool?, audioVolume: Double?) throws {
        if shouldFail { throw SteamBridgeError.noProject }
        playedID = asset.id
        pendingID = asset.id
        if readySynchronously { finishPendingPlayback() }
    }
    func stop() { stopCount += 1 }
    func setDisplayMode(_ mode: WallpaperDisplayMode) {}
    func setAutoPauseWhenCovered(_ enabled: Bool) {}
}

@MainActor
private final class WorkshopLoginItems: LoginItemManaging {
    var isEnabled: Bool { false }
    func setEnabled(_ enabled: Bool) throws {}
    func openSystemSettings() {}
}
