import AppKit
import Carbon.HIToolbox

func terminalModifiers(_ flags: NSEvent.ModifierFlags) -> Int {
    (flags.contains(.shift) ? 1 : 0) | (flags.contains(.control) ? 2 : 0) |
    (flags.contains(.option) ? 4 : 0) | (flags.contains(.command) ? 8 : 0)
}

struct TerminalKeyStroke {
    var key: String
    var modifiers: Int
    var shiftedCodepoint: UInt32?
    var generatedText: String?
    var physicalKeyID: UInt32?

    func command(pane: String, kind: Int) -> [String: Any] {
        var result: [String: Any] = ["type": "key", "pane_id": pane, "key": key,
                                    "modifiers": modifiers, "kind": kind, "tracks_release": true]
        if let physicalKeyID { result["physical_key_id"] = physicalKeyID }
        if let shiftedCodepoint { result["shifted_codepoint"] = shiftedCodepoint }
        if kind != 2, let generatedText { result["generated_text"] = generatedText }
        return result
    }
}

enum TerminalInput {
    private static let specialKeys: [UInt16: String] = [
        36: "enter", 76: "enter", 123: "left", 124: "right", 125: "down", 126: "up",
        51: "backspace", 48: "tab", 53: "escape", 115: "home", 119: "end", 117: "delete",
        114: "insert", 116: "pageup", 121: "pagedown", 122: "f1", 120: "f2", 99: "f3",
        118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10",
        103: "f11", 111: "f12", 105: "f13", 107: "f14", 113: "f15", 106: "f16",
        64: "f17", 79: "f18", 80: "f19", 90: "f20"
    ]
    // Control/Command сохраняют привычные латинские сочетания и в русской раскладке.
    private static let shortcutCharacters: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
        11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t", 31: "o", 32: "u",
        34: "i", 35: "p", 37: "l", 38: "j", 40: "k", 45: "n", 46: "m", 49: " ",
        27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'", 43: ",",
        47: ".", 44: "/", 50: "`", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5",
        22: "6", 26: "7", 28: "8", 25: "9", 29: "0"
    ]
    private static let shiftedPunctuation = [
        "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&",
        "8": "*", "9": "(", "0": ")", "-": "_", "=": "+", "[": "{", "]": "}",
        "\\": "|", ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?", "`": "~"
    ]

    static func isSpecial(_ event: NSEvent) -> Bool { specialKeys[event.keyCode] != nil }

    private static var cachedOptionAsAlt: Bool?
    private static let layoutObserver = DistributedNotificationCenter.default().addObserver(
        forName: Notification.Name(rawValue: kTISNotifySelectedKeyboardInputSourceChanged as String),
        object: nil, queue: .main
    ) { _ in cachedOptionAsAlt = nil }

    static var optionAsAlt: Bool {
        _ = layoutObserver
        if let cachedOptionAsAlt { return cachedOptionAsAlt }
        let source = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        let property = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        let identifier = property.map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String } ?? ""
        // Автоматический профиль Ghostty: Option — Alt в U.S./ABC,
        // в остальных раскладках печатный Option остаётся у текстового ввода macOS.
        let enabled = identifier == "com.apple.keylayout.US" || identifier == "com.apple.keylayout.ABC" ||
            identifier == "com.apple.keylayout.USInternational-PC"
        cachedOptionAsAlt = enabled
        return enabled
    }

    static func requiresSemanticInput(_ event: NSEvent) -> Bool {
        isSpecial(event) || !event.modifierFlags.intersection([.control, .command]).isEmpty ||
            (event.modifierFlags.contains(.option) && optionAsAlt)
    }

    // Это explicit text/esc bindings Ghostty, поэтому они отправляют те же
    // байты даже в приложении с Kitty, а не переинтерпретируются как новые keys.
    static func textBinding(_ event: NSEvent) -> String? {
        switch (event.keyCode, terminalModifiers(event.modifierFlags)) {
        case (123, 8): return "\u{01}"
        case (124, 8): return "\u{05}"
        case (51, 8): return "\u{15}"
        case (123, 4): return "\u{1b}b"
        case (124, 4): return "\u{1b}f"
        default: return nil
        }
    }

    static func stroke(_ event: NSEvent, committedText: String? = nil) -> TerminalKeyStroke? {
        let flags = event.modifierFlags
        var key = specialKeys[event.keyCode]
        var shifted: UInt32?
        if key == nil {
            let characters = event.charactersIgnoringModifiers ?? ""
            let shortcut = !flags.intersection([.control, .command]).isEmpty
            // Сначала используем текст самого события: раскладка могла
            // измениться между постановкой NSEvent в очередь и его обработкой.
            let unshifted: String
            if characters.unicodeScalars.count == 1, characters.unicodeScalars.first!.properties.isAlphabetic {
                unshifted = characters.lowercased()
            } else if flags.contains(.shift) {
                unshifted = event.characters(byApplyingModifiers: []) ?? characters
            } else { unshifted = characters }
            if shortcut, !(unshifted.unicodeScalars.count == 1 && unshifted.unicodeScalars.first!.isASCII &&
                            unshifted.unicodeScalars.first!.value >= 32),
               let latin = shortcutCharacters[event.keyCode] {
                key = latin
            } else {
                guard unshifted.unicodeScalars.count == 1, let scalar = unshifted.unicodeScalars.first,
                      scalar.value >= 32, scalar.value < 0xf700 || scalar.value > 0xf8ff else { return nil }
                let lower = unshifted.lowercased()
                key = lower.unicodeScalars.count == 1 ? lower : unshifted
            }
            if flags.contains(.shift), let key, key.unicodeScalars.count == 1 {
                // Для Ctrl/Command раскладка не должна заменять shifted alternate кириллицей.
                let upper = shortcut && !characters.unicodeScalars.allSatisfy(\.isASCII) ? shiftedShortcut(key) : characters
                if upper != key, upper.unicodeScalars.count == 1 { shifted = upper.unicodeScalars.first?.value }
            }
        }
        guard let key else { return nil }
        return TerminalKeyStroke(key: key, modifiers: terminalModifiers(flags), shiftedCodepoint: shifted,
                                 generatedText: committedText, physicalKeyID: UInt32(event.keyCode) + 1)
    }

    private static func shiftedShortcut(_ key: String) -> String {
        return shiftedPunctuation[key] ?? key.uppercased()
    }
}
