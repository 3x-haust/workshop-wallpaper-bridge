import Darwin
import Foundation

/// Seam over `FileManager`'s trash/remove operations so tests can verify the
/// library-asset removal path prefers Trash (recoverable) over a permanent
/// delete, and can simulate a volume that doesn't support Trash.
public protocol AssetTrashing: Sendable {
    /// Moves `url` to the Trash. Mirrors `FileManager.trashItem(at:resultingItemURL:)`.
    func trashItem(at url: URL) throws
    /// Permanently deletes `url`. Mirrors `FileManager.removeItem(at:)`.
    func removeItem(at url: URL) throws
}

public struct FileManagerAssetTrasher: AssetTrashing {
    public init() {}

    public func trashItem(at url: URL) throws {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
    }

    public func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

public struct LibraryStore: Sendable {
    public let root: URL
    private let trasher: AssetTrashing

    public init(root: URL, trasher: AssetTrashing = FileManagerAssetTrasher()) {
        self.root = root
        self.trasher = trasher
    }

    public func load() throws -> LibraryManifest {
        let manifestURL = root.appending(path: "library.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return LibraryManifest(generatedAt: Date(), assets: [])
        }
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder.bridge.decode(LibraryManifest.self, from: data)
        let repaired = repairStoredAssets(in: manifest)
        if repaired != manifest {
            try? save(repaired)
        }
        return repaired
    }

