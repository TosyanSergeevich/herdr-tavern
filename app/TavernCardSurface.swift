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

extension Notification.Name {
    static let tavernMemoryPressure = Notification.Name("org.herdr.tavern.memory-pressure")
}

struct TavernPlankKey: Hashable {
    let seed: UInt64
    let construction: TavernPlankConstruction
    let pixelWidth: Int
    let pixelHeight: Int
    let pointWidth: CGFloat
    let pointHeight: CGFloat
}

struct TavernCardMaterialKey: Hashable {
    let plank: TavernPlankKey
    let selected: Bool
}

struct TavernCardShadowKey: Equatable {
    let material: TavernCardMaterialKey
    let pixelWidth: Int
    let pixelHeight: Int
    let geometryBits: SIMD4<UInt32>
    let lampBits: SIMD3<UInt32>

    init(material: TavernCardMaterialKey, pixelWidth: Int, pixelHeight: Int,
         geometry: SIMD4<Float>, lamp: SIMD4<Float>) {
        self.material = material
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        geometryBits = SIMD4(geometry.x.bitPattern, geometry.y.bitPattern,
                             geometry.z.bitPattern, geometry.w.bitPattern)
        lampBits = SIMD3(lamp.x.bitPattern, lamp.y.bitPattern, lamp.z.bitPattern)
    }
}

private struct TavernCardShadow {
    let key: TavernCardShadowKey
    let texture: MTLTexture
}

private enum TavernCardSnapshotError: LocalizedError {
    case unavailable
    case gpu(String)
    case encoder

    var errorDescription: String? {
        switch self {
        case .unavailable: return L("core.card.snapshotUnavailable")
        case .gpu(let message): return L("core.card.snapshotFailed", message)
        case .encoder: return L("core.card.encoderFailed")
        }
    }
}

#if TAVERN_RENDER_TESTING
struct TavernCardSnapshotInputs: Equatable {
    let key: TavernCardMaterialKey
    let bounds: CGRect
    let clock: Double
    let geometry: SIMD4<Float>
    let lamp: SIMD4<Float>
    let magicPosition: SIMD4<Float>
    let magicColour: SIMD4<Float>
}
#endif

private final class TavernCardClock {
    static let shared = TavernCardClock()
    private struct Entry { weak var view: TavernCardSurfaceView? }
    private var views: [Entry] = []
    private var timer: Timer?
    private var interval: TimeInterval = 0

    func setActive(_ view: TavernCardSurfaceView, _ active: Bool) {
        views.removeAll { $0.view == nil || $0.view === view }
        if active { views.append(Entry(view: view)) }
        updateTimer()
    }

