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
    func whenReady(_ completion: @escaping (Result<Void, Error>) -> Void)
    func show()
    func close()
    func updateDisplay(_ display: WallpaperDisplay)
    func setSuspended(_ suspended: Bool)
    func setDisplayMode(_ mode: WallpaperDisplayMode)
    func setInteractionEnabled(_ enabled: Bool)
    func setAudio(enabled: Bool, volume: Double)
    func reassertDesktopOrder()
}

typealias WallpaperWindowControlling = DisplayWallpaperWindow

extension DisplayWallpaperWindow {
    func updateDisplay(_ display: WallpaperDisplay) {}
}

@MainActor
final class DisplayPlaybackSessions {
    struct Assignment {
        let asset: WallpaperAsset
        var mode: WallpaperDisplayMode
    }

    typealias WindowFactory = (WallpaperAsset, WallpaperDisplay, WallpaperDisplayMode, Bool, Double) throws -> any DisplayWallpaperWindow

    private final class PendingPlayback {
        var assignments: [String: Assignment]
        var windows: [String: any DisplayWallpaperWindow]
        var readyIDs: Set<String> = []
        var audioEnabled: Bool
        var audioVolume: Double
        var autoPauseWhenCovered: Bool
        let completion: ((Result<Set<String>, Error>) -> Void)?

        init(assignments: [String: Assignment], windows: [String: any DisplayWallpaperWindow],
             audioEnabled: Bool, audioVolume: Double, autoPauseWhenCovered: Bool,
             completion: ((Result<Set<String>, Error>) -> Void)?) {
            self.assignments = assignments
            self.windows = windows
            self.audioEnabled = audioEnabled
            self.audioVolume = audioVolume
            self.autoPauseWhenCovered = autoPauseWhenCovered
            self.completion = completion
        }
    }

    private var pending: [String: PendingPlayback] = [:]
    var pendingDisplayIDs: Set<String> { Set(pending.keys) }
    var playbackStatusHandler: ((WallpaperPlaybackEvent) -> Void)?
    private let makeWindow: WindowFactory
    private(set) var assignments: [String: Assignment] = [:]
    private(set) var windows: [String: any DisplayWallpaperWindow] = [:]
    private(set) var displays: [WallpaperDisplay] = []
    private(set) var sleeping = false
    private(set) var coveredIDs: Set<String> = []
    var interactionEnabled = false
    var audioEnabled = false
    var audioVolume = 0.5
    private(set) var autoPauseWhenCovered = true

    init(makeWindow: @escaping WindowFactory) {
        self.makeWindow = makeWindow
    }

    /// A request commits only after every remaining target is ready. Other requests stay independent.
    func play(asset: WallpaperAsset, on ids: Set<String>, mode: WallpaperDisplayMode,
              audioEnabled: Bool? = nil, audioVolume: Double? = nil,
              autoPauseWhenCovered: Bool? = nil,
              completion: ((Result<Set<String>, Error>) -> Void)? = nil) throws {
        cancelPendingPlayback(on: ids)
        guard asset.supportStatus == .playable else {
            throw PlaybackError.notPlayable(asset.supportStatus.rawValue)
        }
        guard asset.entrypoint != nil else { throw PlaybackError.missingEntrypoint }
        guard !ids.isEmpty else { throw PlaybackError.noScreens }
        let nextAudioEnabled = audioEnabled ?? self.audioEnabled
        let nextAudioVolume = audioVolume ?? self.audioVolume
        var replacements: [String: any DisplayWallpaperWindow] = [:]
        do {
            for display in displays where ids.contains(display.id) {
                replacements[display.id] = try makeWindow(asset, display, mode, false, nextAudioVolume)
            }
        } catch {
            replacements.values.forEach { $0.close() }
            throw error
        }
        let batch = PendingPlayback(
            assignments: Dictionary(uniqueKeysWithValues: ids.map { ($0, Assignment(asset: asset, mode: mode)) }),
            windows: replacements, audioEnabled: nextAudioEnabled, audioVolume: nextAudioVolume,
            autoPauseWhenCovered: autoPauseWhenCovered ?? self.autoPauseWhenCovered, completion: completion
        )
        for id in ids { pending[id] = batch }
        for display in displays where ids.contains(display.id) {
            guard pending[display.id] === batch, let window = batch.windows[display.id] else { continue }
            let id = display.id
            window.whenReady { [weak self, weak batch, weak window] result in
                guard let self, let batch, let window,
                      self.pending[id] === batch, batch.windows[id] === window else { return }
                switch result {
                case .success:
                    batch.readyIDs.insert(id)
                    self.commitIfReady(batch)
                case .failure(let error):
                    self.fail(batch, error: error)
                }
            }
        }
        commitIfReady(batch)
    }

