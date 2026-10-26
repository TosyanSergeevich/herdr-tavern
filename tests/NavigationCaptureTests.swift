import AppKit

#if TAVERN_RENDER_TESTING
@main struct NavigationCaptureTests {
    final class Clicks: NSObject {
        var count = 0
        @objc func click(_ sender: Any?) { count += 1 }
    }

    final class Fixture {
        let drag = TavernNavigationDrag()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        let button: NSButton
        let second: NSButton
        let clicks = Clicks()
        var pending: [(NSView, (Result<NSImage, Error>) -> Void)] = []
        var events: [() -> NSEvent] = []
        var moves: [TavernDropTarget] = []
        var proposedPoints: [NSPoint] = []
        var valid = true
        var available = true
        var bundled = false
        var bundleDecision: ((NSPoint) -> Bool)?
        var targetExists = true
        var scrolls = 0
        var completion: ((Bool) -> Void)?
        var memberOverride: [NSButton]?

        init(cards: Bool = false) {
            button = cards ? TavernButton(frame: NSRect(x: 20, y: 20, width: 120, height: 50))
                : NSButton(frame: NSRect(x: 20, y: 20, width: 120, height: 50))
            second = cards ? TavernButton(frame: NSRect(x: 20, y: 90, width: 120, height: 50))
                : NSButton(frame: NSRect(x: 20, y: 90, width: 120, height: 50))
            window.contentView = root
            root.addSubview(button); root.addSubview(second)
            button.setAccessibilityIdentifier("source")
            second.setAccessibilityIdentifier("second")
            button.target = clicks; button.action = #selector(Clicks.click(_:))
            drag.windowAvailableForTesting = { [unowned self] in available }
            drag.requestImageForTesting = { [unowned self] view, reply in pending.append((view, reply)) }
            drag.nextEventForTesting = { [unowned self] in
                precondition(!events.isEmpty, "Tracking consumed an event after release")
                return events.removeFirst()()
            }
        }
        func mouse(_ type: NSEvent.EventType, _ x: CGFloat = 45, _ y: CGFloat = 40) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: 0,
                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func escape() -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                             windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                             charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        }
        func queue(_ type: NSEvent.EventType, _ x: CGFloat = 45) {
            events.append { [unowned self] in mouse(type, x) }
        }
        func track() {
            precondition(drag.track(button: button, event: mouse(.leftMouseDown, 30), root: root,
                limits: { [unowned self] in root.bounds }, valid: { [unowned self] in valid },
                members: { [unowned self] in memberOverride ?? [second, button] },
                bundleAt: { [unowned self] point, _ in bundleDecision?(point) ?? bundled },
                proposal: { [unowned self] point in
                    proposedPoints.append(point)
                    return targetExists ? TavernDropProposal(target: .tabSlot(Int(point.x)),
                        rect: NSRect(x: 200, y: 100, width: 100, height: 50), title: "drop") : nil
                }, autoscroll: { [unowned self] _ in scrolls += 1 },
                perform: { [unowned self] target, reply in moves.append(target); completion = reply }))
        }
        func completeFirst() {
            let entry = pending.removeFirst()
            entry.1(.success(NSImage(size: entry.0.bounds.size)))
        }
        func releasePending() {
            queue(.leftMouseDragged); queue(.leftMouseUp, 80); track()
            precondition(!drag.tracking && moves.isEmpty && clicks.count == 0)
            precondition(!button.isHidden && drag.displayedCardsForTesting.isEmpty)
        }
        func pump(until predicate: () -> Bool) {
            let deadline = Date(timeIntervalSinceNow: 1)
            while !predicate(), Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            }
            precondition(predicate(), "Runloop did not reach expected state")
        }
    }

    static func main() throws {
        _ = NSApplication.shared
        try TavernAppearance.validateFonts()
        var prepared: Result<Void, Error>?
        TavernCardSurfaceView.prepareResources { prepared = $0 }
        let deadline = Date(timeIntervalSinceNow: 10)
        while prepared == nil, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        }
        guard let prepared else { preconditionFailure("Renderer preparation timed out") }
        try prepared.get()
        clickBeforeThreshold()
        atomicSelectedFirst()
        escapeDuringCapture()
        immutableReleaseAndNewGesture()
        terminalCancellation()
        latestBundleRefresh()
        releasePointDeterminesBundle()
        captureFailure()
        visualRevisionAndViewIdentity()
        print("PASS: async navigation captures, terminal pending, atomic groups and cancellation")
    }

    static func clickBeforeThreshold() {
        let f = Fixture()
        f.queue(.leftMouseUp, 32); f.track()
        precondition(f.clicks.count == 1 && f.pending.isEmpty && f.moves.isEmpty)
    }
    static func atomicSelectedFirst() {
        let f = Fixture(); f.bundled = true
        f.releasePending()
        precondition(f.pending.count == 2 && f.pending[0].0 === f.button)
        f.completeFirst()
        precondition(!f.button.isHidden && !f.second.isHidden && f.drag.displayedCardsForTesting.isEmpty)
        f.completeFirst()
        precondition(f.moves == [.tabSlot(80)] && f.drag.displayedCardsForTesting == [f.button, f.second])
        precondition(f.button.isHidden && f.second.isHidden)
        f.drag.cancel()
        precondition(!f.button.isHidden && !f.second.isHidden && f.drag.displayedCardsForTesting.isEmpty)
    }
    static func escapeDuringCapture() {
        let f = Fixture()
        f.queue(.leftMouseDragged)
        f.events.append { f.escape() }
        f.track(); f.completeFirst()
        precondition(f.moves.isEmpty && f.clicks.count == 0 && !f.button.isHidden)
        precondition(f.drag.displayedCardsForTesting.isEmpty)
        let terminal = Fixture(); terminal.releasePending()
        NSApp.sendEvent(terminal.escape())
        terminal.completeFirst()
        precondition(terminal.moves.isEmpty && !terminal.button.isHidden)
    }
    static func immutableReleaseAndNewGesture() {
        let f = Fixture(); f.releasePending()
        let previous = f.pending.removeFirst().1
        f.queue(.leftMouseUp, 32); f.track()
        previous(.success(NSImage(size: f.button.bounds.size)))
        precondition(f.clicks.count == 1 && f.moves.isEmpty && !f.button.isHidden)
        precondition(f.events.isEmpty)
        let retained = Fixture(); retained.releasePending()
        let scrolls = retained.scrolls
        retained.pump { true }
        retained.completeFirst()
        precondition(retained.moves == [.tabSlot(80)] && retained.scrolls == scrolls)
        precondition(retained.proposedPoints.last == NSPoint(x: 80, y: 40))
        retained.drag.cancel()
    }
    static func terminalCancellation() {
        for reason in ["removed source", "window unavailable", "reconnect", "removed target"] {
            let f = Fixture(); f.releasePending()
            switch reason {
            case "removed source": f.button.removeFromSuperview()
            case "window unavailable": f.available = false
            case "reconnect": f.valid = false; f.drag.refresh()
            default: f.targetExists = false
            }
            f.completeFirst()
            f.pump { f.drag.displayedCardsForTesting.isEmpty }
            precondition(f.moves.isEmpty && !f.button.isHidden, reason)
            f.drag.cancel()
        }
    }
    static func latestBundleRefresh() {
        let f = Fixture()
        f.queue(.leftMouseDragged)
        f.events.append {
            f.bundled = true; f.drag.refresh(); f.drag.refresh()
            return f.mouse(.leftMouseDragged, 55)
        }
        f.queue(.leftMouseUp, 80); f.track()
        precondition(f.pending.count == 1)
        f.completeFirst()
        precondition(f.moves.isEmpty && !f.button.isHidden && f.pending.count == 2)
        f.completeFirst(); f.completeFirst()
        precondition(f.moves.count == 1 && f.drag.displayedCardsForTesting == [f.button, f.second])
        f.completion?(false)
        f.drag.refresh()
        precondition(f.pending.isEmpty, "Returning must not create unused images")
        f.drag.cancel()
    }
    static func releasePointDeterminesBundle() {
        let gathering = Fixture()
        gathering.bundleDecision = { $0.x >= 70 }
        gathering.queue(.leftMouseDragged, 45)
        gathering.queue(.leftMouseUp, 80)
        gathering.track()
        gathering.completeFirst()
        precondition(gathering.moves.isEmpty && !gathering.button.isHidden && gathering.pending.count == 2,
                     "Mouse-up must gather the new release-point group before moving")
        gathering.completeFirst(); gathering.completeFirst()
        precondition(gathering.moves == [.tabSlot(80)]
            && gathering.drag.displayedCardsForTesting == [gathering.button, gathering.second])
        gathering.drag.cancel()

        let separating = Fixture()
        separating.bundleDecision = { $0.x >= 70 }
        separating.queue(.leftMouseDragged, 80)
        separating.queue(.leftMouseUp, 45)
        separating.track()
        separating.completeFirst(); separating.completeFirst()
        precondition(separating.moves.isEmpty && separating.pending.count == 1,
                     "Mouse-up must replace an old bundle with the single-card capture")
        separating.completeFirst()
        precondition(separating.moves == [.tabSlot(45)]
            && separating.drag.displayedCardsForTesting == [separating.button] && !separating.second.isHidden)
        separating.drag.cancel()
    }

    static func captureFailure() {
        let f = Fixture(); f.bundled = true; f.releasePending()
        f.pending.removeFirst().1(.failure(NSError(domain: "test", code: 1)))
        f.completeFirst()
        precondition(f.moves.isEmpty && !f.button.isHidden && !f.second.isHidden)
        precondition(f.drag.displayedCardsForTesting.isEmpty)
    }
    static func visualRevisionAndViewIdentity() {
        let f = Fixture(cards: true)
        let card = f.button as! TavernButton
        card.title = "captured"
        let first = NSImage(size: NSSize(width: 121, height: 50))
        let feedback = NSImage(size: NSSize(width: 122, height: 50))
        let oldSecond = NSImage(size: NSSize(width: 123, height: 50))
        let newSecond = NSImage(size: NSSize(width: 124, height: 50))
        f.queue(.leftMouseDragged)
        f.events.append {
            card.title = "changed while capturing"
            f.pending.removeFirst().1(.success(NSImage(size: NSSize(width: 119, height: 50))))
            precondition(f.drag.displayedImagesForTesting.isEmpty, "Stale text capture must not publish")
            f.pending.removeFirst().1(.success(first))
            precondition(f.drag.displayedImagesForTesting.first === first)
            f.drag.refresh()
            card.title = "changed while capturing"
            precondition(f.drag.displayedImagesForTesting.first === first)
            card.isEnabled = false
            f.drag.refresh()
            precondition(f.drag.displayedImagesForTesting.first === first, "Refresh publishes atomically")
            f.pending.removeFirst().1(.success(feedback))
            precondition(f.drag.displayedImagesForTesting.first === feedback, "Target feedback refreshes visual")
            f.bundled = true
            return f.mouse(.leftMouseDragged, 55)
        }
        f.events.append {
            f.pending.removeFirst().1(.success(oldSecond))
            precondition(f.drag.displayedImagesForTesting[0] === feedback)
            precondition(f.drag.displayedImagesForTesting[1] === oldSecond)
            let other = TavernButton(frame: f.second.frame)
            other.setAccessibilityIdentifier("second")
            f.root.addSubview(other)
            f.second.removeFromSuperview()
            f.memberOverride = [other, card]
            f.drag.refresh()
            precondition(f.drag.displayedImagesForTesting[1] === oldSecond)
            f.pending.removeFirst().1(.success(newSecond))
            precondition(f.drag.displayedImagesForTesting[1] === newSecond, "Reused ID must not reuse old view bitmap")
            return f.escape()
        }
        f.track()
        f.drag.cancel()
        precondition(f.moves.isEmpty && !card.isHidden)
    }

}
#else
@main struct NavigationCaptureTests {
    static func main() { fatalError("Compile NavigationCaptureTests with -D TAVERN_RENDER_TESTING") }
}
#endif
