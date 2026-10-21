import AppKit
import UniformTypeIdentifiers

private final class SoundSettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class TavernSoundSwitch: NSButton {
    override init(frame: NSRect) {
        super.init(frame: frame)
        setButtonType(.switch)
        title = ""
        isBordered = false
        focusRingType = .exterior
    }
    required init?(coder: NSCoder) { fatalError("TavernSoundSwitch requires a frame") }
    override var intrinsicContentSize: NSSize { NSSize(width: 32, height: 28) }
    override var state: NSControl.StateValue { didSet { needsDisplay = true } }
    private var track: NSRect { NSRect(x: bounds.midX - 16, y: bounds.midY - 9, width: 32, height: 18) }
    override var focusRingMaskBounds: NSRect { track }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: track, xRadius: 9, yRadius: 9).fill() }
    override func draw(_ dirtyRect: NSRect) {
        let on = state == .on
        let path = NSBezierPath(roundedRect: track, xRadius: 9, yRadius: 9)
        (on ? TavernAppearance.accent.withAlphaComponent(0.55) : TavernAppearance.chrome).setFill()
        path.fill()
        TavernAppearance.border.setStroke()
        path.lineWidth = 1
        path.stroke()
        TavernAppearance.text.setFill()
        NSBezierPath(ovalIn: NSRect(x: on ? track.maxX - 16 : track.minX + 2,
                                   y: track.minY + 2, width: 14, height: 14)).fill()
    }
}

final class TavernSettingsWindowController: NSWindowController {
    private struct EventControls {
        let enabled: TavernSoundSwitch
        let title: NSTextField
        let volume: NSSlider
        let percentage: NSTextField
        let preview: NSButton
        let details: NSButton
    }

    private struct DetailControls {
        let event: TavernSoundEvent
        let filename: NSTextField
        let title: NSTextField
        let choose: NSButton
        let reset: NSButton
    }

    private let settings: TavernSoundSettings
    private let player: TavernSoundPlayer
    private let masterEnabled = TavernSoundSwitch()
    private let masterVolume = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let masterPercentage = NSTextField(labelWithString: "")
    private var eventControls: [TavernSoundEvent: EventControls] = [:]
    private let detailsPopover = NSPopover()
    private var detailControls: DetailControls?
    private enum Section: String { case sounds, agents }
    private let defaults: UserDefaults
    private let agentsView: AgentSettingsView
    private let soundView = NSView()
    private let sectionHost = NSView()
    private let soundsButton = TavernButton(title: L("settings.sounds"), target: nil, action: nil)
    private let agentsButton = TavernButton(title: L("settings.agents"), target: nil, action: nil)
    private var selectedSection: Section
    private static let sectionKey = "tavern.settings.lastSection"
    private let languagePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private var languageUpdates: [() -> Void] = []
    private var languageObserver: NSObjectProtocol?
    private var sheetLanguageUpdate: (() -> Void)?

    init(settings: TavernSoundSettings, player: TavernSoundPlayer, integrations: AgentIntegrationService,
         defaults: UserDefaults = .standard) {
        self.settings = settings
        self.player = player
        self.defaults = defaults
        agentsView = AgentSettingsView(service: integrations)
        selectedSection = Section(rawValue: defaults.string(forKey: Self.sectionKey) ?? "") ?? .sounds
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = L("settings.title")
        window.identifier = NSUserInterfaceItemIdentifier("soundSettings.window")
        window.setAccessibilityIdentifier("soundSettings.window")
        window.minSize = NSSize(width: 800, height: 480)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.animationBehavior = .utilityWindow
        window.backgroundColor = TavernAppearance.wood
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        super.init(window: window)
        buildContent(in: window)
        refreshControls()
        languageObserver = NotificationCenter.default.addObserver(forName: .tavernLanguageDidChange, object: nil, queue: nil) { [weak self] _ in
            self?.languageDidChange()
        }
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("TavernSettingsWindowController requires sound settings") }
    deinit {
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
    }

