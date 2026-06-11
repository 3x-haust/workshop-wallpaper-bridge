import Foundation
// swiftlint:disable identifier_name

public struct SceneSize: Equatable, Sendable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct SceneVector3: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

public struct SceneVectorKeyframe: Equatable, Sendable {
    public let time: Double
    public let value: SceneVector3

    public init(time: Double, value: SceneVector3) {
        self.time = time
        self.value = value
    }
}

public struct SceneVectorAnimation: Equatable, Sendable {
    public let duration: Double
    public let isRelative: Bool
    public let autoreverses: Bool
    public let keyframes: [SceneVectorKeyframe]

    public init(duration: Double, isRelative: Bool, autoreverses: Bool = false, keyframes: [SceneVectorKeyframe]) {
        self.duration = duration
        self.isRelative = isRelative
        self.autoreverses = autoreverses
        self.keyframes = keyframes
    }
}

public struct SceneScalarKeyframe: Equatable, Sendable {
    public let time: Double
    public let value: Double

    public init(time: Double, value: Double) {
        self.time = time
        self.value = value
    }
}

public struct SceneScalarAnimation: Equatable, Sendable {
    public let duration: Double
    public let isRelative: Bool
    public let autoreverses: Bool
    public let keyframes: [SceneScalarKeyframe]

    public init(duration: Double, isRelative: Bool, autoreverses: Bool = false, keyframes: [SceneScalarKeyframe]) {
        self.duration = duration
        self.isRelative = isRelative
        self.autoreverses = autoreverses
        self.keyframes = keyframes
    }
}

public struct SceneColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

public enum SceneTextHorizontalAlignment: String, Equatable, Sendable {
    case left
    case center
    case right
}

public enum SceneTextVerticalAlignment: String, Equatable, Sendable {
    case top
    case center
    case bottom
}

public enum SceneDynamicText: Equatable, Sendable {
    case clock(SceneClockText)
}

public struct SceneClockText: Equatable, Sendable {
    public let uses24HourFormat: Bool
    public let showsSeconds: Bool
    public let delimiter: String

    public init(uses24HourFormat: Bool, showsSeconds: Bool, delimiter: String) {
        self.uses24HourFormat = uses24HourFormat
        self.showsSeconds = showsSeconds
        self.delimiter = delimiter
    }

    public func string(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        var hour = components.hour ?? 0
        if !uses24HourFormat {
            hour %= 12
            if hour == 0 {
                hour = 12
            }
        }
        var parts = [
            Self.twoDigit(hour),
            Self.twoDigit(components.minute ?? 0)
        ]
        if showsSeconds {
            parts.append(Self.twoDigit(components.second ?? 0))
        }
        return parts.joined(separator: delimiter)
    }

    private static func twoDigit(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}

public struct SceneTextLayer: Equatable, Sendable {
    public let value: String
    public let fontPath: String?
    public let pointSize: Double
    public let color: SceneColor
    public let horizontalAlignment: SceneTextHorizontalAlignment
    public let verticalAlignment: SceneTextVerticalAlignment
    public let dynamicText: SceneDynamicText?
    public let script: SceneTextScript?

    public init(
        value: String,
        fontPath: String?,
        pointSize: Double,
        color: SceneColor,
        horizontalAlignment: SceneTextHorizontalAlignment,
        verticalAlignment: SceneTextVerticalAlignment,
        dynamicText: SceneDynamicText? = nil,
        script: SceneTextScript? = nil
    ) {
        self.value = value
        self.fontPath = fontPath
        self.pointSize = pointSize
        self.color = color
        self.horizontalAlignment = horizontalAlignment
        self.verticalAlignment = verticalAlignment
        self.dynamicText = dynamicText
        self.script = script
    }
}

public enum SceneScriptPropertyValue: Equatable, Sendable {
    case bool(Bool)
    case number(Double)
    case string(String)
}

public struct SceneTextScript: Equatable, Sendable {
    public let source: String
    public let properties: [String: SceneScriptPropertyValue]

    public init(source: String, properties: [String: SceneScriptPropertyValue] = [:]) {
        self.source = source
        self.properties = properties
    }
}

public enum SceneLayerEffect: String, Equatable, Sendable {
    case waterFlow
    case waterWaves
    case waterRipple
    case shake
    case scroll
    case spin
    case shine
    case opacity
    case bloom
    case blur
    case chromaticAberration
    case clouds
    case godRays
    case localContrast
    case materialColor
    case pulse
    case sparkle
}

public struct SceneEffectMaskReference: Equatable, Sendable {
    public let source: String
    public let texturePath: String?

    public init(source: String, texturePath: String? = nil) {
        self.source = source
        self.texturePath = texturePath
    }
}

public struct SceneLayerEffectSetting: Equatable, Sendable {
    public let effect: SceneLayerEffect
    public let speed: Double?
    public let speedX: Double?
    public let speedY: Double?
    public let strength: Double?
    public let scale: Double?
    public let perspective: Double?
    public let direction: SceneVector3?
    public let bounds: SceneSize?
    public let speedVector: [Double]?
    public let auxiliaryTexturePath: String?
    public let usesMask: Bool
    public let maskReference: SceneEffectMaskReference?

