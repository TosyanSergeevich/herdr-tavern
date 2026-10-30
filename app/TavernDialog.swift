import AppKit

/// Нативная панель с безопасной загрузкой ресурсов и прежними кодами ответа по индексам кнопок.
final class TavernDialog: NSObject, NSWindowDelegate {
    enum Style { case informational, warning, critical }

    var messageText = ""
    var informativeText = ""
    var warningText = ""
    var alertStyle: Style = .informational
    var accessoryView: NSView?
    var localizationUpdater: ((TavernDialog) -> Void)?
    private(set) var buttons: [NSButton] = []

    private let useBundledAppearance: Bool
    private var panel: TavernDialogPanel?
    private var completion: ((NSApplication.ModalResponse) -> Void)?
    private var parentCloseObserver: NSObjectProtocol?
    private var languageObserver: NSObjectProtocol?
    private var isFinishing = false
    private var hasCompleted = false
    private var isRunningModal = false
    private var cancellationIndex = 0
    private var defaultIndex = 0
    private var usesDefaultCloseButton = false
    private static var presented: [ObjectIdentifier: TavernDialog] = [:]

    init(useBundledAppearance: Bool = true) {
        self.useBundledAppearance = useBundledAppearance
        super.init()
        languageObserver = NotificationCenter.default.addObserver(
            forName: .tavernLanguageDidChange, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshLocalization() }
    }

    deinit {
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
    }

