import AppKit

@main struct DialogMenuTests {
    private final class Commands: NSObject, NSMenuItemValidation {
        var received: [String] = []
        @objc func receiveCommand(_ sender: NSMenuItem) { received.append(sender.representedObject as! String) }
        func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { menuItem.representedObject as? String != "disabled" }
    }

    private static func pump(_ duration: TimeInterval = 0.15) {
        let deadline = Date().addingTimeInterval(duration)
        repeat {
            while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.01)))
        } while Date() < deadline
    }

    private static func key(_ code: UInt16, window: NSWindow) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                    context: nil, characters: code == 36 ? "\r" : "", charactersIgnoringModifiers: "",
                                    isARepeat: false, keyCode: code)!
        NSApp.postEvent(event, atStart: false)
        pump()
    }

    private static func renderedButton(_ button: TavernButton) -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 40,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        button.layoutSubtreeIfNeeded()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.clear.setFill()
        button.bounds.fill(using: .copy)
        button.draw(button.bounds)
        NSGraphicsContext.restoreGraphicsState()
        return Data(bytes: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }

    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            runTests()
            exit(0)
        }
        NSApp.run()
    }

    private static func runTests() {
        NSApp.activate(ignoringOtherApps: true)
        let owner = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 700, height: 500),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        owner.makeKeyAndOrderFront(nil)
        pump()
        precondition(NSApp.isActive, "Проверка требует активного изолированного приложения")

        let danger = TavernDialog(useBundledAppearance: false)
        danger.messageText = "Закрыть вкладку?"
        danger.addButton(withTitle: L("core.dialog.cancel"))
        danger.addButton(withTitle: "Закрыть").hasDestructiveAction = true
        var responses: [NSApplication.ModalResponse] = []
        danger.beginSheetModal(for: owner) { responses.append($0) }
        pump()
        key(36, window: owner.attachedSheet!)
        pump(0.3)
        precondition(responses == [.alertFirstButtonReturn], "Return должен отменять опасное действие")
        danger.buttons[1].performClick(nil)
        pump()
        precondition(responses.count == 1, "Закрытый диалог не должен повторно вызывать обработчик")
        print("PASS: Return безопасен, обработчик завершения вызывается один раз")

        let input = TavernDialog(useBundledAppearance: false)
        input.messageText = "Переименование"
        let field = NSTextField(string: "Разработка")
        input.accessoryView = field
        input.addButton(withTitle: "Сохранить")
        input.addButton(withTitle: L("core.dialog.cancel"))
        var cancelled = false
        input.beginSheetModal(for: owner) { cancelled = $0 == .alertSecondButtonReturn }
        pump()
        key(53, window: owner.attachedSheet!)
        pump(0.3)
        precondition(cancelled, "Escape должен возвращать индекс отмены, даже если она вторая")
        print("PASS: Escape сохраняет контракт отмены формы")

        let commands = Commands()
        let menu = NSMenu(title: "Проверка")
        for value in ["first", "disabled", "last"] {
            let item = NSMenuItem(title: value, action: #selector(Commands.receiveCommand(_:)), keyEquivalent: "")
            item.target = commands
            item.representedObject = value
            menu.addItem(item)
            if value == "first" { menu.addItem(.separator()) }
        }
        owner.makeKeyAndOrderFront(nil)
        TavernContextMenu.popUp(menu, at: NSPoint(x: 40, y: 300), in: owner.contentView!)
        pump()
        key(125, window: owner)
        key(125, window: owner)
        key(36, window: owner)
        precondition(commands.received == ["last"], "Клавиатура должна пропускать disabled и разделители, сохраняя representedObject")
        print("PASS: validation и клавиатурный выбор выполняют исходную команду")

        TavernContextMenu.popUp(menu, at: NSPoint(x: 40, y: 300), in: owner.contentView!)
        pump()
        key(125, window: owner)
        key(53, window: owner)
        key(36, window: owner)
        precondition(commands.received == ["last"], "После Escape команда меню не должна выполняться")
        print("PASS: Escape снимает перехват команд меню")

        let languageBefore = TavernLocalization.shared.language
        defer { TavernLocalization.shared.setLanguage(languageBefore) }
        let localized = TavernDialog(useBundledAppearance: false)
        localized.messageText = L("core.dialog.name")
        let edited = NSTextField(string: "Agent-Ж")
        localized.accessoryView = edited
        localized.addButton(withTitle: "Save")
        localized.addButton(withTitle: L("core.dialog.cancel"))
        localized.localizationUpdater = { dialog in
            dialog.messageText = L("core.dialog.name")
            dialog.buttons[1].title = L("core.dialog.cancel")
        }
        var languageFormCancelled = false
        localized.beginSheetModal(for: owner) {
            languageFormCancelled = $0 == .alertSecondButtonReturn
        }
        pump()
        let sameSheet = owner.attachedSheet!
        sameSheet.makeFirstResponder(edited)
        let selection = NSRange(location: 2, length: 3)
        (edited.currentEditor() as? NSTextView)?.setSelectedRange(selection)
        TavernLocalization.shared.setLanguage(languageBefore == .english ? .russian : .english)
        pump()
        precondition(owner.attachedSheet === sameSheet, "Changing language must preserve the presented sheet")
        precondition(edited.window === sameSheet && edited.stringValue == "Agent-Ж",
                     "Changing language must preserve the user's input")
        precondition((edited.currentEditor() as? NSTextView)?.selectedRange() == selection,
                     "Changing language must preserve editing focus and selection")
        key(53, window: sameSheet)
        pump(0.3)
        precondition(languageFormCancelled, "Escape must keep its response index after a language change")
        print("PASS: language switching preserves the sheet, edited text, selection, and cancellation")

        for initialTitle in ["Before", ""] {
            let changed = TavernButton(title: initialTitle, target: nil, action: nil)
            changed.frame = NSRect(x: 0, y: 0, width: 240, height: 40)
            changed.prepare(style: .utility)
            let expected = TavernButton(title: "После / After", target: nil, action: nil)
            expected.frame = changed.frame
            expected.prepare(style: .utility)
            changed.title = expected.title
            precondition(renderedButton(changed) == renderedButton(expected),
                         "Changing a prepared button title must update its visible text")
            precondition(changed.intrinsicContentSize == expected.intrinsicContentSize,
                         "Changing a prepared button title must update its layout size")
        }
        print("PASS: changing a decorative button title updates its pixels and layout size")
        owner.orderOut(nil)
        print("Пройдено 6 сценариев диалогов, меню и кнопок")
    }
}
