import AppKit
import Foundation
import WorkshopWallpaperCore

@MainActor
protocol LockScreenAnimationManaging {
    func setEnabled(_ enabled: Bool, activeAsset: WallpaperAsset?, displayMode: WallpaperDisplayMode) throws
    func updateActiveAsset(_ asset: WallpaperAsset?, displayMode: WallpaperDisplayMode) throws
    func openScreenSaverSettings()
}

struct LockScreenAnimationController: LockScreenAnimationManaging {
    private let fileManager: FileManager
    private let applicationSupportDirectory: URL
    private let screenSaverDirectory: URL
    private let stillImageProvider: StillWallpaperImageProvider
    private let bundle: Bundle

    init(
        fileManager: FileManager = .default,
        applicationSupportDirectory: URL = Self.defaultApplicationSupportDirectory(),
        screenSaverDirectory: URL = Self.defaultScreenSaverDirectory(),
        stillImageProvider: StillWallpaperImageProvider = StillWallpaperImageProvider(),
        bundle: Bundle = .main
    ) {
        self.fileManager = fileManager
        self.applicationSupportDirectory = applicationSupportDirectory
        self.screenSaverDirectory = screenSaverDirectory
        self.stillImageProvider = stillImageProvider
        self.bundle = bundle
    }

    func setEnabled(_ enabled: Bool, activeAsset: WallpaperAsset?, displayMode: WallpaperDisplayMode) throws {
        if enabled {
            try installBundledScreenSaver()
        }
        try writeConfiguration(enabled: enabled, asset: activeAsset, displayMode: displayMode)
    }

    func updateActiveAsset(_ asset: WallpaperAsset?, displayMode: WallpaperDisplayMode) throws {
        try writeConfiguration(enabled: true, asset: asset, displayMode: displayMode)
    }

    func openScreenSaverSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")
        if let url, NSWorkspace.shared.open(url) {
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    private func installBundledScreenSaver() throws {
        guard let bundledURL = bundle.url(forResource: Self.screenSaverBundleName, withExtension: "saver") else {
            throw LockScreenAnimationError.bundledScreenSaverMissing
        }
        try fileManager.createDirectory(at: screenSaverDirectory, withIntermediateDirectories: true)
        let destination = screenSaverDirectory.appending(path: "\(Self.screenSaverBundleName).saver")
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: bundledURL, to: destination)
    }

    private func writeConfiguration(
        enabled: Bool,
        asset: WallpaperAsset?,
        displayMode: WallpaperDisplayMode
    ) throws {
        try fileManager.createDirectory(at: configurationDirectory, withIntermediateDirectories: true)
        let configuration = LockScreenAnimationConfiguration(
            enabled: enabled,
            title: asset?.title,
            displayMode: displayMode.rawValue,
            sourcePath: animatedVideoPath(for: asset),
            imagePath: stillImagePath(for: asset)
        )
        let data = try JSONEncoder().encode(configuration)
        try data.write(to: configurationURL, options: [.atomic])
    }

    private func animatedVideoPath(for asset: WallpaperAsset?) -> String? {
        guard let path = asset?.entrypoint,
              asset?.kind == .video,
              Self.screenSaverVideoExtensions.contains(URL(filePath: path).pathExtension.lowercased()) else {
            return nil
        }
        return path
    }

    private func stillImagePath(for asset: WallpaperAsset?) -> String? {
        guard let asset else {
            return nil
        }
        return try? stillImageProvider.stillImageURL(for: asset).path
    }

    private var configurationDirectory: URL {
        applicationSupportDirectory.appending(path: "LockScreen")
    }

    private var configurationURL: URL {
        configurationDirectory.appending(path: "active.json")
    }

    private static let screenSaverBundleName = "Workshop Wallpaper Bridge"
    private static let screenSaverVideoExtensions = ["mp4", "mov", "m4v"]

    private static func defaultApplicationSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base.appending(path: "WorkshopWallpaperBridge")
    }

    private static func defaultScreenSaverDirectory() -> URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base.appending(path: "Screen Savers")
    }
}

private struct LockScreenAnimationConfiguration: Codable {
    let enabled: Bool
    let title: String?
    let displayMode: String
    let sourcePath: String?
    let imagePath: String?
}

enum LockScreenAnimationError: Error, LocalizedError {
    case bundledScreenSaverMissing

    var errorDescription: String? {
        switch self {
        case .bundledScreenSaverMissing:
            return "The Screen Saver is missing. Install the packaged app from the DMG first."
        }
    }
}
