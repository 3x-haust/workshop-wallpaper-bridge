import Foundation
import XCTest
@testable import WorkshopWallpaperBridgeApp

@MainActor
final class LockScreenAnimationControllerTests: XCTestCase {
    func testSetEnabledInstallsAndSelectsBundledScreenSaver() throws {
        // Given
        let root = try makeTempDirectory()
        let applicationSupport = root.appending(path: "ApplicationSupport")
        let screenSaverDirectory = root.appending(path: "Screen Savers")
        let bundle = try makeBundleWithScreenSaver(root: root)
        let selectionWriter = RecordingScreenSaverSelectionWriter()
        let controller = LockScreenAnimationController(
            applicationSupportDirectory: applicationSupport,
            screenSaverDirectory: screenSaverDirectory,
            bundle: bundle,
            screenSaverSelectionWriter: selectionWriter
        )

        // When
        try controller.setEnabled(true, activeAsset: nil, displayMode: .fit)

        // Then
        let installedURL = screenSaverDirectory.appending(path: "Workshop Wallpaper Bridge.saver")
        XCTAssertTrue(FileManager.default.fileExists(atPath: installedURL.path))
        XCTAssertEqual(selectionWriter.selectedModules, [
            ScreenSaverModuleSelection(
                moduleName: "Workshop Wallpaper Bridge",
                path: installedURL.path,
                type: 0
            )
        ])
    }

    func testOpenScreenSaverSettingsInstallsAndSelectsBeforeOpeningSettings() throws {
        // Given
        let root = try makeTempDirectory()
        let applicationSupport = root.appending(path: "ApplicationSupport")
        let screenSaverDirectory = root.appending(path: "Screen Savers")
        let bundle = try makeBundleWithScreenSaver(root: root)
        let selectionWriter = RecordingScreenSaverSelectionWriter()
        let settingsOpener = RecordingScreenSaverSettingsOpener()
        let controller = LockScreenAnimationController(
            applicationSupportDirectory: applicationSupport,
            screenSaverDirectory: screenSaverDirectory,
            bundle: bundle,
            screenSaverSelectionWriter: selectionWriter,
            screenSaverSettingsOpener: settingsOpener
        )

        // When
        try controller.openScreenSaverSettings()

        // Then
        let installedURL = screenSaverDirectory.appending(path: "Workshop Wallpaper Bridge.saver")
        XCTAssertTrue(FileManager.default.fileExists(atPath: installedURL.path))
        XCTAssertEqual(selectionWriter.selectedModules.first?.path, installedURL.path)
        XCTAssertEqual(settingsOpener.openCount, 1)
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func makeBundleWithScreenSaver(root: URL) throws -> Bundle {
        let resources = root.appending(path: "Test.app/Contents/Resources")
        let saver = resources.appending(path: "Workshop Wallpaper Bridge.saver")
        try FileManager.default.createDirectory(at: saver, withIntermediateDirectories: true)
        let info = root.appending(path: "Test.app/Contents/Info.plist")
        try FileManager.default.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>CFBundleIdentifier</key>
          <string>dev.3xhaust.WorkshopWallpaperBridgeTests</string>
          <key>CFBundlePackageType</key>
          <string>APPL</string>
        </dict>
        </plist>
        """.utf8).write(to: info)
        return try XCTUnwrap(Bundle(url: root.appending(path: "Test.app")))
    }
}

private final class RecordingScreenSaverSelectionWriter: ScreenSaverSelectionWriting {
    var selectedModules: [ScreenSaverModuleSelection] = []

    func selectScreenSaver(_ selection: ScreenSaverModuleSelection) throws {
        selectedModules.append(selection)
    }
}

private final class RecordingScreenSaverSettingsOpener: ScreenSaverSettingsOpening {
    var openCount = 0

    func openScreenSaverSettings() {
        openCount += 1
    }
}
