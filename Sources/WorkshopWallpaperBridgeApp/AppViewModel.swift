import AppKit
import Foundation
import Combine
import UniformTypeIdentifiers
import WorkshopWallpaperCore

struct UpdateAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Drives the "Remove" confirmation dialog: holds the assets awaiting the
/// user's confirmation before `AppViewModel.removeSelectedLibraryAssets()`
/// actually moves their library folders to the Trash.
struct PendingLibraryRemoval: Identifiable {
    let id = UUID()
    let assetIds: Set<WallpaperAsset.ID>
    let title: String
}

struct ImportProgress: Equatable {
    let completed: Int
    let total: Int
    var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
}

enum ScannedAssetSortOrder: String, CaseIterable, Identifiable {
    case dateAdded
    case name

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dateAdded:
            "Date Added"
        case .name:
            "Name"
        }
    }
}

@MainActor
protocol WallpaperPlaying: AnyObject {
    func play(
        asset: WallpaperAsset,
        autoPauseWhenCovered: Bool,
        displayMode: WallpaperDisplayMode,
        audioEnabled: Bool?,
        audioVolume: Double?
    ) throws
    func play(asset: WallpaperAsset, on displayIDs: Set<String>, autoPauseWhenCovered: Bool,
              displayMode: WallpaperDisplayMode, audioEnabled: Bool?, audioVolume: Double?) throws
    func stop(on displayIDs: Set<String>)
    func setDisplayMode(_ mode: WallpaperDisplayMode, on displayIDs: Set<String>)
    func setAudioSettings(enabled: Bool, volume: Double)
    func stop()
    func setDisplayMode(_ mode: WallpaperDisplayMode)
    func setAutoPauseWhenCovered(_ enabled: Bool)
    func setInteractionEnabled(_ enabled: Bool)
    func setPlaybackStatusHandler(_ handler: @escaping (WallpaperPlaybackEvent) -> Void)
    func cancelPendingPlayback()
    func cancelPendingPlayback(on displayIDs: Set<String>)
    func play(asset: WallpaperAsset, on displayIDs: Set<String>, autoPauseWhenCovered: Bool,
              displayMode: WallpaperDisplayMode, audioEnabled: Bool?, audioVolume: Double?,
              completion: @escaping (Result<Set<String>, Error>) -> Void) throws
}

extension WallpaperPlaying {
    func setInteractionEnabled(_ enabled: Bool) {}
    func setAudioSettings(enabled: Bool, volume: Double) {}
    func play(asset: WallpaperAsset, on displayIDs: Set<String>, autoPauseWhenCovered: Bool,
              displayMode: WallpaperDisplayMode, audioEnabled: Bool?, audioVolume: Double?) throws {
        try play(asset: asset, autoPauseWhenCovered: autoPauseWhenCovered, displayMode: displayMode,
                 audioEnabled: audioEnabled, audioVolume: audioVolume)
    }
    func stop(on displayIDs: Set<String>) {
        if !displayIDs.isEmpty { stop() }
    }
    func setDisplayMode(_ mode: WallpaperDisplayMode, on displayIDs: Set<String>) { setDisplayMode(mode) }
    func setPlaybackStatusHandler(_ handler: @escaping (WallpaperPlaybackEvent) -> Void) {}
    func cancelPendingPlayback() {}
    func cancelPendingPlayback(on displayIDs: Set<String>) {
        if !displayIDs.isEmpty { cancelPendingPlayback() }
    }
    func play(asset: WallpaperAsset, on displayIDs: Set<String>, autoPauseWhenCovered: Bool,
              displayMode: WallpaperDisplayMode, audioEnabled: Bool?, audioVolume: Double?,
              completion: @escaping (Result<Set<String>, Error>) -> Void) throws {
        try play(asset: asset, on: displayIDs, autoPauseWhenCovered: autoPauseWhenCovered,
                 displayMode: displayMode, audioEnabled: audioEnabled, audioVolume: audioVolume)
        completion(.success(displayIDs))
    }
}

