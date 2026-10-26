import Foundation

#if !TAVERN_RENDER_TESTING
#error("ConnectionWriterTests requires -D TAVERN_RENDER_TESTING")
#endif

private struct WriterTestFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw WriterTestFailure(description: message) }
}

private func eventually(_ message: String, timeout: TimeInterval = 10, _ condition: () -> Bool) throws {
    precondition(Thread.isMainThread)
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { throw WriterTestFailure(description: "Timed out: " + message) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.005))
    }
}

// Only the writer waits on this gate. Tests continue servicing the main runloop.
private final class WriterGate {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var didEnter = false
    private var didTimeOut = false
    private var didRelease = false
    var entered: Bool { lock.lock(); defer { lock.unlock() }; return didEnter }
    var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return didTimeOut }
    func block() {
        precondition(!Thread.isMainThread, "Writer hook ran on main")
        lock.lock(); didEnter = true; lock.unlock()
        let result = release.wait(timeout: .now() + 15)
        lock.lock(); didTimeOut = result == .timedOut; lock.unlock()
    }
    func open() {
        lock.lock()
        let signal = !didRelease
        didRelease = true
        lock.unlock()
        if signal { release.signal() }
    }
    deinit { open() }
}

private final class WriterCallbacks {
    private(set) var results: [String: [Error?]] = [:]
    private(set) var allOnMain = true
    func completion(_ name: String) -> (Error?) -> Void {
        { error in
            // Avoid mutating test state off-main even when reporting a broken contract.
            if Thread.isMainThread { self.results[name, default: []].append(error) }
            else {
                DispatchQueue.main.async {
                    self.allOnMain = false
                    self.results[name, default: []].append(error)
                }
            }
        }
    }
    func wait(_ names: [String]) throws {
        try eventually("callbacks " + names.joined(separator: ",")) {
            names.allSatisfy { self.results[$0]?.count ?? 0 >= 1 }
        }
        try require(allOnMain, "Completion delivered off-main")
        for name in names { try require(results[name]?.count == 1, "Completion must run once: " + name) }
    }
    func success(_ names: [String]) throws {
        try wait(names)
        for name in names { try require(results[name]![0] == nil, "Unexpected failure for \(name): \(String(describing: results[name]![0]))") }
    }
    func failure(_ names: [String], closed: Bool = false) throws {
        try wait(names)
        for name in names {
            let error = results[name]![0]
            try require(error != nil, "Expected failure: " + name)
            if closed { try require(error?.localizedDescription == L("core.connection.closed"), "Expected existing closed error: " + name) }
        }
    }
    func exactlyOnce(_ names: [String]) throws {
        try require(allOnMain, "Completion delivered off-main")
        for name in names { try require(results[name]?.count == 1, "Late duplicate callback: " + name) }
    }
}

private final class WriterServerFixture {
    let directory: URL
    let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let diagnostic: FileHandle
    private(set) var events: [[String: Any]] = []
    private(set) var outputEnded = false
    private(set) var outputError: String?
    private(set) var connection: RustConnection!
    private(set) var snapshot: [String: Any]?
    private var stopped = false
    var commands: [[String: Any]] { events.filter { $0["event"] as? String == "command" } }

