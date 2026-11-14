import Foundation

enum WallpaperDisplayUUID {
    /// CoreGraphics display UUIDs use Foundation's canonical UUID spelling.
    static func normalized(_ value: String) -> String? {
        UUID(uuidString: value)?.uuidString
    }
}

/// How the renderer walks a display's playlist. Persisted in the manifest, so the
/// extension keeps shuffling (or not) across app quits and WallpaperAgent restarts.
enum WallpaperPlaylistMode: String, Codable, Hashable, Sendable {
    case ordered
    case shuffle
}

enum WallpaperAssignmentValidationError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case invalidManifestRevision(UInt64)
    case nonMonotonicManifestRevision(previous: UInt64, current: UInt64)
    case invalidDisplayUUID(String)
    case nonNormalizedDisplayUUID(String)
    case duplicateDisplayUUID(String)
    case mismatchedDisplayUUID(key: String, assignment: String)
    case invalidContentUUID(displayUUID: String, contentUUID: String)
    case invalidAssignmentRevision(
        displayUUID: String,
        assignmentRevision: UInt64,
        manifestRevision: UInt64
    )
    case nonMonotonicAssignmentRevision(
        displayUUID: String,
        previous: UInt64,
        current: UInt64
    )
    case changedAssignmentWithoutRevisionAdvance(displayUUID: String)
    case unsafeResourcePath(displayUUID: String, path: String)
    case unsafePosterPath(displayUUID: String, path: String)
    case emptyTitle(displayUUID: String)
    case invalidContentHash(displayUUID: String)
    case emptyPlaylist(displayUUID: String)
    case oversizedPlaylist(displayUUID: String, count: Int)
    case invalidPlaylistID(displayUUID: String, playlistID: String)
    case invalidEntryDuration(displayUUID: String, contentUUID: String)
    case incompleteAppliedAssignment(displayUUID: String)
    case invalidAppliedRevision(
        displayUUID: String,
        assignmentRevision: UInt64,
        manifestRevision: UInt64
    )
    case emptyAcknowledgmentError(displayUUID: String)
    case unknownFields(type: String, fields: [String])
}

/// One stop in a display's playlist: the content to render plus how long to stay on it.
struct DisplayPlaylistEntry: Codable, Hashable, Sendable {
    /// A week. Generous enough for "basically never rotate" while still bounding the
    /// timer the extension arms from a value the app hands it.
    static let maximumDurationSeconds: Double = 7 * 24 * 60 * 60

    let contentUUID: String
    let kind: WallpaperContentKind
    let contentHash: String?
    let resourcePath: String
    let posterPath: String?
    let title: String
    /// Seconds on screen before the playlist advances. Zero means "never advance on a
    /// timer" — what a single-wallpaper program uses, and what the last remaining entry
    /// of a one-item playlist falls back to.
    let durationSeconds: Double

    init(
        contentUUID: String,
        kind: WallpaperContentKind,
        contentHash: String? = nil,
        resourcePath: String,
        posterPath: String? = nil,
        title: String,
        durationSeconds: Double
    ) {
        self.contentUUID = contentUUID
        self.kind = kind
        self.contentHash = contentHash
        self.resourcePath = resourcePath
        self.posterPath = posterPath
        self.title = title
        self.durationSeconds = durationSeconds
    }

