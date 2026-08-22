# Workshop Wallpaper Bridge

[![Swift](https://img.shields.io/badge/Swift-6-orange.svg)](Package.swift)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey.svg)](README.md)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Downloads](https://img.shields.io/github/downloads/3x-haust/workshop-wallpaper-bridge/total.svg)](https://github.com/3x-haust/workshop-wallpaper-bridge/releases)

Use local Wallpaper Engine Workshop files on macOS.

Workshop Wallpaper Bridge imports a copied Wallpaper Engine Workshop folder into a private Mac library and plays supported wallpapers on the desktop layer. It is built for files you already have locally. It does not talk to Steam, download Workshop items, or modify the copied Workshop folder.

[Website](https://3x-haust.github.io/workshop-wallpaper-bridge/) · [한국어](README.ko.md) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [Releases](https://github.com/3x-haust/workshop-wallpaper-bridge/releases) · [Support](https://www.patreon.com/c/3xhaust)

## Quick Links

- [Download](#download): install the latest DMG.
- [Use It](#use-it): import a copied Workshop folder or add local videos.
- [What Works](#what-works): check supported wallpaper types.
- [Build From Source](#build-from-source): run the app locally or package a DMG.
- [Maintainers And Contributors](#maintainers-and-contributors): project maintainers and contributors.

## Demo

![Workshop Wallpaper Bridge demo](assets/workshop-wallpaper-bridge-demo.gif)

## Support

If Workshop Wallpaper Bridge helps your setup, you can support ongoing compatibility and maintenance on [Patreon](https://www.patreon.com/c/3xhaust).

## Download

Download the latest `WorkshopWallpaperBridge-macOS-arm64.dmg` from [Releases](https://github.com/3x-haust/workshop-wallpaper-bridge/releases).

1. Open the DMG.
2. Drag **Workshop Wallpaper Bridge.app** to **Applications**.
3. Remove download quarantine from the copy in Applications:

   ```bash
   xattr -r -d com.apple.quarantine "/Applications/Workshop Wallpaper Bridge.app"
   ```

4. Open the app. It runs as a menu bar utility, not a Dock app.

The current public build is ad-hoc signed rather than Apple-notarized because the project does not have a paid Apple Developer account. macOS may otherwise report the downloaded app as damaged. Only remove quarantine from a DMG downloaded from this repository's official [Releases](https://github.com/3x-haust/workshop-wallpaper-bridge/releases) page.

The app checks GitHub Releases for updates automatically when **Auto-check Updates** is enabled. Use **Check Updates** from the settings window, or **Check for Updates** from the menu bar menu, to check manually. When a newer release exists, **Download Update** downloads the latest DMG.

## Use It

For Wallpaper Engine projects:

1. On Windows, locate the Workshop folder:

   ```text
   C:\Program Files (x86)\Steam\steamapps\workshop\content\431960
   ```

2. Copy the `431960` folder to your Mac.
3. Open **Workshop Wallpaper Bridge Settings** from the menu bar icon.
4. Click **Browse**, choose the copied `431960` folder, then click **Scan**.
5. Select a supported item and click **Import Selected**.
6. Click **Play on Desktop**.

- The scan list sorts by **Date Added** newest first by default (folder Date Added, falling back to modification date).
- Switch the sort to **Name** for an alphabetical list.
- Items added to the copied Workshop folder after import are marked **NEW** on the next scan.

For your own videos, click **Add Video File** instead of scanning a Workshop folder.

Display modes:

- **Fit** keeps the full wallpaper visible.
- **Fill** covers the screen and may crop edges.
- **Stretch** fills the screen exactly and may distort the image.

Playback notes:

- Playback runs continuously by default to avoid Dock and Space transition flicker.
- **Auto-pause behind apps** is optional.
- **Play wallpaper audio** is off by default (matching prior versions' silent playback). Turn it on and use the volume slider to hear video-wallpaper audio and, for scene wallpapers, the cached scene video's baked-in background music/ambience.
- Both playback toggles apply immediately to whatever is currently playing, with no restart needed. If playback auto-pauses because the wallpaper is covered by another app, its audio pauses too.
- Closing the settings window does not stop playback.
- **Open at Login** restores the last played wallpaper after login.
- **Play on Desktop** does not change the macOS desktop picture, so the translucent menu bar keeps using your current system wallpaper tint.
- Use **Set Still Wallpaper** only when you explicitly want to replace the macOS desktop and Lock Screen still image.
- **Remove** asks for confirmation, then moves the imported Mac-library copy to the Trash (recoverable) only. It does not touch the original copied folder or video.

The settings window has a **Library** tab (import, your Mac library, Display mode, **Play on Desktop** / **Remove**) and a **Settings** tab (playback toggles, Audio, Scene Engine Assets, Screen Saver, and Language). **Convert Video** and **Set Still Wallpaper** are reachable from the library list's right-click context menu and from the **More** ("⋯") menu next to **Play on Desktop**, not as always-visible buttons.

Use the **Language** picker in the Settings tab to switch the app's UI text between **System**, **한국어**, and **English**. The change applies immediately, without restarting the app; only static UI chrome (buttons, section titles, captions) is localized, so status messages generated while the app runs may still appear in English.

Library rotation:

- Turn on **Rotate Library** to automatically cycle through every playable wallpaper in your Mac library on a timer.
- **Shuffle** randomizes the order, **Rotate Every** sets the interval (30s, 1m, 5m, 15m, 30m, 1h), and **Next** jumps to the next wallpaper immediately.
- Rotation is available in both the settings window and the menu bar menu. The on/off state, shuffle, and interval are remembered across launches and resume after login.
- **Play on Desktop** or **Stop** turns rotation off so manual selection always wins. Non-playable items are skipped automatically.

Imported files are stored in:

```text
~/Library/Application Support/WorkshopWallpaperBridge
```

## What Works

| Project type | Support |
| --- | --- |
| `.mp4`, `.mov`, `.m4v` video | Plays directly |
| `.webm`, `.mkv`, `.avi` video | Converts locally with `ffmpeg`, then plays |
| `index.html` web wallpaper | Plays in a restricted local WebView |
| `.jpg`, `.png`, `.gif`, `.heic` image | Displays as a static desktop layer |
| `scene.pkg` scene wallpaper | Renders offscreen to a cached, looping mp4 the first time it plays, then plays that cached video like a normal video wallpaper (see below). Falls back to a native renderer when the video path is unavailable. |

Scene support is conservative: the app favors a cached video render over a live renderer window, and falls back to an approximating native renderer when it can't render one.

### How scene playback works

- The first play renders the scene offscreen (no renderer window is ever shown) into a cached, looping mp4, using a bundled/configured external GPL scene renderer plus `ffmpeg`.
- When the renderer supports it, frames stream directly into the encoder with no intermediate PNG files, making the first render noticeably faster; older renderer builds fall back to record-then-encode automatically.
- The cached clip is 20 seconds long, and the encode crossfades its last ~1.2 seconds into its first ~1.2 seconds, so the loop seam is blended away rather than just made less frequent.
- Authored sound layers (background music, ambience) are extracted from `scene.pkg` and mixed into the cached video as a looping audio track. Audio is muted by default (turn on **Play wallpaper audio** to hear it) and, unlike the video, is not crossfaded at the seam, so a subtle audio seam may be audible. A failed extraction still produces a silent video rather than failing the render.
- The status line shows live "Rendering scene to video… N%" progress while the first render is in flight.
- Tradeoff: baking the scene into a fixed clip means on-screen clocks, audio reactivity, and mouse/keyboard interaction are not live during video playback. That's accepted in exchange for a renderer window never appearing.
- Once cached, playback uses the normal video-wallpaper path: gapless `AVPlayerLooper` looping, always aspect-fill regardless of the app's fit/fill/stretch setting, and reuse by the bundled screen saver (see Screen Saver below).

`wwbctl attach-scene-video <asset-id> <video-file>` only stores a local reference cache for diagnostics/comparison and is unrelated to the automatic render-to-video cache.

Rendering requires a bundled renderer subprocess, `ffmpeg`, and the Wallpaper Engine runtime `assets` folder (copied by the user from their own Windows installation — Workshop Wallpaper Bridge does not download or ship these files):

- In the app: **Scene Engine Assets** -> **Choose Assets Folder...**, then select the copied `steamapps/common/wallpaper_engine/assets` contents folder.
- For CLI/dev launches, `WWB_SCENE_ENGINE_ASSETS_DIR=/path/to/assets` overrides the app setting; otherwise the app checks `~/Library/Application Support/WorkshopWallpaperBridge/wallpaper-engine-assets`.
- If the renderer binary is present but engine assets or `ffmpeg` are missing or incomplete, the app uses the native fallback instead of attempting a render that would fail.
- Cached scene videos live under `~/Library/Application Support/WorkshopWallpaperBridge/SceneVideoCache/` and are rebuilt automatically when the source `scene.pkg` changes.
- This project does not download Steam Workshop items, redistribute creator assets, or bundle Steam content; a renderer binary is a separate component with its own GPL source notice.

### Native fallback renderer

Used while the first render is in progress, or permanently if the renderer subprocess, engine assets, or `ffmpeg` are unavailable.

Supports:

- Packed `.tex` textures: LZ4 blocks and common DXT formats.
- Text layers and a restricted subset of text SceneScript `update(value)` snippets, run through a sandboxed JavaScriptCore context (`Date`, `Math`, `engine.runtime`, `engine.frametime`, `engine.timeOfDay`, parsed `scriptProperties`); loops, timers, eval/dynamic functions, unsupported APIs, and throwing scripts fail closed and keep the existing text.
- Keyframed position, scale, rotation, and opacity, with mirror-mode keyframe animations playing as ping-pong loops.
- Animated sprite-sheet (`texgif`) textures, decoded from the RePKG-documented `TEXS0001`-`TEXS0003` frame containers (including rotated sheet packing and per-frame timing) and played as Core Animation frame sequences.
- Puppet-warp models (`MDLV0013` skeletons — the format Wallpaper Engine uses for bending fish and characters): mesh, bones, and mirror-mode bone animations, played with CPU skinning so puppet bodies flex instead of gliding rigidly.
- Shader effects ported directly from the scene's packed GLSL to Core Image: `spin`, `shake`, `waterripple`, `waterwaves`, `waterflow`, `scroll` — including flow-map-driven shake so only fins and tails move, and full-canvas compose-layer warps (e.g. a scene-wide `waterripple`) distributed onto the layers beneath them so keyframed motion stays live.
- Approximated particle and glint effects: simple sprite/pulse-ring particle systems via Core Animation emitters, and `nitro`-style glints as a noise-driven twinkle pass.

Still skipped or approximate: complex particle operators, masked effect composition, audio-reactive or object/scene API scripts, full custom shader pipelines, media integration, and embedded MP4 video textures — these may look different from Wallpaper Engine until the native scene engine implements them. The package analyzer preserves scene runtime requirements (effect/shader files, shader uniforms, SceneScript, particles, sound layers, audio-analysis inputs, video textures) so this parity work can be targeted.

Workshop preview files such as `preview.jpg`, `thumbnail.jpg`, and `cover.png` are treated as thumbnails. If a project contains `scene.pkg`, the app reads the packed scene data instead of stretching a low-resolution preview across the screen.

## Screen Saver

Turn on **Animate Screen Saver** to install and select the bundled macOS screen saver for the current Mac host.

What animates in the screen saver:

- MP4, MOV, and M4V wallpapers from the Mac library.
- Local videos added with **Add Video File**.
- Scene wallpapers, once they have a cached render-to-video (see What Works above): the screen saver reuses that same cached mp4, upgrading from the still preview automatically as soon as the background render finishes — no need to play it again first.

What uses a still fallback:

- WebM, MKV, and AVI before conversion.
- Web wallpapers.
- Scene wallpapers that have not rendered a cached video yet.

macOS still controls when the screen saver starts. Configure the start time and password timing in System Settings > Lock Screen. Until macOS starts the selected screen saver, the normal static Lock Screen wallpaper is shown.

The app can also set a still desktop wallpaper explicitly with **Set Still Wallpaper**. For MP4, MOV, and M4V files, it extracts a frame from the video instead of using a small Workshop preview. **Play on Desktop** intentionally leaves the macOS desktop picture alone; this avoids surprising menu bar tint changes while animated playback is running.

## Build From Source

Requirements:

- macOS 14 or newer
- Xcode command line tools
- Swift 6 toolchain
- Optional: `ffmpeg` for WebM, MKV, and AVI conversion

```bash
git clone https://github.com/3x-haust/workshop-wallpaper-bridge.git
cd workshop-wallpaper-bridge
swift run WorkshopWallpaperBridge
```

Build a local app bundle and DMG:

```bash
bash Scripts/package-app.sh
open "dist/Workshop Wallpaper Bridge.app"
```

The script writes:

```text
dist/WorkshopWallpaperBridge-macOS-arm64.dmg
```

To include the optional external GPL scene renderer in a local package:

- Set `SCENE_RENDERER_BINARY=/path/to/wwb-scene-renderer`, or place the executable at `ExternalRenderers/wwb-scene-renderer`, before running `Scripts/package-app.sh`.
- The package script copies the binary into app resources when present, and always writes `Renderer Notices/GPL Scene Renderer Notice.txt` with the source link and default pinned source ref `b79ac590ff5ddcfdae2d26f5c3a5d289b3e4b058` for [3x-haust/wallpaperengine-mac-renderer](https://github.com/3x-haust/wallpaperengine-mac-renderer) (a macOS port of [Almamu/linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine)).
- If you ship a different renderer build, set `SCENE_RENDERER_SOURCE_URL` and `SCENE_RENDERER_SOURCE_REF` to the corresponding published source.

The package never bundles Wallpaper Engine runtime assets:

- Copy your own Windows Wallpaper Engine `steamapps/common/wallpaper_engine/assets` contents folder, then choose it in the app under **Scene Engine Assets** -> **Choose Assets Folder...**.
- `WWB_SCENE_ENGINE_ASSETS_DIR` still overrides the app setting for CLI/dev launches; the default fallback remains `~/Library/Application Support/WorkshopWallpaperBridge/wallpaper-engine-assets`.
- `swift run wwbctl doctor` reports whether the renderer binary and required engine asset files are available.

Install `ffmpeg`:

```bash
brew install ffmpeg
```

## CLI

`wwbctl` is included for scanning, importing, conversion, and scene diagnostics:

```bash
swift run wwbctl scan "/path/to/431960" --out index.json
swift run wwbctl import "/path/to/431960"
swift run wwbctl import-video "/path/to/video.mp4"
swift run wwbctl remove "<asset-id>"
swift run wwbctl convert input.webm --out output.mp4
swift run wwbctl scene-info "/path/to/scene.pkg"
swift run wwbctl scene-render-info "/path/to/scene.pkg"
swift run wwbctl scene-engine-info "/path/to/scene.pkg"
swift run wwbctl scene-parity-check "/path/to/scene.pkg" "/path/to/golden-frames"
swift run wwbctl doctor
```

For signed public releases, set `SIGN_IDENTITY`, `NOTARY_PROFILE`, `REQUIRE_SIGNING=1`, and `REQUIRE_NOTARIZATION=1` before running `Scripts/package-app.sh`. The release workflow also requires the `MACOS_DEVELOPER_ID_APPLICATION_CERTIFICATE_BASE64`, `MACOS_DEVELOPER_ID_APPLICATION_CERTIFICATE_PASSWORD`, `MACOS_NOTARY_APPLE_ID`, `MACOS_NOTARY_TEAM_ID`, and `MACOS_NOTARY_PASSWORD` GitHub Secrets.

## Troubleshooting

Nothing appears on the desktop:

- Check that the imported item is marked `playable`.
- Press **Stop**, then **Play on Desktop** again.
- Temporarily turn off **Auto-pause behind apps**.
- Make sure you are viewing the desktop, not a full-screen app Space.

The wallpaper looks blurry or cropped:

- Use **Fit** to keep the full image or video visible.
- Use **Fill** to cover the screen and accept edge cropping.
- For `scene.pkg` items, check whether the scene uses unsupported particles, advanced scripts, shaders, or video textures.

WebM, MKV, or AVI conversion fails:

```bash
brew install ffmpeg
```

**Workshop Wallpaper Bridge** does not appear in Screen Saver settings:

- Open the packaged `.app`, not only `swift run`.
- Turn on **Animate Screen Saver** once.
- Check that `~/Library/Screen Savers/Workshop Wallpaper Bridge.saver` exists.
- Quit and reopen System Settings if the list does not refresh.

The screen saver preview is black:

- Install the latest release.
- Toggle **Animate Screen Saver** off and on again.
- Click **Screen Saver Settings** once so the app reinstalls and reselects the bundled saver.
- If the preview shows dim text describing what failed to load instead of a plain black screen, that message names the problem (for example, an image that could not be read); a plain, message-free black screen instead means the configuration itself did not load, which the steps above resolve.

## Project Boundaries

Workshop Wallpaper Bridge is local-only.

- It does not download Steam Workshop items.
- It does not bypass Steam authentication.
- It does not bypass DRM.
- It does not emulate Steam protocols.
- It does not claim full `scene.pkg` runtime compatibility.
- It does not upload, share, or redistribute creator assets.
- It does not modify the original copied Workshop folder.

Workshop Wallpaper Bridge is not affiliated with Valve, Steam, or Wallpaper Engine. Wallpaper Engine is a trademark of its respective owner.

## Maintainers And Contributors

<!-- profile-roster:start -->
This section is generated from GitHub user profiles.

### Maintainers

- <a href="https://github.com/3x-haust"><img src="https://avatars.githubusercontent.com/u/94370559?v=4&s=72" width="36" height="36" alt="@3x-haust"></a> [유성윤](https://github.com/3x-haust) `@3x-haust`
- <a href="https://github.com/dev-di-tto"><img src="https://avatars.githubusercontent.com/u/297542341?v=4&s=72" width="36" height="36" alt="@dev-di-tto"></a> [메타몽](https://github.com/dev-di-tto) `@dev-di-tto`

### Contributors

- <a href="https://github.com/3x-haust"><img src="https://avatars.githubusercontent.com/u/94370559?v=4&s=72" width="36" height="36" alt="@3x-haust"></a> [유성윤](https://github.com/3x-haust) `@3x-haust`
- <a href="https://github.com/dev-di-tto"><img src="https://avatars.githubusercontent.com/u/297542341?v=4&s=72" width="36" height="36" alt="@dev-di-tto"></a> [메타몽](https://github.com/dev-di-tto) `@dev-di-tto`
- <a href="https://github.com/lotgood"><img src="https://avatars.githubusercontent.com/u/31810171?v=4&s=72" width="36" height="36" alt="@lotgood"></a> [@lotgood](https://github.com/lotgood)
- <a href="https://github.com/ohjack83-lab"><img src="https://avatars.githubusercontent.com/u/263676419?v=4&s=72" width="36" height="36" alt="@ohjack83-lab"></a> [ohjack83](https://github.com/ohjack83-lab) `@ohjack83-lab`
<!-- profile-roster:end -->

## License

MIT
