import CoreGraphics
import CoreImage
import CryptoKit
import Foundation
@preconcurrency import Metal

enum WallpaperContentKind: String, Codable, Sendable {
    case video
    case metalScene
}

struct MetalSceneManifest: Codable, Hashable, Sendable {
    struct Renderer: Codable, Hashable, Sendable {
        let type: String
        let abiVersion: Int
        let source: String
    }

    struct Resolution: Codable, Hashable, Sendable {
        let width: Int
        let height: Int
    }

    struct Preview: Codable, Hashable, Sendable {
        let time: Float
        let width: Int
        let height: Int
    }

    let schemaVersion: Int
    let name: String
    let author: String?
    let renderer: Renderer
    let resolution: Resolution
    let preview: Preview
    let preferredFPS: Int?
}

struct MetalScenePackage: Hashable, Sendable {
    static let packageExtension = "driftwoodscene"
    static let manifestFilename = "scene.json"
    static let currentSchemaVersion = 1
    static let currentABIVersion = 1

    let packageURL: URL
    let manifestURL: URL
    let sourceURL: URL
    let manifest: MetalSceneManifest
    let source: String
    let contentHash: String
    let byteSize: Int64

    static func isSceneResource(_ resourceURL: URL) -> Bool {
        if resourceURL.pathExtension.caseInsensitiveCompare(
            packageExtension
        ) == .orderedSame {
            return true
        }
        return resourceURL.lastPathComponent.caseInsensitiveCompare(
            manifestFilename
        ) == .orderedSame
            && resourceURL.deletingLastPathComponent().pathExtension
                .caseInsensitiveCompare(packageExtension) == .orderedSame
    }

    static func load(from resourceURL: URL) throws -> MetalScenePackage {
        let packageURL: URL
        let manifestURL: URL
        if resourceURL.pathExtension.caseInsensitiveCompare(
            packageExtension
        ) == .orderedSame {
            packageURL = resourceURL
            manifestURL = resourceURL.appendingPathComponent(manifestFilename)
        } else {
            manifestURL = resourceURL
            packageURL = resourceURL.deletingLastPathComponent()
        }

        guard packageURL.pathExtension.caseInsensitiveCompare(
            packageExtension
        ) == .orderedSame else {
            throw MetalScenePackageError.notScenePackage
        }

        let packageValues = try packageURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard packageValues.isDirectory == true,
              packageValues.isSymbolicLink != true else {
            throw MetalScenePackageError.notScenePackage
        }

        let byteSize = try validatePackageContents(at: packageURL)
        let manifestData = try Data(contentsOf: manifestURL)
        guard manifestData.count <= 64 * 1_024 else {
            throw MetalScenePackageError.manifestTooLarge
        }
        let manifest: MetalSceneManifest
        do {
            manifest = try JSONDecoder().decode(
                MetalSceneManifest.self,
                from: manifestData
            )
        } catch {
            throw MetalScenePackageError.invalidManifest(
                error.localizedDescription
            )
        }
        try validate(manifest)

        guard isSafeRelativePath(manifest.renderer.source) else {
            throw MetalScenePackageError.unsafePath(
                manifest.renderer.source
            )
        }
        let sourceURL = packageURL.appendingPathComponent(
            manifest.renderer.source
        )
        guard isContained(sourceURL, in: packageURL),
              sourceURL.pathExtension.caseInsensitiveCompare("metal")
                == .orderedSame else {
            throw MetalScenePackageError.unsafePath(
                manifest.renderer.source
            )
        }

        let sourceValues = try sourceURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard sourceValues.isRegularFile == true,
              sourceValues.isSymbolicLink != true else {
            throw MetalScenePackageError.symbolicLinksNotSupported
        }
        let sourceData = try Data(contentsOf: sourceURL)
        guard sourceData.count <= 1_024 * 1_024 else {
            throw MetalScenePackageError.sourceTooLarge
        }
        guard let source = String(data: sourceData, encoding: .utf8) else {
            throw MetalScenePackageError.sourceIsNotUTF8
        }
        guard !source.contains("#include") else {
            throw MetalScenePackageError.includesNotSupported
        }
        guard source.contains("driftwoodMain") else {
            throw MetalScenePackageError.entryPointMissing
        }

        var digestInput = Data()
        digestInput.append(manifestData)
        digestInput.append(sourceData)
        let contentHash = SHA256.hash(data: digestInput)
            .map { String(format: "%02x", $0) }
            .joined()

        return MetalScenePackage(
            packageURL: packageURL,
            manifestURL: manifestURL,
            sourceURL: sourceURL,
            manifest: manifest,
            source: source,
            contentHash: contentHash,
            byteSize: byteSize
        )
    }

