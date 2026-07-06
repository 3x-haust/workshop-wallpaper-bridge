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
        seconds: Int = 20
    ) {
        self.assetId = assetId
        self.projectDirectory = projectDirectory
        self.assetsDirectory = assetsDirectory
        self.rendererURL = rendererURL
        self.size = size
        self.fps = fps
        self.seconds = seconds
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
    static let cacheVersion = 5

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

    /// Runs the renderer to capture offscreen frames, encodes them with
    /// ffmpeg, and moves the result into the per-asset cache. Blocks the
    /// calling thread, so callers should invoke this off the main actor
    /// (e.g. from `Task.detached`).
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

        let cacheDirectory = SceneVideoCache.cacheDirectoryURL()
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let outputURL = SceneVideoCache.cachedVideoURL(assetId: configuration.assetId)
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
        try fileManager.moveItem(at: temporaryOutputURL, to: outputURL)
        return outputURL
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

enum SceneVideoRenderError: Error, LocalizedError {
    case processFailed(String, Int32)
    case noFramesRecorded

    var errorDescription: String? {
        switch self {
        case .processFailed(let name, let status):
            return "\(name) exited with status \(status)."
        case .noFramesRecorded:
            return "The scene renderer did not produce any recorded frames."
        }
    }
}
