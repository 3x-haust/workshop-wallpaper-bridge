import Foundation

/// 2D affine transform used for puppet-warp skinning.
public struct SceneAffine: Equatable, Sendable {
    public var a: Double
    public var b: Double
    public var c: Double
    public var d: Double
    public var tx: Double
    public var ty: Double

    public static let identity = SceneAffine(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.tx = tx
        self.ty = ty
    }

    public init(translationX: Double, y: Double, rotation: Double) {
        let cosine = cos(rotation)
        let sine = sin(rotation)
        self.init(a: cosine, b: sine, c: -sine, d: cosine, tx: translationX, ty: y)
    }

    public func concatenating(_ other: SceneAffine) -> SceneAffine {
        SceneAffine(
            a: a * other.a + c * other.b,
            b: b * other.a + d * other.b,
            c: a * other.c + c * other.d,
            d: b * other.c + d * other.d,
            tx: a * other.tx + c * other.ty + tx,
            ty: b * other.tx + d * other.ty + ty
        )
    }

    public func inverted() -> SceneAffine {
        let determinant = a * d - b * c
        guard abs(determinant) > 1e-12 else {
            return .identity
        }
        let inverseDeterminant = 1 / determinant
        return SceneAffine(
            a: d * inverseDeterminant,
            b: -b * inverseDeterminant,
            c: -c * inverseDeterminant,
            d: a * inverseDeterminant,
            tx: (c * ty - d * tx) * inverseDeterminant,
            ty: (b * tx - a * ty) * inverseDeterminant
        )
    }

    public func apply(x: Double, y: Double) -> (x: Double, y: Double) {
        (a * x + c * y + tx, b * x + d * y + ty)
    }
}

public struct ScenePuppetVertex: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let u: Double
    public let v: Double
    public let boneIndices: [Int]
    public let weights: [Double]

    public init(x: Double, y: Double, u: Double, v: Double, boneIndices: [Int], weights: [Double]) {
        self.x = x
        self.y = y
        self.u = u
        self.v = v
        self.boneIndices = boneIndices
        self.weights = weights
    }
}

public struct ScenePuppetBone: Equatable, Sendable {
    public let parent: Int

    public init(parent: Int) {
        self.parent = parent
    }
}

/// One sampled bone pose: local translation plus Z rotation.
public struct ScenePuppetPose: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let rotation: Double

    public init(x: Double, y: Double, rotation: Double) {
        self.x = x
        self.y = y
        self.rotation = rotation
    }
}

public struct ScenePuppetAnimation: Equatable, Sendable {
    public let id: Int
    public let name: String
    public let mirrors: Bool
    public let fps: Double
    /// frames[frame][bone]
    public let frames: [[ScenePuppetPose]]

    public init(id: Int, name: String, mirrors: Bool, fps: Double, frames: [[ScenePuppetPose]]) {
        self.id = id
        self.name = name
        self.mirrors = mirrors
        self.fps = fps
        self.frames = frames
    }

    /// Samples the looped (or ping-ponged) pose for every bone at `time`
    /// seconds, linearly interpolating between stored frames the way
    /// Wallpaper Engine plays puppet animations.
    public func poses(at time: Double, rate: Double = 1) -> [ScenePuppetPose] {
        guard let first = frames.first else {
            return []
        }
        guard frames.count > 1 else {
            return first
        }
        let span = Double(frames.count - 1)
        var position = time * max(fps, 0.01) * rate
        if mirrors {
            let cycle = position.truncatingRemainder(dividingBy: span * 2)
            position = cycle <= span ? cycle : (span * 2) - cycle
        } else {
            position = position.truncatingRemainder(dividingBy: span)
        }
        let lower = min(Int(position), frames.count - 2)
        let upper = lower + 1
        let fraction = position - Double(lower)
        return zip(frames[lower], frames[upper]).map { start, end in
            ScenePuppetPose(
                x: start.x + (end.x - start.x) * fraction,
                y: start.y + (end.y - start.y) * fraction,
                rotation: start.rotation + (end.rotation - start.rotation) * fraction
            )
        }
    }
}

public struct ScenePuppetModel: Equatable, Sendable {
    public let vertices: [ScenePuppetVertex]
    public let triangles: [Int]
    public let bones: [ScenePuppetBone]
    public let animations: [ScenePuppetAnimation]

    public init(
        vertices: [ScenePuppetVertex],
        triangles: [Int],
        bones: [ScenePuppetBone],
        animations: [ScenePuppetAnimation]
    ) {
        self.vertices = vertices
        self.triangles = triangles
        self.bones = bones
        self.animations = animations
    }

    public func animation(withID id: Int?) -> ScenePuppetAnimation? {
        guard let id else {
            return animations.first
        }
        return animations.first { $0.id == id } ?? animations.first
    }

