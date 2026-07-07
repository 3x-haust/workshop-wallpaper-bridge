import Foundation

public enum WallpaperKind: String, Codable, CaseIterable, Sendable {
    case video
    case web
    case image
    case scene
    case unknown
}

public enum SupportStatus: String, Codable, CaseIterable, Sendable {
    case playable
    case needsConversion
    case previewOnly
    case unsupported
}

public enum SourceKind: String, Codable, CaseIterable, Sendable {
    case localSteamWorkshop
    case wallpaperEngineBackup
    case manualFolder
}

public struct ScanIssue: Codable, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct WallpaperAsset: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let kind: WallpaperKind
    public let supportStatus: SupportStatus
    public let source: SourceKind
    public let projectDirectory: String
    public let entrypoint: String?
    public let thumbnail: String?
    public let workshopId: String?
    public let dateAdded: Date?
    public let redistributionAllowed: Bool
    public let issues: [ScanIssue]

    public init(
        id: String,
        title: String,
        kind: WallpaperKind,
        supportStatus: SupportStatus,
        source: SourceKind,
        projectDirectory: String,
        entrypoint: String?,
        thumbnail: String?,
        workshopId: String?,
        dateAdded: Date? = nil,
        redistributionAllowed: Bool,
        issues: [ScanIssue]
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.supportStatus = supportStatus
        self.source = source
        self.projectDirectory = projectDirectory
        self.entrypoint = entrypoint
        self.thumbnail = thumbnail
        self.workshopId = workshopId
        self.dateAdded = dateAdded
        self.redistributionAllowed = redistributionAllowed
        self.issues = issues
    }
}

public struct LibraryManifest: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let assets: [WallpaperAsset]

    public init(generatedAt: Date, assets: [WallpaperAsset]) {
        self.generatedAt = generatedAt
        self.assets = assets
    }
}

public struct ScanResult: Codable, Equatable, Sendable {
    public let root: String
    public let generatedAt: Date
    public let assets: [WallpaperAsset]

    public init(root: String, generatedAt: Date, assets: [WallpaperAsset]) {
        self.root = root
        self.generatedAt = generatedAt
        self.assets = assets
    }
}
