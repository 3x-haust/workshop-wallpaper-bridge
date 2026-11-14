import Foundation

/// Central decision-maker for wallpaper playback behavior.
/// Replaces scattered shouldPause boolean checks with a graduated policy system.
enum PlaybackPolicy: Int, Comparable {
    case full = 0
    case reduced = 1
    case minimal = 2
    case paused = 3

    /// Backlight level below which the display counts as off. The display is still
    /// technically "awake" at this point, so no sleep notification fires and
    /// WallpaperAgent never switches to "idle" — but the user cannot see anything.
    static let brightnessPauseThreshold: Float = 0.05

    static func < (lhs: PlaybackPolicy, rhs: PlaybackPolicy) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Evaluate all conditions and return the most restrictive applicable policy.
    ///
    /// `alwaysPauseDesktop`: when true, wallpaper only plays on the lock screen.
    /// On the desktop (unlocked), it pauses with a ramp animation.
    ///
    /// Lock screen never reduces FPS by itself — only power/thermal conditions do.
    static func compute(
        presentationMode: String,
        activityState: String,
        userPaused: Bool,
        alwaysPauseDesktop: Bool,
        pauseWhenOccluded: Bool,
        desktopOccluded: Bool,
        pauseOnBattery: Bool,
        thermalState: ProcessInfo.ThermalState,
        isOnBattery: Bool,
        batteryLevel: Int,
        displayBrightness: Float = 1.0,
    ) -> PlaybackPolicy {
        var worst: PlaybackPolicy = .full

        // --- paused tier ---
        if userPaused { worst = max(worst, .paused) }
        if thermalState == .critical { worst = max(worst, .paused) }
        if batteryLevel < 10 { worst = max(worst, .paused) }
        if activityState.contains("suspended") { worst = max(worst, .paused) }
        if presentationMode == "idle" { worst = max(worst, .paused) }
        if pauseOnBattery, isOnBattery { worst = max(worst, .paused) }
        // User dimmed the backlight to ~zero — nothing is visible to animate.
        if displayBrightness < Self.brightnessPauseThreshold {
            worst = max(worst, .paused)
        }
        // Desktop occlusion is irrelevant on the lock screen — the wallpaper
        // is always fully visible there regardless of desktop window state.
        if pauseWhenOccluded, desktopOccluded, presentationMode != "locked" { worst = max(worst, .paused) }
        if alwaysPauseDesktop, presentationMode != "locked" { worst = max(worst, .paused) }

        // --- minimal tier ---
        if thermalState == .serious { worst = max(worst, .minimal) }
        if isOnBattery, batteryLevel < 20 { worst = max(worst, .minimal) }

        // --- reduced tier ---
        if thermalState == .fair { worst = max(worst, .reduced) }
        if isOnBattery { worst = max(worst, .reduced) }

        return worst
    }

}