    /// World transform per bone for a set of local poses, following parents.
    public func worldTransforms(for poses: [ScenePuppetPose]) -> [SceneAffine] {
        var world = [SceneAffine](repeating: .identity, count: bones.count)
        for index in bones.indices {
            let pose = index < poses.count ? poses[index] : ScenePuppetPose(x: 0, y: 0, rotation: 0)
            let local = SceneAffine(translationX: pose.x, y: pose.y, rotation: pose.rotation)
            let parent = bones[index].parent
            if parent >= 0 && parent < index {
                world[index] = world[parent].concatenating(local)
            } else {
                world[index] = local
            }
        }
        return world
    }

    /// Skin matrices mapping bind-pose space into the animated pose, built
    /// against frame 0 so the animation starts exactly at the bind pose.
    public func skinTransforms(at time: Double, animationID: Int?, rate: Double) -> [SceneAffine]? {
        guard let animation = animation(withID: animationID),
              let bindPose = animation.frames.first else {
            return nil
        }
        let bindWorld = worldTransforms(for: bindPose)
        let animatedWorld = worldTransforms(for: animation.poses(at: time, rate: rate))
        return zip(animatedWorld, bindWorld).map { animated, bind in
            animated.concatenating(bind.inverted())
        }
    }

    /// Applies skinning to every vertex, returning deformed positions.
    public func deformedPositions(skins: [SceneAffine]) -> [(x: Double, y: Double)] {
        vertices.map { vertex in
            var x = 0.0
            var y = 0.0
            var totalWeight = 0.0
            for slot in 0..<min(vertex.boneIndices.count, vertex.weights.count) {
                let weight = vertex.weights[slot]
                guard weight > 0.0001 else {
                    continue
                }
                let bone = vertex.boneIndices[slot]
                guard bone >= 0, bone < skins.count else {
                    continue
                }
                let p = skins[bone].apply(x: vertex.x, y: vertex.y)
                x += p.x * weight
                y += p.y * weight
                totalWeight += weight
            }
            if totalWeight < 0.0001 {
                return (vertex.x, vertex.y)
            }
            return (x / totalWeight, y / totalWeight)
        }
    }
}

/// Decoder for the Wallpaper Engine MDLV0013 puppet-warp container, as
/// reverse-engineered from packaged scene models: a 52-byte vertex array
/// (position, four bone indices, four weights, UV), 16-bit triangle indices,
/// an MDLS0001 skeleton with 4x4 column-major bind matrices, and MDLA0001
/// animations holding per-bone tracks of translation/rotation/scale frames.
public struct ScenePuppetModelDecoder: Sendable {
    private static let maximumVertexCount = 65_536
    private static let maximumBoneCount = 256
    private static let maximumFrameCount = 4_096
    private static let maximumAnimationCount = 64

    public init() {}

