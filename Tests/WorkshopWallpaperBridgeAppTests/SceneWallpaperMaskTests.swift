import QuartzCore
import XCTest
import WorkshopWallpaperCore
@testable import WorkshopWallpaperBridgeApp

@MainActor
final class SceneWallpaperMaskTests: XCTestCase {
    func testSceneWallpaperAppliesDecodedOpacityMaskToImageLayer() throws {
        // Given
        let layer = Self.layer(
            isEffectOnly: false,
            effectSettings: [
                SceneLayerEffectSetting(
                    effect: .opacity,
                    maskReference: SceneEffectMaskReference(
                        source: "masks/fish-mask",
                        texturePath: "masks/fish-mask.tex"
                    )
                )
            ]
        )
        let texture = SceneTexture(
            width: 1,
            height: 1,
            storage: .rgba(width: 1, height: 1, data: Data([255, 255, 255, 255]))
        )

        // When
        let maskPath = SceneWallpaperView.opacityMaskTexturePath(for: layer)
        let maskLayer = SceneWallpaperView.opacityMaskLayer(
            from: texture,
            bounds: CGRect(x: 0, y: 0, width: 320, height: 180),
            contentsScale: 2
        )

        // Then
        XCTAssertEqual(maskPath, "masks/fish-mask.tex")
        let resolvedMaskLayer = try XCTUnwrap(maskLayer)
        XCTAssertNotNil(resolvedMaskLayer.contents)
        XCTAssertEqual(resolvedMaskLayer.bounds, CGRect(x: 0, y: 0, width: 320, height: 180))
        XCTAssertEqual(resolvedMaskLayer.position, CGPoint(x: 160, y: 90))

        let source = try String(contentsOfFile: "Sources/WorkshopWallpaperBridgeApp/SceneWallpaperView.swift")
        XCTAssertTrue(source.contains("contentLayer.mask = maskLayer"))
    }

    func testSceneWallpaperLeavesUnresolvedMaskStaticAndDiagnosticOnly() {
        // Given
        let unresolved = Self.layer(
            isEffectOnly: false,
            effectSettings: [
                SceneLayerEffectSetting(
                    effect: .opacity,
                    maskReference: SceneEffectMaskReference(source: "masks/missing-mask", texturePath: nil)
                )
            ]
        )
        let effectOnly = Self.layer(
            isEffectOnly: true,
            effectSettings: [
                SceneLayerEffectSetting(
                    effect: .opacity,
                    maskReference: SceneEffectMaskReference(
                        source: "masks/effect-only-mask",
                        texturePath: "masks/effect-only-mask.tex"
                    )
                )
            ]
        )
        let nonOpacityMask = Self.layer(
            isEffectOnly: false,
            effectSettings: [
                SceneLayerEffectSetting(
                    effect: .waterWaves,
                    maskReference: SceneEffectMaskReference(
                        source: "masks/waves-mask",
                        texturePath: "masks/waves-mask.tex"
                    )
                )
            ]
        )

        // Then
        XCTAssertNil(SceneWallpaperView.opacityMaskTexturePath(for: unresolved))
        XCTAssertNil(SceneWallpaperView.opacityMaskTexturePath(for: effectOnly))
        XCTAssertNil(SceneWallpaperView.opacityMaskTexturePath(for: nonOpacityMask))
    }

    func testSceneWallpaperDoesNotAdvertiseCloudsUntilPixelsActuallyChange() {
        // Given
        let effects = [SceneLayerEffectSetting(effect: .clouds)]

        // When
        let renderable = SceneWallpaperView.shaderRenderableEffects(from: effects).map(\.effect)

        // Then
        XCTAssertFalse(renderable.contains(.clouds))
    }

    func testSceneWallpaperRejectsOversizedEffectOnlyBitmapSizes() {
        // Then
        XCTAssertTrue(SceneWallpaperView.isSafeBitmapSize(CGSize(width: 4096, height: 4096)))
        XCTAssertFalse(SceneWallpaperView.isSafeBitmapSize(CGSize(width: 100_000, height: 100_000)))
        XCTAssertFalse(SceneWallpaperView.isSafeBitmapSize(CGSize(width: CGFloat.infinity, height: 100)))
        XCTAssertFalse(SceneWallpaperView.isSafeBitmapSize(CGSize(width: 100, height: CGFloat.nan)))
    }

    private static func layer(
        isEffectOnly: Bool,
        effectSettings: [SceneLayerEffectSetting]
    ) -> SceneLayer {
        SceneLayer(
            id: 1,
            name: "Layer",
            texturePath: "materials/layer.tex",
            effects: effectSettings.map(\.effect),
            effectSettings: effectSettings,
            isEffectOnly: isEffectOnly,
            origin: SceneVector3(x: 0, y: 0, z: 0),
            size: SceneSize(width: 320, height: 180),
            scale: SceneVector3(x: 1, y: 1, z: 1),
            alpha: 1,
            originAnimation: nil
        )
    }
}
