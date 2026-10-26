import AppKit

#if !TAVERN_RENDER_TESTING
#error("SurfaceLinkTests requires -D TAVERN_RENDER_TESTING")
#endif

@main struct SurfaceLinkTests {
    static func main() throws {
        _ = NSApplication.shared
        let surface = SurfaceView(fonts: try TerminalFonts.load(size: 16))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = surface
        var hoverLocation: NSPoint?
        var hoverFlags: NSEvent.ModifierFlags = []
        #if TAVERN_RENDER_TESTING
        surface.linkHoverEnvironment = { (hoverLocation, hoverFlags, true) }
        #endif
        func waitUntil(_ condition: () -> Bool) {
            let deadline = Date(timeIntervalSinceNow: 2)
            while !condition(), Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005)) }
            precondition(condition(), "Hover completion timed out")
        }
        var sent: [[String: Any]] = [], opened: [URL] = [], menus = 0
        surface.send = { sent.append($0) }
        surface.openLink = { opened.append($0) }
        surface.contextMenuForPane = { _ in menus += 1; return nil }
        func apply(_ cells: [TerminalCell], links: [String] = [], patch: Bool = false) throws {
            let rect = ["x": 0, "y": 0, "width": cells.count, "height": 1]
            try surface.apply(metadata: ["boot_id": "links", "projection_revision": 1, "surface_revision": patch ? 2 : 1,
                                         "base_surface_revision": 1, "width": cells.count, "height": 1,
                                         "hyperlinks": links, "panes": [["pane_id": "p", "inner_rect": rect, "focused": true, "mouse_reporting": true]]],
                              segments: [CellSegment(x: 0, y: 0, cells: cells)], images: [:], patch: patch)
        }
        func click(_ x: Int, flags: NSEvent.ModifierFlags, right: Bool = false) {
            sent.removeAll(); opened.removeAll(); menus = 0
            let location = surface.convert(NSPoint(x: CGFloat(x) * 8 + 4, y: 10), to: nil)
            for type: NSEvent.EventType in right ? [.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: flags, timestamp: 0,
                                               windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
                switch type {
                case .leftMouseDown: surface.mouseDown(with: event)
                case .leftMouseUp: surface.mouseUp(with: event)
                case .rightMouseDown: surface.rightMouseDown(with: event)
                default: surface.rightMouseUp(with: event)
                }
            }
        }
        let target = URL(string: "https://example.com/osc8")!
        try apply([TerminalCell(symbol: "界", hyperlink: 0), TerminalCell(symbol: "", skip: true), TerminalCell(symbol: " ")], links: [target.absoluteString])
        click(0, flags: .command)
        precondition(opened == [target] && sent.isEmpty && menus == 0)
        click(1, flags: .control)
        precondition(opened == [target] && sent.isEmpty && menus == 0)
        click(0, flags: .control, right: true)
        precondition(opened == [target] && sent.isEmpty && menus == 0)
        print("PASS: OSC 8, Command/Control, широкие символы; нет событий PTY и меню")
        sent.removeAll()
        let hover = NSEvent.mouseEvent(with: .mouseMoved, location: surface.convert(NSPoint(x: 4, y: 10), to: nil),
                                       modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
                                       context: nil, eventNumber: 1, clickCount: 0, pressure: 0)!
        hoverLocation = hover.locationInWindow; hoverFlags = .command
        surface.mouseMoved(with: hover)
        waitUntil { surface.toolTip == target.absoluteString }
        precondition(surface.toolTip == target.absoluteString && NSCursor.current == NSCursor.pointingHand && sent.isEmpty)
        let unmodified = NSEvent.mouseEvent(with: .mouseMoved, location: hover.locationInWindow, modifierFlags: [],
                                            timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                            eventNumber: 2, clickCount: 0, pressure: 0)!
        hoverFlags = []
        surface.mouseMoved(with: unmodified)
        precondition(surface.toolTip == nil && NSCursor.current != NSCursor.pointingHand)
        print("PASS: наведение показывает адрес и курсор-руку; снятие модификатора возвращает обычную мышь")
        click(0, flags: [])
        precondition(opened.isEmpty && sent.map { string($0["phase"]) } == ["down", "up"])
        click(2, flags: .control)
        precondition(opened.isEmpty && menus == 1)
        click(0, flags: [], right: true)
        precondition(opened.isEmpty && menus == 1)
        print("PASS: обычная мышь и контекстное меню вне ссылки сохранены")
        let text = "См. https://example.com/plain."
        try apply(text.map { TerminalCell(symbol: String($0)) })
        click(12, flags: .command)
        precondition(opened == [URL(string: "https://example.com/plain")!] && sent.isEmpty)
        try apply(Array(repeating: TerminalCell(symbol: " "), count: text.count), patch: true)
        click(12, flags: .command)
        precondition(opened.isEmpty && sent.count == 2)
        print("PASS: обычный URL с кириллицей перед ним; патч убирает устаревшую ссылку")
        try apply([TerminalCell(symbol: "x", hyperlink: 0)], links: ["javascript:alert(1)"])
        click(0, flags: .command)
        precondition(opened.isEmpty)
        print("PASS: OSC 8 не запускает неподдерживаемые схемы")
    }
}
