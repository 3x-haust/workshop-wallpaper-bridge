import Foundation
import WorkshopWallpaperCore

#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Describes one scene->video render job: the external renderer records
/// offscreen PNG frames of the scene, which ffmpeg then encodes into a
/// loopable mp4 that plays through the normal video-wallpaper path.
struct SceneVideoRenderConfiguration: Sendable {
    let assetId: String
    let projectDirectory: URL
    let assetsDirectory: URL
    let rendererURL: URL
    let size: CGSize
    let fps: Int
    let seconds: Int
    // The scene.pkg itself, used only to extract authored sound layers to mux
    // into the cached video as a looping audio track. Optional (defaulting to
    // nil) so existing callers/tests that only care about the video pipeline
    // don't need to supply it; when nil, the render is silent as before.
    let sceneURL: URL?

    init(
        assetId: String,
        projectDirectory: URL,
        assetsDirectory: URL,
        rendererURL: URL,
        size: CGSize,
        fps: Int = 30,
        // A longer recorded clip means the (still perceptible) loop point is
        // reached less often, making the seam less jarring for scenes whose
        // motion doesn't tile perfectly. The tradeoff is a longer first
        // render, which the rendering-progress status message covers.
        seconds: Int = 20,
        sceneURL: URL? = nil
    ) {
        self.assetId = assetId
        self.projectDirectory = projectDirectory
        self.assetsDirectory = assetsDirectory
        self.rendererURL = rendererURL
        self.size = size
        self.fps = fps
        self.seconds = seconds
        self.sceneURL = sceneURL
    }
}

/// Computes a sensible offscreen record size for a scene render, derived
/// from the display's logical (point) size rather than its physical
/// (backing/retina) pixel size. Recording at full physical resolution on a
/// retina display (e.g. 3024x1964, doubled again by an over-eager renderer
/// to 6048x3928) produces multi-hundred-megabyte clips that take minutes to
/// encode; clamping the long edge keeps the cached wallpaper video small and
/// fast to render while remaining crisp.
enum SceneVideoRecordSize {
    /// Wallpapers are viewed from a normal desktop distance, so ~1920px on
    /// the long edge is plenty crisp while keeping render time and cache
    /// size small.
    static let defaultMaxLongEdge: CGFloat = 1920

    /// Clamps `logicalSize` so its longer edge does not exceed `maxLongEdge`,
    /// preserving aspect ratio. Dimensions are rounded to even integers,
    /// which common H.264 encoders (including the `libx264` pipeline used
    /// here) require for `yuv420p` output.
    static func clampedRecordSize(
        forLogicalSize logicalSize: CGSize,
        maxLongEdge: CGFloat = defaultMaxLongEdge
    ) -> CGSize {
        guard logicalSize.width > 0, logicalSize.height > 0 else {
            return evenSize(CGSize(width: maxLongEdge, height: maxLongEdge))
        }
        let longEdge = max(logicalSize.width, logicalSize.height)
        guard longEdge > maxLongEdge else {
            return evenSize(logicalSize)
        }
        let scale = maxLongEdge / longEdge
        return evenSize(CGSize(width: logicalSize.width * scale, height: logicalSize.height * scale))
    }

    private static func evenSize(_ size: CGSize) -> CGSize {
        CGSize(width: evenRounded(size.width), height: evenRounded(size.height))
    }

    private static func evenRounded(_ value: CGFloat) -> CGFloat {
        let rounded = value.rounded()
        let isEven = rounded.truncatingRemainder(dividingBy: 2) == 0
        return max(2, isEven ? rounded : rounded - 1)
    }
}

/// Where rendered scene videos are cached, keyed by asset id. Accessed from
/// both the main actor (checking for a fresh cache before playback) and
/// background render tasks (writing the freshly encoded video), so the test
/// override is intentionally not actor-isolated.
enum SceneVideoCache {
    /// Bump whenever a change to the render pipeline (record size, encoding
    /// settings, loop handling, etc.) would make previously cached videos
    /// undesirable even though the source scene package itself hasn't
    /// changed. Cache entries are stored under a version-numbered
    /// subdirectory, so bumping this invalidates every existing cache entry
    /// at once: old videos are simply never found and a fresh one is
    /// rendered and written under the new version's directory.
    ///
    /// v2: fixed record size to use clamped logical points instead of
    /// doubled physical retina pixels (previously produced oversized
    /// 6048x3928 clips).
    ///
    /// v3: default record duration increased from 10s to 20s so the loop
    /// point is reached less often, making the seam where playback jumps
    /// back to the start less noticeable.
    ///
    /// v4: the encode now crossfades the recorded clip's tail into its head
    /// (see `SceneVideoLoopCrossfade`), so the loop seam itself is blended
    /// away instead of merely being made less frequent.
    ///
    /// v5: recordings pass `--record-exclude-live` so live-data elements
    /// (clock text etc.) are no longer baked into the looping video, and the
    /// renderer restored water sparkles with Windows-matched bloom/tone.
    ///
    /// v6: the scene's authored sound layers (ambience/music) are now muxed
    /// into the cached mp4 as a looping audio track (see
    /// `SceneAudioExtractor`/`SceneAudioMux`). Mute/volume are applied at
    /// playback time (`VideoWallpaperView`), so no further bump is needed
    /// when only the user's audio preference changes.
    static let cacheVersion = 6

    nonisolated(unsafe) static var overrideCacheDirectoryURL: URL?

