import Foundation

public struct SceneRuntimeLayerFeature: Codable, Equatable, Sendable {
    public let id: Int?
    public let name: String
    public let kind: String
    public let effectFiles: [String]
    public let scriptCount: Int
    public let constantShaderValueKeys: [String]

    public init(
        id: Int?,
        name: String,
        kind: String,
        effectFiles: [String] = [],
        scriptCount: Int = 0,
        constantShaderValueKeys: [String] = []
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.effectFiles = effectFiles
        self.scriptCount = scriptCount
        self.constantShaderValueKeys = constantShaderValueKeys
    }
}

public struct SceneRuntimeFeatures: Codable, Equatable, Sendable {
    public let layers: [SceneRuntimeLayerFeature]
    public let materialFiles: [String]
    public let effectFiles: [String]
    public let shaderFiles: [String]
    public let textureFiles: [String]
    public let audioFiles: [String]
    public let videoFiles: [String]
    public let shaderUniforms: [String]
    public let requiresSceneScriptRuntime: Bool
    public let requiresParticleRuntime: Bool
    public let requiresSoundRuntime: Bool
    public let requiresModelRuntime: Bool
    public let requiresVideoTextureRuntime: Bool
    public let requiresShaderPipeline: Bool
    public let requiresAudioAnalysis: Bool

    init(
        layers: [SceneRuntimeLayerFeature],
        materialFiles: [String],
        effectFiles: [String],
        shaderFiles: [String],
        textureFiles: [String],
        audioFiles: [String],
        videoFiles: [String],
        shaderUniforms: [String],
        requiresSceneScriptRuntime: Bool,
        requiresParticleRuntime: Bool,
        requiresSoundRuntime: Bool,
        requiresModelRuntime: Bool,
        requiresVideoTextureRuntime: Bool,
        requiresShaderPipeline: Bool,
        requiresAudioAnalysis: Bool
    ) {
        self.layers = layers
        self.materialFiles = materialFiles
        self.effectFiles = effectFiles
        self.shaderFiles = shaderFiles
        self.textureFiles = textureFiles
        self.audioFiles = audioFiles
        self.videoFiles = videoFiles
        self.shaderUniforms = shaderUniforms
        self.requiresSceneScriptRuntime = requiresSceneScriptRuntime
        self.requiresParticleRuntime = requiresParticleRuntime
        self.requiresSoundRuntime = requiresSoundRuntime
        self.requiresModelRuntime = requiresModelRuntime
        self.requiresVideoTextureRuntime = requiresVideoTextureRuntime
        self.requiresShaderPipeline = requiresShaderPipeline
        self.requiresAudioAnalysis = requiresAudioAnalysis
    }

    public var requiresEngineRenderer: Bool {
        requiresSceneScriptRuntime
            || requiresParticleRuntime
            || requiresSoundRuntime
            || requiresModelRuntime
            || requiresVideoTextureRuntime
            || requiresShaderPipeline
            || requiresAudioAnalysis
    }

    public var runtimeGaps: [String] {
        var gaps: [String] = []
        if requiresShaderPipeline {
            gaps.append("metal-shader-effect-pipeline")
        }
        if requiresSceneScriptRuntime {
            gaps.append("scenescript-runtime")
        }
        if requiresParticleRuntime {
            gaps.append("particle-system-runtime")
        }
        if requiresSoundRuntime {
            gaps.append("sound-layer-playback")
        }
        if requiresModelRuntime {
            gaps.append("model-layer-runtime")
        }
        if requiresAudioAnalysis {
            gaps.append("audio-analysis-uniforms")
        }
        if requiresVideoTextureRuntime {
            gaps.append("video-texture-runtime")
        }
        return gaps
    }

    public var userFacingSummary: String {
        guard requiresEngineRenderer else {
            return "This scene only uses the basic layer renderer."
        }
        return "This scene requires engine rendering features: \(runtimeGaps.joined(separator: ", "))."
    }

