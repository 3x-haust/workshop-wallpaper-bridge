import AppKit
import XCTest
import WorkshopWallpaperCore
@testable import WorkshopWallpaperBridgeApp

@MainActor
final class WorkshopScenePreparationTests: XCTestCase {
    func testPreparationRejectsThumbnailWithoutRenderer() async throws {
        let fixture = try PreparationFixture()
        defer { fixture.cleanUp() }
        do {
            try await SceneWallpaperContentFactory.prepare(asset: fixture.asset, frame: frame) { _ in }
            XCTFail("An interim thumbnail must not count as a prepared Workshop scene")
        } catch {
            guard case .unavailable = error as? ScenePreparationError else {
                return XCTFail("Expected a missing renderer error, got \(error)")
            }
        }
    }

    func testFreshCacheDoesNotRequireRenderingToolsOrRenderAgain() async throws {
        let fixture = try PreparationFixture()
        defer { fixture.cleanUp() }
        try Data([1]).write(to: SceneVideoCache.cachedVideoURL(assetId: fixture.asset.id))
        SceneWallpaperContentFactory.renderingTools = { XCTFail("Fresh cache must not resolve tools"); throw ScenePreparationError.incomplete }
        var progress: [Double] = []
        try await SceneWallpaperContentFactory.prepare(asset: fixture.asset, frame: frame) { progress.append($0) }
        XCTAssertEqual(progress, [0, 1])
    }