    public init(
        effect: SceneLayerEffect,
        speed: Double? = nil,
        speedX: Double? = nil,
        speedY: Double? = nil,
        strength: Double? = nil,
        scale: Double? = nil,
        perspective: Double? = nil,
        direction: SceneVector3? = nil,
        bounds: SceneSize? = nil,
        speedVector: [Double]? = nil,
        auxiliaryTexturePath: String? = nil,
        usesMask: Bool = false,
        maskReference: SceneEffectMaskReference? = nil
    ) {
        self.effect = effect
        self.speed = speed
        self.speedX = speedX
        self.speedY = speedY
        self.strength = strength
        self.scale = scale
        self.perspective = perspective
        self.direction = direction
        self.bounds = bounds
        self.speedVector = speedVector
        self.auxiliaryTexturePath = auxiliaryTexturePath
        self.usesMask = usesMask || maskReference != nil
        self.maskReference = maskReference
    }
}

public struct SceneLayer: Equatable, Sendable {
    public let id: Int
    public let name: String
    public let texturePath: String
    public let text: SceneTextLayer?
    public let effects: [SceneLayerEffect]
    public let effectSettings: [SceneLayerEffectSetting]
    public let isEffectOnly: Bool
    public let origin: SceneVector3
    public let size: SceneSize
    public let scale: SceneVector3
    public let angles: SceneVector3
    public let alpha: Double
    public let originAnimation: SceneVectorAnimation?
    public let scaleAnimation: SceneVectorAnimation?
    public let angleAnimation: SceneVectorAnimation?
    public let alphaAnimation: SceneScalarAnimation?

    public var hasAnimation: Bool {
        originAnimation != nil || scaleAnimation != nil || angleAnimation != nil || alphaAnimation != nil
    }

    public init(
        id: Int,
        name: String,
        texturePath: String,
        text: SceneTextLayer? = nil,
        effects: [SceneLayerEffect] = [],
        effectSettings: [SceneLayerEffectSetting] = [],
        isEffectOnly: Bool = false,
        origin: SceneVector3,
        size: SceneSize,
        scale: SceneVector3,
        alpha: Double,
        angles: SceneVector3 = SceneVector3(x: 0, y: 0, z: 0),
        originAnimation: SceneVectorAnimation?,
        scaleAnimation: SceneVectorAnimation? = nil,
        angleAnimation: SceneVectorAnimation? = nil,
        alphaAnimation: SceneScalarAnimation? = nil
    ) {
        self.id = id
        self.name = name
        self.texturePath = texturePath
        self.text = text
        self.effects = effects
        self.effectSettings = effectSettings
        self.isEffectOnly = isEffectOnly
        self.origin = origin
        self.size = size
        self.scale = scale
        self.angles = angles
        self.alpha = alpha
        self.originAnimation = originAnimation
        self.scaleAnimation = scaleAnimation
        self.angleAnimation = angleAnimation
        self.alphaAnimation = alphaAnimation
    }
}

/// Conservative summary of a Wallpaper Engine particle system, carrying only
/// the fields the macOS renderer can approximate with Core Animation emitters.
public struct SceneParticleLayer: Equatable, Sendable {
    public let name: String
    public let origin: SceneVector3
    public let maxCount: Int
    public let rate: Double
    public let lifetimeMin: Double
    public let lifetimeMax: Double
    public let sizeMin: Double
    public let sizeMax: Double
    public let velocityMin: SceneVector3
    public let velocityMax: SceneVector3
    public let emitterRadius: Double
    public let hasAlphaFade: Bool
    public let sizeChangeStart: Double?
    public let sizeChangeEnd: Double?
    public let angularVelocity: Double?
    public let startTime: Double
    public let isTrail: Bool
    public let texturePath: String?
    /// Number of content layers declared before this particle system, so the
    /// renderer can slot it at the matching depth.
    public let insertionIndex: Int

    public init(
        name: String,
        origin: SceneVector3,
        maxCount: Int,
        rate: Double,
        lifetimeMin: Double,
        lifetimeMax: Double,
        sizeMin: Double,
        sizeMax: Double,
        velocityMin: SceneVector3 = SceneVector3(x: 0, y: 0, z: 0),
        velocityMax: SceneVector3 = SceneVector3(x: 0, y: 0, z: 0),
        emitterRadius: Double = 0,
        hasAlphaFade: Bool = false,
        sizeChangeStart: Double? = nil,
        sizeChangeEnd: Double? = nil,
        angularVelocity: Double? = nil,
        startTime: Double = 0,
        isTrail: Bool = false,
        texturePath: String? = nil,
        insertionIndex: Int = .max
    ) {
        self.name = name
        self.origin = origin
        self.maxCount = maxCount
        self.rate = rate
        self.lifetimeMin = lifetimeMin
        self.lifetimeMax = lifetimeMax
        self.sizeMin = sizeMin
        self.sizeMax = sizeMax
        self.velocityMin = velocityMin
        self.velocityMax = velocityMax
        self.emitterRadius = emitterRadius
        self.hasAlphaFade = hasAlphaFade
        self.sizeChangeStart = sizeChangeStart
        self.sizeChangeEnd = sizeChangeEnd
        self.angularVelocity = angularVelocity
        self.startTime = startTime
        self.isTrail = isTrail
        self.texturePath = texturePath
        self.insertionIndex = insertionIndex
    }
}

public struct SceneRenderPlan: Equatable, Sendable {
    public let canvasSize: SceneSize
    public let layers: [SceneLayer]
    public let textures: [String: SceneTexture]
    public let particleLayers: [SceneParticleLayer]

    public var hasRenderableContent: Bool {
        layers.contains { layer in
            guard !layer.isEffectOnly else {
                return false
            }
            if layer.text != nil {
                return true
            }
            return !layer.texturePath.isEmpty && textures[layer.texturePath] != nil
        }
    }

    public init(
        canvasSize: SceneSize,
        layers: [SceneLayer],
        textures: [String: SceneTexture],
        particleLayers: [SceneParticleLayer] = []
    ) {
        self.canvasSize = canvasSize
        self.layers = layers
        self.textures = textures
        self.particleLayers = particleLayers
    }
}

public struct SceneRenderPlanBuilder: Sendable {
    private let maximumDecodedLayerCount: Int

    public init(maximumDecodedLayerCount: Int = 24) {
        self.maximumDecodedLayerCount = maximumDecodedLayerCount
    }

    public func canBuild(url: URL) -> Bool {
        guard let plan = try? build(url: url, decodeTextures: true) else {
            return false
        }
        return plan.hasRenderableContent
    }

