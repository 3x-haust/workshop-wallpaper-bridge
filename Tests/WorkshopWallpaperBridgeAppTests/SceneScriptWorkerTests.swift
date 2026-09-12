import Foundation
import XCTest
@testable import WorkshopWallpaperBridgeApp

final class SceneScriptWorkerTests: XCTestCase {
    func testEffectScriptsUseTheirOwnObjectAndRestartBoundAnimationOnArtworkChanges() throws {
        let runtime = try SceneScriptWorkerRuntime()
        var config = configuration("export function update(value) { return value; }")
        config["objects"] = [
            ["id":"7/effect/1", "layerID":7, "values":["visible":false], "scripts":[["property":"visible", "source":"export function mediaThumbnailChanged(e) { thisObject.visible=e.hasThumbnail; if(e.hasThumbnail)engine.setTimeout(()=>{thisObject.visible=false;},1000); }", "properties":[:]]]],
            ["id":"7/effect/1/multiply", "layerID":7, "values":["value":0], "animation":["c0":[["frame":0,"value":1],["frame":15,"value":0]],"options":["fps":15,"length":15,"mode":"single","startpaused":true]], "scripts":[["property":"value","source":"export function mediaThumbnailChanged(e) { if(e.hasThumbnail) { const a=thisObject.getAnimation(); a.stop(); a.play(); } }", "properties":[:]]]]
        ] as [[String: Any]]
        let media: [String: Any] = ["enabled":true,"hasThumbnail":true,"artworkRevision":"one"]
        let first = try send(runtime, ["configure":config,"frame":["time":0,"media":media]])
        XCTAssertEqual((first["errors"] as? [Any])?.count, 0)
        let half = try send(runtime, ["frame":["time":0.5,"media":media]])
        let objects = half["objects"] as? [[String:Any]]
        XCTAssertEqual(objects?.first(where: { $0["id"] as? String == "7/effect/1/multiply" })?["values"] as? [String:Double], ["value":0.5])
        let end = try send(runtime, ["frame":["time":1.1,"media":media]])
        let ended = end["objects"] as? [[String:Any]]
        XCTAssertEqual(ended?.first(where: { $0["id"] as? String == "7/effect/1" })?["values"] as? [String:Bool], ["visible":false])
        XCTAssertEqual((end["errors"] as? [Any])?.count, 0)
        let idle = try send(runtime, ["frame":["time":1.2,"media":media]])
        XCTAssertTrue((idle["objects"] as? [Any] ?? []).isEmpty, "Completed animations must stop publishing identical frames")
        var next = media; next["artworkRevision"] = "two"
        _ = try send(runtime, ["frame":["time":2,"media":next]])
        let again = try send(runtime, ["frame":["time":2.5,"media":next]])
        XCTAssertEqual((again["objects"] as? [[String:Any]])?.first(where: { $0["id"] as? String == "7/effect/1/multiply" })?["values"] as? [String:Double], ["value":0.5])
    }
    func testMediaEventsUpdateTitleTimelineAndPlaybackWithoutRepeatingMetadata() throws {
        let runtime = try SceneScriptWorkerRuntime()
        let config = configuration("""
        let title='', state=0, position=0, duration=0, artwork=false, changes=0;
        export function mediaPropertiesChanged(e) { title=e.title+' / '+e.artist; changes++; }
        export function mediaPlaybackChanged(e) { state=e.state; }
        export function mediaTimelineChanged(e) { position=e.position; duration=e.duration; }
        export function mediaThumbnailChanged(e) { artwork=e.hasThumbnail; }
        export function update() { return [title,state,position,duration,artwork,changes].join('|'); }
        """)
        var media: [String: Any] = ["enabled":true,"title":"Track","artist":"Artist","state":1,
                                    "position":12,"duration":60,"hasThumbnail":true,"artworkRevision":"a"]
        _ = try send(runtime, ["configure":config,"frame":["media":media]])
        XCTAssertEqual(try values(send(runtime, ["frame":["media":media]]))["text"] as? String,
                       "Track / Artist|1|12|60|true|1")
        media["position"] = 30; media["state"] = 2
        XCTAssertEqual(try values(send(runtime, ["frame":["media":media]]))["text"] as? String,
                       "Track / Artist|2|30|60|true|1")
        media["title"] = "Next"; media["hasThumbnail"] = false; media["artworkRevision"] = ""
        XCTAssertEqual(try values(send(runtime, ["frame":["media":media]]))["text"] as? String,
                       "Next / Artist|2|30|60|false|2")
    }

