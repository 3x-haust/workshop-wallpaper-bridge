import AppKit
import SwiftUI

@main
struct WorkshopWallpaperBridgeApplication: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appDelegate
    @StateObject private var model = AppViewModel()

    var body: some Scene {
        MenuBarExtra {
            StatusMenu(model: model)
        } label: {
            MenuBarIcon {
                SettingsWindowCoordinator.shared.show(model: model)
            }
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

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

private struct MenuBarIcon: View {
    let openSettings: @MainActor () -> Void
    @State private var didOpenInitialSettings = false

    var body: some View {
        Image(systemName: "photo.on.rectangle.angled")
            .accessibilityLabel("Workshop Wallpaper Bridge")
            .task {
                openInitialSettings()
            }
    }

    @MainActor
    private func openInitialSettings() {
        guard !didOpenInitialSettings else {
            return
        }
        didOpenInitialSettings = true
        openSettings()
    }
}
