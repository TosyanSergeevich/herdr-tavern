import AppKit

// NSMenu остаётся моделью команд; системный цикл отслеживания меню не запускается.
// Одна удерживаемая сессия владеет панелями, наблюдателями и мониторами событий.
enum TavernContextMenu {
    private static var session: TavernMenuSession?

    static func popUp(_ menu: NSMenu, with event: NSEvent, for view: NSView) {
        guard let window = view.window else { return }
        let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        present(menu, at: point, owner: window, openingEvent: event)
    }

    static func popUp(_ menu: NSMenu, at point: NSPoint, in view: NSView) {
        guard let window = view.window else { return }
        present(menu, at: window.convertPoint(toScreen: view.convert(point, to: nil)),
                owner: window, openingEvent: nil)
    }

    private static func present(_ menu: NSMenu, at point: NSPoint, owner: NSWindow, openingEvent: NSEvent?) {
        precondition(Thread.isMainThread)
        session?.close()
        let controller = TavernMenuSession(owner: owner, openingEvent: openingEvent)
        session = controller
        controller.onClose = { [weak controller] in
            if session === controller { session = nil }
        }
        controller.show(menu, at: point)
    }
}

private enum TavernMenuStyle {
    static let font = NSFont.systemFont(ofSize: 13)
    static let shortcutFont = NSFont.systemFont(ofSize: 12)
    static let background = NSColor(calibratedRed: 0.105, green: 0.087, blue: 0.074, alpha: 1)
    static let danger = NSColor(calibratedRed: 0.87, green: 0.54, blue: 0.42, alpha: 1)
    static let light = NSGradient(starting: NSColor.white.withAlphaComponent(0.025),
                                  ending: NSColor.black.withAlphaComponent(0.08))!
    static let rowHeight: CGFloat = 34
    static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    static func shortcut(_ item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        var text = ""
        let modifiers = item.keyEquivalentModifierMask
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        let symbols: [String: String] = ["\r": "↩", "\n": "↩", "\t": "⇥", " ": L("core.menu.space"),
                                         "\u{1b}": "⎋", "\u{7f}": "⌫", "\u{f728}": "⌦",
                                         "\u{f700}": "↑", "\u{f701}": "↓", "\u{f702}": "←", "\u{f703}": "→"]
        return text + (symbols[item.keyEquivalent] ?? item.keyEquivalent.uppercased())
    }

    static func destructive(_ item: NSMenuItem) -> Bool {
        let identifier = item.identifier?.rawValue ?? ""
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let closeMenu = L("core.menu.closeMenuPrefix").lowercased()
        if title == closeMenu || title.hasPrefix(closeMenu + " ") { return false }
        return identifier.hasSuffix(".close") || title.hasPrefix(L("core.menu.deletePrefix").lowercased())
            || title.hasPrefix(L("core.menu.closePrefix").lowercased())
    }
}

private final class TavernMenuPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        animationBehavior = .none
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        acceptsMouseMovedEvents = true
    }
}

private final class TavernMenuBackdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        TavernMenuStyle.background.setFill()
        outline.fill()
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        TavernMenuStyle.light.draw(in: bounds, angle: 270)
        NSGraphicsContext.restoreGraphicsState()
        TavernAppearance.border.withAlphaComponent(0.85).setStroke()
        outline.lineWidth = 1
        outline.stroke()
    }
}

private final class TavernMenuDocument: NSView {
    override var isFlipped: Bool { true }
}

// Каждая команда — нативный контрол с доступным действием, ролью пункта меню
// и состоянием отметки; подписи не запекаются в изображения.
private final class TavernMenuRow: NSButton {
    let item: NSMenuItem
    let shortcut: String
    private let shortcutWidth: CGFloat
    private lazy var selectionPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
    var isMenuSelected = false { didSet { if oldValue != isMenuSelected { needsDisplay = true } } }
    var invoke: (() -> Void)?

