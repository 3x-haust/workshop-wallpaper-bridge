import AppKit
import QuartzCore

struct SceneTick: Equatable {
    let elapsedTime: TimeInterval
    let frameTime: TimeInterval
}

struct SceneTickClock {
    private(set) var elapsedTime: TimeInterval = 0
    private(set) var frameTime: TimeInterval = 1.0 / 60.0
    private(set) var isSuspended = false
    private(set) var isInvalidated = false

    mutating func advance(by delta: TimeInterval) -> SceneTick? {
        guard !isSuspended, !isInvalidated, delta > 0 else {
            return nil
        }
        frameTime = delta
        elapsedTime += delta
        return SceneTick(elapsedTime: elapsedTime, frameTime: frameTime)
    }

    mutating func suspend() {
        isSuspended = true
    }

    mutating func resume() {
        guard !isInvalidated else {
            return
        }
        isSuspended = false
    }

    mutating func reset() {
        elapsedTime = 0
        frameTime = 1.0 / 60.0
        isSuspended = false
    }

    mutating func invalidate() {
        isInvalidated = true
        isSuspended = true
    }
}

@MainActor
protocol SceneTickSource: AnyObject {
    var elapsedTime: TimeInterval { get }
    var frameTime: TimeInterval { get }
    var isRunning: Bool { get }
    var onTick: ((SceneTick) -> Void)? { get set }

    func start()
    func stop()
    func suspend()
    func resume()
    func reset()
    func invalidate()
}

@MainActor
final class CADisplayLinkSceneTickSource: SceneTickSource {
    private var clock = SceneTickClock()
    private var displayLink: CADisplayLink?
    private var lastTimestamp: TimeInterval?

    var onTick: ((SceneTick) -> Void)?

    var elapsedTime: TimeInterval {
        clock.elapsedTime
    }

    var frameTime: TimeInterval {
        clock.frameTime
    }

    var isRunning: Bool {
        displayLink != nil
    }

    func start() {
        guard displayLink == nil, !clock.isInvalidated else {
            return
        }
        guard let displayLink = NSScreen.main?.displayLink(
            target: self,
            selector: #selector(handleDisplayLink(_:))
        ) else {
            return
        }
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = nil
    }

    func suspend() {
        clock.suspend()
        displayLink?.isPaused = true
        lastTimestamp = nil
    }

    func resume() {
        clock.resume()
        lastTimestamp = nil
        displayLink?.isPaused = false
    }

    func reset() {
        stop()
        clock.reset()
    }

    func invalidate() {
        stop()
        clock.invalidate()
        onTick = nil
    }

    @objc
    private func handleDisplayLink(_ displayLink: CADisplayLink) {
        let delta: TimeInterval
        if let lastTimestamp {
            delta = displayLink.timestamp - lastTimestamp
        } else {
            delta = displayLink.duration
        }
        self.lastTimestamp = displayLink.timestamp
        guard let tick = clock.advance(by: delta) else {
            return
        }
        onTick?(tick)
    }
}
