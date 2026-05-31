import AppKit
import SwiftUI

@main
struct WorkshopWallpaperBridgeApplication: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appDelegate
    @StateObject private var model = AppViewModel()

    var body: some Scene {
        WindowGroup("Workshop Wallpaper Bridge") {
            ContentView(model: model)
                .frame(minWidth: 980, minHeight: 640)
        }
        .commands {
            CommandMenu("Wallpaper") {
                Button("Stop Playback") {
                    model.stopPlayback()
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])
            }
        }
    }
}

final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidHide(_ notification: Notification) {
        restoreWallpaperWindows()
    }

    func applicationDidUnhide(_ notification: Notification) {
        restoreWallpaperWindows()
    }

    private func restoreWallpaperWindows() {
        Task { @MainActor in
            WallpaperPlayer.shared.restoreVisibleWindowsAfterAppWindowChange()
        }
    }
}