    @objc private func changeLanguage(_ sender: NSPopUpButton) {
        let languages = TavernLanguage.allCases
        guard languages.indices.contains(sender.indexOfSelectedItem) else { return }
        TavernLocalization.shared.setLanguage(languages[sender.indexOfSelectedItem])
    }

    private func languageDidChange() {
        window?.title = L("settings.title")
        soundsButton.title = L("settings.sounds")
        agentsButton.title = L("settings.agents")
        for button in [soundsButton, agentsButton] { button.setAccessibilityLabel(button.title) }
        soundsButton.setAccessibilityValue(L(selectedSection == .sounds ? "settings.selected" : "settings.notSelected"))
        agentsButton.setAccessibilityValue(L(selectedSection == .agents ? "settings.selected" : "settings.notSelected"))
        languagePicker.setAccessibilityLabel(L("settings.language"))
        languagePicker.selectItem(at: TavernLanguage.allCases.firstIndex(of: TavernLocalization.shared.language) ?? 0)
        languageUpdates.forEach { $0() }
        sheetLanguageUpdate?()
        refreshControls()
    }

    override func showWindow(_ sender: Any?) {
        let wasVisible = window?.isVisible == true
        refreshControls()
        if selectedSection == .agents { agentsView.refresh() }
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        if !wasVisible, let content = window?.contentView { TavernMotion.appear(content) }
    }

    func showAgents() {
        selectSection(.agents)
        showWindow(nil)
    }

    @objc private func showSoundsSection(_ sender: NSButton) { selectSection(.sounds) }
    @objc private func showAgentsSection(_ sender: NSButton) {
        selectSection(.agents)
        agentsView.refresh()
    }

