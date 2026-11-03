import Foundation
import Darwin

/// Only runtime permission failures enter this flow; terminal output is never parsed.
enum TavernDirectoryAccess {
    static let marker = "TAVERN_DIRECTORY_ACCESS:"

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

