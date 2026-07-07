import AppKit
import WorkshopWallpaperCore

@MainActor
final class WallpaperPlayer {
    static let shared = WallpaperPlayer()

    private var windows: [WallpaperWindow] = []
    private var activeAsset: WallpaperAsset?
    private var autoPauseWhenCovered = true
    private var displayMode: WallpaperDisplayMode = .fit
    private var audioEnabled = false
    private var audioVolume: Double = 0.5
    private var visibilityTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var isSuspended = false
    private var lastScreenFrames: [CGRect] = []
    private var pendingAutoSuspension: DispatchWorkItem?
    private let visibilityMonitor = DesktopVisibilityMonitor()

    func play(
        asset: WallpaperAsset,
        autoPauseWhenCovered: Bool = true,
        displayMode: WallpaperDisplayMode = .fit,
        audioEnabled: Bool? = nil,
        audioVolume: Double? = nil
    ) throws {
        closeWindows()
        activeAsset = asset
        self.autoPauseWhenCovered = autoPauseWhenCovered
        self.displayMode = displayMode
        if let audioEnabled {
            self.audioEnabled = audioEnabled
        }
        if let audioVolume {
            self.audioVolume = audioVolume
        }
        guard asset.supportStatus == .playable else {
            throw PlaybackError.notPlayable(asset.supportStatus.rawValue)
        }
        guard let entrypoint = asset.entrypoint else {
            throw PlaybackError.missingEntrypoint
        }
        let url = URL(filePath: entrypoint)
        let screens = NSScreen.screens
        let screenFrames = WallpaperScreenFrames.wallpaperFrames(for: screens)
        windows = try screenFrames.map { frame in
            try WallpaperWindow(
                asset: asset,
                url: url,
                frame: frame,
                displayMode: displayMode,
                audioEnabled: self.audioEnabled,
                audioVolume: self.audioVolume
            )
        }
        lastScreenFrames = screenFrames
        windows.forEach { $0.show() }
        startLifecycleObservers()
        startVisibilityTimer()
        updateVisibilityState()
    }

    /// Applies the wallpaper audio (mute/volume) settings immediately to the
    /// currently playing wallpaper, without recreating any windows or
    /// restarting playback. Also remembered for windows created afterwards
    /// (new plays, auto-reopen after wake/screen changes).
    func setAudioSettings(enabled: Bool, volume: Double) {
        audioEnabled = enabled
        audioVolume = volume
        windows.forEach { $0.setAudio(enabled: enabled, volume: volume) }
    }

    func setDisplayMode(_ displayMode: WallpaperDisplayMode) {
        self.displayMode = displayMode
        windows.forEach {
            $0.setDisplayMode(displayMode)
        }
    }

    func setAutoPauseWhenCovered(_ enabled: Bool) {
        autoPauseWhenCovered = enabled
        if !enabled {
            cancelPendingAutoSuspension()
            setSuspended(false)
        }
        updateVisibilityState()
    }

    /// Called once a scene->video render finishes so the newly cached video
    /// swaps in for the still-live native scene fallback.
    func refreshIfNeeded(afterSceneVideoRenderFor assetId: String) {
        guard let activeAsset, activeAsset.id == assetId, activeAsset.kind == .scene else {
            return
        }
        try? reopen(asset: activeAsset)
    }

    func restoreVisibleWindowsAfterAppWindowChange() {
        updateVisibilityState()
        guard !isSuspended else {
            return
        }
        reassertWallpaperWindowOrder()
    }

    func stop() {
        activeAsset = nil
        lastScreenFrames = []
        cancelPendingAutoSuspension()
        stopVisibilityTimer()
        stopLifecycleObservers()
        closeWindows()
    }

    private func closeWindows() {
        windows.forEach { $0.close() }
        windows = []
    }

    private func reopen(asset: WallpaperAsset) throws {
        guard let entrypoint = asset.entrypoint else {
            throw PlaybackError.missingEntrypoint
        }
        closeWindows()
        let url = URL(filePath: entrypoint)
        let screens = NSScreen.screens
        let screenFrames = WallpaperScreenFrames.wallpaperFrames(for: screens)
        windows = try screenFrames.map { frame in
            try WallpaperWindow(
                asset: asset,
                url: url,
                frame: frame,
                displayMode: displayMode,
                audioEnabled: audioEnabled,
                audioVolume: audioVolume
            )
        }
        lastScreenFrames = screenFrames
        windows.forEach { $0.show() }
        updateVisibilityState()
    }

