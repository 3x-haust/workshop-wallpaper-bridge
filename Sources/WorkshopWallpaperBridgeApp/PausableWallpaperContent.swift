import AppKit

@MainActor
protocol PausableWallpaperContent: AnyObject {
    func setPlaybackSuspended(_ suspended: Bool)
}

@MainActor
protocol DisplayModeUpdatableContent: AnyObject {
    func setDisplayMode(_ displayMode: WallpaperDisplayMode)
}
