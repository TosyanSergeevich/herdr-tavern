import Foundation
import Darwin

/// Permission checks use filesystem APIs; terminal output is never parsed.
enum TavernDirectoryAccess {
    static let marker = "TAVERN_DIRECTORY_ACCESS:"

    enum ServerCheck: Equatable {
        case available
        case denied
        case unsupported
        case invalidResponse
        case failed(String)
    }

    static func serverCheck(response: [String: Any], id: String, path: String) -> ServerCheck {
        guard response["id"] as? String == id else { return .invalidResponse }
        if let error = response["error"] as? [String: Any] {
            switch error["code"] as? String {
            case "directory_access_denied": return .denied
            case "invalid_request", "method_not_found": return .unsupported
            default:
                if let message = error["message"] as? String { return .failed(message) }
                return .invalidResponse
            }
        }
        guard let result = response["result"] as? [String: Any],
              result["type"] as? String == "directory_access",
              result["path"] as? String == path else { return .invalidResponse }
        return .available
    }

    /// Access to a picked descendant can be implied consent, not folder-wide TCC.
    /// Probe the protected root to request the native Documents/Desktop/Downloads permission.
    static func authorizationDirectory(for directory: URL,
                                       home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let requested = directory.standardizedFileURL
        for name in ["Documents", "Desktop", "Downloads"] {
            let root = home.appendingPathComponent(name, isDirectory: true).standardizedFileURL
            if requested.path == root.path || requested.path.hasPrefix(root.path + "/") { return root }
        }
        return requested
    }

    static func deniedDirectory(in message: String) -> URL? {
        guard let range = message.range(of: marker),
              let data = message[range.upperBound...].data(using: .utf8),
              let path = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String,
              path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func check(_ url: URL) throws {
        guard let directory = opendir(url.path) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { closedir(directory) }
        errno = 0
        if readdir(directory) == nil, errno != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard access(url.path, X_OK) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(url.path, &resolved) != nil else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

