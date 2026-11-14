import AVFoundation
import CoreGraphics
import os
import QuartzCore

/// What a surface should be showing.
struct WallpaperContent: @unchecked Sendable {
    /// Host-facing label, for logs only. Hosts name the same content differently — the
    /// extension's acquire path knows it by macOS choice id, its assignment observer by
    /// content UUID — so this must never be used to decide whether two requests match.
    let id: String
    let kind: WallpaperContentKind
    let resourceURL: URL
    /// Required for `.metalScene`, ignored otherwise. Prepared by the host so package
    /// validation failures surface before the surface is disturbed.
    let metalPackage: MetalScenePackage?
    /// Selects the file for a destination and policy tier. The video renderer consults it
    /// for the first frame and whenever policy, geometry, or deployed metadata changes.
    let variantSelector: (@Sendable (PlaybackPolicy, CGSize) -> URL)?
    /// Seeded into the display layer before the first decoded frame, so a cold start shows
    /// something immediately instead of an empty layer.
    let posterImage: CGImage?

    /// What actually determines whether two requests render the same thing: the file being
    /// played, plus a procedural scene's content hash so an edited shader still counts as a
    /// change. Derived rather than supplied, so two hosts naming the same content
    /// differently cannot disagree — getting that wrong makes a surface rebuild what it is
    /// already showing, which cuts the outgoing crossfade short and flickers.
    var identity: String {
        resourceURL.standardizedFileURL.path + "#" + (metalPackage?.contentHash ?? "")
    }

    init(
        id: String,
        kind: WallpaperContentKind,
        resourceURL: URL,
        metalPackage: MetalScenePackage? = nil,
        variantSelector: (@Sendable (PlaybackPolicy, CGSize) -> URL)? = nil,
        posterImage: CGImage? = nil
    ) {
        self.id = id
        self.kind = kind
        self.resourceURL = resourceURL
        self.metalPackage = metalPackage
        self.variantSelector = variantSelector
        self.posterImage = posterImage
    }
}

struct WallpaperSurfaceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// One wallpaper rendering slot: a layer deck, the renderer currently feeding it, and the
/// state machine that swaps content with a crossfade.
///
/// The extension puts one on the root layer of each remote `CAContext` WallpaperAgent hosts.
/// It knows nothing about how it is hosted — it only needs a root layer — so the app's
/// overlay windows can adopt it as-is, which is the point of it living here.
///
/// A content change never disturbs what is on screen until the replacement has produced a
/// frame: the new renderer is built on the deck's *idle* layer while the outgoing one keeps
/// playing, and only then do the two crossfade. If the replacement fails at any point the
/// existing content simply carries on.
///
/// **Queue confinement:** every method must be called on `RenderQueue.serial`, and all
/// completions are delivered there.
final class WallpaperSurface: @unchecked Sendable {
    /// Poll interval and budget for a request that arrived while a build was in flight.
    /// Must outlast a slow decoder opening a large file, while staying well under the
    /// host's own deadline — the extension's caller gives up at 6s.
    private static let queuedRetryDelay: TimeInterval = 0.1
    private static let queuedRetryLimit = 40

    private struct QueuedRequest {
        let content: WallpaperContent
        let attemptsRemaining: Int
        let completion: @Sendable (Result<Int, Error>) -> Void
    }

    let rootLayer: CALayer
    private let deck: WallpaperLayerDeck

    /// Written only on `RenderQueue.serial`, but read from other queues — snapshot
    /// requests, state publishing, acknowledgment checks — so the reference itself is
    /// lock-protected. Everything else in this class is queue-confined.
    private let rendererLock = OSAllocatedUnfairLock<WallpaperRenderer?>(
        initialState: nil
    )

    var renderer: WallpaperRenderer? {
        rendererLock.withLock { $0 }
    }
    /// Identity of the committed content, for redundant-request detection.
    private var contentIdentity: String?

    /// Monotonic token for asynchronous build work. A newer request supersedes an older one,
    /// whose completion is then ignored — so a late callback can never restore stale content
    /// after the user has already picked something else.
    private var generation: UInt64 = 0
    private var buildInFlight = false
    private var queued: QueuedRequest?
    /// At most one poll timer in flight. Arming one per `setContent`-while-busy would let
    /// N rapid switches burn the retry budget N times faster than the comment on
    /// `queuedRetryLimit` claims.
    private var pollScheduled = false

    // Applied to every renderer this surface builds, so a host sets them once.
    private var playbackRate: Double = 1
    private var quality: RenderQuality = .auto
    private var policy: PlaybackPolicy = .full
    private(set) var destinationPixelSize: CGSize

