import AppKit
import Darwin
import os.signpost

// Darwin's Swift importer exposes the `struct flock` name instead of this function.
// POSIX declaration: int flock(int descriptor, int operation).
@_silgen_name("flock")
func tavernPerformanceFileLock(_ descriptor: Int32, _ operation: Int32) -> Int32

/// Numeric-only diagnostics. No session identifiers, terminal text, paths or error messages enter records.
final class TavernPerformance: @unchecked Sendable {
    static let shared = TavernPerformance()

    enum Stage: String, CaseIterable {
        case eventDecode, mainHandoff, eventReceive, surfaceApply, surfaceDraw, navigationRebuild
        case endpointQueueWait, endpointRoundTrip, writerQueueWait, writerEncode, wireSend, rustQueueWait
        case nebulaDrawable, nebulaEncode, nebulaGPU, cardDrawable, cardEncode, cardGPU
        case tabSwitch, inputToDraw, mainBusy, nebulaPresentation, cardPresentation
        fileprivate var index: Int {
            switch self {
            case .eventDecode: return 0
            case .mainHandoff: return 1
            case .eventReceive: return 2
            case .surfaceApply: return 3
            case .surfaceDraw: return 4
            case .navigationRebuild: return 5
            case .endpointQueueWait: return 6
            case .endpointRoundTrip: return 7
            case .writerQueueWait: return 8
            case .writerEncode: return 9
            case .wireSend: return 10
            case .rustQueueWait: return 11
            case .nebulaDrawable: return 12
            case .nebulaEncode: return 13
            case .nebulaGPU: return 14
            case .cardDrawable: return 15
            case .cardEncode: return 16
            case .cardGPU: return 17
            case .tabSwitch: return 18
            case .inputToDraw: return 19
            case .mainBusy: return 20
            case .nebulaPresentation: return 21
            case .cardPresentation: return 22
            }
        }
    }
    enum Counter: String, CaseIterable {
        case events, fullFrames, patchFrames, frameCells, drawGlyphs, drawAreaPixels, scrollInputs
        case scrollCoalesced, requestsRejected, nebulaReplaced, nebulaUnavailable, cardUnavailable
        case nebulaPresented, cardPresented, scrollFractional
        fileprivate var index: Int {
            switch self {
            case .events: return 0
            case .fullFrames: return 1
            case .patchFrames: return 2
            case .frameCells: return 3
            case .drawGlyphs: return 4
            case .drawAreaPixels: return 5
            case .scrollInputs: return 6
            case .scrollCoalesced: return 7
            case .requestsRejected: return 8
            case .nebulaReplaced: return 9
            case .nebulaUnavailable: return 10
            case .cardUnavailable: return 11
            case .nebulaPresented: return 12
            case .cardPresented: return 13
            case .scrollFractional: return 14
            }
        }
    }
    enum Gauge: String, CaseIterable {
        case endpointQueue, writerQueue, rustQueueDepth, rustQueueHighWater, visibleCards, tabs, panes
        case windowWidth, windowHeight, backingScale, refreshHz, animationsEnabled, appVisible
        fileprivate var index: Int {
            switch self {
            case .endpointQueue: return 0
            case .writerQueue: return 1
            case .rustQueueDepth: return 2
            case .rustQueueHighWater: return 3
            case .visibleCards: return 4
            case .tabs: return 5
            case .panes: return 6
            case .windowWidth: return 7
            case .windowHeight: return 8
            case .backingScale: return 9
            case .refreshHz: return 10
            case .animationsEnabled: return 11
            case .appVisible: return 12
            }
        }
    }
    struct Span {
        fileprivate let stage: Stage
        fileprivate let start: UInt64
        fileprivate let epoch: UInt64
        fileprivate let signpost: OSSignpostID?
    }
    enum DiagnosticError: String, Error { case disabled, busy, invalidDestination, storageUnavailable, writeFailed, recordTooLarge }