    public func build(url: URL) throws -> SceneRenderPlan {
        try build(url: url, decodeTextures: true)
    }

    public func buildLayout(url: URL) throws -> SceneRenderPlan {
        try build(url: url, decodeTextures: false)
    }

    private func build(url: URL, decodeTextures: Bool) throws -> SceneRenderPlan {
        let package = try ScenePackageReader().read(url: url)
        guard let sceneData = package.data(forPath: "scene.json"),
              let scene = try JSONSerialization.jsonObject(with: sceneData) as? [String: Any] else {
            throw SceneRenderPlanError.missingSceneJSON
        }
        let objects = scene["objects"] as? [[String: Any]] ?? []
        let canvasSize = Self.canvasSize(from: scene)
        var layers: [SceneLayer] = []
        var textures: [String: SceneTexture] = [:]
        var particleLayers: [SceneParticleLayer] = []

        for object in objects where Self.isVisible(object["visible"]) {
            if let particlePath = Self.stringValue(object["particle"]) {
                if let particle = Self.particleLayer(
                    from: object,
                    particlePath: particlePath,
                    package: package,
                    insertionIndex: layers.count
                ) {
                    particleLayers.append(particle)
                }
                continue
            }
            if let imagePath = Self.stringValue(object["image"]) {
                if let texturePath = try resolveTexturePath(imagePath: imagePath, package: package) {
                    var texture: SceneTexture?
                    if decodeTextures {
                        if let cachedTexture = textures[texturePath] {
                            texture = cachedTexture
                        } else {
                            guard let textureData = package.data(forPath: texturePath) else {
                                continue
                            }
                            do {
                                texture = try SceneTextureDecoder().decode(data: textureData)
                            } catch {
                                continue
                            }
                            textures[texturePath] = texture
                        }
                    }
                    layers.append(Self.layer(
                        from: object,
                        package: package,
                        texturePath: texturePath,
                        text: nil,
                        texture: texture,
                        isEffectOnly: false,
                        canvasSize: canvasSize
                    ))
                } else if Self.isEffectOnlyImageLayer(imagePath: imagePath, object: object) {
                    layers.append(Self.layer(
                        from: object,
                        package: package,
                        texturePath: "",
                        text: nil,
                        texture: nil,
                        isEffectOnly: true,
                        canvasSize: canvasSize
                    ))
                }
            } else if let text = Self.textLayer(from: object) {
                layers.append(Self.layer(
                    from: object,
                    package: package,
                    texturePath: "",
                    text: text,
                    texture: nil,
                    isEffectOnly: false,
                    canvasSize: canvasSize
                ))
            }
            if decodeTextures, layers.count >= maximumDecodedLayerCount {
                break
            }
        }

        guard !layers.isEmpty else {
            throw SceneRenderPlanError.noRenderableLayers
        }
        let arrangedLayers = Self.distributeFullCanvasWarpEffects(
            Self.deduplicatedMaskedTextLayers(Self.sortedLayers(layers)),
            canvasSize: canvasSize
        )
        if decodeTextures {
            try Self.decodeEffectTextures(in: arrangedLayers, package: package, textures: &textures)
            Self.decodeParticleTextures(in: particleLayers, package: package, textures: &textures)
        }
        return SceneRenderPlan(
            canvasSize: canvasSize,
            layers: arrangedLayers,
            textures: textures,
            particleLayers: particleLayers
        )
    }

    /// Full-canvas effect-only layers (Wallpaper Engine compose layers) warp
    /// everything rendered beneath them. A frozen snapshot overlay would hide
    /// the live motion of the layers below, so their warp-style effects are
    /// pushed down onto each underlying image layer instead.
    static func distributeFullCanvasWarpEffects(
        _ layers: [SceneLayer],
        canvasSize: SceneSize
    ) -> [SceneLayer] {
        let warpEffects: Set<SceneLayerEffect> = [.waterFlow, .waterWaves, .waterRipple, .scroll]
        let canvasArea = max(canvasSize.width * canvasSize.height, 1)
        var result = layers
        var index = 0
        while index < result.count {
            let layer = result[index]
            let coverage = abs(layer.size.width * layer.size.height) / canvasArea
            guard layer.isEffectOnly, coverage >= 0.5 else {
                index += 1
                continue
            }
            let distributable = layer.effectSettings.filter { warpEffects.contains($0.effect) }
            let targets = (0..<index).filter { result[$0].text == nil && !result[$0].isEffectOnly }
            guard !distributable.isEmpty, !targets.isEmpty else {
                index += 1
                continue
            }
            for target in targets {
                result[target] = Self.appendingEffects(distributable, to: result[target])
            }
            let remaining = layer.effectSettings.filter { !warpEffects.contains($0.effect) }
            if remaining.isEmpty {
                result.remove(at: index)
            } else {
                result[index] = Self.replacingEffects(remaining, in: layer)
                index += 1
            }
        }
        return result
    }

    private static func appendingEffects(
        _ settings: [SceneLayerEffectSetting],
        to layer: SceneLayer
    ) -> SceneLayer {
        Self.replacingEffects(layer.effectSettings + settings, in: layer)
    }

    private static func replacingEffects(
        _ settings: [SceneLayerEffectSetting],
        in layer: SceneLayer
    ) -> SceneLayer {
        SceneLayer(
            id: layer.id,
            name: layer.name,
            texturePath: layer.texturePath,
            text: layer.text,
            effects: settings.map(\.effect),
            effectSettings: settings,
            isEffectOnly: layer.isEffectOnly,
            origin: layer.origin,
            size: layer.size,
            scale: layer.scale,
            alpha: layer.alpha,
            angles: layer.angles,
            originAnimation: layer.originAnimation,
            scaleAnimation: layer.scaleAnimation,
            angleAnimation: layer.angleAnimation,
            alphaAnimation: layer.alphaAnimation
        )
    }

