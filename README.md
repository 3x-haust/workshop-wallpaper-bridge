# Workshop Wallpaper Bridge

[![Swift](https://img.shields.io/badge/Swift-6-orange.svg)](Package.swift)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey.svg)](README.md)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Use local Wallpaper Engine Workshop files on macOS.

Workshop Wallpaper Bridge imports a copied Wallpaper Engine Workshop folder into a private Mac library and plays supported wallpapers on the desktop layer. It is built for files you already have locally. It does not talk to Steam, download Workshop items, or modify the copied Workshop folder.

[한국어](README.ko.md) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [Releases](https://github.com/3x-haust/workshop-wallpaper-bridge/releases)

## Demo

![Workshop Wallpaper Bridge demo](assets/workshop-wallpaper-bridge-demo.gif)

## Download

Download the latest `WorkshopWallpaperBridge-macOS-arm64.dmg` from [Releases](https://github.com/3x-haust/workshop-wallpaper-bridge/releases).

1. Open the DMG.
2. Drag **Workshop Wallpaper Bridge.app** to **Applications**.
3. Open the app. It runs as a menu bar utility, not a Dock app.

macOS may warn that the app is from an unidentified developer if the release is not notarized yet. You can still build from source with Swift.

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

- **Auto-pause behind apps** is enabled by default.
- Closing the settings window does not stop playback.
- **Open at Login** restores the last played wallpaper after login.
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
| `scene.pkg` scene wallpaper | Renders packed 2D image layers and basic keyframed motion |

Scene support is conservative. Basic image-layer scenes work, including packed `.tex` textures, LZ4 blocks, common DXT formats, and keyframed position, scale, rotation, and opacity. Particles, audio-reactive scripts, custom shaders, text layers, media integration, and video/GIF texture animation may be skipped or look different from Wallpaper Engine.

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

The app can also set a still desktop wallpaper with **Set Still Wallpaper**. For MP4, MOV, and M4V files, it extracts a frame from the video instead of using a small Workshop preview.

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
swift run wwbctl doctor
```

For signed public releases, set `SIGN_IDENTITY`, `NOTARY_PROFILE`, and `REQUIRE_SIGNING=1` before running `Scripts/package-app.sh`.

## Troubleshooting

Nothing appears on the desktop:

- Check that the imported item is marked `playable`.
- Press **Stop**, then **Play on Desktop** again.
- Temporarily turn off **Auto-pause behind apps**.
- Make sure you are viewing the desktop, not a full-screen app Space.

The wallpaper looks blurry or cropped:

- Use **Fit** to keep the full image or video visible.
- Use **Fill** to cover the screen and accept edge cropping.
- For `scene.pkg` items, check whether the scene uses unsupported particles, scripts, shaders, or animated textures.

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
