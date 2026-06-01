import AppKit
import CoreGraphics

struct DesktopVisibilityMonitor {
    func isDesktopVisible() -> Bool {
        Self.isDesktopVisible(
            windows: windowSnapshots(),
            currentProcessId: Int(ProcessInfo.processInfo.processIdentifier)
        )
    }

    static func isDesktopVisible(windows: [WindowSnapshot], currentProcessId: Int) -> Bool {
        !windows.contains { isBlockingWindow($0, currentProcessId: currentProcessId) }
    }

    private func windowSnapshots() -> [WindowSnapshot] {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }
        return windows.map(WindowSnapshot.init)
    }

    private static func isBlockingWindow(_ window: WindowSnapshot, currentProcessId: Int) -> Bool {
        guard window.layer == 0, window.alpha > 0.05, window.bounds.area > 12_000 else {
            return false
        }
        if window.processId == currentProcessId {
            return false
        }
        if isFinderDesktopHost(window) {
            return false
        }
        return !ignoredOwners.contains(window.ownerName)
    }

    private static func isFinderDesktopHost(_ window: WindowSnapshot) -> Bool {
        guard window.ownerName == "Finder" else {
            return false
        }
        return window.bounds.width >= 1_000 && window.bounds.height >= 700
    }
}

extension DesktopVisibilityMonitor {
    struct WindowSnapshot {
        let ownerName: String
        let processId: Int?
        let layer: Int
        let alpha: Double
        let bounds: CGRect

        init(ownerName: String, processId: Int?, layer: Int, alpha: Double, bounds: CGRect) {
            self.ownerName = ownerName
            self.processId = processId
            self.layer = layer
            self.alpha = alpha
            self.bounds = bounds
        }

        init(_ window: [String: Any]) {
            ownerName = window[kCGWindowOwnerName as String] as? String ?? ""
            processId = window[kCGWindowOwnerPID as String] as? Int
            layer = window[kCGWindowLayer as String] as? Int ?? Int.max
            alpha = window[kCGWindowAlpha as String] as? Double ?? 1
            bounds = Self.cgRect(from: window[kCGWindowBounds as String] as? [String: Any])
        }

        private static func cgRect(from bounds: [String: Any]?) -> CGRect {
            guard let bounds else {
                return .zero
            }
            return CGRect(
                x: bounds["X"] as? Double ?? 0,
                y: bounds["Y"] as? Double ?? 0,
                width: bounds["Width"] as? Double ?? 0,
                height: bounds["Height"] as? Double ?? 0
            )
        }
    }
}

private extension CGRect {
    var area: Double {
        width * height
    }
}

private let ignoredOwners = [
    "Window Server",
    "Dock",
    "Control Center",
    "WindowManager",
    "Notification Center",
    "SystemUIServer"
]
