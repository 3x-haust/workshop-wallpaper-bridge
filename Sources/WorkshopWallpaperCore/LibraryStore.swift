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
        let repaired = repairLegacyPreviewEntrypoints(in: manifest)
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

    private func repairLegacyPreviewEntrypoints(in manifest: LibraryManifest) -> LibraryManifest {
        let assets = manifest.assets.map(repairLegacyPreviewEntrypoint)
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
}

public enum LibraryStoreError: Error, LocalizedError, Equatable {
    case notRegularFile(String)
    case unsupportedVideoExtension(String)

    public var errorDescription: String? {
        switch self {
        case .notRegularFile(let path):
            return "\(path) is not a regular video file."
        case .unsupportedVideoExtension(let ext):
            return ext.isEmpty
                ? "This file has no supported video extension."
                : ".\(ext) is not supported for manual video import."
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
