import AppKit
import SwiftUI

@MainActor
final class SettingsWindowCoordinator {
    static let shared = SettingsWindowCoordinator()

    private let defaultWindowSize = CGSize(width: 640, height: 560)
    private var window: NSWindow?

    func show(model: AppViewModel) {
        if let window {
            center(window)
            showExisting(window)
            return
        }
        let window = makeWindow(model: model)
        self.window = window
        center(window)
        showExisting(window)
    }

    private func makeWindow(model: AppViewModel) -> NSWindow {
        let controller = NSHostingController(
            rootView: ContentView(model: model)
                .frame(minWidth: 640, minHeight: 560)
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: defaultWindowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Workshop Wallpaper Bridge Settings"
        window.contentViewController = controller
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        return window
    }

    private func center(_ window: NSWindow) {
        let fallback = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? window.frame
        let screenFrame = SettingsWindowPlacement.preferredScreenFrame(
            mouseLocation: NSEvent.mouseLocation,
            screenFrames: NSScreen.screens.map(\.visibleFrame),
            fallback: fallback
        )
        let frame = SettingsWindowPlacement.centeredFrame(
            windowSize: window.frame.size,
            minimumWindowSize: defaultWindowSize,
            screenFrame: screenFrame
        )
        window.setFrame(frame, display: true, animate: false)
    }

    private func showExisting(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
