import Foundation

// One public subscription reader, with a bounded synchronous hand-off to UI.
final class AgentTitleFeed {
    private let pointer: OpaquePointer
    private let calls = DispatchGroup()
    private let lock = NSLock()
    private var closing = false
    private let receive: (Result<[String: Any], Error>) -> Void

    static func open(path: String) throws -> OpaquePointer {
        var error: UnsafeMutablePointer<CChar>?
        let pointer = path.withCString { tavern_title_feed_open($0, &error) }
        guard let pointer else { throw NativeError.message(ownedString(error)) }
        return pointer
    }

    init(pointer: OpaquePointer, receive: @escaping (Result<[String: Any], Error>) -> Void) {
        self.pointer = pointer
        self.receive = receive
        calls.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { calls.leave() }
            var reading = true
            while reading {
                reading = autoreleasepool {
                    var json: UnsafeMutablePointer<CChar>?, error: UnsafeMutablePointer<CChar>?
                    let result = tavern_title_feed_next(pointer, 1000, &json, &error)
                    defer {
                        if let json { tavern_string_free(json) }
                        if let error { tavern_string_free(error) }
                    }
                    if result == 0 { return !isClosing }
                    if result == 2 {
                        deliver(.failure(NativeError.message(L("core.connection.closed"))))
                        return false
                    }
                    if result < 0 {
                        let message = error.map { String(cString: $0) } ?? L("core.connection.unknownError")
                        deliver(.failure(NativeError.message(message)))
                        return false
                    }
                    guard let json else {
                        deliver(.failure(NativeError.message(L("core.connection.emptyEvent"))))
                        return false
                    }
                    do {
                        let data = Data(bytes: json, count: strlen(json))
                        guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            throw NativeError.message(L("core.connection.invalidAPIResponse"))
                        }
                        deliver(.success(event))
                        return !isClosing
                    } catch {
                        deliver(.failure(error))
                        return false
                    }
                }
            }
            close()
        }
    }

    private var isClosing: Bool {
        lock.lock(); defer { lock.unlock() }
        return closing
    }

    private func deliver(_ result: Result<[String: Any], Error>) {
        DispatchQueue.main.sync { [self] in
            // An intentional detach can race with next() returning an IO error.
            guard !isClosing else { return }
            receive(result)
        }
    }

    func close() {
        lock.lock()
        guard !closing else { lock.unlock(); return }
        closing = true
        calls.enter()
        lock.unlock()
        // Never wait on the reader from main: it may be delivering an event.
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            tavern_title_feed_close(pointer)
            calls.leave()
        }
        calls.notify(queue: .global(qos: .utility)) { [pointer] in
            tavern_title_feed_free(pointer)
        }
    }
}
