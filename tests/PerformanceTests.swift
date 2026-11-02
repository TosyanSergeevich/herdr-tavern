import AppKit
import Foundation
import Darwin

@main
struct PerformanceTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tavern-performance-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        boundedHistogramsAndQuantiles(root)
        presentationCadenceDoesNotEvictSlowWork(root)
        resetInvalidatesSpans(root)
        gaugeMaximaPreserveBurstsAndReset(root)
        immutableSnapshotsAndConcurrency(root)
        try privacyAndOptions(root)
        resourcesAndContext(root)
        cpuAccountingUsesSystemSeconds(root)
        snapshotLaunchAndBuildMetadata(root)
        try storageLockContention(root)
        try exportErrors(root)
        try rotationAndRestart(root)
        try mainRunLoopIdle(root)
        print("PerformanceTests passed")
    }

    private static func recorder(_ root: URL) -> TavernPerformance {
        TavernPerformance(environment: [:], directory: root)
    }
    private static func stage(_ snapshot: [String: Any], _ key: String) -> [String: Any] {
        (snapshot["stages"] as! [String: Any])[key] as! [String: Any]
    }
    private static func number(_ dictionary: [String: Any], _ key: String) -> UInt64 {
        (dictionary[key] as! NSNumber).uint64Value
    }
    private static func pump(until predicate: () -> Bool, timeout: TimeInterval = 10) {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !predicate() && ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        }
        precondition(predicate(), "Timed out waiting for recorder worker")
    }
    private static func export(_ recorder: TavernPerformance, _ url: URL) -> Result<URL, Error> {
        var result: Result<URL, Error>?
        recorder.export(to: url) {
            precondition(Thread.isMainThread)
            result = $0
        }
        pump { result != nil }
        return result!
    }
    private static func barrierAfterLifecycle(_ recorder: TavernPerformance, _ root: URL) throws {
        var result: Result<URL, Error>?
        DispatchQueue.main.async {
            recorder.export(to: root.appendingPathComponent("barrier.json")) { result = $0 }
        }
        pump { result != nil }
        _ = try result!.get()
    }

    private static func boundedHistogramsAndQuantiles(_ root: URL) {
        let recorder = recorder(root)
        for value in 1...10_000 { recorder.duration(.surfaceDraw, nanoseconds: UInt64(value)) }
        for value in 0..<100_000 { recorder.duration(.mainBusy, nanoseconds: 20_000_000 + UInt64(value)) }
        let snapshot = recorder.snapshot()
        let draw = stage(snapshot, "surfaceDraw")
        precondition(number(draw, "count") == 10_000)
        precondition(number(draw, "total_ns") == 50_005_000)
        precondition(number(draw, "max_ns") == 10_000)
        for (key, rank) in [("p50_ns", UInt64(5_000)), ("p95_ns", 9_500), ("p99_ns", 9_900)] {
            let estimate = number(draw, key)
            precondition(estimate >= rank && estimate <= min(10_000, rank + rank / 8))
        }
        let slow = snapshot["slow_samples"] as! [[String: Any]]
        precondition(slow.count == TavernPerformance.slowCapacity)
        precondition(number(slow.first!, "duration_ns") == 20_000_000 + 100_000 - UInt64(TavernPerformance.slowCapacity))
        precondition(number(slow.last!, "duration_ns") == 20_099_999)
        precondition(stage(snapshot, "rustQueueWait")["p95_ns"] is NSNull)
        recorder.count(.events, UInt64.max)
        recorder.count(.events)
        precondition(number(recorder.snapshot()["counters"] as! [String: Any], "events") == UInt64.max)
        recorder.duration(.cardGPU, nanoseconds: UInt64.max)
        recorder.duration(.cardGPU, nanoseconds: UInt64.max)
        let saturated = stage(recorder.snapshot(), "cardGPU")
        precondition(number(saturated, "total_ns") == UInt64.max)
        precondition(number(saturated, "p99_ns") == UInt64.max)
        // Fixed histograms/ring produce fixed-size records irrespective of event volume.
        precondition((try! JSONSerialization.data(withJSONObject: recorder.snapshot())).count < TavernPerformance.logFileLimit)
    }

    private static func presentationCadenceDoesNotEvictSlowWork(_ root: URL) {
        let recorder = recorder(root)
        recorder.duration(.surfaceDraw, nanoseconds: 25_000_000)
        for _ in 0..<(TavernPerformance.slowCapacity * 2) {
            recorder.duration(.nebulaPresentation, nanoseconds: 41_666_667)
            recorder.duration(.cardPresentation, nanoseconds: 33_333_333)
        }
        let snapshot = recorder.snapshot()
        let samples = snapshot["slow_samples"] as! [[String: Any]]
        precondition(samples.count == 1)
        precondition(samples[0]["stage"] as! String == "surfaceDraw")
        precondition(number(samples[0], "duration_ns") == 25_000_000)
        for key in ["nebulaPresentation", "cardPresentation"] {
            let histogram = stage(snapshot, key)
            precondition(number(histogram, "count") == UInt64(TavernPerformance.slowCapacity * 2))
            precondition(number(histogram, "p50_ns") > 0)
        }
    }

    private static func gaugeMaximaPreserveBurstsAndReset(_ root: URL) {
        let recorder = recorder(root)
        recorder.gauge(.endpointQueue, 18)
        recorder.gauge(.endpointQueue, 2)
        recorder.gauge(.writerQueue, 11)
        recorder.gauge(.writerQueue, 0)
        recorder.gauge(.endpointQueue, .infinity)
        recorder.gauge(.writerQueue, .nan)
        let snapshot = recorder.snapshot()
        let current = snapshot["gauges"] as! [String: Any]
        let maxima = snapshot["gauge_maxima"] as! [String: Any]
        precondition(number(current, "endpointQueue") == 2)
        precondition(number(current, "writerQueue") == 0)
        precondition(number(maxima, "endpointQueue") == 18)
        precondition(number(maxima, "writerQueue") == 11)
        precondition(maxima["rustQueueDepth"] is NSNull)
        recorder.reset()
        let reset = recorder.snapshot()["gauge_maxima"] as! [String: Any]
        precondition(number(reset, "endpointQueue") == 2)
        precondition(number(reset, "writerQueue") == 0)
        precondition(reset["rustQueueDepth"] is NSNull)
        recorder.gauge(.endpointQueue, 5)
        recorder.gauge(.endpointQueue, 1)
        precondition(number(recorder.snapshot()["gauge_maxima"] as! [String: Any], "endpointQueue") == 5)
        precondition(number(maxima, "endpointQueue") == 18)
    }

    private static func resetInvalidatesSpans(_ root: URL) {
        let recorder = recorder(root)
        let stale = recorder.begin(.tabSwitch)
        recorder.count(.events)
        recorder.gauge(.tabs, 7)
        recorder.reset()
        recorder.end(stale)
        let snapshot = recorder.snapshot()
        precondition(number(snapshot, "epoch") == 1)
        precondition(number(stage(snapshot, "tabSwitch"), "count") == 0)
        precondition(number(snapshot["counters"] as! [String: Any], "events") == 0)
        precondition((snapshot["slow_samples"] as! [[String: Any]]).isEmpty)
        precondition(number(snapshot["gauges"] as! [String: Any], "tabs") == 7)
        let current = recorder.begin(.inputToDraw)
        recorder.end(current)
        precondition(number(stage(recorder.snapshot(), "inputToDraw"), "count") == 1)
    }

    private static func immutableSnapshotsAndConcurrency(_ root: URL) {
        let recorder = recorder(root)
        recorder.count(.events, 2)
        let frozen = recorder.snapshot()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for _ in 0..<2_000 {
                recorder.count(.events)
                recorder.duration(.eventDecode, nanoseconds: 10)
            }
            precondition(JSONSerialization.isValidJSONObject(recorder.snapshot()))
        }
        precondition(number(frozen["counters"] as! [String: Any], "events") == 2)
        let current = recorder.snapshot()
        precondition(number(current["counters"] as! [String: Any], "events") == 16_002)
        precondition(number(stage(current, "eventDecode"), "count") == 16_000)
    }

    private static func privacyAndOptions(_ root: URL) throws {
        let privateValue = "SECRET-terminal-session-payload"
        let recorder = TavernPerformance(environment: ["UNRELATED_SECRET": privateValue], directory: root)
        recorder.gauge(.windowWidth, .nan)
        recorder.gauge(.windowHeight, .infinity)
        let snapshot = recorder.snapshot()
        precondition(snapshot["enabled"] as! Bool)
        precondition(!(snapshot["detailed"] as! Bool))
        let gauges = snapshot["gauges"] as! [String: Any]
        precondition(gauges["windowWidth"] is NSNull && gauges["windowHeight"] is NSNull)
        precondition(gauges["rustQueueDepth"] is NSNull)
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: snapshot), as: UTF8.self)
        precondition(!encoded.contains(privateValue) && !encoded.contains(root.path))
        precondition(!encoded.contains(NSUserName()))
        let detailed = TavernPerformance(environment: ["TAVERN_PERFORMANCE_DETAIL": "1"], directory: root)
        precondition(detailed.snapshot()["detailed"] as! Bool)
        let offDirectory = root.appendingPathComponent("off", isDirectory: true)
        let off = TavernPerformance(environment: ["TAVERN_PERFORMANCE": "off", "TAVERN_PERFORMANCE_DETAIL": "1"], directory: offDirectory)
        off.count(.events)
        off.duration(.surfaceDraw, nanoseconds: 999)
        off.end(off.begin(.tabSwitch))
        off.start(); off.markIncident(); off.stop()
        let result = export(off, offDirectory.appendingPathComponent("export.json"))
        guard case .failure(let error) = result else { preconditionFailure("Disabled export succeeded") }
        precondition(error as? TavernPerformance.DiagnosticError == .disabled)
        precondition(!FileManager.default.fileExists(atPath: offDirectory.path))
        precondition(number(stage(off.snapshot(), "surfaceDraw"), "count") == 0)
        precondition(!(off.snapshot()["detailed"] as! Bool))
    }

    private static func resourcesAndContext(_ root: URL) {
        let recorder = recorder(root)
        recorder.gauge(.backingScale, 2)
        let first = recorder.snapshot()
        let resource = first["resources"] as! [String: Any]
        precondition(number(resource, "sample_count") > 0)
        precondition(resource["cpu_scope"] as! String == "process_lifetime")
        precondition(resource["epoch_peak_method"] as! String == "sampled_physical_footprint")
        for key in ["cpu_seconds", "physical_footprint_bytes", "peak_physical_footprint_bytes", "disk_write_bytes", "epoch_cpu_seconds", "epoch_disk_write_bytes"] {
            precondition(resource[key] is NSNumber || resource[key] is NSNull)
            if let value = resource[key] as? NSNumber { precondition(value.doubleValue >= 0) }
        }
        if let footprint = resource["physical_footprint_bytes"] as? NSNumber {
            precondition(footprint.uint64Value > 0)
        }
        let machine = first["machine"] as! [String: Any]
        precondition(!(machine["os_version"] as! String).isEmpty)
        precondition(number(machine, "logical_cpu_count") > 0)
        precondition(number(machine, "physical_memory_bytes") > 0)
        precondition((machine["uptime_seconds"] as! NSNumber).doubleValue > 0)
        precondition(number(first["gauges"] as! [String: Any], "backingScale") == 2)
        recorder.reset()
        let after = recorder.snapshot()["resources"] as! [String: Any]
        if let lifetime = after["cpu_seconds"] as? NSNumber, let epoch = after["epoch_cpu_seconds"] as? NSNumber {
            precondition(epoch.doubleValue <= lifetime.doubleValue)
        }
    }

    private static func cpuAccountingUsesSystemSeconds(_ root: URL) {
        func systemCPU() -> Double {
            var usage = rusage()
            precondition(getrusage(RUSAGE_SELF, &usage) == 0)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        let recorder = recorder(root)
        func recordedCPU() -> Double {
            let values = recorder.snapshot()["resources"] as! [String: Any]
            return (values["cpu_seconds"] as! NSNumber).doubleValue
        }
        let systemBefore = systemCPU()
        let recordedBefore = recordedCPU()
        var sink = 0.1
        repeat {
            for index in 0..<50_000 { sink = sin(sink + Double(index)) }
        } while systemCPU() - systemBefore < 0.1
        let recordedDelta = recordedCPU() - recordedBefore
        let systemDelta = systemCPU() - systemBefore
        // Compare independent kernel APIs, not wall time or a machine-specific tick rate.
        print("CPU accounting: recorder=\(recordedDelta), getrusage=\(systemDelta), sink=\(sink)")
        precondition(abs(recordedDelta - systemDelta) < max(0.01, systemDelta * 0.15),
                     "CPU counters were not converted to seconds")
    }

    private static func snapshotLaunchAndBuildMetadata(_ root: URL) {
        let recorder = recorder(root)
        let first = recorder.snapshot()
        let identity = first["instance_id"] as! String
        precondition(UUID(uuidString: identity) != nil)
        let recorded = (first["recorded_at_unix_seconds"] as! NSNumber).doubleValue
        precondition(abs(Date().timeIntervalSince1970 - recorded) < 10)
        recorder.reset()
        precondition(recorder.snapshot()["instance_id"] as! String == identity)
        precondition(self.recorder(root).snapshot()["instance_id"] as! String != identity)
        let app = first["app"] as! [String: Any]
        precondition(Set(app.keys) == Set(["version", "build", "source_digest"]))
        for key in ["version", "build", "source_digest"] {
            precondition(app[key] is String || app[key] is NSNull)
        }
        if let digest = app["source_digest"] as? String {
            precondition(digest.utf8.count == 64)
            precondition(digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) })
        }
    }

    private static func storageLockContention(_ root: URL) throws {
        let directory = root.appendingPathComponent("contended", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = Darwin.open(directory.appendingPathComponent(".storage.lock").path,
                                     O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        precondition(descriptor >= 0)
        defer { Darwin.close(descriptor) }
        precondition(tavernPerformanceFileLock(descriptor, LOCK_EX | LOCK_NB) == 0)
        let recorder = recorder(directory)
        recorder.markIncident()
        _ = try export(recorder, root.appendingPathComponent("contention-barrier.json")).get()
        precondition(number(recorder.snapshot(), "storage_failures") == 1)
        precondition(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("incident-0.json").path))
        precondition(tavernPerformanceFileLock(descriptor, LOCK_UN) == 0)
        recorder.markIncident()
        _ = try export(recorder, root.appendingPathComponent("unlocked-barrier.json")).get()
        precondition(FileManager.default.fileExists(atPath: directory.appendingPathComponent("incident-0.json").path))
        precondition(number(recorder.snapshot(), "storage_failures") == 1)
    }

    private static func exportErrors(_ root: URL) throws {
        let recorder = recorder(root)
        let url = root.appendingPathComponent("export.json")
        _ = try export(recorder, url).get()
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        precondition(number(json, "schema_version") == 1)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber
        precondition(permissions.intValue & 0o777 == 0o600)
        guard case .failure(let remoteError) = export(recorder, URL(string: "https://example.invalid/export")!) else {
            preconditionFailure("Remote destination accepted")
        }
        precondition(remoteError as? TavernPerformance.DiagnosticError == .invalidDestination)
        guard case .failure(let missingError) = export(recorder, root.appendingPathComponent("absent/out.json")) else {
            preconditionFailure("Missing parent silently created")
        }
        precondition(missingError as? TavernPerformance.DiagnosticError == .writeFailed)
        let blockedDirectory = root.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: blockedDirectory)
        let blocked = self.recorder(blockedDirectory)
        blocked.markIncident()
        _ = try export(blocked, root.appendingPathComponent("blocked-barrier.json")).get()
        precondition(number(blocked.snapshot(), "storage_failures") == 1)
    }

    private static func rotationAndRestart(_ root: URL) throws {
        let directory = root.appendingPathComponent("retention", isDirectory: true)
        var recorder = self.recorder(directory)
        for value in 0..<TavernPerformance.slowCapacity {
            recorder.duration(.surfaceDraw, nanoseconds: 20_000_000 + UInt64(value))
        }
        for iteration in 0..<100 {
            recorder.start(); recorder.start(); recorder.stop(); recorder.stop()
            try barrierAfterLifecycle(recorder, root)
            if iteration == 49 {
                // A fresh recorder resumes a directory with existing slots, not a new unbounded file.
                recorder = self.recorder(directory)
                for _ in 0..<TavernPerformance.slowCapacity { recorder.duration(.surfaceDraw, nanoseconds: 20_000_000) }
            }
        }
        for _ in 0..<8 {
            recorder.markIncident()
            _ = try export(recorder, root.appendingPathComponent("incident-barrier.json")).get()
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        precondition(files.count == TavernPerformance.logFileCount + TavernPerformance.incidentFileCount + 1)
        var total = 0
        for file in files {
            if file.lastPathComponent == ".storage.lock" {
                let lockData = try Data(contentsOf: file)
                precondition(lockData.isEmpty)
                continue
            }
            let data = try Data(contentsOf: file)
            total += data.count
            precondition(data.count <= TavernPerformance.logFileLimit)
            if file.pathExtension == "jsonl" {
                for line in data.split(separator: 0x0a) { _ = try JSONSerialization.jsonObject(with: Data(line)) }
            } else { _ = try JSONSerialization.jsonObject(with: data) }
        }
        precondition(total <= (TavernPerformance.logFileCount + TavernPerformance.incidentFileCount) * TavernPerformance.logFileLimit)
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as! NSNumber
        precondition(permissions.intValue & 0o777 == 0o700)
    }

    private static func mainRunLoopIdle(_ root: URL) throws {
        let recorder = self.recorder(root.appendingPathComponent("idle", isDirectory: true))
        recorder.start()
        var started = false
        DispatchQueue.main.async { started = true }
        pump { started }
        recorder.reset()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
        let idle = stage(recorder.snapshot(), "mainBusy")
        // Waiting in CFRunLoop is not a 150 ms main-thread hang.
        precondition(number(idle, "max_ns") < 100_000_000)
        var blocked = false
        DispatchQueue.main.async {
            Thread.sleep(forTimeInterval: 0.035)
            blocked = true
        }
        pump { blocked }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        precondition(number(stage(recorder.snapshot(), "mainBusy"), "max_ns") >= 30_000_000)
        recorder.stop()
        try barrierAfterLifecycle(recorder, root)
        precondition(number(recorder.snapshot(), "main_busy_current_ns") == 0)
    }
}