    private func refreshLocalization() {
        guard let current = panel else {
            localizationUpdater?(self)
            return
        }
        let field = accessoryView as? NSTextField
        let editor = field?.currentEditor() as? NSTextView
        let selectedRange = editor?.selectedRange()
        let responder = current.firstResponder as? NSView
        current.makeFirstResponder(nil)
        if usesDefaultCloseButton { buttons.first?.title = L("core.dialog.close") }
        localizationUpdater?(self)
        for button in buttons { button.setAccessibilityLabel(button.title) }
        let frame = current.frame
        let replacement = preparePanel(on: current.screen, parent: current.sheetParent)
        let defaultButtonCell = replacement.defaultButtonCell
        let content = replacement.contentView
        replacement.contentView = nil
        current.contentView = content
        current.title = messageText
        current.setAccessibilityLabel(messageText)
        current.defaultButtonCell = defaultButtonCell
        current.onCancel = replacement.onCancel
        current.onConfirm = replacement.onConfirm
        let size = replacement.frame.size
        current.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height,
                                width: size.width, height: size.height), display: true)
        panel = current
        if let field, let selectedRange {
            current.makeFirstResponder(field)
            (field.currentEditor() as? NSTextView)?.setSelectedRange(selectedRange)
        } else if let responder, responder.window === current {
            current.makeFirstResponder(responder)
        }
    }

    @discardableResult
    func addButton(withTitle title: String) -> NSButton {
        let button = TavernDialogButton(title: title, target: self, action: #selector(choose(_:)))
        button.tag = buttons.count
        button.setAccessibilityLabel(title)
        button.setAccessibilityIdentifier("tavern.dialog.button.\(button.tag)")
        buttons.append(button)
        return button
    }

    func beginSheetModal(for parent: NSWindow,
                         completionHandler: ((NSApplication.ModalResponse) -> Void)? = nil) {
        guard panel == nil, !hasCompleted else { return }
        completion = completionHandler
        let sheet = preparePanel(on: parent.screen, parent: parent)
        Self.presented[ObjectIdentifier(self)] = self
        parentCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                                     object: parent, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.finish(self.response(for: self.cancellationIndex))
        }
        parent.beginSheet(sheet) { [weak self] response in self?.complete(response) }
        focusInitialControl(in: sheet)
    }

    func show(completionHandler: @escaping (NSApplication.ModalResponse) -> Void) {
        guard panel == nil, !hasCompleted else { return }
        completion = completionHandler
        let dialog = preparePanel(on: NSScreen.main, parent: nil)
        Self.presented[ObjectIdentifier(self)] = self
        dialog.center()
        dialog.makeKeyAndOrderFront(nil)
        focusInitialControl(in: dialog)
    }

    func dismiss(with response: NSApplication.ModalResponse) {
        finish(response)
    }

    @discardableResult
    func runModal() -> NSApplication.ModalResponse {
        guard panel == nil, !hasCompleted else { return response(for: cancellationIndex) }
        let dialog = preparePanel(on: NSScreen.main, parent: nil)
        Self.presented[ObjectIdentifier(self)] = self
        isRunningModal = true
        dialog.center()
        dialog.makeKeyAndOrderFront(nil)
        focusInitialControl(in: dialog)
        let result = NSApp.runModal(for: dialog)
        isRunningModal = false
        complete(result)
        return result
    }

    private func response(for index: Int) -> NSApplication.ModalResponse {
        NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index)
    }

    @objc private func choose(_ sender: NSButton) {
        finish(response(for: sender.tag))
    }

    private func finish(_ response: NSApplication.ModalResponse) {
        guard !isFinishing, !hasCompleted, let panel else { return }
        isFinishing = true
        panel.makeFirstResponder(nil)
        if let parent = panel.sheetParent {
            parent.endSheet(panel, returnCode: response)
        } else if isRunningModal {
            NSApp.stopModal(withCode: response)
        } else {
            complete(response)
        }
    }

    private func complete(_ response: NSApplication.ModalResponse) {
        guard !hasCompleted else { return }
        hasCompleted = true
        if let parentCloseObserver { NotificationCenter.default.removeObserver(parentCloseObserver) }
        parentCloseObserver = nil
        panel?.delegate = nil
        panel?.onCancel = nil
        panel?.onConfirm = nil
        panel?.orderOut(nil)
        panel = nil
        let callback = completion
        completion = nil
        Self.presented.removeValue(forKey: ObjectIdentifier(self))
        callback?(response)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish(response(for: cancellationIndex))
        return false
    }

    private func focusInitialControl(in panel: NSPanel) {
        if buttons.contains(where: { $0.hasDestructiveAction }) {
            panel.makeFirstResponder(buttons[cancellationIndex])
        } else if let field = accessoryView as? NSTextField, field.isEditable {
            panel.makeFirstResponder(field)
            field.selectText(nil)
        } else {
            panel.makeFirstResponder(buttons[defaultIndex])
        }
    }

    private func preparePanel(on screen: NSScreen?, parent: NSWindow?) -> TavernDialogPanel {
        if buttons.isEmpty {
            addButton(withTitle: L("core.dialog.close"))
            usesDefaultCloseButton = true
        }
        cancellationIndex = buttons.firstIndex(where: { $0.title == L("core.dialog.cancel") || $0.keyEquivalent == "\u{1b}" })
            ?? buttons.firstIndex(where: { !$0.hasDestructiveAction }) ?? 0
        defaultIndex = buttons.firstIndex(where: { $0.keyEquivalent == "\r" && !$0.hasDestructiveAction })
            ?? (buttons.contains(where: { $0.hasDestructiveAction }) ? cancellationIndex : 0)
        // Return никогда не подтверждает опасное действие, даже если кнопка в фокусе.
        if buttons[defaultIndex].hasDestructiveAction { defaultIndex = cancellationIndex }
        let safeDefault = buttons[defaultIndex].hasDestructiveAction ? nil : buttons[defaultIndex]
        let fontsAvailable = useBundledAppearance && (try? TavernAppearance.validateFonts()) != nil
        let titleFont = fontsAvailable
            ? NSFontManager.shared.convert(TavernAppearance.bodyFont, toSize: 25)
            : NSFont.systemFont(ofSize: 25, weight: .medium)
        let buttonFont = fontsAvailable
            ? NSFontManager.shared.convert(TavernAppearance.bodyFont, toSize: 14)
            : NSFont.systemFont(ofSize: 14, weight: .medium)
        let materials = useBundledAppearance ? (try? TavernMaterials.bundled.get()) : nil
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let width = min(490, max(240, visible.width - 32))
        // Sheet также должна помещаться под точкой прикрепления к родительскому окну.
        let availableHeight = parent.map { max(200, $0.frame.maxY - visible.minY - 60) } ?? (visible.height - 40)
        let maxHeight = max(200, min(visible.height - 40, availableHeight))
        let inset: CGFloat = width < 400 ? 25 : 35
        let contentWidth = width - inset * 2
        let body = TavernDialogFlippedView()
        var y: CGFloat = 31

        let ornament = label("◆", font: .systemFont(ofSize: 11), color: TavernAppearance.accent,
                             width: contentWidth, alignment: .center)
        ornament.frame.origin = NSPoint(x: 0, y: y)
        ornament.setAccessibilityElement(false)
        body.addSubview(ornament)
        y += ornament.frame.height + 17
        let heading = label(messageText, font: titleFont, color: dialogColor(0xf1d9aa),
                            width: contentWidth, alignment: .center)
        heading.setAccessibilityIdentifier("tavern.dialog.title")
        heading.frame.origin = NSPoint(x: 0, y: y)
        body.addSubview(heading)
        y += heading.frame.height + 14
        let warning = warningText.isEmpty && alertStyle != .informational ? informativeText : warningText
        let explanation = warningText.isEmpty && alertStyle != .informational ? "" : informativeText
        if !explanation.isEmpty {
            let text = label(explanation, font: .systemFont(ofSize: 13), color: dialogColor(0xbfb29e),
                             width: contentWidth, alignment: .center)
            text.frame.origin = NSPoint(x: 0, y: y)
            body.addSubview(text)
            y += text.frame.height + 22
        }
        if !warning.isEmpty {
            let text = label(warning, font: .systemFont(ofSize: 13), color: dialogColor(0xecd0b4),
                             width: contentWidth - 30, alignment: .left)
            let box = TavernDialogWarningView(frame: NSRect(x: 0, y: y, width: contentWidth,
                                                            height: text.frame.height + 28))
            text.frame.origin = NSPoint(x: 15, y: 14)
            box.addSubview(text)
            body.addSubview(box)
            y += box.frame.height + 22
        }
        if let accessory = accessoryView {
            if let field = accessory as? NSTextField, field.isEditable {
                let caption = label(field.accessibilityLabel() ?? L("core.dialog.name"), font: .systemFont(ofSize: 11),
                                    color: dialogColor(0xc9b58f), width: contentWidth, alignment: .left)
                caption.frame.origin = NSPoint(x: 0, y: y)
                body.addSubview(caption)
                y += caption.frame.height + 8
                let well = TavernDialogInputWell(frame: NSRect(x: 0, y: y, width: contentWidth, height: 43))
                field.frame = NSRect(x: 12, y: 11, width: contentWidth - 24, height: 23)
                field.autoresizingMask = [.width]
                field.font = .systemFont(ofSize: 14)
                field.textColor = TavernAppearance.text
                field.backgroundColor = .clear
                field.drawsBackground = false
                field.isBezeled = false
                field.isBordered = false
                field.focusRingType = .none
                well.field = field
                well.addSubview(field)
                body.addSubview(well)
                y += 43
            } else {
                let height = min(max(44, accessory.frame.height), max(80, maxHeight * 0.45))
                accessory.frame = NSRect(x: 0, y: y, width: contentWidth, height: height)
                if let scroll = accessory as? NSScrollView {
                    scroll.drawsBackground = false
                    scroll.borderType = .lineBorder
                    if let text = scroll.documentView as? NSTextView {
                        text.backgroundColor = dialogColor(0x14130f)
                        text.textColor = TavernAppearance.text
                        text.insertionPointColor = TavernAppearance.accent
                        text.textContainerInset = NSSize(width: 8, height: 8)
                        text.setFrameSize(NSSize(width: scroll.contentSize.width, height: text.frame.height))
                    }
                }
                body.addSubview(accessory)
                y += height
            }
        }
        body.frame = NSRect(x: 0, y: 0, width: contentWidth, height: y + 2)

        let visualButtons = buttons.filter { $0.tag == cancellationIndex } + buttons.filter { $0.tag != cancellationIndex }
        var buttonWidths: [CGFloat] = []
        for button in visualButtons {
            button.font = buttonFont
            button.keyEquivalent = button === safeDefault ? "\r" : ""
            if let styled = button as? TavernDialogButton {
                styled.isPrimary = button === safeDefault && button.tag != cancellationIndex
                styled.skins = materials?.buttonSkins
            }
            buttonWidths.append(min(contentWidth, max(104, ceil((button.title as NSString).size(withAttributes: [.font: buttonFont]).width) + 38)))
        }
        let singleRow = buttonWidths.reduce(0, +) + CGFloat(max(0, buttons.count - 1)) * 10 <= contentWidth
        let actionsHeight: CGFloat = singleRow ? 40 : CGFloat(buttons.count) * 50 - 10
        let footerHeight = actionsHeight + 53
        let bodyHeight = min(body.frame.height, max(60, maxHeight - footerHeight - 12))
        let size = NSSize(width: width, height: bodyHeight + footerHeight + 12)
        let panel = TavernDialogPanel(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
        TavernMotion.configureWindow(panel)
        panel.delegate = self
        panel.title = messageText
        panel.setAccessibilityLabel(messageText)
        panel.setAccessibilitySubrole(.dialog)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.worksWhenModal = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.autorecalculatesKeyViewLoop = true
        let background = TavernDialogBackground(frame: NSRect(origin: .zero, size: size), materials: materials,
                                                frameInset: parent == nil ? 0 : 8)
        panel.contentView = background
        let scroll = NSScrollView(frame: NSRect(x: inset, y: 12, width: contentWidth, height: bodyHeight))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = bodyHeight < body.frame.height
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = body
        background.addSubview(scroll)
        var x = inset + (singleRow ? contentWidth - buttonWidths.reduce(0, +) - CGFloat(max(0, buttons.count - 1)) * 10 : 0)
        var buttonY = size.height - 28 - actionsHeight
        for (index, button) in visualButtons.enumerated() {
            button.frame = NSRect(x: x, y: buttonY, width: singleRow ? buttonWidths[index] : contentWidth, height: 40)
            background.addSubview(button)
            if singleRow { x += buttonWidths[index] + 10 } else { buttonY += 50 }
        }
        panel.defaultButtonCell = safeDefault?.cell as? NSButtonCell
        panel.onCancel = { [weak self] in
            guard let self else { return }
            self.finish(self.response(for: self.cancellationIndex))
        }
        panel.onConfirm = { [weak safeDefault] in safeDefault?.performClick(nil) }
        self.panel = panel
        return panel
    }

    private func label(_ value: String, font: NSFont, color: NSColor, width: CGFloat,
                       alignment: NSTextAlignment) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: value)
        field.font = font
        field.textColor = color
        field.alignment = alignment
        field.isSelectable = true
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineSpacing = 4
        field.attributedStringValue = NSAttributedString(string: value, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph
        ])
        let height = field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height ?? 24
        field.frame = NSRect(x: 0, y: 0, width: width, height: ceil(height))
        return field
    }
}

