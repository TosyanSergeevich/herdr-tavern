import AppKit

#if !TAVERN_RENDER_TESTING
#error("NebulaRenderingTests requires -D TAVERN_RENDER_TESTING")
#endif

// Run inside a disposable .app with the built Tavern's Resources, on a logged-in
// macOS desktop. This driver never connects to herdr or changes user settings.
@main struct NebulaRenderingTests {
    private static let blue = NSColor(calibratedRed: 0.2, green: 0.4, blue: 0.9, alpha: 1)
    private static let pink = NSColor(calibratedRed: 0.9, green: 0.3, blue: 0.6, alpha: 1)
    private static func wait(_ description: String, details: @autoclosure () -> String = "", until predicate: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: 10)
        while !predicate(), Date() < deadline {
            pumpEvents(until: min(deadline, Date(timeIntervalSinceNow: 0.005)))
        }
        precondition(predicate(), "Timed out: \(description)\n\(details())\n\(windowDiagnostics())")
    }

    private static func pumpEvents(until deadline: Date) {
        // RunLoop.main alone does not dispatch AppKit/window-server events.
        if let event = NSApp.nextEvent(matching: .any, until: deadline,
                                       inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
        NSApp.updateWindows()
        RunLoop.main.run(until: min(deadline, Date(timeIntervalSinceNow: 0.001)))
    }

    private static func windowDiagnostics() -> String {
        let pid = ProcessInfo.processInfo.processIdentifier
        let appKit = NSApp.windows.map {
            "number=\($0.windowNumber) visible=\($0.isVisible) occlusion=\($0.occlusionState.rawValue) frame=\($0.frame)"
        }
        let all = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements],
                                             kCGNullWindowID) as? [[String: Any]] ?? []
        let own = all.filter {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
        }
        let cg = own.map {
            "number=\(String(describing: $0[kCGWindowNumber as String])) bounds=\(String(describing: $0[kCGWindowBounds as String])) onscreen=\(String(describing: $0[kCGWindowIsOnscreen as String]))"
        }
        return "pid=\(pid) NSApp.isActive=\(NSApp.isActive) NSApp.isHidden=\(NSApp.isHidden)\nAppKit windows: \(appKit)\nCGWindowList PID matches=\(own.count): \(cg)"
    }

    private static func pump(_ seconds: TimeInterval) {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while Date() < deadline {
            pumpEvents(until: min(deadline, Date(timeIntervalSinceNow: 0.005)))
        }
    }

    private static func changedMotion() {
        NotificationCenter.default.post(name: .tavernMotionDidChange, object: nil)
    }

    private static func boundedLatestFrameAndResize(_ view: TavernWorkspaceNebulaView) {
        var gateEntries = 0
        var frames: [CGSize] = []
        let release = DispatchSemaphore(value: 0)
        TavernWorkspaceNebulaView.renderDidComplete = { _, size in
            precondition(Thread.isMainThread)
            frames.append(size)
        }
        TavernWorkspaceNebulaView.renderGate = {
            precondition(!Thread.isMainThread, "Drawable acquisition must not run on main")
            DispatchQueue.main.async { gateEntries += 1 }
            precondition(release.wait(timeout: .now() + 8) == .success)
        }
        view.configure(cardSize: NSSize(width: 200, height: 80), agentColor: blue)
        wait("first drawable worker gate") { gateEntries == 1 }
        for index in 0..<100 {
            view.configure(cardSize: NSSize(width: CGFloat(201 + index), height: 80), agentColor: blue)
        }
        TavernWorkspaceNebulaView.renderGate = nil
        view.setFrameSize(NSSize(width: 340, height: 130))
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        var heartbeat = false
        DispatchQueue.main.async { heartbeat = true }
        wait("main heartbeat with drawable worker blocked") { heartbeat }
        pump(0.15)
        precondition(gateEntries == 1 && frames.isEmpty,
                     "Blocked rendering must have one job and no completed frames")
        let scale = view.window!.backingScaleFactor
        let expected = CGSize(width: (view.bounds.width * scale).rounded(),
                              height: (view.bounds.height * scale).rounded())
        release.signal()
        wait("latest resized frame") { !frames.isEmpty }
        pump(0.15)
        precondition(frames.count == 1 && frames[0] == expected,
                     "Render backlog was retained or an old-size frame was published: \(frames)")
        let before = frames.count
        for _ in 0..<20 {
            view.configure(cardSize: NSSize(width: 300, height: 80), agentColor: blue)
        }
        pump(0.15)
        precondition(frames.count == before, "Equal configure must not request another drawable")
        print("PASS: bounded latest frame, main responsiveness, resize, equal configure")
    }

    private static func hiddenCancelsStaleLighting(_ view: TavernWorkspaceNebulaView) {
        var entered = false
        var completed = 0
        let release = DispatchSemaphore(value: 0)
        TavernWorkspaceNebulaView.renderDidComplete = { _, _ in completed += 1 }
        TavernWorkspaceNebulaView.renderGate = {
            precondition(!Thread.isMainThread)
            DispatchQueue.main.async { entered = true }
            precondition(release.wait(timeout: .now() + 8) == .success)
        }
        view.configure(cardSize: NSSize(width: 301, height: 80), agentColor: pink)
        wait("hidden test worker gate") { entered }
        view.isHidden = true
        for index in 0..<7 {
            precondition(view.materialLights[index].position.w == 0, "Hidden view retained material lighting")
        }
        TavernWorkspaceNebulaView.renderGate = nil
        release.signal()
        pump(0.25)
        precondition(completed == 0, "Hidden view published a stale GPU completion")
        view.isHidden = false
        wait("unhidden frame") { completed == 1 }
        print("PASS: hidden work cancellation and resumed rendering")
    }

    private static func delayedAnimationAndMotionStop(_ view: TavernWorkspaceNebulaView) {
        var times: [Double] = []
        TavernWorkspaceNebulaView.renderDidComplete = { seconds, _ in times.append(seconds) }
        TavernWorkspaceNebulaView.motionEnabled = true
        changedMotion()
        wait("normal animation frames") { times.count >= 4 }
        let regularDelta = (times[3] - times[2] + 10).truncatingRemainder(dividingBy: 10)
        precondition(regularDelta > 0.015 && regularDelta <= 0.10001,
                     "Ordinary clock frames lost animation progression: \(regularDelta)")
        var entered = false
        let release = DispatchSemaphore(value: 0)
        TavernWorkspaceNebulaView.renderGate = {
            precondition(!Thread.isMainThread)
            DispatchQueue.main.async { entered = true }
            precondition(release.wait(timeout: .now() + 8) == .success)
        }
        wait("animation worker gate") { entered }
        let previous = times.last!
        let before = times.count
        pump(0.4)
        precondition(times.count == before, "Another render ran while the frame was blocked")
        TavernWorkspaceNebulaView.renderGate = nil
        release.signal()
        wait("post-delay frame") { times.count > before }
        let delta = (times[before] - previous + 10).truncatingRemainder(dividingBy: 10)
        precondition(delta > 0 && delta <= 0.10001,
                     "Displayed animation jumped after drawable delay: \(delta)")
        TavernWorkspaceNebulaView.motionEnabled = false
        changedMotion()
        pump(0.2)
        let stopped = times.count
        pump(0.2)
        precondition(times.count == stopped, "Disabled motion continued requesting frames")
        print("PASS: 24Hz animation, bounded post-delay time step, motion stop")
    }

    private static func rejectsStaleCompletion(_ view: TavernWorkspaceNebulaView,
                                                name: String, size: CGFloat,
                                                animated: Bool = false, change: () -> Void) {
        var entered = false
        var completions = 0
        let release = DispatchSemaphore(value: 0)
        TavernWorkspaceNebulaView.renderCompletionGate = {
            precondition(!Thread.isMainThread)
            DispatchQueue.main.async { entered = true }
            precondition(release.wait(timeout: .now() + 8) == .success)
        }
        TavernWorkspaceNebulaView.renderDidComplete = { _, _ in completions += 1 }
        TavernWorkspaceNebulaView.motionEnabled = animated
        changedMotion()
        view.configure(cardSize: NSSize(width: size, height: 80), agentColor: blue)
        wait("\(name) GPU completion gate") { entered }
        TavernWorkspaceNebulaView.renderCompletionGate = nil
        change()
        release.signal()
        pump(0.25)
        if view.isHidden {
            precondition(completions == 0, "\(name) published stale lights after commit")
            view.isHidden = false
            wait("\(name) resumed completion", details: "completed=\(completions) " + String(describing: TavernPerformance.shared.snapshot()["counters"])) { completions == 1 }
        } else {
            wait("\(name) replacement completion") { completions >= 1 }
            precondition(completions == 1, "\(name) published stale lights after commit")
        }
        print("PASS: post-commit \(name) rejects stale material lighting")
    }

    private static func repeatedTimestampDoesNotWrap() {
        let previous = 0.3
        let rounded = Double(Float(previous))
        precondition(TavernNebulaAnimationTime.advancing(from: previous, to: rounded) == previous)
        precondition(TavernNebulaAnimationTime.advancing(from: previous, to: previous - 0.0000001) == previous,
                     "Float rounding was interpreted as a ten-second wrap")
        let wrapped = TavernNebulaAnimationTime.advancing(from: 9.98, to: 0.02)
        precondition(abs(wrapped - 0.02) < 0.000001, "Real loop wrap must still advance normally")
        print("PASS: duplicate/rounded timestamps and genuine animation wrap")
    }

    static func main() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.finishLaunching()
        TavernWorkspaceNebulaView.motionEnabled = false
        defer {
            TavernWorkspaceNebulaView.renderGate = nil
            TavernWorkspaceNebulaView.renderDidComplete = nil
            TavernWorkspaceNebulaView.renderCompletionGate = nil
            TavernWorkspaceNebulaView.motionEnabled = nil
        }
        var prepared: Result<Void, Error>?
        TavernCardSurfaceView.prepareResources { prepared = $0 }
        wait("renderer resources") { prepared != nil }
        try prepared!.get()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 450, height: 220),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = TavernWorkspaceNebulaView(frame: NSRect(x: 20, y: 20, width: 260, height: 110))
        window.contentView!.addSubview(view)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { view.isHidden = true; window.close() }
        wait("visible active test window") {
            NSApp.isActive && window.isVisible && window.occlusionState.contains(.visible)
        }
        window.contentView!.layoutSubtreeIfNeeded()
        boundedLatestFrameAndResize(view)
        hiddenCancelsStaleLighting(view)
        rejectsStaleCompletion(view, name: "resize", size: 310) {
            view.setFrameSize(NSSize(width: 360, height: 140))
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
        }
        rejectsStaleCompletion(view, name: "tint", size: 311) {
            view.configure(cardSize: NSSize(width: 311, height: 80), agentColor: pink)
        }
        rejectsStaleCompletion(view, name: "motion policy", size: 312, animated: true) {
            TavernWorkspaceNebulaView.motionEnabled = false
            changedMotion()
        }
        rejectsStaleCompletion(view, name: "hidden", size: 313) { view.isHidden = true }
        repeatedTimestampDoesNotWrap()
        delayedAnimationAndMotionStop(view)
        print("PASS: Nebula rendering runtime regressions")
    }
}
