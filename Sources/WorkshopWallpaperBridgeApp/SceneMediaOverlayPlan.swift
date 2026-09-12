import AppKit
import CoreText
import WorkshopWallpaperCore

/// Separates supported live media layers from a scene's rendered background.
/// No files are extracted into, or changed in, the creator's project.
@MainActor
struct SceneMediaOverlayPlan {
    struct Layer {
        let model: SceneLayer
        let alignment: String
        let image: CGImage?
        let animation: SceneWallpaperView.SceneTextureFrameContents?
        let thumbnail: Bool
        let masks: [CGImage]
        let shaderEffects: [SceneShaderEffect]
    }
    struct Composition {
        let model: SceneLayer
        let alignment: String
        let effects: [SceneShaderEffect]
    }
    struct Particle {
        let model: SceneLayer
        let settings: [String: Any]
        let overrides: [String: Any]
        let sprite: CGImage
        let trail: [String: Any]?
        let trailSprite: CGImage?
    }
    let canvas: CGSize
    let layers: [Layer]
    let particles: [Particle]
    let compositions: [Composition]
    let order: [Int]
    var configuration: [String: Any]
    let metrics: SceneTextMetrics
    var excludedIDs: [Int] { (layers.map(\.model.id) + particles.map(\.model.id) + compositions.map(\.model.id)).sorted() }
    var cacheSuffix: String { "-media-v4" }

