import Foundation
import XCTest
@testable import WorkshopWallpaperCore

final class SceneRenderPlanTests: XCTestCase {
    private let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/lz8KWwAAAABJRU5ErkJggg=="
    )!

    func testRenderPlanResolvesImageLayerTextureFromModelMaterialChain() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "scene.pkg")
        let sceneJSON = """
        {
          "general": { "orthogonalprojection": { "width": 1920, "height": 1080 } },
          "objects": [
            {
              "id": 7,
              "name": "background",
              "visible": true,
              "image": "models/background.json",
              "origin": "960 540 0",
              "size": "1920 1080",
              "scale": "1 1 1",
              "alpha": 0.75
            }
          ]
        }
        """
        try Fixture.writeScenePackage(
            to: packageURL,
            sceneJSON: sceneJSON,
            extraEntries: [
                (path: "models/background.json", data: Data(#"{"material":"materials/background.json"}"#.utf8)),
                (path: "materials/background.json", data: Data(#"{"passes":[{"textures":["background"]}]}"#.utf8)),
                (path: "materials/background.tex", data: Fixture.texData(width: 1, height: 1, imageData: png))
            ]
        )

        // When
        let plan = try SceneRenderPlanBuilder().build(url: packageURL)

        // Then
        XCTAssertEqual(plan.canvasSize, SceneSize(width: 1920, height: 1080))
        XCTAssertEqual(plan.layers.count, 1)
        XCTAssertEqual(plan.layers[0].id, 7)
        XCTAssertEqual(plan.layers[0].name, "background")
        XCTAssertEqual(plan.layers[0].texturePath, "materials/background.tex")
        XCTAssertEqual(plan.layers[0].origin, SceneVector3(x: 960, y: 540, z: 0))
        XCTAssertEqual(plan.layers[0].size, SceneSize(width: 1920, height: 1080))
        XCTAssertEqual(plan.layers[0].alpha, 0.75)
    }

    func testRenderPlanPreservesLayerTransformAndOpacityAnimations() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "animated-scene.pkg")
        let sceneJSON = """
        {
          "general": { "orthogonalprojection": { "width": 1920, "height": 1080 } },
          "objects": [
            {
              "id": 12,
              "name": "animated-fish",
              "visible": true,
              "image": "models/fish.json",
              "origin": {
                "value": "960 540 0",
                "animation": {
                  "options": { "fps": 30, "length": 60, "relative": false },
                  "c0": [ { "frame": 0, "value": 900 }, { "frame": 60, "value": 1100 } ],
                  "c1": [
                    { "frame": 0, "value": 500 },
                    { "frame": 30, "value": 525 },
                    { "frame": 60, "value": 550 }
                  ]
                }
              },
              "size": "300 120",
              "scale": {
                "value": "1 1 1",
                "animation": {
                  "options": { "fps": 30, "length": 60, "relative": false },
                  "c0": [ { "frame": 0, "value": 1 }, { "frame": 60, "value": 1.4 } ],
                  "c1": [ { "frame": 0, "value": 1 }, { "frame": 60, "value": 0.8 } ]
                }
              },
              "angles": {
                "value": "0 0 15",
                "animation": {
                  "options": { "fps": 30, "length": 60, "relative": false },
                  "c2": [ { "frame": 0, "value": 15 }, { "frame": 60, "value": -15 } ]
                }
              },
              "alpha": {
                "value": 0.75,
                "animation": {
                  "options": { "fps": 30, "length": 60, "relative": false },
                  "c0": [ { "frame": 0, "value": 0.2 }, { "frame": 60, "value": 0.9 } ]
                }
              }
            }
          ]
        }
        """
        try Fixture.writeScenePackage(
            to: packageURL,
            sceneJSON: sceneJSON,
            extraEntries: [
                (path: "models/fish.json", data: Data(#"{"material":"materials/fish.json"}"#.utf8)),
                (path: "materials/fish.json", data: Data(#"{"passes":[{"textures":["fish"]}]}"#.utf8)),
                (path: "materials/fish.tex", data: Fixture.texData(width: 1, height: 1, imageData: png))
            ]
        )

        // When
        let plan = try SceneRenderPlanBuilder().build(url: packageURL)
        let layer = try XCTUnwrap(plan.layers.first)

        // Then
        XCTAssertNotNil(layer.originAnimation)
        XCTAssertNotNil(layer.scaleAnimation)
        XCTAssertNotNil(layer.angleAnimation)
        XCTAssertNotNil(layer.alphaAnimation)
        XCTAssertEqual(layer.angles, SceneVector3(x: 0, y: 0, z: 15))
        XCTAssertEqual(layer.alpha, 0.75)
        XCTAssertEqual(layer.originAnimation?.duration, 2)
        XCTAssertEqual(
            layer.originAnimation?.keyframes.first { $0.time == 1 }?.value,
            SceneVector3(x: 1000, y: 525, z: 0)
        )
        XCTAssertEqual(layer.scaleAnimation?.keyframes.last?.value, SceneVector3(x: 1.4, y: 0.8, z: 1))
        XCTAssertEqual(layer.angleAnimation?.keyframes.last?.value.z, -15)
        XCTAssertEqual(layer.alphaAnimation?.keyframes.last?.value, 0.9)
    }

    func testRenderPlanDoesNotClipCommonScenesAtSixteenLayersAndSortsByDepth() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "many-layers.pkg")
        let objectJSON = (1...20).reversed().map { id in
            """
                {
                  "id": \(id),
                  "name": "layer-\(id)",
                  "visible": true,
                  "image": "models/layer-\(id).json",
                  "origin": "960 540 \(id)",
                  "size": "1920 1080"
                }
            """
        }.joined(separator: ",\n")
        let entries = (1...20).flatMap { id in
            [
                (
                    path: "models/layer-\(id).json",
                    data: Data(#"{"material":"materials/layer-\#(id).json"}"#.utf8)
                ),
                (
                    path: "materials/layer-\(id).json",
                    data: Data(#"{"passes":[{"textures":["layer-\#(id)"]}]}"#.utf8)
                ),
                (
                    path: "materials/layer-\(id).tex",
                    data: Fixture.texData(width: 1, height: 1, imageData: png)
                )
            ]
        }
        try Fixture.writeScenePackage(
            to: packageURL,
            sceneJSON: """
            {
              "general": { "orthogonalprojection": { "width": 1920, "height": 1080 } },
              "objects": [
            \(objectJSON)
              ]
            }
            """,
            extraEntries: entries
        )

        // When
        let plan = try SceneRenderPlanBuilder().build(url: packageURL)

        // Then
        XCTAssertEqual(plan.layers.count, 20)
        XCTAssertEqual(plan.layers.map(\.id), Array(1...20))
        XCTAssertEqual(plan.textures.count, 20)
    }

    func testRenderPlanResolvesTextureNamesFromMaterialDictionaryEntries() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "dictionary-texture.pkg")
        let sceneJSON = """
        {
          "objects": [
            {
              "id": 1,
              "visible": true,
              "image": "models/background.json",
              "origin": "960 540 0",
              "size": "1920 1080"
            }
          ]
        }
        """
        try Fixture.writeScenePackage(
            to: packageURL,
            sceneJSON: sceneJSON,
            extraEntries: [
                (path: "models/background.json", data: Data(#"{"material":"materials/background.json"}"#.utf8)),
                (path: "materials/background.json", data: Data(#"{"passes":[{"textures":[{"name":"background"}]}]}"#.utf8)),
                (path: "materials/background.tex", data: Fixture.texData(width: 1, height: 1, imageData: png))
            ]
        )

        // When
        let plan = try SceneRenderPlanBuilder().build(url: packageURL)

        // Then
        XCTAssertEqual(plan.layers.count, 1)
        XCTAssertEqual(plan.layers[0].texturePath, "materials/background.tex")
    }

    func testRenderPlanBuildsPaintingTheSharksStyleTextAndWaterEffects() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "painting-sharks-style.pkg")
        let sceneJSON = """
        {
          "general": { "orthogonalprojection": { "width": 3840, "height": 2160 } },
          "objects": [
            {
              "id": 1,
              "name": "Espuma",
              "visible": true,
              "image": "models/foam.json",
              "origin": "1920 1535 0",
              "size": "3840 1236",
              "effects": [
                {
                  "file": "effects/waterflow/effect.json",
                  "passes": [
                    { "constantshadervalues": { "speed": 0.45, "strength": 0.47 } }
                  ],
                  "visible": true
                }
              ]
            },
            {
              "id": 3,
              "name": "Compose",
              "visible": true,
              "image": "models/util/composelayer.json",
              "origin": "1920 1080 0",
              "size": "3840 2160",
              "effects": [
                { "file": "effects/waterripple/effect.json", "visible": true }
              ]
            },
            {
              "id": 2,
              "name": "Clock",
              "visible": { "value": true },
              "text": {
                "value": "12:34",
                "script": "export function update(value) { let time = new Date(); var hours = time.getHours(); let minutes = time.getMinutes(); return hours + ':' + minutes; }",
                "scriptproperties": {
                  "delimiter": ":",
                  "showSeconds": false,
                  "use24hFormat": { "value": false }
                }
              },
              "origin": "3394 1838 0",
              "size": "668 390",
              "pointsize": 80,
              "color": "1 1 1",
              "horizontalalign": "center",
              "verticalalign": "center"
            }
          ]
        }
        """
        try Fixture.writeScenePackage(
            to: packageURL,
            sceneJSON: sceneJSON,
            extraEntries: [
                (path: "models/foam.json", data: Data(#"{"material":"materials/foam.json"}"#.utf8)),
                (path: "materials/foam.json", data: Data(#"{"passes":[{"textures":["foam"]}]}"#.utf8)),
                (path: "materials/foam.tex", data: Fixture.texData(width: 1, height: 1, imageData: png))
            ]
        )

        // When
        let plan = try SceneRenderPlanBuilder().build(url: packageURL)

        // Then
        XCTAssertEqual(plan.layers.count, 3)
        let foam = try XCTUnwrap(plan.layers.first { $0.name == "Espuma" })
        XCTAssertTrue(foam.effects.contains(.waterFlow))
        let compose = try XCTUnwrap(plan.layers.first { $0.name == "Compose" })
        XCTAssertTrue(compose.isEffectOnly)
        XCTAssertTrue(compose.effects.contains(.waterRipple))
        XCTAssertEqual(compose.size, SceneSize(width: 3840, height: 2160))
        let clock = try XCTUnwrap(plan.layers.first { $0.name == "Clock" })
        XCTAssertEqual(clock.text?.value, "12:34")
        XCTAssertEqual(clock.text?.dynamicText, .clock(SceneClockText(
            uses24HourFormat: false,
            showsSeconds: false,
            delimiter: ":"
        )))
        let date = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            hour: 22,
            minute: 5,
            second: 9
        )))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        guard case .clock(let clockText) = clock.text?.dynamicText else {
            return XCTFail("Expected dynamic clock text")
        }
        XCTAssertEqual(clockText.string(for: date, calendar: calendar), "10:05")
        XCTAssertEqual(clock.text?.pointSize, 80)
        XCTAssertEqual(clock.text?.horizontalAlignment, .center)
        XCTAssertEqual(clock.text?.verticalAlignment, .center)
    }
}
