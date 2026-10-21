import AppKit

@main struct TerminalInputTests {
    static func event(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    static func main() {
        _ = NSApplication.shared
        cyrillicIdentityBelongsToTheEvent()
        controlLetterUsesLatinShortcut()
        controlPunctuationIsNotTranslatedAgain()
        controlCharacterHasPhysicalFallback()
        capsLockDoesNotBecomeShift()
        textBindingsDoNotCaptureSelectionChords()
        print("Пройдено 6 проверок нормализации клавиатурного ввода")
    }

    static func cyrillicIdentityBelongsToTheEvent() {
        let stroke = TerminalInput.stroke(event(0, "ф"), committedText: "ф")!
        precondition(stroke.key == "ф", "Текущая раскладка не должна заменять кириллицу уже полученного события латиницей")
    }

    static func controlLetterUsesLatinShortcut() {
        let stroke = TerminalInput.stroke(event(0, "ф", .control))!
        precondition(stroke.key == "a", "Ctrl+A должен оставаться командой и в русской раскладке")
    }

    static func controlPunctuationIsNotTranslatedAgain() {
        let stroke = TerminalInput.stroke(event(44, "/", .control))!
        precondition(stroke.key == "/", "Повторная трансляция через текущую раскладку превращала Ctrl+/ в Ctrl+.")
    }

    static func controlCharacterHasPhysicalFallback() {
        let stroke = TerminalInput.stroke(event(49, "\u{00}", .control))!
        precondition(stroke.key == " ", "Нулевой символ NSEvent не должен терять Ctrl+Space")
    }

    static func capsLockDoesNotBecomeShift() {
        let stroke = TerminalInput.stroke(event(0, "A", .capsLock), committedText: "A")!
        precondition(stroke.key == "a" && stroke.modifiers == 0,
                     "Caps Lock не должен превращать печать A в сочетание Shift+A для терминального приложения")
    }

    static func textBindingsDoNotCaptureSelectionChords() {
        precondition(TerminalInput.textBinding(event(123, "\u{f702}", .command)) == "\u{01}")
        precondition(TerminalInput.textBinding(event(123, "\u{f702}", [.command, .shift])) == nil,
                     "Cmd+Shift+Left нельзя превращать в Ctrl+A: это теряет выделение в редакторе")
        precondition(TerminalInput.textBinding(event(124, "\u{f703}", [.option, .shift])) == nil,
                     "Option+Shift+Right не должен срабатывать как обычный переход по слову")
    }
}
