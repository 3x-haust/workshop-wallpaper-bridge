import Foundation
import ObjectiveC
import QuartzCore

/// Layer plumbing the render core needs in both hosts.
///
/// Written to satisfy the stricter host: WallpaperAgent puts the extension's layer tree in a
/// remote `CALayerHost`, where implicit animations and an unprepared video layer are both
/// visible defects. Neither call does any harm in an ordinary in-process window.

/// Remote layer trees should never inherit Core Animation's default position/fade actions
/// when WallpaperAgent hosts or reuses the context. Note this suppresses *implicit*
/// animations only — an explicit `CAAnimation` added with `add(_:forKey:)` still runs, which
/// is what the crossfade relies on.
func disableImplicitAnimations(on layer: CALayer) {
    let disabled = NSNull()
    layer.actions = [
        "bounds": disabled,
        "contents": disabled,
        "onOrderIn": disabled,
        "onOrderOut": disabled,
        "opacity": disabled,
        "position": disabled,
        "sublayers": disabled,
        "transform": disabled,
    ]
}

/// Call `AVSampleBufferDisplayLayer`'s private `_setDisallowsVideoLayerDisplayCompositing:`
/// (a BOOL setter Apple's WallpaperExtensionKit uses on every AVSBDL). Resolved via the ObjC
/// runtime so the private selector never appears in a header; a no-op if the API ever
/// disappears. Prevents the layer painting opaque black before its first frame.
func setDisallowsVideoLayerDisplayCompositing(_ layer: CALayer, _ flag: Bool) {
    let sel = NSSelectorFromString("_setDisallowsVideoLayerDisplayCompositing:")
    guard layer.responds(to: sel),
          let imp = class_getMethodImplementation(type(of: layer), sel) else { return }
    typealias SetBoolFn = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
    unsafeBitCast(imp, to: SetBoolFn.self)(layer, sel, ObjCBool(flag))
}