    init(helper: URL) throws {
        directory = URL(fileURLWithPath: "/tmp/cw-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let log = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        diagnostic = try FileHandle(forWritingTo: log)
        process.executableURL = helper
        process.arguments = [directory.appendingPathComponent("s").path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = diagnostic
        do { try process.run() }
        catch { try? diagnostic.close(); try? FileManager.default.removeItem(at: directory); throw error }
        let handle = output.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var pending = Data()
            do {
                while true {
                    let bytes = handle.availableData
                    guard !bytes.isEmpty else { break }
                    pending.append(bytes)
                    while let newline = pending.firstIndex(of: 10) {
                        let line = pending.prefix(upTo: newline)
                        pending.removeSubrange(...newline)
                        let value = try JSONSerialization.jsonObject(with: Data(line))
                        guard let event = value as? [String: Any] else { throw WriterTestFailure(description: "Invalid helper event") }
                        DispatchQueue.main.async { self.events.append(event) }
                    }
                }
                if !pending.isEmpty { throw WriterTestFailure(description: "Incomplete helper output") }
            } catch { DispatchQueue.main.async { self.outputError = String(describing: error) } }
            DispatchQueue.main.async { self.outputEnded = true }
        }
    }
    func connect() throws {
        try waitEvent("ready")
        var opened: Result<OpaquePointer, Error>?
        let path = directory.appendingPathComponent("s").path
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try RustConnection.open(path: path, cols: 80, rows: 24, cellWidth: 8, cellHeight: 20) }
            DispatchQueue.main.async { opened = result }
        }
        try eventually("real RustConnection.open") { opened != nil }
        connection = RustConnection(pointer: try opened!.get()) { [weak self] result in
            if case .success(let event) = result, event.kind == UInt32(TAVERN_SNAPSHOT) { self?.snapshot = event.metadata }
        }
        try eventually("initial snapshot") { self.snapshot != nil }
        try waitEvent("connected")
    }
    func control(_ op: String, _ values: [String: Any] = [:]) throws {
        var command = values; command["op"] = op
        var bytes = try JSONSerialization.data(withJSONObject: command)
        bytes.append(10)
        try input.fileHandleForWriting.write(contentsOf: bytes)
    }
    func waitEvent(_ event: String) throws {
        try eventually("helper " + event) { self.events.contains { $0["event"] as? String == event } || self.outputEnded }
        try require(events.contains { $0["event"] as? String == event }, "Helper exited before \(event): \(outputError ?? "no output error")")
    }
    func waitCommands(_ count: Int) throws {
        try eventually("\(count) decoded wire commands") { self.commands.count >= count || self.outputEnded }
        try require(commands.count >= count, "Helper exited without expected commands")
    }
    func finish() throws {
        // A deliberately paused server does not observe EOF until it reads again.
        if process.isRunning && !outputEnded { try control("read") }
        connection?.close()
        try eventually("server EOF after connection close") { self.outputEnded }
        try require(outputError == nil, outputError ?? "")
        try eventually("helper process exit") { !self.process.isRunning }
    }
    func cleanup() {
        guard !stopped else { return }; stopped = true
        connection?.close()
        if process.isRunning {
            try? control("stop")
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            if process.isRunning { process.terminate() }
        }
        try? input.fileHandleForWriting.close()
        try? diagnostic.close()
        try? FileManager.default.removeItem(at: directory)
    }
    deinit { cleanup() }
}

@main
struct ConnectionWriterTests {
    static func main() throws {
        precondition(Thread.isMainThread)
        let temporary = URL(fileURLWithPath: "/tmp/cwh-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let helper = try compileServer(in: temporary)
        try adjacentResizePreservesInputOrder(helper)
        try extractedResizeCannotBeReplaced(helper)
        try serializationFailureDoesNotStopDrain(helper)
        try mutableFoundationIsSnapshotted(helper)
        try closeRejectsPendingAndNewCommands(helper)
        try blockedPartialWriteClosesWithoutRetry(helper)
        try largePasteLeavesMainResponsive(helper)
        try nonResizeQueueHasNoAdmissionCap(helper)
        print("ConnectionWriterTests passed")
    }

    // Uses only already-built release dependencies: no cargo, network, or product changes.
    private static func compileServer(in temporary: URL) throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let dependencies = root.appendingPathComponent("target/release/deps")
        let libraries = try FileManager.default.contentsOfDirectory(at: dependencies, includingPropertiesForKeys: [.contentModificationDateKey])
        func library(_ name: String) throws -> URL {
            let matches = libraries.filter { $0.lastPathComponent.hasPrefix("lib" + name + "-") && $0.pathExtension == "rlib" }
            guard let newest = try matches.sorted(by: {
                let left = try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
                let right = try $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
                return left > right
            }).first else { throw WriterTestFailure(description: "Missing release dependency: " + name) }
            return newest
        }
        let helper = temporary.appendingPathComponent("writer-server")
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        compiler.arguments = ["rustc", "+stable", "--edition=2021", root.appendingPathComponent("tests/ConnectionWriterServer.rs").path,
                              "-L", "dependency=" + dependencies.path, "--extern", "herdr_protocol=" + (try library("herdr_protocol")).path,
                              "--extern", "serde_json=" + (try library("serde_json")).path, "-o", helper.path]
        compiler.currentDirectoryURL = root
        try compiler.run()
        defer { if compiler.isRunning { compiler.terminate() } }
        try eventually("test server compilation", timeout: 60) { !compiler.isRunning }
        try require(compiler.terminationStatus == 0, "Unable to compile test-only Rust server")
        return helper
    }

