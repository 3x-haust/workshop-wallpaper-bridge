import AppKit
import AVFoundation

@MainActor
final class VideoWallpaperView: NSView, PausableWallpaperContent {
    private let player: AVQueuePlayer
    private let looper: AVPlayerLooper

    init(url: URL, frame: CGRect) {
        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer()
        player = queue
        looper = AVPlayerLooper(player: queue, templateItem: item)
        super.init(frame: frame)
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspectFill
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
}
