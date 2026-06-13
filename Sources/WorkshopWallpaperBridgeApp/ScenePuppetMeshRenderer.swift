import CoreGraphics
import Foundation
import WorkshopWallpaperCore

/// CPU renderer for Wallpaper Engine puppet-warp models: skins the mesh on
/// the current animation pose and rasterizes each triangle by drawing the
/// sprite texture through the affine map from its UV triangle.
struct ScenePuppetMeshRenderer {
    let model: ScenePuppetModel
    let texture: CGImage
    let animationID: Int?
    let rate: Double

    /// Canvas description in mesh units, padded so deformation stays inside.
    let meshBounds: CGRect
    let pixelsPerUnit: CGFloat
    /// Whether mesh Y grows downward (matching UV V); detected from the
    /// bind pose so either authoring convention renders upright.
    let yGrowsDown: Bool

    private struct TriangleUV {
        let i0: Int
        let i1: Int
        let i2: Int
        let sourceTransform: CGAffineTransform
    }

    private let triangleSources: [TriangleUV]

    init?(
        model: ScenePuppetModel,
        texture: CGImage,
        animationID: Int?,
        rate: Double,
        maximumCanvasDimension: CGFloat = 1024
    ) {
        guard !model.vertices.isEmpty, model.triangles.count >= 3 else {
            return nil
        }
        self.model = model
        self.texture = texture
        self.animationID = animationID
        self.rate = rate

        let xs = model.vertices.map(\.x)
        let ys = model.vertices.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max(),
              maxX > minX, maxY > minY else {
            return nil
        }
        let meanY = ys.reduce(0, +) / Double(ys.count)
        let vs = model.vertices.map(\.v)
        let meanV = vs.reduce(0, +) / Double(vs.count)
        let yvCovariance = zip(ys, vs).reduce(0.0) { $0 + ($1.0 - meanY) * ($1.1 - meanV) }
        yGrowsDown = yvCovariance >= 0

        let padX = (maxX - minX) * 0.18
        let padY = (maxY - minY) * 0.18
        let bounds = CGRect(
            x: minX - padX,
            y: minY - padY,
            width: (maxX - minX) + padX * 2,
            height: (maxY - minY) + padY * 2
        )
        meshBounds = bounds

        // Match the decoded texture's resolution: the sprite spans the UV
        // range of the mesh, so derive mesh-units-per-texture-pixel from it.
        let us = model.vertices.map(\.u)
        let uSpan = (us.max() ?? 1) - (us.min() ?? 0)
        let spriteWidthInMeshUnits = uSpan > 0.0001 ? (maxX - minX) / uSpan : (maxX - minX)
        var density = CGFloat(texture.width) / CGFloat(max(spriteWidthInMeshUnits, 1))
        let largestSide = max(bounds.width, bounds.height)
        if largestSide * density > maximumCanvasDimension {
            density = maximumCanvasDimension / largestSide
        }
        pixelsPerUnit = max(density, 0.05)

        let textureWidth = CGFloat(texture.width)
        let textureHeight = CGFloat(texture.height)
        var sources: [TriangleUV] = []
        sources.reserveCapacity(model.triangles.count / 3)
        for triangle in 0..<(model.triangles.count / 3) {
            let i0 = model.triangles[triangle * 3]
            let i1 = model.triangles[triangle * 3 + 1]
            let i2 = model.triangles[triangle * 3 + 2]
            let v0 = model.vertices[i0]
            let v1 = model.vertices[i1]
            let v2 = model.vertices[i2]
            // Texture pixel coordinates of the UV triangle (top-left origin).
            let s0 = CGPoint(x: v0.u * Double(textureWidth), y: v0.v * Double(textureHeight))
            let s1 = CGPoint(x: v1.u * Double(textureWidth), y: v1.v * Double(textureHeight))
            let s2 = CGPoint(x: v2.u * Double(textureWidth), y: v2.v * Double(textureHeight))
            guard let inverse = Self.affineMapping(from: (s0, s1, s2)) else {
                continue
            }
            sources.append(TriangleUV(i0: i0, i1: i1, i2: i2, sourceTransform: inverse))
        }
        guard !sources.isEmpty else {
            return nil
        }
        triangleSources = sources
    }

