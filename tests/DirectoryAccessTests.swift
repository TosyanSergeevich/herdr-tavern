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

        let id = "folder-check"
        let success: [String: Any] = ["id": id, "result": ["type": "directory_access", "path": path]]
        precondition(TavernDirectoryAccess.serverCheck(response: success, id: id, path: path) == .available)
        print("PASS: only matching server enumeration reports server access")

        precondition(TavernDirectoryAccess.serverCheck(response: success, id: "stale", path: path) == .invalidResponse)
        precondition(TavernDirectoryAccess.serverCheck(response: success, id: id, path: "/tmp/different") == .invalidResponse)
        precondition(TavernDirectoryAccess.serverCheck(response: ["id": id, "result": [:]], id: id, path: path) == .invalidResponse)
        print("PASS: stale, wrong-directory and incomplete replies never report success")

        let denied: [String: Any] = ["id": id, "error": ["code": "directory_access_denied", "message": "denied"]]
        precondition(TavernDirectoryAccess.serverCheck(response: denied, id: id, path: path) == .denied)
        print("PASS: server denial remains denied independently of app authorization")

        let olderServer: [String: Any] = ["id": id, "error": ["code": "invalid_request", "message": "unknown method"]]
        precondition(TavernDirectoryAccess.serverCheck(response: olderServer, id: id, path: path) == .unsupported)
        print("PASS: older running servers have an honest unsupported result")

        let failed: [String: Any] = ["id": id, "error": ["code": "directory_access_failed", "message": "missing"]]
        precondition(TavernDirectoryAccess.serverCheck(response: failed, id: id, path: path) == .failed("missing"))
        print("PASS: other filesystem errors are not permission denials")

        let home = URL(fileURLWithPath: "/tmp/test-home", isDirectory: true)
        let documents = home.appendingPathComponent("Documents", isDirectory: true)
        let descendant = documents.appendingPathComponent("A project/Subfolder", isDirectory: true)
        precondition(TavernDirectoryAccess.authorizationDirectory(for: descendant, home: home) == documents)
        precondition(TavernDirectoryAccess.authorizationDirectory(for: documents, home: home) == documents)
        print("PASS: Documents root is requested even for an already-picked descendant")

        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        precondition(TavernDirectoryAccess.authorizationDirectory(for: desktop.appendingPathComponent("project"), home: home) == desktop)
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        precondition(TavernDirectoryAccess.authorizationDirectory(for: downloads.appendingPathComponent("project"), home: home) == downloads)
        print("PASS: Desktop and Downloads use their protected root")

        let similarlyNamed = home.appendingPathComponent("DocumentsElse/project", isDirectory: true)
        precondition(TavernDirectoryAccess.authorizationDirectory(for: similarlyNamed, home: home) == similarlyNamed.standardizedFileURL)
        let external = URL(fileURLWithPath: "/Volumes/External/Documents/project", isDirectory: true)
        precondition(TavernDirectoryAccess.authorizationDirectory(for: external, home: home) == external.standardizedFileURL)
        print("PASS: component-prefix lookalikes and external folders are unaffected")
    }
}
