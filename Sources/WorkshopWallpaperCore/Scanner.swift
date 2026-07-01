import Foundation

public struct WallpaperScanner: Sendable {
    public init() {}

    public func scan(root: URL) throws -> ScanResult {
        let projects = try discoverProjects(root: root.standardizedFileURL)
        let assets = try projects
            .map { try scanProject(root: root.standardizedFileURL, project: $0) }
            .sorted(by: dateAddedSort)
        return ScanResult(root: root.path, generatedAt: Date(), assets: assets)
    }

    private func discoverProjects(root: URL) throws -> [URL] {
        if isProjectDirectory(root) {
            return [root]
        }
        return try FileManager.default
            .contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .addedToDirectoryDateKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            .filter { isDirectory($0) && isProjectDirectory($0) }
    }

    private func scanProject(root: URL, project: URL) throws -> WallpaperAsset {
        let metadata = ProjectMetadata.load(from: project.appending(path: "project.json"))
        let entry = try findEntrypoint(in: project, preferredFile: metadata.value?.file)
        let kind = classify(entrypoint: entry)
        let status = supportStatus(kind: kind, entrypoint: entry)
        let issues = issues(metadata: metadata, kind: kind, entrypoint: entry)
        let thumbnail = try findThumbnail(in: project, preferredFile: metadata.value?.preview)
        let id = project.lastPathComponent
        return WallpaperAsset(
            id: id,
            title: metadata.value?.title?.nonEmpty ?? id,
            kind: kind,
            supportStatus: status,
            source: sourceKind(for: root),
            projectDirectory: project.path,
            entrypoint: entry?.path,
            thumbnail: thumbnail?.path,
            workshopId: id.allSatisfy(\.isNumber) ? id : nil,
            dateAdded: dateAdded(for: project),
            redistributionAllowed: false,
            issues: issues
        )
    }

    private func isProjectDirectory(_ url: URL) -> Bool {
        if FileManager.default.fileExists(atPath: url.appending(path: "project.json").path) {
            return true
        }
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
            return false
        }
        return files.contains { entrypointExtensions.contains(URL(filePath: $0).pathExtension.lowercased()) }
    }

    private func findEntrypoint(in project: URL, preferredFile: String?) throws -> URL? {
        if let preferredFile, let preferred = resolveExisting(project: project, relativePath: preferredFile) {
            return preferred
        }
        let files = try recursiveFiles(in: project)
        return files.sorted(by: entrypointSort).first {
            classify(entrypoint: $0) != .unknown && !isImplicitThumbnail($0)
        }
    }

    private func findThumbnail(in project: URL, preferredFile: String?) throws -> URL? {
        if let preferredFile, let preferred = resolveExisting(project: project, relativePath: preferredFile) {
            return preferred
        }
        return try recursiveFiles(in: project).first {
            imageExtensions.contains($0.pathExtension.lowercased())
                && preferredThumbnailNames.contains($0.deletingPathExtension().lastPathComponent.lowercased())
        }
    }

    private func recursiveFiles(in directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return enumerator.compactMap { item in
            guard let url = item as? URL, isRegularFile(url) else {
                return nil
            }
            guard isInside(url, root: directory) else {
                return nil
            }
            return url
        }
    }

    private func resolveExisting(project: URL, relativePath: String) -> URL? {
        guard !(relativePath as NSString).isAbsolutePath else {
            return nil
        }
        let candidate = project.appending(path: relativePath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: candidate.path),
              isInside(candidate, root: project) else {
            return nil
        }
        return candidate
    }

    private func isInside(_ url: URL, root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let urlComponents = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard urlComponents.count > rootComponents.count else {
            return false
        }
        return Array(urlComponents.prefix(rootComponents.count)) == rootComponents
    }

    private func isImplicitThumbnail(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
            && preferredThumbnailNames.contains(url.deletingPathExtension().lastPathComponent.lowercased())
    }

    private func classify(entrypoint: URL?) -> WallpaperKind {
        guard let ext = entrypoint?.pathExtension.lowercased() else {
            return .unknown
        }
        if playableVideoExtensions.contains(ext) || conversionVideoExtensions.contains(ext) {
            return .video
        }
        if ext == "html" || ext == "htm" {
            return .web
        }
        if imageExtensions.contains(ext) {
            return .image
        }
        if ext == "pkg" {
            return .scene
        }
        return .unknown
    }

    private func supportStatus(kind: WallpaperKind, entrypoint: URL?) -> SupportStatus {
        switch kind {
        case .video:
            guard let ext = entrypoint?.pathExtension.lowercased() else {
                return .unsupported
            }
            return playableVideoExtensions.contains(ext) ? .playable : .needsConversion
        case .web, .image:
            return .playable
        case .scene:
            guard let entrypoint else {
                return .unsupported
            }
            return SceneRenderPlanBuilder().canBuild(url: entrypoint) ? .playable : .unsupported
        case .unknown:
            return .unsupported
        }
    }

    private func issues(metadata: ProjectMetadataResult, kind: WallpaperKind, entrypoint: URL?) -> [ScanIssue] {
        var result = metadata.issue.map { [$0] } ?? []
        if entrypoint == nil {
            result.append(
                ScanIssue(code: "no_supported_entrypoint", message: "No playable media entrypoint was found.")
            )
        }
        if kind == .scene {
            result.append(contentsOf: sceneIssues(entrypoint: entrypoint))
        }
        return result
    }

    private func sceneIssues(entrypoint: URL?) -> [ScanIssue] {
        guard let entrypoint else {
            return [
                ScanIssue(
                    code: "scene_package_missing",
                    message: "scene.pkg metadata was detected but the package file was not found."
                )
            ]
        }
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

    private func sourceKind(for root: URL) -> SourceKind {
        let path = root.path.lowercased().replacingOccurrences(of: "\\", with: "/")
        if path.contains("/steamapps/workshop/content/431960") {
            return .localSteamWorkshop
        }
        if path.contains("/wallpaper_engine/projects/backup") {
            return .wallpaperEngineBackup
        }
        return .manualFolder
    }

    private func dateAdded(for project: URL) -> Date? {
        let values = try? project.resourceValues(forKeys: [.addedToDirectoryDateKey, .contentModificationDateKey])
        return values?.addedToDirectoryDate ?? values?.contentModificationDate
    }
}