    private func updateTimer() {
        let next: TimeInterval = views.isEmpty ? 0 :
            (views.contains { $0.view?.bookmarkAnimating == true } ? 1.0 / 60 : 1.0 / 30)
        guard interval != next else { return }
        timer?.invalidate()
        timer = nil
        interval = next
        guard next > 0 else { return }
        let timer = Timer(timeInterval: next, repeats: true) { [weak self] _ in
            guard let self else { return }
            // clockTick may unregister a hidden view.
            for entry in self.views { entry.view?.clockTick() }
            self.views.removeAll { $0.view == nil }
            self.updateTimer()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
/// Decorative only: the owning native button retains hit testing, text and accessibility.
final class TavernCardSurfaceView: NSView, MTKViewDelegate {
    var lightPositionProvider: (() -> CGPoint)? { didSet { requestFrame() } }
    var magicLightProvider: (() -> (position: CGPoint, colour: SIMD3<Float>, power: Float)?)?
    var nebulaLightingProvider: (() -> TavernNebulaLighting)? { didSet { requestFrame() } }
    func refreshLighting() { requestFrame() }
    private let renderer: TavernCardRenderer
    private let metalView: MTKView
    private var seed: UInt64 = 0
    private var construction = TavernPlankConstruction.agent
    private var selected = false
    private var maps: TavernCardMaps?
    private var materialKey: TavernCardMaterialKey?
    private var visibilityShadow: TavernCardShadow?
    private var preparation: TavernCardPreparation?
    private var preparingKey: TavernCardMaterialKey?
    private var pendingKey: TavernCardMaterialKey?
    private var generation: UInt64 = 0
    private var observers: [NSObjectProtocol] = []
    private var windowObservers: [NSObjectProtocol] = []
    private weak var observedClip: NSClipView?
    private var clipObserver: NSObjectProtocol?
    private var dirty = true
    private var flushScheduled = false
    private var clock: Double = 0
    private var previousTime: CFTimeInterval?
    private var clockActive = false
    private var fastClock = false
    private var geometrySize = CGSize.zero
    private var bookmark = TavernBookmarkMotion()
    private var animatedMaps: TavernCardMaps?
    fileprivate var bookmarkAnimating: Bool { bookmark.isAnimating }
    private var geometryPixels = CGSize.zero
    #if TAVERN_RENDER_TESTING
    var testingVisibilityPolicy: (() -> Bool)?
    var testingReduceMotionPolicy: (() -> Bool)?
    var testingBookmarkTime: CFTimeInterval?
    var onSubmittedFrame: ((TavernCardMaterialKey, CGRect, CGSize) -> Void)?
    // Copied into each immutable job on main; the gate runs only on the readback worker.
    var snapshotCompletionGate: (() -> Void)?
    var testingSnapshotFailure: Error?
    var onSnapshotCaptured: ((TavernCardSnapshotInputs, TavernCardMaps) -> Void)?
    var testingHeldMaps: TavernCardMaps? { maps }
    var testingMaterialKey: TavernCardMaterialKey? { materialKey }
    var testingHeldShadow: MTLTexture? { visibilityShadow?.texture }
    var testingShadowKey: TavernCardShadowKey? { visibilityShadow?.key }
    var testingGeometry: SIMD4<Float>?
    var testingLamp: SIMD4<Float>?
    var testingMagicPosition: SIMD4<Float>?
    var testingMagicColour: SIMD4<Float>?
    var testingClock: Double {
        get { clock }
        set { clock = newValue }
    }
    func testingSetDrawableSize(_ size: CGSize) {
        metalView.autoResizeDrawable = false
        metalView.drawableSize = size
        geometryChanged()
    }
    #endif

    private var bookmarkTime: CFTimeInterval {
        #if TAVERN_RENDER_TESTING
        if let testingBookmarkTime { return testingBookmarkTime }
        #endif
        return CACurrentMediaTime()
    }

    static func prepareResources(completion: @escaping (Result<Void, Error>) -> Void) {
        TavernCardRenderer.prepareResources(completion: completion)
    }

    override convenience init(frame frameRect: NSRect) {
        do { self.init(frame: frameRect, renderer: try TavernCardRenderer.shared.get()) }
        catch { fatalError(error.localizedDescription) }
    }

    init(frame frameRect: NSRect, renderer: TavernCardRenderer) {
        precondition(Thread.isMainThread)
        guard case .success(let ready) = TavernCardRenderer.shared, ready === renderer else {
            preconditionFailure("Card resources must be prepared before constructing a view")
        }
        self.renderer = renderer
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
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.requestFrame()
            })
        }
        observers.append(center.addObserver(forName: .tavernMotionDidChange,
            object: nil, queue: .main) { [weak self] _ in self?.requestFrame() })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in self?.requestFrame() })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        preparation?.cancel()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        if let clipObserver { NotificationCenter.default.removeObserver(clipObserver) }
    }

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(seed: UInt64, construction: TavernPlankConstruction, selected: Bool) {
        bookmark.select(selected, at: bookmarkTime, animated: visible && !reducedMotion)
        let changed = self.seed != seed || self.construction != construction || self.selected != selected
        guard changed || maps == nil else { return }
        if changed {
            self.seed = seed
            self.construction = construction
            self.selected = selected
            generation &+= 1
            maps = nil
            materialKey = nil
            visibilityShadow = nil
        }
        if visible, geometrySize == bounds.size, geometryPixels == metalView.drawableSize, let key = exactKey() {
            prefetch(key)
        }
        requestFrame()
    }

    override func layout() {
        super.layout()
        if metalView.frame != bounds { metalView.frame = bounds }
        watchClipView()
        geometryChanged()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        geometryChanged()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        for observer in windowObservers { center.removeObserver(observer) }
        windowObservers.removeAll()
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification, NSWindow.didResizeNotification] {
                windowObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.requestFrame()
                })
            }
        }
        watchClipView()
        geometryChanged()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        watchClipView()
        requestFrame()
    }

    override func viewDidHide() { super.viewDidHide(); requestFrame() }
    override func viewDidUnhide() { super.viewDidUnhide(); requestFrame() }

    private var visible: Bool {
        // AppKit may report a nonempty visibleRect wholly outside this view.
        guard !isHiddenOrHasHiddenAncestor, bounds.intersects(visibleRect) else { return false }
        #if TAVERN_RENDER_TESTING
        if let testingVisibilityPolicy { return testingVisibilityPolicy() }
        #endif
        guard let window, window.isVisible, !window.isMiniaturized,
              window.occlusionState.contains(.visible), !NSApp.isHidden else { return false }
        return true
    }

    private var reducedMotion: Bool {
        #if TAVERN_RENDER_TESTING
        if let testingReduceMotionPolicy { return testingReduceMotionPolicy() }
        #endif
        return !TavernMotion.enabled
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

    private func exactKey(width: Int? = nil, height: Int? = nil) -> TavernCardMaterialKey? {
        let width = width ?? Int(metalView.drawableSize.width.rounded())
        let height = height ?? Int(metalView.drawableSize.height.rounded())
        guard width > 0, height > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        return TavernCardMaterialKey(plank: TavernPlankKey(seed: seed, construction: construction,
            pixelWidth: width, pixelHeight: height, pointWidth: bounds.width, pointHeight: bounds.height),
            selected: selected && !bookmark.isAnimating)
    }

    private func prefetch(_ key: TavernCardMaterialKey) {
        if let cached = renderer.cachedMaps(for: key) {
            maps = cached
            materialKey = key
            return
        }
        if preparingKey == key { return }
        guard preparation == nil else { pendingKey = key; return }
        let token = generation
        preparingKey = key
        preparation = renderer.requestPreparation(for: key, accepting: { [weak self] in
            guard let self else { return false }
            return self.visible && self.generation == token && self.exactKey() == key
        }) { [weak self] result in
            guard let self else { return }
            self.preparation = nil
            self.preparingKey = nil
            if self.visible && self.generation == token && self.exactKey() == key {
                switch result {
                case .success(let maps):
                    self.maps = maps
                    self.materialKey = key
                    self.requestFrame()
                case .failure(let error):
                    if error is TavernPreparationError { self.requestFrame() }
                    else { fatalError(error.localizedDescription) }
                }
            }
            let pending = self.pendingKey
            self.pendingKey = nil
            if self.visible, let pending, self.exactKey() == pending { self.prefetch(pending) }
        }
    }

    private func requestFrame() {
        dirty = true
        updateClock()
        guard visible, !flushScheduled else { return }
        flushScheduled = true
        RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            guard self.dirty else { return }
            self.metalView.draw()
        }
    }

    private func geometryChanged() {
        let changed = geometrySize != bounds.size || geometryPixels != metalView.drawableSize
        geometrySize = bounds.size
        geometryPixels = metalView.drawableSize
        guard changed else { updateClock(); return }
        if changed {
            generation &+= 1
            maps = nil
            materialKey = nil
            visibilityShadow = nil
            pendingKey = nil
            preparation?.cancel()
        }
        dirty = true
        updateClock()
        if visible { metalView.draw() }
    }

    private func updateClock() {
        let shown = visible
        let wasAnimating = bookmark.isAnimating
        if !shown || reducedMotion { bookmark.finish() }
        else { bookmark.advance(at: bookmarkTime) }
        if wasAnimating && !bookmark.isAnimating {
            animatedMaps = nil
            visibilityShadow = nil
        }
        let run = shown && !reducedMotion
        if clockActive != run || fastClock != bookmark.isAnimating {
            clockActive = run
            fastClock = bookmark.isAnimating
            TavernCardClock.shared.setActive(self, run)
        }
        if !run { previousTime = nil }
        if !shown {
            generation &+= 1
            preparation?.cancel()
            pendingKey = nil
            maps = nil
            materialKey = nil
            visibilityShadow = nil
        }
    }

    fileprivate func clockTick() {
        guard visible, !reducedMotion else { updateClock(); return }
        dirty = true
        // A pending invalidation and this periodic tick share the deferred flush.
        requestFrame()
    }

    private func advanceClock() {
        let now = CACurrentMediaTime()
        if !reducedMotion {
            if let previousTime { clock += min(now - previousTime, 0.1) }
            previousTime = now
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        dirty = true
    }

    func draw(in view: MTKView) {
        guard visible else { updateClock(); return }
        guard dirty || !reducedMotion, let key = exactKey(),
              let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor,
              let command = renderer.queue.makeCommandBuffer() else { return }
        guard drawable.texture.width == key.plank.pixelWidth,
              drawable.texture.height == key.plank.pixelHeight else { return }
        let maps = exactMaps(for: key, retain: true)
        advanceClock()
        do {
            visibilityShadow = try encode(maps: maps, key: key, uniforms: captureUniforms(),
                                          pass: pass, command: command)
        } catch { fatalError(error.localizedDescription) }
        command.present(drawable)
        command.addCompletedHandler { command in
            if command.status == .error {
                fatalError(L("core.card.renderFailed", String(describing: command.error)))
            }
        }
        command.commit()
        #if TAVERN_RENDER_TESTING
        onSubmittedFrame?(key, bounds, view.drawableSize)
        #endif
        dirty = false
    }

    private func exactMaps(for key: TavernCardMaterialKey, retain: Bool) -> TavernCardMaps {
        if materialKey == key, let maps { return maps }
        do {
            let result = try renderer.buildMapsSynchronously(for: key)
            if retain {
                maps = result
                materialKey = key
            }
            return result
        } catch { fatalError(error.localizedDescription) }
    }

    private func captureUniforms() -> TavernCardUniforms {
        let flicker = reducedMotion ? 1 : 1 + 0.035 * sin(clock * 5.3)
            + 0.025 * sin(clock * 8.71) + 0.012 * sin(clock * 13.5)
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
        #if TAVERN_RENDER_TESTING
        if let testingGeometry { uniforms.geometry = testingGeometry }
        if let testingLamp { uniforms.lamp = testingLamp }
        if let testingMagicPosition { uniforms.magicPosition = testingMagicPosition }
        if let testingMagicColour { uniforms.magicColour = testingMagicColour }
        #endif
        return uniforms
    }

    private func encode(maps baseMaps: TavernCardMaps, key: TavernCardMaterialKey,
                        uniforms captured: TavernCardUniforms,
                        pass: MTLRenderPassDescriptor, command: MTLCommandBuffer) throws -> TavernCardShadow {
        guard let target = pass.colorAttachments[0].texture else {
            throw TavernCardSnapshotError.unavailable
        }
        let maps = try bookmark.isAnimating
            ? composeBookmark(base: baseMaps, geometry: captured.geometry, command: command) : baseMaps
        let shadowKey = TavernCardShadowKey(material: key, pixelWidth: target.width,
            pixelHeight: target.height, geometry: captured.geometry, lamp: captured.lamp)
        let capturedShadow: TavernCardShadow
        if let shadow = visibilityShadow, shadow.key == shadowKey, !bookmark.isAnimating {
            capturedShadow = shadow
        } else {
            if let shadow = visibilityShadow, shadow.key == shadowKey {
                capturedShadow = shadow
            } else {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .r32Float, width: target.width, height: target.height, mipmapped: false)
                descriptor.storageMode = .private
                descriptor.usage = [.renderTarget, .shaderRead]
                guard let texture = renderer.device.makeTexture(descriptor: descriptor) else {
                    throw TavernCardSnapshotError.unavailable
                }
                capturedShadow = TavernCardShadow(key: shadowKey, texture: texture)
            }
            let shadowPass = MTLRenderPassDescriptor()
            shadowPass.colorAttachments[0].texture = capturedShadow.texture
            shadowPass.colorAttachments[0].loadAction = .dontCare
            shadowPass.colorAttachments[0].storeAction = .store
            guard let encoder = command.makeRenderCommandEncoder(descriptor: shadowPass) else {
                throw TavernCardSnapshotError.encoder
            }
            var uniforms = captured
            encoder.setRenderPipelineState(renderer.shadowPipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<TavernCardUniforms>.stride, index: 0)
            encoder.setFragmentTexture(maps.textures[1], index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
        var uniforms = captured
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw TavernCardSnapshotError.encoder
        }
        encoder.setRenderPipelineState(renderer.pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<TavernCardUniforms>.stride, index: 0)
        // Native maps use a height-normalized scene; providers use card-surface points.
        var nebula = (nebulaLightingProvider?() ?? .none).scaled(by: Float(1 / min(1, bounds.height / 140)))
        encoder.setFragmentBytes(&nebula, length: MemoryLayout<TavernNebulaLighting>.stride, index: 1)
        for (index, texture) in maps.textures.enumerated() { encoder.setFragmentTexture(texture, index: index) }
        encoder.setFragmentTexture(capturedShadow.texture, index: 4)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        // Keep replaced textures and their exact maps alive until all encoded reads finish.
        command.addCompletedHandler { _ in
            withExtendedLifetime((maps, capturedShadow)) {}
        }
        return capturedShadow
    }

    /// Transient MRT maps keep the existing lighting/shadow shaders and snapshot path identical.
    /// Textures are reused for the short transition, never baked on the CPU per frame.
    private func composeBookmark(base: TavernCardMaps, geometry: SIMD4<Float>,
                                 command: MTLCommandBuffer) throws -> TavernCardMaps {
        let size = base.textures[0]
        if animatedMaps?.textures[0].width != size.width || animatedMaps?.textures[0].height != size.height {
            var textures: [MTLTexture] = []
            for _ in 0..<4 {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                    width: size.width, height: size.height, mipmapped: false)
                descriptor.storageMode = .private
                descriptor.usage = [.renderTarget, .shaderRead]
                guard let texture = renderer.device.makeTexture(descriptor: descriptor) else {
                    throw TavernCardSnapshotError.unavailable
                }
                textures.append(texture)
            }
            animatedMaps = TavernCardMaps(textures)
        }
        let maps = animatedMaps!
        let pass = MTLRenderPassDescriptor()
        for index in 0..<4 {
            pass.colorAttachments[index].texture = maps.textures[index]
            pass.colorAttachments[index].loadAction = .dontCare
            pass.colorAttachments[index].storeAction = .store
        }
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw TavernCardSnapshotError.encoder
        }
        let pose = bookmark.pose(at: bookmarkTime)
        var uniforms = SIMD4(geometry.x, geometry.y, pose.offset, pose.bend)
        encoder.setRenderPipelineState(renderer.bookmarkPipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        for (index, texture) in base.textures.enumerated() { encoder.setFragmentTexture(texture, index: index) }
        for (index, texture) in renderer.bookmarkTextures.enumerated() {
            encoder.setFragmentTexture(texture, index: index + 4)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        command.addCompletedHandler { _ in withExtendedLifetime((base, maps)) {} }
        return maps
    }

    private static let snapshotReadbackQueue = DispatchQueue(
        label: "org.herdr.tavern.card-snapshot", qos: .userInitiated)

    func requestSnapshot(completion: @escaping (Result<CGImage, Error>) -> Void) {
        precondition(Thread.isMainThread)
        let deliver: (Result<CGImage, Error>) -> Void = { result in
            RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) {
                completion(result)
            }
        }
        do {
            guard bounds.width > 0, bounds.height > 0 else {
                throw TavernCardSnapshotError.unavailable
            }
            let shown = visible
            if !shown { updateClock() }
            let scale = window?.backingScaleFactor ?? 2
            let width = max(1, Int((bounds.width * scale).rounded()))
            let height = max(1, Int((bounds.height * scale).rounded()))
            guard let key = exactKey(width: width, height: height) else {
                throw TavernCardSnapshotError.unavailable
            }
            // Capture all live inputs together; snapshot never advances the animation clock.
            let uniforms = captureUniforms()
            let capturedMaps: TavernCardMaps
            if materialKey == key, let maps {
                capturedMaps = maps
            } else {
                capturedMaps = try renderer.buildMapsSynchronously(for: key)
                if shown { maps = capturedMaps; materialKey = key }
            }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = .renderTarget
            guard let texture = renderer.device.makeTexture(descriptor: descriptor),
                  let command = renderer.queue.makeCommandBuffer() else {
                throw TavernCardSnapshotError.unavailable
            }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            // New snapshot shadows remain job-local, including failed GPU submissions.
            // Only an already exact live shadow can be reused.
            _ = try encode(maps: capturedMaps, key: key, uniforms: uniforms, pass: pass, command: command)
            #if TAVERN_RENDER_TESTING
            let completionGate = snapshotCompletionGate
            let injectedFailure = testingSnapshotFailure
            onSnapshotCaptured?(TavernCardSnapshotInputs(
                key: key, bounds: bounds, clock: clock, geometry: uniforms.geometry,
                lamp: uniforms.lamp, magicPosition: uniforms.magicPosition,
                magicColour: uniforms.magicColour), capturedMaps)
            #endif
            command.addCompletedHandler { command in
                // Neither logical cancellation nor view detachment releases this job's maps.
                let gpuError: Error? = command.status == .completed ? nil :
                    TavernCardSnapshotError.gpu(String(describing: command.error))
                Self.snapshotReadbackQueue.async {
                    withExtendedLifetime(capturedMaps) {
                        #if TAVERN_RENDER_TESTING
                        completionGate?()
                        if let injectedFailure { deliver(.failure(injectedFailure)); return }
                        #endif
                        if let gpuError { deliver(.failure(gpuError)); return }
                        guard let context = CGContext(
                            data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                CGBitmapInfo.byteOrder32Little.rawValue),
                              let data = context.data else {
                            deliver(.failure(TavernCardSnapshotError.unavailable))
                            return
                        }
                        texture.getBytes(data, bytesPerRow: width * 4,
                            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
                        guard let image = context.makeImage() else {
                            deliver(.failure(TavernCardSnapshotError.unavailable))
                            return
                        }
                        deliver(.success(image))
                    }
                }
            }
            command.commit()
        } catch { deliver(.failure(error)) }
    }
}

