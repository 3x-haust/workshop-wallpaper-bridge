import Foundation
import XCTest
@testable import WorkshopWallpaperCore

final class ScenePackageTests: XCTestCase {
    func testReaderParsesPackageEntriesAndSceneData() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "scene.pkg")
        let sceneJSON = #"{"objects":[{"image":"models/background.json"}]}"#
        try Fixture.writeScenePackage(
            to: packageURL,
            sceneJSON: sceneJSON,
            extraEntries: [(path: "materials/background.tex", data: Data([1, 2, 3]))]
        )

        // When
        let package = try ScenePackageReader().read(url: packageURL)

        // Then
        XCTAssertEqual(package.magic, "PKGV0007")
        XCTAssertEqual(package.entries.map(\.path), ["scene.json", "materials/background.tex"])
        let sceneEntry = try XCTUnwrap(package.entry(named: "scene.json"))
        XCTAssertEqual(String(data: package.data(for: sceneEntry), encoding: .utf8), sceneJSON)
    }

    func testReaderRejectsPathEscapingEntries() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "scene.pkg")
        let data = Fixture.scenePackageData(entries: [(path: "../escape.json", data: Data())])
        try data.write(to: packageURL, options: [.atomic])

        // Then
        XCTAssertThrowsError(try ScenePackageReader().read(url: packageURL)) { error in
            XCTAssertEqual(error as? ScenePackageError, .unsafeEntryPath("../escape.json"))
        }
    }

    func testReaderRejectsAbsoluteEntries() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "scene.pkg")
        let data = Fixture.scenePackageData(entries: [(path: "/tmp/escape.json", data: Data())])
        try data.write(to: packageURL, options: [.atomic])

        // Then
        XCTAssertThrowsError(try ScenePackageReader().read(url: packageURL)) { error in
            XCTAssertEqual(error as? ScenePackageError, .unsafeEntryPath("/tmp/escape.json"))
        }
    }

    func testReaderRejectsInvalidEntryRanges() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "scene.pkg")
        var data = Fixture.scenePackageData(entries: [(path: "scene.json", data: Data("{}".utf8))])
        data.replaceSubrange(34..<38, with: littleEndianInt32Bytes(2_000_000_000))
        try data.write(to: packageURL, options: [.atomic])

        // Then
        XCTAssertThrowsError(try ScenePackageReader().read(url: packageURL)) { error in
            XCTAssertEqual(error as? ScenePackageError, .invalidEntryRange("scene.json"))
        }
    }

    func testReaderRejectsPackagesAboveConfiguredSizeLimit() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "scene.pkg")
        FileManager.default.createFile(atPath: packageURL.path, contents: Data())
        let handle = try FileHandle(forWritingTo: packageURL)
        try handle.truncate(atOffset: 128)
        try handle.close()

        // Then
        XCTAssertThrowsError(try ScenePackageReader(maximumPackageBytes: 64).read(url: packageURL)) { error in
            XCTAssertEqual(error as? ScenePackageError, .packageTooLarge(128, 64))
        }
    }

    func testAnalyzerSummarizesSceneFeatures() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "scene.pkg")
        let sceneJSON = """
        {
          "objects": [
            {
              "image": "models/background.json",
              "origin": {
                "value": "0 0 0",
                "animation": {
                  "options": { "fps": 30, "length": 30 },
                  "c0": [ { "frame": 0, "value": 0 }, { "frame": 30, "value": 100 } ]
                }
              }
            },
            {"particle": "particles/leaves.json"},
            {
              "text": "SALE",
              "alpha": {
                "value": 1,
                "animation": {
                  "options": { "fps": 30, "length": 30 },
                  "c0": [ { "frame": 0, "value": 1 }, { "frame": 30, "value": 0 } ]
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
                (path: "materials/background.tex", data: Data([1])),
                (path: "effects/pulse/effect.json", data: Data([2])),
                (path: "shaders/effects/pulse.frag", data: Data([3])),
                (path: "fonts/title.ttf", data: Data([4])),
                (path: "sounds/loop.mp3", data: Data([5]))
            ]
        )

        // When
        let analysis = try ScenePackageAnalyzer().analyze(url: packageURL)

        // Then
        XCTAssertEqual(analysis.objectCount, 3)
        XCTAssertEqual(analysis.imageObjectCount, 1)
        XCTAssertEqual(analysis.particleObjectCount, 1)
        XCTAssertEqual(analysis.textObjectCount, 1)
        XCTAssertEqual(analysis.animatedObjectCount, 2)
        XCTAssertEqual(analysis.originAnimationCount, 1)
        XCTAssertEqual(analysis.alphaAnimationCount, 1)
        XCTAssertEqual(analysis.textureEntryCount, 1)
        XCTAssertEqual(analysis.effectEntryCount, 1)
        XCTAssertEqual(analysis.shaderEntryCount, 1)
        XCTAssertEqual(analysis.fontEntryCount, 1)
        XCTAssertEqual(analysis.audioEntryCount, 1)
        XCTAssertTrue(analysis.requiresFullRenderer)
        XCTAssertTrue(analysis.userFacingSummary.contains("1 image layer"))
        XCTAssertTrue(analysis.userFacingSummary.contains("1 particle system"))
        XCTAssertTrue(analysis.userFacingSummary.contains("2 animated object(s)"))
        XCTAssertTrue(analysis.userFacingSummary.contains("selected clock text"))
        XCTAssertTrue(analysis.userFacingSummary.contains("selected effect playback"))
        XCTAssertTrue(analysis.userFacingSummary.contains("engine rendering features"))
    }

    func testRuntimeFeatureAnalyzerPreservesEngineRendererRequirements() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "engine-scene.pkg")
        let sceneJSON = """
        {
          "objects": [
            {
              "id": 1,
              "name": "Water",
              "image": "models/water.json",
              "effects": [
                {
                  "file": "effects/waterflow/effect.json",
                  "passes": [
                    {
                      "constantshadervalues": {
                        "speed": 0.45,
                        "strength": 0.47
                      }
                    }
                  ]
                }
              ]
            },
            {
              "id": 2,
              "name": "Clock",
              "text": {
                "value": "12:34",
                "script": "export function update() { const time = new Date(); return time.getHours(); }"
              }
            },
            { "id": 3, "name": "Foam", "particle": "particles/foam.json" },
            { "id": 4, "name": "Sea audio", "sound": "sounds/sea.ogg" }
          ]
        }
        """
        try Fixture.writeScenePackage(
            to: packageURL,
            sceneJSON: sceneJSON,
            extraEntries: [
                (path: "models/water.json", data: Data(#"{"material":"materials/water.json"}"#.utf8)),
                (path: "materials/water.json", data: Data(#"{"passes":[{"textures":["water"]}]}"#.utf8)),
                (path: "materials/water.tex", data: Data([1])),
                (path: "effects/waterflow/effect.json", data: Data([2])),
                (
                    path: "shaders/effects/waterflow.frag",
                    data: Data("float t = g_Time + g_AudioSpectrum16Left[0];".utf8)
                ),
                (path: "sounds/sea.ogg", data: Data([3])),
                (path: "textures/ripple.webm", data: Data([4]))
            ]
        )

        // When
        let features = try SceneRuntimeFeatureAnalyzer().analyze(url: packageURL)

        // Then
        XCTAssertTrue(features.requiresEngineRenderer)
        XCTAssertTrue(features.requiresShaderPipeline)
        XCTAssertTrue(features.requiresSceneScriptRuntime)
        XCTAssertTrue(features.requiresParticleRuntime)
        XCTAssertTrue(features.requiresSoundRuntime)
        XCTAssertFalse(features.requiresModelRuntime)
        XCTAssertTrue(features.requiresAudioAnalysis)
        XCTAssertTrue(features.requiresVideoTextureRuntime)
        XCTAssertEqual(features.materialFiles, ["materials/water.json"])
        XCTAssertEqual(features.effectFiles, ["effects/waterflow/effect.json"])
        XCTAssertEqual(features.shaderFiles, ["shaders/effects/waterflow.frag"])
        XCTAssertEqual(features.audioFiles, ["sounds/sea.ogg"])
        XCTAssertEqual(features.videoFiles, ["textures/ripple.webm"])
        XCTAssertEqual(features.shaderUniforms, ["g_AudioSpectrum16Left", "g_Time"])
        XCTAssertEqual(features.layers.first?.constantShaderValueKeys, ["speed", "strength"])
        XCTAssertEqual(features.layers.first { $0.name == "Clock" }?.scriptCount, 1)
        XCTAssertTrue(features.runtimeGaps.contains("metal-shader-effect-pipeline"))
        XCTAssertTrue(features.runtimeGaps.contains("audio-analysis-uniforms"))
    }

    func testRuntimeFeatureAnalyzerMarksModelOnlySceneAsEngineRendererRequirement() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let packageURL = root.appending(path: "model-only.pkg")
        let sceneJSON = """
        {
          "objects": [
            { "id": 1, "name": "Ship mesh", "model": "models/ship.json" }
          ]
        }
        """
        try Fixture.writeScenePackage(
            to: packageURL,
            sceneJSON: sceneJSON,
            extraEntries: [(path: "models/ship.json", data: Data([1]))]
        )

        // When
        let analysis = try ScenePackageAnalyzer().analyze(url: packageURL)

        // Then
        XCTAssertEqual(analysis.modelObjectCount, 1)
        XCTAssertTrue(analysis.requiresFullRenderer)
        XCTAssertTrue(analysis.runtimeFeatures.requiresModelRuntime)
        XCTAssertEqual(analysis.runtimeFeatures.runtimeGaps, ["model-layer-runtime"])
    }
}

private func littleEndianInt32Bytes(_ value: Int) -> Data {
    var raw = Int32(value).littleEndian
    return Swift.withUnsafeBytes(of: &raw) { Data($0) }
}
