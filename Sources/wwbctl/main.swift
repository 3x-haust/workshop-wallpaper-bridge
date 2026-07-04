import Foundation
import WorkshopWallpaperCore

@main
struct WWBCtl {
    static func main() {
        do {
            try run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            Foundation.exit(1)
        }
    }

    static func run(arguments: [String]) throws {
        guard let command = arguments.first else {
            printHelp()
            return
        }
        switch command {
        case "scan":
            try scan(arguments: Array(arguments.dropFirst()))
        case "import":
            try importAssets(arguments: Array(arguments.dropFirst()))
        case "import-video":
            try importVideo(arguments: Array(arguments.dropFirst()))
        case "attach-scene-video":
            try attachSceneVideo(arguments: Array(arguments.dropFirst()))
        case "remove":
            try remove(arguments: Array(arguments.dropFirst()))
        case "convert":
            try convert(arguments: Array(arguments.dropFirst()))
        case "scene-info":
            try sceneInfo(arguments: Array(arguments.dropFirst()))
        case "scene-render-info":
            try sceneRenderInfo(arguments: Array(arguments.dropFirst()))
        case "scene-engine-info":
            try sceneEngineInfo(arguments: Array(arguments.dropFirst()))
        case "scene-parity-check":
            try sceneParityCheck(arguments: Array(arguments.dropFirst()))
        case "doctor":
            try doctor()
        case "help", "--help", "-h":
            printHelp()
        default:
            throw CLIError.unknownCommand(command)
        }
    }

    private static func scan(arguments: [String]) throws {
        guard let path = arguments.first else {
            throw CLIError.missingPath
        }
        let result = try WallpaperScanner().scan(root: URL(filePath: path))
        let data = try JSONEncoder.cli.encode(result)
        if let out = optionValue("--out", in: arguments) {
            try data.write(to: URL(filePath: out), options: [.atomic])
        } else {
            FileHandle.standardOutput.write(data)
            print("")
        }
    }

    private static func importAssets(arguments: [String]) throws {
        guard let path = arguments.first else {
            throw CLIError.missingPath
        }
        let store = try store(from: arguments)
        let result = try WallpaperScanner().scan(root: URL(filePath: path))
        let imported = try result.assets.map { try store.importAsset($0) }
        print("imported \(imported.count) asset(s) into \(store.root.path)")
    }

    private static func importVideo(arguments: [String]) throws {
        guard let path = arguments.first else {
            throw CLIError.missingPath
        }
        let store = try store(from: arguments)
        let imported = try store.importVideoFile(URL(filePath: path))
        print("imported \(imported.title) into \(store.root.path)")
    }

    private static func attachSceneVideo(arguments: [String]) throws {
        guard arguments.count >= 2 else {
            throw CLIError.invalidAttachSceneVideoUsage
        }
        let store = try store(from: arguments)
        let updated = try store.installSceneRenderCache(
            assetID: arguments[0],
            videoURL: URL(filePath: arguments[1])
        )
        let projectDirectory = URL(filePath: updated.projectDirectory)
        let cache = SceneRenderCache.existingVideoURL(in: projectDirectory)?.path ?? projectDirectory.path
        print("attached scene reference cache for \(updated.title) at \(cache); desktop scene playback uses the external scene renderer when available, then native fallback")
    }

    private static func remove(arguments: [String]) throws {
        guard let id = arguments.first else {
            throw CLIError.missingAssetId
        }
        let store = try store(from: arguments)
        try store.removeAsset(id: id)
        print("removed \(id) from \(store.root.path)")
    }

    private static func convert(arguments: [String]) throws {
        guard arguments.count >= 3, arguments[1] == "--out" else {
            throw CLIError.invalidConvertUsage
        }
        try VideoConverter().convertToPlayableVideo(
            input: URL(filePath: arguments[0]),
            output: URL(filePath: arguments[2])
        )
        print("converted \(arguments[2])")
    }

    private static func sceneInfo(arguments: [String]) throws {
        guard let path = arguments.first else {
            throw CLIError.missingPath
        }
        let analysis = try ScenePackageAnalyzer().analyze(url: URL(filePath: path))
        let data = try JSONEncoder.cli.encode(analysis)
        FileHandle.standardOutput.write(data)
        print("")
    }

