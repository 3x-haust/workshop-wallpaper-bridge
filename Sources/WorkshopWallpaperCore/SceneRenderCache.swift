import Foundation

public enum SceneRenderCache {
    public static let directoryName = ".wwb"
    public static let baseFileName = "render-cache"
    public static let issueCode = "scene_render_cache"
    public static let playableVideoExtensions = ["mp4", "mov", "m4v"]

    public static func cacheDirectory(in projectDirectory: URL) -> URL {
        projectDirectory.appending(path: directoryName)
    }

    public static func videoURL(in projectDirectory: URL, fileExtension: String = "mp4") -> URL {
        cacheDirectory(in: projectDirectory)
            .appending(path: "\(baseFileName).\(normalizedExtension(fileExtension))")
    }

    public static func existingVideoURL(in projectDirectory: URL) -> URL? {
        cacheCandidates(in: projectDirectory).first {
            isPlayableVideoFile($0) && isInside($0, parent: projectDirectory)
        }
    }

    public static func cacheCandidates(in projectDirectory: URL) -> [URL] {
        let preferred = playableVideoExtensions.map {
            cacheDirectory(in: projectDirectory).appending(path: "\(baseFileName).\($0)")
        }
        let legacy = playableVideoExtensions.flatMap { ext in
            [
                projectDirectory.appending(path: "\(baseFileName).\(ext)"),
                projectDirectory.appending(path: "rendered.\(ext)")
            ]
        }
        return preferred + legacy
    }

    public static func isPlayableVideoFile(_ url: URL) -> Bool {
        playableVideoExtensions.contains(normalizedExtension(url.pathExtension)) && isRegularFile(url)
    }

    public static func normalizedExtension(_ ext: String) -> String {
        ext.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
            return false
        }
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func isInside(_ url: URL, parent: URL) -> Bool {
        let parentComponents = parent.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let urlComponents = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard urlComponents.count > parentComponents.count else {
            return false
        }
        return zip(parentComponents, urlComponents).allSatisfy { $0 == $1 }
    }
}
