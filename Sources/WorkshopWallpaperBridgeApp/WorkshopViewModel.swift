import Foundation
import Combine
import WorkshopWallpaperCore

@MainActor
final class WorkshopViewModel: ObservableObject {
    @Published private(set) var account: String?
    @Published private(set) var hasSavedSession = false
    @Published private(set) var operation: String?
    @Published private(set) var statusKey = "workshop.ready"
    @Published private(set) var qrURL: String?
    @Published private(set) var authPrompt: String?
    @Published private(set) var items: [WorkshopItem] = []
    @Published private(set) var detail: WorkshopItem?
    @Published private(set) var page = 1
    @Published private(set) var total = 0
    @Published private(set) var pageCount: Int?
    @Published private(set) var hasNextPage = false
    @Published private(set) var completedBytes: UInt64 = 0
    @Published private(set) var totalBytes: UInt64 = 0
    @Published private(set) var downloads: [WorkshopDownload] = []
    @Published private(set) var selectedDownloadID: String?
    @Published private(set) var selectedAsset: WallpaperAsset?
    @Published private(set) var retryItem: WorkshopItem?
    @Published var query = ""
    @Published var sort = "popular"
    @Published var kindFilter = "all"
    @Published var genreFilter = ""
    @Published var pendingRemoval: WorkshopDownload?

    private weak var library: AppViewModel?
    private let client: SteamHelperTransport
    private let storage: WorkshopDownloads
    private let authentication: SteamAuthenticationStorage
    private var requestID: String?
    private var downloading: WorkshopItem?
    private var staging: URL?
    private var stopping = false
    private var applicationIntent: UUID?
    private var downloadIntent: UUID?
    private var pendingSelectionID: String?
    private var pendingSearch: SteamCommand?
    private var requestedPlaybackID: String?
    private var playbackObservation: AnyCancellable?

    init(library: AppViewModel, root: URL, client: SteamHelperTransport? = nil) {
        self.library = library
        storage = WorkshopDownloads(root: root.appending(path: "WorkshopDownloads"))
        authentication = SteamAuthenticationStorage(directory: root.appending(path: "Steam"))
        self.client = client ?? SteamHelperClient(authenticationDirectory: authentication.directory)
        self.client.onEvent = { [weak self] event in self?.receive(event) }
        self.client.onExit = { [weak self] in self?.helperExited() }
        hasSavedSession = authentication.hasSavedSession
        refreshDownloads()
        playbackObservation = library.$playbackEvent.sink { [weak self] event in
            guard let self, let event, let id = requestedPlaybackID, selectedDownloadID == id else { return }
            switch event {
            case .ready(let assetID) where assetID == id:
                statusKey = "workshop.play.ready"
            case .failed(let assetID, _) where assetID == id:
                statusKey = "workshop.error.play"
            default: break
            }
        }
    }

    var pageNumbers: [Int] {
        guard let pageCount, page <= pageCount else { return [page] }
        let count = min(6, pageCount)
        let start = min(max(1, page - 2), pageCount - count + 1)
        return Array(start...(start + (count - 1)))
    }

    var isBusy: Bool { operation != nil }
    var isAuthenticated: Bool { account != nil }
    var hasStoredAuthentication: Bool { authentication.hasStoredAuthentication }
    var canCancel: Bool { (requestID != nil || applicationIntent != nil) && !stopping }
    var selectedDownload: WorkshopDownload? { downloads.first { $0.id == selectedDownloadID } }
    var libraryAsset: WallpaperAsset? {
        guard let id = selectedDownloadID else { return nil }
        return library?.libraryAssets.first { $0.id == id }
    }

    func loginQR() { begin(SteamCommand(id: UUID().uuidString, command: "loginQR"), operation: "login") }

    func login(username: String, password: String) {
        guard !username.trimmingCharacters(in: .whitespaces).isEmpty, !password.isEmpty else { return }
        begin(SteamCommand(id: UUID().uuidString, command: "loginPassword", username: username, password: password), operation: "login")
    }

