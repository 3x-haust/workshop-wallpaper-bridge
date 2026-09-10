import AppKit
import CoreImage
import AVFoundation
import XCTest
@testable import WorkshopWallpaperBridgeApp

@MainActor
final class SceneMediaIntegrationTests: XCTestCase {
    func testLocalMusicPlayerRead() async throws {
        guard ProcessInfo.processInfo.environment["WWB_LOCAL_MUSIC_READ"] == "1" else { throw XCTSkip("Opt-in running Music integration check") }
        let result = await Task.detached { MusicMetadataSource.read(player: "com.apple.Music") }.value
        XCTAssertNil(result.error)
        let snapshot = try XCTUnwrap(result.snapshot)
        XCTAssertEqual(snapshot.state, 1)
        XCTAssertFalse(snapshot.title.isEmpty)
        XCTAssertNotNil(snapshot.artwork)
        print("MUSIC READ: playing, title present, artwork bytes \(snapshot.artwork?.count ?? 0)")
    }
    func testSnapshotAdvancesPlayingTimelineButFreezesPausedAndStaleSamples() {
        let date = Date(timeIntervalSince1970: 100)
        var snapshot = WallpaperMediaSnapshot(enabled: true, state: 1, position: 10, duration: 60, receivedAt: date)
        XCTAssertEqual(snapshot.frame(at: date.addingTimeInterval(2))["position"] as? Double, 12)
        XCTAssertEqual(snapshot.frame(at: date.addingTimeInterval(20))["position"] as? Double, 13)
        snapshot.state = 2
        XCTAssertEqual(snapshot.frame(at: date.addingTimeInterval(2))["position"] as? Double, 10)
        snapshot.duration = 235.32000732421875
        XCTAssertEqual(snapshot.frame()["duration"] as? Double, 235, "Authored minute/second formatters must not receive floating-point tails")
    }

    func testArtworkRequestsStayOnTheHTTPSImageService() {
        for address in ["https://i.scdn.co/image/a", "https://i.scdn.co:443/image/a"] {
            XCTAssertTrue(MusicMetadataSource.allowedArtworkURL(URL(string: address)!))
        }
        for address in ["http://i.scdn.co/image/a", "https://i.scdn.co.evil.test/a", "https://user@i.scdn.co/a", "https://i.scdn.co:444/a", "file:///tmp/a"] {
            XCTAssertFalse(MusicMetadataSource.allowedArtworkURL(URL(string: address)!))
        }
    }