extension WallpaperPlayer: WallpaperPlaying {}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var sourcePath = ""
    @Published var scannedAssets: [WallpaperAsset] = []
    @Published var libraryAssets: [WallpaperAsset] = []
    @Published private(set) var selectedScannedAssetIds: Set<WallpaperAsset.ID> = []
    @Published private(set) var selectedLibraryAssetIds: Set<WallpaperAsset.ID> = []
    @Published var status = "Choose a copied Wallpaper Engine Workshop folder to begin."
    @Published var isWorking = false
    @Published private(set) var activeWallpaperAssetID: String?
    @Published private(set) var playbackEvent: WallpaperPlaybackEvent?
    @Published private(set) var sceneAssetsDirectory = ""
    /// Bumped whenever a scene's background video render completes. Library
    /// rows read this alongside the asset itself so their body actually
    /// re-evaluates: SwiftUI skips re-invoking a child view's body when its
    /// input properties are structurally unchanged, even if the enclosing
    /// `@ObservedObject` published an unrelated change (e.g. `status`), so
    /// without this the "renders on first play" badge never flips to
    /// "playable" until something else forces the asset itself to change.
    @Published private(set) var sceneVideoRenderRevision = 0
    @Published var pendingLibraryRemoval: PendingLibraryRemoval?
    @Published private(set) var importProgress: ImportProgress?
    @Published private(set) var connectedDisplays: [WallpaperDisplay] = []
    @Published private(set) var displayAssignments: [String: DisplayWallpaperAssignment] = [:]
    @Published var selectedDisplayID = "" {
        didSet {
            if selectedDisplayID != oldValue { beginApplicationIntent() }
        }
    }
    private var displayObservation: AnyCancellable?
    private var displaysProvider: () -> [WallpaperDisplay] = { WallpaperDisplay.connected() }
    private var restoringPreferences = false
    private(set) var rotationDisplayIDs: Set<String> = []

    var selectedDisplayIDs: Set<String> {
        selectedDisplayID.isEmpty ? Set(connectedDisplays.map(\.id)) : [selectedDisplayID]
    }

    var selectedDisplayMode: WallpaperDisplayMode? {
        let modes = selectedDisplayIDs.map { displayAssignments[$0]?.displayMode ?? displayMode }
        guard let first = modes.first, modes.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    func applySelectedDisplayMode(_ mode: WallpaperDisplayMode?) {
        guard let mode else { return }
        displayMode = mode
    }

    func identifyDisplays() { DisplayIdentification.shared.show(displays: connectedDisplays) }

    @Published var displayMode: WallpaperDisplayMode = .fit {
        didSet {
            guard !restoringPreferences else { return }
            wallpaperPlayer.setDisplayMode(displayMode, on: selectedDisplayIDs)
            for id in selectedDisplayIDs {
                if displayAssignments[id] == nil {
                    displayAssignments[id] = DisplayWallpaperAssignment(assetID: nil, displayMode: displayMode, isPlaying: false)
                } else {
                    displayAssignments[id]?.displayMode = displayMode
                }
            }
            saveDisplayAssignments()
            userDefaults.set(displayMode.rawValue, forKey: PreferenceKey.displayMode)
            if lockScreenAnimationEnabled, let asset = lastActiveWallpaper {
                _ = refreshLockScreenAnimationConfiguration(asset: asset)
            }
        }
    }
    @Published var autoPauseWhenCovered = false {
        didSet {
            wallpaperPlayer.setAutoPauseWhenCovered(autoPauseWhenCovered)
            userDefaults.set(autoPauseWhenCovered, forKey: PreferenceKey.autoPauseWhenCovered)
        }
    }
    /// Opt in once, then retain the user's choice across app launches.
    @Published var wallpaperInteractionEnabled = false {
        didSet {
            wallpaperPlayer.setInteractionEnabled(wallpaperInteractionEnabled)
            userDefaults.set(wallpaperInteractionEnabled, forKey: PreferenceKey.wallpaperInteractionEnabled)
        }
    }
    @Published var preferLiveScenes = true {
        didSet {
            SceneWallpaperContentFactory.prefersLivePlayback = preferLiveScenes
            userDefaults.set(preferLiveScenes, forKey: PreferenceKey.preferLiveScenes)
        }
    }
    @Published var audioReactiveEnabled = false {
        didSet {
            SystemAudioAnalysis.shared.setEnabled(audioReactiveEnabled)
            userDefaults.set(audioReactiveEnabled, forKey: PreferenceKey.audioReactiveEnabled)
        }
    }
    @Published var mediaIntegrationEnabled = false {
        didSet {
            MusicMetadataSource.shared.setEnabled(mediaIntegrationEnabled)
            userDefaults.set(mediaIntegrationEnabled, forKey: PreferenceKey.mediaIntegrationEnabled)
        }
    }
    /// Existing users retain silent playback until they opt in.
    @Published var wallpaperAudioEnabled = false {
        didSet {
            wallpaperPlayer.setAudioSettings(enabled: wallpaperAudioEnabled, volume: wallpaperAudioVolume)
            userDefaults.set(wallpaperAudioEnabled, forKey: PreferenceKey.wallpaperAudioEnabled)
        }
    }
    @Published var wallpaperAudioVolume = 0.5 {
        didSet {
            wallpaperPlayer.setAudioSettings(enabled: wallpaperAudioEnabled, volume: wallpaperAudioVolume)
            userDefaults.set(wallpaperAudioVolume, forKey: PreferenceKey.wallpaperAudioVolume)
        }
    }
    @Published var lockScreenAnimationEnabled = false {
        didSet {
            guard !isSyncingLockScreenAnimation, lockScreenAnimationEnabled != oldValue else {
                return
            }
            setLockScreenAnimation(lockScreenAnimationEnabled)
        }
    }
    /// macOS 26+: the bundled wallpaper extension plays the wallpaper as the system
    /// wallpaper, so it keeps moving while macOS hides windows (dragging a widget).
    @Published var systemWallpaperEnabled = false {
        didSet {
            guard systemWallpaperEnabled != oldValue, !isSyncingSystemWallpaperPreference else { return }
            userDefaults.set(systemWallpaperEnabled, forKey: PreferenceKey.systemWallpaperEnabled)
            scheduleSystemWallpaperSync()
        }
    }
    /// Displays the extension draws now; the app draws no window there.
    @Published private(set) var systemWallpaperDisplays: Set<String> = []
    @Published var automaticallyCheckForUpdates = true {
        didSet {
            guard automaticallyCheckForUpdates != oldValue else {
                return
            }
            userDefaults.set(automaticallyCheckForUpdates, forKey: PreferenceKey.automaticallyCheckForUpdates)
            if automaticallyCheckForUpdates {
                scheduleAutomaticUpdateCheck(force: true)
            }
        }
    }
    @Published private(set) var isCheckingForUpdates = false
    @Published private(set) var availableUpdate: UpdateRelease?
    @Published var updateAlert: UpdateAlert?
    @Published var launchAtLogin = false {
        didSet {
            guard !isSyncingLaunchAtLogin, launchAtLogin != oldValue else {
                return
            }
            setLaunchAtLogin(launchAtLogin)
        }
    }
    @Published var language: AppLanguage = .system {
        didSet {
            guard language != oldValue else {
                return
            }
            userDefaults.set(language.rawValue, forKey: PreferenceKey.language)
        }
    }

    @Published var rotationEnabled = false {
        didSet {
            guard !isSyncingRotation, rotationEnabled != oldValue else {
                return
            }
            if rotationEnabled {
                startRotation()
            } else {
                disableRotation(status: "Rotation stopped.")
            }
        }
    }
    @Published var rotationShuffle = false {
        didSet {
            guard rotationShuffle != oldValue else {
                return
            }
            userDefaults.set(rotationShuffle, forKey: PreferenceKey.rotationShuffle)
            if rotationEnabled {
                buildRotationQueue()
            }
        }
    }
    @Published var rotationInterval: TimeInterval = 300 {
        didSet {
            guard rotationInterval != oldValue else {
                return
            }
            userDefaults.set(rotationInterval, forKey: PreferenceKey.rotationInterval)
            if rotationEnabled {
                restartRotationTimer()
            }
        }
    }
    @Published var scannedSortOrder: ScannedAssetSortOrder = .dateAdded {
        didSet {
            guard scannedSortOrder != oldValue else {
                return
            }
            userDefaults.set(scannedSortOrder.rawValue, forKey: PreferenceKey.scannedSortOrder)
            sortScannedAssets()
        }
    }

    lazy var workshop = WorkshopViewModel(library: self, root: store.root, userDefaults: userDefaults)
    weak var activeWorkshop: WorkshopViewModel?

    private let scanner = WallpaperScanner()
    private let converter = VideoConverter()
    private let systemWallpaperSetter = SystemWallpaperSetter()
    private let store: LibraryStore
    private let loginItemController: LoginItemManaging
    private let lockScreenAnimationController: LockScreenAnimationManaging
    private let userDefaults: UserDefaults
    private let updateChecker: UpdateChecking
    private let updateURLOpener: UpdateURLOpening
    private let wallpaperPlayer: WallpaperPlaying
    private let scenePreparer: (@MainActor (WallpaperAsset, @escaping @MainActor (Double) -> Void) async throws -> Void)?
    private var preparingWorkshopAssets: [String: Int] = [:]
    private let currentVersionProvider: () -> String
    private var isSyncingLaunchAtLogin = false
    private var isSyncingLockScreenAnimation = false
    private var isSyncingSystemWallpaperPreference = false
    private lazy var systemWallpaperMode = SystemWallpaperMode()
    private var systemWallpaperSyncTask: Task<Void, Never>?
    private var systemWallpaperSyncAgain = false
    private var isSyncingRotation = false
    private var rotationTimer: Timer?
    private var rotationQueue: [WallpaperAsset.ID] = []
    private var rotationIndex = 0
    private(set) var applicationIntentID = UUID()
    private var requestedPlayback: [String: (asset: WallpaperAsset, requestID: UUID)] = [:]

    @discardableResult
    func beginApplicationIntent() -> UUID {
        applicationIntentID = UUID()
        for id in selectedDisplayIDs { requestedPlayback[id] = nil }
        SceneWallpaperContentFactory.cancelWorkshopPreparations()
        wallpaperPlayer.cancelPendingPlayback(on: selectedDisplayIDs)
        return applicationIntentID
    }

    init() {
        userDefaults = .standard
        loginItemController = LoginItemController()
        lockScreenAnimationController = LockScreenAnimationController()
        updateChecker = GitHubReleaseUpdateChecker()
        updateURLOpener = WorkspaceUpdateURLOpener()
        wallpaperPlayer = WallpaperPlayer.shared
        scenePreparer = nil
        currentVersionProvider = { AppVersionProvider.currentVersion() }
        do {
            store = try LibraryStore.defaultStore()
            configureDisplays()
            restorePreferences()
            loadLibrary()
            playLastWallpaperIfAvailable()
            restoreLockScreenAnimationIfNeeded()
            restoreRotationIfNeeded()
        } catch {
            store = LibraryStore(
                root: FileManager.default.temporaryDirectory.appending(path: "WorkshopWallpaperBridge")
            )
            configureDisplays()
            status = error.localizedDescription
        }
        syncLaunchAtLoginStatus()
        scheduleAutomaticUpdateCheck()
        SceneWallpaperContentFactory.statusHandler = { [weak self] message in
            self?.status = message
        }
        SceneWallpaperContentFactory.sceneVideoRenderCompletionHandler = { [weak self] assetId in
            self?.handleSceneVideoRenderCompletion(assetId: assetId)
        }
    }

    init(
        store: LibraryStore,
        loginItemController: LoginItemManaging = LoginItemController(),
        lockScreenAnimationController: LockScreenAnimationManaging = LockScreenAnimationController(),
        updateChecker: UpdateChecking = DisabledUpdateChecker(),
        updateURLOpener: UpdateURLOpening = WorkspaceUpdateURLOpener(),
        wallpaperPlayer: WallpaperPlaying = WallpaperPlayer.shared,
        currentVersionProvider: @escaping () -> String = { "0.0.0" },
        userDefaults: UserDefaults = .standard,
        displaysProvider: @escaping () -> [WallpaperDisplay] = { WallpaperDisplay.connected() },
        scenePreparer: (@MainActor (WallpaperAsset, @escaping @MainActor (Double) -> Void) async throws -> Void)? = nil
    ) {
        self.store = store
        self.loginItemController = loginItemController
        self.lockScreenAnimationController = lockScreenAnimationController
        self.updateChecker = updateChecker
        self.updateURLOpener = updateURLOpener
        self.wallpaperPlayer = wallpaperPlayer
        self.scenePreparer = scenePreparer
        self.currentVersionProvider = currentVersionProvider
        self.userDefaults = userDefaults
        self.displaysProvider = displaysProvider
        configureDisplays()
        restorePreferences()
        loadLibrary()
        playLastWallpaperIfAvailable()
        restoreLockScreenAnimationIfNeeded()
        restoreRotationIfNeeded()
        syncLaunchAtLoginStatus()
    }

    var selectedScannedAsset: WallpaperAsset? {
        selectedScannedAssets.first
    }

    var selectedScannedAssetId: WallpaperAsset.ID? {
        get {
            selectedScannedAsset?.id
        }
        set {
            selectedScannedAssetIds = newValue.map { Set([$0]) } ?? []
        }
    }

    var selectedScannedAssetCount: Int {
        selectedScannedAssets.count
    }

    var selectedScannedAssets: [WallpaperAsset] {
        scannedAssets.filter { selectedScannedAssetIds.contains($0.id) }
    }

    var selectedLibraryAsset: WallpaperAsset? {
        libraryAssets.first { selectedLibraryAssetIds.contains($0.id) }
    }

    var selectedLibraryAssetId: WallpaperAsset.ID? {
        get {
            selectedLibraryAsset?.id
        }
        set {
            beginApplicationIntent()
            selectedLibraryAssetIds = newValue.map { Set([$0]) } ?? []
        }
    }

    var selectedLibraryAssetCount: Int {
        selectedLibraryAssets.count
    }

    var selectedLibraryAssets: [WallpaperAsset] {
        libraryAssets.filter { selectedLibraryAssetIds.contains($0.id) }
    }

    var sceneAssetsStatus: String {
        if let envPath = ProcessInfo.processInfo.environment[SceneEngineRendererConfiguration.assetsEnvironmentVariableName],
           !envPath.isEmpty {
            let envURL = URL(filePath: envPath).standardizedFileURL
            return SceneEngineRendererConfiguration.isValidAssetsDirectory(envURL)
                ? String(format: L("settings.scene.status.envReady"), envURL.path)
                : L("settings.scene.status.envIncomplete")
        }
        guard !sceneAssetsDirectory.isEmpty else {
            return L("settings.scene.status.unset")
        }
        let url = URL(filePath: sceneAssetsDirectory).standardizedFileURL
        return SceneEngineRendererConfiguration.isValidAssetsDirectory(url)
            ? String(format: L("settings.scene.status.ready"), url.path)
            : String(format: L("settings.scene.status.incomplete"), url.path)
    }

    @discardableResult
    func selectAndApplyLibraryAsset(_ id: String) -> Bool {
        selectLibraryAssets([id])
        guard !isWorking, let asset = selectedLibraryAsset, asset.supportStatus == .playable else {
            status = L(isWorking ? "workshop.error.busy" : "workshop.play.unsupported")
            return false
        }
        return playSelected()
    }

    func selectLibraryAssets(_ ids: Set<WallpaperAsset.ID>) {
        beginApplicationIntent()
        selectedLibraryAssetIds = ids
        normalizeLibrarySelection(allowEmpty: true)
    }

    func selectScannedAssets(_ ids: Set<WallpaperAsset.ID>) {
        selectedScannedAssetIds = ids
        normalizeScannedSelection(allowEmpty: true)
    }

    /// Looks up a localized UI chrome string for the currently selected
    /// `language`. Views observe `language` via `@ObservedObject`, so calling
    /// this from the view body re-resolves and redraws immediately when the
    /// user switches languages.
    func L(_ key: String) -> String {
        Localization.string(key, language: language)
    }
}

