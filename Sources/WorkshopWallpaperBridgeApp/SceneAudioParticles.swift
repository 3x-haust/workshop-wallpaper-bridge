import AppKit
import CoreImage

/// Bounded 2D particle playback. Uses package sprites and authored operator
/// settings; the turbulence field is a local implementation, not engine parity.
@MainActor
final class SceneAudioParticles {
    private struct Trail {
        var position: CGPoint
        var age: Double
        var velocity: CGPoint
        let lifetime: Double
        let size: Double
        let alpha: Double
        let layer: CALayer
    }
    private struct Point {
        var position: CGPoint
        var velocity: CGPoint = .zero
        var age: Double
        let lifetime: Double
        let phase: Double
        let size: Double
        let alpha: Double
        let alphaFrequency: Double
        let positionFrequency: Double
        let sizeFrequency: Double
        let layer: CALayer
        var trails: [Trail] = []
        var trailClock: Double = 0
    }
    let layer = CALayer()
    private var points: [Point] = []
    private let operators: [[String: Any]]
    private let drag: Double
    private let radius: Double
    private let minimumRadius: Double
    private let directions: [Double]
    private let fadeIn: Double
    private let fadeOut: Double
    private let trailLifetime: Double
    private let trailRate: Double
    private let trailImage: CGImage?
    private let sprite: CGImage
    private let initializers: [[String: Any]]
    private let trailSettings: [String: Any]
    private let maximumCount: Int
    private let emissionRate: Double
    private let sizeScale: Double
    private let imageContext = CIContext()
    private var emissionClock: Double = 0
    private var orphanedTrails: [Trail] = []
    private var time: Double = 0
    private var randomState: UInt64
    private(set) var motionEnergy: Double = 0
    var activeParticleCount: Int { points.count }
    var activeTrailCount: Int { orphanedTrails.count + points.reduce(0) { $0 + $1.trails.count } }