    init(rootLayer: CALayer) {
        self.rootLayer = rootLayer
        destinationPixelSize = CGSize(
            width: rootLayer.bounds.width * rootLayer.contentsScale,
            height: rootLayer.bounds.height * rootLayer.contentsScale
        )
        deck = WallpaperLayerDeck(rootLayer: rootLayer)
    }

    /// Whether a build is outstanding. Hosts that drive content from more than one place
    /// (the extension both acquires and observes an assignment manifest) use this to avoid
    /// racing the surface.
    var isBuilding: Bool { buildInFlight }

    // MARK: - Content

    /// Show `content`, crossfading from whatever is on screen.
    ///
    /// `completion` receives the committed renderer's id on success. Exactly one build runs
    /// at a time: a request arriving mid-build replaces any older queued one and starts when
    /// the surface is free. Both are delivered on `RenderQueue.serial`.
    func setContent(
        _ content: WallpaperContent,
        completion: @escaping @Sendable (Result<Int, Error>) -> Void
    ) {
        setContent(
            content,
            attemptsRemaining: Self.queuedRetryLimit,
            completion: completion
        )
    }

    private func setContent(
        _ content: WallpaperContent,
        attemptsRemaining: Int,
        completion: @escaping @Sendable (Result<Int, Error>) -> Void
    ) {
        // Already showing exactly this — a duplicate notification, or a request that
        // waited while the build ahead of it delivered the same thing. Rebuilding would
        // restart playback and re-run the dissolve for nothing. Checked before the busy
        // test so a duplicate arriving mid-dissolve is answered rather than parked, but
        // only when no build is in flight: mid-build `contentIdentity` still names the
        // content we are switching away from.
        if !buildInFlight, let renderer, contentIdentity == content.identity {
            renderer.updateVariantSelector(content.variantSelector)
            renderTrace(
                "  [surface] already showing \(content.id) — no rebuild "
                    + "(renderer #\(renderer.debugID))"
            )
            completion(.success(renderer.debugID))
            return
        }

        if buildInFlight {
            // Queue instead; newest wins, so hammering Next collapses to one dissolve per
            // completed transition rather than a burst of half-finished ones.
            guard attemptsRemaining > 0 else {
                completion(.failure(WallpaperSurfaceError(
                    message: "The previous wallpaper renderer build never finished."
                )))
                return
            }
            queued?.completion(.failure(WallpaperSurfaceError(
                message: "A newer wallpaper replaced this request."
            )))
            queued = QueuedRequest(
                content: content,
                attemptsRemaining: attemptsRemaining - 1,
                completion: completion
            )
            renderTrace("  [surface] queued behind an in-flight build: \(content.id)")
            schedulePoll()
            return
        }

        renderTrace(
            "  [surface] building \(content.id): "
                + "\(contentIdentity ?? "nothing") → \(content.identity)"
        )
        generation &+= 1
        buildInFlight = true
        build(content, generation: generation, completion: completion)
    }

    private func build(
        _ content: WallpaperContent,
        generation: UInt64,
        completion: @escaping @Sendable (Result<Int, Error>) -> Void
    ) {
        // Let any dissolve still running reach its end before its layer is reused, so an
        // interrupting switch neither snaps nor waits out the full duration.
        deck.finishFadeQuickly { [weak self] in
            self?.beginBuild(content, generation: generation, completion: completion)
        }
    }

    private func beginBuild(
        _ content: WallpaperContent,
        generation: UInt64,
        completion: @escaping @Sendable (Result<Int, Error>) -> Void
    ) {
        guard generation == self.generation else {
            // Only `stop()` can move the generation between `build` and here, and it
            // already cleared `buildInFlight` and failed anything queued — so this path
            // deliberately does neither.
            completion(.failure(WallpaperSurfaceError(
                message: "A newer wallpaper replaced this request."
            )))
            return
        }
        let outgoing = renderer
        // A first build has nothing to dissolve from, so it renders straight onto the layer
        // that is already visible.
        let target = outgoing == nil
            ? deck.activeLayer
            : deck.acquireIncomingLayer()
        let boxedTarget = SendableBox(target)
        let boxedRoot = SendableBox(rootLayer)
        let buildPolicy = policy
        let buildDestinationPixelSize = destinationPixelSize

        Task { [weak self] in
            let replacement: WallpaperRenderer
            do {
                replacement = try await Self.makeRenderer(
                    content,
                    policy: buildPolicy,
                    destinationPixelSize: buildDestinationPixelSize,
                    rootLayer: boxedRoot.value,
                    displayLayer: boxedTarget.value
                )
            } catch {
                RenderQueue.serial.async { [weak self] in
                    self?.failBuild(
                        generation: generation,
                        error: error,
                        completion: completion
                    )
                }
                return
            }

            RenderQueue.serial.async { [weak self] in
                guard let self else {
                    // The surface went away while this was building. Nothing else holds
                    // this renderer, and a video one would keep its reader and feed loop
                    // running forever inside a sandboxed extension.
                    replacement.stop(preservingDisplayLayer: true)
                    return
                }
                guard generation == self.generation else {
                    // A4: the deck HAS been touched — `acquireIncomingLayer` set its
                    // pending index and the renderer seeded a poster into that layer — so
                    // release it rather than leaving it dangling with a stale frame.
                    replacement.stop(preservingDisplayLayer: true)
                    self.deck.abandonIncoming()
                    completion(.failure(WallpaperSurfaceError(
                        message: "A newer wallpaper replaced this request."
                    )))
                    return
                }
                // Something newer is already waiting. Committing this one would dissolve
                // content the user has moved on from onto the screen, only to dissolve it
                // straight back out.
                if let queued = self.queued,
                   queued.content.identity != content.identity {
                    renderTrace("  [surface] dropping superseded build \(content.id)")
                    replacement.stop(preservingDisplayLayer: true)
                    self.failBuild(
                        generation: generation,
                        error: WallpaperSurfaceError(
                            message: "A newer wallpaper replaced this request."
                        ),
                        completion: completion
                    )
                    return
                }
                replacement.setPlaybackRate(self.playbackRate)
                replacement.setQuality(self.quality)
                self.start(
                    replacement,
                    content: content,
                    outgoing: outgoing,
                    generation: generation,
                    completion: completion
                )
            }
        }
    }