private func dialogColor(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}

private final class TavernDialogPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onConfirm: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func performClose(_ sender: Any?) { onCancel?() }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            switch event.keyCode {
            case 53: onCancel?(); return
            case 36, 76:
                if let editor = firstResponder as? NSTextView, editor.hasMarkedText() {
                    super.sendEvent(event)
                } else {
                    onConfirm?()
                }
                return
            case 48:
                if event.modifierFlags.contains(.shift) { selectPreviousKeyView(nil) }
                else { selectNextKeyView(nil) }
                return
            default: break
            }
        }
        super.sendEvent(event)
    }
}

private class TavernDialogFlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class TavernDialogBackground: NSView {
    private let artwork: NSImage
    override var isFlipped: Bool { true }

    init(frame: NSRect, materials: TavernMaterials?, frameInset: CGFloat = 0) {
        // Компонуем фон один раз: перерисовка не пересоздаёт раму и не загружает материалы.
        // Скругление системного sheet не должно срезать угловые накладки.
        let frameSize = NSSize(width: frame.width - frameInset * 2, height: frame.height - frameInset * 2)
        let frameArtwork = materials?.frameImage(size: frameSize, edge: 6)
        artwork = NSImage(size: frame.size, flipped: true) { bounds in
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9)
            NSGraphicsContext.saveGraphicsState()
            outline.addClip()
            dialogColor(0x211a13).setFill()
            bounds.fill()
            if let materials {
                let tileHeight: CGFloat = 170
                let tileWidth = materials.boardWood.size.width / materials.boardWood.size.height * tileHeight
                var y: CGFloat = 0
                while y < bounds.height {
                    materials.boardWood.draw(in: NSRect(x: (bounds.width - tileWidth) / 2, y: y,
                                                       width: tileWidth, height: tileHeight),
                                             from: .zero, operation: .sourceOver, fraction: 0.25,
                                             respectFlipped: true, hints: TavernMaterials.frameHints)
                    y += tileHeight
                }
            }
            NSColor.black.withAlphaComponent(0.42).setFill()
            bounds.fill()
            NSGradient(starting: dialogColor(0x8d642c).withAlphaComponent(0.18),
                       ending: NSColor.clear)?.draw(in: bounds, angle: 90)
            NSGraphicsContext.restoreGraphicsState()
            if let frameArtwork {
                frameArtwork.draw(in: bounds.insetBy(dx: frameInset, dy: frameInset),
                    from: .zero, operation: .sourceOver, fraction: 0.8, respectFlipped: true,
                    hints: TavernMaterials.frameHints)
            }
            dialogColor(0x8d7046).withAlphaComponent(0.65).setStroke()
            outline.lineWidth = 1
            outline.stroke()
            return true
        }
        super.init(frame: frame)
        artwork.cacheMode = .always
    }

    required init?(coder: NSCoder) { return nil }
    override func draw(_ dirtyRect: NSRect) {
        artwork.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                     hints: TavernMaterials.frameHints)
    }
}

