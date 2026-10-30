import AppKit

private enum AgentSettingsStyle {
    static func label(_ text: String, font: NSFont = TavernAppearance.detailFont,
                      color: NSColor = TavernAppearance.secondary) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = color
        field.maximumNumberOfLines = 0
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    static func stack(spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.detachesHiddenViews = true
        return stack
    }

    static func add(_ view: NSView, to stack: NSStackView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    static func button(_ title: String, identifier: String, target: AnyObject?, action: Selector?) -> TavernButton {
        let button = TavernButton(title: title, target: target, action: action)
        button.prepare(style: .utility)
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(title)
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }
}

private final class AgentSettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private struct AgentSettingsNotice {
    let text: () -> String
    let isError: Bool
}

private final class AgentIntegrationRow: NSView {
    var onInstall: (() -> Void)?
    var onMenu: ((NSButton) -> Void)?
    private let name = AgentSettingsStyle.label("", font: TavernAppearance.smallFont, color: TavernAppearance.text)
    private let status = AgentSettingsStyle.label("")
    private let location = AgentSettingsStyle.label("")
    private let message = AgentSettingsStyle.label("")
    private let actionButton: TavernButton
    private let moreButton: TavernButton
    private let spinner = TavernProgressIndicator()

    init(target: String) {
        let prefix = "agentSettings.agent.\(target)"
        actionButton = AgentSettingsStyle.button(L("settings.integration.connect"), identifier: "\(prefix).install", target: nil, action: nil)
        moreButton = AgentSettingsStyle.button("⋯", identifier: "\(prefix).more", target: nil, action: nil)
        super.init(frame: .zero)
        actionButton.role = .primary
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier(prefix)
        name.setAccessibilityIdentifier("\(prefix).name")
        status.setAccessibilityIdentifier("\(prefix).status")
        location.setAccessibilityIdentifier("\(prefix).location")
        message.setAccessibilityIdentifier("\(prefix).message")
        message.isSelectable = true
        location.isSelectable = true
        location.lineBreakMode = .byCharWrapping
        actionButton.target = self
        actionButton.action = #selector(install(_:))
        moreButton.target = self
        moreButton.action = #selector(showMenu(_:))
        moreButton.setAccessibilityLabel(L("settings.integration.actions"))
        moreButton.widthAnchor.constraint(equalToConstant: 34).isActive = true
        actionButton.widthAnchor.constraint(equalToConstant: 128).isActive = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityIdentifier("\(prefix).progress")
        NSLayoutConstraint.activate([
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16)
        ])
        let labels = AgentSettingsStyle.stack(spacing: 4)
        AgentSettingsStyle.add(name, to: labels)
        AgentSettingsStyle.add(status, to: labels)
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [labels, spinner, actionButton, moreButton])
        header.orientation = .horizontal
        header.distribution = .fill
        header.alignment = .centerY
        header.spacing = 10
        header.detachesHiddenViews = true
        let content = AgentSettingsStyle.stack(spacing: 7)
        AgentSettingsStyle.add(header, to: content)
        AgentSettingsStyle.add(location, to: content)
        AgentSettingsStyle.add(message, to: content)
        addSubview(content)
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            separator.topAnchor.constraint(equalTo: content.bottomAnchor, constant: 14),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("AgentIntegrationRow requires a target") }

    func update(_ agent: AgentIntegration, notice: AgentSettingsNotice?, busy: Bool, enabled: Bool) {
        name.stringValue = agent.label
        let integration: String
        switch agent.state {
        case "current": integration = L("settings.integration.current")
        case "outdated": integration = L("settings.integration.outdated")
        case "notInstalled": integration = L("settings.integration.notInstalled")
        default: integration = L("settings.integration.unknown")
        }
        status.stringValue = integration + (agent.available ? "" : L("settings.integration.notFoundSuffix")) + "\n" + agent.capabilities
        status.textColor = agent.state == "unknown" ? .systemOrange : TavernAppearance.secondary
        status.toolTip = agent.details
        var paths: [String] = []
        if let executable = agent.executablePath { paths.append(L("settings.integration.commandPath", executable)) }
        if let profile = agent.profileDirectory { paths.append(L("settings.integration.selectedProfile", profile)) }
        location.stringValue = paths.joined(separator: "\n")
        location.isHidden = paths.isEmpty
        var messages = notice.map { [$0.text()] } ?? []
        if agent.state == "unknown", !agent.details.isEmpty { messages.append(agent.details) }
        message.stringValue = messages.joined(separator: "\n")
        message.textColor = notice?.isError == true || agent.state == "unknown" ? .systemOrange : TavernAppearance.accent
        message.isHidden = messages.isEmpty
        actionButton.title = L(busy ? "settings.integration.connecting" : agent.needsUpdate ? "settings.integration.update" : "settings.integration.connect")
        actionButton.prepare(style: .utility)
        actionButton.setAccessibilityLabel(L("settings.sound.eventAction", agent.label, actionButton.title))
        actionButton.isHidden = agent.state == "current"
        actionButton.isEnabled = enabled && agent.available && (agent.state == "notInstalled" || agent.needsUpdate)
        actionButton.toolTip = agent.available ? nil : L("settings.integration.installAgentHint")
        moreButton.isEnabled = enabled
        moreButton.setAccessibilityLabel(L("settings.integration.agentActions", agent.label))
        spinner.isHidden = !busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    @objc private func install(_ sender: NSButton) {
        guard sender.isEnabled else { return }
        onInstall?()
    }
    @objc private func showMenu(_ sender: NSButton) {
        guard sender.isEnabled else { return }
        onMenu?(sender)
    }
}

