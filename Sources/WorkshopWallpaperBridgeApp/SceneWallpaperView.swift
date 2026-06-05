import AppKit
import WorkshopWallpaperCore

@MainActor
final class SceneWallpaperView: NSView,
    PausableWallpaperContent,
    DisplayModeUpdatableContent,
    WallpaperContentLifecycle {
    private var plan: SceneRenderPlan
    private var displayMode: WallpaperDisplayMode
    private let previewLayer = CALayer()
    private let sceneLayer = CALayer()
    private var contentLayers: [CALayer] = []
    private var dynamicTextLayers: [(layer: CATextLayer, text: SceneTextLayer)] = []
    private var textRefreshTimer: Timer?
    private var decodeTask: Task<Void, Never>?
    private var isSuspended = false
    private var isClosed = false

    init(url: URL, previewURL: URL?, frame: CGRect, displayMode: WallpaperDisplayMode) throws {
        plan = try SceneRenderPlanBuilder().buildLayout(url: url)
        self.displayMode = displayMode
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        configurePreviewLayer(previewURL: previewURL)
        layer?.addSublayer(previewLayer)
        layer?.addSublayer(sceneLayer)
        configureSceneLayer()
        layoutScene()
        startTextureDecode(url: url)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        layoutScene()
    }

    func setPlaybackSuspended(_ suspended: Bool) {
        guard suspended != isSuspended else {
            return
        }
        isSuspended = suspended
        setLayerTreePaused(suspended)
    }

    func setDisplayMode(_ displayMode: WallpaperDisplayMode) {
        self.displayMode = displayMode
        layoutScene()
    }

    func prepareForClose() {
        isClosed = true
        decodeTask?.cancel()
        decodeTask = nil
        sceneLayer.removeAllAnimations()
        contentLayers.forEach {
            $0.removeAllAnimations()
            $0.removeFromSuperlayer()
        }
        contentLayers = []
        dynamicTextLayers = []
        textRefreshTimer?.invalidate()
        textRefreshTimer = nil
    }

    private func configureSceneLayer() {
        sceneLayer.backgroundColor = nil
        sceneLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        sceneLayer.bounds = CGRect(
            x: 0,
            y: 0,
            width: plan.canvasSize.width,
            height: plan.canvasSize.height
        )
    }

    private func configurePreviewLayer(previewURL: URL?) {
        previewLayer.backgroundColor = NSColor.black.cgColor
        previewLayer.contentsGravity = WallpaperContentLayout.imageContentsGravity(for: displayMode)
        previewLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        previewLayer.minificationFilter = .linear
        previewLayer.magnificationFilter = .linear
        guard let previewURL,
              let image = NSImage(contentsOf: previewURL),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }
        previewLayer.contents = cgImage
    }

    private func startTextureDecode(url: URL) {
        decodeTask = Task { [weak self, url] in
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try SceneRenderPlanBuilder().build(url: url)
                }
            }.value
            guard !Task.isCancelled else {
                return
            }
            self?.applyDecodedPlan(result)
        }
    }

    private func applyDecodedPlan(_ result: Result<SceneRenderPlan, Error>) {
        guard !isClosed, case .success(let decodedPlan) = result else {
            return
        }
        plan = decodedPlan
        contentLayers.forEach {
            $0.removeAllAnimations()
            $0.removeFromSuperlayer()
        }
        contentLayers = []
        dynamicTextLayers = []
        textRefreshTimer?.invalidate()
        textRefreshTimer = nil
        buildLayers()
        layoutScene()
        if isSuspended {
            setLayerTreePaused(true)
        }
    }

    private func buildLayers() {
        var sceneWideEffects: [SceneLayerEffect] = []
        for layerPlan in plan.layers {
            if layerPlan.isEffectOnly {
                sceneWideEffects.append(contentsOf: layerPlan.effects)
                continue
            }
            let contentLayer: CALayer
            if let text = layerPlan.text {
                let textLayer = CATextLayer()
                textLayer.string = string(for: text)
                textLayer.fontSize = text.pointSize
                textLayer.foregroundColor = Self.cgColor(from: text.color)
                textLayer.alignmentMode = Self.textAlignmentMode(for: text.horizontalAlignment)
                textLayer.isWrapped = true
                textLayer.truncationMode = .none
                textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
                if text.dynamicText != nil {
                    dynamicTextLayers.append((layer: textLayer, text: text))
                }
                contentLayer = textLayer
            } else {
                guard let texture = plan.textures[layerPlan.texturePath],
                      let image = Self.cgImage(from: texture) else {
                    continue
                }
                let imageLayer = CALayer()
                imageLayer.contents = image
                imageLayer.contentsGravity = .resize
                imageLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
                imageLayer.minificationFilter = .linear
                imageLayer.magnificationFilter = .linear
                addEffectAnimations(to: imageLayer, plan: layerPlan)
                contentLayer = imageLayer
            }
            contentLayer.name = layerPlan.name
            contentLayer.opacity = Float(max(0, min(layerPlan.alpha, 1)))
            configure(contentLayer, with: layerPlan)
            sceneLayer.addSublayer(contentLayer)
            contentLayers.append(contentLayer)
        }
        addSceneWideEffectAnimations(sceneWideEffects)
        configureTextRefreshTimer()
    }

    private func configureTextRefreshTimer() {
        textRefreshTimer?.invalidate()
        textRefreshTimer = nil
        guard !dynamicTextLayers.isEmpty else {
            return
        }
        refreshDynamicTextLayers()
        textRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDynamicTextLayers()
            }
        }
    }

    private func refreshDynamicTextLayers(date: Date = Date()) {
        guard !isClosed else {
            return
        }
        for item in dynamicTextLayers {
            item.layer.string = string(for: item.text, date: date)
        }
    }

    private func string(for text: SceneTextLayer, date: Date = Date()) -> String {
        switch text.dynamicText {
        case .clock(let clock):
            return clock.string(for: date)
        case nil:
            return text.value
        }
    }

    private func configure(_ layer: CALayer, with plan: SceneLayer) {
        let width = max(1, abs(plan.size.width))
        let height = max(1, abs(plan.size.height))
        layer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        layer.position = CGPoint(x: plan.origin.x, y: plan.origin.y)
        layer.zPosition = plan.origin.z
        layer.transform = staticTransform(for: plan)
        addOriginAnimation(to: layer, plan: plan)
        addScaleAnimations(to: layer, plan: plan)
        addAngleAnimation(to: layer, plan: plan)
        addAlphaAnimation(to: layer, plan: plan)
    }

    private func staticTransform(for plan: SceneLayer) -> CATransform3D {
        let scaled = CATransform3DMakeScale(plan.scale.x, plan.scale.y, 1)
        return CATransform3DRotate(scaled, Self.radians(fromDegrees: plan.angles.z), 0, 0, 1)
    }

    private func addOriginAnimation(to layer: CALayer, plan: SceneLayer) {
        guard let animation = plan.originAnimation else {
            return
        }
        let keyframe = CAKeyframeAnimation(keyPath: "position")
        configure(keyframe, duration: animation.duration)
        keyframe.values = animation.keyframes.map { frame in
            let value = animation.isRelative
                ? SceneVector3(
                    x: plan.origin.x + frame.value.x,
                    y: plan.origin.y + frame.value.y,
                    z: plan.origin.z + frame.value.z
                )
                : frame.value
            return CGPoint(x: value.x, y: value.y)
        }
        keyframe.keyTimes = keyTimes(for: animation)
        layer.add(keyframe, forKey: "scene-origin")
    }

    private func addScaleAnimations(to layer: CALayer, plan: SceneLayer) {
        guard let animation = plan.scaleAnimation else {
            return
        }
        let xAnimation = CAKeyframeAnimation(keyPath: "transform.scale.x")
        configure(xAnimation, duration: animation.duration)
        xAnimation.values = animation.keyframes.map { frame in
            animation.isRelative ? plan.scale.x + frame.value.x : frame.value.x
        }
        xAnimation.keyTimes = keyTimes(for: animation)
        layer.add(xAnimation, forKey: "scene-scale-x")

        let yAnimation = CAKeyframeAnimation(keyPath: "transform.scale.y")
        configure(yAnimation, duration: animation.duration)
        yAnimation.values = animation.keyframes.map { frame in
            animation.isRelative ? plan.scale.y + frame.value.y : frame.value.y
        }
        yAnimation.keyTimes = keyTimes(for: animation)
        layer.add(yAnimation, forKey: "scene-scale-y")
    }

    private func addAngleAnimation(to layer: CALayer, plan: SceneLayer) {
        guard let animation = plan.angleAnimation else {
            return
        }
        let keyframe = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        configure(keyframe, duration: animation.duration)
        keyframe.values = animation.keyframes.map { frame in
            let degrees = animation.isRelative ? plan.angles.z + frame.value.z : frame.value.z
            return Self.radians(fromDegrees: degrees)
        }
        keyframe.keyTimes = keyTimes(for: animation)
        layer.add(keyframe, forKey: "scene-angle-z")
    }

    private func addAlphaAnimation(to layer: CALayer, plan: SceneLayer) {
        guard let animation = plan.alphaAnimation else {
            return
        }
        let keyframe = CAKeyframeAnimation(keyPath: "opacity")
        configure(keyframe, duration: animation.duration)
        keyframe.values = animation.keyframes.map { frame in
            let opacity = animation.isRelative ? plan.alpha + frame.value : frame.value
            return max(0, min(opacity, 1))
        }
        keyframe.keyTimes = keyTimes(for: animation)
        layer.add(keyframe, forKey: "scene-alpha")
    }

    private func addSceneWideEffectAnimations(_ effects: [SceneLayerEffect]) {
        sceneLayer.removeAnimation(forKey: "scene-wide-water-motion")
        sceneLayer.removeAnimation(forKey: "scene-wide-shake-motion")
        sceneLayer.removeAnimation(forKey: "scene-wide-effect-rotation")
        guard !effects.isEmpty else {
            return
        }
        addEffectAnimations(to: sceneLayer, effects: effects, keyPrefix: "scene-wide", amplitude: 12)
    }

    private func addEffectAnimations(to layer: CALayer, plan: SceneLayer) {
        addEffectAnimations(to: layer, effects: plan.effects, keyPrefix: "scene", amplitude: 8)
    }

    private func addEffectAnimations(
        to layer: CALayer,
        effects: [SceneLayerEffect],
        keyPrefix: String,
        amplitude: Double
    ) {
        if effects.contains(.waterFlow) || effects.contains(.waterWaves) || effects.contains(.waterRipple) {
            let animation = CAKeyframeAnimation(keyPath: "transform.translation.y")
            configure(animation, duration: 4)
            animation.values = [-amplitude, amplitude * 0.75, -amplitude * 0.5, amplitude, -amplitude]
            animation.keyTimes = [0, 0.25, 0.5, 0.75, 1]
            layer.add(animation, forKey: "\(keyPrefix)-water-motion")
        }
        if effects.contains(.shake) {
            let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
            configure(animation, duration: 3)
            animation.values = [-5, 4, -3, 5, -5]
            animation.keyTimes = [0, 0.25, 0.5, 0.75, 1]
            layer.add(animation, forKey: "\(keyPrefix)-shake-motion")
        }
        if effects.contains(.scroll) || effects.contains(.spin) {
            let animation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            configure(animation, duration: 8)
            animation.values = [0, 0.02, -0.02, 0]
            animation.keyTimes = [0, 0.33, 0.66, 1]
            layer.add(animation, forKey: "\(keyPrefix)-effect-rotation")
        }
    }

    private func configure(_ animation: CAKeyframeAnimation, duration: Double) {
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.calculationMode = .linear
    }

    private func keyTimes(for animation: SceneVectorAnimation) -> [NSNumber] {
        animation.keyframes.map { frame in
            NSNumber(value: max(0, min(frame.time / animation.duration, 1)))
        }
    }

    private func keyTimes(for animation: SceneScalarAnimation) -> [NSNumber] {
        animation.keyframes.map { frame in
            NSNumber(value: max(0, min(frame.time / animation.duration, 1)))
        }
    }

    private func layoutScene() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.frame = bounds
        previewLayer.frame = bounds
        previewLayer.contentsGravity = WallpaperContentLayout.imageContentsGravity(for: displayMode)
        previewLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let sceneFrame = WallpaperContentLayout.scaledContentFrame(
            for: CGSize(width: plan.canvasSize.width, height: plan.canvasSize.height),
            in: bounds,
            displayMode: displayMode
        )
        sceneLayer.position = CGPoint(x: sceneFrame.midX, y: sceneFrame.midY)
        sceneLayer.bounds = CGRect(
            x: 0,
            y: 0,
            width: plan.canvasSize.width,
            height: plan.canvasSize.height
        )
        sceneLayer.setAffineTransform(transform(for: sceneFrame))
        contentLayers.forEach {
            $0.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        }
        CATransaction.commit()
    }

    private func transform(for sceneFrame: CGRect) -> CGAffineTransform {
        CGAffineTransform(
            scaleX: sceneFrame.width / max(plan.canvasSize.width, 1),
            y: sceneFrame.height / max(plan.canvasSize.height, 1)
        )
    }

    private func setLayerTreePaused(_ paused: Bool) {
        if paused {
            let pausedTime = sceneLayer.convertTime(CACurrentMediaTime(), from: nil)
            sceneLayer.speed = 0
            sceneLayer.timeOffset = pausedTime
            return
        }
        let pausedTime = sceneLayer.timeOffset
        sceneLayer.speed = 1
        sceneLayer.timeOffset = 0
        sceneLayer.beginTime = 0
        let timeSincePause = sceneLayer.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
        sceneLayer.beginTime = timeSincePause
    }

    private static func cgImage(from texture: SceneTexture) -> CGImage? {
        switch texture.storage {
        case .encodedImage(let data):
            return NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        case .rgba(let width, let height, let data):
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let provider = CGDataProvider(data: data as CFData) else {
                return nil
            }
            return CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            )
        }
    }

    private static func cgColor(from color: SceneColor) -> CGColor {
        CGColor(
            red: max(0, min(color.red, 1)),
            green: max(0, min(color.green, 1)),
            blue: max(0, min(color.blue, 1)),
            alpha: max(0, min(color.alpha, 1))
        )
    }

    private static func textAlignmentMode(for alignment: SceneTextHorizontalAlignment) -> CATextLayerAlignmentMode {
        switch alignment {
        case .left:
            return .left
        case .center:
            return .center
        case .right:
            return .right
        }
    }

    private static func radians(fromDegrees degrees: Double) -> Double {
        degrees * .pi / 180
    }
}
