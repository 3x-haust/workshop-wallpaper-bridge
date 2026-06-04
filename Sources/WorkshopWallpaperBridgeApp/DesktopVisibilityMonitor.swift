import AppKit
import CoreGraphics

struct DesktopVisibilityMonitor {
    func isDesktopVisible() -> Bool {
        Self.isDesktopVisible(
            windows: windowSnapshots(),
            currentProcessId: Int(ProcessInfo.processInfo.processIdentifier),
            screenFrames: NSScreen.screens.map(\.frame)
        )
    }

    static func isDesktopVisible(
        windows: [WindowSnapshot],
        currentProcessId: Int,
        screenFrames: [CGRect] = []
    ) -> Bool {
        !windows.contains {
            isBlockingWindow($0, currentProcessId: currentProcessId, screenFrames: screenFrames)
        }
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

    private static func isBlockingWindow(
        _ window: WindowSnapshot,
        currentProcessId: Int,
        screenFrames: [CGRect]
    ) -> Bool {
        guard window.layer == 0, window.alpha > 0.05, window.bounds.area > 12_000 else {
            return false
        }
        if window.processId == currentProcessId {
            return false
        }
        if isFinderDesktopHost(window) {
            return false
        }
        if isSmallDesktopOverlay(window, screenFrames: screenFrames) {
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

    private static func isSmallDesktopOverlay(_ window: WindowSnapshot, screenFrames: [CGRect]) -> Bool {
        guard max(window.bounds.width, window.bounds.height) <= 240 else {
            return false
        }
        return screenFrames.contains { screen in
            abs(window.bounds.minX - screen.minX) <= 80 || abs(window.bounds.maxX - screen.maxX) <= 80
        }
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
    "AirPlayUIAgent",
    "Continuity",
    "Continuity Camera",
    "Window Server",
    "Dock",
    "Control Center",
    "ControlCenter",
    "ContinuityCaptureAgent",
    "Handoff",
    "WindowManager",
    "Notification Center",
    "SystemUIServer"
]