    static func build(url: URL) throws -> Self? {
        let package = try ScenePackageReader().read(url: url)
        func json(_ path: String) -> [String: Any]? {
            guard let data = package.data(forPath: path), data.count <= 4 * 1024 * 1024 else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        guard let scene = json("scene.json"), let objects = scene["objects"] as? [[String: Any]],
              objects.count <= 256, objects.contains(where: hasMedia) else { return nil }
        let layout = try SceneRenderPlanBuilder().buildLayout(url: url)
        guard Set(layout.runtimeLayers.map(\.id)).count == objects.count else { return nil }
        let models = Dictionary(uniqueKeysWithValues: layout.runtimeLayers.map { ($0.id, $0) })
        var configuration = SceneScriptSession.configuration(plan: layout, projectURL: url.deletingLastPathComponent())
        var runtimeLayers = configuration["layers"] as! [[String: Any]]
        var fonts: [String: String] = [:]
        var fontBytes = 0
        var layers: [Layer] = []
        var effectObjects: [[String: Any]] = []
        var particles: [Particle] = []
        var compositions: [Composition] = []
        var decoded: [String: CGImage] = [:]
        var animations: [String: SceneWallpaperView.SceneTextureFrameContents] = [:]
        var decodedPixels = 0
        var shaderSourceBytes = 0
        var shaderPassCount = 0
        func source(_ path: String) -> String? {
            if let data = package.data(forPath: path), data.count <= 512 * 1024 { return String(data: data, encoding: .utf8) }
            guard let root = SceneEngineRendererConfiguration.assetsDirectoryURL()?.resolvingSymlinksInPath() else { return nil }
            let file = root.appending(path: path).standardizedFileURL.resolvingSymlinksInPath()
            guard file.path.hasPrefix(root.path + "/"),
                  let length = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, length <= 512 * 1024,
                  let data = try? Data(contentsOf: file), data.count <= 512 * 1024 else { return nil }
            return String(data: data, encoding: .utf8)
        }
        func texture(_ name: String) throws -> CGImage? {
            if let existing = decoded[name] { return existing }
            guard decoded.count < 24 else { return nil }
            let candidates = [name, name + ".tex", "materials/" + name + ".tex"]
            let packed = candidates.compactMap({ package.data(forPath: $0) }).first
            var external: Data?
            if packed == nil, let root = SceneEngineRendererConfiguration.assetsDirectoryURL() {
                for candidate in candidates where external == nil {
                    let file = root.appending(path: candidate).standardizedFileURL.resolvingSymlinksInPath()
                    guard file.path.hasPrefix(root.resolvingSymlinksInPath().path + "/"),
                          let length = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                          length <= 64 * 1024 * 1024 else { continue }
                    external = try? Data(contentsOf: file)
                }
            }
            guard let data = packed ?? external else { return nil }
            let value = try SceneTextureDecoder(allowsReducedLargeDXT: true).decode(data: data)
            guard let image = SceneWallpaperView.cgImage(fromStorage: value.storage) else { return nil }
            decodedPixels += image.width * image.height
            if value.animation != nil {
                guard let frames = SceneWallpaperView.animationFrameContents(for: value) else { return nil }
                decodedPixels += frames.images.reduce(0) { $0 + $1.width * $1.height }
                animations[name] = frames
            }
            guard decodedPixels <= 32_000_000 else { return nil }
            decoded[name] = image
            return image
        }
        func shaderEffect(_ effect: [String: Any], layerID: Int) throws -> SceneShaderEffect {
            guard effectObjects.count < 128 else { throw SceneShaderEffect.Failure.unsupported("effect object limit") }
            guard let effectID = effect["id"] as? Int else { throw SceneShaderEffect.Failure.unsupported("missing effect ID") }
            let key = "\(layerID)/effect/\(effectID)"
            var parsed = try SceneShaderEffect.build(effect, id: key, json: json, source: source, texture: texture)
            shaderSourceBytes += parsed.passes.reduce(0) { $0 + $1.vertex.utf8.count + $1.fragment.utf8.count }
            shaderPassCount += parsed.passes.count
            guard shaderSourceBytes <= 4 * 1024 * 1024, shaderPassCount <= 32 else { throw SceneShaderEffect.Failure.unsupported("scene shader budget") }
            func scripts(_ raw: Any?, property: String) -> [[String: Any]] {
                guard let value = raw as? [String: Any], let script = value["script"] as? String else { return [] }
                let user = configuration["userProperties"] as? [String: Any] ?? [:]
                let properties = (value["scriptproperties"] as? [String: Any] ?? [:]).mapValues { value in
                    if let binding = value as? [String: Any], let name = binding["user"] as? String, let value = user[name] { return value }
                    return unwrap(value) ?? value
                }
                return [["property": property, "source": script, "properties": properties]]
            }
            effectObjects.append(["id": key, "layerID": layerID, "values": ["visible": parsed.visible], "scripts": scripts(effect["visible"], property: "visible")])
            for index in parsed.passes.indices {
                for (name, value) in parsed.passes[index].constants {
                    let bindings = scripts(value, property: "value")
                    guard !bindings.isEmpty else { continue }
                    guard let initial = unwrap(value) as? Double, initial.isFinite else {
                        throw SceneShaderEffect.Failure.unsupported("non-scalar animated shader uniform")
                    }
                    let uniformKey = key + (parsed.passes.count == 1 ? "/" : "/pass/\(index)/") + name
                    parsed.passes[index].uniformKeys[name] = uniformKey
                    var object: [String: Any] = ["id": uniformKey, "layerID": layerID, "values": ["value": initial], "scripts": bindings]
                    object["animation"] = (value as? [String: Any])?["animation"]
                    effectObjects.append(object)
                }
            }
            return parsed
        }
        for (index, object) in objects.enumerated() {
            guard let id = object["id"] as? Int, let model = models[id] else { return nil }
            if let text = model.text {
                runtimeLayers[index]["maxwidth"] = max(1, min(8192, number(object["maxwidth"], model.size.width)))
                if let path = text.fontPath, fonts[path] == nil, let data = package.data(forPath: path), data.count <= 512 * 1024 {
                    fontBytes += data.count
                    guard fontBytes <= 512 * 1024 else { return nil }
                    fonts[path] = data.base64EncodedString()
                }
                var style: [String: Any] = ["fontSize": text.pointSize, "padding": 0]
                if let path = text.fontPath { style["fontPath"] = path }
                if bool(object["limitwidth"]), let maximum = object["maxwidth"] as? Double {
                    style["maximumWidth"] = max(1, min(8192, maximum))
                }
                runtimeLayers[index]["textMetrics"] = style
            }
            // Resolve user-bound script defaults using project.json as the source.
            let user = configuration["userProperties"] as? [String: Any] ?? [:]
            var bindings = runtimeLayers[index]["scripts"] as? [[String: Any]] ?? []
            for i in bindings.indices {
                guard let property = bindings[i]["property"] as? String,
                      let raw = object[property] as? [String: Any], let defaults = raw["scriptproperties"] as? [String: Any] else { continue }
                bindings[i]["properties"] = defaults.mapValues { value in
                    if let binding = value as? [String: Any], let key = binding["user"] as? String, let v = user[key] { return v }
                    return unwrap(value) ?? value
                }
            }
            runtimeLayers[index]["scripts"] = bindings
            if object["image"] as? String == "models/util/composelayer.json" {
                guard compositions.count < 4, object["parent"] == nil, model.angles.x == 0, model.angles.y == 0 else { return nil }
                var effects: [SceneShaderEffect] = []
                for effect in object["effects"] as? [[String: Any]] ?? [] {
                    // Disabled passes have no GPU work, but remain available to scripts.
                    effects.append(try shaderEffect(effect, layerID: id))
                }
                guard !effects.isEmpty, effects.count <= 8 else { return nil }
                compositions.append(Composition(model: model, alignment: object["alignment"] as? String ?? "center", effects: effects))
                continue
            }
            if let path = object["particle"] as? String, let settings = json(path), hasAudio(settings) {
                guard particles.count < 8 else { return nil }
                guard SceneAudioParticles.supports(settings) else { return nil }
                // This path implements only the audited 2D firefly operator set.
                let names = Set((settings["operator"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })
                guard names.isSubset(of: ["movement", "alphafade", "oscillatealpha", "turbulence", "controlpointattract", "oscillateposition", "oscillatesize"]),
                      names.contains("turbulence"), object["parent"] == nil else { return nil }
                guard let materialPath = settings["material"] as? String, let material = json(materialPath),
                      let spriteName = firstTexture(material), let sprite = try texture(spriteName) else { return nil }
                let children = settings["children"] as? [[String: Any]] ?? []
                guard children.count <= 1 else { return nil }
                var trail: [String: Any]?, trailSprite: CGImage?
                if let child = children.first {
                    guard child["type"] as? String == "eventfollow", let path = child["name"] as? String,
                          let settings = json(path), SceneAudioParticles.supports(settings, trail: true), let path = settings["material"] as? String,
                          let material = json(path), let name = firstTexture(material), let image = try texture(name) else { return nil }
                    trail = settings; trailSprite = image
                }
                particles.append(Particle(model: model, settings: settings, overrides: object["instanceoverride"] as? [String: Any] ?? [:],
                                          sprite: animations[spriteName]?.images.first ?? sprite, trail: trail, trailSprite: trailSprite))
                continue
            }
            let dynamicText = model.text != nil && !model.scripts.isEmpty
            let scriptedImage = !model.scripts.isEmpty && object["image"] as? String != "models/util/composelayer.json"
            guard hasMedia(object) || dynamicText || scriptedImage else { continue }
            guard layers.count < 24, object["parent"] == nil, model.angles.x == 0, model.angles.y == 0 else { return nil }
            var image: CGImage?
            var animation: SceneWallpaperView.SceneTextureFrameContents?
            var thumbnail = false
            var masks: [CGImage] = []
            var shaderEffects: [SceneShaderEffect] = []
            if model.text == nil {
                guard let path = object["image"] as? String else { return nil }
                if path == "models/util/solidlayer.json" {
                    image = nil
                } else {
                    guard let modelJSON = json(path), let materialPath = modelJSON["material"] as? String,
                          let material = json(materialPath) else { return nil }
                    thumbnail = containsString(material, "$mediaThumbnail")
                    if !thumbnail {
                        guard let name = firstTexture(material), let decoded = try texture(name) else { return nil }
                        image = decoded
                        animation = animations[name]
                    }
                }
                for effect in object["effects"] as? [[String: Any]] ?? [] {
                    if hasMedia(effect) {
                        shaderEffects.append(try shaderEffect(effect, layerID: id))
                        continue
                    }
                    guard (effect["file"] as? String)?.contains("opacity/") == true else {
                        if bool(effect["visible"], true) || (effect["visible"] as? [String: Any])?["script"] != nil {
                            shaderEffects.append(try shaderEffect(effect, layerID: id))
                        }
                        continue
                    }
                    guard bool(effect["visible"], true) else { continue }
                    for pass in effect["passes"] as? [[String: Any]] ?? [] {
                        if let names = pass["textures"] as? [Any], names.count > 1,
                           let name = names[1] as? String, let mask = try texture(name) { masks.append(mask) }
                    }
                }
            }
            layers.append(Layer(model: model, alignment: object["alignment"] as? String ?? "center",
                                image: image, animation: animation, thumbnail: thumbnail, masks: masks, shaderEffects: shaderEffects))
        }
        configuration["fonts"] = fonts
        // One cached background can represent only a prefix of the draw order.
        // Any visible static content above a live layer must also become live,
        // otherwise it would be sampled on the wrong side of a compose effect.
        let liveIDs = Set(layers.map(\.model.id) + particles.map(\.model.id) + compositions.map(\.model.id))
        var reachedLive = false
        for object in objects {
            guard let id = object["id"] as? Int else { return nil }
            if liveIDs.contains(id) { reachedLive = true; continue }
            if reachedLive, bool(object["visible"], true), number(object["alpha"], 1) > 0,
               object["image"] as? String != "models/util/projectlayer.json" { return nil }
        }
        configuration["layers"] = runtimeLayers
        guard effectObjects.count <= 128 else { return nil }
        configuration["objects"] = effectObjects
        let metrics = SceneTextMetrics()
        metrics.configure(configuration)
        // Exported scene bounds include the creator's font rasterization scale.
        // Calibrate the same packed font against that initial string; use the
        // calibrated font for both rendering and subsequent script measurements.
        for index in runtimeLayers.indices {
            guard let id = runtimeLayers[index]["id"] as? Int, let model = models[id], let text = model.text,
                  var style = runtimeLayers[index]["textMetrics"] as? [String: Any],
                  let measured = metrics.measure(id: id, text: text.value), !text.value.isEmpty else { continue }
            let padding = (style["padding"] as? Double ?? 0) * 2
            let ratio = model.size.width / max(1, measured[0] - padding)
            style["fontSize"] = text.pointSize * min(8, max(0.5, ratio))
            runtimeLayers[index]["textMetrics"] = style
        }
        configuration["layers"] = runtimeLayers
        metrics.configure(configuration)
        guard let bytes = try? JSONSerialization.data(withJSONObject: configuration), bytes.count < 900_000 else { return nil }
        return Self(canvas: CGSize(width: layout.canvasSize.width, height: layout.canvasSize.height),
                    layers: layers, particles: particles, compositions: compositions, order: objects.compactMap { $0["id"] as? Int }, configuration: configuration, metrics: metrics)
    }

    nonisolated static func unwrap(_ value: Any?) -> Any? { (value as? [String: Any])?["value"] ?? value }
    nonisolated static func number(_ value: Any?, _ fallback: Double) -> Double {
        guard let n = unwrap(value) as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return fallback }
        return n.doubleValue
    }
    static func bool(_ value: Any?, _ fallback: Bool = false) -> Bool { unwrap(value) as? Bool ?? fallback }
    static func hasMedia(_ value: Any) -> Bool { hasMedia(value, depth: 0) }
    private static func hasMedia(_ value: Any, depth: Int) -> Bool {
        guard depth < 64 else { return false }
        if let d = value as? [String: Any] {
            if let source = d["script"] as? String, ["mediaPropertiesChanged", "mediaPlaybackChanged", "mediaTimelineChanged", "mediaThumbnailChanged"].contains(where: source.contains) { return true }
            return d.values.contains { hasMedia($0, depth: depth + 1) }
        }
        return (value as? [Any])?.contains { hasMedia($0, depth: depth + 1) } ?? false
    }
    static func hasAudio(_ value: Any) -> Bool { hasAudio(value, depth: 0) }
    private static func hasAudio(_ value: Any, depth: Int) -> Bool {
        guard depth < 64 else { return false }
        if let d = value as? [String: Any] {
            if number(d["audioprocessingmode"], 0) > 0 { return true }
            return d.values.contains { hasAudio($0, depth: depth + 1) }
        }
        return (value as? [Any])?.contains { hasAudio($0, depth: depth + 1) } ?? false
    }
    private static func containsString(_ value: Any, _ match: String, depth: Int = 0) -> Bool {
        guard depth < 64 else { return false }
        if let s = value as? String { return s == match }
        if let d = value as? [String: Any] { return d.values.contains { containsString($0, match, depth: depth + 1) } }
        return (value as? [Any])?.contains { containsString($0, match, depth: depth + 1) } ?? false
    }
    private static func firstTexture(_ material: [String: Any]) -> String? {
        if let textures = material["textures"] as? [Any], let first = textures.first as? String { return first }
        for pass in material["passes"] as? [[String: Any]] ?? [] {
            if let found = firstTexture(pass) { return found }
        }
        return nil
    }
}
