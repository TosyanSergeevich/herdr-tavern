import Foundation
import Darwin

@main
struct ServerStartupTests {
    static func main() throws {
        let directory = URL(fileURLWithPath: "/tmp/tv-start-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
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
}
