import Darwin
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
        XCTAssertTrue(updated.issues.contains {
            $0.message.contains("reference only")
                && $0.message.contains("native renderer")
        })
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

    func testSceneRenderCacheDoesNotMakeUnsupportedScenePlayableAfterLoadRepair() throws {
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
        XCTAssertEqual(repaired.supportStatus, .unsupported)
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

    func testRemoveAssetAlsoTrashesCompletedDownloadAndExactSceneCaches() throws {
        let root = try makeRemovalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let trasher = SpyAssetTrasher()
        let store = LibraryStore(root: root, trasher: trasher)
        let downloads = WorkshopDownloads(root: root.appending(path: "WorkshopDownloads"))
        let download = try makeCompletedDownload(in: downloads, id: "123")
        let retained = try makeCompletedDownload(in: downloads, id: "1234")
        let imported = try store.importAsset(downloads.scan(download))
        let caches = ["v1/123.mp4", "v6/123-media-v3.mp4", "v7/123-media-v4.mp4"]
        let retainedPaths = ["SceneVideoCache/v7/1234.mp4", "SceneVideoCache/v7/123-extra.mp4",
                             "SceneVideoCache/v7/123-media-v4.mp4.tmp", "SceneVideoCache/current/123.mp4",
                             "Steam/credentials.json", "Engine/assets/keep"]
        for path in caches.map({ "SceneVideoCache/\($0)" }) + retainedPaths {
            let file = root.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: file)
        }

        try store.removeAsset(id: imported.id)

        XCTAssertTrue(try store.load().assets.isEmpty)
        XCTAssertEqual(try downloads.load(), [retained])
        XCTAssertEqual(Set(trasher.trashedURLs.map(\.path)), Set(
            [download.directory, imported.projectDirectory] + caches.map { root.appending(path: "SceneVideoCache/\($0)").path }
        ))
        XCTAssertTrue(trasher.removedURLs.isEmpty)
        for path in caches {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "SceneVideoCache/\(path)").path), path)
        }
        for path in retainedPaths {
            XCTAssertEqual(try Data(contentsOf: root.appending(path: path)), Data("keep".utf8), path)
        }
    }

    func testRemoveLocalAssetIgnoresInvalidWorkshopMetadataAndPreservesDownloads() throws {
        for workshopID in ["last", "../escape", "0", "18446744073709551616"] {
            let root = try makeRemovalRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let trasher = SpyAssetTrasher()
            let store = LibraryStore(root: root, trasher: trasher)
            let asset = try makeRemovalAsset(in: store, id: "local", workshopID: workshopID)
            let preservedPaths = ["WorkshopDownloads/items/last/clip.mp4", "WorkshopDownloads/items/0/clip.mp4",
                                  "WorkshopDownloads/escape/clip.mp4", "WorkshopDownloads/items/18446744073709551616/clip.mp4"]
            for path in preservedPaths {
                let file = root.appending(path: path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("preserved".utf8).write(to: file)
            }

            try store.removeAsset(id: asset.id)

            XCTAssertTrue(try store.load().assets.isEmpty, workshopID)
            XCTAssertFalse(FileManager.default.fileExists(atPath: asset.projectDirectory), workshopID)
            XCTAssertEqual(trasher.trashedURLs.map(\.path), [asset.projectDirectory])
            for path in preservedPaths {
                XCTAssertEqual(try Data(contentsOf: root.appending(path: path)), Data("preserved".utf8))
            }
        }
    }

    func testRemoveAssetTrashesOnlyItsExactGeneratedStillImageWithFallback() throws {
        for fallback in [false, true] {
            let root = try makeRemovalRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let trasher = SpyAssetTrasher()
            if fallback { trasher.trashItemError = CocoaError(.fileWriteVolumeReadOnly) }
            let store = LibraryStore(root: root, trasher: trasher)
            let asset = try makeRemovalAsset(in: store, id: "local_sample")
            let cache = root.appending(path: "GeneratedStillWallpapers/local-sample-still.png")
            let preservedPaths = ["GeneratedStillWallpapers/local-sample2-still.png",
                                  "GeneratedStillWallpapers/local-sample-still.png.tmp",
                                  "original.png", "SystemAppliedWallpapers/local-sample-still.png"]
            for file in [cache] + preservedPaths.map({ root.appending(path: $0) }) {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("image".utf8).write(to: file)
            }

            try store.removeAsset(id: asset.id)

            XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: asset.projectDirectory))
            XCTAssertTrue(try store.load().assets.isEmpty)
            let expected = Set([cache.path, asset.projectDirectory])
            XCTAssertEqual(Set(trasher.trashedURLs.map(\.path)), expected)
            XCTAssertEqual(Set(trasher.removedURLs.map(\.path)), fallback ? expected : [])
            for path in preservedPaths {
                XCTAssertEqual(try Data(contentsOf: root.appending(path: path)), Data("image".utf8))
            }
        }
    }

    func testRemoveAssetRejectsUnsafeOrSharedGeneratedStillImageBeforeDeletingAnything() throws {
        for invalid in ["collision", "symlink", "parent-link", "directory", "hard-link"] {
            let root = try makeRemovalRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let trasher = SpyAssetTrasher()
            let store = LibraryStore(root: root, trasher: trasher)
            let asset = try makeRemovalAsset(in: store, id: "local_sample")
            let cache = root.appending(path: "GeneratedStillWallpapers/local-sample-still.png")
            try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("image".utf8).write(to: cache)
            let outside = root.appending(path: "preserved")
            if invalid == "collision" {
                _ = try makeRemovalAsset(in: store, id: "local-sample")
            } else if invalid == "hard-link" {
                try FileManager.default.linkItem(at: cache, to: outside)
            } else if invalid == "directory" {
                try FileManager.default.removeItem(at: cache)
                try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false)
            } else {
                let target = invalid == "parent-link" ? cache.deletingLastPathComponent() : cache
                try FileManager.default.moveItem(at: target, to: outside)
                try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
            }
            let before = try store.load()

            XCTAssertThrowsError(try store.removeAsset(id: asset.id), invalid)

            XCTAssertEqual(try store.load(), before, invalid)
            XCTAssertTrue(trasher.trashedURLs.isEmpty, invalid)
            XCTAssertTrue(trasher.removedURLs.isEmpty, invalid)
            XCTAssertTrue(FileManager.default.fileExists(atPath: asset.projectDirectory), invalid)
        }
    }

    func testRemoveAssetRetainsManifestForRetryAfterGeneratedStillImageDeletionFails() throws {
        let root = try makeRemovalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let trasher = SpyAssetTrasher()
        let store = LibraryStore(root: root, trasher: trasher)
        let asset = try makeRemovalAsset(in: store, id: "local_sample")
        let cache = root.appending(path: "GeneratedStillWallpapers/local-sample-still.png")
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("image".utf8).write(to: cache)
        trasher.failingPath = cache.path

        XCTAssertThrowsError(try store.removeAsset(id: asset.id))

        XCTAssertEqual(try store.load().assets.map(\.id), [asset.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: asset.projectDirectory))
        trasher.failingPath = nil
        try store.removeAsset(id: asset.id)
        XCTAssertTrue(try store.load().assets.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
    }

    func testRemoveAssetValidatesAllTargetsBeforeDeletingAnything() throws {
        for invalid in ["unmarked-download", "corrupt-marker", "download-link", "download-child-link",
                        "download-parent-link", "cache-link", "cache-directory", "cache-parent-link",
                        "cache-version-link", "library-link", "library-child-link", "library-parent-link"] {
            let root = try makeRemovalRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let trasher = SpyAssetTrasher()
            let store = LibraryStore(root: root, trasher: trasher)
            let downloads = WorkshopDownloads(root: root.appending(path: "WorkshopDownloads"))
            let download = try makeCompletedDownload(in: downloads, id: "123")
            let imported = try store.importAsset(downloads.scan(download))
            let directory = URL(filePath: download.directory)
            let cache = root.appending(path: "SceneVideoCache/v7/123.mp4")
            try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("cache".utf8).write(to: cache)
            let marker = directory.appending(path: ".wwb-completion.json")
            if invalid == "unmarked-download" {
                try FileManager.default.removeItem(at: marker)
            } else if invalid == "corrupt-marker" {
                try Data("invalid".utf8).write(to: marker)
            } else if invalid == "cache-directory" {
                try FileManager.default.removeItem(at: cache)
                try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false)
            } else {
                let target: URL
                switch invalid {
                case "download-link": target = directory
                case "download-child-link": target = directory.appending(path: "clip.mp4")
                case "download-parent-link": target = directory.deletingLastPathComponent()
                case "cache-link": target = cache
                case "cache-parent-link": target = root.appending(path: "SceneVideoCache")
                case "cache-version-link": target = cache.deletingLastPathComponent()
                case "library-link": target = URL(filePath: imported.projectDirectory)
                case "library-child-link": target = URL(filePath: imported.projectDirectory).appending(path: "clip.mp4")
                default: target = root.appending(path: "Assets")
                }
                let outside = root.appending(path: "preserved")
                try FileManager.default.moveItem(at: target, to: outside)
                try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
            }

            XCTAssertThrowsError(try store.removeAsset(id: imported.id), invalid)

            XCTAssertEqual(try store.load().assets.map(\.id), [imported.id], invalid)
            XCTAssertTrue(trasher.trashedURLs.isEmpty, invalid)
            XCTAssertTrue(trasher.removedURLs.isEmpty, invalid)
            XCTAssertTrue(FileManager.default.fileExists(atPath: imported.projectDirectory), invalid)
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path), invalid)
        }
    }

    func testRemoveAssetDeletesOnlyExactVideoPlaybackCaches() throws {
        for fallback in [false, true] {
            let root = try makeRemovalRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let trasher = SpyAssetTrasher()
            if fallback { trasher.trashItemError = CocoaError(.fileWriteVolumeReadOnly) }
            let store = LibraryStore(root: root, trasher: trasher)
            let downloads = WorkshopDownloads(root: root.appending(path: "WorkshopDownloads"))
            let download = try makeCompletedDownload(in: downloads, id: "123")
            let imported = try store.importAsset(downloads.scan(download))
            let cacheRoot = root.appending(path: "VideoPlaybackCache/v1")
            try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
            let removedNames = ["123.mp4", "123.json"]
            let retainedNames = ["1234.mp4", "1234.json", "123-media-v4.mp4", ".123.temporary.mp4", ".123.temporary.json", "123.mp4.backup"]
            for name in removedNames + retainedNames {
                try Data("cache".utf8).write(to: cacheRoot.appending(path: name))
            }

            try store.removeAsset(id: imported.id)

            let expected = Set(removedNames.map { cacheRoot.appending(path: $0).path } + [download.directory, imported.projectDirectory])
            XCTAssertEqual(Set(trasher.trashedURLs.map(\.path)), expected)
            XCTAssertEqual(Set(trasher.removedURLs.map(\.path)), fallback ? expected : [])
            for name in removedNames { XCTAssertFalse(FileManager.default.fileExists(atPath: cacheRoot.appending(path: name).path)) }
            for name in retainedNames { XCTAssertTrue(FileManager.default.fileExists(atPath: cacheRoot.appending(path: name).path)) }
            XCTAssertTrue(try store.load().assets.isEmpty)
        }
    }

    func testRemoveAssetValidatesVideoPlaybackCachesBeforeDeletingAnyCopy() throws {
        for invalid in ["video-link", "metadata-link", "directory", "root-link", "version-link", "hard-link"] {
            let root = try makeRemovalRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let trasher = SpyAssetTrasher()
            let store = LibraryStore(root: root, trasher: trasher)
            let downloads = WorkshopDownloads(root: root.appending(path: "WorkshopDownloads"))
            let download = try makeCompletedDownload(in: downloads, id: "123")
            let imported = try store.importAsset(downloads.scan(download))
            let cacheRoot = root.appending(path: "VideoPlaybackCache/v1")
            try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
            let video = cacheRoot.appending(path: "123.mp4")
            let metadata = cacheRoot.appending(path: "123.json")
            try Data("video".utf8).write(to: video)
            try Data("metadata".utf8).write(to: metadata)
            let outside = root.appending(path: "preserved")
            if invalid == "directory" {
                try FileManager.default.removeItem(at: metadata)
                try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
            } else if invalid == "hard-link" {
                try FileManager.default.linkItem(at: metadata, to: outside)
            } else {
                let target: URL
                switch invalid {
                case "video-link": target = video
                case "metadata-link": target = metadata
                case "root-link": target = cacheRoot.deletingLastPathComponent()
                default: target = cacheRoot
                }
                try FileManager.default.moveItem(at: target, to: outside)
                try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
            }

            XCTAssertThrowsError(try store.removeAsset(id: imported.id), invalid)

            XCTAssertTrue(trasher.trashedURLs.isEmpty, invalid)
            XCTAssertTrue(trasher.removedURLs.isEmpty, invalid)
            XCTAssertEqual(try store.load().assets.map(\.id), [imported.id], invalid)
            XCTAssertTrue(FileManager.default.fileExists(atPath: imported.projectDirectory), invalid)
            XCTAssertEqual(try downloads.load(), [download], invalid)
        }
    }

    func testRemoveAssetRetainsManifestForRetryAfterVideoPlaybackCacheDeletionFails() throws {
        let root = try makeRemovalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let trasher = SpyAssetTrasher()
        let store = LibraryStore(root: root, trasher: trasher)
        let downloads = WorkshopDownloads(root: root.appending(path: "WorkshopDownloads"))
        let download = try makeCompletedDownload(in: downloads, id: "123")
        let imported = try store.importAsset(downloads.scan(download))
        let cacheRoot = root.appending(path: "VideoPlaybackCache/v1")
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        for name in ["123.mp4", "123.json"] {
            try Data("cache".utf8).write(to: cacheRoot.appending(path: name))
        }
        trasher.failingPath = cacheRoot.appending(path: "123.json").path

        XCTAssertThrowsError(try store.removeAsset(id: imported.id))

        XCTAssertEqual(try store.load().assets.map(\.id), [imported.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.projectDirectory))
        XCTAssertEqual(try downloads.load(), [download])
        trasher.failingPath = nil
        try store.removeAsset(id: imported.id)
        XCTAssertTrue(try store.load().assets.isEmpty)
        XCTAssertTrue(try downloads.load().isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cacheRoot.path), [])
    }

    func testRemoveAssetRetainsManifestAndLibraryForRetryWhenDownloadDeletionFails() throws {
        let root = try makeRemovalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let trasher = SpyAssetTrasher()
        let store = LibraryStore(root: root, trasher: trasher)
        let downloads = WorkshopDownloads(root: root.appending(path: "WorkshopDownloads"))
        let download = try makeCompletedDownload(in: downloads, id: "123")
        let imported = try store.importAsset(downloads.scan(download))
        trasher.failingPath = download.directory

        XCTAssertThrowsError(try store.removeAsset(id: imported.id))

        XCTAssertEqual(try store.load().assets.map(\.id), [imported.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.projectDirectory))
        XCTAssertEqual(try downloads.load(), [download])
        trasher.failingPath = nil
        try store.removeAsset(id: imported.id)
        XCTAssertTrue(try store.load().assets.isEmpty)
        XCTAssertTrue(try downloads.load().isEmpty)
    }

    func testRemoveAssetRetryFinishesAfterDownloadWasDeletedButLibraryDeletionFailed() throws {
        let root = try makeRemovalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let trasher = SpyAssetTrasher()
        let store = LibraryStore(root: root, trasher: trasher)
        let downloads = WorkshopDownloads(root: root.appending(path: "WorkshopDownloads"))
        let download = try makeCompletedDownload(in: downloads, id: "123")
        let imported = try store.importAsset(downloads.scan(download))
        trasher.failingPath = imported.projectDirectory

        XCTAssertThrowsError(try store.removeAsset(id: imported.id))

        XCTAssertEqual(try store.load().assets.map(\.id), [imported.id])
        XCTAssertTrue(try downloads.load().isEmpty)
        trasher.failingPath = nil
        try store.removeAsset(id: imported.id)
        XCTAssertTrue(try store.load().assets.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.projectDirectory))
    }

    func testRemoveCopiedWorkshopAssetPreservesOriginalAndUsesTrashFallbackForAllCopies() throws {
        let root = try makeRemovalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appending(path: "original")
        try Fixture.project(root: original, id: "123", metadata: #"{"file":"clip.mp4"}"#, file: "clip.mp4")
        let trasher = SpyAssetTrasher()
        trasher.trashItemError = CocoaError(.fileWriteVolumeReadOnly)
        let store = LibraryStore(root: root.appending(path: "library"), trasher: trasher)
        let asset = try XCTUnwrap(WallpaperScanner().scan(root: original).assets.first)
        let imported = try store.importAsset(asset)
        let downloads = WorkshopDownloads(root: store.root.appending(path: "WorkshopDownloads"))
        let download = try makeCompletedDownload(in: downloads, id: "123")
        let cache = store.root.appending(path: "SceneVideoCache/v7/123.mp4")
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("cache".utf8).write(to: cache)

        try store.removeAsset(id: imported.id)

        XCTAssertEqual(Set(trasher.removedURLs.map(\.path)), Set([download.directory, imported.projectDirectory, cache.path]))
        XCTAssertEqual(trasher.trashedURLs, trasher.removedURLs)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.appending(path: "123/clip.mp4").path))
    }

    func testRemoveAssetRejectsCacheNameSharedWithAnotherAssetID() throws {
        let root = try makeRemovalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let trasher = SpyAssetTrasher()
        let store = LibraryStore(root: root, trasher: trasher)
        let source = root.appending(path: "original")
        for id in ["123", "123-media-v4"] {
            try Fixture.project(root: source, id: id, metadata: #"{"file":"clip.mp4"}"#, file: "clip.mp4")
        }
        for asset in try WallpaperScanner().scan(root: source).assets { _ = try store.importAsset(asset) }
        let cache = root.appending(path: "SceneVideoCache/v7/123-media-v4.mp4")
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("shared".utf8).write(to: cache)

        XCTAssertThrowsError(try store.removeAsset(id: "123"))

        XCTAssertEqual(try store.load().assets.count, 2)
        XCTAssertTrue(trasher.trashedURLs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: cache), Data("shared".utf8))
    }

    func testRemoveAssetAcceptsSystemVarAliasWithoutLeavingManagedCopiesBehind() throws {
        for useAliasForStore in [false, true] {
            let root = try makeRemovalRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            XCTAssertTrue(root.path.hasPrefix("/private/var/"))
            let alias = URL(filePath: String(root.path.dropFirst("/private".count)))
            let trasher = SpyAssetTrasher()
            let store = LibraryStore(root: useAliasForStore ? alias : root, trasher: trasher)
            let downloads = WorkshopDownloads(root: root.appending(path: "WorkshopDownloads"))
            let download = try makeCompletedDownload(in: downloads, id: "123")
            let imported = try store.importAsset(downloads.scan(download))
            let alternateProject = (useAliasForStore ? root : alias)
                .appending(path: "Assets").appending(path: URL(filePath: imported.projectDirectory).lastPathComponent)
            let stored = WallpaperAsset(
                id: imported.id, title: imported.title, kind: imported.kind,
                supportStatus: imported.supportStatus, source: imported.source,
                projectDirectory: alternateProject.path, entrypoint: imported.entrypoint,
                thumbnail: nil, workshopId: imported.workshopId,
                redistributionAllowed: false, issues: []
            )
            try store.replaceAsset(stored)
            let caches = ["SceneVideoCache/v7/123.mp4", "VideoPlaybackCache/v1/123.mp4", "VideoPlaybackCache/v1/123.json"]
            for path in caches {
                let cache = root.appending(path: path)
                try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("cache".utf8).write(to: cache)
            }

            try store.removeAsset(id: imported.id)

            XCTAssertTrue(try store.load().assets.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: imported.projectDirectory))
            XCTAssertFalse(FileManager.default.fileExists(atPath: download.directory))
            for path in caches {
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: path).path))
            }
            XCTAssertEqual(trasher.trashedURLs.count, 5)
        }
    }

    func testRemoveAssetRejectsSymlinkedStoreRootWithoutChangingManifest() throws {
        let root = try makeRemovalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "clip.mp4")
        try Data("video".utf8).write(to: source)
        let trasher = SpyAssetTrasher()
        let store = LibraryStore(root: root.appending(path: "library"), trasher: trasher)
        let imported = try store.importVideoFile(source)
        let alias = root.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: store.root)
        let linked = LibraryStore(root: alias, trasher: trasher)
        let manifest = try Data(contentsOf: store.root.appending(path: "library.json"))

        XCTAssertThrowsError(try linked.removeAsset(id: imported.id))

        XCTAssertTrue(trasher.trashedURLs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: store.root.appending(path: "library.json")), manifest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.projectDirectory))
    }

    func testRemoveAssetRejectsDirectoryOwnedByAnotherLibraryAsset() throws {
        let root = try makeRemovalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "clip.mp4")
        try Data("video".utf8).write(to: source)
        let trasher = SpyAssetTrasher()
        let store = LibraryStore(root: root, trasher: trasher)
        let imported = try store.importVideoFile(source)
        let forged = WallpaperAsset(
            id: "another", title: "Another", kind: .video, supportStatus: .playable,
            source: .manualFolder, projectDirectory: imported.projectDirectory,
            entrypoint: imported.entrypoint, thumbnail: nil, workshopId: nil,
            redistributionAllowed: false, issues: []
        )
        try store.replaceAsset(forged)

        XCTAssertThrowsError(try store.removeAsset(id: forged.id))

        XCTAssertEqual(try store.load().assets.count, 2)
        XCTAssertTrue(trasher.trashedURLs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.projectDirectory))
    }

    func testRemoveAssetDeletesLibraryDirectoryAndManifestEntry() throws {
        // Given
        let sourceRoot = try Fixture.makeTempDirectory()
        let video = sourceRoot.appending(path: "remove-me.mp4")
        FileManager.default.createFile(atPath: video.path, contents: Data([1]))
        let store = LibraryStore(root: try makeRemovalRoot())
        let imported = try store.importVideoFile(video)

        // When
        try store.removeAsset(id: imported.id)
        let manifest = try store.load()

        // Then
        XCTAssertTrue(manifest.assets.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.projectDirectory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.path))
    }

    func testRemoveAssetUsesTrashRatherThanPermanentDelete() throws {
        // Given
        let sourceRoot = try Fixture.makeTempDirectory()
        let video = sourceRoot.appending(path: "trash-me.mp4")
        FileManager.default.createFile(atPath: video.path, contents: Data([1]))
        let trasher = SpyAssetTrasher()
        let store = LibraryStore(root: try makeRemovalRoot(), trasher: trasher)
        let imported = try store.importVideoFile(video)

        // When
        try store.removeAsset(id: imported.id)

        // Then
        XCTAssertEqual(trasher.trashedURLs.map(\.path), [imported.projectDirectory])
        XCTAssertTrue(trasher.removedURLs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.projectDirectory))
    }

    func testRemoveAssetFallsBackToPermanentDeleteWhenTrashFails() throws {
        // Given
        let sourceRoot = try Fixture.makeTempDirectory()
        let video = sourceRoot.appending(path: "fallback-me.mp4")
        FileManager.default.createFile(atPath: video.path, contents: Data([1]))
        let trasher = SpyAssetTrasher()
        trasher.trashItemError = CocoaError(.fileWriteVolumeReadOnly)
        let store = LibraryStore(root: try makeRemovalRoot(), trasher: trasher)
        let imported = try store.importVideoFile(video)

        // When
        try store.removeAsset(id: imported.id)

        // Then
        XCTAssertEqual(trasher.trashedURLs.map(\.path), [imported.projectDirectory])
        XCTAssertEqual(trasher.removedURLs.map(\.path), [imported.projectDirectory])
        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.projectDirectory))
    }

    func testRemoveMissingAssetIsNoOp() throws {
        // Given
        let sourceRoot = try Fixture.makeTempDirectory()
        let video = sourceRoot.appending(path: "keep-me.mp4")
        FileManager.default.createFile(atPath: video.path, contents: Data([1]))
        let store = LibraryStore(root: try makeRemovalRoot())
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
        let store = LibraryStore(root: try makeRemovalRoot())
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

    private func makeRemovalAsset(in store: LibraryStore, id: String, workshopID: String? = nil) throws -> WallpaperAsset {
        let directory = try makeImportedProjectDirectory(in: store.root, id: id)
        let video = directory.appending(path: "clip.mp4")
        try Data("video".utf8).write(to: video)
        let asset = WallpaperAsset(
            id: id, title: id, kind: .video, supportStatus: .playable, source: .manualFolder,
            projectDirectory: directory.path, entrypoint: video.path, thumbnail: nil,
            workshopId: workshopID, redistributionAllowed: false, issues: []
        )
        try store.replaceAsset(asset)
        return asset
    }

    private func makeRemovalRoot() throws -> URL {
        let temporary = try Fixture.makeTempDirectory()
        let resolved = try XCTUnwrap(realpath(temporary.path, nil))
        defer { free(resolved) }
        return URL(filePath: String(cString: resolved))
    }

    private func makeCompletedDownload(in downloads: WorkshopDownloads, id: String) throws -> WorkshopDownload {
        let staging = try downloads.begin(itemID: id)
        try Data(#"{"title":"Fixture","file":"clip.mp4"}"#.utf8).write(to: staging.appending(path: "project.json"))
        try Data("video".utf8).write(to: staging.appending(path: "clip.mp4"))
        return try downloads.finish(itemID: id, title: "Fixture", staging: staging)
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

/// Test double for `AssetTrashing` that records every call so removal tests
/// can assert Trash is preferred, and can simulate a volume that rejects
/// `trashItem` to exercise the permanent-delete fallback.
private final class SpyAssetTrasher: AssetTrashing, @unchecked Sendable {
    private(set) var trashedURLs: [URL] = []
    private(set) var removedURLs: [URL] = []
    var trashItemError: Error?
    var failingPath: String?

    func trashItem(at url: URL) throws {
        trashedURLs.append(url)
        if url.path == failingPath { throw CocoaError(.fileWriteNoPermission) }
        if let trashItemError {
            throw trashItemError
        }
        try FileManager.default.removeItem(at: url)
    }

    func removeItem(at url: URL) throws {
        removedURLs.append(url)
        if url.path == failingPath { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.removeItem(at: url)
    }
}
