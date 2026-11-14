import Foundation

/// Logging seam for the shared render core.
///
/// The two hosts log very differently — the sandboxed extension writes a rotating file inside
/// its container (it has no console to attach to), while the app surfaces problems in its UI.
/// Rather than push one of those on the other, the core emits through this indirection and a
/// host installs its own sink at startup — the extension writes its file, the app writes to
/// the unified log. With no sink installed the core is silent.
public enum RenderLog {
    /// Normal events: content switches, state changes, failures.
    public nonisolated(unsafe) static var sink: (@Sendable (String) -> Void)?

    /// High-volume per-switch/per-frame diagnostics. Kept separate so a host can enable the
    /// noisy channel independently — the extension gates it on a marker file.
    public nonisolated(unsafe) static var traceSink: (@Sendable (String) -> Void)?
}

func renderLog(_ message: String) {
    RenderLog.sink?(message)
}

/// `@autoclosure` so the (often expensive) interpolation is skipped when tracing is off.
func renderTrace(_ message: @autoclosure () -> String) {
    guard let traceSink = RenderLog.traceSink else { return }
    traceSink(message())
}
