import AppKit
import WorkshopWallpaperCore

@MainActor
final class WallpaperPlayer {
    static let shared = WallpaperPlayer()

    private var windows: [WallpaperWindow] = []
    private var activeAsset: WallpaperAsset?
    private var autoPauseWhenCovered = true
    private var visibilityTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var isSuspended = false
    private let visibilityMonitor = DesktopVisibilityMonitor()

    func play(asset: WallpaperAsset, autoPauseWhenCovered: Bool = true) throws {
        closeWindows()
        activeAsset = asset
        self.autoPauseWhenCovered = autoPauseWhenCovered
        guard asset.supportStatus == .playable else {
            throw PlaybackError.notPlayable(asset.supportStatus.rawValue)
        }
        guard let entrypoint = asset.entrypoint else {
            throw PlaybackError.missingEntrypoint
        }
        let url = URL(filePath: entrypoint)
        windows = try NSScreen.screens.map { screen in
            try WallpaperWindow(asset: asset, url: url, frame: screen.frame)
        }
        windows.forEach { $0.show() }
        startLifecycleObservers()
        startVisibilityTimer()
        updateVisibilityState()
    }

    func setAutoPauseWhenCovered(_ enabled: Bool) {
        autoPauseWhenCovered = enabled
        updateVisibilityState()
    }

    func restoreVisibleWindowsAfterAppWindowChange() {
        updateVisibilityState()
        guard !isSuspended else {
            return
        }
        windows.forEach { $0.show() }
    }

    func stop() {
        activeAsset = nil
        stopVisibilityTimer()
        stopLifecycleObservers()
        closeWindows()
    }

    private func closeWindows() {
        windows.forEach { $0.close() }
        windows = []
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
        setSuspended(shouldSuspend)
    }

    private func setSuspended(_ suspended: Bool) {
        guard isSuspended != suspended else {
            return
        }
        isSuspended = suspended
        windows.forEach { $0.setSuspended(suspended) }
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
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.reopenAfterWake() }
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
            try play(asset: activeAsset, autoPauseWhenCovered: autoPauseWhenCovered)
        } catch {
            closeWindows()
        }
    }
}

@MainActor
private final class WallpaperWindow {
    private let window: NSWindow
    private let content: NSView

    init(asset: WallpaperAsset, url: URL, frame: CGRect) throws {
        content = try Self.makeContentView(asset: asset, url: url, frame: frame)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.canHide = false
        window.isExcludedFromWindowsMenu = true
        window.backgroundColor = .black
        window.contentView = content
    }

    func show() {
        window.orderFrontRegardless()
    }

    func close() {
        window.close()
    }

    func setSuspended(_ suspended: Bool) {
        if suspended {
            window.orderOut(nil)
        } else {
            show()
        }
        (content as? PausableWallpaperContent)?.setPlaybackSuspended(suspended)
    }

    private static func makeContentView(asset: WallpaperAsset, url: URL, frame: CGRect) throws -> NSView {
        switch asset.kind {
        case .video:
            return VideoWallpaperView(url: url, frame: frame)
        case .web:
            return RestrictedWebWallpaperView(
                url: url,
                readAccessURL: URL(filePath: asset.projectDirectory),
                frame: frame
            )
        case .image:
            guard let image = NSImage(contentsOf: url) else {
                throw PlaybackError.invalidImage
            }
            let imageView = NSImageView(frame: frame)
            imageView.image = image
            imageView.imageScaling = .scaleProportionallyUpOrDown
            return imageView
        case .scene, .unknown:
            throw PlaybackError.notPlayable(asset.kind.rawValue)
        }
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
