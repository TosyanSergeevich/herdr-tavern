import AppKit
import Darwin

// Explicit local benchmark opt-in only. This channel is never opened in normal
// sessions; it deliberately permits fixture text inspection, unlike the recorder.
final class TavernBenchmarkBridge {
    typealias Reply = (Result<[String: Any], Failure>) -> Void
    enum Failure: String, Error {
        case invalidCommand = "invalid_command", unavailable, timeout, unsafeDirectory = "unsafe_directory"
        case locked, notVisible = "not_visible", wrongState = "wrong_state", exportFailed = "export_failed"
    }
    let directory: URL
    private let queue = DispatchQueue(label: "org.local.HerdrTavern.benchmark", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var lastID = ""
    private var busy = false
    private let handle: ([String: Any], @escaping Reply) -> Void

    init(directory: URL, handle: @escaping ([String: Any], @escaping Reply) -> Void) throws {
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else {
            throw Failure.unsafeDirectory
        }
        self.directory = directory.standardizedFileURL
        self.handle = handle
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        timer.resume()
    }
    deinit { timer?.cancel() }

    private func poll() {
        guard !busy else { return }
        let input = directory.appendingPathComponent("command.json")
        var info = stat()
        guard lstat(input.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_size <= 65536,
              let data = try? Data(contentsOf: input),
              let command = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = command["id"] as? String, !id.isEmpty, id.utf8.count <= 128,
              id != lastID else { return }
        lastID = id
        busy = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.handle(command) { [weak self] result in
                guard let self else { return }
                self.queue.async {
                    var response: [String: Any] = ["id": id]
                    switch result {
                    case .success(let value): response["ok"] = true; response["result"] = value
                    case .failure(let failure): response["ok"] = false; response["error"] = failure.rawValue
                    }
                    do {
                        let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
                        let output = self.directory.appendingPathComponent("response.json")
                        try data.write(to: output, options: .atomic)
                        chmod(output.path, 0o600)
                    } catch {
                        // The runner times out when its private directory becomes
                        // unwritable. Do not leak a filesystem path or raw error.
                    }
                    self.busy = false
                }
            }
        }
    }
    func exportURL(_ path: String) -> URL? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.deletingLastPathComponent() == directory else { return nil }
        var info = stat()
        if lstat(url.path, &info) == 0, info.st_mode & S_IFMT != S_IFREG { return nil }
        return url
    }
}

// A committed frame need not dirty terminal pixels. Keep that outcome distinct
// from a draw so a successful scroll cannot become a timeout or a fake latency.
struct TavernBenchmarkPresentation {
    struct FrameID: Equatable {
        let boot: String
        let projection: Int
        let surface: Int
    }
    struct Checkpoint {
        fileprivate let applied: UInt64
        fileprivate let drawn: UInt64
    }
    enum Completion: Equatable {
        case painted(UInt64)
        case noTerminalPaint
    }
    private var appliedSequence: UInt64 = 0
    private var drawnSequence: UInt64 = 0
    private var lastApplied: FrameID?
    private var lastDrawn: FrameID?
    private var applyNeedsPaint = true
    private var drawnAt: UInt64 = 0
    private(set) var drawnTab = ""
    private(set) var drawnPane = ""
    var checkpoint: Checkpoint { Checkpoint(applied: appliedSequence, drawn: drawnSequence) }

    mutating func applied(_ frame: FrameID, needsPaint: Bool) {
        guard lastApplied != frame else { return }
        lastApplied = frame
        appliedSequence &+= 1
        applyNeedsPaint = needsPaint || lastDrawn == frame
    }
    mutating func drew(_ frame: FrameID, at time: UInt64, tab: String, pane: String) {
        lastDrawn = frame
        drawnSequence &+= 1
        drawnAt = time
        drawnTab = tab
        drawnPane = pane
    }
    func completion(after checkpoint: Checkpoint, allowNoPaint: Bool,
                    condition: @autoclosure () -> Bool) -> Completion? {
        let noPaint = allowNoPaint && appliedSequence > checkpoint.applied && !applyNeedsPaint
        let painted = drawnSequence > checkpoint.drawn
        guard (noPaint || painted) && condition() else { return nil }
        return painted ? .painted(drawnAt) : .noTerminalPaint
    }
}


// Calls the production scrollWheel path with a controlled precise delta and
// actual window coordinates. This is synthetic input, not physical trackpad time.
final class TavernBenchmarkScrollEvent: NSEvent {
    private let point: NSPoint
    private let delta: CGFloat
    private let number: Int
    init(point: NSPoint, lines: Double, cellHeight: CGFloat, window: Int) {
        self.point = point; delta = CGFloat(lines) * cellHeight; number = window
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var type: NSEvent.EventType { .scrollWheel }
    override var locationInWindow: NSPoint { point }
    override var windowNumber: Int { number }
    override var scrollingDeltaY: CGFloat { delta }
    override var scrollingDeltaX: CGFloat { 0 }
    override var hasPreciseScrollingDeltas: Bool { true }
    override var modifierFlags: NSEvent.ModifierFlags { [.shift] }
}