    fileprivate enum CodingKeys: String, CodingKey, CaseIterable {
        case contentUUID
        case kind
        case contentHash
        case resourcePath
        case posterPath
        case title
        case durationSeconds
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(
            allowed: CodingKeys.allCases.map(\.rawValue),
            type: String(describing: Self.self)
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contentUUID = try container.decode(String.self, forKey: .contentUUID)
        kind = try container.decode(WallpaperContentKind.self, forKey: .kind)
        contentHash = try container.decodeIfPresent(
            String.self,
            forKey: .contentHash
        )
        resourcePath = try container.decode(String.self, forKey: .resourcePath)
        posterPath = try container.decodeIfPresent(
            String.self,
            forKey: .posterPath
        )
        title = try container.decode(String.self, forKey: .title)
        durationSeconds = try container.decode(
            Double.self,
            forKey: .durationSeconds
        )
    }

    /// Whether this entry renders the same pixels as `other`. Titles, posters and
    /// durations are metadata: they change what Settings and the scheduler see, never
    /// what the renderer has to rebuild.
    func hasSameRenderableContent(as other: Self) -> Bool {
        contentUUID == other.contentUUID
            && kind == other.kind
            && contentHash == other.contentHash
            && resourcePath == other.resourcePath
    }

    fileprivate func validate(displayUUID: String) throws {
        guard UUID(uuidString: contentUUID) != nil else {
            throw WallpaperAssignmentValidationError.invalidContentUUID(
                displayUUID: displayUUID,
                contentUUID: contentUUID
            )
        }
        guard ManifestPath.isSafeRelative(resourcePath) else {
            throw WallpaperAssignmentValidationError.unsafeResourcePath(
                displayUUID: displayUUID,
                path: resourcePath
            )
        }
        if let posterPath, !ManifestPath.isSafeRelative(posterPath) {
            throw WallpaperAssignmentValidationError.unsafePosterPath(
                displayUUID: displayUUID,
                path: posterPath
            )
        }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw WallpaperAssignmentValidationError.emptyTitle(
                displayUUID: displayUUID
            )
        }
        if let contentHash,
           contentHash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
               || contentHash.unicodeScalars.contains(where: {
                   CharacterSet.controlCharacters.contains($0)
               }) {
            throw WallpaperAssignmentValidationError.invalidContentHash(
                displayUUID: displayUUID
            )
        }
        guard durationSeconds.isFinite,
              durationSeconds >= 0,
              durationSeconds <= Self.maximumDurationSeconds else {
            throw WallpaperAssignmentValidationError.invalidEntryDuration(
                displayUUID: displayUUID,
                contentUUID: contentUUID
            )
        }
    }
}

struct DisplayWallpaperAssignment: Codable, Hashable, Sendable {
    /// A playlist long enough to be a mistake rather than a request. Every entry is a
    /// deployed copy inside the extension container, so this also bounds disk use.
    static let maximumEntryCount = 512

    let displayUUID: String
    /// The app-side playlist this program came from, or nil when a single wallpaper was
    /// applied directly. The extension only uses it to decide whether a new manifest is
    /// "the same playlist, edited" (keep the position) or a different program (start over).
    let playlistID: String?
    let mode: WallpaperPlaylistMode
    let entries: [DisplayPlaylistEntry]
    let assignmentRevision: UInt64

    init(
        displayUUID: String,
        playlistID: String? = nil,
        mode: WallpaperPlaylistMode = .ordered,
        entries: [DisplayPlaylistEntry],
        assignmentRevision: UInt64
    ) throws {
        self.displayUUID = displayUUID
        self.playlistID = playlistID
        self.mode = mode
        self.entries = entries
        self.assignmentRevision = assignmentRevision
        try validate(manifestRevision: .max)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case displayUUID
        case playlistID
        case mode
        case entries
        case assignmentRevision
    }

    /// Schema 1 stored exactly one content per display, inline. Decoding it as a
    /// one-entry playlist means an app updated in place keeps native playback instead
    /// of falling back to the overlay until the user re-applies.
    private enum LegacyCodingKeys: String, CodingKey, CaseIterable {
        case contentUUID
        case kind
        case contentHash
        case resourcePath
        case posterPath
        case title
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Exactly one shape, never a blend: an `entries` document must not also carry the
        // schema-1 inline fields. Allowing both unconditionally meant a v2 document could
        // smuggle a `contentUUID` past validation and have it silently ignored.
        let isLegacy = !container.contains(.entries)
        try decoder.rejectUnknownKeys(
            allowed: CodingKeys.allCases.map(\.rawValue)
                + (isLegacy ? LegacyCodingKeys.allCases.map(\.rawValue) : []),
            type: String(describing: Self.self)
        )
        displayUUID = try container.decode(String.self, forKey: .displayUUID)
        playlistID = try container.decodeIfPresent(
            String.self,
            forKey: .playlistID
        )
        mode = try container.decodeIfPresent(
            WallpaperPlaylistMode.self,
            forKey: .mode
        ) ?? .ordered
        if !isLegacy {
            entries = try container.decode(
                [DisplayPlaylistEntry].self,
                forKey: .entries
            )
        } else {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            self.entries = [
                DisplayPlaylistEntry(
                    contentUUID: try legacy.decode(
                        String.self,
                        forKey: .contentUUID
                    ),
                    kind: try legacy.decode(
                        WallpaperContentKind.self,
                        forKey: .kind
                    ),
                    contentHash: try legacy.decodeIfPresent(
                        String.self,
                        forKey: .contentHash
                    ),
                    resourcePath: try legacy.decode(
                        String.self,
                        forKey: .resourcePath
                    ),
                    posterPath: try legacy.decodeIfPresent(
                        String.self,
                        forKey: .posterPath
                    ),
                    title: try legacy.decode(String.self, forKey: .title),
                    durationSeconds: 0
                )
            ]
        }
        assignmentRevision = try container.decode(
            UInt64.self,
            forKey: .assignmentRevision
        )
        try validate(manifestRevision: .max)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(displayUUID, forKey: .displayUUID)
        try container.encodeIfPresent(playlistID, forKey: .playlistID)
        try container.encode(mode, forKey: .mode)
        try container.encode(entries, forKey: .entries)
        try container.encode(assignmentRevision, forKey: .assignmentRevision)
    }

