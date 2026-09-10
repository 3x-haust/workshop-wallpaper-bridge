# Live SceneScript playback

The `feat/live-scenescript-runtime` development branch adds a local SceneScript runtime and experimental media overlays. It is not a complete implementation of the Windows engine. Successful script execution does not establish visual or timing parity.

## Running it

Run these commands from the repository root. Build with `bash Scripts/package-app.sh`, open `dist/Workshop Wallpaper Bridge.app`, and import a local scene or web project through the Library tab.

- **Prefer live scenes** runs basic image/text scenes only when the entire composition passes structural and decoding checks. Eligible media scenes use a rendered background with live layers. Other complex scenes use a compatible cached video or render one; if neither is available, the preview remains. Turning this option off selects that same video/fallback path.
- **Play & Interact** enables mouse and keyboard input for scene/web wallpapers. The choice survives relaunch. It places the wallpaper above desktop icons; turn interaction off in the menu bar to access the icons. Passive cursor tracking also works without interaction mode.
- **React to system audio** analyzes Mac output through ScreenCaptureKit after macOS capture permission. It does not use the microphone, save recordings or transmit audio. Capture stops when disabled or when all participating wallpapers close or pause. This is separate from **Play wallpaper audio**.
- **Show music information** reads an already-running Music or Spotify app. Allow the requested macOS Automation access. It supplies song information, playback state, elapsed time and artwork. Music artwork stays local; Spotify artwork is fetched only from its HTTPS image service, with redirects and an 8 MiB size limit. Other media apps and browser players are not integrated.
- Web animations continue while the desktop window is inactive. A trusted click requesting an online document presents **Open … in browser**. That button opens the document in the default browser; remote resources remain blocked inside the wallpaper.
- The screen saver uses static images or existing whole-scene video caches. It does not execute live scripts or media overlays.

For denied audio permission, open **System Settings → Privacy & Security → Screen & System Audio Recording** (or **Screen Recording** on older macOS versions), enable the app, and restart if macOS requests it. Permission is controlled by macOS; the bridge does not reset or bypass it. Audio capture on the current test Mac was denied, so actual system-audio response is not yet verified there.

Local development bundles are ad-hoc signed with a build-specific code hash. Replacing the app can require macOS permission again, even if its older entry still appears enabled. Reauthorize the final installed build in System Settings; any Touch ID or password request must be completed by the user.

Scene video generation requires the renderer, its Homebrew libraries, and the user's copied Wallpaper Engine `assets` directory:

```bash
brew install lz4 sdl2 ffmpeg glfw glew mpv freetype
```

Select the copied assets directory in **Scene Engine Assets → Choose Assets Folder…**. Web and ordinary AVFoundation video playback do not need these renderer libraries. Local renderer builds use the host's Homebrew libraries; building with a macOS 14 deployment target does not establish that those libraries run on macOS 14.

Our examples contain no Workshop assets. Run `python3 Scripts/build-live-scene-example.py`, then scan `.tmp/live-examples` for **Live SceneScript demo**. Scan `Examples` for **Live interaction demo**. Use **Scan**, select the discovered project and import it. Check the clock, cursor marker/counter or cube, and pause/resume. With capture permission, audio bars should react to another app’s audio; when capture is unavailable they stay flat. That live-capture check is pending on the test Mac. Stopping and replaying starts a new script session.

## Implemented interfaces

