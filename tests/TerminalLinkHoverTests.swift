import AppKit

#if !TAVERN_RENDER_TESTING
#error("TerminalLinkHoverTests requires -D TAVERN_RENDER_TESTING")
#endif

private final class HoverFileGate {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var blocked = true
    private var entered = false
    var hasEntered: Bool { lock.lock(); defer { lock.unlock() }; return entered }
    func exists(_ path: String) -> Bool {
        precondition(!Thread.isMainThread, "Filesystem hover work reached main")
        lock.lock()
        let shouldBlock = blocked
        blocked = false
        if shouldBlock { entered = true }
        lock.unlock()
        if shouldBlock { release.wait() }
        return FileManager.default.fileExists(atPath: path)
    }
    func resume() { release.signal() }
}

@main struct TerminalLinkHoverTests {
    static func waitUntil(_ label: String, _ condition: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: 3)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005)) }
        precondition(condition(), label)
    }
    static func settle(_ duration: TimeInterval = 0.1) {
        let deadline = Date(timeIntervalSinceNow: duration)
        while Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005)) }
    }
    private final class Harness {
        let gate = HoverFileGate()
        let surface: SurfaceView
        let window: NSWindow
        var location: NSPoint?
        var flags: NSEvent.ModifierFlags = .command
        var visible = true
        var cwd: String?
        var sent: [[String: Any]] = []
        var opened: [URL] = []
        var revision = 1
        let text: String
        init(root: URL, name: String) throws {
            text = name
            cwd = root.path
            let font = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
            let resolver = TerminalLinkHoverResolver(fileExists: gate.exists)
            surface = SurfaceView(fonts: TerminalFonts(regular: font, bold: font, italic: font,
                boldItalic: font, symbols: font), hoverResolver: resolver)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 60),
                              styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = surface
            surface.setFrameSize(NSSize(width: 640, height: 60))
            surface.linkHoverEnvironment = { [weak self] in
                guard let self else { return (nil, [], false) }
                return (self.location, self.flags, self.visible)
            }
            surface.workingDirectoryForPane = { [weak self] _ in self?.cwd }
            surface.send = { [weak self] in self?.sent.append($0) }
            surface.openLink = { [weak self] in self?.opened.append($0) }
            try full()
            location = surface.convert(NSPoint(x: 4, y: 10), to: nil)
        }
        deinit { gate.resume(); window.close() }
        func metadata(patch: Bool = false) -> [String: Any] {
            ["boot_id": "hover", "projection_revision": 1, "surface_revision": revision,
             "base_surface_revision": revision - 1, "width": 80, "height": 3,
             "panes": [["pane_id": "p", "focused": true, "mouse_reporting": true,
                         "inner_rect": ["x": 0, "y": 0, "width": 80, "height": 3]]]]
        }
        func full() throws {
            var cells = Array(repeating: TerminalCell(), count: 240)
            for (index, character) in text.enumerated() { cells[index].symbol = String(character) }
            try surface.apply(metadata: metadata(), segments: [CellSegment(x: 0, y: 0, cells: cells)], images: [:], patch: false)
        }
        func erase() throws {
            revision += 1
            try surface.apply(metadata: metadata(patch: true),
                segments: [CellSegment(x: 0, y: 0, cells: Array(repeating: TerminalCell(), count: text.count))], images: [:], patch: true)
        }
        func event(_ type: NSEvent.EventType, flags override: NSEvent.ModifierFlags? = nil) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: location!, modifierFlags: override ?? flags,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                clickCount: 1, pressure: 1)!
        }
        func move() { surface.mouseMoved(with: event(.mouseMoved)) }
        var phases: [String] { sent.map { string($0["phase"]) } }
    }

    static func main() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tavern-hover-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hit = root.appendingPathComponent("hit.swift")
        try Data("fixture".utf8).write(to: hit)
        do {
            let h = try Harness(root: root, name: "hit.swift")
            h.move(); waitUntil("worker did not enter filesystem") { h.gate.hasEntered }
            var heartbeat = 0
            let timer = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { _ in heartbeat += 1 }
            settle(0.08); timer.invalidate()
            precondition(heartbeat >= 5 && h.sent.isEmpty && h.surface.toolTip == nil)
            h.gate.resume(); waitUntil("hit hover did not publish") { h.surface.toolTip == hit.path }
            precondition(h.sent.isEmpty, "Link hit leaked mouse move to PTY")
            print("PASS: blocking filesystem leaves main responsive; link hit suppresses pending PTY move")
        }
        do {
            let h = try Harness(root: root, name: "missing.swift")
            h.move(); waitUntil("missing worker did not enter") { h.gate.hasEntered }
            h.move(); h.move()
            precondition(h.sent.isEmpty)
            h.gate.resume(); waitUntil("latest missing move did not publish") { h.phases == ["move"] }
            settle(); precondition(h.phases == ["move"])
            print("PASS: pending misses keep only the latest mouse move")
        }
        for interaction in ["down-up", "drag", "menu", "exit", "modifier", "hide", "patch", "cwd", "reconnect"] {
            let h = try Harness(root: root, name: "missing.swift")
            h.move(); waitUntil("race worker did not enter: \(interaction)") { h.gate.hasEntered }
            switch interaction {
            case "down-up":
                h.surface.mouseDown(with: h.event(.leftMouseDown, flags: []))
                h.surface.mouseUp(with: h.event(.leftMouseUp, flags: []))
                precondition(h.phases == ["down", "up"])
            case "drag":
                h.surface.mouseDown(with: h.event(.leftMouseDown, flags: []))
                h.surface.mouseDragged(with: h.event(.leftMouseDragged, flags: []))
                h.surface.mouseUp(with: h.event(.leftMouseUp, flags: []))
                precondition(h.phases == ["down", "drag", "up"])
            case "menu":
                h.surface.contextMenuForPane = { _ in NSMenu() }
                h.surface.presentContextMenu = { _, _, _ in }
                h.surface.rightMouseDown(with: h.event(.rightMouseDown, flags: []))
            case "exit":
                let event = h.event(.mouseMoved); h.location = nil; h.surface.mouseExited(with: event)
            case "modifier": h.flags = []; h.surface.flagsChanged(with: h.event(.mouseMoved))
            case "hide": h.visible = false; h.surface.cancelLinkHover()
            case "patch": try h.erase()
            case "cwd": h.cwd = nil; h.surface.refreshLinkHover()
            default: h.surface.clear(); h.surface.cancelLinkHover()
            }
            let phases = h.phases
            h.gate.resume(); settle(0.2)
            precondition(h.phases == phases, "Late miss sent old move after \(interaction)")
            precondition(h.surface.toolTip == nil, "Stale tooltip after \(interaction)")
            print("PASS: pending miss cancelled before \(interaction); no late PTY move")
        }
        do {
            let h = try Harness(root: root, name: "hit.swift")
            h.move(); waitUntil("click gate did not enter") { h.gate.hasEntered }
            h.surface.mouseDown(with: h.event(.leftMouseDown))
            h.surface.mouseUp(with: h.event(.leftMouseUp))
            precondition(h.opened == [hit] && h.sent.isEmpty, "Click waited for hover")
            h.gate.resume(); settle()
            try FileManager.default.removeItem(at: hit)
            h.surface.mouseDown(with: h.event(.leftMouseDown))
            h.surface.mouseUp(with: h.event(.leftMouseUp))
            precondition(h.opened == [hit], "Click trusted cached existence after file deletion")
            print("PASS: click resolves before hover completion and rechecks deleted files")
        }
        do {
            let h = try Harness(root: root, name: "appears.swift")
            let path = root.appendingPathComponent("appears.swift")
            h.gate.resume()
            h.move(); waitUntil("initial negative hover did not resolve") { h.phases == ["move"] }
            try Data("appeared".utf8).write(to: path)
            waitUntil("negative TTL did not refresh a stationary file hover") { h.surface.toolTip == path.path }
            try FileManager.default.removeItem(at: path)
            waitUntil("positive TTL did not clear a deleted stationary file hover") { h.surface.toolTip == nil }
            precondition(h.phases == ["move"], "TTL refresh replayed an old PTY move")
            print("PASS: stationary hover refreshes positive/negative filesystem results after TTL")
        }
    }
}
