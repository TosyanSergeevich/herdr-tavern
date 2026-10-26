import Foundation
import CoreGraphics

@main struct TerminalLinkResolverTests {
    private final class Gate {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        private var first = true
        private var entered = false
        var started: Bool { lock.lock(); defer { lock.unlock() }; return entered }
        func exists(_ path: String) -> Bool {
            precondition(!Thread.isMainThread)
            lock.lock(); let pause = first; first = false; if pause { entered = true }; lock.unlock()
            if pause { semaphore.wait() }
            return FileManager.default.fileExists(atPath: path)
        }
    }
    static func waitUntil(_ condition: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: 3)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005)) }
        precondition(condition(), "Resolver completion timed out")
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tavern-resolver-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a.swift", "b.swift", "c.swift"] { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
        func snapshot(_ name: String, cwd: String? = nil, generation: UInt64 = 1) -> TerminalLinkHoverSnapshot {
            TerminalLinkHoverSnapshot(bootID: "boot", projectionID: 1, paneID: "p", rowGeneration: generation,
                rowGeometry: CGRect(x: 0, y: 0, width: 80, height: 1), column: 0, anchor: 0,
                utf16Offset: 0, cwd: cwd ?? root.path, explicitTarget: nil, rowText: name)
        }
        do {
            let gate = Gate()
            let blocked = TerminalLinkHoverResolver(fileExists: gate.exists)
            var received: [(String, URL?)] = []
            blocked.request(snapshot("a.swift")) { received.append(("a", $0)) }
            waitUntil { gate.started }
            blocked.request(snapshot("b.swift")) { received.append(("b", $0)) }
            blocked.request(snapshot("c.swift")) { received.append(("c", $0)) }
            gate.semaphore.signal()
            waitUntil { !received.isEmpty }
            precondition(received.count == 1 && received[0].0 == "c" && received[0].1 == root.appendingPathComponent("c.swift"))
            blocked.cancel()
            print("PASS: one blocked request plus replaced latest publishes only the newest row")
        }
        do {
            let gate = Gate()
            let blocked = TerminalLinkHoverResolver(fileExists: gate.exists)
            var stale = false, current = false
            blocked.request(snapshot("a.swift")) { _ in stale = true }
            waitUntil { gate.started }
            blocked.invalidate()
            blocked.request(snapshot("b.swift", generation: 2)) { current = $0 == root.appendingPathComponent("b.swift") }
            gate.semaphore.signal(); waitUntil { current }
            precondition(!stale)
            try FileManager.default.removeItem(at: root.appendingPathComponent("b.swift"))
            blocked.invalidate()
            var delivered = false, missing: URL?
            blocked.request(snapshot("b.swift", generation: 3)) { missing = $0; delivered = true }
            waitUntil { delivered }; precondition(missing == nil)
            print("PASS: invalidation suppresses blocked stale result and discards previous file existence")
        }
    }
}