private struct TavernCardUniforms {
    var geometry: SIMD4<Float>
    var lamp: SIMD4<Float>
    var magicPosition: SIMD4<Float>
    var magicColour: SIMD4<Float> // RGB: talisman light; W: steady selection illumination.
}

final class TavernCardMaps: NSObject {
    let textures: [MTLTexture]
    init(_ textures: [MTLTexture]) { self.textures = textures }
}

private final class TavernMaterialCacheKey<Value: Hashable>: NSObject {
    let value: Value
    init(_ value: Value) { self.value = value }
    override var hash: Int { value.hashValue }
    override func isEqual(_ object: Any?) -> Bool {
        (object as? TavernMaterialCacheKey<Value>)?.value == value
    }
}

fileprivate final class TavernCardPreparation {
    private let lock = NSLock()
    private var cancelled = false
    private var started = false
    func cancel() {
        lock.lock()
        if !started { cancelled = true }
        lock.unlock()
    }
    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        started = true
        return true
    }
}

private enum TavernPreparationError: Error { case cancelled }

private enum TavernRendererPreparationError: Error {
    case notReady
}

final class TavernCardRenderer {
    private enum ResourceState {
        case idle
        case preparing([(Result<Void, Error>) -> Void])
        case ready(TavernCardRenderer)
        case failed(Error)
    }
    private static var resourceState = ResourceState.idle
    private static let resourceWorker = DispatchQueue(
        label: "org.herdr.tavern.renderer-preparation", qos: .userInitiated)
    #if TAVERN_RENDER_TESTING
    // Set on main; each job captures its gate before leaving main.
    static var resourcePreparationGate: (() -> Void)?
    #endif

