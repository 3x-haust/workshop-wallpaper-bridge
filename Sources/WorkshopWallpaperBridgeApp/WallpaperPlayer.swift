import AppKit
import WorkshopWallpaperCore

enum WallpaperPlaybackEvent: Equatable {
    case ready(assetID: String)
    case failed(assetID: String, message: String)
}

@MainActor
final class WallpaperPlayer {
    static let shared = WallpaperPlayer()

    private lazy var sessions: DisplayPlaybackSessions = {
        let sessions = DisplayPlaybackSessions { [makeWindow] asset, display, mode, audio, volume in
            guard let entrypoint = asset.entrypoint else { throw PlaybackError.missingEntrypoint }
            return try makeWindow(asset, URL(filePath: entrypoint), display.frame, mode, audio, volume)
        }
        sessions.playbackStatusHandler = { [weak self] event in
            guard let self else { return }
            if case .ready = event { self.updateVisibilityState() }
            self.playbackStatusHandler?(event)
        }
        return sessions
    }()
    private var windows: [any DisplayWallpaperWindow] { Array(sessions.windows.values) }
    private let connectedDisplays: () -> [WallpaperDisplay]
    private let makeWindow: (WallpaperAsset, URL, CGRect, WallpaperDisplayMode, Bool, Double) throws -> any WallpaperWindowControlling
    private var playbackStatusHandler: ((WallpaperPlaybackEvent) -> Void)?
    var errorHandler: ((String) -> Void)?
    private var autoPauseWhenCovered: Bool { sessions.autoPauseWhenCovered }

    func setPlaybackStatusHandler(_ handler: @escaping (WallpaperPlaybackEvent) -> Void) {
        playbackStatusHandler = handler
    }
    private var interactionEnabled = false
    private var visibilityTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var coveredSince: [String: Date] = [:]
    private var systemSleeping = false
    private var screensSleeping = false
    private var pendingAutoSuspension: DispatchWorkItem?
    private let visibilityMonitor = DesktopVisibilityMonitor()

    init(
        screenFrames: (() -> [CGRect])? = nil,
        makeWindow: @escaping (WallpaperAsset, URL, CGRect, WallpaperDisplayMode, Bool, Double) throws -> any WallpaperWindowControlling = {
            try WallpaperWindow(asset: $0, url: $1, frame: $2, displayMode: $3, audioEnabled: $4, audioVolume: $5)
        }
    ) {
        if let screenFrames {
            connectedDisplays = {
                screenFrames().enumerated().map { index, frame in
                    WallpaperDisplay(id: "screen-\(index)", name: "Display \(index + 1)",
                                     frame: frame, scale: 1, isPrimary: index == 0)
                }
            }
        } else {
            connectedDisplays = { WallpaperDisplay.connected() }
        }
        self.makeWindow = makeWindow
    }

    func play(
        asset: WallpaperAsset,
        autoPauseWhenCovered: Bool = true,
        displayMode: WallpaperDisplayMode = .fit,
        audioEnabled: Bool? = nil,
        audioVolume: Double? = nil
    ) throws {
        try play(asset: asset, on: Set(connectedDisplays().map(\.id)),
                 autoPauseWhenCovered: autoPauseWhenCovered, displayMode: displayMode,
                 audioEnabled: audioEnabled, audioVolume: audioVolume)
    }

    func play(
        asset: WallpaperAsset, on displayIDs: Set<String>,
        autoPauseWhenCovered: Bool, displayMode: WallpaperDisplayMode,
        audioEnabled: Bool?, audioVolume: Double?
    ) throws {
        try play(asset: asset, on: displayIDs, autoPauseWhenCovered: autoPauseWhenCovered,
                 displayMode: displayMode, audioEnabled: audioEnabled, audioVolume: audioVolume,
                 completion: { _ in })
    }

    func play(
        asset: WallpaperAsset, on displayIDs: Set<String>,
        autoPauseWhenCovered: Bool, displayMode: WallpaperDisplayMode,
        audioEnabled: Bool?, audioVolume: Double?,
        completion: @escaping (Result<Set<String>, Error>) -> Void
    ) throws {
        report(sessions.reconcile(connectedDisplays()))
        sessions.interactionEnabled = interactionEnabled
        try sessions.play(asset: asset, on: displayIDs, mode: displayMode,
                          audioEnabled: audioEnabled, audioVolume: audioVolume,
                          autoPauseWhenCovered: autoPauseWhenCovered, completion: completion)
        startLifecycleObservers()
        startVisibilityTimer()
        updateVisibilityState()
    }