    func testTextSizeUsesMeasuredGlyphsAndUpdatesWithinTheSameScriptCall() throws {
        let runtime = try SceneScriptWorkerRuntime()
        var config = configuration("""
        export function update() {
            thisLayer.text='WW'; const wide=thisLayer.size.x;
            thisLayer.text='ii'; const narrow=thisLayer.size.x;
            if (!(wide > narrow && narrow > 0)) throw new Error('text size is not measured');
            return 'measured';
        }
        """)
        var layers = config["layers"] as! [[String:Any]]
        layers[0]["textMetrics"] = ["fontSize":20,"padding":0]
        config["layers"] = layers
        _ = try send(runtime, ["configure":config])
        let response = try send(runtime, [:])
        XCTAssertEqual(values(response)["text"] as? String, "measured")
        XCTAssertEqual((response["errors"] as? [Any])?.count, 0)
    }
    func testPackagedAppUsesItsOwnSpacedExecutableName() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "worker-\(UUID()).app")
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appending(path: "Contents/MacOS/Workshop Wallpaper Bridge")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: executable)
        let info = ["CFBundleIdentifier": "dev.test.worker.\(UUID().uuidString)", "CFBundleExecutable": "Workshop Wallpaper Bridge", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: root.appending(path: "Contents/Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: root))
        XCTAssertEqual(SceneScriptProcess.executableURL(in: bundle)?.standardizedFileURL, executable.standardizedFileURL)
    }

    private func configuration(_ source: String, property: String = "text") -> [String: Any] {
        ["canvasSize": [800,600], "layers": [["id": 7, "name": "Clock", "size": [200,100],
            "values": ["text": "base", "origin": [400,300,0], "scale": [1,1,1], "angles": [0,0,0],
                       "alpha": 1, "visible": true, "color": [1,1,1]],
            "scripts": [["property": property, "source": source, "properties": [:]]]]]]
    }
    private func send(_ runtime: SceneScriptWorkerRuntime, _ request: [String: Any]) throws -> [String: Any] {
        let result = try runtime.respond(to: JSONSerialization.data(withJSONObject: request))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
    }
    private func values(_ response: [String: Any]) -> [String: Any] {
        (response["layers"] as? [[String:Any]])?.first?["values"] as? [String:Any] ?? [:]
    }

    func testInitRunsOnceAndUpdateUsesPreviousValueWithPersistentGlobalsAndLoops() throws {
        let runtime = try SceneScriptWorkerRuntime()
        let config = configuration("""
        let count = 0;
        export function init(value) { count++; return value + ':init'; }
        export function update(value) { for (let i=0;i<3;i++) count++; return value + ':' + count; }
        """)
        XCTAssertEqual(try values(send(runtime, ["configure":config]))["text"] as? String, "base:init")
        XCTAssertEqual(try values(send(runtime, [:]))["text"] as? String, "base:init:4")
        XCTAssertEqual(try values(send(runtime, [:]))["text"] as? String, "base:init:4:7")
    }

    func testVectorOperationsReturnNewObjectsAndCursorCoordinatesReachBoundOrigin() throws {
        let runtime = try SceneScriptWorkerRuntime()
        _ = try send(runtime, ["configure":configuration("""
        import * as WEMath from 'WEMath';
        export function update(value) {
            const cursor = input.cursorWorldPosition;
            const next = cursor.add(new Vec3(10,20,0));
            if(cursor.x !== 50) throw new Error('vector mutated');
            return next.multiply(WEMath.mix(1,3,0.5));
        }
        """, property: "origin")])
        let response = try send(runtime, ["frame":["cursor":[50,60,0]]])
        XCTAssertEqual(values(response)["origin"] as? [Double], [120,160,0])
        XCTAssertEqual((response["errors"] as? [Any])?.count, 0)
    }

    func testAudioBuffersKeepIdentityAndRefreshEveryFrame() throws {
        let runtime = try SceneScriptWorkerRuntime()
        _ = try send(runtime, ["configure":configuration("""
        const audio = engine.registerAudioBuffers(engine.AUDIO_RESOLUTION_16);
        const retained = audio.average;
        export function update(value) { return retained[0]; }
        """, property: "alpha")])
        let response = try send(runtime, ["frame":["audioLeft":Array(repeating:0.2,count:64),"audioRight":Array(repeating:0.6,count:64)]])
        XCTAssertEqual(try XCTUnwrap(values(response)["alpha"] as? Double), 0.4, accuracy:0.00001)
        XCTAssertEqual(try values(send(runtime, [:]))["alpha"] as? Double, 0)
    }

    func testCrossLayerWritesCursorClickAndTimers() throws {
        let runtime = try SceneScriptWorkerRuntime()
        _ = try send(runtime, ["configure":configuration("""
        export function init(value) { engine.setTimeout(()=>thisScene.getLayerByID('7').alpha=0.25, 100); return value; }
        export function cursorClick(event) { thisLayer.text='clicked:'+event.localPosition.x; }
        """)])
        _ = try send(runtime, ["frame":["cursor":[400,300,0],"cursorInside":true,"leftDown":true]])
        let response = try send(runtime, ["frame":["time":0.2,"cursor":[400,300,0],"cursorInside":true,"leftDown":false]])
        XCTAssertEqual(values(response)["text"] as? String, "clicked:0")
        XCTAssertEqual(values(response)["alpha"] as? Double, 0.25)
    }

    func testUnsupportedAPIFailsWithDiagnosticAndKeepsLastGoodValue() throws {
        let runtime = try SceneScriptWorkerRuntime()
        _ = try send(runtime, ["configure":configuration("export function update(value) { return thisScene.createLayer({}); }")])
        let response = try send(runtime, [:])
        XCTAssertTrue(values(response).isEmpty)
        XCTAssertEqual((response["errors"] as? [Any])?.count, 1)
    }

    func testShortClickRetainsDownAndUpWithinOneFrame() throws {
        let runtime = try SceneScriptWorkerRuntime()
        _ = try send(runtime, ["configure":configuration("""
        let events=[];
        export function cursorDown() { events.push('down'); }
        export function cursorUp() { events.push('up'); }
        export function cursorClick() { events.push('click'); }
        export function update() { return events.join(','); }
        """)])
        let response = try send(runtime, ["frame":["cursor":[400,300,0],"cursorInside":true,"leftDown":false,
            "cursorEvents":[["cursor":[400,300,0],"cursorInside":true,"down":true,"up":false],
                            ["cursor":[400,300,0],"cursorInside":true,"down":false,"up":true]]]])
        XCTAssertEqual(values(response)["text"] as? String, "down,up,click")
        XCTAssertEqual(try values(send(runtime, ["frame":["cursor":[400,300,0],"cursorInside":true,"leftDown":false]]))["text"] as? String, "down,up,click")
    }

    func testModuleWordsInsideStringsAreNotRewritten() throws {
        let runtime = try SceneScriptWorkerRuntime()
        _ = try send(runtime, ["configure":configuration("export function update(value) { return `export function update import`; }")])
        XCTAssertEqual(try values(send(runtime, [:]))["text"] as? String,"export function update import")
    }

    func testRetainedInitVectorDoesNotDriftWhenUpdateMutatesItsArgument() throws {
        let runtime = try SceneScriptWorkerRuntime()
        _ = try send(runtime, ["configure":configuration("""
        let initialValue;
        export function init(value) { initialValue=value; return value; }
        export function update(value) { value.y=initialValue.y+10; return value; }
        """, property:"origin")])
        XCTAssertEqual(try values(send(runtime, [:]))["origin"] as? [Double], [400,310,0])
        XCTAssertEqual(try values(send(runtime, [:]))["origin"] as? [Double], [400,310,0])
    }

    func testScalarReturnConvertsToVectorAndUndefinedDoesNotMutateProperty() throws {
        let runtime = try SceneScriptWorkerRuntime()
        XCTAssertEqual(try values(send(runtime, ["configure":configuration("export function init(value) { return 2; }", property:"scale")]))["scale"] as? [Double], [2,2,2])
        _ = try send(runtime, ["configure":configuration("export function update(value) { value.y=999; }", property:"origin")])
        XCTAssertTrue(try values(send(runtime, [:])).isEmpty)
    }

    func testWorkerTimeoutKillsInfiniteLoopWithoutBlockingCaller() async throws {
        let process = SceneScriptProcess()
        defer { process.close() }
        let setup = try JSONSerialization.data(withJSONObject:["configure":configuration("export function update(value) { while(true) {} }")])
        _ = try await process.exchange(setup, timeout: 2)
        let data = Data("{}".utf8)
        let start = Date()
        do { _ = try await process.exchange(data, timeout: 1); XCTFail("Infinite script returned") }
        catch {
            XCTAssertGreaterThan(Date().timeIntervalSince(start), 0.8)
            XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        }
    }
}