    fileprivate func validate(manifestRevision: UInt64) throws {
        guard let normalized = WallpaperDisplayUUID.normalized(displayUUID)
        else {
            throw WallpaperAssignmentValidationError.invalidDisplayUUID(
                displayUUID
            )
        }
        guard normalized == displayUUID else {
            throw WallpaperAssignmentValidationError.nonNormalizedDisplayUUID(
                displayUUID
            )
        }
        if let playlistID,
           WallpaperDisplayUUID.normalized(playlistID) != playlistID {
            throw WallpaperAssignmentValidationError.invalidPlaylistID(
                displayUUID: displayUUID,
                playlistID: playlistID
            )
        }
        guard !entries.isEmpty else {
            throw WallpaperAssignmentValidationError.emptyPlaylist(
                displayUUID: displayUUID
            )
        }
        guard entries.count <= Self.maximumEntryCount else {
            throw WallpaperAssignmentValidationError.oversizedPlaylist(
                displayUUID: displayUUID,
                count: entries.count
            )
        }
        guard assignmentRevision > 0,
              assignmentRevision <= manifestRevision else {
            throw WallpaperAssignmentValidationError.invalidAssignmentRevision(
                displayUUID: displayUUID,
                assignmentRevision: assignmentRevision,
                manifestRevision: manifestRevision
            )
        }
        for entry in entries {
            try entry.validate(displayUUID: displayUUID)
        }
    }

    fileprivate func hasSameContent(as other: Self) -> Bool {
        displayUUID == other.displayUUID
            && playlistID == other.playlistID
            && mode == other.mode
            && entries == other.entries
    }

    /// Whether the surfaces on this display can keep rendering across the change.
    /// Retitling or re-timing is metadata-only. A mode change resets the scheduler's walk,
    /// so the surface must follow it to the newly selected current entry.
    func hasSameRenderableContent(as other: Self) -> Bool {
        displayUUID == other.displayUUID
            && playlistID == other.playlistID
            && mode == other.mode
            && entries.count == other.entries.count
            && zip(entries, other.entries).allSatisfy {
                $0.hasSameRenderableContent(as: $1)
            }
    }

    func contains(contentUUID: String) -> Bool {
        entries.contains { $0.contentUUID == contentUUID }
    }
}

