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
    static func pump(_ mode: RunLoop.Mode = .default, until ready: () -> Bool,
                     file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date(timeIntervalSinceNow: 10)
        while !ready(), Date() < deadline {
            RunLoop.main.run(mode: mode, before: Date(timeIntervalSinceNow: 0.005))
        }
        precondition(ready(), "Snapshot runloop deadline exceeded in \(mode)", file: file, line: line)
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

    static func main() throws {
        _ = NSApplication.shared
        var prepared: Result<Void, Error>?
        TavernCardSurfaceView.prepareResources { prepared = $0 }
        pump { prepared != nil }
        try prepared!.get()
        try fixedInputsAndHeartbeat()
        try detachedFailureOwnership()
        invalidGeometry()
    }
}