    init(item: NSMenuItem, width: CGFloat) {
        self.item = item
        let shortcut = TavernMenuStyle.shortcut(item)
        self.shortcut = shortcut
        shortcutWidth = (shortcut as NSString).size(withAttributes: [.font: TavernMenuStyle.shortcutFont]).width
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: TavernMenuStyle.rowHeight))
        title = item.title
        isBordered = false
        setButtonType(.momentaryChange)
        font = TavernMenuStyle.font
        isEnabled = item.isEnabled
        state = item.state
        toolTip = item.toolTip
        focusRingType = .none
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(item.title)
        setAccessibilityHelp(item.toolTip)
        if let identifier = item.identifier { setAccessibilityIdentifier(identifier.rawValue) }
        target = self
        action = #selector(performCommand(_:))
    }

    required init?(coder: NSCoder) { fatalError("TavernMenuRow requires a menu item") }
    override var acceptsFirstResponder: Bool { isEnabled }
    // Сессия обрабатывает мышь, включая выбор отпусканием после протягивания.
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    @objc private func performCommand(_ sender: Any?) { if isEnabled { invoke?() } }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        invoke?()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isMenuSelected && isEnabled {
            let path = selectionPath
            TavernAppearance.accent.withAlphaComponent(0.17).setFill()
            path.fill()
            TavernAppearance.accent.withAlphaComponent(0.3).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        let color: NSColor
        if !isEnabled { color = TavernAppearance.secondary.withAlphaComponent(0.43) }
        else if TavernMenuStyle.destructive(item) { color = TavernMenuStyle.danger }
        else { color = isMenuSelected ? TavernAppearance.accent : TavernAppearance.text }
        let paragraph = TavernMenuStyle.paragraph
        let attributes: [NSAttributedString.Key: Any] = [.font: TavernMenuStyle.font,
                                                         .foregroundColor: color, .paragraphStyle: paragraph]
        let textHeight = TavernMenuStyle.font.ascender - TavernMenuStyle.font.descender
        let y = (bounds.height - textHeight) / 2 - 1
        let indentation = CGFloat(max(0, item.indentationLevel)) * 12
        var leading: CGFloat = 30 + indentation
        if let image = item.image {
            image.draw(in: NSRect(x: leading, y: 9, width: 16, height: 16), from: .zero,
                       operation: .sourceOver, fraction: isEnabled ? 1 : 0.4)
            leading += 23
        }
        let trailing: CGFloat = item.submenu != nil ? 25 : 12
        let reserved = shortcut.isEmpty ? trailing : trailing + shortcutWidth + 22
        (item.title as NSString).draw(in: NSRect(x: leading, y: y, width: max(0, bounds.width - leading - reserved),
                                               height: textHeight + 3), withAttributes: attributes)
        if item.state != .off {
            let mark = item.state == .mixed ? "−" : "✓"
            (mark as NSString).draw(at: NSPoint(x: 10, y: y), withAttributes: attributes)
        }
        if !shortcut.isEmpty {
            (shortcut as NSString).draw(at: NSPoint(x: bounds.width - trailing - shortcutWidth, y: y + 1),
                                       withAttributes: [.font: TavernMenuStyle.shortcutFont,
                                                        .foregroundColor: isEnabled ? TavernAppearance.secondary : color])
        }
        if item.submenu != nil {
            let arrow = NSBezierPath()
            let x = bounds.maxX - 14, y = bounds.midY
            arrow.move(to: NSPoint(x: x - 2, y: y - 4))
            arrow.line(to: NSPoint(x: x + 2, y: y))
            arrow.line(to: NSPoint(x: x - 2, y: y + 4))
            color.setStroke()
            arrow.lineWidth = 1.3
            arrow.stroke()
        }
    }
}

private final class TavernMenuSeparator: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("TavernMenuSeparator requires a frame") }
    override func draw(_ dirtyRect: NSRect) {
        TavernAppearance.border.withAlphaComponent(0.35).setFill()
        NSRect(x: 10, y: floor(bounds.midY), width: max(0, bounds.width - 20), height: 1).fill()
    }
}

private final class TavernMenuLevel {
    let menu: NSMenu
    let panel: TavernMenuPanel
    let backdrop: TavernMenuBackdrop
    let scroll: NSScrollView
    let document: TavernMenuDocument
    var rows: [TavernMenuRow] = []
    var selected: TavernMenuRow?
    weak var parentRow: TavernMenuRow?
    var boundsObserver: NSObjectProtocol?
    private var languageObserver: NSObjectProtocol?

