import Darwin
import Foundation
import XCTest
@testable import WorkshopWallpaperCore

final class WorkshopDownloadsTests: XCTestCase {
    private var temporaryRoot: URL!
    private var store: WorkshopDownloads!

    override func setUpWithError() throws {
        let temporary = try Fixture.makeTempDirectory()
        let resolved = try XCTUnwrap(realpath(temporary.path, nil))
        defer { free(resolved) }
        temporaryRoot = URL(filePath: String(cString: resolved))
        store = WorkshopDownloads(root: temporaryRoot.appending(path: "downloads"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporaryRoot)
    }

    func testFinishPublishesProjectAndRestoresItAfterRestart() throws {
        let staging = try store.begin(itemID: "123")
        try writeProject(at: staging)

        let download = try store.finish(itemID: "123", title: "Saved title", staging: staging)
        let restarted = WorkshopDownloads(root: store.root)
        let asset = try restarted.scan(download)

        XCTAssertEqual(try restarted.load(), [download])
        XCTAssertEqual(download.id, "123")
        XCTAssertEqual(download.title, "Saved title")
        XCTAssertEqual(download.directory, store.root.appending(path: "items/123").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertEqual(asset.id, "123")
        XCTAssertEqual(asset.title, "Fixture")
        XCTAssertEqual(asset.supportStatus, .playable)
        XCTAssertEqual(asset.projectDirectory, URL(filePath: download.directory).standardizedFileURL.path)
        XCTAssertEqual(asset.entrypoint, URL(filePath: download.directory).standardizedFileURL.appending(path: "clip.mp4").path)
    }

    func testSystemVarAliasCanPublishAndReadCompletedItemsAcrossRootSpellings() throws {
        XCTAssertTrue(store.root.path.hasPrefix("/private/var/"))
        let aliased = WorkshopDownloads(root: URL(filePath: String(store.root.path.dropFirst("/private".count))))
        let staging = try aliased.begin(itemID: "123")
        try writeProject(at: staging)

        let download = try aliased.finish(itemID: "123", title: "Fixture", staging: staging)

        XCTAssertEqual(try store.load(), [download])
        XCTAssertEqual(try store.completedItemIfPresent(itemID: "123"), download)
        XCTAssertEqual(try store.scan(download).id, "123")
        try store.remove(download)
        XCTAssertTrue(try aliased.load().isEmpty)
    }

    func testSystemVarAliasDoesNotPermitCallerControlledParentLinks() throws {
        let parent = temporaryRoot.appending(path: "linked")
        let destination = temporaryRoot.appending(path: "preserved")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: destination)
        let aliased = WorkshopDownloads(root: URL(filePath: String(parent.path.dropFirst("/private".count))))

        XCTAssertThrowsError(try aliased.begin(itemID: "123"))
        XCTAssertThrowsError(try aliased.completedItemIfPresent(itemID: "123"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
    }

    func testCompletedItemLookupDistinguishesMissingFromIncompleteWithoutDeletingFiles() throws {
        XCTAssertNil(try store.completedItemIfPresent(itemID: "123"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.path))
        let directory = store.root.appending(path: "items/123")
        try writeProject(at: directory)

        XCTAssertThrowsError(try store.completedItemIfPresent(itemID: "123")) {
            XCTAssertEqual($0 as? WorkshopDownloadsError, .invalidCompletion("123"))
        }
        XCTAssertEqual(try Data(contentsOf: directory.appending(path: "clip.mp4")), Data("fixture".utf8))
    }

    func testCompletedItemLookupReusesCompletionValidationAndAllowsRemovalRetry() throws {
        let download = try finishProject()
        XCTAssertEqual(try store.completedItemIfPresent(itemID: download.id), download)

        try store.remove(download)

        XCTAssertNil(try store.completedItemIfPresent(itemID: download.id))
        XCTAssertThrowsError(try store.completedItemIfPresent(itemID: "../123"))
    }

    func testCompletedItemLookupRejectsDanglingItemAndParentLinks() throws {
        let directory = store.root.appending(path: "items/123")
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: temporaryRoot.appending(path: "missing"))
        XCTAssertThrowsError(try store.completedItemIfPresent(itemID: "123"))
        try FileManager.default.removeItem(at: directory.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: directory.deletingLastPathComponent(), withDestinationURL: temporaryRoot)
        XCTAssertThrowsError(try store.completedItemIfPresent(itemID: "123"))
    }

    func testEmptyStoreLoadsWithoutCreatingDirectories() throws {
        XCTAssertEqual(try store.load(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.path))
    }

    func testRetryUsesFreshEmptyStagingAndInterruptedProjectsStayInvisible() throws {
        let interrupted = try store.begin(itemID: "123")
        try writeProject(at: interrupted)
        let retry = try WorkshopDownloads(root: store.root).begin(itemID: "123")

        XCTAssertNotEqual(interrupted, retry)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: retry.path), [])
        XCTAssertEqual(try store.load(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: interrupted.appending(path: "clip.mp4").path))
    }

