import Foundation
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

    func testDownloadImportAndApplyAreThreeSeparateActions() async throws {
        let fixture = try makeFixture()
        let download = try await completeDownload(fixture)
        XCTAssertEqual(fixture.model.downloads.map(\.id), [download.id])
        XCTAssertTrue(fixture.library.libraryAssets.isEmpty)
        XCTAssertNil(fixture.player.playedID)
        XCTAssertEqual(fixture.model.selectedAsset?.supportStatus, .playable)

        fixture.model.importSelected()
        XCTAssertTrue(fixture.model.isBusy)
        fixture.model.removeDownloaded(download)
        fixture.model.download(item())
        XCTAssertTrue(FileManager.default.fileExists(atPath: download.directory))
        await waitUntil { !fixture.model.isBusy }
        XCTAssertEqual(fixture.library.libraryAssets.map(\.id), [download.id])
        XCTAssertNil(fixture.player.playedID)
        fixture.model.applySelected()
        XCTAssertEqual(fixture.player.playedID, download.id)
        XCTAssertEqual(fixture.model.statusKey, "workshop.play.requested")
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
        _ = try await completeDownload(fixture)
        fixture.library.isWorking = true
        fixture.model.importSelected()
        XCTAssertFalse(fixture.model.isBusy)
        XCTAssertTrue(fixture.library.libraryAssets.isEmpty)
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
    }

    private func makeFixture() throws -> Fixture {
        let root = try temporaryDirectory()
        let suite = "WorkshopViewModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let player = WorkshopTestPlayer()
        let library = AppViewModel(store: LibraryStore(root: root), loginItemController: WorkshopLoginItems(), wallpaperPlayer: player, userDefaults: defaults)
        let client = FakeSteamClient()
        return Fixture(root: root, library: library, model: WorkshopViewModel(library: library, root: root, client: client), client: client, player: player)
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

    private func completeDownload(_ fixture: Fixture) async throws -> WorkshopDownload {
        authenticate(fixture)
        fixture.model.download(item())
        let command = try XCTUnwrap(fixture.client.commands.last)
        let directory = URL(filePath: try XCTUnwrap(command.directory))
        try Data(#"{"title":"Fixture","type":"web","file":"index.html"}"#.utf8).write(to: directory.appending(path: "project.json"))
        try Data("<html>Local fixture</html>".utf8).write(to: directory.appending(path: "index.html"))
        fixture.client.emit(SteamEvent(id: command.id, type: "completed", itemID: item().id))
        await waitUntil { !fixture.model.isBusy && fixture.model.selectedAsset != nil }
        return try XCTUnwrap(fixture.model.selectedDownload)
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
    func play(asset: WallpaperAsset, autoPauseWhenCovered: Bool, displayMode: WallpaperDisplayMode, audioEnabled: Bool?, audioVolume: Double?) throws { playedID = asset.id }
    func stop() {}
    func setDisplayMode(_ mode: WallpaperDisplayMode) {}
    func setAutoPauseWhenCovered(_ enabled: Bool) {}
}

@MainActor
private final class WorkshopLoginItems: LoginItemManaging {
    var isEnabled: Bool { false }
    func setEnabled(_ enabled: Bool) throws {}
    func openSystemSettings() {}
}