    public func importAsset(_ asset: WallpaperAsset) throws -> WallpaperAsset {
        try FileManager.default.createDirectory(at: assetsRoot, withIntermediateDirectories: true)
        let directoryName = storageDirectoryName(for: asset.id)
        let target = assetsRoot.appending(path: directoryName)
        let replacement = assetsRoot.appending(path: ".\(directoryName).incoming-\(UUID().uuidString)")
        let backup = assetsRoot.appending(path: ".\(directoryName).previous-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: URL(filePath: asset.projectDirectory), to: replacement)
        try replaceDirectory(target: target, replacement: replacement, backup: backup)
        let imported = rewrite(asset: asset, source: URL(filePath: asset.projectDirectory), target: target)
        var manifest = try load()
        manifest = LibraryManifest(
            generatedAt: Date(),
            assets: (manifest.assets.filter { $0.id != asset.id } + [imported])
                .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        )
        try save(manifest)
        return imported
    }

    public func importVideoFile(_ url: URL) throws -> WallpaperAsset {
        let source = url.standardizedFileURL
        guard isRegularFile(source) else {
            throw LibraryStoreError.notRegularFile(source.path)
        }
        let ext = source.pathExtension.lowercased()
        guard manualVideoExtensions.contains(ext) else {
            throw LibraryStoreError.unsupportedVideoExtension(ext)
        }
        try FileManager.default.createDirectory(at: assetsRoot, withIntermediateDirectories: true)
        let id = "manual-video-\(UUID().uuidString)"
        let directoryName = storageDirectoryName(for: id)
        let target = assetsRoot.appending(path: directoryName)
        let replacement = assetsRoot.appending(path: ".\(directoryName).incoming-\(UUID().uuidString)")
        let entrypoint = target.appending(path: source.lastPathComponent)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        do {
            try FileManager.default.copyItem(at: source, to: replacement.appending(path: source.lastPathComponent))
            try replaceDirectory(
                target: target,
                replacement: replacement,
                backup: assetsRoot.appending(path: ".\(directoryName).previous-\(UUID().uuidString)")
            )
        } catch {
            if FileManager.default.fileExists(atPath: replacement.path) {
                try? FileManager.default.removeItem(at: replacement)
            }
            throw error
        }
        let imported = WallpaperAsset(
            id: id,
            title: source.deletingPathExtension().lastPathComponent,
            kind: .video,
            supportStatus: manualPlayableVideoExtensions.contains(ext) ? .playable : .needsConversion,
            source: .manualFolder,
            projectDirectory: target.path,
            entrypoint: entrypoint.path,
            thumbnail: nil,
            workshopId: nil,
            redistributionAllowed: false,
            issues: []
        )
        var manifest = try load()
        manifest = LibraryManifest(
            generatedAt: Date(),
            assets: (manifest.assets + [imported])
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        )
        try save(manifest)
        return imported
    }

    public func replaceAsset(_ asset: WallpaperAsset) throws {
        var manifest = try load()
        manifest = LibraryManifest(
            generatedAt: Date(),
            assets: (manifest.assets.filter { $0.id != asset.id } + [asset])
                .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        )
        try save(manifest)
    }

    public func installSceneRenderCache(assetID: WallpaperAsset.ID, videoURL: URL) throws -> WallpaperAsset {
        let source = videoURL.standardizedFileURL
        guard SceneRenderCache.isPlayableVideoFile(source) else {
            if isRegularFile(source) {
                throw LibraryStoreError.unsupportedVideoExtension(source.pathExtension.lowercased())
            }
            throw LibraryStoreError.notRegularFile(source.path)
        }

        let manifest = try load()
        guard let asset = manifest.assets.first(where: { $0.id == assetID }) else {
            throw LibraryStoreError.missingAsset(assetID)
        }
        guard asset.kind == .scene else {
            throw LibraryStoreError.assetIsNotScene(assetID)
        }

        let projectDirectory = URL(filePath: asset.projectDirectory).standardizedFileURL
        guard isInsideAssetsRoot(projectDirectory) else {
            throw LibraryStoreError.assetOutsideLibrary(assetID)
        }

        let cacheDirectory = SceneRenderCache.cacheDirectory(in: projectDirectory)
        guard !isSymbolicLink(cacheDirectory) else {
            throw LibraryStoreError.unsafeSceneRenderCacheDirectory(assetID)
        }
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        guard isInside(cacheDirectory, parent: projectDirectory) else {
            throw LibraryStoreError.unsafeSceneRenderCacheDirectory(assetID)
        }
        let destination = SceneRenderCache.videoURL(
            in: projectDirectory,
            fileExtension: source.pathExtension
        )
        if source.resolvingSymlinksInPath().path != destination.resolvingSymlinksInPath().path {
            let temporary = cacheDirectory.appending(
                path: ".\(SceneRenderCache.baseFileName)-\(UUID().uuidString).\(source.pathExtension)"
            )
            try FileManager.default.copyItem(at: source, to: temporary)
            for cached in SceneRenderCache.cacheCandidates(in: projectDirectory)
                where cached.path != destination.path && FileManager.default.fileExists(atPath: cached.path) {
                try FileManager.default.removeItem(at: cached)
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
        }

        let cacheIssue = ScanIssue(
            code: SceneRenderCache.issueCode,
            message: "A local rendered scene video cache is attached for reference only; desktop scene playback uses the native renderer."
        )
        let nativeStatus = asset.entrypoint.map { entrypoint in
            SceneRenderPlanBuilder().canBuild(url: URL(filePath: entrypoint))
        } == true
            ? SupportStatus.playable
            : asset.supportStatus
        let updated = WallpaperAsset(
            id: asset.id,
            title: asset.title,
            kind: asset.kind,
            supportStatus: nativeStatus,
            source: asset.source,
            projectDirectory: asset.projectDirectory,
            entrypoint: asset.entrypoint,
            thumbnail: asset.thumbnail,
            workshopId: asset.workshopId,
            dateAdded: asset.dateAdded,
            redistributionAllowed: false,
            issues: mergedIssues(asset.issues + [cacheIssue])
        )
        let updatedManifest = LibraryManifest(
            generatedAt: Date(),
            assets: (manifest.assets.filter { $0.id != assetID } + [updated])
                .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        )
        try save(updatedManifest)
        return updated
    }

    /// The caller must stop imports, downloads, playback preparation, and rendering before removal.
    public func removeAsset(id: WallpaperAsset.ID) throws {
        try validateRemovalAncestors(root)
        let manifestURL = root.appending(path: "library.json")
        if let type = try removalNodeType(manifestURL), type != mode_t(S_IFREG) {
            throw LibraryStoreError.unsafeRemovalPath(manifestURL.path)
        }
        let manifest = try load()
        guard let removed = manifest.assets.first(where: { $0.id == id }) else {
            return
        }
        let remaining = manifest.assets.filter { $0.id != id }
        let directory = try validatedLibraryDirectory(for: removed)
        if let directory, remaining.contains(where: {
            URL(filePath: $0.projectDirectory).standardizedFileURL.path == directory.standardizedFileURL.path
        }) {
            throw LibraryStoreError.unsafeRemovalPath(directory.path)
        }
        let downloads = WorkshopDownloads(root: root.appending(path: "WorkshopDownloads"))
        let download: WorkshopDownload?
        do {
            download = try removed.workshopId.flatMap { try downloads.completedItemIfPresent(itemID: $0) }
        } catch WorkshopDownloadsError.invalidItemID {
            // Copied local folders can have non-Workshop identifiers in legacy metadata.
            download = nil
        }
        let caches = try validatedSceneVideoCaches(for: removed.id, retaining: remaining)
            + validatedVideoPlaybackCaches(for: removed.id)
            + validatedGeneratedStillImage(for: removed.id, retaining: remaining)

        // Validate everything before the first move. Keep the manifest and library
        // copy until the dependent copies are gone so failures remain retryable.
        for cache in caches { try trashOrRemove(cache) }
        if let download { try trashOrRemove(URL(filePath: download.directory)) }
        if let directory { try trashOrRemove(directory) }
        try save(LibraryManifest(generatedAt: Date(), assets: remaining))
    }

    public static func defaultStore() throws -> LibraryStore {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return LibraryStore(root: base.appending(path: "WorkshopWallpaperBridge"))
    }

    private var assetsRoot: URL {
        root.appending(path: "Assets")
    }

    private func save(_ manifest: LibraryManifest) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONEncoder.bridge.encode(manifest)
        try data.write(to: root.appending(path: "library.json"), options: [.atomic])
    }

    private func validatedLibraryDirectory(for asset: WallpaperAsset) throws -> URL? {
        let directory = resolvingSystemVarAlias(URL(filePath: asset.projectDirectory))
        let managedRoot = resolvingSystemVarAlias(assetsRoot)
        // External copied-folder originals are never deletion targets.
        guard directory.pathComponents.starts(with: managedRoot.pathComponents) else { return nil }
        guard directory.deletingLastPathComponent().path == managedRoot.path,
              directory.lastPathComponent == storageDirectoryName(for: asset.id)
                || directory.lastPathComponent == asset.id else {
            throw LibraryStoreError.unsafeRemovalPath(directory.path)
        }
        try validateRemovalAncestors(directory)
        guard try removalNodeType(directory) != nil else { return nil }
        try validateRemovalTree(directory)
        return directory
    }

    private func validatedSceneVideoCaches(for id: String, retaining assets: [WallpaperAsset]) throws -> [URL] {
        let cacheRoot = root.appending(path: "SceneVideoCache")
        try validateRemovalAncestors(cacheRoot)
        guard try removalNodeType(cacheRoot) != nil else { return [] }
        var targets: [URL] = []
        for version in try FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil)
            where isCacheVersion(version.lastPathComponent) {
            try validateRemovalAncestors(version)
            for file in try FileManager.default.contentsOfDirectory(at: version, includingPropertiesForKeys: nil)
                where isSceneCacheFile(file.lastPathComponent, assetID: id) {
                guard try removalNodeType(file) == mode_t(S_IFREG),
                      !assets.contains(where: { isSceneCacheFile(file.lastPathComponent, assetID: $0.id) }) else {
                    throw LibraryStoreError.unsafeRemovalPath(file.path)
                }
                targets.append(file)
            }
        }
        return targets.sorted { $0.path < $1.path }
    }

