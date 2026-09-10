import AppKit
import CoreImage
import XCTest
import WorkshopWallpaperCore
@testable import WorkshopWallpaperBridgeApp

@MainActor
final class SceneShaderEffectTests: XCTestCase {
    func testPendingShaderKeepsProcessedFrameAcrossAnimationTicks() async throws {
        let context = CIContext(), rect = CGRect(x: 0, y: 0, width: 2, height: 2)
        let first = try XCTUnwrap(context.createCGImage(CIImage(color: .white).cropped(to: rect), from: rect))
        let second = try XCTUnwrap(context.createCGImage(CIImage(color: .black).cropped(to: rect), from: rect))
        let processed = try XCTUnwrap(context.createCGImage(CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: rect), from: rect))
        let model = SceneLayer(id: 1, name: "animated", texturePath: "", origin: .init(x: 1, y: 1, z: 0), size: .init(width: 2, height: 2), scale: .init(x: 1, y: 1, z: 1), alpha: 1, originAnimation: nil)
        let animated = SceneMediaOverlayPlan.Layer(model: model, alignment: "center", image: first,
            animation: .init(images: [first, second], keyTimes: [0, 0.5], duration: 0.02), thumbnail: false, masks: [],
            shaderEffects: [.init(id: "held", passes: [])])
        let plan = SceneMediaOverlayPlan(canvas: rect.size, layers: [animated], particles: [], compositions: [], order: [1],
            configuration: ["layers": [["id": 1, "name": "animated", "values": ["visible": true], "scripts": []]]], metrics: SceneTextMetrics())
        let pending = expectation(description: "Second render held after the first processed frame")
        var calls = 0
        var continuation: CheckedContinuation<SceneShaderResult, any Error>?
        let view = MediaSceneWallpaperView(videoURL: URL(filePath: "/dev/null"), previewURL: nil, plan: plan, frame: rect,
            renderShader: { _ in
                calls += 1
                if calls == 1 { return SceneShaderResult(image: processed) }
                return try await withCheckedThrowingContinuation {
                    continuation = $0
                    pending.fulfill()
                }
            })
        view.mediaProvider = { WallpaperMediaSnapshot() }
        defer {
            view.prepareForClose()
            continuation?.resume(throwing: CancellationError())
        }
        await fulfillment(of: [pending], timeout: 2)
        let layer = try XCTUnwrap(view.layer?.sublayers?.flatMap { $0.sublayers ?? [] }.first { $0.name == "animated" })
        for _ in 0..<3 {
            view.tick()
            XCTAssertTrue(layer.contents as AnyObject? === processed, "Raw animation frames must not overwrite a processed image while its next GPU render is pending")
        }
        XCTAssertEqual(calls, 2, "Ticks must not queue additional GPU work")
        view.setPlaybackSuspended(true)
        continuation?.resume(returning: SceneShaderResult(image: second)); continuation = nil
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(layer.contents as AnyObject? === processed, "Suspension must reject the deterministically pending render")
    }

    func testShaderFailureFallsBackToArtworkAndKeepsAcceptingChanges() async throws {
        let rect = CGRect(x: 0, y: 0, width: 2, height: 2)
        let model = SceneLayer(id: 1, name: "artwork", texturePath: "", origin: .init(x: 1, y: 1, z: 0), size: .init(width: 2, height: 2), scale: .init(x: 1, y: 1, z: 1), alpha: 1, originAnimation: nil)
        let artwork = SceneMediaOverlayPlan.Layer(model: model, alignment: "center", image: nil, animation: nil,
            thumbnail: true, masks: [], shaderEffects: [.init(id: "failed", passes: [])])
        let plan = SceneMediaOverlayPlan(canvas: rect.size, layers: [artwork], particles: [], compositions: [], order: [1],
            configuration: ["layers": [["id": 1, "name": "artwork", "values": ["visible": true], "scripts": []]]], metrics: SceneTextMetrics())
        let failed = expectation(description: "Shader failure")
        var calls = 0
        let view = MediaSceneWallpaperView(videoURL: URL(filePath: "/dev/null"), previewURL: nil, plan: plan, frame: rect,
            renderShader: { _ in
                calls += 1; failed.fulfill()
                throw SceneShaderEffect.Failure.unsupported("test shader failure")
            })
        defer { view.prepareForClose() }
        var media = WallpaperMediaSnapshot()
        view.mediaProvider = { media }
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertNotNil(view.diagnostic)
        let layer = try XCTUnwrap(view.layer?.sublayers?.flatMap { $0.sublayers ?? [] }.first { $0.name == "artwork" })
        var previous: AnyObject?
        for (index, color) in [NSColor.red, .blue].enumerated() {
            let image = NSImage(size: rect.size, flipped: false) { rect in color.setFill(); rect.fill(); return true }
            media.artwork = image.tiffRepresentation; media.artworkRevision = "fallback-\(index)"
            view.tick()
            XCTAssertNotNil(layer.contents)
            XCTAssertFalse(layer.contents as AnyObject? === previous, "Shader failure must still allow fresh artwork")
            previous = layer.contents as AnyObject?
        }
        XCTAssertEqual(calls, 1, "A failed shader must not be retried every frame")
    }

    func testShaderSourceFollowsAnimationAndArtwork() throws {
        let context = CIContext(), rect = CGRect(x: 0, y: 0, width: 2, height: 2)
        let first = try XCTUnwrap(context.createCGImage(CIImage(color: .white).cropped(to: rect), from: rect))
        let second = try XCTUnwrap(context.createCGImage(CIImage(color: .black).cropped(to: rect), from: rect))
        let model = SceneLayer(id: 1, name: "animated", texturePath: "", origin: .init(x: 0, y: 0, z: 0), size: .init(width: 2, height: 2), scale: .init(x: 1, y: 1, z: 1), alpha: 1, originAnimation: nil)
        let animated = SceneMediaOverlayPlan.Layer(model: model, alignment: "center", image: first,
            animation: .init(images: [first, second], keyTimes: [0, 0.5], duration: 2), thumbnail: false, masks: [], shaderEffects: [])
        XCTAssertTrue(MediaSceneWallpaperView.sourceImage(for: animated, time: 1.5, artwork: nil) === second)
        let media = SceneMediaOverlayPlan.Layer(model: model, alignment: "center", image: first, animation: nil, thumbnail: true, masks: [], shaderEffects: [])
        XCTAssertTrue(MediaSceneWallpaperView.sourceImage(for: media, time: 0, artwork: second) === second)
    }

    func testTextureUploadAndReadbackPreserveRowOrder() throws {
        let bytes = Data([255,0,0,255, 0,255,0,255, 0,0,255,255, 255,255,255,255] as [UInt8])
        let input = try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: .init(rawValue: CGImageAlphaInfo.last.rawValue), provider: CGDataProvider(data: bytes as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let output = try SceneShaderRenderer().render(input, effects: [], time: 0, values: [:])
        XCTAssertEqual(output.dataProvider?.data as Data?, bytes)
    }
    func testUploadingAuxiliaryTextureDoesNotReplaceTheInputSampler() throws {
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let extent = CGRect(x: 0, y: 0, width: 8, height: 8)
        let input = try XCTUnwrap(context.createCGImage(CIImage(color: CIColor(red: 0.8, green: 0, blue: 0)).cropped(to: extent), from: extent))
        let auxiliary = try XCTUnwrap(context.createCGImage(CIImage(color: CIColor(red: 0, green: 0, blue: 0.5)).cropped(to: extent), from: extent))
        var pass = SceneShaderEffect.Pass(vertex: """
        attribute vec3 a_Position; attribute vec2 a_TexCoord; varying vec2 uv;
        void main(){gl_Position=vec4(a_Position,1.0);uv=a_TexCoord;}
        """, fragment: """
        varying vec2 uv; uniform sampler2D g_Texture0; uniform sampler2D g_Texture1;
        void main(){gl_FragColor=vec4(texSample2D(g_Texture0,uv).r,texSample2D(g_Texture1,uv).b,0.0,1.0);}
        """)
        pass.textures[1] = auxiliary
        let output = try SceneShaderRenderer().render(input, effects: [.init(id: "samplers", passes: [pass])], time: 0, values: [:])
        let data = try XCTUnwrap(output.dataProvider?.data) as Data
        XCTAssertEqual(Int(data[0]), 204, accuracy: 3)
        XCTAssertEqual(Int(data[1]), 128, accuracy: 3)
    }

    func testNamedSamplerEnablesItsComboAndDiscardPixelsAreTransparent() throws {
        let pass = SceneShaderEffect.Pass(vertex: """
        attribute vec3 a_Position; attribute vec2 a_TexCoord; varying vec2 uv;
        void main(){gl_Position=vec4(a_Position,1.0);uv=a_TexCoord;}
        """, fragment: """
        // [COMBO] {"combo":"HASPREVIOUS","default":0}
        uniform sampler2D g_Texture1; // {"combo":"HASPREVIOUS"}
        varying vec2 uv;
        void main(){
            if(uv.x < 0.5) discard;
        #if HASPREVIOUS
            gl_FragColor=texSample2D(g_Texture1,uv);
        #else
            gl_FragColor=vec4(0.0);
        #endif
        }
        """, bindings: [1: "previous"])
        XCTAssertEqual(pass.resolvedCombos["HASPREVIOUS"], 1)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let extent = CGRect(x: 0, y: 0, width: 8, height: 8)
        let input = try XCTUnwrap(context.createCGImage(CIImage(color: .white).cropped(to: extent), from: extent))
        let output = try SceneShaderRenderer().render(input, effects: [.init(id: "discard", passes: [pass])], time: 0, values: [:])
        let data = try XCTUnwrap(output.dataProvider?.data) as Data
        XCTAssertEqual(data[3], 0)
        XCTAssertEqual(data[7 * 4 + 3], 255)
    }
    func testComposeCoordinatesPreservePositionWhenScaling() {
        let layer = CALayer()
        layer.position = CGPoint(x: 100, y: 60)
        layer.bounds = CGRect(x: 0, y: 0, width: 20, height: 10)
        layer.setAffineTransform(CGAffineTransform(scaleX: 2, y: 3))
        let transform = MediaSceneWallpaperView.localToCanvas(layer)
        XCTAssertEqual(CGPoint.zero.applying(transform), CGPoint(x: 80, y: 45))
        XCTAssertEqual(CGPoint(x: 20, y: 10).applying(transform), CGPoint(x: 120, y: 75))
    }

    func testComposeCapturesLowerLayersInItsTransformedRegion() throws {
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let rect = CGRect(x: 0, y: 0, width: 64, height: 64)
        let video = try XCTUnwrap(context.createCGImage(CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: rect), from: rect))
        let lower = CALayer(); lower.frame = CGRect(x: 16, y: 16, width: 32, height: 32)
        lower.backgroundColor = NSColor.green.cgColor; lower.zPosition = 1
        let target = CALayer(); target.bounds = CGRect(x: 0, y: 0, width: 16, height: 16)
        target.position = CGPoint(x: 32, y: 32); target.setAffineTransform(CGAffineTransform(scaleX: 2, y: 2)); target.zPosition = 2
        let upper = CALayer(); upper.frame = rect; upper.backgroundColor = NSColor.blue.cgColor; upper.zPosition = 3
        let snapshot = try XCTUnwrap(MediaSceneWallpaperView.composeInput(for: target, video: video, canvas: rect.size, layers: [upper, lower, target]))
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(CIImage(cgImage: snapshot), toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 8, y: 8, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        XCTAssertLessThan(pixel[0], 5)
        XCTAssertGreaterThan(pixel[1], 240)
        XCTAssertLessThan(pixel[2], 5, "A compose pass must not copy layers above it")
    }

    func testOriginalPassesUseNamedTargetsAndPreviousInput() throws {
        let vertex = """
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 uv;
        void main() { gl_Position = vec4(a_Position, 1.0); uv = a_TexCoord; }
        """
        let first = SceneShaderEffect.Pass(vertex: vertex, fragment: """
        varying vec2 uv;
        uniform sampler2D g_Texture0;
        void main() { gl_FragColor = vec4(0.0, texSample2D(g_Texture0, uv).r, 0.0, 1.0); }
        """, target: "intermediate", bindings: [0: "previous"])
        let second = SceneShaderEffect.Pass(vertex: vertex, fragment: """
        varying vec2 uv;
        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture1;
        uniform float strength; // {"material":"amount","default":0.25}
        uniform float g_Time;
        void main() {
            gl_FragColor = vec4(texSample2D(g_Texture1, uv).r,
                texSample2D(g_Texture0, uv).g * strength, g_Time * 0.1, 1.0);
        }
        """, bindings: [0: "intermediate", 1: "previous"], constants: ["amount": 0.5])
        let effect = SceneShaderEffect(id: "test", passes: [first, second])
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let bounds = CGRect(x: 0, y: 0, width: 16, height: 16)
        let input = try XCTUnwrap(context.createCGImage(CIImage(color: CIColor(red: 0.8, green: 0, blue: 0)).cropped(to: bounds), from: bounds))
        let renderer = try SceneShaderRenderer()
        let result = try renderer.render(input, effects: [effect], time: 2, values: [:])
        let data = try XCTUnwrap(result.dataProvider?.data) as Data
        XCTAssertEqual(Int(data[0]), 204, accuracy: 3)
        XCTAssertEqual(Int(data[1]), 102, accuracy: 3)
        XCTAssertEqual(Int(data[2]), 51, accuracy: 3)
        let hidden = try renderer.render(input, effects: [effect], time: 2, values: ["test": ["visible": false]])
        let hiddenData = try XCTUnwrap(hidden.dataProvider?.data) as Data
        XCTAssertEqual(hiddenData[1], 0)
    }

    func testLocalSummerComposeShadersProduceTimeDependentPixels() throws {
        guard let library = ProcessInfo.processInfo.environment["WWB_LOCAL_SCENE_LIBRARY"] else {
            throw XCTSkip("Opt-in private scene shader check")
        }
        let plan = try XCTUnwrap(SceneMediaOverlayPlan.build(url: URL(filePath: library).appending(path: "Assets/id-MzAwMDU2MjQyNw/scene.pkg")))
        XCTAssertEqual(Set(plan.compositions.map(\.model.id)), [635, 382])
        XCTAssertTrue(plan.excludedIDs.contains(635))
        XCTAssertTrue(plan.excludedIDs.contains(382))
        XCTAssertEqual(plan.layers.first { $0.model.id == 396 }?.shaderEffects.count, 4)
        let renderer = try SceneShaderRenderer()
        let context = CIContext()
        let bounds = CGRect(x: 0, y: 0, width: 256, height: 128)
        let checker = try XCTUnwrap(CIFilter(name: "CICheckerboardGenerator", parameters: ["inputWidth": 8])?.outputImage)
        let input = try XCTUnwrap(context.createCGImage(checker, from: bounds))
        for item in plan.compositions {
            let a = try renderer.render(input, effects: item.effects, time: 1, values: [:])
            let b = try renderer.render(input, effects: item.effects, time: 2, values: [:])
            XCTAssertNotEqual(a.dataProvider?.data as Data?, b.dataProvider?.data as Data?, "\(item.model.name) must consume live time")
        }
        for item in plan.layers where !item.shaderEffects.isEmpty {
            let overrides = Dictionary(uniqueKeysWithValues: item.shaderEffects.map { ($0.id, ["visible": true] as [String: Any]) })
            let output = try renderer.render(try XCTUnwrap(item.image ?? input), effects: item.shaderEffects,
                time: 1, values: overrides, currentArtwork: input, previousArtwork: input)
            XCTAssertNotNil(output.dataProvider?.data)
        }
    }
}
