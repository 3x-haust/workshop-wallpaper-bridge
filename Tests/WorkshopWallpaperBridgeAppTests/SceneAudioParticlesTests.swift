import AppKit
import CoreImage
import WorkshopWallpaperCore
import XCTest
@testable import WorkshopWallpaperBridgeApp

@MainActor
final class SceneAudioParticlesTests: XCTestCase {
    func testUnsupportedEmitterAndInitializerAreRejected() {
        XCTAssertFalse(SceneAudioParticles.supports(["emitter": [["name": "boxrandom"]]]))
        XCTAssertFalse(SceneAudioParticles.supports(["emitter": [["name": "sphererandom"]], "initializer": [["name": "rotationrandom"]]]))
        XCTAssertFalse(SceneAudioParticles.supports(["emitter": [["name": "sphererandom"]], "operator": [["name": "vortex"]]], trail: true))
        XCTAssertFalse(SceneAudioParticles.supports(["emitter": [["name": "sphererandom"]], "children": [["type": "eventfollow", "name": "nested.json"]]], trail: true))
    }
    func testEmissionRateLifetimeAndPrewarmUseAuthoredValues() throws {
        let model = SceneLayer(id: 1, name: "test", texturePath: "", origin: .init(x: 0, y: 0, z: 0), size: .init(width: 64, height: 64), scale: .init(x: 1, y: 1, z: 1), alpha: 1, originAnimation: nil)
        let rect = CGRect(x: 0, y: 0, width: 4, height: 4)
        let sprite = try XCTUnwrap(CIContext().createCGImage(CIImage(color: .white).cropped(to: rect), from: rect))
        var settings: [String: Any] = ["maxcount": 20, "emitter": [["name": "sphererandom", "rate": 2]],
            "initializer": [["name": "lifetimerandom", "min": 1, "max": 1]], "operator": []]
        let system = SceneAudioParticles(plan: .init(model: model, settings: settings, overrides: [:], sprite: sprite, trail: nil, trailSprite: nil))
        XCTAssertEqual(system.activeParticleCount, 0, "An emitter must not begin at maximum population")
        for _ in 0..<5 { system.step(seconds: 0.1, spectrum: .init()) }
        XCTAssertEqual(system.activeParticleCount, 1)
        for _ in 0..<50 { system.step(seconds: 0.1, spectrum: .init()) }
        XCTAssertLessThanOrEqual(system.activeParticleCount, 2, "Lifetime and rate must determine population")
        settings["starttime"] = 3
        let warm = SceneAudioParticles(plan: .init(model: model, settings: settings, overrides: [:], sprite: sprite, trail: nil, trailSprite: nil))
        XCTAssertEqual(warm.activeParticleCount, 2)
    }
}