    private static func sceneRenderInfo(arguments: [String]) throws {
        guard let path = arguments.first else {
            throw CLIError.missingPath
        }
        let plan = try SceneRenderPlanBuilder().build(url: URL(filePath: path))
        let info = SceneRenderInfo(
            canvasWidth: plan.canvasSize.width,
            canvasHeight: plan.canvasSize.height,
            layerCount: plan.layers.count,
            textureCount: plan.textures.count,
            animatedTextureCount: plan.textures.values.filter { $0.animation != nil }.count,
            particleLayerCount: plan.particleLayers.count,
            textLayerCount: plan.layers.filter { $0.text != nil }.count,
            dynamicTextLayerCount: plan.layers.filter { $0.text?.dynamicText != nil }.count,
            effectLayerCount: plan.layers.filter { !$0.effects.isEmpty }.count,
            effectOnlyLayerCount: plan.layers.filter(\.isEffectOnly).count,
            animatedLayerCount: plan.layers.filter(\.hasAnimation).count,
            originAnimationCount: plan.layers.filter { $0.originAnimation != nil }.count,
            scaleAnimationCount: plan.layers.filter { $0.scaleAnimation != nil }.count,
            angleAnimationCount: plan.layers.filter { $0.angleAnimation != nil }.count,
            alphaAnimationCount: plan.layers.filter { $0.alphaAnimation != nil }.count,
            texturePaths: plan.layers.map(\.texturePath).filter { !$0.isEmpty },
            textValues: plan.layers.compactMap { $0.text?.value },
            effects: plan.layers.flatMap(\.effects).map(\.rawValue),
            layers: plan.layers.map(SceneRenderLayerInfo.init(layer:)),
            effectSettings: plan.layers.flatMap(\.effectSettings).map {
                SceneRenderEffectInfo(
                    effect: $0.effect.rawValue,
                    speed: $0.speed,
                    speedX: $0.speedX,
                    speedY: $0.speedY,
                    strength: $0.strength,
                    scale: $0.scale,
                    perspective: $0.perspective,
                    direction: $0.direction.map(SceneRenderVectorInfo.init),
                    usesMask: $0.usesMask,
                    maskReference: $0.maskReference.map(SceneRenderMaskReferenceInfo.init)
                )
            }
        )
        let data = try JSONEncoder.cli.encode(info)
        FileHandle.standardOutput.write(data)
        print("")
    }

    private static func sceneEngineInfo(arguments: [String]) throws {
        guard let path = arguments.first else {
            throw CLIError.missingPath
        }
        let features = try SceneRuntimeFeatureAnalyzer().analyze(url: URL(filePath: path))
        let data = try JSONEncoder.cli.encode(features)
        FileHandle.standardOutput.write(data)
        print("")
    }

    private static func sceneParityCheck(arguments: [String]) throws {
        guard arguments.count >= 2 else {
            throw CLIError.invalidSceneParityCheckUsage
        }
        let packageURL = URL(filePath: arguments[0])
        let goldenDirectory = URL(filePath: arguments[1])
        guard try goldenDirectory.isExistingDirectory else {
            throw CLIError.invalidGoldenDirectory(goldenDirectory.path)
        }

        let plan = try SceneRenderPlanBuilder().build(url: packageURL)
        let features = try SceneRuntimeFeatureAnalyzer().analyze(url: packageURL)
        let goldenFrames = try goldenFrameNames(in: goldenDirectory)
        let report = SceneParityCheckInfo(
            packagePath: packageURL.path,
            goldenDirectory: goldenDirectory.path,
            goldenFrameCount: goldenFrames.count,
            goldenFrames: goldenFrames,
            renderInfo: SceneParityRenderInfo(
                canvasWidth: plan.canvasSize.width,
                canvasHeight: plan.canvasSize.height,
                layerCount: plan.layers.count,
                textureCount: plan.textures.count,
                effectLayerCount: plan.layers.filter { !$0.effects.isEmpty }.count,
                particleLayerCount: plan.particleLayers.count,
                textLayerCount: plan.layers.filter { $0.text != nil }.count
            ),
            runtimeFeatures: features,
            status: "golden frames indexed; renderer capture comparison is not implemented yet"
        )
        let data = try JSONEncoder.cli.encode(report)
        FileHandle.standardOutput.write(data)
        print("")
    }