    static let slowCapacity = 128
    static let logFileLimit = 256 * 1024
    static let logFileCount = 4
    static let incidentFileCount = 3
    // Persistent storage: 7 × 256 KiB, plus at most one atomic-write temporary.
    // Numeric accumulator storage: 23 × 512 UInt64 bins and a 128-entry slow ring.
    private static let slowThreshold: UInt64 = 16_000_000
    private static let signpostLog = OSLog(subsystem: "app.herdr.tavern", category: "Performance")
    private let lock = NSLock()
    private let worker = DispatchQueue(label: "tavern.performance", qos: .utility)
    private let enabled: Bool
    private let detailed: Bool
    private let directory: URL
    // Launch-local diagnostic identity, unrelated to server sessions or process IDs.
    private let instanceID = UUID().uuidString.lowercased()
    private let appMetadata = TavernPerformance.buildMetadata()
    var isEnabled: Bool { enabled }
    private var aggregates = Stage.allCases.map { _ in Aggregate() }
    private var counters = [UInt64](repeating: 0, count: Counter.allCases.count)
    private var gauges = [Double?](repeating: nil, count: Gauge.allCases.count)
    private var gaugeMaxima = [Double?](repeating: nil, count: Gauge.allCases.count)
    private var slow = [SlowSample?](repeating: nil, count: slowCapacity)
    private var slowCursor = 0
    private var epoch: UInt64 = 0
    private var epochStart = TavernPerformance.now()
    private var resource = Resources()
    private var baseline: Resources?
    private var resourceSamples: UInt64 = 0
    private var epochPeak: UInt64 = 0
    private var busySince: UInt64?
    private var running = false
    private var generation: UInt64 = 0
    private var pendingExports = 0
    private var incidentPending = false
    // Main-thread owned observer; worker-owned timer and log cursor.
    private var observer: CFRunLoopObserver?
    private var timer: DispatchSourceTimer?
    private var logIndex = 0
    private var incidentIndex = 0
    private var storageFailures: UInt64 = 0

