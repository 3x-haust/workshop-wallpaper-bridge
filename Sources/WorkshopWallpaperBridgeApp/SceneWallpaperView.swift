import AppKit
import CoreImage
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
    private var shaderEffectLayers: [ShaderEffectLayer] = []
    private var dynamicTextLayers: [DynamicTextLayer] = []
    private var textRefreshTimer: Timer?
    private var shaderEffectTimer: Timer?
    private var shaderEffectElapsedTime: TimeInterval = 0
    private var shaderEffectResumeTime = CACurrentMediaTime()
    private var decodeTask: Task<Void, Never>?
    private var isSuspended = false
    private var isClosed = false
    private let ciContext = CIContext()

    private struct ShaderEffectLayer {
        let layer: CALayer
        let baseImage: CIImage
        let effects: [SceneLayerEffectSetting]
    }

    private struct DynamicTextLayer {
        let layer: CATextLayer
        let text: SceneTextLayer
        let scriptEvaluator: SceneScriptTextEvaluator?
    }

    private static let waterWavesWarpKernel = CIWarpKernel(source: """
    kernel vec2 waterWavesWarp(
        float time,
        float speed,
        float scale,
        float strength,
        float perspective,
        vec2 direction,
        vec4 extent
    ) {
        vec2 coord = destCoord();
        vec2 texCoord = (coord - extent.xy) / extent.zw;
        vec2 safeDirection = direction;
        float directionLength = length(safeDirection);
        if (directionLength < 0.0001) {
            safeDirection = vec2(0.0, 1.0);
        } else {
            safeDirection = safeDirection / directionLength;
        }

        float pos = abs(dot((texCoord - vec2(0.5, 0.5)), safeDirection));
        float distance = time * speed + dot(texCoord, safeDirection) * (scale + perspective * pos);
        vec2 offset = vec2(safeDirection.y, -safeDirection.x);
        float waveStrength = strength * strength + perspective * pos;
        texCoord -= sin(distance) * offset * waveStrength;

        return extent.xy + texCoord * extent.zw;
    }
    """)

    private static let scrollWarpKernel = CIWarpKernel(source: """
    kernel vec2 scrollWarp(
        float time,
        float speedX,
        float speedY,
        vec4 extent
    ) {
        vec2 coord = destCoord();
        vec2 texCoord = (coord - extent.xy) / extent.zw;
        vec2 scroll = vec2(speedX, speedY);
        scroll = sign(scroll) * scroll * scroll * time;
        texCoord = fract(texCoord + scroll);
        return extent.xy + texCoord * extent.zw;
    }
    """)

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
        if suspended {
            shaderEffectElapsedTime = currentShaderEffectTime()
        }
        isSuspended = suspended
        setLayerTreePaused(suspended)
        if suspended {
            shaderEffectTimer?.invalidate()
            shaderEffectTimer = nil
        } else {
            shaderEffectResumeTime = CACurrentMediaTime()
            startShaderEffectTimerIfNeeded()
        }
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
        shaderEffectLayers = []
        dynamicTextLayers = []
        textRefreshTimer?.invalidate()
        textRefreshTimer = nil
        shaderEffectTimer?.invalidate()
        shaderEffectTimer = nil
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
        shaderEffectLayers = []
        dynamicTextLayers = []
        textRefreshTimer?.invalidate()
        textRefreshTimer = nil
        shaderEffectTimer?.invalidate()
        shaderEffectTimer = nil
        buildLayers()
        layoutScene()
        if isSuspended {
            setLayerTreePaused(true)
        }
    }

    private func buildLayers() {
        resetShaderEffectClock()
        for layerPlan in plan.layers {
            if layerPlan.isEffectOnly {
                continue
            }
            let contentLayer: CALayer
            if let text = layerPlan.text {
                let scriptEvaluator = text.script.map { SceneScriptTextEvaluator(script: $0) }
                let textLayer = CATextLayer()
                textLayer.string = string(for: text, scriptEvaluator: scriptEvaluator)
                textLayer.fontSize = text.pointSize
                textLayer.foregroundColor = Self.cgColor(from: text.color)
                textLayer.alignmentMode = Self.textAlignmentMode(for: text.horizontalAlignment)
                textLayer.isWrapped = true
                textLayer.truncationMode = .none
                textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
                if text.dynamicText != nil || text.script != nil {
                    dynamicTextLayers.append(DynamicTextLayer(
                        layer: textLayer,
                        text: text,
                        scriptEvaluator: scriptEvaluator
                    ))
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
                registerShaderEffects(for: imageLayer, image: image, plan: layerPlan)
                contentLayer = imageLayer
            }
            contentLayer.name = layerPlan.name
            contentLayer.opacity = Float(max(0, min(layerPlan.alpha * opacityMultiplier(for: layerPlan), 1)))
            configure(contentLayer, with: layerPlan)
            sceneLayer.addSublayer(contentLayer)
            contentLayers.append(contentLayer)
        }
        configureTextRefreshTimer()
        startShaderEffectTimerIfNeeded()
    }

    private func configureTextRefreshTimer() {
        textRefreshTimer?.invalidate()
        textRefreshTimer = nil
        guard !dynamicTextLayers.isEmpty else {
            return
        }
        let interval = dynamicTextLayers.contains { $0.scriptEvaluator != nil }
            ? 1.0 / 24.0
            : 1
        refreshDynamicTextLayers(frameTime: interval)
        textRefreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDynamicTextLayers(frameTime: interval)
            }
        }
    }

    private func refreshDynamicTextLayers(date: Date = Date(), frameTime: TimeInterval = 1) {
        guard !isClosed else {
            return
        }
        for item in dynamicTextLayers {
            item.layer.string = string(
                for: item.text,
                scriptEvaluator: item.scriptEvaluator,
                date: date,
                frameTime: frameTime
            )
        }
    }

    private func string(
        for text: SceneTextLayer,
        scriptEvaluator: SceneScriptTextEvaluator? = nil,
        date: Date = Date(),
        frameTime: TimeInterval = 1.0 / 24.0
    ) -> String {
        let fallback: String
        switch text.dynamicText {
        case .clock(let clock):
            fallback = clock.string(for: date)
        case nil:
            fallback = text.value
        }
        guard let scriptEvaluator else {
            return fallback
        }
        return scriptEvaluator.string(
            currentValue: fallback,
            date: date,
            runtime: SceneScriptRuntime(time: currentShaderEffectTime(), frameTime: frameTime)
        )
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
        addLayerEffectAnimations(to: layer, plan: plan)
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
        let opacityEffect = opacityMultiplier(for: plan)
        keyframe.values = animation.keyframes.map { frame in
            let opacity = animation.isRelative ? plan.alpha + frame.value : frame.value
            return max(0, min(opacity * opacityEffect, 1))
        }
        keyframe.keyTimes = keyTimes(for: animation)
        layer.add(keyframe, forKey: "scene-alpha")
    }

    private func addLayerEffectAnimations(to layer: CALayer, plan: SceneLayer) {
        for effect in plan.effectSettings where Self.shouldAnimateLayerEffect(
            effect.effect,
            hasAngleAnimation: plan.angleAnimation != nil,
            hasAlphaAnimation: plan.alphaAnimation != nil
        ) {
            switch effect.effect {
            case .shake:
                addShakeEffectAnimation(to: layer, effect: effect)
            case .spin:
                addSpinEffectAnimation(to: layer, effect: effect)
            case .shine:
                addShineEffectAnimation(to: layer, effect: effect)
            case .waterFlow, .waterWaves, .waterRipple, .scroll, .opacity:
                continue
            }
        }
    }

    private func addShakeEffectAnimation(to layer: CALayer, effect: SceneLayerEffectSetting) {
        let offsets = Self.shakeOffsets(for: effect, layerSize: layer.bounds.size)
        guard offsets.contains(where: { abs($0.x) > 0.000_001 || abs($0.y) > 0.000_001 }) else {
            return
        }
        let keyframe = CAKeyframeAnimation(keyPath: "position")
        configure(keyframe, duration: Self.layerEffectDuration(for: effect, defaultDuration: 0.8))
        keyframe.isAdditive = true
        keyframe.values = offsets.map { CGPoint(x: $0.x, y: $0.y) }
        keyframe.keyTimes = [0, 0.25, 0.5, 0.75, 1]
        layer.add(keyframe, forKey: "scene-effect-shake")
    }

    private func addSpinEffectAnimation(to layer: CALayer, effect: SceneLayerEffectSetting) {
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.byValue = CGFloat.pi * 2
        animation.duration = Self.layerEffectDuration(for: effect, defaultDuration: 8)
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        layer.add(animation, forKey: "scene-effect-spin")
    }

    private func addShineEffectAnimation(to layer: CALayer, effect: SceneLayerEffectSetting) {
        let baseOpacity = Double(layer.opacity)
        guard baseOpacity > 0 else {
            return
        }
        let strength = max(0, min(effect.strength ?? 0.35, 1))
        let low = max(0, min(baseOpacity * (1 - (strength * 0.35)), 1))
        let high = max(0, min(baseOpacity * (1 + (strength * 0.2)), 1))
        let keyframe = CAKeyframeAnimation(keyPath: "opacity")
        configure(keyframe, duration: Self.layerEffectDuration(for: effect, defaultDuration: 2.5))
        keyframe.values = [baseOpacity, high, low, baseOpacity]
        keyframe.keyTimes = [0, 0.35, 0.7, 1]
        layer.add(keyframe, forKey: "scene-effect-shine")
    }

    private func opacityMultiplier(for plan: SceneLayer) -> Double {
        guard let opacity = plan.effectSettings.last(where: { $0.effect == .opacity }) else {
            return 1
        }
        return max(0, min(opacity.strength ?? 1, 1))
    }

    private func configure(_ animation: CAKeyframeAnimation, duration: Double) {
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.calculationMode = .linear
    }

    private func registerShaderEffects(for layer: CALayer, image: CGImage, plan: SceneLayer) {
        let effects = Self.shaderRenderableEffects(from: plan.effectSettings)
        guard !effects.isEmpty else {
            return
        }
        shaderEffectLayers.append(ShaderEffectLayer(
            layer: layer,
            baseImage: CIImage(cgImage: image),
            effects: effects
        ))
    }

    private func startShaderEffectTimerIfNeeded() {
        guard !isClosed, !isSuspended, !shaderEffectLayers.isEmpty, shaderEffectTimer == nil else {
            return
        }
        refreshShaderEffectLayers()
        shaderEffectTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshShaderEffectLayers()
            }
        }
    }

    private func refreshShaderEffectLayers() {
        guard !isClosed, !isSuspended else {
            return
        }
        let time = currentShaderEffectTime()
        for item in shaderEffectLayers {
            guard let image = Self.renderShaderEffects(
                baseImage: item.baseImage,
                effects: item.effects,
                time: time,
                context: ciContext
            ) else {
                continue
            }
            item.layer.contents = image
        }
    }

    private func resetShaderEffectClock() {
        shaderEffectElapsedTime = 0
        shaderEffectResumeTime = CACurrentMediaTime()
    }

    private func currentShaderEffectTime() -> TimeInterval {
        Self.shaderEffectTime(
            elapsedTime: shaderEffectElapsedTime,
            resumeTime: shaderEffectResumeTime,
            now: CACurrentMediaTime(),
            isSuspended: isSuspended
        )
    }

    nonisolated static func shaderEffectTime(
        elapsedTime: TimeInterval,
        resumeTime: TimeInterval,
        now: TimeInterval,
        isSuspended: Bool
    ) -> TimeInterval {
        if isSuspended {
            return elapsedTime
        }
        return elapsedTime + max(0, now - resumeTime)
    }

    private static func renderShaderEffects(
        baseImage: CIImage,
        effects: [SceneLayerEffectSetting],
        time: Double,
        context: CIContext
    ) -> CGImage? {
        var image = baseImage
        for effect in effects {
            switch effect.effect {
            case .waterFlow, .waterWaves, .waterRipple:
                image = applyWaterWaves(to: image, effect: effect, time: time) ?? image
            case .scroll:
                image = applyScroll(to: image, effect: effect, time: time) ?? image
            case .shake, .spin, .shine, .opacity:
                continue
            }
        }
        return context.createCGImage(image, from: baseImage.extent)
    }

    nonisolated static func shaderRenderableEffects(
        from effects: [SceneLayerEffectSetting]
    ) -> [SceneLayerEffectSetting] {
        effects.filter { setting in
            switch setting.effect {
            case .waterFlow, .waterWaves, .waterRipple, .scroll:
                return true
            case .shake, .spin, .shine, .opacity:
                return false
            }
        }
    }

    nonisolated static func isLayerAnimatedEffect(_ effect: SceneLayerEffect) -> Bool {
        switch effect {
        case .shake, .spin, .shine:
            return true
        case .waterFlow, .waterWaves, .waterRipple, .scroll, .opacity:
            return false
        }
    }

    nonisolated static func shouldAnimateLayerEffect(
        _ effect: SceneLayerEffect,
        hasAngleAnimation: Bool,
        hasAlphaAnimation: Bool
    ) -> Bool {
        guard isLayerAnimatedEffect(effect) else {
            return false
        }
        switch effect {
        case .spin:
            return !hasAngleAnimation
        case .shine:
            return !hasAlphaAnimation
        case .shake:
            return true
        case .waterFlow, .waterWaves, .waterRipple, .scroll, .opacity:
            return false
        }
    }

    nonisolated static func layerEffectDuration(
        for effect: SceneLayerEffectSetting,
        defaultDuration: Double
    ) -> Double {
        guard let speed = effect.speed, abs(speed) > 0.000_001 else {
            return defaultDuration
        }
        return max(0.1, defaultDuration / abs(speed))
    }

    nonisolated static func shakeOffsets(
        for effect: SceneLayerEffectSetting,
        layerSize: CGSize
    ) -> [(x: Double, y: Double)] {
        let strength = max(0, min(effect.strength ?? 0.08, 1))
        let amplitude = min(max(layerSize.width, layerSize.height) * strength * 0.1, 32)
        guard amplitude > 0 else {
            return Array(repeating: (0, 0), count: 5)
        }
        let direction = normalizedDirection(effect.direction)
        let perpendicular = (x: direction.y, y: -direction.x)
        return [
            (0, 0),
            (perpendicular.x * amplitude, perpendicular.y * amplitude),
            (-perpendicular.x * amplitude * 0.75, -perpendicular.y * amplitude * 0.75),
            (perpendicular.x * amplitude * 0.5, perpendicular.y * amplitude * 0.5),
            (0, 0)
        ]
    }

    private static func applyWaterWaves(
        to image: CIImage,
        effect: SceneLayerEffectSetting,
        time: Double
    ) -> CIImage? {
        guard let kernel = waterWavesWarpKernel else {
            return image
        }
        let direction = normalizedDirection(effect.direction)
        let extent = image.extent
        return kernel.apply(
            extent: extent,
            roiCallback: { _, rect in rect.insetBy(dx: -48, dy: -48) },
            image: image,
            arguments: [
                CGFloat(time),
                CGFloat(effect.speed ?? 1),
                CGFloat(effect.scale ?? 40),
                CGFloat(max(0, min(effect.strength ?? 0.05, 1))),
                CGFloat(max(0, min(effect.perspective ?? 0, 0.2))),
                CIVector(x: direction.x, y: direction.y),
                CIVector(x: extent.origin.x, y: extent.origin.y, z: extent.width, w: extent.height)
            ]
        )
    }

    private static func applyScroll(
        to image: CIImage,
        effect: SceneLayerEffectSetting,
        time: Double
    ) -> CIImage? {
        guard let kernel = scrollWarpKernel else {
            return image
        }
        let extent = image.extent
        let scroll = scrollAxisSpeeds(for: effect)
        return kernel.apply(
            extent: extent,
            roiCallback: { _, rect in rect },
            image: image,
            arguments: [
                CGFloat(time),
                CGFloat(scroll.x),
                CGFloat(scroll.y),
                CIVector(x: extent.origin.x, y: extent.origin.y, z: extent.width, w: extent.height)
            ]
        )
    }

    nonisolated static func scrollAxisSpeeds(for effect: SceneLayerEffectSetting) -> (x: Double, y: Double) {
        if effect.speedX != nil || effect.speedY != nil {
            return (effect.speedX ?? 0, effect.speedY ?? 0)
        }
        let direction = normalizedDirection(effect.direction)
        let speed = effect.speed ?? 0
        return (direction.x * speed, direction.y * speed)
    }

    nonisolated private static func normalizedDirection(_ direction: SceneVector3?) -> SceneVector3 {
        guard let direction else {
            return SceneVector3(x: 0, y: 1, z: 0)
        }
        let length = sqrt((direction.x * direction.x) + (direction.y * direction.y))
        guard length > 0.000_001 else {
            return SceneVector3(x: 0, y: 1, z: 0)
        }
        return SceneVector3(x: direction.x / length, y: direction.y / length, z: 0)
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
