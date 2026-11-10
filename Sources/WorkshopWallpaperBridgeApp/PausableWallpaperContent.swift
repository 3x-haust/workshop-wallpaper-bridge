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
protocol WallpaperContentPreparing: AnyObject {
    /// Completes once initial loading has succeeded or failed; closing cancels delivery.
    func whenReady(_ completion: @escaping (Result<Void, Error>) -> Void)
}

struct WallpaperPreparationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
protocol WallpaperContentLifecycle: AnyObject {
    func prepareForClose()
}

@MainActor
protocol AudioControllableWallpaperContent: AnyObject {
    func setAudioEnabled(_ enabled: Bool, volume: Double)
}
