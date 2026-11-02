import AppKit
import Darwin

@main struct BenchmarkBridgeTests {
    static func wait(_ description: String, _ predicate: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: 3)
        while !predicate(), Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005)) }
        precondition(predicate(), description)
    }
    static func main() throws {
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
