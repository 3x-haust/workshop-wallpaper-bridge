import AppKit
import CoreGraphics

struct DesktopVisibilityMonitor {
    func isDesktopVisible() -> Bool {
        !hasUserWindowAboveDesktop()
    }

    private func hasUserWindowAboveDesktop() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return false
        }
        return windows.contains(where: isBlockingWindow)
    }

    private func isBlockingWindow(_ window: [String: Any]) -> Bool {
        guard layer(window) == 0, alpha(window) > 0.05, boundsArea(window) > 12_000 else {
            return false
        }
        if isCurrentProcessWindow(window) {
            return false
        }
        let owner = ownerName(window)
        return !ignoredOwners.contains(owner)
    }

    private func isCurrentProcessWindow(_ window: [String: Any]) -> Bool {
        guard let pid = window[kCGWindowOwnerPID as String] as? Int else {
            return false
        }
        return pid == Int(ProcessInfo.processInfo.processIdentifier)
    }

    private func layer(_ window: [String: Any]) -> Int {
        window[kCGWindowLayer as String] as? Int ?? Int.max
    }

    private func alpha(_ window: [String: Any]) -> Double {
        window[kCGWindowAlpha as String] as? Double ?? 1
    }

    private func ownerName(_ window: [String: Any]) -> String {
        window[kCGWindowOwnerName as String] as? String ?? ""
    }

    private func boundsArea(_ window: [String: Any]) -> Double {
        guard let bounds = window[kCGWindowBounds as String] as? [String: Any] else {
            return 0
        }
        let width = bounds["Width"] as? Double ?? 0
        let height = bounds["Height"] as? Double ?? 0
        return width * height
    }
}

private let ignoredOwners = [
    "Window Server",
    "Dock",
    "Control Center",
    "Notification Center",
    "SystemUIServer"
]
