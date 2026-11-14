import AppKit
import CoreGraphics
import Foundation
import ImageIO
import os

/// One playlist stop, resolved against the extension container.
struct ResolvedPlaylistEntry: Sendable {
    let entry: DisplayPlaylistEntry
    let resourceURL: URL
    let posterURL: URL?
    let metalPackage: MetalScenePackage?

    var contentUUID: String { entry.contentUUID }
    var kind: WallpaperContentKind { entry.kind }
    var title: String { entry.title }

    var posterImage: CGImage? {
        guard let posterURL,
              let source = CGImageSourceCreateWithURL(
                  posterURL as CFURL,
                  nil
              ) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// A display's whole program plus where the scheduler currently has it. Every consumer
/// wants "what should be on screen now", so the single-content accessors forward to the
/// current entry and the rest of the extension never has to know a playlist is involved.
struct ResolvedWallpaperAssignment: Sendable {
    let assignment: DisplayWallpaperAssignment
    /// Never empty: the manifest rejects empty playlists and resolution is all-or-nothing,
    /// so an entry whose file went missing fails the whole display rather than leaving a
    /// hole the scheduler could land on.
    let entries: [ResolvedPlaylistEntry]
    /// Stamped from `PlaylistScheduler` when the assignment is handed out — never stored,
    /// because it moves on its own while the resolved entries stay put.
    var currentIndex: Int = 0

    var current: ResolvedPlaylistEntry {
        entries[min(max(currentIndex, 0), entries.count - 1)]
    }

    var resourceURL: URL { current.resourceURL }
    var posterURL: URL? { current.posterURL }
    var metalPackage: MetalScenePackage? { current.metalPackage }
    var posterImage: CGImage? { current.posterImage }
    var contentUUID: String { current.contentUUID }
    var kind: WallpaperContentKind { current.kind }
    var title: String { current.title }
    var isPlaylist: Bool { entries.count > 1 }
}

struct DisplayWallpaperSlot: Sendable {
    let choiceID: String
    let displayName: String
    let anchorURL: URL
    let thumbnailURL: URL?
    let assignment: ResolvedWallpaperAssignment?
}

func canonicalDisplayUUID(for displayID: CGDirectDisplayID) -> String? {
    guard displayID != 0,
          let displayUUID =
              CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
          let value = CFUUIDCreateString(nil, displayUUID) else {
        return nil
    }
    return WallpaperDisplayUUID.normalized(value as String)
}

final class WallpaperAssignmentStore: @unchecked Sendable {
    static let shared = WallpaperAssignmentStore()

    private static let notification =
        "dev.3xhaust.WorkshopWallpaperBridge.wallpaper.assignmentsChanged"
    private static let manifestFilename = "driftwood-assignments.json"
    private static let acknowledgmentFilename =
        "driftwood-assignment-ack.json"

    private struct Batch {
        let token: UUID
        var remaining: Int
        var errors: [String]
        /// Whether a failure in this batch may be published as an assignment error. False
        /// for a playlist rotation: the assignment itself succeeded, and reporting a
        /// rotation's stumble against the current revision makes the app conclude native
        /// playback died and fall back to its desktop overlay.
        let reportsFailures: Bool
    }

    private struct DisplaySlotMetadata: Decodable {
        let displayUUID: String
        let choiceID: String
        let displayName: String
        let anchorPath: String
    }

    private struct State {
        var manifest: WallpaperAssignmentManifest?
        var assignments: [String: ResolvedWallpaperAssignment] = [:]
        var acknowledgments: [String: DisplayWallpaperAcknowledgment] = [:]
        /// What each display's cached host-side snapshot was last invalidated for —
        /// revision *and* content, since rotating within one playlist changes the image
        /// without changing the revision.
        var snapshotKeys: [String: String] = [:]
        var batches: [String: Batch] = [:]
        var observing = false
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let acknowledgmentWriteLock =
        OSAllocatedUnfairLock(initialState: ())
    private let documentsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents", isDirectory: true)

    private init() {}

    func start() {
        let shouldStart = lock.withLock { state -> Bool in
            guard !state.observing else { return false }
            state.observing = true
            return true
        }
        guard shouldStart else { return }

        // Before the first reload: the scheduler has to know the checkpointed positions
        // so a restart resumes a playlist where it left off.
        PlaylistScheduler.shared.start()

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let store = Unmanaged<WallpaperAssignmentStore>
                    .fromOpaque(observer)
                    .takeUnretainedValue()
                Lifecycle.queue.async {
                    store.reloadAndApply()
                }
            },
            Self.notification as CFString,
            nil,
            .deliverImmediately
        )

        reload(applyToHostedSurfaces: false)
    }

    func assignment(
        for displayID: CGDirectDisplayID
    ) -> ResolvedWallpaperAssignment? {
        guard let displayUUID = canonicalDisplayUUID(for: displayID) else {
            return nil
        }
        return resolvedAssignment(displayUUID: displayUUID)
    }

    /// Resolve the current content behind a permanent per-display Settings
    /// choice. Preview requests identify the display by this UUID-backed choice
    /// rather than reliably supplying a Core Graphics display ID.
    func assignment(
        forDisplayChoiceID choiceID: String
    ) -> ResolvedWallpaperAssignment? {
        guard let displayUUID = WallpaperDisplayUUID.normalized(choiceID) else {
            return nil
        }
        return resolvedAssignment(displayUUID: displayUUID)
    }

    /// WallpaperAgent can omit a preview's choice configuration after an
    /// extension restart while retaining the immutable slot anchor URL.
    func assignment(
        forDisplaySlotResourceURL resourceURL: URL
    ) -> ResolvedWallpaperAssignment? {
        let requestedURL = resourceURL.standardizedFileURL
        return settingsSlots().first {
            $0.anchorURL.standardizedFileURL == requestedURL
        }?.assignment
    }

    /// The resolved program for a display with the scheduler's current position stamped
    /// in. Everything outside this file goes through here rather than reading the cached
    /// entries, so nothing can render an entry the scheduler has already moved past.
    private func resolvedAssignment(
        displayUUID: String
    ) -> ResolvedWallpaperAssignment? {
        guard var resolved = lock.withLock({ $0.assignments[displayUUID] })
        else {
            return nil
        }
        resolved.currentIndex =
            PlaylistScheduler.shared.currentIndex(for: displayUUID) ?? 0
        return resolved
    }

    /// The permanent choices exposed to Wallpaper Settings. Content metadata is
    /// read from the assignment snapshot, while each choice keeps its immutable
    /// per-display anchor file.
    func settingsSlots() -> [DisplayWallpaperSlot] {
        let slotsURL = documentsURL.appendingPathComponent(
            "display-slots",
            isDirectory: true
        )
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: slotsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return directories.compactMap { directory in
            guard
                (try? directory.resourceValues(
                    forKeys: [.isDirectoryKey]
                ).isDirectory) == true,
                let data = try? Data(
                    contentsOf: directory.appendingPathComponent("slot.json")
                ),
                let metadata = try? JSONDecoder().decode(
                    DisplaySlotMetadata.self,
                    from: data
                ),
                metadata.displayUUID == directory.lastPathComponent,
                WallpaperDisplayUUID.normalized(metadata.displayUUID)
                    == metadata.displayUUID,
                metadata.choiceID == metadata.displayUUID
            else {
                return nil
            }
            let anchorURL = directory.appendingPathComponent(
                metadata.anchorPath
            )
            guard PathSafety.contained(anchorURL, in: directory),
                  FileManager.default.fileExists(atPath: anchorURL.path)
            else {
                return nil
            }
            let fallbackThumbnail = directory.appendingPathComponent(
                "thumbnail.jpg"
            )
            let assignment = resolvedAssignment(
                displayUUID: metadata.displayUUID
            )
            let thumbnailURL =
                assignment?.posterURL
                ?? (FileManager.default.fileExists(
                    atPath: fallbackThumbnail.path
                ) ? fallbackThumbnail : nil)
            return DisplayWallpaperSlot(
                choiceID: metadata.choiceID,
                displayName: metadata.displayName,
                anchorURL: anchorURL,
                thumbnailURL: thumbnailURL,
                assignment: assignment
            )
        }
        .sorted {
            $0.displayName.localizedStandardCompare($1.displayName)
                == .orderedAscending
        }
    }

    func isCurrent(_ assignment: DisplayWallpaperAssignment) -> Bool {
        lock.withLock {
            $0.manifest?.assignments[assignment.displayUUID] == assignment
        }
    }

    func markSurfaceApplied(
        _ assignment: DisplayWallpaperAssignment,
        contentUUID: String,
        key: DisplayKey,
        rendererID: Int
    ) {
        guard isCurrent(assignment),
              WallpaperState.shared.acceptAssignment(
                  contentID: contentUUID,
                  assignmentRevision: assignment.assignmentRevision,
                  for: key,
                  rendererID: rendererID
              ) else {
            return
        }
        WallpaperPrefs.shared.updateCurrentVideo()
        acknowledgeIfEverySurfaceMatches(assignment)
    }

    func recordError(
        _ error: String,
        for assignment: DisplayWallpaperAssignment
    ) {
        guard isCurrent(assignment) else { return }
        // Another path may already have delivered this assignment. Never turn a success
        // into a failure: the app treats a single error entry as "native playback failed"
        // and falls back to the desktop overlay.
        guard !acknowledgeIfEverySurfaceMatches(assignment) else { return }
        finishAcknowledgment(
            assignment: assignment,
            appliedContentUUID: nil,
            error: error
        )
    }

    /// Put the display on whatever entry the scheduler has advanced to. Called from the
    /// scheduler's timer and from Previous/Next, both already on `RenderQueue.serial`.
    func applyCurrentPlaylistEntry(for displayUUID: String) {
        guard let resolved = resolvedAssignment(displayUUID: displayUUID) else {
            return
        }
        extensionLog(
            "[Playlist] \(displayUUID) → entry \(resolved.currentIndex + 1)"
                + "/\(resolved.entries.count) “\(resolved.title)”"
        )
        // Silently: a rotation that lands while the display is asleep or between Spaces
        // has no surface to switch, and publishing that as an assignment failure would
        // make the app tear native playback down and start its overlay.
        apply(resolved, reportingFailures: false)
    }

    private var manifestURL: URL {
        documentsURL.appendingPathComponent(Self.manifestFilename)
    }

    private var acknowledgmentURL: URL {
        documentsURL.appendingPathComponent(Self.acknowledgmentFilename)
    }

    private func reloadAndApply() {
        reload(applyToHostedSurfaces: true)
    }

    private func reload(applyToHostedSurfaces: Bool) {
        do {
            let data = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(
                WallpaperAssignmentManifest.self,
                from: data
            )
            let previous = lock.withLock { $0.manifest }
            if manifest == previous {
                guard applyToHostedSurfaces else { return }
                for assignment in manifest.assignments.values {
                    do {
                        let resolved = try resolve(assignment)
                        lock.withLock {
                            $0.assignments[assignment.displayUUID] = resolved
                        }
                        PlaylistScheduler.shared.sync(assignment)
                        if !acknowledgeIfEverySurfaceMatches(assignment),
                           let stamped = resolvedAssignment(
                               displayUUID: assignment.displayUUID
                           ) {
                            apply(stamped)
                        }
                    } catch {
                        finishAcknowledgment(
                            assignment: assignment,
                            appliedContentUUID: nil,
                            error: error.localizedDescription
                        )
                    }
                }
                return
            }
            if let previous {
                try manifest.validate(successorTo: previous)
            } else {
                try manifest.validate()
            }

            var resolved: [String: ResolvedWallpaperAssignment] = [:]
            var resolutionErrors: [String: String] = [:]
            for (displayUUID, assignment) in manifest.assignments {
                do {
                    resolved[displayUUID] = try resolve(assignment)
                } catch {
                    resolutionErrors[displayUUID] =
                        error.localizedDescription
                }
            }

            var allDisplayUUIDs = Set(manifest.assignments.keys)
            if let previous {
                allDisplayUUIDs.formUnion(previous.assignments.keys)
            }
            let changed = allDisplayUUIDs.filter {
                previous?.assignments[$0] != manifest.assignments[$0]
            }
            let renderChanges = changed.filter { displayUUID in
                guard let prior = previous?.assignments[displayUUID],
                      let current = manifest.assignments[displayUUID] else {
                    return true
                }
                return !current.hasSameRenderableContent(as: prior)
            }
            let resolvedAssignments = resolved
            lock.withLock { state in
                state.manifest = manifest
                state.assignments = resolvedAssignments
                state.batches = state.batches.filter {
                    !changed.contains($0.key)
                }
                state.acknowledgments = state.acknowledgments.filter {
                    guard let assignment = manifest.assignments[$0.key],
                          let applied = $0.value.appliedContentUUID else {
                        return false
                    }
                    return assignment.contains(contentUUID: applied)
                        && assignment.assignmentRevision
                            == $0.value.appliedAssignmentRevision
                }
            }

            // Every display that still has a program, changed or not: durations and mode
            // live in the manifest, so this is also how a re-timed playlist reaches the
            // running timer.
            for assignment in manifest.assignments.values
            where resolved[assignment.displayUUID] != nil {
                PlaylistScheduler.shared.sync(assignment)
            }
            PlaylistScheduler.shared.retain(
                displayUUIDs: Set(resolved.keys)
            )

            extensionLog(
                "[Assignments] Loaded revision \(manifest.revision), "
                    + "\(changed.count) display assignment(s) changed"
            )

            guard applyToHostedSurfaces else { return }
            for displayUUID in changed {
                if resolved[displayUUID] != nil,
                   let stamped = resolvedAssignment(displayUUID: displayUUID) {
                    if renderChanges.contains(displayUUID) {
                        apply(stamped)
                    } else {
                        acceptMetadataUpdate(stamped)
                    }
                } else if let assignment =
                            manifest.assignments[displayUUID],
                          let error = resolutionErrors[displayUUID] {
                    finishAcknowledgment(
                        assignment: assignment,
                        appliedContentUUID: nil,
                        error: error
                    )
                }
            }
        } catch {
            extensionLog("[Assignments] Rejected manifest: \(error)")
        }
    }

    private func resolve(
        _ assignment: DisplayWallpaperAssignment
    ) throws -> ResolvedWallpaperAssignment {
        ResolvedWallpaperAssignment(
            assignment: assignment,
            entries: try assignment.entries.map(resolve(entry:))
        )
    }

    private func resolve(
        entry: DisplayPlaylistEntry
    ) throws -> ResolvedPlaylistEntry {
        let resourceURL = try containedExistingURL(
            relativePath: entry.resourcePath,
            label: "resource"
        )
        let posterURL = try entry.posterPath.map {
            try containedExistingURL(relativePath: $0, label: "poster")
        }

        let package: MetalScenePackage?
        switch entry.kind {
        case .video:
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: resourceURL.path,
                isDirectory: &isDirectory
            ), !isDirectory.boolValue,
                !MetalScenePackage.isSceneResource(resourceURL) else {
                throw NSError(
                    domain: "DriftwoodWallpaperExtension.Assignments",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Video resource is not a regular video file."
                    ]
                )
            }
            package = nil
        case .metalScene:
            let loaded = try MetalScenePackage.load(from: resourceURL)
            if let expectedHash = entry.contentHash,
               loaded.contentHash != expectedHash {
                throw NSError(
                    domain: "DriftwoodWallpaperExtension.Assignments",
                    code: 3,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Metal scene content hash does not match."
                    ]
                )
            }
            package = loaded
        }
        return ResolvedPlaylistEntry(
            entry: entry,
            resourceURL: resourceURL,
            posterURL: posterURL,
            metalPackage: package
        )
    }

    private func containedExistingURL(
        relativePath: String,
        label: String
    ) throws -> URL {
        let url = documentsURL.appendingPathComponent(relativePath)
        guard PathSafety.contained(url, in: documentsURL),
              FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(
                domain: "DriftwoodWallpaperExtension.Assignments",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Assignment \(label) is missing or outside Documents."
                ]
            )
        }
        return url
    }

    private func apply(
        _ resolved: ResolvedWallpaperAssignment,
        reportingFailures: Bool = true
    ) {
        let assignment = resolved.assignment
        let targets = WallpaperState.shared.hostedLiveSurfaces().filter {
            canonicalDisplayUUID(for: $0.key.displayID)
                == assignment.displayUUID
        }
        guard !targets.isEmpty else {
            if reportingFailures {
                finishAcknowledgment(
                    assignment: assignment,
                    appliedContentUUID: nil,
                    error: "No hosted live wallpaper surface exists for this display."
                )
            }
            return
        }

        // A rotation must not displace a batch that is still settling a *new* assignment:
        // the displaced legs would fail their token check, that batch would never
        // complete, and the app's `waitForAssignments` would time out into overlay
        // fallback for an assignment that is actually live.
        let token = UUID()
        let claimed = lock.withLock { state -> Bool in
            if !reportingFailures,
               let pending = state.batches[assignment.displayUUID],
               pending.reportsFailures {
                return false
            }
            state.batches[assignment.displayUUID] = Batch(
                token: token,
                remaining: targets.count,
                errors: [],
                reportsFailures: reportingFailures
            )
            return true
        }
        guard claimed else {
            extensionLog(
                "[Playlist] \(assignment.displayUUID) rotation deferred — an "
                    + "assignment change is still settling"
            )
            return
        }

        for target in targets {
            startSwitch(resolved, target: target, token: token)
        }
    }

    /// Hand one surface its new content. The surface owns the crossfade, the
    /// build serialization and the newest-wins queueing; this only translates a
    /// resolved assignment into a content request and reports the result back into
    /// the batch bookkeeping.
    private func startSwitch(
        _ resolved: ResolvedWallpaperAssignment,
        target: HostedWallpaperSurface,
        token: UUID
    ) {
        let assignment = resolved.assignment
        let entry = resolved.current
        let content = WallpaperContent(
            id: entry.contentUUID,
            kind: entry.kind,
            resourceURL: entry.resourceURL,
            metalPackage: entry.metalPackage,
            variantSelector: entry.kind == .video
                ? makeVariantSelector(
                    choice: entry.contentUUID,
                    fallback: entry.resourceURL
                )
                : nil,
            posterImage: entry.posterImage
        )
        let store = self
        let contentUUID = entry.contentUUID
        target.surface.setContent(content) { result in
            switch result {
            case .success(let rendererID):
                WallpaperPrefs.shared.applyCurrentState()
                store.completeBatch(
                    token: token,
                    assignment: assignment,
                    contentUUID: contentUUID,
                    key: target.key,
                    rendererID: rendererID,
                    result: .success(())
                )
            case .failure(let error):
                store.completeBatch(
                    token: token,
                    assignment: assignment,
                    contentUUID: contentUUID,
                    key: target.key,
                    rendererID: nil,
                    result: .failure(error)
                )
            }
        }
    }

    private func acceptMetadataUpdate(
        _ resolved: ResolvedWallpaperAssignment
    ) {
        let assignment = resolved.assignment
        let targets = WallpaperState.shared.hostedLiveSurfaces().filter {
            canonicalDisplayUUID(for: $0.key.displayID)
                == assignment.displayUUID
        }
        guard !targets.isEmpty else {
            finishAcknowledgment(
                assignment: assignment,
                appliedContentUUID: nil,
                error: "No hosted live wallpaper surface exists for this display."
            )
            return
        }
        let accepted = targets.allSatisfy { target in
            guard let rendererID = target.renderer?.debugID else {
                return false
            }
            // The surface is already rendering the right file — only the revision it is
            // credited with moves. Keep whatever entry it is on rather than the
            // scheduler's idea of "current", which may have advanced past it.
            return WallpaperState.shared.acceptAssignment(
                contentID: target.contentID ?? resolved.contentUUID,
                assignmentRevision: assignment.assignmentRevision,
                for: target.key,
                rendererID: rendererID
            )
        }
        guard accepted else {
            finishAcknowledgment(
                assignment: assignment,
                appliedContentUUID: nil,
                error: "A wallpaper surface could not accept the metadata update."
            )
            return
        }
        WallpaperPrefs.shared.updateCurrentVideo()
        acknowledgeIfEverySurfaceMatches(assignment)
    }

    private func completeBatch(
        token: UUID,
        assignment: DisplayWallpaperAssignment,
        contentUUID: String,
        key: DisplayKey,
        rendererID: Int?,
        result: Result<Void, Error>
    ) {
        guard isCurrent(assignment) else { return }
        if case .success = result, let rendererID {
            if WallpaperState.shared.acceptAssignment(
                contentID: contentUUID,
                assignmentRevision: assignment.assignmentRevision,
                for: key,
                rendererID: rendererID
            ) {
                WallpaperPrefs.shared.updateCurrentVideo()
            }
        }

        let completed = lock.withLock { state -> Batch? in
            guard var batch = state.batches[assignment.displayUUID],
                  batch.token == token else {
                return nil
            }
            if case .failure(let error) = result {
                batch.errors.append(error.localizedDescription)
            }
            batch.remaining -= 1
            if batch.remaining > 0 {
                state.batches[assignment.displayUUID] = batch
                return nil
            }
            state.batches.removeValue(forKey: assignment.displayUUID)
            return batch
        }
        guard let completed else { return }
        // Try the success path first even when a leg reported an error: a surface can fail
        // for a reason that has stopped being true by the time the batch closes — a Space
        // closing mid-switch fails its leg, then disappears from `hostedLiveSurfaces()`, so
        // the surfaces that remain do all match. Publishing the error anyway would make the
        // app roll the manifest back and start its overlay over content that is live.
        guard !acknowledgeIfEverySurfaceMatches(assignment) else { return }
        guard completed.reportsFailures else {
            // A rotation that could not build. The assignment is unchanged and still
            // applied, so leave the acknowledgment alone; the next rotation retries.
            if let error = completed.errors.first {
                extensionLog(
                    "[Playlist] \(assignment.displayUUID) rotation failed: \(error)"
                )
            }
            return
        }
        if let error = completed.errors.first {
            finishAcknowledgment(
                assignment: assignment,
                appliedContentUUID: nil,
                error: error
            )
        }
    }

    /// Whether every surface on this display is settled on one entry of this program.
    ///
    /// Membership rather than a single expected content id: the scheduler can rotate
    /// between a switch starting and this running, and the assignment is no less applied
    /// for having moved on to the next wallpaper in the same playlist.
    @discardableResult
    private func acknowledgeIfEverySurfaceMatches(
        _ assignment: DisplayWallpaperAssignment
    ) -> Bool {
        let surfaces = WallpaperState.shared.hostedLiveSurfaces().filter {
            canonicalDisplayUUID(for: $0.key.displayID)
                == assignment.displayUUID
        }
        guard !surfaces.isEmpty,
              surfaces.allSatisfy({
                  $0.renderer != nil
                      && $0.assignmentRevision
                          == assignment.assignmentRevision
              }),
              let applied = surfaces.first?.contentID,
              surfaces.allSatisfy({ $0.contentID == applied }),
              assignment.contains(contentUUID: applied) else {
            return false
        }
        finishAcknowledgment(
            assignment: assignment,
            appliedContentUUID: applied,
            error: nil
        )
        return true
    }

    private func finishAcknowledgment(
        assignment: DisplayWallpaperAssignment,
        appliedContentUUID: String?,
        error: String?
    ) {
        acknowledgmentWriteLock.withLock { _ in
            guard isCurrent(assignment) else { return }
            do {
                let prior = lock.withLock {
                    $0.acknowledgments[assignment.displayUUID]
                }
                let display = try DisplayWallpaperAcknowledgment(
                    displayUUID: assignment.displayUUID,
                    appliedContentUUID: error == nil
                        ? appliedContentUUID
                        : prior?.appliedContentUUID,
                    appliedAssignmentRevision: error == nil
                        ? assignment.assignmentRevision
                        : prior?.appliedAssignmentRevision,
                    error: error
                )
                let snapshot = lock.withLock { state
                    -> (
                        UInt64,
                        [String: DisplayWallpaperAcknowledgment],
                        Bool
                    )? in
                    guard let manifest = state.manifest,
                          manifest.assignments[assignment.displayUUID]
                            == assignment else {
                        return nil
                    }
                    state.acknowledgments[assignment.displayUUID] = display
                    let snapshotKey = display.appliedContentUUID.map {
                        "\(assignment.assignmentRevision)#\($0)"
                    }
                    let shouldInvalidateSnapshots =
                        error == nil
                        && state.snapshotKeys[assignment.displayUUID]
                            != snapshotKey
                    if shouldInvalidateSnapshots {
                        state.snapshotKeys[assignment.displayUUID] =
                            snapshotKey
                    }
                    return (
                        manifest.revision,
                        state.acknowledgments,
                        shouldInvalidateSnapshots
                    )
                }
                guard let snapshot else { return }
                let acknowledgment = try WallpaperAssignmentAcknowledgment(
                    manifestRevision: snapshot.0,
                    displays: snapshot.1
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(acknowledgment).write(
                    to: acknowledgmentURL,
                    options: .atomic
                )
                extensionLog(
                    "[Assignments] \(assignment.displayUUID) revision "
                        + "\(assignment.assignmentRevision) "
                        + (error.map { "failed: \($0)" } ?? "accepted")
                )
                if snapshot.2 {
                    WallpaperSnapshotInvalidator.shared
                        .invalidateSnapshots()
                }
            } catch {
                extensionLog(
                    "[Assignments] Failed to publish acknowledgment: \(error)"
                )
            }
        }
    }
}
