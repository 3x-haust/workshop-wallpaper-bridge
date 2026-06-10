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

    func testRenderPlanExposesAnimatedSpriteTexture() throws {
        // Given: a scene whose only image layer uses an animated sprite-sheet texture.
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "animated.pkg")
        let sceneJSON = """
        {
          "general": { "orthogonalprojection": { "width": 1920, "height": 1080 } },
          "objects": [
            {
              "id": 1,
              "name": "sprite",
              "visible": true,
              "image": "models/sprite.json",
              "origin": "960 540 0",
              "scale": "1 1 1",
              "alpha": 1
            }
          ]
        }
        """
        let sheet = Data(repeating: 255, count: 4 * 2 * 4)
        let texData = Fixture.animatedTexData(
            textureWidth: 4,
            textureHeight: 2,
            mipmaps: [(width: 4, height: 2, data: sheet)],
            frames: [
                Fixture.TexFrame(frametime: 0.1, x: 0, y: 0, width: 2, height: 2),
                Fixture.TexFrame(frametime: 0.1, x: 2, y: 0, width: 2, height: 2)
            ]
        )
        try Fixture.writeScenePackage(
            to: packageURL,
            sceneJSON: sceneJSON,
            extraEntries: [
                (path: "models/sprite.json", data: Data(#"{"material":"materials/sprite.json"}"#.utf8)),
                (path: "materials/sprite.json", data: Data(#"{"passes":[{"textures":["sprite"]}]}"#.utf8)),
                (path: "materials/sprite.tex", data: texData)
            ]
        )

        // When
        let plan = try SceneRenderPlanBuilder().build(url: packageURL)

        // Then: the scene is renderable and the texture carries its frames,
        // with the default layer size taken from the gif frame size.
        XCTAssertTrue(plan.hasRenderableContent)
        let texture = try XCTUnwrap(plan.textures["materials/sprite.tex"])
        XCTAssertEqual(texture.animation?.frames.count, 2)
        XCTAssertEqual(plan.layers[0].size, SceneSize(width: 2, height: 2))
        XCTAssertTrue(SceneRenderPlanBuilder().canBuild(url: packageURL))
    }

    func testCanBuildAllowsTextOnlySceneWithoutDecodedTextures() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "text-only.pkg")
        try Fixture.writeScenePackage(
            to: packageURL,
            sceneJSON: #"{"objects":[{"name":"Title","text":{"value":"HELLO"},"size":"320 120"}]}"#
        )

        // When
        let plan = try SceneRenderPlanBuilder().build(url: packageURL)
        let canBuild = SceneRenderPlanBuilder().canBuild(url: packageURL)

        // Then
        XCTAssertTrue(canBuild)
        XCTAssertTrue(plan.hasRenderableContent)
        XCTAssertTrue(plan.textures.isEmpty)
        XCTAssertEqual(plan.layers.count, 1)
        XCTAssertEqual(plan.layers.first?.text?.value, "HELLO")
        XCTAssertNil(plan.layers.first?.text?.script)
    }

    func testCanBuildAllowsTextSceneWhenImageTextureFailsDecode() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "mixed-text-broken-image.pkg")
        try Fixture.writeScenePackage(
            to: packageURL,
            sceneJSON: """
            {
              "objects": [
                {"text": {"value": "CLOCK"}},
                {"image": "models/background.json"}
              ]
            }
            """,
            extraEntries: [
                (path: "models/background.json", data: Data(#"{"material":"materials/background.json"}"#.utf8)),
                (path: "materials/background.json", data: Data(#"{"passes":[{"textures":["background"]}]}"#.utf8)),
                (path: "materials/background.tex", data: Data([1, 2, 3]))
            ]
        )

        // When
        let plan = try SceneRenderPlanBuilder().build(url: packageURL)
        let canBuild = SceneRenderPlanBuilder().canBuild(url: packageURL)

        // Then
        XCTAssertTrue(canBuild)
        XCTAssertTrue(plan.hasRenderableContent)
        XCTAssertTrue(plan.textures.isEmpty)
        XCTAssertEqual(plan.layers.count, 1)
        XCTAssertEqual(plan.layers.first?.text?.value, "CLOCK")
    }

    func testCanBuildRejectsEffectOnlySceneWithoutRenderableContent() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "effect-only.pkg")
        try Fixture.writeScenePackage(
            to: packageURL,
            sceneJSON: """
            {
              "objects": [
                {
                  "image": "models/util/composelayer.json",
                  "effects": [{"file": "effects/waterripple/effect.json"}]
                }
              ]
            }
            """
        )

        // When
        let plan = try SceneRenderPlanBuilder().build(url: packageURL)
        let canBuild = SceneRenderPlanBuilder().canBuild(url: packageURL)

        // Then
        XCTAssertFalse(canBuild)
        XCTAssertFalse(plan.hasRenderableContent)
        XCTAssertEqual(plan.layers.count, 1)
        XCTAssertTrue(plan.layers[0].isEffectOnly)
    }

    func testCanBuildRejectsImageOnlySceneWhenTextureCannotDecode() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "broken-image-only.pkg")
        try Fixture.writeScenePackage(
            to: packageURL,
            sceneJSON: #"{"objects":[{"image":"models/background.json"}]}"#,
            extraEntries: [
                (path: "models/background.json", data: Data(#"{"material":"materials/background.json"}"#.utf8)),
                (path: "materials/background.json", data: Data(#"{"passes":[{"textures":["background"]}]}"#.utf8)),
                (path: "materials/background.tex", data: Data([1, 2, 3]))
            ]
        )

        // When
        let canBuild = SceneRenderPlanBuilder().canBuild(url: packageURL)

        // Then
        XCTAssertFalse(canBuild)
        XCTAssertThrowsError(try SceneRenderPlanBuilder().build(url: packageURL)) { error in
            XCTAssertEqual(error as? SceneRenderPlanError, .noRenderableLayers)
        }
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
                    { "constantshadervalues": { "speed": 0.45, "strength": 0.47, "direction": "0.2 1 0" } }
                  ],
                  "visible": true
                },
                {
                  "file": "effects/bloom/effect.json",
                  "passes": [
                    { "constantshadervalues": { "strength": 0.18, "scale": 24 } }
                  ],
                  "visible": true
                },
                {
                  "file": "effects/chromaticaberration/effect.json",
                  "passes": [
                    { "constantshadervalues": { "strength": 0.03, "animationspeed": 0.5 } }
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
                  "offset": { "value": 2.5 },
                  "showSeconds": false,
                  "use24hFormat": { "value": false }
                }
              },
              "origin": "3394 1838 0",
              "size": "668 390",
              "pointsize": 80,
              "color": "1 1 1",
              "horizontalalign": "center",
              "verticalalign": "center",
              "effects": [
                {
                  "file": "effects/opacity/effect.json",
                  "passes": [
                    { "constantshadervalues": { "alpha": 0.25 } }
                  ]
                }
              ]
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
        XCTAssertTrue(foam.effects.contains(.bloom))
        XCTAssertTrue(foam.effects.contains(.chromaticAberration))
        XCTAssertEqual(foam.effectSettings.first?.effect, .waterFlow)
        XCTAssertEqual(foam.effectSettings.first?.speed, 0.45)
        XCTAssertEqual(foam.effectSettings.first?.strength, 0.47)
        XCTAssertEqual(foam.effectSettings.first?.direction, SceneVector3(x: 0.2, y: 1, z: 0))
        XCTAssertEqual(foam.effectSettings.map(\.effect), [.waterFlow, .bloom, .chromaticAberration])
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
        XCTAssertEqual(
            clock.text?.script?.source,
            "export function update(value) { let time = new Date(); var hours = time.getHours(); let minutes = time.getMinutes(); return hours + ':' + minutes; }"
        )
        XCTAssertEqual(clock.text?.script?.properties["delimiter"], .string(":"))
        XCTAssertEqual(clock.text?.script?.properties["offset"], .number(2.5))
        XCTAssertEqual(clock.text?.script?.properties["showSeconds"], .bool(false))
        XCTAssertEqual(clock.text?.script?.properties["use24hFormat"], .bool(false))
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
        XCTAssertEqual(clock.effectSettings.last?.effect, .opacity)
        XCTAssertEqual(clock.effectSettings.last?.strength, 0.25)
        XCTAssertFalse(clock.effectSettings.last?.usesMask ?? true)
    }

    func testRenderPlanSkipsMaskedDuplicateClockTextUntilMaskPipelineIsAvailable() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "duplicate-clock.pkg")
        let clockText = """
        {
          "value": "12:34",
          "script": "export function update(value) { let time = new Date(); var hours = time.getHours(); let minutes = time.getMinutes(); return hours + ':' + minutes; }",
          "scriptproperties": {
            "delimiter": ":",
            "showSeconds": false,
            "use24hFormat": { "value": false }
          }
        }
        """
        let sceneJSON = """
        {
          "objects": [
            {
              "id": 1,
              "name": "Clock",
              "text": \(clockText),
              "origin": "300 200 0",
              "size": "200 100"
            },
            {
              "id": 2,
              "name": "Clock masked",
              "text": \(clockText),
              "origin": "301 200 0",
              "size": "220 120",
              "effects": [
                {
                  "file": "effects/opacity/effect.json",
                  "passes": [
                    {
                      "constantshadervalues": { "alpha": 1 },
                      "textures": [null, "masks/clock-mask"]
                    }
                  ]
                }
              ]
            }
          ]
        }
        """
        try Fixture.writeScenePackage(to: packageURL, sceneJSON: sceneJSON)

        // When
        let plan = try SceneRenderPlanBuilder().build(url: packageURL)

        // Then
        XCTAssertEqual(plan.layers.map(\.name), ["Clock"])
        XCTAssertEqual(plan.layers.filter { $0.text != nil }.count, 1)
    }

    func testRenderPlanKeepsUnmaskedDuplicateOpacityTextLayers() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "duplicate-glow.pkg")
        let sceneJSON = """
        {
          "objects": [
            {
              "id": 1,
              "name": "Title shadow",
              "text": "HELLO",
              "origin": "300 200 0",
              "effects": [
                {
                  "file": "effects/opacity/effect.json",
                  "passes": [
                    { "constantshadervalues": { "alpha": 0.4 } }
                  ]
                }
              ]
            },
            {
              "id": 2,
              "name": "Title fill",
              "text": "HELLO",
              "origin": "301 200 0"
            }
          ]
        }
        """
        try Fixture.writeScenePackage(to: packageURL, sceneJSON: sceneJSON)

        // When
        let plan = try SceneRenderPlanBuilder().build(url: packageURL)

        // Then
        XCTAssertEqual(plan.layers.map(\.name), ["Title shadow", "Title fill"])
        XCTAssertEqual(plan.layers.filter { $0.text != nil }.count, 2)
        XCTAssertFalse(plan.layers[0].effectSettings.first?.usesMask ?? true)
    }

    func testRenderPlanPreservesMaskReferencesForEffectSettings() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "masked-effect.pkg")
        let sceneJSON = """
        {
          "objects": [
            {
              "id": 1,
              "name": "Masked fish",
              "image": "models/fish.json",
              "effects": [
                {
                  "file": "effects/opacity/effect.json",
                  "passes": [
                    {
                      "constantshadervalues": { "alpha": 0.75 },
                      "textures": [null, "masks/fish-mask"]
                    }
                  ]
                }
              ]
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
                (path: "materials/fish.tex", data: Fixture.texData(width: 1, height: 1, imageData: png)),
                (path: "masks/fish-mask.tex", data: Fixture.texData(width: 1, height: 1, imageData: png))
            ]
        )

        // When
        let plan = try SceneRenderPlanBuilder().build(url: packageURL)

        // Then
        let setting = try XCTUnwrap(plan.layers.first?.effectSettings.first)
        XCTAssertEqual(setting.effect, .opacity)
        XCTAssertTrue(setting.usesMask)
        XCTAssertEqual(setting.maskReference?.source, "masks/fish-mask")
        XCTAssertEqual(setting.maskReference?.texturePath, "masks/fish-mask.tex")
    }

    func testRenderPlanResolvesOpacityMaskTexture() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "opacity-mask-texture.pkg")
        let sceneJSON = """
        {
          "objects": [
            {
              "id": 1,
              "name": "Masked fish",
              "image": "models/fish.json",
              "effects": [
                {
                  "file": "effects/opacity/effect.json",
                  "passes": [
                    { "textures": [null, "masks/fish-mask"] }
                  ]
                }
              ]
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
                (path: "materials/fish.tex", data: Fixture.texData(width: 1, height: 1, imageData: png)),
                (path: "masks/fish-mask.tex", data: Fixture.texData(width: 1, height: 1, imageData: png))
            ]
        )

        // When
        let plan = try SceneRenderPlanBuilder().build(url: packageURL)

        // Then
        XCTAssertNotNil(plan.textures["materials/fish.tex"])
        XCTAssertNotNil(plan.textures["masks/fish-mask.tex"])
    }

    func testRenderPlanPreservesScrollAxisSpeedsForEffectMotionFallbacks() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "scroll-axis.pkg")
        let sceneJSON = """
        {
          "objects": [
            {
              "id": 1,
              "name": "Swimmer",
              "image": "models/swimmer.json",
              "effects": [
                {
                  "file": "effects/scroll/effect.json",
                  "passes": [
                    { "constantshadervalues": { "speedx": 0, "speedy": -0.35, "scrolldirection": "0 -1 0" } }
                  ]
                }
              ]
            }
          ]
        }
        """
        try Fixture.writeScenePackage(
            to: packageURL,
            sceneJSON: sceneJSON,
            extraEntries: [
                (path: "models/swimmer.json", data: Data(#"{"material":"materials/swimmer.json"}"#.utf8)),
                (path: "materials/swimmer.json", data: Data(#"{"passes":[{"textures":["swimmer"]}]}"#.utf8)),
                (path: "materials/swimmer.tex", data: Fixture.texData(width: 1, height: 1, imageData: png))
            ]
        )

        // When
        let plan = try SceneRenderPlanBuilder().build(url: packageURL)

        // Then
        let setting = try XCTUnwrap(plan.layers.first?.effectSettings.first)
        XCTAssertEqual(setting.effect, .scroll)
        XCTAssertEqual(setting.speed, -0.35)
        XCTAssertEqual(setting.speedX, 0)
        XCTAssertEqual(setting.speedY, -0.35)
        XCTAssertEqual(setting.direction, SceneVector3(x: 0, y: -1, z: 0))
    }

    func testRenderPlanConvertsShaderDirectionAnglesToVectors() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "direction-angle.pkg")
        let sceneJSON = """
        {
          "objects": [
            {
              "id": 1,
              "name": "Wave",
              "image": "models/wave.json",
              "effects": [
                {
                  "file": "effects/waterwaves/effect.json",
                  "passes": [
                    { "constantshadervalues": { "direction": 1.5707963267948966, "speed": 4, "strength": 0.08, "scale": 40, "perspective": 0.1 } }
                  ]
                }
              ]
            }
          ]
        }
        """
        try Fixture.writeScenePackage(
            to: packageURL,
            sceneJSON: sceneJSON,
            extraEntries: [
                (path: "models/wave.json", data: Data(#"{"material":"materials/wave.json"}"#.utf8)),
                (path: "materials/wave.json", data: Data(#"{"passes":[{"textures":["wave"]}]}"#.utf8)),
                (path: "materials/wave.tex", data: Fixture.texData(width: 1, height: 1, imageData: png))
            ]
        )

        // When
        let plan = try SceneRenderPlanBuilder().build(url: packageURL)

        // Then
        let setting = try XCTUnwrap(plan.layers.first?.effectSettings.first)
        XCTAssertEqual(setting.effect, .waterWaves)
        XCTAssertEqual(setting.direction?.x ?? 0, -1, accuracy: 0.000_001)
        XCTAssertEqual(setting.direction?.y ?? 0, 0, accuracy: 0.000_001)
        XCTAssertEqual(setting.direction?.z ?? 0, 0, accuracy: 0.000_001)
        XCTAssertEqual(setting.perspective, 0.1)
    }
}
