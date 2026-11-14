import Foundation
import os

/// Extension-side reader for shared preferences written by the main app,
/// and writer for extension state (isActive) read by the app.
///
/// Thread-safe via `OSAllocatedUnfairLock`. Observes `dev.3xhaust.WorkshopWallpaperBridge.wallpaper.prefsChanged`
/// Darwin notification to reload when the app writes new values.
final class WallpaperPrefs: @unchecked Sendable {
    static let shared = WallpaperPrefs()

    private struct PrefsFile: Codable {
        var userPaused: Bool
        var alwaysPauseDesktop: Bool
        var pauseWhenOccluded: Bool
        var desktopOccluded: Bool
        var pausedDisplays: Set<UInt32>?
        var occludedDisplays: Set<UInt32>?
        var pausedDisplaysExpireAt: Date?
        var pauseOnBattery: Bool?
        var playbackRate: Double?
        var quality: String?
        var nativeWallpaper: Bool?

        init(
            userPaused: Bool = false,
            alwaysPauseDesktop: Bool = false,
            pauseWhenOccluded: Bool = false,
            desktopOccluded: Bool = false,
            pausedDisplays: Set<UInt32>? = nil,
            occludedDisplays: Set<UInt32>? = nil,
            pausedDisplaysExpireAt: Date? = nil,
            pauseOnBattery: Bool? = true,
            playbackRate: Double? = 1,
            quality: String? = "auto",
            nativeWallpaper: Bool? = true
        ) {
            self.userPaused = userPaused
            self.alwaysPauseDesktop = alwaysPauseDesktop
            self.pauseWhenOccluded = pauseWhenOccluded
            self.desktopOccluded = desktopOccluded
            self.pausedDisplays = pausedDisplays
            self.occludedDisplays = occludedDisplays
            self.pausedDisplaysExpireAt = pausedDisplaysExpireAt
            self.pauseOnBattery = pauseOnBattery
            self.playbackRate = playbackRate
            self.quality = quality
            self.nativeWallpaper = nativeWallpaper
        }
    }

    private struct ContextState: Codable {
        var displayID: UInt32
        var videoID: String?
        var videoName: String?
        var isPreview: Bool
    }

    private struct StateFile: Codable {
        var processID: Int32
        var isActive: Bool
        var currentVideoID: String?
        var currentVideoName: String?
        var contexts: [ContextState]?
    }

    private let lock = OSAllocatedUnfairLock(initialState: PrefsFile())
    /// Last bytes published by this process. Starting nil is deliberate: the first
    /// publication after an extension restart must rewrite and notify even if an old
    /// process left semantically identical state on disk.
    private let stateWriteLock = OSAllocatedUnfairLock(
        initialState: nil as Data?
    )
    private let previousDesktopOccluded = OSAllocatedUnfairLock(initialState: false)
    private let pauseLeaseGeneration = OSAllocatedUnfairLock(initialState: 0)

    private static var docsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    private static var prefsURL: URL {
        docsURL.appendingPathComponent("driftwood-prefs.json")
    }

    private static var stateURL: URL {
        docsURL.appendingPathComponent("driftwood-state.json")
    }

    private init() {
        reload()
    }

    // MARK: - Public (Prefs — app → extension)

    var userPaused: Bool {
        lock.withLock { $0.userPaused }
    }

    var alwaysPauseDesktop: Bool {
        lock.withLock { $0.alwaysPauseDesktop }
    }

    var pauseWhenOccluded: Bool {
        lock.withLock { $0.pauseWhenOccluded }
    }

    var desktopOccluded: Bool {
        lock.withLock { $0.desktopOccluded }
    }

    var pausedDisplays: Set<UInt32> {
        lock.withLock {
            guard let expiry = $0.pausedDisplaysExpireAt,
                  expiry > Date() else {
                return []
            }
            return $0.pausedDisplays ?? []
        }
    }

    /// Displays currently covered by a fullscreen app. Shares `pausedDisplays`' lease.
    var occludedDisplays: Set<UInt32> {
        lock.withLock {
            guard let expiry = $0.pausedDisplaysExpireAt,
                  expiry > Date() else {
                return []
            }
            return $0.occludedDisplays ?? []
        }
    }

    var pauseOnBattery: Bool {
        lock.withLock { $0.pauseOnBattery ?? true }
    }

    var playbackRate: Double {
        lock.withLock { min(max($0.playbackRate ?? 1, 0.25), 4) }
    }

    /// The app ships this across as a raw string; resolve it once here so the renderers
    /// never switch on string literals.
    var quality: RenderQuality {
        lock.withLock { RenderQuality(rawValueOrAuto: $0.quality) }
    }

    /// Whether the user still wants Driftwood to be the macOS wallpaper. When off, the
    /// extension stops advertising its per-display choices to Wallpaper Settings.
    var nativeWallpaperEnabled: Bool {
        lock.withLock { $0.nativeWallpaper ?? true }
    }

    // MARK: - Public (State — extension → app)

