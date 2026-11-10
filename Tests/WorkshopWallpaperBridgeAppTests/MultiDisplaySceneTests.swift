import AppKit
import XCTest
import WorkshopWallpaperCore
@testable import WorkshopWallpaperBridgeApp

@MainActor
final class MultiDisplaySceneTests: XCTestCase {
    func testDisplayLinkBelongsToItsViewAndClosingOneSourceLeavesAnotherRunning() {
        let firstView = DisplayLinkHostView()
        let secondView = DisplayLinkHostView()
        let first = CADisplayLinkSceneTickSource()
        let second = CADisplayLinkSceneTickSource()
        defer { first.invalidate(); second.invalidate() }

        first.attach(to: firstView)
        second.attach(to: secondView)
        first.start()
        second.start()
        first.start()

        XCTAssertEqual(firstView.displayLinkRequests, 1)
        XCTAssertEqual(secondView.displayLinkRequests, 1)
        first.invalidate()
        XCTAssertFalse(first.isRunning)
        XCTAssertTrue(second.isRunning)
        first.start()
        XCTAssertEqual(firstView.displayLinkRequests, 1)
    }

    func testDisplayLinkDoesNotFallBackToTheMainScreenWithoutAnOwningView() {
        let source = CADisplayLinkSceneTickSource()
        defer { source.invalidate() }
        source.start()
        XCTAssertFalse(source.isRunning)
    }