    func resume() { begin(SteamCommand(id: UUID().uuidString, command: "resume"), operation: "login") }

    func submitGuard(_ code: String) {
        guard let id = requestID, operation == "login", !code.isEmpty else { return }
        do {
            try client.send(SteamCommand(id: id, command: "guard", code: code))
            authPrompt = nil
            statusKey = "workshop.auth.waiting"
        } catch { fail("workshop.error.connection") }
    }

    func search(page: Int = 1) {
        guard isAuthenticated, page > 0 else { return }
        let command = SteamCommand(id: UUID().uuidString, command: "search", query: query, page: page,
                                   sort: sort, kind: kindFilter, genre: genreFilter)
        // Serialize helper requests, keeping only the latest requested page/filter combination.
        if operation == "search" {
            pendingSearch = command
        } else {
            begin(command, operation: "search")
        }
    }

    func applyFilters() {
        search(page: 1)
    }

    func showDetails(_ item: WorkshopItem) {
        guard isAuthenticated, Self.validID(item.id) else { return }
        if !isBusy { detail = item }
        begin(SteamCommand(id: UUID().uuidString, command: "details", itemID: item.id), operation: "details")
    }

    func download(_ item: WorkshopItem) {
        guard !isBusy, isAuthenticated, Self.validID(item.id) else { return }
        guard !downloads.contains(where: { $0.id == item.id }) else {
            selectDownload(item.id)
            return
        }
        do {
            let directory = try storage.begin(itemID: item.id)
            requestedPlaybackID = nil
            applicationIntent = library?.beginApplicationIntent()
            downloadIntent = applicationIntent
            staging = directory
            downloading = item
            retryItem = nil
            completedBytes = 0
            totalBytes = 0
            begin(SteamCommand(id: UUID().uuidString, command: "download", itemID: item.id, directory: directory.path), operation: "download")
        } catch { statusKey = "workshop.error.storage" }
    }

    func retryDownload() {
        guard let retryItem else { return }
        download(retryItem)
    }

    func cancel() {
        guard canCancel else { return }
        library?.beginApplicationIntent()
        applicationIntent = nil
        requestedPlaybackID = nil
        pendingSelectionID = nil
        if ["finalizing", "inspecting", "importing"].contains(operation) {
            // Let the current file operation finish before releasing its write/delete gate.
            statusKey = "workshop.cancelled"
        } else {
            stop(status: "workshop.cancelled", deleteCredentials: false)
        }
    }

    func logout() {
        guard !isBusy else { return }
        stop(status: "workshop.loggedOut", deleteCredentials: false)
    }

    func deleteSavedAuthentication() {
        guard !isBusy else { return }
        stop(status: "workshop.auth.deleted", deleteCredentials: true)
    }

    private func begin(_ command: SteamCommand, operation: String) {
        guard !isBusy else { return }
        self.operation = operation
        requestID = command.id
        statusKey = "workshop.working.\(operation)"
        qrURL = nil
        authPrompt = nil
        do { try client.send(command) }
        catch { fail("workshop.error.helper") }
    }

