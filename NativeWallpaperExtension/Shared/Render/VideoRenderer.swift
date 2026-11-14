import AVFoundation
import CoreMedia
import ObjectiveC
import os

/// Plays a looping video into an `AVSampleBufferDisplayLayer` owned by a surface's deck.
///
/// **Queue confinement:** every mutable field belongs to `queue`. Public entry points are
/// called from the render queue and hop; nothing mutates state on the caller's thread. That
/// is what makes the `@unchecked Sendable` here honest — the decode loop, the ramp and
/// deep-pause timers, and policy changes all mutate the same fields (`isPaused`, `asset`,
/// the readers, the timers), so a policy change applied on the caller's queue would race
/// the feed loop.
///
/// The exceptions are deliberate and safe: `displayLayer` and `timebase` are immutable
/// references whose own APIs are thread-safe, `debugID` is a `let`, and `playbackRate` has
/// its own lock. Selector and geometry updates hop to `queue` before changing playback.
final class VideoRenderer: @unchecked Sendable {
    /// Process-wide instance counter so log lines can be attributed to a specific
    /// renderer object (to catch stale/duplicate renderers from acquire races).
    private static let idCounter = OSAllocatedUnfairLock(initialState: 0)
    let debugID: Int = VideoRenderer.idCounter.withLock { $0 += 1; return $0 }

    let displayLayer: AVSampleBufferDisplayLayer
    let timebase: CMTimebase
    private let renderer: AVSampleBufferVideoRenderer
    private var asset: AVURLAsset
    private var videoTrack: AVAssetTrack
    /// Last asset that successfully produced a frame. A failed derived-file switch falls
    /// back here instead of leaving the renderer frozen after its old reader was canceled.
    private var lastPlayableAsset: AVURLAsset
    private var lastPlayableTrack: AVAssetTrack
    private let queue = DispatchQueue(label: "video-renderer", qos: .userInitiated)
    private var isRunning = true
    private(set) var isPaused = false
    private var currentPolicy: PlaybackPolicy = .full
    private var destinationPixelSize: CGSize
    private let playbackRateLock = OSAllocatedUnfairLock(initialState: 1.0)
    private var rampTimer: (any DispatchSourceTimer)?
    private var deepPauseTimer: (any DispatchSourceTimer)?

    private var currentReader: AVAssetReader?
    private var currentOutput: AVAssetReaderTrackOutput?
    private var nextReader: AVAssetReader?
    private var nextOutput: AVAssetReaderTrackOutput?

    /// A renderer `flush` (decoder reset) is the one async hop in the pipeline, and
    /// TWO overlapping flushes corrupt the renderer (rapid-switch breakage). These two
    /// flags — touched ONLY on `queue` — serialize it: at most one flush is ever in
    /// flight, and a switch arriving during a flush is coalesced, so when the flush
    /// completes we restart once to whatever the latest selected asset is.
    private var flushInFlight = false
    private var restartPending = false
    /// A rendition change keeps the current loop position. These values belong to the
    /// latest queued switch and are overwritten with it, preserving last-requested-wins.
    private var restartPositionFraction: Double?
    private var restartTimelineTime: CMTime?
    private var restartKeepsDeepPause = false
    /// Diagnostic: number of remaining feed-loop ticks to log after a restart.
    private var feedLogBudget = 0

    // Gapless looping state.
    // ptsOffset accumulates across loops so both DTS and PTS are monotonically increasing.
    // lastEnqueuedEnd tracks the highest sample end time (max, not last — handles B-frames).
    private var ptsOffset: CMTime = .zero
    private var lastEnqueuedEnd: CMTime = .zero
    /// On the first sample from a new loop, align its source PTS to this running timeline.
    /// This handles assets whose first timestamp is nonzero or negative.
    private var pendingLoopStart: CMTime?

    /// Selects the rendition for the current policy. Written before `start`, then read only
    /// on `queue`; the closure itself resolves the extension library under its own lock.
    var variantSelector: (@Sendable (PlaybackPolicy, CGSize) -> URL)?

