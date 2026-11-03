import Foundation
import Darwin

@main struct DirectoryAccessTests {
    static func main() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        try TavernDirectoryAccess.check(folder)
        print("PASS: readable directory is accepted")

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        do {
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
            do {
                try TavernDirectoryAccess.check(folder)
                preconditionFailure("Inaccessible directory must be rejected")
            } catch let error as POSIXError {
                precondition(error.code == .EACCES || error.code == .EPERM)
            }
        }
        try TavernDirectoryAccess.check(folder)
        print("PASS: denial is reported and granted directory becomes usable")

        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: folder.path)
        do {
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
            do {
                try TavernDirectoryAccess.check(folder)
                preconditionFailure("Readable but non-searchable directory must be rejected")
            } catch let error as POSIXError {
                precondition(error.code == .EACCES || error.code == .EPERM)
            }
        }
        print("PASS: readable directory without search permission is rejected")

        do {
            try TavernDirectoryAccess.check(folder.appendingPathComponent("missing"))
            preconditionFailure("Missing folder must fail")
        } catch let error as POSIXError { precondition(error.code == .ENOENT) }
        print("PASS: missing directory is not a permission denial")

        let path = "/tmp/a folder/quoted\"name/проект"
        let encoded = String(data: try JSONSerialization.data(withJSONObject: path, options: .fragmentsAllowed), encoding: .utf8)!
        precondition(TavernDirectoryAccess.deniedDirectory(in: "spawn failed: TAVERN_DIRECTORY_ACCESS:" + encoded)?.path == path)
        for invalid in ["getcwd: Operation not permitted", "TAVERN_DIRECTORY_ACCESS:\"relative\"",
                        "TAVERN_DIRECTORY_ACCESS:{}", "TAVERN_DIRECTORY_ACCESS:\"/tmp/path\" trailing",
                        "TAVERN_DIRECTORY_ACCESS:\"/tmp/\\u0000\""] {
            precondition(TavernDirectoryAccess.deniedDirectory(in: invalid) == nil)
        }
        print("PASS: only well-formed absolute runtime permission errors request access")
    }
}