extension AppViewModel {
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            sourcePath = url.path
            scanSource()
        }
    }

    func chooseSceneAssetsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = L("settings.scene.choose.message")
        if panel.runModal() == .OK, let url = panel.url {
            setSceneAssetsFolder(url)
        }
    }

    func setSceneAssetsFolder(_ url: URL) {
        let standardizedURL = url.standardizedFileURL
        guard SceneEngineRendererConfiguration.isValidAssetsDirectory(standardizedURL) else {
            status = L("settings.scene.status.invalid")
            return
        }
        let localURL: URL
        do {
            localURL = try copySceneAssetsToDefaultLocation(from: standardizedURL)
        } catch {
            status = String(format: L("settings.scene.status.copyFailed"), error.localizedDescription)
            return
        }
        sceneAssetsDirectory = localURL.path
        userDefaults.set(sceneAssetsDirectory, forKey: PreferenceKey.sceneEngineAssetsDirectory)
        SceneEngineRendererConfiguration.overrideAssetsPath = sceneAssetsDirectory
        status = L("settings.scene.status.copied")
    }

    func clearSceneAssetsFolder() {
        sceneAssetsDirectory = ""
        userDefaults.removeObject(forKey: PreferenceKey.sceneEngineAssetsDirectory)
        SceneEngineRendererConfiguration.overrideAssetsPath = nil
        status = L("settings.scene.status.reset")
    }

    private func copySceneAssetsToDefaultLocation(from sourceURL: URL) throws -> URL {
        guard let destinationURL = SceneEngineRendererConfiguration.defaultAssetsDirectoryURL() else {
            throw CocoaError(.fileNoSuchFile)
        }
        if sourceURL.standardizedFileURL.resolvingSymlinksInPath().path
            == destinationURL.standardizedFileURL.resolvingSymlinksInPath().path {
            return destinationURL
        }

        let fileManager = FileManager.default
        let parentURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)

        let tempURL = parentURL.appending(
            path: ".wallpaper-engine-assets-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try fileManager.copyItem(at: sourceURL, to: tempURL)
        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: tempURL, to: destinationURL)
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw error
        }
        return destinationURL.standardizedFileURL
    }

    func scanSource() {
        guard !sourcePath.isEmpty else {
            status = "Choose a folder first."
            return
        }
        do {
            let result = try scanner.scan(root: URL(filePath: sourcePath))
            scannedAssets = sortedScannedAssets(result.assets)
            selectedScannedAssetIds = scannedAssets.first.map { Set([$0.id]) } ?? []
            status = "Found \(result.assets.count) project(s)."
        } catch {
            status = error.localizedDescription
        }
    }

    @discardableResult
    func importSelected() -> Task<Void, Never> {
        guard !isWorking else {
            status = "Finish the current library operation first."
            return Task {}
        }
        let assets = selectedScannedAssets
        guard !assets.isEmpty else {
            status = "Select a scanned project first."
            return Task {}
        }
        return Task {
            do {
                _ = try await importAssets(assets)
            } catch {
                status = error.localizedDescription
            }
        }
    }

    /// A single manifest-write gate shared by local and Workshop imports.
    /// Workshop duplicates select the existing copy, preserving its conversions and caches.
    func importAssets(_ assets: [WallpaperAsset], preservingExisting: Bool = false) async throws -> [WallpaperAsset] {
        guard !isWorking else { throw SteamBridgeError.busy }
        let selectionIntent = applicationIntentID
        isWorking = true
        importProgress = ImportProgress(completed: 0, total: assets.count)
        status = "Importing 0/\(assets.count)..."
        defer {
            loadLibrary(allowEmptySelection: true)
            importProgress = nil
            isWorking = false
        }
        let store = self.store
        let existing = preservingExisting ? try store.load().assets : []
        var importedAssets: [WallpaperAsset] = []
        for asset in assets {
            let imported: WallpaperAsset
            if let retained = existing.first(where: { $0.id == asset.id }) {
                imported = retained
            } else {
                imported = try await Task.detached { try store.importAsset(asset) }.value
            }
            importedAssets.append(imported)
            importProgress = ImportProgress(completed: importedAssets.count, total: assets.count)
            status = "Importing \(importedAssets.count)/\(assets.count)..."
        }
        userDefaults.set(Date(), forKey: PreferenceKey.lastImportAt)
        loadLibrary(allowEmptySelection: true)
        if applicationIntentID == selectionIntent {
            selectedLibraryAssetIds = Set(importedAssets.map(\.id))
            normalizeLibrarySelection(allowEmpty: true)
        }
        if importedAssets.count == 1, let imported = importedAssets.first {
            status = "Imported \(imported.title)."
        } else {
            status = "Imported \(importedAssets.count) projects."
        }
        return importedAssets
    }

    /// Builds the reusable scene cache only; committing wallpaper windows remains
    /// the caller's responsibility after checking its application intent again.
    func prepareWorkshopAsset(
        _ asset: WallpaperAsset,
        intent: UUID,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws {
        try Task.checkCancellation()
        guard applicationIntentID == intent else { throw CancellationError() }
        preparingWorkshopAssets[asset.id, default: 0] += 1
        defer {
            let remaining = (preparingWorkshopAssets[asset.id] ?? 1) - 1
            preparingWorkshopAssets[asset.id] = remaining > 0 ? remaining : nil
        }
        let report: @MainActor (Double) -> Void = { [weak self] value in
            guard !Task.isCancelled, self?.applicationIntentID == intent else { return }
            progress(value)
        }
        if let scenePreparer {
            try await scenePreparer(asset, report)
        } else if asset.kind == .scene {
            guard let frame = WallpaperScreenFrames.wallpaperFrames(for: NSScreen.screens).first else {
                throw ScenePreparationError.unavailable("display")
            }
            try await SceneWallpaperContentFactory.prepare(asset: asset, frame: frame, progress: report)
        } else if asset.kind == .video, let entrypoint = asset.entrypoint {
            report(0)
            _ = try await VideoPlaybackPreparation.prepare(url: URL(filePath: entrypoint), assetID: asset.id)
            report(1)
        } else {
            report(1)
        }
        try Task.checkCancellation()
        guard applicationIntentID == intent else { throw CancellationError() }
        if asset.kind == .scene { sceneVideoRenderRevision += 1 }
    }

    /// Cancellation releases a caller, not an external process writing its cache.
    /// Deletion must remain disabled until both have finished.
    func isPreparingWorkshopAsset(_ assetID: String) -> Bool {
        preparingWorkshopAssets[assetID, default: 0] > 0
            || SceneWallpaperContentFactory.isRendering(assetID: assetID)
            || VideoPlaybackPreparation.isPreparing(assetID: assetID)
    }

    func chooseVideoFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = Self.videoContentTypes
        panel.message = "Choose a local video file to add to your wallpaper library."
        if panel.runModal() == .OK, let url = panel.url {
            importVideoFile(url)
        }
    }

    @discardableResult
    func importVideoFile(_ url: URL) -> Task<Void, Never> {
        guard !isWorking else {
            status = "Finish the current library operation first."
            return Task {}
        }
        isWorking = true
        status = "Adding \(url.lastPathComponent)..."
        let store = self.store
        return Task {
            defer {
                isWorking = false
            }
            do {
                let imported = try await Task.detached { try store.importVideoFile(url) }.value
                loadLibrary()
                selectedLibraryAssetId = imported.id
                status = imported.supportStatus == .needsConversion
                    ? "Added \(imported.title). Convert it before playing."
                    : "Added \(imported.title)."
            } catch {
                status = error.localizedDescription
            }
        }
    }

    @discardableResult
    func playSelected() -> Bool {
        beginApplicationIntent()
        guard let asset = selectedLibraryAsset else {
            status = "Select a library project first."
            return false
        }
        do {
            try play(asset: asset, remember: true)
            return true
        } catch {
            status = error.localizedDescription
            return false
        }
    }

    func playSelectedInteractively() {
        guard let asset = selectedLibraryAsset, asset.supportStatus == .playable,
              asset.kind == .web || asset.kind == .scene else {
            playSelected()
            return
        }
        wallpaperInteractionEnabled = true
        playSelected()
    }

    func setStillWallpaper() {
        guard let asset = selectedLibraryAsset else {
            status = "Select a library project first."
            return
        }
        do {
            let result = try systemWallpaperSetter.setStillWallpaper(from: asset)
            if result.lockScreenCacheURL != nil {
                status = "Set desktop wallpaper and wrote Lock Screen still image from "
                    + "\(result.imageURL.lastPathComponent). Lock the Mac once to refresh the visible screen."
            } else {
                status = "Set desktop still wallpaper from \(result.imageURL.lastPathComponent), "
                    + "but Lock Screen failed: \(result.lockScreenErrorDescription ?? "unknown error")."
            }
        } catch {
            status = error.localizedDescription
        }
    }

    func removeSelectedLibraryAsset() {
        removeSelectedLibraryAssets()
    }

    /// Prepares the confirmation dialog state for the currently selected
    /// library asset(s). The view presents `.confirmationDialog` bound to
    /// `pendingLibraryRemoval`; only its destructive action actually calls
    /// `removeSelectedLibraryAssets()`.
    func requestRemoveSelectedLibraryAssets() {
        let assets = selectedLibraryAssets
        guard !assets.isEmpty else {
            status = "Select a library project first."
            return
        }
        let title = assets.count == 1
            ? assets[0].title
            : "\(assets.count) items"
        pendingLibraryRemoval = PendingLibraryRemoval(assetIds: Set(assets.map(\.id)), title: title)
    }

    func cancelPendingLibraryRemoval() {
        pendingLibraryRemoval = nil
    }

    func removeSelectedLibraryAssets() {
        let assets = selectedLibraryAssets
        guard !isWorking else {
            status = "Finish the current library operation first."
            return
        }
        guard activeWorkshop?.isChangingLibraryFiles != true,
              !assets.contains(where: { isPreparingWorkshopAsset($0.id) }) else {
            status = L("workshop.error.busy")
            return
        }
        pendingLibraryRemoval = nil
        guard !assets.isEmpty else {
            status = "Select a library project first."
            return
        }
        let wasRotating = rotationEnabled
        do {
            for asset in assets {
                try store.removeAsset(id: asset.id)
                let pendingDisplays = Set(requestedPlayback.filter { $0.value.asset.id == asset.id }.keys)
                wallpaperPlayer.cancelPendingPlayback(on: pendingDisplays)
                for id in pendingDisplays { requestedPlayback[id] = nil }
                if activeWallpaperAssetID == asset.id {
                    activeWallpaperAssetID = nil
                    playbackEvent = nil
                    userDefaults.removeObject(forKey: PreferenceKey.lastPlayedAssetId)
                }
            }
            loadLibrary()
            activeWorkshop?.refreshDownloads()
            scheduleSystemWallpaperSync()
            if wasRotating, !rotationEnabled {
                if assets.count == 1, let asset = assets.first {
                    status = "Moved \(asset.title) to the Trash. Rotation stopped — no playable wallpapers left."
                } else {
                    status = "Moved \(assets.count) items to the Trash. Rotation stopped — no playable wallpapers left."
                }
            } else if assets.count == 1, let asset = assets.first {
                status = "Moved \(asset.title) to the Trash. The original copied folder was not touched."
            } else {
                status = "Moved \(assets.count) items to the Trash. The original copied folders were not touched."
            }
        } catch {
            loadLibrary()
            activeWorkshop?.refreshDownloads()
            status = error.localizedDescription
        }
    }

    func convertSelected() {
        guard !isWorking else {
            status = "Finish the current library operation first."
            return
        }
        guard let asset = selectedLibraryAsset, let entrypoint = asset.entrypoint else {
            status = "Select a library video first."
            return
        }
        let output = URL(filePath: asset.projectDirectory).appending(path: "wwb-converted.mp4")
        isWorking = true
        status = "Converting \(asset.title)..."
        let converter = self.converter
        Task {
            do {
                try await Task.detached {
                    try converter.convertToPlayableVideo(input: URL(filePath: entrypoint), output: output)
                }.value
                let converted = convertedAsset(asset, output: output)
                try store.replaceAsset(converted)
                loadLibrary()
                selectedLibraryAssetId = converted.id
                status = "Converted \(asset.title)."
            } catch {
                status = error.localizedDescription
            }
            isWorking = false
        }
    }

    func stopSelectedPlayback() {
        beginApplicationIntent()
        let ids = selectedDisplayIDs
        wallpaperPlayer.stop(on: ids)
        for id in ids { displayAssignments[id]?.isPlaying = false }
        saveDisplayAssignments()
        excludeRotationDisplays(ids)
        if !displayAssignments.values.contains(where: { $0.isPlaying && $0.assetID == activeWallpaperAssetID }) {
            activeWallpaperAssetID = nil
            playbackEvent = nil
        }
        scheduleSystemWallpaperSync()
        status = "Playback stopped on selected displays."
    }

    func stopPlayback() {
        beginApplicationIntent()
        requestedPlayback = [:]
        activeWallpaperAssetID = nil
        playbackEvent = nil
        for id in displayAssignments.keys { displayAssignments[id]?.isPlaying = false }
        saveDisplayAssignments()
        if rotationEnabled {
            disableRotation()
        }
        wallpaperPlayer.stop()
        userDefaults.removeObject(forKey: PreferenceKey.lastPlayedAssetId)
        scheduleSystemWallpaperSync()
        status = "Playback stopped."
    }

    func openLoginItemsSettings() {
        loginItemController.openSystemSettings()
    }

    func openScreenSaverSettings() {
        do {
            try lockScreenAnimationController.openScreenSaverSettings()
            status = "Installed and selected Workshop Wallpaper Bridge Screen Saver."
        } catch {
            status = "Screen Saver settings could not be opened: \(error.localizedDescription)"
        }
    }

    func checkForUpdates() {
        Task {
            await checkForUpdatesNow(userInitiated: true)
        }
    }

    func checkForUpdatesNow(userInitiated: Bool = true) async {
        guard !isCheckingForUpdates else {
            return
        }
        isCheckingForUpdates = true
        defer {
            isCheckingForUpdates = false
        }
        if userInitiated {
            status = "Checking for updates..."
        }
        do {
            let result = try await updateChecker.checkForUpdates(currentVersion: currentVersionProvider())
            userDefaults.set(Date(), forKey: PreferenceKey.lastUpdateCheckAt)
            applyUpdateCheckResult(result, userInitiated: userInitiated)
        } catch {
            if userInitiated {
                let message = error.localizedDescription
                status = "Update check failed: \(message)"
                updateAlert = UpdateAlert(
                    title: "Update Check Failed",
                    message: message
                )
            }
        }
    }

    func performAutomaticUpdateCheckIfNeeded(force: Bool = false, now: Date = Date()) async {
        guard automaticallyCheckForUpdates else {
            return
        }
        if !force,
           let lastCheck = userDefaults.object(forKey: PreferenceKey.lastUpdateCheckAt) as? Date,
           now.timeIntervalSince(lastCheck) < Self.automaticUpdateCheckInterval {
            return
        }
        await checkForUpdatesNow(userInitiated: false)
    }

    func openAvailableUpdate() {
        guard let update = availableUpdate else {
            status = "No update is available."
            return
        }
        let url = update.downloadURL ?? update.releaseURL
        if updateURLOpener.open(url) {
            status = "Opened Workshop Wallpaper Bridge \(update.version) update."
        } else {
            status = "Could not open the update download page."
        }
    }

    func loadLibrary(allowEmptySelection: Bool = false) {
        do {
            libraryAssets = try store.load().assets
            let removedDisplays = Set(displayAssignments.filter { assignment in
                guard let assetID = assignment.value.assetID else { return false }
                return !libraryAssets.contains(where: { $0.id == assetID })
            }.keys)
            if !removedDisplays.isEmpty {
                wallpaperPlayer.stop(on: removedDisplays)
                for id in removedDisplays {
                    displayAssignments[id]?.assetID = nil
                    displayAssignments[id]?.isPlaying = false
                }
                saveDisplayAssignments()
            }
            normalizeLibrarySelection(allowEmpty: allowEmptySelection)
            if rotationEnabled {
                if playableLibraryAssets.isEmpty {
                    // The last playable item was removed while rotating: shut
                    // rotation down cleanly instead of leaving a stale enabled
                    // flag that would resurrect on the next launch.
                    disableRotation(status: "Rotation stopped — no playable wallpapers left.")
                } else {
                    buildRotationQueue()
                }
            }
        } catch {
            status = error.localizedDescription
        }
    }

    private func normalizeLibrarySelection(allowEmpty: Bool) {
        let validIds = Set(libraryAssets.map(\.id))
        selectedLibraryAssetIds = selectedLibraryAssetIds.intersection(validIds)
        if selectedLibraryAssetIds.isEmpty, !allowEmpty, let firstId = libraryAssets.first?.id {
            selectedLibraryAssetIds = [firstId]
        }
    }

    private func normalizeScannedSelection(allowEmpty: Bool) {
        let validIds = Set(scannedAssets.map(\.id))
        selectedScannedAssetIds = selectedScannedAssetIds.intersection(validIds)
        if selectedScannedAssetIds.isEmpty, !allowEmpty, let firstId = scannedAssets.first?.id {
            selectedScannedAssetIds = [firstId]
        }
    }

    private func syncLaunchAtLoginStatus() {
        isSyncingLaunchAtLogin = true
        launchAtLogin = loginItemController.isEnabled
        isSyncingLaunchAtLogin = false
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try loginItemController.setEnabled(enabled)
            syncLaunchAtLoginStatus()
            status = enabled ? "Workshop Wallpaper Bridge will open at login." : "Open at login is off."
        } catch {
            syncLaunchAtLoginStatus()
            status = "Open at login could not be changed: \(error.localizedDescription)"
        }
    }

    private func setLockScreenAnimation(_ enabled: Bool) {
        do {
            try lockScreenAnimationController.setEnabled(
                enabled,
                activeAsset: lastActiveWallpaper,
                displayMode: displayMode
            )
            userDefaults.set(enabled, forKey: PreferenceKey.lockScreenAnimationEnabled)
            status = enabled
                ? "Installed and selected Workshop Wallpaper Bridge Screen Saver."
                : "Screen Saver animation is off."
        } catch {
            isSyncingLockScreenAnimation = true
            lockScreenAnimationEnabled = oldLockScreenAnimationPreference()
            isSyncingLockScreenAnimation = false
            status = "Screen Saver animation could not be changed: \(error.localizedDescription)"
        }
    }

    private func configureDisplays() {
        connectedDisplays = displaysProvider()
        displayObservation = NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshConnectedDisplays() }
            }
        if let player = wallpaperPlayer as? WallpaperPlayer {
            player.errorHandler = { [weak self] message in self?.status = message }
        }
    }

    func refreshConnectedDisplays() { connectedDisplays = displaysProvider() }

    private func saveDisplayAssignments() {
        guard let data = try? JSONEncoder().encode(displayAssignments) else { return }
        userDefaults.set(data, forKey: PreferenceKey.displayAssignments)
    }

    private func restorePreferences() {
        restoringPreferences = true
        defer { restoringPreferences = false }
        if let data = userDefaults.data(forKey: PreferenceKey.displayAssignments),
           let saved = try? JSONDecoder().decode([String: DisplayWallpaperAssignment].self, from: data) {
            displayAssignments = saved
        }
        rotationDisplayIDs = Set(userDefaults.stringArray(forKey: PreferenceKey.rotationDisplayIDs) ?? [])
        if let rawDisplayMode = userDefaults.string(forKey: PreferenceKey.displayMode),
           let storedDisplayMode = WallpaperDisplayMode(rawValue: rawDisplayMode) {
            displayMode = storedDisplayMode
        }
        if userDefaults.object(forKey: PreferenceKey.autoPauseWhenCovered) != nil {
            autoPauseWhenCovered = userDefaults.bool(forKey: PreferenceKey.autoPauseWhenCovered)
        }
        preferLiveScenes = userDefaults.object(forKey: PreferenceKey.preferLiveScenes) as? Bool ?? true
        wallpaperInteractionEnabled = userDefaults.bool(forKey: PreferenceKey.wallpaperInteractionEnabled)
        audioReactiveEnabled = userDefaults.bool(forKey: PreferenceKey.audioReactiveEnabled)
        mediaIntegrationEnabled = userDefaults.bool(forKey: PreferenceKey.mediaIntegrationEnabled)
        if userDefaults.object(forKey: PreferenceKey.wallpaperAudioEnabled) != nil {
            wallpaperAudioEnabled = userDefaults.bool(forKey: PreferenceKey.wallpaperAudioEnabled)
        }
        if userDefaults.object(forKey: PreferenceKey.wallpaperAudioVolume) != nil {
            wallpaperAudioVolume = userDefaults.double(forKey: PreferenceKey.wallpaperAudioVolume)
        }
        if userDefaults.object(forKey: PreferenceKey.lockScreenAnimationEnabled) != nil {
            isSyncingLockScreenAnimation = true
            lockScreenAnimationEnabled = userDefaults.bool(forKey: PreferenceKey.lockScreenAnimationEnabled)
            isSyncingLockScreenAnimation = false
        }
        if userDefaults.object(forKey: PreferenceKey.automaticallyCheckForUpdates) != nil {
            automaticallyCheckForUpdates = userDefaults.bool(forKey: PreferenceKey.automaticallyCheckForUpdates)
        }
        isSyncingSystemWallpaperPreference = true
        systemWallpaperEnabled = SystemWallpaperMode.isAvailable
            && userDefaults.bool(forKey: PreferenceKey.systemWallpaperEnabled)
        isSyncingSystemWallpaperPreference = false
        sceneAssetsDirectory = restoredSceneAssetsDirectory()
        SceneEngineRendererConfiguration.overrideAssetsPath = sceneAssetsDirectory.isEmpty ? nil : sceneAssetsDirectory
        if let rawLanguage = userDefaults.string(forKey: PreferenceKey.language),
           let storedLanguage = AppLanguage(rawValue: rawLanguage) {
            language = storedLanguage
        }
        if userDefaults.object(forKey: PreferenceKey.rotationShuffle) != nil {
            rotationShuffle = userDefaults.bool(forKey: PreferenceKey.rotationShuffle)
        }
        if let rawScannedSortOrder = userDefaults.string(forKey: PreferenceKey.scannedSortOrder),
           let storedScannedSortOrder = ScannedAssetSortOrder(rawValue: rawScannedSortOrder) {
            scannedSortOrder = storedScannedSortOrder
        }
        let storedRotationInterval = userDefaults.double(forKey: PreferenceKey.rotationInterval)
        if storedRotationInterval > 0 {
            rotationInterval = storedRotationInterval
        }
    }

    private func restoredSceneAssetsDirectory() -> String {
        guard let storedPath = userDefaults.string(forKey: PreferenceKey.sceneEngineAssetsDirectory),
              !storedPath.isEmpty else {
            return ""
        }
        let storedURL = URL(filePath: storedPath).standardizedFileURL
        guard SceneEngineRendererConfiguration.isValidAssetsDirectory(storedURL) else {
            return storedPath
        }
        do {
            let localURL = try copySceneAssetsToDefaultLocation(from: storedURL)
            userDefaults.set(localURL.path, forKey: PreferenceKey.sceneEngineAssetsDirectory)
            return localURL.path
        } catch {
            return storedPath
        }
    }

    private func sortScannedAssets() {
        scannedAssets = sortedScannedAssets(scannedAssets)
        normalizeScannedSelection(allowEmpty: true)
    }

    private func sortedScannedAssets(_ assets: [WallpaperAsset]) -> [WallpaperAsset] {
        switch scannedSortOrder {
        case .dateAdded:
            assets.sorted(by: dateAddedSort)
        case .name:
            assets.sorted { lhs, rhs in
                let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
                if titleOrder != .orderedSame {
                    return titleOrder == .orderedAscending
                }
                return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
            }
        }
    }

    private var lastActiveWallpaper: WallpaperAsset? {
        if let id = userDefaults.string(forKey: PreferenceKey.lastPlayedAssetId),
           let asset = libraryAssets.first(where: { $0.id == id }) { return asset }
        return selectedLibraryAsset
    }

    private func playLastWallpaperIfAvailable() {
        if userDefaults.data(forKey: PreferenceKey.displayAssignments) != nil {
            if let id = userDefaults.string(forKey: PreferenceKey.lastPlayedAssetId),
               libraryAssets.contains(where: { $0.id == id }) {
                selectedLibraryAssetId = id
            }
            let rotating = userDefaults.bool(forKey: PreferenceKey.rotationEnabled) ? rotationDisplayIDs : []
            for (displayID, assignment) in displayAssignments where assignment.isPlaying && !rotating.contains(displayID) {
                guard let asset = libraryAssets.first(where: { $0.id == assignment.assetID }) else { continue }
                do {
                    try applyWallpaper(asset, on: [displayID], remember: false)
                } catch {
                    status = "\(displayID): \(error.localizedDescription)"
                }
            }
            return
        }
        // A legacy rotation applies only to displays connected during migration.
        guard !userDefaults.bool(forKey: PreferenceKey.rotationEnabled) else { return }
        guard let id = userDefaults.string(forKey: PreferenceKey.lastPlayedAssetId),
              let asset = libraryAssets.first(where: { $0.id == id }),
              asset.supportStatus == .playable else {
            return
        }
        selectedLibraryAssetId = id
        do {
            try applyWallpaper(asset, on: selectedDisplayIDs, remember: false)
        } catch {
            userDefaults.removeObject(forKey: PreferenceKey.lastPlayedAssetId)
            status = "Could not restore \(asset.title): \(error.localizedDescription)"
        }
    }

    private func restoreLockScreenAnimationIfNeeded() {
        guard lockScreenAnimationEnabled else {
            return
        }
        do {
            try lockScreenAnimationController.setEnabled(
                true,
                activeAsset: lastActiveWallpaper,
                displayMode: displayMode
            )
        } catch {
            status = "Screen Saver animation could not be restored: \(error.localizedDescription)"
        }
    }

    private func play(asset: WallpaperAsset, remember: Bool) throws {
        try applyWallpaper(asset, on: selectedDisplayIDs, remember: remember, excludingRotation: true)
    }

    private func reportReadyPlayback(_ asset: WallpaperAsset, updateScreenSaver: Bool, readyStatus: String?) {
        let lockScreenError = updateScreenSaver ? refreshLockScreenAnimationConfiguration(asset: asset) : nil
        let playbackStatus = readyStatus ?? L("workshop.play.ready")
        status = lockScreenError.map {
            "\(playbackStatus) Screen Saver update failed: \($0)"
        } ?? playbackStatus
    }

    /// Fires once a scene's background video render finishes. Bumps
    /// `sceneVideoRenderRevision` so the library list's "renders on first
    /// play" badge flips to "playable" immediately (see the doc comment on
    /// that property for why the plain `libraryAssets`/`status` publishes
    /// aren't enough), then refreshes the lock screen animation config.
    func handleSceneVideoRenderCompletion(assetId: String) {
        sceneVideoRenderRevision += 1
        refreshLockScreenAnimationConfigurationAfterSceneVideoRender(assetId: assetId)
    }

    /// A scene's first render is asynchronous: `refreshLockScreenAnimationConfiguration`
    /// only ever sees the fresh cached video if it's called again once the
    /// render completes. Without this, the lock screen config would stay
    /// pinned to the scene's still image (written on the initial play) until
    /// the user replayed the wallpaper.
    private func refreshLockScreenAnimationConfigurationAfterSceneVideoRender(assetId: String) {
        guard let asset = lastActiveWallpaper, asset.id == assetId else { return }
        _ = refreshLockScreenAnimationConfiguration(asset: asset)
    }

    private func refreshLockScreenAnimationConfiguration(asset: WallpaperAsset) -> String? {
        guard lockScreenAnimationEnabled else {
            return nil
        }
        do {
            try lockScreenAnimationController.updateActiveAsset(asset, displayMode: displayMode)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func oldLockScreenAnimationPreference() -> Bool {
        guard userDefaults.object(forKey: PreferenceKey.lockScreenAnimationEnabled) != nil else {
            return false
        }
        return userDefaults.bool(forKey: PreferenceKey.lockScreenAnimationEnabled)
    }

    private func convertedAsset(_ asset: WallpaperAsset, output: URL) -> WallpaperAsset {
        WallpaperAsset(
            id: asset.id,
            title: asset.title,
            kind: .video,
            supportStatus: .playable,
            source: asset.source,
            projectDirectory: asset.projectDirectory,
            entrypoint: output.path,
            thumbnail: asset.thumbnail,
            workshopId: asset.workshopId,
            dateAdded: asset.dateAdded,
            redistributionAllowed: false,
            issues: asset.issues.filter { $0.code != "needs_conversion" }
        )
    }

    func isNewScannedAsset(_ asset: WallpaperAsset) -> Bool {
        guard let lastImportAt = userDefaults.object(forKey: PreferenceKey.lastImportAt) as? Date,
              let dateAdded = asset.dateAdded else {
            return false
        }
        return dateAdded > lastImportAt
    }

    private func scheduleAutomaticUpdateCheck(force: Bool = false) {
        Task {
            await performAutomaticUpdateCheckIfNeeded(force: force)
        }
    }

    private func applyUpdateCheckResult(_ result: UpdateCheckResult, userInitiated: Bool) {
        switch result {
        case .upToDate(_, let latestVersion):
            availableUpdate = nil
            if userInitiated {
                status = "Workshop Wallpaper Bridge is up to date (\(latestVersion))."
                updateAlert = UpdateAlert(
                    title: "Already Up to Date",
                    message: "Workshop Wallpaper Bridge \(latestVersion) is already the latest version."
                )
            }
        case .updateAvailable(let update):
            availableUpdate = update
            status = "Workshop Wallpaper Bridge \(update.version) is available."
            if userInitiated {
                updateAlert = UpdateAlert(
                    title: "Update Available",
                    message: "Workshop Wallpaper Bridge \(update.version) is available. Click Download Update to download the latest DMG."
                )
            }
        }
    }

    private static let videoContentTypes: [UTType] = [
        .movie,
        .mpeg4Movie,
        .quickTimeMovie
    ] + ["m4v", "webm", "mkv", "avi"].compactMap { UTType(filenameExtension: $0) }

    private static let automaticUpdateCheckInterval: TimeInterval = 12 * 60 * 60
}

extension AppViewModel {
    static let rotationIntervalOptions: [(key: String, seconds: TimeInterval)] = [
        ("library.rotate.interval.30s", 30),
        ("library.rotate.interval.1m", 60),
        ("library.rotate.interval.5m", 300),
        ("library.rotate.interval.15m", 900),
        ("library.rotate.interval.30m", 1800),
        ("library.rotate.interval.1h", 3600)
    ]

    var playableLibraryAssets: [WallpaperAsset] {
        libraryAssets.filter { $0.supportStatus == .playable }
    }

    func nextWallpaper() {
        guard rotationEnabled else {
            return
        }
        restartRotationTimer()
        advanceRotation()
    }

    func restoreRotationIfNeeded() {
        guard userDefaults.bool(forKey: PreferenceKey.rotationEnabled) else {
            return
        }
        if userDefaults.object(forKey: PreferenceKey.rotationDisplayIDs) == nil {
            rotationDisplayIDs = Set(connectedDisplays.map(\.id))
        }
        guard !rotationDisplayIDs.isEmpty else { disableRotation(); return }
        if let currentID = rotationDisplayIDs.sorted().compactMap({ displayAssignments[$0]?.assetID }).first {
            selectedLibraryAssetIds = [currentID]
        }
        setRotationEnabledSilently(true)
        startRotation(restoring: true)
    }

    func startRotation(restoring: Bool = false) {
        if !restoring { rotationDisplayIDs = selectedDisplayIDs }
        guard !playableLibraryAssets.isEmpty else {
            disableRotation(status: "Import or add a playable wallpaper before starting rotation.")
            return
        }
        guard !rotationDisplayIDs.isEmpty else { disableRotation(); return }
        userDefaults.set(Array(rotationDisplayIDs).sorted(), forKey: PreferenceKey.rotationDisplayIDs)
        userDefaults.set(true, forKey: PreferenceKey.rotationEnabled)
        buildRotationQueue()
        restartRotationTimer()
        advanceRotation(initial: true, rememberActiveAsset: !restoring)
    }

    func setRotationEnabledSilently(_ value: Bool) {
        isSyncingRotation = true
        rotationEnabled = value
        isSyncingRotation = false
    }

    /// Single exit point for turning rotation off: stop the timer, flip the
    /// published flag without side effects, and clear the persisted preference
    /// so a stale "enabled" value is never restored on the next launch.
    func disableRotation(status message: String? = nil) {
        stopRotationTimer()
        setRotationEnabledSilently(false)
        userDefaults.set(false, forKey: PreferenceKey.rotationEnabled)
        rotationDisplayIDs = []
        userDefaults.set([], forKey: PreferenceKey.rotationDisplayIDs)
        if let message {
            status = message
        }
    }

    private func excludeRotationDisplays(_ ids: Set<String>) {
        guard rotationEnabled else { return }
        rotationDisplayIDs.subtract(ids)
        userDefaults.set(Array(rotationDisplayIDs).sorted(), forKey: PreferenceKey.rotationDisplayIDs)
        if rotationDisplayIDs.isEmpty { disableRotation() }
    }

    func buildRotationQueue() {
        var ids = playableLibraryAssets.map(\.id)
        if rotationShuffle {
            ids.shuffle()
        }
        rotationQueue = ids
        if let selected = selectedLibraryAsset?.id,
           let index = rotationQueue.firstIndex(of: selected) {
            rotationIndex = index
        } else {
            rotationIndex = 0
        }
    }

    func advanceRotation(initial: Bool = false, rememberActiveAsset: Bool = true) {
        guard !rotationQueue.isEmpty else {
            disableRotation()
            return
        }
        if !initial {
            rotationIndex = (rotationIndex + 1) % rotationQueue.count
        }
        var attempts = 0
        var lastPlaybackError: String?
        while attempts < rotationQueue.count {
            let id = rotationQueue[rotationIndex]
            if let asset = libraryAssets.first(where: { $0.id == id && $0.supportStatus == .playable }) {
                selectedLibraryAssetIds = [id]
                do {
                    let targets = rotationDisplayIDs.isEmpty ? selectedDisplayIDs : rotationDisplayIDs
                    try applyWallpaper(asset, on: targets, remember: rememberActiveAsset,
                        readyStatus: "Rotating \(rotationIndex + 1)/\(rotationQueue.count): \(asset.title)")
                } catch {
                    lastPlaybackError = error.localizedDescription
                    rotationIndex = (rotationIndex + 1) % rotationQueue.count
                    attempts += 1
                    continue
                }
                return
            }
            rotationIndex = (rotationIndex + 1) % rotationQueue.count
            attempts += 1
        }
        if let lastPlaybackError {
            disableRotation(status: "Rotation stopped: \(lastPlaybackError)")
            return
        }
        disableRotation(status: "No playable wallpapers left to rotate.")
    }

    private func applyWallpaper(
        _ asset: WallpaperAsset, on ids: Set<String>, remember: Bool = true,
        excludingRotation: Bool = false, readyStatus: String? = nil
    ) throws {
        guard !ids.isEmpty else { throw PlaybackError.notPlayable("No display selected") }
        let intent = applicationIntentID
        let requestID = UUID()
        let modes = Dictionary(uniqueKeysWithValues: ids.map { ($0, displayAssignments[$0]?.displayMode ?? displayMode) })
        let initialMode = modes.values.first.flatMap { first in modes.values.allSatisfy { $0 == first } ? first : nil } ?? displayMode
        for id in ids { requestedPlayback[id] = (asset, requestID) }
        playbackEvent = nil
        status = L("workshop.play.requested")
        do {
            try wallpaperPlayer.play(asset: asset, on: ids, autoPauseWhenCovered: autoPauseWhenCovered,
                displayMode: initialMode, audioEnabled: wallpaperAudioEnabled, audioVolume: wallpaperAudioVolume
            ) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let readyIDs):
                    let completedIDs = readyIDs.filter { self.requestedPlayback[$0]?.requestID == requestID }
                    guard !completedIDs.isEmpty else { return }
                    for id in completedIDs {
                        let mode = self.displayAssignments[id]?.displayMode ?? modes[id] ?? self.displayMode
                        self.wallpaperPlayer.setDisplayMode(mode, on: [id])
                        self.displayAssignments[id] = DisplayWallpaperAssignment(assetID: asset.id, displayMode: mode, isPlaying: true)
                        self.requestedPlayback[id] = nil
                    }
                    self.saveDisplayAssignments()
                    self.scheduleSystemWallpaperSync()
                    if excludingRotation { self.excludeRotationDisplays(completedIDs) }
                    if self.applicationIntentID == intent {
                        if remember { self.userDefaults.set(asset.id, forKey: PreferenceKey.lastPlayedAssetId) }
                        self.activeWallpaperAssetID = asset.id
                        self.reportReadyPlayback(asset, updateScreenSaver: remember, readyStatus: readyStatus)
                        self.playbackEvent = .ready(assetID: asset.id)
                    }
                case .failure(let error):
                    let failedIDs = ids.filter { self.requestedPlayback[$0]?.requestID == requestID }
                    guard !failedIDs.isEmpty else { return }
                    for id in failedIDs { self.requestedPlayback[id] = nil }
                    if self.applicationIntentID == intent {
                        self.status = error.localizedDescription
                        self.playbackEvent = .failed(assetID: asset.id, message: error.localizedDescription)
                    }
                }
            }
        } catch {
            for id in ids where requestedPlayback[id]?.requestID == requestID { requestedPlayback[id] = nil }
            throw error
        }
    }

    func restartRotationTimer() {
        stopRotationTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: rotationInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.advanceRotation()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        rotationTimer = timer
    }

    func stopRotationTimer() {
        rotationTimer?.invalidate()
        rotationTimer = nil
    }
}

