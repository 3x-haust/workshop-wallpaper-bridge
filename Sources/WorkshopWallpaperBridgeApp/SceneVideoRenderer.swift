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
    static let cacheVersion = 3

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
            "--assets-dir", configuration.assetsDirectory.path,
            configuration.projectDirectory.path
        ]
    }

    static func ffmpegArguments(framesDirectory: URL, fps: Int, outputURL: URL) -> [String] {
        [
            "-y",
            "-framerate", String(fps),
            "-i", framesDirectory.appending(path: "frame_%05d.png").path,
            "-c:v", "libx264",
            "-pix_fmt", "yuv420p",
            "-crf", "18",
            "-movflags", "+faststart",
            outputURL.path
        ]
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
            ffmpegArguments(framesDirectory: tempDirectory, fps: configuration.fps, outputURL: temporaryOutputURL)
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
