import XCTest

final class ScreenSaverFeatureTests: XCTestCase {
    func testScreenSaverSettingsOpenUsesWallpaperSettingsPane() throws {
        let source = try String(contentsOfFile: "Sources/WorkshopWallpaperBridgeApp/LockScreenAnimationController.swift")

        XCTAssertTrue(source.contains("x-apple.systempreferences:com.apple.Wallpaper-Settings.extension"))
        XCTAssertFalse(source.contains("x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension"))
    }

    func testScreenSaverControlsUseScreenSaverLanguage() throws {
        let contentView = try String(contentsOfFile: "Sources/WorkshopWallpaperBridgeApp/ContentView.swift")
        let statusMenu = try String(contentsOfFile: "Sources/WorkshopWallpaperBridgeApp/StatusMenu.swift")
        let viewModel = try String(contentsOfFile: "Sources/WorkshopWallpaperBridgeApp/AppViewModel.swift")

        XCTAssertTrue(contentView.contains("Animate Screen Saver"))
        XCTAssertTrue(statusMenu.contains("Animate Screen Saver"))
        XCTAssertTrue(viewModel.contains("Installed the Screen Saver"))
        XCTAssertFalse(contentView.contains("Animate Lock Screen"))
        XCTAssertFalse(statusMenu.contains("Animate Lock Screen"))
        XCTAssertFalse(viewModel.contains("Animated Lock Screen"))
    }

    func testScreenSaverViewShowsFallbackInsteadOfBlackOnlyContent() throws {
        let source = try String(
            contentsOfFile: "Sources/WorkshopWallpaperLockScreenSaver/WorkshopWallpaperLockScreenSaverView.m"
        )

        XCTAssertTrue(source.contains("showFallbackMessage"))
        XCTAssertTrue(source.contains("Workshop Wallpaper Bridge"))
        XCTAssertTrue(source.contains("Choose it in Wallpaper settings"))
    }

    func testScreenSaverKeepsStillFallbackVisibleBehindVideoPlayback() throws {
        let source = try String(
            contentsOfFile: "Sources/WorkshopWallpaperLockScreenSaver/WorkshopWallpaperLockScreenSaverView.m"
        )

        XCTAssertTrue(source.contains("showVideoAtURL:[NSURL fileURLWithPath:sourcePath] fallbackImageURL:"))
        XCTAssertTrue(source.contains("- (void)showVideoAtURL:(NSURL *)url fallbackImageURL:(NSURL *)fallbackImageURL"))
        XCTAssertTrue(source.contains("if (hasFallbackImage) {\n        [self showImageAtURL:fallbackImageURL displayMode:displayMode];"))
        XCTAssertTrue(source.contains("self.playerLayer.hidden = hasFallbackImage"))
        XCTAssertTrue(source.contains("if (self.observedPlayerItem.status == AVPlayerItemStatusReadyToPlay)"))
        XCTAssertTrue(source.contains("[self revealVideoPlayback]"))
        XCTAssertTrue(source.contains("if (self.observedPlayerItem.status == AVPlayerItemStatusFailed)"))
        XCTAssertTrue(source.contains("self.playerLayer.hidden = YES"))
        XCTAssertTrue(source.contains("dispatch_async(dispatch_get_main_queue()"))
        XCTAssertTrue(source.contains("WorkshopWallpaperPlayerItemStatusContext"))
    }
}
