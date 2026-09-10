import AppKit
import XCTest
import WorkshopWallpaperCore
@testable import WorkshopWallpaperBridgeApp

@MainActor
final class LiveScenePlaybackTests: XCTestCase {
    func testAuthoredSceneClockAndShortClickReachNativeView() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Examples/live-scene/scene.json")
        let url = try package(in: root, sceneJSON: String(contentsOf: source, encoding: .utf8))
        let ticks = LiveTestTicks()
        let view = try SceneWallpaperView(url: url, previewURL: nil, frame: CGRect(x:0,y:0,width:960,height:540), displayMode: .fit, sceneTickSource: ticks)
        let window = NSWindow(contentRect:CGRect(x:-10000,y:-10000,width:960,height:540),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.ignoresMouseEvents = false
        window.orderFrontRegardless()
        defer { view.prepareForClose(); window.contentView = nil; window.close() }
        func text(_ name: String) -> String? {
            (view.layer?.sublayers?.last?.sublayers?.first { $0.name == name } as? CATextLayer)?.string as? String
        }
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline, text("Clock") == nil || text("Clock") == "00:00:00" {
            ticks.emit(time: ticks.elapsedTime + 0.05)
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertNotEqual(text("Clock"), "00:00:00")
        XCTAssertNotNil(text("Clock"))
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with:type,location:CGPoint(x:480,y:270),modifierFlags:[],timestamp:0,
                windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1))
            if type == .leftMouseDown { view.mouseDown(with: event) }
            else { view.mouseUp(with: event) }
        }
        let clickDeadline = Date().addingTimeInterval(4)
        while Date() < clickDeadline, text("Click count") != "Click here · 1" {
            ticks.emit(time: ticks.elapsedTime + 0.05)
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertEqual(text("Click count"), "Click here · 1")
        XCTAssertNil(view.scriptDiagnostic)
        if let output = ProcessInfo.processInfo.environment["WWB_SCENE_SNAPSHOT"] {
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(filePath: output))
        }
    }

    func testPackageScriptsReachRenderedLayersAndPauseResumePreservesState() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try package(in: root)
        let ticks = LiveTestTicks()
        let view = try SceneWallpaperView(url: url, previewURL: nil, frame: CGRect(x:0,y:0,width:640,height:360), displayMode: .fit, sceneTickSource: ticks)
        defer { view.prepareForClose() }
        func textLayer() -> CATextLayer? { view.layer?.sublayers?.last?.sublayers?.compactMap { $0 as? CATextLayer }.first }
        try await waitUntil { textLayer()?.string as? String == "100" }
        ticks.emit(time: 2)
        try await waitUntil { textLayer()?.string as? String == "101" }
        let layer = try XCTUnwrap(textLayer())
        XCTAssertEqual(layer.position, CGPoint(x: 20, y: 180))
        XCTAssertEqual(layer.opacity, 0.25)
        view.setPlaybackSuspended(true)
        ticks.emit(time: 3)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(layer.string as? String, "101")
        view.setPlaybackSuspended(false)
        ticks.emit(time: 4)
        try await waitUntil { layer.string as? String == "102" }
        XCTAssertEqual(layer.position, CGPoint(x: 40,y:180))
        XCTAssertNil(view.scriptDiagnostic)
    }

    func testLivePackageBypassesFreshVideoCache() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try package(in: root)
        let oldCache = SceneVideoCache.overrideCacheDirectoryURL
        let oldPreference = SceneWallpaperContentFactory.prefersLivePlayback
        SceneWallpaperContentFactory.prefersLivePlayback = true
        defer { SceneWallpaperContentFactory.prefersLivePlayback = oldPreference }
        SceneVideoCache.overrideCacheDirectoryURL = root
        defer { SceneVideoCache.overrideCacheDirectoryURL = oldCache }
        try Data([1]).write(to: root.appending(path:"live.mp4"))
        let asset = WallpaperAsset(id:"live",title:"Live",kind:.scene,supportStatus:.playable,source:.localSteamWorkshop,
            projectDirectory:root.path,entrypoint:url.path,thumbnail:nil,workshopId:nil,redistributionAllowed:false,issues:[])
        XCTAssertNotNil(SceneVideoCache.freshCachedVideoURL(assetId: "live", sourceURL: url))
        let view = try SceneWallpaperContentFactory.makeSceneContentView(asset:asset,url:url,frame:CGRect(x:0,y:0,width:640,height:360),displayMode:.fit)
        XCTAssertTrue(view is SceneWallpaperView)
        (view as? WallpaperContentLifecycle)?.prepareForClose()
        SceneWallpaperContentFactory.prefersLivePlayback = false
        let fallback = try SceneWallpaperContentFactory.makeSceneContentView(asset:asset,url:url,frame:CGRect(x:0,y:0,width:640,height:360),displayMode:.fit)
        XCTAssertTrue(fallback is VideoWallpaperView, "Disabling the live preference must restore cached video playback")
        (fallback as? WallpaperContentLifecycle)?.prepareForClose()
    }

    func testComplexScriptedSceneKeepsFullVideoEvenWithLivePreference() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try package(in: root, sceneJSON: #"{"objects":[{"id":1,"text":{"value":"Clock","script":"export function update(v) { return v; }"}},{"id":2,"model":"models/cube.json"}]}"#)
        let oldCache = SceneVideoCache.overrideCacheDirectoryURL
        let oldPreference = SceneWallpaperContentFactory.prefersLivePlayback
        SceneVideoCache.overrideCacheDirectoryURL = root
        SceneWallpaperContentFactory.prefersLivePlayback = true
        defer {
            SceneVideoCache.overrideCacheDirectoryURL = oldCache
            SceneWallpaperContentFactory.prefersLivePlayback = oldPreference
        }
        try Data([1]).write(to: root.appending(path: "complex.mp4"))
        let asset = WallpaperAsset(id: "complex", title: "Complex", kind: .scene, supportStatus: .playable,
            source: .manualFolder, projectDirectory: root.path, entrypoint: url.path, thumbnail: nil,
            workshopId: nil, redistributionAllowed: false, issues: [])
        let view = try SceneWallpaperContentFactory.makeSceneContentView(asset: asset, url: url,
            frame: CGRect(x: 0, y: 0, width: 640, height: 360), displayMode: .fit)
        defer { (view as? WallpaperContentLifecycle)?.prepareForClose() }
        XCTAssertTrue(view is VideoWallpaperView)
    }

    func testNativeSceneReplacesPreviewOnlyWhenAllLayersWereDecoded() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let objects = (1...25).map { #"{"id":\#($0),"text":"Layer"}"# }.joined(separator: ",")
        let url = try package(in: root, sceneJSON: "{\"objects\":[\(objects)]}")
        let view = try SceneWallpaperView(url: url, previewURL: nil,
            frame: CGRect(x: 0, y: 0, width: 640, height: 360), displayMode: .fit)
        defer { view.prepareForClose() }
        try await waitUntil { view.scriptDiagnostic != nil }
        XCTAssertFalse(view.isShowingDecodedScene)
        XCTAssertEqual(view.layer?.sublayers?.last?.sublayers?.count ?? 0, 0)
        XCTAssertFalse(view.layer?.sublayers?.first?.isHidden ?? true)

        let completeURL = try package(in: root)
        let completeView = try SceneWallpaperView(url: completeURL, previewURL: nil,
            frame: CGRect(x: 0, y: 0, width: 640, height: 360), displayMode: .fit)
        defer { completeView.prepareForClose() }
        try await waitUntil { completeView.isShowingDecodedScene }
        XCTAssertTrue(completeView.layer?.sublayers?.first?.isHidden ?? false,
                      "The loading thumbnail must not bleed through transparent scene layers")
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(predicate(), "Scene worker did not update the render layer")
    }

    func testPackageWithoutNativeLayersRetainsExistingVideoPlayback() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try package(in: root, sceneJSON: #"{"objects":[{"id":1,"model":"models/cube.json"}]}"#)
        let oldCache = SceneVideoCache.overrideCacheDirectoryURL
        let oldPreference = SceneWallpaperContentFactory.prefersLivePlayback
        SceneVideoCache.overrideCacheDirectoryURL = root
        SceneWallpaperContentFactory.prefersLivePlayback = true
        defer {
            SceneVideoCache.overrideCacheDirectoryURL = oldCache
            SceneWallpaperContentFactory.prefersLivePlayback = oldPreference
        }
        try Data([1]).write(to: root.appending(path:"model.mp4"))
        let asset = WallpaperAsset(id:"model",title:"Model",kind:.scene,supportStatus:.playable,source:.localSteamWorkshop,
            projectDirectory:root.path,entrypoint:url.path,thumbnail:nil,workshopId:nil,redistributionAllowed:false,issues:[])
        let view = try SceneWallpaperContentFactory.makeSceneContentView(asset:asset,url:url,frame:CGRect(x:0,y:0,width:640,height:360),displayMode:.fit)
        XCTAssertTrue(view is VideoWallpaperView)
        (view as? WallpaperContentLifecycle)?.prepareForClose()
    }

    private func fixtureDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path:"wwb-live-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        return root
    }

    private func package(in root: URL, sceneJSON: String? = nil) throws -> URL {
        let scene = sceneJSON ?? #"""
        {"general":{"orthogonalprojection":{"width":640,"height":360}},"objects":[{"id":1,"name":"Counter","size":"240 100",
        "origin":{"value":"320 180 0","script":"export function update(value) { return new Vec3(engine.runtime*10,180,0); }"},
        "alpha":{"value":1,"script":"export function update(value) { return 0.25; }"},
        "text":{"value":"initial","script":"export function init(value) { return '100'; } export function update(value) { return String(Number(value)+1); }"}}]}
        """#
        var bytes = Data()
        func number(_ number: Int) { var n = UInt32(number).littleEndian; bytes.append(Data(bytes:&n,count:4)) }
        func string(_ text: String) { let data = Data(text.utf8); number(data.count); bytes.append(data) }
        string("PKGV0007");number(1);string("scene.json");number(0);number(scene.utf8.count);bytes.append(contentsOf:scene.utf8)
        let url = root.appending(path:"scene.pkg")
        try bytes.write(to:url)
        return url
    }
}

@MainActor
private final class LiveTestTicks: SceneTickSource {
    var elapsedTime: TimeInterval = 0
    var frameTime: TimeInterval = 0
    var isRunning = false
    var onTick: ((SceneTick)->Void)?
    func start() { isRunning = true }
    func stop() { isRunning = false }
    func suspend() { isRunning = false }
    func resume() { isRunning = true }
    func reset() { elapsedTime = 0;frameTime = 0;isRunning = false }
    func invalidate() { isRunning = false;onTick = nil }
    func emit(time: TimeInterval) {
        guard isRunning else { return }
        frameTime = time - elapsedTime;elapsedTime = time
        onTick?(SceneTick(elapsedTime: time, frameTime: frameTime))
    }
}
