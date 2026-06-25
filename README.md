# Workshop Wallpaper Bridge

[![Swift](https://img.shields.io/badge/Swift-6-orange.svg)](Package.swift)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey.svg)](README.md)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Use local Wallpaper Engine Workshop files on macOS.

Workshop Wallpaper Bridge imports a copied Wallpaper Engine Workshop folder into a private Mac library and plays supported wallpapers on the desktop layer. It is built for files you already have locally. It does not talk to Steam, download Workshop items, or modify the copied Workshop folder.

[Website](https://3x-haust.github.io/workshop-wallpaper-bridge/) · [한국어](README.ko.md) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [Releases](https://github.com/3x-haust/workshop-wallpaper-bridge/releases) · [Support](https://www.patreon.com/c/3xhaust)

## Demo

![Workshop Wallpaper Bridge demo](assets/workshop-wallpaper-bridge-demo.gif)

## Support

If Workshop Wallpaper Bridge helps your setup, you can support ongoing compatibility and maintenance on [Patreon](https://www.patreon.com/c/3xhaust).

## Download

Download the latest `WorkshopWallpaperBridge-macOS-arm64.dmg` from [Releases](https://github.com/3x-haust/workshop-wallpaper-bridge/releases).

1. Open the DMG.
2. Drag **Workshop Wallpaper Bridge.app** to **Applications**.
3. Open the app. It runs as a menu bar utility, not a Dock app.

Public releases are Developer ID signed, notarized, and Gatekeeper-checked with download quarantine applied before upload. If macOS reports that a downloaded release is damaged, use the next release and file an issue with the macOS version and release tag.

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

For your own videos, click **Add Video File** instead of scanning a Workshop folder.

Display modes:

- **Fit** keeps the full wallpaper visible.
- **Fill** covers the screen and may crop edges.
- **Stretch** fills the screen exactly and may distort the image.

Playback notes:

- Playback runs continuously by default to avoid Dock and Space transition flicker.
- **Auto-pause behind apps** is optional.
- Closing the settings window does not stop playback.
- **Open at Login** restores the last played wallpaper after login.
- **Play on Desktop** does not change the macOS desktop picture, so the translucent menu bar keeps using your current system wallpaper tint.
- Use **Set Still Wallpaper** only when you explicitly want to replace the macOS desktop and Lock Screen still image.
- **Remove** deletes the imported Mac-library copy only. It does not touch the original copied folder or video.

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
| `scene.pkg` scene wallpaper | Uses the native scene renderer first, even when a local rendered video cache is attached; renders packed 2D image layers, animated sprite-sheet (`texgif`) textures, text-only scenes, selected text SceneScript `update(value)` snippets, basic keyframed motion, selected image-layer and effect-only `waterFlow` / `waterWaves` / `waterRipple` / `scroll` shader motion, and simple `shake` / `spin` / `shine` layer effects from package constants; preserves shader/effect/script/audio requirements for engine-renderer work |

Scene support is conservative. Desktop scene playback is renderer-first and does not treat an attached rendered video cache as the scene implementation. `wwbctl attach-scene-video <asset-id> <video-file>` only stores a local reference cache inside the private Mac library for diagnostics or comparison workflows. Basic image-layer and text-only scenes work, including packed `.tex` textures, LZ4 blocks, common DXT formats, text layers, selected text SceneScript `update(value)` snippets, keyframed position, scale, rotation, and opacity, with mirror-mode keyframe animations playing as ping-pong loops. Animated sprite-sheet textures are decoded from the RePKG-documented `TEXS0001`-`TEXS0003` frame containers, including rotated sheet packing and per-frame timing, and play back as Core Animation frame sequences; embedded MP4 video textures remain unsupported. Full-canvas compose-layer warps such as a scene-wide `waterripple` are distributed onto the layers beneath them so keyframed layer motion stays live instead of freezing under an effect snapshot. Workshop `nitro`-style glint effects play as an approximate noise-driven twinkle pass, and simple sprite or pulse-ring particle systems are approximated with Core Animation emitters; complex particle operators are still skipped. Supported text scripts run through a restricted JavaScriptCore context with `Date`, `Math`, `engine.runtime`, `engine.frametime`, `engine.timeOfDay`, and parsed `scriptProperties`; loops, timers, eval/dynamic functions, unsupported APIs, and throwing scripts fail closed and keep the existing text. Supported image-layer and effect-only `waterFlow`, `waterWaves`, `waterRipple`, and `scroll` effects are driven from package shader constants such as speed, axis speed, direction, scale, strength, and perspective instead of generic layer drift; simple `shake`, `spin`, and `shine` layer effects are mapped to Core Animation when they can be represented safely. The package analyzer preserves scene runtime requirements such as effect files, shader files, shader uniforms, SceneScript, particles, sound layers, audio-analysis inputs, and video textures so renderer-engine parity work can be targeted. Masked effect composition, particles, audio-reactive or object/scene API scripts, full custom shader pipelines, media integration, and video texture playback may still be skipped or look different from Wallpaper Engine until the native scene engine implements those runtime features.

Workshop preview files such as `preview.jpg`, `thumbnail.jpg`, and `cover.png` are treated as thumbnails. If a project contains `scene.pkg`, the app reads the packed scene data instead of stretching a low-resolution preview across the screen.

## Screen Saver

Turn on **Animate Screen Saver** to install and select the bundled macOS screen saver for the current Mac host.

What animates in the screen saver:

- MP4, MOV, and M4V wallpapers from the Mac library.
- Local videos added with **Add Video File**.

What uses a still fallback:

- WebM, MKV, and AVI before conversion.
- Web wallpapers.
- Scene wallpapers.

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

## License

MIT
