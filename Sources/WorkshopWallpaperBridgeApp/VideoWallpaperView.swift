import AppKit
import AVFoundation
import CoreImage

@MainActor
final class VideoWallpaperView: NSView,
    PausableWallpaperContent,
    DisplayModeUpdatableContent,
    WallpaperContentLifecycle,
    AudioControllableWallpaperContent {
    private let player: AVQueuePlayer
    private let looper: AVPlayerLooper
    private let fallbackLayer = CALayer()
    // Not private so tests can assert on the configured video gravity
    // (e.g. that scene-rendered wallpaper videos are forced to fill).
    let playerLayer: AVPlayerLayer
    private weak var sampledItem: AVPlayerItem?
    private var frameOutput: AVPlayerItemVideoOutput?
    private var sampledFrame: CIImage?

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
        audioVolume: Double = 0.5
    ) {
        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer()
        player = queue
        looper = AVPlayerLooper(player: queue, templateItem: item)
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
        player.play()
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

    func prepareForClose() {
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
