import Foundation

/// Edits macOS's wallpaper store (`com.apple.wallpaper/Store/Index.plist`) so a
/// display's desktop is provided by this app's wallpaper extension. Ported from
/// Driftwood's NativeWallpaperProvider (MIT, see NativeWallpaperExtension/LICENSE.driftwood).
/// Pure dictionary work: reading, writing and restarting WallpaperAgent live elsewhere.
enum SystemWallpaperStore {
    static let providerID = "dev.3xhaust.WorkshopWallpaperBridge.wallpaper"

    struct Choice: Equatable {
        let choiceID: String
        let resourceURL: URL
    }

    enum StoreError: LocalizedError, Equatable {
        case unreadable
        case displayMissing

        var errorDescription: String? {
            switch self {
            case .unreadable: "The macOS wallpaper store could not be read."
            case .displayMissing: "The display is missing from the macOS wallpaper store."
            }
        }
    }

    static func decode(_ data: Data) throws -> [String: Any] {
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            as? [String: Any] else {
            throw StoreError.unreadable
        }
        return root
    }

    static func encode(_ root: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }

    /// The store with each display's desktop (and its Space overrides) set to its choice.
    /// `mainDisplayID` also becomes the default for new Spaces and displays.
    static func selecting(
        _ choices: [String: Choice],
        in original: [String: Any],
        connectedDisplayIDs: Set<String>,
        mainDisplayID: String?,
        now: Date = Date()
    ) throws -> [String: Any] {
        guard !choices.isEmpty else { throw StoreError.displayMissing }
        var root = original
        guard materializeDisplayTargets(
            in: &root,
            connectedDisplayIDs: connectedDisplayIDs,
            requiredDisplayIDs: Set(choices.keys)
        ) else {
            throw StoreError.displayMissing
        }
        var changed = 0
        for (displayID, choice) in choices {
            changed += rewriteTargets(in: &root, displayIDs: [displayID], content: content(for: choice), now: now)
        }
        if let mainDisplayID, let main = choices[mainDisplayID] {
            changed += rewriteDefaultTargets(in: &root, content: content(for: main), now: now)
        }
        guard changed > 0 else { throw StoreError.displayMissing }
        return root
    }

