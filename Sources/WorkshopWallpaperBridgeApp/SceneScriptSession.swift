import AppKit
import WorkshopWallpaperCore

@MainActor
final class SceneScriptSession {
    private let process = SceneScriptProcess()
    private var configuration: [String: Any]?
    private var inFlight = false
    private var closed = false
    private var generation = 0
    private var suspended = false
    private var previousTime: TimeInterval = 0
    private var previousSize: [Double]?
    private var pendingResponse: Data?
    var onChanges: (([[String: Any]]) -> Void)?
    var onObjectChanges: (([[String: Any]]) -> Void)?
    var onDiagnostic: ((String) -> Void)?

    init(plan: SceneRenderPlan, projectURL: URL) {
        configuration = Self.configuration(plan: plan, projectURL: projectURL)
    }

    init(configuration: [String: Any]) { self.configuration = configuration }

    static func configuration(plan: SceneRenderPlan, projectURL: URL) -> [String: Any] {
        func vector(_ v: SceneVector3) -> [Double] { [v.x, v.y, v.z] }
        func property(_ v: SceneScriptPropertyValue) -> Any {
            switch v { case .bool(let b): b; case .number(let n): n; case .string(let s): s }
        }
        let layers: [[String: Any]] = plan.runtimeLayers.prefix(256).map { layer in
            var scripts = layer.scripts
            if scripts[.text] == nil { scripts[.text] = layer.text?.script }
            let bindings: [[String: Any]] = scripts.sorted { $0.key.rawValue < $1.key.rawValue }.map { key, script in
                ["property": key.rawValue, "source": script.source, "properties": script.properties.mapValues(property)]
            }
            let color = layer.text?.color ?? layer.color
            return ["id": layer.id, "name": layer.name, "size": [layer.size.width, layer.size.height],
                    "values": ["origin": vector(layer.origin), "scale": vector(layer.scale), "angles": vector(layer.angles),
                               "alpha": layer.alpha, "visible": layer.visible, "text": layer.text?.value ?? "",
                               "color": [color.red, color.green, color.blue]], "scripts": bindings]
        }
        return ["canvasSize": [plan.canvasSize.width, plan.canvasSize.height], "layers": layers,
                "userProperties": projectProperties(at: projectURL), "language": Locale.current.language.languageCode?.identifier ?? "en"]
    }

    /// Read defaults only from the selected project's own bounded, non-symlink file.
    static func projectProperties(at root: URL) -> [String: Any] {
        let directory = root.standardizedFileURL.resolvingSymlinksInPath()
        let url = directory.appending(path: "project.json")
        guard url.resolvingSymlinksInPath().deletingLastPathComponent() == directory,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
              let data = try? Data(contentsOf: url),
              let project = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let general = project["general"] as? [String: Any],
              let properties = general["properties"] as? [String: [String: Any]] else { return [:] }
        return properties.compactMapValues { $0["value"] }
    }

    @discardableResult
    func advance(frame: [String: Any]) -> Bool {
        guard !closed, !suspended, !inFlight else { return false }
        inFlight = true
        let token = generation
        let isFirst = configuration != nil
        let time = frame["time"] as? Double ?? 0
        let size = frame["screen"] as? [Double] ?? []
        var frame = frame
        frame["frameTime"] = max(0, time - previousTime)
        var request: [String: Any] = ["frame": frame, "resized": previousSize != nil && previousSize != size]
        if let configuration { request["configure"] = configuration }
        guard JSONSerialization.isValidJSONObject(request),
              let data = try? JSONSerialization.data(withJSONObject: request) else {
            inFlight = false
            fail("Invalid scene input.")
            return false
        }
        configuration = nil
        previousTime = time
        previousSize = size
        Task { [weak self, process] in
            do {
                let response = try await process.exchange(data, timeout: isFirst ? 2 : 0.25)
                guard let self, !self.closed, self.generation == token else { return }
                self.inFlight = false
                if self.suspended { self.pendingResponse = response }
                else { self.deliver(response) }
            } catch {
                guard let self, !self.closed, self.generation == token else { return }
                self.inFlight = false
                self.fail(error.localizedDescription)
            }
        }
        return true
    }

    private func deliver(_ data: Data) {
        guard let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let layers = result["layers"] as? [[String: Any]], layers.count <= 256 else {
            fail("Invalid SceneScript output."); return
        }
        onChanges?(layers)
        if let objects = result["objects"] as? [[String: Any]], objects.count <= 128 { onObjectChanges?(objects) }
        if let errors = result["errors"] as? [[String: Any]], let first = errors.first {
            onDiagnostic?("SceneScript · \(first["layer"] ?? "?") / \(first["property"] ?? "?"): \(first["message"] ?? "Error")")
        }
    }

    func setSuspended(_ value: Bool) {
        suspended = value
        if !value, let pendingResponse {
            self.pendingResponse = nil
            deliver(pendingResponse)
        }
    }

    private func fail(_ message: String) {
        onDiagnostic?(message)
        close()
    }

    func close() {
        closed = true
        generation += 1
        pendingResponse = nil
        process.close()
    }
}
