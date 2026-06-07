import XCTest
import WorkshopWallpaperCore
@testable import WorkshopWallpaperBridgeApp

final class SceneWallpaperViewEffectOnlyTests: XCTestCase {
    func testSceneWallpaperDoesNotBlanketSkipEffectOnlyLayers() throws {
        let source = try String(contentsOfFile: "Sources/WorkshopWallpaperBridgeApp/SceneWallpaperView.swift")

        XCTAssertFalse(source.contains("""
            if layerPlan.isEffectOnly {
                continue
            }
            """))
        XCTAssertTrue(source.contains("buildEffectOnlyShaderLayer"))
    }

    func testEffectOnlyShaderLayersAreSelectedOnlyWhenTheyHaveRenderableShaders() {
        let renderable = Self.layer(
            isEffectOnly: true,
            effectSettings: [
                SceneLayerEffectSetting(effect: .shine),
                SceneLayerEffectSetting(effect: .waterRipple),
                SceneLayerEffectSetting(effect: .shake)
            ]
        )
        let unsupported = Self.layer(
            isEffectOnly: true,
            effectSettings: [
                SceneLayerEffectSetting(effect: .shine),
                SceneLayerEffectSetting(effect: .shake)
            ]
        )
        let normal = Self.layer(
            isEffectOnly: false,
            effectSettings: [
                SceneLayerEffectSetting(effect: .waterRipple)
            ]
        )

        XCTAssertEqual(
            SceneWallpaperView.effectOnlyShaderEffects(for: renderable).map(\.effect),
            [.waterRipple]
        )
        XCTAssertTrue(SceneWallpaperView.shouldBuildEffectOnlyShaderLayer(for: renderable))
        XCTAssertTrue(SceneWallpaperView.effectOnlyShaderEffects(for: unsupported).isEmpty)
        XCTAssertFalse(SceneWallpaperView.shouldBuildEffectOnlyShaderLayer(for: unsupported))
        XCTAssertTrue(SceneWallpaperView.effectOnlyShaderEffects(for: normal).isEmpty)
        XCTAssertFalse(SceneWallpaperView.shouldBuildEffectOnlyShaderLayer(for: normal))
    }

    private static func layer(
        isEffectOnly: Bool,
        effectSettings: [SceneLayerEffectSetting]
    ) -> SceneLayer {
        SceneLayer(
            id: 1,
            name: "Effect",
            texturePath: "",
            effects: effectSettings.map(\.effect),
            effectSettings: effectSettings,
            isEffectOnly: isEffectOnly,
            origin: SceneVector3(x: 0, y: 0, z: 0),
            size: SceneSize(width: 1920, height: 1080),
            scale: SceneVector3(x: 1, y: 1, z: 1),
            alpha: 1,
            originAnimation: nil
        )
    }
}
