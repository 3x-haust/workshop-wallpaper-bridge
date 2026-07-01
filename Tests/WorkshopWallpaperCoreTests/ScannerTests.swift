import Foundation
import XCTest
@testable import WorkshopWallpaperCore

final class ScannerTests: XCTestCase {
    func testScanDiscoversPlayableVideoWhenWorkshopFolderContainsProjectJson() throws {
        // Given
        let root = try Fixture.makeWorkshopRoot()
        let project = root.appending(path: "123456")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try #"{"title":"Rain Loop","file":"rain.mp4","type":"video"}"#.write(
            to: project.appending(path: "project.json"),
            atomically: true,
            encoding: .utf8
        )
        FileManager.default.createFile(atPath: project.appending(path: "rain.mp4").path, contents: Data())

        // When
        let result = try WallpaperScanner().scan(root: root)

        // Then
        XCTAssertEqual(result.assets.count, 1)
        let asset = try XCTUnwrap(result.assets.first)
        XCTAssertEqual(asset.id, "123456")
        XCTAssertEqual(asset.title, "Rain Loop")
        XCTAssertEqual(asset.kind, .video)
        XCTAssertEqual(asset.supportStatus, .playable)
        XCTAssertEqual(asset.source, .localSteamWorkshop)
        XCTAssertEqual(asset.redistributionAllowed, false)
    }

    func testScanReadsDateAddedAndSortsNewestFirst() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        try Fixture.project(
            root: root,
            id: "100",
            metadata: #"{"title":"Older","file":"older.mp4"}"#,
            file: "older.mp4"
        )
        try Fixture.project(
            root: root,
            id: "200",
            metadata: #"{"title":"Newer","file":"newer.mp4"}"#,
            file: "newer.mp4"
        )
        let older = root.appending(path: "100")
        let newer = root.appending(path: "200")
        let olderDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newerDate = Date(timeIntervalSince1970: 1_700_086_400)
        try FileManager.default.setAttributes([.modificationDate: olderDate], ofItemAtPath: older.path)
        try FileManager.default.setAttributes([.modificationDate: newerDate], ofItemAtPath: newer.path)

        // When
        let result = try WallpaperScanner().scan(root: root)

        // Then
        XCTAssertEqual(result.assets.map(\.id), ["200", "100"])
        XCTAssertNotNil(result.assets[0].dateAdded)
        XCTAssertNotNil(result.assets[1].dateAdded)
    }

    func testScanClassifiesWebImageAndSceneProjects() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        try Fixture.project(
            root: root,
            id: "web",
            metadata: #"{"title":"Clock","file":"index.html"}"#,
            file: "index.html"
        )
        try Fixture.project(
            root: root,
            id: "image",
            metadata: #"{"title":"Poster","file":"poster.png"}"#,
            file: "poster.png"
        )
        try Fixture.project(
            root: root,
            id: "scene",
            metadata: #"{"title":"Particles","file":"scene.pkg"}"#,
            file: "scene.pkg"
        )

        // When
        let result = try WallpaperScanner().scan(root: root)

        // Then
        let supportByKind = Dictionary(uniqueKeysWithValues: result.assets.map { ($0.kind, $0.supportStatus) })
        XCTAssertEqual(supportByKind[.image], .playable)
        XCTAssertEqual(supportByKind[.scene], .unsupported)
        XCTAssertEqual(supportByKind[.web], .playable)
    }

    func testScanReportsMalformedProjectJsonWithoutThrowing() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let project = root.appending(path: "broken")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "{bad json".write(to: project.appending(path: "project.json"), atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: project.appending(path: "clip.mp4").path, contents: Data())

        // When
        let result = try WallpaperScanner().scan(root: root)

        // Then
        XCTAssertEqual(result.assets.count, 1)
        let asset = try XCTUnwrap(result.assets.first)
        XCTAssertEqual(asset.kind, .video)
        XCTAssertTrue(asset.issues.contains { $0.code == "malformed_project_json" })
    }

    func testScanDoesNotUsePreviewImageAsSceneEntrypointWhenProjectFileIsMissing() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let project = root.appending(path: "scene-preview")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try #"{"title":"Scene Preview"}"#.write(
            to: project.appending(path: "project.json"),
            atomically: true,
            encoding: .utf8
        )
        try Fixture.writeScenePackage(
            to: project.appending(path: "scene.pkg"),
            sceneJSON: #"{"objects":[{"image":"models/background.json"},{"particle":"particles/leaves.json"}]}"#,
            extraEntries: [(path: "materials/background.tex", data: Data([1, 2, 3]))]
        )
        FileManager.default.createFile(atPath: project.appending(path: "preview.jpg").path, contents: Data())

        // When
        let result = try WallpaperScanner().scan(root: root)

        // Then
        let asset = try XCTUnwrap(result.assets.first)
        XCTAssertEqual(asset.kind, .scene)
        XCTAssertEqual(asset.supportStatus, .unsupported)
        XCTAssertEqual(URL(filePath: try XCTUnwrap(asset.entrypoint)).lastPathComponent, "scene.pkg")
        XCTAssertEqual(URL(filePath: try XCTUnwrap(asset.thumbnail)).lastPathComponent, "preview.jpg")
        XCTAssertTrue(asset.issues.contains { $0.code == "scene_package_detected" })
        XCTAssertTrue(asset.issues.contains { $0.code == "scene_renderer_limited" })
    }

    func testScanMarksRenderableSceneAsPlayable() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let project = root.appending(path: "renderable-scene")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try #"{"title":"Renderable Scene","file":"scene.pkg"}"#.write(
            to: project.appending(path: "project.json"),
            atomically: true,
            encoding: .utf8
        )
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/lz8KWwAAAABJRU5ErkJggg=="
        )!
        try Fixture.writeScenePackage(
            to: project.appending(path: "scene.pkg"),
            sceneJSON: """
            {
              "objects": [
                {
                  "image": "models/background.json",
                  "origin": "960 540 0",
                  "size": "1920 1080"
                }
              ]
            }
            """,
            extraEntries: [
                (path: "models/background.json", data: Data(#"{"material":"materials/background.json"}"#.utf8)),
                (path: "materials/background.json", data: Data(#"{"passes":[{"textures":["background"]}]}"#.utf8)),
                (path: "materials/background.tex", data: Fixture.texData(width: 1, height: 1, imageData: png))
            ]
        )

        // When
        let result = try WallpaperScanner().scan(root: root)

        // Then
        let asset = try XCTUnwrap(result.assets.first)
        XCTAssertEqual(asset.kind, .scene)
        XCTAssertEqual(asset.supportStatus, .playable)
    }

    func testScanMarksTextOnlySceneAsPlayable() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let project = root.appending(path: "text-only-scene")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try #"{"title":"Text Scene","file":"scene.pkg"}"#.write(
            to: project.appending(path: "project.json"),
            atomically: true,
            encoding: .utf8
        )
        try Fixture.writeScenePackage(
            to: project.appending(path: "scene.pkg"),
            sceneJSON: #"{"objects":[{"text":{"value":"HELLO"},"size":"320 120"}]}"#
        )

        // When
        let result = try WallpaperScanner().scan(root: root)

        // Then
        let asset = try XCTUnwrap(result.assets.first)
        XCTAssertEqual(asset.kind, .scene)
        XCTAssertEqual(asset.supportStatus, .playable)
        XCTAssertTrue(asset.issues.contains { $0.code == "scene_package_detected" })
        XCTAssertTrue(asset.issues.contains { $0.code == "scene_renderer_limited" })
    }

    func testScanMarksMixedTextAndBrokenImageSceneAsPlayable() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let project = root.appending(path: "mixed-scene")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try #"{"title":"Mixed Scene","file":"scene.pkg"}"#.write(
            to: project.appending(path: "project.json"),
            atomically: true,
            encoding: .utf8
        )
        try Fixture.writeScenePackage(
            to: project.appending(path: "scene.pkg"),
            sceneJSON: #"{"objects":[{"text":{"value":"CLOCK"}},{"image":"models/background.json"}]}"#,
            extraEntries: [
                (path: "models/background.json", data: Data(#"{"material":"materials/background.json"}"#.utf8)),
                (path: "materials/background.json", data: Data(#"{"passes":[{"textures":["background"]}]}"#.utf8)),
                (path: "materials/background.tex", data: Data([1, 2, 3]))
            ]
        )

        // When
        let result = try WallpaperScanner().scan(root: root)

        // Then
        let asset = try XCTUnwrap(result.assets.first)
        XCTAssertEqual(asset.kind, .scene)
        XCTAssertEqual(asset.supportStatus, .playable)
    }

    func testScanKeepsSceneUnsupportedWhenTextureCannotDecode() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let project = root.appending(path: "broken-scene-texture")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try #"{"title":"Broken Scene","file":"scene.pkg"}"#.write(
            to: project.appending(path: "project.json"),
            atomically: true,
            encoding: .utf8
        )
        try Fixture.writeScenePackage(
            to: project.appending(path: "scene.pkg"),
            sceneJSON: """
            {
              "objects": [
                {
                  "image": "models/background.json",
                  "origin": "960 540 0",
                  "size": "1920 1080"
                }
              ]
            }
            """,
            extraEntries: [
                (path: "models/background.json", data: Data(#"{"material":"materials/background.json"}"#.utf8)),
                (path: "materials/background.json", data: Data(#"{"passes":[{"textures":["background"]}]}"#.utf8)),
                (path: "materials/background.tex", data: Data([1, 2, 3]))
            ]
        )

        // When
        let result = try WallpaperScanner().scan(root: root)

        // Then
        let asset = try XCTUnwrap(result.assets.first)
        XCTAssertEqual(asset.kind, .scene)
        XCTAssertEqual(asset.supportStatus, .unsupported)
    }

    func testScanKeepsEffectOnlySceneUnsupported() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let project = root.appending(path: "effect-only-scene")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try #"{"title":"Effect Scene","file":"scene.pkg"}"#.write(
            to: project.appending(path: "project.json"),
            atomically: true,
            encoding: .utf8
        )
        try Fixture.writeScenePackage(
            to: project.appending(path: "scene.pkg"),
            sceneJSON: """
            {
              "objects": [
                {
                  "image": "models/util/composelayer.json",
                  "effects": [{"file": "effects/waterripple/effect.json"}]
                }
              ]
            }
            """
        )

        // When
        let result = try WallpaperScanner().scan(root: root)

        // Then
        let asset = try XCTUnwrap(result.assets.first)
        XCTAssertEqual(asset.kind, .scene)
        XCTAssertEqual(asset.supportStatus, .unsupported)
    }

    func testScanPrefersRealVideoOverPreviewImageWhenProjectFileIsMissing() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let project = root.appending(path: "video-preview")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try #"{"title":"Video Preview"}"#.write(
            to: project.appending(path: "project.json"),
            atomically: true,
            encoding: .utf8
        )
        FileManager.default.createFile(atPath: project.appending(path: "clip.mp4").path, contents: Data())
        FileManager.default.createFile(atPath: project.appending(path: "preview.jpg").path, contents: Data())

        // When
        let result = try WallpaperScanner().scan(root: root)

        // Then
        let asset = try XCTUnwrap(result.assets.first)
        XCTAssertEqual(asset.kind, .video)
        XCTAssertEqual(asset.supportStatus, .playable)
        XCTAssertEqual(URL(filePath: try XCTUnwrap(asset.entrypoint)).lastPathComponent, "clip.mp4")
        XCTAssertEqual(URL(filePath: try XCTUnwrap(asset.thumbnail)).lastPathComponent, "preview.jpg")
    }

    func testScanUsesExplicitImageFileAsPlayableEntrypoint() throws {
        // Given
        let root = try Fixture.makeTempDirectory()
        let project = root.appending(path: "explicit-image")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try #"{"title":"Poster","file":"poster.jpg","preview":"preview.jpg"}"#.write(
            to: project.appending(path: "project.json"),
            atomically: true,
            encoding: .utf8
        )
        FileManager.default.createFile(atPath: project.appending(path: "poster.jpg").path, contents: Data())
        FileManager.default.createFile(atPath: project.appending(path: "preview.jpg").path, contents: Data())

        // When
        let result = try WallpaperScanner().scan(root: root)

        // Then
        let asset = try XCTUnwrap(result.assets.first)
        XCTAssertEqual(asset.kind, .image)
        XCTAssertEqual(asset.supportStatus, .playable)
        XCTAssertEqual(URL(filePath: try XCTUnwrap(asset.entrypoint)).lastPathComponent, "poster.jpg")
        XCTAssertEqual(URL(filePath: try XCTUnwrap(asset.thumbnail)).lastPathComponent, "preview.jpg")
    }

    func testScanRejectsMetadataPathsOutsideProjectDirectory() throws {
        // Given
        let parent = try Fixture.makeTempDirectory()
        let root = parent.appending(path: "root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = root.appending(path: "path-escape")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try #"{"title":"Escape","file":"../../outside.mp4","preview":"../../outside.jpg"}"#.write(
            to: project.appending(path: "project.json"),
            atomically: true,
            encoding: .utf8
        )
        FileManager.default.createFile(atPath: parent.appending(path: "outside.mp4").path, contents: Data())
        FileManager.default.createFile(atPath: parent.appending(path: "outside.jpg").path, contents: Data())

        // When
        let result = try WallpaperScanner().scan(root: root)

        // Then
        let asset = try XCTUnwrap(result.assets.first)
        XCTAssertNil(asset.entrypoint)
        XCTAssertNil(asset.thumbnail)
        XCTAssertEqual(asset.kind, .unknown)
        XCTAssertEqual(asset.supportStatus, .unsupported)
        XCTAssertTrue(asset.issues.contains { $0.code == "no_supported_entrypoint" })
    }

    func testScanRejectsSymlinkEntrypointOutsideProjectDirectory() throws {
        // Given
        let parent = try Fixture.makeTempDirectory()
        let root = parent.appending(path: "root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = root.appending(path: "symlink-escape")
        let outside = parent.appending(path: "outside.mp4")
        let symlink = project.appending(path: "clip.mp4")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: outside.path, contents: Data())
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
        try #"{"title":"Symlink","file":"clip.mp4"}"#.write(
            to: project.appending(path: "project.json"),
            atomically: true,
            encoding: .utf8
        )

        // When
        let result = try WallpaperScanner().scan(root: root)

        // Then
        let asset = try XCTUnwrap(result.assets.first)
        XCTAssertNil(asset.entrypoint)
        XCTAssertEqual(asset.kind, .unknown)
        XCTAssertEqual(asset.supportStatus, .unsupported)
    }
}