    static var shared: Result<TavernCardRenderer, Error> {
        precondition(Thread.isMainThread)
        switch resourceState {
        case .ready(let renderer): return .success(renderer)
        case .failed(let error): return .failure(error)
        case .idle, .preparing: return .failure(TavernRendererPreparationError.notReady)
        }
    }

    fileprivate static func prepareResources(completion: @escaping (Result<Void, Error>) -> Void) {
        precondition(Thread.isMainThread)
        switch resourceState {
        case .ready:
            DispatchQueue.main.async { completion(.success(())) }
        case .failed(let error):
            DispatchQueue.main.async { completion(.failure(error)) }
        case .preparing(var waiters):
            waiters.append(completion)
            resourceState = .preparing(waiters)
        case .idle:
            resourceState = .preparing([completion])
            #if TAVERN_RENDER_TESTING
            let gate = resourcePreparationGate
            #endif
            resourceWorker.async {
                let result: Result<TavernCardRenderer, Error> = autoreleasepool {
                    #if TAVERN_RENDER_TESTING
                    gate?()
                    #endif
                    return Result { try TavernCardRenderer() }
                }
                DispatchQueue.main.async {
                    guard case .preparing(let waiters) = resourceState else {
                        preconditionFailure("Renderer preparation lost its waiters")
                    }
                    let completionResult: Result<Void, Error>
                    switch result {
                    case .success(let renderer):
                        resourceState = .ready(renderer)
                        renderer.activateMemoryPressureObservation()
                        completionResult = .success(())
                    case .failure(let error):
                        resourceState = .failed(error)
                        completionResult = .failure(error)
                    }
                    for waiter in waiters { waiter(completionResult) }
                }
            }
        }
    }
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let shadowPipeline: MTLRenderPipelineState
    let bookmarkPipeline: MTLRenderPipelineState
    private(set) var bookmarkTextures: [MTLTexture] = []
    let nebula: TavernWorkspaceNebulaResources
    private let cache = NSCache<TavernMaterialCacheKey<TavernCardMaterialKey>, TavernCardMaps>()
    private let plankCache = NSCache<TavernMaterialCacheKey<TavernPlankKey>, TavernPlankMaps>()
    private var sources: [String: CGImage] = [:]
    private let root: URL
    private let planks: TavernPlankMaterial
    private let workerPlanks: TavernPlankMaterial
    private let preparationWorker = DispatchQueue(label: "org.herdr.tavern.material-preparation", qos: .userInitiated)
    private var preparations: [TavernCardMaterialKey: [TavernCardPreparation]] = [:]
    private var memoryPressure: DispatchSourceMemoryPressure?
    #if TAVERN_RENDER_TESTING
    var preparationGate: ((TavernCardMaterialKey) -> Void)?
    #endif

