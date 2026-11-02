import AppKit

#if !TAVERN_RENDER_TESTING
#error("CardSnapshotTests requires -D TAVERN_RENDER_TESTING")
#endif

private final class SnapshotGate {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var entered = false

    var isEntered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entered
    }

    func blockWorker() {
        precondition(!Thread.isMainThread)
        lock.lock()
        entered = true
        lock.unlock()
        precondition(release.wait(timeout: .now() + 10) == .success, "Snapshot gate timed out")
    }

    func open() { release.signal() }
}

@main struct CardSnapshotTests {
    static func pump(_ mode: RunLoop.Mode = .default, stage: String = #function,
                     details: @autoclosure () -> String = "", until ready: () -> Bool,
                     file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date(timeIntervalSinceNow: 10)
        while !ready(), Date() < deadline {
            let step = min(deadline, Date(timeIntervalSinceNow: 0.005))
            if mode == .default {
                // CAMetalLayer needs real AppKit/window-server event delivery.
                if let event = NSApp.nextEvent(matching: .any, until: step,
                                               inMode: .default, dequeue: true) {
                    NSApp.sendEvent(event)
                }
                NSApp.updateWindows()
            }
            RunLoop.main.run(mode: mode, before: step)
        }
        precondition(ready(), "Snapshot deadline: \(stage), mode=\(mode), \(details())\n\(windowDiagnostics())",
                     file: file, line: line)
    }

    private static func windowDiagnostics() -> String {
        "appActive=\(NSApp.isActive) appHidden=\(NSApp.isHidden) windows=" +
            NSApp.windows.map {
                "number=\($0.windowNumber) visible=\($0.isVisible) occlusion=\($0.occlusionState.rawValue) frame=\($0.frame)"
            }.joined(separator: "; ")
    }

