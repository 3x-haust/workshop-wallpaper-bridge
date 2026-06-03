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
        XCTAssertTrue(viewModel.contains("Installed and selected Workshop Wallpaper Bridge Screen Saver"))
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
        XCTAssertFalse(source.contains("@\"Workshop Wallpaper Bridge has no playable Screen Saver media selected.\""))
    }

    func testScreenSaverReadsConfigurationFromRealUserHomeOutsideLegacyHostContainer() throws {
        let source = try String(
            contentsOfFile: "Sources/WorkshopWallpaperLockScreenSaver/WorkshopWallpaperLockScreenSaverView.m"
        )

        XCTAssertTrue(source.contains("#import <pwd.h>"))
        XCTAssertTrue(source.contains("#import <unistd.h>"))
        XCTAssertTrue(source.contains("- (NSArray<NSURL *> *)configurationURLs"))
        XCTAssertTrue(source.contains("- (NSURL *)realHomeApplicationSupportURL"))
        XCTAssertTrue(source.contains("getpwuid(getuid())"))
        XCTAssertTrue(source.contains("Library/Application Support"))
        XCTAssertTrue(source.contains("[self configurationURLFromApplicationSupport:realHomeApplicationSupport]"))
    }

    func testScreenSaverFallbackLayerUsesNonzeroBackingScale() throws {
        let source = try String(
            contentsOfFile: "Sources/WorkshopWallpaperLockScreenSaver/WorkshopWallpaperLockScreenSaverView.m"
        )

        XCTAssertTrue(source.contains("- (CGFloat)backingScaleFactor"))
        XCTAssertTrue(source.contains("self.window.screen.backingScaleFactor"))
        XCTAssertTrue(source.contains("return 1.0"))
        XCTAssertTrue(source.contains("self.fallbackLayer.contentsScale = [self backingScaleFactor]"))
        XCTAssertFalse(source.contains("NSScreen.mainScreen.backingScaleFactor"))
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

    func testScreenSaverViewHasAppKitDrawingFallbackForLegacyHosts() throws {
        let source = try String(
            contentsOfFile: "Sources/WorkshopWallpaperLockScreenSaver/WorkshopWallpaperLockScreenSaverView.m"
        )

        XCTAssertTrue(source.contains("@property(nonatomic, strong) NSImage *fallbackImage"))
        XCTAssertTrue(source.contains("@property(nonatomic, copy) NSString *fallbackDisplayMode"))
        XCTAssertTrue(source.contains("@property(nonatomic, copy) NSString *fallbackMessage"))
        XCTAssertTrue(source.contains("- (void)drawRect:(NSRect)rect"))
        XCTAssertTrue(source.contains("[NSColor.blackColor setFill]"))
        XCTAssertTrue(source.contains("[self.fallbackImage drawInRect:"))
        XCTAssertTrue(source.contains("[self.fallbackMessage drawInRect:"))
        XCTAssertTrue(source.contains("[self fallbackImageRectForImageSize:self.fallbackImage.size displayMode:self.fallbackDisplayMode]"))
        XCTAssertTrue(source.contains("self.fallbackImage = image"))
        XCTAssertTrue(source.contains("self.fallbackDisplayMode = displayMode"))
        XCTAssertTrue(source.contains("self.fallbackMessage = nil"))
        XCTAssertTrue(source.contains("self.fallbackImage = nil"))
        XCTAssertTrue(source.contains("self.fallbackMessage = [NSString stringWithFormat:"))
        XCTAssertTrue(source.contains("self.layer.contents = (__bridge id)cgImage"))
        XCTAssertTrue(source.contains("self.layer.contentsGravity = [self contentsGravityForDisplayMode:displayMode]"))
        XCTAssertTrue(source.contains("self.layer.contents = nil"))
        XCTAssertTrue(source.contains("[self setNeedsDisplay:YES]"))
    }
}
