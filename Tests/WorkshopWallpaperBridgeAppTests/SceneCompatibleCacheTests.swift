import Foundation
import XCTest
@testable import WorkshopWallpaperBridgeApp

final class SceneCompatibleCacheTests: XCTestCase {
    func testRendererCapabilityProbeIsBoundedAndDrainsOutput() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "wwb-help-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appending(path: "renderer")
        try "#!/bin/sh\nexec /bin/sleep 20\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let start = Date()
        XCTAssertEqual(SceneVideoRenderer.readRendererHelp(script, timeout: 0.1), "")
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        try "#!/bin/sh\nprintf '%s\\n' '--record-raw'\n".write(to: script, atomically: true, encoding: .utf8)
        XCTAssertTrue(SceneVideoRenderer.readRendererHelp(script).contains("--record-raw"))
    }

    func testOnlyFreshVisuallyCompatiblePreviousCacheIsReused() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "wwb-cache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let old = SceneVideoCache.overrideCacheDirectoryURL
        SceneVideoCache.overrideCacheDirectoryURL = root.appending(path: "v7")
        defer { SceneVideoCache.overrideCacheDirectoryURL = old }
        for version in [5, 6, 7] {
            try FileManager.default.createDirectory(at: root.appending(path: "v\(version)"), withIntermediateDirectories: true)
        }
        let source = root.appending(path: "scene.pkg")
        try Data([1]).write(to: source)
        try Data([2]).write(to: root.appending(path: "v5/scene.mp4"))
        XCTAssertNil(SceneVideoCache.previousCompatibleCachedVideoURL(assetId: "scene", sourceURL: source))
        let compatible = root.appending(path: "v6/scene.mp4")
        try Data([3]).write(to: compatible)
        XCTAssertEqual(SceneVideoCache.previousCompatibleCachedVideoURL(assetId: "scene", sourceURL: source), compatible)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: source.path)
        XCTAssertNil(SceneVideoCache.previousCompatibleCachedVideoURL(assetId: "scene", sourceURL: source))
        SceneVideoCache.overrideCacheDirectoryURL = root.appending(path: "v8")
        XCTAssertNil(SceneVideoCache.previousCompatibleCachedVideoURL(assetId: "scene", sourceURL: source))
    }
}
