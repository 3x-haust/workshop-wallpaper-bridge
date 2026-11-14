import Foundation

/// The extension evaluates policy from a `PowerMonitor.PowerState` snapshot. That type is
/// extension-only (it polls IOKit power sources and the backlight), so this convenience
/// overload stays here while the policy rules themselves live in the shared render core.
extension PlaybackPolicy {
    static func compute(
        presentationMode: String,
        activityState: String,
        userPaused: Bool,
        alwaysPauseDesktop: Bool,
        pauseWhenOccluded: Bool,
        desktopOccluded: Bool,
        pauseOnBattery: Bool,
        powerState: PowerMonitor.PowerState,
    ) -> PlaybackPolicy {
        compute(
            presentationMode: presentationMode,
            activityState: activityState,
            userPaused: userPaused,
            alwaysPauseDesktop: alwaysPauseDesktop,
            pauseWhenOccluded: pauseWhenOccluded,
            desktopOccluded: desktopOccluded,
            pauseOnBattery: pauseOnBattery,
            thermalState: powerState.thermalState,
            isOnBattery: powerState.isOnBattery,
            batteryLevel: powerState.batteryLevel,
            displayBrightness: powerState.displayBrightness,
        )
    }
}