final class AgentSettingsView: NSView {
    var onInteraction: (() -> Void)?
    private let service: AgentIntegrationService
    private let refreshButton: TavernButton
    private let disclosure = NSButton(title: L("settings.integration.otherAgents"), target: nil, action: nil)
    private let progress = TavernProgressIndicator()
    private let globalMessage = AgentSettingsStyle.label("")
    private let emptyMessage = AgentSettingsStyle.label(L("settings.integration.checking"))
    private let primaryRows = AgentSettingsStyle.stack(spacing: 0)
    private let otherRows = AgentSettingsStyle.stack(spacing: 0)
    private var agents: [AgentIntegration] = []
    private var rows: [String: AgentIntegrationRow] = [:]
    private var notices: [String: AgentSettingsNotice] = [:]
    private var operationDetails: [String: String] = [:]
    private var isRefreshing = false
    private var hasFreshStatus = false
    private var busyTarget: String?
    private var expanded = false
    private var languageObserver: NSObjectProtocol?
    private var languageUpdates: [() -> Void] = []
    private var sheetLanguageUpdate: (() -> Void)?
    private var refreshError: Error?

    init(service: AgentIntegrationService) {
        self.service = service
        refreshButton = AgentSettingsStyle.button(L("settings.integration.refresh"), identifier: "agentSettings.refresh", target: nil, action: nil)
        super.init(frame: .zero)
        setAccessibilityIdentifier("agentSettings.content")
        buildContent()
        languageObserver = NotificationCenter.default.addObserver(forName: .tavernLanguageDidChange, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.languageUpdates.forEach { $0() }
            self.sheetLanguageUpdate?()
            self.updateControls()
        }
    }

    required init?(coder: NSCoder) { fatalError("AgentSettingsView requires an integration service") }
    deinit {
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
    }

    private func localizedLabel(_ key: String, font: NSFont = TavernAppearance.detailFont,
                                color: NSColor = TavernAppearance.secondary) -> NSTextField {
        let field = AgentSettingsStyle.label(L(key), font: font, color: color)
        languageUpdates.append { [weak field] in field?.stringValue = L(key) }
        return field
    }