    private func receive(_ event: SteamEvent) {
        if event.type == "disconnected" {
            // A new login closes any preceding connection before authenticating.
            if operation != "login" { helperExited() }
            return
        }
        guard event.id == requestID, !stopping else { return }
        switch event.type {
        case "qr" where operation == "login":
            guard let value = event.url, let url = URL(string: value),
                  url.scheme == "https", url.host == "s.team" else {
                fail("workshop.error.protocol")
                return
            }
            qrURL = value
            statusKey = "workshop.auth.scan"
        case "authPrompt" where operation == "login":
            guard let prompt = event.prompt, ["emailCode", "twoFactor", "mobileApproval"].contains(prompt) else {
                fail("workshop.error.authentication")
                return
            }
            authPrompt = prompt
            statusKey = "workshop.auth.\(prompt)"
        case "authenticated" where operation == "login":
            guard let account = event.account, !account.isEmpty else {
                fail("workshop.error.protocol")
                return
            }
            self.account = account
            finishRequest(status: "workshop.auth.connected")
            hasSavedSession = authentication.hasSavedSession
        case "items" where operation == "search":
            guard let items = event.items, let page = event.page, page > 0,
                  items.allSatisfy({ Self.validID($0.id) }) else {
                fail("workshop.error.protocol")
                return
            }
            if let command = pendingSearch {
                pendingSearch = nil
                finishRequest(status: "workshop.search.finished")
                begin(command, operation: "search")
                return
            }
            self.items = items
            self.page = page
            total = max(0, event.total ?? items.count)
            if let pageSize = event.pageSize, pageSize > 0 {
                pageCount = total > 0 ? (total - 1) / pageSize + 1 : 1
            } else {
                pageCount = nil
            }
            hasNextPage = pageCount.map { page < $0 } ?? false
            finishRequest(status: items.isEmpty ? "workshop.search.empty" : "workshop.search.finished")
        case "detail" where operation == "details":
            guard let item = event.item, item.id == detail?.id else {
                fail("workshop.error.protocol")
                return
            }
            detail = item
            finishRequest(status: "workshop.detail.ready")
        case "progress" where operation == "download":
            completedBytes = event.completed ?? 0
            totalBytes = UInt64(max(0, event.total ?? 0))
        case "completed" where operation == "download":
            guard let item = downloading, event.itemID == item.id, let staging else {
                fail("workshop.error.protocol")
                return
            }
            requestID = nil
            operation = "finalizing"
            let storage = self.storage
            let intent = downloadIntent
            Task {
                do {
                    let downloaded = try await Task.detached {
                        try storage.finish(itemID: item.id, title: item.title, staging: staging)
                    }.value
                    self.staging = nil
                    downloading = nil
                    downloadIntent = nil
                    refreshDownloads()
                    if statusKey == "workshop.working.download" { statusKey = "workshop.download.finished" }
                    if let intent, isCurrentIntent(intent) {
                        selectedDownloadID = downloaded.id
                        selectedAsset = nil
                        statusKey = "workshop.download.finished"
                        await inspectAndApply(downloaded, intent: intent)
                    }
                    finishApplication()
                } catch { fail("workshop.error.project") }
            }
        case "error":
            fail(Self.errorKey(event.code))
        default:
            fail("workshop.error.protocol")
        }
    }

    private func finishRequest(status: String) {
        requestID = nil
        operation = nil
        qrURL = nil
        authPrompt = nil
        statusKey = status
    }

    private func fail(_ key: String) {
        stop(status: key, deleteCredentials: false)
    }

    private func helperExited() {
        account = nil
        qrURL = nil
        authPrompt = nil
        hasSavedSession = authentication.hasSavedSession
        if !stopping {
            if requestID != nil { fail("workshop.error.connection") }
            else if operation == nil { statusKey = "workshop.disconnected" }
        }
    }

    private func stop(status: String, deleteCredentials: Bool) {
        guard !stopping else { return }
        stopping = true
        applicationIntent = nil
        downloadIntent = nil
        pendingSelectionID = nil
        pendingSearch = nil
        requestID = nil
        operation = "stopping"
        qrURL = nil
        authPrompt = nil
        retryItem = downloading ?? retryItem
        Task {
            await client.stop()
            account = nil
            var finalStatus = status
            if let staging {
                do { try storage.discard(staging: staging) }
                catch { finalStatus = "workshop.error.cleanup" }
            }
            staging = nil
            downloading = nil
            if deleteCredentials {
                do { try authentication.deleteSavedSession() }
                catch { finalStatus = "workshop.error.credentials" }
            }
            hasSavedSession = authentication.hasSavedSession
            stopping = false
            finishRequest(status: finalStatus)
        }
    }

