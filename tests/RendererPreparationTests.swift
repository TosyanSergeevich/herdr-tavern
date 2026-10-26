import AppKit

#if !TAVERN_RENDER_TESTING
#error("RendererPreparationTests requires -D TAVERN_RENDER_TESTING")
#endif

@main struct RendererPreparationTests {
    private static func wait(_ description: String, until predicate: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: 10)
        while !predicate(), Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        }
        precondition(predicate(), "Timed out: \(description)")
    }

    private static func prepare() -> Result<Void, Error> {
        var captured: Result<Void, Error>?
        TavernCardSurfaceView.prepareResources {
            precondition(Thread.isMainThread)
            precondition(captured == nil, "Preparation completed twice")
            captured = $0
        }
        wait("resource preparation") { captured != nil }
        return captured!
    }

    private static func successfulPreparation() throws {
        if case .success = TavernCardRenderer.shared {
            preconditionFailure("Reading shared must not prepare resources")
        }
        let release = DispatchSemaphore(value: 0)
        var entered = false
        TavernCardRenderer.resourcePreparationGate = {
            precondition(!Thread.isMainThread)
            DispatchQueue.main.async { entered = true }
            precondition(release.wait(timeout: .now() + 8) == .success)
        }
        var completions = [Int]()
        var failures = [Error]()
        for index in 0..<2 {
            TavernCardSurfaceView.prepareResources { result in
                precondition(Thread.isMainThread)
                completions.append(index)
                if case .failure(let error) = result { failures.append(error) }
            }
        }
        // A queued job must use the gate captured at admission, not a mutable static hook.
        TavernCardRenderer.resourcePreparationGate = {
            preconditionFailure("Preparation started a second job or read a changed gate")
        }
        wait("worker gate entry") { entered }
        var heartbeat = false
        DispatchQueue.main.async { heartbeat = true }
        wait("main heartbeat while renderer worker is blocked") { heartbeat }
        precondition(completions.isEmpty, "Blocked preparation completed early")
        if case .success = TavernCardRenderer.shared {
            preconditionFailure("Preparing renderer was published before initialization")
        }
        release.signal()
        wait("joined preparation callbacks") { completions.count == 2 }
        precondition(completions == [0, 1], "Joined preparation must complete each waiter once")
        if let error = failures.first { throw error }
        let renderer = try TavernCardRenderer.shared.get()
        try prepare().get()
        let cachedRenderer = try TavernCardRenderer.shared.get()
        precondition(cachedRenderer === renderer)
        // Constructors are only exercised after successful publication.
        let view = TavernCardSurfaceView(frame: NSRect(x: 0, y: 0, width: 100, height: 50))
        withExtendedLifetime(view) {}
        TavernCardRenderer.resourcePreparationGate = nil
    }

    private static func cachedFailure(mode: String, pristineResources: URL) throws {
        let first = prepare()
        guard case .failure(let error) = first else {
            preconditionFailure("\(mode) unexpectedly prepared an empty/fallback renderer")
        }
        guard case .failure(let sharedError) = TavernCardRenderer.shared else {
            preconditionFailure("Failed renderer was published as ready")
        }
        precondition(sharedError.localizedDescription == error.localizedDescription)
        if mode == "missing-atlas" {
            precondition(error.localizedDescription.contains("plank-atlas.png"),
                         "Missing atlas did not report the resource error: \(error)")
        }
        if mode == "corrupt-shader" {
            precondition((error as NSError).domain == "MTLLibraryErrorDomain",
                         "Corrupt shader did not report a Metal compiler error: \(error)")
        }
        // Repair only this disposable child bundle. A retry must still return the cached error,
        // not silently rebuild resources or recover through an empty renderer.
        let resources = Bundle.main.resourceURL!
        let relative = mode == "missing-atlas"
            ? "Textures/TavernVisuals/materials/plank-atlas.png" : "Shaders/TavernCard.metal"
        let destination = resources.appendingPathComponent(relative)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: pristineResources.appendingPathComponent(relative), to: destination)
        TavernCardRenderer.resourcePreparationGate = {
            preconditionFailure("Failed preparation was started again")
        }
        guard case .failure(let cached) = prepare() else {
            preconditionFailure("Failed preparation was not cached")
        }
        precondition(cached.localizedDescription == error.localizedDescription)
        TavernCardRenderer.resourcePreparationGate = nil
    }

    private static func runChild(mode: String, baseline: URL, directory: URL) throws {
        let files = FileManager.default
        let app = directory.appendingPathComponent("\(mode).app")
        let contents = app.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        try files.createDirectory(at: macOS, withIntermediateDirectories: true)
        let executable = macOS.appendingPathComponent("RendererPreparationTests")
        try files.copyItem(at: Bundle.main.executableURL!, to: executable)
        let resources = contents.appendingPathComponent("Resources")
        try files.copyItem(at: baseline.appendingPathComponent("Contents/Resources"), to: resources)
        let info: [String: Any] = [
            "CFBundleIdentifier": "org.local.HerdrTavern.RendererPreparation.\(mode)",
            "CFBundleExecutable": "RendererPreparationTests", "CFBundlePackageType": "APPL"
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        if mode == "missing-atlas" {
            try files.removeItem(at: resources.appendingPathComponent("Textures/TavernVisuals/materials/plank-atlas.png"))
        } else if mode == "corrupt-shader" {
            try Data("This is deliberately invalid Metal source".utf8)
                .write(to: resources.appendingPathComponent("Shaders/TavernCard.metal"))
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = [baseline.path, mode]
        try process.run()
        let deadline = Date(timeIntervalSinceNow: 10)
        while process.isRunning, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        }
        if process.isRunning {
            process.terminate()
            preconditionFailure("Timed out: renderer child \(mode)")
        }
        precondition(process.terminationReason == .exit && process.terminationStatus == 0,
                     "Renderer child \(mode) failed: \(process.terminationStatus)")
    }

    static func main() throws {
        precondition(CommandLine.arguments.count >= 2, "Pass the built Tavern .app as argument 1")
        let baseline = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        if CommandLine.arguments.count > 2 {
            let mode = CommandLine.arguments[2]
            if mode == "success" {
                _ = NSApplication.shared
                try successfulPreparation()
            } else {
                precondition(mode == "missing-atlas" || mode == "corrupt-shader")
                try cachedFailure(mode: mode,
                    pristineResources: baseline.appendingPathComponent("Contents/Resources"))
            }
            print("PASS: renderer preparation \(mode)")
            return
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tavern-renderer-preparation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for mode in ["success", "corrupt-shader", "missing-atlas"] {
            try runChild(mode: mode, baseline: baseline, directory: directory)
        }
        print("PASS: renderer preparation children")
    }
}
