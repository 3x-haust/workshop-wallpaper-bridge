import AppKit
import AVFoundation
import XCTest
import WorkshopWallpaperCore
@testable import WorkshopWallpaperBridgeApp

/// Opt-in tests use the private local library without checking in creator assets.
@MainActor
final class LocalScenePlaybackTests: XCTestCase {
    func testLocalSceneRendering() async throws {
        guard let library = ProcessInfo.processInfo.environment["WWB_LOCAL_SCENE_LIBRARY"] else {
            throw XCTSkip("Set WWB_LOCAL_SCENE_LIBRARY to a copied local library")
        }
        let previousExecutable = SceneEngineRendererConfiguration.overrideExecutablePath
        let previousResources = SceneEngineRendererConfiguration.overrideResourceURL
        SceneEngineRendererConfiguration.overrideExecutablePath = "/nonexistent/wwb-test-renderer"
        SceneEngineRendererConfiguration.overrideResourceURL = URL(filePath: "/nonexistent/wwb-test-resources")
        defer {
            SceneEngineRendererConfiguration.overrideExecutablePath = previousExecutable
            SceneEngineRendererConfiguration.overrideResourceURL = previousResources
        }
        let root = URL(filePath: library)
        let data = try Data(contentsOf: root.appending(path: "library.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let assets = try XCTUnwrap(json["assets"] as? [[String: Any]])
        for asset in assets where asset["kind"] as? String == "scene" {
            let url = URL(filePath: try XCTUnwrap(asset["entrypoint"] as? String))
            let id = try XCTUnwrap(asset["id"] as? String)
            let plan = try SceneRenderPlanBuilder().build(url: url)
            let layout = try SceneRenderPlanBuilder().buildLayout(url: url)
            print("LOCAL SCENE \(id): layout=\(layout.layers.count) decoded=\(plan.layers.count) scripts=\(plan.requiresLivePlayback)")
            let preview = (asset["thumbnail"] as? String).map { URL(filePath: $0) }
            let view = try SceneWallpaperView(url: url, previewURL: preview,
                frame: CGRect(x: 0, y: 0, width: 960, height: 624), displayMode: .fill)
            let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 960, height: 624),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.orderFrontRegardless()
            let decodeDeadline = Date().addingTimeInterval(15)
            while !view.isShowingDecodedScene, view.scriptDiagnostic == nil, Date() < decodeDeadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertTrue(view.isShowingDecodedScene || view.scriptDiagnostic != nil, "Decoding did not finish for \(id)")
            if let output = ProcessInfo.processInfo.environment["WWB_LOCAL_SCENE_SNAPSHOTS"] {
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(filePath: output).appending(path: "native-\(id).png"))
            }
            print("LOCAL DIAGNOSTIC \(id): \(view.scriptDiagnostic ?? "none")")
            view.prepareForClose()
            window.contentView = nil
            window.close()
            XCTAssertTrue(plan.hasRenderableContent)
            XCTAssertFalse(layout.canPreferLivePlayback, "The current local corpus requires the full rendering path")
            XCTAssertEqual(view.isShowingDecodedScene, plan.omittedLayerCount == 0)
            let wallpaper = WallpaperAsset(id: id, title: asset["title"] as? String ?? id, kind: .scene,
                supportStatus: .playable, source: .manualFolder, projectDirectory: url.deletingLastPathComponent().path,
                entrypoint: url.path, thumbnail: preview?.path, workshopId: nil, redistributionAllowed: false, issues: [])
            let playback = try SceneWallpaperContentFactory.makeSceneContentView(asset: wallpaper, url: url,
                previewURL: preview, frame: CGRect(x: 0, y: 0, width: 960, height: 624), displayMode: .fill)
            defer { (playback as? WallpaperContentLifecycle)?.prepareForClose() }
            let video = try XCTUnwrap((playback as? MediaSceneWallpaperView)?.background ?? playback as? VideoWallpaperView,
                                     "\(id) must retain the rendered background")
            let readyDeadline = Date().addingTimeInterval(5)
            while video.playerLayer.player?.currentItem == nil, Date() < readyDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let videoAsset = try XCTUnwrap(video.playerLayer.player?.currentItem?.asset as? AVURLAsset)
            let isPlayable = try await videoAsset.load(.isPlayable)
            XCTAssertTrue(isPlayable)
            let generator = AVAssetImageGenerator(asset: videoAsset)
            generator.maximumSize = CGSize(width: 960, height: 624)
            let first = try await generator.image(at: CMTime(seconds: 2, preferredTimescale: 600)).image
            let second = try await generator.image(at: CMTime(seconds: 8, preferredTimescale: 600)).image
            let firstPNG = NSBitmapImageRep(cgImage: first).representation(using: .png, properties: [:])
            let secondPNG = NSBitmapImageRep(cgImage: second).representation(using: .png, properties: [:])
            XCTAssertNotEqual(firstPNG, secondPNG, "\(id) must contain changing frames")
            if let output = ProcessInfo.processInfo.environment["WWB_LOCAL_SCENE_SNAPSHOTS"] {
                try firstPNG?.write(to: URL(filePath: output).appending(path: "playback-\(id).png"))
            }
            print("LOCAL PLAYBACK \(id): \(videoAsset.url.path), playable, changing frames")
        }
    }
}