    private enum CodingKeys: String, CodingKey {
        case layers
        case materialFiles
        case effectFiles
        case shaderFiles
        case textureFiles
        case audioFiles
        case videoFiles
        case shaderUniforms
        case requiresSceneScriptRuntime
        case requiresParticleRuntime
        case requiresSoundRuntime
        case requiresModelRuntime
        case requiresVideoTextureRuntime
        case requiresShaderPipeline
        case requiresAudioAnalysis
        case requiresEngineRenderer
        case runtimeGaps
        case userFacingSummary
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        layers = try container.decode([SceneRuntimeLayerFeature].self, forKey: .layers)
        materialFiles = try container.decode([String].self, forKey: .materialFiles)
        effectFiles = try container.decode([String].self, forKey: .effectFiles)
        shaderFiles = try container.decode([String].self, forKey: .shaderFiles)
        textureFiles = try container.decode([String].self, forKey: .textureFiles)
        audioFiles = try container.decode([String].self, forKey: .audioFiles)
        videoFiles = try container.decode([String].self, forKey: .videoFiles)
        shaderUniforms = try container.decode([String].self, forKey: .shaderUniforms)
        requiresSceneScriptRuntime = try container.decode(Bool.self, forKey: .requiresSceneScriptRuntime)
        requiresParticleRuntime = try container.decode(Bool.self, forKey: .requiresParticleRuntime)
        requiresSoundRuntime = try container.decode(Bool.self, forKey: .requiresSoundRuntime)
        requiresModelRuntime = try container.decodeIfPresent(Bool.self, forKey: .requiresModelRuntime) ?? false
        requiresVideoTextureRuntime = try container.decode(Bool.self, forKey: .requiresVideoTextureRuntime)
        requiresShaderPipeline = try container.decode(Bool.self, forKey: .requiresShaderPipeline)
        requiresAudioAnalysis = try container.decode(Bool.self, forKey: .requiresAudioAnalysis)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(layers, forKey: .layers)
        try container.encode(materialFiles, forKey: .materialFiles)
        try container.encode(effectFiles, forKey: .effectFiles)
        try container.encode(shaderFiles, forKey: .shaderFiles)
        try container.encode(textureFiles, forKey: .textureFiles)
        try container.encode(audioFiles, forKey: .audioFiles)
        try container.encode(videoFiles, forKey: .videoFiles)
        try container.encode(shaderUniforms, forKey: .shaderUniforms)
        try container.encode(requiresSceneScriptRuntime, forKey: .requiresSceneScriptRuntime)
        try container.encode(requiresParticleRuntime, forKey: .requiresParticleRuntime)
        try container.encode(requiresSoundRuntime, forKey: .requiresSoundRuntime)
        try container.encode(requiresModelRuntime, forKey: .requiresModelRuntime)
        try container.encode(requiresVideoTextureRuntime, forKey: .requiresVideoTextureRuntime)
        try container.encode(requiresShaderPipeline, forKey: .requiresShaderPipeline)
        try container.encode(requiresAudioAnalysis, forKey: .requiresAudioAnalysis)
        try container.encode(requiresEngineRenderer, forKey: .requiresEngineRenderer)
        try container.encode(runtimeGaps, forKey: .runtimeGaps)
        try container.encode(userFacingSummary, forKey: .userFacingSummary)
    }
}

public struct SceneRuntimeFeatureAnalyzer: Sendable {
    public init() {}

    public func analyze(url: URL) throws -> SceneRuntimeFeatures {
        let package = try ScenePackageReader().read(url: url)
        guard let sceneData = package.data(forPath: "scene.json"),
              let scene = try JSONSerialization.jsonObject(with: sceneData) as? [String: Any] else {
            throw ScenePackageError.missingSceneJSON
        }
        return analyze(package: package, scene: scene)
    }

    public func analyze(package: ScenePackage, scene: [String: Any]) -> SceneRuntimeFeatures {
        let objects = scene["objects"] as? [[String: Any]] ?? []
        let layers = objects.enumerated().map { index, object in
            SceneRuntimeLayerFeature(
                id: Self.intValue(object["id"]),
                name: Self.stringValue(object["name"]) ?? "layer-\(index)",
                kind: Self.kind(of: object),
                effectFiles: Self.effectFiles(from: object),
                scriptCount: Self.scriptCount(in: object),
                constantShaderValueKeys: Self.constantShaderValueKeys(from: object)
            )
        }
        let shaderFiles = Self.paths(in: package, where: { $0.hasPrefix("shaders/") })
        let shaderUniforms = Self.shaderUniforms(in: package, shaderFiles: shaderFiles)
        let hasAudioUniforms = shaderUniforms.contains { $0.hasPrefix("g_Audio") }
        let videoFiles = Self.paths(in: package, where: { Self.videoExtensions.contains(Self.pathExtension($0)) })
        return SceneRuntimeFeatures(
            layers: layers,
            materialFiles: Self.paths(in: package, where: { $0.hasPrefix("materials/") && $0.hasSuffix(".json") }),
            effectFiles: Self.paths(in: package, where: { $0.hasPrefix("effects/") }),
            shaderFiles: shaderFiles,
            textureFiles: Self.paths(in: package, where: { $0.hasSuffix(".tex") }),
            audioFiles: Self.paths(in: package, where: { Self.audioExtensions.contains(Self.pathExtension($0)) }),
            videoFiles: videoFiles,
            shaderUniforms: shaderUniforms,
            requiresSceneScriptRuntime: layers.contains { $0.scriptCount > 0 },
            requiresParticleRuntime: layers.contains { $0.kind == "particle" },
            requiresSoundRuntime: layers.contains { $0.kind == "sound" },
            requiresModelRuntime: layers.contains { $0.kind == "model" },
            requiresVideoTextureRuntime: !videoFiles.isEmpty,
            requiresShaderPipeline: !shaderFiles.isEmpty || layers.contains { !$0.effectFiles.isEmpty },
            requiresAudioAnalysis: hasAudioUniforms || Self.containsAudioScript(in: objects)
        )
    }

