import QuartzCore

/// How Driftwood animates a wallpaper content change on a surface that is already
/// visible. There is exactly one transition today (a crossfade); this type is the
/// seam that lets more be added — and made user-selectable — without touching the
/// renderers or the overlay windows.
///
/// Compiled into both the app and the wallpaper extension so the two paths cannot
/// drift apart.
enum WallpaperTransition {
    /// Crossfade length when replacing wallpaper content on a visible surface.
    /// Cold starts, re-acquires (Space switch, display wake) and metadata-only
    /// assignment updates are NOT transitions and must stay instant.
    static let fadeDuration: TimeInterval = 1.0

    /// Slack added when scheduling the post-fade cleanup, so the reconciler always
    /// runs after Core Animation has reached the final opacity.
    static let fadeSettleSlack: TimeInterval = 0.05

    static var timingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(name: .easeInEaseOut)
    }
}
