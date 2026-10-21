import CryptoKit
import Darwin
import Foundation

struct HerdrRelease {
    let version: String
    let url: URL
    let sha256: String

    static var recommended: HerdrRelease {
        #if arch(arm64)
        return HerdrRelease(
            version: "0.9.4",
            url: URL(string: "https://github.com/herdrdev/herdr/releases/download/v0.9.4/herdr-macos-aarch64")!,
            sha256: "ea20bfff9cb8c83a996081c926e6ff9370de8e543baa859bca48d19175d895ff"
        )
        #elseif arch(x86_64)
        return HerdrRelease(
            version: "0.9.4",
            url: URL(string: "https://github.com/herdrdev/herdr/releases/download/v0.9.4/herdr-macos-x86_64")!,
            sha256: "2015ca1de3e93b84cdcccbfd94fbbd65dd56338cea4d3e57a8660e977a3bd700"
        )
        #else
        #error("The pinned herdr release supports only macOS arm64 and x86_64")
        #endif
    }
}

enum HerdrInstallerError: LocalizedError {
    case invalidResponse
    case http(Int)
    case checksum

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return L("installer.error.invalidResponse")
        case .http(let status): return L("installer.error.http", status)
        case .checksum: return L("installer.error.checksum")
        }
    }
}

final class HerdrInstaller {
    static var executableURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HerdrTavern/bin/herdr")
    }

    let destination: URL
    let release: HerdrRelease
    private let download: (URL) async throws -> (URL, URLResponse)

    init(destination: URL = HerdrInstaller.executableURL,
         release: HerdrRelease = .recommended,
         download: @escaping (URL) async throws -> (URL, URLResponse) = {
             try await URLSession.shared.download(from: $0)
         }) {
        self.destination = destination
        self.release = release
        self.download = download
    }

    func install() async throws -> URL {
        let manager = FileManager.default
        try Task.checkCancellation()
        if isExecutableFile() { return destination }
        // Do not remove or repair a pre-existing non-executable file.
        if manager.fileExists(atPath: destination.path) { throw POSIXError(.EEXIST) }

        let (downloadURL, response) = try await download(release.url)
        defer { try? manager.removeItem(at: downloadURL) }
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else {
            throw HerdrInstallerError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw HerdrInstallerError.http(response.statusCode)
        }

        let directory = destination.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        var template = Array(directory.appendingPathComponent(".herdr-install-XXXXXX").path.utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { throw posixError() }
        let stagingURL = URL(fileURLWithPath: String(cString: template))
        defer { try? manager.removeItem(at: stagingURL) }
        let staging = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? staging.close() }

        let source = try FileHandle(forReadingFrom: downloadURL)
        defer { try? source.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            guard let chunk = try source.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
            try staging.write(contentsOf: chunk)
            hash.update(data: chunk)
        }
        var expected = release.sha256.utf8.makeIterator()
        for byte in hash.finalize() {
            let high = byte >> 4, low = byte & 15
            guard expected.next() == (high < 10 ? 48 + high : 87 + high),
                  expected.next() == (low < 10 ? 48 + low : 87 + low) else {
                throw HerdrInstallerError.checksum
            }
        }
        guard expected.next() == nil else { throw HerdrInstallerError.checksum }
        guard fchmod(descriptor, 0o755) == 0 else { throw posixError() }
        try staging.close()
        try Task.checkCancellation()

        // Both paths are in the same directory. link atomically publishes the verified
        // inode, but unlike rename it can never replace a concurrent install or sentinel.
        if link(stagingURL.path, destination.path) != 0 {
            let error = posixError()
            if error.code == .EEXIST, isExecutableFile() { return destination }
            throw error
        }
        return destination
    }

    private func isExecutableFile() -> Bool {
        var directory: ObjCBool = false
        let manager = FileManager.default
        return manager.fileExists(atPath: destination.path, isDirectory: &directory)
            && !directory.boolValue && manager.isExecutableFile(atPath: destination.path)
    }

    private func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