    func cancelPendingPlayback(on ids: Set<String>) {
        var affected: [PendingPlayback] = []
        for id in ids {
            guard let batch = pending.removeValue(forKey: id) else { continue }
            batch.assignments.removeValue(forKey: id)
            batch.readyIDs.remove(id)
            batch.windows.removeValue(forKey: id)?.close()
            if !affected.contains(where: { $0 === batch }) { affected.append(batch) }
        }
        for batch in affected { commitIfReady(batch) }
    }

    private func commitIfReady(_ batch: PendingPlayback) {
        let ids = Set(batch.assignments.keys)
        guard !ids.isEmpty, ids.allSatisfy({ pending[$0] === batch }),
              Set(batch.windows.keys).isSubset(of: batch.readyIDs) else { return }
        let orderedIDs = displays.map(\.id).filter { ids.contains($0) }
        for id in ids { pending.removeValue(forKey: id) }
        for id in orderedIDs { windows.removeValue(forKey: id)?.close() }
        audioEnabled = batch.audioEnabled
        audioVolume = batch.audioVolume
        autoPauseWhenCovered = batch.autoPauseWhenCovered
        for id in ids { assignments[id] = batch.assignments[id] }
        for id in orderedIDs {
            if let window = batch.windows[id] {
                windows[id] = window
                configure(window, id: id)
            }
        }
        let assetID = batch.assignments.values.first!.asset.id
        batch.completion?(.success(ids))
        playbackStatusHandler?(.ready(assetID: assetID))
    }

    private func fail(_ batch: PendingPlayback, error: Error) {
        let ids = Set(batch.assignments.keys)
        guard let assetID = batch.assignments.values.first?.asset.id else { return }
        for id in ids { pending.removeValue(forKey: id) }
        let discarded = batch.windows.values
        batch.windows = [:]
        batch.assignments = [:]
        discarded.forEach { $0.close() }
        batch.completion?(.failure(error))
        playbackStatusHandler?(.failed(assetID: assetID, message: error.localizedDescription))
    }

    func stop(on ids: Set<String>) {
        cancelPendingPlayback(on: ids)
        for id in ids {
            assignments.removeValue(forKey: id)
            windows.removeValue(forKey: id)?.close()
            coveredIDs.remove(id)
        }
    }

    /// Disconnection removes resources, not assignments. Relayout never restarts healthy players.
    func reconcile(_ current: [WallpaperDisplay]) -> [String] {
        let connected = Set(current.map(\.id))
        cancelPendingPlayback(on: pendingDisplayIDs.subtracting(connected))
        for id in Array(windows.keys) where !connected.contains(id) {
            windows.removeValue(forKey: id)?.close()
            coveredIDs.remove(id)
        }
        let previous = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
        displays = current
        var errors: [String] = []
        for display in current {
            if previous[display.id] != display {
                windows[display.id]?.updateDisplay(display)
                pending[display.id]?.windows[display.id]?.updateDisplay(display)
            }
            if windows[display.id] == nil, pending[display.id] == nil,
               let assignment = assignments[display.id] {
                do {
                    try play(asset: assignment.asset, on: [display.id], mode: assignment.mode)
                } catch {
                    errors.append("\(display.name): \(error.localizedDescription)")
                }
            }
        }
        return errors
    }

    func refreshScene(assetID: String) -> [String] {
        var errors: [String] = []
        let targets = displays.filter {
            pending[$0.id] == nil && assignments[$0.id]?.asset.id == assetID
                && assignments[$0.id]?.asset.kind == .scene
        }
        // Group matching modes so refreshing a shared scene preserves batch readiness.
        for mode in Set(targets.compactMap { assignments[$0.id]?.mode.rawValue }) {
            let ids = Set(targets.filter { assignments[$0.id]?.mode.rawValue == mode }.map(\.id))
            guard let id = ids.first, let assignment = assignments[id] else { continue }
            do {
                try play(asset: assignment.asset, on: ids, mode: assignment.mode)
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        return errors
    }

    func setMode(_ mode: WallpaperDisplayMode, on ids: Set<String>) {
        for id in ids {
            assignments[id]?.mode = mode
            windows[id]?.setDisplayMode(mode)
            pending[id]?.assignments[id]?.mode = mode
            pending[id]?.windows[id]?.setDisplayMode(mode)
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

    func setAutoPauseWhenCovered(_ enabled: Bool) {
        autoPauseWhenCovered = enabled
        for batch in pending.values { batch.autoPauseWhenCovered = enabled }
    }

    func setAudioSettings(enabled: Bool, volume: Double) {
        audioEnabled = enabled
        audioVolume = volume
        for batch in pending.values {
            batch.audioEnabled = enabled
            batch.audioVolume = volume
        }
        applySettings()
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
