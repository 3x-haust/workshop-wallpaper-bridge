import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
@preconcurrency import Metal
import ObjectiveC
import os
import QuartzCore

private struct PixelBufferBox: @unchecked Sendable {
    var value: CVPixelBuffer?
}

private final class LatestFrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var frame: CVPixelBuffer?

    func set(_ frame: CVPixelBuffer?) {
        lock.lock()
        self.frame = frame
        lock.unlock()
    }

    func image(using context: CIContext) -> CGImage? {
        lock.lock()
        let currentFrame = frame
        lock.unlock()
        guard let currentFrame else { return nil }
        let image = CIImage(cvPixelBuffer: currentFrame)
        return context.createCGImage(image, from: image.extent)
    }
}

final class MetalSceneRenderer: @unchecked Sendable {
    private static let idCounter = OSAllocatedUnfairLock(initialState: 10_000)
    private static let queueIdentityKey =
        DispatchSpecificKey<ObjectIdentifier>()
    let debugID = MetalSceneRenderer.idCounter.withLock {
        $0 += 1
        return $0
    }

    let displayLayer: AVSampleBufferDisplayLayer

    private var package: MetalScenePackage
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache
    private let renderer: AVSampleBufferVideoRenderer
    private let queue = DispatchQueue(
        label: "dev.3xhaust.WorkshopWallpaperBridge.wallpaper.metal-scene",
        qos: .userInteractive
    )
    private let latestFrame = LatestFrameStore()
    /// Built on first use: a `CIContext` is heavyweight (its own caches and Metal state)
    /// and is only needed for snapshots, so eager creation taxed every wallpaper switch.
    private let imageContextLock = NSLock()
    private var _imageContext: CIContext?
    private let playbackRate = OSAllocatedUnfairLock(initialState: 1.0)

    private var pixelBufferPool: CVPixelBufferPool
    private var formatDescription: CMVideoFormatDescription?
    private var requestedPixelSize: CGSize
    private var pixelSize: CGSize
    private var timer: (any DispatchSourceTimer)?
    private var isRunning = true
    private var isStarted = false
    private var isFrameInFlight = false
    private var currentPolicy: PlaybackPolicy = .full
    private var quality = RenderQuality.auto
    private var sceneTime: Double = 0
    private var lastRenderUptime: TimeInterval?
    private var frameIndex: UInt32 = 0
    private var firstFrameCallback: (@Sendable (Bool) -> Void)?
    private var requiresVisibleRendering = true

    /// Build a renderer that feeds one of a surface's permanent deck layers. The
    /// layer is owned by the surface's `WallpaperLayerDeck` and outlives every
    /// renderer, so this only (re)configures it — it never attaches or detaches it.
    static func create(
        rootLayer: CALayer,
        package: MetalScenePackage,
        reusingDisplayLayer displayLayer: AVSampleBufferDisplayLayer
    ) throws -> MetalSceneRenderer {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw CocoaError(.featureUnsupported)
        }
        let pipeline = try MetalSceneCompiler.makePipeline(
            package: package,
            device: device
        )