    var canvasPixelSize: CGSize {
        CGSize(
            width: max(1, (meshBounds.width * pixelsPerUnit).rounded(.up)),
            height: max(1, (meshBounds.height * pixelsPerUnit).rounded(.up))
        )
    }

    /// Renders the skinned mesh at `time` seconds into a bitmap covering
    /// `meshBounds`. Returns nil when the pose cannot be evaluated.
    func render(at time: Double) -> CGImage? {
        guard let skins = model.skinTransforms(at: time, animationID: animationID, rate: rate) else {
            return nil
        }
        let positions = model.deformedPositions(skins: skins)
        let size = canvasPixelSize
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.clear(CGRect(origin: .zero, size: size))
        context.interpolationQuality = .medium

        // Canvas rows run top-down like layer contents; map mesh Y so the
        // sprite renders upright regardless of the mesh's Y direction.
        func canvasPoint(_ p: (x: Double, y: Double)) -> CGPoint {
            let row = yGrowsDown
                ? (CGFloat(p.y) - meshBounds.minY)
                : (meshBounds.maxY - CGFloat(p.y))
            return CGPoint(
                x: (CGFloat(p.x) - meshBounds.minX) * pixelsPerUnit,
                y: row * pixelsPerUnit
            )
        }

        let textureRect = CGRect(x: 0, y: 0, width: texture.width, height: texture.height)
        for triangle in triangleSources {
            let d0 = canvasPoint(positions[triangle.i0])
            let d1 = canvasPoint(positions[triangle.i1])
            let d2 = canvasPoint(positions[triangle.i2])
            let destinationTransform = CGAffineTransform(
                a: d1.x - d0.x, b: d1.y - d0.y,
                c: d2.x - d0.x, d: d2.y - d0.y,
                tx: d0.x, ty: d0.y
            )
            context.saveGState()
            context.beginPath()
            // Expand the clip a hair to hide seams between triangles.
            let cx = (d0.x + d1.x + d2.x) / 3
            let cy = (d0.y + d1.y + d2.y) / 3
            func expanded(_ p: CGPoint) -> CGPoint {
                CGPoint(x: cx + (p.x - cx) * 1.02, y: cy + (p.y - cy) * 1.02)
            }
            context.move(to: expanded(d0))
            context.addLine(to: expanded(d1))
            context.addLine(to: expanded(d2))
            context.closePath()
            context.clip()
            context.concatenate(destinationTransform)
            context.concatenate(triangle.sourceTransform)
            // The texture draws in its own pixel space; flip because CGImage
            // drawing uses a bottom-left origin while UVs are top-left.
            context.translateBy(x: 0, y: textureRect.height)
            context.scaleBy(x: 1, y: -1)
            context.draw(texture, in: textureRect)
            context.restoreGState()
        }
        return context.makeImage()
    }

    /// Affine transform mapping the unit basis triangle onto `points`,
    /// inverted — i.e. the transform that takes triangle-space coordinates
    /// back to barycentric basis space.
    private static func affineMapping(
        from points: (CGPoint, CGPoint, CGPoint)
    ) -> CGAffineTransform? {
        let transform = CGAffineTransform(
            a: points.1.x - points.0.x, b: points.1.y - points.0.y,
            c: points.2.x - points.0.x, d: points.2.y - points.0.y,
            tx: points.0.x, ty: points.0.y
        )
        let determinant = transform.a * transform.d - transform.b * transform.c
        guard abs(determinant) > 1e-9 else {
            return nil
        }
        return transform.inverted()
    }
}