    private static let maximumParticleCount = 1_000

    private static func particleLayer(
        from object: [String: Any],
        particlePath: String,
        package: ScenePackage,
        insertionIndex: Int
    ) -> SceneParticleLayer? {
        guard let data = package.data(forPath: particlePath),
              let particle = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let emitters = particle["emitter"] as? [[String: Any]],
              let emitter = emitters.first else {
            return nil
        }
        let initializers = particle["initializer"] as? [[String: Any]] ?? []
        let operators = particle["operator"] as? [[String: Any]] ?? []
        let renderers = particle["renderer"] as? [[String: Any]] ?? []
        func initializer(_ name: String) -> [String: Any]? {
            initializers.first { stringValue($0["name"]) == name }
        }
        func operatorNamed(_ name: String) -> [String: Any]? {
            operators.first { stringValue($0["name"]) == name }
        }
        let lifetime = initializer("lifetimerandom")
        let size = initializer("sizerandom")
        let velocity = initializer("velocityrandom")
        let angular = initializer("angularvelocityrandom")
        let sizeChange = operatorNamed("sizechange")
        let rendererName = renderers.compactMap { stringValue($0["name"]) }.first ?? "sprite"
        guard rendererName == "sprite" || rendererName == "spritetrail" else {
            return nil
        }
        let texturePath = particleTexturePath(particle: particle, package: package)
        let origin = vectorValue(object["origin"]) ?? SceneVector3(x: 0, y: 0, z: 0)
        let lifetimeMin = max(doubleValue(lifetime?["min"]) ?? 1, 0.05)
        let lifetimeMax = max(doubleValue(lifetime?["max"]) ?? lifetimeMin, lifetimeMin)
        let sizeMin = max(doubleValue(size?["min"]) ?? 16, 1)
        let sizeMax = max(doubleValue(size?["max"]) ?? sizeMin, sizeMin)
        return SceneParticleLayer(
            name: stringValue(object["name"]) ?? particlePath,
            origin: origin,
            maxCount: min(max(intValue(particle["maxcount"]) ?? 100, 1), maximumParticleCount),
            rate: min(max(doubleValue(emitter["rate"]) ?? 1, 0), 100_000),
            lifetimeMin: lifetimeMin,
            lifetimeMax: lifetimeMax,
            sizeMin: sizeMin,
            sizeMax: sizeMax,
            velocityMin: vectorValue(velocity?["min"]) ?? SceneVector3(x: 0, y: 0, z: 0),
            velocityMax: vectorValue(velocity?["max"]) ?? SceneVector3(x: 0, y: 0, z: 0),
            emitterRadius: max(doubleValue(emitter["distancemax"]) ?? 0, 0),
            hasAlphaFade: operatorNamed("alphafade") != nil,
            sizeChangeStart: doubleValue(sizeChange?["startvalue"]),
            sizeChangeEnd: doubleValue(sizeChange?["endvalue"]),
            angularVelocity: (vectorValue(angular?["min"]) ?? vectorValue(angular?["max"]))?.z,
            startTime: doubleValue(particle["starttime"]) ?? 0,
            isTrail: rendererName == "spritetrail",
            texturePath: texturePath,
            insertionIndex: insertionIndex
        )
    }

    private static func particleTexturePath(particle: [String: Any], package: ScenePackage) -> String? {
        guard let materialPath = stringValue(particle["material"]),
              let materialData = package.data(forPath: materialPath),
              let material = (try? JSONSerialization.jsonObject(with: materialData)) as? [String: Any],
              let textureName = firstTextureName(in: material) else {
            return nil
        }
        return textureCandidates(for: textureName).first { package.entry(named: $0) != nil }
    }

    private static func decodeParticleTextures(
        in particleLayers: [SceneParticleLayer],
        package: ScenePackage,
        textures: inout [String: SceneTexture]
    ) {
        let decoder = SceneTextureDecoder()
        for texturePath in Set(particleLayers.compactMap(\.texturePath)) where textures[texturePath] == nil {
            guard let data = package.data(forPath: texturePath),
                  let texture = try? decoder.decode(data: data) else {
                continue
            }
            textures[texturePath] = texture
        }
    }

    private func resolveTexturePath(imagePath: String, package: ScenePackage) throws -> String? {
        guard let modelData = package.data(forPath: imagePath),
              let model = try JSONSerialization.jsonObject(with: modelData) as? [String: Any],
              let materialPath = Self.stringValue(model["material"]),
              let materialData = package.data(forPath: materialPath),
              let material = try JSONSerialization.jsonObject(with: materialData) as? [String: Any] else {
            return nil
        }
        guard let textureName = Self.firstTextureName(in: material) else {
            return nil
        }
        let candidates = Self.textureCandidates(for: textureName)
        return candidates.first { package.entry(named: $0) != nil }
    }

    private static func firstTextureName(in material: [String: Any]) -> String? {
        if let textures = material["textures"] as? [String], let first = textures.first {
            return first
        }
        if let texture = stringValue(material["texture"]) {
            return texture
        }
        for key in ["name", "file", "path"] {
            if let texture = stringValue(material[key]) {
                return texture
            }
        }
        guard let passes = material["passes"] as? [[String: Any]] else {
            return nil
        }
        for pass in passes {
            if let textures = pass["textures"] as? [String], let first = textures.first {
                return first
            }
            if let textures = pass["textures"] as? [Any] {
                for item in textures {
                    if let value = stringValue(item) {
                        return value
                    }
                    if let dict = item as? [String: Any],
                       let value = firstTextureName(in: dict) {
                        return value
                    }
                }
            }
            if let texture = stringValue(pass["texture"]) {
                return texture
            }
        }
        return nil
    }