        var textureCache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &textureCache
        ) == kCVReturnSuccess, let textureCache else {
            throw CocoaError(.coderInvalidValue)
        }

        let pixelSize = Self.normalizedPixelSize(
            CGSize(
                width: rootLayer.bounds.width * rootLayer.contentsScale,
                height: rootLayer.bounds.height * rootLayer.contentsScale
            )
        )
        let pool = try Self.makePixelBufferPool(size: pixelSize)
        displayLayer.videoGravity = .resizeAspectFill
        displayLayer.frame = rootLayer.bounds
        displayLayer.contentsScale = rootLayer.contentsScale

        return MetalSceneRenderer(
            package: package,
            device: device,
            commandQueue: commandQueue,
            pipeline: pipeline,
            textureCache: textureCache,
            pixelBufferPool: pool,
            pixelSize: pixelSize,
            displayLayer: displayLayer
        )
    }

    private init(
        package: MetalScenePackage,
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        pipeline: MTLRenderPipelineState,
        textureCache: CVMetalTextureCache,
        pixelBufferPool: CVPixelBufferPool,
        pixelSize: CGSize,
        displayLayer: AVSampleBufferDisplayLayer
    ) {
        self.package = package
        self.device = device
        self.commandQueue = commandQueue
        self.pipeline = pipeline
        self.textureCache = textureCache
        self.pixelBufferPool = pixelBufferPool
        self.requestedPixelSize = pixelSize
        self.pixelSize = pixelSize
        self.displayLayer = displayLayer
        self.renderer = displayLayer.sampleBufferRenderer
        queue.setSpecific(
            key: Self.queueIdentityKey,
            value: ObjectIdentifier(self)
        )

        renderTrace(
            "  [MetalScene #\(debugID)] created \(package.manifest.name) "
                + "\(Int(pixelSize.width))x\(Int(pixelSize.height))"
        )
    }

    /// See `VideoRenderer.start` for why a replacement on a hidden deck layer must pass
    /// `requiresVisibleRendering: false`.
    func start(
        onFirstFrameProcessed: (@Sendable (Bool) -> Void)? = nil,
        requiresVisibleRendering: Bool = true
    ) {
        queue.async { [weak self] in
            guard let self, isRunning, !isStarted else {
                onFirstFrameProcessed?(false)
                return
            }
            isStarted = true
            self.requiresVisibleRendering = requiresVisibleRendering
            firstFrameCallback = onFirstFrameProcessed
            renderFrame()
            scheduleTimer()
            if onFirstFrameProcessed != nil {
                queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, firstFrameCallback != nil else { return }
                    renderLog(
                        "  [MetalScene #\(debugID)] first frame timed out"
                    )
                    completeFirstFrame(false)
                }
            }
        }
    }

    func stop(preservingDisplayLayer: Bool = false) {
        if DispatchQueue.getSpecific(key: Self.queueIdentityKey)
            == ObjectIdentifier(self) {
            stopOnQueue()
        } else {
            queue.sync { self.stopOnQueue() }
        }
        latestFrame.set(nil)
        // The surface's layer deck owns the display layer, so callers pass
        // `preservingDisplayLayer: true` for anything but a dying surface.
        if !preservingDisplayLayer {
            displayLayer.removeFromSuperlayer()
        }
        renderLog(
            "  [MetalScene #\(debugID)] stopped \(package.manifest.name)"
        )
    }

    private func stopOnQueue() {
        guard isRunning else { return }
        isRunning = false
        timer?.cancel()
        timer = nil
    }

    func setPlaybackRate(_ rate: Double) {
        playbackRate.withLock { $0 = min(max(rate, 0.25), 4) }
    }

    func setQuality(_ quality: RenderQuality) {
        queue.async { [weak self] in
            guard let self, self.quality != quality else { return }
            self.quality = quality
            _ = self.rebuildPixelBufferPoolIfNeeded()
            self.timer?.cancel()
            self.timer = nil
            self.scheduleTimer()
        }
    }

    func applyPolicy(_ policy: PlaybackPolicy, animated _: Bool = false) {
        queue.async { [weak self] in
            guard let self, isRunning, currentPolicy != policy else { return }
            currentPolicy = policy
            timer?.cancel()
            timer = nil
            lastRenderUptime = nil
            if policy != .paused {
                renderFrame()
                scheduleTimer()
            }
            renderLog(
                "  [MetalScene #\(debugID)] policy → \(policy)"
            )
        }
    }

    func resize(to size: CGSize) {
        let normalized = Self.normalizedPixelSize(size)
        queue.async { [weak self] in
            guard let self, isRunning else { return }
            requestedPixelSize = normalized
            _ = rebuildPixelBufferPoolIfNeeded()
            renderFrame()
        }
    }

    func snapshot() -> CGImage? {
        latestFrame.image(using: imageContext())
    }

    private func imageContext() -> CIContext {
        imageContextLock.lock()
        defer { imageContextLock.unlock() }
        if let context = _imageContext {
            return context
        }
        let context = CIContext(mtlDevice: device)
        _imageContext = context
        return context
    }

    private func scheduleTimer() {
        guard isRunning, isStarted, currentPolicy != .paused, timer == nil else {
            return
        }
        let preferredFramesPerSecond = min(
            quality.maximumFramesPerSecond,
            Double(package.manifest.preferredFPS ?? 120)
        )
        let framesPerSecond: Double = switch currentPolicy {
        case .full: preferredFramesPerSecond
        case .reduced: min(preferredFramesPerSecond, 30)
        case .minimal: min(preferredFramesPerSecond, 15)
        case .paused: 1
        }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(
            deadline: .now() + 1 / framesPerSecond,
            repeating: 1 / framesPerSecond,
            // Proportional leeway (an eighth of the frame interval) lets the kernel
            // coalesce wakeups at throttled frame rates; jitter stays well under a frame.
            leeway: .milliseconds(max(2, Int(1000 / framesPerSecond / 8)))
        )
        source.setEventHandler { [weak self] in self?.renderFrame() }
        timer = source
        source.resume()
    }

    private func renderFrame() {
        guard isRunning, !isFrameInFlight else { return }
        if renderer.status == .failed
            || renderer.requiresFlushToResumeDecoding {
            renderLog(
                "  [MetalScene #\(debugID)] renderer reset: "
                    + (renderer.error?.localizedDescription ?? "flush required")
            )
            renderer.flush()
        }
        guard firstFrameCallback != nil || renderer.isReadyForMoreMediaData,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pixelBufferPool,
            &pixelBuffer
        ) == kCVReturnSuccess, let pixelBuffer else {
            return
        }

        var metalTexture: CVMetalTexture?
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &metalTexture
        ) == kCVReturnSuccess,
              let metalTexture,
              let texture = CVMetalTextureGetTexture(metalTexture) else {
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let delta = lastRenderUptime.map { min(max(now - $0, 0), 0.25) } ?? 0
        lastRenderUptime = now
        let rate = playbackRate.withLock { $0 }
        sceneTime += delta * rate
        var uniforms = DriftwoodMetalUniforms(
            resolution: SIMD2(Float(width), Float(height)),
            time: Float(sceneTime),
            deltaTime: Float(delta),
            playbackRate: Float(rate),
            frameIndex: frameIndex
        )
        frameIndex &+= 1

        do {
            try MetalSceneCompiler.encode(
                commandBuffer: commandBuffer,
                texture: texture,
                pipeline: pipeline,
                uniforms: &uniforms
            )
        } catch {
            renderLog(
                "  [MetalScene #\(debugID)] command encoding failed: \(error)"
            )
            completeFirstFrame(false)
            return
        }
        isFrameInFlight = true
        let completedFrame = PixelBufferBox(value: pixelBuffer)
        commandBuffer.addCompletedHandler { [weak self] buffer in
            guard let self else { return }
            let succeeded = buffer.status == .completed
            queue.async { [weak self, completedFrame, succeeded] in
                guard let self else { return }
                self.isFrameInFlight = false
                defer {
                    if self.rebuildPixelBufferPoolIfNeeded() {
                        self.renderFrame()
                    }
                }
                guard self.isRunning, succeeded,
                      let pixelBuffer = completedFrame.value,
                      let sample = self.makeSampleBuffer(from: pixelBuffer) else {
                    self.completeFirstFrame(false)
                    return
                }
                self.renderer.enqueue(sample)
                self.latestFrame.set(pixelBuffer)
                // Only the first frame needs a transaction flush: a remote context's layer
                // tree must reach the render server once (see VideoRenderer.start), but
                // after that, sample-buffer enqueues bypass Core Animation commits — the
                // steady-state video feed loop never flushes either. Flushing here every
                // frame forced a layer-tree commit walk at up to 60 Hz per scene.
                guard self.firstFrameCallback != nil else { return }
                CATransaction.flush()
                guard self.requiresVisibleRendering else {
                    self.completeFirstFrame(self.renderer.status != .failed)
                    return
                }
                let deadline = ProcessInfo.processInfo.systemUptime + 0.2
                while self.renderer.status == .unknown,
                      ProcessInfo.processInfo.systemUptime < deadline {
                    Thread.sleep(forTimeInterval: 0.005)
                }
                self.completeFirstFrame(self.renderer.status == .rendering)
            }
        }
        commandBuffer.commit()
    }

    private func completeFirstFrame(_ rendered: Bool) {
        let callback = firstFrameCallback
        firstFrameCallback = nil
        callback?(rendered)
    }

    @discardableResult
    private func rebuildPixelBufferPoolIfNeeded() -> Bool {
        guard !isFrameInFlight else { return false }
        let scale = quality.renderScale
        let targetSize = Self.normalizedPixelSize(
            CGSize(
                width: requestedPixelSize.width * scale,
                height: requestedPixelSize.height * scale
            )
        )
        guard targetSize != pixelSize else { return false }
        do {
            pixelBufferPool = try Self.makePixelBufferPool(size: targetSize)
            pixelSize = targetSize
            formatDescription = nil
            CVMetalTextureCacheFlush(textureCache, 0)
            renderTrace(
                "  [MetalScene #\(debugID)] render size → "
                    + "\(Int(targetSize.width))x\(Int(targetSize.height))"
            )
            return true
        } catch {
            renderLog(
                "  [MetalScene #\(debugID)] resize failed: \(error)"
            )
            return false
        }
    }

    private func makeSampleBuffer(
        from pixelBuffer: CVPixelBuffer
    ) -> CMSampleBuffer? {
        if formatDescription == nil {
            guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &formatDescription
            ) == noErr else {
                return nil
            }
        }
        guard let formatDescription else { return nil }
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: .invalid,
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        ) == noErr, let sample else {
            return nil
        }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sample,
            createIfNecessary: true
        ), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, 0),
                to: CFMutableDictionary.self
            )
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(
                    kCMSampleAttachmentKey_DisplayImmediately
                ).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sample
    }

    private static func makePixelBufferPool(
        size: CGSize
    ) throws -> CVPixelBufferPool {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: Int(size.width),
            kCVPixelBufferHeightKey: Int(size.height),
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            nil,
            attributes as CFDictionary,
            &pool
        ) == kCVReturnSuccess, let pool else {
            throw CocoaError(.coderInvalidValue)
        }
        return pool
    }

    private static func normalizedPixelSize(_ size: CGSize) -> CGSize {
        CGSize(
            width: max(1, size.width.rounded()),
            height: max(1, size.height.rounded())
        )
    }
}