| Surface | Behavior |
| --- | --- |
| JavaScript | Persistent globals, functions, loops, arrays, typed arrays, closures and standard math/date/string operations. Declaration exports and named/namespace imports from supported built-in modules. Arbitrary module loading is not implemented. |
| Layer properties | `origin`, `scale`, `angles`, `alpha`, `visible`, `text`, `color`. Scalar returns on vector bindings expand to vectors. Undefined/null returns preserve the current property. |
| Lifecycle | One `init(value)` per binding, then `update(value)` on accepted frames. While a request is outstanding, new frames are skipped and elapsed time accumulates for the next request. Each binding owns its globals; `shared` belongs to the scene. Startup settings, resize, media, cursor and timer events are dispatched. Closing terminates the worker; it does not run `destroy()`. |
| Layer access | `thisLayer`, `thisProperty`, `thisScene.getLayer`, `getLayerByID`, `getLayerCount`, `enumerateLayers`, hidden/helper objects and project defaults. |
| Effect objects | Separate `thisObject` targets for effect visibility and scalar shader constants. Bound scalar animations expose `play`, `pause`, `stop`, `isPlaying`, single/loop/mirror modes and Bezier keyframes. This is not the full animation/bone API. |
| Text measurement | Packed fonts remain in memory. `thisLayer.size` measures the current string synchronously, including a string assigned earlier in the same script call. The same calibrated font is used for display; the authored `maxwidth` is exposed for overflow/scrolling decisions. |
| Time | `engine.runtime`, `frametime`, `timeOfDay`, `Date`, canvas size and physical screen resolution. Runtime and timers pause; wall-clock time catches up on resume. |
| Vectors/modules | Common `Vec2`/`Vec3`/`Vec4` operations and `WEMath`, `WEVector`, `WEColor`. Full matrix/model interfaces are absent. |
| Cursor | World/screen coordinates, left-button state, enter/leave/move/down/up/click hooks. Transformed 2D bounds determine hits. Short clicks remain queued while a worker request is in flight. |
| Audio | Persistent `engine.registerAudioBuffers` arrays at 16/32/64 bands. Web listeners receive 128 values: 64 left, then 64 right. FFT band gain has not been calibrated against Windows. |
| Media | Status, properties, playback, timeline and thumbnail events. Timeline duration is whole seconds to avoid fractional tails in authored minute/second formatters. Current/previous artwork is bound to the original package blend and gradient-wipe shaders. |
| Web | Local HTML/JavaScript/WebGL, native input, background animation frames, audio callbacks and initial project property defaults. Remote HTTP(S) resources remain blocked inside the wallpaper. |

GPU passes run serially on a separate actor so shader work does not block script updates. There is at most one pending effect sequence per view; pause, close and artwork replacement discard stale results. Effect layers retain their processed image while the next render is pending, so animation ticks cannot flash unprocessed frames. Shader passes are compiled from local package files and bounded includes from the selected engine-assets directory. Only full-quad GLSL passes with supported uniforms, textures and buffer bindings are accepted. This is not the full material, model or shader API. If a shader fails, the view reports the error, clears compose surfaces and falls back to unprocessed image/animation/artwork layers until playback restarts.

The Library status line shows rendering progress and script errors. There is no permanent playback-mode badge yet. Developers can inspect `SceneWallpaperContentFactory.lastDiagnostic` for live/native/media selection; the private view test also checks the actual background and overlay ratio.

Scripts cannot access native filesystem, network or shell objects. Unsupported APIs report the affected binding and disable it. A worker timeout or crash stops all scripts in that scene and retains the last values; **Stop**, then **Play on Desktop** creates a new worker.

## Summer in the City

The private test project contains 43 objects and 80 script bindings: 74 direct layer bindings and six nested media-effect bindings. The local integration test loads the original package without changing it. It exercises initialization, playing/paused states, title/artist/album text, timeline, current/previous artwork events, animation restart, hide timers and long-title scrolling with zero script diagnostics. The original title script includes randomized typing delays and mistakes; partial or briefly mistyped titles can be authored animation. The view-composition test disables that random typing option to verify media delivery at a fixed time.

The media path draws 24 image/text layers, two compose layers and four audio-responsive particle groups above a separately cached background. It includes the scripted day/night image layers and foreground borders; these must not remain frozen in the video. Background and overlays share the authored canvas ratio and aspect-fill transform. Current/previous artwork drives the original vinyl blend and one-second gradient-wipe shaders. A duration such as `3:55.320007…` previously overran the panel, and the small clock appeared beyond the right edge. Both were checked inside the panel with Music playback in the installed `1.5.0-dev` build 15 on 2026-09-10 (Apple Silicon, macOS 26.5.1).

The two compose layers (`VintageEffect` and `GlichyEffectLayerDay`) are excluded from the cached background. Their six origin/scale/visibility bindings now drive live surfaces that copy the playing video and the layers below them. Original glitch, CRT and pixelate shaders execute with authored uniforms, combo defaults and named intermediate buffers. The hidden alternate album-art layer uses the same shader path. A local test enables the authored glitch script and verifies that it produces a composed image from live playback.

Limits remain:

