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

    func testInstallSceneRenderCacheCopiesVideoInsideImportedSceneDirectory() throws {
        // Given
        let store = LibraryStore(root: try Fixture.makeTempDirectory())
        let project = try makeImportedProjectDirectory(in: store.root, id: "scene-cache")
        let scenePackage = project.appending(path: "scene.pkg")
        try Fixture.writeScenePackage(
            to: scenePackage,
            sceneJSON: #"{"objects":[{"text":{"value":"HELLO"},"size":"320 120"}]}"#
        )
        let asset = WallpaperAsset(
            id: "scene-cache",
            title: "Scene Cache",
            kind: .scene,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: project.path,
            entrypoint: scenePackage.path,
            thumbnail: nil,
            workshopId: "scene-cache",
            redistributionAllowed: false,
            issues: []
        )
        try store.replaceAsset(asset)
        let sourceVideo = try Fixture.makeTempDirectory().appending(path: "windows-reference.mp4")
        FileManager.default.createFile(atPath: sourceVideo.path, contents: Data([1, 2, 3]))

        // When
        let updated = try store.installSceneRenderCache(assetID: asset.id, videoURL: sourceVideo)

        // Then
        let cacheURL = SceneRenderCache.videoURL(in: project)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))
        XCTAssertEqual(try Data(contentsOf: cacheURL), Data([1, 2, 3]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceVideo.path))
        XCTAssertEqual(updated.supportStatus, .playable)
        XCTAssertTrue(updated.issues.contains { $0.code == SceneRenderCache.issueCode })
        XCTAssertEqual(SceneRenderCache.existingVideoURL(in: project)?.path, cacheURL.path)
    }

    func testInstallSceneRenderCacheReplacesStaleCacheCandidates() throws {
        // Given
        let store = LibraryStore(root: try Fixture.makeTempDirectory())
        let project = try makeImportedProjectDirectory(in: store.root, id: "scene-cache-replace")
        let scenePackage = project.appending(path: "scene.pkg")
        try Fixture.writeScenePackage(
            to: scenePackage,
            sceneJSON: #"{"objects":[{"text":{"value":"HELLO"},"size":"320 120"}]}"#
        )
        let asset = WallpaperAsset(
            id: "scene-cache-replace",
            title: "Scene Cache Replace",
            kind: .scene,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: project.path,
            entrypoint: scenePackage.path,
            thumbnail: nil,
            workshopId: "scene-cache-replace",
            redistributionAllowed: false,
            issues: []
        )
        try store.replaceAsset(asset)
        let cacheDirectory = SceneRenderCache.cacheDirectory(in: project)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let stalePreferred = SceneRenderCache.videoURL(in: project, fileExtension: "mp4")
        let staleLegacy = project.appending(path: "render-cache.mov")
        let staleRendered = project.appending(path: "rendered.mp4")
        FileManager.default.createFile(atPath: stalePreferred.path, contents: Data([0]))
        FileManager.default.createFile(atPath: staleLegacy.path, contents: Data([1]))
        FileManager.default.createFile(atPath: staleRendered.path, contents: Data([2]))
        let sourceVideo = try Fixture.makeTempDirectory().appending(path: "windows-reference.mov")
        FileManager.default.createFile(atPath: sourceVideo.path, contents: Data([3, 4, 5]))

        // When
        _ = try store.installSceneRenderCache(assetID: asset.id, videoURL: sourceVideo)

        // Then
        let cacheURL = SceneRenderCache.videoURL(in: project, fileExtension: "mov")
        XCTAssertEqual(try Data(contentsOf: cacheURL), Data([3, 4, 5]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stalePreferred.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleLegacy.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleRendered.path))
        XCTAssertEqual(SceneRenderCache.existingVideoURL(in: project)?.path, cacheURL.path)
    }

    func testInstallSceneRenderCacheRejectsNonSceneAsset() throws {
        // Given
        let sourceRoot = try Fixture.makeTempDirectory()
        let video = sourceRoot.appending(path: "loop.mp4")
        FileManager.default.createFile(atPath: video.path, contents: Data([1]))
        let store = LibraryStore(root: try Fixture.makeTempDirectory())
        let imported = try store.importVideoFile(video)

        // When / Then
        XCTAssertThrowsError(try store.installSceneRenderCache(assetID: imported.id, videoURL: video)) { error in
            XCTAssertEqual(error as? LibraryStoreError, .assetIsNotScene(imported.id))
        }
    }

    func testInstallSceneRenderCacheRejectsSymlinkedCacheDirectory() throws {
        // Given
        let store = LibraryStore(root: try Fixture.makeTempDirectory())
        let project = try makeImportedProjectDirectory(in: store.root, id: "scene-cache-symlink-dir")
        let scenePackage = project.appending(path: "scene.pkg")
        try Fixture.writeScenePackage(
            to: scenePackage,
            sceneJSON: #"{"objects":[{"text":{"value":"HELLO"},"size":"320 120"}]}"#
        )
        let asset = WallpaperAsset(
            id: "scene-cache-symlink-dir",
            title: "Scene Cache Symlink Dir",
            kind: .scene,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: project.path,
            entrypoint: scenePackage.path,
            thumbnail: nil,
            workshopId: "scene-cache-symlink-dir",
            redistributionAllowed: false,
            issues: []
        )
        try store.replaceAsset(asset)
        let outsideDirectory = try Fixture.makeTempDirectory()
        try FileManager.default.createSymbolicLink(
            at: SceneRenderCache.cacheDirectory(in: project),
            withDestinationURL: outsideDirectory
        )
        let sourceVideo = try Fixture.makeTempDirectory().appending(path: "windows-reference.mp4")
        FileManager.default.createFile(atPath: sourceVideo.path, contents: Data([1]))

        // When / Then
        XCTAssertThrowsError(try store.installSceneRenderCache(assetID: asset.id, videoURL: sourceVideo)) { error in
            XCTAssertEqual(error as? LibraryStoreError, .unsafeSceneRenderCacheDirectory(asset.id))
        }
    }

    func testSceneRenderCacheKeepsUnsupportedScenePlayableAfterLoadRepair() throws {
        // Given
        let store = LibraryStore(root: try Fixture.makeTempDirectory())
        let project = try makeImportedProjectDirectory(in: store.root, id: "scene-cache-unsupported")
        let scenePackage = project.appending(path: "scene.pkg")
        try Fixture.writeScenePackage(
            to: scenePackage,
            sceneJSON: #"{"objects":[{"image":"models/background.json"}]}"#,
            extraEntries: [
                (path: "models/background.json", data: Data(#"{"material":"materials/background.json"}"#.utf8)),
                (path: "materials/background.json", data: Data(#"{"passes":[{"textures":["background"]}]}"#.utf8)),
                (path: "materials/background.tex", data: Data([1, 2, 3]))
            ]
        )
        let asset = WallpaperAsset(
            id: "scene-cache-unsupported",
            title: "Scene Cache Unsupported",
            kind: .scene,
            supportStatus: .unsupported,
            source: .manualFolder,
            projectDirectory: project.path,
            entrypoint: scenePackage.path,
            thumbnail: nil,
            workshopId: "scene-cache-unsupported",
            redistributionAllowed: false,
            issues: []
        )
        try store.replaceAsset(asset)
        let sourceVideo = try Fixture.makeTempDirectory().appending(path: "windows-reference.mp4")
        FileManager.default.createFile(atPath: sourceVideo.path, contents: Data([1, 2, 3]))

        // When
        _ = try store.installSceneRenderCache(assetID: asset.id, videoURL: sourceVideo)
        let repaired = try XCTUnwrap(store.load().assets.first)

        // Then
        XCTAssertEqual(repaired.supportStatus, .playable)
        XCTAssertEqual(repaired.redistributionAllowed, false)
        XCTAssertTrue(repaired.issues.contains { $0.code == SceneRenderCache.issueCode })
        XCTAssertTrue(repaired.issues.contains { $0.code == "scene_renderer_limited" })
    }

    func testSceneRenderCacheRejectsSymlinkedVideoCache() throws {
        // Given
        let project = try Fixture.makeTempDirectory()
        let cacheDirectory = SceneRenderCache.cacheDirectory(in: project)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let outsideVideo = try Fixture.makeTempDirectory().appending(path: "outside.mp4")
        FileManager.default.createFile(atPath: outsideVideo.path, contents: Data([1]))
        let symlink = SceneRenderCache.videoURL(in: project)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outsideVideo)

        // Then
        XCTAssertNil(SceneRenderCache.existingVideoURL(in: project))
    }

    func testSceneRenderCacheRejectsVideoThroughSymlinkedCacheDirectory() throws {
        // Given
        let project = try Fixture.makeTempDirectory()
        let outsideDirectory = try Fixture.makeTempDirectory()
        let outsideVideo = SceneRenderCache.videoURL(in: outsideDirectory)
        FileManager.default.createFile(atPath: outsideVideo.path, contents: Data([1]))
        try FileManager.default.createSymbolicLink(
            at: SceneRenderCache.cacheDirectory(in: project),
            withDestinationURL: outsideDirectory
        )

        // Then
        XCTAssertNil(SceneRenderCache.existingVideoURL(in: project))
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
        try Fixture.writeScenePackage(
            to: scenePackage,
            sceneJSON: #"{"objects":[{"image":"models/background.json"}]}"#
        )
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
        XCTAssertTrue(repaired.issues.contains { $0.code == "scene_package_detected" })
        XCTAssertTrue(repaired.issues.contains { $0.code == "scene_renderer_limited" })
    }

    func testLoadRefreshesImportedSceneDiagnostics() throws {
        // Given
        let store = LibraryStore(root: try Fixture.makeTempDirectory())
        let project = try makeImportedProjectDirectory(in: store.root, id: "scene-diagnostics")
        let scenePackage = project.appending(path: "scene.pkg")
        try Fixture.writeScenePackage(
            to: scenePackage,
            sceneJSON: """
            {
              "objects": [
                {"text": {"value": "12:34"}},
                {"image": "models/foam.json", "effects": [{"file": "effects/waterflow/effect.json"}]}
              ]
            }
            """
        )
        let stale = WallpaperAsset(
            id: "scene-diagnostics",
            title: "Scene Diagnostics",
            kind: .scene,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: project.path,
            entrypoint: scenePackage.path,
            thumbnail: nil,
            workshopId: "scene-diagnostics",
            redistributionAllowed: false,
            issues: [
                ScanIssue(code: "scene_package_detected", message: "2D image-layer playback is enabled."),
                ScanIssue(code: "scene_renderer_limited", message: "old limited renderer message")
            ]
        )
        try store.replaceAsset(stale)

        // When
        let repaired = try XCTUnwrap(store.load().assets.first)

        // Then
        XCTAssertEqual(repaired.issues.filter { $0.code == "scene_package_detected" }.count, 1)
        XCTAssertTrue(repaired.issues.contains { issue in
            issue.code == "scene_package_detected"
                && issue.message.contains("selected text SceneScript")
                && issue.message.contains("selected effect playback")
        })
        XCTAssertTrue(repaired.issues.contains { issue in
            issue.code == "scene_renderer_limited"
                && issue.message.contains("selected text SceneScript")
                && issue.message.contains("selected effect motion")
        })
    }

    func testLoadRefreshesTextOnlySceneSupportStatusToPlayable() throws {
        // Given
        let store = LibraryStore(root: try Fixture.makeTempDirectory())
        let project = try makeImportedProjectDirectory(in: store.root, id: "text-only-scene")
        let scenePackage = project.appending(path: "scene.pkg")
        try Fixture.writeScenePackage(
            to: scenePackage,
            sceneJSON: #"{"objects":[{"text":{"value":"HELLO"},"size":"320 120"}]}"#
        )
        let stale = WallpaperAsset(
            id: "text-only-scene",
            title: "Text Scene",
            kind: .scene,
            supportStatus: .unsupported,
            source: .manualFolder,
            projectDirectory: project.path,
            entrypoint: scenePackage.path,
            thumbnail: nil,
            workshopId: "text-only-scene",
            redistributionAllowed: false,
            issues: [
                ScanIssue(code: "scene_package_detected", message: "old summary"),
                ScanIssue(code: "scene_renderer_limited", message: "old renderer message")
            ]
        )
        try store.replaceAsset(stale)

        // When
        let repaired = try XCTUnwrap(store.load().assets.first)

        // Then
        XCTAssertEqual(repaired.supportStatus, .playable)
        XCTAssertTrue(repaired.issues.contains { $0.code == "scene_package_detected" })
        XCTAssertTrue(repaired.issues.contains { $0.code == "scene_renderer_limited" })
    }

    func testLoadKeepsBrokenSceneSupportStatusUnsupported() throws {
        // Given
        let store = LibraryStore(root: try Fixture.makeTempDirectory())
        let project = try makeImportedProjectDirectory(in: store.root, id: "broken-scene")
        let scenePackage = project.appending(path: "scene.pkg")
        try Fixture.writeScenePackage(
            to: scenePackage,
            sceneJSON: #"{"objects":[{"image":"models/background.json"}]}"#,
            extraEntries: [
                (path: "models/background.json", data: Data(#"{"material":"materials/background.json"}"#.utf8)),
                (path: "materials/background.json", data: Data(#"{"passes":[{"textures":["background"]}]}"#.utf8)),
                (path: "materials/background.tex", data: Data([1, 2, 3]))
            ]
        )
        let stale = WallpaperAsset(
            id: "broken-scene",
            title: "Broken Scene",
            kind: .scene,
            supportStatus: .playable,
            source: .manualFolder,
            projectDirectory: project.path,
            entrypoint: scenePackage.path,
            thumbnail: nil,
            workshopId: "broken-scene",
            redistributionAllowed: false,
            issues: []
        )
        try store.replaceAsset(stale)

        // When
        let repaired = try XCTUnwrap(store.load().assets.first)

        // Then
        XCTAssertEqual(repaired.supportStatus, .unsupported)
        XCTAssertTrue(repaired.issues.contains { $0.code == "scene_package_detected" })
        XCTAssertTrue(repaired.issues.contains { $0.code == "scene_renderer_limited" })
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