    /// Build a renderer that feeds one of a surface's permanent deck layers. The
    /// layer is owned by the surface's `WallpaperLayerDeck` and outlives every
    /// renderer, so this only (re)configures it — it never attaches or detaches it.
    static func create(
        rootLayer: CALayer,
        videoURL: URL,
        stillImage: CGImage? = nil,
        initialPolicy: PlaybackPolicy = .full,
        reusingDisplayLayer displayLayer: AVSampleBufferDisplayLayer
    ) async throws -> VideoRenderer {
        let asset = AVURLAsset(url: videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: "No video track found in \(videoURL.lastPathComponent)",
            ])
        }

        displayLayer.videoGravity = .resizeAspectFill
        displayLayer.frame = rootLayer.bounds
        displayLayer.contentsScale = rootLayer.contentsScale

        return VideoRenderer(
            displayLayer: displayLayer,
            asset: asset,
            videoTrack: track,
            stillImage: stillImage,
            initialPolicy: initialPolicy,
        )
    }

    private init(
        displayLayer: AVSampleBufferDisplayLayer,
        asset: AVURLAsset,
        videoTrack: AVAssetTrack,
        stillImage: CGImage?,
        initialPolicy: PlaybackPolicy,
    ) {
        self.displayLayer = displayLayer
        self.renderer = displayLayer.sampleBufferRenderer
        self.asset = asset
        self.videoTrack = videoTrack
        self.lastPlayableAsset = asset
        self.lastPlayableTrack = videoTrack
        self.currentPolicy = initialPolicy
        self.isPaused = initialPolicy == .paused
        self.destinationPixelSize = CGSize(
            width: displayLayer.bounds.width * displayLayer.contentsScale,
            height: displayLayer.bounds.height * displayLayer.contentsScale
        )

        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &tb,
        )
        self.timebase = tb!
        CMTimebaseSetTime(timebase, time: .zero)
        // Rate stays 0 until start() — prevents the timebase from advancing
        // during the async gap between init and start, which would cause
        // the first batch of frames to be considered "late" and dropped.
        CMTimebaseSetRate(timebase, rate: 0.0)
        displayLayer.controlTimebase = timebase

        // Seed the still in an action-free transaction, so Core Animation doesn't play
        // an implicit "onOrderIn" animation (the video appearing to zoom/fade in). The
        // still is an IOSurface-backed sample buffer at PTS 0 — unlike CALayer.contents
        // (black when hosted cross-process) it composites into WallpaperAgent's
        // CALayerHost, so the desktop shows the still immediately; the video's first
        // real frame (also PTS 0) plays over it once rate=1.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        renderTrace("  [Renderer #\(debugID)] CREATED for \(asset.url.lastPathComponent), displayLayer=\(ObjectIdentifier(displayLayer))")
        if let stillImage, let stillBuffer = makeStillSampleBuffer(from: stillImage) {
            // Tag DisplayImmediately so the still is shown the instant it's enqueued,
            // rather than waiting on the control timebase (which is frozen at rate 0 here).
            // Without this the frame can sit undisplayed → the layer reads empty → black.
            Self.setDisplayImmediately(stillBuffer)
            renderer.enqueue(stillBuffer)
            renderTrace("  [Renderer #\(debugID)] Seeded still into display layer (\(stillImage.width)x\(stillImage.height))")
        } else {
            renderTrace("  [Renderer #\(debugID)] No still to seed (stillImage present: \(stillImage != nil))")
        }
        CATransaction.commit()
        // flush() (not just commit()) is what pushes the layer tree to the render
        // server for a REMOTE context — without it the still never reaches the
        // WindowServer and the desktop stays black until a later flush.
        CATransaction.flush()
    }

    /// Start playback: decode and enqueue the first frame, then begin the feed loop.
    /// Runs on the renderer's serial queue rather than the caller's thread — the
    /// first-frame `copyNextSampleBuffer` is a blocking decode, and the caller is a
    /// Swift-concurrency (cooperative) task; blocking a cooperative thread violates
    /// forward progress and starves the extension's tiny executor.
    ///
    /// `onFirstFrameProcessed`, if provided, is invoked after the first sample has
    /// been enqueued and the display layer has had a bounded opportunity to enter
    /// its rendering state. Its Boolean is false when no sample could be decoded or
    /// the layer did not become observable as rendering before the deadline.
    /// `requiresVisibleRendering` demands the display layer actually be composited before
    /// reporting success — right for a first build, where the caller must not hand
    /// WallpaperAgent an empty surface. A replacement built on a deck's hidden layer must
    /// pass false: that layer is transparent until the crossfade reveals it, so it is never
    /// composited and the check could only ever time out.
    func start(
        onFirstFrameProcessed: (@Sendable (Bool) -> Void)? = nil,
        requiresVisibleRendering: Bool = true
    ) {
        renderTrace("  [start #\(debugID)] asset=\(asset.url.lastPathComponent)")
        queue.async { [weak self] in
            guard let self else { onFirstFrameProcessed?(false); return }
            guard isRunning else {
                renderTrace("  [start #\(debugID)] aborted — already stopped")
                onFirstFrameProcessed?(false)
                return
            }
            guard let reader = try? AVAssetReader(asset: asset) else {
                onFirstFrameProcessed?(false)
                return
            }
            let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            reader.add(output)
            reader.startReading()

            // Reset timebase BEFORE first enqueue so the frame isn't seen as late.
            CMTimebaseSetTime(timebase, time: .zero)

            // Enqueue the first frame and flush the layer-tree update inside an
            // action-free transaction. Normalize its timestamps onto the renderer's
            // zero-based loop timeline before observing the display layer.
            let sourceFirstSample = output.copyNextSampleBuffer()
            let firstSample: CMSampleBuffer?
            if let sourceFirstSample {
                let firstPTS = CMSampleBufferGetPresentationTimeStamp(sourceFirstSample)
                ptsOffset = firstPTS.isNumeric
                    ? CMTimeMultiplyByFloat64(firstPTS, multiplier: -1)
                    : .zero
                firstSample = offsetTimingForLoop(sourceFirstSample)
            } else {
                firstSample = nil
            }
            if let firstSample {
                // This is also the handoff point for Metal → video. The display
                // layer is permanent, so replace its last generated frame as soon
                // as the decoder produces a valid video frame.
                Self.setDisplayImmediately(firstSample)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                renderer.enqueue(firstSample)
                CATransaction.commit()
                CATransaction.flush()
            }

            currentReader = reader
            currentOutput = output
            pendingLoopStart = nil
            if let firstSample {
                let pts = CMSampleBufferGetPresentationTimeStamp(firstSample)
                let duration = CMSampleBufferGetDuration(firstSample)
                lastEnqueuedEnd = pts.isNumeric
                    ? CMTimeAdd(
                        pts,
                        duration.isNumeric && duration > .zero
                            ? duration
                            : CMTime(value: 1, timescale: 60)
                    )
                    : .zero
                lastPlayableAsset = asset
                lastPlayableTrack = videoTrack
            } else {
                lastEnqueuedEnd = .zero
            }

            // Begin advancing the timebase — playback starts.
            CMTimebaseSetRate(
                timebase,
                rate: isPaused ? 0 : targetPlaybackRate
            )

            let firstFrameRendered: Bool
            if requiresVisibleRendering {
                let renderDeadline = ProcessInfo.processInfo.systemUptime + 0.2
                while firstSample != nil,
                      renderer.status == .unknown,
                      ProcessInfo.processInfo.systemUptime < renderDeadline {
                    Thread.sleep(forTimeInterval: 0.005)
                }
                firstFrameRendered =
                    firstSample != nil && renderer.status == .rendering
            } else {
                // Building onto a hidden layer: `.rendering` means "composited", which a
                // fully transparent layer never is, so waiting for it would always time
                // out. A decoded sample that the renderer hasn't rejected is the strongest
                // signal available — and it is enough, because the outgoing content stays
                // on screen until the crossfade actually starts.
                firstFrameRendered =
                    firstSample != nil && renderer.status != .failed
            }
            onFirstFrameProcessed?(firstFrameRendered)

            if isPaused {
                scheduleDeepPause()
            }
            prepareNextReader()
            feedFromCurrentReader()
        }
    }

    /// Switch to a different video IN PLACE, reusing this renderer's existing
    /// `displayLayer`. The layer is already attached to the display's CAContext and
    /// hosted by WallpaperAgent, so feeding it frames from a new asset updates the
    /// desktop — whereas building a fresh renderer (new `AVSampleBufferDisplayLayer`)
    /// added to an already-hosted context does NOT composite (the switch-between-
    /// videos bug). So we keep the one hosted layer and restart it on the new asset.
    ///
    /// Fully serialized on `queue`, no `Task`: the track load blocks the queue thread
    /// (a real thread we own, which already blocks for decodes). Because every switch
    /// runs to completion in FIFO order on one thread, rapid switching is naturally
    /// last-*requested*-wins with no cancellation bookkeeping — the only async hop is
    /// the renderer's `flush`, which is serialized and coalesces rapid switches.
    func switchVideo(
        to url: URL,
        forceReload: Bool = false,
        preservingPosition: Bool = false
    ) {
        renderTrace("  [switchVideo #\(debugID)] REQUEST target=\(url.lastPathComponent)")
        queue.async { [weak self] in
            self?.switchVideoOnQueue(
                to: url,
                forceReload: forceReload,
                preservingPosition: preservingPosition
            )
        }
    }

    /// Must run on `queue`.
    private func switchVideoOnQueue(
        to url: URL,
        forceReload: Bool,
        preservingPosition: Bool
    ) {
        guard isRunning else { return }
        if asset.url == url, !forceReload {
            renderTrace("  [switchVideo #\(debugID)] DEDUP: already on \(url.lastPathComponent)")
            return
        }

        let timeline = CMTimebaseGetTime(timebase)
        let positionFraction = preservingPosition
            ? Self.loopPositionFraction(
                timeline: timeline,
                track: lastPlayableTrack
            )
            : nil

        let newAsset = AVURLAsset(url: url)
        guard let track = Self.loadFirstVideoTrackBlocking(newAsset) else {
            renderTrace("  [switchVideo #\(debugID)] no video track in \(url.lastPathComponent)")
            return
        }
        asset = newAsset
        videoTrack = track
        restartPositionFraction = positionFraction
        restartTimelineTime = positionFraction == nil ? nil : timeline
        restartKeepsDeepPause = isPaused && currentReader == nil
        renderTrace(
            "  [switchVideo #\(debugID)] restarting "
                + (positionFraction == nil ? "from 0" : "at current position")
                + " → \(url.lastPathComponent)"
        )
        restartWithCurrentAsset()
    }

    /// Tag a sample buffer so the renderer displays it immediately, replacing all
    /// previously enqueued/displayed images regardless of timestamps (per
    /// AVQueuedSampleBufferRendering docs). Used for the first frame of a switched
    /// video so the swap is instant and doesn't wait on the control timebase.
    private static func setDisplayImmediately(_ sample: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) else { return }
        let count = CFArrayGetCount(attachments)
        for i in 0 ..< count {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, i), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque(),
            )
        }
    }

    /// Load the first video track synchronously. Call ONLY from the renderer's serial
    /// `queue` — it blocks that (real, owned) thread on a semaphore while AVFoundation
    /// loads the track on its own internal queue, so there's no cooperative-executor
    /// starvation and no out-of-order Task completion. Local files load in a few ms.
    private static func loadFirstVideoTrackBlocking(_ asset: AVURLAsset) -> AVAssetTrack? {
        renderTrace("  [load] blocking-load START \(asset.url.lastPathComponent) (queue will block until AVF replies)")
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: AVAssetTrack?
        asset.loadTracks(withMediaType: .video) { tracks, _ in
            result = tracks?.first
            sem.signal()
        }
        sem.wait()
        renderTrace("  [load] blocking-load DONE \(asset.url.lastPathComponent) track=\(result != nil ? "ok" : "nil")")
        return result
    }

    /// Like track loading, this waits only on the renderer's private serial thread.
    private static func loadTimeRangeBlocking(_ track: AVAssetTrack) -> CMTimeRange? {
        let semaphore = DispatchSemaphore(value: 0)
        let result = OSAllocatedUnfairLock<CMTimeRange?>(initialState: nil)
        let trackBox = SendableBox(track)
        Task.detached {
            let timeRange = try? await trackBox.value.load(.timeRange)
            result.withLock { $0 = timeRange }
            semaphore.signal()
        }
        semaphore.wait()
        return result.withLock { $0 }
    }

    private static func loopPositionFraction(
        timeline: CMTime,
        track: AVAssetTrack
    ) -> Double? {
        guard timeline.isNumeric,
              let timeRange = loadTimeRangeBlocking(track),
              timeRange.duration.isNumeric,
              timeRange.duration.seconds > 0 else {
            return nil
        }
        let duration = timeRange.duration.seconds
        var loopPosition = timeline.seconds.truncatingRemainder(dividingBy: duration)
        if loopPosition < 0 { loopPosition += duration }
        return max(0, min(loopPosition / duration, 1))
    }

    private static func sourceTime(
        for positionFraction: Double,
        track: AVAssetTrack
    ) -> CMTime? {
        guard let timeRange = loadTimeRangeBlocking(track),
              timeRange.start.isNumeric,
              timeRange.duration.isNumeric,
              timeRange.duration.seconds > 0 else {
            return nil
        }
        return CMTimeAdd(
            timeRange.start,
            CMTimeMultiplyByFloat64(
                timeRange.duration,
                multiplier: positionFraction
            )
        )
    }

    /// Stop playback. Dispatches synchronously to the renderer queue to ensure
    /// no callback is mid-flight before canceling the reader.
    func stop(preservingDisplayLayer: Bool = false) {
        queue.sync {
            renderLog(
                "  [stop #\(debugID)] stopping renderer for "
                    + "\(asset.url.lastPathComponent)"
            )
            isRunning = false
            renderer.stopRequestingMediaData()
            currentReader?.cancelReading()
            nextReader?.cancelReading()
            restartPending = false
            cancelRamp()
            cancelDeepPauseTimer()
        }
        // The surface's layer deck owns the display layer, so callers pass
        // `preservingDisplayLayer: true` for anything but a dying surface.
        if !preservingDisplayLayer {
            displayLayer.removeFromSuperlayer()
        }
    }

    /// Must run on `queue`.
    private func pause() {
        guard !isPaused else { return }
        renderTrace("  [pause #\(debugID)]")
        isPaused = true
        CMTimebaseSetRate(timebase, rate: 0.0)
        // No still is generated on pause: the display layer already holds the last
        // frame. Generating one spawned an AVAssetImageGenerator (its own video
        // decoder) on every pause, and when the desktop thrashes idle/default those
        // pile up and starve the playback reader of the appex's limited decoder
        // resources.
        scheduleDeepPause()
    }

    func updateVariantSelector(
        _ selector: (@Sendable (PlaybackPolicy, CGSize) -> URL)?
    ) {
        queue.async { [weak self] in
            guard let self, isRunning else { return }
            variantSelector = selector
            selectCurrentVariantOnQueue()
        }
    }

    func updateDestinationPixelSize(_ pixelSize: CGSize) {
        let normalized = CGSize(
            width: max(1, pixelSize.width),
            height: max(1, pixelSize.height)
        )
        queue.async { [weak self] in
            guard let self, isRunning,
                  destinationPixelSize != normalized else { return }
            destinationPixelSize = normalized
            selectCurrentVariantOnQueue()
        }
    }

    /// Must run on `queue`.
    private func selectCurrentVariantOnQueue() {
        guard currentPolicy != .paused,
              let selectedURL = variantSelector?(
                  currentPolicy,
                  destinationPixelSize
              ),
              selectedURL != asset.url else { return }
        switchVideoOnQueue(
            to: selectedURL,
            forceReload: false,
            preservingPosition: true
        )
    }

    func refreshSource(fallback: URL) {
        queue.async { [weak self] in
            guard let self, isRunning else { return }
            let selectedURL = variantSelector?(
                currentPolicy,
                destinationPixelSize
            ) ?? fallback
            switchVideoOnQueue(
                to: selectedURL,
                forceReload: true,
                preservingPosition: true
            )
        }
    }

    func setPlaybackRate(_ rate: Double) {
        let clamped = min(max(rate, 0.25), 4)
        playbackRateLock.withLock { $0 = clamped }
        queue.async { [weak self] in
            guard let self, isRunning, !isPaused else { return }
            CMTimebaseSetRate(timebase, rate: targetPlaybackRate)
        }
    }

    private var targetPlaybackRate: Double {
        playbackRateLock.withLock { $0 }
    }

    /// Must run on `queue`.
    private func resume() {
        guard isPaused else { return }
        renderTrace("  [resume #\(debugID)] currentReader=\(currentReader == nil ? "nil(deep)" : "live") asset=\(asset.url.lastPathComponent) rate→\(targetPlaybackRate)")
        isPaused = false
        cancelDeepPauseTimer()
        if currentReader == nil {
            // Woke from deep pause. Re-enter through the serialized restart path so the
            // source seek uses the loop-local time while PTS stays on the running timeline.
            guard isRunning else { return }
            let timeline = CMTimebaseGetTime(timebase)
            restartPositionFraction = Self.loopPositionFraction(
                timeline: timeline,
                track: lastPlayableTrack
            )
            restartTimelineTime = timeline
            restartKeepsDeepPause = false
            restartWithCurrentAsset()
            return
        }
        CMTimebaseSetRate(timebase, rate: targetPlaybackRate)
    }

    /// Policy changes arrive from the render queue, but every field they touch —
    /// `isPaused`, the ramp and deep-pause timers, the current asset — belongs to this
    /// renderer's own queue, alongside the decode loop that also mutates them. Hop once
    /// here so the whole family stays single-threaded.
    func applyPolicy(_ policy: PlaybackPolicy, animated: Bool = false) {
        queue.async { [weak self] in
            self?.applyPolicyOnQueue(policy, animated: animated)
        }
    }

    /// Must run on `queue`.
    private func applyPolicyOnQueue(_ policy: PlaybackPolicy, animated: Bool) {
        guard isRunning else { return }
        if policy == currentPolicy {
            if policy != .paused { selectCurrentVariantOnQueue() }
            return
        }
        let oldPolicy = currentPolicy
        currentPolicy = policy
        renderLog("  [applyPolicy #\(debugID)] \(oldPolicy) → \(policy) animated=\(animated) asset=\(asset.url.lastPathComponent)")
        cancelRamp()

        switch policy {
        case .paused:
            if animated {
                rampDown()
            } else {
                pause()
            }
        case .full, .reduced, .minimal:
            if animated, oldPolicy == .paused, isPaused {
                rampUp()
            } else if isPaused {
                resume()
            } else {
                // A ramp-down can be canceled before it sets `isPaused`. Restore the full
                // configured rate explicitly instead of leaving the timebase throttled.
                CMTimebaseSetRate(timebase, rate: targetPlaybackRate)
            }
            selectCurrentVariantOnQueue()
        }
    }

    // MARK: - Ramp (Apple-like lock screen transition)

    /// Ramp duration in seconds and step interval aligned to display refresh rate.
    /// At 120Hz (8.3ms) this gives 240 steps; at 60Hz it's 120 steps.
    private static let rampDuration: TimeInterval = 2.0
    private static let rampStepInterval: TimeInterval = 1.0 / 120.0

    /// Ease-in-out cubic: smooth acceleration then deceleration.
    /// t in [0, 1] → output in [0, 1].
    private static func easeInOut(_ t: Double) -> Double {
        t < 0.5
            ? 4.0 * t * t * t
            : 1.0 - pow(-2.0 * t + 2.0, 3) / 2.0
    }

    /// Gradually reduce timebase rate to zero, then freeze.
    /// Uses a smooth ease-in curve so the deceleration looks natural. Must run on `queue`.
    private func rampDown() {
        guard !isPaused else { return }
        let totalSteps = Int(Self.rampDuration / Self.rampStepInterval)
        var step = 0

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.rampStepInterval, repeating: Self.rampStepInterval)
        timer.setEventHandler { [weak self] in
            guard let self, isRunning else {
                timer.cancel()
                return
            }
            step += 1
            let progress = Double(step) / Double(totalSteps)
            // Ease-in: slow start, fast finish → rate drops slowly at first
            let eased = Self.easeInOut(progress)
            let rate = max(targetPlaybackRate * (1.0 - eased), 0.0)
            CMTimebaseSetRate(timebase, rate: rate)

            if step >= totalSteps {
                timer.cancel()
                rampTimer = nil
                isPaused = true
                scheduleDeepPause()
            }
        }
        rampTimer = timer
        timer.resume()
    }

    /// Gradually increase timebase rate from zero to the configured rate.
    /// Uses a smooth ease-out curve so acceleration looks natural. Must run on `queue`.
    private func rampUp() {
        guard isPaused else { return }
        isPaused = false
        cancelDeepPauseTimer()

        if currentReader == nil {
            // Deep-paused: no frames exist to ramp into. The serialized restart restores
            // the loop position and resumes at the configured rate after its first frame.
            guard isRunning else { return }
            let timeline = CMTimebaseGetTime(timebase)
            restartPositionFraction = Self.loopPositionFraction(
                timeline: timeline,
                track: lastPlayableTrack
            )
            restartTimelineTime = timeline
            restartKeepsDeepPause = false
            restartWithCurrentAsset()
            return
        }

        let totalSteps = Int(Self.rampDuration / Self.rampStepInterval)
        var step = 0

        // Kick off immediately so there's no dead frame at rate 0
        CMTimebaseSetRate(timebase, rate: 0.01)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.rampStepInterval, repeating: Self.rampStepInterval)
        timer.setEventHandler { [weak self] in
            guard let self, isRunning else {
                timer.cancel()
                return
            }
            step += 1
            let progress = Double(step) / Double(totalSteps)
            let eased = Self.easeInOut(progress)
            let rate = min(eased, 1.0) * targetPlaybackRate
            CMTimebaseSetRate(timebase, rate: rate)

            if step >= totalSteps {
                timer.cancel()
                rampTimer = nil
            }
        }
        rampTimer = timer
        timer.resume()
    }

    /// Must run on `queue`.
    private func cancelRamp() {
        rampTimer?.cancel()
        rampTimer = nil
    }

    // MARK: - Deep Pause

    //
    // After a sustained pause (lock screen overnight, brightness at zero, etc.)
    // the asset reader still holds decoded buffers and the underlying video
    // decoder. Tearing them down frees memory and lets the system fully idle.
    // Resume enters the same serialized restart path used by rendition switches.

    private static let deepPauseDelay: TimeInterval = 30

    /// Must run on `queue`.
    private func scheduleDeepPause() {
        cancelDeepPauseTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.deepPauseDelay)
        timer.setEventHandler { [weak self] in
            self?.enterDeepPause()
        }
        deepPauseTimer = timer
        timer.resume()
    }

    /// Must run on `queue`.
    private func cancelDeepPauseTimer() {
        deepPauseTimer?.cancel()
        deepPauseTimer = nil
    }

    /// Runs on the renderer queue when the deep-pause timer fires.
    private func enterDeepPause() {
        deepPauseTimer = nil
        guard isRunning, isPaused, currentReader != nil else { return }
        renderer.stopRequestingMediaData()
        currentReader?.cancelReading()
        nextReader?.cancelReading()
        currentReader = nil
        currentOutput = nil
        nextReader = nil
        nextOutput = nil
        renderLog("  [Renderer] Deep-paused — freed asset readers")
    }

    /// Restart playback on the already-set `asset`/`videoTrack`. Content changes start at
    /// zero; rendition changes seek to the same fractional loop position and keep the
    /// running timebase timeline. The async decoder flush remains serialized, and the old
    /// displayed image stays in place until the first frame from the new file lands.
    private func restartWithCurrentAsset() {
        // Serialize the decoder reset: if a flush is already in flight, just mark that
        // a restart is wanted. When that flush completes it will restart to whatever
        // `asset` is by then (the latest pick) — so rapid switching coalesces to one
        // reset per settle, never two overlapping flushes.
        renderTrace("  [restart #\(debugID)] ENTER flushInFlight=\(flushInFlight) restartPending=\(restartPending) asset=\(asset.url.lastPathComponent)")
        if flushInFlight {
            restartPending = true
            renderTrace("  [restart #\(debugID)] flush in flight → coalescing to latest (\(asset.url.lastPathComponent))")
            return
        }
        flushInFlight = true
        // Freeze the clock up front so it can't advance past PTS 0 during the async
        // flush — otherwise the first frames arrive "late" and get dropped.
        CMTimebaseSetRate(timebase, rate: 0.0)
        renderer.stopRequestingMediaData()
        currentReader?.cancelReading()
        nextReader?.cancelReading()
        nextReader = nil
        nextOutput = nil

        renderTrace("  [restart #\(debugID)] flushing decoder for \(asset.url.lastPathComponent)")
        // Keep the currently displayed frame (no blank) — the first new frame below is
        // tagged DisplayImmediately, which replaces it the instant it decodes.
        renderer.flush(removingDisplayedImage: false) { [weak self] in
            guard let self else { renderLog("  [restart] FLUSH-CB but self gone (flushInFlight leaks!)"); return }
            renderTrace("  [restart #\(debugID)] FLUSH-CB fired (rendererStatus=\(renderer.status.rawValue)) → hop to queue")
            queue.async { [weak self] in
                guard let self else { return }
                flushInFlight = false
                renderTrace("  [restart #\(debugID)] FLUSH-CB on queue: flushInFlight→false, restartPending=\(restartPending), asset=\(asset.url.lastPathComponent), isRunning=\(isRunning)")
                // Switches arrived during the flush → do exactly one more restart to
                // the newest asset, instead of feeding this (now stale) one.
                if restartPending {
                    restartPending = false
                    renderTrace("  [restart #\(debugID)] coalesced → restarting to \(asset.url.lastPathComponent)")
                    restartWithCurrentAsset()
                    return
                }
                guard isRunning else { return }
                let positionFraction = restartPositionFraction
                let preservedTimeline = restartTimelineTime
                let keepDeepPaused = restartKeepsDeepPause
                restartPositionFraction = nil
                restartTimelineTime = nil
                restartKeepsDeepPause = false

                guard let reader = try? AVAssetReader(asset: asset) else {
                    recoverFailedRestart(
                        positionFraction: positionFraction,
                        preservedTimeline: preservedTimeline,
                        keepDeepPaused: keepDeepPaused,
                        reason: "could not create AVAssetReader"
                    )
                    return
                }
                if let positionFraction,
                   let sourceTime = Self.sourceTime(
                       for: positionFraction,
                       track: videoTrack
                   ) {
                    reader.timeRange = CMTimeRange(
                        start: sourceTime,
                        duration: .positiveInfinity
                    )
                }

                let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
                output.alwaysCopiesSampleData = false
                guard reader.canAdd(output) else {
                    recoverFailedRestart(
                        positionFraction: positionFraction,
                        preservedTimeline: preservedTimeline,
                        keepDeepPaused: keepDeepPaused,
                        reason: "reader rejected video output"
                    )
                    return
                }
                reader.add(output)
                guard reader.startReading(),
                      let first = output.copyNextSampleBuffer() else {
                    recoverFailedRestart(
                        positionFraction: positionFraction,
                        preservedTimeline: preservedTimeline,
                        keepDeepPaused: keepDeepPaused,
                        reason: reader.error?.localizedDescription
                            ?? "reader produced no first frame"
                    )
                    return
                }
                currentReader = reader
                currentOutput = output
                pendingLoopStart = nil

                let firstPTS = CMSampleBufferGetPresentationTimeStamp(first)
                if let preservedTimeline,
                   preservedTimeline.isNumeric,
                   firstPTS.isNumeric {
                    ptsOffset = CMTimeSubtract(preservedTimeline, firstPTS)
                    lastEnqueuedEnd = preservedTimeline
                } else if firstPTS.isNumeric {
                    ptsOffset = CMTimeMultiplyByFloat64(firstPTS, multiplier: -1)
                    lastEnqueuedEnd = .zero
                    CMTimebaseSetTime(timebase, time: .zero)
                } else {
                    ptsOffset = .zero
                    lastEnqueuedEnd = .zero
                    CMTimebaseSetTime(timebase, time: .zero)
                }

                // The old frame remains displayed through the flush. This immediate sample
                // replaces it even when the surface is paused and its timebase rate is zero.
                let adjustedFirst = offsetTimingForLoop(first)
                Self.setDisplayImmediately(adjustedFirst)
                renderer.enqueue(adjustedFirst)
                let pts = CMSampleBufferGetPresentationTimeStamp(adjustedFirst)
                let duration = CMSampleBufferGetDuration(adjustedFirst)
                if pts.isNumeric {
                    lastEnqueuedEnd = duration.isNumeric && duration > .zero
                        ? CMTimeAdd(pts, duration)
                        : CMTimeAdd(pts, CMTime(value: 1, timescale: 60))
                }

                CMTimebaseSetRate(
                    timebase,
                    rate: isPaused ? 0.0 : targetPlaybackRate
                )
                let renderDeadline = ProcessInfo.processInfo.systemUptime + 0.2
                while renderer.status == .unknown,
                      ProcessInfo.processInfo.systemUptime < renderDeadline {
                    Thread.sleep(forTimeInterval: 0.005)
                }
                guard renderer.status != .failed else {
                    recoverFailedRestart(
                        positionFraction: positionFraction,
                        preservedTimeline: preservedTimeline,
                        keepDeepPaused: keepDeepPaused,
                        reason: renderer.error?.localizedDescription
                            ?? "sample-buffer renderer rejected the first frame"
                    )
                    return
                }

                lastPlayableAsset = asset
                lastPlayableTrack = videoTrack
                renderTrace("  [restart #\(debugID)] playing \(asset.url.lastPathComponent) rate=\(isPaused ? 0 : targetPlaybackRate) rendererStatus=\(renderer.status.rawValue) requiresFlush=\(renderer.requiresFlushToResumeDecoding) readerStatus=\(reader.status.rawValue) err=\(renderer.error?.localizedDescription ?? "-")")
                if keepDeepPaused {
                    enterDeepPause()
                    return
                }
                feedLogBudget = 4
                prepareNextReader()
                feedFromCurrentReader()
            }
        }
    }

    /// Restore the last asset that decoded successfully. The retained displayed frame stays
    /// visible through this second serialized flush, so a broken rendition never strands a
    /// live original on a frozen renderer.
    private func recoverFailedRestart(
        positionFraction: Double?,
        preservedTimeline: CMTime?,
        keepDeepPaused: Bool,
        reason: String
    ) {
        currentReader = nil
        currentOutput = nil
        guard asset !== lastPlayableAsset else {
            renderLog(
                "  [restart #\(debugID)] FAILED on last playable asset "
                    + "\(asset.url.lastPathComponent): \(reason)"
            )
            return
        }
        renderLog(
            "  [restart #\(debugID)] FAILED \(asset.url.lastPathComponent): \(reason); "
                + "falling back to \(lastPlayableAsset.url.lastPathComponent)"
        )
        asset = lastPlayableAsset
        videoTrack = lastPlayableTrack
        restartPositionFraction = positionFraction
        restartTimelineTime = preservedTimeline
        restartKeepsDeepPause = keepDeepPaused
        restartWithCurrentAsset()
    }

    // MARK: - Preloaded Loop Reader

    private func prepareNextReader() {
        // Rendition changes are applied immediately by policy, selector, and geometry
        // updates. A loop preload must stay on this confirmed-playable asset; silently
        // changing files here would bypass the switch fallback path.
        queue.async { [weak self] in
            guard let self, isRunning else { return }
            installNextReader(asset: asset, track: videoTrack)
        }
    }

    /// Build an asset reader on the renderer queue and store it as the
    /// preloaded next reader. Must run on `queue`.
    private func installNextReader(asset: AVURLAsset, track: AVAssetTrack) {
        guard let reader = try? AVAssetReader(asset: asset) else {
            renderTrace("  [Renderer] Failed to create next reader")
            return
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        // Start while the current iteration is still feeding. Constructing a reader is
        // cheap; startReading() is where AVFoundation opens the decode pipeline. Deferring
        // that work to the boundary makes the final frame linger while the next loop starts.
        guard reader.startReading() else {
            renderTrace("  [Renderer] Failed to start next reader")
            return
        }
        nextReader = reader
        nextOutput = output
    }

    /// Swap to the preloaded next reader at a loop boundary.
    /// Uses timing offset for gapless continuation — no flush, no timebase reset.
    private func swapToNextReader() {
        renderer.stopRequestingMediaData()

        // Align the next reader's first source timestamp when it arrives. Using
        // `lastEnqueuedEnd` as a raw offset assumes every asset starts at PTS zero.
        pendingLoopStart = lastEnqueuedEnd

        if let nr = nextReader, let no = nextOutput {
            if let nrAsset = nr.asset as? AVURLAsset, nrAsset.url != asset.url {
                asset = nrAsset
                videoTrack = no.track
                renderTrace("  [Renderer] Switched variant: \(nrAsset.url.lastPathComponent)")
            }
            currentReader = nr
            currentOutput = no
            nextReader = nil
            nextOutput = nil
        } else {
            renderTrace("  [Renderer] Next reader not ready, creating synchronously")
            guard let reader = try? AVAssetReader(asset: asset) else {
                renderTrace("  [Renderer] Failed to create fallback reader")
                return
            }
            let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else {
                renderTrace("  [Renderer] Failed to start fallback reader")
                return
            }
            currentReader = reader
            currentOutput = output
        }

        prepareNextReader()
        feedFromCurrentReader()
    }

    // MARK: - Playback Loop

    private func feedFromCurrentReader() {
        renderer.requestMediaDataWhenReady(on: queue) { [weak self] in
            guard let self, isRunning else {
                self?.renderer.stopRequestingMediaData()
                return
            }

            // Unrecoverable failure — full reset.
            // Dispatch async: requestMediaDataWhenReady is not reentrant.
            if renderer.status == .failed {
                renderLog("  [Renderer] Status failed: \(renderer.error?.localizedDescription ?? "unknown"), recovering")
                renderer.stopRequestingMediaData()
                queue.async { [weak self] in
                    self?.recoverFromError()
                }
                return
            }

            // Decoder hit a discontinuity. Stop this request callback and recover through
            // the serialized restart path; a direct flush here could overlap a queued switch.
            if renderer.requiresFlushToResumeDecoding {
                renderTrace("  [feed #\(debugID)] requiresFlushToResumeDecoding=YES → serialized restart; status=\(renderer.status.rawValue)")
                renderer.stopRequestingMediaData()
                queue.async { [weak self] in
                    self?.recoverFromError()
                }
                return
            }

            var enqueuedThisTick = 0
            while renderer.isReadyForMoreMediaData {
                if let sample = currentOutput?.copyNextSampleBuffer() {
                    if let loopStart = pendingLoopStart {
                        let sourcePTS = CMSampleBufferGetPresentationTimeStamp(sample)
                        ptsOffset = sourcePTS.isNumeric
                            ? CMTimeSubtract(loopStart, sourcePTS)
                            : loopStart
                        pendingLoopStart = nil
                    }
                    let adjusted = offsetTimingForLoop(sample)
                    enqueuedThisTick += 1

                    // Track the highest end time (max handles B-frame reordering).
                    // Some containers emit padding samples with invalid PTS — skip those
                    // to prevent NaN from poisoning the timeline offset.
                    let pts = CMSampleBufferGetPresentationTimeStamp(adjusted)
                    let dur = CMSampleBufferGetDuration(adjusted)
                    if pts.isValid {
                        let sampleEnd = dur.isValid && dur > .zero
                            ? CMTimeAdd(pts, dur)
                            : CMTimeAdd(pts, CMTime(value: 1, timescale: 60))
                        if sampleEnd > lastEnqueuedEnd {
                            lastEnqueuedEnd = sampleEnd
                        }
                    }

                    renderer.enqueue(adjusted)
                    lastPlayableAsset = asset
                    lastPlayableTrack = videoTrack
                } else {
                    // Dispatch async: requestMediaDataWhenReady is not reentrant.
                    if feedLogBudget > 0 {
                        renderTrace("  [feed #\(debugID)] reader exhausted after enqueuing this tick=\(enqueuedThisTick); status=\(renderer.status.rawValue) → swapToNextReader")
                    }
                    renderer.stopRequestingMediaData()
                    queue.async { [weak self] in
                        self?.swapToNextReader()
                    }
                    return
                }
            }
            if feedLogBudget > 0 {
                feedLogBudget -= 1
                renderTrace("  [feed #\(debugID)] tick enqueued=\(enqueuedThisTick) status=\(renderer.status.rawValue) requiresFlush=\(renderer.requiresFlushToResumeDecoding) ready=\(renderer.isReadyForMoreMediaData) timebase=\(CMTimebaseGetTime(timebase).seconds)")
            }
        }
    }

    /// Offset both DTS and PTS of a sample for gapless looping.
    /// Returns the original sample unchanged for the first loop (no copy needed).
    /// For subsequent loops, creates a lightweight copy with adjusted timing
    /// (shares the underlying data buffer — only the timing metadata differs).
    private func offsetTimingForLoop(_ sample: CMSampleBuffer) -> CMSampleBuffer {
        guard ptsOffset.isNumeric, ptsOffset != .zero else { return sample }

        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let dts = CMSampleBufferGetDecodeTimeStamp(sample)
        let dur = CMSampleBufferGetDuration(sample)

        var timingInfo = CMSampleTimingInfo(
            duration: dur,
            presentationTimeStamp: pts.isValid ? CMTimeAdd(pts, ptsOffset) : pts,
            decodeTimeStamp: dts.isValid ? CMTimeAdd(dts, ptsOffset) : .invalid,
        )

        var adjusted: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil,
            sampleBuffer: sample,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleBufferOut: &adjusted,
        )

        return adjusted ?? sample
    }

    /// Reset through the same flush state machine used by rendition changes. This keeps a
    /// decoder discontinuity from overlapping a source-switch flush.
    private func recoverFromError() {
        let timeline = CMTimebaseGetTime(timebase)
        restartPositionFraction = Self.loopPositionFraction(
            timeline: timeline,
            track: lastPlayableTrack
        )
        restartTimelineTime = timeline
        restartKeepsDeepPause = false
        restartWithCurrentAsset()
    }

}
