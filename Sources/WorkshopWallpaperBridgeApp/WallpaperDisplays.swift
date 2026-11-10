import AppKit
import WorkshopWallpaperCore

struct WallpaperDisplay: Identifiable, Equatable {
    let id: String
    let name: String
    let frame: CGRect
    let scale: CGFloat
    let isPrimary: Bool

    @MainActor
    static func connected() -> [WallpaperDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else {
                return nil
            }
            return WallpaperDisplay(
                id: CFUUIDCreateString(nil, uuid) as String,
                name: screen.localizedName,
                frame: screen.frame,
                scale: screen.backingScaleFactor,
                isPrimary: number.uint32Value == CGMainDisplayID()
            )
        }
    }

    var pixelSizeLabel: String {
        "\(Int(frame.width * scale)) × \(Int(frame.height * scale)) · \(scale.formatted())×"
    }
}

struct DisplayWallpaperAssignment: Codable, Equatable {
    var assetID: String?
    var displayMode: WallpaperDisplayMode
    var isPlaying: Bool
}

/// Window/media operations are the OS boundary; the routing logic is also used by tests.
@MainActor
protocol DisplayWallpaperWindow: AnyObject {
    func show()
    func close()
    func updateDisplay(_ display: WallpaperDisplay)
    func setSuspended(_ suspended: Bool)
    func setDisplayMode(_ mode: WallpaperDisplayMode)
    func setInteractionEnabled(_ enabled: Bool)
    func setAudio(enabled: Bool, volume: Double)
    func reassertDesktopOrder()
}

@MainActor
final class DisplayPlaybackSessions {
    struct Assignment {
        let asset: WallpaperAsset
        var mode: WallpaperDisplayMode
    }

    typealias WindowFactory = (WallpaperAsset, WallpaperDisplay, WallpaperDisplayMode) throws -> any DisplayWallpaperWindow
    private let makeWindow: WindowFactory
    private(set) var assignments: [String: Assignment] = [:]
    private(set) var windows: [String: any DisplayWallpaperWindow] = [:]
    private(set) var displays: [WallpaperDisplay] = []
    private(set) var sleeping = false
    private(set) var coveredIDs: Set<String> = []
    var interactionEnabled = false
    var audioEnabled = false
    var audioVolume = 0.5

    init(makeWindow: @escaping WindowFactory) {
        self.makeWindow = makeWindow
    }

    /// Prepare every replacement first. A failed display leaves all current windows intact.
    func play(asset: WallpaperAsset, on ids: Set<String>, mode: WallpaperDisplayMode) throws {
        guard asset.supportStatus == .playable else {
            throw PlaybackError.notPlayable(asset.supportStatus.rawValue)
        }
        guard asset.entrypoint != nil else { throw PlaybackError.missingEntrypoint }
        var replacements: [String: any DisplayWallpaperWindow] = [:]
        do {
            for display in displays where ids.contains(display.id) {
                do {
                    replacements[display.id] = try makeWindow(asset, display, mode)
                } catch {
                    throw DisplayPlaybackFailure(displayName: display.name, reason: error.localizedDescription)
                }
            }
        } catch {
            replacements.values.forEach { $0.close() }
            throw error
        }
        for id in ids {
            windows.removeValue(forKey: id)?.close()
            assignments[id] = Assignment(asset: asset, mode: mode)
            if let window = replacements[id] {
                windows[id] = window
                configure(window, id: id)
            }
        }
    }

    func stop(on ids: Set<String>) {
        for id in ids {
            assignments.removeValue(forKey: id)
            windows.removeValue(forKey: id)?.close()
            coveredIDs.remove(id)
        }
    }

    /// Disconnection removes resources, not assignments. Relayout never restarts healthy players.
    func reconcile(_ current: [WallpaperDisplay]) -> [String] {
        let connected = Set(current.map(\.id))
        for id in Array(windows.keys) where !connected.contains(id) {
            windows.removeValue(forKey: id)?.close()
            coveredIDs.remove(id)
        }
        let previous = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
        displays = current
        var errors: [String] = []
        for display in current {
            if let window = windows[display.id] {
                if previous[display.id] != display { window.updateDisplay(display) }
            } else if let assignment = assignments[display.id] {
                do {
                    let window = try makeWindow(assignment.asset, display, assignment.mode)
                    windows[display.id] = window
                    configure(window, id: display.id)
                } catch {
                    errors.append("\(display.name): \(error.localizedDescription)")
                }
            }
        }
        return errors
    }

    func refreshScene(assetID: String) -> [String] {
        var errors: [String] = []
        for display in displays {
            guard let assignment = assignments[display.id],
                  assignment.asset.id == assetID, assignment.asset.kind == .scene else { continue }
            do {
                let replacement = try makeWindow(assignment.asset, display, assignment.mode)
                windows.removeValue(forKey: display.id)?.close()
                windows[display.id] = replacement
                configure(replacement, id: display.id)
            } catch {
                errors.append("\(display.name): \(error.localizedDescription)")
            }
        }
        return errors
    }

    func setMode(_ mode: WallpaperDisplayMode, on ids: Set<String>) {
        for id in ids {
            assignments[id]?.mode = mode
            windows[id]?.setDisplayMode(mode)
        }
    }

    func setSleeping(_ value: Bool) {
        guard sleeping != value else { return }
        sleeping = value
        applySuspension()
    }

    func setCovered(_ ids: Set<String>) {
        guard coveredIDs != ids else { return }
        coveredIDs = ids
        applySuspension()
    }

    func applySettings() {
        for window in windows.values {
            window.setInteractionEnabled(interactionEnabled)
            window.setAudio(enabled: audioEnabled, volume: audioVolume)
        }
    }

    private func configure(_ window: any DisplayWallpaperWindow, id: String) {
        window.setInteractionEnabled(interactionEnabled)
        window.setAudio(enabled: audioEnabled, volume: audioVolume)
        window.setSuspended(sleeping || coveredIDs.contains(id))
        window.show()
    }

    private func applySuspension() {
        for (id, window) in windows { window.setSuspended(sleeping || coveredIDs.contains(id)) }
    }
}

private struct DisplayPlaybackFailure: LocalizedError {
    let displayName: String
    let reason: String
    var errorDescription: String? { "\(displayName): \(reason)" }
}

@MainActor
final class DisplayIdentification {
    static let shared = DisplayIdentification()
    private var windows: [NSWindow] = []
    private var dismiss: DispatchWorkItem?

    func show(displays: [WallpaperDisplay]) {
        dismiss?.cancel()
        windows.forEach { $0.close() }
        windows = displays.enumerated().map { index, display in
            let frame = CGRect(x: display.frame.midX - 180, y: display.frame.midY - 65, width: 360, height: 130)
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let label = NSTextField(labelWithString: "\(index + 1) · \(display.name)\n\(display.pixelSizeLabel)")
            label.font = .systemFont(ofSize: 24, weight: .semibold)
            label.alignment = .center
            label.frame = CGRect(x: 10, y: 25, width: 340, height: 80)
            window.contentView?.addSubview(label)
            window.orderFrontRegardless()
            return window
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.windows.forEach { $0.close() }
                self?.windows = []
            }
        }
        dismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
}