private final class TavernDialogWarningView: TavernDialogFlippedView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        dialogColor(0x4d281c).withAlphaComponent(0.35).setFill()
        path.fill()
        dialogColor(0x88523d).setStroke()
        path.stroke()
        dialogColor(0xc08353).setFill()
        NSRect(x: 0, y: 4, width: 3, height: max(0, bounds.height - 8)).fill()
    }
}

private final class TavernDialogInputWell: TavernDialogFlippedView {
    weak var field: NSTextField?
    private var focusObservers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusObservers.forEach { NotificationCenter.default.removeObserver($0) }
        focusObservers.removeAll()
        guard window != nil else { return }
        for name in [NSControl.textDidBeginEditingNotification, NSControl.textDidEndEditingNotification] {
            focusObservers.append(NotificationCenter.default.addObserver(forName: name,
                                                                         object: field, queue: .main) { [weak self] _ in
                self?.needsDisplay = true
            })
        }
    }

    deinit {
        focusObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
        dialogColor(0x10120f).setFill()
        path.fill()
        (field?.currentEditor() != nil ? TavernAppearance.accent : dialogColor(0x6d5838)).setStroke()
        path.lineWidth = field?.currentEditor() != nil ? 2 : 1
        path.stroke()
    }
}

final class TavernDialogButton: NSButton {
    var isPrimary = false {
        didSet {
            guard isPrimary != oldValue else { return }
            primaryArtwork = nil
            needsDisplay = true
        }
    }
    var skins: TavernButtonSkins? {
        didSet {
            primaryArtwork = nil
            needsDisplay = true
        }
    }
    private var primaryArtwork: NSImage?
    private var primaryArtworkSize = NSSize.zero
    private var hovered = false
    private var hoverArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryPushIn)
        focusRingType = .none
    }
    required init?(coder: NSCoder) { return nil }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }
    override func updateTrackingAreas() {
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let focused = window?.firstResponder === self
        let rect = bounds.insetBy(dx: 3, dy: 3)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        if isPrimary, !hasDestructiveAction, let skins {
            if primaryArtwork == nil || primaryArtworkSize != rect.size {
                primaryArtwork = skins.image(role: .primary, icon: false, size: rect.size)
                primaryArtworkSize = rect.size
            }
            primaryArtwork?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                                 respectFlipped: true, hints: TavernMaterials.frameHints)
        } else {
            let top = hasDestructiveAction ? dialogColor(0x783f2c) : dialogColor(isPrimary ? 0x645032 : 0x494031)
            let bottom = hasDestructiveAction ? dialogColor(0x48251e) : dialogColor(isPrimary ? 0x35291c : 0x28251e)
            NSGradient(starting: top, ending: bottom)?.draw(in: path, angle: 270)
        }
        if hovered || isHighlighted {
            NSColor.white.withAlphaComponent(isHighlighted ? 0.04 : 0.08).setFill()
            path.fill()
        }
        (hasDestructiveAction ? dialogColor(0xa26749) : dialogColor(0x967047)).setStroke()
        path.lineWidth = 1
        path.stroke()
        if focused {
            TavernAppearance.accent.setStroke()
            let focus = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 7, yRadius: 7)
            focus.lineWidth = 1.5
            focus.stroke()
        }
        let textFont = font ?? .systemFont(ofSize: 14)
        let color = hasDestructiveAction ? dialogColor(0xf5cfb6) : dialogColor(isPrimary ? 0xffe2ab : 0xdbcfb8)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let textHeight = ceil(textFont.ascender - textFont.descender + textFont.leading)
        (title as NSString).draw(in: NSRect(x: 12, y: (bounds.height - textHeight) / 2,
                                          width: bounds.width - 24, height: textHeight + 2),
                                withAttributes: [.font: textFont, .foregroundColor: color, .paragraphStyle: paragraph])
    }
}
