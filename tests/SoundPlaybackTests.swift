import AppKit

#if !TAVERN_RENDER_TESTING
#error("SoundPlaybackTests requires -D TAVERN_RENDER_TESTING")
#endif

@main struct SoundPlaybackTests {
    static func main() throws {
        _ = NSApplication.shared
        try stoppedAndSupersededLoadsAreSilent()
        try sourceChangeRejectsQueuedOldLoad()
        try separateCopiesAndLateDelegateIdentity()
        try enabledVolumePreviewAndSuppression()
        try missingCustomDoesNotPlayBundledFallback()
        print("Пройдены проверки асинхронного воспроизведения без вывода звука")
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
        var entered = false
        func block() {
            precondition(!Thread.isMainThread)
            condition.lock()
            DispatchQueue.main.async { self.entered = true }
            while !released { condition.wait() }
            condition.unlock()
        }
        func release() {
            condition.lock(); released = true; condition.broadcast(); condition.unlock()
        }
        deinit { release() }
    }

    final class Fixture {
        let root: URL
        let suite = "HerdrTavern.SoundPlayback.\(UUID().uuidString)"
        let defaults: UserDefaults
        let settings: TavernSoundSettings
        let player: TavernSoundPlayer
        var accepted: [NSSound] = []
        var errors: [String] = []
        init() throws {
            defaults = UserDefaults(suiteName: suite)!
            root = FileManager.default.temporaryDirectory.appendingPathComponent("tavern-play-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            // Prevent prewarming from racing the gates; every test exercises real Data loading itself.
            defaults.set(["enabled": false, "volume": 1], forKey: "HerdrTavern.sounds.v1.event.interfaceClick")
            for event in [TavernSoundEvent.attention, .error, .complete] {
                let filename = "tavern-sound-\(UUID().uuidString).wav"
                let bundled = Bundle.main.url(forResource: event.defaultFilename,
                                               withExtension: nil, subdirectory: "Sounds")!
                try FileManager.default.copyItem(at: bundled, to: root.appendingPathComponent(filename))
                defaults.set(["enabled": true, "volume": 0.7, "customFilename": filename],
                             forKey: "HerdrTavern.sounds.v1.event." + event.rawValue)
            }
            settings = TavernSoundSettings(defaults: defaults, soundDirectory: root)
            player = TavernSoundPlayer(settings: settings)
            player.playSound = { [weak self] sound in
                precondition(Thread.isMainThread)
                self?.accepted.append(sound)
                return true // Never call NSSound.play in automated tests.
            }
            player.isSoundPlaying = { _ in precondition(Thread.isMainThread); return true }
            player.onError = { [weak self] message in
                precondition(Thread.isMainThread)
                self?.errors.append(message)
            }
            settings.onChange = { [weak player] in player?.settingsDidChange() }
        }
        func finishIO() {
            // A real queued file operation is a fence, not a sleep or production counter.
            var done = false
            settings.resetSound(for: .complete) { result in
                precondition(Thread.isMainThread && !done)
                try! result.get()
                done = true
            }
            SoundPlaybackTests.wait("file fence") { done }
        }
        deinit {
            player.stop()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    static func stoppedAndSupersededLoadsAreSilent() throws {
        for supersede in [false, true] {
            let fixture = try Fixture()
            let gate = Gate()
            fixture.settings.ioGate = { gate.block() }
            fixture.player.play(.attention)
            wait("old load blocked") { gate.entered }
            var heartbeat = false
            DispatchQueue.main.async { heartbeat = true }
            wait("heartbeat while audio IO blocked") { heartbeat }
            fixture.settings.ioGate = nil
            fixture.player.stop()
            // Make the stale load fail after cancellation, not merely succeed late.
            try FileManager.default.removeItem(at: fixture.settings.resource(for: .attention)!.url)
            if supersede { fixture.player.play(.error) }
            gate.release()
            fixture.finishIO()
            if supersede {
                wait("new event accepted") { fixture.accepted.count == 1 }
                precondition(fixture.player.testingActiveSound === fixture.accepted[0])
            } else {
                precondition(fixture.accepted.isEmpty && fixture.player.testingActiveSound == nil)
            }
            precondition(fixture.errors.isEmpty, "Ошибка устаревшего load не публикуется")
        }
    }

    static func sourceChangeRejectsQueuedOldLoad() throws {
        let fixture = try Fixture()
        let old = fixture.settings.resource(for: .attention)!
        let gate = Gate()
        fixture.settings.ioGate = { gate.block() }
        var reset = false
        fixture.settings.resetSound(for: .attention) { result in try! result.get(); reset = true }
        wait("source mutation gate") { gate.entered }
        fixture.settings.ioGate = nil
        fixture.player.play(.attention) // Queued with the old resource while reset owns IO.
        gate.release()
        wait("source reset") { reset }
        fixture.finishIO()
        precondition(fixture.settings.resource(for: .attention) != old)
        precondition(fixture.accepted.isEmpty && fixture.errors.isEmpty)
        precondition(fixture.player.testingActiveSound == nil)
        precondition(fixture.player.testingTemplate(for: old) == nil,
                     "Устаревший ресурс не создаёт template после worker completion")
    }

    static func separateCopiesAndLateDelegateIdentity() throws {
        let fixture = try Fixture()
        fixture.player.play(.attention)
        wait("first playback") { fixture.accepted.count == 1 }
        let first = fixture.accepted[0]
        let resource = fixture.settings.resource(for: .attention)!
        let template = fixture.player.testingTemplate(for: resource)!
        precondition(template !== first && template.delegate == nil && !template.isPlaying)
        precondition(first.delegate === fixture.player)
        fixture.player.stop()
        fixture.player.play(.attention)
        wait("second playback") { fixture.accepted.count == 2 }
        let second = fixture.accepted[1]
        precondition(second !== first && second !== template)
        precondition(fixture.player.testingTemplate(for: resource) === template)
        precondition(template.delegate == nil && !template.isPlaying)
        // The old callback may arrive on an arbitrary audio thread after the new play.
        var delivered = false
        DispatchQueue.global().async {
            fixture.player.sound(first, didFinishPlaying: false)
            DispatchQueue.main.async { delivered = true }
        }
        wait("old delegate callback") { delivered }
        precondition(fixture.player.testingActiveSound === second && second.delegate === fixture.player)
        precondition(fixture.errors.isEmpty)
        fixture.player.sound(second, didFinishPlaying: true)
        wait("current delegate callback") { fixture.player.testingActiveSound == nil }
        precondition(second.delegate == nil && fixture.errors.isEmpty)
    }

    static func missingCustomDoesNotPlayBundledFallback() throws {
        let fixture = try Fixture()
        let resource = fixture.settings.resource(for: .attention)!
        try FileManager.default.removeItem(at: resource.url)
        fixture.player.play(.attention)
        wait("missing custom error") { !fixture.errors.isEmpty }
        precondition(fixture.errors.count == 1 && fixture.accepted.isEmpty)
        precondition(fixture.player.testingActiveSound == nil)
        precondition(fixture.settings.resource(for: .attention) == resource,
                     "Ошибка IO не подменяет пользовательский выбор bundled звуком")
    }

    static func enabledVolumePreviewAndSuppression() throws {
        let fixture = try Fixture()
        fixture.settings.enabled = false
        fixture.player.play(.attention, preview: true)
        precondition(fixture.player.testingActiveSound == nil && fixture.accepted.isEmpty)
        fixture.settings.enabled = true
        fixture.settings.setEnabled(false, for: .attention)
        fixture.player.play(.attention)
        precondition(fixture.accepted.isEmpty)
        fixture.settings.volume = 0.4
        fixture.settings.setVolume(0.25, for: .attention)
        fixture.player.play(.attention, preview: true)
        wait("disabled event preview") { fixture.accepted.count == 1 }
        let preview = fixture.accepted[0]
        precondition(abs(preview.volume - 0.1) < 0.00001)
        fixture.settings.setVolume(0.5, for: .attention)
        precondition(abs(preview.volume - 0.2) < 0.00001)
        precondition(fixture.player.testingActiveSound === preview, "Preview игнорирует event enabled")
        fixture.settings.setEnabled(true, for: .attention)
        fixture.player.play(.attention)
        precondition(fixture.accepted.count == 1, "Non-click уже играет — повтор подавлен")
        fixture.settings.enabled = false
        precondition(fixture.player.testingActiveSound == nil)
        fixture.settings.enabled = true
        fixture.settings.setEnabled(true, for: .interfaceClick)
        fixture.player.play(.interfaceClick)
        wait("click playback") { fixture.accepted.count == 2 }
        let firstClick = fixture.accepted[1]
        fixture.player.play(.interfaceClick)
        wait("click restart") { fixture.accepted.count == 3 }
        precondition(fixture.accepted[2] !== firstClick)
        fixture.settings.setEnabled(false, for: .interfaceClick)
        precondition(fixture.player.testingActiveSound == nil)
        precondition(fixture.errors.isEmpty)
    }
}