    private static func scenario(_ helper: URL, _ body: (WriterServerFixture, WriterCallbacks) throws -> Void) throws {
        let server = try WriterServerFixture(helper: helper)
        defer { server.cleanup() }
        try server.connect()
        try body(server, WriterCallbacks())
    }
    private static func resize(_ cols: Int) -> [String: Any] {
        ["type": "resize", "cols": cols, "rows": 24, "cell_width_px": 8, "cell_height_px": 20]
    }
    private static func paste(_ text: Any) -> [String: Any] { ["type": "paste", "pane_id": "writer-pane", "text": text] }
    private static func key(_ kind: Int) -> [String: Any] { ["type": "key", "pane_id": "writer-pane", "key": "a", "kind": kind] }

    private static func adjacentResizePreservesInputOrder(_ helper: URL) throws {
        try scenario(helper) { server, callbacks in
            let gate = WriterGate(); defer { gate.open() }
            server.connection.beforeWriterDrain = { gate.block() }
            server.connection.send(resize(81), completion: callbacks.completion("A"))
            try eventually("pending resize gate") { gate.entered }
            server.connection.send(resize(82), completion: callbacks.completion("B"))
            server.connection.send(key(0), completion: callbacks.completion("down"))
            server.connection.send(resize(83), completion: callbacks.completion("C"))
            server.connection.send(key(2), completion: callbacks.completion("up"))
            server.connection.send(paste("tail"), completion: callbacks.completion("paste"))
            gate.open(); try server.control("read")
            let names = ["A", "B", "down", "C", "up", "paste"]
            try callbacks.success(names)
            try server.waitCommands(5)
            try server.finish()
            let records = server.commands
            try require(records.map { $0["kind"] as? String ?? "" } == ["resize", "key", "resize", "key", "paste"], "Resize coalescing crossed an input barrier")
            try require(records[0]["cols"] as? Int == 82 && records[2]["cols"] as? Int == 83, "Wrong coalesced geometry")
            try require(records[1]["key_kind"] as? String == "down" && records[3]["key_kind"] as? String == "up", "Key down/up order changed")
            try require(records[4]["text"] as? String == "tail", "Paste changed")
            try callbacks.exactlyOnce(names)
            try require(!gate.timedOut, "Writer gate timed out")
        }
    }

    private static func extractedResizeCannotBeReplaced(_ helper: URL) throws {
        try scenario(helper) { server, callbacks in
            let gate = WriterGate(); defer { gate.open() }
            server.connection.beforeWriterSerialization = { command in if command["cols"] as? Int == 81 { gate.block() } }
            server.connection.send(resize(81), completion: callbacks.completion("A"))
            try eventually("extracted resize") { gate.entered }
            server.connection.send(resize(82), completion: callbacks.completion("B"))
            server.connection.send(key(0), completion: callbacks.completion("key"))
            gate.open(); try server.control("read")
            try callbacks.success(["A", "B", "key"])
            try server.waitCommands(3); try server.finish()
            try require(server.commands.map { $0["kind"] as? String ?? "" } == ["resize", "resize", "key"], "In-flight resize was replaced")
            try require(server.commands.prefix(2).compactMap { $0["cols"] as? Int } == [81, 82], "In-flight resize payload changed")
            try callbacks.exactlyOnce(["A", "B", "key"])
        }
    }

