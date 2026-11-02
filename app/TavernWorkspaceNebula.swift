import AppKit
import MetalKit
import QuartzCore
import ImageIO
import CoreImage
import Accelerate

// Fixed layout: seven pairs of float4, shared verbatim with both Metal shaders.
struct TavernNebulaLight {
    var position: SIMD4<Float> = .zero // card-surface points XYZ, power
    var colour: SIMD4<Float> = .zero // linear RGB, radius in points
}
struct TavernNebulaLighting {
    var a = TavernNebulaLight(), b = TavernNebulaLight(), c = TavernNebulaLight()
    var d = TavernNebulaLight(), e = TavernNebulaLight(), f = TavernNebulaLight()
    var g = TavernNebulaLight()
    static let none = TavernNebulaLighting()
    subscript(index: Int) -> TavernNebulaLight {
        get {
            switch index { case 0: return a; case 1: return b; case 2: return c
            case 3: return d; case 4: return e; case 5: return f; default: return g }
        }
        set {
            switch index { case 0: a = newValue; case 1: b = newValue; case 2: c = newValue
            case 3: d = newValue; case 4: e = newValue; case 5: f = newValue; default: g = newValue }
        }
    }
    func scaled(by scale: Float) -> Self {
        var result = self
        for i in 0..<7 {
            var light = result[i]
            light.position.x *= scale; light.position.y *= scale; light.position.z *= scale
            light.colour.w *= scale
            result[i] = light
        }
        return result
    }
}

