import Darwin
import Foundation

/// Expand only macOS's fixed /var alias, not links inside caller-controlled paths.
/// Foundation standardization may rewrite /private/var back to /var.
func resolvingSystemVarAlias(_ url: URL) -> URL {
    guard url.isFileURL, url.path == "/var" || url.path.hasPrefix("/var/"),
          let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: "/var"),
          destination == "private/var" || destination == "/private/var" else { return url }
    return URL(filePath: "/private" + url.path)
}

public struct WorkshopDownload: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let directory: String
    public let completedAt: Date

    public init(id: String, title: String, directory: String, completedAt: Date) {
        self.id = id
        self.title = title
        self.directory = directory
        self.completedAt = completedAt
    }
}

/// Synchronous storage. The caller must serialize operations and keep the helper
/// stopped while validating, moving, scanning, or removing its output.
public struct WorkshopDownloads: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func load() throws -> [WorkshopDownload] {
        try validateRoot()
        guard try nodeType(root) != nil else { return [] }
        try validateAncestors(itemsRoot)
        guard try nodeType(itemsRoot) != nil else { return [] }
        var downloads: [WorkshopDownload] = []
        for directory in try FileManager.default.contentsOfDirectory(
            at: itemsRoot, includingPropertiesForKeys: nil
        ) {
            // Invalid or incomplete entries are left untouched, never repaired or deleted.
            guard let download = try? completedItem(itemID: directory.lastPathComponent) else { continue }
            downloads.append(download)
        }
        return downloads.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    /// Returns an empty project directory whose final component is the Workshop ID.
    public func begin(itemID: String) throws -> URL {
        try validateID(itemID)
        try prepareRoot()
        try createPrivateDirectory(stagingRoot)
        let operation = stagingRoot.appending(path: UUID().uuidString)
        try createPrivateDirectory(operation)
        let staging = operation.appending(path: itemID)
        try createPrivateDirectory(staging)
        return staging
    }