    private static func validate(_ manifest: MetalSceneManifest) throws {
        guard manifest.schemaVersion == currentSchemaVersion else {
            throw MetalScenePackageError.unsupportedSchema(
                manifest.schemaVersion
            )
        }
        guard manifest.renderer.type == "metalFragment" else {
            throw MetalScenePackageError.unsupportedRenderer(
                manifest.renderer.type
            )
        }
        guard manifest.renderer.abiVersion == currentABIVersion else {
            throw MetalScenePackageError.unsupportedABI(
                manifest.renderer.abiVersion
            )
        }
        guard !manifest.name.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw MetalScenePackageError.missingName
        }
        guard (1 ... 16_384).contains(manifest.resolution.width),
              (1 ... 16_384).contains(manifest.resolution.height),
              (1 ... 4_096).contains(manifest.preview.width),
              (1 ... 4_096).contains(manifest.preview.height),
              manifest.preview.time.isFinite,
              manifest.preview.time >= 0 else {
            throw MetalScenePackageError.invalidDimensions
        }
        if let preferredFPS = manifest.preferredFPS,
           !(1 ... 120).contains(preferredFPS) {
            throw MetalScenePackageError.invalidFrameRate
        }
    }

    private static func validatePackageContents(at packageURL: URL) throws
        -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: packageURL,
            includingPropertiesForKeys: [
                .fileSizeKey,
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ],
            options: []
        ) else {
            throw MetalScenePackageError.unreadablePackage
        }

        let allowedExtensions = Set(["json", "metal", "png", "jpg", "jpeg"])
        var totalBytes: Int64 = 0
        for case let url as URL in enumerator {
            guard isContained(url, in: packageURL) else {
                throw MetalScenePackageError.unsafePath(
                    url.lastPathComponent
                )
            }
            let values = try url.resourceValues(
                forKeys: [
                    .fileSizeKey,
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                ]
            )
            guard values.isSymbolicLink != true else {
                throw MetalScenePackageError.symbolicLinksNotSupported
            }
            if values.isDirectory == true {
                continue
            }
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                throw MetalScenePackageError.unsupportedFile(
                    url.lastPathComponent
                )
            }
            totalBytes += Int64(values.fileSize ?? 0)
            guard totalBytes <= 32 * 1_024 * 1_024 else {
                throw MetalScenePackageError.packageTooLarge
            }

            // Finder may add this metadata file when a package is browsed.
            // It is inert, but all other unsupported package contents remain
            // rejected.
            if url.lastPathComponent == ".DS_Store" {
                continue
            }
            guard allowedExtensions.contains(
                url.pathExtension.lowercased()
            ) else {
                throw MetalScenePackageError.unsupportedFile(
                    url.lastPathComponent
                )
            }
        }
        return totalBytes
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        let components = NSString(string: path).pathComponents
        return !components.contains("..")
            && !components.contains(".")
            && !components.contains("")
    }

    private static func isContained(_ url: URL, in root: URL) -> Bool {
        let rootPath =
            root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let urlPath =
            url.standardizedFileURL.resolvingSymlinksInPath().path
        return urlPath.hasPrefix(rootPath)
    }
}

enum MetalScenePackageError: LocalizedError {
    case notScenePackage
    case unreadablePackage
    case invalidManifest(String)
    case manifestTooLarge
    case unsupportedSchema(Int)
    case unsupportedRenderer(String)
    case unsupportedABI(Int)
    case missingName
    case invalidDimensions
    case invalidFrameRate
    case unsafePath(String)
    case symbolicLinksNotSupported
    case unsupportedFile(String)
    case packageTooLarge
    case sourceTooLarge
    case sourceIsNotUTF8
    case includesNotSupported
    case entryPointMissing
    case metalUnavailable
    case shaderFunctionsMissing
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .notScenePackage:
            "This is not a Driftwood Metal scene package."
        case .unreadablePackage:
            "The Metal scene package could not be read."
        case .invalidManifest(let detail):
            "The scene manifest is invalid: \(detail)"
        case .manifestTooLarge:
            "The scene manifest is too large."
        case .unsupportedSchema(let version):
            "Scene schema version \(version) is not supported."
        case .unsupportedRenderer(let renderer):
            "Scene renderer “\(renderer)” is not supported."
        case .unsupportedABI(let version):
            "Scene shader ABI version \(version) is not supported."
        case .missingName:
            "The scene manifest needs a name."
        case .invalidDimensions:
            "The scene manifest contains invalid render dimensions."
        case .invalidFrameRate:
            "The scene’s preferred frame rate must be between 1 and 120."
        case .unsafePath(let path):
            "The scene contains an unsafe path: \(path)"
        case .symbolicLinksNotSupported:
            "Metal scene packages cannot contain symbolic links."
        case .unsupportedFile(let name):
            "The scene contains an unsupported file: \(name)"
        case .packageTooLarge:
            "The Metal scene package is larger than 32 MB."
        case .sourceTooLarge:
            "The Metal shader source is larger than 1 MB."
        case .sourceIsNotUTF8:
            "The Metal shader must be UTF-8 text."
        case .includesNotSupported:
            "Metal scene shaders cannot use #include."
        case .entryPointMissing:
            "The shader must define driftwoodMain."
        case .metalUnavailable:
            "Metal rendering is unavailable on this Mac."
        case .shaderFunctionsMissing:
            "The scene’s Metal shader functions could not be loaded."
        case .renderFailed:
            "The Metal scene could not render a frame."
        }
    }
}

