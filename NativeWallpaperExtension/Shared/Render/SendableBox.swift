/// Carries a non-`Sendable` value (a `CALayer`, a reply object) into a `Task` or an
/// `@Sendable` closure without tainting the closure's isolation region.
///
/// `nonisolated(unsafe)` on a local isn't enough under region-based isolation: capturing the
/// raw value merges the closure's other, genuinely Sendable captures into a non-Sendable
/// region, which then trips the `sending` checker at unrelated call sites. Boxing makes the
/// capture Sendable so the reasoning stays local.
struct SendableBox<T>: @unchecked Sendable {
    let value: T

    init(_ value: T) { self.value = value }
    init(value: T) { self.value = value }
}
