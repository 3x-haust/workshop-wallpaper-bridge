import AppKit
import Foundation

struct UpdateRelease: Equatable {
    let version: String
    let tagName: String
    let releaseURL: URL
    let downloadURL: URL?
}

enum UpdateCheckResult: Equatable {
    case upToDate(currentVersion: String, latestVersion: String)
    case updateAvailable(UpdateRelease)
}

@MainActor
protocol UpdateChecking {
    func checkForUpdates(currentVersion: String) async throws -> UpdateCheckResult
}

@MainActor
protocol UpdateURLOpening {
    func open(_ url: URL) -> Bool
}

struct WorkspaceUpdateURLOpener: UpdateURLOpening {
    func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}

struct AppVersionProvider {
    static func currentVersion(bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}

struct DisabledUpdateChecker: UpdateChecking {
    func checkForUpdates(currentVersion: String) async throws -> UpdateCheckResult {
        .upToDate(currentVersion: currentVersion, latestVersion: currentVersion)
    }
}

struct GitHubReleaseUpdateChecker: UpdateChecking {
    private let latestReleaseURL: URL
    private let session: URLSession

    init(
        latestReleaseURL: URL = URL(
            string: "https://api.github.com/repos/3x-haust/workshop-wallpaper-bridge/releases/latest"
        )!,
        session: URLSession = .shared
    ) {
        self.latestReleaseURL = latestReleaseURL
        self.session = session
    }

    func checkForUpdates(currentVersion: String) async throws -> UpdateCheckResult {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("WorkshopWallpaperBridge", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let response = response as? HTTPURLResponse,
           !(200..<300).contains(response.statusCode) {
            throw UpdateCheckError.unexpectedStatusCode(response.statusCode)
        }
        return try Self.result(from: data, currentVersion: currentVersion)
    }

    nonisolated static func result(from data: Data, currentVersion: String) throws -> UpdateCheckResult {
        let release = try JSONDecoder().decode(GitHubReleaseResponse.self, from: data)
        let latestVersion = AppReleaseVersion(release.tagName)
        let installedVersion = AppReleaseVersion(currentVersion)
        let version = latestVersion.description
        guard latestVersion > installedVersion else {
            return .upToDate(currentVersion: currentVersion, latestVersion: version)
        }
        guard let releaseURL = URL(string: release.htmlURL) else {
            throw UpdateCheckError.invalidReleaseURL
        }
        return .updateAvailable(UpdateRelease(
            version: version,
            tagName: release.tagName,
            releaseURL: releaseURL,
            downloadURL: release.preferredDownloadURL ?? release.defaultDownloadURL
        ))
    }
}

struct AppReleaseVersion: Comparable, CustomStringConvertible {
    private let components: [Int]
    private let fallback: String

    init(_ rawValue: String) {
        let trimmed = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingPrefix("v")
        fallback = trimmed.isEmpty ? "0" : String(trimmed)
        let parsed = trimmed
            .split { !$0.isNumber }
            .prefix(4)
            .compactMap { Int($0) }
        components = parsed.isEmpty ? [0] : parsed
    }

    var description: String {
        fallback
    }

    static func == (lhs: AppReleaseVersion, rhs: AppReleaseVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return false
            }
        }
        return true
    }

    static func < (lhs: AppReleaseVersion, rhs: AppReleaseVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }
}

enum UpdateCheckError: LocalizedError, Equatable {
    case unexpectedStatusCode(Int)
    case invalidReleaseURL

    var errorDescription: String? {
        switch self {
        case .unexpectedStatusCode(let code):
            return "GitHub returned HTTP \(code) while checking for updates."
        case .invalidReleaseURL:
            return "The latest release did not include a valid release URL."
        }
    }
}

private struct GitHubReleaseResponse: Decodable {
    let tagName: String
    let htmlURL: String
    let assets: [GitHubReleaseAsset]

    var preferredDownloadURL: URL? {
        assets
            .first { $0.name.lowercased().hasSuffix(".dmg") }
            .flatMap { URL(string: $0.browserDownloadURL) }
    }

    var defaultDownloadURL: URL? {
        URL(
            string: "https://github.com/3x-haust/workshop-wallpaper-bridge/releases/download/\(tagName)/WorkshopWallpaperBridge-macOS-arm64.dmg"
        )
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }
}

private struct GitHubReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}