    public func decode(data: Data) throws -> ScenePuppetModel {
        var reader = ScenePuppetBinaryReader(data: data)
        guard try reader.readBytes(8) == Data("MDLV0013".utf8) else {
            throw ScenePuppetModelError.unsupportedMagic
        }
        try reader.skip(1)
        _ = try reader.readUInt32()
        _ = try reader.readUInt32()
        _ = try reader.readUInt32()
        _ = try reader.readCString()
        _ = try reader.readUInt32()
        let vertexBytes = Int(try reader.readUInt32())
        guard vertexBytes % 52 == 0, vertexBytes / 52 <= Self.maximumVertexCount else {
            throw ScenePuppetModelError.malformedModel
        }
        var vertices: [ScenePuppetVertex] = []
        vertices.reserveCapacity(vertexBytes / 52)
        for _ in 0..<(vertexBytes / 52) {
            let x = Double(try reader.readFloat())
            let y = Double(try reader.readFloat())
            _ = try reader.readFloat()
            var bones: [Int] = []
            for _ in 0..<4 {
                bones.append(Int(try reader.readInt32()))
            }
            var weights: [Double] = []
            for _ in 0..<4 {
                weights.append(Double(try reader.readFloat()))
            }
            let u = Double(try reader.readFloat())
            let v = Double(try reader.readFloat())
            vertices.append(ScenePuppetVertex(x: x, y: y, u: u, v: v, boneIndices: bones, weights: weights))
        }
        let indexBytes = Int(try reader.readUInt32())
        guard indexBytes % 2 == 0 else {
            throw ScenePuppetModelError.malformedModel
        }
        var triangles: [Int] = []
        triangles.reserveCapacity(indexBytes / 2)
        for _ in 0..<(indexBytes / 2) {
            let index = Int(try reader.readUInt16())
            guard index < vertices.count else {
                throw ScenePuppetModelError.malformedModel
            }
            triangles.append(index)
        }
        guard try reader.readBytes(8) == Data("MDLS0001".utf8) else {
            throw ScenePuppetModelError.malformedModel
        }
        try reader.skip(1)
        _ = try reader.readUInt32()
        let boneCount = Int(try reader.readUInt32())
        guard boneCount > 0, boneCount <= Self.maximumBoneCount else {
            throw ScenePuppetModelError.malformedModel
        }
        var bones: [ScenePuppetBone] = []
        for _ in 0..<boneCount {
            try reader.skip(1)
            _ = try reader.readUInt32()
            let parent = Int(try reader.readInt32())
            let matrixBytes = Int(try reader.readUInt32())
            guard matrixBytes == 64 else {
                throw ScenePuppetModelError.malformedModel
            }
            try reader.skip(64)
            try reader.skip(1)
            bones.append(ScenePuppetBone(parent: parent))
        }
        guard try reader.readBytes(8) == Data("MDLA0001".utf8) else {
            // Models without animation data still expose the static mesh.
            return ScenePuppetModel(vertices: vertices, triangles: triangles, bones: bones, animations: [])
        }
        try reader.skip(1)
        _ = try reader.readUInt32()
        let animationCount = Int(try reader.readUInt32())
        guard animationCount <= Self.maximumAnimationCount else {
            throw ScenePuppetModelError.malformedModel
        }
        var animations: [ScenePuppetAnimation] = []
        for _ in 0..<animationCount {
            let id = Int(try reader.readUInt32())
            _ = try reader.readUInt32()
            let name = try reader.readCString()
            let mode = try reader.readCString()
            let fps = Double(try reader.readFloat())
            let declaredFrames = Int(try reader.readUInt32())
            _ = try reader.readUInt32()
            let trackCount = Int(try reader.readUInt32())
            guard trackCount == boneCount, declaredFrames <= Self.maximumFrameCount else {
                throw ScenePuppetModelError.malformedModel
            }
            // tracks[bone][frame]
            var tracks: [[ScenePuppetPose]] = []
            var frameCount = Int.max
            for _ in 0..<trackCount {
                _ = try reader.readUInt32()
                let trackBytes = Int(try reader.readUInt32())
                guard trackBytes % 36 == 0, trackBytes / 36 <= Self.maximumFrameCount else {
                    throw ScenePuppetModelError.malformedModel
                }
                var poses: [ScenePuppetPose] = []
                for _ in 0..<(trackBytes / 36) {
                    let tx = Double(try reader.readFloat())
                    let ty = Double(try reader.readFloat())
                    _ = try reader.readFloat()
                    _ = try reader.readFloat()
                    _ = try reader.readFloat()
                    let rz = Double(try reader.readFloat())
                    _ = try reader.readFloat()
                    _ = try reader.readFloat()
                    _ = try reader.readFloat()
                    poses.append(ScenePuppetPose(x: tx, y: ty, rotation: rz))
                }
                frameCount = min(frameCount, poses.count)
                tracks.append(poses)
            }
            guard frameCount > 0, frameCount != Int.max else {
                continue
            }
            let frames = (0..<frameCount).map { frame in
                tracks.map { $0[frame] }
            }
            animations.append(ScenePuppetAnimation(
                id: id,
                name: name,
                mirrors: mode.lowercased() == "mirror",
                fps: fps > 0 ? fps : 30,
                frames: frames
            ))
        }
        return ScenePuppetModel(vertices: vertices, triangles: triangles, bones: bones, animations: animations)
    }
}

public enum ScenePuppetModelError: Error, Equatable, LocalizedError {
    case unsupportedMagic
    case malformedModel
    case truncatedModel

    public var errorDescription: String? {
        switch self {
        case .unsupportedMagic:
            return "The puppet model container is not MDLV0013."
        case .malformedModel:
            return "The puppet model data is malformed."
        case .truncatedModel:
            return "The puppet model data is truncated."
        }
    }
}

struct ScenePuppetBinaryReader {
    let data: Data
    var offset = 0

    mutating func readBytes(_ count: Int) throws -> Data {
        guard count >= 0, data.count - offset >= count else {
            throw ScenePuppetModelError.truncatedModel
        }
        defer { offset += count }
        return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + count))
    }

    mutating func skip(_ count: Int) throws {
        guard data.count - offset >= count else {
            throw ScenePuppetModelError.truncatedModel
        }
        offset += count
    }

    mutating func readUInt32() throws -> UInt32 {
        guard data.count - offset >= 4 else {
            throw ScenePuppetModelError.truncatedModel
        }
        let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        offset += 4
        return UInt32(littleEndian: value)
    }

    mutating func readInt32() throws -> Int32 {
        Int32(bitPattern: try readUInt32())
    }

    mutating func readUInt16() throws -> UInt16 {
        guard data.count - offset >= 2 else {
            throw ScenePuppetModelError.truncatedModel
        }
        let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }
        offset += 2
        return UInt16(littleEndian: value)
    }

    mutating func readFloat() throws -> Float {
        Float(bitPattern: try readUInt32())
    }

    mutating func readCString() throws -> String {
        var bytes: [UInt8] = []
        while true {
            guard offset < data.count else {
                throw ScenePuppetModelError.truncatedModel
            }
            let byte = data[data.startIndex + offset]
            offset += 1
            if byte == 0 {
                break
            }
            bytes.append(byte)
            guard bytes.count <= 4_096 else {
                throw ScenePuppetModelError.malformedModel
            }
        }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }
}