final class TavernWorkspaceNebulaResources {
    let atlas: MTLTexture
    let pipeline: MTLRenderPipelineState
    private let weights: [Float]
    // ImageIO's provider stores PNG scanlines top-to-bottom. Read those scanlines
    // directly: a Quartz drawing transform must never reorder atlas cells or light rows.
    private static func rgbaData(_ image: CGImage, url: URL) throws -> CFData {
        let order = image.bitmapInfo.intersection(.byteOrderMask)
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32,
              order.isEmpty || order == .byteOrder32Big,
              image.alphaInfo == .last || image.alphaInfo == .premultipliedLast,
              image.bytesPerRow >= image.width * 4,
              let data = image.dataProvider?.data,
              CFDataGetLength(data) >= image.bytesPerRow * image.height else {
            throw TavernCardResourceError.invalid(L("core.card.unreadableFile", url.path))
        }
        return data
    }
    init(device: MTLDevice, root: URL, library: MTLLibrary) throws {
        precondition(!Thread.isMainThread)
        let url = root.appendingPathComponent("nebula/workspace-nebula.png")
        guard let atlasSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let atlasImage = CGImageSourceCreateImageAtIndex(atlasSource, 0, nil),
              atlasImage.width == 7104, atlasImage.height == 2700 else {
            throw TavernCardResourceError.invalid(L("core.card.unreadableFile", url.path))
        }
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 7104, height: 2700, mipmapped: false)
        textureDescriptor.storageMode = .shared
        textureDescriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            throw TavernCardResourceError.invalid(L("core.card.textureUnavailable"))
        }
        // Preserve the PNG's exact row order and sRGB channel values. Metal samples
        // UNORM and the external screen compositor works in the same encoded space.
        let atlasData = try Self.rgbaData(atlasImage, url: url)
        defer { withExtendedLifetime(atlasData) {} }
        let sourcePixels = CFDataGetBytePtr(atlasData)!
        let region = MTLRegionMake2D(0, 0, 7104, 2700)
        if atlasImage.alphaInfo == .premultipliedLast {
            texture.replace(region: region, mipmapLevel: 0, withBytes: sourcePixels,
                bytesPerRow: atlasImage.bytesPerRow)
        } else {
            var atlasBytes = [UInt8](repeating: 0, count: 7104 * 2700 * 4)
            let status = atlasBytes.withUnsafeMutableBytes { storage -> vImage_Error in
                var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: sourcePixels),
                    height: vImagePixelCount(2700), width: vImagePixelCount(7104),
                    rowBytes: atlasImage.bytesPerRow)
                var destination = vImage_Buffer(data: storage.baseAddress!,
                    height: vImagePixelCount(2700), width: vImagePixelCount(7104),
                    rowBytes: 7104 * 4)
                let result = vImagePremultiplyData_RGBA8888(&source, &destination,
                    vImage_Flags(kvImageNoFlags))
                if result == kvImageNoError {
                    texture.replace(region: region, mipmapLevel: 0,
                        withBytes: storage.baseAddress!, bytesPerRow: destination.rowBytes)
                }
                return result
            }
            guard status == kvImageNoError else {
                throw TavernCardResourceError.invalid(L("core.card.unreadableFile", url.path))
            }
        }
        atlas = texture
        let weightURL = root.appendingPathComponent("nebula/workspace-nebula-weights.png")
        guard let source = CGImageSourceCreateWithURL(weightURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == 240, image.height == 7 else {
            throw TavernCardResourceError.invalid(L("core.card.unreadableFile", weightURL.path))
        }
        let weightData = try Self.rgbaData(image, url: weightURL)
        defer { withExtendedLifetime(weightData) {} }
        let weightPixels = CFDataGetBytePtr(weightData)!
        weights = (0..<(240 * 7)).map {
            Float(weightPixels[($0 / 240) * image.bytesPerRow + ($0 % 240) * 4]) / 255
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "tavernCardVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "tavernWorkspaceNebulaFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }
    func lighting(seconds: Double, size: NSSize) -> TavernNebulaLighting {
        let t = Float(seconds.truncatingRemainder(dividingBy: 10))
        let angle = t * .pi / 5
        let sx = Float(size.width) / 394.5, sy = Float(size.height) / 90.5
        let unit = min(sx, sy)
        var result = TavernNebulaLighting.none
        for i in 0..<7 {
            let reference: SIMD4<Float>, rgb: SIMD3<Float>, phase: Float
            switch i {
            case 0: reference = SIMD4(93, 127, 18, 36); rgb = SIMD3(75, 185, 255); phase = 0.2
            case 1: reference = SIMD4(172, 132, 18, 27); rgb = SIMD3(246, 87, 208); phase = 2.3
            case 2: reference = SIMD4(322, 133, 18, 30); rgb = SIMD3(128, 115, 255); phase = 4.1
            case 3: reference = SIMD4(418, 177, 18, 17); rgb = SIMD3(65, 168, 255); phase = 1.7
            case 4: reference = SIMD4(105, 128, 16, 28); rgb = SIMD3(126, 221, 255); phase = 1.4
            case 5: reference = SIMD4(401, 139, 16, 22); rgb = SIMD3(255, 163, 69); phase = 4.8
            default: reference = SIMD4(239, 131, 16, 32); rgb = SIMD3(255, 112, 211); phase = 8.1
            }
            let x = reference.x + (i < 4 ? 6 * sin(angle + phase) : 0)
            let y = reference.y + (i < 4 ? 3 * cos(angle * 2 + phase) : 0)
            let distance = (t - phase + 15).truncatingRemainder(dividingBy: 10) - 5
            let pulse = exp(-pow(distance / 0.45, 2))
            let power: Float = i < 4 ? 0.30 + 0.34 * (0.5 + 0.5 * sin(angle + phase)) : (pulse > 0.002 ? pulse * 0.95 : 0)
            result[i] = TavernNebulaLight(
                position: SIMD4((x - 22.5) * sx, (y - 138.5) * sy, reference.z * unit, power),
                colour: SIMD4(pow(rgb.x / 255, 2.2), pow(rgb.y / 255, 2.2), pow(rgb.z / 255, 2.2), reference.w * unit))
        }
        return result
    }
    func coupled(_ lights: TavernNebulaLighting, seconds: Double) -> TavernNebulaLighting {
        var result = lights
        let frame = Int((seconds * 24).rounded()) % 240
        for i in 0..<7 { var light = result[i]; light.position.w *= weights[i * 240 + frame]; result[i] = light }
        return result
    }
}

private struct TavernNebulaUniforms {
    var geometry: SIMD4<Float> // view width/height, surface width/height
    var timing: SIMD4<Float> // seconds, atlas frame, surface inset, reserved
    var clip: SIMD4<Float> // actual visible bounds, minXY/maxXY
    var tint: SIMD4<Float> // sRGB agent colour, strength; zero means workspace
}

private final class TavernNebulaMetalHost: NSView {
    override var isOpaque: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override func makeBackingLayer() -> CALayer { CAMetalLayer() }
}

