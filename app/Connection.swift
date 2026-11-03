import Foundation
import CoreGraphics
import Darwin

// Apache-2.0: native rendering and input behavior adapted from the herdr surface
// research for upstream revision 2563803dca97c040beaf3dc3acdcb5a3221b4238.
enum NativeError: Error, LocalizedError {
    case message(String)
    case herdrNotFound
    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .herdrNotFound: return L("core.launch.herdrNotFound")
        }
    }
}
func ownedString(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
    guard let pointer else { return L("core.connection.unknownError") }
    defer { tavern_string_free(pointer) }
    return String(cString: pointer)
}
func bytesData(_ bytes: TavernBytes) -> Data {
    guard bytes.len > 0, let pointer = bytes.ptr else { return Data() }
    return Data(bytes: pointer, count: bytes.len)
}
func bytesString(_ bytes: TavernBytes) -> String {
    guard let pointer = bytes.ptr, bytes.len > 0 else { return "" }
    return String(decoding: UnsafeBufferPointer(start: pointer, count: bytes.len), as: UTF8.self)
}
struct NativeEvent {
    let kind: UInt32
    let metadata: [String: Any]
    let segments: [CellSegment]
    let popupSegments: [CellSegment]
    let images: [String: CGImage]
    let navigationPresentation: TavernNavigationPresentation?
    init(taking event: OpaquePointer) throws {
        // All borrowed buffers are copied while the event is alive. Release the
        // native allocation before potentially expensive raster preparation.
        let copied: (UInt32, [String: Any], [CellSegment], [CellSegment], [GraphicAsset]) = try {
            defer { tavern_event_free(event) }
            let kind = tavern_event_kind(event)
            let data = bytesData(tavern_event_json(event))
            guard let metadata = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NativeError.message(L("core.connection.invalidMetadata"))
            }
            var main: [CellSegment] = [], popup: [CellSegment] = []
            for index in 0..<tavern_event_segment_count(event) {
                var segment = TavernSegment()
                guard tavern_event_segment(event, index, &segment) == 0 else { throw NativeError.message(L("core.connection.unavailableSegment")) }
                var cells: [TerminalCell] = []
                cells.reserveCapacity(segment.count)
                for offset in 0..<segment.count {
                    var cell = TavernCell()
                    guard tavern_event_cell(event, index, offset, &cell) == 0 else { throw NativeError.message(L("core.connection.unavailableCell")) }
                    cells.append(TerminalCell(symbol: bytesString(cell.symbol), foreground: cell.fg, background: cell.bg,
                                              modifier: cell.modifier, skip: cell.skip != 0,
                                              hyperlink: cell.hyperlink_present != 0 ? cell.hyperlink : nil))
                }
                let span = CellSegment(x: Int(segment.x), y: Int(segment.y), cells: cells)
                if segment.target == 0 { main.append(span) }
                else if segment.target == 1 { popup.append(span) }
                else { throw NativeError.message(L("core.connection.unknownSurface")) }
            }
            var graphics: [GraphicAsset] = []
            for index in 0..<tavern_event_asset_count(event) {
                var asset = TavernAsset()
                guard tavern_event_asset(event, index, &asset) == 0 else { throw NativeError.message(L("core.connection.unavailableAsset")) }
                graphics.append(GraphicAsset(id: bytesString(asset.id), width: Int(asset.width), height: Int(asset.height),
                                             format: Int(asset.format), data: bytesData(asset.data)))
            }
            return (kind, metadata, main, popup, graphics)
        }()
        kind = copied.0; metadata = copied.1
        segments = copied.2; popupSegments = copied.3
        var prepared: [String: CGImage] = [:]
        for asset in copied.4 { prepared[asset.id] = try GraphicAssetDecoder.decode(asset) }
        images = prepared
        navigationPresentation = kind == UInt32(TAVERN_SNAPSHOT) ? TavernNavigationPresentation(snapshot: metadata) : nil
    }
}

