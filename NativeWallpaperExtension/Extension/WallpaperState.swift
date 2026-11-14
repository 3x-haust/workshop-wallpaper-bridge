import Foundation
import os
import QuartzCore

/// One active per-surface rendering slot. Every content kind renders into one of the
/// surface's two permanent sample-buffer display layers; only the producer feeding a
/// layer changes, and a switch crossfades between the two.
struct ActiveWallpaper: @unchecked Sendable {
    let caContext: AnyObject // CAContext (private class, hold as AnyObject)
    let contextId: UInt32
    let rootLayer: CALayer
    /// The rendering slot: layer deck, current renderer, and the content-switch state
    /// machine. Outlives every renderer it builds.
    let surface: WallpaperSurface
    let displayID: UInt32?
    var videoID: String?
    var assignmentRevision: UInt64?
    let isPreview: Bool
    /// Whether WallpaperAgent currently hosts this surface. Invalidated
    /// surfaces may retain their renderer briefly for seamless re-acquire, but
    /// they are no longer proof that native playback is visible.
    var isHosted = true
    /// True after this surface has content ready and its acquire reply has been
    /// released to WallpaperAgent. Invalidated predecessor surfaces can only be
    /// reclaimed early once a replacement in the same display/role is ready.
    var isReady = false
    /// The XPC connection that most recently acquired this surface. UUID-less invalidation
    /// fallback uses it to reject stale history from an older connection.
    var acquisitionOwner: UUID
    /// Last effective policy requested for this surface. Renderer policy changes are
    /// asynchronous, so lifecycle logging reports this value as requested, not observed.
    var playbackPolicy: PlaybackPolicy = .full

    var renderer: WallpaperRenderer? { surface.renderer }
}

struct HostedWallpaperSurface: @unchecked Sendable {
    let key: DisplayKey
    let surface: WallpaperSurface
    let contentID: String?
    let assignmentRevision: UInt64?

    var renderer: WallpaperRenderer? { surface.renderer }
}

/// Identifies one hosted wallpaper SURFACE — a distinct `CAContext`/layer tree that
/// WallpaperAgent hosts in one `CALayerHost`. There is one per **WallpaperID UUID**,
/// i.e. one per Space, per lock-screen surface, and per Settings preview.
///
/// This used to be keyed by `displayID` alone (one shared context per display), on the
/// assumption that every consumer of a display hosts the same surface. That's wrong:
/// macOS keeps multiple Spaces' wallpaper surfaces (plus the lock screen) *live at once*,
/// each a separate WallpaperID with its own `acquire`, and a `CAContext` can only be
/// hosted in ONE `CALayerHost` at a time. Handing the same `contextId` to two Spaces made
/// the second steal the surface and the first go black (permanent on a space switch, a
/// transient flash during the desktop↔lock reveal). Keying by the WallpaperID UUID gives
/// each surface its own context, so none can steal another's. `displayID` is retained for
/// display-level fan-out (policy, per-display switch).
struct DisplayKey: Hashable {
    let displayID: UInt32
    let surfaceUUID: UUID
}

final class WallpaperState: Sendable {
    static let shared = WallpaperState()

    private static let selectedVideoKey = "selectedVideoID"