    private func startVisibilityTimer() {
        stopVisibilityTimer()
        visibilityTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateVisibilityState()
            }
        }
        if let visibilityTimer {
            RunLoop.main.add(visibilityTimer, forMode: .common)
        }
    }

    private func stopVisibilityTimer() {
        visibilityTimer?.invalidate()
        visibilityTimer = nil
    }

    private func updateVisibilityState() {
        let shouldSuspend = autoPauseWhenCovered && !visibilityMonitor.isDesktopVisible()
        if shouldSuspend {
            scheduleAutoSuspension()
        } else {
            cancelPendingAutoSuspension()
            setSuspended(false)
        }
    }

    private func setSuspended(_ suspended: Bool) {
        guard isSuspended != suspended else {
            return
        }
        isSuspended = suspended
        windows.forEach { $0.setSuspended(suspended) }
    }

    private func scheduleAutoSuspension() {
        guard pendingAutoSuspension == nil, !isSuspended else {
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.autoPauseWhenCovered, !self.visibilityMonitor.isDesktopVisible() else {
                    return
                }
                self.pendingAutoSuspension = nil
                self.setSuspended(true)
            }
        }
        pendingAutoSuspension = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
    }

    private func cancelPendingAutoSuspension() {
        pendingAutoSuspension?.cancel()
        pendingAutoSuspension = nil
    }

    private func startLifecycleObservers() {
        guard workspaceObservers.isEmpty else {
            return
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.setSuspended(true) }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reopenAfterWake() }
            },
            center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.scheduleWallpaperWindowOrderReassertion() }
            },
            center.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.scheduleWallpaperWindowOrderReassertion() }
            },
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.reopenAfterScreenFrameChange() }
            }
        ]
    }

    private func stopLifecycleObservers() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { observer in
            center.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        workspaceObservers = []
    }

    private func reopenAfterWake() {
        guard let activeAsset else {
            return
        }
        do {
            try play(asset: activeAsset, autoPauseWhenCovered: autoPauseWhenCovered, displayMode: displayMode)
        } catch {
            closeWindows()
        }
    }

    private func reopenAfterScreenFrameChange() {
        guard activeAsset != nil else {
            return
        }
        let currentScreenFrames = WallpaperScreenFrames.wallpaperFrames(for: NSScreen.screens)
        guard WallpaperScreenFrames.shouldReopenWindows(
            previous: lastScreenFrames,
            current: currentScreenFrames
        ) else {
            reassertWallpaperWindowOrder()
            return
        }
        reopenAfterWake()
    }

    private func reassertWallpaperWindowOrder() {
        windows.forEach { $0.reassertDesktopOrder() }
    }

    private func scheduleWallpaperWindowOrderReassertion() {
        wakeWallpaperForAppTransition()
        reassertWallpaperWindowOrder()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            Task { @MainActor in
                self?.updateVisibilityState()
                self?.reassertWallpaperWindowOrder()
            }
        }
    }

    private func wakeWallpaperForAppTransition() {
        guard autoPauseWhenCovered else {
            return
        }
        cancelPendingAutoSuspension()
        setSuspended(false)
        updateVisibilityState()
    }
}

enum WallpaperScreenFrames {
    static func wallpaperFrames(for screens: [NSScreen]) -> [CGRect] {
        screens.map { wallpaperFrame(screenFrame: $0.frame, visibleFrame: $0.visibleFrame) }
    }

    static func wallpaperFrame(screenFrame: CGRect, visibleFrame _: CGRect) -> CGRect {
        screenFrame
    }

    static func shouldReopenWindows(previous: [CGRect], current: [CGRect]) -> Bool {
        normalized(previous) != normalized(current)
    }

    private static func normalized(_ frames: [CGRect]) -> [CGRect] {
        frames.sorted { lhs, rhs in
            if lhs.minX != rhs.minX {
                return lhs.minX < rhs.minX
            }
            if lhs.minY != rhs.minY {
                return lhs.minY < rhs.minY
            }
            if lhs.width != rhs.width {
                return lhs.width < rhs.width
            }
            return lhs.height < rhs.height
        }
    }
}

@MainActor
private final class WallpaperWindow {
    private let window: NSWindow
    private let content: NSView

