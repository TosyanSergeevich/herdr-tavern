import Foundation

@main
struct HerdrInstallerTests {
    private static let abc = Data("abc".utf8)
    private static let abcSHA256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    static func main() async throws {
        try await installsVerifiedExecutable()
        try await verifiesAcrossReadBoundaries()
        try await checksumMismatchPreservesConcurrentInstall()
        try await rejectsHTTPError()
        try await rejectsNonHTTPResponse()
        try await cancellationDoesNotPublish()
        try await existingExecutableSkipsDownload()
        try await preservesNonExecutableSentinel()
        try await concurrentExecutableIsNotReplaced()
        try await concurrentSentinelIsNotReplaced()
        print("HerdrInstallerTests passed")
    }

    private static func installsVerifiedExecutable() async throws {
        let fixture = try Fixture(data: abc)
        defer { fixture.remove() }
        let installer = fixture.installer()
        let result = try await installer.install()
        precondition(result == fixture.destination)
        try assertContents(result, abc)
        precondition(FileManager.default.isExecutableFile(atPath: result.path))
        try assertPermissions(result, 0o755)
        try fixture.assertClean()
        let entries = try FileManager.default.contentsOfDirectory(atPath: result.deletingLastPathComponent().path)
        precondition(entries == ["herdr"], "Only the verified executable may remain in bin")
    }

    private static func verifiesAcrossReadBoundaries() async throws {
        // Standard SHA-256 million-'a' test vector spans multiple copy/hash chunks.
        let data = Data(repeating: 0x61, count: 1_000_000)
        let fixture = try Fixture(data: data)
        defer { fixture.remove() }
        let installer = fixture.installer(sha256: "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
        let result = try await installer.install()
        try assertContents(result, data)
        try assertPermissions(result, 0o755)
        try fixture.assertClean()
    }

    private static func checksumMismatchPreservesConcurrentInstall() async throws {
        let fixture = try Fixture(data: abc)
        defer { fixture.remove() }
        let installed = Data("another installed herdr".utf8)
        let installer = fixture.installer(sha256: String(repeating: "0", count: 64)) { _ in
            try fixture.putDestination(installed, permissions: 0o751)
            return (fixture.downloadURL, fixture.http())
        }
        do {
            _ = try await installer.install()
            preconditionFailure("A checksum mismatch must not publish")
        } catch HerdrInstallerError.checksum {}
        try assertContents(fixture.destination, installed)
        try assertPermissions(fixture.destination, 0o751)
        try fixture.assertClean()
    }

    private static func rejectsHTTPError() async throws {
        let fixture = try Fixture(data: abc)
        defer { fixture.remove() }
        let installer = fixture.installer { _ in (fixture.downloadURL, fixture.http(status: 503)) }
        do {
            _ = try await installer.install()
            preconditionFailure("An HTTP error body must not be installed even when its hash matches")
        } catch HerdrInstallerError.http(let status) {
            precondition(status == 503)
        }
        precondition(!FileManager.default.fileExists(atPath: fixture.destination.path))
        try fixture.assertClean()
    }

    private static func rejectsNonHTTPResponse() async throws {
        let fixture = try Fixture(data: abc)
        defer { fixture.remove() }
        let installer = fixture.installer { _ in
            let response = URLResponse(url: fixture.release.url, mimeType: nil,
                                       expectedContentLength: abc.count, textEncodingName: nil)
            return (fixture.downloadURL, response)
        }
        do {
            _ = try await installer.install()
            preconditionFailure("A non-HTTP response must not be installed")
        } catch HerdrInstallerError.invalidResponse {}
        precondition(!FileManager.default.fileExists(atPath: fixture.destination.path))
        try fixture.assertClean()
    }

    private static func cancellationDoesNotPublish() async throws {
        let fixture = try Fixture(data: abc)
        defer { fixture.remove() }
        let installer = fixture.installer { _ in
            // Cancel after the download has produced its own file, without a timer/race.
            withUnsafeCurrentTask { $0?.cancel() }
            return (fixture.downloadURL, fixture.http())
        }
        let task = Task { try await installer.install() }
        do {
            _ = try await task.value
            preconditionFailure("A cancelled install must not publish")
        } catch is CancellationError {}
        precondition(!FileManager.default.fileExists(atPath: fixture.destination.path))
        try fixture.assertClean()
    }

    private static func existingExecutableSkipsDownload() async throws {
        let fixture = try Fixture(data: abc)
        defer { fixture.remove() }
        let installed = Data("existing executable".utf8)
        try fixture.putDestination(installed, permissions: 0o751)
        let installer = fixture.installer { _ in
            preconditionFailure("An existing executable must bypass the network")
        }
        let result = try await installer.install()
        precondition(result == fixture.destination)
        try assertContents(result, installed)
        try assertPermissions(result, 0o751)
        try assertContents(fixture.downloadURL, abc)
        try fixture.assertClean(downloadConsumed: false)
    }

    private static func preservesNonExecutableSentinel() async throws {
        let fixture = try Fixture(data: abc)
        defer { fixture.remove() }
        let sentinel = Data("not ours: do not replace".utf8)
        try fixture.putDestination(sentinel, permissions: 0o640)
        let installer = fixture.installer { _ in
            preconditionFailure("A conflicting file should be rejected before downloading")
        }
        do {
            _ = try await installer.install()
            preconditionFailure("A non-executable sentinel must cause a visible failure")
        } catch let error as POSIXError {
            precondition(error.code == .EEXIST)
        }
        try assertContents(fixture.destination, sentinel)
        try assertPermissions(fixture.destination, 0o640)
        try fixture.assertClean(downloadConsumed: false)
    }

    private static func concurrentExecutableIsNotReplaced() async throws {
        let fixture = try Fixture(data: abc)
        defer { fixture.remove() }
        let installed = Data("winner of the publication race".utf8)
        let installer = fixture.installer { _ in
            try fixture.putDestination(installed, permissions: 0o751)
            return (fixture.downloadURL, fixture.http())
        }
        let result = try await installer.install()
        precondition(result == fixture.destination)
        try assertContents(result, installed)
        try assertPermissions(result, 0o751)
        try fixture.assertClean()
    }

    private static func concurrentSentinelIsNotReplaced() async throws {
        let fixture = try Fixture(data: abc)
        defer { fixture.remove() }
        let sentinel = Data("a file appeared during download".utf8)
        let installer = fixture.installer { _ in
            try fixture.putDestination(sentinel, permissions: 0o600)
            return (fixture.downloadURL, fixture.http())
        }
        do {
            _ = try await installer.install()
            preconditionFailure("Atomic publication must not replace a concurrent sentinel")
        } catch let error as POSIXError {
            precondition(error.code == .EEXIST)
        }
        try assertContents(fixture.destination, sentinel)
        try assertPermissions(fixture.destination, 0o600)
        try fixture.assertClean()
    }

    private static func assertContents(_ url: URL, _ expected: Data) throws {
        let actual = try Data(contentsOf: url)
        precondition(actual == expected, "Unexpected file contents at \(url.path)")
    }

    private static func assertPermissions(_ url: URL, _ expected: Int) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = (attributes[.posixPermissions] as! NSNumber).intValue
        precondition(permissions == expected, "Unexpected permissions at \(url.path)")
    }

