import Foundation

enum SettingsWindowPlacement {
    static func centeredFrame(
        windowSize: CGSize,
        minimumWindowSize: CGSize = .zero,
        screenFrame: CGRect
    ) -> CGRect {
        let targetWidth = max(windowSize.width, minimumWindowSize.width)
        let targetHeight = max(windowSize.height, minimumWindowSize.height)
        let width = min(targetWidth, screenFrame.width)
        let height = min(targetHeight, screenFrame.height)
        let originX = screenFrame.minX + ((screenFrame.width - width) / 2)
        let originY = screenFrame.minY + ((screenFrame.height - height) / 2)
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    static func preferredScreenFrame(mouseLocation: CGPoint, screenFrames: [CGRect], fallback: CGRect) -> CGRect {
        screenFrames.first { $0.contains(mouseLocation) } ?? fallback
    }
}
