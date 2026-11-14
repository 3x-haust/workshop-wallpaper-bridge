import AppKit
import AVFoundation
import CoreMedia
import os
import QuartzCore

/// Builds the adaptive variant selector for a renderer. Captures only Sendable
/// values (the choice ID + a fallback URL), so it can cross into the render Task.
/// Reading the per-context `choice` (not the process-wide `currentVideoID`) keeps
/// each display on its own selection — otherwise every renderer would converge on
/// whichever choice was set most recently (multi-monitor bug).
func makeVariantSelector(
    choice: String?,
    fallback: URL
) -> @Sendable (PlaybackPolicy, CGSize) -> URL {
    { policy, destinationPixelSize in
        guard let videoID = choice else { return fallback }
        return VideoLibrary.shared.bestVariantURL(
            for: videoID,
            policy: policy,
            destinationPixelSize: destinationPixelSize
        ) ?? fallback
    }
}


/// WallpaperAgent normally reports a destination in backing pixels, but on a
/// scaled secondary display it can report logical points plus a scale factor.
/// Resolve against CoreGraphics' actual pixel dimensions so the remote context
/// does not occupy only one quarter of a 2× display.
private struct SurfaceGeometry {
    let size: CGSize
    let contentsScale: CGFloat
    let snapshotPixelSize: CGSize
}

private func surfaceGeometry(
    destinationSize: CGSize,
    scaleFactor: CGFloat,
    displayID: UInt32?,
    isPreview: Bool
) -> SurfaceGeometry {
    let normalizedScale = max(scaleFactor, 1)
    let scaledSize = CGSize(
        width: destinationSize.width * normalizedScale,
        height: destinationSize.height * normalizedScale
    )
    guard !isPreview, let displayID else {
        return SurfaceGeometry(
            size: destinationSize,
            contentsScale: normalizedScale,
            snapshotPixelSize: scaledSize
        )
    }
    let displayPixels = CGSize(
        width: CGDisplayPixelsWide(displayID),
        height: CGDisplayPixelsHigh(displayID)
    )
    guard displayPixels.width > 0, displayPixels.height > 0 else {
        return SurfaceGeometry(
            size: destinationSize,
            contentsScale: normalizedScale,
            snapshotPixelSize: scaledSize
        )
    }

    func distance(_ size: CGSize) -> CGFloat {
        abs(size.width - displayPixels.width)
            + abs(size.height - displayPixels.height)
    }
    if distance(scaledSize) + 1 < distance(destinationSize) {
        return SurfaceGeometry(
            size: scaledSize,
            contentsScale: 1,
            snapshotPixelSize: scaledSize
        )
    }
    return SurfaceGeometry(
        size: destinationSize,
        // A remote CAContext is sized in the display's physical pixels. Keeping
        // WallpaperAgent's reported 2× scale on a 1× external display makes the
        // IOSurface repeat as four quadrants.
        contentsScale: 1,
        snapshotPixelSize: destinationSize
    )
}

private func resizeRootLayer(
    _ rootLayer: CALayer,
    to size: CGSize,
    contentsScale: CGFloat
) {
    guard rootLayer.bounds.size != size
        || rootLayer.contentsScale != contentsScale else {
        return
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    rootLayer.frame = CGRect(origin: .zero, size: size)
    rootLayer.contentsScale = contentsScale
    for layer in rootLayer.sublayers ?? [] {
        layer.frame = rootLayer.bounds
        layer.contentsScale = contentsScale
    }
    CATransaction.commit()
    CATransaction.flush()
}

private func installFallbackGradient(on rootLayer: CALayer) {
    let gradientLayer = CAGradientLayer()
    disableImplicitAnimations(on: gradientLayer)
    gradientLayer.colors = [
        CGColor(red: 0.2, green: 0.0, blue: 0.5, alpha: 1.0),
        CGColor(red: 0.0, green: 0.3, blue: 0.7, alpha: 1.0),
        CGColor(red: 0.0, green: 0.6, blue: 0.4, alpha: 1.0),
    ]
    gradientLayer.startPoint = CGPoint(x: 0, y: 0)
    gradientLayer.endPoint = CGPoint(x: 1, y: 1)
    gradientLayer.frame = rootLayer.bounds
    gradientLayer.contentsScale = rootLayer.contentsScale

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    // Beneath the layer deck, which is attached when the surface is created. The
    // deck's layers paint nothing until their first frame (that is what
    // `_setDisallowsVideoLayerDisplayCompositing:` buys), so this still shows
    // through as the fallback.
    rootLayer.insertSublayer(gradientLayer, at: 0)
    CATransaction.commit()
    CATransaction.flush()
}

private struct RemoteSurface: @unchecked Sendable {
    let context: CAContext
    let contextID: UInt32
    let rootLayer: CALayer
    let surface: WallpaperSurface
    let replyObject: AnyObject
}

private func makeRemoteSurface(
    displayID: UInt32?,
    geometry: SurfaceGeometry
) throws -> RemoteSurface {
    var contextOptions: [String: Any] = [:]
    if let displayID {
        contextOptions["displayId"] = displayID
    }
    let rawContext: Any? = contextOptions.isEmpty
        ? CAContext.remoteContext()
        : CAContext.perform(
            NSSelectorFromString("remoteContextWithOptions:"),
            with: contextOptions
        )?.takeUnretainedValue()
    guard let context = rawContext as? CAContext, context.contextId != 0 else {
        throw NSError(
            domain: "DriftwoodWallpaperExtension",
            code: 4,
            userInfo: [
                NSLocalizedDescriptionKey: "Failed to create remote CAContext"
            ]
        )
    }

    let rootLayer = CALayer()
    disableImplicitAnimations(on: rootLayer)
    rootLayer.frame = CGRect(origin: .zero, size: geometry.size)
    rootLayer.contentsScale = geometry.contentsScale
    rootLayer.contentsGravity = .resizeAspectFill
    context.layer = rootLayer
    // The surface's two render layers must exist before WallpaperAgent hosts this
    // context — it does not reliably notice layers added afterwards, and a crossfade
    // needs the second one.
    let surface = WallpaperSurface(rootLayer: rootLayer)
    // Asked fresh at each switch rather than latched, so a surface created while the
    // displays are asleep is correct from the start and a missed wake notification cannot
    // leave crossfades disabled.
    surface.animatesContentChanges = { !WallpaperState.shared.isDisplayAsleep }
    CATransaction.flush()

    guard let replyObject = createRemoteContextXPC(
        contextId: context.contextId
    ) else {
        invalidateRemoteContext(context)
        throw NSError(
            domain: "DriftwoodWallpaperExtension",
            code: 3,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Failed to create remote context response"
            ]
        )
    }
    return RemoteSurface(
        context: context,
        contextID: context.contextId,
        rootLayer: rootLayer,
        surface: surface,
        replyObject: replyObject
    )
}

