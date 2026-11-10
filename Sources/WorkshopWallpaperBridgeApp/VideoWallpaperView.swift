import AppKit
import AVFoundation
import CoreImage

@MainActor
final class VideoWallpaperView: NSView,
    PausableWallpaperContent,
    DisplayModeUpdatableContent,
    WallpaperContentLifecycle,
    WallpaperContentPreparing,
    AudioControllableWallpaperContent {
    private let player: AVQueuePlayer
    private var looper: AVPlayerLooper?
    private var preparationTask: Task<Void, Never>?
    private var isSuspended = false
    private var firstFrameVerified = false
    private var looperReadinessObservation: NSKeyValueObservation?
    private let fallbackLayer = CALayer()
    // Not private so tests can assert on the configured video gravity
    // (e.g. that scene-rendered wallpaper videos are forced to fill).
    let playerLayer: AVPlayerLayer
    private weak var sampledItem: AVPlayerItem?
    private var frameOutput: AVPlayerItemVideoOutput?
    private var sampledFrame: CIImage?
    private var readinessHandler: ((Result<Void, Error>) -> Void)?
    private var readinessResult: Result<Void, Error>?
    private var readinessObservations: [NSKeyValueObservation] = []
    private var itemReadinessObservation: NSKeyValueObservation?
    private weak var readinessItem: AVPlayerItem?
    private var closed = false

    /// Attach lazily to the current looper item; AVPlayerLayer continues normal
    /// presentation. Compose effects sample that same item and playback time.
    func currentFrame() -> CIImage? {
        guard let item = player.currentItem else { return nil }
        if sampledItem !== item {
            if let sampledItem, let frameOutput { sampledItem.remove(frameOutput) }
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            item.add(output); sampledItem = item; frameOutput = output; sampledFrame = nil
        }
        if let frameOutput {
            let time = frameOutput.itemTime(forHostTime: CACurrentMediaTime())
            if frameOutput.hasNewPixelBuffer(forItemTime: time), let buffer = frameOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                sampledFrame = CIImage(cvPixelBuffer: buffer)
            }
        }
        return sampledFrame
    }

    init(
        url: URL,
        fallbackImageURL: URL?,
        frame: CGRect,
        displayMode: WallpaperDisplayMode,
        audioEnabled: Bool = false,
        audioVolume: Double = 0.5,
        assetID: String? = nil
    ) {
        player = AVQueuePlayer()
        playerLayer = AVPlayerLayer(player: player)
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        configureFallbackLayer(fallbackImageURL: fallbackImageURL, displayMode: displayMode)
        playerLayer.videoGravity = WallpaperContentLayout.videoGravity(for: displayMode)
        layer?.addSublayer(fallbackLayer)
        layer?.addSublayer(playerLayer)
        layoutLayers()
        player.actionAtItemEnd = .none
        player.isMuted = !audioEnabled
        player.volume = Float(audioVolume)
        preparationTask = Task { [weak self] in
            do {
                let preparedURL = try await VideoPlaybackPreparation.prepare(url: url, assetID: assetID)
                try await VideoPlaybackPreparation.verifyFirstFrame(url: preparedURL)
                guard let self, !self.closed, !Task.isCancelled else { return }
                self.firstFrameVerified = true
                self.looper = AVPlayerLooper(player: self.player, templateItem: AVPlayerItem(url: preparedURL))
                self.observeLooperReadiness()
                if !self.isSuspended { self.player.play() }
                self.observeCurrentItemReadiness()
            } catch {
                guard let self, !self.closed, !Task.isCancelled else { return }
                self.finishReadiness(.failure(error))
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        layoutLayers()
    }

    func setPlaybackSuspended(_ suspended: Bool) {
        isSuspended = suspended
        guard !closed else { return }
        if suspended {
            player.pause()
        } else {
            player.play()
        }
    }

    func setDisplayMode(_ displayMode: WallpaperDisplayMode) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fallbackLayer.contentsGravity = WallpaperContentLayout.imageContentsGravity(for: displayMode)
        playerLayer.videoGravity = WallpaperContentLayout.videoGravity(for: displayMode)
        CATransaction.commit()
    }

    func setAudioEnabled(_ enabled: Bool, volume: Double) {
        player.isMuted = !enabled
        player.volume = Float(volume)
    }

    func whenReady(_ completion: @escaping (Result<Void, Error>) -> Void) {
        guard !closed else { return }
        if let readinessResult { completion(readinessResult); return }
        readinessHandler = completion
        guard readinessObservations.isEmpty else { return }
        readinessObservations = [
            player.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.observeCurrentItemReadiness() }
            },
            player.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.checkReadiness() }
            }
        ]
        observeLooperReadiness()
    }

    private func observeLooperReadiness() {
        guard !closed, readinessResult == nil else { return }
        looperReadinessObservation = looper?.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.checkReadiness() }
        }
    }

    private func observeCurrentItemReadiness() {
        guard !closed, readinessResult == nil else { return }
        if readinessItem !== player.currentItem {
            readinessItem = player.currentItem
            itemReadinessObservation = player.currentItem?.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.checkReadiness() }
            }
        }
        checkReadiness()
    }

    private func checkReadiness() {
        guard !closed, readinessResult == nil else { return }
        if looper?.status == .failed || player.status == .failed || player.currentItem?.status == .failed {
            finishReadiness(.failure(looper?.error ?? player.error ?? player.currentItem?.error
                ?? WallpaperPreparationError(message: "The selected video could not be loaded.")))
        } else if firstFrameVerified, player.currentItem?.status == .readyToPlay {
            finishReadiness(.success(()))
        }
    }

    private func finishReadiness(_ result: Result<Void, Error>) {
        readinessResult = result
        looperReadinessObservation = nil
        readinessObservations.removeAll()
        itemReadinessObservation = nil
        let handler = readinessHandler
        readinessHandler = nil
        handler?(result)
    }

    func prepareForClose() {
        closed = true
        preparationTask?.cancel()
        preparationTask = nil
        looperReadinessObservation = nil
        looper?.disableLooping()
        looper = nil
        readinessHandler = nil
        readinessObservations.removeAll()
        itemReadinessObservation = nil
        if let sampledItem, let frameOutput { sampledItem.remove(frameOutput) }
        frameOutput = nil; sampledItem = nil; sampledFrame = nil
        player.pause()
        player.removeAllItems()
        playerLayer.player = nil
    }

    private func configureFallbackLayer(fallbackImageURL: URL?, displayMode: WallpaperDisplayMode) {
        fallbackLayer.backgroundColor = NSColor.black.cgColor
        fallbackLayer.contentsGravity = WallpaperContentLayout.imageContentsGravity(for: displayMode)
        fallbackLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        fallbackLayer.minificationFilter = .linear
        fallbackLayer.magnificationFilter = .linear
        guard let fallbackImageURL,
              let image = NSImage(contentsOf: fallbackImageURL),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }
        fallbackLayer.contents = cgImage
    }

    private func layoutLayers() {
        layer?.frame = bounds
        fallbackLayer.frame = bounds
        playerLayer.frame = bounds
    }
}
