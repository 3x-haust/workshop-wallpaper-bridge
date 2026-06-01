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
}
