import AppKit
import Foundation
import WorkshopWallpaperCore

/// "Play as the system wallpaper" (macOS 26+): the bundled wallpaper extension draws the
/// video for WallpaperAgent, so it keeps playing where macOS hides ordinary windows
/// (dragging a desktop widget, editing widgets, revealing the desktop).
@MainActor
final class SystemWallpaperMode {
    enum ModeError: LocalizedError {
        case notConfirmed

        var errorDescription: String? {
            switch self {
            case .notConfirmed:
                "macOS didn't start the wallpaper extension, so the app keeps drawing the wallpaper itself."
            }
        }
    }

    private let library: SystemWallpaperExtensionLibrary
    private let storeURL: URL
    private let backupURL: URL
    private let restartAgent: @MainActor () throws -> Void
    private let resolveVideo: @MainActor (WallpaperAsset) async -> URL?
    private let displayNumbers: @MainActor () -> [String: UInt32]
    private let fileManager = FileManager.default

    init(
        library: SystemWallpaperExtensionLibrary = SystemWallpaperExtensionLibrary(
            documentsURL: SystemWallpaperExtensionLibrary.containerDocuments()
        ),
        storeURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/com.apple.wallpaper/Store/Index.plist"),
        backupURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "WorkshopWallpaperBridge/SystemWallpaper/Index.before-system-wallpaper.plist"),
        restartAgent: @escaping @MainActor () throws -> Void = SystemWallpaperMode.restartWallpaperAgent,
        resolveVideo: @escaping @MainActor (WallpaperAsset) async -> URL? = SystemWallpaperMode.playableVideo(for:),
        displayNumbers: @escaping @MainActor () -> [String: UInt32] = SystemWallpaperMode.connectedDisplayNumbers
    ) {
        self.library = library
        self.storeURL = storeURL
        self.backupURL = backupURL
        self.restartAgent = restartAgent
        self.resolveVideo = resolveVideo
        self.displayNumbers = displayNumbers
    }

    /// Whether this Mac can host the extension and this build carries it.
    static var isAvailable: Bool {
        guard #available(macOS 26, *) else { return false }
        let appex = Bundle.main.bundleURL.appending(path: "Contents/Extensions/\(extensionBundleName)")
        return FileManager.default.fileExists(atPath: appex.path)
    }

    static let extensionBundleName = "Workshop Wallpaper Bridge Wallpaper.appex"

    /// The video the extension can play for an asset: a video wallpaper (after the same
    /// container repair the app's player uses) or a scene's rendered video, once it exists.
    static func playableVideo(for asset: WallpaperAsset) async -> URL? {
        guard let entrypoint = asset.entrypoint else { return nil }
        let url = URL(filePath: entrypoint)
        switch asset.kind {
        case .video:
            guard ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) else { return nil }
            return (try? await VideoPlaybackPreparation.prepare(url: url, assetID: asset.id)) ?? url
        case .scene:
            return SceneVideoCache.freshCachedVideoURL(assetId: asset.id, sourceURL: url)
        default:
            return nil
        }
    }

    /// Hands the displays whose wallpaper has a playable video to the extension. Returns the
    /// displays it now draws; the app keeps drawing the rest. Displays it drew before but
    /// no longer gets go back to what they were before this mode started.
    func apply(_ playing: [String: WallpaperAsset]) async throws -> Set<String> {
        var choices: [String: SystemWallpaperStore.Choice] = [:]
        try library.prepareDocuments()
        try library.writePreferences(paused: false)
        for (displayID, asset) in playing {
            guard let video = await resolveVideo(asset) else { continue }
            choices[displayID] = try library.publish(videoURL: video, assetID: asset.id, title: asset.title)
        }
        guard !choices.isEmpty else {
            try restore()
            return []
        }
        SystemWallpaperExtensionLibrary.post(SystemWallpaperExtensionLibrary.libraryChangedNotification)

        let originalData = try Data(contentsOf: storeURL)
        var root = try SystemWallpaperStore.decode(originalData)
        let provided = SystemWallpaperStore.providedDisplays(in: root)
        let numbers = displayNumbers()
        let rendered = library.renderedChoices()
        let alreadyServed = choices.allSatisfy { displayID, choice in
            provided[displayID] == choice.choiceID && numbers[displayID].map { rendered[$0] == choice.choiceID } == true
        }
        if alreadyServed, Set(provided.keys) == Set(choices.keys) {
            library.prune(keeping: Set(choices.values.map(\.choiceID)))
            return Set(choices.keys)
        }

        if !SystemWallpaperStore.usesProvider(root) {
            try fileManager.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try originalData.write(to: backupURL, options: .atomic)
        }
        let dropped = Set(provided.keys).subtracting(choices.keys)
        if !dropped.isEmpty, let backup = try? SystemWallpaperStore.decode(Data(contentsOf: backupURL)) {
            root = SystemWallpaperStore.restoring(displays: dropped, from: backup, in: root)
        }
        let mainDisplayID = NSScreen.main.flatMap(Self.displayID(for:))
        let updated = try SystemWallpaperStore.selecting(
            choices, in: root, connectedDisplayIDs: Set(numbers.keys), mainDisplayID: mainDisplayID
        )
        try SystemWallpaperStore.encode(updated).write(to: storeURL, options: .atomic)
        try restartAgent()

        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(250))
            let rendered = library.renderedChoices()
            if choices.allSatisfy({ displayID, choice in numbers[displayID].map { rendered[$0] == choice.choiceID } == true }) {
                library.prune(keeping: Set(choices.values.map(\.choiceID)))
                return Set(choices.keys)
            }
        }
        try originalData.write(to: storeURL, options: .atomic)
        try? restartAgent()
        throw ModeError.notConfirmed
    }

    /// Gives every desktop this mode took back what it had before. Desktops the user
    /// changed since then are left alone.
    func restore() throws {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let root = try SystemWallpaperStore.decode(data)
        guard SystemWallpaperStore.usesProvider(root) else {
            try? fileManager.removeItem(at: backupURL)
            library.prune(keeping: [])
            return
        }
        let backup = (try? Data(contentsOf: backupURL)).flatMap { try? SystemWallpaperStore.decode($0) } ?? [:]
        let restored = SystemWallpaperStore.restoringAll(from: backup, in: root)
        try SystemWallpaperStore.encode(restored).write(to: storeURL, options: .atomic)
        try restartAgent()
        try? fileManager.removeItem(at: backupURL)
        library.prune(keeping: [])
    }

    static func displayID(for screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(nil, uuid) as String
    }

    static func connectedDisplayNumbers() -> [String: UInt32] {
        var result: [String: UInt32] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let id = displayID(for: screen) else { continue }
            result[id] = number.uint32Value
        }
        return result
    }

    nonisolated static func restartWallpaperAgent() throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/killall")
        process.arguments = ["WallpaperAgent"]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }
}