    init(menu: NSMenu, visibleFrame: NSRect) {
        self.menu = menu
        let items = menu.items.filter { !$0.isHidden }
        var width: CGFloat = 300
        var height: CGFloat = 0
        for item in items {
            height += item.isSeparatorItem ? 11 : TavernMenuStyle.rowHeight
            guard !item.isSeparatorItem else { continue }
            let titleWidth = (item.title as NSString).size(withAttributes: [.font: TavernMenuStyle.font]).width
            let shortcut = TavernMenuStyle.shortcut(item)
            let keyWidth = (shortcut as NSString).size(withAttributes: [.font: TavernMenuStyle.shortcutFont]).width
            width = max(width, titleWidth + keyWidth + (shortcut.isEmpty ? 0 : 22) + 68 +
                        CGFloat(max(0, item.indentationLevel)) * 12 + (item.image == nil ? 0 : 23))
        }
        width = min(ceil(width), max(1, visibleFrame.width - 8))
        let size = NSSize(width: width, height: min(height + 12, max(1, visibleFrame.height - 8)))
        panel = TavernMenuPanel(size: size)
        backdrop = TavernMenuBackdrop(frame: NSRect(origin: .zero, size: size))
        scroll = NSScrollView(frame: NSRect(origin: .zero, size: size).insetBy(dx: 6, dy: 6))
        document = TavernMenuDocument(frame: NSRect(x: 0, y: 0, width: width - 12, height: height))
        backdrop.setAccessibilityElement(true)
        backdrop.setAccessibilityRole(.menu)
        backdrop.setAccessibilityLabel(menu.title.isEmpty ? L("core.menu.contextMenu") : menu.title)
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = height > scroll.frame.height
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.scrollerKnobStyle = .light
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none
        scroll.autohidesScrollers = true
        scroll.lineScroll = TavernMenuStyle.rowHeight
        document.setAccessibilityElement(false)
        var y: CGFloat = 0
        for item in items {
            if item.isSeparatorItem {
                let separator = TavernMenuSeparator(frame: NSRect(x: 0, y: y, width: width - 12, height: 11))
                document.addSubview(separator)
                y += 11
            } else {
                let row = TavernMenuRow(item: item, width: width - 12)
                row.frame.origin.y = y
                rows.append(row)
                document.addSubview(row)
                row.setAccessibilityParent(backdrop)
                y += TavernMenuStyle.rowHeight
            }
        }
        scroll.documentView = document
        scroll.contentView.postsBoundsChangedNotifications = true
        backdrop.addSubview(scroll)
        backdrop.setAccessibilityChildren(rows)
        panel.contentView = backdrop
        languageObserver = NotificationCenter.default.addObserver(
            forName: .tavernLanguageDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.backdrop.setAccessibilityLabel(self.menu.title.isEmpty ? L("core.menu.contextMenu") : self.menu.title)
        }
    }

    deinit {
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
    }

    func row(at screenPoint: NSPoint) -> TavernMenuRow? {
        let local = panel.convertPoint(fromScreen: screenPoint)
        let viewportPoint = scroll.contentView.convert(local, from: nil)
        guard scroll.contentView.bounds.contains(viewportPoint) else { return nil }
        let point = document.convert(local, from: nil)
        return rows.first { $0.frame.contains(point) }
    }

    func screenRect(for row: TavernMenuRow) -> NSRect {
        panel.convertToScreen(row.convert(row.bounds, to: nil))
    }
}

private final class TavernMenuSession {
    weak var owner: NSWindow?
    var onClose: (() -> Void)?
    private var levels: [TavernMenuLevel] = []
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var hoverWork: DispatchWorkItem?
    private var closed = false
    private var openingButton: Int?
    private let openingPoint: NSPoint
    private var draggedFromOpening = false
    private var pressedRow: TavernMenuRow?
    private weak var trackingScroller: NSScroller?
    private var keyboardLevel: TavernMenuLevel?
    private var typePrefix = ""
    private var lastTypeTime: TimeInterval = 0

    init(owner: NSWindow, openingEvent: NSEvent?) {
        self.owner = owner
        openingPoint = NSEvent.mouseLocation
        if let event = openingEvent,
           [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
            openingButton = event.buttonNumber
        }
    }

