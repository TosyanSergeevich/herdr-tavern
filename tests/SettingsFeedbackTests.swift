import AppKit

#if !TAVERN_RENDER_TESTING
#error("SettingsFeedbackTests requires -D TAVERN_RENDER_TESTING")
#endif

@main struct SettingsFeedbackTests {
    private enum FixtureError: Error { case noAgentCommands }

    static func main() throws {
        _ = NSApplication.shared
        var prepared: Result<Void, Error>?
        TavernCardSurfaceView.prepareResources { prepared = $0 }
        wait("material resources") { prepared != nil }
        try prepared!.get()
        let suite = "HerdrTavern.SettingsFeedback.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        // Use a genuine custom audio resource, but never output audio or invoke herdr.
        let customName = "tavern-sound-\(UUID().uuidString).wav"
        let bundled = Bundle.main.url(forResource: TavernSoundEvent.interfaceClick.defaultFilename,
                                      withExtension: nil, subdirectory: "Sounds")!
        try FileManager.default.copyItem(at: bundled, to: root.appendingPathComponent(customName))
        defaults.set(["enabled": true, "volume": 0.25, "customFilename": customName],
                     forKey: "HerdrTavern.sounds.v1.event.interfaceClick")
        let settings = TavernSoundSettings(defaults: defaults, soundDirectory: root)
        settings.enabled = true
        settings.volume = 0.4
        let player = TavernSoundPlayer(settings: settings)
        defer { player.stop() }
        settings.onChange = { [weak player] in player?.settingsDidChange() }
        var played: [NSSound] = []
        player.playSound = { sound in played.append(sound); return true }
        player.isSoundPlaying = { _ in true }
        player.onError = { preconditionFailure($0) }
        let service = AgentIntegrationService(executable: {
            throw FixtureError.noAgentCommands
        }, defaults: defaults)
        let typography = TavernTerminalSettings(defaults: defaults)
        let fonts = try TerminalFonts.load(size: CGFloat(typography.typography.size))
        let controller = TavernSettingsWindowController(settings: settings, player: player, integrations: service,
                                                       terminalSettings: typography, terminalFonts: fonts, defaults: defaults)
        let content = controller.window!.contentView!
        fence(settings)
        precondition(played.isEmpty, "Construction and programmatic refresh must be silent")

        let sounds: NSButton = control("settings.section.sounds", in: content)
        activate(sounds)
        wait("sound section click") { played.count == 1 }
        precondition(abs(played.last!.volume - 0.1) < 0.00001, "Click uses master × event volume")
        precondition(settings.resource(for: .interfaceClick)!.url.lastPathComponent == customName)

        let terminal: NSButton = control("settings.section.terminal", in: content)
        activate(terminal)
        wait("terminal section click") { played.count == 2 }
        let stepper: NSStepper = control("terminalSettings.sizeStepper", in: content)
        stepper.doubleValue += 1
        activate(stepper)
        wait("terminal size feedback") { played.count == 3 }
        let agents: NSButton = control("settings.section.agents", in: content)
        activate(agents)
        wait("agent section click") { played.count == 4 }
        let refresh: NSButton = control("agentSettings.refresh", in: content)
        wait("isolated agent refresh") { refresh.isEnabled }
        activate(refresh)
        wait("explicit agent refresh feedback") { played.count == 5 && refresh.isEnabled }
        let agentView = find("agentSettings.content", in: content) as! AgentSettingsView
        agentView.refresh()
        wait("automatic agent refresh") { refresh.isEnabled }
        precondition(played.count == 5, "Automatic refresh must not click")

        let volume: TavernSettingsSlider = control("soundSettings.master.volume", in: content)
        volume.doubleValue = 0.8
        activate(volume)
        precondition(played.count == 5, "Continuous volume actions must not flood feedback")
        precondition(settings.volume == 0.8 && abs(played.last!.volume - 0.2) < 0.00001,
                     "Live volume still updates the active sound")
        volume.onInteraction?() // Synthetic end-of-gesture; native gesture delivery is covered by UI QA.
        wait("volume gesture feedback") { played.count == 6 }
        precondition(abs(played.last!.volume - 0.2) < 0.00001)

        settings.setEnabled(false, for: .interfaceClick)
        activate(sounds)
        fence(settings)
        precondition(played.count == 6, "Disabled interface click remains silent")
        settings.setEnabled(true, for: .interfaceClick)
        settings.enabled = false
        activate(terminal)
        volume.onInteraction?()
        fence(settings)
        precondition(played.count == 6, "Master mute remains authoritative")
        settings.enabled = true
        sounds.isEnabled = false
        activate(sounds)
        fence(settings)
        precondition(played.count == 6, "Rejected disabled action stays silent")
        sounds.isEnabled = true

        // Rebuild control state after the externally changed master preference.
        controller.showWindow(nil)
        precondition(played.count == 6, "Showing settings does not duplicate the main-window click")
        settings.setEnabled(false, for: .attention)
        let preview: NSButton = control("soundSettings.event.attention.preview", in: content)
        activate(preview)
        wait("selected preview") { played.count == 7 }
        let previewSound = played.last!
        fence(settings)
        precondition(played.count == 7 && player.testingActiveSound === previewSound,
                     "Preview plays only its selected event and is not interrupted by a click")
        precondition(abs(previewSound.volume - Float(settings.volume * settings.choice(for: .attention).volume)) < 0.00001)
        controller.close()
        print("Settings feedback routing, mute, custom resource, live volume and preview checks passed")
    }

    private static func find(_ identifier: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == identifier { return view }
        for child in view.subviews {
            if let match = find(identifier, in: child) { return match }
        }
        return nil
    }

    private static func control<T: NSControl>(_ identifier: String, in view: NSView) -> T {
        guard let result = find(identifier, in: view) as? T else { preconditionFailure(identifier) }
        return result
    }

    private static func activate(_ control: NSControl) {
        precondition(NSApp.sendAction(control.action!, to: control.target, from: control))
    }

    private static func fence(_ settings: TavernSoundSettings) {
        var done = false
        settings.resetSound(for: .complete) { result in try! result.get(); done = true }
        wait("audio IO fence") { done }
    }

    private static func wait(_ description: String, until predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(8)
        while !predicate(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.002))
        }
        precondition(predicate(), "Timeout: \(description)")
    }
}
