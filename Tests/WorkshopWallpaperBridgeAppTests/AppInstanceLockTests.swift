import Foundation
import XCTest
@testable import WorkshopWallpaperBridgeApp

final class AppInstanceLockTests: XCTestCase {
    func testSecondInstanceCannotAcquireHeldLock() {
        // Given
        let lockPath = temporaryLockPath()
        let first = AppInstanceLock(lockPath: lockPath)
        let second = AppInstanceLock(lockPath: lockPath)

        // Then
        XCTAssertTrue(first.acquire())
        XCTAssertFalse(second.acquire())
    }

    func testLockCanBeAcquiredAfterFirstInstanceReleasesIt() {
        // Given
        let lockPath = temporaryLockPath()
        var first: AppInstanceLock? = AppInstanceLock(lockPath: lockPath)

        // When
        XCTAssertTrue(first?.acquire() ?? false)
        first = nil
        let second = AppInstanceLock(lockPath: lockPath)

        // Then
        XCTAssertTrue(second.acquire())
    }

    func testOpenFailureDoesNotAcquireLock() {
        // Given
        let lock = AppInstanceLock(lockPath: NSTemporaryDirectory())

        // Then
        XCTAssertFalse(lock.acquire())
    }

    private func temporaryLockPath() -> String {
        let filename = "wwb-\(UUID().uuidString).lock"
        return URL(filePath: NSTemporaryDirectory())
            .appending(path: filename)
            .path
    }
}
