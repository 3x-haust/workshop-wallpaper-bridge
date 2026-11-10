import AppKit
import AVFoundation
import XCTest
import WorkshopWallpaperCore
@testable import WorkshopWallpaperBridgeApp

@MainActor
final class WallpaperContentReadinessTests: XCTestCase {
    func testInvalidLocalVideoReportsPreparationFailure() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "invalid.mp4")
        try Data("not a video".utf8).write(to: url)
        let view = VideoWallpaperView(url: url, fallbackImageURL: nil,
                                     frame: CGRect(x: 0, y: 0, width: 100, height: 100), displayMode: .fit)
        defer { view.prepareForClose() }
        let reported = expectation(description: "Invalid video reports a load error")
        view.whenReady { result in
            if case .success = result { XCTFail("An invalid video cannot be ready") }
            reported.fulfill()
        }

        await fulfillment(of: [reported], timeout: 5)
    }

    func testMissingLocalWebEntrypointReportsPreparationFailure() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let view = RestrictedWebWallpaperView(url: root.appending(path: "missing.html"),
                                             readAccessURL: root,
                                             frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        defer { view.prepareForClose() }
        let reported = expectation(description: "Missing web entrypoint reports a load error")
        view.whenReady { result in
            if case .success = result { XCTFail("A missing web entrypoint cannot be ready") }
            reported.fulfill()
        }

        await fulfillment(of: [reported], timeout: 5)
    }

    func testValidLocalVideoReportsReadyOnlyAfterPlayerItemIsReady() async throws {
        guard let ffmpeg = VideoConverter().ffmpegPath() else { throw XCTSkip("ffmpeg is required for the video fixture") }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "valid.mp4")
        let process = Process()
        process.executableURL = URL(filePath: ffmpeg)
        process.arguments = ["-v", "error", "-f", "lavfi", "-i", "color=c=blue:s=32x32:r=10",
                             "-t", "1", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-threads", "1", url.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let view = VideoWallpaperView(url: url, fallbackImageURL: nil,
                                     frame: CGRect(x: 0, y: 0, width: 100, height: 100), displayMode: .fit)
        defer { view.prepareForClose() }
        view.setPlaybackSuspended(true)
        let ready = expectation(description: "Valid video becomes ready")
        view.whenReady { result in
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }
            XCTAssertEqual(view.playerLayer.player?.currentItem?.status, .readyToPlay)
            ready.fulfill()
        }

        await fulfillment(of: [ready], timeout: 5)
    }

    func testValidLocalWebDocumentReportsReadyAfterNavigationFinishes() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "index.html")
        try "<!doctype html><html><body>Local wallpaper</body></html>".write(to: url, atomically: true, encoding: .utf8)
        let view = RestrictedWebWallpaperView(url: url, readAccessURL: root,
                                             frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        // No audio capture is needed to verify document readiness.
        view.setPlaybackSuspended(true)
        defer { view.prepareForClose() }
        let ready = expectation(description: "Local document finishes loading")
        view.whenReady { result in
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }
            XCTAssertEqual(view.webView.url, url)
            XCTAssertFalse(view.webView.isLoading)
            ready.fulfill()
        }

        await fulfillment(of: [ready], timeout: 5)
    }

    func testClosedWebViewDoesNotDeliverLateNavigationCallbacks() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let view = RestrictedWebWallpaperView(url: root.appending(path: "missing.html"), readAccessURL: root,
                                             frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        var callbacks = 0
        view.whenReady { _ in callbacks += 1 }

        view.prepareForClose()
        view.webView(view.webView, didFinish: nil)
        view.webView(view.webView, didFailProvisionalNavigation: nil,
                     withError: WallpaperPreparationError(message: "late failure"))

        XCTAssertEqual(callbacks, 0)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