    func refresh() {
        guard !isRefreshing, busyTarget == nil else { return }
        isRefreshing = true
        hasFreshStatus = false
        refreshError = nil
        globalMessage.stringValue = ""
        globalMessage.isHidden = true
        updateControls()
        service.list { [weak self] result in
            guard let self else { return }
            self.isRefreshing = false
            switch result {
            case .success(let agents):
                self.agents = agents
                self.hasFreshStatus = true
                self.reconcileRows()
                self.emptyMessage.stringValue = L("settings.integration.empty")
                self.emptyMessage.isHidden = !agents.isEmpty
            case .failure(let error):
                self.refreshError = error
                self.globalMessage.isHidden = false
                self.emptyMessage.isHidden = true
            }
            self.updateControls()
        }
    }

    private func buildContent() {
        let content = AgentSettingsStyle.stack(spacing: 12)
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 32),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18)
        ])
        let title = localizedLabel("settings.integration.yourAgents", font: TavernAppearance.headingFont, color: TavernAppearance.text)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        refreshButton.target = self
        refreshButton.action = #selector(refreshPressed(_:))
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.setAccessibilityIdentifier("agentSettings.progress")
        NSLayoutConstraint.activate([
            progress.widthAnchor.constraint(equalToConstant: 16),
            progress.heightAnchor.constraint(equalToConstant: 16)
        ])
        let header = NSStackView(views: [title, progress, refreshButton])
        header.orientation = .horizontal
        header.distribution = .fill
        header.alignment = .centerY
        header.spacing = 10
        AgentSettingsStyle.add(header, to: content)
        let explanation = localizedLabel("settings.integration.explanation")
        explanation.setAccessibilityIdentifier("agentSettings.explanation")
        AgentSettingsStyle.add(explanation, to: content)
        globalMessage.textColor = .systemOrange
        globalMessage.isSelectable = true
        globalMessage.isHidden = true
        globalMessage.setAccessibilityIdentifier("agentSettings.error")

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        let scroller = TavernScroller()
        scroller.controlSize = .small
        scroll.verticalScroller = scroller
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.setAccessibilityIdentifier("agentSettings.scroll")
        AgentSettingsStyle.add(scroll, to: content)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        let document = AgentSettingsDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        let list = AgentSettingsStyle.stack(spacing: 12)
        document.addSubview(list)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        AgentSettingsStyle.add(globalMessage, to: list)
        emptyMessage.setAccessibilityIdentifier("agentSettings.empty")
        AgentSettingsStyle.add(emptyMessage, to: list)
        let board = TavernBoardPanel()
        board.translatesAutoresizingMaskIntoConstraints = false
        board.addSubview(primaryRows)
        NSLayoutConstraint.activate([
            primaryRows.leadingAnchor.constraint(equalTo: board.leadingAnchor),
            primaryRows.trailingAnchor.constraint(equalTo: board.trailingAnchor),
            primaryRows.topAnchor.constraint(equalTo: board.topAnchor),
            primaryRows.bottomAnchor.constraint(equalTo: board.bottomAnchor)
        ])
        AgentSettingsStyle.add(board, to: list)
        disclosure.setButtonType(.pushOnPushOff)
        disclosure.bezelStyle = .recessed
        disclosure.isBordered = false
        disclosure.alignment = .left
        disclosure.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        disclosure.imagePosition = .imageLeading
        disclosure.font = TavernAppearance.smallFont
        disclosure.contentTintColor = TavernAppearance.accent
        disclosure.target = self
        disclosure.action = #selector(toggleOthers(_:))
        disclosure.setAccessibilityIdentifier("agentSettings.otherAgents")
        disclosure.setAccessibilityLabel(L("settings.integration.expand"))
        AgentSettingsStyle.add(disclosure, to: list)
        AgentSettingsStyle.add(otherRows, to: list)
        otherRows.isHidden = true
        disclosure.isHidden = true
        let footer = localizedLabel("settings.integration.restartNote")
        footer.setAccessibilityIdentifier("agentSettings.restartNote")
        AgentSettingsStyle.add(footer, to: content)
    }

    private func reconcileRows() {
        let retainedTargets = Set(agents.map(\.target))
        for target in Array(rows.keys) where !retainedTargets.contains(target) {
            rows.removeValue(forKey: target)?.removeFromSuperview()
        }
        for stack in [primaryRows, otherRows] {
            for view in stack.arrangedSubviews {
                stack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
        }
        for agent in agents {
            let row: AgentIntegrationRow
            if let existing = rows[agent.target] {
                row = existing
            } else {
                row = AgentIntegrationRow(target: agent.target)
                let target = agent.target
                row.onInstall = { [weak self] in self?.install(target: target) }
                row.onMenu = { [weak self] sender in self?.showMenu(target: target, sender: sender) }
                rows[agent.target] = row
            }
            let main = agent.available || agent.installed || agent.executablePath != nil || agent.profileDirectory != nil || notices[agent.target] != nil
            let destination = main ? primaryRows : otherRows
            destination.addArrangedSubview(row)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalTo: destination.widthAnchor).isActive = true
        }
        primaryRows.superview?.isHidden = primaryRows.arrangedSubviews.isEmpty
        disclosure.isHidden = otherRows.arrangedSubviews.isEmpty
        otherRows.isHidden = !expanded || otherRows.arrangedSubviews.isEmpty
    }

    private func updateControls() {
        refreshButton.title = L("settings.integration.refresh")
        refreshButton.setAccessibilityLabel(refreshButton.title)
        disclosure.title = L("settings.integration.otherAgents")
        disclosure.setAccessibilityLabel(L(expanded ? "settings.integration.collapse" : "settings.integration.expand"))
        emptyMessage.stringValue = L(isRefreshing ? "settings.integration.checking" : "settings.integration.empty")
        if let refreshError {
            globalMessage.stringValue = L("settings.integration.checkFailed", refreshError.localizedDescription)
                + (agents.isEmpty ? "" : L("settings.integration.stale"))
        }
        let enabled = !isRefreshing && busyTarget == nil
        refreshButton.isEnabled = enabled
        if isRefreshing { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        progress.isHidden = !isRefreshing
        for agent in agents {
            rows[agent.target]?.update(agent, notice: notices[agent.target], busy: busyTarget == agent.target,
                                      enabled: enabled && hasFreshStatus)
        }
    }

    @objc private func refreshPressed(_ sender: NSButton) {
        guard sender.isEnabled, !isRefreshing, busyTarget == nil else { return }
        onInteraction?()
        refresh()
    }

    @objc private func toggleOthers(_ sender: NSButton) {
        guard sender.isEnabled else { return }
        onInteraction?()
        expanded = sender.state == .on
        otherRows.isHidden = !expanded
        sender.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        sender.setAccessibilityLabel(L(expanded ? "settings.integration.collapse" : "settings.integration.expand"))
    }

    private func install(target: String) {
        guard !isRefreshing, busyTarget == nil, hasFreshStatus,
              let agent = agents.first(where: { $0.target == target }), agent.available,
              agent.state == "notInstalled" || agent.needsUpdate else { return }
        onInteraction?()
        run(target: target, success: "settings.integration.installedNotice") { completion in
            service.install(target: target, completion: completion)
        }
    }

    private func run(target: String, success: String,
                     operation: (@escaping (Result<String, Error>) -> Void) -> Void) {
        busyTarget = target
        notices[target] = AgentSettingsNotice(text: { L("settings.integration.configuring") }, isError: false)
        updateControls()
        operation { [weak self] result in
            guard let self else { return }
            self.busyTarget = nil
            switch result {
            case .success(let output):
                self.operationDetails[target] = output.trimmingCharacters(in: .whitespacesAndNewlines)
                self.notices[target] = AgentSettingsNotice(text: { L(success) }, isError: false)
            case .failure(let error):
                self.notices[target] = AgentSettingsNotice(text: { L("settings.integration.changeFailed", error.localizedDescription) }, isError: true)
            }
            self.updateControls()
            self.refresh()
        }
    }

    private func showMenu(target: String, sender: NSButton) {
        guard sender.isEnabled, !isRefreshing, busyTarget == nil, hasFreshStatus,
              let agent = agents.first(where: { $0.target == target }) else { return }
        onInteraction?()
        let menu = NSMenu()
        menu.autoenablesItems = false
        func item(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = target
            item.isEnabled = enabled
            item.setAccessibilityIdentifier("agentSettings.agent.\(target).menu.\(NSStringFromSelector(action).replacingOccurrences(of: ":", with: ""))")
            menu.addItem(item)
        }
        item(L("settings.integration.details"), #selector(showDetails(_:)))
        item(L("settings.integration.instructions"), #selector(openInstructions(_:)))
        if agent.supportsProfileDirectory {
            item(L("settings.integration.chooseProfile"), #selector(chooseProfile(_:)))
            if agent.profileDirectory != nil { item(L("settings.integration.defaultProfile"), #selector(resetProfile(_:))) }
        }
        if !agent.available || agent.executablePath != nil {
            item(L("settings.integration.chooseExecutable"), #selector(chooseExecutable(_:)))
        }
        if agent.executablePath != nil { item(L("settings.integration.automaticCommand"), #selector(resetExecutable(_:))) }
        if agent.installed {
            menu.addItem(.separator())
            item(L("settings.integration.remove"), #selector(removeIntegration(_:)))
        }
        TavernContextMenu.popUp(menu, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
    }

    private func agent(for item: NSMenuItem) -> AgentIntegration? {
        guard item.isEnabled, !isRefreshing, busyTarget == nil, hasFreshStatus,
              let target = item.representedObject as? String else { return nil }
        return agents.first(where: { $0.target == target })
    }

    @objc private func openInstructions(_ sender: NSMenuItem) {
        guard agent(for: sender) != nil,
              let url = URL(string: "https://herdr.dev/docs/agents/") else { return }
        onInteraction?()
        NSWorkspace.shared.open(url)
    }

    @objc private func showDetails(_ sender: NSMenuItem) {
        guard let agent = agent(for: sender), let window else { return }
        onInteraction?()
        let alert = TavernDialog()
        alert.messageText = agent.label
        alert.informativeText = L("settings.integration.detailsNote")
        alert.addButton(withTitle: L("settings.close"))
        let lastOperation = operationDetails[agent.target]
        func details() -> String {
            var value = L("settings.integration.detailsBody", agent.target, agent.command, L(agent.available ? "settings.yes" : "settings.no"), agent.details)
            if let result = lastOperation, !result.isEmpty {
                value += L("settings.integration.lastOperation", result)
            }
            if let path = agent.executablePath { value += "\n\n" + L("settings.integration.executablePath", path) }
            if let profile = agent.profileDirectory { value += "\n\n" + L("settings.integration.selectedProfile", profile) }
            if !agent.supportsProfileDirectory { value += "\n\n" + L("settings.integration.profileNotSupported") }
            return value
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 250))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.isSelectable = true
        text.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        text.string = details()
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.setAccessibilityIdentifier("agentSettings.agent.\(agent.target).details")
        scroll.documentView = text
        alert.accessoryView = scroll
        alert.localizationUpdater = { [weak text] dialog in
            dialog.informativeText = L("settings.integration.detailsNote")
            dialog.buttons.first?.title = L("settings.close")
            dialog.buttons.first?.setAccessibilityLabel(L("settings.close"))
            text?.string = details()
        }
        alert.beginSheetModal(for: window)
    }

    @objc private func chooseExecutable(_ sender: NSMenuItem) {
        guard let agent = agent(for: sender), let window else { return }
        onInteraction?()
        let panel = NSOpenPanel()
        TavernMotion.configureWindow(panel)
        panel.title = L("settings.integration.executableTitle", agent.label)
        panel.message = L("settings.integration.executableMessage", agent.command)
        panel.prompt = L("settings.choose")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if let path = agent.executablePath { panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent() }
        sheetLanguageUpdate = { [weak panel] in
            panel?.title = L("settings.integration.executableTitle", agent.label)
            panel?.message = L("settings.integration.executableMessage", agent.command)
            panel?.prompt = L("settings.choose")
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            self?.sheetLanguageUpdate = nil
            guard let self, response == .OK, let url = panel.url else { return }
            self.service.setExecutablePath(url.path, for: agent.target)
            self.notices[agent.target] = AgentSettingsNotice(text: { L("settings.integration.executableSaved") }, isError: false)
            self.refresh()
        }
    }

    @objc private func chooseProfile(_ sender: NSMenuItem) {
        guard let agent = agent(for: sender), agent.supportsProfileDirectory, let window else { return }
        onInteraction?()
        let panel = NSOpenPanel()
        TavernMotion.configureWindow(panel)
        panel.title = L("settings.integration.profileTitle", agent.label)
        panel.message = agent.profileDirectoryHint + " " + L("settings.integration.profileMessage")
        panel.prompt = L("settings.integration.profilePrompt")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if let path = agent.profileDirectory { panel.directoryURL = URL(fileURLWithPath: path) }
        sheetLanguageUpdate = { [weak panel] in
            panel?.title = L("settings.integration.profileTitle", agent.label)
            panel?.message = agent.profileDirectoryHint + " " + L("settings.integration.profileMessage")
            panel?.prompt = L("settings.integration.profilePrompt")
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            self?.sheetLanguageUpdate = nil
            guard let self, response == .OK, let url = panel.url else { return }
            self.service.setProfileDirectory(url.path, for: agent.target)
            self.notices[agent.target] = AgentSettingsNotice(text: { L("settings.integration.profileSaved", url.path) }, isError: false)
            self.refresh()
        }
    }

    @objc private func resetProfile(_ sender: NSMenuItem) {
        guard let agent = agent(for: sender) else { return }
        onInteraction?()
        service.setProfileDirectory(nil, for: agent.target)
        notices[agent.target] = AgentSettingsNotice(text: { L("settings.integration.defaultProfileSaved") }, isError: false)
        refresh()
    }

    @objc private func resetExecutable(_ sender: NSMenuItem) {
        guard let agent = agent(for: sender) else { return }
        onInteraction?()
        service.setExecutablePath(nil, for: agent.target)
        notices[agent.target] = AgentSettingsNotice(text: { L("settings.integration.automaticCommandSaved") }, isError: false)
        refresh()
    }

    @objc private func removeIntegration(_ sender: NSMenuItem) {
        guard let agent = agent(for: sender), agent.installed, let window else { return }
        onInteraction?()
        let alert = TavernDialog()
        alert.alertStyle = .warning
        alert.messageText = L("settings.integration.removeTitle", agent.label)
        func message() -> String {
            let profile = agent.profileDirectory.map { "\n" + L("settings.integration.selectedProfile", $0) } ?? ""
            return L("settings.integration.removeMessage", profile)
        }
        alert.informativeText = message()
        alert.addButton(withTitle: L("settings.integration.removeAction"))
        alert.addButton(withTitle: L("settings.cancel"))
        alert.buttons[0].hasDestructiveAction = true
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        alert.localizationUpdater = { dialog in
            dialog.messageText = L("settings.integration.removeTitle", agent.label)
            dialog.informativeText = message()
            dialog.buttons[0].title = L("settings.integration.removeAction")
            dialog.buttons[0].setAccessibilityLabel(dialog.buttons[0].title)
            dialog.buttons[1].title = L("settings.cancel")
            dialog.buttons[1].setAccessibilityLabel(dialog.buttons[1].title)
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn, !self.isRefreshing, self.busyTarget == nil else { return }
            self.onInteraction?()
            self.run(target: agent.target, success: "settings.integration.removedNotice") { completion in
                self.service.uninstall(target: agent.target, completion: completion)
            }
        }
    }
}