    private struct SceneRenderInfo: Codable {
        let canvasWidth: Double
        let canvasHeight: Double
        let layerCount: Int
        let textureCount: Int
        let animatedTextureCount: Int
        let particleLayerCount: Int
        let textLayerCount: Int
        let dynamicTextLayerCount: Int
        let effectLayerCount: Int
        let effectOnlyLayerCount: Int
        let animatedLayerCount: Int
        let originAnimationCount: Int
        let scaleAnimationCount: Int
        let angleAnimationCount: Int
        let alphaAnimationCount: Int
        let texturePaths: [String]
        let textValues: [String]
        let effects: [String]
        let layers: [SceneRenderLayerInfo]
        let effectSettings: [SceneRenderEffectInfo]
    }

    private struct SceneRenderLayerInfo: Codable {
        let id: Int
        let name: String
        let texturePath: String
        let isText: Bool
        let isEffectOnly: Bool
        let origin: SceneRenderVectorInfo
        let size: SceneRenderSizeInfo
        let scale: SceneRenderVectorInfo
        let angles: SceneRenderVectorInfo
        let alpha: Double
        let originAnimation: SceneRenderVectorAnimationInfo?
        let scaleAnimation: SceneRenderVectorAnimationInfo?
        let angleAnimation: SceneRenderVectorAnimationInfo?
        let alphaAnimation: SceneRenderScalarAnimationInfo?
        let effectSettings: [SceneRenderEffectInfo]

        init(layer: SceneLayer) {
            id = layer.id
            name = layer.name
            texturePath = layer.texturePath
            isText = layer.text != nil
            isEffectOnly = layer.isEffectOnly
            origin = SceneRenderVectorInfo(layer.origin)
            size = SceneRenderSizeInfo(layer.size)
            scale = SceneRenderVectorInfo(layer.scale)
            angles = SceneRenderVectorInfo(layer.angles)
            alpha = layer.alpha
            originAnimation = layer.originAnimation.map(SceneRenderVectorAnimationInfo.init(animation:))
            scaleAnimation = layer.scaleAnimation.map(SceneRenderVectorAnimationInfo.init(animation:))
            angleAnimation = layer.angleAnimation.map(SceneRenderVectorAnimationInfo.init(animation:))
            alphaAnimation = layer.alphaAnimation.map(SceneRenderScalarAnimationInfo.init(animation:))
            effectSettings = layer.effectSettings.map {
                SceneRenderEffectInfo(
                    effect: $0.effect.rawValue,
                    speed: $0.speed,
                    speedX: $0.speedX,
                    speedY: $0.speedY,
                    strength: $0.strength,
                    scale: $0.scale,
                    perspective: $0.perspective,
                    direction: $0.direction.map(SceneRenderVectorInfo.init),
                    usesMask: $0.usesMask,
                    maskReference: $0.maskReference.map(SceneRenderMaskReferenceInfo.init)
                )
            }
        }
    }

    private struct SceneRenderVectorInfo: Codable {
        let x: Double
        let y: Double
        let z: Double

        init(_ vector: SceneVector3) {
            x = vector.x
            y = vector.y
            z = vector.z
        }
    }

    private struct SceneRenderSizeInfo: Codable {
        let width: Double
        let height: Double

        init(_ size: SceneSize) {
            width = size.width
            height = size.height
        }
    }

    private struct SceneRenderVectorAnimationInfo: Codable {
        let duration: Double
        let isRelative: Bool
        let keyframes: [SceneRenderVectorKeyframeInfo]

        init(animation: SceneVectorAnimation) {
            duration = animation.duration
            isRelative = animation.isRelative
            keyframes = animation.keyframes.map(SceneRenderVectorKeyframeInfo.init(keyframe:))
        }
    }

    private struct SceneRenderVectorKeyframeInfo: Codable {
        let time: Double
        let value: SceneRenderVectorInfo

        init(keyframe: SceneVectorKeyframe) {
            time = keyframe.time
            value = SceneRenderVectorInfo(keyframe.value)
        }
    }

    private struct SceneRenderScalarAnimationInfo: Codable {
        let duration: Double
        let isRelative: Bool
        let keyframes: [SceneRenderScalarKeyframeInfo]

        init(animation: SceneScalarAnimation) {
            duration = animation.duration
            isRelative = animation.isRelative
            keyframes = animation.keyframes.map(SceneRenderScalarKeyframeInfo.init(keyframe:))
        }
    }

    private struct SceneRenderScalarKeyframeInfo: Codable {
        let time: Double
        let value: Double

        init(keyframe: SceneScalarKeyframe) {
            time = keyframe.time
            value = keyframe.value
        }
    }

