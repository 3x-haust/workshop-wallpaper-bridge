import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

enum WallpaperRenderer: @unchecked Sendable {
    case video(VideoRenderer)
    case metalScene(MetalSceneRenderer)

    var debugID: Int {
        switch self {
        case .video(let renderer): renderer.debugID
        case .metalScene(let renderer): renderer.debugID
        }
    }

    var currentVideoTime: CMTime? {
        guard case .video(let renderer) = self else { return nil }
        return CMTimebaseGetTime(renderer.timebase)
    }

    func start(
        onFirstFrameProcessed: (@Sendable (Bool) -> Void)? = nil,
        requiresVisibleRendering: Bool = true
    ) {
        switch self {
        case .video(let renderer):
            renderer.start(
                onFirstFrameProcessed: onFirstFrameProcessed,
                requiresVisibleRendering: requiresVisibleRendering
            )
        case .metalScene(let renderer):
            renderer.start(
                onFirstFrameProcessed: onFirstFrameProcessed,
                requiresVisibleRendering: requiresVisibleRendering
            )
        }
    }

    var displayLayer: AVSampleBufferDisplayLayer {
        switch self {
        case .video(let renderer): renderer.displayLayer
        case .metalScene(let renderer): renderer.displayLayer
        }
    }

    func stop(preservingDisplayLayer: Bool = false) {
        switch self {
        case .video(let renderer):
            renderer.stop(preservingDisplayLayer: preservingDisplayLayer)
        case .metalScene(let renderer):
            renderer.stop(preservingDisplayLayer: preservingDisplayLayer)
        }
    }

    func updateVariantSelector(
        _ selector: (@Sendable (PlaybackPolicy, CGSize) -> URL)?
    ) {
        guard case .video(let renderer) = self else { return }
        renderer.updateVariantSelector(selector)
    }

    func setPlaybackRate(_ rate: Double) {
        switch self {
        case .video(let renderer): renderer.setPlaybackRate(rate)
        case .metalScene(let renderer): renderer.setPlaybackRate(rate)
        }
    }

    func setQuality(_ quality: RenderQuality) {
        guard case .metalScene(let renderer) = self else { return }
        renderer.setQuality(quality)
    }

    func applyPolicy(_ policy: PlaybackPolicy, animated: Bool = false) {
        switch self {
        case .video(let renderer):
            renderer.applyPolicy(policy, animated: animated)
        case .metalScene(let renderer):
            renderer.applyPolicy(policy, animated: animated)
        }
    }

    func resize(to pixelSize: CGSize) {
        switch self {
        case .video(let renderer):
            renderer.updateDestinationPixelSize(pixelSize)
        case .metalScene(let renderer):
            renderer.resize(to: pixelSize)
        }
    }

    func snapshot() -> CGImage? {
        guard case .metalScene(let renderer) = self else { return nil }
        return renderer.snapshot()
    }
}
