import Foundation
import XCTest
@testable import WorkshopWallpaperCore

final class SceneScriptBindingTests: XCTestCase {
    func testPreservesPropertyScriptsAndInitiallyHiddenLayers() throws {
        let root = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "scene.pkg")
        try Fixture.writeScenePackage(to: url, sceneJSON: #"""
        {"objects":[{"id":4,"name":"Clock","text":{"value":"","script":"export function update(value) { return new Date().toLocaleTimeString(); }"},
        "visible":{"value":false,"script":"export function init(value) { return true; }"},
        "origin":{"value":"20 30 0","script":"export function update(value) { return input.cursorWorldPosition; }","scriptproperties":{"speed":{"value":1}}},
        "color":{"value":"0.2 0.4 0.6","script":"export function update(value) { return value; }"},
        "alpha":{"value":0.5,"script":"export function update(value) { return value; }"}}]}
        """#)
        let plan = try SceneRenderPlanBuilder().build(url: url)
        let layer = try XCTUnwrap(plan.layers.first)
        XCTAssertTrue(plan.requiresLivePlayback)
        XCTAssertFalse(layer.visible)
        XCTAssertEqual(Set(layer.scripts.keys), [.text, .origin, .alpha, .visible, .color])
        XCTAssertEqual(layer.color, SceneColor(red: 0.2, green: 0.4, blue: 0.6))
        XCTAssertEqual(layer.text?.color, layer.color)
        XCTAssertEqual(layer.scripts[.origin]?.properties["speed"], .number(1))
        XCTAssertEqual(layer.origin, SceneVector3(x: 20, y: 30, z: 0))
    }

    func testAnyScriptInScenePreventsBakingEvenOnUnsupportedLayer() throws {
        let root = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "scene.pkg")
        try Fixture.writeScenePackage(to: url, sceneJSON: #"""
        {"objects":[{"id":1,"text":"Base"},{"id":2,"model":"models/cube.json","angles":{"script":"export function update(v) { return v; }","value":"0 0 0"}}]}
        """#)
        XCTAssertTrue(try SceneRenderPlanBuilder().buildLayout(url: url).requiresLivePlayback)
    }

    func testStaticHiddenObjectsDoNotConsumeRenderLayers() throws {
        let root = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "scene.pkg")
        try Fixture.writeScenePackage(to: url, sceneJSON: #"{"objects":[{"id":1,"text":"Hidden","visible":false},{"id":2,"text":"Shown"}]}"#)
        let plan = try SceneRenderPlanBuilder().build(url: url)
        XCTAssertFalse(plan.requiresLivePlayback)
        XCTAssertEqual(plan.layers.map(\.id), [2])
    }
}
