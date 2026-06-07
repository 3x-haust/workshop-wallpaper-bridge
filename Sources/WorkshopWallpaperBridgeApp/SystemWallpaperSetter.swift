import AppKit
import WorkshopWallpaperCore

@MainActor
struct SystemWallpaperSetter {
    private let resolveStillImage: @MainActor (WallpaperAsset) throws -> URL
    private let setDesktopImage: @MainActor (URL) throws -> Void
    private let setLockScreenImage: @MainActor (URL) throws -> URL?

    init(
        resolveStillImage: @escaping @MainActor (WallpaperAsset) throws -> URL = {
            try StillWallpaperImageProvider().stillImageURL(for: $0)
        },
        setDesktopImage: @escaping @MainActor (URL) throws -> Void = Self.setDesktopImageOnAllScreens,
        setLockScreenImage: @escaping @MainActor (URL) throws -> URL? = { url in
            try LockScreenWallpaperCache().writeLockScreenImage(from: url)
        }
    ) {
        self.resolveStillImage = resolveStillImage
        self.setDesktopImage = setDesktopImage
        self.setLockScreenImage = setLockScreenImage
    }

    func setStillWallpaper(from asset: WallpaperAsset) throws -> StillWallpaperResult {
        let url = try resolveStillImage(asset)
        try setDesktopImage(url)
        do {
            return StillWallpaperResult(
                imageURL: url,
                lockScreenCacheURL: try setLockScreenImage(url),
                lockScreenErrorDescription: nil
            )
        } catch {
            return StillWallpaperResult(
                imageURL: url,
                lockScreenCacheURL: nil,
                lockScreenErrorDescription: error.localizedDescription
            )
        }
    }

    private static func setDesktopImageOnAllScreens(_ url: URL) throws {
        for screen in NSScreen.screens {
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
        }
    }
}

struct StillWallpaperResult: Equatable {
    let imageURL: URL
    let lockScreenCacheURL: URL?
    let lockScreenErrorDescription: String?
}

struct LockScreenWallpaperCache {
    func writeLockScreenImage(from imageURL: URL) throws -> URL {
        let generatedUID = try currentUserGeneratedUID()
        let output = Self.cacheFileURL(generatedUID: generatedUID)
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        let data = try pngData(from: imageURL)
        try data.write(to: output, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: output.path)
        return output
    }

    static func cacheFileURL(generatedUID: String) -> URL {
        URL(filePath: "/Library/Caches/Desktop Pictures")
            .appending(path: generatedUID)
            .appending(path: "lockscreen.png")
    }

    private func currentUserGeneratedUID() throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/dscl")
        process.arguments = [".", "-read", "/Users/\(NSUserName())", "GeneratedUID"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SystemWallpaperError.lockScreenCacheUnavailable
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            throw SystemWallpaperError.lockScreenCacheUnavailable
        }
        guard let uid = output.split(separator: " ").last?.trimmingCharacters(in: .whitespacesAndNewlines),
              !uid.isEmpty else {
            throw SystemWallpaperError.lockScreenCacheUnavailable
        }
        return uid
    }

    func pngData(from imageURL: URL) throws -> Data {
        guard let image = NSImage(contentsOf: imageURL),
              let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff),
              let data = representation.representation(using: .png, properties: [:]) else {
            throw SystemWallpaperError.noStillImage
        }
        return data
    }
}

enum SystemWallpaperError: Error, LocalizedError {
    case noStillImage
    case conversionRequiredForStillImage
    case lockScreenCacheUnavailable

    var errorDescription: String? {
        switch self {
        case .noStillImage:
            return "No still preview image was found for this project."
        case .conversionRequiredForStillImage:
            return "Convert this video to MP4, MOV, or M4V before setting a still wallpaper."
        case .lockScreenCacheUnavailable:
            return "The macOS Lock Screen wallpaper cache is not available."
        }
    }
}