private func currentContextReply(
    for key: DisplayKey,
    fallback: AnyObject
) -> AnyObject {
    guard let contextID = WallpaperState.shared.context(for: key)?.contextId,
          let reply = createRemoteContextXPC(contextId: contextID) else {
        return fallback
    }
    return reply
}

/// Process-wide serialization for wallpaper lifecycle XPC. Every connection gets its own
/// `WallpaperXPCHandler`, but the Agent multiplexes desktop + Settings-preview + thumbnail
/// connections, so lifecycle callbacks (acquire/update/invalidate/choice change) can
/// otherwise interleave across connections. We funnel them all through ONE serial queue —
/// mirroring Apple's single `Controller`-actor `AsyncQueue` — so an invalidate can't slip
/// between the halves of an acquire.
enum Lifecycle {
    /// Deliberately the render core's queue, not a second one: surface teardown here has to
    /// be ordered against content switches and crossfade cleanup happening in the core.
    static let queue = RenderQueue.serial

    /// Pending per-display teardown timers. Touched ONLY on `queue`.
    nonisolated(unsafe) static var teardownTimers: [DisplayKey: DispatchWorkItem] = [:]

    /// Grace between an invalidate of a display's LIVE wallpaper and actually tearing it
    /// down. A re-acquire (display woke / switched) cancels it; only a display that stays
    /// gone (asleep/removed) lets it fire. Short enough to save power promptly, long enough
    /// to ride out a brief sleep/wake flicker.
    static let teardownGrace: TimeInterval = 15.0

    /// Time for WallpaperAgent to consume a successful acquire reply and swap its
    /// CALayerHost before the old remote context is invalidated.
    static let replacementHandoffGrace: TimeInterval = 0.75

    /// Pending per-preview idle timers. Touched ONLY on `queue`.
    nonisolated(unsafe) static var previewIdleTimers: [DisplayKey: DispatchWorkItem] = [:]

    /// How long a Settings-preview surface keeps playing after its last acquire/update.
    /// WallpaperAgent holds preview surfaces long after the Settings pane closes, and each
    /// one is a full-rate decode of a wallpaper nobody can see. Long enough that a pane
    /// being looked at (whose interactions send updates) never visibly freezes.
    static let previewIdleGrace: TimeInterval = 60
}

/// Arm (or re-arm) the teardown timer for a display whose live wallpaper was invalidated.
/// MUST be called on `Lifecycle.queue`.
private func scheduleTeardown(for key: DisplayKey) {
    Lifecycle.teardownTimers[key]?.cancel()
    let item = DispatchWorkItem {
        Lifecycle.teardownTimers[key] = nil
        let torn = WallpaperState.shared.tearDownContext(for: key)
        extensionLog("  [teardown] grace fired for display \(key.displayID) → \(torn ? "stopped renderer + invalidated CAContext" : "nothing to tear down")")
        if torn {
            WallpaperState.shared.logLifecycleTelemetry("teardown grace fired")
        }
    }
    Lifecycle.teardownTimers[key] = item
    Lifecycle.queue.asyncAfter(deadline: .now() + Lifecycle.teardownGrace, execute: item)
}

/// Cancel a display's pending teardown because it was re-acquired (woke / switched).
/// MUST be called on `Lifecycle.queue`.
private func cancelTeardown(for key: DisplayKey) {
    if let item = Lifecycle.teardownTimers.removeValue(forKey: key) {
        item.cancel()
        extensionLog("  [teardown] cancelled pending teardown for display \(key.displayID) (re-acquired)")
    }
}

/// A Settings-preview surface just saw connection activity (acquire or update): resume it
/// if the idle pause froze it, and re-arm its idle timer. MUST be called on
/// `Lifecycle.queue`, which is the render queue the surface requires.
private func markPreviewActive(for key: DisplayKey) {
    Lifecycle.previewIdleTimers[key]?.cancel()
    if WallpaperState.shared.setPreviewIdle(false, for: key) {
        // It was frozen. Resume only this preview under current policy.
        WallpaperPrefs.shared.applyCurrentState(to: key)
        extensionLog("  [preview] surface \(key.surfaceUUID) active again — resumed")
    }
    let item = DispatchWorkItem {
        Lifecycle.previewIdleTimers[key] = nil
        // Refused for surfaces that were torn down or aren't previews, so a stale
        // timer can never freeze a live wallpaper.
        guard WallpaperState.shared.setPreviewIdle(true, for: key) else { return }
        WallpaperState.shared.applyPolicy(.paused, for: key)
        extensionLog(
            "  [preview] surface \(key.surfaceUUID) idle for "
                + "\(Int(Lifecycle.previewIdleGrace))s — paused preview decode"
        )
    }
    Lifecycle.previewIdleTimers[key] = item
    Lifecycle.queue.asyncAfter(
        deadline: .now() + Lifecycle.previewIdleGrace,
        execute: item
    )
}

/// Drop a preview surface's idle timer once WallpaperAgent lets go of it.
/// MUST be called on `Lifecycle.queue`.
private func cancelPreviewIdle(for key: DisplayKey) {
    Lifecycle.previewIdleTimers.removeValue(forKey: key)?.cancel()
    WallpaperState.shared.setPreviewIdle(false, for: key)
}

/// Reclaim invalidated surfaces as soon as their replacement is ready. Keeping
/// every switched-out CAContext alive for the full sleep/wake grace lets rapid
/// wallpaper changes pile up remote surfaces and can desynchronize WallpaperAgent
/// (partial/quarter-screen output until it is restarted).
/// MUST be called on `Lifecycle.queue`.
private func retireSupersededSurfaces(replacedBy replacementKey: DisplayKey) {
    let superseded = Lifecycle.teardownTimers.keys.filter {
        WallpaperState.shared.isReadyReplacement(replacementKey, for: $0)
    }
    for key in superseded {
        Lifecycle.teardownTimers.removeValue(forKey: key)?.cancel()
        let torn = WallpaperState.shared.tearDownContext(for: key)
        extensionLog(
            "  [teardown] replacement ready on display \(key.displayID) → "
                + (torn ? "reclaimed superseded surface" : "surface already gone")
        )
        if torn {
            WallpaperState.shared.logLifecycleTelemetry("replacement ready")
        }
    }
}

