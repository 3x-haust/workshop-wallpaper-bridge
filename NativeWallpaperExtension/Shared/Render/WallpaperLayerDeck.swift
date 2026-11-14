import AVFoundation
import QuartzCore

/// The two permanent render layers of one wallpaper surface.
///
/// WallpaperAgent hosts a surface's remote `CAContext` in a `CALayerHost` and does
/// not reliably notice layers added after that, so BOTH layers are created and
/// attached while the context is still private to this process — before the acquire
/// reply. One layer cannot crossfade: it can only hold its last frame while a new
/// producer takes over (that was the old hard cut). With two, the outgoing renderer
/// keeps playing on its own layer for the whole transition, so a switch is a real
/// dissolve between two live wallpapers.
///
/// Ordering is sublayer insertion order only — `layers[1]` is always on top. No
/// `zPosition`: nothing else in this tree uses it and the host is free to flatten.
/// The crossfade therefore always animates the TOP layer and alternates direction:
///
/// - incoming is the top layer    → top fades 0 → 1 over the live bottom layer
/// - incoming is the bottom layer → top fades 1 → 0, revealing the live bottom layer
///
/// Both are true crossfades, and neither reorders the tree.
///
/// The fade is an explicit `CABasicAnimation`. It has to be: `disableImplicitAnimations`
/// nulls the `opacity` action, and an explicit animation is serialized into the
/// render-server commit so WallpaperAgent's host animates it without this extension
/// ticking anything. Every mutation ends in `CATransaction.flush()` — for a remote
/// context a plain `commit()` never reaches the render server.
///
/// **Queue confinement:** all state here is mutated only on `RenderQueue.serial`. Nothing in
/// this class is safe to touch from another queue.
final class WallpaperLayerDeck: @unchecked Sendable {
    private static let fadeKey = "driftwood.transition.fade"

    private struct InFlightFade {
        let generation: UInt64
        let from: Float
        let to: Float
        let startedAt: TimeInterval
        let duration: TimeInterval
        let onFinish: @Sendable () -> Void

        /// Where the top layer is right now, derived from elapsed time rather than read
        /// back from the render server. `crossfade` documents why `presentation()` is not
        /// trusted here: for a remote `CAContext` it can lag or be absent, which would make
        /// an interrupting fade jump backwards or not animate at all.
        func currentOpacity(at now: TimeInterval) -> Float {
            guard duration > 0 else { return to }
            let linear = min(max((now - startedAt) / duration, 0), 1)
            // Matches `WallpaperTransition.timingFunction` (ease-in-ease-out) closely
            // enough that the handover is not visible.
            let eased = linear < 0.5
                ? 4 * linear * linear * linear
                : 1 - pow(-2 * linear + 2, 3) / 2
            return from + (to - from) * Float(eased)
        }
    }

    /// `[bottom, top]`. Never reordered.
    private let layers: [AVSampleBufferDisplayLayer]

    /// Which layer the committed renderer feeds.
    private var activeIndex = 0

    /// Layer handed to an incoming renderer by `acquireIncomingLayer`, if any.
    private var pendingIndex: Int?

    private var inFlight: InFlightFade?
    private var fadeGeneration: UInt64 = 0