    /// Call only after the helper has explicitly reported success and stopped writing.
    /// Validation here does not replace confinement of the helper before it writes.
    public func finish(itemID: String, title: String, staging: URL) throws -> WorkshopDownload {
        try validateID(itemID)
        try validateStaging(staging)
        guard staging.lastPathComponent == itemID else {
            throw WorkshopDownloadsError.invalidProject(itemID)
        }
        try validateTree(staging)
        _ = try scanProject(staging, itemID: itemID)
        try createPrivateDirectory(itemsRoot)
        let destination = itemsRoot.appending(path: itemID)
        guard try nodeType(destination) == nil else {
            throw WorkshopDownloadsError.alreadyExists(itemID)
        }
        let marker = staging.appending(path: completionName)
        guard try nodeType(marker) == nil else {
            throw WorkshopDownloadsError.invalidCompletion(itemID)
        }
        let download = WorkshopDownload(
            id: itemID, title: title, directory: destination.path, completedAt: Date()
        )
        // Publishing the directory and its marker together keeps an interrupted
        // operation invisible until the same-volume move succeeds.
        try JSONEncoder().encode(download).write(to: marker, options: [.withoutOverwriting])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        guard renameatx_np(AT_FDCWD, staging.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw WorkshopDownloadsError.alreadyExists(itemID) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return download
    }

    /// Returns only a validated completed item. Absence is safe for deletion retries;
    /// an existing incomplete or unsafe item must not be mistaken for absence.
    func completedItemIfPresent(itemID: String) throws -> WorkshopDownload? {
        try validateID(itemID)
        try validateRoot()
        let directory = itemsRoot.appending(path: itemID)
        try validateAncestors(directory)
        guard try nodeType(directory) != nil else { return nil }
        return try completedItem(itemID: itemID)
    }

    public func remove(_ download: WorkshopDownload) throws {
        try validateDownloadPath(download)
        _ = try completedItem(itemID: download.id)
        try FileManager.default.removeItem(at: itemsRoot.appending(path: download.id))
    }

    public func discard(staging: URL) throws {
        try validateStaging(staging)
        try validateTree(staging)
        try FileManager.default.removeItem(at: staging)
    }

    public func scan(_ download: WorkshopDownload) throws -> WallpaperAsset {
        try validateDownloadPath(download)
        _ = try completedItem(itemID: download.id)
        return try scanProject(itemsRoot.appending(path: download.id), itemID: download.id)
    }

    private var itemsRoot: URL { root.appending(path: "items") }
    private var stagingRoot: URL { root.appending(path: "staging") }
    private var completionName: String { ".wwb-completion.json" }

    private func validateID(_ itemID: String) throws {
        guard !itemID.isEmpty,
              itemID.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = UInt64(itemID), number > 0 else {
            throw WorkshopDownloadsError.invalidItemID(itemID)
        }
    }

    private func validateRoot() throws {
        guard root.isFileURL, root.path != "/", root.path.hasPrefix("/") else {
            throw WorkshopDownloadsError.unsafePath(root.path)
        }
        try validateAncestors(root)
    }

    private func prepareRoot() throws {
        try validateRoot()
        try createPrivateDirectory(root)
    }

    private func createPrivateDirectory(_ directory: URL) throws {
        try validateAncestors(directory)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try validateAncestors(directory)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func validateAncestors(_ directory: URL) throws {
        guard directory.isFileURL else { throw WorkshopDownloadsError.unsafePath(directory.absoluteString) }
        var current = URL(filePath: "/", directoryHint: .isDirectory)
        for component in resolvingSystemVarAlias(directory).pathComponents.dropFirst() {
            guard component != "..", component != "." else {
                throw WorkshopDownloadsError.unsafePath(directory.path)
            }
            current.append(path: component)
            if let type = try nodeType(current), type != mode_t(S_IFDIR) {
                throw WorkshopDownloadsError.unsafePath(current.path)
            }
        }
    }

    private func validateStaging(_ staging: URL) throws {
        try validateRoot()
        guard staging.isFileURL else { throw WorkshopDownloadsError.unsafePath(staging.absoluteString) }
        let operation = staging.deletingLastPathComponent()
        guard operation.deletingLastPathComponent().path == stagingRoot.path,
              UUID(uuidString: operation.lastPathComponent) != nil else {
            throw WorkshopDownloadsError.unsafePath(staging.path)
        }
        try validateID(staging.lastPathComponent)
        try validateAncestors(staging)
        guard try nodeType(staging) == mode_t(S_IFDIR) else {
            throw WorkshopDownloadsError.unsafePath(staging.path)
        }
    }

    private func validateDownloadPath(_ download: WorkshopDownload) throws {
        try validateID(download.id)
        try validateRoot()
        let expected = itemsRoot.appending(path: download.id)
        guard resolvingSystemVarAlias(URL(filePath: download.directory)).path
                == resolvingSystemVarAlias(expected).path else {
            throw WorkshopDownloadsError.unsafePath(download.directory)
        }
        try validateAncestors(expected)
    }

    private func completedItem(itemID: String) throws -> WorkshopDownload {
        try validateID(itemID)
        let directory = itemsRoot.appending(path: itemID)
        try validateAncestors(directory)
        try validateTree(directory)
        let marker = directory.appending(path: completionName)
        guard try nodeType(marker) == mode_t(S_IFREG) else {
            throw WorkshopDownloadsError.invalidCompletion(itemID)
        }
        let download = try JSONDecoder().decode(WorkshopDownload.self, from: Data(contentsOf: marker))
        guard download.id == itemID else { throw WorkshopDownloadsError.invalidCompletion(itemID) }
        try validateDownloadPath(download)
        _ = try scanProject(directory, itemID: itemID)
        return download
    }

    private func validateTree(_ directory: URL) throws {
        guard try nodeType(directory) == mode_t(S_IFDIR) else {
            throw WorkshopDownloadsError.unsafePath(directory.path)
        }
        var pending = [directory]
        while let parent = pending.popLast() {
            for child in try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) {
                let type = try nodeType(child)
                if type == mode_t(S_IFDIR) {
                    pending.append(child)
                } else if type != mode_t(S_IFREG) {
                    throw WorkshopDownloadsError.unsafePath(child.path)
                }
            }
        }
    }

    private func scanProject(_ directory: URL, itemID: String) throws -> WallpaperAsset {
        let metadataURL = directory.appending(path: "project.json")
        if try nodeType(metadataURL) == mode_t(S_IFREG),
           let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any] {
            for key in ["file", "preview"] {
                guard let path = metadata[key] as? String else { continue }
                let components = path.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/")
                guard !(path as NSString).isAbsolutePath,
                      !path.contains(":"), !components.contains(".."), !path.hasPrefix("\\") else {
                    throw WorkshopDownloadsError.unsafePath(path)
                }
            }
        }
        let assets = try WallpaperScanner().scan(root: directory).assets
        guard assets.count == 1, let asset = assets.first, asset.id == itemID,
              asset.projectDirectory == directory.standardizedFileURL.path, let entrypoint = asset.entrypoint,
              try nodeType(URL(filePath: entrypoint)) == mode_t(S_IFREG) else {
            throw WorkshopDownloadsError.invalidProject(itemID)
        }
        return asset
    }

    /// lstat also detects dangling symbolic links and never follows the final component.
    private func nodeType(_ url: URL) throws -> mode_t? {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            path.map { lstat($0, &info) } ?? -1
        }
        guard result == 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        // A hard link could expose a file outside the private store even without a symlink.
        if (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink > 1 {
            throw WorkshopDownloadsError.unsafePath(url.path)
        }
        return info.st_mode & S_IFMT
    }
}

public enum WorkshopDownloadsError: Error, Equatable, LocalizedError, Sendable {
    case invalidItemID(String)
    case unsafePath(String)
    case invalidProject(String)
    case alreadyExists(String)
    case invalidCompletion(String)

    public var errorDescription: String? {
        switch self {
        case .invalidItemID(let id): "Invalid Workshop item ID: \(id)"
        case .unsafePath(let path): "Unsafe Workshop download path: \(path)"
        case .invalidProject(let id): "No complete Workshop project was found for \(id)."
        case .alreadyExists(let id): "Workshop item \(id) already exists."
        case .invalidCompletion(let id): "Workshop item \(id) has no valid completion record."
        }
    }
}