    init(asset: WallpaperAsset,
        url: URL,
        frame: CGRect,
        displayMode: WallpaperDisplayMode,
        audioEnabled: Bool = false,
        audioVolume: Double = 0.5
    ) throws {
        content = try Self.makeContentView(
            asset: asset,
            url: url,
            frame: frame,
            displayMode: displayMode,
            audioEnabled: audioEnabled,
            audioVolume: audioVolume
        )
        window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = WallpaperWindowLevel.desktopWallpaper
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true
        window.canHide = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.isExcludedFromWindowsMenu = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = content
    }

    func show() {
        guard !window.isVisible else {
            return
        }
        window.orderFrontRegardless()
    }

    func reassertDesktopOrder() {
        window.orderFrontRegardless()
    }

    func close() {
        (content as? WallpaperContentLifecycle)?.prepareForClose()
        window.contentView = nil
        window.close()
    }

    func setSuspended(_ suspended: Bool) {
        (content as? PausableWallpaperContent)?.setPlaybackSuspended(suspended)
    }

    func setDisplayMode(_ displayMode: WallpaperDisplayMode) {
        (content as? DisplayModeUpdatableContent)?.setDisplayMode(displayMode)
    }

    func setAudio(enabled: Bool, volume: Double) {
        (content as? AudioControllableWallpaperContent)?.setAudioEnabled(enabled, volume: volume)
    }

    private static func makeContentView(
        asset: WallpaperAsset,
        url: URL,
        frame: CGRect,
        displayMode: WallpaperDisplayMode,
        audioEnabled: Bool = false,
        audioVolume: Double = 0.5
    ) throws -> NSView {
        let contentFrame = WallpaperContentLayout.contentFrame(for: frame)
        switch asset.kind {
        case .video:
            let fallbackImageURL = try? StillWallpaperImageProvider().stillImageURL(for: asset)
            return VideoWallpaperView(
                url: url,
                fallbackImageURL: fallbackImageURL,
                frame: contentFrame,
                displayMode: displayMode,
                audioEnabled: audioEnabled,
                audioVolume: audioVolume
            )
        case .web:
            return RestrictedWebWallpaperView(
                url: url,
                readAccessURL: URL(filePath: asset.projectDirectory),
                frame: contentFrame
            )
        case .image:
            guard let image = NSImage(contentsOf: url) else {
                throw PlaybackError.invalidImage
            }
            return ImageWallpaperView(image: image, frame: contentFrame, displayMode: displayMode)
        case .scene:
            let previewURL = asset.thumbnail.map { URL(filePath: $0) }
            return try SceneWallpaperContentFactory.makeSceneContentView(
                asset: asset,
                url: url,
                previewURL: previewURL,
                frame: contentFrame,
                displayMode: displayMode,
                audioEnabled: audioEnabled,
                audioVolume: audioVolume
            )
        case .unknown:
            throw PlaybackError.notPlayable(asset.kind.rawValue)
        }
    }
}

@MainActor
enum SceneWallpaperContentFactory {
    static var lastDiagnostic: String?
    static var statusHandler: ((String) -> Void)?
    /// Invoked with the asset id once a scene's video render finishes
    /// (successfully), after `WallpaperPlayer` has already swapped the
    /// desktop wallpaper over to the freshly cached video. Lets callers also
    /// refresh anything else derived from "does this scene have a cached
    /// video yet" (the lock screen animation configuration) without this
    /// factory needing to know about that dependency directly.
    static var sceneVideoRenderCompletionHandler: ((String) -> Void)?
    private static var pendingRenderAssetIDs = Set<String>()