    private func validatedVideoPlaybackCaches(for id: String) throws -> [URL] {
        // Playback preparation only creates caches for ASCII-safe IDs.
        guard !id.isEmpty, id.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || $0 == 45 || $0 == 95
        }) else { return [] }
        let directory = root.appending(path: "VideoPlaybackCache/v1")
        try validateRemovalAncestors(directory)
        var targets: [URL] = []
        for ext in ["mp4", "json"] {
            let file = directory.appending(path: "\(id).\(ext)")
            guard let type = try removalNodeType(file) else { continue }
            guard type == mode_t(S_IFREG) else {
                throw LibraryStoreError.unsafeRemovalPath(file.path)
            }
            targets.append(file)
        }
        return targets
    }

    private func validatedGeneratedStillImage(for id: String, retaining assets: [WallpaperAsset]) throws -> [URL] {
        func fileName(_ id: String) -> String {
            id.components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }.joined(separator: "-") + "-still.png"
        }
        let directory = root.appending(path: "GeneratedStillWallpapers")
        try validateRemovalAncestors(directory)
        let file = directory.appending(path: fileName(id))
        guard let type = try removalNodeType(file) else { return [] }
        guard type == mode_t(S_IFREG),
              !assets.contains(where: { fileName($0.id) == file.lastPathComponent }) else {
            throw LibraryStoreError.unsafeRemovalPath(file.path)
        }
        return [file]
    }

    private func isCacheVersion(_ name: String) -> Bool {
        name.hasPrefix("v") && !name.dropFirst().isEmpty
            && name.dropFirst().utf8.allSatisfy { (48...57).contains($0) }
    }

    private func isSceneCacheFile(_ name: String, assetID: String) -> Bool {
        if name == "\(assetID).mp4" { return true }
        let prefix = "\(assetID)-media-"
        guard name.hasPrefix(prefix), name.hasSuffix(".mp4") else { return false }
        return isCacheVersion(String(name.dropFirst(prefix.count).dropLast(4)))
    }

    private func validateRemovalAncestors(_ directory: URL) throws {
        guard directory.isFileURL, directory.path != "/", directory.path.hasPrefix("/") else {
            throw LibraryStoreError.unsafeRemovalPath(directory.path)
        }
        var current = URL(filePath: "/", directoryHint: .isDirectory)
        for component in resolvingSystemVarAlias(directory).pathComponents.dropFirst() {
            guard component != ".", component != ".." else {
                throw LibraryStoreError.unsafeRemovalPath(directory.path)
            }
            current.append(path: component)
            if let type = try removalNodeType(current), type != mode_t(S_IFDIR) {
                throw LibraryStoreError.unsafeRemovalPath(current.path)
            }
        }
    }

    private func validateRemovalTree(_ directory: URL) throws {
        var pending = [directory]
        while let parent = pending.popLast() {
            for child in try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) {
                let type = try removalNodeType(child)
                if type == mode_t(S_IFDIR) {
                    pending.append(child)
                } else if type != mode_t(S_IFREG) {
                    throw LibraryStoreError.unsafeRemovalPath(child.path)
                }
            }
        }
    }

    private func removalNodeType(_ url: URL) throws -> mode_t? {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            path.map { lstat($0, &info) } ?? -1
        }
        guard result == 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink > 1 {
            throw LibraryStoreError.unsafeRemovalPath(url.path)
        }
        return info.st_mode & S_IFMT
    }

    /// Preserve the existing Trash-first behavior and permanent-delete fallback.
    private func trashOrRemove(_ url: URL) throws {
        do {
            try trasher.trashItem(at: url)
        } catch {
            try trasher.removeItem(at: url)
        }
    }

    private func isInsideAssetsRoot(_ url: URL) -> Bool {
        let rootComponents = assetsRoot.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let urlComponents = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard urlComponents.count > rootComponents.count else {
            return false
        }
        return zip(rootComponents, urlComponents).allSatisfy { $0 == $1 }
    }

    private func isInside(_ url: URL, parent: URL) -> Bool {
        let parentComponents = parent.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let urlComponents = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard urlComponents.count > parentComponents.count else {
            return false
        }
        return zip(parentComponents, urlComponents).allSatisfy { $0 == $1 }
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func replaceDirectory(target: URL, replacement: URL, backup: URL) throws {
        let exists = FileManager.default.fileExists(atPath: target.path)
        if exists {
            try FileManager.default.moveItem(at: target, to: backup)
        }
        do {
            try FileManager.default.moveItem(at: replacement, to: target)
            if exists {
                try FileManager.default.removeItem(at: backup)
            }
        } catch {
            if exists, FileManager.default.fileExists(atPath: backup.path) {
                try? FileManager.default.moveItem(at: backup, to: target)
            }
            if FileManager.default.fileExists(atPath: replacement.path) {
                try? FileManager.default.removeItem(at: replacement)
            }
            throw error
        }
    }

    private func rewrite(asset: WallpaperAsset, source: URL, target: URL) -> WallpaperAsset {
        WallpaperAsset(
            id: asset.id,
            title: asset.title,
            kind: asset.kind,
            supportStatus: asset.supportStatus,
            source: asset.source,
            projectDirectory: target.path,
            entrypoint: rewrite(path: asset.entrypoint, source: source, target: target),
            thumbnail: rewrite(path: asset.thumbnail, source: source, target: target),
            workshopId: asset.workshopId,
            dateAdded: asset.dateAdded,
            redistributionAllowed: false,
            issues: asset.issues
        )
    }

    private func rewrite(path: String?, source: URL, target: URL) -> String? {
        guard let path else {
            return nil
        }
        let prefix = source.path.hasSuffix("/") ? source.path : "\(source.path)/"
        guard path.hasPrefix(prefix) else {
            return path
        }
        let relative = String(path.dropFirst(prefix.count))
        return target.appending(path: relative).path
    }

    private func repairStoredAssets(in manifest: LibraryManifest) -> LibraryManifest {
        let assets = manifest.assets
            .map(repairLegacyPreviewEntrypoint)
            .map(refreshSceneDiagnostics)
        guard assets != manifest.assets else {
            return manifest
        }
        return LibraryManifest(generatedAt: Date(), assets: assets)
    }

    private func repairLegacyPreviewEntrypoint(_ asset: WallpaperAsset) -> WallpaperAsset {
        guard asset.kind == .image,
              asset.supportStatus == .playable,
              let entrypoint = asset.entrypoint,
              isImplicitPreview(URL(filePath: entrypoint)),
              let scanned = try? WallpaperScanner()
                .scan(root: URL(filePath: asset.projectDirectory))
                .assets
                .first,
              scanned.entrypoint != nil,
              scanned.entrypoint != asset.entrypoint else {
            return asset
        }
        return WallpaperAsset(
            id: asset.id,
            title: asset.title,
            kind: scanned.kind,
            supportStatus: scanned.supportStatus,
            source: asset.source,
            projectDirectory: asset.projectDirectory,
            entrypoint: scanned.entrypoint,
            thumbnail: scanned.thumbnail ?? asset.thumbnail,
            workshopId: asset.workshopId,
            dateAdded: asset.dateAdded ?? scanned.dateAdded,
            redistributionAllowed: false,
            issues: mergedIssues(asset.issues + scanned.issues)
        )
    }

    private func refreshSceneDiagnostics(_ asset: WallpaperAsset) -> WallpaperAsset {
        guard asset.kind == .scene,
              let entrypoint = asset.entrypoint else {
            return asset
        }
        let entrypointURL = URL(filePath: entrypoint)
        let refreshed = currentSceneIssues(entrypoint: entrypointURL)
        guard !refreshed.isEmpty else {
            return asset
        }
        let hasRenderCache = SceneRenderCache.existingVideoURL(
            in: URL(filePath: asset.projectDirectory)
        ) != nil
        let supportStatus: SupportStatus = SceneRenderPlanBuilder().canBuild(url: entrypointURL)
            ? .playable
            : .unsupported
        let preserved = asset.issues.filter { issue in
            issue.code != "scene_package_detected"
                && issue.code != "scene_renderer_limited"
                && issue.code != "scene_package_unreadable"
                && issue.code != SceneRenderCache.issueCode
        }
        let cacheIssues = hasRenderCache
            ? [
                ScanIssue(
                    code: SceneRenderCache.issueCode,
                    message: "A local rendered scene video cache is attached for reference only; desktop scene playback uses the native renderer."
                )
            ]
            : []
        return WallpaperAsset(
            id: asset.id,
            title: asset.title,
            kind: asset.kind,
            supportStatus: supportStatus,
            source: asset.source,
            projectDirectory: asset.projectDirectory,
            entrypoint: asset.entrypoint,
            thumbnail: asset.thumbnail,
            workshopId: asset.workshopId,
            dateAdded: asset.dateAdded,
            redistributionAllowed: hasRenderCache ? false : asset.redistributionAllowed,
            issues: mergedIssues(preserved + refreshed + cacheIssues)
        )
    }

    private func currentSceneIssues(entrypoint: URL) -> [ScanIssue] {
        do {
            let analysis = try ScenePackageAnalyzer().analyze(url: entrypoint)
            return [
                ScanIssue(code: "scene_package_detected", message: analysis.userFacingSummary),
                ScanIssue(
                    code: "scene_renderer_limited",
                    message: "Scene playback supports 2D image layers, animated sprite textures, text layers, "
                        + "selected text SceneScript, "
                        + "keyframed motion, and selected effect motion; advanced shaders, particles, advanced scripts, audio, "
                        + "and video textures may differ."
                )
            ]
        } catch {
            return [
                ScanIssue(
                    code: "scene_package_unreadable",
                    message: "scene.pkg could not be inspected: \(error.localizedDescription)"
                )
            ]
        }
    }
}