    /// Call when the active video changes while the extension is already active.
    func updateCurrentVideo() {
        publishActiveState(traceOnly: true)
    }

    func refreshActiveState() {
        publishActiveState(traceOnly: false)
    }

    private func publishActiveState(traceOnly: Bool) {
        stateWriteLock.withLock { lastPublishedData in
            let contexts = buildContextStates()
            let isActive = !contexts.isEmpty
            let videoID = isActive
                ? WallpaperState.shared.currentVideoID
                : nil
            let videoName = videoID.flatMap {
                VideoLibrary.shared.entry(for: $0)?.name
            }
            let state = StateFile(
                processID: ProcessInfo.processInfo.processIdentifier,
                isActive: isActive,
                currentVideoID: videoID,
                currentVideoName: videoName,
                contexts: contexts
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(state) else { return }
            guard data != lastPublishedData else { return }
            do {
                try data.write(to: Self.stateURL, options: .atomic)
            } catch {
                extensionLog("[WallpaperPrefs] Failed to publish state: \(error)")
                return
            }
            lastPublishedData = data
            postStateNotification()
            let message =
                "[WallpaperPrefs] active=\(isActive), video: "
                + "\(videoName ?? "nil"), hosted surfaces: \(contexts.count)"
            if traceOnly {
                traceLog(message)
            } else {
                extensionLog(message)
            }
        }
    }

    private func buildContextStates() -> [ContextState] {
        WallpaperState.shared.activeDisplayContexts().map { ctx in
            let name = ctx.videoID.flatMap { VideoLibrary.shared.entry(for: $0)?.name }
            return ContextState(
                displayID: ctx.displayID,
                videoID: ctx.videoID,
                videoName: name,
                isPreview: ctx.isPreview
            )
        }.sorted { lhs, rhs in
            if lhs.displayID != rhs.displayID {
                return lhs.displayID < rhs.displayID
            }
            if lhs.isPreview != rhs.isPreview {
                return !lhs.isPreview
            }
            if lhs.videoID != rhs.videoID {
                if lhs.videoID == nil { return true }
                if rhs.videoID == nil { return false }
                return lhs.videoID! < rhs.videoID!
            }
            if lhs.videoName != rhs.videoName {
                if lhs.videoName == nil { return true }
                if rhs.videoName == nil { return false }
                return lhs.videoName! < rhs.videoName!
            }
            return false
        }
    }

    // MARK: - Reload

    func reload() {
        let data: Data
        do {
            data = try Data(contentsOf: Self.prefsURL)
        } catch {
            return // File doesn't exist yet — normal on first launch
        }
        do {
            let prefs = try JSONDecoder().decode(PrefsFile.self, from: data)
            lock.withLock { state in
                state = prefs
            }
            schedulePauseLeaseExpiry(prefs.pausedDisplaysExpireAt)
            traceLog("[WallpaperPrefs] Loaded: userPaused=\(prefs.userPaused), alwaysPauseDesktop=\(prefs.alwaysPauseDesktop), pauseWhenOccluded=\(prefs.pauseWhenOccluded), desktopOccluded=\(prefs.desktopOccluded)")
        } catch {
            extensionLog("[WallpaperPrefs] Failed to decode prefs: \(error)")
        }
    }

    private func schedulePauseLeaseExpiry(_ expiry: Date?) {
        let generation = pauseLeaseGeneration.withLock {
            $0 += 1
            return $0
        }
        guard let expiry, expiry > Date() else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + expiry.timeIntervalSinceNow
        ) { [weak self] in
            guard let self,
                  pauseLeaseGeneration.withLock({ $0 == generation }) else {
                return
            }
            applyCurrentState()
        }
    }

    // MARK: - Darwin Observer

    private var isObservingChanges = false