enum TavernNebulaAnimationTime {
    static func advancing(from previous: Double, to requested: Double) -> Double {
        let difference = requested - previous
        // Float shader uniforms can round a repeated timestamp slightly backward.
        if abs(difference) < 0.00001 { return previous }
        let elapsed = difference < 0 ? difference + 10 : difference
        return elapsed <= 0.1 ? requested :
            (previous + 0.1).truncatingRemainder(dividingBy: 10)
    }
}

// Each layer owns its timeline. Metal invokes presented handlers off main;
// this state must never share AppKit's animation/geometry fields.
final class TavernMetalPresentationMetrics {
    private let lock = NSLock()
    private var lastPresentedTime: CFTimeInterval?
    private var generation: UInt64 = 0
    private let stage: TavernPerformance.Stage
    private let counter: TavernPerformance.Counter

    init(stage: TavernPerformance.Stage, counter: TavernPerformance.Counter) {
        self.stage = stage
        self.counter = counter
    }

    func suspend() {
        guard TavernPerformance.shared.isEnabled else { return }
        lock.lock()
        generation &+= 1
        lastPresentedTime = nil
        lock.unlock()
    }

    func frameToken(continuous: Bool) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        if !continuous {
            generation &+= 1
            lastPresentedTime = nil
            return nil
        }
        return generation
    }

    func presented(at time: CFTimeInterval, token: UInt64?) {
        guard time.isFinite, time > 0 else { return }
        TavernPerformance.shared.count(counter)
        guard let token else { return }
        lock.lock()
        guard token == generation else { lock.unlock(); return }
        let previous = lastPresentedTime
        if previous == nil || time > previous! { lastPresentedTime = time }
        lock.unlock()
        if let previous, time > previous {
            TavernPerformance.shared.duration(stage, nanoseconds: UInt64((time - previous) * 1_000_000_000))
        }
    }

    static func gpu(_ command: MTLCommandBuffer, stage: TavernPerformance.Stage) {
        guard TavernPerformance.shared.isEnabled else { return }
        let start = command.gpuStartTime, end = command.gpuEndTime
        guard command.status == .completed, start > 0, end >= start else { return }
        TavernPerformance.shared.duration(stage, nanoseconds: UInt64((end - start) * 1_000_000_000))
    }
}