final class RustConnection {
    private let pointer: OpaquePointer
    private let writer = DispatchQueue(label: "org.local.HerdrTavern.writer", qos: .userInitiated)
    private let calls = DispatchGroup()
    private let lock = NSLock()
    private var closing = false
    private struct PendingWrite {
        var command: [String: Any]
        var completions: [(Error?) -> Void]
        let queuedAt: UInt64
    }
    private var pendingWrites: [PendingWrite?] = []
    private var writeHead = 0
    private var draining = false
    #if TAVERN_RENDER_TESTING
    var beforeWriterDrain: (() -> Void)?
    var beforeWriterSerialization: (([String: Any]) -> Void)?
    #endif
    private let receive: (Result<NativeEvent, Error>) -> Void
    init(pointer: OpaquePointer, receive: @escaping (Result<NativeEvent, Error>) -> Void) {
        self.pointer = pointer; self.receive = receive
        calls.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { calls.leave() }
            var receiving = true
            while receiving {
                // Foundation создаёт временные объекты; worker живёт всё соединение.
                receiving = autoreleasepool {
                    var event: OpaquePointer?, error: UnsafeMutablePointer<CChar>?
                    let result = tavern_client_next_event(pointer, 1000, &event, &error)
                    if result == 0 { return true }
                    if result == 2 { return false }
                    if result < 0 {
                        let message = ownedString(error)
                        DispatchQueue.main.sync { receive(.failure(NativeError.message(message))) }
                        return false
                    }
                    guard let event else {
                        DispatchQueue.main.sync { receive(.failure(NativeError.message(L("core.connection.emptyEvent")))) }
                        return false
                    }
                    let decoded: Result<NativeEvent, Error>
                    let decodeSpan = TavernPerformance.shared.begin(.eventDecode)
                    do { decoded = .success(try NativeEvent(taking: event)) } catch { decoded = .failure(error) }
                    TavernPerformance.shared.end(decodeSpan)
                    let handoffStarted = DispatchTime.now().uptimeNanoseconds
                    // Bounded hand-off: reader never queues unbounded full surfaces. No UI
                    // thread waits for this worker; detach interrupts next_event separately.
                    DispatchQueue.main.sync {
                        TavernPerformance.shared.duration(.mainHandoff, nanoseconds: DispatchTime.now().uptimeNanoseconds - handoffStarted)
                        receive(decoded)
                    }
                    return true
                }
            }
            close()
        }
    }
    // Swift value collections share immutable storage until changed. Copy only
    // paths containing reference-backed Foundation values before admission.
    private static func ownedValue(_ value: Any) -> Any? {
        if type(of: value) is AnyClass {
            if let string = value as? NSMutableString { return string.copy() as! NSString }
            if let data = value as? NSMutableData { return Data(bytes: data.bytes, count: data.length) }
            if let dictionary = value as? NSDictionary {
                var result: [AnyHashable: Any] = [:]
                result.reserveCapacity(dictionary.count)
                for (key, child) in dictionary {
                    result[key as! AnyHashable] = ownedValue(child) ?? child
                }
                return NSDictionary(dictionary: result)
            }
            if let array = value as? NSArray { return array.map { ownedValue($0) ?? $0 } }
            return nil
        }
        if type(of: value) == [String].self || type(of: value) == [String: String].self { return nil }
        if let dictionary = value as? [String: Any] {
            var result: [String: Any]?
            for (key, child) in dictionary {
                if let owned = ownedValue(child) {
                    if result == nil { result = dictionary }
                    result?[key] = owned
                }
            }
            return result
        }
        if let array = value as? [Any] {
            var result: [Any]?
            for (index, child) in array.enumerated() {
                if let owned = ownedValue(child) {
                    if result == nil { result = array }
                    result?[index] = owned
                }
            }
            return result
        }
        return nil
    }

    private static func complete(_ callbacks: [(Error?) -> Void], with error: Error?) {
        DispatchQueue.main.async { for callback in callbacks { callback(error) } }
    }

    func send(_ command: [String: Any], completion: @escaping (Error?) -> Void) {
        let captured = Self.ownedValue(command) as? [String: Any] ?? command
        lock.lock()
        guard !closing else {
            lock.unlock()
            Self.complete([completion], with: NativeError.message(L("core.connection.closed")))
            return
        }
        let last = pendingWrites.count - 1
        if last >= writeHead, string(captured["type"]) == "resize",
           string(pendingWrites[last]?.command["type"]) == "resize" {
            pendingWrites[last]?.command = captured
            pendingWrites[last]?.completions.append(completion)
        } else {
            pendingWrites.append(PendingWrite(command: captured, completions: [completion],
                                             queuedAt: DispatchTime.now().uptimeNanoseconds))
        }
        TavernPerformance.shared.gauge(.writerQueue, Double(pendingWrites.count - writeHead))
        if !draining {
            draining = true
            calls.enter()
            #if TAVERN_RENDER_TESTING
            let drainGate = beforeWriterDrain
            let serializationGate = beforeWriterSerialization
            #endif
            writer.async { [self] in
                defer { calls.leave() }
                #if TAVERN_RENDER_TESTING
                drainGate?()
                #endif
                while true {
                    lock.lock()
                    guard !closing, writeHead < pendingWrites.count else {
                        pendingWrites.removeAll(keepingCapacity: true)
                        writeHead = 0; draining = false
                        TavernPerformance.shared.gauge(.writerQueue, 0)
                        lock.unlock()
                        return
                    }
                    let entry = pendingWrites[writeHead]!
                    pendingWrites[writeHead] = nil
                    writeHead += 1
                    if writeHead >= 256 && writeHead >= pendingWrites.count - writeHead {
                        pendingWrites.removeFirst(writeHead)
                        writeHead = 0
                    }
                    TavernPerformance.shared.gauge(.writerQueue, Double(pendingWrites.count - writeHead))
                    lock.unlock()
                    TavernPerformance.shared.duration(.writerQueueWait, nanoseconds: DispatchTime.now().uptimeNanoseconds - entry.queuedAt)
                    let failure: Error? = autoreleasepool {
                        #if TAVERN_RENDER_TESTING
                        serializationGate?(entry.command)
                        #endif
                        lock.lock(); let closedBeforeEncoding = closing; lock.unlock()
                        guard !closedBeforeEncoding else { return NativeError.message(L("core.connection.closed")) }
                        do {
                            let data: Data = try {
                                let encodeSpan = TavernPerformance.shared.begin(.writerEncode)
                                defer { TavernPerformance.shared.end(encodeSpan) }
                                // Reject unsupported objects before Foundation can raise an exception.
                                guard JSONSerialization.isValidJSONObject(entry.command) else {
                                    throw CocoaError(.propertyListWriteInvalid)
                                }
                                return try JSONSerialization.data(withJSONObject: entry.command)
                            }()
                            lock.lock(); let closedBeforeSending = closing; lock.unlock()
                            guard !closedBeforeSending else { return NativeError.message(L("core.connection.closed")) }
                            var error: UnsafeMutablePointer<CChar>?
                            let sendSpan = TavernPerformance.shared.begin(.wireSend)
                            let result = data.withUnsafeBytes { bytes in
                                tavern_client_send_json(pointer, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &error)
                            }
                            TavernPerformance.shared.end(sendSpan)
                            return result == 0 ? nil : NativeError.message(ownedString(error))
                        } catch { return error }
                    }
                    Self.complete(entry.completions, with: failure)
                }
            }
        }
        lock.unlock()
    }

    func close() {
        lock.lock()
        guard !closing else { lock.unlock(); return }
        closing = true
        var abandoned: [(Error?) -> Void] = []
        for entry in pendingWrites[writeHead...] { if let entry { abandoned.append(contentsOf: entry.completions) } }
        pendingWrites.removeAll()
        writeHead = 0
        TavernPerformance.shared.gauge(.writerQueue, 0)
        calls.enter()
        lock.unlock()
        if !abandoned.isEmpty { Self.complete(abandoned, with: NativeError.message(L("core.connection.closed"))) }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            tavern_client_close(pointer); calls.leave()
        }
        calls.notify(queue: .global(qos: .utility)) { [pointer] in tavern_client_free(pointer) }
    }
    static func open(path: String, cols: Int, rows: Int, cellWidth: Int, cellHeight: Int) throws -> OpaquePointer {
        var error: UnsafeMutablePointer<CChar>?
        let pointer = path.withCString { tavern_client_open($0, UInt16(cols), UInt16(rows), UInt32(cellWidth), UInt32(cellHeight), &error) }
        guard let pointer else { throw NativeError.message(ownedString(error)) }
        return pointer
    }
    static func publicRequest(path: String, request: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: request)
        var response: UnsafeMutablePointer<CChar>?, error: UnsafeMutablePointer<CChar>?
        let result = path.withCString { path in
            data.withUnsafeBytes { bytes in
                tavern_public_json(path, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &response, &error)
            }
        }
        guard result == 0, let response else { throw NativeError.message(ownedString(error)) }
        let raw = ownedString(response)
        guard let json = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
            throw NativeError.message(L("core.connection.invalidAPIResponse"))
        }
        return json
    }
}

