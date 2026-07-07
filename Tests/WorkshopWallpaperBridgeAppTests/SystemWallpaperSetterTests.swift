import AppKit
import AVFoundation
import XCTest
@testable import WorkshopWallpaperBridgeApp
import WorkshopWallpaperCore

@MainActor
final class SystemWallpaperSetterTests: XCTestCase {
    func testStillWallpaperSetterWritesDesktopAndLockScreenCache() throws {
        // Given
        let imageURL = URL(filePath: "/tmp/preview.jpg")
        let lockScreenURL = URL(filePath: "/tmp/lockscreen.png")
        let asset = WallpaperAsset(
            id: "still",
            title: "Still",
            kind: .scene,
            supportStatus: .unsupported,
            source: .manualFolder,
            projectDirectory: "/tmp/still",
            entrypoint: "/tmp/scene.pkg",
            thumbnail: imageURL.path,
            workshopId: nil,
            redistributionAllowed: false,
            issues: []
        )
        var desktopImageURL: URL?
        var lockScreenImageURL: URL?
        let setter = SystemWallpaperSetter(
            resolveStillImage: { _ in imageURL },
            setDesktopImage: { desktopImageURL = $0 },
            setLockScreenImage: {
                lockScreenImageURL = $0
                return lockScreenURL
            }
        )

        // When
        let result = try setter.setStillWallpaper(from: asset)

        // Then
        XCTAssertEqual(desktopImageURL, imageURL)
        XCTAssertEqual(lockScreenImageURL, imageURL)
        XCTAssertEqual(result.imageURL, imageURL)
        XCTAssertEqual(result.lockScreenCacheURL, lockScreenURL)
        XCTAssertNil(result.lockScreenErrorDescription)
    }

    func testStillWallpaperSetterReportsLockScreenWriteFailure() throws {
        // Given
        let imageURL = URL(filePath: "/tmp/preview.jpg")
        let asset = makeAsset(kind: .image, entrypoint: imageURL.path, thumbnail: nil)
        let setter = SystemWallpaperSetter(
            resolveStillImage: { _ in imageURL },
            setDesktopImage: { _ in },
            setLockScreenImage: { _ in throw SystemWallpaperError.lockScreenCacheUnavailable }
        )

        // When
        let result = try setter.setStillWallpaper(from: asset)

        // Then
        XCTAssertEqual(result.imageURL, imageURL)
        XCTAssertNil(result.lockScreenCacheURL)
        XCTAssertEqual(result.lockScreenErrorDescription, "The macOS Lock Screen wallpaper cache is not available.")
    }