// One job (including GPU execution) and one latest snapshot per view. Geometry
// belongs to AppKit; this worker never reads an NSView or waits for main.
private final class TavernNebulaRenderWorker {
    private struct Configuration: Equatable {
        let geometry: SIMD4<Float>
        let clip: SIMD4<Float>
        let tint: SIMD4<Float>
        let drawableSize: CGSize
        let animated: Bool
    }
    struct Frame {
        var uniforms: TavernNebulaUniforms
        let cardSize: NSSize
        let drawableSize: CGSize
        let animated: Bool
        #if TAVERN_RENDER_TESTING
        var gate: (() -> Void)?
        var completionGate: (() -> Void)?
        #endif
    }
    private let layer: CAMetalLayer
    private let resources: TavernWorkspaceNebulaResources
    private let commandQueue: MTLCommandQueue
    private let queue = DispatchQueue(label: "org.herdr.tavern.nebula", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: Frame?
    private var running = false
    private var generation: UInt64 = 0
    private var configuration: Configuration?
    private var configurationRevision: UInt64 = 0
    // Only the serial render queue accesses animation continuity.
    private var previousSeconds: Double?
    private var previousGeneration: UInt64?
    private let presentationMetrics = TavernMetalPresentationMetrics(stage: .nebulaPresentation, counter: .nebulaPresented)
    private let completed: (TavernNebulaLighting, Double, CGSize) -> Void

    init(layer: CAMetalLayer, renderer: TavernCardRenderer,
         completed: @escaping (TavernNebulaLighting, Double, CGSize) -> Void) {
        self.layer = layer
        resources = renderer.nebula
        commandQueue = renderer.queue
        self.completed = completed
    }

    func submit(_ frame: Frame) {
        lock.lock()
        let next = Configuration(geometry: frame.uniforms.geometry, clip: frame.uniforms.clip,
                                 tint: frame.uniforms.tint, drawableSize: frame.drawableSize,
                                 animated: frame.animated)
        if configuration != next {
            configuration = next
            configurationRevision &+= 1
        }
        let replaced = pending != nil
        pending = frame
        let start = !running
        running = true
        lock.unlock()
        if replaced { TavernPerformance.shared.count(.nebulaReplaced) }
        if start { queue.async { self.render() } }
    }

    func suspend() {
        lock.lock()
        pending = nil
        generation &+= 1
        presentationMetrics.suspend()
        lock.unlock()
    }

    private func render() {
        autoreleasepool {
            lock.lock()
            guard let initialFrame = pending else {
                running = false
                lock.unlock()
                return
            }
            let token = generation
            pending = nil
            lock.unlock()
            #if TAVERN_RENDER_TESTING
            initialFrame.gate?()
            #endif
            lock.lock()
            let active = token == generation
            lock.unlock()
            guard active else {
                finish()
                return
            }
            // Drawable acquisition may block the worker, never the main thread.
            let drawableSpan = TavernPerformance.shared.begin(.nebulaDrawable)
            let acquiredDrawable = layer.nextDrawable()
            TavernPerformance.shared.end(drawableSpan)
            guard let drawable = acquiredDrawable else {
                TavernPerformance.shared.count(.nebulaUnavailable)
                finish()
                return
            }
            lock.lock()
            guard token == generation else {
                lock.unlock()
                finish()
                return
            }
            let frame = pending ?? initialFrame
            pending = nil
            let revision = configurationRevision
            let presentationToken = TavernPerformance.shared.isEnabled
                ? presentationMetrics.frameToken(continuous: frame.animated) : nil
            lock.unlock()
            // A resize on main can replace the drawable pool during acquisition.
            guard drawable.texture.width == Int(frame.drawableSize.width),
                  drawable.texture.height == Int(frame.drawableSize.height) else {
                TavernPerformance.shared.count(.nebulaUnavailable)
                finish()
                return
            }
            let encodeSpan = TavernPerformance.shared.begin(.nebulaEncode)
            var uniforms = frame.uniforms
            let requested = Double(uniforms.timing.x)
            let seconds: Double
            if frame.animated, previousGeneration == token, let previousSeconds {
                seconds = TavernNebulaAnimationTime.advancing(from: previousSeconds, to: requested)
            } else {
                seconds = requested
            }
            uniforms.timing.x = Float(seconds)
            uniforms.timing.y = Float(Int((seconds * 24).rounded()) % 240)
            var lights = resources.lighting(seconds: seconds, size: frame.cardSize)
            var materialLights = resources.coupled(lights, seconds: seconds)
            if uniforms.tint.w > 0 {
                let tint = uniforms.tint
                let colour = SIMD3(pow(tint.x, 2.2), pow(tint.y, 2.2), pow(tint.z, 2.2))
                for index in 0..<7 {
                    var light = materialLights[index]
                    light.colour = SIMD4(colour.x, colour.y, colour.z, light.colour.w)
                    light.position.w *= index < 4 ? 0.18 : 0
                    materialLights[index] = light
                }
            }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            guard let command = commandQueue.makeCommandBuffer(),
                  let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
                TavernPerformance.shared.end(encodeSpan)
                TavernPerformance.shared.count(.nebulaUnavailable)
                finish()
                return
            }
            encoder.setRenderPipelineState(resources.pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<TavernNebulaUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&lights, length: MemoryLayout<TavernNebulaLighting>.stride, index: 1)
            encoder.setFragmentTexture(resources.atlas, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            TavernPerformance.shared.end(encodeSpan)
            if TavernPerformance.shared.isEnabled {
                let presentationMetrics = self.presentationMetrics
                drawable.addPresentedHandler { drawable in
                    presentationMetrics.presented(at: drawable.presentedTime, token: presentationToken)
                }
            }
            command.present(drawable)
            let publishedLights = materialLights
            command.addCompletedHandler { command in
                TavernMetalPresentationMetrics.gpu(command, stage: .nebulaGPU)
                if command.status == .error {
                    fatalError(L("core.card.renderFailed", String(describing: command.error)))
                }
                self.queue.async {
                    #if TAVERN_RENDER_TESTING
                    frame.completionGate?()
                    #endif
                    self.previousSeconds = seconds
                    self.previousGeneration = frame.animated ? token : nil
                    DispatchQueue.main.async {
                        self.lock.lock()
                        let current = token == self.generation && revision == self.configurationRevision
                        self.lock.unlock()
                        if current { self.completed(publishedLights, seconds, frame.drawableSize) }
                    }
                    self.finish()
                }
            }
            command.commit()
        }
    }

    private func finish() {
        lock.lock()
        let again = pending != nil
        if !again { running = false }
        lock.unlock()
        if again { queue.async { self.render() } }
    }
}

// One clock for every visible workspace. A view never owns an animation timer.
private final class TavernWorkspaceNebulaClock {
    static let shared = TavernWorkspaceNebulaClock()
    private struct Entry { weak var view: TavernWorkspaceNebulaView? }
    private var entries: [Entry] = []
    private var timer: Timer?
    private var previous: CFTimeInterval?
    private(set) var seconds: Double = 0
    func setActive(_ view: TavernWorkspaceNebulaView, active: Bool) {
        let contained = entries.contains { $0.view === view }
        if active && contained { return }
        entries.removeAll { $0.view == nil || $0.view === view }
        if active { entries.append(Entry(view: view)) }
        if entries.isEmpty { timer?.invalidate(); timer = nil; previous = nil }
        else if timer == nil {
            previous = CACurrentMediaTime()
            let tick = Timer(timeInterval: 1 / 24.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                let now = CACurrentMediaTime()
                if let previous = self.previous { self.seconds = (self.seconds + min(0.1, now - previous)).truncatingRemainder(dividingBy: 10) }
                self.previous = now
                for entry in self.entries { entry.view?.clockTick() }
                self.entries.removeAll { $0.view == nil }
                if self.entries.isEmpty { self.timer?.invalidate(); self.timer = nil; self.previous = nil }
            }
            timer = tick
            RunLoop.main.add(tick, forMode: .common)
        }
    }
}

final class TavernWorkspaceNebulaView: NSView {
    static let padding: CGFloat = 18
    #if TAVERN_RENDER_TESTING
    // Set/read on main; the gate is captured in the immutable submitted frame.
    static var renderGate: (() -> Void)?
    static var renderDidComplete: ((Double, CGSize) -> Void)?
    static var renderCompletionGate: (() -> Void)?
    static var motionEnabled: Bool?
    #endif
    var onLightingChange: (() -> Void)?
    private(set) var materialLights = TavernNebulaLighting.none
    private let renderer: TavernCardRenderer
    private let metalView: TavernNebulaMetalHost
    private var renderWorker: TavernNebulaRenderWorker!
    private var cardSize = NSSize.zero
    private var enabled = false
    private var agentTint = SIMD4<Float>(repeating: 0)
    private let phaseOffset = Double.random(in: 0..<10)
    private var observers: [NSObjectProtocol] = []
    private var windowObservers: [NSObjectProtocol] = []
    private weak var clip: NSClipView?
    private var clipObserver: NSObjectProtocol?
    private var suspended = true
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override init(frame: NSRect) {
        do { renderer = try TavernCardRenderer.shared.get() }
        catch { fatalError(error.localizedDescription) }
        metalView = TavernNebulaMetalHost(frame: .zero)
        super.init(frame: frame)
        wantsLayer = true
        guard let screen = CIFilter(name: "CIScreenBlendMode") else {
            fatalError(L("core.talisman.invalidResource", "CIScreenBlendMode"))
        }
        layer?.compositingFilter = screen
        setAccessibilityElement(false)
        metalView.wantsLayer = true
        let metalLayer = metalView.layer as! CAMetalLayer
        metalLayer.device = renderer.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = false
        metalLayer.framebufferOnly = true
        metalLayer.maximumDrawableCount = 2
        metalLayer.allowsNextDrawableTimeout = true
        metalView.setAccessibilityElement(false)
        renderWorker = TavernNebulaRenderWorker(layer: metalLayer, renderer: renderer) { [weak self] lights, seconds, size in
            guard let self else { return }
            self.materialLights = lights
            self.onLightingChange?()
            #if TAVERN_RENDER_TESTING
            Self.renderDidComplete?(seconds, size)
            #endif
        }
        addSubview(metalView)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .tavernMotionDidChange, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() })
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit {
        renderWorker?.suspend()
        for token in observers { NotificationCenter.default.removeObserver(token); NSWorkspace.shared.notificationCenter.removeObserver(token) }
        for token in windowObservers { NotificationCenter.default.removeObserver(token) }
        if let clipObserver { NotificationCenter.default.removeObserver(clipObserver) }
    }
    func configure(cardSize: NSSize, kind: AgentUnreadKind?) {
        guard self.cardSize != cardSize || agentTint != .zero || enabled != (kind != nil) else { return }
        self.cardSize = cardSize
        agentTint = .zero
        enabled = kind != nil
        isHidden = !enabled
        refresh()
    }
    func configure(cardSize: NSSize, agentColor: NSColor) {
        let tint = SIMD4(Float(agentColor.redComponent), Float(agentColor.greenComponent),
                         Float(agentColor.blueComponent), 0.42)
        guard self.cardSize != cardSize || agentTint != tint || !enabled else { return }
        self.cardSize = cardSize
        agentTint = tint
        enabled = true
        isHidden = false
        refresh()
    }
    private var visible: Bool {
        enabled && cardSize.width > 0 && cardSize.height > 0 && !isHiddenOrHasHiddenAncestor
            && !NSApp.isHidden && window?.isVisible == true
            && window?.isMiniaturized == false
            && window?.occlusionState.contains(.visible) == true && bounds.intersects(visibleRect)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        for token in windowObservers { center.removeObserver(token) }
        windowObservers.removeAll()
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification, NSWindow.didResizeNotification] {
                windowObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.refresh() })
            }
        }
        refresh()
    }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); refresh() }
    override func viewDidHide() { super.viewDidHide(); refresh() }
    override func viewDidUnhide() { super.viewDidUnhide(); refresh() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); refresh() }
    override func layout() {
        super.layout()
        metalView.frame = bounds
        let next = enclosingScrollView?.contentView
        if next !== clip {
            if let clipObserver { NotificationCenter.default.removeObserver(clipObserver) }
            clip = next
            next?.postsBoundsChangedNotifications = true
            clipObserver = next.map { NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                object: $0, queue: .main) { [weak self] _ in self?.refresh() } }
        }
        refresh()
    }
    private func refresh() {
        let shown = visible
        #if TAVERN_RENDER_TESTING
        let animated = Self.motionEnabled ?? TavernMotion.enabled
        #else
        let animated = TavernMotion.enabled
        #endif
        TavernWorkspaceNebulaClock.shared.setActive(self, active: shown && animated)
        guard shown else {
            if !suspended {
                renderWorker.suspend()
                suspended = true
                materialLights = .none
                onLightingChange?()
            }
            return
        }
        suspended = false
        let metalLayer = metalView.layer as! CAMetalLayer
        let scale = window?.backingScaleFactor ?? 1
        let drawableSize = CGSize(width: max(1, (bounds.width * scale).rounded()),
                                  height: max(1, (bounds.height * scale).rounded()))
        metalLayer.contentsScale = scale
        if metalLayer.drawableSize != drawableSize { metalLayer.drawableSize = drawableSize }
        var seconds = animated ? TavernWorkspaceNebulaClock.shared.seconds : 0
        if agentTint.w > 0 { seconds = (seconds + phaseOffset).truncatingRemainder(dividingBy: 10) }
        let clipped = bounds.intersection(visibleRect)
        let uniforms = TavernNebulaUniforms(
            geometry: SIMD4(Float(bounds.width), Float(bounds.height), Float(cardSize.width), Float(cardSize.height)),
            timing: SIMD4(Float(seconds), 0, Float(Self.padding + 3), 0),
            clip: SIMD4(Float(clipped.minX), Float(clipped.minY), Float(clipped.maxX), Float(clipped.maxY)),
            tint: agentTint)
        var frame = TavernNebulaRenderWorker.Frame(uniforms: uniforms, cardSize: cardSize,
                                                  drawableSize: drawableSize, animated: animated)
        #if TAVERN_RENDER_TESTING
        frame.gate = Self.renderGate
        frame.completionGate = Self.renderCompletionGate
        #endif
        renderWorker.submit(frame)
    }
    fileprivate func clockTick() { refresh() }
}