    private func selectSection(_ section: Section) {
        detailsPopover.close()
        if selectedSection != section {
            window?.makeFirstResponder(section == .sounds ? soundsButton : agentsButton)
        }
        selectedSection = section
        defaults.set(section.rawValue, forKey: Self.sectionKey)
        soundView.isHidden = section != .sounds
        agentsView.isHidden = section != .agents
        soundsButton.prepare(style: .utility, selected: section == .sounds)
        agentsButton.prepare(style: .utility, selected: section == .agents)
        soundsButton.setAccessibilityValue(L(section == .sounds ? "settings.selected" : "settings.notSelected"))
        agentsButton.setAccessibilityValue(L(section == .agents ? "settings.selected" : "settings.notSelected"))
    }
    private func buildContent(in window: NSWindow) {
        let root = ChromeView(fill: TavernAppearance.wood, material: .wood)
        window.contentView = root
        root.setAccessibilityIdentifier("settings.content")
        let sidebar = ChromeView(fill: TavernAppearance.chrome, material: .wood)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebar)
        sectionHost.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sectionHost)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            sidebar.widthAnchor.constraint(equalToConstant: 158),
            sectionHost.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 4),
            sectionHost.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            sectionHost.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            sectionHost.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6)
        ])
        let navigation = verticalStack(spacing: 6)
        sidebar.addSubview(navigation)
        for (button, section, action) in [
            (soundsButton, Section.sounds, #selector(showSoundsSection(_:))),
            (agentsButton, Section.agents, #selector(showAgentsSection(_:)))
        ] {
            button.target = self
            button.action = action
            button.role = .navigation
            button.prepare(style: .utility)
            button.setAccessibilityLabel(button.title)
            button.setAccessibilityIdentifier("settings.section.\(section.rawValue)")
            button.heightAnchor.constraint(equalToConstant: 38).isActive = true
            addFullWidth(button, to: navigation)
        }
        addFullWidth(localizedLabel("settings.language"), to: navigation)
        for language in TavernLanguage.allCases { languagePicker.addItem(withTitle: language.displayName) }
        languagePicker.selectItem(at: TavernLanguage.allCases.firstIndex(of: TavernLocalization.shared.language) ?? 0)
        languagePicker.target = self
        languagePicker.action = #selector(changeLanguage(_:))
        languagePicker.setAccessibilityIdentifier("settings.language")
        languagePicker.setAccessibilityLabel(L("settings.language"))
        addFullWidth(languagePicker, to: navigation)
        NSLayoutConstraint.activate([
            navigation.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            navigation.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
            navigation.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 18)
        ])
        for view in [soundView, agentsView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            sectionHost.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: sectionHost.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: sectionHost.trailingAnchor),
                view.topAnchor.constraint(equalTo: sectionHost.topAnchor),
                view.bottomAnchor.constraint(equalTo: sectionHost.bottomAnchor)
            ])
        }
        buildSoundContent(in: soundView)
        selectSection(selectedSection)
        let frame = LivingChromeView(role: .root)
        frame.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(frame)
        NSLayoutConstraint.activate([
            frame.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            frame.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            frame.topAnchor.constraint(equalTo: root.topAnchor),
            frame.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
    }

    private func buildSoundContent(in root: NSView) {
        let content = verticalStack(spacing: 12)
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18)
        ])
        addFullWidth(localizedLabel("settings.sounds", font: TavernAppearance.headingFont), to: content)

        let master = NSStackView()
        master.orientation = .horizontal
        master.distribution = .fill
        master.alignment = .centerY
        master.spacing = 12
        masterEnabled.controlSize = .small
        masterEnabled.target = self
        masterEnabled.action = #selector(changeMasterEnabled(_:))
        masterEnabled.setAccessibilityLabel(L("settings.sound.masterEnabled"))
        masterEnabled.setAccessibilityIdentifier("soundSettings.master.enabled")
        master.addArrangedSubview(masterEnabled)
        let masterTitle = localizedLabel("settings.sound.masterTitle", font: TavernAppearance.smallFont)
        masterTitle.textColor = TavernAppearance.text
        master.addArrangedSubview(masterTitle)
        prepareSlider(masterVolume, label: L("settings.sound.masterVolume"), identifier: "soundSettings.master.volume")
        masterVolume.target = self
        masterVolume.action = #selector(changeMasterVolume(_:))
        masterVolume.widthAnchor.constraint(equalToConstant: 220).isActive = true
        master.addArrangedSubview(masterVolume)
        preparePercentage(masterPercentage, label: L("settings.sound.masterPercentage"), identifier: "soundSettings.master.percentage")
        master.addArrangedSubview(masterPercentage)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        master.addArrangedSubview(spacer)
        addFullWidth(boardPanel(containing: master), to: content)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        let scroller = TavernScroller(); scroller.controlSize = .small
        scroll.verticalScroller = scroller
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.setAccessibilityIdentifier("soundSettings.scroll")
        addFullWidth(scroll, to: content)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true

        let document = SoundSettingsDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        let events = verticalStack(spacing: 0)
        document.addSubview(events)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            events.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            events.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            events.topAnchor.constraint(equalTo: document.topAnchor),
            events.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])

        let rows = verticalStack(spacing: 0)
        for (index, event) in TavernSoundEvent.allCases.enumerated() {
            if event == .attention || event == .interfaceClick {
                let heading = localizedLabel(event == .attention ? "settings.sound.notifications" : "settings.sound.interface")
                heading.font = TavernAppearance.smallFont
                heading.heightAnchor.constraint(equalToConstant: 28).isActive = true
                addFullWidth(heading, to: rows)
            }
            addFullWidth(eventRow(event, index: index), to: rows)
        }
        if let first = eventControls[.attention] {
            for event in TavernSoundEvent.allCases where event != .attention {
                guard let controls = eventControls[event] else { continue }
                NSLayoutConstraint.activate([
                    controls.title.widthAnchor.constraint(equalTo: first.title.widthAnchor),
                    controls.volume.widthAnchor.constraint(equalTo: first.volume.widthAnchor)
                ])
            }
        }
        addFullWidth(boardPanel(containing: rows), to: events)
        let footer = localizedLabel("settings.immediate")
        footer.alignment = .right
        addFullWidth(footer, to: content)

        detailsPopover.behavior = .transient
        detailsPopover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func eventRow(_ event: TavernSoundEvent, index: Int) -> NSView {
        let prefix = "soundSettings.event.\(event.rawValue)"
        let enabled = TavernSoundSwitch()
        enabled.controlSize = .small
        enabled.target = self
        enabled.action = #selector(changeEventEnabled(_:))
        enabled.tag = index
        enabled.setAccessibilityLabel(L("settings.sound.eventEnabled", event.title))
        enabled.setAccessibilityIdentifier("\(prefix).enabled")
        enabled.widthAnchor.constraint(equalToConstant: 32).isActive = true

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: event.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .regular))
        icon.contentTintColor = TavernAppearance.accent
        icon.imageScaling = .scaleProportionallyDown
        icon.setAccessibilityElement(false)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22)
        ])
        let title = label(event.title, font: TavernAppearance.smallFont)
        title.textColor = TavernAppearance.text
        title.maximumNumberOfLines = 2
        title.widthAnchor.constraint(greaterThanOrEqualToConstant: 124).isActive = true

        let volume = NSSlider(value: 0, minValue: 0, maxValue: 1, target: self, action: #selector(changeEventVolume(_:)))
        volume.tag = index
        prepareSlider(volume, label: L("settings.sound.eventVolume", event.title), identifier: "\(prefix).volume")
        if event == .attention {
            let preferredWidth = volume.widthAnchor.constraint(equalToConstant: 168)
            preferredWidth.priority = .defaultHigh
            preferredWidth.isActive = true
        }
        let percentage = NSTextField(labelWithString: "")
        preparePercentage(percentage, label: L("settings.sound.eventPercentage", event.title), identifier: "\(prefix).percentage")
        let preview = button("", action: #selector(previewSound(_:)), event: event, index: index,
                             suffix: "preview", symbol: "play.fill", accessibilityTitle: L("settings.sound.preview"))
        let details = button("⋯", action: #selector(showDetails(_:)), event: event, index: index,
                             suffix: "details", accessibilityTitle: L("settings.sound.details"))
        details.widthAnchor.constraint(equalToConstant: 32).isActive = true
        let row = NSStackView(views: [enabled, icon, title, volume, percentage, preview, details])
        row.orientation = .horizontal
        row.distribution = .fill
        row.alignment = .centerY
        row.spacing = 8
        row.heightAnchor.constraint(equalToConstant: 42).isActive = true
        eventControls[event] = EventControls(enabled: enabled, title: title, volume: volume, percentage: percentage, preview: preview, details: details)
        return row
    }

    @objc private func showDetails(_ sender: NSButton) {
        guard let event = event(for: sender) else { return }
        if detailsPopover.isShown, detailControls?.event == event {
            detailsPopover.performClose(sender)
            return
        }
        detailsPopover.close()
        let content = verticalStack(spacing: 12)
        let title = label(event.title, font: TavernAppearance.smallFont)
        title.textColor = TavernAppearance.text
        addFullWidth(title, to: content)
        let filename = label("")
        filename.preferredMaxLayoutWidth = 316
        filename.maximumNumberOfLines = 3
        filename.setAccessibilityLabel(L("settings.sound.eventFile", event.title))
        filename.setAccessibilityIdentifier("soundSettings.event.\(event.rawValue).filename")
        addFullWidth(filename, to: content)
        let choose = button(L("settings.sound.chooseFile"), action: #selector(chooseSound(_:)), event: event,
                            index: sender.tag, suffix: "choose")
        let reset = button(L("settings.sound.reset"), action: #selector(resetSound(_:)), event: event,
                           index: sender.tag, suffix: "reset")
        addFullWidth(choose, to: content)
        addFullWidth(reset, to: content)
        detailControls = DetailControls(event: event, filename: filename, title: title, choose: choose, reset: reset)
        refreshDetails()
        let panel = boardPanel(containing: content)
        panel.widthAnchor.constraint(equalToConstant: 340).isActive = true
        let controller = NSViewController()
        controller.view = panel
        panel.setAccessibilityIdentifier("soundSettings.event.\(event.rawValue).popover")
        detailsPopover.contentViewController = controller
        detailsPopover.contentSize = panel.fittingSize
        detailsPopover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        detailsPopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minX)
    }

    private func refreshDetails() {
        guard let controls = detailControls else { return }
        let choice = settings.choice(for: controls.event)
        let custom = choice.customFilename != nil || choice.customDisplayName != nil
        let filename = custom ? settings.displayName(for: controls.event) : L("settings.sound.standard")
        controls.filename.stringValue = filename
        controls.filename.toolTip = filename
        controls.reset.isEnabled = custom
        controls.title.stringValue = controls.event.title
        controls.filename.setAccessibilityLabel(L("settings.sound.eventFile", controls.event.title))
        controls.choose.title = L("settings.sound.chooseFile")
        controls.reset.title = L("settings.sound.reset")
        for button in [controls.choose, controls.reset] {
            button.toolTip = L("settings.sound.eventAction", controls.event.title, button.title)
            button.setAccessibilityLabel(button.toolTip)
        }
        if detailsPopover.isShown, let view = detailsPopover.contentViewController?.view {
            view.layoutSubtreeIfNeeded()
            detailsPopover.contentSize = view.fittingSize
        }
    }

    private func boardPanel(containing content: NSView) -> NSView {
        let panel = TavernBoardPanel()
        panel.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: panel.topAnchor, constant: 10),
            content.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -10)
        ])
        return panel
    }

    private func verticalStack(spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    private func addFullWidth(_ view: NSView, to stack: NSStackView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func localizedLabel(_ key: String, font: NSFont = TavernAppearance.detailFont) -> NSTextField {
        let field = label(L(key), font: font)
        languageUpdates.append { [weak field] in field?.stringValue = L(key) }
        return field
    }

    private func label(_ text: String, font: NSFont = TavernAppearance.detailFont) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = font == TavernAppearance.headingFont ? TavernAppearance.text : TavernAppearance.secondary
        field.maximumNumberOfLines = 0
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func prepareSlider(_ slider: NSSlider, label: String, identifier: String) {
        slider.isContinuous = true
        slider.trackFillColor = TavernAppearance.accent
        slider.setAccessibilityLabel(label)
        slider.setAccessibilityIdentifier(identifier)
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
    }

    private func preparePercentage(_ field: NSTextField, label: String, identifier: String) {
        field.font = TavernAppearance.detailFont
        field.textColor = TavernAppearance.text
        field.alignment = .right
        field.setAccessibilityLabel(label)
        field.setAccessibilityIdentifier(identifier)
        field.widthAnchor.constraint(equalToConstant: 46).isActive = true
    }

    private func button(_ title: String, action: Selector, event: TavernSoundEvent, index: Int, suffix: String,
                        symbol: String? = nil, accessibilityTitle: String? = nil) -> NSButton {
        let button = TavernButton(title: title, target: self, action: action)
        button.symbolName = symbol
        button.prepare(style: .utility)
        button.tag = index
        let actionTitle = accessibilityTitle ?? title
        button.toolTip = L("settings.sound.eventAction", event.title, actionTitle)
        button.setAccessibilityLabel(button.toolTip)
        button.setAccessibilityIdentifier("soundSettings.event.\(event.rawValue).\(suffix)")
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        if symbol != nil {
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            button.widthAnchor.constraint(equalToConstant: 32).isActive = true
        }
        return button
    }

    private func refreshControls() {
        masterEnabled.setAccessibilityLabel(L("settings.sound.masterEnabled"))
        masterVolume.setAccessibilityLabel(L("settings.sound.masterVolume"))
        masterPercentage.setAccessibilityLabel(L("settings.sound.masterPercentage"))
        masterEnabled.state = settings.enabled ? .on : .off
        updateVolume(masterVolume, percentage: masterPercentage, value: settings.volume)
        for event in TavernSoundEvent.allCases {
            guard let controls = eventControls[event] else { continue }
            controls.title.stringValue = event.title
            controls.enabled.setAccessibilityLabel(L("settings.sound.eventEnabled", event.title))
            controls.volume.setAccessibilityLabel(L("settings.sound.eventVolume", event.title))
            controls.percentage.setAccessibilityLabel(L("settings.sound.eventPercentage", event.title))
            controls.preview.setAccessibilityLabel(L("settings.sound.eventAction", event.title, L("settings.sound.preview")))
            controls.details.setAccessibilityLabel(L("settings.sound.eventAction", event.title, L("settings.sound.details")))
            controls.details.toolTip = controls.details.accessibilityLabel()
            let choice = settings.choice(for: event)
            controls.enabled.state = choice.enabled ? .on : .off
            updateVolume(controls.volume, percentage: controls.percentage, value: choice.volume)
            controls.preview.isEnabled = settings.enabled
            controls.preview.toolTip = settings.enabled
                ? L("settings.sound.previewDisabledEvent")
                : L("settings.sound.enablePreview")
        }
        refreshDetails()
    }

    private func updateVolume(_ slider: NSSlider, percentage: NSTextField, value: Double) {
        slider.doubleValue = value
        let text = L("settings.sound.percentage", Int((value * 100).rounded()))
        percentage.stringValue = text
        slider.setAccessibilityValueDescription(text)
    }

    private func event(for control: NSControl) -> TavernSoundEvent? {
        let events = TavernSoundEvent.allCases
        guard events.indices.contains(control.tag) else { return nil }
        return events[control.tag]
    }

    @objc private func changeMasterEnabled(_ sender: NSButton) {
        settings.enabled = sender.state == .on
        refreshControls()
    }

    @objc private func changeMasterVolume(_ sender: NSSlider) {
        settings.volume = sender.doubleValue
        updateVolume(masterVolume, percentage: masterPercentage, value: settings.volume)
    }

    @objc private func changeEventEnabled(_ sender: NSButton) {
        guard let event = event(for: sender) else { return }
        settings.setEnabled(sender.state == .on, for: event)
        refreshControls()
    }

    @objc private func changeEventVolume(_ sender: NSSlider) {
        guard let event = event(for: sender), let controls = eventControls[event] else { return }
        settings.setVolume(sender.doubleValue, for: event)
        updateVolume(controls.volume, percentage: controls.percentage, value: settings.choice(for: event).volume)
    }

    @objc private func previewSound(_ sender: NSButton) {
        guard settings.enabled, let event = event(for: sender) else { return }
        // Владелец player.onError в main показывает ошибки воспроизведения.
        player.play(event, preview: true)
    }

    @objc private func chooseSound(_ sender: NSButton) {
        guard let event = event(for: sender), let window else { return }
        detailsPopover.close()
        let panel = NSOpenPanel()
        panel.title = L("settings.sound.chooseTitle", event.title)
        panel.message = L("settings.sound.chooseMessage")
        panel.prompt = L("settings.choose")
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        sheetLanguageUpdate = { [weak panel] in
            panel?.title = L("settings.sound.chooseTitle", event.title)
            panel?.message = L("settings.sound.chooseMessage")
            panel?.prompt = L("settings.choose")
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            self?.sheetLanguageUpdate = nil
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                try self.settings.replaceSound(for: event, with: url)
                self.refreshControls()
            } catch {
                self.showError("settings.sound.replaceFailed", event: event, error: error)
            }
        }
    }

    @objc private func resetSound(_ sender: NSButton) {
        guard let event = event(for: sender) else { return }
        do {
            try settings.resetSound(for: event)
            refreshControls()
        } catch {
            showError("settings.sound.resetFailed", event: event, error: error)
        }
    }

    private func showError(_ title: String, event: TavernSoundEvent, error: Error) {
        detailsPopover.close()
        let alert = TavernDialog()
        alert.alertStyle = .warning
        alert.messageText = L(title)
        alert.informativeText = "\(event.title)\n\(error.localizedDescription)"
        alert.addButton(withTitle: L("settings.close"))
        alert.localizationUpdater = { dialog in
            dialog.messageText = L(title)
            dialog.informativeText = "\(event.title)\n\(error.localizedDescription)"
            dialog.buttons.first?.title = L("settings.close")
            dialog.buttons.first?.setAccessibilityLabel(L("settings.close"))
        }
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