    static func cacheDirectoryURL() -> URL {
        if let overrideCacheDirectoryURL {
            return overrideCacheDirectoryURL
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appending(path: "WorkshopWallpaperBridge")
            .appending(path: "SceneVideoCache")
            .appending(path: "v\(cacheVersion)")
    }

    static func cachedVideoURL(assetId: String) -> URL {
        cacheDirectoryURL().appending(path: "\(assetId).mp4")
    }

    /// A cache entry is fresh when it exists and was written on or after the
    /// scene package it was rendered from was last modified. Modification
    /// dates are read via `FileManager` rather than `URL.resourceValues`
    /// because the latter caches values per `URL` instance, which would
    /// return stale results after the source file is touched again.
    static func isFresh(cacheURL: URL, sourceURL: URL) -> Bool {
        let fileManager = FileManager.default
        guard let cacheModified = modificationDate(of: cacheURL, fileManager: fileManager),
              let sourceModified = modificationDate(of: sourceURL, fileManager: fileManager) else {
            return false
        }
        return cacheModified >= sourceModified
    }

    private static func modificationDate(of url: URL, fileManager: FileManager) -> Date? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attributes[.modificationDate] as? Date
    }

    static func freshCachedVideoURL(assetId: String, sourceURL: URL) -> URL? {
        let url = cachedVideoURL(assetId: assetId)
        return isFresh(cacheURL: url, sourceURL: sourceURL) ? url : nil
    }
}

/// The status a library row should display for an asset. This is purely
/// presentational: it never touches `WallpaperAsset.supportStatus`, which
/// stays scan-derived and is what's persisted to `library.json`. Scenes are
/// special-cased because playing one for the first time renders an offscreen
/// video (see `SceneWallpaperContentFactory`), which takes about a minute -
/// showing the same "playable" badge a video/image asset gets would make
/// that first play look broken while it renders.
enum LibraryRowDisplayStatus: Equatable {
    case playable
    case needsFirstRender
    case notPlayable(SupportStatus)

    var label: String {
        switch self {
        case .playable:
            return SupportStatus.playable.rawValue
        case .needsFirstRender:
            return "renders on first play"
        case .notPlayable(let status):
            return status.rawValue
        }
    }

    var isPositive: Bool {
        self == .playable
    }
}

enum LibraryRowStatusResolver {
    /// Derives the display status fresh from disk state every call rather
    /// than caching it, so the row picks up a completed render simply by
    /// re-evaluating on the next SwiftUI re-render (e.g. once the app's
    /// status message flips to "Playing" after the background render task
    /// finishes).
    static func status(for asset: WallpaperAsset) -> LibraryRowDisplayStatus {
        guard asset.supportStatus == .playable else {
            return .notPlayable(asset.supportStatus)
        }
        guard asset.kind == .scene, let entrypoint = asset.entrypoint else {
            return .playable
        }
        let sourceURL = URL(filePath: entrypoint)
        let hasFreshCache = SceneVideoCache.freshCachedVideoURL(assetId: asset.id, sourceURL: sourceURL) != nil
        return hasFreshCache ? .playable : .needsFirstRender
    }
}

/// Pure math for turning a recorded (non-tiling) clip into a seamlessly
/// looping one by crossfading its tail into its head at encode time,
/// factored out of `SceneVideoRenderer.ffmpegArguments` so the frame/offset
/// arithmetic can be unit tested without invoking ffmpeg.
///
/// Given a recorded clip of `totalFrameCount` frames at `fps`, the output is
/// built from two views of the same frame sequence:
/// - `main` = frames `[crossfadeFrameCount, totalFrameCount)`, i.e. the clip
///   with its first `crossfadeFrameCount` frames trimmed off, re-based to
///   start at t=0.
/// - `head` = frames `[0, crossfadeFrameCount)`, i.e. just the clip's head.
///
/// ffmpeg's `xfade` filter is applied as `xfade(main, head)`: it plays
/// `main` unblended for `offsetSeconds`, then blends `main`'s next
/// `crossfadeSeconds` (which is exactly the *original* clip's tail, since
/// `main` is `main`'s local time + the trimmed head duration) with `head`'s
/// full duration (the *original* clip's head). Because `xfade`'s total output
/// duration is `offset + duration(head)`, and `duration(head) ==
/// crossfadeSeconds`, the result is exactly `totalSeconds - crossfadeSeconds`
/// long, with the seam itself replaced by a blend of the original tail and
/// head instead of a hard cut between them.
enum SceneVideoLoopCrossfade {
    /// The recommended crossfade window: long enough to hide a swimming/
    /// drifting scene's seam, short enough not to noticeably shorten the
    /// loop or blur fast motion.
    static let defaultSeconds: Double = 1.2

    /// How many frames the crossfade should span, clamped so recordings that
    /// are too short to crossfade (mainly small fixtures in tests) fall back
    /// to a plain (non-crossfaded) encode rather than producing invalid
    /// ffmpeg filter arguments.
    ///
    /// Crossfading requires an unblended `main` body of positive length
    /// before the transition starts, i.e. `totalFrameCount > 2 *
    /// crossfadeFrameCount`; when the recording is too short for that
    /// (mainly small fixtures in tests), this returns 0 to signal "disable
    /// crossfading".
    static func frameCount(totalFrameCount: Int, fps: Int, seconds: Double = defaultSeconds) -> Int {
        guard totalFrameCount > 0, fps > 0 else {
            return 0
        }
        let desired = max(1, Int((seconds * Double(fps)).rounded()))
        guard totalFrameCount > desired * 2 else {
            return 0
        }
        return desired
    }