    func selectDownload(_ id: String) {
        guard let download = downloads.first(where: { $0.id == id }), !stopping else { return }
        guard !isBusy || ["download", "finalizing", "inspecting", "importing"].contains(operation) else { return }
        requestedPlaybackID = nil
        applicationIntent = library?.beginApplicationIntent()
        selectedDownloadID = id
        selectedAsset = nil
        if isBusy {
            pendingSelectionID = id
            return
        }
        guard let intent = applicationIntent else { return }
        operation = "inspecting"
        Task {
            await inspectAndApply(download, intent: intent)
            finishApplication()
        }
    }

    private func isCurrentIntent(_ intent: UUID) -> Bool {
        applicationIntent == intent && library?.applicationIntentID == intent
    }

    private func inspectAndApply(_ download: WorkshopDownload, intent: UUID) async {
        operation = "inspecting"
        let storage = self.storage
        let asset: WallpaperAsset
        do { asset = try await Task.detached { try storage.scan(download) }.value }
        catch {
            if isCurrentIntent(intent) { statusKey = "workshop.error.project" }
            return
        }
        guard isCurrentIntent(intent), let library else { return }
        selectedAsset = asset
        guard !library.isWorking else {
            statusKey = "workshop.error.busy"
            return
        }
        operation = "importing"
        do {
            let imported = try await library.importAssets([asset], preservingExisting: true)
            guard isCurrentIntent(intent), let retained = imported.first else { return }
            guard retained.supportStatus == .playable else {
                statusKey = "workshop.play.unsupported"
                return
            }
            // Synchronous acceptance is not evidence that asynchronous rendering succeeded.
            requestPlayback(retained.id, library: library)
        } catch {
            if isCurrentIntent(intent) {
                statusKey = (error as? SteamBridgeError) == .busy ? "workshop.error.busy" : "workshop.error.import"
            }
        }
    }

    private func finishApplication() {
        let id = applicationIntent == library?.applicationIntentID ? pendingSelectionID : nil
        pendingSelectionID = nil
        operation = nil
        applicationIntent = nil
        if let id { selectDownload(id) }
    }

    func importSelected() {
        guard !isBusy, let id = selectedDownloadID else { return }
        selectDownload(id)
    }

    func applySelected() {
        guard !isBusy, let asset = libraryAsset, let library else { return }
        guard asset.supportStatus == .playable else {
            statusKey = "workshop.play.unsupported"
            return
        }
        guard !library.isWorking else {
            statusKey = "workshop.error.busy"
            return
        }
        requestPlayback(asset.id, library: library)
    }

    private func requestPlayback(_ id: String, library: AppViewModel) {
        requestedPlaybackID = id
        statusKey = "workshop.play.requested"
        if !library.selectAndApplyLibraryAsset(id) {
            requestedPlaybackID = nil
            statusKey = "workshop.error.play"
        }
    }

    func removeDownloaded(_ download: WorkshopDownload) {
        guard !isBusy else { return }
        pendingRemoval = nil
        do {
            try storage.remove(download)
            if selectedDownloadID == download.id {
                selectedDownloadID = nil
                selectedAsset = nil
            }
            refreshDownloads()
            statusKey = "workshop.download.removed"
        } catch { statusKey = "workshop.error.storage" }
    }

    private func refreshDownloads() {
        do { downloads = try storage.load() }
        catch { statusKey = "workshop.error.storage" }
    }

    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) } && UInt64(value).map { $0 > 0 } == true
    }

    private static func errorKey(_ code: String?) -> String {
        switch code?.lowercased() {
        case "accessdenied", "license", "ownership", "access_denied": "workshop.error.access"
        case "authentication", "invalidpassword", "expired", "revoked", "auth_failed",
             "authenticationrequired", "authenticationfailed", "credentialsunavailable": "workshop.error.authentication"
        case "wrong_app", "wrongapp", "unsupported", "collection": "workshop.error.unsupported"
        case "unsafe_path", "unsafepath", "path", "credentialstoragefailed": "workshop.error.storage"
        case "missingmanifest", "integrityfailed", "downloadfailed": "workshop.error.project"
        default: "workshop.error.connection"
        }
    }
}
