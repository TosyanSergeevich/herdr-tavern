import Foundation
import Darwin

@main
struct ServerStartupTests {
    static func main() throws {
        let directory = URL(fileURLWithPath: "/tmp/tv-start-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try namespaceRouting()
        try executableResolution(in: directory)
        try failedStartup(in: directory)
        let path = directory.appendingPathComponent("client.sock").path
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        precondition(descriptor >= 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = path.utf8CString
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { destination.copyBytes(from: $0) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        precondition(bound == 0)
        precondition(Darwin.listen(descriptor, 8) == 0)
        let options = LaunchOptions(socketPath: path, publicSocketPath: path + ".api", connectOnly: false,
                                    herdrPath: directory.appendingPathComponent("missing-herdr").path, session: nil)
        // A live server must be reused even when no executable is available.
        try options.ensureServer()
        precondition(fcntl(descriptor, F_GETFD) >= 0)
        print("PASS: live server reused without launching a replacement")
        Darwin.close(descriptor)
        precondition(FileManager.default.fileExists(atPath: path))
        // A dead socket must enter startup, not report success based on the file.
        var attemptedStartup = false
        do { try options.ensureServer() }
        catch NativeError.message { attemptedStartup = true }
        precondition(attemptedStartup, "Stale socket incorrectly treated as a running server")
        print("PASS: stale socket triggers executable resolution")
        let connectOnly = LaunchOptions(socketPath: path, publicSocketPath: path + ".api", connectOnly: true,
                                        herdrPath: options.herdrPath, session: nil)
        try connectOnly.ensureServer()
        precondition(FileManager.default.fileExists(atPath: path))
        print("PASS: connect-only mode leaves stale socket untouched")
        let tooLong = LaunchOptions(socketPath: String(repeating: "x", count: 200), publicSocketPath: "", connectOnly: false,
                                   herdrPath: options.herdrPath, session: nil)
        do {
            try tooLong.ensureServer()
            preconditionFailure("Oversized socket path accepted")
        } catch let error as POSIXError {
            precondition(error.code == .ENAMETOOLONG)
        }
        print("PASS: oversized socket path rejected safely")
    }

    private static func namespaceRouting() throws {
        let inherited = [
            "HOME": "/tmp/tavern-home", "XDG_CONFIG_HOME": "/tmp/tavern-config",
            "PATH": "/tmp/system-herdr:/usr/bin", "HERDR_SESSION": "foreign",
            "HERDR_SOCKET_PATH": "/tmp/foreign.sock", "HERDR_CLIENT_SOCKET_PATH": "/tmp/foreign-client.sock",
            "HERDR_CONFIG_PATH": "/tmp/foreign.toml", "HERDR_STATE_PATH": "/tmp/foreign-state.json"
        ]
        let options = try LaunchOptions.parse(["Tavern"], environment: inherited)
        let root = "/tmp/tavern-config/" + LaunchOptions.runtimeDirectoryName
        precondition(options.session == nil && !options.connectOnly)
        precondition(options.publicSocketPath == root + "/herdr-tavern.sock")
        precondition(options.socketPath == root + "/herdr-tavern-client.sock")
        precondition(LaunchOptions.configURL(environment: inherited).path == root + "/config.toml")
        let child = LaunchOptions.runtimeEnvironment(inherited, helpersDirectory: "/tmp/Tavern.app/Contents/Helpers")
        precondition(child.keys.allSatisfy { !$0.hasPrefix("HERDR_") })
        precondition(child["PATH"]?.components(separatedBy: ":").first == "/tmp/Tavern.app/Contents/Helpers")
        precondition(child["HOME"] == inherited["HOME"])
        var selected = inherited
        selected["HERDR_TAVERN_SESSION"] = "my-session"
        selected["HERDR_TAVERN_CONFIG_PATH"] = "/tmp/tavern-custom.toml"
        selected["HERDR_TAVERN_STATE_PATH"] = "/tmp/tavern-state.json"
        let session = try LaunchOptions.parse(["Tavern"], environment: selected)
        precondition(session.session == "my-session")
        precondition(session.socketPath == root + "/sessions/my-session/herdr-tavern-client.sock")
        precondition(LaunchOptions.configURL(environment: selected).path == "/tmp/tavern-custom.toml")
        precondition(LaunchOptions.runtimeEnvironment(selected)["HERDR_TAVERN_STATE_PATH"] == "/tmp/tavern-state.json")
        selected["HERDR_TAVERN_SOCKET_PATH"] = "/tmp/tavern-custom.sock"
        let overridden = try LaunchOptions.parse(["Tavern"], environment: selected)
        precondition(overridden.session == nil && !overridden.connectOnly)
        precondition(overridden.publicSocketPath == "/tmp/tavern-custom.sock")
        precondition(overridden.socketPath == "/tmp/tavern-custom-client.sock")
        let explicit = try LaunchOptions.parse(["Tavern", "--session", "explicit"], environment: selected)
        precondition(explicit.socketPath == root + "/sessions/explicit/herdr-tavern-client.sock")
        let connected = try LaunchOptions.parse(["Tavern", "--socket", "/tmp/external-client.sock"], environment: selected)
        precondition(connected.connectOnly && connected.session == nil)
        precondition(connected.publicSocketPath == "/tmp/external.sock")
        print("PASS: runtime namespace, config, session and environment isolation")
    }

    private static func executableResolution(in directory: URL) throws {
        let bundled = directory.appendingPathComponent("Contents/Helpers/herdr-tavern")
        try FileManager.default.createDirectory(at: bundled.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: bundled)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundled.path)
        let options = try LaunchOptions.parse(["Tavern"], environment: [:])
        let resolvedDefault = try options.resolveExecutable(bundledURL: bundled)
        precondition(resolvedDefault == bundled.path)
        do {
            _ = try options.resolveExecutable(bundledURL: directory.appendingPathComponent("missing-bundled-runtime"))
            preconditionFailure("Missing bundled runtime accepted")
        } catch NativeError.herdrNotFound {}
        let explicit = try LaunchOptions.parse(["Tavern", "--herdr-tavern", bundled.path], environment: [:])
        let resolvedExplicit = try explicit.resolveExecutable(bundledURL: directory.appendingPathComponent("missing"))
        precondition(resolvedExplicit == bundled.path)
        let invalid = try LaunchOptions.parse(["Tavern", "--herdr-tavern", directory.appendingPathComponent("invalid").path], environment: [:])
        do {
            _ = try invalid.resolveExecutable(bundledURL: bundled)
            preconditionFailure("Invalid explicit path fell back to bundle")
        } catch NativeError.message {}
        let directoryOption = try LaunchOptions.parse(["Tavern", "--herdr-tavern", directory.path], environment: [:])
        do {
            _ = try directoryOption.resolveExecutable(bundledURL: bundled)
            preconditionFailure("Directory accepted as explicit executable")
        } catch NativeError.message {}
        do {
            _ = try LaunchOptions.parse(["Tavern", "--herdr", bundled.path], environment: [:])
            preconditionFailure("Removed --herdr alias accepted")
        } catch NativeError.message {}
        print("PASS: bundled-only default and strict explicit executable")
    }

    private static func failedStartup(in directory: URL) throws {
        let executable = directory.appendingPathComponent("failed-runtime")
        let captured = directory.appendingPathComponent("environment")
        let script = """
        #!/bin/sh
        /usr/bin/env > '\(captured.path)'
        exit 23
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let options = LaunchOptions(socketPath: directory.appendingPathComponent("failed-client.sock").path,
                                    publicSocketPath: directory.appendingPathComponent("failed.sock").path,
                                    connectOnly: false, herdrPath: executable.path, session: "test")
        do {
            try options.ensureServer(logDirectory: directory.appendingPathComponent("logs"))
            preconditionFailure("Runtime exiting before readiness reported startup success")
        } catch NativeError.message {}
        let environment = try String(contentsOf: captured, encoding: .utf8)
        precondition(environment.contains("HERDR_TAVERN_SOCKET_PATH=" + options.publicSocketPath))
        precondition(environment.contains("HERDR_TAVERN_CLIENT_SOCKET_PATH=" + options.socketPath))
        precondition(!environment.contains("\nHERDR_SOCKET_PATH="))
        precondition(!environment.contains("\nHERDR_TAVERN_SESSION="))
        print("PASS: early runtime exit fails with exact socket routing")
    }
}