    /// Seconds of unblended `main` playback before the crossfade transition
    /// begins. This is also the `offset` argument to ffmpeg's `xfade` filter.
    static func offsetSeconds(totalFrameCount: Int, crossfadeFrameCount: Int, fps: Int) -> Double {
        guard fps > 0 else {
            return 0
        }
        return Double(totalFrameCount - 2 * crossfadeFrameCount) / Double(fps)
    }

    /// The final output duration: the recorded clip's length minus one
    /// crossfade window.
    static func outputSeconds(totalFrameCount: Int, crossfadeFrameCount: Int, fps: Int) -> Double {
        guard fps > 0 else {
            return 0
        }
        return Double(totalFrameCount - crossfadeFrameCount) / Double(fps)
    }
}

/// One authored sound layer extracted from a scene package's `scene.json`
/// (an object with a `sound` array), factored out so it can be tested without
/// reading an actual `.pkg` file.
struct SceneAudioTrack: Equatable, Sendable {
    /// The package-relative path to the audio file (e.g. `sounds/x.mp3`).
    let path: String
    /// The layer's authored volume (`volume.value` in scene.json), used as
    /// the mix weight so louder/quieter authored layers stay proportionate
    /// to one another. Defaults to 1.0 when the layer doesn't specify one.
    let volume: Double
}

/// Reads the sound layers a scene author configured (ambience, background
/// music, etc.) out of a parsed `scene.json`, factored out of
/// `SceneVideoRenderer` so the JSON-shape logic can be unit tested without
/// touching the filesystem.
enum SceneAudioExtractor {
    static func audioTracks(scene: [String: Any]) -> [SceneAudioTrack] {
        let objects = scene["objects"] as? [[String: Any]] ?? []
        var tracks: [SceneAudioTrack] = []
        for object in objects {
            guard let soundPaths = object["sound"] as? [Any] else {
                continue
            }
            let volume = volumeValue(object["volume"]) ?? 1.0
            for case let path as String in soundPaths {
                tracks.append(SceneAudioTrack(path: path, volume: volume))
            }
        }
        return tracks
    }

    private static func volumeValue(_ value: Any?) -> Double? {
        if let dict = value as? [String: Any] {
            return volumeValue(dict["value"])
        }
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let double = value as? Double {
            return double
        }
        return nil
    }
}

/// Builds the ffmpeg invocation that muxes one or more looping authored audio
/// tracks onto an already-encoded (silent) scene video, factored out so the
/// argument construction can be unit tested without invoking ffmpeg. Each
/// audio input is looped indefinitely (`-stream_loop -1`) and the output is
/// trimmed to the video's length (`-shortest`), since the source recording is
/// an arbitrary-length loop rather than something the audio needs to match
/// exactly.
///
/// v1 note: the audio track itself is not crossfaded at the loop point the
/// way the video is (see `SceneVideoLoopCrossfade`) - it simply loops, so a
/// (typically subtle) seam may be audible in the authored track's own loop
/// point. This is an accepted simplification for the first version.
enum SceneAudioMux {
    static func ffmpegArguments(
        videoURL: URL,
        audioTracks: [(url: URL, weight: Double)],
        outputURL: URL
    ) -> [String] {
        guard !audioTracks.isEmpty else {
            return []
        }

        var arguments = ["-y", "-i", videoURL.path]
        for track in audioTracks {
            arguments += ["-stream_loop", "-1", "-i", track.url.path]
        }

        let filterComplex: String
        if audioTracks.count == 1 {
            filterComplex = "[1:a]volume=\(formatWeight(audioTracks[0].weight))[a]"
        } else {
            var volumeFilters: [String] = []
            var mixLabels: [String] = []
            for (index, track) in audioTracks.enumerated() {
                let inputIndex = index + 1
                let label = "a\(index)"
                volumeFilters.append("[\(inputIndex):a]volume=\(formatWeight(track.weight))[\(label)]")
                mixLabels.append("[\(label)]")
            }
            let mix = "\(mixLabels.joined())amix=inputs=\(audioTracks.count):duration=longest:normalize=0[a]"
            filterComplex = (volumeFilters + [mix]).joined(separator: ";")
        }

        arguments += [
            "-filter_complex", filterComplex,
            "-map", "0:v",
            "-map", "[a]",
            "-c:v", "copy",
            "-c:a", "aac",
            "-shortest",
            "-movflags", "+faststart",
            outputURL.path
        ]
        return arguments
    }

