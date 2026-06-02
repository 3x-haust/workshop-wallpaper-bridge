import AppKit
import Foundation
import UniformTypeIdentifiers
import WorkshopWallpaperCore

struct AppViewModelOperations: Sendable {
    var scan: @Sendable (String) throws -> ScanResult
    var loadLibrary: @Sendable () throws -> [WallpaperAsset]
    var importAssets: @Sendable ([WallpaperAsset]) throws -> [WallpaperAsset]
    var importVideoFile: @Sendable (URL) throws -> WallpaperAsset
    var removeAssets: @Sendable ([WallpaperAsset.ID]) throws -> Void
    var replaceAsset: @Sendable (WallpaperAsset) throws -> Void

    init(
        scan: @escaping @Sendable (String) throws -> ScanResult = { path in
            try WallpaperScanner().scan(root: URL(filePath: path))
        },
        loadLibrary: @escaping @Sendable () throws -> [WallpaperAsset] = {
            throw AppViewModelOperationsError.unconfiguredOperation
        },
        importAssets: @escaping @Sendable ([WallpaperAsset]) throws -> [WallpaperAsset] = { _ in
            throw AppViewModelOperationsError.unconfiguredOperation
        },
        importVideoFile: @escaping @Sendable (URL) throws -> WallpaperAsset = { _ in
            throw AppViewModelOperationsError.unconfiguredOperation
        },
        removeAssets: @escaping @Sendable ([WallpaperAsset.ID]) throws -> Void = { _ in
            throw AppViewModelOperationsError.unconfiguredOperation
        },
        replaceAsset: @escaping @Sendable (WallpaperAsset) throws -> Void = { _ in
            throw AppViewModelOperationsError.unconfiguredOperation
        }
    ) {
        self.scan = scan
        self.loadLibrary = loadLibrary
        self.importAssets = importAssets
        self.importVideoFile = importVideoFile
        self.removeAssets = removeAssets
        self.replaceAsset = replaceAsset
    }

    static func live(store: LibraryStore) -> AppViewModelOperations {
        AppViewModelOperations(
            scan: { path in
                try WallpaperScanner().scan(root: URL(filePath: path))
            },
            loadLibrary: {
                try store.load().assets
            },
            importAssets: { assets in
                try assets.map { try store.importAsset($0) }
            },
            importVideoFile: { url in
                try store.importVideoFile(url)
            },
            removeAssets: { ids in
                for id in ids {
                    try store.removeAsset(id: id)
                }
            },
            replaceAsset: { asset in
                try store.replaceAsset(asset)
            }
        )
    }
}