    private static func textureCandidates(for textureName: String) -> [String] {
        let name = textureName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return []
        }
        if name.hasSuffix(".tex") {
            return name.contains("/") ? [name, "materials/\(name)"] : ["materials/\(name)", name]
        }
        if name.contains("/") {
            return ["\(name).tex", "materials/\(name).tex", name]
        }
        return ["materials/\(name).tex", "\(name).tex", name]
    }

    /// Resolves the non-mask helper texture an effect samples, such as a
    /// noise, normal, or phase map packed next to the effect material.
    private static func auxiliaryTexturePath(in effect: [String: Any], package: ScenePackage?) -> String? {
        guard let package else {
            return nil
        }
        var names: [String] = []
        collectEffectTextureNames(effect, into: &names, depth: 0)
        for name in names {
            let lowered = name.lowercased()
            guard !lowered.contains("mask"),
                  !lowered.hasPrefix("util/"),
                  !lowered.hasPrefix("_rt_") else {
                continue
            }
            if let resolved = textureCandidates(for: name).first(where: { package.entry(named: $0) != nil }) {
                return resolved
            }
        }
        return nil
    }

    private static func collectEffectTextureNames(_ value: Any, into names: inout [String], depth: Int) {
        guard depth <= 64 else {
            return
        }
        if let dict = value as? [String: Any] {
            if let textures = dict["textures"] as? [Any] {
                for texture in textures {
                    if let name = stringValue(texture), !name.isEmpty {
                        names.append(name)
                    }
                }
            }
            for child in dict.values {
                collectEffectTextureNames(child, into: &names, depth: depth + 1)
            }
        } else if let array = value as? [Any] {
            for child in array {
                collectEffectTextureNames(child, into: &names, depth: depth + 1)
            }
        }
    }

    private static func layer(
        from object: [String: Any],
        package: ScenePackage,
        texturePath: String,
        text: SceneTextLayer?,
        texture: SceneTexture?,
        isEffectOnly: Bool,
        canvasSize: SceneSize
    ) -> SceneLayer {
        let originValue = vectorValue(object["origin"]) ?? SceneVector3(
            x: canvasSize.width / 2,
            y: canvasSize.height / 2,
            z: 0
        )
        let scaleValue = vectorValue(object["scale"]) ?? SceneVector3(x: 1, y: 1, z: 1)
        let anglesValue = vectorValue(object["angles"]) ?? SceneVector3(x: 0, y: 0, z: 0)
        let alphaValue = scalarValue(object["alpha"]) ?? 1
        let sizeValue = sizeValue(object["size"]) ?? SceneSize(
            width: texture.map { Double($0.width) } ?? canvasSize.width,
            height: texture.map { Double($0.height) } ?? canvasSize.height
        )
        let layerEffectSettings = effectSettings(from: object, package: package)
        return SceneLayer(
            id: intValue(object["id"]) ?? 0,
            name: stringValue(object["name"]) ?? stringValue(object["id"]) ?? texturePath,
            texturePath: texturePath,
            text: text,
            effects: layerEffectSettings.map(\.effect),
            effectSettings: layerEffectSettings,
            isEffectOnly: isEffectOnly,
            origin: originValue,
            size: sizeValue,
            scale: scaleValue,
            alpha: alphaValue,
            angles: anglesValue,
            originAnimation: vectorAnimation(object["origin"], fallback: originValue),
            scaleAnimation: vectorAnimation(object["scale"], fallback: scaleValue),
            angleAnimation: vectorAnimation(object["angles"], fallback: anglesValue),
            alphaAnimation: scalarAnimation(object["alpha"], fallback: alphaValue)
        )
    }

