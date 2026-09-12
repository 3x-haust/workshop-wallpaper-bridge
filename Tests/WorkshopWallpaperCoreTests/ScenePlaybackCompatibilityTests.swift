import Foundation
import XCTest
@testable import WorkshopWallpaperCore

final class ScenePlaybackCompatibilityTests: XCTestCase {
    func testOnlyCompleteBasicScenesCanPreferLivePlayback() throws {
        let basic = #"{"id":1,"text":{"value":"Clock","script":"export function update(v) { return v; }"}}"#
        XCTAssertTrue(try plan(objects: basic).canPreferLivePlayback)
        for extra in [
            #"{"id":2,"model":"models/cube.json"}"#,
            #"{"id":2,"particle":"particles/snow.json"}"#,
            #"{"id":2,"image":"models/missing.json"}"#,
            #"{"id":2,"text":"FX","effects":[{"file":"effects/custom/effect.json"}]}"#,
            #"{"id":2,"text":"Child","parent":1}"#,
            #"{"id":2,"text":"3D","angles":"20 10 0"}"#,
            #"{"id":2,"sound":["audio/song.ogg"]}"#
        ] {
            XCTAssertFalse(try plan(objects: basic + "," + extra).canPreferLivePlayback, extra)
        }
    }

    func testShaderAudioFlagDoesNotAuthorizeNativeLiveRenderer() throws {
        let result = try plan(objects: #"{"id":1,"text":"Static"}"#, general: #""audioprocessing":true"#)
        XCTAssertTrue(result.requiresLivePlayback)
        XCTAssertFalse(result.canPreferLivePlayback)
    }

    func testUnsupportedPropertyScriptDoesNotAuthorizeNativeLiveRenderer() throws {
        let result = try plan(objects: #"{"id":1,"text":"Base","size":{"value":"100 100","script":"export function update(v) { return v; }"}}"#)
        XCTAssertFalse(result.canPreferLivePlayback)
    }

    func testBloomAndExcessLayersDoNotReplaceFullSceneWithPartialLiveScene() throws {
        let layer = #"{"text":{"value":"Base","script":"export function update(v) { return v; }"}}"#
        XCTAssertFalse(try plan(objects: layer, general: #""bloom":{"value":true}"#).canPreferLivePlayback)
        let layers = (1...25).map { #"{"id":\#($0),"text":"Layer"}"# }.joined(separator: ",")
        let result = try plan(objects: layer + "," + layers, decode: true)
        XCTAssertEqual(result.layers.count, 24, "Preserve the decode safety budget")
        XCTAssertEqual(result.omittedLayerCount, 2)
        XCTAssertFalse(result.canPreferLivePlayback)
    }

    func testExactlyFullBudgetIsCompleteAndHiddenStaticLayersDoNotConsumeIt() throws {
        let layers = (1...24).map { #"{"id":\#($0),"text":"Layer"}"# }.joined(separator: ",")
        let result = try plan(objects: #"{"id":0,"text":"Hidden","visible":false},"# + layers, decode: true)
        XCTAssertEqual(result.layers.count, 24)
        XCTAssertEqual(result.omittedLayerCount, 0)
    }

    func testPreviewBackgroundUsesSceneClearColor() throws {
        let result = try plan(objects: #"{"id":1,"text":"Transparent"}"#, general: #""clearcolor":"0.1 0.2 0.3","clearenabled":true"#)
        XCTAssertEqual(result.backgroundColor, SceneColor(red: 0.1, green: 0.2, blue: 0.3))
    }

    private func plan(objects: String, general: String = "", decode: Bool = false) throws -> SceneRenderPlan {
        let root = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "scene.pkg")
        try Fixture.writeScenePackage(to: url, sceneJSON: "{\"general\":{\(general)},\"objects\":[\(objects)]}")
        return try decode ? SceneRenderPlanBuilder().build(url: url) : SceneRenderPlanBuilder().buildLayout(url: url)
    }
}