    private func start(
        _ replacement: WallpaperRenderer,
        content: WallpaperContent,
        outgoing: WallpaperRenderer?,
        generation: UInt64,
        completion: @escaping @Sendable (Result<Int, Error>) -> Void
    ) {
        replacement.start(
            onFirstFrameProcessed: { [weak self] firstFrameRendered in
                RenderQueue.serial.async { [weak self] in
                    guard let self else { return }
                    guard generation == self.generation else {
                        replacement.stop(preservingDisplayLayer: true)
                        self.deck.abandonIncoming()
                        completion(.failure(WallpaperSurfaceError(
                            message: "A newer wallpaper replaced this request."
                        )))
                        return
                    }
                    guard firstFrameRendered else {
                        replacement.stop(preservingDisplayLayer: true)
                        self.deck.abandonIncoming()
                        self.failBuild(
                            generation: generation,
                            error: WallpaperSurfaceError(
                                message: "The replacement wallpaper renderer "
                                    + "did not produce a frame."
                            ),
                            completion: completion
                        )
                        return
                    }

                    self.rendererLock.withLock { $0 = replacement }
                    self.contentIdentity = content.identity
                    self.buildInFlight = false
                    replacement.applyPolicy(self.policy)
                    replacement.resize(to: self.destinationPixelSize)

                    if let outgoing {
                        // Retire the outgoing renderer only once the dissolve is over. The deck
                        // guarantees this runs exactly once, even if a newer switch cuts the
                        // fade short.
                        let retire: @Sendable () -> Void = {
                            outgoing.stop(preservingDisplayLayer: true)
                            outgoing.displayLayer.sampleBufferRenderer.flush(
                                removingDisplayedImage: true
                            )
                        }
                        if self.animatesContentChanges() {
                            self.deck.crossfade(
                                duration: WallpaperTransition.fadeDuration,
                                onFinish: retire
                            )
                        } else {
                            self.deck.commitInstantly(onFinish: retire)
                        }
                    }

                    completion(.success(replacement.debugID))
                    self.drainQueued()
                }
            },
            // WallpaperAgent composites a new context only after the acquire reply,
            // which waits for this callback, so a first build can never be seen as
            // rendering (macOS 27). A decoded frame the renderer accepted is enough.
            requiresVisibleRendering: false
        )
    }

    private func failBuild(
        generation: UInt64,
        error: Error,
        completion: @escaping @Sendable (Result<Int, Error>) -> Void
    ) {
        guard generation == self.generation else {
            completion(.failure(error))
            return
        }
        deck.abandonIncoming()
        buildInFlight = false
        completion(.failure(error))
        drainQueued()
    }

    /// Polled rather than woken: a host can start its own build (the extension's acquire
    /// path does) and finish it without ever calling back into here.
    private func schedulePoll() {
        guard !pollScheduled else { return }
        pollScheduled = true
        RenderQueue.serial.asyncAfter(deadline: .now() + Self.queuedRetryDelay) {
            [weak self] in
            self?.pollScheduled = false
            self?.drainQueued()
        }
    }

