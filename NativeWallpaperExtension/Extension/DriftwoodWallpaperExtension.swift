import AppKit
import ExtensionFoundation
import Foundation

@main
final class DriftwoodWallpaperExtension: NSObject, AppExtension {
    override required init() {
        super.init()

        // Route the shared render core's diagnostics into this process's log file. The trace
        // channel stays gated on the VERBOSE_LOG marker, exactly as the extension's own is.
        RenderLog.sink = { extensionLog($0) }
        if verboseLoggingEnabled {
            RenderLog.traceSink = { extensionLog($0) }
        }

        let frameworkPath = "/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit"
        if let handle = dlopen(frameworkPath, RTLD_LAZY) {
            // Keep handle open — framework must stay loaded for vtable/C-function-pointer validity.
            _ = handle
            extensionLog("INIT (PID: \(ProcessInfo.processInfo.processIdentifier)) — WallpaperExtensionKit loaded")
            verifyRuntimeLayout()
            VideoLibrary.shared.scan()
            WallpaperAssignmentStore.shared.start()
            WallpaperPrefs.shared.refreshActiveState()
            observeLibraryChanges()
            observeDisplaySleepWake()
            observeScreenLockState()
            WallpaperPrefs.shared.observeChanges()
            PowerMonitor.shared.startMonitoring()
            Task {
                for await powerState in PowerMonitor.shared.stateChanges() {
                    WallpaperPrefs.shared.applyCurrentState(powerState: powerState)
                }
            }
        } else {
            let err = String(cString: dlerror())
            extensionLog("INIT (PID: \(ProcessInfo.processInfo.processIdentifier)) — dlopen failed: \(err)")
        }
    }

    /// Startup self-check: confirm the private WallpaperExtensionKit classes the
    /// extension bridges to are present after dlopen. This doesn't fail the
    /// launch — the per-call guards already fail closed — but it surfaces an
    /// unsupported OS/runtime layout in one clear log line up front instead of
    /// as scattered downstream failures, which is the documented manual
    /// compatibility check for OS upgrades.
    private func verifyRuntimeLayout() {
        let critical = [
            "WallpaperRemoteContextXPC",
            "WallpaperSnapshotXPC",
            "WallpaperCreationRequestXPC",
            "WallpaperSettingsViewModelsXPC",
            "WallpaperIDXPC",
        ]
        let missing = critical.filter { objc_getClass($0) == nil }
        if missing.isEmpty {
            extensionLog("  [SelfCheck] Runtime layout OK — all \(critical.count) critical classes present")
        } else {
            extensionLog("  [SelfCheck] UNSUPPORTED RUNTIME — missing: \(missing.joined(separator: ", ")). Rendering/snapshots may be degraded.")
        }
    }

    /// Observe display sleep/wake to stop rendering when no display is awake
    /// and resume on wake with correct policy.
    private func observeDisplaySleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil, queue: .main,
        ) { _ in
            WallpaperState.shared.isDisplayAsleep = true
            PlaylistScheduler.shared.setAllPaused(true)
            WallpaperState.shared.forSurfaceContexts { key, _ in
                WallpaperState.shared.applyPolicy(.paused, for: key)
            }
            extensionLog("[Extension] Displays asleep — paused all renderers")
        }
        center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil, queue: .main,
        ) { _ in
            WallpaperState.shared.isDisplayAsleep = false
            // Symmetry with the blanket pause on sleep. `applyCurrentState` only reaches
            // displays that still have a live surface, so a display whose surfaces were
            // torn down while asleep would stay parked with its timer disarmed. Releasing
            // first and letting the recompute re-park whatever policy still says is paused
            // cannot strand a playlist.
            PlaylistScheduler.shared.setAllPaused(false)
            Self.recomputeAndApplyPolicy()
            extensionLog("[Extension] Displays awake — recomputed policy (locked: \(WallpaperState.shared.isScreenLocked))")

            // Recompute again after a short delay to catch any pending
            // WallpaperAgent presentation mode updates that arrive after wake.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                Self.recomputeAndApplyPolicy()
            }
        }
    }

    /// Track screen lock state via distributed notifications from loginwindow.
    /// This lets us know the lock screen is showing even before the WallpaperAgent
    /// sends a presentation mode update — fixing the race where a video paused
    /// on the desktop doesn't resume on the lock screen after lid open.
    private func observeScreenLockState() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(
            forName: .init("com.apple.screenIsLocked"),
            object: nil, queue: .main,
        ) { _ in
            WallpaperState.shared.isScreenLocked = true
            extensionLog("[Extension] Screen locked")
        }
        dnc.addObserver(
            forName: .init("com.apple.screenIsUnlocked"),
            object: nil, queue: .main,
        ) { _ in
            WallpaperState.shared.isScreenLocked = false
            Self.recomputeAndApplyPolicy()
            extensionLog("[Extension] Screen unlocked — recomputed policy")
        }
    }

    /// Recompute playback policy from current state and apply to all renderers.
    static func recomputeAndApplyPolicy() {
        let state = WallpaperState.shared
        let prefs = WallpaperPrefs.shared
        // When we know the screen is locked but the WallpaperAgent hasn't
        // updated the presentation mode yet (e.g., right after display wake),
        // use "locked" to prevent stale desktop-mode policy from blocking
        // lock screen playback.
        let effectiveMode = state.isScreenLocked && state.presentationMode != "locked"
            ? "locked"
            : state.presentationMode

        prefs.applyCurrentState(presentationMode: effectiveMode)
    }

    /// Listen for Darwin notifications from the main app when it adds/removes videos.
    private func observeLibraryChanges() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, _, _, _, _ in
                VideoLibrary.shared.scan()
                extensionLog("[Extension] Library changed notification received, re-scanned")
            },
            "dev.3xhaust.WorkshopWallpaperBridge.wallpaper.libraryChanged" as CFString,
            nil,
            .deliverImmediately,
        )
    }

    var configuration: some AppExtensionConfiguration {
        WallpaperExtensionConfig()
    }
}