    func observeChanges() {
        guard !isObservingChanges else { return }
        isObservingChanges = true

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, _, _, _, _ in
                WallpaperPrefs.shared.reload()
                WallpaperPrefs.shared.applyCurrentState()
            },
            "dev.3xhaust.WorkshopWallpaperBridge.wallpaper.prefsChanged" as CFString,
            nil,
            .deliverImmediately,
        )
    }

    func stopObserving() {
        guard isObservingChanges else { return }
        isObservingChanges = false

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveObserver(
            center,
            observer,
            CFNotificationName("dev.3xhaust.WorkshopWallpaperBridge.wallpaper.prefsChanged" as CFString),
            nil,
        )
    }

    /// Recompute playback policy for one reacquired surface without touching sibling
    /// Spaces, previews, lock-screen surfaces, displays, or playlist timers.
    /// Must run on `RenderQueue.serial`.
    func applyCurrentState(to key: DisplayKey) {
        let state = WallpaperState.shared
        guard let context = state.context(for: key) else { return }

        context.surface.setPlaybackRate(playbackRate)
        context.surface.setQuality(quality)

        let displayID = context.displayID
        let displayPaused = displayID.map(pausedDisplays.contains) ?? false
        let displayOccluded = desktopOccluded
            || (displayID.map(occludedDisplays.contains) ?? false)
        let mode = state.isScreenLocked && state.presentationMode != "locked"
            ? "locked"
            : state.presentationMode
        var policy = PlaybackPolicy.compute(
            presentationMode: mode,
            activityState: state.activityState,
            userPaused: userPaused || displayPaused,
            alwaysPauseDesktop: alwaysPauseDesktop,
            pauseWhenOccluded: pauseWhenOccluded,
            desktopOccluded: displayOccluded,
            pauseOnBattery: pauseOnBattery,
            powerState: PowerMonitor.shared.currentState
        )
        if state.isDisplayAsleep
            || (context.isPreview && state.isPreviewIdle(key)) {
            policy = .paused
        }
        state.applyPolicy(policy, for: key)
    }

    /// Recompute playback policy and apply to all active renderers.
    /// Uses ramp animation for occlusion transitions (desktop covered/uncovered).
    func applyCurrentState(
        powerState: PowerMonitor.PowerState? = nil,
        presentationMode: String? = nil,
        activityState: String? = nil,
        animated: Bool? = nil
    ) {
        let state = WallpaperState.shared
        let isDesktopOccluded = desktopOccluded
        let anyOccluded = isDesktopOccluded || !occludedDisplays.isEmpty
        let occlusionChanged = previousDesktopOccluded.withLock { previous in
            defer { previous = anyOccluded }
            return previous != anyOccluded
        }
        let shouldAnimate = animated
            ?? (occlusionChanged && pauseWhenOccluded)

        let displayIDs = state.uniqueDisplayIDs()
        let currentPausedDisplays = pausedDisplays
        let currentOccludedDisplays = occludedDisplays
        let power = powerState ?? PowerMonitor.shared.currentState
        let mode = presentationMode ?? state.presentationMode
        let activity = activityState ?? state.activityState
        let rate = playbackRate
        let currentQuality = quality

        state.forEachSurface { surface in
            surface.setPlaybackRate(rate)
            surface.setQuality(currentQuality)
        }

        // An idle Settings preview stays frozen no matter what the display-level policy
        // says — it is a surface nobody is looking at, and resuming it is the acquire/
        // update activity path's job, not a side effect of every policy recompute.
        if displayIDs.isEmpty {
            // No per-display info — apply globally (backward compat)
            let computedPolicy = PlaybackPolicy.compute(
                presentationMode: mode,
                activityState: activity,
                userPaused: userPaused,
                alwaysPauseDesktop: alwaysPauseDesktop,
                pauseWhenOccluded: pauseWhenOccluded,
                desktopOccluded: isDesktopOccluded,
                pauseOnBattery: pauseOnBattery,
                powerState: power,
            )
            let policy: PlaybackPolicy = state.isDisplayAsleep
                ? .paused
                : computedPolicy
            PlaylistScheduler.shared.setAllPaused(policy == .paused)
            state.forSurfaceContexts { key, isPreview in
                let effective = isPreview && state.isPreviewIdle(key)
                    ? PlaybackPolicy.paused
                    : policy
                state.applyPolicy(effective, animated: shouldAnimate, for: key)
            }
        } else {
            for displayID in displayIDs {
                let isDisplayPaused = currentPausedDisplays.contains(displayID)
                // Occlusion is deliberately NOT folded into `userPaused`: `compute` ignores
                // it on the lock screen, where the wallpaper is fully visible again no
                // matter what is covering the desktop. Treating it as a user pause is what
                // used to leave the lock screen frozen behind a fullscreen app.
                let isDisplayOccluded =
                    isDesktopOccluded || currentOccludedDisplays.contains(displayID)
                let computedPolicy = PlaybackPolicy.compute(
                    presentationMode: mode,
                    activityState: activity,
                    userPaused: userPaused || isDisplayPaused,
                    alwaysPauseDesktop: alwaysPauseDesktop,
                    pauseWhenOccluded: pauseWhenOccluded,
                    desktopOccluded: isDisplayOccluded,
                    pauseOnBattery: pauseOnBattery,
                    powerState: power,
                )
                let policy: PlaybackPolicy = state.isDisplayAsleep
                    ? .paused
                    : computedPolicy
                // A frozen wallpaper must not rotate underneath the freeze — pausing is
                // exactly the request not to have the desktop change.
                if let displayUUID = canonicalDisplayUUID(for: displayID) {
                    PlaylistScheduler.shared.setPaused(
                        policy == .paused,
                        displayUUID: displayUUID
                    )
                }
                state.forSurfaceContexts(displayID: displayID) {
                    key, isPreview in
                    let effective = isPreview && state.isPreviewIdle(key)
                        ? PlaybackPolicy.paused
                        : policy
                    state.applyPolicy(
                        effective,
                        animated: shouldAnimate,
                        for: key
                    )
                }
            }
        }
    }

    private func postStateNotification() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName("dev.3xhaust.WorkshopWallpaperBridge.wallpaper.stateChanged" as CFString),
            nil,
            nil,
            true,
        )
    }
}