    func testPlaybackDoesNotChangeDesktopStillWallpaper() throws {
        // Given
        let source = try String(contentsOfFile: "Sources/WorkshopWallpaperBridgeApp/AppViewModel.swift")
        let start = try XCTUnwrap(source.range(of: "private func play(asset: WallpaperAsset, remember: Bool)"))
        let end = try XCTUnwrap(source.range(of: "private func refreshLockScreenAnimationConfiguration", range: start.lowerBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        // Then
        XCTAssertFalse(body.contains("setStillWallpaper(from: asset)"))
        XCTAssertFalse(body.contains("setDesktop"))
    }

    func testStillImageProviderExtractsVideoFrameBeforeGifThumbnail() throws {
        // Given
        let root = try makeTempDirectory()
        let videoURL = root.appending(path: "clip.mp4")
        let thumbnailURL = root.appending(path: "preview.gif")
        try makeVideo(at: videoURL)
        try Data("GIF89a".utf8).write(to: thumbnailURL)
        let cacheDirectory = root.appending(path: "cache")
        var exportedVideoURL: URL?
        let provider = StillWallpaperImageProvider(
            cacheDirectory: cacheDirectory,
            exportVideoFrame: { videoURL, assetId, cacheDirectory in
                exportedVideoURL = videoURL
                let output = cacheDirectory.appending(path: "\(assetId)-still.png")
                try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
                try self.makeImage(at: output)
                return output
            }
        )
        let asset = makeAsset(kind: .video, entrypoint: videoURL.path, thumbnail: thumbnailURL.path)

        // When
        let output = try provider.stillImageURL(for: asset)

        // Then
        XCTAssertEqual(output.pathExtension, "png")
        XCTAssertEqual(exportedVideoURL, videoURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertGreaterThan(try Data(contentsOf: output).count, 0)
    }

    func testDefaultStillImageProviderExtractsPlayableVideoFrameWhenAVFoundationCanDecodeFixture() throws {
        // Given
        let root = try makeTempDirectory()
        let videoURL = root.appending(path: "clip.mp4")
        try makeVideo(at: videoURL)
        let provider = StillWallpaperImageProvider(cacheDirectory: root.appending(path: "cache"))
        let asset = makeAsset(kind: .video, entrypoint: videoURL.path, thumbnail: nil)

        // When
        let output = try provider.stillImageURL(for: asset)

        // Then
        XCTAssertEqual(output.pathExtension, "png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertGreaterThan(try Data(contentsOf: output).count, 0)
    }

    func testStillImageProviderRequiresConversionBeforeUsingConvertibleVideoThumbnail() throws {
        // Given
        let root = try makeTempDirectory()
        let videoURL = root.appending(path: "clip.webm")
        let thumbnailURL = root.appending(path: "preview.gif")
        try Data().write(to: videoURL)
        try makeImage(at: thumbnailURL)
        let provider = StillWallpaperImageProvider(cacheDirectory: root.appending(path: "cache"))
        let asset = makeAsset(kind: .video, entrypoint: videoURL.path, thumbnail: thumbnailURL.path)

        XCTAssertThrowsError(try provider.stillImageURL(for: asset)) { error in
            XCTAssertEqual(error as? SystemWallpaperError, .conversionRequiredForStillImage)
        }
    }

    func testStillImageProviderNormalizesGifThumbnailToPNG() throws {
        // Given
        let root = try makeTempDirectory()
        let imageURL = root.appending(path: "preview.gif")
        try makeImage(at: imageURL)
        let provider = StillWallpaperImageProvider(cacheDirectory: root.appending(path: "cache"))
        let asset = makeAsset(kind: .scene, entrypoint: nil, thumbnail: imageURL.path)

        // When
        let output = try provider.stillImageURL(for: asset)

        // Then
        XCTAssertEqual(output.pathExtension, "png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    func testLockScreenCachePathUsesGeneratedUID() {
        // When
        let url = LockScreenWallpaperCache.cacheFileURL(generatedUID: "USER-UUID")

        // Then
        XCTAssertEqual(url.path, "/Library/Caches/Desktop Pictures/USER-UUID/lockscreen.png")
    }

    private func makeAsset(
        kind: WallpaperKind,
        entrypoint: String?,
        thumbnail: String?
    ) -> WallpaperAsset {
        WallpaperAsset(
            id: "still asset",
            title: "Still",
            kind: kind,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: "/tmp/still",
            entrypoint: entrypoint,
            thumbnail: thumbnail,
            workshopId: nil,
            redistributionAllowed: false,
            issues: []
        )
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "WorkshopWallpaperBridgeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeImage(at url: URL) throws {
        let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 32,
            pixelsHigh: 18,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let representation,
              let data = representation.representation(using: .png, properties: [:]) else {
            throw SystemWallpaperError.noStillImage
        }
        try data.write(to: url)
    }

    private func makeVideo(at url: URL) throws {
        guard let ffmpeg = VideoConverter().ffmpegPath() else {
            throw XCTSkip("ffmpeg is required to create the video fixture.")
        }
        let process = Process()
        process.executableURL = URL(filePath: ffmpeg)
        process.arguments = [
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-f",
            "lavfi",
            "-i",
            "testsrc=size=32x32:rate=1:duration=1",
            "-frames:v",
            "1",
            url.path
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