struct WallpaperAssignmentManifest: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 2
    /// Schema 1 assignments decode into one-entry playlists, so an older manifest left
    /// behind by a previous build is still consumable.
    static let minimumSupportedSchemaVersion = 1

    let schemaVersion: Int
    let revision: UInt64
    let assignments: [String: DisplayWallpaperAssignment]

    init(
        schemaVersion: Int = currentSchemaVersion,
        revision: UInt64,
        assignments: [String: DisplayWallpaperAssignment]
    ) throws {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.assignments = assignments
        try validate()
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case revision
        case assignments
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(
            allowed: CodingKeys.allCases.map(\.rawValue),
            type: String(describing: Self.self)
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        revision = try container.decode(UInt64.self, forKey: .revision)
        assignments = try container.decode(
            [String: DisplayWallpaperAssignment].self,
            forKey: .assignments
        )
        try validate()
    }

    /// Always stamps the current version. `schemaVersion` is preserved through decode so a
    /// rejection can name what it read, but a schema-1 manifest that has been decoded into
    /// playlists must not be written back out still claiming to be schema 1.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(revision, forKey: .revision)
        try container.encode(assignments, forKey: .assignments)
    }

    func validate() throws {
        guard schemaVersion >= Self.minimumSupportedSchemaVersion,
              schemaVersion <= Self.currentSchemaVersion else {
            throw WallpaperAssignmentValidationError.unsupportedSchema(
                schemaVersion
            )
        }
        guard revision > 0 else {
            throw WallpaperAssignmentValidationError.invalidManifestRevision(
                revision
            )
        }

        var normalizedDisplayUUIDs = Set<String>()
        for (key, assignment) in assignments {
            guard let normalized = WallpaperDisplayUUID.normalized(key) else {
                throw WallpaperAssignmentValidationError.invalidDisplayUUID(
                    key
                )
            }
            guard normalizedDisplayUUIDs.insert(normalized).inserted else {
                throw WallpaperAssignmentValidationError.duplicateDisplayUUID(
                    normalized
                )
            }
            guard normalized == key else {
                throw WallpaperAssignmentValidationError
                    .nonNormalizedDisplayUUID(key)
            }
            guard key == assignment.displayUUID else {
                throw WallpaperAssignmentValidationError.mismatchedDisplayUUID(
                    key: key,
                    assignment: assignment.displayUUID
                )
            }
            try assignment.validate(manifestRevision: revision)
        }
    }

    func validate(successorTo previous: Self) throws {
        try validate()
        guard revision > previous.revision else {
            throw WallpaperAssignmentValidationError
                .nonMonotonicManifestRevision(
                    previous: previous.revision,
                    current: revision
                )
        }

        for (displayUUID, assignment) in assignments {
            guard let previousAssignment = previous.assignments[displayUUID]
            else {
                continue
            }
            guard assignment.assignmentRevision
                >= previousAssignment.assignmentRevision else {
                throw WallpaperAssignmentValidationError
                    .nonMonotonicAssignmentRevision(
                        displayUUID: displayUUID,
                        previous: previousAssignment.assignmentRevision,
                        current: assignment.assignmentRevision
                    )
            }
            if !assignment.hasSameContent(as: previousAssignment),
               assignment.assignmentRevision
                    == previousAssignment.assignmentRevision {
                throw WallpaperAssignmentValidationError
                    .changedAssignmentWithoutRevisionAdvance(
                        displayUUID: displayUUID
                    )
            }
        }
    }
}

struct DisplayWallpaperAcknowledgment: Codable, Hashable, Sendable {
    let displayUUID: String
    /// The playlist entry the renderer settled on. With a rotating playlist this is
    /// whichever entry was current when the assignment was accepted, so callers match it
    /// against the assignment's entries rather than against a single expected value.
    let appliedContentUUID: String?
    let appliedAssignmentRevision: UInt64?
    let error: String?

