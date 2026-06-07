import Foundation

public struct LibraryStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
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

    public func removeAsset(id: WallpaperAsset.ID) throws {
        let manifest = try load()
        guard let removed = manifest.assets.first(where: { $0.id == id }) else {
            return
        }
        let remaining = manifest.assets.filter { $0.id != id }
        try removeLibraryDirectory(for: removed)
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

    private func removeLibraryDirectory(for asset: WallpaperAsset) throws {
        let directory = URL(filePath: asset.projectDirectory).standardizedFileURL
        guard isInsideAssetsRoot(directory) else {
            return
        }
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
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
                    message: "Scene playback supports 2D image layers, text layers, selected text SceneScript, "
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
