import AppKit
import AVFoundation
import WorkshopWallpaperCore

struct StillWallpaperImageProvider {
    let cacheDirectory: URL
    private let exportVideoFrame: (URL, String, URL) throws -> URL

    init(
        cacheDirectory: URL = Self.defaultCacheDirectory(),
        exportVideoFrame: @escaping (URL, String, URL) throws -> URL = Self.exportVideoFrame
    ) {
        self.cacheDirectory = cacheDirectory
        self.exportVideoFrame = exportVideoFrame
    }

    func stillImageURL(for asset: WallpaperAsset) throws -> URL {
        if asset.kind == .video {
            guard let entrypoint = playableVideoURL(for: asset.entrypoint) else {
                throw SystemWallpaperError.conversionRequiredForStillImage
            }
            return try exportVideoFrame(entrypoint, asset.id, cacheDirectory)
        }
        if asset.kind == .image, let entrypoint = stillImageURL(for: asset.entrypoint) {
            return try normalizeStillImage(entrypoint, assetId: asset.id)
        }
        if let thumbnail = stillImageURL(for: asset.thumbnail) {
            return try normalizeStillImage(thumbnail, assetId: asset.id)
        }
        throw SystemWallpaperError.noStillImage
    }

    private static func defaultCacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base
            .appending(path: "WorkshopWallpaperBridge")
            .appending(path: "GeneratedStillWallpapers")
    }

    private func playableVideoURL(for path: String?) -> URL? {
        guard let path else {
            return nil
        }
        let url = URL(filePath: path)
        guard playableVideoExtensions.contains(url.pathExtension.lowercased()) else {
            return nil
        }
        return url
    }

    private func stillImageURL(for path: String?) -> URL? {
        guard let path else {
            return nil
        }
        let url = URL(filePath: path)
        guard stillImageExtensions.contains(url.pathExtension.lowercased()) else {
            return nil
        }
        return url
    }

    private static func exportVideoFrame(from videoURL: URL, assetId: String, cacheDirectory: URL) throws -> URL {
        let output = cacheURL(assetId: assetId, cacheDirectory: cacheDirectory)
        do {
            try exportVideoFrameWithAVFoundation(from: videoURL, to: output, cacheDirectory: cacheDirectory)
        } catch {
            try exportVideoFrameWithFFmpeg(from: videoURL, to: output)
        }
        return output
    }

    private static func exportVideoFrameWithAVFoundation(
        from videoURL: URL,
        to output: URL,
        cacheDirectory: URL
    ) throws {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        generator.appliesPreferredTrackTransform = true
        let image: CGImage
        do {
            image = try generator.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil)
        } catch {
            image = try generator.copyCGImage(at: .zero, actualTime: nil)
        }
        try writePNG(NSBitmapImageRep(cgImage: image), to: output, cacheDirectory: cacheDirectory)
    }

    private static func exportVideoFrameWithFFmpeg(from videoURL: URL, to output: URL) throws {
        guard let ffmpeg = VideoConverter().ffmpegPath() else {
            throw SystemWallpaperError.noStillImage
        }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(filePath: ffmpeg)
        process.arguments = [
            "-y",
            "-ss",
            "0",
            "-i",
            videoURL.path,
            "-frames:v",
            "1",
            output.path
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: output.path) else {
            throw SystemWallpaperError.noStillImage
        }
    }

    private func normalizeStillImage(_ url: URL, assetId: String) throws -> URL {
        let output = cacheURL(assetId: assetId)
        let data = try LockScreenWallpaperCache().pngData(from: url)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try data.write(to: output, options: [.atomic])
        return output
    }

    private static func writePNG(_ representation: NSBitmapImageRep, to output: URL, cacheDirectory: URL) throws {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw SystemWallpaperError.noStillImage
        }
        try data.write(to: output, options: [.atomic])
    }

    private func cacheURL(assetId: String) -> URL {
        Self.cacheURL(assetId: assetId, cacheDirectory: cacheDirectory)
    }

    private static func cacheURL(assetId: String, cacheDirectory: URL) -> URL {
        cacheDirectory.appending(path: "\(safeFileName(assetId))-still.png")
    }

    private static func safeFileName(_ value: String) -> String {
        value
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }
}

private let playableVideoExtensions = ["mp4", "mov", "m4v"]
private let stillImageExtensions = ["jpg", "jpeg", "png", "gif", "heic"]
