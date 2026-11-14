import Foundation
import os

/// Owns where each display is inside its playlist.
///
/// The renderer decides when a wallpaper rotates, not the app. Driftwood is a menu-bar
/// app the user can quit — or simply never open after login — while WallpaperAgent keeps
/// this extension alive, so a playlist driven from the app would silently stop advancing.
/// Everything needed to keep going arrives in the assignment manifest (the entries, their
/// durations, ordered vs. shuffle), and the position is checkpointed beside it so a
/// WallpaperAgent restart resumes instead of snapping back to the first wallpaper.
///
/// Timers run on `RenderQueue.serial`, the same queue surfaces require, so an advance can
/// hand content straight to `WallpaperAssignmentStore` without another hop.
final class PlaylistScheduler: @unchecked Sendable {
    static let shared = PlaylistScheduler()

    private static let stateFilename = "driftwood-playlist-state.json"
    private static let schemaVersion = 1

    private struct Playback {
        /// Identity of the program. Two manifests with the same fingerprint are the same
        /// playlist, so retitling a wallpaper or re-timing an entry keeps the position.
        var fingerprint: String
        var mode: WallpaperPlaylistMode
        /// Seconds per entry, indexed like the manifest's `entries`.
        var durations: [Double]
        /// Entry indices in playback order. For `.ordered` this is `0..<count`; for
        /// `.shuffle` it is a permutation, redrawn each time the list wraps.
        var order: [Int]
        var cursor: Int
        var paused: Bool
        var deadline: Date?
        /// What was left on the current entry when it was paused.
        var remaining: TimeInterval?
        /// Bumped whenever a pending fire stops being valid, so a timer that has already
        /// been dispatched can recognise itself as stale.
        var timerGeneration: UInt64

        var currentEntryIndex: Int {
            guard !order.isEmpty else { return 0 }
            return order[min(max(cursor, 0), order.count - 1)]
        }

        /// How long the current entry stays up. A one-entry program has nothing to rotate
        /// to, so it never arms a timer regardless of what the manifest says.
        var currentDuration: TimeInterval {
            guard order.count > 1,
                  durations.indices.contains(currentEntryIndex) else {
                return 0
            }
            return durations[currentEntryIndex]
        }
    }

    private struct PersistedPlayback: Codable {
        var fingerprint: String
        var order: [Int]
        var cursor: Int
    }

    private struct PersistedState: Codable {
        var schemaVersion: Int
        var displays: [String: PersistedPlayback]
        /// The Previous/Next running total per display as of the last one applied, so a
        /// restart adopts what is already in the control file instead of replaying it.
        var controlTotals: [String: Int]
    }

    private struct State {
        var playbacks: [String: Playback] = [:]
        var restorable: [String: PersistedPlayback] = [:]
        var controlTotals: [String: Int] = [:]
        var observing = false
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let documentsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents", isDirectory: true)

    private init() {}

    // MARK: - Lifecycle