    private func drainQueued() {
        guard let request = queued else { return }
        guard !buildInFlight else {
            // Still busy. Keep polling — returning here without re-arming the timer would
            // strand the request whenever whatever frees the surface (a build completing,
            // or a dissolve settling) does so through a path that doesn't call back here.
            guard request.attemptsRemaining > 0 else {
                queued = nil
                request.completion(.failure(WallpaperSurfaceError(
                    message: "The wallpaper surface never became free."
                )))
                return
            }
            queued = QueuedRequest(
                content: request.content,
                attemptsRemaining: request.attemptsRemaining - 1,
                completion: request.completion
            )
            schedulePoll()
            return
        }
        queued = nil
        setContent(
            request.content,
            attemptsRemaining: request.attemptsRemaining,
            completion: request.completion
        )
    }

    /// Whether a content change should dissolve, asked fresh at each switch.
    ///
    /// A closure rather than a stored flag on purpose: a flag has to be cleared *and*
    /// restored by the host, so a missed restore disables crossfades permanently and a
    /// surface created while the condition holds starts out wrong. Hosts answer from live
    /// state instead — the extension reports whether the display is asleep.
    ///
    /// Deliberately NOT tied to `PlaybackPolicy.paused`: paused covers battery, occlusion
    /// and thermal throttling, where the wallpaper is still on screen showing its last
    /// frame. A dissolve there is an opacity animation between two static layers, which the
    /// render server runs for free, so suppressing it would turn every switch on an
    /// unplugged laptop into a hard cut.
    var animatesContentChanges: @Sendable () -> Bool = { true }

    private static func makeRenderer(
        _ content: WallpaperContent,
        policy: PlaybackPolicy,
        destinationPixelSize: CGSize,
        rootLayer: CALayer,
        displayLayer: AVSampleBufferDisplayLayer
    ) async throws -> WallpaperRenderer {
        switch content.kind {
        case .video:
            let initialURL = content.variantSelector?(
                policy,
                destinationPixelSize
            ) ?? content.resourceURL
            let renderer = try await VideoRenderer.create(
                rootLayer: rootLayer,
                videoURL: initialURL,
                stillImage: content.posterImage,
                initialPolicy: policy,
                reusingDisplayLayer: displayLayer
            )
            renderer.variantSelector = content.variantSelector
            return .video(renderer)
        case .metalScene:
            guard let package = content.metalPackage else {
                throw WallpaperSurfaceError(
                    message: "Metal scene package was not prepared."
                )
            }
            return .metalScene(
                try MetalSceneRenderer.create(
                    rootLayer: rootLayer,
                    package: package,
                    reusingDisplayLayer: displayLayer
                )
            )
        }
    }

    // MARK: - Live controls

    func applyPolicy(_ policy: PlaybackPolicy, animated: Bool = false) {
        self.policy = policy
        renderer?.applyPolicy(policy, animated: animated)
    }

    func setPlaybackRate(_ rate: Double) {
        playbackRate = rate
        renderer?.setPlaybackRate(rate)
    }

    func setQuality(_ quality: RenderQuality) {
        self.quality = quality
        renderer?.setQuality(quality)
    }

    /// Follow the host's geometry. The extension's root layer is resized by WallpaperAgent's
    /// reported destination; the app's follows its window. Either way the deck's layers were
    /// added by hand and need their frames kept in step.
    func updateGeometry(bounds: CGRect, contentsScale: CGFloat) {
        destinationPixelSize = CGSize(
            width: bounds.width * contentsScale,
            height: bounds.height * contentsScale
        )
        deck.updateGeometry(bounds: bounds, contentsScale: contentsScale)
        renderer?.resize(to: destinationPixelSize)
    }

    func resize(to pixelSize: CGSize) {
        destinationPixelSize = pixelSize
        renderer?.resize(to: pixelSize)
    }

    func snapshot() -> CGImage? {
        renderer?.snapshot()
    }

    /// Replace the file behind the *same* content without a transition — used when a host
    /// swaps the media on disk for a choice that is already showing.
    func refreshVideoSource(_ url: URL) {
        guard case .video(let videoRenderer)? = renderer else { return }
        videoRenderer.refreshSource(fallback: url)
    }

    /// Force any in-flight fade to its end state, running its cleanup. Call when the surface
    /// stops being visible so a later reveal never inherits a half-faded tree.
    func settle() {
        deck.settle()
    }

    /// Tear the surface down. The layers go with the root layer.
    func stop() {
        // Bumping the generation invalidates any build still in flight, so when it lands
        // it stops its renderer instead of installing it on a surface that is gone. Without
        // this the surface would also stay wedged at `buildInFlight == true` forever.
        generation &+= 1
        buildInFlight = false
        deck.settle()
        renderer?.stop(preservingDisplayLayer: true)
        rendererLock.withLock { $0 = nil }
        contentIdentity = nil
        queued?.completion(.failure(WallpaperSurfaceError(
            message: "The wallpaper surface went away."
        )))
        queued = nil
    }
}