    private static func formatWeight(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

enum SceneVideoRenderer {
    /// Injectable so tests can capture the ffmpeg invocation instead of
    /// actually spawning a process. Rendering runs off the main actor (see
    /// `render(configuration:ffmpegPath:)`), so this is intentionally not
    /// actor-isolated.
    nonisolated(unsafe) static var runProcess: (URL, [String]) throws -> Void = { executableURL, arguments in
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SceneVideoRenderError.processFailed(executableURL.lastPathComponent, process.terminationStatus)
        }
    }

    /// Runs the scene renderer. Some renderer builds have been observed to
    /// crash during shutdown-time cleanup (a non-zero exit / uncaught
    /// exception in their own teardown) even after successfully writing
    /// every requested frame, so the exit code alone is not a reliable
    /// success signal here; `render(configuration:ffmpegPath:)` verifies
    /// success by checking that frames were actually recorded instead.
    nonisolated(unsafe) static var runRendererProcess: (URL, [String]) -> Void = { executableURL, arguments in
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        try? process.run()
        process.waitUntilExit()
    }

    static func canRender(rendererURL: URL?, assetsDirectory: URL?, ffmpegPath: String?) -> Bool {
        rendererURL != nil && assetsDirectory != nil && ffmpegPath != nil
    }

    static func recordingArguments(
        recordDirectory: URL,
        configuration: SceneVideoRenderConfiguration
    ) -> [String] {
        [
            "--window", windowArgument(for: configuration.size),
            "--silent",
            "--noautomute",
            "--no-audio-processing",
            "--disable-mouse",
            "--record-dir", recordDirectory.path,
            "--record-seconds", String(configuration.seconds),
            "--record-fps", String(configuration.fps),
            "--record-exclude-live",
            "--assets-dir", configuration.assetsDirectory.path,
            configuration.projectDirectory.path
        ]
    }

    /// Builds the ffmpeg invocation that encodes the recorded frame sequence
    /// into the cached mp4. `recordedFrameCount` is the number of frames
    /// actually written by the renderer (not the requested `fps * seconds`
    /// target, which the renderer may fall short of or exceed slightly).
    ///
    /// When there are enough frames, the clip's tail is crossfaded into its
    /// head (see `SceneVideoLoopCrossfade`) so the encoded video loops
    /// seamlessly instead of jump-cutting back to frame 0. Short recordings
    /// (mainly test fixtures) fall back to a plain single-pass encode.
    static func ffmpegArguments(
        framesDirectory: URL,
        fps: Int,
        recordedFrameCount: Int,
        outputURL: URL
    ) -> [String] {
        let framePattern = framesDirectory.appending(path: "frame_%05d.png").path
        let crossfadeFrameCount = SceneVideoLoopCrossfade.frameCount(totalFrameCount: recordedFrameCount, fps: fps)
        guard crossfadeFrameCount > 0 else {
            return [
                "-y",
                "-framerate", String(fps),
                "-i", framePattern,
                "-c:v", "libx264",
                "-pix_fmt", "yuv420p",
                "-crf", "18",
                "-movflags", "+faststart",
                outputURL.path
            ]
        }

        let offsetSeconds = SceneVideoLoopCrossfade.offsetSeconds(
            totalFrameCount: recordedFrameCount,
            crossfadeFrameCount: crossfadeFrameCount,
            fps: fps
        )
        let crossfadeSeconds = Double(crossfadeFrameCount) / Double(fps)
        let filterComplex = "[0:v]trim=start_frame=\(crossfadeFrameCount),setpts=PTS-STARTPTS[main];"
            + "[1:v]trim=end_frame=\(crossfadeFrameCount),setpts=PTS-STARTPTS[head];"
            + "[main][head]xfade=transition=fade:duration=\(formatSeconds(crossfadeSeconds)):offset=\(formatSeconds(offsetSeconds))[out]"

        return [
            "-y",
            "-framerate", String(fps),
            "-i", framePattern,
            "-framerate", String(fps),
            "-i", framePattern,
            "-filter_complex", filterComplex,
            "-map", "[out]",
            "-c:v", "libx264",
            "-pix_fmt", "yuv420p",
            "-crf", "18",
            "-movflags", "+faststart",
            outputURL.path
        ]
    }

    private static func formatSeconds(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    // MARK: - Raw-pipe pipeline (renderer --record-raw + concurrent ffmpeg)

    /// Injectable seam for probing whether `rendererURL` supports
    /// `--record-raw` (streaming RGBA frames to a FIFO) by inspecting its
    /// `--help` output, so tests can stub the probe without running a real
    /// binary. Failures (missing binary, non-zero exit, etc.) resolve to an
    /// empty string, which `supportsRecordRaw` treats as "not supported" so
    /// the caller falls back to the PNG-sequence pipeline.
    nonisolated(unsafe) static var rendererHelpOutput: (URL) -> String = { rendererURL in
        let process = Process()
        process.executableURL = rendererURL
        process.arguments = ["--help"]
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return ""
        }
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Pure check factored out of `rendererHelpOutput` so the detection logic
    /// can be unit tested against sample `--help` text without invoking a
    /// process.
    static func supportsRecordRaw(helpOutput: String) -> Bool {
        helpOutput.contains("record-raw")
    }

    static func supportsRecordRaw(rendererURL: URL) -> Bool {
        supportsRecordRaw(helpOutput: rendererHelpOutput(rendererURL))
    }

    /// Builds the renderer invocation for the raw-pipe pipeline: identical to
    /// `recordingArguments` except frames stream to `fifoURL` (a FIFO or
    /// regular file) via `--record-raw` instead of being written as a PNG
    /// sequence via `--record-dir`.
    static func rawRecordingArguments(
        fifoURL: URL,
        configuration: SceneVideoRenderConfiguration
    ) -> [String] {
        [
            "--window", windowArgument(for: configuration.size),
            "--silent",
            "--noautomute",
            "--no-audio-processing",
            "--disable-mouse",
            "--record-raw", fifoURL.path,
            "--record-seconds", String(configuration.seconds),
            "--record-fps", String(configuration.fps),
            "--record-exclude-live",
            "--assets-dir", configuration.assetsDirectory.path,
            configuration.projectDirectory.path
        ]
    }

    /// Builds the ffmpeg invocation that reads raw RGBA frames from
    /// `fifoURL` as they're streamed by the renderer and encodes them into a
    /// fast, near-lossless intermediate mp4. Encoding overlaps the renderer's
    /// frame production (rather than waiting for it to finish, as the PNG
    /// pipeline does), which is the whole point of the raw-pipe pipeline.
    ///
    /// The crossfade loop filter (`SceneVideoLoopCrossfade`) needs to read
    /// the same clip twice (once for its head, once for its tail), which a
    /// single-consumer FIFO can't provide - so this stage only transcodes the
    /// raw stream to a seekable intermediate file; `videoCrossfadeFfmpegArguments`
    /// then runs the crossfade pass on that file as a second, much shorter
    /// (real-time-fast) step.
    static func rawEncodeFfmpegArguments(
        fifoURL: URL,
        size: CGSize,
        fps: Int,
        outputURL: URL
    ) -> [String] {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        return [
            "-y",
            "-f", "rawvideo",
            "-pix_fmt", "rgba",
            "-s", "\(width)x\(height)",
            "-r", String(fps),
            "-i", fifoURL.path,
            "-c:v", "libx264",
            "-preset", "ultrafast",
            "-qp", "0",
            "-pix_fmt", "yuv420p",
            outputURL.path
        ]
    }

    /// Same crossfade-loop math as `ffmpegArguments`, but reading from an
    /// already-encoded video file (the raw-pipe pipeline's intermediate mp4)
    /// instead of a PNG frame sequence.
    static func videoCrossfadeFfmpegArguments(
        videoURL: URL,
        fps: Int,
        recordedFrameCount: Int,
        outputURL: URL
    ) -> [String] {
        let crossfadeFrameCount = SceneVideoLoopCrossfade.frameCount(totalFrameCount: recordedFrameCount, fps: fps)
        guard crossfadeFrameCount > 0 else {
            return [
                "-y",
                "-i", videoURL.path,
                "-c:v", "libx264",
                "-pix_fmt", "yuv420p",
                "-crf", "18",
                "-movflags", "+faststart",
                outputURL.path
            ]
        }

        let offsetSeconds = SceneVideoLoopCrossfade.offsetSeconds(
            totalFrameCount: recordedFrameCount,
            crossfadeFrameCount: crossfadeFrameCount,
            fps: fps
        )
        let crossfadeSeconds = Double(crossfadeFrameCount) / Double(fps)
        let filterComplex = "[0:v]trim=start_frame=\(crossfadeFrameCount),setpts=PTS-STARTPTS[main];"
            + "[1:v]trim=end_frame=\(crossfadeFrameCount),setpts=PTS-STARTPTS[head];"
            + "[main][head]xfade=transition=fade:duration=\(formatSeconds(crossfadeSeconds)):offset=\(formatSeconds(offsetSeconds))[out]"

        return [
            "-y",
            "-i", videoURL.path,
            "-i", videoURL.path,
            "-filter_complex", filterComplex,
            "-map", "[out]",
            "-c:v", "libx264",
            "-pix_fmt", "yuv420p",
            "-crf", "18",
            "-movflags", "+faststart",
            outputURL.path
        ]
    }

    /// Injectable seam for starting a process without blocking until it
    /// exits, used so ffmpeg can be started (and be actively reading the
    /// FIFO) *before* the renderer is started writing to it. `stderrPipe`,
    /// when provided, is wired up as the process's standard error so its
    /// `frame=` progress lines can be parsed as they're written.
    nonisolated(unsafe) static var startProcess: (URL, [String], Pipe?) throws -> Process = { executableURL, arguments, stderrPipe in
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let stderrPipe {
            process.standardError = stderrPipe
        }
        try process.run()
        return process
    }

    /// How long the raw-pipe pipeline is allowed to run before it's treated
    /// as stalled (renderer hung mid-scene, ffmpeg stopped reading, etc.) and
    /// both child processes are killed so `render()` can fall back to the
    /// PNG-sequence pipeline instead of hanging the caller forever.
    /// Injectable so tests can exercise the stall path without waiting on a
    /// realistic timeout. Defaults to twice the requested record duration
    /// with a floor, since the raw-pipe pipeline overlaps recording and
    /// encoding but the final crossfade pass still needs a little headroom
    /// beyond that.
    nonisolated(unsafe) static var rawPipeWatchdogTimeout: (SceneVideoRenderConfiguration) -> TimeInterval = { configuration in
        max(30, Double(configuration.seconds) * 2)
    }

    /// Runs the concurrent raw-pipe pipeline: a FIFO is created, ffmpeg is
    /// started reading raw RGBA frames from it (encoding them to a fast
    /// intermediate file as they arrive), then the renderer is started
    /// writing frames into the same FIFO via `--record-raw`. Once both have
    /// finished, the intermediate file is passed through the existing
    /// crossfade-loop encode to produce the final silent video.
    ///
    /// Race fix: a FIFO's blocking `open(2)` only rendezvous correctly when
    /// *both* processes actually reach their own open call. If either one is
    /// slow to start (library init, dynamic loading, etc.) or fails to start
    /// at all (crash, missing binary, bad arguments) before doing so, the
    /// other can hang forever inside `open()` waiting for a counterpart that
    /// is late or will never arrive - e.g. a fast-writing renderer (or a
    /// short-lived fake one in tests) can write everything and exit before a
    /// slower-initializing ffmpeg has even reached its own `open()` of the
    /// FIFO, so ffmpeg then blocks forever waiting for a writer that already
    /// came and went. To avoid that, this function itself opens the FIFO
    /// `O_RDWR` (`anchorFD`) before starting either child process. An
    /// `O_RDWR` open of a FIFO never blocks and counts as both a reader and
    /// a writer, so for as long as it's held, ffmpeg's read-open and the
    /// renderer's write-open both succeed immediately no matter how late
    /// either process is to actually call `open()`, and no matter what order
    /// they start in or whether one fails outright. The anchor is kept open
    /// until the renderer process has actually finished (see below) - only
    /// then is it safe to close: closing it any earlier would just
    /// reconstruct the same race (ffmpeg might still not have reached its
    /// own open() yet), while an anchor left open past that point would
    /// itself count as a permanent second writer and prevent ffmpeg from
    /// ever observing EOF.
    ///
    /// Belt-and-braces: an overall watchdog (`rawPipeWatchdogTimeout`) kills
    /// both processes and signals a stall if the pipeline runs far longer
    /// than expected, and every error path below explicitly terminates and
    /// reaps any process it already started so no ffmpeg/renderer instance
    /// is left running past this function returning.
    private static func renderUsingRawPipe(
        configuration: SceneVideoRenderConfiguration,
        ffmpegPath: String,
        tempDirectory: URL,
        progressHandler: (@Sendable (Double) -> Void)?
    ) throws -> URL {
        let fileManager = FileManager.default
        let fifoURL = tempDirectory.appending(path: "scene-raw.fifo")
        guard mkfifo(fifoURL.path, 0o600) == 0 else {
            throw SceneVideoRenderError.fifoCreationFailed(errno)
        }

        let anchorFD = open(fifoURL.path, O_RDWR)
        guard anchorFD != -1 else {
            let openErrno = errno
            try? fileManager.removeItem(at: fifoURL)
            throw SceneVideoRenderError.fifoCreationFailed(openErrno)
        }
        var anchorClosed = false
        func closeAnchor() {
            guard !anchorClosed else {
                return
            }
            close(anchorFD)
            anchorClosed = true
        }
        defer { closeAnchor() }

        let intermediateOutputURL = tempDirectory.appending(path: "scene-render-raw.mp4")
        let stderrPipe = Pipe()
        let ffmpegProcess: Process
        do {
            ffmpegProcess = try startProcess(
                URL(filePath: ffmpegPath),
                rawEncodeFfmpegArguments(
                    fifoURL: fifoURL,
                    size: configuration.size,
                    fps: configuration.fps,
                    outputURL: intermediateOutputURL
                ),
                stderrPipe
            )
        } catch {
            try? fileManager.removeItem(at: fifoURL)
            throw error
        }

        let targetFrameCount = configuration.fps * configuration.seconds
        let progressMonitor = FfmpegStderrProgressMonitor(
            pipe: stderrPipe,
            targetFrameCount: targetFrameCount,
            handler: progressHandler ?? { _ in }
        )
        progressMonitor.start()

        let rendererProcess: Process
        do {
            rendererProcess = try startProcess(
                configuration.rendererURL,
                rawRecordingArguments(fifoURL: fifoURL, configuration: configuration),
                nil
            )
        } catch {
            _ = progressMonitor.stop()
            ffmpegProcess.terminate()
            ffmpegProcess.waitUntilExit()
            try? fileManager.removeItem(at: fifoURL)
            throw error
        }

        let watchdogState = RawPipeWatchdogState()
        let watchdogWorkItem = DispatchWorkItem {
            watchdogState.markFired()
            rendererProcess.terminate()
            ffmpegProcess.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + rawPipeWatchdogTimeout(configuration),
            execute: watchdogWorkItem
        )

        // The renderer's own exit status isn't a reliable success signal
        // (some builds crash during their own shutdown-time cleanup even
        // after successfully streaming every frame), so it's ignored here
        // just like the PNG-sequence pipeline's `runRendererProcess` ignores
        // it.
        rendererProcess.waitUntilExit()

        // Only now - once the renderer has actually finished (normally or
        // via the watchdog above) - is it safe to release the anchor fd.
        // ffmpeg keeps reading happily regardless of when it got around to
        // opening the FIFO for real, and closing the anchor here lets it see
        // a normal EOF right as the renderer's own write end goes away, with
        // no gap in which either side could still be waiting on the other.
        closeAnchor()

        ffmpegProcess.waitUntilExit()
        watchdogWorkItem.cancel()

        let recordedFrameCount = progressMonitor.stop()
        try? fileManager.removeItem(at: fifoURL)

        if watchdogState.hasFired {
            throw SceneVideoRenderError.rawPipeStalled
        }
        guard ffmpegProcess.terminationStatus == 0 else {
            throw SceneVideoRenderError.processFailed("ffmpeg", ffmpegProcess.terminationStatus)
        }
        guard recordedFrameCount > 0 else {
            throw SceneVideoRenderError.noFramesRecorded
        }
        progressHandler?(1.0)

        let temporaryOutputURL = tempDirectory.appending(path: "scene-render-output.mp4")
        try runProcess(
            URL(filePath: ffmpegPath),
            videoCrossfadeFfmpegArguments(
                videoURL: intermediateOutputURL,
                fps: configuration.fps,
                recordedFrameCount: recordedFrameCount,
                outputURL: temporaryOutputURL
            )
        )
        return temporaryOutputURL
    }

    /// Runs the original serial pipeline: the renderer writes a PNG frame
    /// sequence to a temp directory (recording finishes before encoding
    /// starts), then ffmpeg encodes the sequence. Used when the renderer
    /// binary doesn't support `--record-raw` yet.
    private static func renderUsingPNGSequence(
        configuration: SceneVideoRenderConfiguration,
        ffmpegPath: String,
        tempDirectory: URL,
        progressHandler: (@Sendable (Double) -> Void)?
    ) throws -> URL {
        let fileManager = FileManager.default
        let progressMonitor = progressHandler.map {
            SceneVideoRenderProgressMonitor(
                directory: tempDirectory,
                targetFrameCount: configuration.fps * configuration.seconds,
                handler: $0
            )
        }
        progressMonitor?.start()
        runRendererProcess(
            configuration.rendererURL,
            recordingArguments(recordDirectory: tempDirectory, configuration: configuration)
        )
        progressMonitor?.stop()
        let recordedFrameCount = (try? fileManager.contentsOfDirectory(atPath: tempDirectory.path))?
            .filter { $0.hasPrefix("frame_") }
            .count ?? 0
        guard recordedFrameCount > 0 else {
            throw SceneVideoRenderError.noFramesRecorded
        }
        progressHandler?(1.0)

        let temporaryOutputURL = tempDirectory.appending(path: "scene-render-output.mp4")
        try runProcess(
            URL(filePath: ffmpegPath),
            ffmpegArguments(
                framesDirectory: tempDirectory,
                fps: configuration.fps,
                recordedFrameCount: recordedFrameCount,
                outputURL: temporaryOutputURL
            )
        )
        return temporaryOutputURL
    }

    /// Runs the renderer to capture offscreen frames, encodes them with
    /// ffmpeg, and moves the result into the per-asset cache. Blocks the
    /// calling thread, so callers should invoke this off the main actor
    /// (e.g. from `Task.detached`).
    ///
    /// When the renderer binary supports `--record-raw` (probed via its
    /// `--help` output), rendering and encoding run concurrently through a
    /// FIFO instead of the renderer writing a complete PNG sequence before
    /// ffmpeg starts - the first-play render is significantly faster since
    /// encoding overlaps frame production instead of following it. Older
    /// renderer binaries without that flag fall back to the original
    /// serial PNG-sequence pipeline.
    ///
    /// `progressHandler`, when provided, is invoked periodically from a
    /// background queue (never the calling thread) with the fraction of the
    /// target frame count (`fps * seconds`) recorded so far, so callers can
    /// surface render progress to the user during the tens-of-seconds first
    /// render.
    static func render(
        configuration: SceneVideoRenderConfiguration,
        ffmpegPath: String,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) throws -> URL {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appending(path: "wwb-scene-render-\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: tempDirectory)
        }

        let temporaryOutputURL: URL
        if supportsRecordRaw(rendererURL: configuration.rendererURL) {
            do {
                temporaryOutputURL = try renderUsingRawPipe(
                    configuration: configuration,
                    ffmpegPath: ffmpegPath,
                    tempDirectory: tempDirectory,
                    progressHandler: progressHandler
                )
            } catch SceneVideoRenderError.rawPipeStalled {
                // The concurrent pipeline stalled past its watchdog timeout;
                // both processes were already killed, so fall back to the
                // original serial PNG-sequence pipeline rather than failing
                // the render outright.
                temporaryOutputURL = try renderUsingPNGSequence(
                    configuration: configuration,
                    ffmpegPath: ffmpegPath,
                    tempDirectory: tempDirectory,
                    progressHandler: progressHandler
                )
            }
        } else {
            temporaryOutputURL = try renderUsingPNGSequence(
                configuration: configuration,
                ffmpegPath: ffmpegPath,
                tempDirectory: tempDirectory,
                progressHandler: progressHandler
            )
        }

        let finalOutputURL = configuration.sceneURL.map {
            muxSceneAudioIfAvailable(
                sceneURL: $0,
                silentVideoURL: temporaryOutputURL,
                tempDirectory: tempDirectory,
                ffmpegPath: ffmpegPath
            )
        } ?? temporaryOutputURL

        let cacheDirectory = SceneVideoCache.cacheDirectoryURL()
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let outputURL = SceneVideoCache.cachedVideoURL(assetId: configuration.assetId)
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
        try fileManager.moveItem(at: finalOutputURL, to: outputURL)
        return outputURL
    }

    /// Records why the most recent render's audio mux step didn't produce a
    /// track with audio (either there was nothing to mux, or muxing failed).
    /// `nil` after a render that successfully baked audio in. Never causes
    /// the render itself to fail: any audio-extraction/mux problem falls back
    /// to the plain silent video.
    nonisolated(unsafe) static var lastAudioDiagnostic: String?

    /// Extracts the scene's authored sound layers (if any) from `sceneURL`
    /// and muxes them into `silentVideoURL` as a looping audio track. Falls
    /// back to returning `silentVideoURL` unchanged (silent) if the scene has
    /// no sound layers, or if anything about extraction/muxing fails -
    /// audio is a nice-to-have on top of the video render, never a reason to
    /// fail it.
    private static func muxSceneAudioIfAvailable(
        sceneURL: URL,
        silentVideoURL: URL,
        tempDirectory: URL,
        ffmpegPath: String
    ) -> URL {
        lastAudioDiagnostic = nil
        do {
            let package = try ScenePackageReader().read(url: sceneURL)
            guard let sceneData = package.data(forPath: "scene.json"),
                  let scene = try JSONSerialization.jsonObject(with: sceneData) as? [String: Any] else {
                return silentVideoURL
            }
            let tracks = SceneAudioExtractor.audioTracks(scene: scene)
            guard !tracks.isEmpty else {
                return silentVideoURL
            }

            let audioDirectory = tempDirectory.appending(path: "scene-audio")
            try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
            var writtenTracks: [(url: URL, weight: Double)] = []
            for (index, track) in tracks.enumerated() {
                guard let data = package.data(forPath: track.path) else {
                    continue
                }
                let fileExtension = URL(filePath: track.path).pathExtension
                let fileURL = audioDirectory.appending(path: "audio-\(index).\(fileExtension)")
                try data.write(to: fileURL)
                writtenTracks.append((url: fileURL, weight: track.volume))
            }
            guard !writtenTracks.isEmpty else {
                return silentVideoURL
            }

            let mixedOutputURL = tempDirectory.appending(path: "scene-render-with-audio.mp4")
            try runProcess(
                URL(filePath: ffmpegPath),
                SceneAudioMux.ffmpegArguments(
                    videoURL: silentVideoURL,
                    audioTracks: writtenTracks,
                    outputURL: mixedOutputURL
                )
            )
            return mixedOutputURL
        } catch {
            lastAudioDiagnostic = "scene audio mux failed: \(error.localizedDescription)"
            return silentVideoURL
        }
    }

    private static func windowArgument(for size: CGSize) -> String {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        return "0x0x\(width)x\(height)"
    }
}

/// Pure fraction-of-target computation, factored out of the polling monitor
/// below so it can be unit tested without any concurrency or file-system
/// timing involved.
enum SceneVideoRenderProgress {
    static func fraction(recordedFrameCount: Int, targetFrameCount: Int) -> Double {
        guard targetFrameCount > 0 else {
            return 0
        }
        return min(1, max(0, Double(recordedFrameCount) / Double(targetFrameCount)))
    }
}

/// Parses ffmpeg's periodic `frame=  123 fps=... ` progress lines (written to
/// stderr, updated in place with carriage returns), factored out so the
/// regex-like extraction can be unit tested against sample lines without any
/// process or pipe involved.
enum FfmpegProgressParsing {
    static func frameCount(fromLine line: String) -> Int? {
        guard let range = line.range(of: "frame=") else {
            return nil
        }
        let afterFrame = line[range.upperBound...].drop { $0 == " " }
        let digits = afterFrame.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }
}

/// Watches an ffmpeg process's stderr pipe while it encodes, parsing the
/// `frame=` progress lines it periodically writes there to report render
/// progress and to recover the final encoded frame count once the process
/// exits (used as `recordedFrameCount` for the crossfade-loop pass in the
/// raw-pipe pipeline).
private final class FfmpegStderrProgressMonitor: @unchecked Sendable {
    private let pipe: Pipe
    private let targetFrameCount: Int
    private let handler: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var lastFrameCount = 0

    init(pipe: Pipe, targetFrameCount: Int, handler: @escaping @Sendable (Double) -> Void) {
        self.pipe = pipe
        self.targetFrameCount = targetFrameCount
        self.handler = handler
    }

    func start() {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
            guard let self else {
                return
            }
            let data = fileHandle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
                return
            }
            var latestFrameCount: Int?
            for line in text.split(whereSeparator: { $0 == "\r" || $0 == "\n" }) {
                if let frameCount = FfmpegProgressParsing.frameCount(fromLine: String(line)) {
                    latestFrameCount = frameCount
                }
            }
            guard let latestFrameCount else {
                return
            }
            self.lock.lock()
            self.lastFrameCount = latestFrameCount
            self.lock.unlock()
            self.handler(SceneVideoRenderProgress.fraction(
                recordedFrameCount: latestFrameCount,
                targetFrameCount: self.targetFrameCount
            ))
        }
    }

