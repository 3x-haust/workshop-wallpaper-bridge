import AppKit

/// Shader source is read from the user's package/assets at runtime. No creator
/// shaders are bundled. Named intermediate buffers preserve multipass effects.
struct SceneShaderEffect {
    struct Uniform {
        let name: String
        let type: String
        let material: String
        let value: Any?
        let combo: String?
    }
    struct Pass {
        let vertex: String
        let fragment: String
        var target: String? = nil
        var bindings: [Int: String] = [:]
        var constants: [String: Any] = [:]
        var combos: [String: Int] = [:]
        var textures: [Int: CGImage] = [:]
        var systemTextures: [Int: String] = [:]
        var uniformKeys: [String: String] = [:]
        var uniforms: [Uniform] { Self.metadata(vertex + "\n" + fragment) }

        static func metadata(_ source: String) -> [Uniform] {
            let expression = try! NSRegularExpression(pattern: #"(?m)^\s*uniform\s+(\w+)\s+(\w+)\s*;[^\n]*?//\s*(\{[^\n]+\})"#)
            return expression.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap { match in
                func part(_ n: Int) -> String { String(source[Range(match.range(at: n), in: source)!]) }
                guard let data = part(3).data(using: .utf8), let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                return Uniform(name: part(2), type: part(1), material: info["material"] as? String ?? part(2), value: info["default"], combo: info["combo"] as? String)
            }
        }
        var resolvedCombos: [String: Int] {
            var output: [String: Int] = [:]
            for line in (vertex + "\n" + fragment).components(separatedBy: .newlines) where line.contains("[COMBO]") {
                guard let start = line.firstIndex(of: "{"), let data = String(line[start...]).data(using: .utf8),
                      let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let name = info["combo"] as? String, Self.identifier(name) else { continue }
                output[name] = info["default"] as? Int ?? 0
            }
            for uniform in uniforms {
                if let combo = uniform.combo, Self.identifier(combo) {
                    let slot = Int(uniform.name.replacingOccurrences(of: "g_Texture", with: ""))
                    output[combo] = slot.map { textures[$0] != nil || systemTextures[$0] != nil || bindings[$0] != nil } == true ? 1 : 0
                }
            }
            output.merge(combos.filter { Self.identifier($0.key) }) { _, new in new }
            return output
        }
        static func identifier(_ value: String) -> Bool { value.range(of: #"^[A-Za-z_][A-Za-z0-9_]{0,63}$"#, options: .regularExpression) != nil }
    }
    let id: String
    var passes: [Pass]
    var visible = true

    enum Failure: Error, LocalizedError {
        case unsupported(String)
        var errorDescription: String? { switch self { case .unsupported(let message): return "Scene shader: " + message } }
    }

    @MainActor static func build(_ effect: [String: Any], id: String,
                      json: (String) -> [String: Any]?, source: (String) -> String?,
                      texture: (String) throws -> CGImage?) throws -> Self {
        guard let file = effect["file"] as? String, let definition = json(file),
              let definitions = definition["passes"] as? [[String: Any]], !definitions.isEmpty, definitions.count <= 8 else {
            throw Failure.unsupported("invalid effect passes")
        }
        let overrides = effect["passes"] as? [[String: Any]] ?? []
        let buffers = definition["fbos"] as? [[String: Any]] ?? []
        guard buffers.count <= 4, buffers.allSatisfy({ SceneMediaOverlayPlan.number($0["scale"], 1) == 1 }) else {
            throw Failure.unsupported("unsupported intermediate buffer scale")
        }
        var bytes = 0
        func expanded(_ text: String, depth: Int = 0, stack: Set<String> = []) throws -> String {
            guard depth <= 8 else { throw Failure.unsupported("include depth limit") }
            var output = ""
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#include") {
                    let parts = trimmed.components(separatedBy: "\"")
                    guard parts.count == 3, !stack.contains(parts[1]),
                          let included = source("shaders/" + parts[1]) else { throw Failure.unsupported("missing or cyclic shader include") }
                    output += try expanded(included, depth: depth + 1, stack: stack.union([parts[1]]))
                } else { output += line + "\n"; bytes += line.utf8.count + 1 }
                guard bytes <= 2 * 1024 * 1024 else { throw Failure.unsupported("shader source limit") }
            }
            return output
        }
        var passes: [Pass] = []
        for (index, descriptor) in definitions.enumerated() {
            guard let path = descriptor["material"] as? String, let material = json(path),
                  let materialPasses = material["passes"] as? [[String: Any]], materialPasses.count == 1,
                  let materialPass = materialPasses.first, let shader = materialPass["shader"] as? String,
                  let vertex = source("shaders/" + shader + ".vert"), let fragment = source("shaders/" + shader + ".frag") else {
                throw Failure.unsupported("missing shader/material")
            }
            let override = index < overrides.count ? overrides[index] : [:]
            var pass = Pass(vertex: try expanded(vertex), fragment: try expanded(fragment), target: descriptor["target"] as? String)
            pass.constants = materialPass["constantshadervalues"] as? [String: Any] ?? [:]
            pass.constants.merge(override["constantshadervalues"] as? [String: Any] ?? [:]) { _, new in new }
            pass.combos = materialPass["combos"] as? [String: Int] ?? [:]
            pass.combos.merge(override["combos"] as? [String: Int] ?? [:]) { _, new in new }
            for binding in descriptor["bind"] as? [[String: Any]] ?? [] {
                guard let slot = binding["index"] as? Int, (0..<8).contains(slot), let name = binding["name"] as? String else {
                    throw Failure.unsupported("invalid sampler binding")
                }
                pass.bindings[slot] = name
            }
            let baseTextures = materialPass["textures"] as? [Any] ?? []
            let overrideTextures = override["textures"] as? [Any] ?? []
            let systemTextures = override["usertextures"] as? [Any] ?? []
            for slot in 1..<8 where pass.bindings[slot] == nil {
                if slot < systemTextures.count, let descriptor = systemTextures[slot] as? [String: Any],
                   descriptor["type"] as? String == "system", let name = descriptor["name"] as? String {
                    guard ["$mediaThumbnail", "$mediaPreviousThumbnail"].contains(name) else { throw Failure.unsupported("unsupported system texture") }
                    pass.systemTextures[slot] = name
                }
                let uniform = pass.uniforms.first { $0.name == "g_Texture\(slot)" }
                let name = (slot < overrideTextures.count ? overrideTextures[slot] as? String : nil)
                    ?? (slot < baseTextures.count ? baseTextures[slot] as? String : nil) ?? (uniform?.value as? String)
                if let name, !name.isEmpty {
                    guard let image = try texture(name) else { throw Failure.unsupported("missing effect texture") }
                    pass.textures[slot] = image
                }
            }
            passes.append(pass)
        }
        return Self(id: id, passes: passes, visible: SceneMediaOverlayPlan.bool(effect["visible"], true))
    }
}
