import Foundation
import XCTest
@testable import WorkshopWallpaperBridgeApp
import WorkshopWallpaperCore

@MainActor
final class SystemWallpaperModeTests: XCTestCase {
    private let display = "11111111-2222-3333-4444-555555555555"
    private let root = FileManager.default.temporaryDirectory.appending(path: "wwb-system-wallpaper-\(UUID().uuidString)")

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSelectingTakesTheDisplayAndKeepsTheScreenSaver() throws {
        let choice = SystemWallpaperStore.Choice(choiceID: UUID().uuidString, resourceURL: URL(filePath: "/tmp/v.mp4"))
        let updated = try SystemWallpaperStore.selecting(
            [display: choice], in: sharedImageStore(), connectedDisplayIDs: [display], mainDisplayID: display
        )
        XCTAssertEqual(SystemWallpaperStore.providedDisplays(in: updated), [display: choice.choiceID])
        let shared = try XCTUnwrap(updated["AllSpacesAndDisplays"] as? [String: Any])
        XCTAssertNil(shared["Desktop"])
        XCTAssertNotNil(shared["Idle"], "the screen saver stays")
        XCTAssertTrue(SystemWallpaperStore.usesProvider(updated))
        XCTAssertNoThrow(try SystemWallpaperStore.decode(SystemWallpaperStore.encode(updated)))
    }

    func testRestoringAllPutsTheSharedDesktopBack() throws {
        let original = sharedImageStore()
        let choice = SystemWallpaperStore.Choice(choiceID: UUID().uuidString, resourceURL: URL(filePath: "/tmp/v.mp4"))
        let updated = try SystemWallpaperStore.selecting(
            [display: choice], in: original, connectedDisplayIDs: [display], mainDisplayID: display
        )
        let restored = SystemWallpaperStore.restoringAll(from: original, in: updated)
        XCTAssertFalse(SystemWallpaperStore.usesProvider(restored))
        let shared = try XCTUnwrap(restored["AllSpacesAndDisplays"] as? [String: Any])
        XCTAssertEqual((shared["Desktop"] as? [String: Any])?["Content"] as? [String: String], ["image": "old.png"])
    }

    func testPublishClonesTheVideoOnceUnderAStableChoice() throws {
        let video = root.appending(path: "clip.mp4")
        try Data(repeating: 7, count: 64).write(to: video)
        let library = SystemWallpaperExtensionLibrary(documentsURL: root.appending(path: "Documents"))
        let first = try library.publish(videoURL: video, assetID: "123", title: "Clip")
        XCTAssertEqual(first.choiceID, SystemWallpaperExtensionLibrary.choiceID(forAssetID: "123"))
        XCTAssertNotNil(UUID(uuidString: first.choiceID))
        XCTAssertEqual(try Data(contentsOf: first.resourceURL), try Data(contentsOf: video))
        let metadata = first.resourceURL.deletingLastPathComponent().appending(path: "metadata.json")
        let entry = try JSONDecoder().decode(SystemWallpaperExtensionLibrary.Entry.self, from: Data(contentsOf: metadata))
        XCTAssertEqual(entry.id, first.choiceID)
        XCTAssertEqual(entry.filename, "wallpaper.mp4")

        let copied = try FileManager.default.attributesOfItem(atPath: first.resourceURL.path)[.modificationDate] as? Date
        _ = try library.publish(videoURL: video, assetID: "123", title: "Clip")
        let again = try FileManager.default.attributesOfItem(atPath: first.resourceURL.path)[.modificationDate] as? Date
        XCTAssertEqual(copied, again, "an unchanged video isn't copied again")

        library.prune(keeping: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.resourceURL.path))
    }

    func testApplyHandsTheDisplayToTheExtensionAndRestoreGivesItBack() async throws {
        let storeURL = root.appending(path: "Index.plist")
        let originalData = try SystemWallpaperStore.encode(sharedImageStore())
        try originalData.write(to: storeURL)
        let documents = root.appending(path: "Documents")
        let library = SystemWallpaperExtensionLibrary(documentsURL: documents)
        let video = root.appending(path: "clip.mp4")
        try Data(repeating: 1, count: 16).write(to: video)
        var restarts = 0
        let mode = SystemWallpaperMode(
            library: library,
            storeURL: storeURL,
            backupURL: root.appending(path: "backup/Index.plist"),
            restartAgent: {
                restarts += 1
                // WallpaperAgent starts the extension, which reports what it draws.
                let store = try SystemWallpaperStore.decode(Data(contentsOf: storeURL))
                let contexts = SystemWallpaperStore.providedDisplays(in: store).values.map {
                    ["displayID": 7, "videoID": $0, "isPreview": false] as [String: Any]
                }
                let state: [String: Any] = ["processID": 1, "isActive": true, "contexts": contexts]
                try JSONSerialization.data(withJSONObject: state).write(to: library.stateURL)
            },
            resolveVideo: { _ in video },
            displayNumbers: { [self.display: 7] }
        )

        let served = try await mode.apply([display: asset()])
        XCTAssertEqual(served, [display])
        XCTAssertEqual(restarts, 1)
        let store = try SystemWallpaperStore.decode(Data(contentsOf: storeURL))
        XCTAssertEqual(SystemWallpaperStore.providedDisplays(in: store)[display],
                       SystemWallpaperExtensionLibrary.choiceID(forAssetID: "a1"))

        // Playing the same wallpaper again needs no store change or restart.
        _ = try await mode.apply([display: asset()])
        XCTAssertEqual(restarts, 1)

        try mode.restore()
        XCTAssertEqual(restarts, 2)
        let restored = try SystemWallpaperStore.decode(Data(contentsOf: storeURL))
        XCTAssertFalse(SystemWallpaperStore.usesProvider(restored))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "backup/Index.plist").path))
    }

    func testRestoreLeavesAStoreTheUserChangedAlone() throws {
        let storeURL = root.appending(path: "Index.plist")
        let userData = try SystemWallpaperStore.encode(sharedImageStore())
        try userData.write(to: storeURL)
        var restarts = 0
        let mode = SystemWallpaperMode(
            library: SystemWallpaperExtensionLibrary(documentsURL: root.appending(path: "Documents")),
            storeURL: storeURL,
            backupURL: root.appending(path: "backup/Index.plist"),
            restartAgent: { restarts += 1 }
        )
        try mode.restore()
        XCTAssertEqual(restarts, 0)
        XCTAssertEqual(try Data(contentsOf: storeURL), userData)
    }

    private func sharedImageStore() -> [String: Any] {
        [
            "AllSpacesAndDisplays": [
                "Desktop": ["Content": ["image": "old.png"]],
                "Idle": ["Content": ["saver": "aerial"]],
                "Type": "linked"
            ] as [String: Any],
            "SystemDefault": ["Type": "idle"],
            "Displays": [String: Any](),
            "Spaces": [String: Any]()
        ]
    }

    private func asset() -> WallpaperAsset {
        WallpaperAsset(
            id: "a1", title: "Clip", kind: .video, supportStatus: .playable, source: .localSteamWorkshop,
            projectDirectory: root.path, entrypoint: root.appending(path: "clip.mp4").path, thumbnail: nil,
            workshopId: nil, redistributionAllowed: false, issues: []
        )
    }
}