    /// Stops watching and returns the last frame count observed in a
    /// `frame=` line, which - once the encoder process has exited - is its
    /// final encoded frame count.
    func stop() -> Int {
        pipe.fileHandleForReading.readabilityHandler = nil
        lock.lock()
        defer { lock.unlock() }
        return lastFrameCount
    }
}

/// Polls the renderer's frame output directory on a background queue while
/// the (synchronous, blocking) renderer process runs, reporting progress as
/// `frames written / (fps * seconds)`. The renderer process itself has no
/// progress-reporting protocol of its own, so counting frame files on disk is
/// the only available signal.
private final class SceneVideoRenderProgressMonitor: @unchecked Sendable {
    private let directory: URL
    private let targetFrameCount: Int
    private let handler: @Sendable (Double) -> Void
    private let queue = DispatchQueue(label: "com.workshopwallpaperbridge.scene-video-render-progress")
    private var timer: DispatchSourceTimer?

    init(directory: URL, targetFrameCount: Int, handler: @escaping @Sendable (Double) -> Void) {
        self.directory = directory
        self.targetFrameCount = targetFrameCount
        self.handler = handler
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [directory, targetFrameCount, handler] in
            let recordedFrameCount = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
                .filter { $0.hasPrefix("frame_") }
                .count ?? 0
            handler(SceneVideoRenderProgress.fraction(
                recordedFrameCount: recordedFrameCount,
                targetFrameCount: targetFrameCount
            ))
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}

enum SceneVideoRenderError: Error, LocalizedError, Equatable {
    case processFailed(String, Int32)
    case noFramesRecorded
    case fifoCreationFailed(Int32)
    case rawPipeStalled

    var errorDescription: String? {
        switch self {
        case .processFailed(let name, let status):
            return "\(name) exited with status \(status)."
        case .noFramesRecorded:
            return "The scene renderer did not produce any recorded frames."
        case .fifoCreationFailed(let errnoValue):
            return "Could not create the recording FIFO (errno \(errnoValue))."
        case .rawPipeStalled:
            return "The concurrent scene render pipeline stalled and was aborted."
        }
    }
}

/// Thread-safe latch set by the raw-pipe pipeline's watchdog timer when it
/// kills both child processes after the pipeline runs longer than
/// `SceneVideoRenderer.rawPipeWatchdogTimeout` allows, so the code that
/// awaited the (now-terminated) processes can tell a genuine stall apart
/// from normal completion or a real process failure.
private final class RawPipeWatchdogState: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func markFired() {
        lock.lock()
        fired = true
        lock.unlock()
    }

    var hasFired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }
}