    func testSceneLayersAndMasksFollowWindowBackingScaleAndWindowMoves() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try scenePackage(in: root)
        let plan = try SceneRenderPlanBuilder().build(url: url)
        let view = try SceneWallpaperView(url: url, previewURL: nil, frame: frame,
                                         displayMode: .fit, decodedPlan: plan)
        defer { view.prepareForClose() }
        let text = try XCTUnwrap(view.layer?.sublayers?.last?.sublayers?.first as? CATextLayer)
        text.mask = CALayer()
        try assertScaleFollowsWindow(view)
    }

    func testMediaAndBackgroundVideoLayersFollowWindowBackingScaleAndWindowMoves() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try scenePackage(in: root)
        let decoded = try SceneRenderPlanBuilder().build(url: url)
        let model = try XCTUnwrap(decoded.layers.first)
        let metrics = SceneTextMetrics()
        metrics.configure(["layers": [["id": model.id, "textMetrics": ["fontSize": 16]]]])
        let plan = SceneMediaOverlayPlan(canvas: CGSize(width: 640, height: 360),
            layers: [.init(model: model, alignment: "center", image: nil, animation: nil,
                           thumbnail: false, masks: [], shaderEffects: [])],
            particles: [], compositions: [], order: [model.id],
            configuration: SceneScriptSession.configuration(plan: decoded, projectURL: root), metrics: metrics)
        let view = MediaSceneWallpaperView(videoURL: root.appending(path: "missing.mp4"),
                                          previewURL: nil, plan: plan, frame: frame)
        defer { view.prepareForClose() }
        try assertScaleFollowsWindow(view)
        XCTAssertEqual(view.background.playerLayer.contentsScale, 1)
    }

    func testClosingOneVideoDoesNotDetachAnotherVideosPlayer() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = VideoWallpaperView(url: root.appending(path: "first.mp4"), fallbackImageURL: nil,
                                       frame: frame, displayMode: .fill)
        let second = VideoWallpaperView(url: root.appending(path: "second.mp4"), fallbackImageURL: nil,
                                        frame: frame, displayMode: .fill)
        defer { first.prepareForClose(); second.prepareForClose() }
        let secondPlayer = try XCTUnwrap(second.playerLayer.player)

        first.prepareForClose()

        XCTAssertNil(first.playerLayer.player)
        XCTAssertTrue(second.playerLayer.player === secondPlayer)
        try assertScaleFollowsWindow(second)
    }

    func testClosingOneScriptSessionLeavesAnotherSessionUpdating() async throws {
        let configuration: [String: Any] = ["canvasSize": [640, 360], "layers": [[
            "id": 1, "name": "Clock", "size": [200, 40],
            "values": ["text": "initial", "origin": [320, 180, 0], "scale": [1, 1, 1],
                       "angles": [0, 0, 0], "alpha": 1, "visible": true, "color": [1, 1, 1]],
            "scripts": [["property": "text", "source": "export function init() { return 'ready'; } export function update() { return String(engine.runtime); }", "properties": [:]]]
        ]]]
        let first = SceneScriptSession(configuration: configuration)
        let second = SceneScriptSession(configuration: configuration)
        defer { first.close(); second.close() }
        let firstReady = expectation(description: "First session initialized")
        let secondReady = expectation(description: "Second session initialized")
        first.onChanges = { _ in firstReady.fulfill() }
        second.onChanges = { _ in secondReady.fulfill() }
        first.onDiagnostic = { XCTFail($0) }
        second.onDiagnostic = { XCTFail($0) }
        XCTAssertTrue(first.advance(frame: ["time": 0]))
        XCTAssertTrue(second.advance(frame: ["time": 0]))
        await fulfillment(of: [firstReady, secondReady], timeout: 3)

        first.close()
        let updated = expectation(description: "Remaining session updated")
        second.onChanges = { changes in
            XCTAssertEqual((changes.first?["values"] as? [String: Any])?["text"] as? String, "2")
            updated.fulfill()
        }
        XCTAssertFalse(first.advance(frame: ["time": 2]))
        XCTAssertTrue(second.advance(frame: ["time": 2]))
        await fulfillment(of: [updated], timeout: 3)
    }

    func testCanvasRatioCacheRejectsFreshDisplayRatioVideosFromV7AndV6() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = SceneVideoCache.overrideCacheDirectoryURL
        SceneVideoCache.overrideCacheDirectoryURL = root.appending(path: "v8")
        defer { SceneVideoCache.overrideCacheDirectoryURL = old }
        let source = root.appending(path: "scene.pkg")
        try writeDatedFile(source, seconds: 100)
        for version in [6, 7] {
            try writeDatedFile(root.appending(path: "v\(version)/scene.mp4"), seconds: 200)
        }

        XCTAssertEqual(SceneVideoCache.cacheVersion, 8)
        XCTAssertNil(SceneVideoCache.freshCachedVideoURL(assetId: "scene", sourceURL: source))
        XCTAssertNil(SceneVideoCache.previousCompatibleCachedVideoURL(assetId: "scene", sourceURL: source),
                     "Old display-shaped recordings must not replace the preview while rebuilding")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "v7/scene.mp4").path),
                      "Invalidation must not delete prior recordings")
    }

    func testCanvasRatioCacheAcceptsOnlyFreshCurrentVersionRecordings() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = SceneVideoCache.overrideCacheDirectoryURL
        SceneVideoCache.overrideCacheDirectoryURL = root.appending(path: "v8")
        defer { SceneVideoCache.overrideCacheDirectoryURL = old }
        let source = root.appending(path: "scene.pkg")
        let video = SceneVideoCache.cachedVideoURL(assetId: "scene")
        try writeDatedFile(source, seconds: 100)
        try writeDatedFile(video, seconds: 200)
        XCTAssertEqual(SceneVideoCache.freshCachedVideoURL(assetId: "scene", sourceURL: source), video)

        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 300)], ofItemAtPath: source.path)
        XCTAssertNil(SceneVideoCache.freshCachedVideoURL(assetId: "scene", sourceURL: source))
    }

    private var frame: CGRect { CGRect(x: 0, y: 0, width: 640, height: 360) }

    private func assertScaleFollowsWindow(_ view: NSView) throws {
        let first = ScaleWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        let second = ScaleWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        first.isReleasedWhenClosed = false
        second.isReleasedWhenClosed = false
        defer { first.contentView = nil; second.contentView = nil; first.close(); second.close() }
        first.testScale = 2
        second.testScale = 1
        first.contentView = view
        assertLayerScale(try XCTUnwrap(view.layer), equals: 2)

        first.testScale = 1
        view.viewDidChangeBackingProperties()
        for child in view.subviews { child.viewDidChangeBackingProperties() }
        assertLayerScale(try XCTUnwrap(view.layer), equals: 1)
        first.testScale = 2
        view.viewDidChangeBackingProperties()
        for child in view.subviews { child.viewDidChangeBackingProperties() }
        assertLayerScale(try XCTUnwrap(view.layer), equals: 2)

        first.contentView = nil
        second.contentView = view
        assertLayerScale(try XCTUnwrap(view.layer), equals: 1)
    }

    private func assertLayerScale(_ layer: CALayer, equals expected: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(layer.contentsScale, expected, "Layer: \(layer.name ?? String(describing: type(of: layer)))", file: file, line: line)
        if let mask = layer.mask { assertLayerScale(mask, equals: expected, file: file, line: line) }
        for child in layer.sublayers ?? [] { assertLayerScale(child, equals: expected, file: file, line: line) }
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "wwb-multi-scene-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeDatedFile(_ url: URL, seconds: TimeInterval) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: url.path)
    }

    private func scenePackage(in root: URL) throws -> URL {
        let scene = #"{"general":{"orthogonalprojection":{"width":640,"height":360}},"objects":[{"id":1,"name":"Text","size":"200 40","origin":"320 180 0","text":"Canvas"}]}"#
        var data = Data()
        func number(_ value: Int) { var little = UInt32(value).littleEndian; data.append(Data(bytes: &little, count: 4)) }
        func string(_ value: String) { number(value.utf8.count); data.append(contentsOf: value.utf8) }
        string("PKGV0007"); number(1); string("scene.json"); number(0); number(scene.utf8.count)
        data.append(contentsOf: scene.utf8)
        let url = root.appending(path: "scene.pkg")
        try data.write(to: url)
        return url
    }
}

@MainActor
private final class DisplayLinkHostView: NSView {
    private(set) var displayLinkRequests = 0
    override func displayLink(target: Any, selector: Selector) -> CADisplayLink {
        displayLinkRequests += 1
        return super.displayLink(target: target, selector: selector)
    }
}

@MainActor
private final class ScaleWindow: NSWindow {
    var testScale: CGFloat = 1
    override var backingScaleFactor: CGFloat { testScale }
}
