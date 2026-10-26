import Foundation
import CoreGraphics

struct TerminalLinkHoverSnapshot: Equatable {
    let bootID: String
    let projectionID: UInt64
    let paneID: String
    let rowGeneration: UInt64
    let rowGeometry: NSRect
    let column: Int
    let anchor: Int
    let utf16Offset: Int
    let cwd: String?
    let explicitTarget: String?
    let rowText: String
}

final class TerminalLinkHoverResolver {
    private struct Request {
        let token: UInt64
        let snapshot: TerminalLinkHoverSnapshot
        let completion: (URL?) -> Void
    }

    // Only this value-owned state crosses to the serial worker; no AppKit owner is retained.
    private final class Worker {
        private struct RowKey: Equatable {
            let bootID: String
            let paneID: String
            let generation: UInt64
            let geometry: NSRect
            let cwd: String?
            let explicitTarget: String?
            let text: String

            init(_ snapshot: TerminalLinkHoverSnapshot) {
                bootID = snapshot.bootID
                paneID = snapshot.paneID
                generation = snapshot.rowGeneration
                geometry = snapshot.rowGeometry
                cwd = snapshot.cwd
                explicitTarget = snapshot.explicitTarget
                text = snapshot.rowText
            }
        }

        private struct RowEntry {
            let key: RowKey
            let candidates: [TerminalLinkCandidate]
        }

        private struct FileEntry {
            let exists: Bool
            let expires: TimeInterval
            var access: UInt64
        }

        private let fileExists: (String) -> Bool
        private var rows: [RowEntry] = []
        private var files: [String: FileEntry] = [:]
        private var access: UInt64 = 0

        init(fileExists: @escaping (String) -> Bool) {
            self.fileExists = fileExists
        }

        func invalidate() {
            rows.removeAll(keepingCapacity: true)
            files.removeAll(keepingCapacity: true)
        }

        func resolve(_ snapshot: TerminalLinkHoverSnapshot) -> URL? {
            let key = RowKey(snapshot)
            let candidates: [TerminalLinkCandidate]
            if let index = rows.firstIndex(where: { $0.key == key }) {
                let entry = rows.remove(at: index)
                rows.append(entry)
                candidates = entry.candidates
            } else {
                if let explicit = snapshot.explicitTarget {
                    candidates = TerminalLinks.explicitCandidate(explicit, cwd: snapshot.cwd).map { [$0] } ?? []
                } else {
                    candidates = TerminalLinks.candidates(in: snapshot.rowText, cwd: snapshot.cwd)
                }
                if rows.count == 128 { rows.removeFirst() }
                rows.append(RowEntry(key: key, candidates: candidates))
            }
            let candidate = snapshot.explicitTarget != nil ? candidates.first : candidates.first {
                NSLocationInRange(snapshot.utf16Offset, $0.range)
            }
            guard let candidate else { return nil }
            return TerminalLinks.resolve(candidate, fileExists: cachedFileExists)
        }

        private func cachedFileExists(_ path: String) -> Bool {
            access &+= 1
            let now = ProcessInfo.processInfo.systemUptime
            if var entry = files[path], entry.expires > now {
                entry.access = access
                files[path] = entry
                return entry.exists
            }
            let exists = fileExists(path)
            if files[path] == nil, files.count == 256,
               let oldest = files.min(by: { $0.value.access < $1.value.access })?.key {
                files.removeValue(forKey: oldest)
            }
            files[path] = FileEntry(exists: exists, expires: ProcessInfo.processInfo.systemUptime + 1, access: access)
            return exists
        }
    }

    private let queue = DispatchQueue(label: "org.herdr.tavern.link-hover", qos: .userInitiated)
    private let worker: Worker
    private var token: UInt64 = 0
    private var inFlight = false
    private var latest: Request?
    private var active: Request?

    init(fileExists: @escaping (String) -> Bool = FileManager.default.fileExists(atPath:)) {
        worker = Worker(fileExists: fileExists)
    }

    func request(_ snapshot: TerminalLinkHoverSnapshot, completion: @escaping (URL?) -> Void) {
        precondition(Thread.isMainThread)
        token &+= 1
        let request = Request(token: token, snapshot: snapshot, completion: completion)
        if inFlight {
            latest = request
        } else {
            start(request)
        }
    }

    func cancel() {
        precondition(Thread.isMainThread)
        token &+= 1
        latest = nil
        active = nil
    }

    func invalidate() {
        precondition(Thread.isMainThread)
        cancel()
        let worker = worker
        // Ordered after any current syscall and before subsequent work; never waits on main.
        queue.async { worker.invalidate() }
    }

    private func start(_ request: Request) {
        inFlight = true
        let worker = worker
        active = request
        let snapshot = request.snapshot
        let requestToken = request.token
        queue.async { [weak self] in
            let target = worker.resolve(snapshot)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let completed = self.active
                self.active = nil
                self.inFlight = false
                // Start the replaceable request before invoking client code, which can reenter.
                let next = self.latest
                self.latest = nil
                if let next { self.start(next) }
                if requestToken == self.token { completed?.completion(target) }
            }
        }
    }
}
