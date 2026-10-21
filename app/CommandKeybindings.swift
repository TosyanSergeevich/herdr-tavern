import AppKit

// Метки и непрозрачные ID уже проверены сервером. Клиент не читает и не исполняет
// command strings: все четыре типа команд выполняются через command.invoke.
final class CommandKeybindings {
    enum Result: Equatable {
        case passThrough
        case consumed
        case invoke(String)
    }
    private struct Chord: Equatable {
        let key: String
        let modifiers: Int

        init?(_ label: String) {
            var body = label
            var modifiers = 0
            while let separator = body.firstIndex(of: "+"), separator != body.startIndex {
                let token = String(body[..<separator])
                let bit: Int
                switch token {
                case "ctrl", "control": bit = 2
                case "alt", "option", "meta": bit = 4
                case "shift": bit = 1
                case "cmd", "command", "super": bit = 8
                default: return nil
                }
                modifiers |= bit
                body = String(body[body.index(after: separator)...])
            }
            let aliases = ["space": " ", "esc": "escape", "return": "enter", "plus": "+",
                           "minus": "-", "comma": ",", "period": ".", "slash": "/",
                           "backslash": "\\", "quote": "'", "semicolon": ";", "backtick": "`"]
            let key = aliases[body] ?? body
            guard !key.isEmpty else { return nil }
            self.key = key
            self.modifiers = modifiers
        }
        func matches(_ stroke: TerminalKeyStroke) -> Bool {
            let sameKey = stroke.key == key
            if sameKey && stroke.modifiers == modifiers { return true }
            let shifted = stroke.shiftedCodepoint.flatMap(UnicodeScalar.init).map(String.init)
            // В published label символ '+' уже включает Shift, физический ввод
            // может быть '=' + Shift с shifted alternate '+'.
            let punctuation = "!@#$%^&*()_+{}|:\"<>?~"
            return key.count == 1 && punctuation.contains(key) &&
                (sameKey || shifted == key) && stroke.modifiers & 1 != 0 &&
                stroke.modifiers & ~1 == modifiers & ~1
        }
    }
    private struct Binding: Equatable {
        let chord: Chord
        let prefixed: Bool
        let commandID: String
    }
    private var bindings: [Binding] = []
    private var prefixes: [Chord] = []
    private var context = ""
    private var prefixPending = false
    private var consumedKeys: Set<UInt16> = []

    func update(commands: [[String: Any]], prefixes labels: [String], context: String) {
        let prefixes = labels.compactMap(Chord.init)
        var bindings: [Binding] = []
        for command in commands {
            guard let id = command["command_id"] as? String, !id.isEmpty,
                  let action = command["action"] as? String,
                  ["Shell", "Pane", "Popup", "PluginAction"].contains(action),
                  let labels = command["binding_labels"] as? [String] else { continue }
            for label in labels {
                let prefixed = label.hasPrefix("prefix+")
                let body = prefixed ? String(label.dropFirst(7)) : label
                guard let chord = Chord(body) else { continue }
                // Не перехватывать обычную печать даже при несовместимом сервере.
                guard prefixed || chord.key.count != 1 || chord.modifiers & ~1 != 0 else { continue }
                bindings.append(Binding(chord: chord, prefixed: prefixed, commandID: id))
            }
        }
        if bindings != self.bindings || prefixes != self.prefixes || context != self.context {
            prefixPending = false
            self.bindings = bindings
            self.prefixes = prefixes
            self.context = context
        }
    }

    func resetInput() {
        prefixPending = false
    }

    func keyDown(_ event: NSEvent) -> Result {
        if consumedKeys.contains(event.keyCode) {
            if event.isARepeat { return .consumed }
            // После потери фокуса отпускание могло уйти другому окну.
            // Новое физическое нажатие завершает прежнее удержание.
            consumedKeys.remove(event.keyCode)
        }
        // Повтор клавиши, уже переданной PTY, не должен внезапно стать командой
        // после reload; удержание сочетания не запускает новые вкладки.
        guard !event.isARepeat, let stroke = TerminalInput.stroke(event) else { return .passThrough }
        let result: Result
        if prefixPending {
            prefixPending = false
            if prefixes.contains(where: { $0.matches(stroke) }) {
                // Двойной prefix передаёт одну буквальную клавишу в терминал.
                return .passThrough
            }
            let command = bindings.first { $0.prefixed && $0.chord.matches(stroke) }
            result = command.map { .invoke($0.commandID) } ?? .consumed
        } else if let command = bindings.first(where: { !$0.prefixed && $0.chord.matches(stroke) }) {
            result = .invoke(command.commandID)
        } else if bindings.contains(where: { $0.prefixed }) && prefixes.contains(where: { $0.matches(stroke) }) {
            prefixPending = true
            result = .consumed
        } else {
            return .passThrough
        }
        consumedKeys.insert(event.keyCode)
        return result
    }

    func keyUp(_ event: NSEvent) -> Bool {
        consumedKeys.remove(event.keyCode) != nil
    }
}
