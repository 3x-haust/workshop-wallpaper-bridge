import AppKit
import CoreImage
import CoreText
import WorkshopWallpaperCore

@MainActor
final class MediaSceneWallpaperView: NSView, WallpaperContentLifecycle, PausableWallpaperContent,
    DisplayModeUpdatableContent, AudioControllableWallpaperContent {
    let background: VideoWallpaperView
    let plan: SceneMediaOverlayPlan
    private let overlay = CALayer()
    private let session: SceneScriptSession
    private var timer: Timer?
    private var mediaConsumer: UUID?
    private var audioConsumer: UUID?
    private var closed = false
    private var suspended = false
    private var elapsed: Double = 0
    private var previousTick = ProcessInfo.processInfo.systemUptime
    private var cursorPressed = false
    private var cursorEvents: [[String: Any]] = []
    private var artworkRevision = ""
    private var currentArtwork: CGImage?
    private var previousArtwork: CGImage?
    private var objectValues: [String: [String: Any]] = [:]
    private let imageContext = CIContext()
    private var values: [Int: [String: Any]] = [:]
    private var rendered: [Int: CALayer] = [:]
    private var emitters: [Int: SceneAudioParticles] = [:]
    private let renderShader: @MainActor (SceneShaderRequest) async throws -> SceneShaderResult
    private var shaderTask: Task<Void, Never>?
    private var shaderGeneration = 0
    private var shaderFailure = false
    private(set) var diagnostic: String?
    var mediaProvider: () -> WallpaperMediaSnapshot = { MusicMetadataSource.shared.snapshot }
    var audioProvider: () -> WallpaperAudioSpectrum = { SystemAudioAnalysis.shared.currentSpectrum }

    init(videoURL: URL, previewURL: URL?, plan: SceneMediaOverlayPlan, frame: CGRect,
         audioEnabled: Bool = false, audioVolume: Double = 0.5,
         renderShader: (@MainActor (SceneShaderRequest) async throws -> SceneShaderResult)? = nil) {
        self.plan = plan
        let executor = SceneShaderExecutor()
        self.renderShader = renderShader ?? { request in try await executor.render(request) }
        session = SceneScriptSession(configuration: plan.configuration)
        background = VideoWallpaperView(url: videoURL, fallbackImageURL: previewURL, frame: frame,
                                        displayMode: .fill, audioEnabled: audioEnabled, audioVolume: audioVolume)
        super.init(frame: frame)
        wantsLayer = true; layer = CALayer(); layer?.masksToBounds = true
        background.frame = bounds; addSubview(background)
        overlay.zPosition = 1
        layer?.addSublayer(overlay)
        for item in plan.configuration["layers"] as? [[String: Any]] ?? [] {
            if let id = item["id"] as? Int { values[id] = item["values"] as? [String: Any] }
        }
        for item in plan.configuration["objects"] as? [[String: Any]] ?? [] {
            if let id = item["id"] as? String { objectValues[id] = item["values"] as? [String: Any] }
        }
        for item in plan.layers {
            let target: CALayer
            if let text = item.model.text, let style = plan.metrics.styles[item.model.id] {
                let textLayer = CATextLayer()
                textLayer.font = style.font
                textLayer.fontSize = CTFontGetSize(style.font)
                textLayer.foregroundColor = color(item.model.color)
                textLayer.alignmentMode = text.horizontalAlignment == .left ? .left : text.horizontalAlignment == .right ? .right : .center
                textLayer.isWrapped = false
                textLayer.truncationMode = .none
                target = textLayer
            } else {
                target = CALayer()
                target.contents = item.animation?.images.first ?? item.image
                target.contentsGravity = item.thumbnail ? .resizeAspectFill : .resize
                if item.image == nil && !item.thumbnail { target.backgroundColor = color(item.model.color) }
                if let mask = makeMask(item.masks, size: item.model.size) { target.mask = mask }
            }
            target.name = item.model.name
            target.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            target.masksToBounds = true
            overlay.addSublayer(target)
            rendered[item.model.id] = target
        }
        for particle in plan.particles {
            let emitter = SceneAudioParticles(plan: particle)
            overlay.addSublayer(emitter.layer); emitters[particle.model.id] = emitter
        }
        for item in plan.compositions {
            let target = CALayer(); target.name = item.model.name; target.masksToBounds = true
            overlay.addSublayer(target); rendered[item.model.id] = target
        }
        for (index, id) in plan.order.enumerated() {
            (rendered[id] ?? emitters[id]?.layer)?.zPosition = CGFloat(index)
        }
        session.onChanges = { [weak self] changes in
            guard let self, !self.closed, !self.suspended else { return }
            for change in changes {
                guard let id = change["id"] as? Int, let next = change["values"] as? [String: Any] else { continue }
                self.values[id, default: [:]].merge(next) { _, new in new }
            }
            self.applyValues()
        }
        session.onDiagnostic = { [weak self] message in
            self?.diagnostic = message; SceneWallpaperContentFactory.statusHandler?(message)
        }
        session.onObjectChanges = { [weak self] changes in
            guard let self, !self.closed, !self.suspended else { return }
            for change in changes {
                if let id = change["id"] as? String, let next = change["values"] as? [String: Any] {
                    self.objectValues[id, default: [:]].merge(next) { _, new in new }
                }
            }
            if !changes.isEmpty { self.updateShaderEffects() }
        }
        applyValues(); layoutOverlay(); resume()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { window?.ignoresMouseEvents == false && bounds.contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) { recordCursorEvent(event, down: true) }
    override func mouseUp(with event: NSEvent) { recordCursorEvent(event, down: false) }
    private func recordCursorEvent(_ event: NSEvent, down: Bool) {
        guard !closed, !suspended, window?.ignoresMouseEvents == false else { return }
        cursorPressed = down
        let local = convert(event.locationInWindow, from: nil), world = overlay.convert(local, from: layer)
        if cursorEvents.count < 64 {
            cursorEvents.append(["cursor": [Double(world.x), Double(world.y), 0], "down": down, "up": !down,
                                 "cursorInside": bounds.contains(local) && overlay.bounds.contains(world)])
        }
    }
    override func layout() { super.layout(); layoutOverlay() }

    private func layoutOverlay() {
        background.frame = bounds
        let frame = WallpaperContentLayout.scaledContentFrame(for: plan.canvas, in: bounds, displayMode: .fill)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        overlay.bounds = CGRect(origin: .zero, size: plan.canvas)
        overlay.position = CGPoint(x:frame.midX,y:frame.midY)
        overlay.setAffineTransform(CGAffineTransform(scaleX:frame.width/plan.canvas.width,y:frame.height/plan.canvas.height))
        CATransaction.commit()
    }
    private func resume() {
        mediaConsumer = MusicMetadataSource.shared.acquire(); audioConsumer = SystemAudioAnalysis.shared.acquire()
        previousTick = ProcessInfo.processInfo.systemUptime
        timer = Timer.scheduledTimer(withTimeInterval: 1/30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }
    func tick() {
        guard !closed, !suspended else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(0.1,max(0,now-previousTick)); previousTick = now; elapsed += dt
        let media = mediaProvider(), audio = audioProvider()
        let local = window.map { convert($0.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil) } ?? .zero
        let world = overlay.convert(local, from: layer), scale = window?.backingScaleFactor ?? 1
        if window?.ignoresMouseEvents != false { cursorPressed = false; cursorEvents = [] }
        let accepted = session.advance(frame: ["time":elapsed,"now":Date().timeIntervalSince1970*1000,
                                "screen":[bounds.width * scale,bounds.height * scale],"media":media.frame(),
                                "cursor": [Double(world.x), Double(world.y), 0],
                                "cursorScreen": [Double(local.x * scale), Double((bounds.height - local.y) * scale)],
                                "cursorInside": window != nil && bounds.contains(local) && overlay.bounds.contains(world),
                                "leftDown": cursorPressed, "cursorEvents": cursorEvents,
                                "audioLeft":audio.left,"audioRight":audio.right])
        if accepted { cursorEvents = [] }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for item in plan.layers {
            // Shader layers keep their last processed image while the next
            // request runs. Only the renderer publishes their live contents.
            guard item.shaderEffects.isEmpty || shaderFailure,
                  let animation = item.animation, let target = rendered[item.model.id], !target.isHidden else { continue }
            let phase = elapsed.truncatingRemainder(dividingBy: animation.duration) / animation.duration
            let index = max(0, (animation.keyTimes.firstIndex { $0.doubleValue > phase } ?? animation.images.count) - 1)
            target.contents = animation.images[min(index, animation.images.count - 1)]
        }
        for emitter in emitters.values {
            emitter.step(seconds: dt, spectrum: audio, cursor: window == nil ? nil : emitter.layer.convert(world, from: overlay))
        }
        if artworkRevision != media.artworkRevision {
            shaderGeneration += 1; shaderTask?.cancel()
            artworkRevision = media.artworkRevision
            let image = media.artwork.flatMap(Self.artworkImage)
            previousArtwork = currentArtwork; currentArtwork = image
            for item in plan.layers where item.thumbnail && (item.shaderEffects.isEmpty || shaderFailure) {
                if let target = rendered[item.model.id] {
                    target.contents = image
                }
            }
        }
        updateShaderEffects()
        CATransaction.commit()
    }

    private func updateShaderEffects() {
        guard !shaderFailure, shaderTask == nil, !closed, !suspended else { return }
        let activeCompositions = plan.compositions.filter { rendered[$0.model.id]?.isHidden == false && (rendered[$0.model.id]?.opacity ?? 0) > 0 }
        let activeImages = plan.layers.filter { !$0.shaderEffects.isEmpty && rendered[$0.model.id]?.isHidden == false && (rendered[$0.model.id]?.opacity ?? 0) > 0 }
        guard !activeCompositions.isEmpty || !activeImages.isEmpty else { return }
        let generation = shaderGeneration
        shaderTask = Task { [weak self] in
            guard let self else { return }
            defer { self.shaderTask = nil }
            do {
                for item in activeImages {
                    guard !Task.isCancelled, !closed, !suspended, shaderGeneration == generation else { return }
                    guard let target = rendered[item.model.id] else { continue }
                    let input: CGImage
                    if let image = Self.sourceImage(for: item, time: elapsed, artwork: currentArtwork) { input = image }
                    else {
                        let base = CIImage(color: CIColor(cgColor: color(item.model.color))).cropped(to: CGRect(x: 0, y: 0, width: item.model.size.width, height: item.model.size.height))
                        guard let image = imageContext.createCGImage(base, from: base.extent) else { continue }
                        input = image
                    }
                    let result = try await renderShader(SceneShaderRequest(image: input, effects: item.shaderEffects, time: elapsed, values: objectValues, currentArtwork: currentArtwork, previousArtwork: previousArtwork))
                    guard !Task.isCancelled, !closed, !suspended, shaderGeneration == generation else { return }
                    CATransaction.begin(); CATransaction.setDisableActions(true); target.contents = result.image; CATransaction.commit()
                }
                guard !activeCompositions.isEmpty, let frame = background.currentFrame(),
                      let video = imageContext.createCGImage(frame, from: frame.extent) else { return }
                for item in activeCompositions {
                    guard !Task.isCancelled, !closed, !suspended, shaderGeneration == generation else { return }
                    guard let target = rendered[item.model.id], let input = Self.composeInput(for: target, video: video, canvas: plan.canvas, layers: overlay.sublayers ?? []) else { continue }
                    let result = try await renderShader(SceneShaderRequest(image: input, effects: item.effects, time: elapsed, values: objectValues, currentArtwork: currentArtwork, previousArtwork: previousArtwork))
                    guard !Task.isCancelled, !closed, !suspended, shaderGeneration == generation else { return }
                    CATransaction.begin(); CATransaction.setDisableActions(true); target.contents = result.image; CATransaction.commit()
                }
            } catch {
                guard !Task.isCancelled, !closed, !suspended, shaderGeneration == generation else { return }
                shaderFailure = true
                // Fall back explicitly to current unprocessed images. Subsequent
                // animation/artwork ticks keep those images live until restart.
                for item in plan.layers where !item.shaderEffects.isEmpty {
                    rendered[item.model.id]?.contents = Self.sourceImage(for: item, time: elapsed, artwork: currentArtwork)
                }
                for item in plan.compositions { rendered[item.model.id]?.contents = nil }
                diagnostic = error.localizedDescription
                SceneWallpaperContentFactory.statusHandler?(error.localizedDescription)
            }
        }
    }

    static func sourceImage(for item: SceneMediaOverlayPlan.Layer, time: Double, artwork: CGImage?) -> CGImage? {
        if item.thumbnail { return artwork }
        if let animation = item.animation {
            let phase = max(0, time).truncatingRemainder(dividingBy: animation.duration) / animation.duration
            let index = max(0, (animation.keyTimes.firstIndex { $0.doubleValue > phase } ?? animation.images.count) - 1)
            return animation.images[min(index, animation.images.count - 1)]
        }
        return item.image
    }

    /// Copies only the layers beneath this compose layer into its local space.
    /// AVPlayer is sampled explicitly; CALayer.render does not capture video.
    static func composeInput(for target: CALayer, video: CGImage, canvas: CGSize, layers: [CALayer]) -> CGImage? {
        let size = target.bounds.size
        guard size.width > 0, size.height > 0, size.width * size.height <= 2_097_152 else { return nil }
        let transform = Self.localToCanvas(target)
        guard abs(transform.a * transform.d - transform.b * transform.c) > 0.000001,
              let context = CGContext(data: nil, width: Int(ceil(size.width)), height: Int(ceil(size.height)), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.concatenate(transform.inverted())
        context.draw(video, in: CGRect(origin: .zero, size: canvas))
        let below = layers.filter { $0.zPosition < target.zPosition && !$0.isHidden && $0.opacity > 0 }
            .sorted { $0.zPosition < $1.zPosition }
        for child in below {
            context.saveGState()
            context.concatenate(Self.localToCanvas(child))
            child.render(in: context)
            context.restoreGState()
        }
        return context.makeImage()
    }
    static func localToCanvas(_ layer: CALayer) -> CGAffineTransform {
        var transform = layer.affineTransform()
        transform.tx = layer.position.x; transform.ty = layer.position.y
        return transform.translatedBy(x: -layer.bounds.width * layer.anchorPoint.x, y: -layer.bounds.height * layer.anchorPoint.y)
    }
    private func applyValues() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for item in plan.layers {
            guard let target = rendered[item.model.id], let state = values[item.model.id] else { continue }
            let origin = vector(state["origin"], [item.model.origin.x,item.model.origin.y,item.model.origin.z])
            let scale = vector(state["scale"], [1,1,1]), angles = vector(state["angles"], [0,0,0])
            var size = CGSize(width:item.model.size.width,height:item.model.size.height)
            var anchor = CGPoint(x:item.alignment.contains("left") ? 0 : item.alignment.contains("right") ? 1 : 0.5,
                                 y:item.alignment.contains("top") ? 1 : item.alignment.contains("bottom") ? 0 : 0.5)
            if let text = target as? CATextLayer, let definition = item.model.text {
                let value = state["text"] as? String ?? ""
                text.string = value
                let rgb = vector(state["color"], [definition.color.red, definition.color.green, definition.color.blue])
                text.foregroundColor = NSColor(srgbRed: min(1,max(0,rgb[0])), green: min(1,max(0,rgb[1])), blue: min(1,max(0,rgb[2])), alpha: 1).cgColor
                if let measured = plan.metrics.measure(id:item.model.id,text:value), let style = plan.metrics.styles[item.model.id] {
                    // Padding belongs to the text's layout/measurement bounds;
                    // glyphs are inset so script scrolling uses the same width.
                    size.width = max(1,measured[0]-style.padding*2)
                    size.height = CTFontGetAscent(style.font)+CTFontGetDescent(style.font)+CTFontGetLeading(style.font)
                }
                anchor.x = definition.horizontalAlignment == .left ? 0 : definition.horizontalAlignment == .right ? 1 : 0.5
                anchor.y = definition.verticalAlignment == .top ? 1 : definition.verticalAlignment == .bottom ? 0 : 0.5
            }
            target.bounds = CGRect(origin:.zero,size:size); target.anchorPoint = anchor
            target.position = CGPoint(x:origin[0],y:origin[1])
            target.transform = CATransform3DScale(CATransform3DMakeRotation(angles[2] * .pi/180,0,0,1),scale[0],scale[1],1)
            target.opacity = Float(min(1,max(0,state["alpha"] as? Double ?? 1)))
            target.isHidden = !(state["visible"] as? Bool ?? true) || abs(origin[2]) > 1000
        }
        for particle in plan.particles {
            guard let target = emitters[particle.model.id]?.layer, let state = values[particle.model.id] else { continue }
            let origin = vector(state["origin"],[particle.model.origin.x,particle.model.origin.y,0])
            target.position = CGPoint(x:origin[0],y:origin[1]); target.isHidden = !(state["visible"] as? Bool ?? true)
            let scale = vector(state["scale"], [1,1,1])
            target.setAffineTransform(CGAffineTransform(scaleX: scale[0], y: scale[1]))
            target.opacity = Float(min(1, max(0, state["alpha"] as? Double ?? 1)))
        }
        for item in plan.compositions {
            guard let target = rendered[item.model.id], let state = values[item.model.id] else { continue }
            let origin = vector(state["origin"], [item.model.origin.x, item.model.origin.y, item.model.origin.z])
            let scale = vector(state["scale"], [item.model.scale.x, item.model.scale.y, item.model.scale.z])
            let angles = vector(state["angles"], [0, 0, 0])
            target.bounds = CGRect(x: 0, y: 0, width: item.model.size.width, height: item.model.size.height)
            target.anchorPoint = CGPoint(x: item.alignment.contains("left") ? 0 : item.alignment.contains("right") ? 1 : 0.5,
                                         y: item.alignment.contains("top") ? 1 : item.alignment.contains("bottom") ? 0 : 0.5)
            target.position = CGPoint(x: origin[0], y: origin[1])
            target.transform = CATransform3DScale(CATransform3DMakeRotation(angles[2] * .pi / 180, 0, 0, 1), scale[0], scale[1], 1)
            target.opacity = Float(min(1, max(0, state["alpha"] as? Double ?? 1)))
            target.isHidden = !(state["visible"] as? Bool ?? true) || abs(origin[2]) > 1000
        }
    }
    func setPlaybackSuspended(_ value: Bool) {
        guard !closed, suspended != value else { return }; suspended = value
        background.setPlaybackSuspended(value); session.setSuspended(value)
        if value { stopInputs() } else { resume() }
    }
    private func stopInputs() {
        shaderGeneration += 1; shaderTask?.cancel()
        timer?.invalidate(); timer = nil
        if let mediaConsumer { MusicMetadataSource.shared.release(mediaConsumer) }; mediaConsumer = nil
        if let audioConsumer { SystemAudioAnalysis.shared.release(audioConsumer) }; audioConsumer = nil
    }
    func setDisplayMode(_ mode: WallpaperDisplayMode) { layoutOverlay() }
    func setAudioEnabled(_ enabled: Bool, volume: Double) { background.setAudioEnabled(enabled, volume: volume) }
    func prepareForClose() { closed = true; stopInputs(); session.close(); background.prepareForClose() }
    private func vector(_ value: Any?, _ fallback: [Double]) -> [Double] {
        guard let v = value as? [Double], v.count == 3, v.allSatisfy({ $0.isFinite && abs($0)<1e7 }) else { return fallback }; return v
    }
    private func color(_ value: SceneColor) -> CGColor { NSColor(srgbRed:value.red,green:value.green,blue:value.blue,alpha:1).cgColor }
    private static func artworkImage(_ data: Data) -> CGImage? {
        guard data.count <= 8*1024*1024, let source = CGImageSourceCreateWithData(data as CFData,nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,
            kCGImageSourceThumbnailMaxPixelSize:1024,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary)
    }
    private func makeMask(_ images: [CGImage], size: SceneSize) -> CALayer? {
        guard let first = images.first else { return nil }
        let extent = CGRect(x:0,y:0,width:first.width,height:first.height)
        var output = CIImage(cgImage:first).applyingFilter("CIMaskToAlpha")
        for image in images.dropFirst() {
            let next = CIImage(cgImage:image).transformed(by:CGAffineTransform(scaleX:extent.width/CGFloat(image.width),y:extent.height/CGFloat(image.height))).applyingFilter("CIMaskToAlpha")
            output = output.applyingFilter("CISourceInCompositing",parameters:[kCIInputBackgroundImageKey:next])
        }
        guard let image = CIContext().createCGImage(output,from:extent) else { return nil }
        let mask = CALayer(); mask.contents = image; mask.frame = CGRect(x:0,y:0,width:size.width,height:size.height)
        return mask
    }
}