    func show(_ menu: NSMenu, at point: NSPoint) {
        guard let owner, owner.isVisible, NSApp.isActive else { close(); return }
        installMonitors(owner: owner)
        let screen = screenFrame(at: point)
        prepare(menu)
        guard !menu.items.allSatisfy({ $0.isHidden }) else { close(); return }
        menu.delegate?.menuWillOpen?(menu)
        let level = TavernMenuLevel(menu: menu, visibleFrame: screen)
        levels.append(level)
        configure(level)
        let frame = NSRect(x: point.x, y: point.y - level.panel.frame.height,
                           width: level.panel.frame.width, height: level.panel.frame.height)
        level.panel.setFrame(clamp(frame, to: screen), display: false)
        owner.addChildWindow(level.panel, ordered: .above)
        level.panel.orderFront(nil)
        keyboardLevel = level
        NSAccessibility.post(element: level.backdrop, notification: .created)
        NSAccessibility.post(element: level.backdrop, notification: .focusedUIElementChanged)
    }

    private func prepare(_ menu: NSMenu) {
        menu.delegate?.menuNeedsUpdate?(menu)
        // NSMenu.update сохраняет autoenablesItems, цепочку респондеров
        // и правила NSMenuItemValidation/NSUserInterfaceValidations.
        menu.update()
    }