struct LaunchOptions {
    let socketPath: String
    let publicSocketPath: String
    let connectOnly: Bool
    let herdrPath: String?
    let session: String?
    #if DEBUG
    static let runtimeDirectoryName = "herdr-tavern-dev"
    #else
    static let runtimeDirectoryName = "herdr-tavern"
    #endif

    static var bundledExecutableURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/herdr-tavern")
    }

    static func runtimeEnvironment(_ inherited: [String: String],
                                   helpersDirectory: String = bundledExecutableURL.deletingLastPathComponent().path) -> [String: String] {
        var environment = inherited.filter { !$0.key.hasPrefix("HERDR_") || $0.key.hasPrefix("HERDR_TAVERN_") }
        let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        var directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        directories.removeAll { $0 == helpersDirectory }
        directories.insert(helpersDirectory, at: 0)
        for directory in [home + "/.cargo/bin", "/opt/homebrew/bin", "/usr/local/bin"] {
            if !directories.contains(directory) { directories.append(directory) }
        }
        environment["PATH"] = directories.joined(separator: ":")
        environment["PI_FORCE_IMAGE_PROTOCOL"] = "kitty"
        return environment
    }

    static var serverEnvironment: [String: String] { runtimeEnvironment(ProcessInfo.processInfo.environment) }

    static func configURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment["HERDR_TAVERN_CONFIG_PATH"] { return URL(fileURLWithPath: path) }
        return configDirectory(environment: environment).appendingPathComponent("config.toml")
    }

    private static func configDirectory(environment: [String: String]) -> URL {
        let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        return URL(fileURLWithPath: environment["XDG_CONFIG_HOME"] ?? home + "/.config")
            .appendingPathComponent(runtimeDirectoryName)
    }

    static func parse(_ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) throws -> LaunchOptions {
        var socket: String?, executable: String?, session: String?
        var index = 1
        while index < arguments.count {
            let option = arguments[index]
            if option.hasPrefix("-psn_") { index += 1; continue }
            guard ["--socket", "--herdr-tavern", "--session"].contains(option), index + 1 < arguments.count else {
                throw NativeError.message(L("core.launch.arguments"))
            }
            let value = arguments[index + 1]
            guard !value.isEmpty else { throw NativeError.message(L("core.launch.emptyValue", option)) }
            switch option { case "--socket": socket = value; case "--herdr-tavern": executable = value; default: session = value }
            index += 2
        }
        let selectedSession = session ?? (socket == nil && environment["HERDR_TAVERN_SOCKET_PATH"] == nil ? environment["HERDR_TAVERN_SESSION"] : nil)
        if let name = selectedSession {
            guard !name.isEmpty, name.utf8.count <= 64, name.unicodeScalars.allSatisfy({ scalar in
                scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "_-".unicodeScalars.contains(scalar))
            }) else { throw NativeError.message(L("core.launch.invalidSession")) }
        }
        var directory = configDirectory(environment: environment)
        if let name = selectedSession, name != "default" { directory.appendPathComponent("sessions"); directory.appendPathComponent(name) }
        let api: String
        let client: String
        if let socket {
            client = NSString(string: socket).expandingTildeInPath
            let url = URL(fileURLWithPath: client)
            let stem = url.deletingPathExtension().lastPathComponent
            let apiStem = stem.hasSuffix("-client") ? String(stem.dropLast(7)) : "herdr-tavern"
            api = url.deletingLastPathComponent().appendingPathComponent(apiStem + ".sock").path
        } else if session == nil, let override = environment["HERDR_TAVERN_SOCKET_PATH"] {
            api = override
            let url = URL(fileURLWithPath: override)
            client = url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-client" + (url.pathExtension.isEmpty ? "" : "." + url.pathExtension)).path
        } else {
            api = directory.appendingPathComponent("herdr-tavern.sock").path
            client = session == nil ? environment["HERDR_TAVERN_CLIENT_SOCKET_PATH"] ?? directory.appendingPathComponent("herdr-tavern-client.sock").path : directory.appendingPathComponent("herdr-tavern-client.sock").path
        }
        return LaunchOptions(socketPath: client, publicSocketPath: api, connectOnly: socket != nil, herdrPath: executable, session: selectedSession)
    }
    func resolveExecutable(bundledURL: URL = LaunchOptions.bundledExecutableURL) throws -> String {
        let manager = FileManager.default
        func isExecutableFile(_ path: String) -> Bool {
            var isDirectory: ObjCBool = false
            return manager.fileExists(atPath: path, isDirectory: &isDirectory)
                && !isDirectory.boolValue && manager.isExecutableFile(atPath: path)
        }
        if let herdrPath {
            let path = NSString(string: herdrPath).expandingTildeInPath
            guard isExecutableFile(path) else { throw NativeError.message(L("core.launch.notExecutable", path)) }
            return path
        }
        guard isExecutableFile(bundledURL.path) else { throw NativeError.herdrNotFound }
        return bundledURL.path
    }
    private func serverIsListening() throws -> Bool {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = socketPath.utf8CString
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            path.withUnsafeBytes { destination.copyBytes(from: $0) }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { return true }
        let code = errno
        if code == ENOENT || code == ECONNREFUSED { return false }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    func ensureServer(logDirectory: URL? = nil) throws {
        guard !connectOnly else { return }
        guard try !serverIsListening() else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try resolveExecutable())
        var environment = Self.serverEnvironment
        environment["HERDR_TAVERN_SOCKET_PATH"] = publicSocketPath
        environment["HERDR_TAVERN_CLIENT_SOCKET_PATH"] = socketPath
        environment.removeValue(forKey: "HERDR_TAVERN_SESSION")
        process.environment = environment
        process.arguments = ["server"] + (session.map { ["--session", $0] } ?? [])
        process.standardInput = FileHandle.nullDevice
        let logs = logDirectory ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/HerdrTavern", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let logURL = logs.appendingPathComponent("server.log")
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: logURL)
        let startupOffset = try handle.seekToEnd()
        defer { try? handle.close() }
        process.standardOutput = handle; process.standardError = handle
        try process.run()
        // Only initial socket readiness is awaited. No mutation or failed handshake
        // is retried; a server started here remains alive after the window detaches.
        let deadline = DispatchTime.now() + .seconds(15)
        repeat {
            if try serverIsListening() { return }
            guard process.isRunning, DispatchTime.now() < deadline else { break }
            Thread.sleep(forTimeInterval: 0.05)
        } while true
        // Inspect only this launch's bounded log tail, never a previous server failure.
        if let reader = try? FileHandle(forReadingFrom: logURL) {
            defer { try? reader.close() }
            let end = (try? reader.seekToEnd()) ?? startupOffset
            try? reader.seek(toOffset: max(startupOffset, end > 65536 ? end - 65536 : 0))
            if let data = try? reader.readToEnd(), let text = String(data: data, encoding: .utf8),
               let line = text.components(separatedBy: .newlines).last(where: {
                   TavernDirectoryAccess.deniedDirectory(in: $0) != nil
               }) {
                throw NativeError.message(line)
            }
        }
        throw NativeError.message(L("core.launch.socketTimeout", logURL.path))
    }
}
