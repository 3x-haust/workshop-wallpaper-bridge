import AppKit
import AVFoundation

@MainActor
final class VideoWallpaperView: NSView,
    PausableWallpaperContent,
    DisplayModeUpdatableContent,
    WallpaperContentLifecycle {
    private let player: AVQueuePlayer
    private let looper: AVPlayerLooper
    private let fallbackLayer = CALayer()
    private let playerLayer: AVPlayerLayer

    init(url: URL, fallbackImageURL: URL?, frame: CGRect, displayMode: WallpaperDisplayMode) {
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
        player.isMuted = true
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

    func prepareForClose() {
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
