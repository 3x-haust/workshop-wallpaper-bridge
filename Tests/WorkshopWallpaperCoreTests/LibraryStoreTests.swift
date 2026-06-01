import Foundation
import XCTest
@testable import WorkshopWallpaperCore

final class LibraryStoreTests: XCTestCase {
    func testImportCopiesProjectIntoLibraryAndPersistsManifest() throws {
        // Given
        let sourceRoot = try Fixture.makeTempDirectory()
        try Fixture.project(
            root: sourceRoot,
            id: "777",
            metadata: #"{"title":"Neon","file":"neon.mp4"}"#,
            file: "neon.mp4"
        )
        let asset = try XCTUnwrap(WallpaperScanner().scan(root: sourceRoot).assets.first)
        let store = LibraryStore(root: try Fixture.makeTempDirectory())

        // When
        let imported = try store.importAsset(asset)
        let manifest = try store.load()

        // Then
        XCTAssertEqual(manifest.assets.map(\.id), ["777"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.projectDirectory))
        let importedVideoPath = URL(filePath: imported.projectDirectory).appending(path: "neon.mp4").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: importedVideoPath))
        XCTAssertEqual(imported.redistributionAllowed, false)
    }

    func testImportKeepsDistinctStorageForIdsThatNormalizeSimilarly() throws {
        // Given
        let sourceRoot = try Fixture.makeTempDirectory()
        try Fixture.project(
            root: sourceRoot,
            id: "a b",
            metadata: #"{"title":"Space","file":"space.mp4"}"#,
            file: "space.mp4"
        )
        try Fixture.project(
            root: sourceRoot,
            id: "a_b",
            metadata: #"{"title":"Underscore","file":"under.mp4"}"#,
            file: "under.mp4"
        )
        let assets = try WallpaperScanner().scan(root: sourceRoot).assets
        let store = LibraryStore(root: try Fixture.makeTempDirectory())

        // When
        let imported = try assets.map { try store.importAsset($0) }
        let manifest = try store.load()

        // Then
        XCTAssertEqual(manifest.assets.map(\.id), ["a b", "a_b"])
        XCTAssertEqual(Set(imported.map(\.projectDirectory)).count, 2)
        XCTAssertTrue(imported.allSatisfy { FileManager.default.fileExists(atPath: $0.projectDirectory) })
    }

    func testImportVideoFileCopiesOnlySelectedVideoIntoLibrary() throws {
        // Given
        let sourceRoot = try Fixture.makeTempDirectory()
        let video = sourceRoot.appending(path: "My Loop.mp4")
        let unrelated = sourceRoot.appending(path: "ignore.txt")
        FileManager.default.createFile(atPath: video.path, contents: Data([1, 2, 3]))
        FileManager.default.createFile(atPath: unrelated.path, contents: Data([4, 5, 6]))
        let store = LibraryStore(root: try Fixture.makeTempDirectory())

        // When
        let imported = try store.importVideoFile(video)
        let manifest = try store.load()

        // Then
        XCTAssertEqual(manifest.assets, [imported])
        XCTAssertEqual(imported.title, "My Loop")
        XCTAssertEqual(imported.kind, .video)
        XCTAssertEqual(imported.supportStatus, .playable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(imported.entrypoint)))
        let copiedIgnorePath = URL(filePath: imported.projectDirectory).appending(path: "ignore.txt").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: copiedIgnorePath))
    }

    func testImportVideoFileRejectsUnsupportedFileType() throws {
        // Given
        let sourceRoot = try Fixture.makeTempDirectory()
        let text = sourceRoot.appending(path: "notes.txt")
        FileManager.default.createFile(atPath: text.path, contents: Data([1]))
        let store = LibraryStore(root: try Fixture.makeTempDirectory())

        // When / Then
        XCTAssertThrowsError(try store.importVideoFile(text))
    }

    func testImportVideoFileMarksConvertibleFormats() throws {
        // Given
        let sourceRoot = try Fixture.makeTempDirectory()
        let video = sourceRoot.appending(path: "loop.webm")
        FileManager.default.createFile(atPath: video.path, contents: Data([1]))
        let store = LibraryStore(root: try Fixture.makeTempDirectory())

        // When
        let imported = try store.importVideoFile(video)

        // Then
        XCTAssertEqual(imported.supportStatus, .needsConversion)
    }

    func testRemoveAssetDeletesLibraryDirectoryAndManifestEntry() throws {
        // Given
        let sourceRoot = try Fixture.makeTempDirectory()
        let video = sourceRoot.appending(path: "remove-me.mp4")
        FileManager.default.createFile(atPath: video.path, contents: Data([1]))
        let store = LibraryStore(root: try Fixture.makeTempDirectory())
        let imported = try store.importVideoFile(video)

        // When
        try store.removeAsset(id: imported.id)
        let manifest = try store.load()

        // Then
        XCTAssertTrue(manifest.assets.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.projectDirectory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.path))
    }

    func testRemoveMissingAssetIsNoOp() throws {
        // Given
        let sourceRoot = try Fixture.makeTempDirectory()
        let video = sourceRoot.appending(path: "keep-me.mp4")
        FileManager.default.createFile(atPath: video.path, contents: Data([1]))
        let store = LibraryStore(root: try Fixture.makeTempDirectory())
        let imported = try store.importVideoFile(video)

        // When
        try store.removeAsset(id: "missing")
        let manifest = try store.load()

        // Then
        XCTAssertEqual(manifest.assets, [imported])
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.projectDirectory))
    }

    func testRemoveAssetDoesNotDeleteOutsideAssetsRoot() throws {
        // Given
        let store = LibraryStore(root: try Fixture.makeTempDirectory())
        let outside = try Fixture.makeTempDirectory()
        let outsideFile = outside.appending(path: "original.mp4")
        FileManager.default.createFile(atPath: outsideFile.path, contents: Data([1]))
        let asset = WallpaperAsset(
            id: "outside",
            title: "Outside",
            kind: .video,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: outside.path,
            entrypoint: outsideFile.path,
            thumbnail: nil,
            workshopId: nil,
            redistributionAllowed: false,
            issues: []
        )
        try store.replaceAsset(asset)

        // When
        try store.removeAsset(id: asset.id)
        let manifest = try store.load()

        // Then
        XCTAssertTrue(manifest.assets.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideFile.path))
    }

    func testLoadRepairsLegacyPreviewImageManifestForSceneProject() throws {
        // Given
        let store = LibraryStore(root: try Fixture.makeTempDirectory())
        let project = try makeImportedProjectDirectory(in: store.root, id: "legacy-scene")
        let preview = project.appending(path: "preview.jpg")
        let scenePackage = project.appending(path: "scene.pkg")
        try #"{"title":"Scene","file":"scene.json","preview":"preview.jpg","type":"scene"}"#
            .write(to: project.appending(path: "project.json"), atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: preview.path, contents: Data([1]))
        FileManager.default.createFile(atPath: scenePackage.path, contents: Data([2]))
        let legacy = WallpaperAsset(
            id: "legacy-scene",
            title: "Scene",
            kind: .image,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: project.path,
            entrypoint: preview.path,
            thumbnail: preview.path,
            workshopId: "legacy-scene",
            redistributionAllowed: false,
            issues: []
        )
        try store.replaceAsset(legacy)

        // When
        let repaired = try XCTUnwrap(store.load().assets.first)

        // Then
        XCTAssertEqual(repaired.id, legacy.id)
        XCTAssertEqual(repaired.kind, .scene)
        XCTAssertEqual(repaired.supportStatus, .unsupported)
        XCTAssertEqual(standardPath(repaired.entrypoint), standardPath(scenePackage.path))
        XCTAssertEqual(repaired.thumbnail, preview.path)
        XCTAssertTrue(repaired.issues.contains { $0.code == "proprietary_scene_package" })
    }

    func testLoadRepairsLegacyPreviewImageManifestForVideoProject() throws {
        // Given
        let store = LibraryStore(root: try Fixture.makeTempDirectory())
        let project = try makeImportedProjectDirectory(in: store.root, id: "legacy-video")
        let preview = project.appending(path: "preview.jpg")
        let video = project.appending(path: "wallpaper.mp4")
        try #"{"title":"Video","file":"wallpaper.mp4","preview":"preview.jpg","type":"video"}"#
            .write(to: project.appending(path: "project.json"), atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: preview.path, contents: Data([1]))
        FileManager.default.createFile(atPath: video.path, contents: Data([2]))
        let legacy = WallpaperAsset(
            id: "legacy-video",
            title: "Video",
            kind: .image,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: project.path,
            entrypoint: preview.path,
            thumbnail: preview.path,
            workshopId: "legacy-video",
            redistributionAllowed: false,
            issues: []
        )
        try store.replaceAsset(legacy)

        // When
        let repaired = try XCTUnwrap(store.load().assets.first)

        // Then
        XCTAssertEqual(repaired.id, legacy.id)
        XCTAssertEqual(repaired.kind, .video)
        XCTAssertEqual(repaired.supportStatus, .playable)
        XCTAssertEqual(repaired.entrypoint, video.path)
        XCTAssertEqual(repaired.thumbnail, preview.path)
    }

    private func makeImportedProjectDirectory(in root: URL, id: String) throws -> URL {
        let project = root.appending(path: "Assets").appending(path: id)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return project
    }

    private func standardPath(_ path: String?) -> String? {
        path.map { URL(filePath: $0).standardizedFileURL.resolvingSymlinksInPath().path }
    }
}
