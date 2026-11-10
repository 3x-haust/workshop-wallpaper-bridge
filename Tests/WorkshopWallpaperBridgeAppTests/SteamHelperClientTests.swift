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