    static func pixels(_ image: CGImage) -> Data {
        let context = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                CGBitmapInfo.byteOrder32Little.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: context.data!, count: image.width * image.height * 4)
    }

    static func card(renderer: TavernCardRenderer) -> TavernCardSurfaceView {
        let card = TavernCardSurfaceView(frame: CGRect(x: 0, y: 0, width: 234.5, height: 78),
                                         renderer: renderer)
        card.isHidden = true
        card.testingReduceMotionPolicy = { false }
        card.configure(seed: 42, construction: .agent, selected: false)
        card.lightPositionProvider = { CGPoint(x: 80, y: 120) }
        card.magicLightProvider = { (CGPoint(x: 24, y: 60), SIMD3(0.2, 0.4, 0.8), 0.7) }
        return card
    }

    static func fixedInputsAndHeartbeat() throws {
        let renderer = try TavernCardRenderer.shared.get()
        let view = card(renderer: renderer)
        var reference: CGImage?
        view.requestSnapshot { reference = try! $0.get() }
        pump { reference != nil }
        precondition(view.testingHeldMaps == nil, "Cold hidden capture retained view maps")

        let gate = SnapshotGate()
        view.snapshotCompletionGate = { gate.blockWorker() }
        var inputs: TavernCardSnapshotInputs?
        view.onSnapshotCaptured = { captured, _ in inputs = captured }
        var result: CGImage?
        var calls = 0
        view.requestSnapshot {
            precondition(Thread.isMainThread)
            precondition(RunLoop.current.currentMode == .eventTracking)
            calls += 1
            result = try! $0.get()
        }
        let captured = inputs!
        precondition(captured.bounds.size == CGSize(width: 234.5, height: 78))
        precondition(captured.key.plank.pixelWidth == 469 && captured.key.plank.pixelHeight == 156)
        precondition(captured.clock == 0 && captured.magicPosition.w == 0.7)
        precondition(captured.magicColour.w == 0 && captured.lamp.w == 1)
        // The job must already own its gate and uniforms, not consult the live view later.
        view.snapshotCompletionGate = { preconditionFailure("Read mutable gate after enqueue") }
        view.frame.size = CGSize(width: 380, height: 46)
        view.configure(seed: 999, construction: .workspace, selected: true)
        view.lightPositionProvider = { CGPoint(x: -1000, y: -1000) }
        view.magicLightProvider = nil
        pump(.eventTracking) { gate.isEntered }
        var heartbeat = false
        RunLoop.main.perform(inModes: [.eventTracking]) { heartbeat = true }
        pump(.eventTracking) { heartbeat }
        precondition(calls == 0 && view.testingHeldMaps == nil)
        gate.open()
        pump(.eventTracking) { result != nil }
        precondition(calls == 1)
        precondition(result!.width == reference!.width && result!.height == reference!.height)
        precondition(pixels(result!) == pixels(reference!), "Snapshot used post-request geometry or uniforms")
        precondition(view.testingHeldMaps == nil)
        print("PASS: cold hidden snapshot, frozen inputs, worker gate and eventTracking delivery")
    }

    static func detachedFailureOwnership() throws {
        enum Expected: Error { case readback }
        let gate = SnapshotGate()
        weak var ownedMaps: TavernCardMaps?
        weak var releasedView: TavernCardSurfaceView?
        var calls = 0
        var cancelled = false
        var publications = 0
        // Release the view and reusable cache ownership while the job is gated.
        try autoreleasepool {
            let renderer = try TavernCardRenderer.shared.get()
            let view = card(renderer: renderer)
            // Isolate ownership from earlier cache lookups outside this pool.
            view.configure(seed: 777, construction: .agent, selected: false)
            releasedView = view
            view.snapshotCompletionGate = { gate.blockWorker() }
            view.testingSnapshotFailure = Expected.readback
            view.onSnapshotCaptured = { _, maps in ownedMaps = maps }
            view.requestSnapshot { result in
                precondition(Thread.isMainThread)
                calls += 1
                guard case .failure(let error) = result, error is Expected else {
                    preconditionFailure("Readback failure was not returned explicitly")
                }
                if !cancelled { publications += 1 }
            }
            renderer.purgeReusableCaches()
        }
        cancelled = true
        pump { gate.isEntered }
        precondition(releasedView == nil, "Snapshot job retained its view")
        precondition(ownedMaps != nil, "In-flight job released maps before readback")
        gate.open()
        pump { calls == 1 }
        pump { ownedMaps == nil }
        precondition(publications == 0)
        print("PASS: logical cancellation, detached resource ownership and explicit failure")
    }

    static func invalidGeometry() {
        let view = TavernCardSurfaceView(frame: .zero)
        var calls = 0
        view.requestSnapshot { result in
            precondition(Thread.isMainThread)
            guard case .failure = result else { preconditionFailure("Empty capture succeeded") }
            calls += 1
        }
        precondition(calls == 0, "Failure delivered synchronously")
        pump(.modalPanel) { calls == 1 }
        var drained = false
        RunLoop.main.perform(inModes: [.default]) { drained = true }
        pump { drained }
        precondition(calls == 1)
        print("PASS: asynchronous failure in modalPanel delivered once")
    }

    private final class LiveHost {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let view: TavernCardSurfaceView
        var visible = false
        var reduced = true
        var submissions: [TavernCardMaterialKey] = []
        init() throws {
            window.isReleasedWhenClosed = false
            view = TavernCardSurfaceView(frame: CGRect(x: 0, y: 0, width: 234.5, height: 78),
                                         renderer: try TavernCardRenderer.shared.get())
            view.testingVisibilityPolicy = { [weak self] in self?.visible ?? false }
            view.testingReduceMotionPolicy = { [weak self] in self?.reduced ?? true }
            view.onSubmittedFrame = { [weak self] key, _, _ in
                precondition(Thread.isMainThread)
                self?.submissions.append(key)
            }
            window.contentView!.addSubview(view)
            view.layoutSubtreeIfNeeded()
            view.testingSetDrawableSize(CGSize(width: 469, height: 156))
            view.configure(seed: 42, construction: .agent, selected: false)
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            CardSnapshotTests.pump(stage: "LiveHost visible WindowServer window", details: diagnostics) {
                self.window.isVisible && self.window.occlusionState.contains(.visible)
            }
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
        }
        var diagnostics: String {
            let state = view.testingRenderState
            let hosts = view.subviews.map {
                "frame=\($0.frame) layerBounds=\(String(describing: $0.layer?.bounds))"
            }
            let counters = String(describing: TavernPerformance.shared.snapshot()["counters"])
            return "running=\(state.running) pending=\(state.pending) starts=\(state.starts) " +
                "submissions=\(submissions.map { $0.plank.seed }) material=\(String(describing: view.testingMaterialKey)) " +
                "viewFrame=\(view.frame) viewBounds=\(view.bounds) visibleRect=\(view.visibleRect) hosts=\(hosts) " +
                "performanceEnabled=\(TavernPerformance.shared.isEnabled) counters=\(counters)"
        }
        func close() {
            visible = false
            view.refreshLighting()
            view.removeFromSuperview()
            window.close()
        }
    }

    static func latestRenderAndMainHeartbeat() throws {
        let host = try LiveHost()
        defer { host.close() }
        let gate = SnapshotGate()
        host.view.renderGate = { gate.blockWorker() }
        host.visible = true
        host.view.refreshLighting()
        pump(stage: "latest initial render gate", details: host.diagnostics) { gate.isEntered }
        host.view.renderGate = nil
        for seed in UInt64(100)...120 {
            host.view.configure(seed: seed, construction: .workspace, selected: false)
            var heartbeat = false
            RunLoop.main.perform { heartbeat = true }
            pump(stage: "latest pending seed \(seed)", details: host.diagnostics) {
                heartbeat && host.view.testingRenderState.pending
            }
            precondition(host.view.testingRenderState.starts == 1, "Queued render escaped bounded slot")
        }
        precondition(host.submissions.isEmpty, "Blocked drawable worker submitted on main")
        gate.open()
        pump(stage: "latest GPU completion and idle", details: host.diagnostics) {
            host.submissions.count == 1 && !host.view.testingRenderState.running
        }
        precondition(host.submissions[0].plank.seed == 120, "Worker did not render latest material")
        precondition(host.view.testingRenderState.starts == 2, "Accumulated obsolete render jobs")
        print("PASS: delayed drawable worker, responsive main, bounded/latest material")
    }

    private static func staleRender(_ name: String, change: (LiveHost) -> Void) throws {
        let host = try LiveHost()
        defer { host.close() }
        let gate = SnapshotGate()
        host.view.testingLamp = SIMD4(11, 30, 132, 1)
        host.view.renderCompletionGate = { gate.blockWorker() }
        host.visible = true
        host.view.refreshLighting()
        pump(stage: "\(name): initial GPU completion gate", details: host.diagnostics) { gate.isEntered }
        host.view.renderCompletionGate = nil
        change(host)
        let expectedLamp = SIMD4<Float>(22, 30, 132, 1)
        host.view.testingLamp = expectedLamp
        host.view.refreshLighting()
        precondition(host.view.testingHeldShadow == nil,
                     "\(name): retained stale shadow; \(host.diagnostics)")
        var newCallbacks = 0
        if host.visible {
            var flushed = false
            RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) { flushed = true }
            pump(stage: "\(name): latest pending sentinel frame", details: host.diagnostics) {
                flushed && host.view.testingRenderState.pending
            }
            precondition(host.view.testingRenderState.starts == 1,
                         "\(name): GPU slot released before completion; \(host.diagnostics)")
            guard let expectedKey = host.view.testingMaterialKey else {
                preconditionFailure("\(name): latest pending material missing; \(host.diagnostics)")
            }
            let expectedBounds = host.view.bounds
            host.view.onRenderedInputs = { [weak host] inputs, _, _ in
                guard let host else { preconditionFailure("\(name): callback outlived its fixture") }
                precondition(Thread.isMainThread)
                precondition(inputs.lamp.x.bitPattern == expectedLamp.x.bitPattern &&
                             inputs.lamp == expectedLamp &&
                             inputs.key == expectedKey && inputs.bounds == expectedBounds,
                             "\(name): stale captured frame published; inputs=\(inputs) expectedKey=\(expectedKey) expectedBounds=\(expectedBounds) expectedLamp=\(expectedLamp); \(host.diagnostics)")
                newCallbacks += 1
            }
        } else {
            host.view.onRenderedInputs = { [weak host] inputs, _, _ in
                guard let host else { preconditionFailure("\(name): callback outlived its fixture") }
                preconditionFailure("\(name): hidden captured frame published; inputs=\(inputs); \(host.diagnostics)")
            }
        }
        gate.open()
        if host.visible {
            // Motion can continuously submit valid new frames; idle is not its contract.
            pump(stage: "\(name): first exact new captured callback", details: host.diagnostics) {
                newCallbacks >= 1
            }
        } else {
            pump(stage: "\(name): hidden worker idle", details: host.diagnostics) {
                !host.view.testingRenderState.running
            }
        }
        // The held old job queues its main callback before any new GPU completion.
        var drained = false
        DispatchQueue.main.async { drained = true }
        pump(stage: "\(name): drain main completion callbacks", details: host.diagnostics) { drained }
        if host.visible {
            precondition(newCallbacks >= 1 && host.submissions.count == newCallbacks,
                         "\(name): missing exact new callback; verified=\(newCallbacks) count=\(host.submissions.count) keys=\(host.submissions); \(host.diagnostics)")
            precondition(host.view.testingHeldShadow != nil,
                         "\(name): latest shadow missing; \(host.diagnostics)")
        } else {
            precondition(host.submissions.isEmpty,
                         "\(name): hidden completion published; count=\(host.submissions.count) keys=\(host.submissions); \(host.diagnostics)")
            precondition(host.view.testingHeldShadow == nil,
                         "\(name): resurrected hidden shadow; \(host.diagnostics)")
        }
        print("PASS: \(name) invalidates delayed GPU completion")
    }

    static func idleHiddenReleasesShadow() throws {
        let host = try LiveHost()
        defer { host.close() }
        host.visible = true
        host.view.refreshLighting()
        pump { host.submissions.count == 1 && !host.view.testingRenderState.running }
        weak var shadow: AnyObject?
        autoreleasepool {
            shadow = host.view.testingHeldShadow
            precondition(shadow != nil, "Completed static frame did not own a shadow")
            host.visible = false
            // The idle cleanup must survive generation drift and coalesce this burst.
            for _ in 0..<100 { host.view.refreshLighting() }
        }
        precondition(host.view.testingHeldShadow == nil)
        pump { shadow == nil }
        precondition(host.submissions.count == 1, "Hidden cleanup rendered another frame")
        print("PASS: completed static shadow deallocates after idle hide")
    }

    static func frozenBookmarkAndLighting() throws {
        let host = try LiveHost()
        defer { host.close() }
        host.reduced = false
        host.view.testingBookmarkTime = 100
        let gate = SnapshotGate()
        host.view.renderGate = { gate.blockWorker() }
        host.view.lightPositionProvider = {
            precondition(Thread.isMainThread)
            return CGPoint(x: 80, y: 120)
        }
        host.view.magicLightProvider = {
            precondition(Thread.isMainThread)
            return (CGPoint(x: 24, y: 60), SIMD3(0.2, 0.4, 0.8), 0.7)
        }
        var light = TavernNebulaLighting.none
        light.a.position = SIMD4(11, 22, 33, 0.8)
        host.view.nebulaLightingProvider = { precondition(Thread.isMainThread); return light }
        host.visible = true
        host.view.configure(seed: 42, construction: .agent, selected: true)
        pump { gate.isEntered }
        host.view.renderGate = nil
        host.view.testingBookmarkTime = 100.1
        host.view.refreshLighting()
        var captured: TavernCardSnapshotInputs?
        host.view.onSnapshotCaptured = { inputs, _ in captured = inputs }
        var reference: CGImage?
        host.view.requestSnapshot { reference = try! $0.get() }
        pump { reference != nil && host.view.testingRenderState.pending }
        let frozenInputs = captured!
        var renderedPose: SIMD2<Float>?
        host.view.onRenderedInputs = { inputs, nebula, pose in
            precondition(inputs.key == frozenInputs.key && inputs.geometry == frozenInputs.geometry)
            precondition(inputs.magicPosition == frozenInputs.magicPosition && inputs.magicColour == frozenInputs.magicColour)
            precondition(nebula.a.position == light.scaled(by: Float(140.0 / 78)).a.position)
            renderedPose = pose
        }
        gate.open()
        pump { renderedPose != nil }
        var expected = TavernBookmarkMotion()
        expected.select(false, at: 100, animated: false)
        expected.select(true, at: 100, animated: true)
        let pose = expected.pose(at: 100.1)
        precondition(renderedPose == SIMD2(pose.offset, pose.bend), "Bookmark pose was read on worker")
        var repeated: CGImage?
        host.view.requestSnapshot { repeated = try! $0.get() }
        pump { repeated != nil }
        // Flicker changes with clock, so compare with the exact captured lamp/clock.
        host.view.testingLamp = frozenInputs.lamp
        host.view.testingClock = frozenInputs.clock
        var frozen: CGImage?
        host.view.requestSnapshot { frozen = try! $0.get() }
        pump { frozen != nil }
        precondition(pixels(frozen!) == pixels(reference!), "Live bookmark encoding mutated snapshot maps")
        print("PASS: main-only providers, exact light scale, captured bookmark, independent snapshots")
    }

    static func main() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.finishLaunching()
        var prepared: Result<Void, Error>?
        TavernCardSurfaceView.prepareResources { prepared = $0 }
        pump { prepared != nil }
        try prepared!.get()
        try fixedInputsAndHeartbeat()
        try detachedFailureOwnership()
        invalidGeometry()
        try latestRenderAndMainHeartbeat()
        try staleRender("hidden") { $0.visible = false }
        try staleRender("resize") {
            $0.view.frame.size.width = 300
            $0.view.layoutSubtreeIfNeeded()
            $0.view.testingSetDrawableSize(CGSize(width: 600, height: 156))
        }
        try staleRender("configuration") {
            $0.view.configure(seed: 900, construction: .workspace, selected: true)
        }
        try staleRender("motion") { $0.reduced = false }
        try frozenBookmarkAndLighting()
        try idleHiddenReleasesShadow()
    }
}
