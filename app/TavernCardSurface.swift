import AppKit
import MetalKit
import QuartzCore
import ImageIO

enum TavernCardResourceError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return L("core.card.materialsError", message) }
    }
}

/// Decorative only: the owning native button retains hit testing, text and accessibility.
final class TavernCardSurfaceView: NSView, MTKViewDelegate {
    var lightPositionProvider: (() -> CGPoint)? { didSet { requestFrame() } }
    var magicLightProvider: (() -> (position: CGPoint, colour: SIMD3<Float>, power: Float)?)?
    func refreshLighting() { requestFrame() }
    private let renderer: TavernCardRenderer
    private let metalView: MTKView
    private var seed: UInt64 = 0
    private var construction = TavernPlankConstruction.agent
    private var selected = false
    private var maps: TavernCardMaps?
    private var mapPixelSize = CGSize.zero
    private var mapPointSize = CGSize.zero
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private weak var observedClip: NSClipView?
    private var clipObserver: NSObjectProtocol?
    private var dirty = true
    private var clock: Double = 0
    private var previousTime: CFTimeInterval?

    static func validateResources() throws {
        _ = try TavernCardRenderer.shared.get()
    }

    override init(frame frameRect: NSRect) {
        do { renderer = try TavernCardRenderer.shared.get() }
        catch { fatalError(error.localizedDescription) }
        metalView = MTKView(frame: .zero, device: renderer.device)
        super.init(frame: frameRect)
        setAccessibilityElement(false)
        wantsLayer = true
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.framebufferOnly = true
        metalView.clearColor = MTLClearColorMake(0, 0, 0, 0)
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = false
        metalView.wantsLayer = true
        metalView.layer?.isOpaque = false
        metalView.setAccessibilityElement(false)
        metalView.delegate = self
        addSubview(metalView)
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.didResizeNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.requestFrame()
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in self?.requestFrame() })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        timer?.invalidate()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let clipObserver { NotificationCenter.default.removeObserver(clipObserver) }
    }

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(seed: UInt64, construction: TavernPlankConstruction, selected: Bool) {
        guard self.seed != seed || self.construction != construction || self.selected != selected || maps == nil else { return }
        self.seed = seed
        self.construction = construction
        self.selected = selected
        maps = nil
        requestFrame()
    }

    override func layout() {
        super.layout()
        metalView.frame = bounds
        watchClipView()
        requestFrame()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        watchClipView()
        requestFrame()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        watchClipView()
        requestFrame()
    }

    override func viewDidHide() { super.viewDidHide(); updateClock() }
    override func viewDidUnhide() { super.viewDidUnhide(); requestFrame() }

    private var visible: Bool {
        guard let window, window.isVisible, !window.isMiniaturized,
              window.occlusionState.contains(.visible), !NSApp.isHidden,
              !isHiddenOrHasHiddenAncestor, !visibleRect.isEmpty,
              bounds.width > 0, bounds.height > 0 else { return false }
        return true
    }

    private func watchClipView() {
        let clip = enclosingScrollView?.contentView
        guard observedClip !== clip else { return }
        if let clipObserver { NotificationCenter.default.removeObserver(clipObserver) }
        clipObserver = nil
        observedClip = clip
        if let clip {
            clip.postsBoundsChangedNotifications = true
            clipObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                object: clip, queue: .main) { [weak self] _ in self?.requestFrame() }
        }
    }

    private func requestFrame() {
        dirty = true
        updateClock()
        if visible { metalView.draw() }
    }

    private func updateClock() {
        let run = visible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if run && timer == nil {
            previousTime = nil
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                guard self.visible else { self.updateClock(); return }
                self.metalView.draw()
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !run {
            timer?.invalidate()
            timer = nil
            previousTime = nil
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        dirty = true
    }

    func draw(in view: MTKView) {
        guard visible else { updateClock(); return }
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard dirty || !reduced else { return }
        let width = Int(view.drawableSize.width.rounded())
        let height = Int(view.drawableSize.height.rounded())
        guard width > 0, height > 0,
              let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor,
              let command = renderer.queue.makeCommandBuffer() else { return }
        encode(width: width, height: height, pass: pass, command: command)
        command.present(drawable)
        command.addCompletedHandler { command in
            if command.status == .error {
                fatalError(L("core.card.renderFailed", String(describing: command.error)))
            }
        }
        command.commit()
        dirty = false
    }

    private func encode(width: Int, height: Int, pass: MTLRenderPassDescriptor, command: MTLCommandBuffer) {
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let pixelSize = CGSize(width: width, height: height)
        if maps == nil || mapPixelSize != pixelSize || mapPointSize != bounds.size {
            let key = "\(seed):\(construction.rawValue):\(width)x\(height):\(bounds.width)x\(bounds.height)"
            do {
                maps = try renderer.maps(seed: seed, construction: construction, selected: selected, width: width,
                    height: height, pointSize: bounds.size, key: key)
                mapPixelSize = pixelSize
                mapPointSize = bounds.size
            } catch { fatalError(error.localizedDescription) }
        }
        guard let maps else { fatalError("Tavern materials: encode requires prepared maps") }
        let now = CACurrentMediaTime()
        if !reduced {
            if let previousTime { clock += min(now - previousTime, 0.1) }
            previousTime = now
        }
        let flicker = reduced ? 1 : 1 + 0.035 * sin(clock * 5.3)
            + 0.025 * sin(clock * 8.71) + 0.012 * sin(clock * 13.5)
        // Read every drawn frame: scrolling changes the fixed lantern's local position.
        // Without a configured real lamp the card receives ambient light only.
        let light = lightPositionProvider?()
        let scale = min(1, bounds.height / 140)
        let magic = magicLightProvider?()
        let sceneWidth = Float(bounds.width / scale)
        let sceneHeight = Float(bounds.height / scale)
        var uniforms = TavernCardUniforms(
            geometry: SIMD4(sceneWidth, sceneHeight, 1, 1),
            lamp: SIMD4(Float((light?.x ?? 0) / scale), Float((light?.y ?? 0) / scale),
                        132, light == nil ? 0 : Float(flicker)),
            magicPosition: SIMD4(Float((magic?.position.x ?? 0) / scale), Float((magic?.position.y ?? 0) / scale),
                                 42, magic?.power ?? 0),
            magicColour: SIMD4(magic?.colour.x ?? 0, magic?.colour.y ?? 0, magic?.colour.z ?? 0, selected ? 1 : 0))
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            fatalError(L("core.card.encoderFailed"))
        }
        encoder.setRenderPipelineState(renderer.pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<TavernCardUniforms>.stride, index: 0)
        for (index, texture) in maps.textures.enumerated() { encoder.setFragmentTexture(texture, index: index) }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    // cacheDisplay не читает CAMetalLayer. Readback нужен только при создании
    // образа перетаскивания, а обычные кадры остаются framebufferOnly.
    func snapshotImage() -> CGImage? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = window?.backingScaleFactor ?? 2
        let width = max(1, Int((bounds.width * scale).rounded()))
        let height = max(1, Int((bounds.height * scale).rounded()))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .renderTarget
        guard let texture = renderer.device.makeTexture(descriptor: descriptor),
              let command = renderer.queue.makeCommandBuffer(),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let data = context.data else {
            fatalError(L("core.card.snapshotUnavailable"))
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        encode(width: width, height: height, pass: pass, command: command)
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else {
            fatalError(L("core.card.snapshotFailed", String(describing: command.error)))
        }
        texture.getBytes(data, bytesPerRow: width * 4,
                         from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return context.makeImage()
    }
}

private struct TavernCardUniforms {
    var geometry: SIMD4<Float>
    var lamp: SIMD4<Float>
    var magicPosition: SIMD4<Float>
    var magicColour: SIMD4<Float> // RGB: talisman light; W: steady selection illumination.
}

private final class TavernCardMaps: NSObject {
    let textures: [MTLTexture]
    init(_ textures: [MTLTexture]) { self.textures = textures }
}

private final class TavernCardRenderer {
    static let shared: Result<TavernCardRenderer, Error> = Result { try TavernCardRenderer() }
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    private let cache = NSCache<NSString, TavernCardMaps>()
    private let plankCache = NSCache<NSString, TavernPlankMaps>()
    private var sources: [String: CGImage] = [:]
    private let root: URL
    private let planks: TavernPlankMaterial

    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw TavernCardResourceError.invalid(L("core.card.metalUnavailable"))
        }
        self.device = device
        self.queue = queue
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("Textures/TavernVisuals"),
              let shader = Bundle.main.url(forResource: "TavernCard", withExtension: "metal", subdirectory: "Shaders") else {
            throw TavernCardResourceError.invalid(L("core.card.missingResources"))
        }
        self.root = root
        let atlasURL = root.appendingPathComponent("materials/plank-atlas.png")
        guard let atlasSource = CGImageSourceCreateWithURL(atlasURL as CFURL, nil),
              let atlas = CGImageSourceCreateImageAtIndex(atlasSource, 0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              atlas.width > 1, atlas.height > 1 else {
            throw TavernCardResourceError.invalid(L("core.card.unreadableFile", atlasURL.path))
        }
        planks = try TavernPlankMaterial(atlas: atlas)
        let library = try device.makeLibrary(source: String(contentsOf: shader, encoding: .utf8), options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "tavernCardVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "tavernCardFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        cache.totalCostLimit = 96 * 1024 * 1024
        cache.countLimit = 72
        plankCache.totalCostLimit = 32 * 1024 * 1024
        plankCache.countLimit = 48
        for suffix in ["", "-height", "-material"] { _ = try image("sprites/bookmark\(suffix)") }
    }

    private func image(_ path: String) throws -> CGImage {
        if let image = sources[path] { return image }
        let url = root.appendingPathComponent(path).appendingPathExtension("png")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary), image.width > 0, image.height > 0 else {
            throw TavernCardResourceError.invalid(L("core.card.unreadableFile", url.path))
        }
        sources[path] = image
        return image
    }

    private func bookmarkMap(kind: Int) throws -> CGImage {
        let key = "bookmark-map:\(kind)"
        if let image = sources[key] { return image }
        let alpha = try image("sprites/bookmark")
        let context = try TavernPlankMaterial.context(width: alpha.width, height: alpha.height)
        let rect = CGRect(x: 0, y: 0, width: alpha.width, height: alpha.height)
        if kind == 2 {
            context.setFillColor(CGColor(red: 128.0 / 255, green: 128.0 / 255, blue: 1, alpha: 1))
            context.fill(rect)
        } else {
            let suffix = ["", "-height", "", "-material"][kind]
            context.draw(try image("sprites/bookmark" + suffix), in: rect)
        }
        if kind != 0 {
            context.setBlendMode(.destinationIn)
            context.draw(alpha, in: rect)
            context.setBlendMode(.normal)
        }
        guard let image = context.makeImage() else { throw TavernCardResourceError.invalid(L("core.card.mapUnavailable", key)) }
        sources[key] = image
        return image
    }

    private func contactShadow() throws -> CGImage {
        if let image = sources["bookmark-contact"] { return image }
        // The reference stamp is 36x112, bookmark at (10,9), blur 2.3, shadow offset (1.5,3).
        let context = try TavernPlankMaterial.context(width: 36, height: 112)
        // Drawing outside the clip lets Quartz emit only the shadow, not the source bookmark.
        context.saveGState()
        context.setShadow(offset: CGSize(width: 1.5 + 100, height: -3), blur: 2.3,
            color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.72))
        context.draw(try image("sprites/bookmark"), in: CGRect(x: -90, y: 15, width: 16, height: 88))
        context.restoreGState()
        guard let image = context.makeImage() else { throw TavernCardResourceError.invalid(L("core.card.shadowUnavailable")) }
        sources["bookmark-contact"] = image
        return image
    }

    func maps(seed: UInt64, construction: TavernPlankConstruction, selected: Bool,
              width: Int, height: Int, pointSize: CGSize, key: String) throws -> TavernCardMaps {
        let textureKey = "\(key):\(selected)" as NSString
        if let maps = cache.object(forKey: textureKey) { return maps }
        let base: TavernPlankMaps
        if let cached = plankCache.object(forKey: key as NSString) {
            base = cached
        } else {
            base = try planks.build(seed: seed, construction: construction,
                width: width, height: height, pointSize: pointSize)
            plankCache.setObject(base, forKey: key as NSString, cost: width * height * 16)
        }
        let scale = min(1, pointSize.height / 140)
        let xScale = CGFloat(width) / pointSize.width
        let yScale = CGFloat(height) / pointSize.height
        let unitX = scale * xScale, unitY = scale * yScale
        let board = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        var textures: [MTLTexture] = []
        for kind in 0..<4 {
            let context: CGContext
            if selected {
                context = try TavernPlankMaterial.context(width: width, height: height)
                guard let image = base.contexts[kind].makeImage() else {
                    throw TavernCardResourceError.invalid(L("core.card.woodMapUnavailable"))
                }
                context.draw(image, in: board)
            } else {
                context = base.contexts[kind]
            }
            func draw(_ image: CGImage, in rect: CGRect) {
                context.draw(image, in: CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY,
                                              width: rect.width, height: rect.height))
            }
            if selected {
                if kind == 0 {
                    context.saveGState()
                    let clip = board.insetBy(dx: 5 * unitX, dy: 5 * unitY)
                    context.clip(to: CGRect(x: clip.minX, y: CGFloat(height) - clip.maxY, width: clip.width, height: clip.height))
                    draw(try contactShadow(), in: CGRect(x: CGFloat(width) - 92 * unitX, y: -5 * unitY, width: 36 * unitX, height: 112 * unitY))
                    context.restoreGState()
                }
                draw(try bookmarkMap(kind: kind),
                    in: CGRect(x: CGFloat(width) - 82 * unitX, y: 4 * unitY, width: 16 * unitX, height: 88 * unitY))
            }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                width: width, height: height, mipmapped: false)
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: descriptor), let data = context.data else {
                throw TavernCardResourceError.invalid(L("core.card.textureUnavailable"))
            }
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: data, bytesPerRow: width * 4)
            textures.append(texture)
        }
        let maps = TavernCardMaps(textures)
        cache.setObject(maps, forKey: textureKey, cost: width * height * 16)
        return maps
    }
}