    func cancelPendingPlayback() {
        cancelPendingPlayback(on: sessions.pendingDisplayIDs)
    }

    func cancelPendingPlayback(on displayIDs: Set<String>) {
        sessions.cancelPendingPlayback(on: displayIDs)
    }

    /// Updates mouse handling on current and future wallpaper windows.
    func setInteractionEnabled(_ enabled: Bool) {
        interactionEnabled = enabled
        sessions.interactionEnabled = enabled
        sessions.applySettings()
    }

    /// Applies mute/volume without recreating windows or restarting playback.
    func setAudioSettings(enabled: Bool, volume: Double) {
        sessions.setAudioSettings(enabled: enabled, volume: volume)
    }

    func setDisplayMode(_ displayMode: WallpaperDisplayMode) {
        setDisplayMode(displayMode, on: Set(sessions.assignments.keys).union(sessions.pendingDisplayIDs))
    }

    func setDisplayMode(_ mode: WallpaperDisplayMode, on displayIDs: Set<String>) {
        sessions.setMode(mode, on: displayIDs)
    }

    func setAutoPauseWhenCovered(_ enabled: Bool) {
        sessions.setAutoPauseWhenCovered(enabled)
        if !enabled {
            cancelPendingAutoSuspension()
            setSuspended(false)
        }
        updateVisibilityState()
    }

    /// Called once a scene->video render finishes so the newly cached video
    /// swaps in for the still-live native scene fallback.
    func isPlaying(assetID: String) -> Bool {
        sessions.assignments.values.contains { $0.asset.id == assetID }
    }

    func refreshIfNeeded(afterSceneVideoRenderFor assetId: String) {
        report(sessions.refreshScene(assetID: assetId))
    }

    func restoreVisibleWindowsAfterAppWindowChange() {
        updateVisibilityState()
        guard !sessions.sleeping else {
            return
        }
        reassertWallpaperWindowOrder()
    }

    func stop() {
        SceneWallpaperContentFactory.invalidateBackgroundRefresh()
        sessions.stop(on: Set(sessions.assignments.keys).union(sessions.pendingDisplayIDs))
        coveredSince = [:]
        systemSleeping = false
        screensSleeping = false
        sessions.setSleeping(false)
        cancelPendingAutoSuspension()
        stopVisibilityTimer()
        stopLifecycleObservers()
    }

    func stop(on displayIDs: Set<String>) {
        sessions.stop(on: displayIDs)
        for id in displayIDs { coveredSince.removeValue(forKey: id) }
        if sessions.assignments.isEmpty && sessions.pendingDisplayIDs.isEmpty { stop() }
    }

    private func report(_ errors: [String]) {
        if !errors.isEmpty { errorHandler?(errors.joined(separator: "\n")) }
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
        guard !sessions.sleeping else { return }
        guard autoPauseWhenCovered else {
            cancelPendingAutoSuspension()
            setSuspended(false)
            return
        }
        let covered = visibilityMonitor.coveredDisplayIDs(sessions.displays)
        let now = Date()
        coveredSince = coveredSince.filter { covered.contains($0.key) }
        for id in covered where coveredSince[id] == nil { coveredSince[id] = now }
        sessions.setCovered(Set(coveredSince.compactMap { id, since in
            now.timeIntervalSince(since) >= 1.5 ? id : nil
        }))
        if covered != sessions.coveredIDs { scheduleAutoSuspension() }
    }

    private func setSuspended(_ suspended: Bool) {
        if !suspended { coveredSince = [:] }
        sessions.setCovered(suspended ? Set(sessions.windows.keys) : [])
    }