    init(environment: [String: String] = ProcessInfo.processInfo.environment, directory: URL? = nil) {
        enabled = environment["TAVERN_PERFORMANCE"]?.lowercased() != "off"
        detailed = enabled && environment["TAVERN_PERFORMANCE_DETAIL"] == "1"
        self.directory = directory ?? environment["TAVERN_PERFORMANCE_DIRECTORY"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/HerdrTavern/Performance", isDirectory: true)
        resource = Self.readResources()
        baseline = resource
    }
    deinit {
        if let observer { CFRunLoopObserverInvalidate(observer) }
        timer?.cancel()
    }

    private static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    private static func add(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let result = a.addingReportingOverflow(b)
        return result.overflow ? UInt64.max : result.partialValue
    }

    func begin(_ stage: Stage) -> Span {
        guard enabled else { return Span(stage: stage, start: 0, epoch: 0, signpost: nil) }
        let stamp = locked { epoch }
        let id: OSSignpostID? = detailed ? OSSignpostID(log: Self.signpostLog) : nil
        if let id { os_signpost(.begin, log: Self.signpostLog, name: "Stage", signpostID: id, "%{public}@", stage.rawValue) }
        return Span(stage: stage, start: Self.now(), epoch: stamp, signpost: id)
    }

    func end(_ span: Span) {
        guard enabled else { return }
        let finish = Self.now()
        if let id = span.signpost { os_signpost(.end, log: Self.signpostLog, name: "Stage", signpostID: id) }
        locked {
            guard span.epoch == epoch, finish >= span.start else { return }
            record(span.stage, finish - span.start, finish)
        }
    }
    func duration(_ stage: Stage, nanoseconds: UInt64) {
        guard enabled else { return }
        let now = Self.now()
        locked { record(stage, nanoseconds, now) }
    }
    private func record(_ stage: Stage, _ duration: UInt64, _ now: UInt64) {
        aggregates[stage.index].record(duration)
        // Presentation intervals include intentional display cadence, not just work.
        // Keep their histograms, but never let scheduled frames evict actionable slow work.
        if duration >= Self.slowThreshold, stage != .nebulaPresentation, stage != .cardPresentation {
            slow[slowCursor] = SlowSample(stage: stage, duration: duration, at: now >= epochStart ? now - epochStart : 0)
            slowCursor = (slowCursor + 1) % Self.slowCapacity
        }
    }
    func count(_ counter: Counter, _ amount: UInt64 = 1) {
        guard enabled else { return }
        locked { counters[counter.index] = Self.add(counters[counter.index], amount) }
    }
    func gauge(_ gauge: Gauge, _ value: Double) {
        guard enabled, value.isFinite else { return }
        locked {
            let index = gauge.index
            gauges[index] = value
            gaugeMaxima[index] = max(gaugeMaxima[index] ?? value, value)
        }
    }
    func reset() {
        locked {
            let current = Self.readResources()
            epoch &+= 1
            epochStart = Self.now()
            aggregates = Stage.allCases.map { _ in Aggregate() }
            counters = [UInt64](repeating: 0, count: Counter.allCases.count)
            // Gauges describe current UI/context, not accumulated scenario work.
            // Copy scalars, not the array buffer: next hot-path update must not trigger COW.
            for gauge in Gauge.allCases { gaugeMaxima[gauge.index] = gauges[gauge.index] }
            slow = [SlowSample?](repeating: nil, count: Self.slowCapacity)
            slowCursor = 0
            resource = current
            baseline = current
            resourceSamples = 0
            epochPeak = current.footprint ?? 0
            if busySince != nil { busySince = epochStart }
        }
    }

    func snapshot() -> [String: Any] {
        let machine = Self.machineMetadata()
        let recordedAt = Date().timeIntervalSince1970
        // Build fresh dictionaries while locked: no returned mutable Foundation container or
        // histogram COW buffer can race with subsequent numeric writes.
        return locked {
            let current = Self.readResources()
            resource = current
            resourceSamples = Self.add(resourceSamples, 1)
            epochPeak = max(epochPeak, current.footprint ?? 0)
            var stages: [String: Any] = [:]
            for stage in Stage.allCases { stages[stage.rawValue] = aggregates[stage.index].json }
            var counts: [String: Any] = [:]
            for counter in Counter.allCases { counts[counter.rawValue] = counters[counter.index] }
            var values: [String: Any] = [:]
            for gauge in Gauge.allCases { values[gauge.rawValue] = gauges[gauge.index].map { $0 as Any } ?? NSNull() }
            var maxima: [String: Any] = [:]
            for gauge in Gauge.allCases { maxima[gauge.rawValue] = gaugeMaxima[gauge.index].map { $0 as Any } ?? NSNull() }
            let now = Self.now()
            let samples = (0..<Self.slowCapacity).compactMap { slow[(slowCursor + $0) % Self.slowCapacity]?.json }
            return ["schema_version": 1, "enabled": enabled, "detailed": detailed,
                    "recorded_at_unix_seconds": recordedAt, "instance_id": instanceID, "app": appMetadata,
                    "epoch": epoch, "elapsed_ns": now - epochStart,
                    "histogram_relative_precision": 0.125, "quantile_method": "histogram_upper_bound",
                    "stages": stages, "counters": counts, "gauges": values, "gauge_maxima": maxima, "slow_samples": samples,
                    "resources": resource.json(baseline: baseline, peak: epochPeak, samples: resourceSamples),
                    "main_busy_current_ns": busySince.map { now >= $0 ? now - $0 : 0 } ?? 0,
                    "storage_failures": storageFailures, "machine": machine]
        }
    }

    /// Safe to call repeatedly, including from non-main callers. Does not block them.
    func start() {
        guard enabled else { return }
        DispatchQueue.main.async { [weak self] in self?.startOnMain() }
    }
    private func startOnMain() {
        let token: UInt64? = locked {
            guard !running else { return nil }
            running = true; generation &+= 1
            return generation
        }
        guard let token else { return }
        let activities = CFRunLoopActivity.entry.rawValue | CFRunLoopActivity.afterWaiting.rawValue |
            CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue
        let obs = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { [weak self] _, activity in
            guard let self else { return }
            let now = Self.now()
            self.locked {
                guard self.running, self.generation == token else { return }
                if activity == .afterWaiting || activity == .entry {
                    if self.busySince == nil { self.busySince = now }
                } else if let start = self.busySince {
                    self.busySince = nil
                    if now >= start { self.record(.mainBusy, now - start, now) }
                }
            }
        }
        observer = obs
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
        worker.async { [weak self] in
            guard let self, self.locked({ self.running && self.generation == token }) else { return }
            self.timer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: self.worker)
            timer.schedule(deadline: .now(), repeating: .seconds(5), leeway: .milliseconds(500))
            timer.setEventHandler { [weak self] in
                guard let self, self.locked({ self.running && self.generation == token }) else { return }
                self.writeSummary()
            }
            self.timer = timer
            timer.resume()
        }
    }
    func stop() {
        // Lifecycle operations remain FIFO on main; cancellation and final flush never wait on I/O.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let wasRunning = self.locked { () -> Bool in
                guard self.running else { return false }
                self.running = false; self.generation &+= 1; self.busySince = nil
                return true
            }
            guard wasRunning else { return }
            if let observer = self.observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
            self.observer = nil
            self.worker.async { [weak self] in
                guard let self else { return }
                self.timer?.cancel(); self.timer = nil
                if self.enabled { self.writeSummary() }
            }
        }
    }

    func export(to url: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        guard enabled else { DispatchQueue.main.async { completion(.failure(DiagnosticError.disabled)) }; return }
        guard url.isFileURL, !url.hasDirectoryPath else {
            DispatchQueue.main.async { completion(.failure(DiagnosticError.invalidDestination)) }; return
        }
        let accepted = locked { () -> Bool in
            guard pendingExports < 2 else { return false }
            pendingExports += 1; return true
        }
        guard accepted else { DispatchQueue.main.async { completion(.failure(DiagnosticError.busy)) }; return }
        worker.async { [self] in
            let result: Result<URL, Error>
            do { try Self.write(snapshot(), to: url); result = .success(url) }
            catch let error as DiagnosticError { result = .failure(error) }
            catch { result = .failure(DiagnosticError.writeFailed) }
            locked { pendingExports -= 1 }
            DispatchQueue.main.async { completion(result) }
        }
    }
    func markIncident() {
        guard enabled else { return }
        let accepted = locked { () -> Bool in
            guard !incidentPending else { return false }; incidentPending = true; return true
        }
        guard accepted else { return }
        worker.async { [self] in
            defer { locked { incidentPending = false } }
            do {
                try withStorageLock {
                    let url = directory.appendingPathComponent("incident-\(incidentIndex).json")
                    try Self.write(snapshot(), to: url)
                    incidentIndex = (incidentIndex + 1) % Self.incidentFileCount
                }
            } catch { locked { storageFailures = Self.add(storageFailures, 1) } }
        }
    }
    private func prepareDirectory() throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch { throw DiagnosticError.storageUnavailable }
    }
    /// Cross-process slot rotation is serialized, without ever blocking the app/main thread.
    /// A contended periodic sample can be dropped rather than building an I/O backlog.
    private func withStorageLock(_ body: () throws -> Void) throws {
        try prepareDirectory()
        let path = directory.appendingPathComponent(".storage.lock").path
        let descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw DiagnosticError.storageUnavailable }
        defer { Darwin.close(descriptor) }
        guard tavernPerformanceFileLock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw DiagnosticError.storageUnavailable }
        defer { _ = tavernPerformanceFileLock(descriptor, LOCK_UN) }
        try body()
    }
    private func writeSummary() {
        do {
            try withStorageLock {
                var data = try Self.encode(snapshot())
                data.append(0x0a)
                var url = directory.appendingPathComponent("summary-\(logIndex).jsonl")
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
                if size + data.count > Self.logFileLimit {
                    logIndex = (logIndex + 1) % Self.logFileCount
                    url = directory.appendingPathComponent("summary-\(logIndex).jsonl")
                    try data.write(to: url, options: [.atomic])
                } else if FileManager.default.fileExists(atPath: url.path) {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.seekToEnd(); try handle.write(contentsOf: data)
                } else { try data.write(to: url, options: [.atomic]) }
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        } catch { locked { storageFailures = Self.add(storageFailures, 1) } }
    }
    private static func encode(_ value: [String: Any]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard data.count < logFileLimit else { throw DiagnosticError.recordTooLarge }
        return data
    }
    private static func write(_ value: [String: Any], to url: URL) throws {
        do {
            try encode(value).write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch let error as DiagnosticError { throw error }
        catch { throw DiagnosticError.writeFailed }
    }

    private struct SlowSample {
        let stage: Stage
        let duration: UInt64
        let at: UInt64
        var json: [String: Any] { ["stage": stage.rawValue, "duration_ns": duration, "at_ns": at] }
    }
    private struct Aggregate {
        var count: UInt64 = 0
        var total: UInt64 = 0
        var maximum: UInt64 = 0
        var bins = [UInt64](repeating: 0, count: 512)
        mutating func record(_ value: UInt64) {
            count = TavernPerformance.add(count, 1)
            total = TavernPerformance.add(total, value)
            maximum = max(maximum, value)
            let index: Int
            if value < 8 { index = Int(value) }
            else {
                let exponent = 63 - value.leadingZeroBitCount
                index = exponent * 8 + Int((value >> (exponent - 3)) & 7)
            }
            bins[index] = TavernPerformance.add(bins[index], 1)
        }
        func quantile(_ percent: UInt64) -> UInt64 {
            guard count > 0 else { return 0 }
            // ceil(count * percent / 100), without overflow.
            let target = (count / 100) * percent + ((count % 100) * percent + 99) / 100
            var cumulative: UInt64 = 0
            for (index, amount) in bins.enumerated() {
                cumulative = TavernPerformance.add(cumulative, amount)
                if cumulative >= target {
                    if index < 8 { return min(UInt64(index), maximum) }
                    let exponent = index / 8
                    let mantissa = UInt64(9 + index % 8)
                    let shift = exponent - 3
                    let upper = mantissa > (UInt64.max >> shift) ? UInt64.max : (mantissa << shift) - 1
                    return min(upper, maximum)
                }
            }
            return maximum
        }
        var json: [String: Any] {
            ["count": count, "total_ns": total, "max_ns": maximum,
             "p50_ns": count == 0 ? NSNull() : quantile(50) as Any,
             "p95_ns": count == 0 ? NSNull() : quantile(95) as Any,
             "p99_ns": count == 0 ? NSNull() : quantile(99) as Any]
        }
    }
    private struct Resources {
        var cpu: Double?
        var footprint: UInt64?
        var lifetimePeak: UInt64?
        var disk: UInt64?
        func json(baseline: Resources?, peak: UInt64, samples: UInt64) -> [String: Any] {
            let cpuDelta = cpu.flatMap { end in baseline?.cpu.map { max(0, end - $0) } }
            let diskDelta = disk.flatMap { end in baseline?.disk.map { end >= $0 ? end - $0 : 0 } }
            return ["cpu_seconds": cpu.map { $0 as Any } ?? NSNull(),
                    "physical_footprint_bytes": footprint.map { $0 as Any } ?? NSNull(),
                    "peak_physical_footprint_bytes": lifetimePeak.map { $0 as Any } ?? NSNull(),
                    "disk_write_bytes": disk.map { $0 as Any } ?? NSNull(),
                    "epoch_cpu_seconds": cpuDelta.map { $0 as Any } ?? NSNull(),
                    "epoch_disk_write_bytes": diskDelta.map { $0 as Any } ?? NSNull(),
                    "epoch_peak_physical_footprint_bytes": footprint == nil ? NSNull() : peak as Any,
                    "cpu_scope": "process_lifetime", "disk_scope": "process_lifetime",
                    "epoch_peak_method": "sampled_physical_footprint", "sample_count": samples,
                    "thermal_state": TavernPerformance.thermalState()]
        }
    }
    // proc_pid_rusage CPU fields use Mach absolute ticks, not nanoseconds.
    private static let cpuSecondsPerTick: Double? = {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS,
              timebase.numer > 0, timebase.denom > 0 else { return nil }
        return Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }()

    private static func readResources() -> Resources {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard status == 0 else { return Resources() }
        return Resources(cpu: cpuSecondsPerTick.map {
                             (Double(info.ri_user_time) + Double(info.ri_system_time)) * $0
                         },
                         footprint: info.ri_phys_footprint, lifetimePeak: info.ri_lifetime_max_phys_footprint,
                         disk: info.ri_diskio_byteswritten)
    }
    private static func thermalState() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
    private static func buildMetadata() -> [String: Any] {
        let info = Bundle.main.infoDictionary ?? [:]
        func version(_ key: String) -> Any {
            guard let value = info[key] as? String, !value.isEmpty, value.utf8.count <= 64,
                  value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) ||
                      (97...122).contains($0) || [43, 45, 46, 95].contains($0) }) else { return NSNull() }
            return value
        }
        let digest = info["TavernBuildSourceDigest"] as? String
        let safeDigest: Any
        if let digest, digest.utf8.count == 64,
           digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) {
            safeDigest = digest
        } else { safeDigest = NSNull() }
        return ["version": version("CFBundleShortVersionString"), "build": version("CFBundleVersion"),
                "source_digest": safeDigest]
    }

    private static func machineMetadata() -> [String: Any] {
        var size = 0
        var model: String? = nil
        if sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0, size < 256 {
            var bytes = [CChar](repeating: 0, count: size)
            if sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 { model = String(cString: bytes) }
        }
        let process = ProcessInfo.processInfo
        return ["os_version": process.operatingSystemVersionString,
                "hardware_model": model.map { $0 as Any } ?? NSNull(),
                "logical_cpu_count": process.processorCount, "physical_memory_bytes": process.physicalMemory,
                "uptime_seconds": process.systemUptime, "low_power_mode": process.isLowPowerModeEnabled]
    }
}
