# Workshop Wallpaper Bridge

Use your own Wallpaper Engine Workshop projects on macOS.

Workshop Wallpaper Bridge is for people who already bought Wallpaper Engine on Windows and copied their local Workshop folder to a Mac. It scans that copied folder, imports supported wallpapers into a private Mac library, and plays video, web, and image wallpapers on the desktop layer.

[한국어 README](README.ko.md)

## Quick Start

1. On Windows, find your Wallpaper Engine Workshop folder:

   ```text
   C:\Program Files (x86)\Steam\steamapps\workshop\content\431960
   ```

2. Copy the `431960` folder to your Mac.
3. Download `WorkshopWallpaperBridge-macOS-arm64.zip` from the latest GitHub release.
4. Unzip it and open **Workshop Wallpaper Bridge.app**.
5. Click **Browse**, choose the copied `431960` folder, then click **Scan**.
6. Select a supported project and click **Import Selected**.
7. Select the imported project and click **Play on Desktop**.

The app process must stay open while animated wallpapers are running. You can minimize or hide the control window; playback continues on the desktop layer.

## Playback Behavior

- **Auto-pause behind apps** is enabled by default.
- Minimizing or hiding the Workshop Wallpaper Bridge control window does not stop playback.
- When another app covers the desktop, video playback pauses and the wallpaper window hides.
- When you return to the desktop, playback resumes automatically.
- After sleep/wake or monitor changes, the app recreates the wallpaper windows and resumes the selected wallpaper.
- You can disable auto-pause in the app header if you want continuous playback.

## Lock Screen And Still Wallpaper

macOS does not provide a stable public API for third-party animated Lock Screen wallpapers. This app does not use private APIs or patch system wallpaper databases.

What the app can do safely:

- Set a still preview image as the macOS desktop wallpaper.
- Let macOS use that still image for the Lock Screen when your system settings mirror the desktop wallpaper.

Use **Set Still Wallpaper** on an imported project. Video projects need a `preview.jpg`, `preview.png`, or similar thumbnail in the Workshop project folder.

## Supported Projects

| Project type | Support |
| --- | --- |
| `.mp4`, `.mov`, `.m4v` video | Plays directly |
| `.webm`, `.mkv`, `.avi` video | Convert with local `ffmpeg`, then play |
| `index.html` web wallpaper | Plays locally in a restricted WebView |
| `.jpg`, `.png`, `.gif`, `.heic` image | Displays as a static desktop layer |
| `scene.pkg` scene wallpaper | Detected only; not unpacked or converted |

## What This App Will Not Do

Workshop Wallpaper Bridge is local-only.

- It does not download Steam Workshop items.
- It does not bypass Steam authentication.
- It does not bypass DRM.
- It does not emulate Steam protocols.
- It does not unpack or reverse engineer `scene.pkg`.
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
dist/WorkshopWallpaperBridge-macOS-arm64.zip
```

## CLI

`wwbctl` is included for advanced users and testing.

```bash
swift run wwbctl scan "/path/to/431960" --out index.json
swift run wwbctl import "/path/to/431960"
swift run wwbctl convert input.webm --out output.mp4
swift run wwbctl doctor
```

## Troubleshooting

If nothing appears on the desktop:

- Check that the imported project is marked `playable`.
- Press **Stop**, then **Play on Desktop** again.
- Temporarily turn off **Auto-pause behind apps**.
- Make sure you are looking at the desktop, not a full-screen app Space.

If WebM/MKV/AVI conversion fails:

```bash
brew install ffmpeg
```

If macOS warns that the app is from an unidentified developer, that means the release is not notarized yet. You can still build from source with Swift.

## Relationship To Wallpaper Engine

This project is not affiliated with Valve, Steam, or Wallpaper Engine. Wallpaper Engine is a trademark of its respective owner. Workshop Wallpaper Bridge is a compatibility tool for personal local use with files you already have lawful access to.

## License

MIT