    private func scheduleAutoSuspension() {
        guard pendingAutoSuspension == nil else {
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.pendingAutoSuspension = nil
                self.updateVisibilityState()
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
                Task { @MainActor in
                    self?.systemSleeping = true
                    self?.cancelPendingAutoSuspension()
                    self?.sessions.setSleeping(true)
                }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.systemSleeping = false
                    self?.reopenAfterWake()
                }
            },
            center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.screensSleeping = true
                    self?.cancelPendingAutoSuspension()
                    self?.sessions.setSleeping(true)
                }
            },
            center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.screensSleeping = false
                    self?.reopenAfterWake()
                }
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

    func reopenAfterWake() {
        report(sessions.reconcile(connectedDisplays()))
        sessions.setSleeping(systemSleeping || screensSleeping)
        updateVisibilityState()
        reassertWallpaperWindowOrder()
    }

    private func reopenAfterScreenFrameChange() {
        report(sessions.reconcile(connectedDisplays()))
        updateVisibilityState()
        reassertWallpaperWindowOrder()
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
            if lhs.minX != rhs.minX { return lhs.minX < rhs.minX }
            if lhs.minY != rhs.minY { return lhs.minY < rhs.minY }
            if lhs.width != rhs.width { return lhs.width < rhs.width }
            return lhs.height < rhs.height
        }
    }
}

/// Borderless wallpapers need explicit focus support for native web controls.
@MainActor
final class DesktopWallpaperWindow: NSWindow {
    private var interactionEnabled = false
    override var canBecomeKey: Bool { interactionEnabled }
    override var canBecomeMain: Bool { false }

    func setInteractionEnabled(_ enabled: Bool) {
        interactionEnabled = enabled
        ignoresMouseEvents = !enabled
        acceptsMouseMovedEvents = enabled
        level = enabled
            ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            : WallpaperWindowLevel.desktopWallpaper
        if !enabled, isKeyWindow { resignKey() }
    }
}

@MainActor
enum WallpaperInteraction {
    static func supports(_ content: NSView) -> Bool {
        content is SceneWallpaperView || content is RestrictedWebWallpaperView || content is MediaSceneWallpaperView
    }
}