    private static func serializationFailureDoesNotStopDrain(_ helper: URL) throws {
        try scenario(helper) { server, callbacks in
            let gate = WriterGate(); defer { gate.open() }
            server.connection.beforeWriterDrain = { gate.block() }
            server.connection.send(paste(Date()), completion: callbacks.completion("invalid"))
            try eventually("invalid entry queued") { gate.entered }
            server.connection.send(paste("after-invalid"), completion: callbacks.completion("valid"))
            gate.open(); try server.control("read")
            try callbacks.failure(["invalid"]); try callbacks.success(["valid"])
            try server.waitCommands(1); try server.finish()
            try require(server.commands.count == 1 && server.commands[0]["text"] as? String == "after-invalid", "Invalid JSON reached wire or stopped drain")
            try callbacks.exactlyOnce(["invalid", "valid"])
        }
    }

    private static func mutableFoundationIsSnapshotted(_ helper: URL) throws {
        try scenario(helper) { server, callbacks in
            let gate = WriterGate(); defer { gate.open() }
            server.connection.beforeWriterDrain = { gate.block() }
            var acceptedDataWasOwned: Bool?
            server.connection.beforeWriterSerialization = { command in
                precondition(!Thread.isMainThread)
                if let bytes = command["text"] as? Data {
                    let owned = bytes == Data([1, 2, 3])
                    DispatchQueue.main.async { acceptedDataWasOwned = owned }
                }
            }
            let text = NSMutableString(string: "accepted")
            let nested = NSMutableDictionary(dictionary: ["text": text])
            let array = NSMutableArray(object: nested)
            let params = NSMutableDictionary(dictionary: ["nested": array])
            guard let boot = server.snapshot?["boot_id"] as? String else {
                throw WriterTestFailure(description: "Fixture snapshot has no boot_id")
            }
            server.connection.send(["type": "request", "request_id": "snapshot-test", "boot_id": boot, "method": "writer.snapshot", "params": params], completion: callbacks.completion("nested"))
            try eventually("mutable graph captured") { gate.entered }
            let pasteText = NSMutableString(string: "accepted-paste")
            server.connection.send(paste(pasteText), completion: callbacks.completion("string"))
            let bytes = NSMutableData(data: Data([1, 2, 3]))
            server.connection.send(paste(bytes), completion: callbacks.completion("data"))
            text.setString("mutated"); nested["extra"] = true; array.add("late"); params["extra"] = true
            pasteText.setString("mutated-paste"); bytes.append(Data([4, 5]))
            gate.open(); try server.control("read")
            try callbacks.success(["nested", "string"]); try callbacks.failure(["data"])
            try require(acceptedDataWasOwned == true, "Invalid NSMutableData was not snapshotted before worker serialization")
            try server.waitCommands(2); try server.finish()
            try require(server.commands.count == 2, "Invalid mutable Data reached wire")
            let actual = server.commands[0]["params"] as? NSDictionary
            let expected: NSDictionary = ["nested": [["text": "accepted"]]]
            try require(actual == expected, "Nested mutable Foundation graph changed after admission")
            try require(server.commands[1]["text"] as? String == "accepted-paste", "NSMutableString changed after admission")
            try callbacks.exactlyOnce(["nested", "string", "data"])
        }
    }

