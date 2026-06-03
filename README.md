# Workshop Wallpaper Bridge

[![Swift](https://img.shields.io/badge/Swift-6-orange.svg)](Package.swift)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey.svg)](README.md)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Use your own Wallpaper Engine Workshop projects on macOS.

Workshop Wallpaper Bridge is for people who already bought Wallpaper Engine on Windows and copied their local Workshop folder to a Mac. It scans that copied folder, imports supported wallpapers into a private Mac library, and plays video, web, image, and supported scene wallpapers on the desktop layer.

[한국어 README](README.ko.md) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md)

## Demo

![Workshop Wallpaper Bridge demo](assets/workshop-wallpaper-bridge-demo.gif)

## Highlights

- Imports local copies of Wallpaper Engine Workshop projects into a private Mac library.
- Plays MP4, MOV, M4V, restricted local web wallpapers, images, and supported `scene.pkg` projects on the desktop layer.
- Converts WebM, MKV, and AVI files locally with `ffmpeg`.
- Can install a bundled macOS screen saver that animates while the Mac is locked.
- Keeps original copied Workshop folders untouched.
- Ships a CLI, `wwbctl`, for scanning, importing, conversion, and scene diagnostics.

## Project Status

This is an early compatibility project. Video and image wallpapers are the most reliable paths. Scene support is intentionally conservative and currently focuses on packed 2D image layers, common texture formats, and basic keyframed motion.

Workshop Wallpaper Bridge is not affiliated with Valve, Steam, or Wallpaper Engine. It does not download Workshop items, bypass Steam authentication, bypass DRM, or redistribute creator assets.

## Quick Start

1. On Windows, find your Wallpaper Engine Workshop folder:

   ```text
   C:\Program Files (x86)\Steam\steamapps\workshop\content\431960
   ```

2. Copy the `431960` folder to your Mac.
3. Download `WorkshopWallpaperBridge-macOS-arm64.dmg` from the latest GitHub release.
4. Open the DMG, drag **Workshop Wallpaper Bridge.app** to **Applications**, then open it.
5. Click the menu bar icon, then choose **Open Settings**.
6. For Wallpaper Engine projects, click **Browse**, choose the copied `431960` folder, then click **Scan**.
7. Select a supported project and click **Import Selected**.
8. For your own video, click **Add Video File** instead.
9. Select the imported project or video and click **Play on Desktop**.
10. Choose **Display**:
    - **Fit** keeps the full wallpaper visible and may show letterboxing.
    - **Fill** covers the screen like Wallpaper Engine's cover-style modes and may crop the edges.
    - **Stretch** fills the screen exactly and may distort the image.
11. Use **Remove** to delete an imported item from the Mac library without touching the original copied folder or video.

The app runs as a menu bar utility. It does not stay in the Dock or app switcher, and the settings window can be closed while animated wallpapers continue running on the desktop layer.

To animate while the Mac is locked, turn on **Animate Screen Saver**, click **Screen Saver Settings**, and select **Workshop Wallpaper Bridge** in System Settings > Wallpaper > Screen Saver. The button installs the bundled screen saver before opening System Settings. macOS does not expose a public way to replace the login/Lock Screen wallpaper itself with live video; this app uses the screen saver system. MP4, MOV, and M4V wallpapers animate after the selected screen saver starts. Other wallpaper types use a still fallback image.

## Playback Behavior

- **Auto-pause behind apps** is enabled by default.
- Minimizing or hiding the Workshop Wallpaper Bridge control window does not stop playback.
- Closing the settings window does not quit the app. Use **Quit** from the menu bar icon when you want to fully stop the background utility.
- When another app covers the desktop, video playback pauses while the wallpaper layer stays in place.
- When you return to the desktop, playback resumes automatically.
- After sleep/wake or monitor changes, the app recreates the wallpaper windows and resumes the selected wallpaper.
- You can disable auto-pause from the menu bar icon or the settings window if you want continuous playback.
- Turn on **Open at Login** if you want the menu bar utility to start automatically after logging in. The last played wallpaper is restored on app launch unless you press **Stop Playback** first.
- Use **Remove** in the imported library list to delete copied Mac-library files you no longer want.

## Performance Snapshot

Measured on an Apple M2 Mac running macOS 26.2 with a local MP4 wallpaper:

- Launch-to-process average: 69.8 ms across 5 cold opens.
- Playback sample: 2.35% average CPU and 107.1 MB average RSS over 20 seconds.
- Video still-frame extraction: 231.7 ms average across 5 runs.
- Current local library scan: 466 ms.

## Screen Saver And Still Wallpaper

Workshop Wallpaper Bridge supports animation while locked through a bundled macOS screen saver. Apple exposes a public `ScreenSaverView` framework for custom screen savers, and macOS can start the selected screen saver when the Mac is inactive or locked.

Important: macOS still requires you to choose **Workshop Wallpaper Bridge** in Screen Saver settings. The app can install and configure its bundled screen saver, but it does not force-change the system-selected screen saver.

If the Mac still shows your existing static Lock Screen wallpaper, check the Lock Screen timing in System Settings. macOS shows the normal login/Lock Screen wallpaper until the selected screen saver starts. Closing and reopening a Mac usually shows that static system Lock Screen first; live motion begins only when macOS starts the selected screen saver.

What the app can animate:

- MP4, MOV, and M4V video wallpapers selected in your Mac library.
- Your own videos added with **Add Video File**.

What uses a still fallback:

- WebM, MKV, and AVI until you convert them to MP4.
- Web wallpapers.
- Scene wallpapers. Desktop scene playback renders supported 2D image layers, but the screen saver uses a still fallback for scene projects.

How to enable it:

1. Open **Workshop Wallpaper Bridge Settings**.
2. Turn on **Animate Screen Saver**.
3. Click **Screen Saver Settings**. This installs or refreshes the bundled `.saver` in `~/Library/Screen Savers` and opens System Settings > Wallpaper.
4. Choose **Workshop Wallpaper Bridge** as the macOS screen saver.
5. In macOS Lock Screen settings, set when the screen saver starts and when a password is required.

This app does not patch Apple's Aerial wallpaper database or use private Lock Screen wallpaper databases.

What the app can do safely:

- Set a still image as the macOS desktop wallpaper.
- For MP4, MOV, and M4V video wallpapers, extract a still frame from the video instead of using a tiny Workshop preview GIF.
- Write the same still image to the current user's macOS Lock Screen cache when that cache is available.

Use **Set Still Wallpaper** on an imported project. Direct-play video projects use a generated frame from the video file; WebM, MKV, and AVI projects must be converted first. Image and scene projects use a still preview when one exists. If macOS has already cached a Lock Screen image, the visible Lock Screen may update after locking, logging out, or the next wallpaper refresh.

## Supported Projects

| Project type | Support |
| --- | --- |
| `.mp4`, `.mov`, `.m4v` video | Plays directly |
| `.webm`, `.mkv`, `.avi` video | Convert with local `ffmpeg`, then play |
| `index.html` web wallpaper | Plays locally in a restricted WebView |
| `.jpg`, `.png`, `.gif`, `.heic` image | Displays as a static desktop layer |
| `scene.pkg` scene wallpaper | Renders packed 2D image layers and basic keyframed motion |

You can also add your own local video with **Add Video File**. MP4, MOV, and M4V play directly. WebM, MKV, and AVI are imported first, then converted locally with `ffmpeg`.

Workshop preview files such as `preview.jpg`, `thumbnail.jpg`, or `cover.png` are treated as thumbnails, not as the real wallpaper content. If a Workshop project contains `scene.pkg`, the app reads the packed scene data and renders supported 2D image layers instead of stretching the low-resolution preview across your screen.

Scene support is intentionally conservative. Basic image-layer scenes work locally, including packed `.tex` textures, LZ4 blocks, common DXT formats, and keyframed position, scale, rotation, and opacity. Advanced Wallpaper Engine runtime features such as particles, audio-reactive scripts, custom shaders, text layers, media integration, and video/GIF texture animation may be skipped or look different.

## What This App Will Not Do

Workshop Wallpaper Bridge is local-only.

- It does not download Steam Workshop items.
- It does not bypass Steam authentication.
- It does not bypass DRM.
- It does not emulate Steam protocols.
- It does not claim full `scene.pkg` runtime compatibility.
- It does not upload, share, or redistribute creator assets.
- It does not modify your original copied Workshop folder.

Imported files are copied into:

```text
~/Library/Application Support/WorkshopWallpaperBridge
```

## Install From Source

Requirements:

- macOS 14 or newer
- Xcode command line tools
- Swift 6 toolchain
- Optional: `ffmpeg` for WebM/MKV/AVI conversion

```bash
git clone https://github.com/3x-haust/workshop-wallpaper-bridge.git
cd workshop-wallpaper-bridge
swift run WorkshopWallpaperBridge
```

Install `ffmpeg`:

```bash
brew install ffmpeg
```

## Build A Local App Bundle

```bash
bash Scripts/package-app.sh
open "dist/Workshop Wallpaper Bridge.app"
```

The script creates:

```text
dist/WorkshopWallpaperBridge-macOS-arm64.dmg
```

## Developer ID Signing And Notarization

Unsigned local builds are useful for development, but public GitHub releases should use Apple Developer ID signing and notarization so users do not see the unidentified-developer warning.

Prerequisites:

- Apple Developer Program membership
- A `Developer ID Application` certificate installed in Keychain
- A saved notary profile, for example:

```bash
xcrun notarytool store-credentials "wwb-notary" \
  --apple-id "APPLE_ID_EMAIL" \
  --team-id "TEAM_ID" \
  --password "APP_SPECIFIC_PASSWORD"
```

Build, sign, notarize, and staple the DMG:

```bash
SIGN_IDENTITY="Developer ID Application: NAME (TEAM_ID)" \
NOTARY_PROFILE="wwb-notary" \
REQUIRE_SIGNING=1 \
bash Scripts/package-app.sh
```

The script signs the bundled executables, signs the app, creates the DMG, signs the DMG, submits it with `notarytool`, staples the accepted ticket, and verifies the final DMG with `spctl`.

## CLI

`wwbctl` is included for advanced users and testing.

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

Use `scene-info` first when a scene looks static. It reports animation, particle, effect, and shader counts without decoding large textures. `scene-render-info` decodes supported textures and can take longer on high-resolution scene packages.

## Troubleshooting

If nothing appears on the desktop:

- Check that the imported project is marked `playable`.
- Press **Stop**, then **Play on Desktop** again.
- Temporarily turn off **Auto-pause behind apps**.
- Make sure you are looking at the desktop, not a full-screen app Space.

If the wallpaper looks blurry or cropped:

- Choose **Fit** to keep the full image/video visible.
- Choose **Fill** if you want the screen fully covered and accept edge cropping.
- Check whether the Workshop item is a `scene.pkg` project with unsupported effects. Scene projects render supported image layers and basic keyframed layer motion, while particles, scripts, custom shader effects, and animated texture features may differ from Wallpaper Engine.

If WebM/MKV/AVI conversion fails:

```bash
brew install ffmpeg
```

If macOS warns that the app is from an unidentified developer, that means the release is not notarized yet. You can still build from source with Swift.

If **Workshop Wallpaper Bridge** does not appear in Screen Saver settings:

- Open the app from the packaged `.app`, not only `swift run`.
- Turn on **Animate Screen Saver** once, then click **Screen Saver Settings**.
- Check that `~/Library/Screen Savers/Workshop Wallpaper Bridge.saver` exists.
- Quit and reopen System Settings if macOS does not refresh the list immediately.

If the preview is black, restart System Settings after installing the latest app. The app now writes a still fallback image for the screen saver and removes macOS quarantine metadata from imported media before the screen saver reads it.

## Relationship To Wallpaper Engine

This project is not affiliated with Valve, Steam, or Wallpaper Engine. Wallpaper Engine is a trademark of its respective owner. Workshop Wallpaper Bridge is a compatibility tool for personal local use with files you already have lawful access to.

## License

MIT
