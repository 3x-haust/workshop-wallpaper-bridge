import AppKit

@MainActor
protocol PausableWallpaperContent: AnyObject {
    func setPlaybackSuspended(_ suspended: Bool)
}

@MainActor
protocol DisplayModeUpdatableContent: AnyObject {
    func setDisplayMode(_ displayMode: WallpaperDisplayMode)
}

@MainActor
protocol WallpaperContentLifecycle: AnyObject {
    func prepareForClose()
}

@MainActor
protocol AudioControllableWallpaperContent: AnyObject {
    func setAudioEnabled(_ enabled: Bool, volume: Double)
}