struct DriftwoodMetalUniforms {
    var resolution: SIMD2<Float>
    var time: Float
    var deltaTime: Float
    var playbackRate: Float
    var frameIndex: UInt32
    var padding: SIMD2<Float> = .zero
}

private final class MetalScenePipelineCache: @unchecked Sendable {
    static let shared = MetalScenePipelineCache()

    private final class PipelineBox {
        let value: MTLRenderPipelineState

        init(_ value: MTLRenderPipelineState) {
            self.value = value
        }
    }

    private let pipelines = NSCache<NSString, PipelineBox>()

    private init() {
        pipelines.countLimit = 16
    }

    func pipeline(
        for package: MetalScenePackage,
        device: MTLDevice
    ) throws -> MTLRenderPipelineState {
        let key = "\(device.registryID)-\(package.contentHash)" as NSString
        if let pipeline = pipelines.object(forKey: key)?.value {
            return pipeline
        }

        let source = Self.abiHeader + "\n"
            + package.source + "\n"
            + Self.abiWrapper
        let library = try device.makeLibrary(source: source, options: nil)
        guard let vertex = library.makeFunction(
            name: "driftwoodFullscreenVertex"
        ), let fragment = library.makeFunction(
            name: "driftwoodFragment"
        ) else {
            throw MetalScenePackageError.shaderFunctionsMissing
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline = try device.makeRenderPipelineState(
            descriptor: descriptor
        )

        pipelines.setObject(PipelineBox(pipeline), forKey: key)
        return pipeline
    }

    private static let abiHeader = """
    #include <metal_stdlib>
    using namespace metal;

    struct DriftwoodMetalUniforms {
        float2 resolution;
        float time;
        float deltaTime;
        float playbackRate;
        uint frameIndex;
        float2 padding;
    };
    """

    private static let abiWrapper = """
    struct DriftwoodVertexOutput {
        float4 position [[position]];
    };

    vertex DriftwoodVertexOutput driftwoodFullscreenVertex(
        uint vertexID [[vertex_id]]
    ) {
        const float2 positions[3] = {
            float2(-1.0, -1.0),
            float2(3.0, -1.0),
            float2(-1.0, 3.0)
        };
        DriftwoodVertexOutput output;
        output.position = float4(positions[vertexID], 0.0, 1.0);
        return output;
    }

    fragment float4 driftwoodFragment(
        DriftwoodVertexOutput input [[stage_in]],
        constant DriftwoodMetalUniforms &uniforms [[buffer(0)]]
    ) {
        float2 fragCoord = input.position.xy;
        fragCoord.y = uniforms.resolution.y - fragCoord.y;
        return driftwoodMain(fragCoord, uniforms);
    }
    """
}

enum MetalSceneCompiler {
    static func makePipeline(
        package: MetalScenePackage,
        device: MTLDevice
    ) throws -> MTLRenderPipelineState {
        try MetalScenePipelineCache.shared.pipeline(
            for: package,
            device: device
        )
    }

    static func encode(
        commandBuffer: MTLCommandBuffer,
        texture: MTLTexture,
        pipeline: MTLRenderPipelineState,
        uniforms: inout DriftwoodMetalUniforms
    ) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: pass
        ) else {
            throw MetalScenePackageError.renderFailed
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<DriftwoodMetalUniforms>.stride,
            index: 0
        )
        encoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 3
        )
        encoder.endEncoding()
    }

    static func renderStill(
        package: MetalScenePackage,
        size requestedSize: CGSize? = nil,
        time: Float? = nil
    ) throws -> CGImage {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw MetalScenePackageError.metalUnavailable
        }
        let pipeline = try makePipeline(package: package, device: device)
        let size = requestedSize ?? CGSize(
            width: package.manifest.preview.width,
            height: package.manifest.preview.height
        )
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalScenePackageError.renderFailed
        }
        var uniforms = DriftwoodMetalUniforms(
            resolution: SIMD2(Float(width), Float(height)),
            time: time ?? package.manifest.preview.time,
            deltaTime: 0,
            playbackRate: 1,
            frameIndex: 0
        )
        try encode(
            commandBuffer: commandBuffer,
            texture: texture,
            pipeline: pipeline,
            uniforms: &uniforms
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed,
              commandBuffer.error == nil,
              let image = CIImage(
                  mtlTexture: texture,
                  options: [
                      .colorSpace: CGColorSpaceCreateDeviceRGB()
                  ]
              ) else {
            if let error = commandBuffer.error {
                throw error
            }
            throw MetalScenePackageError.renderFailed
        }

        // Core Image gives a standalone Metal texture a bottom-left origin,
        // while the live CVPixelBuffer path is top-left. Mirror only this
        // exported still so a poster has the same orientation as the wallpaper.
        let orientedImage = image.oriented(.downMirrored)
        guard let cgImage = CIContext(mtlDevice: device).createCGImage(
            orientedImage,
            from: CGRect(
                x: 0,
                y: 0,
                width: width,
                height: height
            )
        ) else {
            if let error = commandBuffer.error {
                throw error
            }
            throw MetalScenePackageError.renderFailed
        }
        return cgImage
    }
}