- Fireflies use package sprites, emitter rate, prewarm time, randomized lifetime/size/color/alpha, independent trail lifetimes, gravity, fades and oscillations. Audio force and cursor attraction are live. The turbulence field and numerical motion are local implementations without Windows calibration; exact particle paths and timing are not established.
- Large DXT atlases can be reduced block by block within the existing output memory budget. This avoids allocating the full atlas in RGBA, but reduces image detail.
- The video background is a loop. Effects baked into it do not become live merely because the script graph runs.

These are known gaps, not a compatibility percentage. The current development build is not cleared for a release claiming all scene functionality or complete Windows parity. No creator source, package or engine assets are committed with the tests.

## Resource and lifecycle boundaries

Basic native decoding remains capped at 24 image/text layers. Incomplete basic plans retain the preview. The media plan separately bounds the script graph to 256 objects, nested effect objects to 128, live image/text layers to 24, compose layers to four, decoded image/frame pixels to 32 million and font data to 512 KiB. Shader passes are limited to 32 per scene and 4 MiB of expanded source. Effect surfaces are capped at 2,097,152 pixels; one render call allocates at most 16,777,216 texture pixels. Package paths, external asset paths and symlinks are validated; original Workshop files are read-only.

Each scene uses the app executable's isolated `--scene-script-worker` mode. Pipe requests and responses are limited to 1 MiB, with one outstanding request per scene. Stale responses are discarded after replacement/close; pause holds a completed response until resume. Watchdogs allow 2 seconds for initialization and 250 milliseconds per frame. Resident memory is sampled every 50 milliseconds with a 256 MiB threshold; this is a sampled safeguard, not a hard allocation cap.

`v6` and `v7` below are cache-format generations, not app versions. Source-fresh whole-scene v6 videos can play while v7 renders. Media backgrounds use distinct cache keys (`-media-v4` for this composition) and exclusions so live text is never stacked above an old video containing the same text. Media backgrounds are recorded at the authored canvas ratio. Renderer capability checks and recording have timeouts; failed rendering retains a compatible video or preview.

## Verification

`swift test` checks runtime state, event delivery, vector copies, text measurement, effect animation, actual multipass shader pixels, independent sampler slots, transparent discarded pixels, texture orientation, transformed compose regions and particle emission/lifetime, cursor queues, isolated-worker timeouts, video fallback, WebKit animation/input behavior and deterministic stereo FFT data. A held-render regression checks that animation ticks preserve processed frames and that suspension rejects a pending GPU result; another checks live artwork fallback after shader failure. `bash Scripts/package-app.sh` verifies the packaged app and screen saver signatures.

Private integrations are opt-in. `WWB_LOCAL_SCENE_LIBRARY` is the bridge library directory containing `library.json` and `Assets/`, including the local Summer fixture. Each web variable points to its imported project directory containing `project.json` and the HTML entrypoint:

```bash
WWB_LOCAL_SCENE_LIBRARY='/path/to/WorkshopWallpaperBridge' swift test -c release --filter SceneMediaIntegrationTests
WWB_LOCAL_CUBE_PROJECT='/path/to/cube' WWB_LOCAL_PERIODIC_PROJECT='/path/to/table' swift test --filter LocalWebInteractionTests
```

The web tests verify a real cube face move, element expansion and a user-requested Wikipedia URL. The five-scene regression checks cached-video routing, playability and differing frames at 2 and 8 seconds. None of these replaces a Windows comparison. Offscreen layer snapshots are not accepted as visual proof of AVPlayer composition; the installed app is checked on screen.

The pinned renderer source is recorded in [scene-renderer.env](../Scripts/scene-renderer.env). [build-scene-renderer.sh](../Scripts/build-scene-renderer.sh) builds that public revision and copies license notices. Its lazy MPV loading was verified by a successful help probe and actual Summer recording. Video textures still need the matching Homebrew MPV runtime.

Full-parity acceptance needs paired Windows/Mac captures with matched project settings, time, media changes, cursor paths and audio input. Remaining comparisons include compose effects, particle operators, font rasterization, texture detail, event ordering and audio gain.

References inspected 2026-09-10:

- [Official SceneScript definitions](https://docs.wallpaperengine.io/reference/lib.sceneScript.d.ts)
- [Initialization and scalar-to-vector conversion](https://docs.wallpaperengine.io/en/scene/scenescript/reference/event/init.html)
- [Vector semantics](https://docs.wallpaperengine.io/en/scene/scenescript/reference/class/Vec3.html)
- [Web audio buffer layout](https://docs.wallpaperengine.io/en/web/audio/visualizer.html)
- [Apple ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)