/// Mark a new surface ready from any callback queue, then serialize retirement
/// with acquire/invalidate handling.
private func surfaceBecameReady(_ key: DisplayKey) {
    WallpaperState.shared.markReady(for: key)
    // Queue behind policy work scheduled by the acquire completion so the logged
    // requested policy is current.
    Lifecycle.queue.async {
        WallpaperState.shared.logLifecycleTelemetry("surface ready")
    }
    Lifecycle.queue.asyncAfter(deadline: .now() + Lifecycle.replacementHandoffGrace) {
        retireSupersededSurfaces(replacedBy: key)
    }
}

/// Keeps the host-side snapshot cache in step with assignment-backed content.
///
/// The permanent per-display choice architecture changes the renderer without
/// changing macOS's selected choice, so `selectedChoicesDidChange` is not called
/// and WallpaperAgent otherwise keeps the snapshot from whichever content first
/// occupied that choice. That stale snapshot is what loginwindow can show after
/// the user session has gone away.
final class WallpaperSnapshotInvalidator: @unchecked Sendable {
    static let shared = WallpaperSnapshotInvalidator()

    private let lock = NSLock()
    private nonisolated(unsafe) var proxies:
        [UUID: any WallpaperExtensionProxyXPCProtocol] = [:]
    private nonisolated(unsafe) var hasPendingInvalidation = false

    private init() {}

    func register(
        _ proxy: any WallpaperExtensionProxyXPCProtocol
    ) -> UUID {
        let token = UUID()
        let shouldInvalidate = lock.withLock {
            proxies[token] = proxy
            guard hasPendingInvalidation else { return false }
            hasPendingInvalidation = false
            return true
        }
        if shouldInvalidate {
            invalidate(using: [proxy])
        }
        return token
    }

    func unregister(_ token: UUID?) {
        guard let token else { return }
        _ = lock.withLock {
            proxies.removeValue(forKey: token)
        }
    }

    func invalidateSnapshots() {
        let currentProxies = lock.withLock {
            let current = Array(proxies.values)
            if current.isEmpty {
                hasPendingInvalidation = true
            }
            return current
        }
        invalidate(using: currentProxies)
    }

    private func invalidate(
        using proxies: [any WallpaperExtensionProxyXPCProtocol]
    ) {
        for proxy in proxies {
            proxy.invalidateSnapshots { error in
                if let error {
                    extensionLog(
                        "  [Snapshots] Invalidation failed: \(error)"
                    )
                } else {
                    traceLog("  [Snapshots] WallpaperAgent cache invalidated")
                }
            }
        }
    }
}

final class WallpaperXPCHandler: NSObject, WallpaperExtensionXPCProtocol {
    /// Proxy to call methods on WallpaperAgent (ping, invalidateSnapshots, etc.).
    /// Lock-backed: it's assigned in `accept(connection:)` and nilled from the
    /// invalidation queue, while XPC callbacks read it from the message queue.
    /// The proxy existential isn't Sendable, so this uses a plain `NSLock` around
    /// `nonisolated(unsafe)` storage rather than `OSAllocatedUnfairLock` (whose
    /// `withLock` body is `@Sendable` and would reject the non-Sendable value).
    private let agentProxyLock = NSLock()
    private nonisolated(unsafe) var _agentProxy: (any WallpaperExtensionProxyXPCProtocol)?
    var agentProxy: (any WallpaperExtensionProxyXPCProtocol)? {
        get { agentProxyLock.lock(); defer { agentProxyLock.unlock() }; return _agentProxy }
        set { agentProxyLock.lock(); defer { agentProxyLock.unlock() }; _agentProxy = newValue }
    }

    /// PID of the peer on this connection (WallpaperAgent vs. Settings preview vs.
    /// the thumbnail service), set in `accept(connection:)`. Logged so acquire and
    /// invalidation can be attributed to a specific connection.
    var connectionPID: Int32 = -1

    /// Whether this connection's most recent acquire was a Settings *preview*
    /// (`isPreview: true`). A preview connection reports its own presentation state
    /// (which idles/toggles as the picker is interacted with), and since every
    /// connection shares the one desktop renderer, letting a preview's `update()`
    /// apply pause policy would freeze the visible desktop wallpaper. Preview
    /// connections therefore don't drive playback; only the live desktop connection
    /// (`isPreview: false`) does.
    private var acquiredAsPreview = false

    /// Surfaces acquired on this XPC connection and not subsequently invalidated here.
    /// WallpaperKit occasionally sends an identifier with no UUID. We only use this
    /// history when it names one currently hosted surface whose latest acquire was on
    /// this connection. Touched only on `Lifecycle.queue`.
    private let acquisitionOwner = UUID()
    private var acquiredSurfaceKeys: Set<DisplayKey> = []

    // MARK: - Lifecycle