private struct ProjectMetadata: Decodable {
    let title: String?
    let file: String?
    let preview: String?
}

private struct ProjectMetadataResult {
    let value: ProjectMetadata?
    let issue: ScanIssue?
}

private extension ProjectMetadata {
    static func load(from url: URL) -> ProjectMetadataResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ProjectMetadataResult(value: nil, issue: nil)
        }
        do {
            let data = try Data(contentsOf: url)
            let value = try JSONDecoder().decode(ProjectMetadata.self, from: data)
            return ProjectMetadataResult(value: value, issue: nil)
        } catch {
            return ProjectMetadataResult(
                value: nil,
                issue: ScanIssue(code: "malformed_project_json", message: "project.json could not be parsed.")
            )
        }
    }
}

private let playableVideoExtensions = ["mp4", "mov", "m4v"]
private let conversionVideoExtensions = ["webm", "mkv", "avi"]
private let imageExtensions = ["jpg", "jpeg", "png", "gif", "heic"]
private let entrypointExtensions =
    playableVideoExtensions + conversionVideoExtensions + imageExtensions + ["html", "htm", "pkg"]
private let preferredThumbnailNames = ["preview", "thumbnail", "thumb", "cover"]

private func entrypointSort(_ lhs: URL, _ rhs: URL) -> Bool {
    entrypointRank(lhs) < entrypointRank(rhs)
}

private func entrypointRank(_ url: URL) -> Int {
    let ext = url.pathExtension.lowercased()
    if playableVideoExtensions.contains(ext) { return 0 }
    if conversionVideoExtensions.contains(ext) { return 1 }
    if ext == "html" || ext == "htm" { return 2 }
    if imageExtensions.contains(ext) { return 3 }
    if ext == "pkg" { return 4 }
    return 5
}

private func dateAddedSort(_ lhs: WallpaperAsset, _ rhs: WallpaperAsset) -> Bool {
    switch (lhs.dateAdded, rhs.dateAdded) {
    case let (left?, right?) where left != right:
        return left > right
    case (_?, nil):
        return true
    case (nil, _?):
        return false
    default:
        return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
    }
}

private func isDirectory(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
}

private func isRegularFile(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