    func testNativeLiveSceneDoesNotRender() async throws {
        let fixture = try PreparationFixture(sceneJSON: #"{"objects":[{"id":1,"text":{"value":"Clock","script":"export function update(v) { return v; }"}}]}"#)
        defer { fixture.cleanUp() }
        XCTAssertTrue(try SceneRenderPlanBuilder().build(url: fixture.scene).canPreferLivePlayback)
        SceneWallpaperContentFactory.renderingTools = { XCTFail("Native live scene must not resolve tools"); throw ScenePreparationError.incomplete }
        var progress: [Double] = []
        try await SceneWallpaperContentFactory.prepare(asset: fixture.asset, frame: frame) { progress.append($0) }
        XCTAssertEqual(progress, [0, 1])
        XCTAssertFalse(SceneWallpaperContentFactory.isRendering(assetID: fixture.asset.id))
    }

    func testRenderWaitsForCommittedCacheAndUsesClampedLogicalSize() async throws {
        let fixture = try PreparationFixture()
        defer { fixture.cleanUp() }
        fixture.installTools()
        let started = expectation(description: "Render started")
        var release: CheckedContinuation<Void, Never>?
        var configuration: SceneVideoRenderConfiguration?
        SceneWallpaperContentFactory.renderVideo = { config, _, progress in
            configuration = config
            progress(0.5)
            await withCheckedContinuation { release = $0; started.fulfill() }
            progress(1)
            let output = SceneVideoCache.cachedVideoURL(assetId: config.assetId)
            try Data([1]).write(to: output)
            return output
        }
        var completed = false
        var progress: [Double] = []
        let task = Task {
            try await SceneWallpaperContentFactory.prepare(asset: fixture.asset, frame: frame) { progress.append($0) }
            completed = true
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertFalse(completed, "The thumbnail and recording progress are not readiness")
        XCTAssertFalse(progress.contains(1))
        XCTAssertEqual(configuration?.size, CGSize(width: 1920, height: 1080))
        XCTAssertEqual(configuration?.excludedObjectIDs, [])
        release?.resume()
        try await task.value
        XCTAssertTrue(completed)
        XCTAssertEqual(progress.last, 1)
        XCTAssertTrue(progress.contains(0.475))
        XCTAssertFalse(SceneWallpaperContentFactory.isRendering(assetID: fixture.asset.id))
        SceneWallpaperContentFactory.renderVideo = { _, _, _ in XCTFail("Reapplying must reuse the fresh cache"); throw ScenePreparationError.incomplete }
        try await SceneWallpaperContentFactory.prepare(asset: fixture.asset, frame: frame) { _ in }
    }

    func testMediaPreparationUsesExcludedBackdropCacheAndAuthoredCanvas() async throws {
        let fixture = try PreparationFixture(sceneJSON: #"{"general":{"bloom":true,"orthogonalprojection":{"width":800,"height":600}},"objects":[{"id":7,"text":{"value":"Track","script":"export function mediaPropertiesChanged(event) {}"},"origin":"400 300 0","size":"200 80"}]}"#)
        defer { fixture.cleanUp() }
        fixture.installTools()
        let media = try XCTUnwrap(SceneMediaOverlayPlan.build(url: fixture.scene))
        try Data([1]).write(to: SceneVideoCache.cachedVideoURL(assetId: fixture.asset.id))
        var configurations: [SceneVideoRenderConfiguration] = []
        SceneWallpaperContentFactory.renderVideo = { config, _, _ in
            configurations.append(config)
            let output = SceneVideoCache.cachedVideoURL(assetId: config.assetId)
            try Data([1]).write(to: output)
            return output
        }
        try await SceneWallpaperContentFactory.prepare(asset: fixture.asset, frame: frame) { _ in }
        XCTAssertEqual(configurations.count, 1, "Whole-scene cache cannot substitute for an excluded backdrop")
        XCTAssertEqual(configurations.first?.assetId, fixture.asset.id + media.cacheSuffix)
        XCTAssertEqual(configurations.first?.excludedObjectIDs, [7])
        XCTAssertEqual(configurations.first?.size, CGSize(width: 800, height: 600))
        try await SceneWallpaperContentFactory.prepare(asset: fixture.asset, frame: frame) { _ in }
        XCTAssertEqual(configurations.count, 1)
    }

    func testRendererFailureAndMissingOutputAreNotSuccess() async throws {
        let fixture = try PreparationFixture()
        defer { fixture.cleanUp() }
        fixture.installTools()
        SceneWallpaperContentFactory.renderVideo = { _, _, _ in throw SceneVideoRenderError.noFramesRecorded }
        do {
            try await SceneWallpaperContentFactory.prepare(asset: fixture.asset, frame: frame) { _ in }
            XCTFail("Renderer failure must reach the caller")
        } catch { XCTAssertEqual(error as? SceneVideoRenderError, .noFramesRecorded) }
        SceneWallpaperContentFactory.renderVideo = { _, _, _ in fixture.root.appending(path: "absent.mp4") }
        do {
            try await SceneWallpaperContentFactory.prepare(asset: fixture.asset, frame: frame) { _ in }
            XCTFail("A renderer return without a fresh cache is not success")
        } catch { XCTAssertEqual(error as? ScenePreparationError, .incomplete) }
    }

    func testCancelledWaiterDoesNotReleaseWriterOrCancelAnotherWaiter() async throws {
        let fixture = try PreparationFixture()
        defer { fixture.cleanUp() }
        fixture.installTools()
        let started = expectation(description: "Shared render started")
        let joined = expectation(description: "Second preparation joined")
        joined.assertForOverFulfill = false
        var release: CheckedContinuation<Void, Never>?
        var renders = 0
        SceneWallpaperContentFactory.renderVideo = { config, _, _ in
            renders += 1
            await withCheckedContinuation { release = $0; started.fulfill() }
            let output = SceneVideoCache.cachedVideoURL(assetId: config.assetId)
            try Data([1]).write(to: output)
            return output
        }
        let first = Task { try await SceneWallpaperContentFactory.prepare(asset: fixture.asset, frame: frame) { _ in } }
        await fulfillment(of: [started], timeout: 2)
        first.cancel()
        do { try await first.value; XCTFail("Cancellation must return before the external renderer exits") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(SceneWallpaperContentFactory.isRendering(assetID: fixture.asset.id))
        let second = Task { try await SceneWallpaperContentFactory.prepare(asset: fixture.asset, frame: frame) { _ in joined.fulfill() } }
        await fulfillment(of: [joined], timeout: 2)
        XCTAssertEqual(renders, 1)
        release?.resume()
        try await second.value
        XCTAssertEqual(renders, 1)
        XCTAssertFalse(SceneWallpaperContentFactory.isRendering(assetID: fixture.asset.id))
    }

    func testPreparationJoinsScheduledRenderWithoutSuppressingExistingDisplayRefresh() async throws {
        try await checkScheduledRenderRefresh(cancelPreparation: false)
    }

    func testCancellingWorkshopPreparationPreservesExistingDisplayBackgroundRefresh() async throws {
        try await checkScheduledRenderRefresh(cancelPreparation: true)
    }

    private func checkScheduledRenderRefresh(cancelPreparation: Bool) async throws {
        let fixture = try PreparationFixture()
        defer { fixture.cleanUp() }
        fixture.installTools()
        let started = expectation(description: "Background render started")
        let joined = expectation(description: "Preparation joined")
        joined.assertForOverFulfill = false
        let refreshed = expectation(description: "Existing background render can refresh its displays")
        var release: CheckedContinuation<Void, Never>?
        var renders = 0
        var refreshes = 0
        let oldHandler = SceneWallpaperContentFactory.sceneVideoRenderCompletionHandler
        SceneWallpaperContentFactory.sceneVideoRenderCompletionHandler = { _ in
            refreshes += 1
            refreshed.fulfill()
        }
        defer { SceneWallpaperContentFactory.sceneVideoRenderCompletionHandler = oldHandler }
        SceneWallpaperContentFactory.renderVideo = { config, _, _ in
            renders += 1
            await withCheckedContinuation { release = $0; started.fulfill() }
            let output = SceneVideoCache.cachedVideoURL(assetId: config.assetId)
            try Data([1]).write(to: output)
            return output
        }
        let interim = try SceneWallpaperContentFactory.makeSceneContentView(asset: fixture.asset, url: fixture.scene,
            previewURL: fixture.preview, frame: frame, displayMode: .fit)
        defer { (interim as? WallpaperContentLifecycle)?.prepareForClose() }
        await fulfillment(of: [started], timeout: 2)
        let preparation = Task { try await SceneWallpaperContentFactory.prepare(asset: fixture.asset, frame: frame) { _ in joined.fulfill() } }
        await fulfillment(of: [joined], timeout: 2)
        XCTAssertEqual(renders, 1)
        if cancelPreparation {
            SceneWallpaperContentFactory.cancelWorkshopPreparations()
            do { try await preparation.value; XCTFail("The Workshop waiter must be cancelled") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        release?.resume()
        if !cancelPreparation { try await preparation.value }
        await fulfillment(of: [refreshed], timeout: 2)
        XCTAssertEqual(refreshes, 1)
    }

    func testAppPreparationDoesNotApplyAndRejectsSupersededIntent() async throws {
        let fixture = try PreparationFixture()
        defer { fixture.cleanUp() }
        let suite = "wwb-preparation-defaults-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let started = expectation(description: "Preparation started")
        var release: CheckedContinuation<Void, Never>?
        let player = PreparationPlayer()
        let model = AppViewModel(store: LibraryStore(root: fixture.root.appending(path: "library")),
            loginItemController: PreparationLoginItem(), wallpaperPlayer: player, userDefaults: defaults,
            scenePreparer: { _, progress in
                progress(0.25)
                await withCheckedContinuation { release = $0; started.fulfill() }
                progress(1)
            })
        let intent = model.beginApplicationIntent()
        var progress: [Double] = []
        let preparation = Task {
            try await model.prepareWorkshopAsset(fixture.asset, intent: intent) { progress.append($0) }
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(player.played, [])
        XCTAssertTrue(model.isPreparingWorkshopAsset(fixture.asset.id))
        model.beginApplicationIntent()
        release?.resume()
        do { try await preparation.value; XCTFail("A superseded preparation cannot report success") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(player.played, [])
        XCTAssertEqual(progress, [0.25])
        XCTAssertFalse(model.isPreparingWorkshopAsset(fixture.asset.id))
    }

    func testNewIntentCancelsWaitingPreparationButRetainsWriterUntilExit() async throws {
        let fixture = try PreparationFixture()
        defer { fixture.cleanUp() }
        fixture.installTools()
        let started = expectation(description: "Render started")
        let finished = expectation(description: "Render finished")
        var release: CheckedContinuation<Void, Never>?
        SceneWallpaperContentFactory.renderVideo = { config, _, _ in
            await withCheckedContinuation { release = $0; started.fulfill() }
            let output = SceneVideoCache.cachedVideoURL(assetId: config.assetId)
            try Data([1]).write(to: output)
            finished.fulfill()
            return output
        }
        let preparation = Task { try await SceneWallpaperContentFactory.prepare(asset: fixture.asset, frame: frame) { _ in } }
        await fulfillment(of: [started], timeout: 2)
        SceneWallpaperContentFactory.cancelWorkshopPreparations()
        do { try await preparation.value; XCTFail("New intent must cancel the old waiter") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(SceneWallpaperContentFactory.isRendering(assetID: fixture.asset.id))
        release?.resume()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertFalse(SceneWallpaperContentFactory.isRendering(assetID: fixture.asset.id))
    }

    private var frame: CGRect { CGRect(x: 0, y: 0, width: 2560, height: 1440) }
}

@MainActor
private struct PreparationLoginItem: LoginItemManaging {
    var isEnabled: Bool { false }
    func setEnabled(_ enabled: Bool) throws {}
    func openSystemSettings() {}
}

@MainActor
private final class PreparationPlayer: WallpaperPlaying {
    var played: [String] = []
    func play(asset: WallpaperAsset, autoPauseWhenCovered: Bool, displayMode: WallpaperDisplayMode,
              audioEnabled: Bool?, audioVolume: Double?) throws { played.append(asset.id) }
    func stop() {}
    func setDisplayMode(_ mode: WallpaperDisplayMode) {}
    func setAutoPauseWhenCovered(_ enabled: Bool) {}
}

@MainActor
private final class PreparationFixture {
    let root: URL
    let scene: URL
    let preview: URL
    let asset: WallpaperAsset
    private let oldCache = SceneVideoCache.overrideCacheDirectoryURL
    private let oldRenderer = SceneEngineRendererConfiguration.overrideExecutablePath
    private let oldResource = SceneEngineRendererConfiguration.overrideResourceURL
    private let oldAssets = SceneEngineRendererConfiguration.overrideAssetsPath
    private let oldDefaultAssets = SceneEngineRendererConfiguration.overrideDefaultAssetsDirectoryURL
    private let oldLive = SceneWallpaperContentFactory.prefersLivePlayback
    private let oldTools = SceneWallpaperContentFactory.renderingTools
    private let oldRender = SceneWallpaperContentFactory.renderVideo

    init(sceneJSON: String = #"{"objects":[{"id":1,"model":"models/cube.json"}]}"#) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "wwb-preparation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        scene = root.appending(path: "scene.pkg")
        preview = root.appending(path: "preview.png")
        var bytes = Data()
        func number(_ value: Int) { var n = UInt32(value).littleEndian; bytes.append(Data(bytes: &n, count: 4)) }
        func string(_ value: String) { number(value.utf8.count); bytes.append(contentsOf: value.utf8) }
        string("PKGV0007"); number(1); string("scene.json"); number(0); number(sceneJSON.utf8.count)
        bytes.append(contentsOf: sceneJSON.utf8)
        try bytes.write(to: scene)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: preview)
        asset = WallpaperAsset(id: "prepared-scene", title: "Scene", kind: .scene, supportStatus: .playable,
            source: .manualFolder, projectDirectory: root.path, entrypoint: scene.path, thumbnail: preview.path,
            workshopId: nil, redistributionAllowed: false, issues: [])
        SceneVideoCache.overrideCacheDirectoryURL = root
        SceneEngineRendererConfiguration.overrideExecutablePath = root.appending(path: "missing-renderer").path
        SceneEngineRendererConfiguration.overrideResourceURL = root
        SceneEngineRendererConfiguration.overrideAssetsPath = root.appending(path: "missing-assets").path
        SceneEngineRendererConfiguration.overrideDefaultAssetsDirectoryURL = root
        SceneWallpaperContentFactory.prefersLivePlayback = true
    }

    func installTools() {
        SceneWallpaperContentFactory.renderingTools = { [root] in
            (root.appending(path: "renderer"), root.appending(path: "assets"), root.appending(path: "ffmpeg").path)
        }
    }

    func cleanUp() {
        SceneWallpaperContentFactory.renderingTools = oldTools
        SceneWallpaperContentFactory.renderVideo = oldRender
        SceneVideoCache.overrideCacheDirectoryURL = oldCache
        SceneEngineRendererConfiguration.overrideExecutablePath = oldRenderer
        SceneEngineRendererConfiguration.overrideResourceURL = oldResource
        SceneEngineRendererConfiguration.overrideAssetsPath = oldAssets
        SceneEngineRendererConfiguration.overrideDefaultAssetsDirectoryURL = oldDefaultAssets
        SceneWallpaperContentFactory.prefersLivePlayback = oldLive
        try? FileManager.default.removeItem(at: root)
    }
}
