import AppKit

@main
struct CommandKeybindingsTests {
    static func event(_ code: UInt16 = 15, _ flags: NSEvent.ModifierFlags = [.control, .option],
                      text: String = "r", repeatKey: Bool = false, up: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: up ? .keyUp : .keyDown, location: .zero, modifierFlags: flags,
                        timestamp: 0, windowNumber: 0, context: nil, characters: text,
                        charactersIgnoringModifiers: text, isARepeat: repeatKey, keyCode: code)!
    }
    static func command(_ id: String = "review", _ labels: [String] = ["ctrl+alt+r"],
                        action: String = "PluginAction") -> [String: Any] {
        ["command_id": id, "action": action, "binding_labels": labels]
    }
    static func configure(_ model: CommandKeybindings, _ commands: [[String: Any]],
                          prefixes: [String] = ["ctrl+b"], context: String = "boot:pane") {
        model.update(commands: commands, prefixes: prefixes, context: context)
    }
    static func main() {
        directCommandAndRelease()
        typingAndUnboundModifiersPassThrough()
        alternateBindingsAndCommandModifier()
        prefixSequenceSurvivesSnapshot()
        prefixCancellationAndLiteralPrefix()
        reloadReplacesCommandAndCancelsSequence()
        focusResetCancelsSequence()
        shiftedPunctuation()
        russianControlShortcut()
        futureActionsAndUnsafeTypingAreNotIntercepted()
        print("CommandKeybindingsTests: 10 сценариев пройдены")
    }
    static func directCommandAndRelease() {
        let model = CommandKeybindings()
        configure(model, [command()])
        precondition(model.keyDown(event()) == .invoke("review"))
        precondition(model.keyDown(event(repeatKey: true)) == .consumed)
        precondition(model.keyUp(event(up: true)))
        precondition(model.keyDown(event()) == .invoke("review"))
    }
    static func typingAndUnboundModifiersPassThrough() {
        let model = CommandKeybindings()
        configure(model, [command()])
        precondition(model.keyDown(event(15, [])) == .passThrough)
        precondition(model.keyDown(event(15, [.control])) == .passThrough)
        precondition(model.keyDown(event(15, [.control, .option, .shift], text: "R")) == .passThrough)
        precondition(model.keyDown(event(11, [.control], text: "b")) == .passThrough)
        precondition(!model.keyUp(event(up: true)))
        precondition(model.keyDown(event(repeatKey: true)) == .passThrough)
    }
    static func alternateBindingsAndCommandModifier() {
        let model = CommandKeybindings()
        configure(model, [command("shell", ["alt+f5", "cmd+shift+r"], action: "Shell")])
        precondition(model.keyDown(event(96, [.option], text: "")) == .invoke("shell"))
        precondition(model.keyUp(event(96, [], up: true)))
        precondition(model.keyDown(event(15, [.command, .shift], text: "R")) == .invoke("shell"))
    }
    static func prefixSequenceSurvivesSnapshot() {
        let model = CommandKeybindings(), commands = [command("popup", ["prefix+r"], action: "Popup")]
        configure(model, commands, prefixes: ["ctrl+b", "ctrl+space"])
        precondition(model.keyDown(event(49, [.control], text: " ")) == .consumed)
        precondition(model.keyUp(event(49, [], text: " ", up: true)))
        configure(model, commands, prefixes: ["ctrl+b", "ctrl+space"])
        precondition(model.keyDown(event(15, [])) == .invoke("popup"))
        precondition(model.keyUp(event(up: true)))
        precondition(model.keyDown(event(15, [])) == .passThrough)
    }
    static func prefixCancellationAndLiteralPrefix() {
        let model = CommandKeybindings()
        configure(model, [command("pane", ["prefix+r"], action: "Pane")])
        let prefix = event(11, [.control], text: "b")
        precondition(model.keyDown(prefix) == .consumed)
        precondition(model.keyUp(prefix))
        precondition(model.keyDown(prefix) == .passThrough)
        precondition(!model.keyUp(prefix))
        precondition(model.keyDown(prefix) == .consumed)
        precondition(model.keyUp(prefix))
        precondition(model.keyDown(event(53, [], text: "\u{1b}")) == .consumed)
        precondition(model.keyDown(event(15, [])) == .passThrough)
    }
    static func reloadReplacesCommandAndCancelsSequence() {
        let model = CommandKeybindings()
        configure(model, [command(), command("prefix", ["prefix+r"])])
        precondition(model.keyDown(event(11, [.control], text: "b")) == .consumed)
        configure(model, [command("new"), command("prefix", ["prefix+r"])])
        precondition(model.keyDown(event(15, [])) == .passThrough)
        precondition(model.keyDown(event()) == .invoke("new"))
        configure(model, [])
        precondition(model.keyDown(event(repeatKey: true)) == .consumed)
        precondition(model.keyUp(event(up: true)))
        precondition(model.keyDown(event()) == .passThrough)
    }
    static func focusResetCancelsSequence() {
        let model = CommandKeybindings()
        configure(model, [command("prefix", ["prefix+r"])])
        precondition(model.keyDown(event(11, [.control], text: "b")) == .consumed)
        configure(model, [command("prefix", ["prefix+r"])], context: "boot:other-pane")
        precondition(model.keyDown(event(15, [])) == .passThrough)
        precondition(model.keyDown(event(11, [.control], text: "b")) == .consumed)
        model.resetInput()
        precondition(model.keyDown(event(15, [])) == .passThrough)
    }
    static func shiftedPunctuation() {
        let model = CommandKeybindings()
        configure(model, [command("plus", ["ctrl++"]), command("question", ["prefix+?"])])
        precondition(model.keyDown(event(24, [.control, .shift], text: "+")) == .invoke("plus"))
        precondition(model.keyUp(event(24, [], up: true)))
        precondition(model.keyDown(event(11, [.control], text: "b")) == .consumed)
        precondition(model.keyUp(event(11, [], up: true)))
        precondition(model.keyDown(event(44, [.shift], text: "?")) == .invoke("question"))
    }
    static func russianControlShortcut() {
        let model = CommandKeybindings()
        configure(model, [command()])
        precondition(model.keyDown(event(15, [.control, .option], text: "к")) == .invoke("review"))
    }
    static func futureActionsAndUnsafeTypingAreNotIntercepted() {
        let model = CommandKeybindings()
        configure(model, [command("future", ["ctrl+alt+r"], action: "FutureAction"), command("typing", ["r"])])
        precondition(model.keyDown(event()) == .passThrough)
        precondition(model.keyDown(event(15, [])) == .passThrough)
    }
}
