import AppKit
import WorkshopWallpaperCore
import XCTest
@testable import WorkshopWallpaperBridgeApp

final class SceneWallpaperViewEffectParityTests: XCTestCase {
    func testSpinAnimationParametersFollowSpeedSignAndMagnitude() {
        let clockwise = SceneWallpaperView.spinAnimationParameters(
            for: SceneLayerEffectSetting(effect: .spin, speed: -0.16)
        )
        XCTAssertEqual(clockwise.byValue, -CGFloat.pi * 2)
        XCTAssertEqual(clockwise.duration, (2 * Double.pi) / 0.16, accuracy: 0.001)

        let counterClockwise = SceneWallpaperView.spinAnimationParameters(
            for: SceneLayerEffectSetting(effect: .spin, speed: 0.5)
        )
        XCTAssertEqual(counterClockwise.byValue, CGFloat.pi * 2)
        XCTAssertEqual(counterClockwise.duration, (2 * Double.pi) / 0.5, accuracy: 0.001)

        let defaulted = SceneWallpaperView.spinAnimationParameters(
            for: SceneLayerEffectSetting(effect: .spin)
        )
        XCTAssertEqual(defaulted.byValue, CGFloat.pi * 2)
        XCTAssertEqual(defaulted.duration, 8, accuracy: 0.001)
    }

    func testMaskedSpinIsShaderRenderableAndUnmaskedSpinIsNot() {
        let masked = SceneLayerEffectSetting(
            effect: .spin,
            speed: -0.16,
            maskReference: SceneEffectMaskReference(source: "mask", texturePath: "materials/mask.tex")
        )
        let unmasked = SceneLayerEffectSetting(effect: .spin, speed: -0.16)
        let sparkle = SceneLayerEffectSetting(effect: .sparkle)

        let renderable = SceneWallpaperView.shaderRenderableEffects(from: [masked, unmasked, sparkle])

        XCTAssertEqual(renderable.count, 2)
        XCTAssertTrue(renderable.contains { $0.effect == .spin && $0.usesMask })
        XCTAssertTrue(renderable.contains { $0.effect == .sparkle })
    }

    func testEmitterConfigurationMapsWallpaperEngineUnits() {
        // Values mirror the Chaotic_particles system from Painting the Sharks.
        let particle = SceneParticleLayer(
            name: "chaotic",
            origin: SceneVector3(x: 1920, y: 1080, z: 0),
            maxCount: 500,
            rate: 15000,
            lifetimeMin: 0.5,
            lifetimeMax: 5,
            sizeMin: 70,
            sizeMax: 85,
            velocityMin: SceneVector3(x: -200, y: -200, z: 0),
            velocityMax: SceneVector3(x: 200, y: 200, z: 0),
            emitterRadius: 2000,
            hasAlphaFade: true
        )

        let configuration = SceneWallpaperView.emitterConfiguration(
            for: particle,
            spriteSize: CGSize(width: 64, height: 64),
            canvasSize: SceneSize(width: 3840, height: 2160)
        )

        // Birth rate is capped by maxcount / average lifetime (not the raw
        // rate) and damped to keep the wallpaper approximation subtle.
        XCTAssertEqual(configuration.birthRate, Float(500 / 2.75 * 0.35), accuracy: 0.5)
        XCTAssertEqual(configuration.lifetime, 2.75, accuracy: 0.001)
        XCTAssertEqual(configuration.lifetimeRange, 2.25, accuracy: 0.001)
        XCTAssertEqual(configuration.velocityRange, 200)
        XCTAssertEqual(configuration.scale, 77.5 / 64, accuracy: 0.001)
        XCTAssertEqual(configuration.alphaSpeed, -0.2, accuracy: 0.001)
        XCTAssertEqual(configuration.emitterSize, CGSize(width: 3840, height: 2160))
    }

    func testPulseRingParticleDetection() {
        let pulse = SceneParticleLayer(
            name: "magic pulse",
            origin: SceneVector3(x: 2634, y: 244, z: 0),
            maxCount: 16,
            rate: 1,
            lifetimeMin: 1,
            lifetimeMax: 1,
            sizeMin: 650,
            sizeMax: 650,
            sizeChangeStart: 0,
            sizeChangeEnd: 2
        )
        let chaotic = SceneParticleLayer(
            name: "chaotic",
            origin: SceneVector3(x: 0, y: 0, z: 0),
            maxCount: 500,
            rate: 15000,
            lifetimeMin: 0.5,
            lifetimeMax: 5,
            sizeMin: 70,
            sizeMax: 85
        )

        XCTAssertTrue(SceneWallpaperView.isPulseRingParticle(pulse))
        XCTAssertFalse(SceneWallpaperView.isPulseRingParticle(chaotic))
    }

    func testScrollWarpKernelUsesLinearSpeed() throws {
        let source = try String(contentsOfFile: "Sources/WorkshopWallpaperBridgeApp/SceneWallpaperView.swift")

        XCTAssertTrue(source.contains("vec2 scroll = vec2(speedX, speedY) * time;"))
        XCTAssertFalse(source.contains("sign(scroll) * scroll * scroll * time"))
    }

    func testSparkleEffectOnlyLayersStartFromTransparentBase() throws {
        let source = try String(contentsOfFile: "Sources/WorkshopWallpaperBridgeApp/SceneWallpaperView.swift")

        XCTAssertTrue(source.contains("effects.allSatisfy { $0.effect == .sparkle }"))
        XCTAssertTrue(source.contains("sparkleBand"))
    }
}