    static func supports(_ settings: [String: Any], trail: Bool = false) -> Bool {
        if trail, let children = settings["children"], !(children is NSNull) {
            guard let list = children as? [Any], list.isEmpty else { return false }
        }
        let emitters = settings["emitter"] as? [[String: Any]] ?? []
        guard emitters.count == 1, emitters.first?["name"] as? String == "sphererandom" else { return false }
        let initializers = Set((settings["initializer"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })
        guard initializers.isSubset(of: ["lifetimerandom", "sizerandom", "colorrandom", "alpharandom", "velocityrandom"]) else { return false }
        let operators = Set((settings["operator"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })
        let supported: Set<String> = trail ? ["movement", "alphafade", "sizechange"] :
            ["movement", "alphafade", "oscillatealpha", "turbulence", "controlpointattract", "oscillateposition", "oscillatesize"]
        return operators.isSubset(of: supported)
    }

    init(plan: SceneMediaOverlayPlan.Particle) {
        randomState = UInt64(truncatingIfNeeded: plan.model.id) &+ 1
        let authoredOperators = plan.settings["operator"] as? [[String: Any]] ?? []
        operators = authoredOperators
        let initializers = plan.settings["initializer"] as? [[String: Any]] ?? []
        self.initializers = initializers
        trailSettings = plan.trail ?? [:]
        func op(_ name: String) -> [String: Any] { authoredOperators.first { $0["name"] as? String == name } ?? [:] }
        let emitter = (plan.settings["emitter"] as? [[String: Any]])?.first ?? [:]
        drag = max(0, Self.number(op("movement")["drag"], 1))
        radius = min(2048, max(1, Self.number(emitter["distancemax"], 256)))
        minimumRadius = min(radius, max(0, Self.number(emitter["distancemin"], 0)))
        directions = Self.vector(emitter["directions"], [1, 1, 0])
        fadeIn = min(1, max(0.001, Self.number(op("alphafade")["fadeintime"], 0.1)))
        fadeOut = min(0.999, max(0, Self.number(op("alphafade")["fadeouttime"], 0.9)))
        sizeScale = max(0.01, min(10, Self.number(plan.overrides["size"], 1)))
        let count = Int(min(128, max(1, Self.number(plan.settings["maxcount"], 20) * Self.number(plan.overrides["count"], 1))))
        maximumCount = count
        emissionRate = min(128, max(0, Self.number(emitter["rate"], 1) * Self.number(plan.overrides["rate"], 1)))
        let trailInitializers = plan.trail?["initializer"] as? [[String: Any]] ?? []
        let trailLife = trailInitializers.first { $0["name"] as? String == "lifetimerandom" } ?? [:]
        trailLifetime = max(0.1, min(5, Self.number(trailLife["max"], 1)))
        trailRate = max(0, min(30, Self.number((plan.trail?["emitter"] as? [[String: Any]])?.first?["rate"], 10)))
        let tint = Self.vector(plan.overrides["colorn"], [1, 1, 1])
        let context = CIContext()
        func tinted(_ image: CGImage) -> CGImage? {
            let input = CIImage(cgImage: image)
            let brightness = min(4, max(0, Self.number(plan.overrides["brightness"], 1)))
            let result = input.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: tint[0] * brightness, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: tint[1] * brightness, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: tint[2] * brightness, w: 0)])
            return context.createCGImage(result, from: input.extent)
        }
        sprite = tinted(plan.sprite) ?? plan.sprite
        trailImage = plan.trailSprite.flatMap(tinted)
        let warmup = min(60, max(0, Self.number(plan.settings["starttime"], 0)))
        for _ in 0..<Int(warmup * 30) { step(seconds: 1.0 / 30, spectrum: WallpaperAudioSpectrum()) }
    }

    private func emit() {
        func entry(_ name: String) -> [String: Any] { initializers.first { $0["name"] as? String == name } ?? [:] }
        func op(_ name: String) -> [String: Any] { operators.first { $0["name"] as? String == name } ?? [:] }
        let target = CALayer(); target.contents = randomColorImage(sprite, definition: entry("colorrandom")); target.magnificationFilter = .nearest
        target.compositingFilter = "screenBlendMode"; layer.addSublayer(target)
        let life = max(0.1, min(120, sample(entry("lifetimerandom"), minimum: 3, maximum: 25)))
        let size = max(0.1, min(1024, sample(entry("sizerandom"), minimum: 3, maximum: 8))) * sizeScale
        let velocity = entry("velocityrandom")
        let low = Self.vector(velocity["min"], [0, 0, 0]), high = Self.vector(velocity["max"], [0, 0, 0])
        points.append(Point(position: spawnPosition(), velocity: CGPoint(x: low[0] + (high[0] - low[0]) * random(), y: low[1] + (high[1] - low[1]) * random()), age: 0, lifetime: life,
            phase: random() * .pi * 2, size: size,
            alpha: min(1, max(0, sample(entry("alpharandom"), minimum: 1, maximum: 1))),
            alphaFrequency: frequency(op("oscillatealpha"), default: 1), positionFrequency: frequency(op("oscillateposition"), default: 1),
            sizeFrequency: frequency(op("oscillatesize"), default: 1), layer: target))
    }
    private func randomColorImage(_ image: CGImage, definition: [String: Any]) -> CGImage {
        guard !definition.isEmpty else { return image }
        let low = Self.vector(definition["min"], [255, 255, 255]), high = Self.vector(definition["max"], [255, 255, 255])
        let tint = (0..<3).map { min(1, max(0, (low[$0] + (high[$0] - low[$0]) * random()) / 255)) }
        let input = CIImage(cgImage: image)
        let output = input.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: tint[0], y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: tint[1], z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: tint[2], w: 0)])
        return imageContext.createCGImage(output, from: input.extent) ?? image
    }
    private func sample(_ definition: [String: Any], minimum: Double, maximum: Double) -> Double {
        let low = Self.number(definition["min"], minimum), high = Self.number(definition["max"], maximum)
        return low + (high - low) * pow(random(), min(16, max(0.01, Self.number(definition["exponent"], 1))))
    }
    private func retireExpiredPoints() {
        for point in points where point.age >= point.lifetime {
            point.layer.removeFromSuperlayer()
            orphanedTrails.append(contentsOf: point.trails)
        }
        points.removeAll { $0.age >= $0.lifetime }
    }

    func step(seconds: Double, spectrum: WallpaperAudioSpectrum, cursor: CGPoint? = nil) {
        let dt = seconds.isFinite ? min(0.1, max(0, seconds)) : 0; time += dt
        motionEnergy = 0
        retireExpiredPoints()
        emissionClock += dt * emissionRate
        let births = min(maximumCount - points.count, Int(emissionClock + 1e-9))
        emissionClock -= floor(emissionClock + 1e-9)
        for _ in 0..<births { emit() }
        for i in points.indices {
            points[i].age += dt
            let phase = points[i].phase
            let gravity = Self.vector(operators.first { $0["name"] as? String == "movement" }?["gravity"], [0, 0, 0])
            var force = CGPoint(x: gravity[0], y: gravity[1])
            for op in operators where op["name"] as? String == "turbulence" {
                let minimum = Self.number(op["speedmin"], 0), maximum = Self.number(op["speedmax"], 10)
                let speed = minimum + (maximum - minimum) * (0.5 + 0.5 * sin(phase))
                let audio = Self.number(op["audioprocessingmode"], 0) > 0 ? audioLevel(spectrum, op) : 1
                let scale = Self.number(op["scale"], 0.01), rate = Self.number(op["timescale"], 1)
                force.x += sin(points[i].position.y * scale + time * rate * 0.1 + phase) * speed * audio
                force.y += cos(points[i].position.x * scale + time * rate * 0.1 + phase) * speed * audio
            }
            if let cursor, let attract = operators.first(where: { $0["name"] as? String == "controlpointattract" }) {
                let dx = cursor.x - points[i].position.x, dy = cursor.y - points[i].position.y
                let distance = hypot(dx, dy), threshold = max(1, Self.number(attract["threshold"], 64))
                if distance > 0.001 && distance < threshold {
                    let strength = Self.number(attract["scale"], 0) * (1 - distance / threshold) / distance
                    force.x += dx * strength; force.y += dy * strength
                }
            }
            let damping = exp(-drag * dt)
            points[i].velocity.x = (points[i].velocity.x + force.x * dt) * damping
            points[i].velocity.y = (points[i].velocity.y + force.y * dt) * damping
            points[i].position.x += points[i].velocity.x * dt
            points[i].position.y += points[i].velocity.y * dt
            motionEnergy += hypot(points[i].velocity.x, points[i].velocity.y)
            let life = points[i].age / points[i].lifetime
            let fade = min(1, min(life / fadeIn, (1 - life) / (1 - fadeOut)))
            let alpha = oscillation("oscillatealpha", points[i].alphaFrequency, phase, 1)
            let size = max(0, min(4096, points[i].size * oscillation("oscillatesize", points[i].sizeFrequency, phase, 1)))
            let offset = oscillation("oscillateposition", points[i].positionFrequency, phase, 0)
            let position = CGPoint(x: points[i].position.x + sin(phase) * offset, y: points[i].position.y + cos(phase) * offset)
            points[i].layer.opacity = Float(max(0, min(1, points[i].alpha * fade * alpha)))
            points[i].layer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            points[i].layer.position = position
            points[i].trailClock += dt
            if let trailImage, trailRate > 0, points[i].trailClock >= 1 / trailRate, points[i].trails.count < 10,
               activeTrailCount < maximumCount * 10 {
                points[i].trailClock -= 1 / trailRate
                let definitions = trailSettings["initializer"] as? [[String: Any]] ?? []
                func entry(_ name: String) -> [String: Any] { definitions.first { $0["name"] as? String == name } ?? [:] }
                let lifetime = max(0.1, min(5, sample(entry("lifetimerandom"), minimum: 0.5, maximum: trailLifetime)))
                let size = max(0, min(1024, sample(entry("sizerandom"), minimum: 20, maximum: 50))) * sizeScale
                let alpha = min(1, max(0, sample(entry("alpharandom"), minimum: 0.2, maximum: 0.4)))
                let velocity = entry("velocityrandom")
                let low = Self.vector(velocity["min"], [-5, -5, 0]), high = Self.vector(velocity["max"], [5, 5, 0])
                let target = CALayer(); target.contents = randomColorImage(trailImage, definition: entry("colorrandom")); target.position = position
                target.compositingFilter = "screenBlendMode"; layer.insertSublayer(target, at: 0)
                points[i].trails.append(Trail(position: position, age: 0,
                    velocity: CGPoint(x: low[0] + (high[0] - low[0]) * random(), y: low[1] + (high[1] - low[1]) * random()),
                    lifetime: lifetime, size: size, alpha: alpha, layer: target))
            }
            for j in points[i].trails.indices { advanceTrail(&points[i].trails[j], dt: dt) }
            points[i].trails.removeAll { $0.age >= $0.lifetime }
        }
        for i in orphanedTrails.indices { advanceTrail(&orphanedTrails[i], dt: dt) }
        orphanedTrails.removeAll { $0.age >= $0.lifetime }
        retireExpiredPoints()
    }
    private func advanceTrail(_ trail: inout Trail, dt: Double) {
        let operators = trailSettings["operator"] as? [[String: Any]] ?? []
        func op(_ name: String) -> [String: Any] { operators.first { $0["name"] as? String == name } ?? [:] }
        trail.age += dt
        let fraction = min(1, trail.age / trail.lifetime)
        let fade = op("alphafade"), movement = op("movement"), sizeChange = op("sizechange")
        let fadeIn = min(1, max(0.001, Self.number(fade["fadeintime"], 0.1)))
        let fadeOut = min(0.999, max(0, Self.number(fade["fadeouttime"], 0.9)))
        trail.layer.opacity = Float(trail.alpha * min(1, min(fraction / fadeIn, (1 - fraction) / (1 - fadeOut))))
        let gravity = Self.vector(movement["gravity"], [0, 0, 0])
        let damping = exp(-max(0, Self.number(movement["drag"], 0)) * dt)
        trail.velocity.x = (trail.velocity.x + gravity[0] * dt) * damping
        trail.velocity.y = (trail.velocity.y + gravity[1] * dt) * damping
        trail.position.x += trail.velocity.x * dt; trail.position.y += trail.velocity.y * dt
        trail.layer.position = trail.position
        let startTime = Self.number(sizeChange["starttime"], 0), endTime = Self.number(sizeChange["endtime"], 1)
        let phase = min(1, max(0, (fraction - startTime) / max(0.001, endTime - startTime)))
        let startSize = Self.number(sizeChange["startvalue"], 1), endSize = Self.number(sizeChange["endvalue"], 0)
        let size = max(0, trail.size * (startSize + (endSize - startSize) * phase))
        trail.layer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        if fraction >= 1 { trail.layer.removeFromSuperlayer() }
    }
    private func audioLevel(_ spectrum: WallpaperAudioSpectrum, _ op: [String: Any]) -> Double {
        let start = Int(min(63, max(0, Self.number(op["audioprocessingfrequencystart"], 0))))
        let end = Int(min(63, max(Double(start), Self.number(op["audioprocessingfrequencyend"], 63))))
        let bands = Array(zip(spectrum.left, spectrum.right))
        guard bands.count > end else { return 0 }
        let mean = (start...end).reduce(0.0) { $0 + max(0, min(1, Double(bands[$1].0 + bands[$1].1) / 2)) } / Double(end - start + 1)
        return pow(mean, max(0.1, min(8, Self.number(op["audioprocessingexponent"], 1))))
    }
    private func oscillation(_ name: String, _ frequency: Double, _ phase: Double, _ fallback: Double) -> Double {
        guard let op = operators.first(where: { $0["name"] as? String == name }) else { return fallback }
        let minimum = Self.number(op["scalemin"], fallback), maximum = Self.number(op["scalemax"], 1)
        return minimum + (maximum - minimum) * (0.5 + 0.5 * sin(time * frequency + phase))
    }
    private func frequency(_ op: [String: Any], default fallback: Double) -> Double {
        let minimum = Self.number(op["frequencymin"], fallback), maximum = Self.number(op["frequencymax"], max(minimum, fallback))
        return minimum + random() * max(0, maximum - minimum)
    }
    private func spawnPosition() -> CGPoint {
        let angle = random() * .pi * 2
        let distance = minimumRadius + random() * (radius - minimumRadius)
        return CGPoint(x: cos(angle) * distance * directions[0], y: sin(angle) * distance * directions[1])
    }
    private func random() -> Double {
        randomState = randomState &* 6364136223846793005 &+ 1
        return Double(randomState >> 11) / Double(UInt64.max >> 11)
    }
    private static func number(_ value: Any?, _ fallback: Double) -> Double {
        min(100_000, max(-100_000, SceneMediaOverlayPlan.number(value, fallback)))
    }
    private static func vector(_ value: Any?, _ fallback: [Double]) -> [Double] {
        let v = (value as? String)?.split(separator: " ").compactMap { Double($0) } ?? fallback
        return v.count == 3 && v.allSatisfy({ $0.isFinite && abs($0) <= 1e7 }) ? v : fallback
    }
}
