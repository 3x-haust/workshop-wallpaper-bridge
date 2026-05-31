import AppKit

@MainActor
protocol PausableWallpaperContent: AnyObject {
    func setPlaybackSuspended(_ suspended: Bool)
}
