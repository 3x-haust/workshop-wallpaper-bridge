# Copilot Instructions

When reviewing or generating code for this repository:

- Treat the app as a local-only macOS utility.
- Do not suggest Steam Workshop downloaders, authentication bypasses, DRM bypasses, or asset redistribution features.
- Pay close attention to Swift concurrency. Background work must not allow overlapping manifest writes or stale UI updates.
- Treat `LibraryStore` manifest updates as consistency-sensitive.
- Treat Workshop metadata, scene package paths, web wallpaper content, and symlinks as untrusted inputs.
- Prefer conservative scene support over claiming full Wallpaper Engine runtime compatibility.
- For user-facing behavior changes, update both `README.md` and `README.ko.md`.
- Prefer tests in `Tests/WorkshopWallpaperCoreTests` for scanner, package, texture, and store behavior.
- Prefer tests in `Tests/WorkshopWallpaperBridgeAppTests` for app state, UI lifecycle, playback, and macOS integration boundaries.

Why this exists: Copilot reviews are more useful when they understand this project is a local bridge with strict file safety and compatibility boundaries.

