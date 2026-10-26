import AppKit
import MetalKit

#if !TAVERN_RENDER_TESTING
#error("Compile MaterialPreparationTests with -D TAVERN_RENDER_TESTING")
#endif

// Uses real Metal submissions and the normal resource bundle, not a replacement renderer.
// The worker gate has a deadline so a regression cannot deadlock the driver indefinitely.
@main struct MaterialPreparationTests {
    private final class Gate {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var enteredValue = false
        private var timedOutValue = false

        var entered: Bool { lock.lock(); defer { lock.unlock() }; return enteredValue }
        var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return timedOutValue }

        func block() {
            precondition(!Thread.isMainThread, "Preparation gate ran on main")
            lock.lock(); enteredValue = true; lock.unlock()
            if semaphore.wait(timeout: .now() + 8) == .timedOut {
                lock.lock(); timedOutValue = true; lock.unlock()
            }
        }

        func release() { semaphore.signal() }
    }

    private struct Submission {
        let key: TavernCardMaterialKey
        let bounds: CGRect
        let drawableSize: CGSize
    }

    private final class Host {
        let window: NSWindow
        let view: TavernCardSurfaceView
        var visible = true
        var reduced = true
        var submissions: [Submission] = []

        init(renderer: TavernCardRenderer) {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 260),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            view = TavernCardSurfaceView(frame: NSRect(x: 12, y: 12, width: 234.5, height: 78),
                                         renderer: renderer)
            view.testingVisibilityPolicy = { [weak self] in self?.visible ?? false }
            view.testingReduceMotionPolicy = { [weak self] in self?.reduced ?? true }
            view.onSubmittedFrame = { [weak self] key, bounds, drawableSize in
                guard let self else { return }
                precondition(Thread.isMainThread)
                precondition(bounds == self.view.bounds, "Submitted stale point geometry")
                precondition(key.plank.pointWidth == bounds.width && key.plank.pointHeight == bounds.height,
                             "Material point geometry differs from the encoded frame")
                precondition(key.plank.pixelWidth == Int(drawableSize.width.rounded()) &&
                             key.plank.pixelHeight == Int(drawableSize.height.rounded()),
                             "Material pixel geometry differs from the actual drawable")
                guard let maps = self.view.testingHeldMaps else { fatalError("Submitted without retained maps") }
                precondition(maps.textures.count == 4)
                for texture in maps.textures {
                    precondition(texture.width == key.plank.pixelWidth && texture.height == key.plank.pixelHeight,
                                 "Submitted a stretched old texture")
                }
                self.submissions.append(Submission(key: key, bounds: bounds, drawableSize: drawableSize))
            }
            window.contentView!.addSubview(view)
            window.orderFront(nil)
            view.layoutSubtreeIfNeeded()
        }

        func awaitFrame(after index: Int, _ message: String) {
            MaterialPreparationTests.wait(message) {
                if self.submissions.count > index { return true }
                self.view.refreshLighting()
                return self.submissions.count > index
            }
        }

        func close() {
            visible = false
            view.refreshLighting()
            view.removeFromSuperview()
            window.close()
        }
    }

    private static func wait(_ message: String, timeout: TimeInterval = 10,
                             mode: RunLoop.Mode = .default, until predicate: () -> Bool) {
        precondition(Thread.isMainThread)
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !predicate() {
            precondition(Date() < deadline, "Timed out: \(message)")
            _ = RunLoop.main.run(mode: mode, before: Date(timeIntervalSinceNow: 0.005))
        }
    }

    private static func key(seed: UInt64, width: CGFloat = 234.5, height: CGFloat = 78,
                            pixels: CGSize = CGSize(width: 469, height: 156),
                            selected: Bool = false,
                            construction: TavernPlankConstruction = .agent) -> TavernCardMaterialKey {
        TavernCardMaterialKey(plank: TavernPlankKey(seed: seed, construction: construction,
            pixelWidth: Int(pixels.width), pixelHeight: Int(pixels.height),
            pointWidth: width, pointHeight: height), selected: selected)
    }

    private static func fence(_ renderer: TavernCardRenderer, seed: UInt64) {
        var done = false
        renderer.requestPreparation(for: key(seed: seed)) { result in
            precondition(Thread.isMainThread)
            _ = try! result.get()
            done = true
        }
        wait("preparation queue fence") { done }
    }

    private static func fractionalKeys(_ renderer: TavernCardRenderer) throws {
        let left = key(seed: 42, width: 234.125)
        let right = key(seed: 42, width: 234.375)
        precondition(Set([left, right]).count == 2, "Fractional point widths were rounded in the key")
        let first = try renderer.buildMapsSynchronously(for: left)
        let second = try renderer.buildMapsSynchronously(for: right)
        precondition(first !== second, "Different fractional geometries reused the same material")
        precondition(renderer.cachedMaps(for: left) === first)
        precondition(renderer.cachedMaps(for: right) === second)
        let selected = key(seed: 42, width: 234.125, selected: true)
        let bookmark = try renderer.buildMapsSynchronously(for: selected)
        precondition(bookmark !== first, "Selection reused unselected material maps")
        precondition(renderer.cachedMaps(for: left) === first, "Selected preparation mutated the base cache entry")
        print("PASS: exact fractional and selection cache identities")
    }

    private static func synchronousFirstWinner(_ renderer: TavernCardRenderer) throws {
        let requested = key(seed: 1_001, selected: true)
        let gate = Gate()
        var completion: TavernCardMaps?
        renderer.preparationGate = { candidate in if candidate == requested { gate.block() } }
        renderer.requestPreparation(for: requested) { result in completion = try! result.get() }
        // The queued job must retain the hook captured for that job, not this mutable property.
        renderer.preparationGate = nil
        wait("worker enters captured gate") { gate.entered }
        var heartbeat = false
        RunLoop.main.perform { heartbeat = true }
        wait("main heartbeat during material preparation") { heartbeat }
        precondition(completion == nil)
        let synchronous = try renderer.buildMapsSynchronously(for: requested)
        precondition(!gate.timedOut, "Synchronous exact miss waited for the gated worker")
        precondition(completion == nil, "Main blocked until worker completion")
        precondition(renderer.cachedMaps(for: requested) === synchronous)
        gate.release()
        wait("late duplicate completion") { completion != nil }
        precondition(!gate.timedOut)
        precondition(completion === synchronous, "Late worker replaced the synchronous first winner")
        precondition(renderer.cachedMaps(for: requested) === synchronous)
        print("PASS: exact miss is independent of the worker; first publication wins")
    }

    private static func staleGeometry(_ renderer: TavernCardRenderer) throws {
        let host = Host(renderer: renderer)
        defer { host.close() }
        host.view.testingSetDrawableSize(CGSize(width: 469, height: 156))
        let initialFrame = host.submissions.count
        host.view.configure(seed: 2_000, construction: .agent, selected: false)
        host.awaitFrame(after: initialFrame, "initial exact drawable")
        // A submitted frame can have synchronously won while its cancelled preparation
        // still awaits main delivery. Drain that completion before restricting runloop modes.
        fence(renderer, seed: 2_098)

        let old = key(seed: 2_001)
        let gate = Gate()
        renderer.preparationGate = { candidate in if candidate == old { gate.block() } }
        host.view.configure(seed: old.plank.seed, construction: .agent, selected: false)
        // Do not service the deferred display flush before the worker has started:
        // that would cancel the queued job and test a different race.
        wait("old geometry worker gate", mode: RunLoop.Mode("MaterialPreparationGate")) { gate.entered }
        renderer.preparationGate = nil
        // Preparation A is still blocked. Geometry B must submit exact maps immediately,
        // not wait for A and not use the maps retained by the preceding frame.
        let firstNewFrame = host.submissions.count
        host.view.frame.size = CGSize(width: 374.25, height: 78)
        host.view.layoutSubtreeIfNeeded()
        host.view.testingSetDrawableSize(CGSize(width: 749, height: 156))
        host.awaitFrame(after: firstNewFrame, "first resized frame while worker is blocked")
        precondition(!gate.timedOut, "Geometry-critical rendering waited for preparation")
        let first = host.submissions[firstNewFrame]
        precondition(first.bounds.size == CGSize(width: 374.25, height: 78), "First resized frame used old bounds")
        precondition(first.key.plank.pointWidth == 374.25)
        guard let current = host.view.testingMaterialKey, let currentMaps = host.view.testingHeldMaps else {
            fatalError("Resized view has no exact material")
        }
        precondition(current != old)
        gate.release()
        fence(renderer, seed: 2_099)
        precondition(!gate.timedOut)
        precondition(host.view.testingMaterialKey == current, "Stale worker completion replaced current geometry")
        precondition(host.view.testingHeldMaps === currentMaps, "Stale maps replaced the view's exact maps")
        precondition(renderer.cachedMaps(for: current) === currentMaps, "Stale publication displaced current cache entry")
        precondition(renderer.cachedMaps(for: old) == nil, "Stale geometry was published into reusable caches")
        print("PASS: newer exact geometry is submitted before stale preparation completes")
    }

    private static func visibilityBackingAndReducedMotion(_ renderer: TavernCardRenderer) {
        let host = Host(renderer: renderer)
        defer { host.close() }
        let initialFrame = host.submissions.count
        host.view.configure(seed: 3_000, construction: .workspace, selected: true)
        host.view.testingSetDrawableSize(CGSize(width: 469, height: 156))
        host.awaitFrame(after: initialFrame, "visible workspace material")
        precondition(host.view.testingHeldMaps != nil)
        host.visible = false
        host.view.refreshLighting()
        precondition(host.view.testingHeldMaps == nil, "Hidden view retained material maps")
        let hiddenFrames = host.submissions.count
        host.view.configure(seed: 3_001, construction: .workspace, selected: false)
        host.view.frame.size = CGSize(width: 374, height: 40)
        host.view.layoutSubtreeIfNeeded()
        host.view.testingSetDrawableSize(CGSize(width: 374, height: 40))
        precondition(host.view.testingHeldMaps == nil, "Hidden reconfiguration prepared view-held maps")
        precondition(host.submissions.count == hiddenFrames, "Hidden view submitted a frame")
        host.visible = true
        host.view.refreshLighting()
        host.awaitFrame(after: hiddenFrames, "hidden to visible with Reduce Motion")
        let restored = host.submissions[hiddenFrames]
        precondition(restored.key == key(seed: 3_001, width: 374, height: 40,
            pixels: CGSize(width: 374, height: 40), construction: .workspace))
        let beforeBacking = host.submissions.count
        host.view.testingSetDrawableSize(CGSize(width: 748, height: 80))
        host.view.viewDidChangeBackingProperties()
        host.awaitFrame(after: beforeBacking, "2x backing transition")
        let backed = host.submissions[beforeBacking]
        precondition(backed.drawableSize == CGSize(width: 748, height: 80))
        precondition(backed.key.plank.pointWidth == 374 && backed.key.plank.pixelWidth == 748)
        host.reduced = false
        host.view.refreshLighting()
        let beforeReduced = host.submissions.count
        host.reduced = true
        host.view.configure(seed: 3_002, construction: .agent, selected: true)
        host.awaitFrame(after: beforeReduced, "dirty frame after Reduce Motion transition")
        precondition(host.submissions.last!.key.plank.seed == 3_002)
        host.visible = false
        host.view.refreshLighting()
        host.view.removeFromSuperview()
        precondition(host.view.testingHeldMaps == nil, "Detached view retained material maps")
        print("PASS: hidden release, exact restore, backing change and Reduce Motion dirty frame")
    }

    private static func viewportClipping(_ renderer: TavernCardRenderer) {
        let host = Host(renderer: renderer)
        defer { host.close() }
        let scroll = NSScrollView(frame: host.window.contentView!.bounds)
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 1200))
        scroll.documentView = document
        host.view.removeFromSuperview()
        document.addSubview(host.view)
        host.window.contentView = scroll
        let initial = host.submissions.count
        host.view.testingSetDrawableSize(CGSize(width: 469, height: 156))
        host.view.refreshLighting()
        host.awaitFrame(after: initial, "visible card in scroll viewport")
        precondition(host.view.testingHeldMaps != nil)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 800))
        scroll.reflectScrolledClipView(scroll.contentView)
        wait("offscreen scroll releases material maps") { host.view.testingHeldMaps == nil }
        precondition(!host.view.bounds.intersects(host.view.visibleRect))
        let beforeRestore = host.submissions.count
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        host.awaitFrame(after: beforeRestore, "scroll restores exact visible material")
        precondition(host.view.testingHeldMaps != nil)
        print("PASS: offscreen clip geometry releases maps and scrolling back restores them")
    }

    private static func coldSnapshot(_ renderer: TavernCardRenderer) {
        let view = TavernCardSurfaceView(frame: NSRect(x: 0, y: 0, width: 234.5, height: 78), renderer: renderer)
        view.testingVisibilityPolicy = { false }
        view.testingReduceMotionPolicy = { true }
        view.configure(seed: UInt64.max, construction: .agent, selected: true)
        precondition(view.testingHeldMaps == nil)
        var captured: Result<CGImage, Error>?
        view.requestSnapshot { captured = $0 }
        wait("cold detached snapshot") { captured != nil }
        guard case .success(let image)? = captured else {
            fatalError("Cold, detached card could not be captured")
        }
        let bitmap = NSBitmapImageRep(cgImage: image)
        precondition(image.width == 469 && image.height == 156, "Cold snapshot geometry was rounded in points")
        for fraction in [0.2, 0.4, 0.6, 0.8] {
            let colour = bitmap.colorAt(x: Int(Double(image.width) * fraction), y: image.height / 2)!
            precondition(colour.alphaComponent > 0.99, "Cold snapshot lost the wooden material")
        }
        for (x, y) in [(0, image.height / 2), (image.width - 1, image.height / 2),
                       (image.width / 2, 0), (image.width / 2, image.height - 1)] {
            precondition(bitmap.colorAt(x: x, y: y)!.alphaComponent < 0.01,
                         "Cold snapshot material escaped its card boundary")
        }
        precondition(view.testingHeldMaps == nil, "Hidden cold snapshot retained reusable view maps")
        print("PASS: cold detached snapshot retains exact fractional geometry and material")
    }

    static func main() throws {
        _ = NSApplication.shared
        guard CommandLine.arguments.count == 2,
              let bundle = Bundle(path: CommandLine.arguments[1]), bundle.resourceURL != nil else {
            fatalError("Pass the built Herdr Tavern.app as argument 1; run this driver from its own resource-equipped .app")
        }
        var prepared: Result<Void, Error>?
        TavernCardSurfaceView.prepareResources { prepared = $0 }
        wait("renderer resources") { prepared != nil }
        try prepared!.get()
        let renderer = try TavernCardRenderer.shared.get()
        try fractionalKeys(renderer)
        try synchronousFirstWinner(renderer)
        try staleGeometry(renderer)
        visibilityBackingAndReducedMotion(renderer)
        viewportClipping(renderer)
        coldSnapshot(renderer)
        print("PASS: MaterialPreparationTests")
    }
}