    private struct SceneRenderEffectInfo: Codable {
        let effect: String
        let speed: Double?
        let speedX: Double?
        let speedY: Double?
        let strength: Double?
        let scale: Double?
        let perspective: Double?
        let direction: SceneRenderVectorInfo?
        let usesMask: Bool
        let maskReference: SceneRenderMaskReferenceInfo?
    }

    private struct SceneRenderMaskReferenceInfo: Codable {
        let source: String
        let texturePath: String?

        init(_ reference: SceneEffectMaskReference) {
            source = reference.source
            texturePath = reference.texturePath
        }
    }

    private struct SceneParityCheckInfo: Codable {
        let packagePath: String
        let goldenDirectory: String
        let goldenFrameCount: Int
        let goldenFrames: [String]
        let renderInfo: SceneParityRenderInfo
        let runtimeFeatures: SceneRuntimeFeatures
        let status: String
    }

    private struct SceneParityRenderInfo: Codable {
        let canvasWidth: Double
        let canvasHeight: Double
        let layerCount: Int
        let textureCount: Int
        let effectLayerCount: Int
        let particleLayerCount: Int
        let textLayerCount: Int
    }

    private static func goldenFrameNames(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                && url.pathExtension.lowercased() == "png"
        }
        .map(\.lastPathComponent)
        .sorted()
    }

    private static func doctor() throws {
        let store = try LibraryStore.defaultStore()
        let ffmpeg = VideoConverter().ffmpegPath() ?? "not found"
        print("library: \(store.root.path)")
        print("ffmpeg: \(ffmpeg)")
        print(sceneRendererDiagnosticLine())
        print(sceneRendererAssetsDiagnosticLine())
        print("platform: \(ProcessInfo.processInfo.operatingSystemVersionString)")
    }

    private static func sceneRendererDiagnosticLine() -> String {
        let envVar = "WWB_SCENE_ENGINE_RENDERER"
        let bundledPath = "Contents/Resources/Renderers/wwb-scene-renderer"
        let sourceURL = "https://github.com/Almamu/linux-wallpaperengine"
        let sourceRef = "b016d7d1fdcf4e5fd2f9c9fa420a8aaa07fee02d"
        let environment = ProcessInfo.processInfo.environment

        if let envPath = environment[envVar], !envPath.isEmpty {
            let rendererURL = URL(filePath: envPath).standardizedFileURL
            if isRegularExecutable(rendererURL) {
                return "Scene renderer: env=\(envVar) path=\(rendererURL.path) bundled=\(bundledPath) "
                    + "source_url=\(sourceURL) source_ref=\(sourceRef) availability=available fallback=external"
            }
            return "Scene renderer: env=\(envVar) path=\(rendererURL.path) bundled=\(bundledPath) "
                + "source_url=\(sourceURL) source_ref=\(sourceRef) availability=unavailable "
                + "fallback=native reason=env-path-not-executable"
        }

        let bundledURL = Bundle.main.bundleURL.appending(path: bundledPath).standardizedFileURL
        if isRegularExecutable(bundledURL) {
            return "Scene renderer: env=\(envVar) path=\(bundledURL.path) bundled=\(bundledPath) "
                + "source_url=\(sourceURL) source_ref=\(sourceRef) availability=available fallback=external"
        }
        return "Scene renderer: env=\(envVar) bundled=\(bundledPath) source_url=\(sourceURL) "
            + "source_ref=\(sourceRef) availability=unavailable fallback=native reason=renderer-not-found"
    }

    private static func sceneRendererAssetsDiagnosticLine() -> String {
        let envVar = "WWB_SCENE_ENGINE_ASSETS_DIR"
        let defaultURL = defaultSceneRendererAssetsDirectoryURL()
        let defaultPath = defaultURL?.path ?? "unavailable"
        let environment = ProcessInfo.processInfo.environment

        if let envPath = environment[envVar], !envPath.isEmpty {
            let assetsURL = URL(filePath: envPath).standardizedFileURL
            return sceneRendererAssetsDiagnosticLine(
                envVar: envVar,
                path: assetsURL.path,
                defaultPath: defaultPath,
                missing: missingSceneRendererAssetPaths(in: assetsURL)
            )
        }

        guard let defaultURL else {
            return "Scene renderer assets: env=\(envVar) default=unavailable availability=unavailable "
                + "fallback=native reason=default-assets-dir-unavailable"
        }
        return sceneRendererAssetsDiagnosticLine(
            envVar: envVar,
            path: defaultURL.path,
            defaultPath: defaultPath,
            missing: missingSceneRendererAssetPaths(in: defaultURL)
        )
    }

    private static func sceneRendererAssetsDiagnosticLine(
        envVar: String,
        path: String,
        defaultPath: String,
        missing: [String]
    ) -> String {
        let exists = FileManager.default.fileExists(atPath: path) ? "present" : "missing"
        let base = "Scene renderer assets: env=\(envVar) path=\(path) default=\(defaultPath) exists=\(exists)"
        if missing.isEmpty {
            return "\(base) sentinel=present availability=available fallback=external"
        }
        return "\(base) sentinel=missing availability=unavailable fallback=native missing=\(missing.joined(separator: ",")) "
            + "guidance=\"Copy steamapps/common/wallpaper_engine/assets from your Windows Wallpaper Engine install to this path for your local personal use; the app never downloads or redistributes these files.\""
    }

    private static let requiredSceneRendererAssetPaths = [
        "materials/util/composelayer.json",
        "shaders/"
    ]

    private static func defaultSceneRendererAssetsDirectoryURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "WorkshopWallpaperBridge")
            .appending(path: "wallpaper-engine-assets")
            .standardizedFileURL
    }

    private static func missingSceneRendererAssetPaths(in directory: URL) -> [String] {
        guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true,
              values.isSymbolicLink != true else {
            return ["<assets-dir>"] + requiredSceneRendererAssetPaths
        }
        if hasRegularFile(directory.appending(path: "materials/util/composelayer.json"))
            || hasDirectory(directory.appending(path: "shaders")) {
            return []
        }
        return requiredSceneRendererAssetPaths
    }

    private static func hasRegularFile(_ url: URL) -> Bool {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func hasDirectory(_ url: URL) -> Bool {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil,
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func isRegularExecutable(_ url: URL) -> Bool {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
            return false
        }
        guard FileManager.default.isExecutableFile(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func store(from arguments: [String]) throws -> LibraryStore {
        if let path = optionValue("--library", in: arguments) {
            return LibraryStore(root: URL(filePath: path))
        }
        return try LibraryStore.defaultStore()
    }

    private static func optionValue(_ option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option) else {
            return nil
        }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else {
            return nil
        }
        return arguments[valueIndex]
    }

    private static func printHelp() {
        print("""
        wwbctl scan <folder> [--out <index.json>]
        wwbctl import <folder> [--library <folder>]
        wwbctl import-video <video-file> [--library <folder>]
        wwbctl attach-scene-video <asset-id> <video-file> [--library <folder>]  # reference cache only
        wwbctl remove <asset-id> [--library <folder>]
        wwbctl convert <input-video> --out <output.mp4>
        wwbctl scene-info <scene.pkg>
        wwbctl scene-render-info <scene.pkg>
        wwbctl scene-engine-info <scene.pkg>
        wwbctl scene-parity-check <scene.pkg> <golden-dir>
        wwbctl doctor
        """)
    }
}

private enum CLIError: Error, LocalizedError {
    case unknownCommand(String)
    case missingPath
    case missingAssetId
    case invalidConvertUsage
    case invalidAttachSceneVideoUsage
    case invalidSceneParityCheckUsage
    case invalidGoldenDirectory(String)

    var errorDescription: String? {
        switch self {
        case .unknownCommand(let command):
            return "unknown command: \(command)"
        case .missingPath:
            return "missing folder path"
        case .missingAssetId:
            return "missing asset id"
        case .invalidConvertUsage:
            return "usage: wwbctl convert <input-video> --out <output.mp4>"
        case .invalidAttachSceneVideoUsage:
            return "usage: wwbctl attach-scene-video <asset-id> <video-file> [--library <folder>] (stores a reference cache only; desktop scene playback uses the external scene renderer when available, then native fallback)"
        case .invalidSceneParityCheckUsage:
            return "usage: wwbctl scene-parity-check <scene.pkg> <golden-dir>"
        case .invalidGoldenDirectory(let path):
            return "golden frame directory does not exist or is not a directory: \(path)"
        }
    }
}

private extension URL {
    var isExistingDirectory: Bool {
        get throws {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                return false
            }
            guard isDirectory.boolValue else {
                return false
            }
            let values = try resourceValues(forKeys: [.isDirectoryKey])
            return values.isDirectory == true
        }
    }
}

private extension JSONEncoder {
    static var cli: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