    /// Stable per-display surface UUID for the rare acquire that carries no WallpaperID — so
    /// such acquires still collapse to one context per display (old behavior) instead of
    /// minting a fresh context each time. Encodes the displayID into a fixed UUID layout.
    static func fallbackSurfaceUUID(forDisplay displayID: UInt32) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", displayID))
            ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    }

    func acquire(withId id: Any?, request: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        nonisolated(unsafe) let unsafeRequest = request
        nonisolated(unsafe) let unsafeID = id
        nonisolated(unsafe) let handler = self
        Lifecycle.queue.async { handler.acquireBody(id: unsafeID, request: unsafeRequest, reply: reply) }
    }

    private func acquireBody(id: Any?, request: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        traceLog("=== ACQUIRE ===")

        // Extract destination size from WallpaperCreationRequestXPC
        var destSize = CGSize(width: 2_560, height: 1_440) // fallback
        var scaleFactor: CGFloat = 2.0
        var isPreview = false
        var displayID: UInt32?
        if let reqObj = request as? NSObject {
            let mirror = Mirror(reflecting: reqObj)
            for child in mirror.children {
                let reqMirror = Mirror(reflecting: child.value)
                for prop in reqMirror.children {
                    if prop.label == "destination" {
                        let destMirror = Mirror(reflecting: prop.value)
                        for destProp in destMirror.children {
                            if destProp.label == "size", let size = destProp.value as? CGSize {
                                destSize = size
                            } else if destProp.label == "scaleFactor", let sf = destProp.value as? CGFloat {
                                scaleFactor = sf
                            } else if destProp.label == "directDisplayID", let did = destProp.value as? UInt32 {
                                displayID = did
                            }
                        }
                    } else if prop.label == "isPreview", let preview = prop.value as? Bool {
                        isPreview = preview
                    } else if prop.label == "cacheDirectory" {
                        if let url = prop.value as? URL {
                            WallpaperState.shared.cacheDirectoryURL = url
                        }
                    }
                }
            }
        }

        // Extract choice configuration and files from descriptor via Mirror traversal
        // Path: WallpaperCreationRequestXPC.rawValue.descriptor.{configuration, files}
        var choiceConfiguration: String?
        var choiceFiles: [URL] = []
        if let reqObj = request as? NSObject {
            let mirror = Mirror(reflecting: reqObj)
            if let rawValue = mirror.children.first?.value {
                let rawMirror = Mirror(reflecting: rawValue)
                for prop in rawMirror.children where prop.label == "descriptor" {
                    let descMirror = Mirror(reflecting: prop.value)
                    for descProp in descMirror.children {
                        if descProp.label == "configuration" {
                            if let data = descProp.value as? Data, !data.isEmpty {
                                choiceConfiguration = String(data: data, encoding: .utf8)
                            }
                        } else if descProp.label == "files" {
                            if let urls = descProp.value as? [URL] {
                                choiceFiles = urls
                            }
                        }
                    }
                }
            }
            // If direct Mirror didn't work, try string description parsing as fallback
            if choiceConfiguration == nil {
                let desc = String(describing: reqObj)
                // Look for our identifier in the description
                if let idRange = desc.range(of: "identifier: \"") {
                    let after = desc[idRange.upperBound...]
                    if let endQuote = after.firstIndex(of: "\"") {
                        let identifier = String(after[..<endQuote])
                        traceLog("  [Choice] Fallback extraction from description: identifier=\(identifier)")
                        choiceConfiguration = identifier
                    }
                }
            }
        }

        // On extension restart WallpaperAgent can omit `configuration` while
        // retaining the per-display descriptor file. Recover the matching choice
        // so each monitor keeps its own resource instead of the first library item.
        let requestedResourceURL = choiceFiles.first {
            $0.isFileURL && FileManager.default.fileExists(atPath: $0.path)
        }
        if choiceConfiguration == nil,
           let requestedResourceURL,
           let entry = VideoLibrary.shared.entry(
               forResourceURL: requestedResourceURL
           ) {
            choiceConfiguration = entry.id
        }

        traceLog("  destination: \(destSize) @\(scaleFactor)x, isPreview: \(isPreview), pid: \(connectionPID), choice: \(choiceConfiguration ?? "nil"), files: \(choiceFiles)")
        acquiredAsPreview = isPreview
        let wallpaperUUID = extractWallpaperUUID(fromID: id)
        let resolvedDisplayID = displayID
            ?? wallpaperUUID.flatMap {
                WallpaperState.shared.resolveWallpaperKey($0)?.displayID
            }
        let manifestAssignment = !isPreview
            ? resolvedDisplayID.flatMap {
                WallpaperAssignmentStore.shared.assignment(for: $0)
            }
            : nil
        // A Settings preview is a real animated surface, but it must not count
        // as an applied desktop surface. Resolve its current content separately
        // from `manifestAssignment`, which owns acknowledgments and errors.
        let previewAssignment: ResolvedWallpaperAssignment?
        if isPreview {
            previewAssignment =
                resolvedDisplayID.flatMap {
                WallpaperAssignmentStore.shared.assignment(for: $0)
            }
                ?? choiceConfiguration.flatMap {
                    WallpaperAssignmentStore.shared.assignment(
                        forDisplayChoiceID: $0
                    )
                }
                ?? requestedResourceURL.flatMap {
                    WallpaperAssignmentStore.shared.assignment(
                        forDisplaySlotResourceURL: $0
                    )
                }
        } else {
            previewAssignment = nil
        }
        let renderAssignment = manifestAssignment
            ?? previewAssignment
        if let renderAssignment {
            // The playlist entry the scheduler currently has this display on, not the
            // program as a whole — a surface renders one wallpaper at a time.
            choiceConfiguration = renderAssignment.contentUUID
        }
        let geometry = surfaceGeometry(
            destinationSize: destSize,
            scaleFactor: scaleFactor,
            displayID: resolvedDisplayID,
            isPreview: isPreview
        )
        traceLog("  resolved surface: \(geometry.size) @\(geometry.contentsScale)x")

        // Each acquire's `choiceConfiguration` is authoritative for *this* display's
        // context. Do NOT mutate the process-wide `currentVideoID` here based on a
        // diff — concurrent acquires for different displays would race and a renderer
        // can end up initialized with the wrong monitor's video. The global tracks
        // the last user-picked choice (via `selectedChoicesDidChange`); we only seed
        // it on first launch when UserDefaults has no value yet, so the menu-bar UI
        // has something sensible to show before the user picks anything.
        if WallpaperState.shared.currentVideoID == nil, let videoID = choiceConfiguration {
            WallpaperState.shared.currentVideoID = videoID
        }

        // Each WallpaperID (a Space, the lock-screen surface, or a Settings preview) is its own
        // hosted surface and must get its OWN CAContext — sharing one context per display let a
        // second Space or the lock surface steal it and black out the first. Key the context by
        // the WallpaperID UUID; fall back to a per-display constant if an id ever lacks one.
        let displayID0 = resolvedDisplayID ?? 0
        let surfaceUUID = wallpaperUUID
            ?? Self.fallbackSurfaceUUID(forDisplay: displayID0)
        let key = DisplayKey(displayID: displayID0, surfaceUUID: surfaceUUID)
        let videoURL = renderAssignment?.resourceURL
            ?? findVideoURL(forChoice: choiceConfiguration)
            ?? requestedResourceURL
        let cachedStill = renderAssignment?.posterImage
            ?? loadCachedSnapshotImage(forChoice: choiceConfiguration)
        let isMetalScene = renderAssignment?.kind == .metalScene
            || (videoURL.map(MetalScenePackage.isSceneResource) ?? false)

        // ---- REUSE: this wallpaper surface already has an active slot ----
        // Re-selecting is a no-op and assignment-backed changes reuse the hosted
        // display layer. Legacy choices that are not driven by the assignment
        // manifest still take the replacement-context path below.
        if let existing = WallpaperState.shared.context(for: key) {
            resizeRootLayer(
                existing.rootLayer,
                to: geometry.size,
                contentsScale: geometry.contentsScale
            )
            existing.surface.updateGeometry(
                bounds: existing.rootLayer.bounds,
                contentsScale: existing.rootLayer.contentsScale
            )
            traceLog("  [acquire] REUSE ctx=\(existing.contextId) display=\(key.displayID) storedVideoID=\(existing.videoID ?? "nil") newChoice=\(choiceConfiguration ?? "nil") renderer=\(existing.renderer.map { "#\($0.debugID)" } ?? "nil") videoURL=\(findVideoURL(forChoice: choiceConfiguration)?.lastPathComponent ?? "nil")")
            guard let replyObj = createRemoteContextXPC(contextId: existing.contextId) else {
                reply(
                    nil,
                    NSError(
                        domain: "DriftwoodWallpaperExtension",
                        code: 3,
                        userInfo: nil
                    )
                )
                return
            }
            // Do not cancel teardown or claim this acquire until a reusable reply object
            // exists. Otherwise a failed re-acquire can strand an unhosted context.
            WallpaperState.shared.registerWallpaperID(surfaceUUID, key: key)
            acquiredSurfaceKeys.insert(key)
            cancelTeardown(for: key)
            let resumedHosting = WallpaperState.shared.restoreHosting(
                for: key,
                owner: acquisitionOwner
            )
            if isPreview {
                markPreviewActive(for: key)
            }
            if resumedHosting {
                WallpaperPrefs.shared.applyCurrentState(to: key)
                WallpaperPrefs.shared.refreshActiveState()
                WallpaperState.shared.logLifecycleTelemetry("surface re-acquired")
            }

            let assignmentAlreadyApplied =
                manifestAssignment?.assignment.assignmentRevision
                    == existing.assignmentRevision
            if existing.videoID == choiceConfiguration,
               existing.renderer != nil,
               manifestAssignment == nil || assignmentAlreadyApplied {
                traceLog("  [acquire] SAME choice (\(choiceConfiguration ?? "nil")) + renderer present → no swap")
                if let manifestAssignment,
                   let renderer = existing.renderer {
                    WallpaperAssignmentStore.shared.markSurfaceApplied(
                        manifestAssignment.assignment,
                        contentUUID: manifestAssignment.contentUUID,
                        key: key,
                        rendererID: renderer.debugID
                    )
                }
                reply(replyObj, nil)
                return
            }
            guard let videoURL else {
                traceLog("  [acquire] no render source for new choice, keeping current")
                reply(replyObj, nil)
                return
            }
            // One path for every combination. The surface builds the replacement on its
            // idle layer and crossfades, so a renderer-kind change no longer needs a
            // whole fresh CAContext handed off to WallpaperAgent — that workaround
            // existed only because a single display layer could not switch producers
            // without a visible cut.
            let package: MetalScenePackage?
            if isMetalScene {
                do {
                    package = try renderAssignment?.metalPackage
                        ?? MetalScenePackage.load(from: videoURL)
                } catch {
                    if let assignment = manifestAssignment?.assignment {
                        WallpaperAssignmentStore.shared.recordError(
                            error.localizedDescription,
                            for: assignment
                        )
                    }
                    extensionLog("  [acquire] Metal scene failed to load: \(error)")
                    reply(replyObj, nil)
                    return
                }
            } else {
                package = nil
            }

            let content = WallpaperContent(
                id: choiceConfiguration ?? videoURL.path,
                kind: isMetalScene ? .metalScene : .video,
                resourceURL: videoURL,
                metalPackage: package,
                variantSelector: isMetalScene
                    ? nil
                    : makeVariantSelector(
                        choice: choiceConfiguration,
                        fallback: videoURL
                    ),
                posterImage: cachedStill
            )
            // The assignment observer is already delivering something to this surface, and
            // it will finish on its own — a second request would just queue behind it and
            // the two would report each other as superseded, producing an error ack for a
            // switch that actually succeeded. Only valid when there IS an observer: a
            // legacy choice has nothing else to deliver it, so it must queue normally.
            if manifestAssignment != nil, existing.surface.isBuilding {
                traceLog(
                    "  [acquire] build already in flight for display "
                        + "\(key.displayID) → serving the current surface"
                )
                reply(replyObj, nil)
                return
            }

            let assignment = manifestAssignment?.assignment
            let appliedContentUUID = manifestAssignment?.contentUUID
            let choiceID = choiceConfiguration
            existing.surface.setContent(content) { result in
                switch result {
                case .success(let rendererID):
                    if let assignment, let appliedContentUUID {
                        WallpaperAssignmentStore.shared.markSurfaceApplied(
                            assignment,
                            contentUUID: appliedContentUUID,
                            key: key,
                            rendererID: rendererID
                        )
                    } else {
                        WallpaperState.shared.updateVideoID(choiceID, for: key)
                    }
                    WallpaperPrefs.shared.refreshActiveState()
                case .failure(let error):
                    if let assignment {
                        WallpaperAssignmentStore.shared.recordError(
                            error.localizedDescription,
                            for: assignment
                        )
                    }
                }
            }
            reply(replyObj, nil)
            if !isMetalScene {
                let w = Int(geometry.snapshotPixelSize.width)
                let h = Int(geometry.snapshotPixelSize.height)
                Task { [videoURL, choiceConfiguration, w, h] in
                    await writeBMPSnapshot(
                        videoURL: videoURL,
                        videoID: choiceConfiguration,
                        displayPixelWidth: w,
                        displayPixelHeight: h
                    )
                }
            }
            return
        }

        // ---- CREATE: first acquire for this display slot ----
        let remote: RemoteSurface
        do {
            remote = try makeRemoteSurface(
                displayID: resolvedDisplayID,
                geometry: geometry
            )
        } catch {
            extensionLog("  ERROR: remote CAContext creation failed: \(error)")
            reply(nil, error)
            return
        }

        // Install the persistent slot now (renderer added async) so a concurrent
        // acquire for the same display reuses this context instead of creating another.
        WallpaperState.shared.installContext(
            ActiveWallpaper(
                caContext: remote.context,
                contextId: remote.contextID,
                rootLayer: remote.rootLayer,
                surface: remote.surface,
                displayID: resolvedDisplayID,
                videoID: choiceConfiguration,
                isPreview: isPreview,
                acquisitionOwner: acquisitionOwner
            ),
            for: key,
        )
        WallpaperState.shared.registerWallpaperID(surfaceUUID, key: key)
        acquiredSurfaceKeys.insert(key)
        // Defensive cleanup for a stale timer. A new context should not normally have one.
        cancelTeardown(for: key)
        extensionLog(
            "  Created context \(remote.contextID) for display \(key.displayID)"
        )
        if isPreview {
            markPreviewActive(for: key)
        }

        // Defer the XPC reply until the renderer has submitted its first sample and
        // the display layer has had a bounded opportunity to begin rendering.
        // WallpaperAgent keeps the previous surface hosted in the meantime. If a
        // decoder cannot confirm a live frame, the IOSurface-backed poster remains
        // the bounded fallback, and every branch still replies exactly once.

        guard let videoURL else {
            // No video file — solid gradient fallback. Static content, so it's ready as
            // soon as it's installed; reply immediately.
            installFallbackGradient(on: remote.rootLayer)
            reply(remote.replyObject, nil)
            surfaceBecameReady(key)
            extensionLog("  No video file found — solid color fallback")
            return
        }

        // Keep a nonblank layer available if WallpaperAgent issues a duplicate
        // acquire before the asynchronous renderer produces its first frame.
        installFallbackGradient(on: remote.rootLayer)

        let createPackage: MetalScenePackage?
        if isMetalScene {
            do {
                createPackage = try renderAssignment?.metalPackage
                    ?? MetalScenePackage.load(from: videoURL)
            } catch {
                extensionLog("  [acquire] Metal scene failed to load: \(error)")
                if let assignment = manifestAssignment?.assignment {
                    WallpaperAssignmentStore.shared.recordError(
                        error.localizedDescription,
                        for: assignment
                    )
                }
                reply(remote.replyObject, nil)
                surfaceBecameReady(key)
                return
            }
        } else {
            createPackage = nil
        }

        traceLog(
            "  Setting up renderer for: "
                + (isMetalScene ? "Metal scene" : videoURL.lastPathComponent)
        )
        let createContent = WallpaperContent(
            id: choiceConfiguration ?? videoURL.path,
            kind: isMetalScene ? .metalScene : .video,
            resourceURL: videoURL,
            metalPackage: createPackage,
            variantSelector: isMetalScene
                ? nil
                : makeVariantSelector(
                    choice: choiceConfiguration,
                    fallback: videoURL
                ),
            posterImage: cachedStill
        )
        let createAssignment = manifestAssignment?.assignment
        let createContentUUID = manifestAssignment?.contentUUID
        let replyObject = SendableBox(value: remote.replyObject)
        remote.surface.setContent(createContent) { result in
            switch result {
            case .success(let rendererID):
                WallpaperPrefs.shared.refreshActiveState()
                WallpaperPrefs.shared.applyCurrentState()
                if let createAssignment, let createContentUUID {
                    WallpaperAssignmentStore.shared.markSurfaceApplied(
                        createAssignment,
                        contentUUID: createContentUUID,
                        key: key,
                        rendererID: rendererID
                    )
                }
                reply(replyObject.value, nil)
            case .failure(let error):
                extensionLog(
                    "  [acquire] renderer did not become current: \(error); "
                        + "using the fallback or newer wallpaper"
                )
                if let createAssignment {
                    WallpaperAssignmentStore.shared.recordError(
                        error.localizedDescription,
                        for: createAssignment
                    )
                }
                reply(
                    currentContextReply(for: key, fallback: replyObject.value),
                    nil
                )
            }
            surfaceBecameReady(key)
        }
        if !isMetalScene {
            let w = Int(geometry.snapshotPixelSize.width)
            let h = Int(geometry.snapshotPixelSize.height)
            Task {
                await writeBMPSnapshot(
                    videoURL: videoURL,
                    videoID: choiceConfiguration,
                    displayPixelWidth: w,
                    displayPixelHeight: h
                )
            }
        }
    }

    func update(withId id: Any?, request: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        nonisolated(unsafe) let unsafeID = id
        nonisolated(unsafe) let unsafeRequest = request
        nonisolated(unsafe) let handler = self
        Lifecycle.queue.async {
            handler.updateBody(id: unsafeID, request: unsafeRequest, reply: reply)
        }
    }

    private func updateBody(
        id: Any?,
        request: Any?,
        reply: @escaping @Sendable ((any Error)?) -> Void
    ) {
        // Extract presentation mode / activity state by walking the request's Mirror
        // for the named properties and reading the enum case, rather than scanning a
        // stringified description (which silently fell through to "?" — and so failed
        // to pause — whenever the description format didn't match). Default to the
        // benign desktop-active values if a field genuinely can't be found.
        var presentationMode = "default"
        var activityState = "active"
        if let request {
            if let mode = mirrorFindProperty("presentationMode", in: request) {
                presentationMode = enumCaseName(mode)
            }
            if let activity = mirrorFindProperty("activityState", in: request) {
                activityState = enumCaseName(activity)
            }
        }

        // Settings previews have an independent lifecycle. Their idle/suspended
        // updates must never pause the live desktop renderers.
        let updateIsPreview = extractWallpaperUUID(fromID: id)
            .flatMap(WallpaperState.shared.isPreview(for:))
            ?? acquiredAsPreview
        guard !updateIsPreview else {
            // Ignored for *policy* — but it is the signal that the Settings picker is
            // being interacted with, so it keeps that preview's idle pause at bay.
            if let key = extractWallpaperUUID(fromID: id)
                .flatMap(WallpaperState.shared.resolveWallpaperKey) {
                markPreviewActive(for: key)
            }
            traceLog("=== UPDATE (preview pid \(connectionPID)) === policy ignored, activity noted")
            reply(nil)
            return
        }

        // Record the framework state atomically. The Agent is authoritative for the
        // lock state once it sends a desktop update.
        let changes = WallpaperState.shared.recordDesktopUpdate(
            presentationMode: presentationMode,
            activityState: activityState
        )

        guard changes.modeChanged
            || changes.activityChanged
            || changes.lockStateChanged else {
            traceLog(
                "=== UPDATE (desktop pid \(connectionPID)) === unchanged mode: "
                    + "\(presentationMode), activity: \(activityState)"
            )
            reply(nil)
            return
        }

        let prefs = WallpaperPrefs.shared
        // Apple-like ramp when alwaysPauseDesktop is on:
        // desktop → lock = ramp up (start playing), lock → desktop = ramp down (pause).
        // Only ramp when activity is active (suspended = hard pause, process may sleep).
        let animated = prefs.alwaysPauseDesktop
            && activityState == "active"
            && changes.modeChanged

        prefs.applyCurrentState(
            presentationMode: presentationMode,
            activityState: activityState,
            animated: animated
        )

        extensionLog("=== UPDATE (desktop pid \(connectionPID)) === mode: \(presentationMode), activity: \(activityState)")
        reply(nil)
    }

    func invalidate(withId id: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        nonisolated(unsafe) let unsafeID = id
        nonisolated(unsafe) let handler = self
        Lifecycle.queue.async { handler.invalidateBody(id: unsafeID, reply: reply) }
    }

    private func invalidateBody(id: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        // Prefer an exact UUID learned at acquire. Some WallpaperKit paths omit the UUID;
        // those may fall back only when this connection has one currently hosted acquire.
        // A valid but unknown UUID never falls back, because it may belong to another
        // provider or a surface this connection did not acquire.
        let identifierUUIDs = extractWallpaperUUIDs(fromID: id)
        let resolvedPairs = identifierUUIDs.compactMap { uuid in
            WallpaperState.shared.resolveWallpaperKey(uuid).map { (uuid, $0) }
        }
        let resolvedKeys = Set(resolvedPairs.map(\.1))

        let key: DisplayKey
        let targetDescription: String
        if resolvedKeys.count == 1, let resolved = resolvedPairs.first {
            key = resolved.1
            targetDescription = "UUID \(resolved.0)"
        } else if resolvedKeys.count > 1 {
            extensionLog(
                "=== INVALIDATE === identifier resolves to multiple surfaces → ignore"
            )
            reply(nil)
            return
        } else if !identifierUUIDs.isEmpty {
            extensionLog(
                "=== INVALIDATE === UUID(s) unknown (not ours / already forgotten) → ignore"
            )
            reply(nil)
            return
        } else {
            let candidates = acquiredSurfaceKeys.filter {
                WallpaperState.shared.isHosted($0, by: acquisitionOwner)
            }
            guard candidates.count == 1, let candidate = candidates.first else {
                extensionLog(
                    "=== INVALIDATE === no UUID and connection history is "
                        + "\(candidates.isEmpty ? "empty" : "ambiguous") → ignore"
                )
                reply(nil)
                return
            }
            key = candidate
            targetDescription = "no UUID; connection-local surface \(key.surfaceUUID)"
        }

        acquiredSurfaceKeys.remove(key)
        guard WallpaperState.shared.pauseUnhostedSurface(for: key) else {
            extensionLog(
                "=== INVALIDATE === \(targetDescription) already unhosted → ignore"
            )
            reply(nil)
            return
        }
        WallpaperState.shared.forgetWallpaperIDs(for: key)
        cancelPreviewIdle(for: key)
        scheduleTeardown(for: key)
        WallpaperState.shared.logLifecycleTelemetry("surface invalidated")
        if WallpaperState.shared.hasReadyReplacement(for: key) {
            extensionLog(
                "=== INVALIDATE === \(targetDescription) → replacement ready; "
                    + "reclaiming display \(key.displayID) surface after handoff"
            )
            Lifecycle.queue.asyncAfter(
                deadline: .now() + Lifecycle.replacementHandoffGrace
            ) {
                guard WallpaperState.shared.hasReadyReplacement(for: key) else { return }
                Lifecycle.teardownTimers.removeValue(forKey: key)?.cancel()
                let torn = WallpaperState.shared.tearDownContext(for: key)
                extensionLog(
                    "  [teardown] replacement handoff on display \(key.displayID) → "
                        + (torn ? "reclaimed superseded surface" : "surface already gone")
                )
                if torn {
                    WallpaperState.shared.logLifecycleTelemetry(
                        "replacement handoff"
                    )
                }
            }
        } else {
            extensionLog(
                "=== INVALIDATE === \(targetDescription) → tear down surface on "
                    + "display \(key.displayID) in \(Lifecycle.teardownGrace)s "
                    + "unless re-acquired"
            )
        }
        reply(nil)
    }

    func snapshot(withId id: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        traceLog("=== SNAPSHOT ===")

        let identifierUUIDs = extractWallpaperUUIDs(fromID: id)
        let context = identifierUUIDs.lazy.compactMap(
            WallpaperState.shared.context(forWallpaperUUID:)
        ).first
        let displayAssignment = identifierUUIDs.lazy.compactMap {
            WallpaperAssignmentStore.shared.assignment(
                forDisplayChoiceID: $0.uuidString
            )
        }.first
        if !identifierUUIDs.isEmpty,
           context == nil,
           displayAssignment == nil {
            traceLog("  Snapshot target no longer has an active context")
            reply(nil, nil)
            return
        }
        let currentTime = context?.renderer?.currentVideoTime
        let generatedImage =
            context?.renderer?.snapshot()
            ?? displayAssignment?.posterImage
        let choiceID =
            context?.videoID
            ?? displayAssignment?.contentUUID
        let resourceURL =
            displayAssignment?.resourceURL
            ?? choiceID.flatMap(VideoLibrary.shared.videoURL(for:))
        traceLog(
            "  Snapshot route: identifiers=\(identifierUUIDs.count) "
                + "context=\(context != nil) "
                + "displayAssignment="
                + "\(displayAssignment?.assignment.displayUUID ?? "nil") "
                + "entry=\(displayAssignment?.contentUUID ?? "nil")"
        )

        Task {
            if let generatedImage,
               let snapshotXPC = renderSnapshotToIOSurface(image: generatedImage) {
                reply(snapshotXPC, nil)
                traceLog("  Snapshot replied (generated IOSurface)")
            } else if let snapshotXPC = await createSnapshotViaRuntime(
                resourceURL: resourceURL,
                choiceID: choiceID,
                currentTime: currentTime
            ) {
                reply(snapshotXPC, nil)
                traceLog("  Snapshot replied (IOSurface)")
            } else {
                reply(nil, nil)
                traceLog("  Snapshot replied (nil)")
            }
        }
    }

    // MARK: - Settings

    func provideSettingsViewModels(withContentTypes _: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        traceLog("=== PROVIDE SETTINGS VIEW MODELS ===")

        Task {
            if let result = await buildSettingsViewModelsXPC() {
                traceLog("  [Settings] Remapped to \(NSStringFromClass(type(of: result as AnyObject)))")
                reply(result, nil)
            } else {
                traceLog("  [Settings] Build failed, using empty fallback")
                reply(makeEmptyGroupsResponse(), nil)
            }
        }
    }

    // MARK: - Choices

    func addChoiceRequest(withChoiceRequest _: Any?, onBehalfOfProcess _: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        traceLog("=== ADD CHOICE REQUEST ===")
        reply(nil, nil)
    }

    func removeChoiceRequest(withChoiceRequest request: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        nonisolated(unsafe) let unsafeRequest = request
        nonisolated(unsafe) let handler = self
        Lifecycle.queue.async { handler.removeChoiceRequestBody(request: unsafeRequest, reply: reply) }
    }

    private func removeChoiceRequestBody(request _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        extensionLog("=== REMOVE CHOICE REQUEST ===")
        // The app owns its media catalog, assignments, and deployed copies.
        // Deleting only the extension copy would leave those sources of truth
        // inconsistent, so this unsupported path fails closed.
        reply(NSError(
            domain: "DriftwoodWallpaperExtension",
            code: 5,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Remove wallpapers in Workshop Wallpaper Bridge."
            ]
        ))
    }

    func selectedChoicesDidChange(for id: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        nonisolated(unsafe) let unsafeID = id
        nonisolated(unsafe) let handler = self
        Lifecycle.queue.async { handler.selectedChoicesDidChangeBody(id: unsafeID, reply: reply) }
    }

    private func selectedChoicesDidChangeBody(id: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        extensionLog("=== SELECTED CHOICES DID CHANGE ===")

        // Extract the choice identifier from the WallpaperChoiceID
        var choiceIdentifier: String?
        if let idObj = id as? NSObject {
            let mirror = Mirror(reflecting: idObj)
            for child in mirror.children {
                let desc = String(describing: child.value)
                // Look for the identifier field which contains our video UUID
                if let range = desc.range(of: "identifier: \"") {
                    let after = desc[range.upperBound...]
                    if let endQuote = after.firstIndex(of: "\"") {
                        choiceIdentifier = String(after[..<endQuote])
                    }
                }
            }
        }

        guard let videoID = choiceIdentifier else {
            extensionLog("selectedChoicesDidChange: unknown choice \(String(describing: choiceIdentifier))")
            reply(nil)
            return
        }

        guard VideoLibrary.shared.entry(for: videoID) != nil else {
            extensionLog("selectedChoicesDidChange: unknown video \(videoID)")
            reply(nil)
            return
        }

        extensionLog("=== CHOICE CHANGED === videoID: \(videoID)")

        // Track the last user-picked video (for menu-bar UI / new-acquire fallback).
        // The XPC API does NOT tell us which display this choice is for — only that
        // the user picked it. We can't safely touch any renderer here; doing so used
        // to flip the wrong display, because stopping all renderers forced macOS to
        // re-acquire every display, and the racing acquires would pick up the wrong
        // per-context choiceConfiguration. macOS issues `invalidate(oldID)` and
        // `acquire(newID)` for the affected display on its own; let it.
        WallpaperState.shared.currentVideoID = videoID
        WallpaperState.shared.cachedThumbnailURL = nil
        WallpaperPrefs.shared.updateCurrentVideo()

        // Invalidate Agent snapshots so the picker re-fetches with the new video.
        if let proxy = agentProxy {
            proxy.invalidateSnapshots { error in
                if let error {
                    extensionLog("  [Choice] invalidateSnapshots error: \(error)")
                }
            }
        }

        reply(nil)
    }

    func invokeContextMenuAction(withMenuItemID menuItemID: Any?, groupItemID _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        let identifier = (menuItemID as? String) ?? String(describing: menuItemID ?? "nil")
        extensionLog("=== CONTEXT MENU ACTION === identifier: \(identifier)")

        if identifier == "add-video" {
            extensionLog("  Launching companion app via NSWorkspace")
            if let url = URL(string: "driftwood://import") {
                let opened = NSWorkspace.shared.open(url)
                traceLog("  NSWorkspace.open = \(opened)")
            }
        }

        reply(nil)
    }

    // MARK: - Downloads

    func isChoiceDownloaded(with _: Any?, reply: @escaping @Sendable (Bool, (any Error)?) -> Void) {
        traceLog("isChoiceDownloaded")
        reply(true, nil)
    }

    func download(withChoiceID _: Any?, reply: ((any Error)?) -> Void) -> Any? {
        traceLog("download")
        reply(nil)
        return nil
    }

    func pauseDownload(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    func cancelDownload(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    func resumeDownload(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    func removeDownload(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    // MARK: - Migration

    func migrateSelectedChoice(for _: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        traceLog("migrateSelectedChoice")
        reply(nil, nil)
    }

    func migrate(from _: Any?, to _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        traceLog("migrate")
        reply(nil)
    }

    // MARK: - Shuffle

    func skipShuffledContent(withId _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        traceLog("skipShuffledContent")
        reply(nil)
    }

    func canSkipShuffledContent(withId _: Any?, reply: @escaping @Sendable (Bool, (any Error)?) -> Void) {
        traceLog("canSkipShuffledContent")
        reply(false, nil)
    }

    // MARK: - Debug & Notifications

    func handleDebugRequest(for _: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        traceLog("handleDebugRequest")
        reply(nil, nil)
    }

    func handleNotification(withNamed name: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        traceLog("handleNotification(\(name ?? "nil"))")
        reply(nil)
    }
}

/// Recursively search a value's `Mirror` for a stored property with the given
/// label, to a shallow depth. Robust to the XPC wrapper nesting, unlike scanning
/// a stringified description.
private func mirrorFindProperty(_ label: String, in value: Any, depth: Int = 0) -> Any? {
    guard depth < 6 else { return nil }
    for child in Mirror(reflecting: value).children {
        if child.label == label { return child.value }
        if let found = mirrorFindProperty(label, in: child.value, depth: depth + 1) { return found }
    }
    return nil
}

/// Extract an enum case name from a value: `.idle` → `"idle"`,
/// `.suspended(reason)` → `"suspended"`. Falls back to `String(describing:)` for
/// non-enums or payload-less cases (whose description is already the case name).
private func enumCaseName(_ value: Any) -> String {
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .enum, let label = mirror.children.first?.label {
        return label
    }
    return String(describing: value)
}