    init(rootLayer: CALayer) {
        let bottom = AVSampleBufferDisplayLayer()
        let top = AVSampleBufferDisplayLayer()
        layers = [bottom, top]

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, layer) in layers.enumerated() {
            disableImplicitAnimations(on: layer)
            layer.name = "driftwood.deck.\(index)"
            layer.videoGravity = .resizeAspectFill
            layer.frame = rootLayer.bounds
            layer.contentsScale = rootLayer.contentsScale
            // Opaque whenever a layer is the visible one: a non-opaque
            // AVSampleBufferDisplayLayer adds a per-frame blend and blinks while the
            // compositor rebuilds it. The top layer is non-opaque while it fades, and
            // stays that way while it is the hidden one (where it costs nothing).
            layer.isOpaque = true
            // Match WallpaperExtensionKit: stop an as-yet-empty layer painting
            // opaque black before its first frame is composited.
            setDisallowsVideoLayerDisplayCompositing(layer, true)
            layer.opacity = index == 0 ? 1 : 0
            rootLayer.addSublayer(layer)
        }
        CATransaction.commit()
        CATransaction.flush()
    }

    /// The layer the committed renderer feeds. This is also the layer a first
    /// acquire's renderer should be built on — a cold start is not a transition.
    var activeLayer: AVSampleBufferDisplayLayer {
        layers[activeIndex]
    }

    /// Hand out the layer an incoming renderer should feed.
    ///
    /// Settles any fade still running first, so `activeIndex` is authoritative and
    /// the returned layer is never the one displaying committed content. Callers
    /// must follow up with exactly one of `crossfade`, `commitInstantly`, or
    /// `abandonIncoming`.
    func acquireIncomingLayer() -> AVSampleBufferDisplayLayer {
        settle()
        let index = 1 - activeIndex
        pendingIndex = index
        return layers[index]
    }

    /// Dissolve from the active layer to the one `acquireIncomingLayer` returned.
    ///
    /// `onFinish` runs on `RenderQueue.serial` once the fade has settled — that is
    /// where the outgoing renderer should be stopped and its buffers released. It is
    /// always called exactly once, including when a newer transition cuts this one
    /// short.
    func crossfade(
        duration: TimeInterval,
        onFinish: @escaping @Sendable () -> Void
    ) {
        guard let incoming = pendingIndex, incoming != activeIndex else {
            // Programmer error: crossfading without having acquired a layer. Running
            // `onFinish` here would stop the renderer feeding the *visible* layer and
            // flush it, blanking the surface, and would leave `activeIndex` pointing
            // away from the committed renderer. Leaking the outgoing renderer is the
            // lesser evil, so log loudly and do nothing.
            pendingIndex = nil
            renderLog(
                "  [deck] crossfade with no incoming layer — ignoring "
                    + "(active=\(activeIndex))"
            )
            return
        }
        pendingIndex = nil
        // `acquireIncomingLayer` already settled any earlier fade; settle again
        // rather than overwrite `inFlight`, which would drop that fade's cleanup and
        // leak its renderer.
        settle()

        let top = layers[1]
        let target: Float = incoming == 1 ? 1 : 0
        // `settle()` just force-landed the steady opacities, so the start value is
        // known. Reading `presentation()` instead would depend on the render server
        // having caught up, and a stale value would make the fade jump.
        let start: Float = activeIndex == 1 ? 1 : 0

        // Put the incoming layer at its steady opacity before the top layer moves.
        // When the incoming layer is the bottom one this is invisible — the still
        // opaque top layer covers it — and it is what makes the fade-out direction
        // a crossfade rather than a fade to nothing.
        if incoming == 0 {
            setOpacityImmediately(1, on: layers[0])
        }

        top.isOpaque = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        top.opacity = target
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = start
        fade.toValue = target
        fade.duration = duration
        fade.timingFunction = WallpaperTransition.timingFunction
        fade.fillMode = .both
        fade.isRemovedOnCompletion = false
        top.add(fade, forKey: Self.fadeKey)
        CATransaction.commit()
        CATransaction.flush()

        activeIndex = incoming
        fadeGeneration &+= 1
        let generation = fadeGeneration
        inFlight = InFlightFade(
            generation: generation,
            from: start,
            to: target,
            startedAt: ProcessInfo.processInfo.systemUptime,
            duration: duration,
            onFinish: onFinish
        )

        // Reconcile on a timer rather than through CAAnimationDelegate: the delegate
        // would fire on whatever thread Core Animation chooses, and a display that
        // sleeps mid-fade can leave the animation without a completion at all. This
        // also force-lands the final opacity if the animation never propagated.
        RenderQueue.serial.asyncAfter(
            deadline: .now() + duration + WallpaperTransition.fadeSettleSlack
        ) { [weak self] in
            self?.settleFade(generation: generation)
        }
    }

    /// Swap to the incoming layer with no animation — a sleeping display has nothing
    /// to dissolve, and animating one only burns power.
    func commitInstantly(onFinish: @escaping @Sendable () -> Void) {
        guard let incoming = pendingIndex else {
            onFinish()
            return
        }
        pendingIndex = nil
        settle()
        activeIndex = incoming
        applySteadyOpacities()
        onFinish()
    }

    /// The incoming renderer never produced a frame, or was superseded. Leave the
    /// active layer alone, re-hide the layer that was handed out, and drop whatever
    /// the abandoned renderer managed to enqueue so its surfaces are released.
    func abandonIncoming() {
        guard let index = pendingIndex else { return }
        pendingIndex = nil
        guard index != activeIndex else { return }
        setOpacityImmediately(0, on: layers[index])
        layers[index].sampleBufferRenderer.flush(removingDisplayedImage: true)
    }

    func updateGeometry(bounds: CGRect, contentsScale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in layers {
            layer.frame = bounds
            layer.contentsScale = contentsScale
        }
        CATransaction.commit()
        CATransaction.flush()
    }

    /// How long an interrupted dissolve gets to finish before its layer is reused. Short
    /// enough to feel immediate, long enough that the eye reads it as the fade completing
    /// rather than jumping.
    private static let interruptCatchUp: TimeInterval = 0.12

    /// Bring any running dissolve to its end *smoothly*, then invoke `completion`.
    ///
    /// A switch arriving mid-dissolve needs the layer the old fade is still using. Taking it
    /// outright means force-landing that fade, which snaps on screen; waiting out the full
    /// duration makes the app feel unresponsive. So the fade is retargeted to finish in a
    /// fraction of the time, from wherever it currently is, and the layer is handed over
    /// once it has.
    func finishFadeQuickly(_ completion: @escaping @Sendable () -> Void) {
        guard let running = inFlight else {
            completion()
            return
        }
        let top = layers[1]
        let target: Float = activeIndex == 1 ? 1 : 0
        let current = running.currentOpacity(
            at: ProcessInfo.processInfo.systemUptime
        )
        // Claim the fade so the original watchdog — still armed for the full duration —
        // cannot land on top of the catch-up and snap the opacity it is animating.
        fadeGeneration &+= 1
        let generation = fadeGeneration
        inFlight = InFlightFade(
            generation: generation,
            from: current,
            to: target,
            startedAt: ProcessInfo.processInfo.systemUptime,
            duration: Self.interruptCatchUp,
            onFinish: running.onFinish
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        top.opacity = target
        let catchUp = CABasicAnimation(keyPath: "opacity")
        catchUp.fromValue = current
        catchUp.toValue = target
        catchUp.duration = Self.interruptCatchUp
        catchUp.timingFunction = CAMediaTimingFunction(name: .easeOut)
        catchUp.fillMode = .both
        catchUp.isRemovedOnCompletion = false
        top.add(catchUp, forKey: Self.fadeKey)
        CATransaction.commit()
        CATransaction.flush()

        RenderQueue.serial.asyncAfter(
            deadline: .now() + Self.interruptCatchUp
        ) { [weak self] in
            // Generation-guarded so this can only land its own catch-up, never a newer
            // fade that started inside the window. Runs the interrupted fade's cleanup,
            // retiring its outgoing renderer.
            self?.settleFade(generation: generation)
            completion()
        }
    }

    /// Force the deck to its terminal state, running any pending fade's cleanup.
    /// Called before handing out a layer, and whenever a surface stops being hosted
    /// so a re-acquire can never inherit a half-faded tree.
    func settle() {
        let fade = inFlight
        inFlight = nil
        applySteadyOpacities()
        fade?.onFinish()
    }

    private func settleFade(generation: UInt64) {
        guard let fade = inFlight, fade.generation == generation else { return }
        inFlight = nil
        applySteadyOpacities()
        fade.onFinish()
    }

    /// Active layer fully visible and opaque, idle layer fully hidden, no animations.
    private func applySteadyOpacities() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, layer) in layers.enumerated() {
            layer.removeAnimation(forKey: Self.fadeKey)
            layer.opacity = index == activeIndex ? 1 : 0
        }
        layers[1].isOpaque = activeIndex == 1
        CATransaction.commit()
        CATransaction.flush()
    }

    private func setOpacityImmediately(_ value: Float, on layer: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: Self.fadeKey)
        layer.opacity = value
        CATransaction.commit()
        CATransaction.flush()
    }
}
