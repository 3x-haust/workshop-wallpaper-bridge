import AppKit
import Foundation
import UniformTypeIdentifiers
import WorkshopWallpaperCore

struct UpdateAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor
protocol WallpaperPlaying: AnyObject {
    func play(
        asset: WallpaperAsset,
        autoPauseWhenCovered: Bool,
        displayMode: WallpaperDisplayMode
    ) throws
    func stop()
    func setDisplayMode(_ mode: WallpaperDisplayMode)
    func setAutoPauseWhenCovered(_ enabled: Bool)
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
    @Published var displayMode: WallpaperDisplayMode = .fit {
        didSet {
            wallpaperPlayer.setDisplayMode(displayMode)
            userDefaults.set(displayMode.rawValue, forKey: PreferenceKey.displayMode)
            if lockScreenAnimationEnabled, let asset = selectedLibraryAsset {
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
    @Published var lockScreenAnimationEnabled = false {
        didSet {
            guard !isSyncingLockScreenAnimation, lockScreenAnimationEnabled != oldValue else {
                return
            }
            setLockScreenAnimation(lockScreenAnimationEnabled)
        }
    }
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

    @Published var rotationEnabled = false {
        didSet {
            guard !isSyncingRotation, rotationEnabled != oldValue else {
                return
            }
            if rotationEnabled {
                startRotation()
            } else {
                stopRotationTimer()
                userDefaults.set(false, forKey: PreferenceKey.rotationEnabled)
                status = "Rotation stopped."
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
    private let currentVersionProvider: () -> String
    private var isSyncingLaunchAtLogin = false
    private var isSyncingLockScreenAnimation = false
    private var isSyncingRotation = false
    private var rotationTimer: Timer?
    private var rotationQueue: [WallpaperAsset.ID] = []
    private var rotationIndex = 0

    init() {
        userDefaults = .standard
        loginItemController = LoginItemController()
        lockScreenAnimationController = LockScreenAnimationController()
        updateChecker = GitHubReleaseUpdateChecker()
        updateURLOpener = WorkspaceUpdateURLOpener()
        wallpaperPlayer = WallpaperPlayer.shared
        currentVersionProvider = { AppVersionProvider.currentVersion() }
        do {
            store = try LibraryStore.defaultStore()
            restorePreferences()
            loadLibrary()
            playLastWallpaperIfAvailable()
            restoreLockScreenAnimationIfNeeded()
            restoreRotationIfNeeded()
        } catch {
            store = LibraryStore(
                root: FileManager.default.temporaryDirectory.appending(path: "WorkshopWallpaperBridge")
            )
            status = error.localizedDescription
        }
        syncLaunchAtLoginStatus()
        scheduleAutomaticUpdateCheck()
    }

    init(
        store: LibraryStore,
        loginItemController: LoginItemManaging = LoginItemController(),
        lockScreenAnimationController: LockScreenAnimationManaging = LockScreenAnimationController(),
        updateChecker: UpdateChecking = DisabledUpdateChecker(),
        updateURLOpener: UpdateURLOpening = WorkspaceUpdateURLOpener(),
        wallpaperPlayer: WallpaperPlaying = WallpaperPlayer.shared,
        currentVersionProvider: @escaping () -> String = { "0.0.0" },
        userDefaults: UserDefaults = .standard
    ) {
        self.store = store
        self.loginItemController = loginItemController
        self.lockScreenAnimationController = lockScreenAnimationController
        self.updateChecker = updateChecker
        self.updateURLOpener = updateURLOpener
        self.wallpaperPlayer = wallpaperPlayer
        self.currentVersionProvider = currentVersionProvider
        self.userDefaults = userDefaults
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
        do {
            let result = try scanner.scan(root: URL(filePath: sourcePath))
            scannedAssets = result.assets
            selectedScannedAssetIds = result.assets.first.map { Set([$0.id]) } ?? []
            status = "Found \(result.assets.count) project(s)."
        } catch {
            status = error.localizedDescription
        }
    }

    func importSelected() {
        let assets = selectedScannedAssets
        guard !assets.isEmpty else {
            status = "Select a scanned project first."
            return
        }
        var importedAssets: [WallpaperAsset] = []
        do {
            for asset in assets {
                importedAssets.append(try store.importAsset(asset))
            }
            loadLibrary()
            selectLibraryAssets(Set(importedAssets.map(\.id)))
            if importedAssets.count == 1, let imported = importedAssets.first {
                status = "Imported \(imported.title)."
            } else {
                status = "Imported \(importedAssets.count) projects."
            }
        } catch {
            loadLibrary()
            if importedAssets.isEmpty {
                status = error.localizedDescription
            } else {
                status = "Imported \(importedAssets.count) project(s), then failed: \(error.localizedDescription)"
            }
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
        do {
            let imported = try store.importVideoFile(url)
            loadLibrary()
            selectedLibraryAssetId = imported.id
            status = imported.supportStatus == .needsConversion
                ? "Added \(imported.title). Convert it before playing."
                : "Added \(imported.title)."
        } catch {
            status = error.localizedDescription
        }
    }

    func playSelected() {
        guard let asset = selectedLibraryAsset else {
            status = "Select a library project first."
            return
        }
        if rotationEnabled {
            disableRotation()
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
        do {
            for asset in assets {
                try store.removeAsset(id: asset.id)
            }
            loadLibrary()
            if assets.count == 1, let asset = assets.first {
                status = "Removed \(asset.title) from your Mac library."
            } else {
                status = "Removed \(assets.count) items from your Mac library."
            }
        } catch {
            status = error.localizedDescription
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

    func stopPlayback() {
        if rotationEnabled {
            disableRotation()
        }
        wallpaperPlayer.stop()
        userDefaults.removeObject(forKey: PreferenceKey.lastPlayedAssetId)
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

    func loadLibrary() {
        do {
            libraryAssets = try store.load().assets
            normalizeLibrarySelection(allowEmpty: false)
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
                activeAsset: selectedLibraryAsset,
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
        if userDefaults.object(forKey: PreferenceKey.automaticallyCheckForUpdates) != nil {
            automaticallyCheckForUpdates = userDefaults.bool(forKey: PreferenceKey.automaticallyCheckForUpdates)
        }
        if userDefaults.object(forKey: PreferenceKey.rotationShuffle) != nil {
            rotationShuffle = userDefaults.bool(forKey: PreferenceKey.rotationShuffle)
        }
        let storedRotationInterval = userDefaults.double(forKey: PreferenceKey.rotationInterval)
        if storedRotationInterval > 0 {
            rotationInterval = storedRotationInterval
        }
    }

    private func playLastWallpaperIfAvailable() {
        // If rotation was on, let restoreRotationIfNeeded() own the initial play
        // to avoid playing a wallpaper twice on launch (double play / flicker).
        guard !userDefaults.bool(forKey: PreferenceKey.rotationEnabled) else {
            return
        }
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
            status = "Screen Saver animation could not be restored: \(error.localizedDescription)"
        }
    }

    private func play(asset: WallpaperAsset, remember: Bool) throws {
        try wallpaperPlayer.play(
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
        status = lockScreenError.map {
            "\(playbackStatus) Screen Saver update failed: \($0)"
        } ?? playbackStatus
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
            redistributionAllowed: false,
            issues: asset.issues.filter { $0.code != "needs_conversion" }
        )
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
    static let rotationIntervalOptions: [(label: String, seconds: TimeInterval)] = [
        ("30 sec", 30),
        ("1 min", 60),
        ("5 min", 300),
        ("15 min", 900),
        ("30 min", 1800),
        ("1 hour", 3600)
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
        setRotationEnabledSilently(true)
        startRotation()
    }

    func startRotation() {
        guard !playableLibraryAssets.isEmpty else {
            disableRotation(status: "Import or add a playable wallpaper before starting rotation.")
            return
        }
        userDefaults.set(true, forKey: PreferenceKey.rotationEnabled)
        buildRotationQueue()
        restartRotationTimer()
        advanceRotation(initial: true)
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
        if let message {
            status = message
        }
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

    func advanceRotation(initial: Bool = false) {
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
                selectedLibraryAssetId = id
                do {
                    try play(asset: asset, remember: true)
                    status = "Rotating \(rotationIndex + 1)/\(rotationQueue.count): \(asset.title)"
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
    static let displayMode = "displayMode"
    static let autoPauseWhenCovered = "autoPauseWhenCovered"
    static let lockScreenAnimationEnabled = "lockScreenAnimationEnabled"
    static let lastPlayedAssetId = "lastPlayedAssetId"
    static let automaticallyCheckForUpdates = "automaticallyCheckForUpdates"
    static let lastUpdateCheckAt = "lastUpdateCheckAt"
    static let rotationEnabled = "rotationEnabled"
    static let rotationShuffle = "rotationShuffle"
    static let rotationInterval = "rotationInterval"
}
