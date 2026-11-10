import AppKit
import AVFoundation
import XCTest
import WorkshopWallpaperCore
@testable import WorkshopWallpaperBridgeApp

@MainActor
final class VideoPlaybackPreparationTests: XCTestCase {
    func testHEV1RemuxDecodesAndReusesFreshCacheWithoutChangingSource() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root, codec: "libx265", tag: "hev1")
        let original = try Data(contentsOf: source)
        let preparation = VideoPlaybackPreparation(cacheDirectory: root.appending(path: "cache/v1"))
        do {
            try await decode(source)
            XCTFail("The synthetic hev1 fixture must reproduce the unsupported sample entry")
        } catch { XCTAssertEqual((error as NSError).domain, AVFoundationErrorDomain) }

        let firstStart = ContinuousClock.now
        async let first = preparation.prepare(url: source, assetID: "3836674583")
        async let second = preparation.prepare(url: source, assetID: "3836674583")
        let (output, duplicate) = try await (first, second)
        let firstDuration = firstStart.duration(to: .now)

        XCTAssertEqual(output, duplicate)
        XCTAssertEqual(output.lastPathComponent, "3836674583.mp4")
        try await decode(output)
        let modified = try modificationDate(output)
        let cachedStart = ContinuousClock.now
        let cached = try await preparation.prepare(url: source, assetID: "3836674583")
        let cachedDuration = cachedStart.duration(to: .now)
        print("HEVC preparation: first=\(firstDuration), cached=\(cachedDuration)")
        XCTAssertEqual(cached, output)
        XCTAssertEqual(try modificationDate(output), modified)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.deletingLastPathComponent().path).sorted(),
                       ["3836674583.json", "3836674583.mp4"])
    }

    func testH264AndHVC1KeepOriginalURLWithoutCreatingCache() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appending(path: "cache/v1")
        let preparation = VideoPlaybackPreparation(cacheDirectory: cache)
        for (codec, tag) in [("libx264", "avc1"), ("libx265", "hvc1")] {
            let source = try fixture(in: root, codec: codec, tag: tag)
            let output = try await preparation.prepare(url: source, assetID: tag)
            XCTAssertEqual(output, source)
            try await decode(output)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
    }

    func testChangedSourceDateSizeAndURLInvalidateCache() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root, codec: "libx265", tag: "hev1")
        let preparation = VideoPlaybackPreparation(cacheDirectory: root.appending(path: "cache/v1"))
        let output = try await preparation.prepare(url: source, assetID: "video")
        let metadata = output.deletingPathExtension().appendingPathExtension("json")
        let oldMetadata = try Data(contentsOf: metadata)
        let oldDate = try modificationDate(source)
        try FileManager.default.setAttributes([.modificationDate: oldDate.addingTimeInterval(10)], ofItemAtPath: source.path)
        _ = try await preparation.prepare(url: source, assetID: "video")
        let changedDateMetadata = try Data(contentsOf: metadata)
        XCTAssertNotEqual(changedDateMetadata, oldMetadata)

        let handle = try FileHandle(forWritingTo: source)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0, count: 8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: oldDate.addingTimeInterval(10)], ofItemAtPath: source.path)
        _ = try await preparation.prepare(url: source, assetID: "video")
        let changedSizeMetadata = try Data(contentsOf: metadata)
        XCTAssertNotEqual(changedSizeMetadata, changedDateMetadata)

        let other = root.appending(path: "other.mp4")
        try FileManager.default.copyItem(at: source, to: other)
        _ = try await preparation.prepare(url: other, assetID: "video")
        XCTAssertNotEqual(try Data(contentsOf: metadata), changedSizeMetadata)
        try await decode(output)
    }

    func testUnsafeAssetIDsAndSymlinkedCacheAreRejected() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root, codec: "libx265", tag: "hev1")
        let cache = root.appending(path: "cache/v1")
        let preparation = VideoPlaybackPreparation(cacheDirectory: cache)
        for id in ["../outside", "", "/absolute", "a/b", ".", ".."] {
            do {
                _ = try await preparation.prepare(url: source, assetID: id)
                XCTFail("Unsafe asset ID accepted: \(id)")
            } catch { }
        }
        let outside = root.appending(path: "outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "cache"), withDestinationURL: outside)
        do {
            _ = try await preparation.prepare(url: source, assetID: "safe")
            XCTFail("A symlinked cache ancestor must not be followed")
        } catch { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    func testSymlinkedCacheOutputAndMetadataAreRejectedWithoutChangingTarget() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root, codec: "libx265", tag: "hev1")
        let cache = root.appending(path: "cache/v1")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let outside = root.appending(path: "outside")
        let original = Data("untouched".utf8)
        try original.write(to: outside)
        let preparation = VideoPlaybackPreparation(cacheDirectory: cache)

        for name in ["safe.mp4", "safe.json"] {
            let link = cache.appending(path: name)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            do {
                _ = try await preparation.prepare(url: source, assetID: "safe")
                XCTFail("A symlinked cache entry must not be followed: \(name)")
            } catch {
                XCTAssertEqual(error.localizedDescription, "The video cache must not contain symbolic links.")
            }
            XCTAssertEqual(try Data(contentsOf: outside), original)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path), [name])
            try FileManager.default.removeItem(at: link)
        }
    }

    func testCancellationWaitsForProcessExitAndPublishesNothing() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root, codec: "libx265", tag: "hev1")
        let script = root.appending(path: "ffmpeg")
        let started = root.appending(path: "started")
        let exited = root.appending(path: "exited")
        try "#!/bin/sh\ntrap 'touch \"\(exited.path)\"; exit 143' TERM\ntouch \"\(started.path)\"\nwhile :; do :; done\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let cache = root.appending(path: "cache/v1")
        let preparation = VideoPlaybackPreparation(cacheDirectory: cache, ffmpegPath: script.path)
        let task = Task { try await preparation.prepare(url: source, assetID: "cancel") }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: started.path), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))
        XCTAssertTrue(preparation.isPreparing(assetID: "cancel"))

        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled remux must not return a cache") }
        catch { XCTAssertTrue(error is CancellationError) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: exited.path))
        XCTAssertFalse(preparation.isPreparing(assetID: "cancel"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path), [])
    }

    func testClosingBeforePreparationSuppressesCallbacksAndPreservesSettingsWhileSuspended() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root, codec: "libx264", tag: "avc1")
        let view = VideoWallpaperView(url: source, fallbackImageURL: nil, frame: .zero, displayMode: .fit)
        view.setPlaybackSuspended(true)
        view.setAudioEnabled(true, volume: 0.2)
        view.setDisplayMode(.fill)
        let ready = expectation(description: "Decoded video prepared while suspended")
        view.whenReady { result in
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }
            XCTAssertEqual(view.playerLayer.player?.rate, 0)
            XCTAssertEqual(view.playerLayer.player?.volume, 0.2)
            XCTAssertEqual(view.playerLayer.player?.isMuted, false)
            XCTAssertEqual(view.playerLayer.videoGravity, .resizeAspectFill)
            ready.fulfill()
        }
        await fulfillment(of: [ready], timeout: 5)
        view.prepareForClose()
        let closed = VideoWallpaperView(url: source, fallbackImageURL: nil, frame: .zero, displayMode: .fit)
        closed.whenReady { _ in XCTFail("Closed video must not call its readiness handler") }
        closed.prepareForClose()
        await Task.yield()
        XCTAssertNil(closed.playerLayer.player)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(path: "video-preparation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func modificationDate(_ url: URL) throws -> Date {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    }

    private func decode(_ url: URL) async throws {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.maximumSize = CGSize(width: 32, height: 32)
        let result = try await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600))
        XCTAssertGreaterThan(result.image.width, 0)
    }

    private func fixture(in root: URL, codec: String, tag: String) throws -> URL {
        guard let ffmpeg = VideoConverter().ffmpegPath() else { throw XCTSkip("ffmpeg is required for synthetic video fixtures") }
        let url = root.appending(path: "\(tag).mp4")
        let process = Process()
        process.executableURL = URL(filePath: ffmpeg)
        process.arguments = ["-v", "error", "-f", "lavfi", "-i", "color=c=blue:s=64x64:r=10", "-t", "1",
                             "-c:v", codec, "-pix_fmt", codec == "libx265" ? "yuv420p10le" : "yuv420p", "-threads", "1"]
        if codec == "libx265" { process.arguments! += ["-x265-params", "pools=1:frame-threads=1:log-level=error"] }
        process.arguments! += ["-tag:v", tag, url.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return url
    }
}