    static func makeSceneContentView(
        asset: WallpaperAsset,
        url: URL,
        previewURL: URL? = nil,
        frame: CGRect,
        displayMode: WallpaperDisplayMode,
        audioEnabled: Bool = false,
        audioVolume: Double = 0.5
    ) throws -> NSView {
        lastDiagnostic = nil
        guard SceneEngineRendererConfiguration.isScenePackage(url, inside: asset.projectDirectory) else {
            return try SceneWallpaperView(
                url: url,
                previewURL: previewURL,
                frame: frame,
                displayMode: displayMode
            )
        }
        if let cachedVideoURL = SceneVideoCache.freshCachedVideoURL(assetId: asset.id, sourceURL: url) {
            // Scene videos are a rendered wallpaper loop, not a user-picked
            // video file: they should always cover the whole desktop
            // regardless of the app's general fit/fill/stretch preference,
            // so the display mode is fixed to `.fill` here rather than
            // forwarding the caller's `displayMode`.
            return VideoWallpaperView(
                url: cachedVideoURL,
                fallbackImageURL: previewURL,
                frame: frame,
                displayMode: .fill,
                audioEnabled: audioEnabled,
                audioVolume: audioVolume
            )
        }
        guard let rendererURL = SceneEngineRendererConfiguration.executableURL(),
              let assetsDirectory = SceneEngineRendererConfiguration.assetsDirectoryURL(),
              let ffmpegPath = VideoConverter().ffmpegPath() else {
            lastDiagnostic = "scene video rendering skipped: \(missingRenderingComponentDescription())"
            return try SceneWallpaperView(
                url: url,
                previewURL: previewURL,
                frame: frame,
                displayMode: displayMode
            )
        }
        scheduleSceneVideoRender(
            asset: asset,
            sceneURL: url,
            rendererURL: rendererURL,
            assetsDirectory: assetsDirectory,
            ffmpegPath: ffmpegPath,
            frame: frame
        )
        lastDiagnostic = "scene video rendering in progress"
        statusHandler?("Rendering scene to video… 0%")
        return try SceneWallpaperView(
            url: url,
            previewURL: previewURL,
            frame: frame,
            displayMode: displayMode
        )
    }

    private static func missingRenderingComponentDescription() -> String {
        var missing: [String] = []
        if SceneEngineRendererConfiguration.executableURL() == nil {
            missing.append("scene renderer binary")
        }
        if SceneEngineRendererConfiguration.assetsDirectoryURL() == nil {
            missing.append("Wallpaper Engine assets folder")
        }
        if VideoConverter().ffmpegPath() == nil {
            missing.append("ffmpeg")
        }
        return missing.isEmpty ? "unknown reason" : missing.joined(separator: ", ")
    }

    private static func scheduleSceneVideoRender(
        asset: WallpaperAsset,
        sceneURL: URL,
        rendererURL: URL,
        assetsDirectory: URL,
        ffmpegPath: String,
        frame: CGRect
    ) {
        guard !pendingRenderAssetIDs.contains(asset.id) else {
            return
        }
        pendingRenderAssetIDs.insert(asset.id)
        // Record at a clamped size derived from the display's logical
        // (point) size, not its physical/backing pixel size: recording at
        // full retina resolution produces multi-hundred-megabyte clips that
        // take minutes to render for no visible benefit on a wallpaper
        // viewed from normal desktop distance.
        let recordSize = SceneVideoRecordSize.clampedRecordSize(forLogicalSize: frame.size)
        let configuration = SceneVideoRenderConfiguration(
            assetId: asset.id,
            projectDirectory: URL(filePath: asset.projectDirectory).standardizedFileURL,
            assetsDirectory: assetsDirectory,
            rendererURL: rendererURL,
            size: recordSize,
            sceneURL: sceneURL
        )
        let assetId = asset.id
        Task.detached(priority: .utility) {
            do {
                _ = try SceneVideoRenderer.render(
                    configuration: configuration,
                    ffmpegPath: ffmpegPath,
                    progressHandler: { progress in
                        let percent = Int((progress * 100).rounded())
                        Task { @MainActor in
                            guard pendingRenderAssetIDs.contains(assetId) else {
                                return
                            }
                            statusHandler?("Rendering scene to video… \(percent)%")
                        }
                    }
                )
                await MainActor.run {
                    pendingRenderAssetIDs.remove(assetId)
                    statusHandler?("Playing")
                    WallpaperPlayer.shared.refreshIfNeeded(afterSceneVideoRenderFor: assetId)
                    sceneVideoRenderCompletionHandler?(assetId)
                }
            } catch {
                await MainActor.run {
                    pendingRenderAssetIDs.remove(assetId)
                    lastDiagnostic = "scene video render failed: \(error.localizedDescription)"
                    statusHandler?("Scene video render failed: \(error.localizedDescription)")
                }
            }
        }
    }
}

@MainActor
enum SceneEngineRendererConfiguration {
    static let environmentVariableName = "WWB_SCENE_ENGINE_RENDERER"
    static let assetsEnvironmentVariableName = "WWB_SCENE_ENGINE_ASSETS_DIR"
    static var overrideExecutablePath: String?
    static var overrideAssetsPath: String?
    static var overrideResourceURL: URL?
    static var overrideDefaultAssetsDirectoryURL: URL?

