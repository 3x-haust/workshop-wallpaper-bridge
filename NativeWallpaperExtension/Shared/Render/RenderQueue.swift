import Foundation

/// The one serial queue the render core is confined to.
///
/// Surfaces, layer decks and content switches are all single-threaded on this queue rather
/// than lock-protected: the work is inherently ordered (a switch must not interleave with a
/// teardown), and Core Animation transactions want a stable thread anyway.
///
/// This must be the *same* queue a host uses for its own lifecycle work. The extension's
/// `Lifecycle.queue` is an alias for it — two distinct queues would silently break the
/// ordering guarantees the deck's exactly-once cleanup depends on.
public enum RenderQueue {
    public static let serial = DispatchQueue(label: "dev.3xhaust.WorkshopWallpaperBridge.wallpaper.render")
}