    private static let audioExtensions = Set(["mp3", "wav", "ogg"])
    private static let videoExtensions = Set(["mp4", "webm"])
    private static let maximumJSONTraversalDepth = 64
    private static let knownShaderUniforms = [
        "g_Time",
        "g_Texture0Resolution",
        "g_Texture1Resolution",
        "g_Texture2Resolution",
        "g_Texture3Resolution",
        "g_AudioSpectrum16Left",
        "g_AudioSpectrum16Right",
        "g_AudioSpectrum16",
        "g_AudioFrequencyMin",
        "g_AudioFrequencyMax",
        "g_AudioPower"
    ]

    private static func paths(in package: ScenePackage, where predicate: (String) -> Bool) -> [String] {
        package.entries.map(\.path).filter(predicate).sorted()
    }

    private static func pathExtension(_ path: String) -> String {
        URL(filePath: path).pathExtension.lowercased()
    }

    private static func shaderUniforms(in package: ScenePackage, shaderFiles: [String]) -> [String] {
        var uniforms = Set<String>()
        for path in shaderFiles {
            guard let data = package.data(forPath: path),
                  let source = String(data: data, encoding: .utf8) else {
                continue
            }
            for uniform in knownShaderUniforms where containsIdentifier(uniform, in: source) {
                uniforms.insert(uniform)
            }
        }
        return uniforms.sorted()
    }

    private static func containsIdentifier(_ identifier: String, in source: String) -> Bool {
        var searchRange = source.startIndex..<source.endIndex
        while let range = source.range(of: identifier, options: [], range: searchRange) {
            let hasIdentifierPrefix = range.lowerBound > source.startIndex
                && isIdentifierCharacter(source[source.index(before: range.lowerBound)])
            let hasIdentifierSuffix = range.upperBound < source.endIndex
                && isIdentifierCharacter(source[range.upperBound])
            if !hasIdentifierPrefix && !hasIdentifierSuffix {
                return true
            }
            searchRange = range.upperBound..<source.endIndex
        }
        return false
    }

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character == "_" || character.isLetter || character.isNumber
    }

    private static func kind(of object: [String: Any]) -> String {
        if object["image"] != nil {
            return "image"
        }
        if object["text"] != nil {
            return "text"
        }
        if object["particle"] != nil {
            return "particle"
        }
        if object["sound"] != nil {
            return "sound"
        }
        if object["model"] != nil {
            return "model"
        }
        return "unknown"
    }

    private static func effectFiles(from object: [String: Any]) -> [String] {
        guard let effects = object["effects"] as? [[String: Any]] else {
            return []
        }
        return effects.compactMap { stringValue($0["file"]) }.sorted()
    }

    private static func constantShaderValueKeys(from object: [String: Any]) -> [String] {
        var keys = Set<String>()
        collectConstantShaderValueKeys(object, into: &keys, depth: 0)
        return keys.sorted()
    }

    private static func collectConstantShaderValueKeys(_ value: Any, into keys: inout Set<String>, depth: Int) {
        guard depth <= maximumJSONTraversalDepth else {
            return
        }
        if let dict = value as? [String: Any] {
            if let constants = dict["constantshadervalues"] as? [String: Any] {
                keys.formUnion(constants.keys)
            }
            for child in dict.values {
                collectConstantShaderValueKeys(child, into: &keys, depth: depth + 1)
            }
        } else if let array = value as? [Any] {
            for child in array {
                collectConstantShaderValueKeys(child, into: &keys, depth: depth + 1)
            }
        }
    }

    private static func scriptCount(in value: Any, depth: Int = 0) -> Int {
        guard depth <= maximumJSONTraversalDepth else {
            return 0
        }
        if let dict = value as? [String: Any] {
            let ownCount = stringValue(dict["script"]) == nil ? 0 : 1
            return ownCount + dict.values.reduce(0) { $0 + scriptCount(in: $1, depth: depth + 1) }
        }
        if let array = value as? [Any] {
            return array.reduce(0) { $0 + scriptCount(in: $1, depth: depth + 1) }
        }
        return 0
    }

    private static func containsAudioScript(in objects: [[String: Any]]) -> Bool {
        objects.contains { object in
            Self.scriptSource(in: object).contains { source in
                source.contains("registerAudioBuffers")
                    || source.contains("AudioBuffers")
                    || source.contains("audio")
            }
        }
    }

    private static func scriptSource(in value: Any, depth: Int = 0) -> [String] {
        guard depth <= maximumJSONTraversalDepth else {
            return []
        }
        if let dict = value as? [String: Any] {
            var scripts = stringValue(dict["script"]).map { [$0] } ?? []
            for child in dict.values {
                scripts.append(contentsOf: scriptSource(in: child, depth: depth + 1))
            }
            return scripts
        }
        if let array = value as? [Any] {
            return array.flatMap { scriptSource(in: $0, depth: depth + 1) }
        }
        return []
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        if let dict = value as? [String: Any] {
            return stringValue(dict["value"])
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }
}
