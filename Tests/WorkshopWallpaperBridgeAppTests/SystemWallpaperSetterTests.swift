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

    func testDesktopStillWallpaperDoesNotWriteLockScreenCache() throws {
        // Given
        let imageURL = URL(filePath: "/tmp/preview.jpg")
        let asset = makeAsset(kind: .image, entrypoint: imageURL.path, thumbnail: nil)
        var desktopImageURL: URL?
        var didWriteLockScreen = false
        let setter = SystemWallpaperSetter(
            resolveStillImage: { _ in imageURL },
            setDesktopImage: { desktopImageURL = $0 },
            setLockScreenImage: { _ in
                didWriteLockScreen = true
                return nil
            }
        )

        // When
        let result = try setter.setDesktopStillWallpaper(from: asset)

        // Then
        XCTAssertEqual(result, imageURL)
        XCTAssertEqual(desktopImageURL, imageURL)
        XCTAssertFalse(didWriteLockScreen)
    }

    func testPlaybackConfiguresDesktopTransitionFallback() throws {
        // Given
        let source = try String(contentsOfFile: "Sources/WorkshopWallpaperBridgeApp/AppViewModel.swift")
        let start = try XCTUnwrap(source.range(of: "private func play(asset: WallpaperAsset, remember: Bool)"))
        let end = try XCTUnwrap(source.range(of: "private func refreshLockScreenAnimationConfiguration", range: start.lowerBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        // Then
        XCTAssertTrue(body.contains("setDesktopTransitionFallback(asset: asset)"))
        XCTAssertTrue(source.contains("setDesktopStillWallpaper(from: asset)"))
    }

    func testStillImageProviderExtractsVideoFrameBeforeGifThumbnail() throws {
        // Given
        let root = try makeTempDirectory()
        let videoURL = root.appending(path: "clip.mp4")
        let thumbnailURL = root.appending(path: "preview.gif")
        try makeVideo(at: videoURL)
        try Data("GIF89a".utf8).write(to: thumbnailURL)
        let provider = StillWallpaperImageProvider(cacheDirectory: root.appending(path: "cache"))
        let asset = makeAsset(kind: .video, entrypoint: videoURL.path, thumbnail: thumbnailURL.path)

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
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 64,
                AVVideoHeightKey: 36
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64,
                kCVPixelBufferHeightKey as String: 36
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let buffer = try makePixelBuffer(width: 64, height: 36)
        XCTAssertTrue(adaptor.append(buffer, withPresentationTime: .zero))
        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()
        if let error = writer.error {
            throw error
        }
        XCTAssertEqual(writer.status, .completed)
    }

    private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw SystemWallpaperError.noStillImage
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            throw SystemWallpaperError.noStillImage
        }
        memset(baseAddress, 0x80, CVPixelBufferGetDataSize(buffer))
        return buffer
    }
}