@MainActor
private final class WallpaperWindow: DisplayWallpaperWindow {
    private let window: DesktopWallpaperWindow
    private let content: NSView
    private let isSceneVideo: Bool

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
            // Preparation may start decoding, but must not overlap audible playback.
            audioEnabled: false,
            audioVolume: audioVolume
        )
        isSceneVideo = asset.kind == .scene && content is VideoWallpaperView
        window = DesktopWallpaperWindow(
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
        (content as? PausableWallpaperContent)?.setPlaybackSuspended(true)
    }

    func whenReady(_ completion: @escaping (Result<Void, Error>) -> Void) {
        if let preparing = content as? WallpaperContentPreparing {
            preparing.whenReady(completion)
        } else {
            completion(.success(()))
        }
    }

    func updateDisplay(_ display: WallpaperDisplay) {
        window.setFrame(display.frame, display: true)
        content.frame = WallpaperContentLayout.contentFrame(for: display.frame)
        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
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
        (content as? DisplayModeUpdatableContent)?.setDisplayMode(isSceneVideo ? .fill : displayMode)
    }

    func setInteractionEnabled(_ enabled: Bool) {
        let interactive = enabled && WallpaperInteraction.supports(content)
        window.setInteractionEnabled(interactive)
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
                audioVolume: audioVolume,
                assetID: asset.id
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
    static var prefersLivePlayback = true
    static var lastDiagnostic: String?
    static var statusHandler: ((String) -> Void)?
    /// Invoked with the asset id once a scene's video render finishes
    /// (successfully), after `WallpaperPlayer` has requested preparation of
    /// the freshly cached video. Playback readiness is reported separately. Lets callers also
    /// refresh anything else derived from "does this scene have a cached
    /// video yet" (the lock screen animation configuration) without this
    /// factory needing to know about that dependency directly.
    static var sceneVideoRenderCompletionHandler: ((String) -> Void)?
    private enum PlaybackPlan {
        case native(SceneRenderPlan?)
        case media(SceneMediaOverlayPlan)
        case video
    }

    /// Preparation and window creation must agree about live layers and cache identity.
    private static func playbackPlan(asset: WallpaperAsset, url: URL) -> PlaybackPlan {
        guard SceneEngineRendererConfiguration.isScenePackage(url, inside: asset.projectDirectory) else {
            return .native(nil)
        }
        if prefersLivePlayback {
            let builder = SceneRenderPlanBuilder()
            if let layout = try? builder.buildLayout(url: url), layout.canPreferLivePlayback,
               let decoded = try? builder.build(url: url), decoded.canPreferLivePlayback {
                return .native(decoded)
            }
            if let media = try? SceneMediaOverlayPlan.build(url: url) { return .media(media) }
        }
        return .video
    }

    static var renderingTools: () throws -> (renderer: URL, assets: URL, ffmpeg: String) = {
        guard let renderer = SceneEngineRendererConfiguration.executableURL(),
              let assets = SceneEngineRendererConfiguration.assetsDirectoryURL(),
              let ffmpeg = VideoConverter().ffmpegPath() else {
            throw ScenePreparationError.unavailable(missingRenderingComponentDescription())
        }
        return (renderer, assets, ffmpeg)
    }

    /// Only this boundary starts external processes; tests supply a controlled renderer.
    static var renderVideo: @MainActor (SceneVideoRenderConfiguration, String, @escaping @MainActor (Double) -> Void) async throws -> URL = { configuration, ffmpeg, progress in
        try await Task.detached(priority: .utility) {
            try SceneVideoRenderer.render(configuration: configuration, ffmpegPath: ffmpeg) { value in
                Task { @MainActor in progress(value) }
            }
        }.value
    }

    @MainActor
    private final class RenderJob {
        let assetID: String
        var refreshPlayback: Bool
        var progress = 0.0
        var result: Result<URL, Error>?
        var waiters: [UUID: (continuation: CheckedContinuation<URL, Error>, progress: @MainActor (Double) -> Void)] = [:]

        init(assetID: String, refreshPlayback: Bool) {
            self.assetID = assetID
            self.refreshPlayback = refreshPlayback
        }
    }
    // A cancelled waiter never releases this cache-write slot. The blocking external
    // renderer owns it until it exits, so a retry cannot race its final cache move.
    private static var renderJobs: [URL: RenderJob] = [:]

    static func isRendering(assetID: String) -> Bool {
        renderJobs.values.contains { $0.assetID == assetID }
    }

    static func invalidateBackgroundRefresh() {
        for job in renderJobs.values { job.refreshPlayback = false }
    }

    static func cancelWorkshopPreparations() {
        for job in renderJobs.values {
            let waiters = job.waiters.values
            job.waiters.removeAll()
            for waiter in waiters { waiter.continuation.resume(throwing: CancellationError()) }
        }
    }

    static func prepare(
        asset: WallpaperAsset,
        frame: CGRect,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws {
        try Task.checkCancellation()
        guard asset.supportStatus == .playable else { throw PlaybackError.notPlayable(asset.supportStatus.rawValue) }
        guard let entrypoint = asset.entrypoint else { throw PlaybackError.missingEntrypoint }
        progress(0)
        guard asset.kind == .scene else { progress(1); return }
        let url = URL(filePath: entrypoint)
        let cacheID: String
        let excludedIDs: [Int]
        let logicalSize: CGSize
        switch playbackPlan(asset: asset, url: url) {
        case .native(let decoded):
            let plan = try decoded ?? SceneRenderPlanBuilder().build(url: url)
            guard plan.nativePlaybackIssues.isEmpty, plan.omittedLayerCount == 0 else {
                throw ScenePreparationError.incomplete
            }
            progress(1)
            return
        case .media(let plan):
            cacheID = asset.id + plan.cacheSuffix
            excludedIDs = plan.excludedIDs
            logicalSize = plan.canvas
        case .video:
            cacheID = asset.id
            excludedIDs = []
            let canvas = try SceneRenderPlanBuilder().canvasSize(url: url)
            logicalSize = CGSize(width: canvas.width, height: canvas.height)
        }
        if SceneVideoCache.freshCachedVideoURL(assetId: cacheID, sourceURL: url) != nil {
            progress(1)
            return
        }
        let key = SceneVideoCache.cachedVideoURL(assetId: cacheID).standardizedFileURL
        let job: RenderJob
        if let running = renderJobs[key] {
            job = running
        } else {
            let tools = try renderingTools()
            let configuration = SceneVideoRenderConfiguration(
                assetId: cacheID,
                projectDirectory: URL(filePath: asset.projectDirectory).standardizedFileURL,
                assetsDirectory: tools.assets,
                rendererURL: tools.renderer,
                size: SceneVideoRecordSize.clampedRecordSize(forLogicalSize: logicalSize),
                sceneURL: url,
                excludedObjectIDs: excludedIDs
            )
            job = startRender(configuration: configuration, ffmpegPath: tools.ffmpeg,
                              assetID: asset.id, refreshPlayback: false)
        }
        _ = try await waitForRender(job, progress: progress)
        try Task.checkCancellation()
        guard SceneVideoCache.freshCachedVideoURL(assetId: cacheID, sourceURL: url) != nil else {
            throw ScenePreparationError.incomplete
        }
        progress(1)
    }

    private static func waitForRender(_ job: RenderJob, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if let result = job.result { continuation.resume(with: result); return }
                job.waiters[waiterID] = (continuation, progress)
                progress(job.progress)
            }
        } onCancel: {
            Task { @MainActor in
                job.waiters.removeValue(forKey: waiterID)?.continuation.resume(throwing: CancellationError())
            }
        }
    }

    private static func startRender(
        configuration: SceneVideoRenderConfiguration, ffmpegPath: String,
        assetID: String, refreshPlayback: Bool
    ) -> RenderJob {
        let key = SceneVideoCache.cachedVideoURL(assetId: configuration.assetId).standardizedFileURL
        if let existing = renderJobs[key] {
            existing.refreshPlayback = existing.refreshPlayback || refreshPlayback
            return existing
        }
        let job = RenderJob(assetID: assetID, refreshPlayback: refreshPlayback)
        renderJobs[key] = job
        let render = renderVideo
        Task {
            let result: Result<URL, Error>
            do {
                let output = try await render(configuration, ffmpegPath) { value in
                    guard job.result == nil, value.isFinite else { return }
                    // The renderer reports recording progress before encoding and muxing.
                    // Reserve completion for the committed, fresh cache, not its last frame.
                    job.progress = max(job.progress, min(0.95, max(0, value) * 0.95))
                    for waiter in job.waiters.values { waiter.progress(job.progress) }
                    if job.refreshPlayback, WallpaperPlayer.shared.isPlaying(assetID: assetID) {
                        statusHandler?("Rendering scene to video… \(Int((job.progress * 100).rounded()))%")
                    }
                }
                result = .success(output)
            } catch {
                result = .failure(error)
            }
            job.result = result
            renderJobs.removeValue(forKey: key)
            let waiters = job.waiters.values
            job.waiters.removeAll()
            for waiter in waiters { waiter.continuation.resume(with: result) }
            guard job.refreshPlayback else { return }
            switch result {
            case .success:
                if WallpaperPlayer.shared.isPlaying(assetID: assetID) { statusHandler?("Scene video render complete.") }
                WallpaperPlayer.shared.refreshIfNeeded(afterSceneVideoRenderFor: assetID)
                sceneVideoRenderCompletionHandler?(assetID)
            case .failure(let error):
                lastDiagnostic = "scene video render failed: \(error.localizedDescription)"
                if WallpaperPlayer.shared.isPlaying(assetID: assetID) {
                    statusHandler?("Scene video render failed: \(error.localizedDescription)")
                }
            }
        }
        return job
    }

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
        let plan = playbackPlan(asset: asset, url: url)
        if case .native(let decoded) = plan {
            if decoded != nil { lastDiagnostic = "live SceneScript playback" }
            return try SceneWallpaperView(url: url, previewURL: previewURL, frame: frame,
                                          displayMode: displayMode, decodedPlan: decoded)
        }
        if case .media(let mediaPlan) = plan {
            let cacheID = asset.id + mediaPlan.cacheSuffix
            if let video = SceneVideoCache.freshCachedVideoURL(assetId: cacheID, sourceURL: url) {
                lastDiagnostic = "live media scene playback"
                return MediaSceneWallpaperView(videoURL: video, previewURL: previewURL, plan: mediaPlan,
                    frame: frame, audioEnabled: audioEnabled, audioVolume: audioVolume)
            }
            if let tools = try? renderingTools() {
                scheduleSceneVideoRender(asset: asset, sceneURL: url, rendererURL: tools.renderer,
                    assetsDirectory: tools.assets, ffmpegPath: tools.ffmpeg, frame: frame,
                    cacheAssetID: cacheID, excludedObjectIDs: mediaPlan.excludedIDs,
                    recordingCanvas: mediaPlan.canvas)
            }
            // Until the background with these exact exclusions is ready, keep
            // the old whole-scene video. Never stack live layers over baked ones.
            let previous = SceneVideoCache.freshCachedVideoURL(assetId: asset.id, sourceURL: url)
                ?? SceneVideoCache.previousCompatibleCachedVideoURL(assetId: asset.id, sourceURL: url)
            if let previous {
                return VideoWallpaperView(url: previous, fallbackImageURL: previewURL, frame: frame,
                    displayMode: .fill, audioEnabled: audioEnabled, audioVolume: audioVolume)
            }
            if let previewURL, let image = NSImage(contentsOf: previewURL) {
                return ImageWallpaperView(image: image, frame: frame, displayMode: displayMode)
            }
        }
        let layout = try? SceneRenderPlanBuilder().buildLayout(url: url)
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
        let previousVideo = SceneVideoCache.previousCompatibleCachedVideoURL(assetId: asset.id, sourceURL: url)
        func interimContent() throws -> NSView {
            if let previousVideo {
                return VideoWallpaperView(url: previousVideo, fallbackImageURL: previewURL, frame: frame,
                    displayMode: .fill, audioEnabled: audioEnabled, audioVolume: audioVolume)
            }
            // Never show a partial composite over the thumbnail while rendering.
            if let previewURL, let image = NSImage(contentsOf: previewURL) {
                return ImageWallpaperView(image: image, frame: frame, displayMode: displayMode)
            }
            return try SceneWallpaperView(url: url, previewURL: nil, frame: frame, displayMode: displayMode)
        }
        guard let tools = try? renderingTools() else {
            lastDiagnostic = "scene video rendering skipped: \(missingRenderingComponentDescription())"
            // Preserve a complete native fallback when it is structurally supported.
            if previousVideo == nil, layout?.nativePlaybackIssues.isEmpty == true {
                return try SceneWallpaperView(url: url, previewURL: previewURL, frame: frame, displayMode: displayMode)
            }
            return try interimContent()
        }
        let recordingCanvas = layout?.canvasSize ?? (try? SceneRenderPlanBuilder().canvasSize(url: url))
        scheduleSceneVideoRender(
            asset: asset,
            sceneURL: url,
            rendererURL: tools.renderer,
            assetsDirectory: tools.assets,
            ffmpegPath: tools.ffmpeg,
            frame: frame,
            recordingCanvas: recordingCanvas.map { CGSize(width: $0.width, height: $0.height) }
        )
        lastDiagnostic = "scene video rendering in progress"
        statusHandler?("Rendering scene to video… 0%")
        return try interimContent()
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
        frame: CGRect,
        cacheAssetID: String? = nil,
        excludedObjectIDs: [Int] = [],
        recordingCanvas: CGSize? = nil
    ) {
        // Shared cache identity must not depend on which display started first.
        let recordSize = SceneVideoRecordSize.clampedRecordSize(
            forLogicalSize: recordingCanvas ?? CGSize(width: 1920, height: 1080)
        )
        let configuration = SceneVideoRenderConfiguration(
            assetId: cacheAssetID ?? asset.id,
            projectDirectory: URL(filePath: asset.projectDirectory).standardizedFileURL,
            assetsDirectory: assetsDirectory,
            rendererURL: rendererURL,
            size: recordSize,
            sceneURL: sceneURL,
            excludedObjectIDs: excludedObjectIDs
        )
        _ = startRender(configuration: configuration, ffmpegPath: ffmpegPath,
                        assetID: asset.id, refreshPlayback: true)
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

enum ScenePreparationError: Error, LocalizedError, Equatable {
    case unavailable(String)
    case incomplete

    var errorDescription: String? {
        switch self {
        case .unavailable(let component):
            return "Scene preparation requires: \(component)."
        case .incomplete:
            return "The scene could not be prepared for playback."
        }
    }
}

enum PlaybackError: Error, LocalizedError {
    case missingEntrypoint
    case invalidImage
    case noScreens
    case notPlayable(String)

    var errorDescription: String? {
        switch self {
        case .missingEntrypoint:
            return "The selected project has no playable entrypoint."
        case .invalidImage:
            return "The selected image could not be opened."
        case .noScreens:
            return "No display is available for wallpaper playback."
        case .notPlayable(let reason):
            return "This project is not playable on macOS: \(reason)."
        }
    }
}
