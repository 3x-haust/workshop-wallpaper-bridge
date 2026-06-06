import Foundation

public struct ScenePackageEntry: Equatable, Sendable {
    public let path: String
    public let offset: Int
    public let length: Int
    let dataOffset: Int
}

public struct ScenePackage: Equatable, Sendable {
    public let magic: String
    public let entries: [ScenePackageEntry]
    private let data: Data

    init(magic: String, entries: [ScenePackageEntry], data: Data) {
        self.magic = magic
        self.entries = entries
        self.data = data
    }

    public func entry(named path: String) -> ScenePackageEntry? {
        entries.first { $0.path == path }
    }

    public func data(for entry: ScenePackageEntry) -> Data {
        data.subdata(in: entry.dataOffset..<(entry.dataOffset + entry.length))
    }

    public func data(forPath path: String) -> Data? {
        guard let entry = entry(named: path) else {
            return nil
        }
        return data(for: entry)
    }
}

public struct ScenePackageReader: Sendable {
    private let maximumPackageBytes: UInt64

    public init(maximumPackageBytes: UInt64 = 512 * 1024 * 1024) {
        self.maximumPackageBytes = maximumPackageBytes
    }

    public func read(url: URL) throws -> ScenePackage {
        let packageSize = try fileSize(url)
        guard packageSize <= maximumPackageBytes else {
            throw ScenePackageError.packageTooLarge(packageSize, maximumPackageBytes)
        }
        let data = try Data(contentsOf: url)
        var reader = SceneBinaryReader(data: data)
        let magic = try reader.readString(maxLength: 32)
        guard magic.hasPrefix("PKGV") else {
            throw ScenePackageError.unsupportedMagic(magic)
        }
        let entryCount = try reader.readInt()
        guard entryCount >= 0, entryCount <= 100_000 else {
            throw ScenePackageError.invalidEntryCount(entryCount)
        }
        var rawEntries: [RawScenePackageEntry] = []
        rawEntries.reserveCapacity(entryCount)
        for _ in 0..<entryCount {
            let path = try reader.readString(maxLength: 4096)
            try Self.validateEntryPath(path)
            rawEntries.append(
                RawScenePackageEntry(path: path, offset: try reader.readInt(), length: try reader.readInt())
            )
        }
        let dataStart = reader.offset
        let entries = try rawEntries.map { raw in
            guard raw.offset >= 0, raw.length >= 0 else {
                throw ScenePackageError.invalidEntryRange(raw.path)
            }
            let dataOffset = dataStart + raw.offset
            guard dataOffset >= dataStart,
                  dataOffset <= data.count,
                  raw.length <= data.count - dataOffset else {
                throw ScenePackageError.invalidEntryRange(raw.path)
            }
            return ScenePackageEntry(
                path: raw.path,
                offset: raw.offset,
                length: raw.length,
                dataOffset: dataOffset
            )
        }
        return ScenePackage(magic: magic, entries: entries, data: data)
    }

    private static func validateEntryPath(_ path: String) throws {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.contains("\0") else {
            throw ScenePackageError.unsafeEntryPath(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0 == "." || $0 == ".." || $0.isEmpty }) else {
            throw ScenePackageError.unsafeEntryPath(path)
        }
    }
}

public struct ScenePackageAnalysis: Codable, Equatable, Sendable {
    public let magic: String
    public let entryCount: Int
    public let objectCount: Int
    public let imageObjectCount: Int
    public let textObjectCount: Int
    public let particleObjectCount: Int
    public let soundObjectCount: Int
    public let modelObjectCount: Int
    public let animatedObjectCount: Int
    public let originAnimationCount: Int
    public let scaleAnimationCount: Int
    public let angleAnimationCount: Int
    public let alphaAnimationCount: Int
    public let textureEntryCount: Int
    public let materialEntryCount: Int
    public let effectEntryCount: Int
    public let shaderEntryCount: Int
    public let fontEntryCount: Int
    public let audioEntryCount: Int
    public let videoEntryCount: Int
    public let runtimeFeatures: SceneRuntimeFeatures

    public var requiresFullRenderer: Bool {
        runtimeFeatures.requiresEngineRenderer
    }

    public var userFacingSummary: String {
        let objectSummary = [
            countText(imageObjectCount, "image layer"),
            countText(textObjectCount, "text layer"),
            countText(particleObjectCount, "particle system"),
            countText(modelObjectCount, "model layer"),
            countText(soundObjectCount, "sound layer")
        ].compactMap(\.self).joined(separator: ", ")
        let assetSummary = [
            countText(textureEntryCount, "texture"),
            countText(materialEntryCount, "material"),
            countText(effectEntryCount, "effect"),
            countText(shaderEntryCount, "shader"),
            countText(audioEntryCount, "audio file"),
            countText(videoEntryCount, "video texture")
        ].compactMap(\.self).joined(separator: ", ")
        let animationSummary = animatedObjectCount > 0 ? "; \(animatedObjectCount) animated object(s)" : ""
        let objects = objectSummary.isEmpty ? "\(objectCount) object(s)" : objectSummary
        let assets = assetSummary.isEmpty ? "\(entryCount) packaged file(s)" : assetSummary
        return "scene.pkg \(magic): \(objects); \(assets)\(animationSummary). 2D image, text, selected text SceneScript, and selected effect playback is enabled. \(runtimeFeatures.userFacingSummary)"
    }
}

public struct ScenePackageAnalyzer: Sendable {
    public init() {}