    private func configure(_ level: TavernMenuLevel) {
        for row in level.rows {
            row.invoke = { [weak self, weak level, weak row] in
                guard let self, let level, let row else { return }
                self.select(row, in: level, keyboard: true)
                self.activate(row, in: level)
            }
        }
        level.boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                               object: level.scroll.contentView, queue: .main) { [weak self, weak level] _ in
            guard let self, let level, !self.closed else { return }
            self.hoverWork?.cancel()
            self.closeDescendants(of: level)
        }
    }

    private func installMonitors(owner: NSWindow) {
        let mask: NSEvent.EventTypeMask = [.keyDown, .mouseMoved, .leftMouseDragged, .rightMouseDragged,
                                          .otherMouseDragged, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                          .leftMouseUp, .rightMouseUp, .otherMouseUp, .scrollWheel]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self, !self.closed else { return event }
            return self.handle(event)
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.close()
        }
        let center = NotificationCenter.default
        for name in [NSApplication.didResignActiveNotification, NSApplication.didChangeScreenParametersNotification] {
            observers.append(center.addObserver(forName: name, object: NSApp, queue: .main) { [weak self] _ in self?.close() })
        }
        for name in [NSWindow.willCloseNotification, NSWindow.willMiniaturizeNotification, NSWindow.didResignKeyNotification] {
            observers.append(center.addObserver(forName: name, object: owner, queue: .main) { [weak self] _ in self?.close() })
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        if event.type == .keyDown { handleKey(event); return nil }
        let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        let level = levels.reversed().first { $0.panel.frame.contains(point) }
        if trackingScroller != nil {
            switch event.type {
            case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: return event
            case .leftMouseUp, .rightMouseUp, .otherMouseUp:
                trackingScroller = nil
                return event
            default: trackingScroller = nil
            }
        }
        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            if hypot(point.x - openingPoint.x, point.y - openingPoint.y) > 4 { draggedFromOpening = true }
            pointerMoved(to: point, in: level)
            return level == nil ? event : nil
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            openingButton = nil
            guard let level else { close(); return event }
            let local = level.scroll.convert(level.panel.convertPoint(fromScreen: point), from: nil)
            if let scroller = level.scroll.verticalScroller, !scroller.isHidden,
               scroller.alphaValue > 0, scroller.frame.contains(local) {
                pressedRow = nil
                trackingScroller = scroller
                select(nil, in: level, keyboard: false)
                return event
            }
            pressedRow = level.row(at: point)
            pointerMoved(to: point, in: level)
            return nil
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            if openingButton == event.buttonNumber {
                openingButton = nil
                guard draggedFromOpening else { return level == nil ? event : nil }
                if let level, let row = level.row(at: point) { activate(row, in: level) }
                return nil
            }
            guard let level else { pressedRow = nil; return event }
            if let row = level.row(at: point), row === pressedRow { activate(row, in: level) }
            pressedRow = nil
            return nil
        case .scrollWheel:
            guard let level else { close(); return event }
            hoverWork?.cancel()
            closeDescendants(of: level)
            return event
        default: return event
        }
    }

    private func pointerMoved(to point: NSPoint, in level: TavernMenuLevel?) {
        guard let level else { hoverWork?.cancel(); return }
        keyboardLevel = level
        guard let row = level.row(at: point), row.isEnabled else {
            select(nil, in: level, keyboard: false)
            return
        }
        if level.selected === row { return }
        select(row, in: level, keyboard: false)
        guard row.item.submenu != nil else { return }
        let work = DispatchWorkItem { [weak self, weak level, weak row] in
            guard let self, let level, let row, !self.closed, level.selected === row else { return }
            self.openSubmenu(row, in: level, keyboard: false)
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func select(_ row: TavernMenuRow?, in level: TavernMenuLevel, keyboard: Bool) {
        hoverWork?.cancel()
        hoverWork = nil
        if level.selected !== row {
            closeDescendants(of: level)
            level.selected?.isMenuSelected = false
            level.selected = row
            row?.isMenuSelected = true
            level.backdrop.setAccessibilitySelectedChildren(row.map { [$0] } ?? [])
        }
        if keyboard, let row {
            for current in levels {
                for candidate in current.rows { candidate.setAccessibilityFocused(candidate === row) }
            }
            keyboardLevel = level
            row.scrollToVisible(row.bounds)
            NSAccessibility.post(element: row, notification: .focusedUIElementChanged)
        }
    }

    private func openSubmenu(_ row: TavernMenuRow, in level: TavernMenuLevel, keyboard: Bool) {
        guard !closed, row.isEnabled, let submenu = row.item.submenu else { return }
        if let existing = levels.first(where: { $0.parentRow === row }) {
            if keyboard { moveSelection(in: existing, direction: 1, edge: true) }
            return
        }
        guard !levels.contains(where: { $0.menu === submenu }) else { return }
        closeDescendants(of: level)
        prepare(submenu)
        guard !submenu.items.allSatisfy({ $0.isHidden }) else { return }
        submenu.delegate?.menuWillOpen?(submenu)
        let rowFrame = level.screenRect(for: row)
        let screen = screenFrame(at: NSPoint(x: rowFrame.midX, y: rowFrame.midY))
        let child = TavernMenuLevel(menu: submenu, visibleFrame: screen)
        child.parentRow = row
        configure(child)
        var x = level.panel.frame.maxX - 1
        if x + child.panel.frame.width > screen.maxX - 4 { x = level.panel.frame.minX - child.panel.frame.width + 1 }
        let frame = NSRect(x: x, y: rowFrame.maxY + 6 - child.panel.frame.height,
                           width: child.panel.frame.width, height: child.panel.frame.height)
        child.panel.setFrame(clamp(frame, to: screen), display: false)
        levels.append(child)
        level.panel.addChildWindow(child.panel, ordered: .above)
        child.panel.orderFront(nil)
        row.setAccessibilityChildren([child.backdrop])
        NSAccessibility.post(element: child.backdrop, notification: .created)
        if keyboard { moveSelection(in: child, direction: 1, edge: true) }
    }

    private func activate(_ row: TavernMenuRow, in level: TavernMenuLevel) {
        guard !closed else { return }
        level.menu.update()
        guard row.item.menu === level.menu, !row.item.isHidden, row.item.isEnabled else {
            row.isEnabled = row.item.isEnabled
            row.needsDisplay = true
            return
        }
        if row.item.submenu != nil { openSubmenu(row, in: level, keyboard: true); return }
        guard let action = row.item.action else { return }
        let item = row.item
        // Передаём исходный пункт с representedObject и сохраняем респондер
        // владельца для поиска обработчика при отсутствии явного target.
        close()
        NSApp.sendAction(action, to: item.target, from: item)
    }

    private func moveSelection(in level: TavernMenuLevel, direction: Int, edge: Bool = false) {
        let rows = level.rows.filter { $0.isEnabled && !$0.item.isHidden }
        guard !rows.isEmpty else { return }
        let next: TavernMenuRow
        if edge || level.selected == nil { next = direction > 0 ? rows[0] : rows[rows.count - 1] }
        else if let index = rows.firstIndex(where: { $0 === level.selected }) {
            next = rows[(index + direction + rows.count) % rows.count]
        } else { next = rows[0] }
        select(next, in: level, keyboard: true)
    }

    private func handleKey(_ event: NSEvent) {
        guard let level = keyboardLevel ?? levels.last else { return }
        switch event.keyCode {
        case 53: close()
        case 125: moveSelection(in: level, direction: 1)
        case 126: moveSelection(in: level, direction: -1)
        case 115: moveSelection(in: level, direction: 1, edge: true)
        case 119: moveSelection(in: level, direction: -1, edge: true)
        case 124:
            if let row = level.selected { openSubmenu(row, in: level, keyboard: true) }
        case 123:
            if let parentRow = level.parentRow, let index = levels.firstIndex(where: { $0 === level }), index > 0 {
                let parent = levels[index - 1]
                closeDescendants(of: parent)
                select(parentRow, in: parent, keyboard: true)
            }
        case 36, 76, 49:
            if let row = level.selected { activate(row, in: level) }
        case 48: close()
        case 116, 121:
            let count = max(1, Int(level.scroll.contentSize.height / TavernMenuStyle.rowHeight) - 1)
            for _ in 0..<count { moveSelection(in: level, direction: event.keyCode == 121 ? 1 : -1) }
        default:
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if !flags.intersection([.command, .control, .option]).isEmpty {
                for candidate in levels.reversed() {
                    if let row = candidate.rows.first(where: {
                        $0.isEnabled && !$0.item.keyEquivalent.isEmpty &&
                        $0.item.keyEquivalent.lowercased() == key &&
                        $0.item.keyEquivalentModifierMask.intersection([.command, .control, .option, .shift]) == flags
                    }) { activate(row, in: candidate); return }
                }
                return
            }
            guard let text = event.characters, text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return }
            let now = event.timestamp
            typePrefix = now - lastTypeTime > 0.8 ? text : typePrefix + text
            lastTypeTime = now
            if let row = level.rows.first(where: {
                $0.isEnabled && $0.item.title.range(of: typePrefix,
                    options: [.anchored, .caseInsensitive, .diacriticInsensitive], locale: .current) != nil
            }) {
                select(row, in: level, keyboard: true)
            }
        }
    }

    private func closeDescendants(of level: TavernMenuLevel) {
        guard let index = levels.firstIndex(where: { $0 === level }), index + 1 < levels.count else { return }
        let removed = Array(levels[(index + 1)...])
        levels.removeSubrange((index + 1)...)
        if removed.contains(where: { $0 === keyboardLevel }) { keyboardLevel = level }
        for child in removed.reversed() { dismiss(child) }
    }

    private func dismiss(_ level: TavernMenuLevel) {
        if let observer = level.boundsObserver { NotificationCenter.default.removeObserver(observer) }
        level.boundsObserver = nil
        level.parentRow?.setAccessibilityChildren(nil)
        level.panel.parent?.removeChildWindow(level.panel)
        level.panel.orderOut(nil)
        level.panel.close()
        NSAccessibility.post(element: level.backdrop, notification: .uiElementDestroyed)
        level.menu.delegate?.menuDidClose?(level.menu)
    }

    func close() {
        guard !closed else { return }
        closed = true
        hoverWork?.cancel()
        hoverWork = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        let dismissed = levels.reversed()
        levels.removeAll()
        keyboardLevel = nil
        pressedRow = nil
        for level in dismissed { dismiss(level) }
        if let responder = owner?.firstResponder as? NSView {
            NSAccessibility.post(element: responder, notification: .focusedUIElementChanged)
        }
        let completion = onClose
        onClose = nil
        completion?()
    }

    private func screenFrame(at point: NSPoint) -> NSRect {
        let screens = NSScreen.screens
        return (screens.first { $0.frame.contains(point) } ?? owner?.screen ?? screens.first)?.visibleFrame
            ?? NSRect(x: point.x, y: point.y - 600, width: 800, height: 600)
    }

    private func clamp(_ frame: NSRect, to visible: NSRect) -> NSRect {
        let inset = visible.insetBy(dx: 4, dy: 4)
        var result = frame
        result.origin.x = max(inset.minX, min(frame.minX, inset.maxX - frame.width))
        result.origin.y = max(inset.minY, min(frame.minY, inset.maxY - frame.height))
        return result
    }
}