    func testLocalSummerMediaScripts() throws {
        guard let library = ProcessInfo.processInfo.environment["WWB_LOCAL_SCENE_LIBRARY"] else {
            throw XCTSkip("Set WWB_LOCAL_SCENE_LIBRARY to test private creator content")
        }
        let url = URL(filePath: library).appending(path: "Assets/id-MzAwMDU2MjQyNw/scene.pkg")
        let plan = try XCTUnwrap(SceneMediaOverlayPlan.build(url: url))
        let bindings = ((plan.configuration["layers"] as? [[String: Any]] ?? [])
            + (plan.configuration["objects"] as? [[String: Any]] ?? []))
            .flatMap { $0["scripts"] as? [[String: Any]] ?? [] }
        XCTAssertEqual(bindings.count, 80, "Count nested effect scripts as well as layer bindings")
        XCTAssertTrue(plan.excludedIDs.contains(432))
        for id in [610, 5551, 2667, 9126, 120904, 4729, 2772] {
            XCTAssertTrue(plan.excludedIDs.contains(id), "Scripted day/night layers must leave the fixed video: \(id)")
        }
        XCTAssertEqual(plan.particles.count, 4)
        let runtime = try SceneScriptWorkerRuntime()
        var state: [Int: [String: Any]] = [:]
        var objects: [String: [String: Any]] = [:]
        func send(_ request: [String: Any]) throws {
            let data = try runtime.respond(to: JSONSerialization.data(withJSONObject: request))
            let response = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual((response["errors"] as? [Any])?.count, 0, "\(response["errors"] ?? "")")
            for layer in response["layers"] as? [[String: Any]] ?? [] {
                if let id = layer["id"] as? Int, let values = layer["values"] as? [String: Any] {
                    state[id, default: [:]].merge(values) { _, new in new }
                }
            }
            for object in response["objects"] as? [[String: Any]] ?? [] {
                if let id = object["id"] as? String, let values = object["values"] as? [String: Any] {
                    objects[id, default: [:]].merge(values) { _, new in new }
                }
            }
        }
        var media = WallpaperMediaSnapshot(enabled: true, state: 1, title: "Test Song", artist: "Test Artist", albumTitle: "Album", position: 65, duration: 240)
        media.artwork = Data([1]); media.artworkRevision = "first"
        try send(["configure": plan.configuration, "frame": ["time": 0, "now": Date().timeIntervalSince1970*1000, "media": media.frame(at: media.receivedAt)]])
        for id in ["205/effect/206", "205/effect/208", "396/effect/397", "396/effect/399"] {
            XCTAssertEqual(objects[id]?["visible"] as? Bool, true)
        }
        for index in 1...120 {
            try send(["frame": ["time": Double(index)/30, "frameTime": 1.0/30, "now": Date().timeIntervalSince1970*1000, "media": media.frame(at: media.receivedAt)]])
        }
        XCTAssertEqual(state[432]?["text"] as? String, "Test Song")
        XCTAssertEqual(state[780]?["text"] as? String, "Test Artist  —  Album")
        // The authored script advances seconds between timeline notifications.
        XCTAssertEqual(state[1126]?["text"] as? String, "1:08")
        XCTAssertEqual(state[284]?["text"] as? String, "4:00")
        XCTAssertEqual(state[51]?["alpha"] as? Double, 0)
        XCTAssertGreaterThan(state[432]?["alpha"] as? Double ?? 0, 0.5)
        for id in ["205/effect/208", "396/effect/399"] {
            XCTAssertEqual(objects[id]?["visible"] as? Bool, false)
            XCTAssertEqual(objects[id + "/multiply"]?["value"] as? Double, 0)
        }
        // A second cover restarts both the wipe and the one-second hide timer.
        media.artworkRevision = "second"
        try send(["frame": ["time": 4.0, "media": media.frame(at: media.receivedAt)]])
        for id in ["205/effect/208", "396/effect/399"] {
            XCTAssertEqual(objects[id]?["visible"] as? Bool, true)
            XCTAssertEqual(try XCTUnwrap(objects[id + "/multiply"]?["value"] as? Double), 1, accuracy: 0.0001)
        }
        media.state = 2
        for index in 121...240 {
            try send(["frame": ["time": Double(index)/30, "frameTime": 1.0/30, "media": media.frame(at: media.receivedAt)]])
        }
        XCTAssertEqual(state[432]?["alpha"] as? Double, 0)
        XCTAssertGreaterThan(state[51]?["alpha"] as? Double ?? 0, 0.5)
        for hour in [12, 23] {
            let date = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: hour)))
            try send(["frame": ["time": 9.0 + Double(hour), "now": date.timeIntervalSince1970 * 1000,
                                "media": media.frame(at: media.receivedAt)]])
            let night = hour == 23
            for id in [610, 2667, 4729, 2772, 819, 756, 1065, 822] { XCTAssertEqual(state[id]?["visible"] as? Bool, night) }
            for id in [5551, 9126, 120904] { XCTAssertEqual(state[id]?["visible"] as? Bool, !night) }
        }
        // The creator checks thisLayer.maxwidth before starting a marquee.
        // Verify a long title reaches the scrolling branch, not just metadata.
        var scrolling = plan.configuration
        var properties = scrolling["userProperties"] as? [String: Any] ?? [:]
        properties["enabletypinganimation"] = false
        scrolling["userProperties"] = properties
        media.state = 1
        media.title = String(repeating: "A long title for a narrow display panel ", count: 5)
        try send(["configure": scrolling, "frame": ["time": 0, "media": media.frame(at: media.receivedAt)]])
        var sawScroll = false
        for index in 1...900 {
            try send(["frame": ["time": Double(index) / 30, "frameTime": 1.0 / 30, "media": media.frame(at: media.receivedAt)]])
            if let title = state[432]?["text"] as? String, !title.isEmpty, title != media.title { sawScroll = true }
        }
        XCTAssertTrue(sawScroll, "Long titles must use the original scrolling script")
        let quiet = SceneAudioParticles(plan: try XCTUnwrap(plan.particles.first))
        let loud = SceneAudioParticles(plan: try XCTUnwrap(plan.particles.first))
        for _ in 0..<60 {
            quiet.step(seconds: 1.0/30, spectrum: WallpaperAudioSpectrum())
            loud.step(seconds: 1.0/30, spectrum: WallpaperAudioSpectrum(left: Array(repeating: 1, count: 64), right: Array(repeating: 1, count: 64)))
        }
        XCTAssertGreaterThan(loud.motionEnergy, quiet.motionEnergy*2)
        if let output = ProcessInfo.processInfo.environment["WWB_LOCAL_SCENE_SNAPSHOTS"] {
            try JSONSerialization.data(withJSONObject: plan.excludedIDs).write(to: URL(filePath: output).appending(path: "media-excluded.json"))
        }
    }

    func testLocalSummerViewSessionAndCanvasRatio() async throws {
        guard let library = ProcessInfo.processInfo.environment["WWB_LOCAL_SCENE_LIBRARY"],
              let video = ProcessInfo.processInfo.environment["WWB_LOCAL_MEDIA_VIDEO"] else {
            throw XCTSkip("Set local library and excluded-background video paths")
        }
        var plan = try XCTUnwrap(SceneMediaOverlayPlan.build(url: URL(filePath: library).appending(path: "Assets/id-MzAwMDU2MjQyNw/scene.pkg")))
        var properties = plan.configuration["userProperties"] as? [String: Any] ?? [:]
        properties["displaypanelglicheffect"] = true
        properties["displaypanelglicheffectprob"] = 1.0
        properties["displaypanelglicheffectmaxduration"] = 100_000
        properties["displaypanelglicheffectcooldownduration"] = 0
        // This view test checks media delivery and GPU composition. The original
        // title script has randomized typing mistakes, so a fixed wall-clock
        // wait cannot establish when its authored typing animation is complete.
        properties["enabletypinganimation"] = false
        plan.configuration["userProperties"] = properties
        let view = MediaSceneWallpaperView(videoURL: URL(filePath: video), previewURL: nil, plan: plan,
                                          frame: CGRect(x: 0, y: 0, width: 1440, height: 600))
        XCTAssertTrue(WallpaperInteraction.supports(view), "Media scenes must receive mouse clicks in interaction mode")
        var media = WallpaperMediaSnapshot(enabled: true, state: 1, title: "Summer in the City", artist: "Compatibility test", albumTitle: "Local playback", position: 65, duration: 240)
        let artwork = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor.systemOrange.setFill(); rect.fill(); return true
        }
        media.artwork = artwork.tiffRepresentation; media.artworkRevision = "test-art"
        view.mediaProvider = { media }
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 1440, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFrontRegardless()
        defer { view.prepareForClose(); window.contentView = nil; window.close() }
        try await Task.sleep(for: .seconds(5))
        XCTAssertNil(view.diagnostic)
        let contentLayers = view.layer?.sublayers?.flatMap { $0.sublayers ?? [] } ?? []
        let title = try XCTUnwrap(contentLayers.first { $0.name == "Song Title" } as? CATextLayer)
        let clock = try XCTUnwrap(contentLayers.first { $0.name == "mainClock" } as? CATextLayer)
        XCTAssertEqual(title.string as? String, media.title)
        XCTAssertGreaterThan(title.opacity, 0.5)
        XCTAssertEqual(clock.opacity, 0)
        let glitch = try XCTUnwrap(contentLayers.first { $0.name == "GlichyEffectLayerDay" })
        XCTAssertFalse(glitch.isHidden, "The original visibility script must enable the optional compose effect")
        XCTAssertNotNil(glitch.contents, "Script output must produce a composed image from the playing video and live layers")
        view.setPlaybackSuspended(true)
        let heldImage = glitch.contents as AnyObject?
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(glitch.contents as AnyObject? === heldImage, "A suspended view must reject an in-flight GPU result")
        view.setPlaybackSuspended(false)
        let asset = AVURLAsset(url: URL(filePath: video))
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size.width / size.height, plan.canvas.width / plan.canvas.height, accuracy: 0.005,
                       "The background and overlay must use the same canvas aspect ratio")
        media.state = 2
        try await Task.sleep(for: .seconds(4))
        XCTAssertNil(view.diagnostic)
        XCTAssertEqual(title.opacity, 0)
        XCTAssertGreaterThan(clock.opacity, 0.5)
    }
}
