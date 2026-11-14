import Foundation

/// How hard the renderer is allowed to work. Chosen by the user in Settings and applied by
/// both hosts.
///
/// This used to be an app-side enum that reached the extension as a bare `String`, which meant
/// both of the extension's `switch`es needed a `default:` — and `auto` fell into it silently.
/// Keeping the derivations here makes every case deliberate and stops the two render paths
/// from drifting apart.
enum RenderQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto, high, balanced, performance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .high: "High"
        case .balanced: "Balanced"
        case .performance: "Performance"
        }
    }

    /// Upper bound on frame rate. A scene's own `preferredFPS` can lower this further.
    var maximumFramesPerSecond: Double {
        switch self {
        case .high: 60
        // `auto` deliberately matches `balanced` — the adaptive part of "auto" is the
        // playback policy (thermal, battery, occlusion), not a different frame ceiling.
        case .auto, .balanced: 30
        case .performance: 15
        }
    }

    /// Fraction of the surface's pixel size a procedural scene renders at, before being
    /// scaled up for display. Videos are unaffected — they render at their own resolution.
    var renderScale: CGFloat {
        switch self {
        case .high: 1
        case .auto, .balanced: 0.75
        case .performance: 0.5
        }
    }

    /// Resolve a value that crossed a process boundary as a string, falling back to `auto`.
    init(rawValueOrAuto raw: String?) {
        self = raw.flatMap(RenderQuality.init(rawValue:)) ?? .auto
    }
}
