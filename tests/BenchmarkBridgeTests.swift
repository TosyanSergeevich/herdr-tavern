import AppKit
import Darwin

@main struct BenchmarkBridgeTests {
    static func wait(_ description: String, _ predicate: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: 3)
        while !predicate(), Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005)) }
        precondition(predicate(), description)
    }
    static func presentationWithoutPaint() {
        typealias Frame = TavernBenchmarkPresentation.FrameID
        let first = Frame(boot: "boot", projection: 1, surface: 1)
        var state = TavernBenchmarkPresentation()
        state.applied(first, needsPaint: false)
        let checkpoint = state.checkpoint
        precondition(state.completion(after: checkpoint, allowNoPaint: true, condition: true) == nil,
                     "An earlier apply must not complete a new command")
        let scrolled = Frame(boot: "boot", projection: 1, surface: 2)
        state.applied(scrolled, needsPaint: false)
        precondition(state.completion(after: checkpoint, allowNoPaint: true, condition: false) == nil,
                     "No-paint scroll still requires its server acknowledgement")
        precondition(state.completion(after: checkpoint, allowNoPaint: true, condition: true) == .noTerminalPaint)
        precondition(state.completion(after: checkpoint, allowNoPaint: false, condition: true) == nil,
                     "Other actions must retain the draw boundary")

        let next = state.checkpoint
        let pending = Frame(boot: "boot", projection: 1, surface: 3)
        state.applied(pending, needsPaint: true)
        state.applied(Frame(boot: "boot", projection: 1, surface: 4), needsPaint: true)
        precondition(state.completion(after: next, allowNoPaint: true, condition: true) == nil,
                     "An unchanged frame must not bypass an outstanding paint")
        state.drew(Frame(boot: "boot", projection: 1, surface: 4), at: 50, tab: "tab", pane: "pane")
        precondition(state.completion(after: next, allowNoPaint: true, condition: true) == .painted(50))

        let synchronous = state.checkpoint
        let drawnFirst = Frame(boot: "boot", projection: 1, surface: 5)
        state.drew(drawnFirst, at: 80, tab: "tab", pane: "pane")
        state.applied(drawnFirst, needsPaint: false)
        precondition(state.completion(after: synchronous, allowNoPaint: true, condition: true) == .painted(80),
                     "A synchronous draw before apply publication is still a draw")
        print("PASS: acknowledged no-paint completion, pending paint and draw/apply ordering")
    }
    static func main() throws {
        presentationWithoutPaint()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        chmod(root.path, 0o755)
        do {
            _ = try TavernBenchmarkBridge(directory: root) { _, reply in reply(.success([:])) }
            preconditionFailure("Publicly accessible control directory was accepted")
        } catch TavernBenchmarkBridge.Failure.unsafeDirectory { }
        chmod(root.path, 0o700)
        var held: TavernBenchmarkBridge.Reply?
        var received: [String] = []
        let bridge = try TavernBenchmarkBridge(directory: root) { command, reply in
            precondition(Thread.isMainThread)
            received.append(command["id"] as! String)
            held = reply
        }
        func command(_ id: String) throws {
            try JSONSerialization.data(withJSONObject: ["id": id, "op": "inspect"])
                .write(to: root.appendingPathComponent("command.json"), options: .atomic)
        }
        func response() -> [String: Any]? {
            guard let data = try? Data(contentsOf: root.appendingPathComponent("response.json")) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        try command("one")
        wait("first command not admitted") { received == ["one"] }
        try command("two")
        held?(.failure(.unavailable))
        wait("second command not admitted after prior reply") { received == ["one", "two"] }
        held?(.success(["ready": true]))
        wait("reply ID does not match command") { response()?["id"] as? String == "two" }
        precondition(response()?["ok"] as? Bool == true)
        try command("two")
        let until = Date(timeIntervalSinceNow: 0.08)
        while Date() < until { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005)) }
        precondition(received == ["one", "two"], "Duplicate command executed twice")
        precondition(bridge.exportURL(root.appendingPathComponent("report.json").path) != nil)
        precondition(bridge.exportURL(root.appendingPathComponent("../escape.json").path) == nil)
        let link = root.appendingPathComponent("symlink.json")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/tmp/unused-benchmark-target")
        precondition(bridge.exportURL(link.path) == nil)
        print("PASS: private control directory, serialized admission, duplicate suppression, reply identity and export containment")
    }
}
