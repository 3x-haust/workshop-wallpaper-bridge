import AppKit
import WorkshopWallpaperCore

@MainActor
final class WallpaperPlayer {
    static let shared = WallpaperPlayer()

    private var windows: [WallpaperWindow] = []
    private var activeAsset: WallpaperAsset?
    private var autoPauseWhenCovered = true
    private var displayMode: WallpaperDisplayMode = .fit
    private var visibilityTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var isSuspended = false
    private var lastScreenFrames: [CGRect] = []
    private var pendingAutoSuspension: DispatchWorkItem?
    private let visibilityMonitor = DesktopVisibilityMonitor()

    func play(
        asset: WallpaperAsset,
        autoPauseWhenCovered: Bool = true,
        displayMode: WallpaperDisplayMode = .fit
    ) throws {
        closeWindows()
        activeAsset = asset
        self.autoPauseWhenCovered = autoPauseWhenCovered
        self.displayMode = displayMode
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
            try WallpaperWindow(asset: asset, url: url, frame: frame, displayMode: displayMode)
        }
        lastScreenFrames = screenFrames
        windows.forEach { $0.show() }
        startLifecycleObservers()
        startVisibilityTimer()
        updateVisibilityState()
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
            try WallpaperWindow(asset: asset, url: url, frame: frame, displayMode: displayMode)
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

    static func wallpaperFrame(screenFrame: CGRect, visibleFrame: CGRect) -> CGRect {
        guard screenFrame.width > 0, screenFrame.height > 0,
              visibleFrame.width > 0, visibleFrame.height > 0 else {
            return screenFrame
        }
        let menuBarBottom = min(screenFrame.maxY, max(screenFrame.minY, visibleFrame.maxY))
        guard menuBarBottom > screenFrame.minY else {
            return screenFrame
        }
        return CGRect(
            x: screenFrame.minX,
            y: screenFrame.minY,
            width: screenFrame.width,
            height: menuBarBottom - screenFrame.minY
        )
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

    init(asset: WallpaperAsset, url: URL, frame: CGRect, displayMode: WallpaperDisplayMode) throws {
        content = try Self.makeContentView(asset: asset, url: url, frame: frame, displayMode: displayMode)
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
        window.backgroundColor = .black
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

    private static func makeContentView(
        asset: WallpaperAsset,
        url: URL,
        frame: CGRect,
        displayMode: WallpaperDisplayMode
    ) throws -> NSView {
        let contentFrame = WallpaperContentLayout.contentFrame(for: frame)
        switch asset.kind {
        case .video:
            let fallbackImageURL = try? StillWallpaperImageProvider().stillImageURL(for: asset)
            return VideoWallpaperView(
                url: url,
                fallbackImageURL: fallbackImageURL,
                frame: contentFrame,
                displayMode: displayMode
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
            return try SceneWallpaperView(
                url: url,
                previewURL: previewURL,
                frame: contentFrame,
                displayMode: displayMode
            )
        case .unknown:
            throw PlaybackError.notPlayable(asset.kind.rawValue)
        }
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