    func testRejectsNonDecimalZeroOverflowAndPathItemIDs() throws {
        for id in ["", "0", "00", "-1", "+1", "1.0", "1 ", "１２", "../1", "1/2", "18446744073709551616"] {
            XCTAssertThrowsError(try store.begin(itemID: id), id) {
                XCTAssertEqual($0 as? WorkshopDownloadsError, .invalidItemID(id))
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.path))
        XCTAssertEqual(try store.begin(itemID: "18446744073709551615").lastPathComponent, "18446744073709551615")
    }

    func testCreatedDirectoriesAndCompletionRecordArePrivate() throws {
        let staging = try store.begin(itemID: "123")
        for directory in [store.root, staging.deletingLastPathComponent().deletingLastPathComponent(),
                          staging.deletingLastPathComponent(), staging] {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        }
        try writeProject(at: staging)
        let download = try store.finish(itemID: "123", title: "Fixture", staging: staging)
        let marker = URL(filePath: download.directory).appending(path: ".wwb-completion.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: marker.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testUnsupportedProjectsCanBeManagedWithoutBecomingPlayable() throws {
        let staging = try store.begin(itemID: "123")
        try writeProject(at: staging, file: "program.exe")

        let download = try store.finish(itemID: "123", title: "Unsupported", staging: staging)

        XCTAssertEqual(try store.load(), [download])
        XCTAssertEqual(try store.scan(download).kind, .unknown)
        XCTAssertEqual(try store.scan(download).supportStatus, .unsupported)
    }

    func testEmptyMetadataOnlyAndWrongProjectLayoutsCannotFinish() throws {
        let empty = try store.begin(itemID: "123")
        XCTAssertThrowsError(try store.finish(itemID: "123", title: "Empty", staging: empty))
        try Data(#"{"file":"missing.mp4"}"#.utf8).write(to: empty.appending(path: "project.json"))
        XCTAssertThrowsError(try store.finish(itemID: "123", title: "Missing", staging: empty))
        let nested = try store.begin(itemID: "456")
        try writeProject(at: nested.appending(path: "789"))
        XCTAssertThrowsError(try store.finish(itemID: "456", title: "Nested", staging: nested))
        XCTAssertThrowsError(try store.finish(itemID: "789", title: "Mismatch", staging: nested))
        XCTAssertEqual(try store.load(), [])
    }

    func testUnmarkedItemsAndCorruptOrMismatchedMarkersAreExcludedWithoutDeletion() throws {
        let unmarked = store.root.appending(path: "items/123")
        try writeProject(at: unmarked)
        XCTAssertEqual(try store.load(), [])
        let marker = unmarked.appending(path: ".wwb-completion.json")
        try Data("invalid".utf8).write(to: marker)
        XCTAssertEqual(try store.load(), [])
        let wrong = WorkshopDownload(id: "456", title: "Wrong", directory: unmarked.path,
                                     completedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try JSONEncoder().encode(wrong).write(to: marker)
        XCTAssertEqual(try store.load(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: unmarked.appending(path: "clip.mp4").path))
    }

    func testCompletedItemWithMissingContentIsExcludedAndNotAutomaticallyDeleted() throws {
        let download = try finishProject()
        let directory = URL(filePath: download.directory)
        try FileManager.default.removeItem(at: directory.appending(path: "clip.mp4"))

        XCTAssertEqual(try store.load(), [])
        XCTAssertThrowsError(try store.scan(download))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    func testDuplicateFinishPreservesExistingAndIncomingFiles() throws {
        let original = try finishProject()
        let incoming = try store.begin(itemID: "123")
        try writeProject(at: incoming, file: "replacement.mp4")

        XCTAssertThrowsError(try store.finish(itemID: "123", title: "Replacement", staging: incoming)) {
            XCTAssertEqual($0 as? WorkshopDownloadsError, .alreadyExists("123"))
        }

        XCTAssertEqual(try store.load(), [original])
        XCTAssertTrue(FileManager.default.fileExists(atPath: incoming.appending(path: "replacement.mp4").path))
        XCTAssertEqual(try Data(contentsOf: URL(filePath: original.directory).appending(path: "clip.mp4")), Data("fixture".utf8))
    }

    func testFinishDoesNotOverwriteAnUnfinishedDestination() throws {
        let destination = store.root.appending(path: "items/123")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: destination.appending(path: "user-data"))
        let incoming = try store.begin(itemID: "123")
        try writeProject(at: incoming)

        XCTAssertThrowsError(try store.finish(itemID: "123", title: "Duplicate", staging: incoming))
        XCTAssertEqual(try Data(contentsOf: destination.appending(path: "user-data")), Data("keep".utf8))
    }

    func testMetadataPathsCannotEscapeTheProject() throws {
        for path in ["../outside.mp4", "/outside.mp4", "..\\outside.mp4", "C:\\outside.mp4"] {
            let staging = try store.begin(itemID: "123")
            try writeProject(at: staging)
            let metadata: [String: String] = ["file": path]
            try JSONSerialization.data(withJSONObject: metadata).write(to: staging.appending(path: "project.json"))
            XCTAssertThrowsError(try store.finish(itemID: "123", title: "Escape", staging: staging), path)
        }
        XCTAssertEqual(try store.load(), [])
    }

    func testRejectsSymlinksIncludingHiddenAndDanglingFiles() throws {
        let outside = temporaryRoot.appending(path: "outside")
        try Data("keep".utf8).write(to: outside)
        for name in ["alias", ".hidden", "dangling"] {
            let staging = try store.begin(itemID: "123")
            try writeProject(at: staging)
            let target = name == "dangling" ? temporaryRoot.appending(path: "missing") : outside
            try FileManager.default.createSymbolicLink(at: staging.appending(path: name), withDestinationURL: target)

            XCTAssertThrowsError(try store.finish(itemID: "123", title: "Link", staging: staging), name)
            XCTAssertThrowsError(try store.discard(staging: staging), name)
        }
        XCTAssertEqual(try store.load(), [])
        XCTAssertEqual(try Data(contentsOf: outside), Data("keep".utf8))
    }

    func testRejectsSpecialFilesAndHardLinks() throws {
        let staging = try store.begin(itemID: "123")
        try writeProject(at: staging)
        let fifo = staging.appending(path: "pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try store.finish(itemID: "123", title: "FIFO", staging: staging))
        try FileManager.default.removeItem(at: fifo)
        let outside = temporaryRoot.appending(path: "outside")
        try Data("keep".utf8).write(to: outside)
        try FileManager.default.linkItem(at: outside, to: staging.appending(path: "hardlink"))
        XCTAssertThrowsError(try store.finish(itemID: "123", title: "Hard link", staging: staging))
        XCTAssertEqual(try Data(contentsOf: outside), Data("keep".utf8))
    }

    func testRejectsSymlinkedRootAndParentsWithoutWritingToTarget() throws {
        let outside = temporaryRoot.appending(path: "outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let alias = temporaryRoot.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
        for root in [alias, alias.appending(path: "downloads")] {
            let unsafe = WorkshopDownloads(root: root)
            XCTAssertThrowsError(try unsafe.begin(itemID: "123"))
            XCTAssertThrowsError(try unsafe.load())
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
        XCTAssertThrowsError(try WorkshopDownloads(root: URL(filePath: "/")).begin(itemID: "123"))
    }

    func testRejectsSymlinkedItemsAndStagingContainers() throws {
        _ = try store.begin(itemID: "123")
        let outside = temporaryRoot.appending(path: "outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: store.root.appending(path: "items"), withDestinationURL: outside)
        XCTAssertThrowsError(try store.load())
        try FileManager.default.removeItem(at: store.root.appending(path: "staging"))
        try FileManager.default.createSymbolicLink(at: store.root.appending(path: "staging"), withDestinationURL: outside)
        XCTAssertThrowsError(try store.begin(itemID: "456"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    func testRemoveAndScanRejectForgedPathsAndIDs() throws {
        let download = try finishProject()
        let outside = temporaryRoot.appending(path: "outside")
        try Data("keep".utf8).write(to: outside)
        for path in [outside.path, store.root.path, store.root.appending(path: "items").path,
                     store.root.appending(path: "items/123/../../outside").path] {
            let forged = WorkshopDownload(id: "123", title: "Forged", directory: path, completedAt: download.completedAt)
            XCTAssertThrowsError(try store.remove(forged), path)
            XCTAssertThrowsError(try store.scan(forged), path)
        }
        let invalidID = WorkshopDownload(id: "../outside", title: "Forged", directory: outside.path,
                                        completedAt: download.completedAt)
        XCTAssertThrowsError(try store.remove(invalidID))
        XCTAssertEqual(try store.load(), [download])
        XCTAssertEqual(try Data(contentsOf: outside), Data("keep".utf8))
    }

    func testCompletedItemReplacedWithSymlinkCannotBeScannedOrRemoved() throws {
        let download = try finishProject()
        let directory = URL(filePath: download.directory)
        let outside = temporaryRoot.appending(path: "outside")
        try FileManager.default.moveItem(at: directory, to: outside)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside)

        XCTAssertEqual(try store.load(), [])
        XCTAssertThrowsError(try store.scan(download))
        XCTAssertThrowsError(try store.remove(download))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appending(path: "clip.mp4").path))
    }

    func testDiscardRejectsRootItemsExternalAndNonOperationDirectories() throws {
        let download = try finishProject()
        let outside = temporaryRoot.appending(path: "outside")
        try writeProject(at: outside)
        for path in [store.root, store.root.appending(path: "staging"), URL(filePath: download.directory),
                     outside, store.root.appending(path: "staging/not-a-uuid/123")] {
            XCTAssertThrowsError(try store.discard(staging: path), path.path)
            XCTAssertThrowsError(try store.finish(itemID: "123", title: "Forged", staging: path), path.path)
        }
        XCTAssertEqual(try store.load(), [download])
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appending(path: "clip.mp4").path))
    }

    func testExplicitRemoveAndDiscardOnlyDeleteTheirOwnProject() throws {
        let removed = try finishProject()
        let retained = try finishProject(id: "456")
        let discarded = try store.begin(itemID: "789")
        try writeProject(at: discarded)
        let untouched = try store.begin(itemID: "789")

        try store.discard(staging: discarded)
        try store.remove(removed)

        XCTAssertFalse(FileManager.default.fileExists(atPath: discarded.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: removed.directory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: untouched.path))
        XCTAssertEqual(try store.load(), [retained])
    }

    private func finishProject(id: String = "123") throws -> WorkshopDownload {
        let staging = try store.begin(itemID: id)
        try writeProject(at: staging)
        return try store.finish(itemID: id, title: "Fixture", staging: staging)
    }

    private func writeProject(at directory: URL, file: String = "clip.mp4") throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["title": "Fixture", "file": file])
            .write(to: directory.appending(path: "project.json"))
        try Data("fixture".utf8).write(to: directory.appending(path: file))
    }
}
