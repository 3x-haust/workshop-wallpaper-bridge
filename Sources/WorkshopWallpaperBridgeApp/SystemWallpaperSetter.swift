import AppKit
import WorkshopWallpaperCore

@MainActor
struct SystemWallpaperSetter {
    func setStillWallpaper(from asset: WallpaperAsset) throws -> URL {
        guard let url = stillImageURL(for: asset) else {
            throw SystemWallpaperError.noStillImage
        }
        for screen in NSScreen.screens {
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
        }
        return url
    }

    private func stillImageURL(for asset: WallpaperAsset) -> URL? {
        if let thumbnail = asset.thumbnail, isSupportedImage(thumbnail) {
            return URL(filePath: thumbnail)
        }
        if asset.kind == .image, let entrypoint = asset.entrypoint, isSupportedImage(entrypoint) {
            return URL(filePath: entrypoint)
        }
        return nil
    }

    private func isSupportedImage(_ path: String) -> Bool {
        imageExtensions.contains(URL(filePath: path).pathExtension.lowercased())
    }
}

private enum SystemWallpaperError: Error, LocalizedError {
    case noStillImage

    var errorDescription: String? {
        switch self {
        case .noStillImage:
            return "No still preview image was found for this project."
        }
    }
}

private let imageExtensions = ["jpg", "jpeg", "png", "heic"]