    init(
        displayUUID: String,
        appliedContentUUID: String?,
        appliedAssignmentRevision: UInt64?,
        error: String?
    ) throws {
        self.displayUUID = displayUUID
        self.appliedContentUUID = appliedContentUUID
        self.appliedAssignmentRevision = appliedAssignmentRevision
        self.error = error
        try validate(manifestRevision: .max)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case displayUUID
        case appliedContentUUID
        case appliedAssignmentRevision
        case error
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(
            allowed: CodingKeys.allCases.map(\.rawValue),
            type: String(describing: Self.self)
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayUUID = try container.decode(String.self, forKey: .displayUUID)
        appliedContentUUID = try container.decodeIfPresent(
            String.self,
            forKey: .appliedContentUUID
        )
        appliedAssignmentRevision = try container.decodeIfPresent(
            UInt64.self,
            forKey: .appliedAssignmentRevision
        )
        error = try container.decodeIfPresent(String.self, forKey: .error)
        try validate(manifestRevision: .max)
    }

    fileprivate func validate(manifestRevision: UInt64) throws {
        guard let normalized = WallpaperDisplayUUID.normalized(displayUUID)
        else {
            throw WallpaperAssignmentValidationError.invalidDisplayUUID(
                displayUUID
            )
        }
        guard normalized == displayUUID else {
            throw WallpaperAssignmentValidationError.nonNormalizedDisplayUUID(
                displayUUID
            )
        }
        guard (appliedContentUUID == nil)
            == (appliedAssignmentRevision == nil) else {
            throw WallpaperAssignmentValidationError
                .incompleteAppliedAssignment(displayUUID: displayUUID)
        }
        if let appliedContentUUID,
           UUID(uuidString: appliedContentUUID) == nil {
            throw WallpaperAssignmentValidationError.invalidContentUUID(
                displayUUID: displayUUID,
                contentUUID: appliedContentUUID
            )
        }
        if let appliedAssignmentRevision,
           appliedAssignmentRevision == 0
                || appliedAssignmentRevision > manifestRevision {
            throw WallpaperAssignmentValidationError.invalidAppliedRevision(
                displayUUID: displayUUID,
                assignmentRevision: appliedAssignmentRevision,
                manifestRevision: manifestRevision
            )
        }
        if let error,
           error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw WallpaperAssignmentValidationError
                .emptyAcknowledgmentError(displayUUID: displayUUID)
        }
    }
}

struct WallpaperAssignmentAcknowledgment: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let manifestRevision: UInt64
    let displays: [String: DisplayWallpaperAcknowledgment]

    init(
        schemaVersion: Int = currentSchemaVersion,
        manifestRevision: UInt64,
        displays: [String: DisplayWallpaperAcknowledgment]
    ) throws {
        self.schemaVersion = schemaVersion
        self.manifestRevision = manifestRevision
        self.displays = displays
        try validate()
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case manifestRevision
        case displays
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(
            allowed: CodingKeys.allCases.map(\.rawValue),
            type: String(describing: Self.self)
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        manifestRevision = try container.decode(
            UInt64.self,
            forKey: .manifestRevision
        )
        displays = try container.decode(
            [String: DisplayWallpaperAcknowledgment].self,
            forKey: .displays
        )
        try validate()
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw WallpaperAssignmentValidationError.unsupportedSchema(
                schemaVersion
            )
        }
        guard manifestRevision > 0 else {
            throw WallpaperAssignmentValidationError.invalidManifestRevision(
                manifestRevision
            )
        }

        var normalizedDisplayUUIDs = Set<String>()
        for (key, acknowledgment) in displays {
            guard let normalized = WallpaperDisplayUUID.normalized(key) else {
                throw WallpaperAssignmentValidationError.invalidDisplayUUID(
                    key
                )
            }
            guard normalizedDisplayUUIDs.insert(normalized).inserted else {
                throw WallpaperAssignmentValidationError.duplicateDisplayUUID(
                    normalized
                )
            }
            guard normalized == key else {
                throw WallpaperAssignmentValidationError
                    .nonNormalizedDisplayUUID(key)
            }
            guard key == acknowledgment.displayUUID else {
                throw WallpaperAssignmentValidationError.mismatchedDisplayUUID(
                    key: key,
                    assignment: acknowledgment.displayUUID
                )
            }
            try acknowledgment.validate(manifestRevision: manifestRevision)
        }
    }
}

enum ManifestPath {
    static func isSafeRelative(_ path: String) -> Bool {
        guard !path.isEmpty,
              !NSString(string: path).isAbsolutePath,
              !path.contains("\\"),
              !path.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            return false
        }

        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { component in
                !component.isEmpty && component != "." && component != ".."
            }
    }
}

private struct StrictCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private extension Decoder {
    func rejectUnknownKeys(
        allowed: [String],
        type: String
    ) throws {
        let container = try container(keyedBy: StrictCodingKey.self)
        let allowed = Set(allowed)
        let unknown = container.allKeys
            .map(\.stringValue)
            .filter { !allowed.contains($0) }
            .sorted()
        guard unknown.isEmpty else {
            throw WallpaperAssignmentValidationError.unknownFields(
                type: type,
                fields: unknown
            )
        }
    }
}
