import Foundation
import XCTest
import WorkshopWallpaperCore
@testable import WorkshopWallpaperBridgeApp

final class LibraryRowStatusResolverTests: XCTestCase {
    func testSceneWithoutCachedVideoNeedsFirstRender() throws {
        // Given
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appending(path: "scene.pkg")
        try "scene-package".write(to: sourceURL, atomically: true, encoding: .utf8)
        let asset = Self.sceneAsset(root: root, entrypoint: sourceURL)

        let previousCacheDirectory = SceneVideoCache.overrideCacheDirectoryURL
        SceneVideoCache.overrideCacheDirectoryURL = root.appending(path: "SceneVideoCache")
        defer { SceneVideoCache.overrideCacheDirectoryURL = previousCacheDirectory }

        // When
        let status = LibraryRowStatusResolver.status(for: asset)

        // Then
        XCTAssertEqual(status, .needsFirstRender)
        XCTAssertEqual(status.label, "renders on first play")
        XCTAssertFalse(status.isPositive)
    }

    func testSceneWithFreshCachedVideoIsPlayable() throws {
        // Given
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appending(path: "scene.pkg")
        try "scene-package".write(to: sourceURL, atomically: true, encoding: .utf8)
        let asset = Self.sceneAsset(root: root, entrypoint: sourceURL)

        let cacheDirectory = root.appending(path: "SceneVideoCache")
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let cachedVideoURL = cacheDirectory.appending(path: "\(asset.id).mp4")
        try "fake-cached-video".write(to: cachedVideoURL, atomically: true, encoding: .utf8)

        let previousCacheDirectory = SceneVideoCache.overrideCacheDirectoryURL
        SceneVideoCache.overrideCacheDirectoryURL = cacheDirectory
        defer { SceneVideoCache.overrideCacheDirectoryURL = previousCacheDirectory }

        // When
        let status = LibraryRowStatusResolver.status(for: asset)

        // Then
        XCTAssertEqual(status, .playable)
        XCTAssertEqual(status.label, "playable")
        XCTAssertTrue(status.isPositive)
    }

    func testNonSceneAssetIsUnaffected() throws {
        // Given
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let asset = WallpaperAsset(
            id: root.lastPathComponent,
            title: "Video",
            kind: .video,
            supportStatus: .playable,
            source: .localSteamWorkshop,
            projectDirectory: root.path,
            entrypoint: root.appending(path: "video.mp4").path,
            thumbnail: nil,
            workshopId: nil,
            redistributionAllowed: false,
            issues: []
        )

        // When
        let status = LibraryRowStatusResolver.status(for: asset)

        // Then
        XCTAssertEqual(status, .playable)
        XCTAssertEqual(status.label, "playable")
        XCTAssertTrue(status.isPositive)
    }

    func testNonPlayableAssetKeepsExistingSupportStatusLabel() throws {
        // Given
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let asset = WallpaperAsset(
            id: root.lastPathComponent,
            title: "Legacy Video",
            kind: .video,
            supportStatus: .needsConversion,
            source: .localSteamWorkshop,
            projectDirectory: root.path,
            entrypoint: root.appending(path: "video.avi").path,
            thumbnail: nil,
            workshopId: nil,
            redistributionAllowed: false,
            issues: []
        )

        // When
        let status = LibraryRowStatusResolver.status(for: asset)

        // Then
        XCTAssertEqual(status, .notPlayable(.needsConversion))
        XCTAssertEqual(status.label, "needsConversion")
        XCTAssertFalse(status.isPositive)
    }

    private static func makeTempDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "wwb-libraryrow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func sceneAsset(root: URL, entrypoint: URL) -> WallpaperAsset {
        WallpaperAsset(
            id: root.lastPathComponent,
            title: "Scene",
            kind: .scene,
            supportStatus: .playable,
            source: .localSteamWorkshop,
            projectDirectory: root.path,
            entrypoint: entrypoint.path,
            thumbnail: nil,
            workshopId: nil,
            redistributionAllowed: false,
            issues: []
        )
    }
}