private enum PreferenceKey {
    static let displayAssignments = "displayWallpaperAssignments"
    static let rotationDisplayIDs = "rotationDisplayIDs"
    static let displayMode = "displayMode"
    static let autoPauseWhenCovered = "autoPauseWhenCovered"
    static let lockScreenAnimationEnabled = "lockScreenAnimationEnabled"
    static let lastPlayedAssetId = "lastPlayedAssetId"
    static let automaticallyCheckForUpdates = "automaticallyCheckForUpdates"
    static let lastUpdateCheckAt = "lastUpdateCheckAt"
    static let sceneEngineAssetsDirectory = "sceneEngineAssetsDirectory"
    static let audioReactiveEnabled = "audioReactiveEnabled"
    static let mediaIntegrationEnabled = "mediaIntegrationEnabled"
    static let preferLiveScenes = "preferLiveScenes"
    static let wallpaperInteractionEnabled = "wallpaperInteractionEnabled"
    static let wallpaperAudioEnabled = "wallpaperAudioEnabled"
    static let wallpaperAudioVolume = "wallpaperAudioVolume"
    static let language = "language"
    static let rotationEnabled = "rotationEnabled"
    static let rotationShuffle = "rotationShuffle"
    static let rotationInterval = "rotationInterval"
    static let scannedSortOrder = "scannedSortOrder"
    static let lastImportAt = "lastImportAt"
    static let systemWallpaperEnabled = "systemWallpaperEnabled"
}

