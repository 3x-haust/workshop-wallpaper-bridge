import CryptoKit
import Foundation

/// The files the sandboxed wallpaper extension reads, inside its own container:
/// `Documents/videos/<choice UUID>/<video>` plus `metadata.json` (the extension's
/// `VideoLibrary` format), the playback preferences, and the state it reports back.
struct SystemWallpaperExtensionLibrary {
    static let extensionBundleID = SystemWallpaperStore.providerID
    static let libraryChangedNotification = "\(extensionBundleID).libraryChanged"
    static let preferencesChangedNotification = "\(extensionBundleID).prefsChanged"

    let documentsURL: URL
    var fileManager: FileManager = .default

    static func containerDocuments(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: "Library/Containers/\(extensionBundleID)/Data/Documents", directoryHint: .isDirectory)
    }

    var videosURL: URL { documentsURL.appending(path: "videos", directoryHint: .isDirectory) }
    var preferencesURL: URL { documentsURL.appending(path: "driftwood-prefs.json") }
    var stateURL: URL { documentsURL.appending(path: "driftwood-state.json") }

    /// A stable choice per wallpaper, so replaying the same one needs no store change.
    static func choiceID(forAssetID assetID: String) -> String {
        var bytes = Array(SHA256.hash(data: Data("wwb-system-wallpaper:\(assetID)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return uuid.uuidString
    }

    /// Places the video where the extension can read it (an APFS clone, so no second copy
    /// on disk) and returns the choice the store should point at.
    func publish(videoURL: URL, assetID: String, title: String) throws -> SystemWallpaperStore.Choice {
        let choiceID = Self.choiceID(forAssetID: assetID)
        let directory = videosURL.appending(path: choiceID, directoryHint: .isDirectory)
        let ext = videoURL.pathExtension.lowercased()
        guard ["mp4", "mov", "m4v"].contains(ext) else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let filename = "wallpaper.\(ext)"
        let destination = directory.appending(path: filename)
        let source = try Fingerprint(url: videoURL)
        let metadataURL = directory.appending(path: "metadata.json")
        let current = (try? Data(contentsOf: metadataURL)).flatMap { try? JSONDecoder().decode(Entry.self, from: $0) }
        if current?.source != source || !fileManager.fileExists(atPath: destination.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let staged = directory.appending(path: ".incoming-\(UUID().uuidString).\(ext)")
            try fileManager.copyItem(at: videoURL, to: staged)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
            } else {
                try fileManager.moveItem(at: staged, to: destination)
            }
        }
        let entry = Entry(id: choiceID, name: title, filename: filename, kind: "video", duration: 0, fps: 0,
                          resolution: [0, 0], dateAdded: current?.dateAdded ?? Date(), source: source)
        if entry != current {
            let encoder = JSONEncoder()
            try encoder.encode(entry).write(to: metadataURL, options: .atomic)
        }
        return SystemWallpaperStore.Choice(choiceID: choiceID, resourceURL: destination)
    }

    /// Drops videos no display uses any more.
    func prune(keeping choiceIDs: Set<String>) {
        guard let entries = try? fileManager.contentsOfDirectory(at: videosURL, includingPropertiesForKeys: nil) else {
            return
        }
        for entry in entries where UUID(uuidString: entry.lastPathComponent) != nil
            && !choiceIDs.contains(entry.lastPathComponent) {
            try? fileManager.removeItem(at: entry)
        }
    }

    /// The app pauses its own wallpaper only when asked to, never on battery: match it.
    func writePreferences(paused: Bool) throws {
        let preferences = Preferences(userPaused: paused, alwaysPauseDesktop: false, pauseWhenOccluded: false,
                                      desktopOccluded: false, pauseOnBattery: false, playbackRate: 1,
                                      quality: "auto", nativeWallpaper: true)
        let data = try JSONEncoder().encode(preferences)
        if (try? Data(contentsOf: preferencesURL)) != data {
            try data.write(to: preferencesURL, options: .atomic)
        }
    }

    /// Choice IDs the extension reports it is drawing, per CG display number.
    func renderedChoices() -> [UInt32: String] {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(State.self, from: data),
              state.isActive else {
            return [:]
        }
        var result: [UInt32: String] = [:]
        for context in state.contexts ?? [] where context.isPreview != true {
            if let videoID = context.videoID { result[context.displayID] = videoID }
        }
        return result
    }

    func prepareDocuments() throws {
        try fileManager.createDirectory(at: videosURL, withIntermediateDirectories: true)
    }

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true
        )
    }

    struct Fingerprint: Codable, Equatable {
        let path: String
        let size: UInt64
        let modified: Date

        init(url: URL) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            path = url.standardizedFileURL.path
            self.size = size.uint64Value
            self.modified = modified
        }
    }

    /// The extension's `VideoEntry`, plus where the copy came from (ignored by the extension).
    struct Entry: Codable, Equatable {
        let id: String
        let name: String
        let filename: String
        let kind: String
        let duration: Double
        let fps: Double
        let resolution: [Double]
        let dateAdded: Date
        let source: Fingerprint?
    }

    private struct Preferences: Codable {
        let userPaused: Bool
        let alwaysPauseDesktop: Bool
        let pauseWhenOccluded: Bool
        let desktopOccluded: Bool
        let pauseOnBattery: Bool
        let playbackRate: Double
        let quality: String
        let nativeWallpaper: Bool
    }

    private struct State: Decodable {
        struct Context: Decodable {
            let displayID: UInt32
            let videoID: String?
            let isPreview: Bool?
        }

        let isActive: Bool
        let contexts: [Context]?
    }
}