    func start() {
        let shouldStart = lock.withLock { state -> Bool in
            guard !state.observing else { return false }
            state.observing = true
            return true
        }
        guard shouldStart else { return }

        loadPersistedState()
        // A display with no checkpoint adopts the existing total rather than replaying
        // the control file's whole history. Persisted totals stay authoritative so a
        // command interrupted by a process exit remains pending after restart.
        seedControlTotals()

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let scheduler = Unmanaged<PlaylistScheduler>
                    .fromOpaque(observer)
                    .takeUnretainedValue()
                RenderQueue.serial.async {
                    scheduler.consumeControlCommands()
                }
            },
            PlaylistControlFile.notification as CFString,
            nil,
            .deliverImmediately
        )
    }

    // MARK: - Assignment sync

    /// Bring a display's playback in line with a newly-loaded assignment and return the
    /// entry index that should be on screen right now.
    @discardableResult
    func sync(_ assignment: DisplayWallpaperAssignment) -> Int {
        let displayUUID = assignment.displayUUID
        let fingerprint = Self.fingerprint(for: assignment)
        let durations = assignment.entries.map(\.durationSeconds)
        let count = assignment.entries.count

        let (index, needsRearm) = lock.withLock { state -> (Int, Bool) in
            if var playback = state.playbacks[displayUUID],
               playback.fingerprint == fingerprint,
               playback.order.count == count {
                let timingChanged = playback.durations != durations
                playback.durations = durations
                state.playbacks[displayUUID] = playback
                return (playback.currentEntryIndex, timingChanged)
            }

            var order = Array(0..<count)
            var cursor = 0
            if let restored = state.restorable[displayUUID],
               restored.fingerprint == fingerprint,
               Self.isValidOrder(restored.order, count: count),
               restored.order.indices.contains(restored.cursor) {
                order = restored.order
                cursor = restored.cursor
            } else {
                order = WallpaperPlaylistWalk.makeOrder(
                    count: count,
                    mode: assignment.mode
                )
            }
            state.restorable[displayUUID] = nil

            let playback = Playback(
                fingerprint: fingerprint,
                mode: assignment.mode,
                durations: durations,
                order: order,
                cursor: cursor,
                // A fresh program starts running; the next policy pass parks it if the
                // display is asleep, occluded or on battery.
                paused: false,
                deadline: nil,
                remaining: nil,
                timerGeneration: 0
            )
            state.playbacks[displayUUID] = playback
            return (playback.currentEntryIndex, true)
        }

        if needsRearm {
            persist()
            rearm(displayUUID: displayUUID, restartingEntry: true)
        }
        // A control command can arrive while this display is temporarily absent. Its
        // running total remains pending until playback exists again, then lands here.
        consumeControlCommands(for: displayUUID)
        return currentIndex(for: displayUUID) ?? index
    }

    /// The entry index a display should be showing, if it has a program at all.
    func currentIndex(for displayUUID: String) -> Int? {
        lock.withLock { $0.playbacks[displayUUID]?.currentEntryIndex }
    }

    /// Stop timers for displays the manifest no longer covers.
    ///
    /// Their position is demoted back to `restorable` rather than dropped: a display can
    /// fall out of this set because one of its files was momentarily unresolvable — mid
    /// redeploy, say — and losing the checkpoint would restart the playlist at the first
    /// wallpaper instead of resuming where it was.
    func retain(displayUUIDs: Set<String>) {
        let changed = lock.withLock { state -> Bool in
            let stale = state.playbacks.keys.filter {
                !displayUUIDs.contains($0)
            }
            for displayUUID in stale {
                guard var playback = state.playbacks[displayUUID] else {
                    continue
                }
                playback.timerGeneration &+= 1
                state.playbacks[displayUUID] = playback
                state.restorable[displayUUID] = PersistedPlayback(
                    fingerprint: playback.fingerprint,
                    order: playback.order,
                    cursor: playback.cursor
                )
                state.playbacks.removeValue(forKey: displayUUID)
            }
            return !stale.isEmpty
        }
        if changed { persist() }
    }

    // MARK: - Playback control

    /// Park or resume a display's rotation. A paused wallpaper is one the user asked to
    /// freeze (or that power policy froze); rotating underneath that would be the one
    /// thing pause is supposed to prevent.
    func setPaused(_ paused: Bool, displayUUID: String) {
        let changed = lock.withLock { state -> Bool in
            guard var playback = state.playbacks[displayUUID],
                  playback.paused != paused else {
                return false
            }
            playback.paused = paused
            if paused {
                if let deadline = playback.deadline {
                    // Floored just above zero rather than at some round number: the entry
                    // resumes with what it actually had left, and a deadline that already
                    // slipped past (its fire orphaned by the generation bump) rotates
                    // promptly instead of arming a non-positive timer.
                    playback.remaining = max(
                        0.05,
                        deadline.timeIntervalSinceNow
                    )
                }
                playback.deadline = nil
                playback.timerGeneration &+= 1
            }
            state.playbacks[displayUUID] = playback
            return true
        }
        guard changed, !paused else { return }
        rearm(displayUUID: displayUUID, restartingEntry: false)
    }

    func setAllPaused(_ paused: Bool) {
        let displayUUIDs = lock.withLock { Array($0.playbacks.keys) }
        for displayUUID in displayUUIDs {
            setPaused(paused, displayUUID: displayUUID)
        }
    }

    // MARK: - Timing

    private func rearm(displayUUID: String, restartingEntry: Bool) {
        let request = lock.withLock { state -> (UInt64, TimeInterval)? in
            guard var playback = state.playbacks[displayUUID] else {
                return nil
            }
            playback.timerGeneration &+= 1
            let generation = playback.timerGeneration
            defer { state.playbacks[displayUUID] = playback }

            guard !playback.paused else {
                if restartingEntry {
                    let duration = playback.currentDuration
                    playback.remaining = duration > 0 ? duration : nil
                }
                playback.deadline = nil
                return nil
            }

            let interval = restartingEntry
                ? playback.currentDuration
                : (playback.remaining ?? playback.currentDuration)
            playback.remaining = nil
            guard interval > 0 else {
                playback.deadline = nil
                return nil
            }
            playback.deadline = Date().addingTimeInterval(interval)
            return (generation, interval)
        }

        guard let (generation, interval) = request else { return }
        RenderQueue.serial.asyncAfter(deadline: .now() + interval) {
            [weak self] in
            self?.advance(displayUUID: displayUUID, generation: generation)
        }
    }

    private func advance(displayUUID: String, generation: UInt64) {
        let advanced = lock.withLock { state -> Bool in
            guard var playback = state.playbacks[displayUUID],
                  playback.timerGeneration == generation,
                  !playback.paused,
                  playback.order.count > 1 else {
                return false
            }
            WallpaperPlaylistWalk.step(
                order: &playback.order,
                cursor: &playback.cursor,
                offset: 1,
                mode: playback.mode
            )
            state.playbacks[displayUUID] = playback
            return true
        }
        guard advanced else { return }
        persist()
        rearm(displayUUID: displayUUID, restartingEntry: true)
        WallpaperAssignmentStore.shared.applyCurrentPlaylistEntry(
            for: displayUUID
        )
    }

    // MARK: - Control file

    private func consumeControlCommands(for displayUUID: String? = nil) {
        let outcome = lock.withLock {
            state -> (moved: [String: Int], adopted: Bool) in
            guard let control = readControlFile() else { return ([:], false) }
            let displayUUIDs = displayUUID.map { [$0] }
                ?? Array(control.commands.keys)
            var moved: [String: Int] = [:]
            var adopted = false
            for displayUUID in displayUUIDs {
                switch control.resolve(
                    displayUUID: displayUUID,
                    lastAppliedTotal: state.controlTotals[displayUUID] ?? 0
                ) {
                case .step(let offset, let total):
                    guard var playback = state.playbacks[displayUUID] else {
                        // Keep it pending. `sync` retries this display once its assignment
                        // is resolvable again.
                        continue
                    }
                    state.controlTotals[displayUUID] = total
                    adopted = true
                    guard playback.order.count > 1 else {
                        // Previous/Next on a one-entry program is a consumed no-op, not a
                        // command that should unexpectedly fire if entries are added later.
                        continue
                    }
                    WallpaperPlaylistWalk.step(
                        order: &playback.order,
                        cursor: &playback.cursor,
                        offset: offset,
                        mode: playback.mode
                    )
                    playback.remaining = nil
                    playback.timerGeneration &+= 1
                    state.playbacks[displayUUID] = playback
                    moved[displayUUID] = offset
                case .resync(let total):
                    // The control file was reset or replaced. Adopt the total so the next
                    // press is a normal one step, rather than replaying its whole history.
                    state.controlTotals[displayUUID] = total
                    adopted = true
                case .none:
                    continue
                }
            }
            return (moved, adopted)
        }
        guard outcome.adopted else { return }
        // Cursor movement and the total that caused it share one atomic state snapshot:
        // after a restart the command is either still pending or fully applied, never half.
        persist()
        for (displayUUID, offset) in outcome.moved {
            extensionLog(
                "[Playlist] \(displayUUID) step \(offset) from the app"
            )
            rearm(displayUUID: displayUUID, restartingEntry: true)
            WallpaperAssignmentStore.shared.applyCurrentPlaylistEntry(
                for: displayUUID
            )
        }
    }

    private func readControlFile() -> PlaylistControlFile? {
        guard let data = try? Data(contentsOf: controlURL),
              let control = try? JSONDecoder().decode(
                  PlaylistControlFile.self,
                  from: data
              ), control.isSupported else {
            return nil
        }
        return control
    }

    private func seedControlTotals() {
        guard let control = readControlFile() else { return }
        lock.withLock { state in
            for (displayUUID, command) in control.commands {
                if state.controlTotals[displayUUID] == nil {
                    state.controlTotals[displayUUID] = command.totalSteps
                }
            }
        }
    }

    // MARK: - Persistence

    private var stateURL: URL {
        documentsURL.appendingPathComponent(Self.stateFilename)
    }

    private var controlURL: URL {
        documentsURL.appendingPathComponent(PlaylistControlFile.filename)
    }

    private func loadPersistedState() {
        guard let data = try? Data(contentsOf: stateURL),
              let persisted = try? JSONDecoder().decode(
                  PersistedState.self,
                  from: data
              ), persisted.schemaVersion == Self.schemaVersion else {
            return
        }
        lock.withLock { state in
            state.restorable = persisted.displays
            state.controlTotals = persisted.controlTotals
        }
    }

    private func persist() {
        let snapshot = lock.withLock { state in
            var displays = state.restorable
            for (displayUUID, playback) in state.playbacks {
                displays[displayUUID] = PersistedPlayback(
                    fingerprint: playback.fingerprint,
                    order: playback.order,
                    cursor: playback.cursor
                )
            }
            return PersistedState(
                schemaVersion: Self.schemaVersion,
                displays: displays,
                controlTotals: state.controlTotals
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    // MARK: - Helpers

    private static func fingerprint(
        for assignment: DisplayWallpaperAssignment
    ) -> String {
        WallpaperProgramIdentity.fingerprint(
            playlistID: assignment.playlistID,
            mode: assignment.mode,
            contentUUIDs: assignment.entries.map(\.contentUUID)
        )
    }

    private static func isValidOrder(_ order: [Int], count: Int) -> Bool {
        order.count == count && Set(order) == Set(0..<count)
    }

}