    private static func closeRejectsPendingAndNewCommands(_ helper: URL) throws {
        try scenario(helper) { server, callbacks in
            let gate = WriterGate(); defer { gate.open() }
            server.connection.beforeWriterDrain = { gate.block() }
            server.connection.send(resize(81), completion: callbacks.completion("A"))
            try eventually("close pending gate") { gate.entered }
            server.connection.send(resize(82), completion: callbacks.completion("B"))
            server.connection.send(paste("unsent"), completion: callbacks.completion("pending"))
            server.connection.close()
            server.connection.send(paste("rejected"), completion: callbacks.completion("new"))
            // Must complete before releasing the writer, not merely after its queue drains.
            try callbacks.failure(["A", "B", "pending", "new"], closed: true)
            gate.open(); try server.finish()
            try require(server.commands.isEmpty, "Close sent an unsent command")
            try callbacks.exactlyOnce(["A", "B", "pending", "new"])
        }
        try scenario(helper) { server, callbacks in
            let gate = WriterGate(); defer { gate.open() }
            server.connection.beforeWriterSerialization = { _ in gate.block() }
            server.connection.send(paste("encoding"), completion: callbacks.completion("inflight"))
            try eventually("close encoding gate") { gate.entered }
            server.connection.send(key(0), completion: callbacks.completion("pending"))
            server.connection.close()
            try callbacks.failure(["pending"], closed: true)
            gate.open()
            try callbacks.failure(["inflight"])
            try server.finish()
            try require(server.commands.isEmpty, "Close during encoding wrote data")
            try callbacks.exactlyOnce(["inflight", "pending"])
        }
    }

    private static func blockedPartialWriteClosesWithoutRetry(_ helper: URL) throws {
        try scenario(helper) { server, callbacks in
            try server.control("partial", ["bytes": 1024])
            server.connection.send(paste(String(repeating: "p", count: 900 * 1024)), completion: callbacks.completion("partial"))
            try server.waitEvent("partial")
            server.connection.send(key(0), completion: callbacks.completion("pending"))
            server.connection.close()
            try callbacks.failure(["pending"], closed: true)
            try callbacks.wait(["partial"])
            try server.finish()
            try require(server.commands.isEmpty, "A partial paste was replayed or a queued key escaped close")
            try require(server.events.filter { $0["event"] as? String == "partial" }.count == 1, "Partial write was repeated")
            try callbacks.exactlyOnce(["partial", "pending"])
        }
    }

    private static func largePasteLeavesMainResponsive(_ helper: URL) throws {
        try scenario(helper) { server, callbacks in
            let gate = WriterGate(); defer { gate.open() }
            server.connection.beforeWriterSerialization = { _ in gate.block() }
            let text = String(repeating: "x", count: 900 * 1024)
            server.connection.send(paste(text), completion: callbacks.completion("large"))
            try eventually("large paste writer gate") { gate.entered }
            var heartbeat = false
            DispatchQueue.main.async { heartbeat = true }
            try eventually("main heartbeat while writer is gated") { heartbeat }
            try require(callbacks.results["large"] == nil, "Gated paste already completed")
            gate.open(); try server.control("read")
            try callbacks.success(["large"])
            try server.waitCommands(1); try server.finish()
            try require(server.commands.count == 1 && server.commands[0]["text"] as? String == text, "Large paste changed or repeated")
            try callbacks.exactlyOnce(["large"])
        }
    }

    private static func nonResizeQueueHasNoAdmissionCap(_ helper: URL) throws {
        try scenario(helper) { server, callbacks in
            let gate = WriterGate(); defer { gate.open() }
            server.connection.beforeWriterDrain = { gate.block() }
            let names = (0..<2049).map { "input-\($0)" }
            for name in names { server.connection.send(paste(name), completion: callbacks.completion(name)) }
            try eventually("large accepted FIFO") { gate.entered }
            gate.open(); try server.control("read")
            try callbacks.success(names)
            try server.waitCommands(names.count); try server.finish()
            try require(server.commands.compactMap { $0["text"] as? String } == names, "Non-resize inputs were dropped, reordered, or retried")
            try callbacks.exactlyOnce(names)
        }
    }
}