    public func analyze(url: URL) throws -> ScenePackageAnalysis {
        let package = try ScenePackageReader().read(url: url)
        guard let sceneEntry = package.entry(named: "scene.json") else {
            throw ScenePackageError.missingSceneJSON
        }
        let sceneData = package.data(for: sceneEntry)
        guard let scene = try JSONSerialization.jsonObject(with: sceneData) as? [String: Any] else {
            throw ScenePackageError.malformedSceneJSON
        }
        let objects = scene["objects"] as? [[String: Any]] ?? []
        let runtimeFeatures = SceneRuntimeFeatureAnalyzer().analyze(package: package, scene: scene)
        return ScenePackageAnalysis(
            magic: package.magic,
            entryCount: package.entries.count,
            objectCount: objects.count,
            imageObjectCount: objects.filter { $0["image"] != nil }.count,
            textObjectCount: objects.filter { $0["text"] != nil }.count,
            particleObjectCount: objects.filter { $0["particle"] != nil }.count,
            soundObjectCount: objects.filter { $0["sound"] != nil }.count,
            modelObjectCount: objects.filter { $0["model"] != nil }.count,
            animatedObjectCount: objects.filter(Self.hasAnimation).count,
            originAnimationCount: objects.filter { Self.hasAnimation($0["origin"]) }.count,
            scaleAnimationCount: objects.filter { Self.hasAnimation($0["scale"]) }.count,
            angleAnimationCount: objects.filter { Self.hasAnimation($0["angles"]) }.count,
            alphaAnimationCount: objects.filter { Self.hasAnimation($0["alpha"]) }.count,
            textureEntryCount: package.entries.filter { $0.path.hasSuffix(".tex") }.count,
            materialEntryCount: package.entries.filter { $0.path.hasPrefix("materials/") }.count,
            effectEntryCount: package.entries.filter { $0.path.hasPrefix("effects/") }.count,
            shaderEntryCount: package.entries.filter { $0.path.hasPrefix("shaders/") }.count,
            fontEntryCount: package.entries.filter { $0.path.hasSuffix(".ttf") || $0.path.hasSuffix(".otf") }.count,
            audioEntryCount: package.entries.filter { ["mp3", "wav", "ogg"].contains($0.path.pathExtension) }.count,
            videoEntryCount: package.entries.filter { ["mp4", "webm"].contains($0.path.pathExtension) }.count,
            runtimeFeatures: runtimeFeatures
        )
    }

    private static func hasAnimation(_ object: [String: Any]) -> Bool {
        hasAnimation(object["origin"])
            || hasAnimation(object["scale"])
            || hasAnimation(object["angles"])
            || hasAnimation(object["alpha"])
    }

    private static func hasAnimation(_ value: Any?) -> Bool {
        guard let dict = value as? [String: Any],
              dict["animation"] is [String: Any] else {
            return false
        }
        return true
    }
}

public enum ScenePackageError: Error, Equatable, LocalizedError {
    case unsupportedMagic(String)
    case packageTooLarge(UInt64, UInt64)
    case invalidEntryCount(Int)
    case invalidStringLength(Int)
    case truncatedPackage
    case unsafeEntryPath(String)
    case invalidEntryRange(String)
    case missingSceneJSON
    case malformedSceneJSON

    public var errorDescription: String? {
        switch self {
        case .unsupportedMagic(let magic):
            return "Unsupported scene package magic: \(magic)."
        case .packageTooLarge(let size, let limit):
            return "scene.pkg is too large to inspect safely: \(size) bytes exceeds \(limit) bytes."
        case .invalidEntryCount(let count):
            return "Invalid scene package entry count: \(count)."
        case .invalidStringLength(let length):
            return "Invalid scene package string length: \(length)."
        case .truncatedPackage:
            return "The scene package is truncated."
        case .unsafeEntryPath(let path):
            return "Unsafe scene package entry path: \(path)."
        case .invalidEntryRange(let path):
            return "Invalid scene package entry range: \(path)."
        case .missingSceneJSON:
            return "The scene package does not contain scene.json."
        case .malformedSceneJSON:
            return "scene.json could not be parsed."
        }
    }
}

private struct SceneBinaryReader {
    let data: Data
    var offset = 0

    mutating func readInt() throws -> Int {
        guard data.count - offset >= 4 else {
            throw ScenePackageError.truncatedPackage
        }
        let value = data.withUnsafeBytes { rawBuffer in
            rawBuffer.loadUnaligned(fromByteOffset: offset, as: Int32.self)
        }
        offset += 4
        return Int(Int32(littleEndian: value))
    }

    mutating func readString(maxLength: Int) throws -> String {
        let length = try readInt()
        guard length >= 0, length <= maxLength else {
            throw ScenePackageError.invalidStringLength(length)
        }
        guard data.count - offset >= length else {
            throw ScenePackageError.truncatedPackage
        }
        let range = offset..<(offset + length)
        offset += length
        var bytes = Array(data[range])
        while bytes.last == 0 {
            bytes.removeLast()
        }
        guard let string = String(bytes: bytes, encoding: .utf8) else {
            throw ScenePackageError.malformedSceneJSON
        }
        return string
    }
}

private struct RawScenePackageEntry {
    let path: String
    let offset: Int
    let length: Int
}

private func fileSize(_ url: URL) throws -> UInt64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let size = attributes[.size] as? NSNumber else {
        return 0
    }
    return size.uint64Value
}

private func countText(_ count: Int, _ label: String) -> String? {
    guard count > 0 else {
        return nil
    }
    return "\(count) \(label)\(count == 1 ? "" : "s")"
}

private extension String {
    var pathExtension: String {
        URL(filePath: self).pathExtension.lowercased()
    }
}
