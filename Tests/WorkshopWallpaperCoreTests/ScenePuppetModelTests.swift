import Foundation
import XCTest
@testable import WorkshopWallpaperCore

final class ScenePuppetModelTests: XCTestCase {
    func testDecoderParsesSyntheticPuppetModel() throws {
        // Given: a two-bone, two-triangle quad whose second bone waves.
        let data = Self.puppetData(
            vertices: [
                (x: -10, y: -10, bone: 0, u: 0, v: 0),
                (x: 10, y: -10, bone: 0, u: 1, v: 0),
                (x: -10, y: 10, bone: 1, u: 0, v: 1),
                (x: 10, y: 10, bone: 1, u: 1, v: 1)
            ],
            triangles: [0, 1, 2, 2, 1, 3],
            bones: [-1, 0],
            animation: (
                id: 372,
                name: "Animación 1",
                mode: "mirror",
                fps: 5.8,
                tracks: [
                    [(x: 0, y: 0, rz: 0), (x: 0, y: 0, rz: 0)],
                    [(x: 0, y: 5, rz: 0), (x: 0, y: 5, rz: 0.5)]
                ]
            )
        )

        // When
        let model = try ScenePuppetModelDecoder().decode(data: data)

        // Then
        XCTAssertEqual(model.vertices.count, 4)
        XCTAssertEqual(model.vertices[0].x, -10)
        XCTAssertEqual(model.vertices[3].boneIndices[0], 1)
        XCTAssertEqual(model.vertices[3].weights[0], 1)
        XCTAssertEqual(model.vertices[3].u, 1)
        XCTAssertEqual(model.triangles, [0, 1, 2, 2, 1, 3])
        XCTAssertEqual(model.bones.map(\.parent), [-1, 0])
        let animation = try XCTUnwrap(model.animations.first)
        XCTAssertEqual(animation.id, 372)
        XCTAssertEqual(animation.name, "Animación 1")
        XCTAssertTrue(animation.mirrors)
        XCTAssertEqual(animation.fps, 5.8, accuracy: 0.001)
        XCTAssertEqual(animation.frames.count, 2)
        XCTAssertEqual(animation.frames[1][1].rotation, 0.5, accuracy: 0.0001)
    }

    func testAnimationSamplingInterpolatesAndMirrors() {
        let animation = ScenePuppetAnimation(
            id: 1,
            name: "wave",
            mirrors: true,
            fps: 1,
            frames: [
                [ScenePuppetPose(x: 0, y: 0, rotation: 0)],
                [ScenePuppetPose(x: 10, y: 0, rotation: 1)]
            ]
        )

        XCTAssertEqual(animation.poses(at: 0.5)[0].x, 5, accuracy: 0.0001)
        XCTAssertEqual(animation.poses(at: 0.5)[0].rotation, 0.5, accuracy: 0.0001)
        // Mirror playback returns toward the first frame after the span ends.
        XCTAssertEqual(animation.poses(at: 1.5)[0].x, 5, accuracy: 0.0001)
        XCTAssertEqual(animation.poses(at: 2.0)[0].x, 0, accuracy: 0.0001)
    }

    func testAnimationSamplingHandlesNegativeRate() {
        let animation = ScenePuppetAnimation(
            id: 1,
            name: "reverse",
            mirrors: false,
            fps: 1,
            frames: [
                [ScenePuppetPose(x: 0, y: 0, rotation: 0)],
                [ScenePuppetPose(x: 10, y: 0, rotation: 1)],
                [ScenePuppetPose(x: 20, y: 0, rotation: 2)]
            ]
        )

        XCTAssertEqual(animation.poses(at: 0.5, rate: -1)[0].x, 15, accuracy: 0.0001)
    }

    func testSkinningRotatesWeightedVerticesAboutTheBone() throws {
        let model = ScenePuppetModel(
            vertices: [
                ScenePuppetVertex(x: 10, y: 0, u: 0, v: 0, boneIndices: [0, 0, 0, 0], weights: [1, 0, 0, 0])
            ],
            triangles: [0, 0, 0],
            bones: [ScenePuppetBone(parent: -1)],
            animations: [
                ScenePuppetAnimation(
                    id: 7,
                    name: "spin",
                    mirrors: false,
                    fps: 1,
                    frames: [
                        [ScenePuppetPose(x: 0, y: 0, rotation: 0)],
                        [ScenePuppetPose(x: 0, y: 0, rotation: .pi / 2)]
                    ]
                )
            ]
        )

        let skins = try XCTUnwrap(model.skinTransforms(at: 0.5, animationID: 7, rate: 1))
        let positions = model.deformedPositions(skins: skins)

        // Halfway through the quarter turn the vertex sits at 45 degrees.
        XCTAssertEqual(positions[0].x, 10 * cos(Double.pi / 4), accuracy: 0.001)
        XCTAssertEqual(positions[0].y, 10 * sin(Double.pi / 4), accuracy: 0.001)
    }

