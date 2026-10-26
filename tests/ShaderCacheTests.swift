import AppKit
import MetalKit
import CryptoKit

#if !TAVERN_RENDER_TESTING
#error("Compile ShaderCacheTests with -D TAVERN_RENDER_TESTING")
#endif

// The golden shader is the untouched 93498e2 source, not the current product shader.
@main struct ShaderCacheTests {
    private struct Uniforms {
        var geometry: SIMD4<Float>
        var lamp: SIMD4<Float>
        var magicPosition: SIMD4<Float>
        var magicColour: SIMD4<Float>
    }

    private final class ScaleWindow: NSWindow {
        var fixtureScale: CGFloat = 1
        override var backingScaleFactor: CGFloat { fixtureScale }
    }

    private final class Gate {
        private let lock = NSLock()
        private let signal = DispatchSemaphore(value: 0)
        private var didEnter = false
        private var didTimeout = false
        var entered: Bool { lock.lock(); defer { lock.unlock() }; return didEnter }
        var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return didTimeout }
        func block() {
            precondition(!Thread.isMainThread)
            lock.lock(); didEnter = true; lock.unlock()
            if signal.wait(timeout: .now() + 8) == .timedOut {
                lock.lock(); didTimeout = true; lock.unlock()
            }
        }
        func release() { signal.signal() }
    }

    private final class Host {
        let window: ScaleWindow
        let view: TavernCardSurfaceView
        var visible = false
        var submitted = 0
        init(renderer: TavernCardRenderer, size: CGSize, scale: CGFloat) {
            window = ScaleWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 300),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
            window.fixtureScale = scale
            window.isReleasedWhenClosed = false
            view = TavernCardSurfaceView(frame: CGRect(origin: .zero, size: size), renderer: renderer)
            view.testingVisibilityPolicy = { [weak self] in self?.visible ?? false }
            view.testingReduceMotionPolicy = { true }
            view.onSubmittedFrame = { [weak self] _, _, _ in self?.submitted += 1 }
            window.contentView!.addSubview(view)
            view.layoutSubtreeIfNeeded()
            view.testingSetDrawableSize(CGSize(width: (size.width * scale).rounded(),
                                              height: (size.height * scale).rounded()))
        }
        func frame() {
            let old = submitted
            view.refreshLighting()
            ShaderCacheTests.wait("visible exact shadow frame") {
                if self.submitted > old { return true }
                self.view.refreshLighting()
                return self.submitted > old
            }
            precondition(view.testingHeldShadow != nil, "Visible frame did not retain its shadow")
        }
        func close() {
            visible = false
            view.refreshLighting()
            view.removeFromSuperview()
            window.close()
        }
    }

    private static let worker = DispatchQueue(label: "org.herdr.tavern.shader-oracle")
    private static func wait(_ name: String, until predicate: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: 10)
        while !predicate() {
            precondition(Date() < deadline, "Timed out: \(name)")
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
    }

    private static func baselinePipeline(_ renderer: TavernCardRenderer) throws -> MTLRenderPipelineState {
        var result: Result<MTLRenderPipelineState, Error>?
        let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/TavernCardBaseline.metal")
        worker.async {
            let prepared = Result<MTLRenderPipelineState, Error> {
                let data = try Data(contentsOf: sourceURL)
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                precondition(digest == "2b12caffbb777005d2ec72b6ae4a6a796117ad2b68f30c35d9a5e5a46d926b7b",
                             "Golden shader is not the pinned original")
                let library = try renderer.device.makeLibrary(source: String(decoding: data, as: UTF8.self), options: nil)
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "tavernCardVertex")
                descriptor.fragmentFunction = library.makeFunction(name: "tavernCardFragment")
                let attachment = descriptor.colorAttachments[0]!
                attachment.pixelFormat = .bgra8Unorm
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .one
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                return try renderer.device.makeRenderPipelineState(descriptor: descriptor)
            }
            DispatchQueue.main.async { result = prepared }
        }
        wait("original shader compilation") { result != nil }
        return try result!.get()
    }

    private static func baseline(_ inputs: TavernCardSnapshotInputs, maps: TavernCardMaps,
                                 renderer: TavernCardRenderer, pipeline: MTLRenderPipelineState) throws -> Data {
        let width = inputs.key.plank.pixelWidth, height = inputs.key.plank.pixelHeight
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .renderTarget
        let texture = renderer.device.makeTexture(descriptor: descriptor)!
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        let command = renderer.queue.makeCommandBuffer()!
        let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
        var uniforms = Uniforms(geometry: inputs.geometry, lamp: inputs.lamp,
                                magicPosition: inputs.magicPosition, magicColour: inputs.magicColour)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        for (index, texture) in maps.textures.enumerated() { encoder.setFragmentTexture(texture, index: index) }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        var result: Result<Data, Error>?
        command.addCompletedHandler { command in
            let failure = command.status == .completed ? nil : command.error ?? NSError(domain: "ShaderOracle", code: 1)
            worker.async {
                let bytes: Result<Data, Error>
                if let failure { bytes = .failure(failure) }
                else {
                    var data = Data(count: width * height * 4)
                    data.withUnsafeMutableBytes { memory in
                        texture.getBytes(memory.baseAddress!, bytesPerRow: width * 4,
                            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
                    }
                    bytes = .success(data)
                }
                withExtendedLifetime(maps) {}
                DispatchQueue.main.async { result = bytes }
            }
        }
        command.commit()
        wait("baseline GPU completion") { result != nil }
        return try result!.get()
    }

    private static func imageBytes(_ image: CGImage) -> Data {
        precondition(image.bitsPerPixel == 32 && image.bytesPerRow == image.width * 4)
        precondition(image.alphaInfo == .premultipliedFirst)
        precondition(image.bitmapInfo.contains(.byteOrder32Little))
        return image.dataProvider!.data! as Data
    }
    private static func equal(_ actual: Data, _ expected: Data, inputs: TavernCardSnapshotInputs, name: String) {
        precondition(actual.count == expected.count, "\(name): byte count differs; frozen inputs=\(inputs)")
        if let offset = zip(actual, expected).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset {
            let a = Array(actual), b = Array(expected)
            let pixel = offset / 4, start = pixel * 4
            preconditionFailure("\(name): first mismatch x=\(pixel % inputs.key.plank.pixelWidth) y=\(pixel / inputs.key.plank.pixelWidth) channel=\(offset % 4), cached BGRA=\(Array(a[start..<start + 4])) original BGRA=\(Array(b[start..<start + 4])); frozen inputs=\(inputs)")
        }
    }

    private static func snapshot(_ view: TavernCardSurfaceView) throws -> (CGImage, TavernCardSnapshotInputs, TavernCardMaps) {
        var capture: (TavernCardSnapshotInputs, TavernCardMaps)?
        var result: Result<CGImage, Error>?
        view.onSnapshotCaptured = { capture = ($0, $1) }
        view.requestSnapshot { result = $0 }
        wait("cached snapshot GPU completion") { result != nil }
        view.onSnapshotCaptured = nil
        let captured = capture!
        return (try result!.get(), captured.0, captured.1)
    }

    private static func freeze(_ inputs: TavernCardSnapshotInputs, on view: TavernCardSurfaceView) {
        view.testingGeometry = inputs.geometry
        view.testingLamp = inputs.lamp
        view.testingMagicPosition = inputs.magicPosition
        view.testingMagicColour = inputs.magicColour
        view.testingClock = inputs.clock
    }

    private static func inputs(seed: UInt64, construction: TavernPlankConstruction, selected: Bool,
                               size: CGSize, scale: CGFloat, variant: Int) -> TavernCardSnapshotInputs {
        let key = TavernCardMaterialKey(plank: TavernPlankKey(seed: seed, construction: construction,
            pixelWidth: Int((size.width * scale).rounded()), pixelHeight: Int((size.height * scale).rounded()),
            pointWidth: size.width, pointHeight: size.height), selected: selected)
        let sceneScale = min(1, size.height / 140)
        let distant = Float(-500 / sceneScale)
        let lamps: [SIMD4<Float>] = [SIMD4(90, 34, 132, 1), SIMD4(distant, distant, 132, 0.973),
                                    SIMD4(177.25, -12.5, Float(132).nextUp, 1.064)]
        return TavernCardSnapshotInputs(key: key, bounds: CGRect(origin: .zero, size: size),
            clock: Double(variant) * 0.375,
            geometry: SIMD4(Float(size.width / sceneScale), Float(size.height / sceneScale), 1, 1),
            lamp: lamps[variant], magicPosition: variant == 0 ? .zero : SIMD4(72, 91, 42, 0.83),
            magicColour: SIMD4(0.32, 0.74, 1, selected ? 1 : 0))
    }

    private static func pixels(renderer: TavernCardRenderer, pipeline: MTLRenderPipelineState) throws {
        let sizes: [CGSize] = [CGSize(width: 234, height: 78), CGSize(width: 374, height: 78),
                               CGSize(width: 374, height: 40), CGSize(width: 234.5, height: 78)]
        for seed: UInt64 in [0, 42, UInt64.max] {
            for construction: TavernPlankConstruction in [.agent, .workspace] {
                for selected in [false, true] {
                    for size in sizes {
                        for scale: CGFloat in [1, 2] {
                            let host = Host(renderer: renderer, size: size, scale: scale)
                            host.view.configure(seed: seed, construction: construction, selected: selected)
                            for variant in 0..<3 {
                                let frozen = inputs(seed: seed, construction: construction, selected: selected,
                                                    size: size, scale: scale, variant: variant)
                                freeze(frozen, on: host.view)
                                let (image, captured, maps) = try snapshot(host.view)
                                precondition(captured.key == frozen.key)
                                precondition(captured.geometry == frozen.geometry && captured.lamp == frozen.lamp)
                                equal(imageBytes(image), try baseline(captured, maps: maps, renderer: renderer, pipeline: pipeline),
                                      inputs: captured, name: "cold snapshot seed=\(seed) construction=\(construction) selected=\(selected) points=\(size) scale=\(scale) variant=\(variant)")
                                precondition(host.view.testingHeldShadow == nil && host.view.testingHeldMaps == nil,
                                             "Hidden snapshot retained resources on the view")
                            }
                            host.close()
                        }
                    }
                }
            }
        }
        print("PASS: original versus cached final BGRA, all seed/material/selection/size/scale/lamp/magic fixtures")
    }

    private static func identityAndCapture(renderer: TavernCardRenderer, pipeline: MTLRenderPipelineState) throws {
        let size = CGSize(width: 234.5, height: 78)
        let host = Host(renderer: renderer, size: size, scale: 2)
        defer { host.close() }
        var frozen = inputs(seed: 42, construction: .agent, selected: false, size: size, scale: 2, variant: 0)
        host.view.configure(seed: 42, construction: .agent, selected: false)
        freeze(frozen, on: host.view)
        host.visible = true
        host.frame()
        let first = host.view.testingHeldShadow!
        let firstKey = host.view.testingShadowKey!
        frozen = TavernCardSnapshotInputs(key: frozen.key, bounds: frozen.bounds, clock: 2.75,
            geometry: frozen.geometry, lamp: SIMD4(frozen.lamp.x, frozen.lamp.y, frozen.lamp.z, 0.92),
            magicPosition: SIMD4(33, 77, 42, 0.9), magicColour: SIMD4(0.7, 0.3, 1, 0))
        freeze(frozen, on: host.view)
        host.frame()
        precondition(host.view.testingHeldShadow === first && host.view.testingShadowKey == firstKey,
                     "Flicker, clock or magic invalidated visibility")
        let (warmImage, warmInputs, warmMaps) = try snapshot(host.view)
        equal(imageBytes(warmImage), try baseline(warmInputs, maps: warmMaps, renderer: renderer, pipeline: pipeline),
              inputs: warmInputs, name: "warm live-cache snapshot")
        // Vary each keyed scalar independently; a combined change would not detect an omitted field.
        for scalar in 0..<7 {
            let previous = host.view.testingHeldShadow!
            let previousKey = host.view.testingShadowKey!
            var geometry = frozen.geometry
            var lamp = frozen.lamp
            if scalar < 4 { geometry[scalar] = geometry[scalar].nextUp }
            else { lamp[scalar - 4] = lamp[scalar - 4].nextUp }
            let changed = TavernCardSnapshotInputs(key: frozen.key, bounds: frozen.bounds, clock: frozen.clock,
                geometry: geometry, lamp: lamp, magicPosition: frozen.magicPosition, magicColour: frozen.magicColour)
            freeze(changed, on: host.view)
            host.frame()
            precondition(host.view.testingHeldShadow !== previous && host.view.testingShadowKey != previousKey,
                         "Visibility key omitted exact scalar \(scalar)")
            let (image, captured, maps) = try snapshot(host.view)
            equal(imageBytes(image), try baseline(captured, maps: maps, renderer: renderer, pipeline: pipeline),
                  inputs: captured, name: "independent key scalar \(scalar)")
            freeze(frozen, on: host.view)
            host.frame()
        }
        var zeroLamp = frozen.lamp
        zeroLamp.x = 0
        freeze(TavernCardSnapshotInputs(key: frozen.key, bounds: frozen.bounds, clock: frozen.clock,
            geometry: frozen.geometry, lamp: zeroLamp, magicPosition: .zero, magicColour: .zero), on: host.view)
        host.frame()
        let positiveZeroShadow = host.view.testingHeldShadow!
        let positiveZeroKey = host.view.testingShadowKey!
        zeroLamp.x = -Float.zero
        freeze(TavernCardSnapshotInputs(key: frozen.key, bounds: frozen.bounds, clock: frozen.clock,
            geometry: frozen.geometry, lamp: zeroLamp, magicPosition: .zero, magicColour: .zero), on: host.view)
        host.frame()
        precondition(host.view.testingHeldShadow !== positiveZeroShadow && host.view.testingShadowKey != positiveZeroKey,
                     "Visibility key compared Float values instead of signed-zero bit patterns")
        freeze(frozen, on: host.view)
        host.frame()
        let gate = Gate()
        var oldCapture: (TavernCardSnapshotInputs, TavernCardMaps)?
        var oldResult: Result<CGImage, Error>?
        host.view.snapshotCompletionGate = { gate.block() }
        host.view.onSnapshotCaptured = { oldCapture = ($0, $1) }
        host.view.requestSnapshot { oldResult = $0 }
        wait("snapshot readback gate") { gate.entered }
        var lamp = frozen.lamp
        lamp.z = lamp.z.nextUp
        var geometry = frozen.geometry
        geometry.x = geometry.x.nextUp
        freeze(TavernCardSnapshotInputs(key: frozen.key, bounds: frozen.bounds, clock: 9,
            geometry: geometry, lamp: lamp, magicPosition: .zero, magicColour: .zero), on: host.view)
        host.view.frame.size = CGSize(width: 374, height: 40)
        host.view.layoutSubtreeIfNeeded()
        host.view.testingSetDrawableSize(CGSize(width: 748, height: 80))
        host.frame()
        precondition(host.view.testingHeldShadow !== first && host.view.testingShadowKey != firstKey,
                     "Exact scene/lamp Float bits reused stale shadow")
        var heartbeat = false
        RunLoop.main.perform { heartbeat = true }
        wait("heartbeat while snapshot completion is gated") { heartbeat }
        precondition(oldResult == nil && !gate.timedOut)
        host.visible = false
        host.view.refreshLighting()
        wait("hidden shadow release") { host.view.testingHeldShadow == nil && host.view.testingHeldMaps == nil }
        gate.release()
        wait("old captured snapshot delivery") { oldResult != nil }
        precondition(!gate.timedOut)
        let captured = oldCapture!
        equal(imageBytes(try oldResult!.get()), try baseline(captured.0, maps: captured.1, renderer: renderer, pipeline: pipeline),
              inputs: captured.0, name: "captured snapshot survives live geometry/lamp replacement and hide")
        host.view.snapshotCompletionGate = nil
        host.view.onSnapshotCaptured = nil
        precondition(host.view.testingHeldShadow == nil, "Late completion resurrected hidden shadow")
        print("PASS: exact cache identity, warm pixels, captured geometry race, hidden release and main heartbeat")
    }

    static func main() throws {
        precondition(CommandLine.arguments.count >= 2, "Pass the current built .app as argument 1")
        precondition(FileManager.default.fileExists(atPath: CommandLine.arguments[1] + "/Contents/Resources/Shaders/TavernCard.metal"))
        _ = NSApplication.shared
        var prepared: Result<Void, Error>?
        TavernCardSurfaceView.prepareResources { prepared = $0 }
        wait("async current renderer preparation") { prepared != nil }
        try prepared!.get()
        let renderer = try TavernCardRenderer.shared.get()
        let pipeline = try baselinePipeline(renderer)
        try pixels(renderer: renderer, pipeline: pipeline)
        try identityAndCapture(renderer: renderer, pipeline: pipeline)
        print("PASS: ShaderCacheTests")
    }
}
