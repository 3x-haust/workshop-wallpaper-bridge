import Darwin
import Foundation
import XCTest
@testable import WorkshopWallpaperBridgeApp

@MainActor
final class SteamHelperClientTests: XCTestCase {
    func testSubprocessDeliversTypedEventAndStopsBeforeReturning() async throws {
        let root = try temporaryDirectory()
        let script = try executable(in: root, body: """
        IFS= read -r request
        printf '%s\\n' '{"id":"test","type":"authenticated","account":"fixture"}'
        while IFS= read -r request; do :; done
        """)
        let client = SteamHelperClient(executable: script, authenticationDirectory: root.appending(path: "Steam"))
        var events: [SteamEvent] = []
        var exited = false
        client.onEvent = { events.append($0) }
        client.onExit = { exited = true }
        try client.send(SteamCommand(id: "test", command: "resume"))
        await waitUntil { events.count == 1 }
        XCTAssertEqual(events.first?.account, "fixture")
        await client.stop()
        XCTAssertTrue(exited)
    }

    func testMalformedHelperOutputClosesConnectionWithoutExposingRawText() async throws {
        let root = try temporaryDirectory()
        let script = try executable(in: root, body: """
        IFS= read -r request
        printf '%s\\n' 'synthetic-sensitive-diagnostic'
        while IFS= read -r request; do :; done
        """)
        let client = SteamHelperClient(executable: script, authenticationDirectory: root.appending(path: "Steam"))
        var count = 0
        var exited = false
        client.onEvent = { _ in count += 1 }
        client.onExit = { exited = true }
        try client.send(SteamCommand(id: "test", command: "resume"))
        await waitUntil { exited }
        XCTAssertEqual(count, 0)
        await client.stop()
    }

    func testSearchFiltersEncodeAsOptionalServerFields() throws {
        let command = SteamCommand(id: "search", command: "search", query: "sky", page: 1,
                                   sort: "rated", kind: "video", genre: "Sci-Fi")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(command)) as? [String: Any])
        XCTAssertEqual(json["sort"] as? String, "rated")
        XCTAssertEqual(json["kind"] as? String, "video")
        XCTAssertEqual(json["genre"] as? String, "Sci-Fi")
        let legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(SteamCommand(id: "old", command: "search"))) as? [String: Any])
        XCTAssertNil(legacy["sort"])
        XCTAssertNil(legacy["kind"])
        XCTAssertNil(legacy["genre"])
    }

    func testCreatorAndTagsDecodeWithoutBreakingOlderMetadata() throws {
        let current = Data(#"{"id":"1","title":"Fixture","description":"","creatorID":"76561198000000000","tags":["Nature","Video"]}"#.utf8)
        let item = try JSONDecoder().decode(WorkshopItem.self, from: current)
        XCTAssertEqual(item.creatorID, "76561198000000000")
        XCTAssertEqual(item.tags, ["Nature", "Video"])
        let legacy = try JSONDecoder().decode(WorkshopItem.self, from: Data(#"{"id":"1","title":"Fixture","description":""}"#.utf8))
        XCTAssertNil(legacy.creatorID)
        XCTAssertNil(legacy.tags)
    }

    func testMissingHelperIsARecoverableErrorNotAClaimedLogin() throws {
        let root = try temporaryDirectory()
        let client = SteamHelperClient(executable: root.appending(path: "absent"), authenticationDirectory: root)
        XCTAssertThrowsError(try client.send(SteamCommand(id: "test", command: "resume")))
    }

    private func executable(in root: URL, body: String) throws -> URL {
        let url = root.appending(path: "test-helper")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func temporaryDirectory() throws -> URL {
        let path = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(path) }
        let root = URL(filePath: String(cString: path)).appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(predicate(), "Expected helper lifecycle event", file: file, line: line)
    }
}