private func dateAddedSort(_ lhs: WallpaperAsset, _ rhs: WallpaperAsset) -> Bool {
    switch (lhs.dateAdded, rhs.dateAdded) {
    case let (left?, right?) where left != right:
        return left > right
    case (_?, nil):
        return true
    case (nil, _?):
        return false
    default:
        return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
    }
}

// MARK: - System wallpaper mode

extension AppViewModel {
    /// Brings the extension in line with what each display plays: it takes the displays
    /// with a playable video (the app then stops its own window there) and gives back the
    /// rest. Calls made while one runs are folded into one more pass.
    func scheduleSystemWallpaperSync() {
        guard SystemWallpaperMode.isAvailable else { return }
        if systemWallpaperSyncTask != nil {
            systemWallpaperSyncAgain = true
            return
        }
        systemWallpaperSyncTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.systemWallpaperSyncAgain = false
                await self.syncSystemWallpaper()
            } while self.systemWallpaperSyncAgain
            self.systemWallpaperSyncTask = nil
        }
    }

    private func syncSystemWallpaper() async {
        guard systemWallpaperEnabled else {
            let served = systemWallpaperDisplays
            do {
                try systemWallpaperMode.restore()
            } catch {
                status = error.localizedDescription
            }
            systemWallpaperDisplays = []
            resumeOwnWallpaper(on: served)
            return
        }
        let connected = Set(WallpaperDisplay.connected().map(\.id))
        var playing: [String: WallpaperAsset] = [:]
        for (id, assignment) in displayAssignments where assignment.isPlaying && connected.contains(id) {
            if let asset = libraryAssets.first(where: { $0.id == assignment.assetID }) { playing[id] = asset }
        }
        do {
            let served = try await systemWallpaperMode.apply(playing)
            let released = systemWallpaperDisplays.subtracting(served)
            systemWallpaperDisplays = served
            wallpaperPlayer.stop(on: served)
            resumeOwnWallpaper(on: released)
            if !served.isEmpty, served.count < playing.count {
                status = L("settings.systemWallpaper.partial")
            }
        } catch {
            let served = systemWallpaperDisplays
            systemWallpaperDisplays = []
            resumeOwnWallpaper(on: served)
            status = error.localizedDescription
        }
    }

    private func resumeOwnWallpaper(on displayIDs: Set<String>) {
        for id in displayIDs {
            guard let assignment = displayAssignments[id], assignment.isPlaying,
                  let asset = libraryAssets.first(where: { $0.id == assignment.assetID }) else { continue }
            try? applyWallpaper(asset, on: [id], remember: false)
        }
    }
}
