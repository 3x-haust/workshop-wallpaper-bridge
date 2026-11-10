# Workshop Wallpaper Bridge

[![Swift](https://img.shields.io/badge/Swift-6-orange.svg)](Package.swift)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey.svg)](README.md)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Downloads](https://img.shields.io/github/downloads/3x-haust/workshop-wallpaper-bridge/total.svg)](https://github.com/3x-haust/workshop-wallpaper-bridge/releases)

Use supported Wallpaper Engine Workshop content on macOS.

Workshop Wallpaper Bridge imports Wallpaper Engine Workshop projects into a private Mac library and plays supported wallpapers on the desktop layer. Copied-folder imports and local playback remain available. Steam integration covers searching and downloading App ID `431960` Workshop items through normal Steam authentication within your account's permissions. It does not modify the original copied Workshop folder.

[Website](https://3x-haust.github.io/workshop-wallpaper-bridge/) · [한국어](README.ko.md) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [Releases](https://github.com/3x-haust/workshop-wallpaper-bridge/releases) · [Support](https://www.patreon.com/c/3xhaust)

## Quick Links

- [Download](#download): install the latest DMG.
- [Use It](#use-it): import a copied Workshop folder or add local videos.
- [Steam Workshop](#steam-workshop-in-development): authenticated search/download, storage, and current verification status.
- [What Works](#what-works): check supported wallpaper types.
- [Build From Source](#build-from-source): run the app locally or package a DMG.
- [Maintainers And Contributors](#maintainers-and-contributors): project maintainers and contributors.

## Demo

![Workshop Wallpaper Bridge demo](assets/workshop-wallpaper-bridge-demo.gif)

![Playing a cube game on the Mac desktop](assets/desktop-cube-interaction.gif)

The cube is an interactive web wallpaper: dragging rotates the view and clicks turn its faces. Recorded on macOS with **Play & Interact** enabled. The recording is shared with the user’s permission; the original Workshop project is not included.

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

For locally copied Wallpaper Engine projects:

1. On Windows, locate the Workshop folder:

   ```text
   C:\Program Files (x86)\Steam\steamapps\workshop\content\431960
   ```

2. Copy the `431960` folder to your Mac.
3. Open **Workshop Wallpaper Bridge Settings** from the menu bar icon.
4. Open **My Wallpapers → Import Local Files**, click **Browse**, choose the copied `431960` folder, then click **Scan**.
5. Select a supported item and click **Import Selected**.
6. Select the imported wallpaper in **My Wallpapers** to apply it. **Play on Desktop** remains available in its details.

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
- Auto-pause and audio settings apply immediately. If playback auto-pauses because the wallpaper is covered by another app, its audio pauses too.
- **Prefer live scenes** runs supported scene scripts when the whole composition fits the native renderer. Eligible media scenes combine a rendered background with live music information; other complex scenes keep video playback. [Live playback, interaction and audio setup](docs/scenescript-compatibility.md#running-it).
- Closing the settings window does not stop playback.
- **Open at Login** restores the last played wallpaper after login.
- **Play on Desktop** does not change the macOS desktop picture, so the translucent menu bar keeps using your current system wallpaper tint.
- Use **Set Still Wallpaper** only when you explicitly want to replace the macOS desktop and Lock Screen still image.
- **Remove** asks for confirmation, then removes the Mac-library copy, its completed Workshop download, and its playback caches together, preferring the Trash. Original folders, source videos, engine assets, and Steam authentication are not removed.

The browser has **Explore**, **My Wallpapers**, and **Settings** in its sidebar. Completed wallpapers are managed in **My Wallpapers**; there is no separate Downloads tab. Explore and the local library use thumbnail grids with a large selected-item preview and details. Smaller windows open details in a sheet. The existing local import, display mode, playback, rotation and removal controls remain available; **Convert Video** and **Set Still Wallpaper** are available from item details and the library's context menu. Settings retains playback, Audio, Scene Engine Assets, Screen Saver, and Language controls. See [the browser design guide](DESIGN.md).

Use the **Language** picker in the Settings tab to switch the app's UI text between **System**, **한국어**, **简体中文**, and **English**. The change applies immediately, without restarting the app; only static UI chrome (buttons, section titles, captions) is localized, so status messages generated while the app runs may still appear in English. When Language is set to **System**, Korean and Simplified Chinese macOS preferences use those bundled translations; other system languages fall back to English.

Library rotation:

- Turn on **Rotate Library** to automatically cycle through every playable wallpaper in your Mac library on a timer.
- **Shuffle** randomizes the order, **Rotate Every** sets the interval (30s, 1m, 5m, 15m, 30m, 1h), and **Next** jumps to the next wallpaper immediately.
- Rotation is available in both the settings window and the menu bar menu. The on/off state, shuffle, and interval are remembered across launches and resume after login.
- **Play on Desktop** or **Stop** turns rotation off so manual selection always wins. Non-playable items are skipped automatically.

Imported files are stored in:

```text
~/Library/Application Support/WorkshopWallpaperBridge
```

### Steam Workshop (In Development)

Steam integration is in development; the packaged login-to-playback flow is not yet verified, and inclusion in the latest public release is not implied.

1. Open **Explore** and use the Steam account control to sign in with a QR code or your Steam account and Steam Guard. Access is limited to what that account is authorized to retrieve for Wallpaper Engine (App ID `431960`).
2. Browse thumbnails, search, and sort by popularity, date or rating. **Filters** includes age rating, type, genre, resolution, and features such as Approved and Audio responsive. Each tag can be included, excluded, or left unrestricted. The default requires Everyone and excludes Questionable and Mature; resetting restores this default. Settings are remembered across launches. Tags can be inaccurate; Steam Community content preferences remain separate. Use the numbered page buttons to jump between results; the current page is highlighted, and a successful page change returns the list to the top. Select an item for its preview and details. Compatibility notes are available in the preview help; support badges and issues remain visible.
3. Choose **Download & Apply** and follow its progress. You can cancel or retry; cancelling a download disconnects Steam. Reconnect with saved authentication before retrying.
4. Explicit completion and storage validation are required before a project enters **My Wallpapers**. Partial or cancelled downloads are not completed items.
5. **Download & Apply** includes library import and any required scene rendering before application. Fresh rendered caches are reused on subsequent applications. Preparation progress, errors, cancellation, and retry remain visible in Explore, including the detail sheet in narrow windows, rather than a separate window-wide status bar. Use **Stop Playback** in the menu bar menu to stop the wallpaper. A scene-rendering failure is reported separately from a download failure; the saved library copy and previous wallpaper are retained. Cancelling preparation prevents application; an already-running shared renderer may finish caching, and deletion stays unavailable until it finishes. If that item ID already exists, the app links/selects the existing library copy rather than overwriting it.
6. Selecting a supported installed item applies it directly. Unsupported items remain available for inspection; use **My Wallpapers** for additional conversion. Preparing a replacement preserves the previous wallpaper until the new content is ready. The support limits below still apply.

**Download success is not playback success.** Unsupported formats, scene features, or missing engine assets can still prevent playback or leave a preview visible. This integration does not promise official Wallpaper Engine compatibility or expand the scene support boundary.

Downloads are stored separately from imported library copies:

```text
~/Library/Application Support/WorkshopWallpaperBridge/WorkshopDownloads
```

#### Saved Authentication And Logout

Authentication persists across app launches in an app-specific file:

```text
~/Library/Application Support/WorkshopWallpaperBridge/Steam/credentials.json
```

- The `Steam` directory uses mode `0700`; the credential file uses `0600`. This is persistent file storage, **not Keychain**. Treat the file and backups as secrets; permissions do not protect it from other processes running as your user.
- The app reconnects automatically using saved authentication on launch. Expired or revoked sessions require signing in again.
- **Logout** ends the helper session and disables automatic reconnection, but keeps saved authentication. Choosing **Reconnect** or signing in enables automatic connection again.
- **Delete saved authentication** removes only `credentials.json` and its interrupted atomic-save temporary file `credentials.json.tmp` from this app's `Steam` directory. It does not affect authentication or sessions in the Steam app or other Steam clients, or revoke tokens on Steam's servers.
- Do not include credentials, QR login payloads, tokens, or Steam Guard codes in reports or logs. See [Security](SECURITY.md).

The Steam helper is a separate GPL component based on [SteamRE/DepotDownloader 3.4.0](https://github.com/SteamRE/DepotDownloader/tree/DepotDownloader_3.4.0), using SteamKit as a normal authenticated client. Steam-enabled app packages are intended to bundle a self-contained macOS arm64 helper; users do not need to install .NET or run CLI commands for this integration.

## What Works

| Project type | Support |
| --- | --- |
| `.mp4`, `.mov`, `.m4v` video | Plays directly; HEVC `hev1` files are losslessly repackaged to a cached `hvc1` copy for macOS |
| `.webm`, `.mkv`, `.avi` video | Converts locally with `ffmpeg`, then plays |
| `index.html` web wallpaper | Local WebView with mouse interaction, WebGL, initial user settings and system-audio callbacks |
| `.jpg`, `.png`, `.gif`, `.heic` image | Displays as a static desktop layer |
| `scene.pkg` scene wallpaper | Complete basic image/text scenes can run supported scripts live. Eligible media scenes add live layers over a rendered background. Other complex scenes use video; a compatible video or preview remains visible while rendering. |

Scene support is conservative. Live playback supports the SceneScript interfaces described in [Live SceneScript playback](docs/scenescript-compatibility.md); it does not provide full Windows engine compatibility. Advanced scenes can look different in the native renderer.

Choose **Play & Interact** to play scene/web content with mouse and keyboard input. The interaction choice is remembered across launches; turn it off in the menu bar to access desktop icons. Web animations keep running when the desktop window is inactive, including cube startup sequences and element expansion. Online information requested by a click can be opened with **Open … in browser**; remote resources remain blocked inside the wallpaper. **React to system audio** enables local analysis after macOS capture permission and is independent of **Play wallpaper audio**. **Show music information** reads the current track, artwork and timeline from an already-running Music or Spotify app with macOS Automation permission. Spotify artwork is fetched from its HTTPS image service. See the [compatibility guide](docs/scenescript-compatibility.md) for setup and authored examples.

### How scene playback works

- System-audio permission is checked before capture starts. When access is missing, **Allow access…** appears in Settings; already-granted access hides it. Permission changes are picked up automatically, and playback does not repeatedly request access.
- With **Prefer live scenes** on, basic image/text scenes run supported property bindings live only after the entire composition passes structural checks and texture decoding. Effects, particles, models, parented layers, custom materials, bloom, unsupported bindings, and missing or over-budget layers retain the video path. This prevents a partial native scene from replacing a full rendered scene.
- An audited media overlay path runs song information, clocks, artwork transitions and day/night layers over a background rendered at the original canvas ratio. Original package shaders now drive artwork blends, glitch, CRT and pixelate passes, including live compose layers. It remains experimental; Windows visual/timing parity is unverified. [Evidence and limits](docs/scenescript-compatibility.md#summer-in-the-city).
- For other scenes, the first play renders the scene offscreen (no renderer window is ever shown) into a cached, looping mp4, using a bundled/configured external GPL scene renderer plus `ffmpeg`.
- When the renderer supports it, frames stream directly into the encoder with no intermediate PNG files, making the first render noticeably faster; older renderer builds fall back to record-then-encode automatically.
- The cached clip is 20 seconds long, and the encode crossfades its last ~1.2 seconds into its first ~1.2 seconds, so the loop seam is blended away rather than just made less frequent.
- Authored sound layers (background music, ambience) are extracted from `scene.pkg` and mixed into the cached video as a looping audio track. Audio is muted by default (turn on **Play wallpaper audio** to hear it) and, unlike the video, is not crossfaded at the seam, so a subtle audio seam may be audible. A failed extraction still produces a silent video rather than failing the render.
- During rendering, the app keeps a source-fresh v6 video if available (v7 changed audio duration, not pictures), otherwise the project preview. v6 audio may loop sooner until the v7 render completes. Older visual cache versions are not reused. Renderer capability probing and recording waits have time limits.
- The status line shows live "Rendering scene to video… N%" progress while the first render is in flight.
- Video playback is a fixed loop and cannot respond to live inputs. The basic live and media overlay paths run scripts; shader-only audio effects are not implemented by the script bridge.
- Once cached, playback uses the normal video-wallpaper path: gapless `AVPlayerLooper` looping, always aspect-fill regardless of the app's fit/fill/stretch setting, and reuse by the bundled screen saver (see Screen Saver below).

`wwbctl attach-scene-video <asset-id> <video-file>` only stores a local reference cache for diagnostics/comparison and is unrelated to the automatic render-to-video cache.

The render-to-video path requires the bundled renderer subprocess, its Homebrew runtime libraries (`brew install lz4 sdl2 ffmpeg glfw glew mpv freetype`), and the Wallpaper Engine runtime `assets` folder (copied by the user from their own Windows installation — Workshop Wallpaper Bridge does not download or ship these files):

- In the app: **Scene Engine Assets** -> **Choose Assets Folder...**, then select the copied `steamapps/common/wallpaper_engine/assets` contents folder.
- For CLI/dev launches, `WWB_SCENE_ENGINE_ASSETS_DIR=/path/to/assets` overrides the app setting; otherwise the app checks `~/Library/Application Support/WorkshopWallpaperBridge/wallpaper-engine-assets`.
- If rendering components are unavailable, the app uses a compatible cached video, a complete basic native scene, or the project preview, in that order.
- Cached scene videos live under `~/Library/Application Support/WorkshopWallpaperBridge/SceneVideoCache/` and are rebuilt automatically when the source `scene.pkg` changes.
- Authenticated Workshop downloads do not supply Wallpaper Engine runtime assets. This project does not redistribute creator assets or bundle Steam content; a renderer binary is a separate component with its own GPL source notice.

### Native fallback renderer

Used for supported live scenes and basic scenes without rendering components. The decode budget remains 24 image/text layers; a plan with missing or excess layers keeps the preview instead of displaying a partial composite. Once complete layers are ready, the loading thumbnail is removed so it cannot show through transparent areas.

Supports:

- Packed `.tex` textures: LZ4 blocks and common DXT formats.
- Text layers and live property-bound SceneScript in a separate, time-limited JavaScriptCore worker. Supported bindings include time, cursor input, audio buffers, common vectors and layer access; see the [interface and limits table](docs/scenescript-compatibility.md#implemented-interfaces).
- Keyframed position, scale, rotation, and opacity, with mirror-mode keyframe animations playing as ping-pong loops.
- Animated sprite-sheet (`texgif`) textures, decoded from the RePKG-documented `TEXS0001`-`TEXS0003` frame containers (including rotated sheet packing and per-frame timing) and played as Core Animation frame sequences.
- Puppet-warp models (`MDLV0013` skeletons — the format Wallpaper Engine uses for bending fish and characters): mesh, bones, and mirror-mode bone animations, played with CPU skinning so puppet bodies flex instead of gliding rigidly.
- Shader effects ported directly from the scene's packed GLSL to Core Image: `spin`, `shake`, `waterripple`, `waterwaves`, `waterflow`, `scroll` — including flow-map-driven shake so only fins and tails move, and full-canvas compose-layer warps (e.g. a scene-wide `waterripple`) distributed onto the layers beneath them so keyframed motion stays live.
- Approximated particle and glint effects: simple sprite/pulse-ring particle systems via Core Animation emitters, and `nitro`-style glints as a noise-driven twinkle pass.

Still skipped or approximate: complex particle operators, masked effect composition, non-scalar effect-property scripts, full 3D/model and animation APIs, shader pipelines outside the supported full-quad passes, media from apps other than Music/Spotify, sound-layer control, and embedded MP4 video textures — these may look different from Wallpaper Engine until the native scene engine implements them. The package analyzer preserves scene runtime requirements (effect/shader files, shader uniforms, SceneScript, particles, sound layers, audio-analysis inputs, video textures) so this parity work can be targeted.

Workshop preview files such as `preview.jpg`, `thumbnail.jpg`, and `cover.png` are loading and fallback images. The app reads `scene.pkg` for playback and retains the preview when it cannot safely display the scene or while an uncached scene is rendering.

## Screen Saver

Turn on **Animate Screen Saver** to install and select the bundled macOS screen saver for the current Mac host.

What animates in the screen saver:

- MP4, MOV, and M4V wallpapers from the Mac library.
- Local videos added with **Add Video File**.
- Scene wallpapers, once they have a cached render-to-video (see What Works above): the screen saver reuses that same cached mp4, upgrading from the still preview automatically as soon as the background render finishes — no need to play it again first.

What uses a still fallback:

- WebM, MKV, and AVI before conversion.
- Web wallpapers.
- Scene wallpapers without a video cache, including new live script scenes. The screen saver does not execute SceneScript.

macOS still controls when the screen saver starts. Configure the start time and password timing in System Settings > Lock Screen. Until macOS starts the selected screen saver, the normal static Lock Screen wallpaper is shown.

The app can also set a still desktop wallpaper explicitly with **Set Still Wallpaper**. For MP4, MOV, and M4V files, it extracts a frame from the video instead of using a small Workshop preview. **Play on Desktop** intentionally leaves the macOS desktop picture alone; this avoids surprising menu bar tint changes while animated playback is running.

## Build From Source

Requirements:

- macOS 14 or newer
- Xcode command line tools
- Swift 6 toolchain
- .NET 9 SDK to build the separate Steam helper (`net9.0`)
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

For the Steam-enabled package, build the separate helper before packaging:

```bash
bash Scripts/build-steam-helper.sh
bash Scripts/package-app.sh
```

`Scripts/build-steam-helper.sh` targets a self-contained macOS arm64 helper based on SteamRE/DepotDownloader 3.4.0; `Scripts/package-app.sh` integrates it into the app bundle. Distribute its GPL license and corresponding-source notices with the helper. .NET is a developer build prerequisite, not a consumer runtime installation requirement.

Local packages include the external GPL scene renderer:

- `Scripts/package-app.sh` builds the pinned public renderer source with `Scripts/build-scene-renderer.sh` when no renderer is available, and stops if the build fails. The renderer's build and runtime dependencies listed above must be installed. Release CI builds it before packaging.
- To use an existing build, set `SCENE_RENDERER_BINARY=/path/to/wwb-scene-renderer`, or place the executable at `ExternalRenderers/wwb-scene-renderer`.
- The package script copies the renderer and its local libraries into app resources, and writes `Renderer Notices/GPL Scene Renderer Notice.txt` with the source link and the pinned source ref from [Scripts/scene-renderer.env](Scripts/scene-renderer.env) for [3x-haust/wallpaperengine-mac-renderer](https://github.com/3x-haust/wallpaperengine-mac-renderer) (a macOS port of [Almamu/linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine)).
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

Workshop Wallpaper Bridge keeps wallpaper playback and the imported library local, with optional authenticated Steam Workshop access.

- Search/download is restricted to Wallpaper Engine (App ID `431960`) and the signed-in account's permissions.
- It does not bypass Steam authentication, account entitlements, or DRM.
- It does not emulate or impersonate Steam protocols. Normal authenticated SteamKit client use in the separate helper is permitted and is distinct from prohibited protocol emulation.
- It does not claim full `scene.pkg` runtime or official Wallpaper Engine compatibility. Downloading an item does not prove it can play.
- It does not upload, share, or redistribute creator assets.
- It does not modify the original copied Workshop folder.
- It does not download or bundle Wallpaper Engine runtime `assets`; users supply their own as described above.

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
- <a href="https://github.com/cl1107"><img src="https://avatars.githubusercontent.com/u/21985353?v=4&s=72" width="36" height="36" alt="@cl1107"></a> [@cl1107](https://github.com/cl1107)
- <a href="https://github.com/lotgood"><img src="https://avatars.githubusercontent.com/u/31810171?v=4&s=72" width="36" height="36" alt="@lotgood"></a> [@lotgood](https://github.com/lotgood)
- <a href="https://github.com/ohjack83-lab"><img src="https://avatars.githubusercontent.com/u/263676419?v=4&s=72" width="36" height="36" alt="@ohjack83-lab"></a> [ohjack83](https://github.com/ohjack83-lab) `@ohjack83-lab`
<!-- profile-roster:end -->

## License

The main application is MIT licensed. The separate Steam helper is based on [SteamRE/DepotDownloader 3.4.0](https://github.com/SteamRE/DepotDownloader/tree/DepotDownloader_3.4.0) and carries its [GPL license](https://github.com/SteamRE/DepotDownloader/blob/DepotDownloader_3.4.0/LICENSE), not the application's MIT license. The optional external scene renderer also has its own GPL license/source notices. Distributions must retain the applicable licenses and provide corresponding source for the GPL components, including modifications.
