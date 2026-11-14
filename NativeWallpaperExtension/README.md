# System wallpaper extension (macOS 26+)

A `com.apple.wallpaper` ExtensionKit extension that WallpaperAgent hosts, so a video
wallpaper is drawn by macOS itself and keeps playing where macOS hides app windows
(dragging or editing desktop widgets, revealing the desktop).

Adapted from [Driftwood](https://github.com/iamEvanYT/driftwood) at commit
`17565db7fb208bb5094ca49e79d07e6181fce1a1` (MIT, see `LICENSE.driftwood`):
`Extension/` is its `DriftwoodWallpaperExtension/`, `Shared/` its `Shared/`. Changes:

- Bundle, notification and queue identifiers use `dev.3xhaust.WorkshopWallpaperBridge.wallpaper`;
  user-facing names say Workshop Wallpaper Bridge.
- `WallpaperAssignmentStore.swift` imports AppKit (CGDisplayCreateUUIDFromDisplayID).
- `WallpaperSurface` accepts a decoded first frame instead of waiting for it to be
  composited: WallpaperAgent only composites a new context after the acquire reply,
  which waits for that frame, so on macOS 27 a first build always timed out.

It relies on private WallpaperExtensionKit interfaces. `Scripts/package-app.sh` builds it
with `swiftc` (ExtensionKit's `_NSExtensionMain` entry point) into
`Contents/Extensions/` and signs it with the app sandbox entitlement. The app writes the
video and preferences into the extension's container and selects it in the wallpaper
store (`Sources/WorkshopWallpaperBridgeApp/SystemWallpaper*.swift`).