    private struct State: @unchecked Sendable {
        /// Persistent contexts keyed by wallpaper surface. Reused across acquires.
        var contexts: [DisplayKey: ActiveWallpaper] = [:]
        /// WallpaperID UUID → its surface key, learned at acquire. Lets `invalidate(UUID)`
        /// resolve which surface context to tear down. Each surface owns its context, so an
        /// invalidate tears down only that surface — no cross-surface interference.
        var keyForWallpaperUUID: [UUID: DisplayKey] = [:]
        var cachedThumbnailURL: URL?
        var cacheDirectoryURL: URL?
        var currentVideoID: String? = UserDefaults.standard.string(forKey: WallpaperState.selectedVideoKey)
        var presentationMode: String = "active"
        var activityState: String = "active"
        var isDisplayAsleep: Bool = false
        var isScreenLocked: Bool = false
        /// Settings-preview surfaces whose activity grace has elapsed. Policy application
        /// freezes these — WallpaperAgent holds preview surfaces long after the Settings
        /// pane closes, and each is a full-rate decode of a wallpaper nobody can see.
        var idlePreviewKeys: Set<DisplayKey> = []
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    private init() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let state = Unmanaged<WallpaperState>.fromOpaque(observer).takeUnretainedValue()
                state.clearCaches()
            },
            "dev.3xhaust.WorkshopWallpaperBridge.wallpaper.libraryChanged" as CFString,
            nil,
            .deliverImmediately,
        )
    }

    /// Re-scan and switch each live surface to the current file for its stable
    /// choice. Driftwood changes media behind one provider choice, so normal
    /// wallpaper changes never need to rewrite WallpaperAgent's store.
    private func clearCaches() {
        lock.withLock { state in
            state.cachedThumbnailURL = nil
        }
        VideoLibrary.shared.scan()
        let active = lock.withLock { state in
            state.contexts.values.compactMap { context -> (WallpaperSurface, String)? in
                guard let videoID = context.videoID else { return nil }
                return (context.surface, videoID)
            }
        }
        RenderQueue.serial.async {
            for (surface, videoID) in active {
                if let url = VideoLibrary.shared.videoURL(for: videoID) {
                    surface.refreshVideoSource(url)
                }
            }
        }
    }

    // MARK: - Context Management

    /// The existing persistent context for a wallpaper surface, if any.
    func context(for key: DisplayKey) -> ActiveWallpaper? {
        lock.withLock { $0.contexts[key] }
    }

    /// The exact context requested by WallpaperAgent for snapshot generation.
    func context(forWallpaperUUID uuid: UUID) -> ActiveWallpaper? {
        lock.withLock { state in
            if let key = state.keyForWallpaperUUID[uuid],
               let context = state.contexts[key] {
                return context
            }
            // `invalidate` drops the lookup mapping immediately, but the
            // surface itself intentionally remains alive during teardown
            // grace. WallpaperAgent can request its final snapshot in that
            // interval, so recover it from the key's durable surface UUID.
            return state.contexts.first {
                $0.key.surfaceUUID == uuid
            }?.value
        }
    }

    /// Install a freshly-created context for a wallpaper surface (first acquire).
    func installContext(_ context: ActiveWallpaper, for key: DisplayKey) {
        lock.withLock { $0.contexts[key] = context }
    }

    /// Track the choice a slot is showing after its content changed.
    func updateVideoID(_ videoID: String?, for key: DisplayKey) {
        lock.withLock { state in
            guard var context = state.contexts[key] else { return }
            context.videoID = videoID
            state.contexts[key] = context
        }
    }

    @discardableResult
    func acceptAssignment(
        contentID: String,
        assignmentRevision: UInt64,
        for key: DisplayKey,
        rendererID: Int
    ) -> Bool {
        lock.withLock { state in
            guard var context = state.contexts[key],
                  context.surface.renderer?.debugID == rendererID else {
                return false
            }
            context.videoID = contentID
            context.assignmentRevision = assignmentRevision
            state.contexts[key] = context
            return true
        }
    }

    /// Mark a surface as safe for WallpaperAgent to host.
    func markReady(for key: DisplayKey) {
        lock.withLock { state in
            guard var context = state.contexts[key] else { return }
            context.isReady = true
            state.contexts[key] = context
        }
    }

    /// Whether `replacementKey` is a ready successor for an invalidated surface.
    /// Preview and live surfaces are separate roles; replacing one must never tear
    /// down the other.
    func isReadyReplacement(_ replacementKey: DisplayKey, for oldKey: DisplayKey) -> Bool {
        lock.withLock { state in
            guard replacementKey != oldKey,
                  let replacement = state.contexts[replacementKey],
                  let old = state.contexts[oldKey] else {
                return false
            }
            return replacement.isReady
                && replacement.isHosted
                && replacement.displayID == old.displayID
                && replacement.isPreview == old.isPreview
        }
    }

    /// Whether an invalidated surface already has another ready surface that can
    /// replace it on the same display without exposing a black transition.
    func hasReadyReplacement(for oldKey: DisplayKey) -> Bool {
        lock.withLock { state in
            guard let old = state.contexts[oldKey] else { return false }
            return state.contexts.contains { key, context in
                key != oldKey
                    && context.isReady
                    && context.isHosted
                    && context.displayID == old.displayID
                    && context.isPreview == old.isPreview
            }
        }
    }

    /// Execute a closure for each surface (snapshot copy under lock, iteration outside).
    ///
    /// Deliberately per-*surface* rather than per-renderer: a surface remembers the policy,
    /// rate and quality it was last given and applies them to any renderer it builds later.
    /// Reaching past it to the current renderer would leave the next one at the defaults.
    /// The body runs on `RenderQueue.serial`, which surfaces require. Callers arrive from
    /// `.main` (display sleep/wake, screen lock) and from the power-monitor task, so the
    /// hop happens here rather than at each call site.
    func forEachSurface(_ body: @escaping @Sendable (WallpaperSurface) -> Void) {
        let surfaces = lock.withLock { state in
            state.contexts.values.map(\.surface)
        }
        RenderQueue.serial.async {
            for surface in surfaces {
                body(surface)
            }
        }
    }

    /// Execute a closure for the surfaces on a specific display.
    func forSurfaces(
        displayID: UInt32,
        _ body: @escaping @Sendable (WallpaperSurface) -> Void
    ) {
        let surfaces = lock.withLock { state in
            state.contexts.values
                .filter { $0.displayID == displayID }
                .map(\.surface)
        }
        RenderQueue.serial.async {
            for surface in surfaces {
                body(surface)
            }
        }
    }

    /// Execute a closure for each surface key and preview role. The snapshot is taken under
    /// the lock, then delivered on `RenderQueue.serial`.
    func forSurfaceContexts(
        displayID: UInt32? = nil,
        _ body: @escaping @Sendable (DisplayKey, Bool) -> Void
    ) {
        let snapshot = lock.withLock { state in
            state.contexts.compactMap { key, context -> (DisplayKey, Bool)? in
                guard displayID == nil || context.displayID == displayID else {
                    return nil
                }
                return (key, context.isPreview)
            }
        }
        RenderQueue.serial.async {
            for (key, isPreview) in snapshot {
                body(key, isPreview)
            }
        }
    }

    /// Apply a policy to one exact surface and retain the request for lifecycle logging.
    /// Callers invoke this from `RenderQueue.serial`, preserving ordering with content
    /// switches and teardown.
    func applyPolicy(
        _ policy: PlaybackPolicy,
        animated: Bool = false,
        for key: DisplayKey
    ) {
        let target = lock.withLock {
            state -> (WallpaperSurface, PlaybackPolicy)? in
            guard var context = state.contexts[key] else { return nil }
            // A policy recompute may have captured this surface just before its
            // invalidation. Check hosting at application time so stale work can
            // never restart an unhosted decoder.
            let effective = context.isHosted ? policy : .paused
            context.playbackPolicy = effective
            state.contexts[key] = context
            return (context.surface, effective)
        }
        if let (surface, effective) = target {
            surface.applyPolicy(effective, animated: animated)
        }
    }

    /// Mark a Settings-preview surface idle (its activity grace elapsed) or active again.
    /// Returns whether the flag actually changed; idling a surface that is gone or not a
    /// preview is refused, which is what lets a stale idle timer no-op safely.
    @discardableResult
    func setPreviewIdle(_ idle: Bool, for key: DisplayKey) -> Bool {
        lock.withLock { state in
            if idle {
                guard state.contexts[key]?.isPreview == true else { return false }
                return state.idlePreviewKeys.insert(key).inserted
            }
            return state.idlePreviewKeys.remove(key) != nil
        }
    }

    func isPreviewIdle(_ key: DisplayKey) -> Bool {
        lock.withLock { $0.idlePreviewKeys.contains(key) }
    }

    func hostedLiveSurfaces() -> [HostedWallpaperSurface] {
        lock.withLock { state in
            state.contexts.compactMap { key, context in
                guard context.isHosted, !context.isPreview else { return nil }
                return HostedWallpaperSurface(
                    key: key,
                    surface: context.surface,
                    contentID: context.videoID,
                    assignmentRevision: context.assignmentRevision
                )
            }
        }
    }

    // MARK: - WallpaperID ↔ display bridge (for per-display invalidate/teardown)

    /// Learned at acquire: this WallpaperID UUID maps to this surface `key`, so a later
    /// `invalidate(UUID)` can resolve which surface context to tear down.
    func registerWallpaperID(_ uuid: UUID, key: DisplayKey) {
        lock.withLock { $0.keyForWallpaperUUID[uuid] = key }
    }

    /// The surface key an invalidate's WallpaperID targets, if we know it.
    func resolveWallpaperKey(_ uuid: UUID) -> DisplayKey? {
        lock.withLock { state in
            state.keyForWallpaperUUID[uuid]
                ?? state.contexts.keys.first { $0.surfaceUUID == uuid }
        }
    }

    func isPreview(for uuid: UUID) -> Bool? {
        lock.withLock { state in
            guard let key = state.keyForWallpaperUUID[uuid] else { return nil }
            return state.contexts[key]?.isPreview
        }
    }

    /// Drop every identifier mapping for a surface once its instance is invalidated.
    func forgetWallpaperIDs(for key: DisplayKey) {
        lock.withLock { state in
            state.keyForWallpaperUUID = state.keyForWallpaperUUID.filter {
                $0.value != key
            }
        }
    }

    /// Mark one exact surface unhosted and freeze its producer immediately while retaining
    /// its CAContext for teardown grace. Must run on `RenderQueue.serial`.
    @discardableResult
    func pauseUnhostedSurface(for key: DisplayKey) -> Bool {
        let surface = lock.withLock { state -> WallpaperSurface? in
            guard var context = state.contexts[key], context.isHosted else {
                return nil
            }
            context.isHosted = false
            context.playbackPolicy = .paused
            state.contexts[key] = context
            return context.surface
        }
        guard let surface else { return false }
        // Settle before pausing so a same-surface re-acquire never inherits a
        // half-run fade or an outgoing producer that is still decoding.
        surface.settle()
        surface.applyPolicy(.paused)
        traceLog(
            "  [host] display=\(key.displayID) surface="
                + "\(key.surfaceUUID) hosted=false"
        )
        WallpaperPrefs.shared.refreshActiveState()
        return true
    }

    /// Record the latest connection to acquire this surface and restore its hosted bit.
    @discardableResult
    func restoreHosting(for key: DisplayKey, owner: UUID) -> Bool {
        let changed = lock.withLock { state -> Bool in
            guard var context = state.contexts[key] else { return false }
            let changed = !context.isHosted
            context.isHosted = true
            context.acquisitionOwner = owner
            state.contexts[key] = context
            return changed
        }
        if changed {
            traceLog(
                "  [host] display=\(key.displayID) surface="
                    + "\(key.surfaceUUID) hosted=true"
            )
        }
        return changed
    }

    func isHosted(_ key: DisplayKey, by owner: UUID) -> Bool {
        lock.withLock { state in
            guard let context = state.contexts[key] else { return false }
            return context.isHosted && context.acquisitionOwner == owner
        }
    }

    /// Per-surface teardown (the invalidate grace timer fired with no re-acquire — the Space
    /// closed, the preview dismissed, or the display slept): stop ONLY this surface's renderer
    /// and `-[CAContext invalidate]` its context, leaving other surfaces playing. Returns
    /// whether it tore down.
    @discardableResult
    func tearDownContext(for key: DisplayKey) -> Bool {
        let removed = lock.withLock { state -> ActiveWallpaper? in
            state.idlePreviewKeys.remove(key)
            state.keyForWallpaperUUID = state.keyForWallpaperUUID.filter {
                $0.value != key
            }
            return state.contexts.removeValue(forKey: key)
        }
        guard let removed else { return false }
        // `stop()` runs any pending fade's cleanup first, so the renderer it was going to
        // retire does not outlive the surface.
        removed.surface.stop()
        invalidateRemoteContext(removed.caContext)
        WallpaperPrefs.shared.refreshActiveState()
        return true
    }

    /// All unique display IDs from active contexts.
    func uniqueDisplayIDs() -> Set<UInt32> {
        lock.withLock { state in
            Set(state.contexts.values.compactMap(\.displayID))
        }
    }

    /// Get every surface that currently has a live renderer. WallpaperAgent can
    /// host multiple surfaces for one display while Spaces or choices hand off.
    func activeDisplayContexts() -> [
        (displayID: UInt32, videoID: String?, isPreview: Bool)
    ] {
        lock.withLock { state in
            state.contexts.values.compactMap { context in
                guard context.isHosted,
                      context.renderer != nil,
                      let displayID = context.displayID else {
                    return nil
                }
                return (
                    displayID: displayID,
                    videoID: context.videoID,
                    isPreview: context.isPreview
                )
            }
        }
    }

    var activeContextCount: Int {
        lock.withLock { $0.contexts.count }
    }

    /// Log a compact snapshot at lifecycle transitions without scheduling any work.
    func logLifecycleTelemetry(_ reason: String) {
        let counts = lock.withLock { state in
            var hosted = 0
            var renderers = 0
            var unpausedRenderers = 0
            for context in state.contexts.values {
                if context.isHosted { hosted += 1 }
                if context.renderer != nil {
                    renderers += 1
                    if context.playbackPolicy != .paused {
                        unpausedRenderers += 1
                    }
                }
            }
            return (
                contexts: state.contexts.count,
                hosted: hosted,
                renderers: renderers,
                unpausedRenderers: unpausedRenderers
            )
        }
        extensionLog(
            "  [lifecycle] \(reason): contexts=\(counts.contexts), "
                + "hosted=\(counts.hosted), renderers=\(counts.renderers), "
                + "requestedUnpaused=\(counts.unpausedRenderers)"
        )
    }

    // MARK: - Properties

    var cachedThumbnailURL: URL? {
        get { lock.withLock { $0.cachedThumbnailURL } }
        set { lock.withLock { $0.cachedThumbnailURL = newValue } }
    }

    var cacheDirectoryURL: URL? {
        get { lock.withLock { $0.cacheDirectoryURL } }
        set { lock.withLock { $0.cacheDirectoryURL = newValue } }
    }

    /// Currently selected video ID, persisted to UserDefaults.
    var currentVideoID: String? {
        get { lock.withLock { $0.currentVideoID } }
        set {
            lock.withLock { $0.currentVideoID = newValue }
            UserDefaults.standard.set(newValue, forKey: WallpaperState.selectedVideoKey)
        }
    }

    // MARK: - Display & Presentation State

    /// Atomically record one desktop update and the lock state it implies.
    func recordDesktopUpdate(
        presentationMode: String,
        activityState: String
    ) -> (modeChanged: Bool, activityChanged: Bool, lockStateChanged: Bool) {
        lock.withLock { state in
            let locked = presentationMode == "locked"
            let changes = (
                modeChanged: state.presentationMode != presentationMode,
                activityChanged: state.activityState != activityState,
                lockStateChanged: state.isScreenLocked != locked
            )
            state.presentationMode = presentationMode
            state.activityState = activityState
            state.isScreenLocked = locked
            return changes
        }
    }

    /// Last known presentation mode from the framework's `update()` call.
    var presentationMode: String {
        get { lock.withLock { $0.presentationMode } }
        set { lock.withLock { $0.presentationMode = newValue } }
    }

    /// Last known activity state from the framework's `update()` call.
    var activityState: String {
        get { lock.withLock { $0.activityState } }
        set { lock.withLock { $0.activityState = newValue } }
    }

    /// Whether all displays are currently asleep.
    var isDisplayAsleep: Bool {
        get { lock.withLock { $0.isDisplayAsleep } }
        set { lock.withLock { $0.isDisplayAsleep = newValue } }
    }

    /// Whether the screen is currently locked (lock screen showing).
    /// Tracked via `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked`
    /// distributed notifications.
    var isScreenLocked: Bool {
        get { lock.withLock { $0.isScreenLocked } }
        set { lock.withLock { $0.isScreenLocked = newValue } }
    }
}

/// Force the WindowServer to reclaim a remote `CAContext`. Dropping our Swift
/// reference (ARC) is NOT enough: the context is refcounted across processes, and
/// WallpaperAgent's `CALayerHost` keeps the context's layer tree resident in the
/// render server until it's explicitly invalidated. Without this, every wallpaper
/// switch leaves a pinned tree behind → escalating composite cost / gray, reset
/// only by `killall WallpaperAgent`. `-[CAContext invalidate]` reclaims it even
/// while a consumer host is still attached.
func invalidateRemoteContext(_ caContext: AnyObject) {
    let sel = NSSelectorFromString("invalidate")
    guard let object = caContext as? NSObject, object.responds(to: sel) else { return }
    object.perform(sel)
}
