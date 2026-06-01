import AppKit
import AVFoundation

@MainActor
final class VideoWallpaperView: NSView, PausableWallpaperContent, DisplayModeUpdatableContent {
    private let player: AVQueuePlayer
    private let looper: AVPlayerLooper
    private let playerLayer: AVPlayerLayer

    init(url: URL, frame: CGRect, displayMode: WallpaperDisplayMode) {
        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer()
        player = queue
        looper = AVPlayerLooper(player: queue, templateItem: item)
        playerLayer = AVPlayerLayer(player: player)
        super.init(frame: frame)
        playerLayer.videoGravity = WallpaperContentLayout.videoGravity(for: displayMode)
        wantsLayer = true
        layer = playerLayer
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
        layer?.frame = bounds
    }

    func setPlaybackSuspended(_ suspended: Bool) {
        if suspended {
            player.pause()
        } else {
            player.play()
        }
    }

    func setDisplayMode(_ displayMode: WallpaperDisplayMode) {
        playerLayer.videoGravity = WallpaperContentLayout.videoGravity(for: displayMode)
    }
}