private enum AppViewModelOperationsError: Error {
    case unconfiguredOperation
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var sourcePath = ""
    @Published var scannedAssets: [WallpaperAsset] = []
    @Published var libraryAssets: [WallpaperAsset] = []
    @Published private(set) var selectedScannedAssetIds: Set<WallpaperAsset.ID> = []
    @Published private(set) var selectedLibraryAssetIds: Set<WallpaperAsset.ID> = []
    @Published var status = "Choose a copied Wallpaper Engine Workshop folder to begin."
    @Published var isWorking = false
    @Published var displayMode: WallpaperDisplayMode = .fit {
        didSet {
            WallpaperPlayer.shared.setDisplayMode(displayMode)
            userDefaults.set(displayMode.rawValue, forKey: PreferenceKey.displayMode)
            if lockScreenAnimationEnabled, let asset = selectedLibraryAsset {
                _ = refreshLockScreenAnimationConfiguration(asset: asset)
            }
        }
    }
    @Published var autoPauseWhenCovered = true {
        didSet {
            WallpaperPlayer.shared.setAutoPauseWhenCovered(autoPauseWhenCovered)
            userDefaults.set(autoPauseWhenCovered, forKey: PreferenceKey.autoPauseWhenCovered)
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
    @Published var launchAtLogin = false {
        didSet {
            guard !isSyncingLaunchAtLogin, launchAtLogin != oldValue else {
                return
            }
            setLaunchAtLogin(launchAtLogin)
        }
    }

    private let converter = VideoConverter()
    private let systemWallpaperSetter = SystemWallpaperSetter()
    private let store: LibraryStore
    private let operations: AppViewModelOperations
    private let loginItemController: LoginItemManaging
    private let lockScreenAnimationController: LockScreenAnimationManaging
    private let userDefaults: UserDefaults
    private var isSyncingLaunchAtLogin = false
    private var isSyncingLockScreenAnimation = false

    init() {
        userDefaults = .standard
        loginItemController = LoginItemController()
        lockScreenAnimationController = LockScreenAnimationController()
        do {
            store = try LibraryStore.defaultStore()
            operations = .live(store: store)
            restorePreferences()
            loadLibrary()
            playLastWallpaperIfAvailable()
            restoreLockScreenAnimationIfNeeded()
        } catch {
            store = LibraryStore(
                root: FileManager.default.temporaryDirectory.appending(path: "WorkshopWallpaperBridge")
            )
            operations = .live(store: store)
            status = error.localizedDescription
        }
        syncLaunchAtLoginStatus()
    }

    init(
        store: LibraryStore,
        loginItemController: LoginItemManaging = LoginItemController(),
        lockScreenAnimationController: LockScreenAnimationManaging = LockScreenAnimationController(),
        userDefaults: UserDefaults = .standard,
        operations: AppViewModelOperations? = nil
    ) {
        self.store = store
        self.operations = operations ?? .live(store: store)
        self.loginItemController = loginItemController
        self.lockScreenAnimationController = lockScreenAnimationController
        self.userDefaults = userDefaults
        restorePreferences()
        loadLibrary()
        playLastWallpaperIfAvailable()
        restoreLockScreenAnimationIfNeeded()
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
            selectedLibraryAssetIds = newValue.map { Set([$0]) } ?? []
        }
    }

    var selectedLibraryAssetCount: Int {
        selectedLibraryAssets.count
    }

    var selectedLibraryAssets: [WallpaperAsset] {
        libraryAssets.filter { selectedLibraryAssetIds.contains($0.id) }
    }

    func selectLibraryAssets(_ ids: Set<WallpaperAsset.ID>) {
        selectedLibraryAssetIds = ids
        normalizeLibrarySelection(allowEmpty: true)
    }

    func selectScannedAssets(_ ids: Set<WallpaperAsset.ID>) {
        selectedScannedAssetIds = ids
        normalizeScannedSelection(allowEmpty: true)
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

    func scanSource() {
        guard !sourcePath.isEmpty else {
            status = "Choose a folder first."
            return
        }
        let path = sourcePath
        let scan = operations.scan
        isWorking = true
        status = "Scanning \(path)..."
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try scan(path)
                }.value
                scannedAssets = result.assets
                selectedScannedAssetIds = result.assets.first.map { Set([$0.id]) } ?? []
                status = "Found \(result.assets.count) project(s)."
            } catch {
                status = error.localizedDescription
            }
            isWorking = false
        }
    }

    func importSelected() {
        let assets = selectedScannedAssets
        guard !assets.isEmpty else {
            status = "Select a scanned project first."
            return
        }
        let importAssets = operations.importAssets
        let loadLibrary = operations.loadLibrary
        isWorking = true
        status = assets.count == 1
            ? "Importing \(assets[0].title)..."
            : "Importing \(assets.count) projects..."
        Task {
            var importedAssets: [WallpaperAsset] = []
            do {
                (importedAssets, libraryAssets) = try await Task.detached(priority: .userInitiated) {
                    let imported = try importAssets(assets)
                    return (imported, try loadLibrary())
                }.value
                normalizeLibrarySelection(allowEmpty: false)
                selectLibraryAssets(Set(importedAssets.map(\.id)))
                if importedAssets.count == 1, let imported = importedAssets.first {
                    status = "Imported \(imported.title)."
                } else {
                    status = "Imported \(importedAssets.count) projects."
                }
            } catch {
                do {
                    libraryAssets = try await Task.detached(priority: .userInitiated) {
                        try loadLibrary()
                    }.value
                    normalizeLibrarySelection(allowEmpty: false)
                } catch {
                    status = error.localizedDescription
                    isWorking = false
                    return
                }
                if importedAssets.isEmpty {
                    status = error.localizedDescription
                } else {
                    status = "Imported \(importedAssets.count) project(s), then failed: \(error.localizedDescription)"
                }
            }
            isWorking = false
        }
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

    func importVideoFile(_ url: URL) {
        let importVideoFile = operations.importVideoFile
        let loadLibrary = operations.loadLibrary
        isWorking = true
        status = "Adding \(url.lastPathComponent)..."
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let imported = try importVideoFile(url)
                    return (imported, try loadLibrary())
                }.value
                let imported = result.0
                libraryAssets = result.1
                normalizeLibrarySelection(allowEmpty: false)
                selectedLibraryAssetId = imported.id
                status = imported.supportStatus == .needsConversion
                    ? "Added \(imported.title). Convert it before playing."
                    : "Added \(imported.title)."
            } catch {
                status = error.localizedDescription
            }
            isWorking = false
        }
    }

    func playSelected() {
        guard let asset = selectedLibraryAsset else {
            status = "Select a library project first."
            return
        }
        do {
            try play(asset: asset, remember: true)
        } catch {
            status = error.localizedDescription
        }
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

    func removeSelectedLibraryAssets() {
        let assets = selectedLibraryAssets
        guard !assets.isEmpty else {
            status = "Select a library project first."
            return
        }
        let ids = assets.map(\.id)
        let removeAssets = operations.removeAssets
        let loadLibrary = operations.loadLibrary
        isWorking = true
        status = assets.count == 1
            ? "Removing \(assets[0].title)..."
            : "Removing \(assets.count) items..."
        Task {
            do {
                libraryAssets = try await Task.detached(priority: .userInitiated) {
                    try removeAssets(ids)
                    return try loadLibrary()
                }.value
                normalizeLibrarySelection(allowEmpty: true)
                if assets.count == 1, let asset = assets.first {
                    status = "Removed \(asset.title) from your Mac library."
                } else {
                    status = "Removed \(assets.count) items from your Mac library."
                }
            } catch {
                status = error.localizedDescription
            }
            isWorking = false
        }
    }

    func convertSelected() {
        guard let asset = selectedLibraryAsset, let entrypoint = asset.entrypoint else {
            status = "Select a library video first."
            return
        }
        let output = URL(filePath: asset.projectDirectory).appending(path: "wwb-converted.mp4")
        isWorking = true
        status = "Converting \(asset.title)..."
        let converter = self.converter
        let replaceAsset = operations.replaceAsset
        let loadLibrary = operations.loadLibrary
        Task {
            do {
                let converted = try await Task.detached(priority: .userInitiated) {
                    try converter.convertToPlayableVideo(input: URL(filePath: entrypoint), output: output)
                    let converted = Self.convertedAsset(asset, output: output)
                    try replaceAsset(converted)
                    return (converted, try loadLibrary())
                }.value
                libraryAssets = converted.1
                normalizeLibrarySelection(allowEmpty: false)
                let convertedAsset = converted.0
                selectedLibraryAssetId = convertedAsset.id
                status = "Converted \(asset.title)."
            } catch {
                status = error.localizedDescription
            }
            isWorking = false
        }
    }

    func stopPlayback() {
        WallpaperPlayer.shared.stop()
        userDefaults.removeObject(forKey: PreferenceKey.lastPlayedAssetId)
        status = "Playback stopped."
    }

    func openLoginItemsSettings() {
        loginItemController.openSystemSettings()
    }

    func openScreenSaverSettings() {
        lockScreenAnimationController.openScreenSaverSettings()
    }

    func loadLibrary() {
        do {
            libraryAssets = try store.load().assets
            normalizeLibrarySelection(allowEmpty: false)
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
                activeAsset: selectedLibraryAsset,
                displayMode: displayMode
            )
            userDefaults.set(enabled, forKey: PreferenceKey.lockScreenAnimationEnabled)
            status = enabled
                ? "Installed the Lock Screen screen saver. Select it in Screen Saver settings to animate while locked."
                : "Animated Lock Screen screen saver is off."
        } catch {
            isSyncingLockScreenAnimation = true
            lockScreenAnimationEnabled = oldLockScreenAnimationPreference()
            isSyncingLockScreenAnimation = false
            status = "Animated Lock Screen could not be changed: \(error.localizedDescription)"
        }
    }

    private func restorePreferences() {
        if let rawDisplayMode = userDefaults.string(forKey: PreferenceKey.displayMode),
           let storedDisplayMode = WallpaperDisplayMode(rawValue: rawDisplayMode) {
            displayMode = storedDisplayMode
        }
        if userDefaults.object(forKey: PreferenceKey.autoPauseWhenCovered) != nil {
            autoPauseWhenCovered = userDefaults.bool(forKey: PreferenceKey.autoPauseWhenCovered)
        }
        if userDefaults.object(forKey: PreferenceKey.lockScreenAnimationEnabled) != nil {
            isSyncingLockScreenAnimation = true
            lockScreenAnimationEnabled = userDefaults.bool(forKey: PreferenceKey.lockScreenAnimationEnabled)
            isSyncingLockScreenAnimation = false
        }
    }

    private func playLastWallpaperIfAvailable() {
        guard let id = userDefaults.string(forKey: PreferenceKey.lastPlayedAssetId),
              let asset = libraryAssets.first(where: { $0.id == id }),
              asset.supportStatus == .playable else {
            return
        }
        selectedLibraryAssetId = id
        do {
            try play(asset: asset, remember: false)
            status = "Restored \(asset.title) on the desktop."
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
                activeAsset: selectedLibraryAsset,
                displayMode: displayMode
            )
        } catch {
            status = "Animated Lock Screen could not be restored: \(error.localizedDescription)"
        }
    }

    private func play(asset: WallpaperAsset, remember: Bool) throws {
        try WallpaperPlayer.shared.play(
            asset: asset,
            autoPauseWhenCovered: autoPauseWhenCovered,
            displayMode: displayMode
        )
        if remember {
            userDefaults.set(asset.id, forKey: PreferenceKey.lastPlayedAssetId)
        }
        let lockScreenError = refreshLockScreenAnimationConfiguration(asset: asset)
        let playbackStatus = autoPauseWhenCovered
            ? "Playing on the desktop layer. You can minimize this app; playback pauses only behind other apps."
            : "Playing continuously on the desktop layer. You can minimize this app."
        status = lockScreenError.map { "\(playbackStatus) Lock Screen update failed: \($0)" } ?? playbackStatus
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

    private nonisolated static func convertedAsset(_ asset: WallpaperAsset, output: URL) -> WallpaperAsset {
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
            redistributionAllowed: false,
            issues: asset.issues.filter { $0.code != "needs_conversion" }
        )
    }

    private static let videoContentTypes: [UTType] = [
        .movie,
        .mpeg4Movie,
        .quickTimeMovie
    ] + ["m4v", "webm", "mkv", "avi"].compactMap { UTType(filenameExtension: $0) }
}

private enum PreferenceKey {
    static let displayMode = "displayMode"
    static let autoPauseWhenCovered = "autoPauseWhenCovered"
    static let lockScreenAnimationEnabled = "lockScreenAnimationEnabled"
    static let lastPlayedAssetId = "lastPlayedAssetId"
}