    func testSkinTransformsStartAtBindPose() throws {
        let model = ScenePuppetModel(
            vertices: [
                ScenePuppetVertex(x: 3, y: 4, u: 0, v: 0, boneIndices: [0, 0, 0, 0], weights: [1, 0, 0, 0])
            ],
            triangles: [0, 0, 0],
            bones: [ScenePuppetBone(parent: -1)],
            animations: [
                ScenePuppetAnimation(
                    id: 1,
                    name: "rest",
                    mirrors: false,
                    fps: 1,
                    frames: [
                        [ScenePuppetPose(x: 100, y: 50, rotation: 0.7)],
                        [ScenePuppetPose(x: 100, y: 50, rotation: 0.7)]
                    ]
                )
            ]
        )

        let skins = try XCTUnwrap(model.skinTransforms(at: 0, animationID: 1, rate: 1))
        let positions = model.deformedPositions(skins: skins)

        // Frame 0 defines the bind pose, so the mesh starts undeformed even
        // though the bone itself carries a transform.
        XCTAssertEqual(positions[0].x, 3, accuracy: 0.001)
        XCTAssertEqual(positions[0].y, 4, accuracy: 0.001)
    }

    func testDecoderAcceptsStaticModelWithoutAnimationChunk() throws {
        let data = Self.puppetData(
            vertices: [
                (x: -10, y: -10, bone: 0, u: 0, v: 0),
                (x: 10, y: -10, bone: 0, u: 1, v: 0),
                (x: -10, y: 10, bone: 0, u: 0, v: 1)
            ],
            triangles: [0, 1, 2],
            bones: [-1],
            animation: nil
        )

        let model = try ScenePuppetModelDecoder().decode(data: data)
        let skins = try XCTUnwrap(model.skinTransforms(at: 3, animationID: nil, rate: 1))
        let positions = model.deformedPositions(skins: skins)

        XCTAssertTrue(model.animations.isEmpty)
        XCTAssertEqual(positions[0].x, -10, accuracy: 0.001)
        XCTAssertEqual(positions[1].y, -10, accuracy: 0.001)
    }

    // MARK: - Fixture

    // swiftlint:disable:next function_body_length
    private static func puppetData(
        vertices: [(x: Double, y: Double, bone: Int, u: Double, v: Double)],
        triangles: [Int],
        bones: [Int],
        animation: (id: Int, name: String, mode: String, fps: Double, tracks: [[(x: Double, y: Double, rz: Double)]])?
    ) -> Data {
        var data = Data()
        data.append(Data("MDLV0013".utf8))
        data.append(0)
        data.appendUInt32(0x0180_0009)
        data.appendUInt32(1)
        data.appendUInt32(1)
        data.append(Data("materials/test.json".utf8))
        data.append(0)
        data.appendUInt32(0)
        data.appendUInt32(UInt32(vertices.count * 52))
        for vertex in vertices {
            data.appendFloat(Float(vertex.x))
            data.appendFloat(Float(vertex.y))
            data.appendFloat(0)
            data.appendUInt32(UInt32(vertex.bone))
            data.appendUInt32(0)
            data.appendUInt32(0)
            data.appendUInt32(0)
            data.appendFloat(1)
            data.appendFloat(0)
            data.appendFloat(0)
            data.appendFloat(0)
            data.appendFloat(Float(vertex.u))
            data.appendFloat(Float(vertex.v))
        }
        data.appendUInt32(UInt32(triangles.count * 2))
        for index in triangles {
            data.appendUInt16(UInt16(index))
        }
        data.append(Data("MDLS0001".utf8))
        data.append(0)
        data.appendUInt32(0)
        data.appendUInt32(UInt32(bones.count))
        for parent in bones {
            data.append(0)
            data.appendUInt32(1)
            data.appendInt32(Int32(parent))
            data.appendUInt32(64)
            let identity: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
            for value in identity {
                data.appendFloat(value)
            }
            data.append(0)
        }
        guard let animation else {
            return data
        }
        data.append(Data("MDLA0001".utf8))
        data.append(0)
        data.appendUInt32(0)
        data.appendUInt32(1)
        data.appendUInt32(UInt32(animation.id))
        data.appendUInt32(0)
        data.append(Data(animation.name.utf8))
        data.append(0)
        data.append(Data(animation.mode.utf8))
        data.append(0)
        data.appendFloat(Float(animation.fps))
        data.appendUInt32(UInt32(max(animation.tracks.first?.count ?? 1, 1) - 1))
        data.appendUInt32(0)
        data.appendUInt32(UInt32(animation.tracks.count))
        for track in animation.tracks {
            data.appendUInt32(0)
            data.appendUInt32(UInt32(track.count * 36))
            for frame in track {
                data.appendFloat(Float(frame.x))
                data.appendFloat(Float(frame.y))
                data.appendFloat(0)
                data.appendFloat(0)
                data.appendFloat(0)
                data.appendFloat(Float(frame.rz))
                data.appendFloat(1)
                data.appendFloat(1)
                data.appendFloat(1)
            }
        }
        return data
    }
}

private extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        var raw = value.littleEndian
        Swift.withUnsafeBytes(of: &raw) { append(contentsOf: $0) }
    }

    mutating func appendInt32(_ value: Int32) {
        appendUInt32(UInt32(bitPattern: value))
    }

    mutating func appendUInt16(_ value: UInt16) {
        var raw = value.littleEndian
        Swift.withUnsafeBytes(of: &raw) { append(contentsOf: $0) }
    }

    mutating func appendFloat(_ value: Float) {
        appendUInt32(value.bitPattern)
    }
}