    private static func sortedLayers(_ layers: [SceneLayer]) -> [SceneLayer] {
        layers.enumerated().sorted { lhs, rhs in
            let left = lhs.element
            let right = rhs.element
            if left.origin.z != right.origin.z {
                return left.origin.z < right.origin.z
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func deduplicatedMaskedTextLayers(_ layers: [SceneLayer]) -> [SceneLayer] {
        var result: [SceneLayer] = []
        for layer in layers {
            if isMaskedDuplicateTextLayer(layer, existingLayers: result) {
                continue
            }
            result.append(layer)
        }
        return result
    }

    private static func isMaskedDuplicateTextLayer(_ layer: SceneLayer, existingLayers: [SceneLayer]) -> Bool {
        guard let text = layer.text,
              layer.effectSettings.contains(where: { $0.effect == .opacity && $0.usesMask }) else {
            return false
        }
        return existingLayers.contains { existing in
            guard let existingText = existing.text else {
                return false
            }
            return existingText.value == text.value
                && existingText.dynamicText == text.dynamicText
                && abs(existing.origin.x - layer.origin.x) <= 4
                && abs(existing.origin.y - layer.origin.y) <= 4
        }
    }

    private static func textLayer(from object: [String: Any]) -> SceneTextLayer? {
        let textObject = object["text"]
        guard let value = stringValue(unwrappedValue(textObject))?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return SceneTextLayer(
            value: value,
            fontPath: stringValue(object["font"]),
            pointSize: scalarValue(object["pointsize"]) ?? 64,
            color: colorValue(object["color"]) ?? SceneColor(red: 1, green: 1, blue: 1),
            horizontalAlignment: horizontalAlignment(from: stringValue(object["horizontalalign"])),
            verticalAlignment: verticalAlignment(from: stringValue(object["verticalalign"])),
            dynamicText: dynamicText(from: textObject),
            script: textScript(from: textObject)
        )
    }

    private static func textScript(from value: Any?) -> SceneTextScript? {
        guard let text = value as? [String: Any],
              let script = stringValue(text["script"]),
              !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return SceneTextScript(
            source: script,
            properties: scriptProperties(from: text["scriptproperties"])
        )
    }

    private static func scriptProperties(from value: Any?) -> [String: SceneScriptPropertyValue] {
        guard let dictionary = value as? [String: Any] else {
            return [:]
        }
        var properties: [String: SceneScriptPropertyValue] = [:]
        for (key, rawValue) in dictionary {
            if let value = scriptPropertyValue(from: unwrappedValue(rawValue)) {
                properties[key] = value
            }
        }
        return properties
    }

    private static func scriptPropertyValue(from value: Any?) -> SceneScriptPropertyValue? {
        if let bool = value as? Bool {
            return .bool(bool)
        }
        if let number = value as? NSNumber {
            return .number(number.doubleValue)
        }
        if let string = value as? String {
            return .string(string)
        }
        return nil
    }

    private static func dynamicText(from value: Any?) -> SceneDynamicText? {
        guard let text = value as? [String: Any],
              let script = stringValue(text["script"]),
              script.contains("new Date()"),
              script.contains("time.getHours()"),
              script.contains("time.getMinutes()") else {
            return nil
        }
        let scriptProperties = text["scriptproperties"] as? [String: Any] ?? [:]
        let uses24HourFormat = boolValue(unwrappedValue(scriptProperties["use24hFormat"])) ?? true
        let showsSeconds = boolValue(unwrappedValue(scriptProperties["showSeconds"])) ?? false
        let delimiter = stringValue(unwrappedValue(scriptProperties["delimiter"])) ?? ":"
        return .clock(SceneClockText(
            uses24HourFormat: uses24HourFormat,
            showsSeconds: showsSeconds,
            delimiter: delimiter
        ))
    }

    private static func effectSettings(from object: [String: Any], package: ScenePackage? = nil) -> [SceneLayerEffectSetting] {
        guard let rawEffects = object["effects"] as? [[String: Any]] else {
            return []
        }
        var settings: [SceneLayerEffectSetting] = []
        for rawEffect in rawEffects where isVisible(rawEffect["visible"]) {
            guard let file = stringValue(rawEffect["file"])?.lowercased() else {
                continue
            }
            let effect: SceneLayerEffect?
            if file.contains("waterflow") {
                effect = .waterFlow
            } else if file.contains("waterwaves") {
                effect = .waterWaves
            } else if file.contains("waterripple") {
                effect = .waterRipple
            } else if file.contains("shake") {
                effect = .shake
            } else if file.contains("scroll") {
                effect = .scroll
            } else if file.contains("spin") {
                effect = .spin
            } else if file.contains("shine") {
                effect = .shine
            } else if file.contains("opacity") {
                effect = .opacity
            } else if file.contains("bloom") {
                effect = .bloom
            } else if file.contains("blur") {
                effect = .blur
            } else if file.contains("chromatic") || file.contains("aberration") {
                effect = .chromaticAberration
            } else if file.contains("cloud") {
                effect = .clouds
            } else if file.contains("godray") || file.contains("god-ray") || file.contains("god_ray") {
                effect = .godRays
            } else if file.contains("localcontrast") || file.contains("local-contrast") || file.contains("local_contrast") {
                effect = .localContrast
            } else if file.contains("materialcolor") || file.contains("material-color") || file.contains("material_color") {
                effect = .materialColor
            } else if file.contains("pulse") {
                effect = .pulse
            } else if file.contains("nitro") || file.contains("sparkle") {
                effect = .sparkle
            } else {
                effect = nil
            }
            if let effect {
                let constants = constantShaderValues(from: rawEffect)
                let speedX = doubleValue(constants["speedx"])
                let speedY = doubleValue(constants["speedy"])
                let speedComponents = numericList(constants["speed"])
                let maskReference = maskReference(in: rawEffect, package: package)
                settings.append(SceneLayerEffectSetting(
                    effect: effect,
                    speed: firstNonZeroDouble(
                        doubleValue(constants["speed"]),
                        doubleValue(constants["scrollspeed"]),
                        doubleValue(constants["animationspeed"]),
                        speedX,
                        speedY
                    ),
                    speedX: speedX,
                    speedY: speedY,
                    strength: doubleValue(constants["strength"])
                        ?? doubleValue(constants["ripplestrength"])
                        ?? doubleValue(constants["rayintensity"])
                        ?? doubleValue(constants["multiply"])
                        ?? doubleValue(constants["alpha"]),
                    scale: doubleValue(constants["scale"])
                        ?? numericList(constants["scale"]).first
                        ?? doubleValue(constants["phasescale"])
                        ?? doubleValue(constants["noisescale"]),
                    perspective: doubleValue(constants["perspective"]),
                    direction: vectorValue(constants["direction"])
                        ?? vectorValue(constants["scrolldirection"])
                        ?? directionVector(fromAngle: doubleValue(constants["direction"]))
                        ?? directionVector(fromAngle: doubleValue(constants["scrolldirection"])),
                    bounds: sizeValue(constants["bounds"]),
                    speedVector: speedComponents.count >= 4 ? Array(speedComponents.prefix(4)) : nil,
                    auxiliaryTexturePath: auxiliaryTexturePath(in: rawEffect, package: package),
                    usesMask: containsMaskReference(rawEffect, depth: 0),
                    maskReference: maskReference
                ))
            }
        }
        return settings
    }

    private static func decodeEffectTextures(
        in layers: [SceneLayer],
        package: ScenePackage,
        textures: inout [String: SceneTexture]
    ) throws {
        let effectTexturePaths = Set(layers.flatMap { layer in
            layer.effectSettings.compactMap { $0.maskReference?.texturePath }
                + layer.effectSettings.compactMap(\.auxiliaryTexturePath)
        })
        let decoder = SceneTextureDecoder()
        for texturePath in effectTexturePaths where textures[texturePath] == nil {
            guard let data = package.data(forPath: texturePath) else {
                continue
            }
            do {
                textures[texturePath] = try decoder.decode(data: data)
            } catch {
                continue
            }
        }
    }

    private static func firstNonZeroDouble(_ values: Double?...) -> Double? {
        values.compactMap(\.self).first { abs($0) > 0.000_001 } ?? values.compactMap(\.self).first
    }

    private static func directionVector(fromAngle angle: Double?) -> SceneVector3? {
        guard let angle else {
            return nil
        }
        return SceneVector3(x: -sin(angle), y: cos(angle), z: 0)
    }

    private static func constantShaderValues(from effect: [String: Any]) -> [String: Any] {
        var values: [String: Any] = [:]
        collectConstantShaderValues(effect, into: &values, depth: 0)
        return values
    }

    private static func maskReference(in effect: [String: Any], package: ScenePackage?) -> SceneEffectMaskReference? {
        guard let source = firstMaskReferenceSource(in: effect, depth: 0) else {
            return nil
        }
        return SceneEffectMaskReference(
            source: source,
            texturePath: resolvedTexturePath(for: source, package: package)
        )
    }

    private static func resolvedTexturePath(for source: String, package: ScenePackage?) -> String? {
        guard let package else {
            return nil
        }
        return textureCandidates(for: source).first { package.entry(named: $0) != nil }
    }

    private static func firstMaskReferenceSource(in value: Any, depth: Int) -> String? {
        guard depth <= 64 else {
            return nil
        }
        if let dict = value as? [String: Any] {
            for (key, child) in dict where key.lowercased().contains("mask") {
                if let childSource = firstString(in: child, depth: depth + 1) {
                    return childSource
                }
                return key
            }
            for child in dict.values {
                if let source = firstMaskReferenceSource(in: child, depth: depth + 1) {
                    return source
                }
            }
            return nil
        }
        if let array = value as? [Any] {
            for child in array {
                if let source = firstMaskReferenceSource(in: child, depth: depth + 1) {
                    return source
                }
            }
            return nil
        }
        guard let string = stringValue(value),
              string.lowercased().contains("mask") else {
            return nil
        }
        return string
    }

    private static func firstString(in value: Any, depth: Int) -> String? {
        guard depth <= 64 else {
            return nil
        }
        if let string = stringValue(value), !string.isEmpty {
            return string
        }
        if let array = value as? [Any] {
            for child in array {
                if let source = firstString(in: child, depth: depth + 1) {
                    return source
                }
            }
            return nil
        }
        if let dict = value as? [String: Any] {
            for child in dict.values {
                if let source = firstString(in: child, depth: depth + 1) {
                    return source
                }
            }
        }
        return nil
    }

    private static func collectConstantShaderValues(_ value: Any, into values: inout [String: Any], depth: Int) {
        guard depth <= 64 else {
            return
        }
        if let dict = value as? [String: Any] {
            if let constants = dict["constantshadervalues"] as? [String: Any] {
                for (key, value) in constants {
                    values[key.lowercased()] = unwrappedValue(value)
                }
            }
            for child in dict.values {
                collectConstantShaderValues(child, into: &values, depth: depth + 1)
            }
        } else if let array = value as? [Any] {
            for child in array {
                collectConstantShaderValues(child, into: &values, depth: depth + 1)
            }
        }
    }

    private static func containsMaskReference(_ value: Any, depth: Int) -> Bool {
        guard depth <= 64 else {
            return false
        }
        if let dict = value as? [String: Any] {
            return dict.contains { key, child in
                key.lowercased().contains("mask") || containsMaskReference(child, depth: depth + 1)
            }
        }
        if let array = value as? [Any] {
            return array.contains { containsMaskReference($0, depth: depth + 1) }
        }
        if let string = stringValue(value) {
            return string.lowercased().contains("mask")
        }
        return false
    }

    private static func isEffectOnlyImageLayer(imagePath: String, object: [String: Any]) -> Bool {
        imagePath == "models/util/composelayer.json" && !effectSettings(from: object).isEmpty
    }

    private static func canvasSize(from scene: [String: Any]) -> SceneSize {
        let projection = (scene["general"] as? [String: Any])?["orthogonalprojection"] as? [String: Any]
        let width = doubleValue(projection?["width"]) ?? 1920
        let height = doubleValue(projection?["height"]) ?? 1080
        return SceneSize(width: width, height: height)
    }

    private static func isVisible(_ value: Any?) -> Bool {
        if let bool = value as? Bool {
            return bool
        }
        if let dict = value as? [String: Any] {
            return boolValue(dict["value"]) ?? true
        }
        return true
    }

    private static func vectorAnimation(_ value: Any?, fallback: SceneVector3) -> SceneVectorAnimation? {
        guard let dict = value as? [String: Any],
              let animation = dict["animation"] as? [String: Any] else {
            return nil
        }
        let options = animation["options"] as? [String: Any]
        let fps = doubleValue(options?["fps"]) ?? 30
        let isRelative = boolValue(options?["relative"]) ?? false
        let autoreverses = stringValue(options?["mode"])?.lowercased() == "mirror"
        let missingChannelValue = isRelative ? SceneVector3(x: 0, y: 0, z: 0) : fallback
        let channels = [
            channelFrames(animation["c0"], fps: fps),
            channelFrames(animation["c1"], fps: fps),
            channelFrames(animation["c2"], fps: fps)
        ]
        let duration = animationDuration(animation, fps: fps, channels: channels)
        let times = Set(channels.flatMap { $0.keys }).sorted()
        let keyframes = times.map { time in
            SceneVectorKeyframe(
                time: time,
                value: SceneVector3(
                    x: interpolatedValue(at: time, in: channels[0], fallback: missingChannelValue.x),
                    y: interpolatedValue(at: time, in: channels[1], fallback: missingChannelValue.y),
                    z: interpolatedValue(at: time, in: channels[2], fallback: missingChannelValue.z)
                )
            )
        }
        guard keyframes.count >= 2 else {
            return nil
        }
        return SceneVectorAnimation(
            duration: max(duration, 0.1),
            isRelative: isRelative,
            autoreverses: autoreverses,
            keyframes: keyframes
        )
    }

    private static func scalarAnimation(_ value: Any?, fallback: Double) -> SceneScalarAnimation? {
        guard let dict = value as? [String: Any],
              let animation = dict["animation"] as? [String: Any] else {
            return nil
        }
        let options = animation["options"] as? [String: Any]
        let fps = doubleValue(options?["fps"]) ?? 30
        let isRelative = boolValue(options?["relative"]) ?? false
        let autoreverses = stringValue(options?["mode"])?.lowercased() == "mirror"
        let frames = channelFrames(animation["c0"], fps: fps)
        let duration = animationDuration(animation, fps: fps, channels: [frames])
        let missingChannelValue = isRelative ? 0 : fallback
        let keyframes = frames.keys.sorted().map { time in
            SceneScalarKeyframe(time: time, value: frames[time] ?? missingChannelValue)
        }
        guard keyframes.count >= 2 else {
            return nil
        }
        return SceneScalarAnimation(
            duration: max(duration, 0.1),
            isRelative: isRelative,
            autoreverses: autoreverses,
            keyframes: keyframes
        )
    }

    private static func animationDuration(
        _ animation: [String: Any],
        fps: Double,
        channels: [[Double: Double]]
    ) -> Double {
        let rawLength = doubleValue((animation["options"] as? [String: Any])?["length"])
        let maxKeyTime = channels.flatMap { $0.keys }.max() ?? 0
        guard let rawLength else {
            return max(maxKeyTime, 0.1)
        }
        let safeFPS = max(fps, 1)
        let interpretedLength = maxKeyTime > 0 && rawLength > maxKeyTime * 1.5
            ? rawLength / safeFPS
            : rawLength
        return max(interpretedLength, maxKeyTime, 0.1)
    }

    private static func interpolatedValue(
        at time: Double,
        in frames: [Double: Double],
        fallback: Double
    ) -> Double {
        guard !frames.isEmpty else {
            return fallback
        }
        if let exact = frames[time] {
            return exact
        }
        let times = frames.keys.sorted()
        guard let first = times.first, let last = times.last else {
            return fallback
        }
        if time <= first {
            return frames[first] ?? fallback
        }
        if time >= last {
            return frames[last] ?? fallback
        }
        for index in 1..<times.count {
            let previous = times[index - 1]
            let next = times[index]
            guard previous <= time, time <= next,
                  let previousValue = frames[previous],
                  let nextValue = frames[next] else {
                continue
            }
            let progress = (time - previous) / max(next - previous, 0.000_001)
            return previousValue + ((nextValue - previousValue) * progress)
        }
        return fallback
    }

    private static func channelFrames(_ value: Any?, fps: Double) -> [Double: Double] {
        guard let frames = value as? [[String: Any]] else {
            return [:]
        }
        var result: [Double: Double] = [:]
        for frame in frames {
            guard let frameNumber = doubleValue(frame["frame"]),
                  let value = doubleValue(frame["value"]) else {
                continue
            }
            result[frameNumber / max(fps, 1)] = value
        }
        return result
    }

    private static func vectorValue(_ value: Any?) -> SceneVector3? {
        if let dict = value as? [String: Any] {
            return vectorValue(dict["value"])
        }
        let numbers = numericList(value)
        guard numbers.count >= 2 else {
            return nil
        }
        return SceneVector3(x: numbers[0], y: numbers[1], z: numbers.count >= 3 ? numbers[2] : 0)
    }

    private static func scalarValue(_ value: Any?) -> Double? {
        if let dict = value as? [String: Any] {
            return scalarValue(dict["value"])
        }
        return doubleValue(value)
    }

    private static func sizeValue(_ value: Any?) -> SceneSize? {
        if let dict = value as? [String: Any] {
            return sizeValue(dict["value"])
        }
        let numbers = numericList(value)
        guard numbers.count >= 2 else {
            return nil
        }
        return SceneSize(width: numbers[0], height: numbers[1])
    }

    private static func colorValue(_ value: Any?) -> SceneColor? {
        let numbers = numericList(value)
        guard numbers.count >= 3 else {
            return nil
        }
        return SceneColor(
            red: numbers[0],
            green: numbers[1],
            blue: numbers[2],
            alpha: numbers.count >= 4 ? numbers[3] : 1
        )
    }

    private static func horizontalAlignment(from value: String?) -> SceneTextHorizontalAlignment {
        switch value?.lowercased() {
        case "left":
            return .left
        case "right":
            return .right
        default:
            return .center
        }
    }

    private static func verticalAlignment(from value: String?) -> SceneTextVerticalAlignment {
        switch value?.lowercased() {
        case "top":
            return .top
        case "bottom":
            return .bottom
        default:
            return .center
        }
    }

    private static func unwrappedValue(_ value: Any?) -> Any? {
        if let dict = value as? [String: Any], dict.keys.contains("value") {
            return dict["value"]
        }
        return value
    }

    private static func numericList(_ value: Any?) -> [Double] {
        if let string = stringValue(value) {
            return string
                .replacingOccurrences(of: ",", with: " ")
                .split(separator: " ")
                .compactMap { Double($0) }
        }
        if let array = value as? [Any] {
            return array.compactMap(doubleValue)
        }
        return doubleValue(value).map { [$0] } ?? []
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            return ["true", "1", "yes"].contains(string.lowercased())
        }
        return nil
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

    private static func doubleValue(_ value: Any?) -> Double? {
        if let double = value as? Double {
            return double
        }
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string)
        }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }
}

public enum SceneRenderPlanError: Error, Equatable, LocalizedError {
    case missingSceneJSON
    case noRenderableLayers

    public var errorDescription: String? {
        switch self {
        case .missingSceneJSON:
            return "The scene package does not contain readable scene.json."
        case .noRenderableLayers:
            return "The scene package has no renderable scene layers."
        }
    }
}