    private init() throws {
        precondition(!Thread.isMainThread)
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
        workerPlanks = try TavernPlankMaterial(atlas: atlas)
        guard let nebulaShader = Bundle.main.url(forResource: "TavernWorkspaceNebula", withExtension: "metal", subdirectory: "Shaders") else {
            throw TavernCardResourceError.invalid(L("core.card.unreadableFile", "Shaders/TavernWorkspaceNebula.metal"))
        }
        let shaderSource = try String(contentsOf: shader, encoding: .utf8)
            + "\n" + String(contentsOf: nebulaShader, encoding: .utf8)
        let library = try device.makeLibrary(source: shaderSource, options: nil)
        nebula = try TavernWorkspaceNebulaResources(device: device, root: root, library: library)
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
        let shadowDescriptor = MTLRenderPipelineDescriptor()
        shadowDescriptor.vertexFunction = library.makeFunction(name: "tavernCardVertex")
        shadowDescriptor.fragmentFunction = library.makeFunction(name: "tavernCardShadowFragment")
        shadowDescriptor.colorAttachments[0].pixelFormat = .r32Float
        shadowPipeline = try device.makeRenderPipelineState(descriptor: shadowDescriptor)
        let bookmarkDescriptor = MTLRenderPipelineDescriptor()
        bookmarkDescriptor.vertexFunction = library.makeFunction(name: "tavernCardVertex")
        bookmarkDescriptor.fragmentFunction = library.makeFunction(name: "tavernBookmarkMapsFragment")
        for index in 0..<4 { bookmarkDescriptor.colorAttachments[index].pixelFormat = .rgba8Unorm }
        bookmarkPipeline = try device.makeRenderPipelineState(descriptor: bookmarkDescriptor)
        cache.totalCostLimit = 96 * 1024 * 1024
        cache.countLimit = 72
        plankCache.totalCostLimit = 32 * 1024 * 1024
        plankCache.countLimit = 48
        for suffix in ["", "-height", "-material"] { _ = try image("sprites/bookmark\(suffix)") }
        for kind in 0..<4 { _ = try bookmarkMap(kind: kind) }
        _ = try contactShadow()
        for kind in 0..<5 {
            let source = try kind == 4 ? contactShadow() : bookmarkMap(kind: kind)
            let context = try TavernPlankMaterial.context(width: source.width, height: source.height)
            context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                width: source.width, height: source.height, mipmapped: false)
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: descriptor), let data = context.data else {
                throw TavernCardResourceError.invalid(L("core.card.textureUnavailable"))
            }
            texture.replace(region: MTLRegionMake2D(0, 0, source.width, source.height), mipmapLevel: 0,
                withBytes: data, bytesPerRow: source.width * 4)
            bookmarkTextures.append(texture)
        }
    }

    private func activateMemoryPressureObservation() {
        precondition(Thread.isMainThread)
        precondition(memoryPressure == nil)
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self] in
            self?.purgeReusableCaches()
            NotificationCenter.default.post(name: .tavernMemoryPressure, object: nil)
        }
        pressure.resume()
        memoryPressure = pressure
    }

    deinit { memoryPressure?.cancel() }

    func purgeReusableCaches() {
        precondition(Thread.isMainThread)
        cache.removeAllObjects()
        plankCache.removeAllObjects()
    }

    func cachedMaps(for key: TavernCardMaterialKey) -> TavernCardMaps? {
        precondition(Thread.isMainThread)
        return cache.object(forKey: TavernMaterialCacheKey(key))
    }

    func buildMapsSynchronously(for key: TavernCardMaterialKey) throws -> TavernCardMaps {
        precondition(Thread.isMainThread)
        // Queued work is dispensable; already-started work never blocks exact display.
        for preparation in preparations[key] ?? [] { preparation.cancel() }
        if let maps = cachedMaps(for: key) { return maps }
        let base = plankCache.object(forKey: TavernMaterialCacheKey(key.plank))
        let result = try build(key: key, planks: planks, base: base)
        return publish(result, for: key)
    }

    func requestPreparation(for key: TavernCardMaterialKey,
                            completion: @escaping (Result<TavernCardMaps, Error>) -> Void) {
        _ = requestPreparation(for: key, accepting: { true }, completion: completion)
    }

    @discardableResult
    fileprivate func requestPreparation(for key: TavernCardMaterialKey, accepting: @escaping () -> Bool,
                            completion: @escaping (Result<TavernCardMaps, Error>) -> Void) -> TavernCardPreparation {
        precondition(Thread.isMainThread)
        let token = TavernCardPreparation()
        if let cached = cachedMaps(for: key) {
            RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) {
                completion(.success(cached))
            }
            return token
        }
        preparations[key, default: []].append(token)
        #if TAVERN_RENDER_TESTING
        let gate = preparationGate
        #endif
        // No mutable base context crosses the queue boundary. workerPlanks has its own atlas.
        preparationWorker.async { [self] in
            let result: Result<(TavernCardMaps, TavernPlankMaps), Error> = autoreleasepool {
                guard token.begin() else { return .failure(TavernPreparationError.cancelled) }
                #if TAVERN_RENDER_TESTING
                gate?(key)
                #endif
                return Result { try build(key: key, planks: workerPlanks, base: nil) }
            }
            RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) { [self] in
                preparations[key]?.removeAll { $0 === token }
                if preparations[key]?.isEmpty == true { preparations.removeValue(forKey: key) }
                if let winner = cachedMaps(for: key) {
                    completion(.success(winner))
                } else if accepting() {
                    completion(result.map { publish($0, for: key) })
                } else {
                    // Stale jobs cannot displace useful current cache entries.
                    completion(result.map { $0.0 })
                }
            }
        }
        return token
    }

    private func publish(_ result: (TavernCardMaps, TavernPlankMaps),
                         for key: TavernCardMaterialKey) -> TavernCardMaps {
        if let winner = cachedMaps(for: key) { return winner }
        let cost = key.plank.pixelWidth * key.plank.pixelHeight * 16
        if plankCache.object(forKey: TavernMaterialCacheKey(key.plank)) == nil {
            plankCache.setObject(result.1, forKey: TavernMaterialCacheKey(key.plank), cost: cost)
        }
        cache.setObject(result.0, forKey: TavernMaterialCacheKey(key), cost: cost)
        return result.0
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

    private func build(key: TavernCardMaterialKey, planks: TavernPlankMaterial,
                       base cachedBase: TavernPlankMaps?) throws -> (TavernCardMaps, TavernPlankMaps) {
        let width = key.plank.pixelWidth, height = key.plank.pixelHeight
        let pointSize = CGSize(width: key.plank.pointWidth, height: key.plank.pointHeight)
        let selected = key.selected
        let base = try cachedBase ?? planks.build(seed: key.plank.seed, construction: key.plank.construction,
            width: width, height: height, pointSize: pointSize)
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
                    draw(sources["bookmark-contact"]!, in: CGRect(x: CGFloat(width) - 92 * unitX, y: -5 * unitY, width: 36 * unitX, height: 112 * unitY))
                    context.restoreGState()
                }
                draw(sources["bookmark-map:\(kind)"]!,
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
        return (TavernCardMaps(textures), base)
    }
}
