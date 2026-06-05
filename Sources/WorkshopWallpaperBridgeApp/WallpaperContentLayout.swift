import AVFoundation
import CoreGraphics
import QuartzCore

enum WallpaperDisplayMode: String, CaseIterable, Codable, Identifiable {
    case fit
    case fill
    case stretch

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .fit:
            return "Fit"
        case .fill:
            return "Fill"
        case .stretch:
            return "Stretch"
        }
    }
}

enum WallpaperContentLayout {
    static func contentFrame(for windowFrame: CGRect) -> CGRect {
        CGRect(origin: .zero, size: windowFrame.size)
    }

    static func videoGravity(for mode: WallpaperDisplayMode) -> AVLayerVideoGravity {
        switch mode {
        case .fit:
            return .resizeAspect
        case .fill:
            return .resizeAspectFill
        case .stretch:
            return .resize
        }
    }

    static func imageContentsGravity(for mode: WallpaperDisplayMode) -> CALayerContentsGravity {
        switch mode {
        case .fit:
            return .resizeAspect
        case .fill:
            return .resizeAspectFill
        case .stretch:
            return .resize
        }
    }

    static func scaledContentFrame(
        for contentSize: CGSize,
        in bounds: CGRect,
        displayMode: WallpaperDisplayMode
    ) -> CGRect {
        guard contentSize.width > 0, contentSize.height > 0,
              bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        switch displayMode {
        case .fit:
            let scale = min(bounds.width / contentSize.width, bounds.height / contentSize.height)
            return centeredFrame(contentSize: contentSize, scaleX: scale, scaleY: scale, in: bounds)
        case .fill:
            let scale = max(bounds.width / contentSize.width, bounds.height / contentSize.height)
            return centeredFrame(contentSize: contentSize, scaleX: scale, scaleY: scale, in: bounds)
        case .stretch:
            return bounds
        }
    }

    private static func centeredFrame(
        contentSize: CGSize,
        scaleX: CGFloat,
        scaleY: CGFloat,
        in bounds: CGRect
    ) -> CGRect {
        let width = contentSize.width * scaleX
        let height = contentSize.height * scaleY
        return CGRect(
            x: bounds.midX - (width / 2),
            y: bounds.midY - (height / 2),
            width: width,
            height: height
        )
    }
}
