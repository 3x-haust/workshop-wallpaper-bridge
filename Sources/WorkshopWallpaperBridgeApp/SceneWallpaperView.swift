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
    private let sceneTickSource: SceneTickSource
    private var decodeTask: Task<Void, Never>?
    private var isSuspended = false
    private var isClosed = false
    private let ciContext = CIContext()

    private struct ShaderEffectLayer {
        let layer: CALayer
        let baseImage: CIImage
        let effects: [SceneLayerEffectSetting]
        let auxiliaryImages: [String: CIImage]
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
        vec2 scroll = vec2(speedX, speedY) * time;
        texCoord = fract(texCoord + scroll);
        return extent.xy + texCoord * extent.zw;
    }
    """)

    private static let sparkleBandKernel = CIColorKernel(source: """
    kernel vec4 sparkleBand(__sample noiseA, __sample noiseB, float lowEdge, float highEdge, float gain) {
        float product = noiseA.r * noiseB.r;
        float band = smoothstep(lowEdge, highEdge, product);
        float value = clamp(band * gain, 0.0, 1.0);
        return vec4(value, value, value, value);
    }
    """)

    init(
        url: URL,
        previewURL: URL?,
        frame: CGRect,
        displayMode: WallpaperDisplayMode,
        sceneTickSource: SceneTickSource = CADisplayLinkSceneTickSource()
    ) throws {
        plan = try SceneRenderPlanBuilder().buildLayout(url: url)
        self.displayMode = displayMode
        self.sceneTickSource = sceneTickSource
        super.init(frame: frame)
        self.sceneTickSource.onTick = { [weak self] tick in
            self?.refreshSceneTickDrivenLayers(tick)
        }
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
        if suspended {
            sceneTickSource.suspend()
        } else {
            sceneTickSource.resume()
            startSceneTickSourceIfNeeded()
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
        sceneTickSource.invalidate()
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
        sceneTickSource.stop()
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
                guard let contentLayer = buildEffectOnlyShaderLayer(for: layerPlan) else {
                    continue
                }
                contentLayer.name = layerPlan.name
                contentLayer.opacity = Float(max(0, min(layerPlan.alpha * opacityMultiplier(for: layerPlan), 1)))
                configure(contentLayer, with: layerPlan)
                sceneLayer.addSublayer(contentLayer)
                contentLayers.append(contentLayer)
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
                guard let texture = plan.textures[layerPlan.texturePath] else {
                    continue
                }
                let frameContents = Self.animationFrameContents(for: texture)
                guard let image = frameContents?.images.first ?? Self.cgImage(from: texture) else {
                    continue
                }
                let imageLayer = CALayer()
                imageLayer.contents = image
                imageLayer.contentsGravity = .resize
                imageLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
                imageLayer.minificationFilter = .linear
                imageLayer.magnificationFilter = .linear
                if let frameContents, frameContents.images.count > 1 {
                    // Shader effect ticks overwrite layer contents every frame,
                    // which would freeze sprite playback, so animated textures
                    // keep their frame animation instead.
                    imageLayer.add(
                        Self.textureFrameAnimation(for: frameContents),
                        forKey: "scene-texture-frames"
                    )
                } else {
                    registerShaderEffects(for: imageLayer, image: image, plan: layerPlan)
                }
                contentLayer = imageLayer
            }
            contentLayer.name = layerPlan.name
            contentLayer.opacity = Float(max(0, min(layerPlan.alpha * opacityMultiplier(for: layerPlan), 1)))
            configure(contentLayer, with: layerPlan)
            applyOpacityMaskIfAvailable(to: contentLayer, for: layerPlan)
            sceneLayer.addSublayer(contentLayer)
            contentLayers.append(contentLayer)
        }
        buildParticleLayers()
        configureTextRefreshTimer()
        startSceneTickSourceIfNeeded()
    }

    private static let maximumParticleSystems = 4

    private func buildParticleLayers() {
        for particle in plan.particleLayers.prefix(Self.maximumParticleSystems) {
            let particleLayer: CALayer?
            if Self.isPulseRingParticle(particle) {
                particleLayer = buildPulseRingLayer(for: particle)
            } else {
                particleLayer = buildEmitterLayer(for: particle)
            }
            guard let particleLayer else {
                continue
            }
            particleLayer.name = particle.name
            let sublayerCount = sceneLayer.sublayers?.count ?? 0
            sceneLayer.insertSublayer(particleLayer, at: UInt32(min(particle.insertionIndex, sublayerCount)))
            contentLayers.append(particleLayer)
        }
    }

    struct SceneParticleEmitterConfiguration: Equatable {
        let birthRate: Float
        let lifetime: Float
        let lifetimeRange: Float
        let velocityRange: CGFloat
        let scale: CGFloat
        let scaleRange: CGFloat
        let alphaSpeed: Float
        let emitterSize: CGSize
        let spinRange: CGFloat
    }

    nonisolated static func isPulseRingParticle(_ particle: SceneParticleLayer) -> Bool {
        particle.rate <= 2 && particle.sizeChangeEnd != nil
    }

    /// Wallpaper Engine renders particles with engine-side fade and blending
    /// that Core Animation emitters cannot reproduce, so the approximation
    /// keeps fewer, fainter particles to match the on-screen subtlety.
    nonisolated private static let particleSubtletyFactor = 0.35

    nonisolated static func emitterConfiguration(
        for particle: SceneParticleLayer,
        spriteSize: CGSize?,
        canvasSize: SceneSize
    ) -> SceneParticleEmitterConfiguration {
        let averageLifetime = max((particle.lifetimeMin + particle.lifetimeMax) / 2, 0.05)
        let birthRate = min(particle.rate, Double(particle.maxCount) / averageLifetime) * particleSubtletyFactor
        let velocityRange = max(
            abs(particle.velocityMin.x),
            abs(particle.velocityMax.x),
            abs(particle.velocityMin.y),
            abs(particle.velocityMax.y)
        )
        let spriteDimension = max(spriteSize.map { max($0.width, $0.height) } ?? 64, 1)
        let averageSize = (particle.sizeMin + particle.sizeMax) / 2
        let radius = particle.emitterRadius
        return SceneParticleEmitterConfiguration(
            birthRate: Float(max(birthRate, 0.05)),
            lifetime: Float(averageLifetime),
            lifetimeRange: Float(max((particle.lifetimeMax - particle.lifetimeMin) / 2, 0)),
            velocityRange: CGFloat(velocityRange),
            scale: CGFloat(averageSize / spriteDimension),
            scaleRange: CGFloat(max((particle.sizeMax - particle.sizeMin) / 2 / spriteDimension, 0)),
            alphaSpeed: particle.hasAlphaFade ? Float(-1 / max(particle.lifetimeMax, 0.1)) : 0,
            emitterSize: CGSize(
                width: radius > 0 ? min(radius * 2, canvasSize.width) : canvasSize.width / 4,
                height: radius > 0 ? min(radius * 2, canvasSize.height) : canvasSize.height / 4
            ),
            spinRange: CGFloat(abs(particle.angularVelocity ?? 0))
        )
    }

    private func buildEmitterLayer(for particle: SceneParticleLayer) -> CALayer? {
        let textureSprite = particle.texturePath
            .flatMap { plan.textures[$0] }
            .flatMap { Self.particleSpriteImage(from: $0) }
        guard let sprite = textureSprite ?? Self.softParticleImage(diameter: 32) else {
            return nil
        }
        let configuration = Self.emitterConfiguration(
            for: particle,
            spriteSize: CGSize(width: sprite.width, height: sprite.height),
            canvasSize: plan.canvasSize
        )
        let emitter = CAEmitterLayer()
        emitter.emitterPosition = CGPoint(x: particle.origin.x, y: particle.origin.y)
        emitter.emitterShape = .rectangle
        emitter.emitterSize = configuration.emitterSize
        emitter.seed = 7
        emitter.renderMode = .unordered
        let cell = CAEmitterCell()
        cell.contents = sprite
        cell.birthRate = configuration.birthRate
        cell.lifetime = configuration.lifetime
        cell.lifetimeRange = configuration.lifetimeRange
        cell.velocity = 0
        cell.velocityRange = configuration.velocityRange
        cell.emissionRange = .pi * 2
        cell.scale = configuration.scale
        cell.scaleRange = configuration.scaleRange
        cell.alphaSpeed = configuration.alphaSpeed
        cell.spinRange = configuration.spinRange
        cell.color = NSColor.white.withAlphaComponent(0.35).cgColor
        emitter.emitterCells = [cell]
        return emitter
    }

    private func buildPulseRingLayer(for particle: SceneParticleLayer) -> CALayer? {
        guard let ring = Self.ringImage(diameter: 256) else {
            return nil
        }
        let diameter = max(particle.sizeMax, 8)
        let layer = CALayer()
        layer.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        layer.position = CGPoint(x: particle.origin.x, y: particle.origin.y)
        layer.contents = ring
        layer.contentsGravity = .resize
        layer.opacity = 0
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = max(particle.sizeChangeStart ?? 0, 0.001)
        scale.toValue = max(particle.sizeChangeEnd ?? 1, 0.001)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.0, 0.4, 0.0]
        fade.keyTimes = [0, 0.2, 1]
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = max(particle.lifetimeMax, 0.5)
        group.repeatCount = .infinity
        layer.add(group, forKey: "scene-particle-pulse")
        return layer
    }

    nonisolated private static func ringImage(diameter: Int) -> CGImage? {
        let size = CGSize(width: diameter, height: diameter)
        guard let context = bitmapContext(size: size) else {
            return nil
        }
        let bounds = CGRect(origin: .zero, size: size)
        context.clear(bounds)
        let lineWidth = CGFloat(diameter) * 0.05
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.55))
        context.setLineWidth(lineWidth)
        context.strokeEllipse(in: bounds.insetBy(dx: lineWidth, dy: lineWidth))
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.2))
        context.setLineWidth(lineWidth * 2)
        context.strokeEllipse(in: bounds.insetBy(dx: lineWidth * 2.2, dy: lineWidth * 2.2))
        return context.makeImage()
    }

    /// Animated particle sprites are packed as multi-frame sheets; an emitter
    /// cell needs a single frame, not the whole sheet.
    nonisolated static func particleSpriteImage(from texture: SceneTexture) -> CGImage? {
        if texture.animation != nil,
           let firstFrame = animationFrameContents(for: texture)?.images.first {
            return firstFrame
        }
        return cgImage(fromStorage: texture.storage)
    }

    nonisolated private static func softParticleImage(diameter: Int) -> CGImage? {
        let size = CGSize(width: diameter, height: diameter)
        guard let context = bitmapContext(size: size) else {
            return nil
        }
        context.clear(CGRect(origin: .zero, size: size))
        let colors = [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.9),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0)
        ] as CFArray
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: [0, 1]
        ) else {
            return nil
        }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        context.drawRadialGradient(
            gradient,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: size.width / 2,
            options: []
        )
        return context.makeImage()
    }

    private func buildEffectOnlyShaderLayer(for layerPlan: SceneLayer) -> CALayer? {
        let effects = Self.effectOnlyShaderEffects(for: layerPlan)
        guard !effects.isEmpty else {
            return nil
        }
        // Generator effects such as sparkle emit their own pixels, so they
        // start from a transparent base instead of freezing a scene snapshot.
        let generatesOwnPixels = effects.allSatisfy { $0.effect == .sparkle }
        let baseImage = generatesOwnPixels
            ? Self.transparentImage(size: CGSize(
                width: max(1, abs(layerPlan.size.width)),
                height: max(1, abs(layerPlan.size.height))
            ))
            : effectOnlyBaseImage(for: layerPlan)
        guard let image = baseImage else {
            return nil
        }
        let effectLayer = CALayer()
        effectLayer.contents = image
        effectLayer.contentsGravity = .resize
        effectLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        effectLayer.minificationFilter = .linear
        effectLayer.magnificationFilter = .linear
        registerShaderEffects(for: effectLayer, image: image, effects: effects)
        return effectLayer
    }

    private func effectOnlyBaseImage(for layerPlan: SceneLayer) -> CGImage? {
        let size = CGSize(
            width: max(1, abs(layerPlan.size.width)),
            height: max(1, abs(layerPlan.size.height))
        )
        let sceneRect = CGRect(
            x: layerPlan.origin.x - (size.width / 2),
            y: layerPlan.origin.y - (size.height / 2),
            width: size.width,
            height: size.height
        )
        return snapshotSceneLayer(in: sceneRect, outputSize: size)
            ?? Self.transparentImage(size: size)
    }

    private func snapshotSceneLayer(in sceneRect: CGRect, outputSize: CGSize) -> CGImage? {
        guard !contentLayers.isEmpty,
              let context = Self.bitmapContext(size: outputSize) else {
            return nil
        }
        context.clear(CGRect(origin: .zero, size: outputSize))
        context.translateBy(x: -sceneRect.minX, y: -sceneRect.minY)
        sceneLayer.render(in: context)
        return context.makeImage()
    }

    private func configureTextRefreshTimer() {
        textRefreshTimer?.invalidate()
        textRefreshTimer = nil
        guard dynamicTextLayers.contains(where: { $0.scriptEvaluator == nil }) else {
            return
        }
        let interval: TimeInterval = 1
        refreshDynamicTextLayers(frameTime: interval, includeScripted: false)
        textRefreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDynamicTextLayers(frameTime: interval, includeScripted: false)
            }
        }
    }

    private func refreshDynamicTextLayers(
        date: Date = Date(),
        frameTime: TimeInterval = 1,
        includeScripted: Bool = true
    ) {
        guard !isClosed else {
            return
        }
        for item in dynamicTextLayers where includeScripted || item.scriptEvaluator == nil {
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
        frameTime: TimeInterval = 1.0 / 60.0
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
            runtime: SceneScriptRuntime(time: currentSceneTime(), frameTime: sceneFrameTime(fallback: frameTime))
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
        configure(keyframe, duration: animation.duration, autoreverses: animation.autoreverses)
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
        configure(xAnimation, duration: animation.duration, autoreverses: animation.autoreverses)
        xAnimation.values = animation.keyframes.map { frame in
            animation.isRelative ? plan.scale.x + frame.value.x : frame.value.x
        }
        xAnimation.keyTimes = keyTimes(for: animation)
        layer.add(xAnimation, forKey: "scene-scale-x")

        let yAnimation = CAKeyframeAnimation(keyPath: "transform.scale.y")
        configure(yAnimation, duration: animation.duration, autoreverses: animation.autoreverses)
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
        configure(keyframe, duration: animation.duration, autoreverses: animation.autoreverses)
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
        configure(keyframe, duration: animation.duration, autoreverses: animation.autoreverses)
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
            case .spin where !effect.usesMask:
                addSpinEffectAnimation(to: layer, effect: effect)
            case .shine:
                addShineEffectAnimation(to: layer, effect: effect)
            case .pulse:
                addPulseEffectAnimation(to: layer, effect: effect)
            case .spin, .waterFlow, .waterWaves, .waterRipple, .scroll, .opacity,
                    .bloom, .blur, .chromaticAberration, .clouds, .godRays,
                    .localContrast, .materialColor, .sparkle:
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
        let parameters = Self.spinAnimationParameters(for: effect)
        animation.byValue = parameters.byValue
        animation.duration = parameters.duration
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        layer.add(animation, forKey: "scene-effect-spin")
    }

    /// Wallpaper Engine spin speed is radians per second with sign giving the
    /// rotation direction.
    nonisolated static func spinAnimationParameters(
        for effect: SceneLayerEffectSetting
    ) -> (byValue: CGFloat, duration: Double) {
        guard let speed = effect.speed, abs(speed) > 0.000_001 else {
            return (CGFloat.pi * 2, 8)
        }
        return (speed < 0 ? -CGFloat.pi * 2 : CGFloat.pi * 2, (2 * Double.pi) / abs(speed))
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

    private func addPulseEffectAnimation(to layer: CALayer, effect: SceneLayerEffectSetting) {
        let baseOpacity = Double(layer.opacity)
        guard baseOpacity > 0 else {
            return
        }
        let strength = max(0, min(effect.strength ?? 0.35, 1))
        let low = max(0, min(baseOpacity * (1 - (strength * 0.45)), 1))
        let high = max(0, min(baseOpacity * (1 + (strength * 0.25)), 1))
        let keyframe = CAKeyframeAnimation(keyPath: "opacity")
        configure(keyframe, duration: Self.layerEffectDuration(for: effect, defaultDuration: 1.8))
        keyframe.values = [baseOpacity, high, low, high, baseOpacity]
        keyframe.keyTimes = [0, 0.25, 0.5, 0.75, 1]
        layer.add(keyframe, forKey: "scene-effect-pulse")
    }

    private func opacityMultiplier(for plan: SceneLayer) -> Double {
        guard let opacity = plan.effectSettings.last(where: { $0.effect == .opacity }) else {
            return 1
        }
        return max(0, min(opacity.strength ?? 1, 1))
    }

    private func applyOpacityMaskIfAvailable(to contentLayer: CALayer, for layerPlan: SceneLayer) {
        guard let texturePath = Self.opacityMaskTexturePath(for: layerPlan),
              let texture = plan.textures[texturePath],
              let maskLayer = Self.opacityMaskLayer(
                from: texture,
                bounds: contentLayer.bounds,
                contentsScale: contentLayer.contentsScale
              ) else {
            return
        }
        contentLayer.mask = maskLayer
    }

    static func opacityMaskTexturePath(for layer: SceneLayer) -> String? {
        guard !layer.isEffectOnly else {
            return nil
        }
        return layer.effectSettings.first {
            $0.effect == .opacity && $0.maskReference?.texturePath != nil
        }?.maskReference?.texturePath
    }

    static func opacityMaskLayer(
        from texture: SceneTexture,
        bounds: CGRect,
        contentsScale: CGFloat
    ) -> CALayer? {
        guard let image = cgImage(from: texture) else {
            return nil
        }
        let maskLayer = CALayer()
        maskLayer.contents = image
        maskLayer.contentsGravity = .resize
        maskLayer.contentsScale = contentsScale
        maskLayer.bounds = bounds
        maskLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        return maskLayer
    }

    private func configure(_ animation: CAKeyframeAnimation, duration: Double, autoreverses: Bool = false) {
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.calculationMode = .linear
        animation.autoreverses = autoreverses
    }

    private func registerShaderEffects(for layer: CALayer, image: CGImage, plan: SceneLayer) {
        let effects = Self.shaderRenderableEffects(from: plan.effectSettings)
        guard !effects.isEmpty else {
            return
        }
        registerShaderEffects(for: layer, image: image, effects: effects)
    }

    nonisolated private static let maximumShaderImageDimension: CGFloat = 2048

    private func registerShaderEffects(
        for layer: CALayer,
        image: CGImage,
        effects: [SceneLayerEffectSetting]
    ) {
        var auxiliaryImages: [String: CIImage] = [:]
        for setting in effects {
            guard let path = setting.auxiliaryTexturePath,
                  auxiliaryImages[path] == nil,
                  let texture = plan.textures[path],
                  let auxImage = Self.cgImage(fromStorage: texture.storage) else {
                continue
            }
            auxiliaryImages[path] = CIImage(cgImage: auxImage)
        }
        shaderEffectLayers.append(ShaderEffectLayer(
            layer: layer,
            baseImage: Self.shaderBaseImage(from: image),
            effects: effects,
            auxiliaryImages: auxiliaryImages
        ))
    }

    /// Keeps per-tick Core Image work bounded on 4K scenes by rendering the
    /// effect chain at a capped resolution; the layer scales the result back up.
    nonisolated private static func shaderBaseImage(from image: CGImage) -> CIImage {
        let ciImage = CIImage(cgImage: image)
        let largestDimension = max(ciImage.extent.width, ciImage.extent.height)
        guard largestDimension > maximumShaderImageDimension else {
            return ciImage
        }
        let factor = maximumShaderImageDimension / largestDimension
        return ciImage.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
    }

    private func startSceneTickSourceIfNeeded() {
        guard !isClosed, !isSuspended, !sceneTickSource.isRunning, needsSceneTickSource else {
            return
        }
        refreshSceneTickDrivenLayers(SceneTick(
            elapsedTime: currentSceneTime(),
            frameTime: sceneFrameTime(fallback: 1.0 / 60.0)
        ))
        sceneTickSource.start()
    }

    private var needsSceneTickSource: Bool {
        !shaderEffectLayers.isEmpty || dynamicTextLayers.contains { $0.scriptEvaluator != nil }
    }

    private func refreshSceneTickDrivenLayers(_ tick: SceneTick) {
        refreshShaderEffectLayers(time: tick.elapsedTime)
        refreshDynamicTextLayers(frameTime: tick.frameTime)
    }

    private func refreshShaderEffectLayers(time: TimeInterval) {
        guard !isClosed, !isSuspended else {
            return
        }
        for item in shaderEffectLayers {
            guard let image = Self.renderShaderEffects(
                baseImage: item.baseImage,
                effects: item.effects,
                time: time,
                context: ciContext,
                auxiliaryImages: item.auxiliaryImages
            ) else {
                continue
            }
            item.layer.contents = image
        }
    }

    private func resetShaderEffectClock() {
        sceneTickSource.reset()
    }

    private func currentSceneTime() -> TimeInterval {
        sceneTickSource.elapsedTime
    }

    private func sceneFrameTime(fallback: TimeInterval) -> TimeInterval {
        let frameTime = sceneTickSource.frameTime
        guard frameTime > 0 else {
            return fallback
        }
        return frameTime
    }

    private static func renderShaderEffects(
        baseImage: CIImage,
        effects: [SceneLayerEffectSetting],
        time: Double,
        context: CIContext,
        auxiliaryImages: [String: CIImage] = [:]
    ) -> CGImage? {
        var image = baseImage
        for effect in effects {
            switch effect.effect {
            case .waterFlow, .waterWaves, .waterRipple:
                image = applyWaterWaves(to: image, effect: effect, time: time) ?? image
            case .scroll:
                image = applyScroll(to: image, effect: effect, time: time) ?? image
            case .spin:
                image = applySpin(to: image, effect: effect, time: time) ?? image
            case .sparkle:
                image = applySparkle(
                    to: image,
                    effect: effect,
                    time: time,
                    noise: effect.auxiliaryTexturePath.flatMap { auxiliaryImages[$0] }
                ) ?? image
            case .bloom:
                image = applyBloom(to: image, effect: effect) ?? image
            case .blur:
                image = applyBlur(to: image, effect: effect) ?? image
            case .chromaticAberration:
                image = applyChromaticAberration(to: image, effect: effect, time: time) ?? image
            case .godRays:
                image = applyGodRays(to: image, effect: effect) ?? image
            case .localContrast:
                image = applyLocalContrast(to: image, effect: effect) ?? image
            case .materialColor:
                image = applyMaterialColor(to: image, effect: effect) ?? image
            case .shake, .shine, .opacity, .pulse, .clouds:
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
            case .waterFlow, .waterWaves, .waterRipple, .scroll,
                    .bloom, .blur, .chromaticAberration, .godRays,
                    .localContrast, .materialColor, .sparkle:
                return true
            case .spin:
                // Masked spin rotates the texture beneath a fixed opacity
                // mask, which only the Core Image path can express.
                return setting.usesMask
            case .shake, .shine, .opacity, .pulse, .clouds:
                return false
            }
        }
    }

    nonisolated static func effectOnlyShaderEffects(
        for layer: SceneLayer
    ) -> [SceneLayerEffectSetting] {
        guard layer.isEffectOnly else {
            return []
        }
        return shaderRenderableEffects(from: layer.effectSettings)
    }

    nonisolated static func shouldBuildEffectOnlyShaderLayer(for layer: SceneLayer) -> Bool {
        !effectOnlyShaderEffects(for: layer).isEmpty
    }

    private static func transparentImage(size: CGSize) -> CGImage? {
        guard let context = bitmapContext(size: size) else {
            return nil
        }
        context.clear(CGRect(origin: .zero, size: size))
        return context.makeImage()
    }

    nonisolated private static let maximumBitmapDimension = 16_384
    nonisolated private static let maximumBitmapPixels = 18_000_000

    nonisolated static func isSafeBitmapSize(_ size: CGSize) -> Bool {
        guard size.width.isFinite, size.height.isFinite else {
            return false
        }
        let widthValue = ceil(abs(size.width))
        let heightValue = ceil(abs(size.height))
        guard widthValue >= 1,
              heightValue >= 1,
              widthValue <= CGFloat(maximumBitmapDimension),
              heightValue <= CGFloat(maximumBitmapDimension) else {
            return false
        }
        let width = Int(widthValue)
        let height = Int(heightValue)
        return width <= maximumBitmapPixels / height
    }

    nonisolated private static func bitmapContext(size: CGSize) -> CGContext? {
        guard isSafeBitmapSize(size) else {
            return nil
        }
        let width = Int(max(1, ceil(abs(size.width))))
        let height = Int(max(1, ceil(abs(size.height))))
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    nonisolated static func isLayerAnimatedEffect(_ effect: SceneLayerEffect) -> Bool {
        switch effect {
        case .shake, .spin, .shine, .pulse:
            return true
        case .waterFlow, .waterWaves, .waterRipple, .scroll, .opacity,
                .bloom, .blur, .chromaticAberration, .clouds, .godRays,
                .localContrast, .materialColor, .sparkle:
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
        case .pulse:
            return !hasAlphaAnimation
        case .waterFlow, .waterWaves, .waterRipple, .scroll, .opacity,
                .bloom, .blur, .chromaticAberration, .clouds, .godRays,
                .localContrast, .materialColor, .sparkle:
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

    private static func applySpin(
        to image: CIImage,
        effect: SceneLayerEffectSetting,
        time: Double
    ) -> CIImage? {
        let speed = effect.speed ?? 0
        guard abs(speed) > 0.000_001 else {
            return image
        }
        let extent = image.extent
        let angle = CGFloat(speed * time)
        let center = CGPoint(x: extent.midX, y: extent.midY)
        let transform = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: angle)
            .translatedBy(x: -center.x, y: -center.y)
        return image.transformed(by: transform).cropped(to: extent)
    }

    /// Approximates the Wallpaper Engine "nitro" style glint shader: two
    /// copies of a noise texture scroll against each other and pixels where
    /// the product crosses the configured band light up as white twinkles.
    private static func applySparkle(
        to image: CIImage,
        effect: SceneLayerEffectSetting,
        time: Double,
        noise: CIImage?
    ) -> CIImage? {
        guard let kernel = sparkleBandKernel,
              let noise,
              noise.extent.width > 0,
              noise.extent.height > 0 else {
            return image
        }
        let extent = image.extent
        let uvScale = max(effect.scale ?? 2, 0.05)
        let speeds = effect.speedVector ?? [0.05, 0, -0.05, 0]
        let tileSize = CGSize(width: extent.width / uvScale, height: extent.height / uvScale)
        guard tileSize.width >= 1, tileSize.height >= 1 else {
            return image
        }
        func scrolledNoise(speedX: Double, speedY: Double) -> CIImage {
            let offset = CGPoint(
                x: CGFloat((speedX * time).truncatingRemainder(dividingBy: 1)) * tileSize.width,
                y: CGFloat((speedY * time).truncatingRemainder(dividingBy: 1)) * tileSize.height
            )
            return noise
                .transformed(by: CGAffineTransform(
                    scaleX: tileSize.width / noise.extent.width,
                    y: tileSize.height / noise.extent.height
                ))
                .transformed(by: CGAffineTransform(translationX: offset.x, y: offset.y))
                .applyingFilter("CIAffineTile", parameters: [:])
                .cropped(to: extent)
        }
        let bandCenter = effect.bounds.map { ($0.width + $0.height) / 2 } ?? 0.6
        let gain = max(0.2, min((effect.strength ?? 1) * 0.15, 2.5))
        guard let band = kernel.apply(
            extent: extent,
            arguments: [
                scrolledNoise(speedX: speeds[0], speedY: speeds.count > 1 ? speeds[1] : 0),
                scrolledNoise(speedX: speeds.count > 2 ? speeds[2] : -speeds[0], speedY: speeds.count > 3 ? speeds[3] : 0),
                max(bandCenter - 0.16, 0),
                min(bandCenter + 0.08, 1),
                gain
            ]
        ) else {
            return image
        }
        return band.composited(over: image).cropped(to: extent)
    }

    private static func applyBloom(to image: CIImage, effect: SceneLayerEffectSetting) -> CIImage? {
        image.applyingFilter("CIBloom", parameters: [
            kCIInputRadiusKey: max(1, min((effect.scale ?? 12) * 0.35, 24)),
            kCIInputIntensityKey: max(0.05, min(effect.strength ?? 0.35, 1.2))
        ]).cropped(to: image.extent)
    }

    private static func applyBlur(to image: CIImage, effect: SceneLayerEffectSetting) -> CIImage? {
        image.applyingFilter("CIGaussianBlur", parameters: [
            kCIInputRadiusKey: max(0.2, min(effect.strength ?? effect.scale ?? 2, 12))
        ]).cropped(to: image.extent)
    }

    private static func applyChromaticAberration(
        to image: CIImage,
        effect: SceneLayerEffectSetting,
        time: Double
    ) -> CIImage? {
        let strength = max(0.5, min((effect.strength ?? 0.025) * 64, 8))
        let phase = sin(time * max(0.25, abs(effect.speed ?? 0.6)))
        let red = image
            .transformed(by: CGAffineTransform(translationX: strength, y: phase * strength * 0.25))
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
        let cyan = image
            .transformed(by: CGAffineTransform(translationX: -strength, y: -phase * strength * 0.25))
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
        return red.composited(over: cyan).cropped(to: image.extent)
    }

    private static func applyGodRays(to image: CIImage, effect: SceneLayerEffectSetting) -> CIImage? {
        let rays = image.applyingFilter("CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: image.extent.midX, y: image.extent.maxY),
            "inputRadius0": max(20, min(image.extent.width, image.extent.height) * 0.06),
            "inputRadius1": max(image.extent.width, image.extent.height) * 0.75,
            "inputColor0": CIColor(red: 1, green: 0.96, blue: 0.72, alpha: max(0.04, min(effect.strength ?? 0.16, 0.45))),
            "inputColor1": CIColor(red: 1, green: 0.96, blue: 0.72, alpha: 0)
        ]).cropped(to: image.extent)
        return rays.composited(over: image).cropped(to: image.extent)
    }

    private static func applyLocalContrast(to image: CIImage, effect: SceneLayerEffectSetting) -> CIImage? {
        image.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 1 + max(0, min(effect.strength ?? 0.08, 0.35)),
            kCIInputContrastKey: 1 + max(0, min(effect.strength ?? 0.12, 0.45))
        ])
    }

    private static func applyMaterialColor(to image: CIImage, effect: SceneLayerEffectSetting) -> CIImage? {
        image.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: max(0.75, min(1 + (effect.strength ?? 0.08), 1.35)),
            kCIInputBrightnessKey: max(-0.08, min((effect.strength ?? 0.04) * 0.12, 0.08))
        ])
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
        cgImage(fromStorage: texture.storage)
    }

    nonisolated static func cgImage(fromStorage storage: SceneTextureStorage) -> CGImage? {
        switch storage {
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

    struct SceneTextureFrameContents {
        let images: [CGImage]
        let keyTimes: [NSNumber]
        let duration: Double
    }

    nonisolated private static let maximumAnimationFramePixels = 32_000_000

    /// Cuts per-frame images out of an animated texture's sprite sheets.
    /// Returns nil when the animation is absent, malformed, or too large, so
    /// callers fall back to static sheet rendering.
    nonisolated static func animationFrameContents(for texture: SceneTexture) -> SceneTextureFrameContents? {
        guard let animation = texture.animation, !animation.frames.isEmpty else {
            return nil
        }
        let sheetStorages = texture.animationSheets.isEmpty ? [texture.storage] : texture.animationSheets
        var sheets: [CGImage?] = Array(repeating: nil, count: sheetStorages.count)
        var images: [CGImage] = []
        images.reserveCapacity(animation.frames.count)
        var totalPixels = 0
        for frame in animation.frames {
            guard frame.imageIndex < sheetStorages.count else {
                return nil
            }
            if sheets[frame.imageIndex] == nil {
                sheets[frame.imageIndex] = cgImage(fromStorage: sheetStorages[frame.imageIndex])
            }
            guard let sheet = sheets[frame.imageIndex],
                  let image = frameImage(from: sheet, frame: frame) else {
                return nil
            }
            totalPixels += image.width * image.height
            guard totalPixels <= maximumAnimationFramePixels else {
                return nil
            }
            images.append(image)
        }
        let durations = animation.frames.map { max($0.duration, 0.01) }
        let total = durations.reduce(0, +)
        guard total > 0 else {
            return nil
        }
        // Discrete keyframe animations need values.count + 1 key times.
        var keyTimes: [NSNumber] = [0]
        var elapsed = 0.0
        for duration in durations {
            elapsed += duration
            keyTimes.append(NSNumber(value: min(elapsed / total, 1)))
        }
        return SceneTextureFrameContents(images: images, keyTimes: keyTimes, duration: total)
    }

    nonisolated static func frameDisplaySize(for frame: SceneTextureFrame) -> CGSize {
        CGSize(
            width: max(abs(frame.width), abs(frame.widthY)).rounded(),
            height: max(abs(frame.heightX), abs(frame.height)).rounded()
        )
    }

    /// Maps destination frame coordinates (top-left origin) into sprite-sheet
    /// coordinates (top-left origin) using the frame's axis vectors, which is
    /// how RePKG reconstructs rotated or flipped sheet packing.
    nonisolated static func frameSheetTransform(for frame: SceneTextureFrame) -> CGAffineTransform? {
        let transform = CGAffineTransform(
            a: CGFloat(sign(frame.width)),
            b: CGFloat(sign(frame.widthY)),
            c: CGFloat(sign(frame.heightX)),
            d: CGFloat(sign(frame.height)),
            tx: CGFloat(frame.x.rounded()),
            ty: CGFloat(frame.y.rounded())
        )
        let determinant = transform.a * transform.d - transform.b * transform.c
        guard abs(determinant) > 0.5 else {
            return nil
        }
        return transform
    }

    nonisolated private static func sign(_ value: Double) -> Double {
        if value > 0 { return 1 }
        if value < 0 { return -1 }
        return 0
    }

    nonisolated private static func frameImage(from sheet: CGImage, frame: SceneTextureFrame) -> CGImage? {
        let size = frameDisplaySize(for: frame)
        guard size.width >= 1, size.height >= 1,
              isSafeBitmapSize(size),
              let destinationToSheet = frameSheetTransform(for: frame),
              let context = bitmapContext(size: size) else {
            return nil
        }
        context.interpolationQuality = .none
        // Flip into top-left destination space, map into sheet space, then
        // flip again so CGImage drawing (bottom-left origin) lines up.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.concatenate(destinationToSheet.inverted())
        context.translateBy(x: 0, y: CGFloat(sheet.height))
        context.scaleBy(x: 1, y: -1)
        context.draw(sheet, in: CGRect(x: 0, y: 0, width: sheet.width, height: sheet.height))
        return context.makeImage()
    }

    nonisolated static func textureFrameAnimation(for contents: SceneTextureFrameContents) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = contents.images
        animation.keyTimes = contents.keyTimes
        animation.duration = contents.duration
        animation.calculationMode = .discrete
        animation.repeatCount = .infinity
        return animation
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