extension SystemWallpaperStore {
    /// `current` with the given displays' nodes (and their Space overrides) taken from `backup`.
    static func restoring(displays: Set<String>, from backup: [String: Any], in current: [String: Any]) -> [String: Any] {
        var root = current
        var nodes = root["Displays"] as? [String: Any] ?? [:]
        let backupNodes = backup["Displays"] as? [String: Any] ?? [:]
        for id in displays {
            nodes[id] = backupNodes[id] ?? sharedFallback(from: backup)
        }
        root["Displays"] = nodes
        if var spaces = root["Spaces"] as? [String: Any] {
            let backupSpaces = backup["Spaces"] as? [String: Any] ?? [:]
            for (spaceID, value) in spaces {
                guard var space = value as? [String: Any], var spaceNodes = space["Displays"] as? [String: Any] else {
                    continue
                }
                let old = ((backupSpaces[spaceID] as? [String: Any])?["Displays"] as? [String: Any]) ?? [:]
                for id in displays where spaceNodes[id] != nil {
                    spaceNodes[id] = old[id]
                }
                space["Displays"] = spaceNodes
                spaces[spaceID] = space
            }
            root["Spaces"] = spaces
        }
        return root
    }

    /// `current` with every node this app's extension provides put back as in `backup`.
    static func restoringAll(from backup: [String: Any], in current: [String: Any]) -> [String: Any] {
        var root = current
        let ours = providedDisplays(in: current)
        root = restoring(displays: Set(ours.keys), from: backup, in: root)
        for key in ["SystemDefault", "AllSpacesAndDisplays"] {
            let node = root[key] as? [String: Any]
            if node.map({ choiceID(in: $0) != nil }) == true || (key == "AllSpacesAndDisplays"
                && node?["Desktop"] == nil && node?["Linked"] == nil && backup[key] != nil) {
                root[key] = backup[key]
            }
        }
        if var spaces = root["Spaces"] as? [String: Any] {
            let backupSpaces = backup["Spaces"] as? [String: Any] ?? [:]
            for (spaceID, value) in spaces {
                guard var space = value as? [String: Any] else { continue }
                if let node = space["Default"] as? [String: Any], choiceID(in: node) != nil {
                    space["Default"] = (backupSpaces[spaceID] as? [String: Any])?["Default"]
                }
                spaces[spaceID] = space
            }
            root["Spaces"] = spaces
        }
        // A display the backup didn't list follows the shared desktop again.
        if var nodes = root["Displays"] as? [String: Any] {
            for (id, value) in nodes {
                if let node = value as? [String: Any], choiceID(in: node) != nil { nodes[id] = nil }
            }
            root["Displays"] = nodes
        }
        return root
    }

    /// What a display without its own node showed before: the shared desktop, else the default.
    private static func sharedFallback(from backup: [String: Any]) -> Any? {
        for key in ["AllSpacesAndDisplays", "SystemDefault"] {
            guard let node = backup[key] as? [String: Any] else { continue }
            if ["Desktop", "Linked"].contains(where: { ((node[$0] as? [String: Any])?["Content"]) is [String: Any] }) {
                return node
            }
        }
        return nil
    }
}
