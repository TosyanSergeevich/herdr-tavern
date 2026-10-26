import AppKit

#if !TAVERN_RENDER_TESTING
#error("SoundTransactionTests requires -D TAVERN_RENDER_TESTING")
#endif

@main struct SoundTransactionTests {
    static let manager = FileManager.default

    static func main() throws {
        _ = NSApplication.shared
        try importResetPreserveInterveningPreferences()
        try invalidAudioAndCopyFailurePreserveOldSource()
        try failedRemovalRollsBackNewCopy()
        try changedSourceFailsCopyValidationAndCleansUp()
        try cleanupFailureRetainsOriginalAndReportsBothErrors()
        try sharedAndUnsafeManagedEntriesAreNotDeleted()
        try operationRetainsSettingsAfterOwnerCloses()
        print("Пройдены транзакционные проверки звука")
    }

    static func wait(_ description: String, until predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(8)
        while !predicate(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.002))
        }
        precondition(predicate(), "Timeout: \(description)")
    }

    final class Gate {
        private let condition = NSCondition()
        private var released = false
        var entered = false // Published only on main.
        func block() {
            precondition(!Thread.isMainThread)
            condition.lock()
            DispatchQueue.main.async { self.entered = true }
            while !released { condition.wait() }
            condition.unlock()
        }
        func release() {
            condition.lock()
            released = true
            condition.broadcast()
            condition.unlock()
        }
        deinit { release() }
    }

    final class Fixture {
        let root: URL
        let directory: URL
        let source: URL
        let suite = "HerdrTavern.SoundTransactions.\(UUID().uuidString)"
        let defaults: UserDefaults
        init() throws {
            defaults = UserDefaults(suiteName: suite)!
            root = manager.temporaryDirectory.appendingPathComponent("tavern-sounds-\(UUID().uuidString)")
            directory = root.appendingPathComponent("managed")
            source = root.appendingPathComponent("source.wav")
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let bundled = Bundle.main.url(forResource: TavernSoundEvent.interfaceClick.defaultFilename,
                                           withExtension: nil, subdirectory: "Sounds")!
            try manager.copyItem(at: bundled, to: source)
        }
        func settings() -> TavernSoundSettings {
            TavernSoundSettings(defaults: defaults, soundDirectory: directory)
        }
        func names() throws -> Set<String> {
            Set(try manager.contentsOfDirectory(atPath: directory.path))
        }
        func seed(_ event: TavernSoundEvent, filename: String) {
            defaults.set(["enabled": true, "volume": 0.7, "customFilename": filename,
                          "customDisplayName": "old.wav"],
                         forKey: "HerdrTavern.sounds.v1.event." + event.rawValue)
        }
        deinit {
            defaults.removePersistentDomain(forName: suite)
            try? manager.removeItem(at: root)
        }
    }

    @discardableResult static func operation(
        _ start: (@escaping (Result<Void, Error>) -> Void) -> Void
    ) -> Result<Void, Error> {
        var result: Result<Void, Error>?
        var calls = 0
        start {
            precondition(Thread.isMainThread)
            calls += 1
            precondition(calls == 1, "Completion должен быть единственным")
            result = $0
        }
        wait("sound transaction") { result != nil }
        return result!
    }

    static func requireFailure(_ result: Result<Void, Error>) {
        if case .success = result { preconditionFailure("Ожидалась реальная файловая ошибка") }
    }

    static func importResetPreserveInterveningPreferences() throws {
        let fixture = try Fixture()
        let settings = fixture.settings()
        let original = settings.resource(for: .interfaceMove)
        let gate = Gate()
        settings.ioGate = { gate.block() }
        var result: Result<Void, Error>?
        settings.replaceSound(for: .interfaceMove, with: fixture.source) {
            precondition(Thread.isMainThread && result == nil)
            result = $0
        }
        wait("import gate") { gate.entered }
        var heartbeat = false
        DispatchQueue.main.async { heartbeat = true }
        wait("main heartbeat during blocked IO") { heartbeat }
        settings.setEnabled(false, for: .interfaceMove)
        settings.setVolume(0.23, for: .interfaceMove)
        settings.volume = 0.37
        settings.ioGate = nil
        gate.release()
        wait("import commit") { result != nil }
        try result!.get()
        let imported = settings.resource(for: .interfaceMove)!
        precondition(imported != original)
        precondition((try! Data(contentsOf: imported.url)) == (try! Data(contentsOf: fixture.source)))
        precondition(!settings.choice(for: .interfaceMove).enabled)
        precondition(settings.choice(for: .interfaceMove).volume == 0.23 && settings.volume == 0.37)
        let restored = fixture.settings()
        precondition(restored.choice(for: .interfaceMove).customFilename == imported.url.lastPathComponent)
        let resetGate = Gate()
        settings.ioGate = { resetGate.block() }
        var reset: Result<Void, Error>?
        settings.resetSound(for: .interfaceMove) { reset = $0; precondition(Thread.isMainThread) }
        wait("reset gate") { resetGate.entered }
        settings.setVolume(0.49, for: .interfaceMove)
        settings.setEnabled(true, for: .interfaceMove)
        settings.ioGate = nil
        resetGate.release()
        wait("reset commit") { reset != nil }
        try reset!.get()
        precondition(!manager.fileExists(atPath: imported.url.path))
        precondition(settings.choice(for: .interfaceMove).customFilename == nil)
        precondition(settings.choice(for: .interfaceMove).enabled)
        precondition(settings.choice(for: .interfaceMove).volume == 0.49)
        precondition(settings.resource(for: .interfaceMove)?.revision != imported.revision)
    }

    static func invalidAudioAndCopyFailurePreserveOldSource() throws {
        let fixture = try Fixture()
        let settings = fixture.settings()
        try operation { settings.replaceSound(for: .attention, with: fixture.source, completion: $0) }.get()
        let old = settings.resource(for: .attention)
        let names = try fixture.names()
        let invalid = fixture.root.appendingPathComponent("invalid.wav")
        try Data("not audio".utf8).write(to: invalid)
        requireFailure(operation { settings.replaceSound(for: .attention, with: invalid, completion: $0) })
        precondition(settings.resource(for: .attention) == old && (try! fixture.names()) == names)
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.directory.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.directory.path) }
        requireFailure(operation { settings.replaceSound(for: .attention, with: fixture.source, completion: $0) })
        precondition(settings.resource(for: .attention) == old && (try! fixture.names()) == names)
    }

    static func failedRemovalRollsBackNewCopy() throws {
        let fixture = try Fixture()
        let settings = fixture.settings()
        try operation { settings.replaceSound(for: .complete, with: fixture.source, completion: $0) }.get()
        let old = settings.resource(for: .complete)!
        let names = try fixture.names()
        try manager.setAttributes([.immutable: true], ofItemAtPath: old.url.path)
        defer { try? manager.setAttributes([.immutable: false], ofItemAtPath: old.url.path) }
        requireFailure(operation { settings.replaceSound(for: .complete, with: fixture.source, completion: $0) })
        precondition(settings.resource(for: .complete) == old)
        precondition((try! fixture.names()) == names, "Неудачный import удаляет новую копию")
        requireFailure(operation { settings.resetSound(for: .complete, completion: $0) })
        precondition(settings.resource(for: .complete) == old)
        precondition((try! Data(contentsOf: old.url)) == (try! Data(contentsOf: fixture.source)))
    }

    static func changedSourceFailsCopyValidationAndCleansUp() throws {
        let fixture = try Fixture()
        let settings = fixture.settings()
        try operation { settings.replaceSound(for: .attention, with: fixture.source, completion: $0) }.get()
        let old = settings.resource(for: .attention)
        let names = try fixture.names()
        // Only the serial worker touches this ordinal. No synthetic filesystem result.
        var job = 0
        let source = fixture.source
        settings.ioGate = {
            precondition(!Thread.isMainThread)
            job += 1
            if job == 2 { try! Data("source changed after initial validation".utf8).write(to: source) }
        }
        requireFailure(operation { settings.replaceSound(for: .attention, with: source, completion: $0) })
        settings.ioGate = nil
        precondition(settings.resource(for: .attention) == old)
        precondition((try! fixture.names()) == names, "Невалидная скопированная версия удаляется")
    }

    static func cleanupFailureRetainsOriginalAndReportsBothErrors() throws {
        let fixture = try Fixture()
        let settings = fixture.settings()
        try operation { settings.replaceSound(for: .error, with: fixture.source, completion: $0) }.get()
        let old = settings.resource(for: .error)!
        try manager.setAttributes([.immutable: true], ofItemAtPath: old.url.path)
        defer {
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.directory.path)
            try? manager.setAttributes([.immutable: false], ofItemAtPath: old.url.path)
        }
        var job = 0
        let directory = fixture.directory
        settings.ioGate = {
            job += 1
            if job == 3 {
                // Copy exists; old removal fails due to its flag, cleanup due to directory permissions.
                try! manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
            }
        }
        let result = operation { settings.replaceSound(for: .error, with: fixture.source, completion: $0) }
        settings.ioGate = nil
        guard case .failure(let error) = result else { preconditionFailure("Ожидались ошибки remove и cleanup") }
        precondition(settings.resource(for: .error) == old)
        precondition((try! fixture.names()).count == 2, "Неудачный cleanup оставляет реальную новую копию")
        let removalDescription = L("settings.sound.removeFailed")
        precondition(error.localizedDescription.components(separatedBy: removalDescription).count >= 3,
                     "Пользователю сообщаются обе ошибки удаления, включая неудачный cleanup")
    }

    static func sharedAndUnsafeManagedEntriesAreNotDeleted() throws {
        let fixture = try Fixture()
        let filename = "tavern-sound-\(UUID().uuidString).wav"
        let shared = fixture.directory.appendingPathComponent(filename)
        try manager.copyItem(at: fixture.source, to: shared)
        fixture.seed(.attention, filename: filename)
        fixture.seed(.complete, filename: filename)
        let settings = fixture.settings()
        try operation { settings.resetSound(for: .attention, completion: $0) }.get()
        precondition(manager.fileExists(atPath: shared.path))
        precondition(settings.choice(for: .complete).customFilename == filename)
        try operation { settings.resetSound(for: .complete, completion: $0) }.get()
        precondition(!manager.fileExists(atPath: shared.path))

        for directory in [false, true] {
            let name = "tavern-sound-\(UUID().uuidString).wav"
            let entry = fixture.directory.appendingPathComponent(name)
            if directory {
                try manager.createDirectory(at: entry, withIntermediateDirectories: false)
                try Data([1, 2, 3]).write(to: entry.appendingPathComponent("keep"))
            } else {
                try manager.createSymbolicLink(at: entry, withDestinationURL: fixture.source)
            }
            fixture.seed(.bell, filename: name)
            let unsafe = fixture.settings()
            try operation { unsafe.resetSound(for: .bell, completion: $0) }.get()
            let attributes = try manager.attributesOfItem(atPath: entry.path)
            precondition(attributes[.type] as? FileAttributeType == (directory ? .typeDirectory : .typeSymbolicLink))
            precondition(manager.fileExists(atPath: fixture.source.path))
        }
    }

    static func operationRetainsSettingsAfterOwnerCloses() throws {
        let fixture = try Fixture()
        var owner: TavernSoundSettings? = fixture.settings()
        weak var weakSettings = owner
        let gate = Gate()
        owner!.ioGate = { gate.block() }
        var result: Result<Void, Error>?
        owner!.replaceSound(for: .error, with: fixture.source) { result = $0; precondition(Thread.isMainThread) }
        wait("retained import gate") { gate.entered }
        owner = nil
        precondition(weakSettings != nil, "Transaction удерживает settings после закрытия UI")
        gate.release()
        wait("retained transaction completion") { result != nil }
        try result!.get()
        let restored = fixture.settings()
        let resource = restored.resource(for: .error)!
        precondition(restored.choice(for: .error).customFilename != nil)
        precondition((try! Data(contentsOf: resource.url)) == (try! Data(contentsOf: fixture.source)))
    }
}
