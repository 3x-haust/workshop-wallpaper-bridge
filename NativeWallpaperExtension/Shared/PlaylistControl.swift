import Foundation

/// Previous/Next, as a request from the app to the renderer.
///
/// The extension owns where a playlist is, so stepping cannot be expressed as a new
/// assignment — publishing a manifest would restart the program rather than move within
/// it. This is the side channel for that, and it lives in `Shared/` for the same reason
/// the manifest does: two hand-mirrored copies of an on-disk format drift silently,
/// because both sides decode with `try?`.
///
/// The payload is a **running total**, not a delta. Darwin notifications coalesce, so
/// three quick Next presses can reach the extension as a single wake-up; the extension
/// applies the difference against what it last applied, which loses nothing to coalescing
/// and cannot double-apply if the file is re-read.
struct PlaylistStepCommand: Codable, Hashable, Sendable {
    /// Net entries requested for this display over the life of the control file.
    /// Monotonic in intent but not in value — Previous decrements it.
    var totalSteps: Int

    init(totalSteps: Int) {
        self.totalSteps = totalSteps
    }
}

struct PlaylistControlFile: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1
    static let filename = "driftwood-playlist-control.json"
    static let notification = "dev.3xhaust.WorkshopWallpaperBridge.wallpaper.playlistControl"

    /// The most entries one wake-up may move. Larger than any plausible burst of clicks,
    /// small enough to bound the arithmetic — a hand-written or truncated file would
    /// otherwise be able to overflow the cursor maths in the extension.
    static let maximumStep = 4_096

    var schemaVersion: Int
    var commands: [String: PlaylistStepCommand]

    init(
        schemaVersion: Int = currentSchemaVersion,
        commands: [String: PlaylistStepCommand] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.commands = commands
    }

    var isSupported: Bool {
        schemaVersion == Self.currentSchemaVersion
    }

    /// What the renderer should do about `displayUUID`, given the total it last applied.
    enum Resolution: Equatable {
        /// Move this many entries, then record `total`.
        case step(Int, total: Int)
        /// Adopt `total` without moving. The file was reset, replaced or corrupted, so the
        /// difference is meaningless — better to lose a press than to spin a playlist
        /// through hundreds of entries.
        case resync(total: Int)
        case none
    }

    func resolve(
        displayUUID: String,
        lastAppliedTotal: Int
    ) -> Resolution {
        guard isSupported,
              WallpaperDisplayUUID.normalized(displayUUID) == displayUUID,
              let command = commands[displayUUID] else {
            return .none
        }
        let total = command.totalSteps
        guard total != lastAppliedTotal else { return .none }
        // Reported totals are untrusted, so the subtraction itself has to be safe —
        // widening to `Int64` does not help, it is the same width as `Int` here, and
        // `Int.max - Int.min` traps either way. `magnitude` rather than `abs` for the
        // same reason: `abs(Int.min)` traps.
        let (delta, overflowed) = total.subtractingReportingOverflow(
            lastAppliedTotal
        )
        guard !overflowed,
              delta.magnitude <= UInt(Self.maximumStep) else {
            return .resync(total: total)
        }
        return .step(delta, total: total)
    }
}

/// Identity of a display's program, used on both sides of the process boundary to decide
/// whether a newly published assignment is "the same playlist, edited" — keep the
/// position — or a different program — start over.
///
/// Shared because the two sides must agree: if the app's overlay cursor and the renderer's
/// cursor disagree about what counts as the same program, a display resets its rotation on
/// one path and not the other.
enum WallpaperProgramIdentity {
    static func fingerprint(
        playlistID: String?,
        mode: WallpaperPlaylistMode,
        contentUUIDs: [String]
    ) -> String {
        (playlistID ?? "-")
            + "|" + mode.rawValue
            + "|" + contentUUIDs.joined(separator: ",")
    }
}
