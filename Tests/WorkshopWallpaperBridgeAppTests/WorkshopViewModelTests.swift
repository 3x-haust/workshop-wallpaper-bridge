import Foundation
import Combine
import Darwin
import XCTest
@testable import WorkshopWallpaperBridgeApp
import WorkshopWallpaperCore

@MainActor
final class WorkshopViewModelTests: XCTestCase {
    func testSavedAuthenticationReconnectsWhenModelStarts() throws {
        let fixture = try makeFixture()
        let credential = fixture.root.appending(path: "Steam/credentials.json")
        try FileManager.default.createDirectory(at: credential.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("synthetic-credentials".utf8).write(to: credential)
        let client = FakeSteamClient()

        let model = WorkshopViewModel(library: fixture.library, root: fixture.root, client: client, userDefaults: fixture.defaults)

        XCTAssertEqual(client.commands.map(\.command), ["resume"])
        XCTAssertEqual(model.operation, "login")
        XCTAssertNil(model.account, "A saved file is not proof that Steam accepted the session")
    }

    func testExplicitLogoutStaysLoggedOutAcrossLaunchesUntilReconnect() async throws {
        let fixture = try makeFixture()
        let credential = fixture.root.appending(path: "Steam/credentials.json")
        try FileManager.default.createDirectory(at: credential.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("synthetic-credentials".utf8).write(to: credential)
        authenticate(fixture)
        fixture.model.logout()
        await waitUntil { !fixture.model.isBusy }
        let client = FakeSteamClient()
        let model = WorkshopViewModel(library: fixture.library, root: fixture.root, client: client, userDefaults: fixture.defaults)
        XCTAssertTrue(model.hasSavedSession)
        XCTAssertTrue(client.commands.isEmpty)

        model.resume()
        XCTAssertEqual(client.commands.map(\.command), ["resume"])
        client.emit(SteamEvent(id: client.commands[0].id, type: "authenticated", account: "test-account"))
        let relaunchedClient = FakeSteamClient()
        let relaunched = WorkshopViewModel(library: fixture.library, root: fixture.root, client: relaunchedClient, userDefaults: fixture.defaults)
        XCTAssertEqual(relaunchedClient.commands.map(\.command), ["resume"])
        XCTAssertEqual(relaunched.operation, "login")
    }

    func testExpiredSavedAuthenticationStopsWithoutDeletingOrRetrying() async throws {
        let fixture = try makeFixture()
        let credential = fixture.root.appending(path: "Steam/credentials.json")
        try FileManager.default.createDirectory(at: credential.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("synthetic-credentials".utf8).write(to: credential)
        let client = FakeSteamClient()
        let model = WorkshopViewModel(library: fixture.library, root: fixture.root, client: client, userDefaults: fixture.defaults)
        let command = try XCTUnwrap(client.commands.first)

        client.emit(SteamEvent(id: command.id, type: "error", code: "expired"))
        await waitUntil { !model.isBusy }

        XCTAssertNil(model.account)
        XCTAssertEqual(model.statusKey, "workshop.error.authentication")
        XCTAssertEqual(client.commands.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: credential.path))
    }

    func testRequestFailuresKeepAuthenticatedConnectionAndAllowNextSearch() async throws {
        for operation in ["search", "details", "download"] {
            for code in ["accessDenied", "unavailable", "requestFailed", "invalidRequest", "busy", "downloadFailed", "unsafePath", "wrongApp"] {
                let fixture = try makeFixture()
                try saveAuthentication(fixture)
                authenticate(fixture)
                switch operation {
                case "search": fixture.model.search()
                case "details": fixture.model.showDetails(item())
                default: fixture.model.download(item())
                }
                let command = try XCTUnwrap(fixture.client.commands.last)
                fixture.client.emit(SteamEvent(id: command.id, type: "error", code: code))
                await waitUntil { !fixture.model.isBusy }

                XCTAssertEqual(fixture.model.account, "test-account", "\(operation): \(code)")
                XCTAssertEqual(fixture.client.stopCount, 0, "\(operation): \(code)")
                XCTAssertEqual(fixture.client.commands.count, 2)
                if let directory = command.directory {
                    XCTAssertFalse(FileManager.default.fileExists(atPath: directory))
                    XCTAssertEqual(fixture.model.retryItem, item())
                }
                fixture.model.search()
                XCTAssertEqual(fixture.client.commands.last?.command, "search")
                XCTAssertEqual(fixture.client.commands.count, 3)
            }
        }
    }

    func testLostConnectionAndDownloadCancellationResumeOnceAfterStopAndCleanup() async throws {
        for trigger in ["exit", "disconnected", "error", "send", "cancel"] {
            let fixture = try makeFixture()
            try saveAuthentication(fixture)
            authenticate(fixture)
            fixture.client.holdStop = true
            fixture.client.failSend = trigger == "send"
            fixture.model.download(item())
            let command = try XCTUnwrap(fixture.client.commands.last)
            switch trigger {
            case "exit": fixture.client.onExit?()
            case "disconnected": fixture.client.emit(SteamEvent(id: "", type: "disconnected"))
            case "error": fixture.client.emit(SteamEvent(id: command.id, type: "error", code: "disconnected"))
            case "cancel": fixture.model.cancel()
            default: break
            }
            await waitUntil { fixture.client.stopWaiter != nil }
            XCTAssertNil(fixture.model.account, trigger)
            XCTAssertEqual(fixture.model.operation, "stopping", trigger)
            fixture.model.resume()
            fixture.model.search()
            XCTAssertEqual(fixture.client.commands.map(\.command), ["loginQR", "download"], trigger)
            fixture.client.emit(SteamEvent(id: command.id, type: "completed", itemID: item().id))
            fixture.client.onExit?()
            fixture.client.failSend = false
            fixture.client.finishStop()
            await waitUntil { fixture.model.operation != "stopping" }

            XCTAssertEqual(fixture.client.commands.map(\.command), ["loginQR", "download", "resume"], trigger)
            XCTAssertEqual(fixture.model.operation, "login", trigger)
            XCTAssertNil(fixture.model.account, trigger)
            XCTAssertTrue(fixture.model.downloads.isEmpty)
            XCTAssertTrue(fixture.library.libraryAssets.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(command.directory)))
            XCTAssertEqual(fixture.model.retryItem, item())

            fixture.client.onExit?()
            await waitUntil { !fixture.model.isBusy }
            XCTAssertEqual(fixture.client.commands.count, 3, "Failed automatic login must not recurse: \(trigger)")
            XCTAssertNil(fixture.model.account)
        }
    }

    func testIdleConnectionRecoveryRequiresAuthenticationBeforeNextRequest() async throws {
        let fixture = try makeFixture()
        try saveAuthentication(fixture)
        authenticate(fixture)
        fixture.client.onExit?()
        await waitUntil { fixture.model.operation != "stopping" }
        XCTAssertEqual(fixture.client.commands.map(\.command), ["loginQR", "resume"])
        XCTAssertNil(fixture.model.account)
        fixture.model.search()
        XCTAssertEqual(fixture.client.commands.count, 2)

        fixture.client.emit(SteamEvent(id: fixture.client.commands.last!.id, type: "authenticated", account: "test-account"))
        fixture.model.search()
        XCTAssertEqual(fixture.client.commands.map(\.command), ["loginQR", "resume", "search"])
    }

    func testConnectionRecoveryRequiresSavedCredentialsAndEnabledPreference() async throws {
        for saved in [false, true] {
            let fixture = try makeFixture()
            if saved { try saveAuthentication(fixture) }
            authenticate(fixture)
            if saved { fixture.defaults.set(false, forKey: "steamWorkshopAutomaticLogin") }
            fixture.client.onExit?()
            await waitUntil { !fixture.model.isBusy }
            XCTAssertNil(fixture.model.account)
            XCTAssertEqual(fixture.client.commands.map(\.command), ["loginQR"])
        }
    }

    func testAuthenticationAndProtocolFailuresStopWithoutAutomaticRecovery() async throws {
        for code in ["expired", "authenticationRequired", "credentialStorageFailed", "unrecognized"] {
            let fixture = try makeFixture()
            try saveAuthentication(fixture)
            authenticate(fixture)
            fixture.model.search()
            fixture.client.emit(SteamEvent(id: fixture.client.commands.last!.id, type: "error", code: code))
            await waitUntil { !fixture.model.isBusy }
            XCTAssertNil(fixture.model.account, code)
            XCTAssertEqual(fixture.client.stopCount, 1, code)
            XCTAssertEqual(fixture.client.commands.count, 2, code)
        }
        let fixture = try makeFixture()
        try saveAuthentication(fixture)
        authenticate(fixture)
        fixture.model.search()
        fixture.client.emit(SteamEvent(id: fixture.client.commands.last!.id, type: "items", items: [item()], page: 0))
        await waitUntil { !fixture.model.isBusy }
        XCTAssertNil(fixture.model.account)
        XCTAssertEqual(fixture.model.statusKey, "workshop.error.protocol")
        XCTAssertEqual(fixture.client.commands.count, 2)
    }

    func testExplicitSessionActionsNeverAutomaticallyReconnect() async throws {
        for action in ["logout", "delete", "cancelLogin"] {
            let fixture = try makeFixture()
            try saveAuthentication(fixture)
            authenticate(fixture)
            switch action {
            case "logout": fixture.model.logout()
            case "delete": fixture.model.deleteSavedAuthentication()
            default:
                fixture.model.resume()
                fixture.model.cancel()
            }
            await waitUntil { !fixture.model.isBusy }
            fixture.client.onExit?()
            await waitUntil { !fixture.model.isBusy }
            XCTAssertNil(fixture.model.account, action)
            XCTAssertFalse(fixture.defaults.bool(forKey: "steamWorkshopAutomaticLogin"), action)
            XCTAssertEqual(fixture.client.commands.map(\.command), action == "cancelLogin" ? ["loginQR", "resume"] : ["loginQR"], action)
        }
    }

    func testDisconnectDuringPreparationDefersRecoveryUntilWriteGateFinishes() async throws {
        var preparation: CheckedContinuation<Void, Error>?
        let fixture = try makeFixture(scenePreparer: { _, _ in
            try await withCheckedThrowingContinuation { preparation = $0 }
        })
        try saveAuthentication(fixture)
        try startCompletedDownload(fixture)
        await waitUntil { preparation != nil }
        fixture.client.onExit?()
        fixture.client.emit(SteamEvent(id: "", type: "disconnected"))
        XCTAssertNil(fixture.model.account)
        XCTAssertEqual(fixture.model.operation, "preparing")
        XCTAssertTrue(fixture.model.isChangingLibraryFiles)
        XCTAssertEqual(fixture.client.stopCount, 0)
        fixture.model.resume()
        fixture.model.cancel()
        fixture.library.removeSelectedLibraryAssets()
        XCTAssertEqual(fixture.library.libraryAssets.count, 1)
        XCTAssertEqual(fixture.client.commands.count, 2)

        preparation?.resume()
        await waitUntil { fixture.model.operation != "preparing" && fixture.model.operation != "stopping" }
        XCTAssertEqual(fixture.client.commands.map(\.command), ["loginQR", "download", "resume"])
        XCTAssertEqual(fixture.model.operation, "login")
        XCTAssertNil(fixture.model.account)
        XCTAssertNil(fixture.player.playedID)
        XCTAssertEqual(fixture.library.libraryAssets.count, 1)
    }

    func testEveryoneFilterIsDefaultAndSettingsPersistAcrossLaunchesAndPages() throws {
        let fixture = try makeFixture()
        authenticate(fixture)
        fixture.model.search()
        var command = try XCTUnwrap(fixture.client.commands.last)
        XCTAssertEqual(command.tagGroups, [["Everyone"]])
        XCTAssertEqual(command.excludedTags, ["Mature", "Questionable"])
        fixture.client.emit(SteamEvent(id: command.id, type: "items", items: [], total: 0, page: 1, pageSize: 30))
        var filters = WorkshopSearchFilters()
        filters.includedTags.formUnion(["Scene", "Video", "Nature", "Landscape", "1920 x 1080", "Approved"])
        filters.excludedTags.insert("Anime")
        fixture.model.updateFilters(filters)
        command = try XCTUnwrap(fixture.client.commands.last)
        XCTAssertEqual(command.page, 1)
        XCTAssertEqual(command.tagGroups, filters.tagGroups)
        XCTAssertEqual(command.excludedTags, filters.excludedTags.sorted())
        fixture.client.emit(SteamEvent(id: command.id, type: "items", items: [], total: 0, page: 1, pageSize: 30))
        fixture.model.search(page: 2)
        XCTAssertEqual(fixture.client.commands.last?.tagGroups, filters.tagGroups)
        let relaunched = WorkshopViewModel(library: fixture.library, root: fixture.root, client: FakeSteamClient(), userDefaults: fixture.defaults)
        XCTAssertEqual(relaunched.filters, filters)
    }

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

    func testDownloadWaitsForPreparationAndReportsProgressBeforeApplying() async throws {
        var preparation: CheckedContinuation<Void, Error>?
        let fixture = try makeFixture(scenePreparer: { _, progress in
            progress(0.4)
            try await withCheckedThrowingContinuation { preparation = $0 }
        })
        try startCompletedDownload(fixture)
        await waitUntil { preparation != nil }

        XCTAssertEqual(fixture.model.operation, "preparing")
        XCTAssertEqual(fixture.model.statusKey, "workshop.working.preparing")
        XCTAssertEqual(fixture.model.preparationProgress, 0.4)
        XCTAssertEqual(fixture.library.libraryAssets.count, 1)
        XCTAssertNil(fixture.player.playedID)
        XCTAssertTrue(fixture.model.canCancel)
        fixture.library.removeSelectedLibraryAssets()
        XCTAssertEqual(fixture.library.libraryAssets.count, 1, "Deletion must wait for preparation writes")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(fixture.model.selectedDownload?.directory)))

