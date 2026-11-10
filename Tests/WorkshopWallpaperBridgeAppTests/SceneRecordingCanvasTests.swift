import AppKit
import XCTest
import WorkshopWallpaperCore
@testable import WorkshopWallpaperBridgeApp

@MainActor
final class SceneRecordingCanvasTests: XCTestCase {
    func testParticleOnlyPortraitSceneRecordsAuthoredCanvasInsteadOfDisplayRatio() async throws {
        guard VideoConverter().ffmpegPath() != nil else {
            throw XCTSkip("Factory requires an installed ffmpeg; encoding itself is stubbed")
        }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sceneURL = try particleScenePackage(in: root)
        XCTAssertThrowsError(try SceneRenderPlanBuilder().buildLayout(url: sceneURL)) {
            XCTAssertEqual($0 as? SceneRenderPlanError, .noRenderableLayers)
        }
        XCTAssertFalse(SceneRenderPlanBuilder().canBuild(url: sceneURL))

        let renderer = root.appending(path: "renderer")
        try """
        #!/bin/sh
        if [ "$1" = "--help" ]; then exit 0; fi
        printf '%s\\n' "$@" > "$0.args"
        while [ "$#" -gt 0 ]; do
            if [ "$1" = "--record-dir" ]; then
                shift
                printf 'fixture' > "$1/frame_00000.png"
                exit 0
            fi
            shift
        done
        exit 1
        """.write(to: renderer, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: renderer.path)
        let assets = root.appending(path: "assets")
        try FileManager.default.createDirectory(at: assets.appending(path: "shaders"), withIntermediateDirectories: true)
        let preview = root.appending(path: "preview.png")
        let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32))
        image.setColor(.black, atX: 0, y: 0)
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: preview)

        let previousRenderer = SceneEngineRendererConfiguration.overrideExecutablePath
        let previousAssets = SceneEngineRendererConfiguration.overrideAssetsPath
        let previousCache = SceneVideoCache.overrideCacheDirectoryURL
        let previousEncoder = SceneVideoRenderer.runProcess
        let previousCompletion = SceneWallpaperContentFactory.sceneVideoRenderCompletionHandler
        let previousDiagnostic = SceneWallpaperContentFactory.lastDiagnostic
        let previousStatus = SceneWallpaperContentFactory.statusHandler
        defer {
            SceneEngineRendererConfiguration.overrideExecutablePath = previousRenderer
            SceneEngineRendererConfiguration.overrideAssetsPath = previousAssets
            SceneVideoCache.overrideCacheDirectoryURL = previousCache
            SceneVideoRenderer.runProcess = previousEncoder
            SceneWallpaperContentFactory.sceneVideoRenderCompletionHandler = previousCompletion
            SceneWallpaperContentFactory.lastDiagnostic = previousDiagnostic
            SceneWallpaperContentFactory.statusHandler = previousStatus
        }
        SceneEngineRendererConfiguration.overrideExecutablePath = renderer.path
        SceneEngineRendererConfiguration.overrideAssetsPath = assets.path
        SceneVideoCache.overrideCacheDirectoryURL = root.appending(path: "v8")
        SceneWallpaperContentFactory.statusHandler = nil
        SceneVideoRenderer.runProcess = { _, arguments in
            let output = try XCTUnwrap(arguments.last)
            try Data("encoded fixture".utf8).write(to: URL(filePath: output))
        }
        let asset = WallpaperAsset(id: "portrait-particles", title: "Portrait particles", kind: .scene,
            supportStatus: .playable, source: .localSteamWorkshop, projectDirectory: root.path,
            entrypoint: "scene.pkg", thumbnail: "preview.png", workshopId: nil,
            redistributionAllowed: false, issues: [])
        let completed = expectation(description: "Scene recording completed")
        SceneWallpaperContentFactory.sceneVideoRenderCompletionHandler = { id in
            if id == asset.id { completed.fulfill() }
        }

        _ = try SceneWallpaperContentFactory.makeSceneContentView(asset: asset, url: sceneURL,
            previewURL: preview, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), displayMode: .fill)
        await fulfillment(of: [completed], timeout: 10)

        let arguments = try String(contentsOf: renderer.appendingPathExtension("args"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        let windowIndex = try XCTUnwrap(arguments.firstIndex(of: "--window"))
        XCTAssertEqual(arguments[windowIndex + 1], "0x0x1080x1920",
                       "Particle-only scenes must preserve their portrait canvas at the 1920px maximum edge")
        XCTAssertNotNil(SceneVideoCache.freshCachedVideoURL(assetId: asset.id, sourceURL: sceneURL))
    }

    private func temporaryDirectory() throws -> URL {
        let base = ProcessInfo.processInfo.environment["APP_SCRATCH_DIR"].map { URL(filePath: $0) }
            ?? FileManager.default.temporaryDirectory
        let root = base.appending(path: "wwb-recording-canvas-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func particleScenePackage(in root: URL) throws -> URL {
        let entries = [
            ("scene.json", #"{"general":{"orthogonalprojection":{"width":1080,"height":1920}},"objects":[{"id":1,"name":"Particles","particle":"particles/test.json","origin":"540 960 0"}]}"#),
            ("particles/test.json", #"{"emitter":[{"rate":1}],"renderer":[{"name":"sprite"}]}"#)
        ]
        var data = Data()
        func number(_ value: Int) { var little = UInt32(value).littleEndian; data.append(Data(bytes: &little, count: 4)) }
        func string(_ value: String) { number(value.utf8.count); data.append(contentsOf: value.utf8) }
        string("PKGV0007")
        number(entries.count)
        var offset = 0
        for (path, content) in entries {
            string(path); number(offset); number(content.utf8.count)
            offset += content.utf8.count
        }
        for (_, content) in entries { data.append(contentsOf: content.utf8) }
        let url = root.appending(path: "scene.pkg")
        try data.write(to: url)
        return url
    }
}