public enum LibraryStoreError: Error, LocalizedError, Equatable {
    case notRegularFile(String)
    case unsupportedVideoExtension(String)
    case missingAsset(String)
    case assetIsNotScene(String)
    case assetOutsideLibrary(String)
    case unsafeSceneRenderCacheDirectory(String)
    case unsafeRemovalPath(String)

    public var errorDescription: String? {
        switch self {
        case .notRegularFile(let path):
            return "\(path) is not a regular video file."
        case .unsupportedVideoExtension(let ext):
            return ext.isEmpty
                ? "This file has no supported video extension."
                : ".\(ext) is not supported for manual video import."
        case .missingAsset(let id):
            return "No library asset exists for id \(id)."
        case .assetIsNotScene(let id):
            return "Asset \(id) is not a scene wallpaper."
        case .assetOutsideLibrary(let id):
            return "Asset \(id) is outside the managed library."
        case .unsafeSceneRenderCacheDirectory(let id):
            return "Scene render cache directory for asset \(id) is unsafe."
        case .unsafeRemovalPath(let path):
            return "Unsafe wallpaper removal path: \(path)"
        }
    }
}

private func storageDirectoryName(for id: String) -> String {
    let encoded = Data(id.utf8)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "id-\(encoded)"
}

private let manualPlayableVideoExtensions = ["mp4", "mov", "m4v"]
private let manualConversionVideoExtensions = ["webm", "mkv", "avi"]
private let manualVideoExtensions = manualPlayableVideoExtensions + manualConversionVideoExtensions
private let implicitPreviewNames = ["preview", "thumbnail", "thumb", "cover"]

private func isRegularFile(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
}

private func isImplicitPreview(_ url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    let name = url.deletingPathExtension().lastPathComponent.lowercased()
    return ["jpg", "jpeg", "png", "gif", "heic"].contains(ext) && implicitPreviewNames.contains(name)
}

private func mergedIssues(_ issues: [ScanIssue]) -> [ScanIssue] {
    var seen: Set<String> = []
    return issues.filter { issue in
        let key = "\(issue.code)\u{0}\(issue.message)"
        guard !seen.contains(key) else {
            return false
        }
        seen.insert(key)
        return true
    }
}

private extension JSONEncoder {
    static var bridge: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var bridge: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