        preparation?.resume()
        await waitUntil { !fixture.model.isBusy }
        XCTAssertEqual(fixture.player.playedID, item().id)
        XCTAssertEqual(fixture.model.statusKey, "workshop.play.requested")
        XCTAssertNil(fixture.model.preparationProgress)
        XCTAssertEqual(fixture.client.commands.map(\.command), ["loginQR", "download"])
    }

    func testPreparationFailureRetainsLibraryAndCanRetryWithoutDownloadingAgain() async throws {
        var attempts = 0
        let fixture = try makeFixture(scenePreparer: { _, _ in
            attempts += 1
            if attempts == 1 { throw SteamBridgeError.unavailable }
        })
        let download = try await completeDownload(fixture)
        XCTAssertEqual(fixture.model.statusKey, "workshop.error.prepare")
        XCTAssertNil(fixture.player.playedID)
        XCTAssertEqual(fixture.library.libraryAssets.count, 1)
        XCTAssertTrue(fixture.model.isAuthenticated)

        fixture.model.selectDownload(download.id)
        await waitUntil { !fixture.model.isBusy }
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(fixture.player.playedID, download.id)
        XCTAssertEqual(fixture.client.commands.map(\.command), ["loginQR", "download"])
    }

    func testRendererFailureIsDistinctFromDownloadFailureAndRetainsRetry() async throws {
        let fixture = try makeFixture(scenePreparer: { _, _ in
            throw SceneVideoRenderError.noFramesRecorded
        })
        _ = try await completeDownload(fixture)

        XCTAssertEqual(fixture.model.statusKey, "workshop.error.prepare.renderer")
        XCTAssertNil(fixture.player.playedID)
        XCTAssertEqual(fixture.library.libraryAssets.count, 1)
        XCTAssertEqual(fixture.model.downloads.count, 1)
        XCTAssertTrue(fixture.model.isAuthenticated)
    }

    func testCancelledPreparationCannotApplyOrDisconnectSteam() async throws {
        var preparation: CheckedContinuation<Void, Error>?
        let fixture = try makeFixture(scenePreparer: { _, _ in
            try await withCheckedThrowingContinuation { preparation = $0 }
        })
        try startCompletedDownload(fixture)
        await waitUntil { preparation != nil }

        fixture.model.cancel()
        preparation?.resume()
        await waitUntil { !fixture.model.isBusy }

        XCTAssertEqual(fixture.model.statusKey, "workshop.cancelled")
        XCTAssertTrue(fixture.model.isAuthenticated)
        XCTAssertEqual(fixture.library.libraryAssets.count, 1)
        XCTAssertEqual(fixture.model.downloads.count, 1)
        XCTAssertNil(fixture.player.playedID)
        XCTAssertEqual(fixture.player.stopCount, 0)
    }

    func testNewLibrarySelectionDuringPreparationPreventsLateApplication() async throws {
        var preparation: CheckedContinuation<Void, Error>?
        let fixture = try makeFixture(scenePreparer: { _, _ in
            try await withCheckedThrowingContinuation { preparation = $0 }
        })
        try startCompletedDownload(fixture)
        await waitUntil { preparation != nil }

        fixture.library.selectLibraryAssets([])
        preparation?.resume()
        await waitUntil { !fixture.model.isBusy }

        XCTAssertNil(fixture.player.playedID)
        XCTAssertTrue(fixture.library.selectedLibraryAssetIds.isEmpty)
        XCTAssertEqual(fixture.player.stopCount, 0)
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

    func testLibraryRemovalAlsoRefreshesDownloadedStateAndStopsDeletedWallpaper() async throws {
        let fixture = try makeFixture()
        let download = try await completeDownload(fixture)
        fixture.player.finishPendingPlayback()
        XCTAssertEqual(fixture.library.activeWallpaperAssetID, download.id)

        fixture.library.removeSelectedLibraryAssets()

        XCTAssertTrue(fixture.library.libraryAssets.isEmpty)
        XCTAssertTrue(fixture.model.downloads.isEmpty)
        XCTAssertNil(fixture.model.selectedDownloadID)
        XCTAssertNil(fixture.library.activeWallpaperAssetID)
        XCTAssertNil(fixture.defaults.string(forKey: "lastPlayedAssetId"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: download.directory))
        XCTAssertTrue(fixture.model.isAuthenticated)
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

    func testIdleDisconnectClearsLoginStateAndReconnectCanStart() async throws {
        let fixture = try makeFixture()
        authenticate(fixture)
        fixture.client.emit(SteamEvent(id: "", type: "disconnected"))
        XCTAssertNil(fixture.model.account)
        await waitUntil { !fixture.model.isBusy }
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

    func testRevisitingPageItemsReusesCompleteDetailsWithoutBlockingBrowsing() throws {
        let fixture = try makeFixture()
        authenticate(fixture)
        let summaries = [item(), WorkshopItem(id: "42", title: "Second", description: "Short", previewURL: nil, kind: "scene", size: nil)]
        fixture.model.search()
        fixture.client.emit(SteamEvent(id: fixture.client.commands.last!.id, type: "items", items: summaries, total: 2, page: 1, pageSize: 20))
        let details = summaries.map {
            WorkshopItem(id: $0.id, title: $0.title, description: "Full description for \($0.id)",
                         previewURL: "https://example.com/\($0.id).jpg", kind: $0.kind, size: 1234)
        }
        var blockingSelections = 0

        for index in 0..<12 {
            let selected = index % summaries.count
            fixture.model.showDetails(summaries[selected])
            if fixture.model.isBusy {
                blockingSelections += 1
                fixture.client.emit(SteamEvent(id: fixture.client.commands.last!.id, type: "detail", item: details[selected]))
            }
            XCTAssertEqual(fixture.model.detail, details[selected], "Revisits must keep complete details, not the search summary")
            XCTAssertEqual(fixture.model.statusKey, "workshop.detail.ready")
        }

        print("DETAIL_BROWSING selections=12 helperRequests=\(fixture.client.commands.filter { $0.command == "details" }.count) blockingSelections=\(blockingSelections)")
        XCTAssertEqual(blockingSelections, 2)
        XCTAssertEqual(fixture.client.commands.filter { $0.command == "details" }.map(\.itemID), summaries.map(\.id))
        XCTAssertEqual(fixture.model.items, summaries)
        XCTAssertNil(fixture.player.playedID)
        XCTAssertEqual(fixture.player.stopCount, 0)
        XCTAssertTrue(fixture.library.libraryAssets.isEmpty)
    }

    func testDetailReuseEndsWhenSearchRefreshesOrSessionChanges() async throws {
        for trigger in ["search", "failedSearch", "session"] {
            let fixture = try makeFixture()
            authenticate(fixture)
            fixture.model.search()
            fixture.client.emit(SteamEvent(id: fixture.client.commands.last!.id, type: "items", items: [item()], page: 1))
            fixture.model.showDetails(item())
            fixture.client.emit(SteamEvent(id: fixture.client.commands.last!.id, type: "detail", item: item()))

            if trigger == "session" {
                fixture.model.logout()
                await waitUntil { !fixture.model.isBusy }
                authenticate(fixture)
            } else {
                fixture.model.search()
                if trigger == "failedSearch" {
                    fixture.client.emit(SteamEvent(id: fixture.client.commands.last!.id, type: "error", code: "unavailable"))
                } else {
                    fixture.client.emit(SteamEvent(id: fixture.client.commands.last!.id, type: "items", items: [item()], page: 1))
                }
            }
            fixture.model.showDetails(item())

            XCTAssertEqual(fixture.model.operation, "details", trigger)
            XCTAssertEqual(fixture.client.commands.filter { $0.command == "details" }.count, 2, trigger)
            let updated = WorkshopItem(id: item().id, title: "Updated", description: "New details", previewURL: nil, kind: "web", size: 321)
            fixture.client.emit(SteamEvent(id: fixture.client.commands.last!.id, type: "detail", item: updated))
            XCTAssertEqual(fixture.model.detail, updated, trigger)
        }
    }

    func testFailedDetailsAreRetriedAndOutOfPageDetailsAreNotRetained() throws {
        let fixture = try makeFixture()
        authenticate(fixture)
        fixture.model.search()
        fixture.client.emit(SteamEvent(id: fixture.client.commands.last!.id, type: "items", items: [item()], page: 1))
        fixture.model.showDetails(item())
        let failedRequest = fixture.client.commands.last!.id
        fixture.client.emit(SteamEvent(id: failedRequest, type: "error", code: "unavailable"))
        fixture.model.showDetails(item())
        XCTAssertEqual(fixture.model.operation, "details")
        let retry = fixture.client.commands.last!.id
        XCTAssertNotEqual(retry, failedRequest)
        fixture.client.emit(SteamEvent(id: failedRequest, type: "detail", item: item()))
        XCTAssertEqual(fixture.model.operation, "details", "Late responses must not finish a newer request")
        fixture.client.emit(SteamEvent(id: retry, type: "detail", item: item()))

        let outside = WorkshopItem(id: "42", title: "Outside page", description: "", previewURL: nil, kind: nil, size: nil)
        fixture.model.showDetails(outside)
        fixture.client.emit(SteamEvent(id: fixture.client.commands.last!.id, type: "detail", item: outside))
        fixture.model.showDetails(outside)
        XCTAssertEqual(fixture.model.operation, "details")
        let request = fixture.client.commands.last!.id
        fixture.model.showDetails(item())
        XCTAssertEqual(fixture.model.detail, outside, "A cache hit must not replace the selection of an in-flight operation")
        XCTAssertEqual(fixture.client.commands.last!.id, request)
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

    func testSearchPageNumbersUseServerTotalsAndStayWithinSixPages() throws {
        let cases: [(page: Int, total: Int, pageSize: Int?, count: Int?, numbers: [Int])] = [
            (1, 0, 20, 1, [1]),
            (1, 1, 20, 1, [1]),
            (2, 41, 20, 3, [1, 2, 3]),
            (1, 120, 20, 6, [1, 2, 3, 4, 5, 6]),
            (4, 200, 20, 10, [2, 3, 4, 5, 6, 7]),
            (10, 200, 20, 10, [5, 6, 7, 8, 9, 10]),
            (3, 200, nil, nil, [3]),
            (3, 200, 0, nil, [3]),
            (3, 200, -1, nil, [3]),
            (1, -1, 20, 1, [1]),
            (5, 0, 20, 1, [5]),
            (1, Int.max, Int.max, 1, [1]),
            (Int.max, Int.max, 1, Int.max, Array((Int.max - 5)...Int.max)),
            (Int.max / 20, Int.max, 20, Int.max / 20 + 1,
             Array((Int.max / 20 - 4)...(Int.max / 20 + 1)))
        ]
        for value in cases {
            let fixture = try makeFixture()
            authenticate(fixture)
            fixture.model.search(page: value.page)
            fixture.client.emit(SteamEvent(id: fixture.client.commands.last!.id, type: "items", items: [],
                                           total: value.total, page: value.page, pageSize: value.pageSize))

            XCTAssertEqual(fixture.model.pageCount, value.count, "\(value)")
            XCTAssertEqual(fixture.model.pageNumbers, value.numbers, "\(value)")
            XCTAssertEqual(fixture.model.hasNextPage, value.count.map { value.page < $0 } ?? false, "\(value)")
            XCTAssertEqual(fixture.model.total, max(0, value.total))
        }
    }

    func testSearchPageNumbersFallBackToReceivedItemsWhenTotalIsMissing() throws {
        let fixture = try makeFixture()
        authenticate(fixture)
        fixture.model.search()
        fixture.client.emit(SteamEvent(id: fixture.client.commands.last!.id, type: "items", items: [item()], page: 1, pageSize: 20))

        XCTAssertEqual(fixture.model.total, 1)
        XCTAssertEqual(fixture.model.pageCount, 1)
        XCTAssertEqual(fixture.model.pageNumbers, [1])
        XCTAssertFalse(fixture.model.hasNextPage)
    }

    func testSearchPageNumbersChangeOnlyAfterLatestSuccessfulResponse() async throws {
        let fixture = try makeFixture()
        authenticate(fixture)
        fixture.model.search(page: 2)
        fixture.client.emit(SteamEvent(id: fixture.client.commands.last!.id, type: "items", items: [item()], total: 200, page: 2, pageSize: 20))
        fixture.model.search(page: 4)
        let pending = try XCTUnwrap(fixture.client.commands.last)
        fixture.model.genreFilter = "Nature"
        fixture.model.applyFilters()
        XCTAssertEqual(fixture.model.page, 2)
        XCTAssertEqual(fixture.model.pageNumbers, [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(fixture.client.commands.last?.id, pending.id)

        fixture.client.emit(SteamEvent(id: pending.id, type: "items", items: [item()], total: 200, page: 4, pageSize: 20))
        let filtered = try XCTUnwrap(fixture.client.commands.last)
        XCTAssertEqual(filtered.page, 1)
        XCTAssertEqual(filtered.genre, "Nature")
        XCTAssertEqual(fixture.model.page, 2)
        XCTAssertEqual(fixture.model.pageCount, 10)
        fixture.client.emit(SteamEvent(id: filtered.id, type: "items", items: [item()], total: 21, page: 1, pageSize: 20))
        XCTAssertEqual(fixture.model.page, 1)
        XCTAssertEqual(fixture.model.pageCount, 2)
        XCTAssertEqual(fixture.model.pageNumbers, [1, 2])

        fixture.model.search(page: 2)
        fixture.client.emit(SteamEvent(id: fixture.client.commands.last!.id, type: "error", code: "accessdenied"))
        await waitUntil { !fixture.model.isBusy }
        XCTAssertEqual(fixture.model.page, 1)
        XCTAssertEqual(fixture.model.pageNumbers, [1, 2])
        XCTAssertEqual(fixture.model.statusKey, "workshop.error.access")
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

    func testInvalidCompletedProjectKeepsConnectionAndDiscardsStagingForRetry() async throws {
        let fixture = try makeFixture()
        try saveAuthentication(fixture)
        authenticate(fixture)
        fixture.model.download(item())
        let command = try XCTUnwrap(fixture.client.commands.last)
        fixture.client.emit(SteamEvent(id: command.id, type: "completed", itemID: item().id))
        await waitUntil { !fixture.model.isBusy }

        XCTAssertEqual(fixture.model.statusKey, "workshop.error.project")
        XCTAssertEqual(fixture.model.account, "test-account")
        XCTAssertEqual(fixture.client.stopCount, 0)
        XCTAssertEqual(fixture.client.commands.count, 2)
        XCTAssertEqual(fixture.model.retryItem, item())
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(command.directory)))
        XCTAssertTrue(fixture.model.downloads.isEmpty)
        XCTAssertTrue(fixture.library.libraryAssets.isEmpty)
        fixture.model.retryDownload()
        XCTAssertEqual(fixture.client.commands.map(\.command), ["loginQR", "download", "download"])
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
        XCTAssertEqual(fixture.library.status, fixture.library.L("workshop.play.ready"))
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

    private func makeFixture(
        scenePreparer: (@MainActor (WallpaperAsset, @escaping @MainActor (Double) -> Void) async throws -> Void)? = nil
    ) throws -> Fixture {
        let root = try temporaryDirectory()
        let suite = "WorkshopViewModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let player = WorkshopTestPlayer()
        let library = AppViewModel(store: LibraryStore(root: root), loginItemController: WorkshopLoginItems(), wallpaperPlayer: player, userDefaults: defaults, scenePreparer: scenePreparer)
        let client = FakeSteamClient()
        return Fixture(root: root, library: library, model: WorkshopViewModel(library: library, root: root, client: client, userDefaults: defaults), client: client, player: player, defaults: defaults)
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

    private func saveAuthentication(_ fixture: Fixture) throws {
        let credential = fixture.root.appending(path: "Steam/credentials.json")
        try FileManager.default.createDirectory(at: credential.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("synthetic-credentials".utf8).write(to: credential)
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
    var failSend = false
    var stopCount = 0
    var stopWaiter: CheckedContinuation<Void, Never>?
    func send(_ command: SteamCommand) throws {
        commands.append(command)
        if failSend { throw SteamBridgeError.unavailable }
    }
    func emit(_ event: SteamEvent) { onEvent?(event) }
    func stop() async {
        stopCount += 1
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
    func cancelPendingPlayback() { pendingID = nil; handler = nil }
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
    func play(asset: WallpaperAsset, on displayIDs: Set<String>, autoPauseWhenCovered: Bool,
              displayMode: WallpaperDisplayMode, audioEnabled: Bool?, audioVolume: Double?,
              completion: @escaping (Result<Set<String>, Error>) -> Void) throws {
        handler = { [weak self] event in
            switch event {
            case .ready(let id) where id == asset.id:
                self?.handler = nil
                completion(.success(displayIDs))
            case .failed(let id, let message) where id == asset.id:
                self?.handler = nil
                completion(.failure(NSError(domain: "WorkshopTest", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: message])))
            default: break
            }
        }
        try play(asset: asset, autoPauseWhenCovered: autoPauseWhenCovered, displayMode: displayMode,
                 audioEnabled: audioEnabled, audioVolume: audioVolume)
    }
    func stop() { stopCount += 1; cancelPendingPlayback() }
    func setDisplayMode(_ mode: WallpaperDisplayMode) {}
    func setAutoPauseWhenCovered(_ enabled: Bool) {}
}

@MainActor
private final class WorkshopLoginItems: LoginItemManaging {
    var isEnabled: Bool { false }
    func setEnabled(_ enabled: Bool) throws {}
    func openSystemSettings() {}
}