    nonisolated static let requiredAssetPaths = [
        "models/util/composelayer.json",
        "materials/util/composelayer.json",
        "materials/util/effectpassthrough.json",
        "materials/util/downsample_quarter_bloom.json",
        "materials/util/downsample_eighth_blur_v.json",
        "materials/util/blur_h_bloom.json",
        "materials/util/combine.json",
        "shaders/genericimage2.frag",
        "shaders/genericimage2.vert",
        "shaders/common_blur.h",
        "shaders/genericparticle.vert",
        "shaders/genericparticle.frag"
    ]

    static func executableURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let path = overrideExecutablePath ?? environment[environmentVariableName],
           !path.isEmpty {
            let url = URL(filePath: path).standardizedFileURL
            if isRegularExecutable(url) {
                return url
            }
        }
        guard let bundledURL = (overrideResourceURL ?? Bundle.main.resourceURL)?
            .appending(path: "Renderers")
            .appending(path: "wwb-scene-renderer")
            .standardizedFileURL,
            isRegularExecutable(bundledURL) else {
                return nil
        }
        return bundledURL
    }

    static func assetsDirectoryURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let path = environment[assetsEnvironmentVariableName] ?? overrideAssetsPath,
           !path.isEmpty {
            let url = URL(filePath: path).standardizedFileURL
            return isValidAssetsDirectory(url) ? url : nil
        }
        guard let url = defaultAssetsDirectoryURL() else {
            return nil
        }
        return isValidAssetsDirectory(url) ? url : nil
    }

    static func isScenePackage(_ url: URL, inside projectDirectory: String) -> Bool {
        guard url.pathExtension.lowercased() == "pkg" else {
            return false
        }
        let project = URL(filePath: projectDirectory).standardizedFileURL.resolvingSymlinksInPath()
        let scene = url.standardizedFileURL.resolvingSymlinksInPath()
        let projectComponents = project.pathComponents
        let sceneComponents = scene.pathComponents
        guard sceneComponents.count > projectComponents.count else {
            return false
        }
        return Array(sceneComponents.prefix(projectComponents.count)) == projectComponents
    }

    static func defaultAssetsDirectoryURL() -> URL? {
        if let overrideDefaultAssetsDirectoryURL {
            return overrideDefaultAssetsDirectoryURL.standardizedFileURL
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "WorkshopWallpaperBridge")
            .appending(path: "wallpaper-engine-assets")
            .standardizedFileURL
    }

    static func isValidAssetsDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true,
              values.isSymbolicLink != true else {
            return false
        }
        return hasRegularFile(url.appending(path: "materials/util/composelayer.json"))
            || hasDirectory(url.appending(path: "shaders"))
    }

    private static func hasRegularFile(_ url: URL) -> Bool {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func hasDirectory(_ url: URL) -> Bool {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil,
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func isRegularExecutable(_ url: URL) -> Bool {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
            return false
        }
        guard FileManager.default.isExecutableFile(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
}

@MainActor
private final class ImageWallpaperView: NSView, DisplayModeUpdatableContent {
    private let image: NSImage
    private var displayMode: WallpaperDisplayMode

    init(image: NSImage, frame: CGRect, displayMode: WallpaperDisplayMode) {
        self.image = image
        self.displayMode = displayMode
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        configureLayer()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        configureLayer()
    }

    private func configureLayer() {
        guard let layer else {
            return
        }
        layer.frame = bounds
        layer.backgroundColor = NSColor.black.cgColor
        layer.contentsGravity = WallpaperContentLayout.imageContentsGravity(for: displayMode)
        layer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer.minificationFilter = .linear
        layer.magnificationFilter = .linear
        layer.contents = image
    }

    func setDisplayMode(_ displayMode: WallpaperDisplayMode) {
        self.displayMode = displayMode
        configureLayer()
    }
}

private enum PlaybackError: Error, LocalizedError {
    case missingEntrypoint
    case invalidImage
    case notPlayable(String)

    var errorDescription: String? {
        switch self {
        case .missingEntrypoint:
            return "The selected project has no playable entrypoint."
        case .invalidImage:
            return "The selected image could not be opened."
        case .notPlayable(let reason):
            return "This project is not playable on macOS: \(reason)."
        }
    }
}
