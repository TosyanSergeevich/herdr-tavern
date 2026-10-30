import AppKit

/// Немодальное приглашение: терминалом можно пользоваться без настройки агентов.
final class AgentWelcomeWindowController: NSWindowController {
    private let configure: () -> Void
    private var languageObserver: NSObjectProtocol?

    init(configure: @escaping () -> Void) {
        self.configure = configure
        let size = NSSize(width: 490, height: 280)
        let panel = TavernAgentWelcomePanel(contentRect: NSRect(origin: .zero, size: size),
                                            styleMask: [.borderless], backing: .buffered, defer: false)
        TavernMotion.configureWindow(panel)
        panel.title = L("settings.welcome.title")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.setAccessibilityIdentifier("agentSetup.welcome")
        panel.setAccessibilityLabel(panel.title)
        panel.setAccessibilitySubrole(.dialog)
        super.init(window: panel)
        let materials = try? TavernMaterials.bundled.get()
        let root = TavernDialogBackground(frame: NSRect(origin: .zero, size: size), materials: materials)
        panel.contentView = root
        let fontsAvailable = (try? TavernAppearance.validateFonts()) != nil
        let ornament = NSTextField(labelWithString: "◆")
        ornament.font = .systemFont(ofSize: 11)
        ornament.textColor = TavernAppearance.accent
        ornament.alignment = .center
        ornament.setAccessibilityElement(false)
        let heading = NSTextField(wrappingLabelWithString: L("settings.welcome.heading"))
        heading.font = fontsAvailable
            ? NSFontManager.shared.convert(TavernAppearance.bodyFont, toSize: 25)
            : .systemFont(ofSize: 25, weight: .medium)
        heading.alignment = .center
        heading.textColor = NSColor(srgbRed: 241 / 255, green: 217 / 255, blue: 170 / 255, alpha: 1)
        let description = NSTextField(wrappingLabelWithString: L("settings.welcome.description"))
        description.font = .systemFont(ofSize: 13)
        description.textColor = TavernAppearance.secondary
        description.alignment = .center
        description.setContentCompressionResistancePriority(.required, for: .vertical)
        let buttonFont = fontsAvailable
            ? NSFontManager.shared.convert(TavernAppearance.bodyFont, toSize: 14)
            : .systemFont(ofSize: 14, weight: .medium)
        let later = TavernDialogButton(title: L("settings.welcome.later"), target: self, action: #selector(dismiss))
        later.font = buttonFont
        later.keyEquivalent = "\u{1b}"
        later.setAccessibilityIdentifier("agentSetup.later")
        later.setAccessibilityLabel(later.title)
        let setup = TavernDialogButton(title: L("settings.welcome.setup"), target: self, action: #selector(openSettings))
        setup.isPrimary = true
        setup.skins = materials?.buttonSkins
        setup.font = buttonFont
        setup.keyEquivalent = "\r"
        setup.setAccessibilityIdentifier("agentSetup.configure")
        setup.setAccessibilityLabel(setup.title)
        panel.defaultButtonCell = setup.cell as? NSButtonCell
        panel.initialFirstResponder = setup
        let buttons = NSStackView(views: [later, setup])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        for view in [ornament, heading, description, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            ornament.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            ornament.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 35),
            heading.topAnchor.constraint(equalTo: ornament.bottomAnchor, constant: 14),
            heading.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -35),
            description.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            description.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            description.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 14),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -35),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -28),
            later.widthAnchor.constraint(equalToConstant: 116),
            later.heightAnchor.constraint(equalToConstant: 40),
            setup.widthAnchor.constraint(equalToConstant: 132),
            setup.heightAnchor.constraint(equalToConstant: 40),
            description.bottomAnchor.constraint(lessThanOrEqualTo: buttons.topAnchor, constant: -20)
        ])
        languageObserver = NotificationCenter.default.addObserver(forName: .tavernLanguageDidChange, object: nil, queue: nil) { [weak panel] _ in
            panel?.title = L("settings.welcome.title")
            panel?.setAccessibilityLabel(L("settings.welcome.title"))
            heading.stringValue = L("settings.welcome.heading")
            description.stringValue = L("settings.welcome.description")
            later.title = L("settings.welcome.later")
            later.setAccessibilityLabel(later.title)
            setup.title = L("settings.welcome.setup")
            setup.setAccessibilityLabel(setup.title)
        }
        panel.center()
    }

    required init?(coder: NSCoder) { return nil }
    deinit {
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
    }
    @objc private func dismiss() { close() }
    @objc private func openSettings() { close(); configure() }
}

private final class TavernAgentWelcomePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { close() }
    override func performClose(_ sender: Any?) { close() }
}