    private struct Fixture {
        let root: URL
        let downloadURL: URL
        let destination: URL

        var release: HerdrRelease {
            HerdrRelease(version: "test", url: URL(string: "https://installer.invalid/herdr")!,
                         sha256: HerdrInstallerTests.abcSHA256)
        }

        init(data: Data) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("HerdrInstallerTests-" + UUID().uuidString, isDirectory: true)
            downloadURL = root.appendingPathComponent("owned-download")
            destination = root.appendingPathComponent("bin/herdr")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            do {
                try data.write(to: downloadURL)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: downloadURL.path)
            } catch {
                try? FileManager.default.removeItem(at: root)
                throw error
            }
        }

        func installer(sha256: String = HerdrInstallerTests.abcSHA256,
                       download: ((URL) async throws -> (URL, URLResponse))? = nil) -> HerdrInstaller {
            let release = HerdrRelease(version: self.release.version, url: self.release.url, sha256: sha256)
            return HerdrInstaller(destination: destination, release: release,
                                  download: download ?? { _ in (downloadURL, http()) })
        }

        func http(status: Int = 200) -> HTTPURLResponse {
            HTTPURLResponse(url: release.url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        }

        func putDestination(_ data: Data, permissions: Int) throws {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: destination)
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: destination.path)
        }

        func assertClean(downloadConsumed: Bool = true) throws {
            let manager = FileManager.default
            precondition(manager.fileExists(atPath: downloadURL.path) != downloadConsumed,
                         "Only a download actually handed to the installer belongs to it")
            let directory = destination.deletingLastPathComponent()
            if manager.fileExists(atPath: directory.path) {
                let entries = try manager.contentsOfDirectory(atPath: directory.path)
                precondition(!entries.contains { $0.hasPrefix(".herdr-install-") }, "Staging files must be removed")
            }
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