    /// Which displays' desktops this app's extension currently provides (display ID → choice ID).
    static func providedDisplays(in root: [String: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for (displayID, value) in root["Displays"] as? [String: Any] ?? [:] {
            if let container = value as? [String: Any], let choice = choiceID(in: container) {
                result[displayID] = choice
            }
        }
        return result
    }

    /// Whether any desktop in the store (a display, a Space, the shared or default one) is ours.
    static func usesProvider(_ root: [String: Any]) -> Bool {
        var containers: [[String: Any]] = []
        for key in ["AllSpacesAndDisplays", "SystemDefault"] {
            if let container = root[key] as? [String: Any] { containers.append(container) }
        }
        containers += (root["Displays"] as? [String: Any] ?? [:]).values.compactMap { $0 as? [String: Any] }
        for space in (root["Spaces"] as? [String: Any] ?? [:]).values.compactMap({ $0 as? [String: Any] }) {
            if let node = space["Default"] as? [String: Any] { containers.append(node) }
            containers += (space["Displays"] as? [String: Any] ?? [:]).values.compactMap { $0 as? [String: Any] }
        }
        return containers.contains { choiceID(in: $0) != nil }
    }

    static func content(for choice: Choice) -> [String: Any] {
        [
            "Choices": [[
                "Configuration": Data(choice.choiceID.utf8),
                "Files": [["relative": choice.resourceURL.absoluteString]],
                "Provider": providerID
            ]],
            "EncodedOptionValues": videoOptionValues,
            "Shuffle": "$null"
        ]
    }

    static func choiceID(in container: [String: Any]) -> String? {
        guard let desktop = container["Desktop"] as? [String: Any],
              let content = desktop["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]],
              let choice = choices.first,
              choice["Provider"] as? String == providerID else {
            return nil
        }
        if let data = choice["Configuration"] as? Data, let value = String(data: data, encoding: .utf8) {
            return UUID(uuidString: value)?.uuidString
        }
        return (choice["Configuration"] as? String).flatMap { UUID(uuidString: $0)?.uuidString }
    }

    private static func materializeDisplayTargets(
        in root: inout [String: Any],
        connectedDisplayIDs: Set<String>,
        requiredDisplayIDs: Set<String>
    ) -> Bool {
        var displays = root["Displays"] as? [String: Any] ?? [:]
        let missing = connectedDisplayIDs.union(requiredDisplayIDs).subtracting(displays.keys)
        let shared = root["AllSpacesAndDisplays"] as? [String: Any]
        if !missing.isEmpty {
            let candidates = [shared, root["SystemDefault"] as? [String: Any]].compactMap { $0 }
                + displays.values.compactMap { $0 as? [String: Any] }
            let wallpaperTemplate = candidates.first(where: hasActiveContent)
            let requiredTemplate = wallpaperTemplate ?? candidates.first(where: hasIdleContent)
            for displayID in missing {
                if let wallpaperTemplate {
                    displays[displayID] = wallpaperTemplate
                } else if requiredDisplayIDs.contains(displayID) {
                    displays[displayID] = requiredTemplate ?? [:]
                }
            }
            root["Displays"] = displays
        }
        // A shared Desktop overrides the per-display entries: keep only its idle
        // (screen saver) part, as Wallpaper Settings does when displays split.
        if var shared, shared["Desktop"] != nil || shared["Linked"] != nil {
            if let linked = shared["Linked"] as? [String: Any] { shared["Idle"] = linked }
            shared.removeValue(forKey: "Desktop")
            shared.removeValue(forKey: "Linked")
            if shared["Idle"] != nil { shared["Type"] = "idle" }
            root["AllSpacesAndDisplays"] = shared
        }
        return requiredDisplayIDs.isSubset(of: Set(displays.keys))
    }

    private static func rewriteTargets(
        in root: inout [String: Any], displayIDs: Set<String>, content: [String: Any], now: Date
    ) -> Int {
        var changed = 0
        if var displays = root["Displays"] as? [String: Any] {
            for displayID in displayIDs {
                guard var display = displays[displayID] as? [String: Any] else { continue }
                replaceDesktop(in: &display, content: content, now: now)
                displays[displayID] = display
                changed += 1
            }
            root["Displays"] = displays
        }
        if var spaces = root["Spaces"] as? [String: Any] {
            for (spaceID, value) in spaces {
                guard var space = value as? [String: Any],
                      var spaceDisplays = space["Displays"] as? [String: Any] else { continue }
                var touched = false
                for displayID in displayIDs {
                    guard var display = spaceDisplays[displayID] as? [String: Any] else { continue }
                    replaceDesktop(in: &display, content: content, now: now)
                    spaceDisplays[displayID] = display
                    changed += 1
                    touched = true
                }
                guard touched else { continue }
                space["Displays"] = spaceDisplays
                spaces[spaceID] = space
            }
            root["Spaces"] = spaces
        }
        return changed
    }

    private static func rewriteDefaultTargets(in root: inout [String: Any], content: [String: Any], now: Date) -> Int {
        var changed = 0
        if var systemDefault = root["SystemDefault"] as? [String: Any] {
            replaceDesktop(in: &systemDefault, content: content, now: now)
            root["SystemDefault"] = systemDefault
            changed += 1
        }
        if var spaces = root["Spaces"] as? [String: Any] {
            for (spaceID, value) in spaces {
                guard var space = value as? [String: Any],
                      var node = space["Default"] as? [String: Any] else { continue }
                replaceDesktop(in: &node, content: content, now: now)
                space["Default"] = node
                spaces[spaceID] = space
                changed += 1
            }
            root["Spaces"] = spaces
        }
        return changed
    }

    private static func replaceDesktop(in container: inout [String: Any], content: [String: Any], now: Date) {
        if let linked = container["Linked"] as? [String: Any] { container["Idle"] = linked }
        container.removeValue(forKey: "Linked")
        var desktop = container["Desktop"] as? [String: Any] ?? [:]
        desktop["Content"] = content
        desktop["LastSet"] = now
        desktop["LastUse"] = now
        container["Desktop"] = desktop
        container["Type"] = "individual"
    }

    private static func hasActiveContent(_ container: [String: Any]) -> Bool {
        ["Desktop", "Linked"].contains { ((container[$0] as? [String: Any])?["Content"]) is [String: Any] }
    }

    private static func hasIdleContent(_ container: [String: Any]) -> Bool {
        ((container["Idle"] as? [String: Any])?["Content"]) is [String: Any]
    }

    /// Option payload macOS stores for an extension-provided video choice (from Driftwood).
    private static let videoOptionValues = Data(base64Encoded: """
    YnBsaXN0MDDRAQJWdmFsdWVz0gMEBRJVY29sb3JZcGxhY2VtZW500QMG0QcIUl8w0QMJ0goLDBFaY29tcG9uZW50c1pjb2xvclNwYWNl\
    pA0ODxAjP9BQUFBQUFAjP9paWlpaWlojP+VVVVVVVVUjP/AAAAAAAABPEENicGxpc3QwMF8QF2tDR0NvbG9yU3BhY2VHZW5lcmljUkdC\
    CAAAAAAAAAEBAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAi0RMUVnBpY2tlctEHFdEWF1JpZFRDcm9wCAsSFx0nKi0wMzhDTlNcZW53vcDH\
    ys3QAAAAAAAAAQEAAAAAAAAAGAAAAAAAAAAAAAAAAAAAANU=
    """)!
}
