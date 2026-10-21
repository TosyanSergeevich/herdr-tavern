import AppKit

struct EndpointAction {
    let id: String
    let boot: String
    let method: String
    let params: [String: Any]
    let completion: (([String: Any]) -> Void)?
}
private struct MenuTarget {
    enum Kind: String { case pane, tab }
    let kind: Kind
    let id: String
    let boot: String
    let generation: Int
}
private struct NavigationKey: Hashable {
    let action: String
    let target: String
}
final class NavigationButton: TavernButton {
    var actionName = ""
    var targetID = ""
    var contextMenu: (() -> NSMenu?)?
    var dragMouseDown: ((NavigationButton, NSEvent) -> Bool)?
    override func menu(for event: NSEvent) -> NSMenu? {
        guard isEnabled else { return nil }
        return contextMenu?()
    }
    override func rightMouseDown(with event: NSEvent) {
        if let menu = menu(for: event) { TavernContextMenu.popUp(menu, with: event, for: self) }
    }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), contextMenu != nil {
            if let menu = menu(for: event) { TavernContextMenu.popUp(menu, with: event, for: self) }
            return
        }
        if isEnabled, dragMouseDown?(self, event) == true { return }
        super.mouseDown(with: event)
    }
}
private final class NavigationTransitionView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
final class TavernDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSSplitViewDelegate, NSMenuItemValidation {
    private var window: NSWindow!
    private var surface: SurfaceView!
    private var popupSurface: SurfaceView!
    private var popupTitle = NSTextField(labelWithString: "")
    private let popupCloseButton = TavernButton()
    private var popupContainer = NSBox()
    private let popupChrome = LivingChromeView(role: .body)
    private var root: NSView!
    private var mainSplit: NSSplitView!
    private var sidebarPanel = NSView()
    private var sidebar = NSView()
    private var agentChains: [String: AgentChainView] = [:]
    private var sidebarScroll = NSScrollView()
    private let sidebarChrome = LivingChromeView(role: .sidebar)
    private let sidebarHeading = NSTextField(labelWithString: L("shell.workspaces"))
    private let createWorkspaceButton = NavigationButton()
    private let agentsHeading = NSTextField(labelWithString: L("shell.agents"))
    private let agentsDivider = SectionDivider()
    private let emptyAgentsLabel = NSTextField(labelWithString: L("shell.agents.empty"))
    private var sidebarButtons: [NavigationKey: NavigationButton] = [:]
    private var tabButtons: [NavigationKey: NavigationButton] = [:]
    private var sidebarTransitionView: NSView?
    private let rootChrome = LivingChromeView(role: .root)
    private let tabsChrome = LivingChromeView(role: .tabs)
    private let terminalChrome = LivingChromeView(role: .body)
    private let statusLight = TavernStatusLight()
    private let settingsButton = TavernButton(title: "", target: nil, action: nil)
    private var body = ChromeView(fill: TavernAppearance.chrome, material: .grain)
    private var terminalFrame = NSView()
    private var tabScroll = TavernTabScrollView()
    private let tabRecess = TavernTabRecessView(frame: .zero)
    private var tabbar = NSView()
    private var addTab = NavigationButton()
    private var status = NSTextField(labelWithString: L("shell.connecting.initial"))
    private var reconnectButton = TavernButton(title: L("shell.connect"), target: nil, action: nil)
    private var reconnectVisible = true
    private var reconnectVisibilityGeneration = 0
    private var sidebarWidth: CGFloat = 230
    private var navigationWorkspace = ""
    private var navigationPane = ""
    private var navigationTab = ""
    private var navigationTabViewportWidth: CGFloat = 0
    private var snapshot: [String: Any] = [:]
    private var pendingSnapshot: [String: Any]?
    private var connection: RustConnection?
    private var options: LaunchOptions?
    private let terminalLaunchEnvironment = ["PI_FORCE_IMAGE_PROTOCOL": "kitty"]
    private var generation = 0
    private var connecting = false
    private var attached = false
    private var terminated = false
    private var surfaceActive = true
    private var resumeRequested = false
    private var requests: [EndpointAction] = []
    private var inFlight: EndpointAction?
    private var requestTimeout: Timer?
    private var lastGeometry = ""
    private var navSignature: Data?
    private var lastError: String?
    private var lastErrorLocalization: (() -> String)?
    private var publicRequestBusy = false
    private var popupID = ""
    private let soundSettings = TavernSoundSettings()
    private lazy var soundPlayer = TavernSoundPlayer(settings: soundSettings)
    private var settingsController: TavernSettingsWindowController?
    private var herdrMenuController: HerdrMenuController?
    private var herdrSetup: HerdrSetupController?
    private lazy var agentIntegrations = AgentIntegrationService(executable: { [weak self] in
        guard let options = self?.options else { throw TavernShellError { L("shell.error.launchOptions") } }
        return try options.resolveExecutable()
    })
    private var agentWelcome: AgentWelcomeWindowController?
    private let notifications = TavernNotifications()
    private var unread = AgentUnreadTracker()
    private let navigationDrag = TavernNavigationDrag()
    private var paneGrips: [String: TavernPaneGrip] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launchOptions: LaunchOptions
        do {
            launchOptions = try LaunchOptions.parse(CommandLine.arguments)
            options = launchOptions
        }
        catch { showStartupError(error.localizedDescription); return }
        let fonts: TerminalFonts
        do { fonts = try TerminalFonts.load(size: 16) }
        catch { showStartupError(error.localizedDescription); return }
        do { try TavernAppearance.validateFonts() }
        catch { showStartupError(error.localizedDescription); return }
        do {
            _ = try TavernMaterials.bundled.get()
            try LivingChromeView.validateResources()
            try TavernCardSurfaceView.validateResources()
            try TavernTalismanView.validateResources()
            try TavernRuneParticlesView.validateResources()
        }
        catch { showStartupError(error.localizedDescription); return }
        do { _ = try launchOptions.resolveExecutable() }
        catch NativeError.herdrNotFound {
            let setup = HerdrSetupController()
            herdrSetup = setup
            NSApp.activate(ignoringOtherApps: true)
            setup.present { [weak self] installed in
                guard let self else { return }
                self.herdrSetup = nil
                if installed { self.startInterface(fonts: fonts) }
                else { NSApp.terminate(nil) }
            }
            return
        }
        catch { showStartupError(error.localizedDescription); return }
        startInterface(fonts: fonts)
    }

    private func startInterface(fonts: TerminalFonts) {
        surface = SurfaceView(fonts: fonts)
        popupSurface = SurfaceView(fonts: fonts)
        buildWindow(); buildMenus(); wireSurface(surface)
        NotificationCenter.default.addObserver(self, selector: #selector(languageDidChange(_:)),
                                               name: .tavernLanguageDidChange, object: nil)
        soundSettings.onChange = { [weak self] in self?.soundPlayer.settingsDidChange() }
        soundPlayer.onError = { [weak self] message in
            guard let self else { return }
            self.lastErrorLocalization = nil; self.lastError = message; self.updateStatus()
            if let settingsWindow = self.settingsController?.window, settingsWindow.isVisible,
               settingsWindow.attachedSheet == nil {
                let alert = TavernDialog(); alert.messageText = L("shell.error.sound")
                alert.localizationUpdater = { $0.messageText = L("shell.error.sound") }
                alert.informativeText = message; alert.beginSheetModal(for: settingsWindow)
            }
        }
        notifications.onError = { [weak self] message in
            self?.lastErrorLocalization = nil; self?.lastError = message; self?.updateStatus()
        }
        notifications.onOpen = { [weak self] context in self?.openNotification(context) }
        notifications.prepare()
        popupSurface.send = { [weak self] command in
            guard let self, !self.popupID.isEmpty else { return }
            var command = command; command.removeValue(forKey: "pane_id"); command["terminal_id"] = self.popupID
            self.send(command)
        }
        window.center(); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(surface)
        NSApp.activate(ignoringOtherApps: true)
        connect()
        DispatchQueue.main.async { [weak self] in self?.offerAgentSetup() }
    }
    private func showStartupError(_ message: String) {
        let alert = TavernDialog(useBundledAppearance: false); alert.messageText = "Herdr Tavern"; alert.informativeText = message
        alert.addButton(withTitle: L("shell.close")); alert.runModal(); NSApp.terminate(nil)
    }
    private func wireSurface(_ view: SurfaceView) {
        view.send = { [weak self] command in self?.send(command) }
        view.invokeCommand = { [weak self] id, selection in self?.invokeConfiguredCommand(id, selection: selection) }
        view.request = { [weak self] method, params in self?.request(method, params) }
        view.focusPane = { [weak self] id in self?.request("pane.focus", ["pane_id": id]) }
        view.contextMenuForPane = { [weak self] id in self?.paneContextMenu(id) }
        view.presentContextMenu = { TavernContextMenu.popUp($0, with: $1, for: $2) }
        view.workingDirectoryForPane = { [weak self, weak view] id in
            guard let self, let view,
                  string(view.scene["boot_id"]) == string(self.snapshot["boot_id"]),
                  integer(view.scene["projection_revision"]) == integer(self.snapshot["revision"]),
                  let pane = objects(self.snapshot["panes"]).first(where: { string($0["pane_id"]) == id }) else { return nil }
            return [string(pane["foreground_cwd"]), string(pane["cwd"])].first(where: { !$0.isEmpty })
        }
        view.openLink = { [weak self] url in
            if !NSWorkspace.shared.open(url) { self?.localizedError { L("shell.error.openLink", url.isFileURL ? url.path : url.absoluteString) } }
        }
        view.readSelection = { [weak self] params, completion in self?.readTerminalSelection(params, completion: completion) }
        view.selectionError = { [weak self] message in self?.error(message) }
        view.geometryChanged = { [weak self] cols, rows, width, height in self?.resize(cols: cols, rows: rows, width: width, height: height) }
    }
    private func readTerminalSelection(_ params: [String: Any], completion: @escaping (Result<String, Error>) -> Void) {
        let pane = string(params["pane_id"]), boot = string(snapshot["boot_id"])
        guard let options, attached, !boot.isEmpty,
              objects(snapshot["panes"]).contains(where: { string($0["pane_id"]) == pane }) else {
            completion(.failure(TavernShellError { L("shell.error.selectionPane") })); return
        }
        let epoch = generation, id = UUID().uuidString
        let command: [String: Any] = ["id": id, "method": "pane.selection.read", "params": params]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<String, Error>
            do {
                let response = try RustConnection.publicRequest(path: options.publicSocketPath, request: command)
                guard string(response["id"]) == id else { throw TavernShellError { L("shell.error.selectionMismatch") } }
                let rejection = dictionary(response["error"])
                if !rejection.isEmpty {
                    if string(rejection["code"]) == "stale_content" { throw TerminalSelectionReadError.staleContent }
                    throw TavernShellError { L("shell.error.selectionRejected", string(rejection["message"]), string(rejection["code"])) }
                }
                let value = dictionary(response["result"])
                guard string(value["type"]) == "pane_selection", string(value["pane_id"]) == pane,
                      let text = value["text"] as? String else { throw TavernShellError { L("shell.error.selectionResponse") } }
                result = .success(text)
            } catch { result = .failure(error) }
            DispatchQueue.main.async {
                guard let self, self.generation == epoch, self.attached, !self.terminated,
                      string(self.snapshot["boot_id"]) == boot,
                      objects(self.snapshot["panes"]).contains(where: { string($0["pane_id"]) == pane }) else { return }
                completion(result)
            }
        }
    }
    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 680),
                          styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        window.title = "Herdr Tavern"; window.minSize = NSSize(width: 680, height: 400); window.delegate = self
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = TavernAppearance.wood
        window.titlebarAppearsTransparent = true
        root = ChromeView(frame: NSRect(x: 0, y: 0, width: 1080, height: 680),
                          fill: TavernAppearance.wood, material: .wood)
        window.contentView = root
        let statusBackground = LivingChromeView(role: .status)
        statusBackground.frame = NSRect(x: 8, y: 11, width: 1064, height: 30)
        statusBackground.autoresizingMask = [.width]; root.addSubview(statusBackground)
        mainSplit = TavernSplitView(frame: NSRect(x: 8, y: 41, width: 1064, height: 631))
        mainSplit.isVertical = true; mainSplit.dividerStyle = .thin; mainSplit.autoresizingMask = [.width,.height]
        root.addSubview(mainSplit)
        sidebarPanel.frame = NSRect(x: 0, y: 0, width: 230, height: 631)
        sidebarChrome.frame = sidebarPanel.bounds
        sidebarChrome.autoresizingMask = [.width, .height]
        sidebarPanel.addSubview(sidebarChrome)
        sidebarScroll.hasVerticalScroller = true; sidebarScroll.autohidesScrollers = true
        let sidebarScroller = TavernScroller(); sidebarScroller.controlSize = .small
        sidebarScroller.setAccessibilityIdentifier("navigation.sidebar.scrollbar")
        sidebarScroll.verticalScroller = sidebarScroller
        sidebarScroll.setAccessibilityIdentifier("navigation.sidebar")
        sidebarScroll.drawsBackground = false; sidebarScroll.contentView.drawsBackground = false
        sidebarScroll.contentView.postsBoundsChangedNotifications = true
        sidebarScroll.documentView = sidebar; sidebarPanel.addSubview(sidebarScroll)
        agentsHeading.font = TavernAppearance.headingFont
        agentsHeading.textColor = TavernAppearance.accent
        emptyAgentsLabel.font = TavernAppearance.smallFont; emptyAgentsLabel.textColor = TavernAppearance.secondary
        agentsHeading.wantsLayer = true; agentsDivider.wantsLayer = true
        sidebar.addSubview(agentsDivider); sidebar.addSubview(agentsHeading); sidebar.addSubview(emptyAgentsLabel)
        sidebarHeading.font = TavernAppearance.workspaceHeadingFont
        sidebarHeading.textColor = TavernAppearance.accent
        sidebarHeading.lineBreakMode = .byTruncatingTail; sidebarHeading.toolTip = L("shell.workspaces")
        sidebarPanel.addSubview(sidebarHeading)
        createWorkspaceButton.title = "+"; createWorkspaceButton.actionName = "workspace.create"
        createWorkspaceButton.target = self; createWorkspaceButton.action = #selector(navigate(_:))
        createWorkspaceButton.role = .primary
        createWorkspaceButton.prepare(style: .utility)
        createWorkspaceButton.setAccessibilityLabel(L("shell.workspace.new")); createWorkspaceButton.toolTip = L("shell.workspace.new")
        createWorkspaceButton.setAccessibilityIdentifier("navigation.workspace.create")
        sidebarPanel.addSubview(createWorkspaceButton)
        mainSplit.addSubview(sidebarPanel)
        body.frame = NSRect(x: 237, y: 0, width: 827, height: 631); mainSplit.addSubview(body)
        mainSplit.delegate = self
        body.addSubview(tabsChrome)
        tabScroll.hasHorizontalScroller = true; tabScroll.autohidesScrollers = true
        let tabScroller = TavernScroller()
        tabScroller.controlSize = .small; tabScroll.horizontalScroller = tabScroller
        tabScroll.drawsBackground = false; tabScroll.contentView.drawsBackground = false
        tabScroll.documentView = tabbar; body.addSubview(tabScroll)
        addTab.title = "+"; addTab.actionName = "tab.create"; addTab.target = self; addTab.action = #selector(navigate(_:))
        addTab.symbolName = ""; addTab.prepare(style: .addTab)
        addTab.setAccessibilityLabel(L("shell.tab.new")); addTab.setAccessibilityIdentifier("navigation.tab.create")
        body.addSubview(addTab)
        tabScroll.addButton = addTab
        tabScroll.onScrollerStyleChange = { [weak self] in self?.layoutBody() }
        tabScroll.verticalScrollElasticity = .none
        terminalFrame.wantsLayer = true
        terminalFrame.layer?.backgroundColor = TavernAppearance.terminal.cgColor
        body.addSubview(terminalFrame); terminalFrame.addSubview(surface)
        body.addSubview(terminalChrome)
        body.addSubview(tabRecess)
        popupContainer.boxType = .custom; popupContainer.borderType = .lineBorder
        popupContainer.borderColor = TavernAppearance.border
        popupContainer.fillColor = TavernAppearance.chrome; popupContainer.contentViewMargins = .zero
        popupTitle.font = TavernAppearance.bodyFont; popupTitle.textColor = TavernAppearance.text
        popupCloseButton.title = ""; popupCloseButton.symbolName = "xmark"
        popupCloseButton.target = self; popupCloseButton.action = #selector(closePopup(_:))
        popupCloseButton.prepare(style: .utility)
        popupCloseButton.toolTip = L("shell.dialog.close")
        popupCloseButton.setAccessibilityLabel(L("shell.dialog.close"))
        popupCloseButton.setAccessibilityIdentifier("terminal.popup.close")
        popupContainer.isHidden = true; body.addSubview(popupContainer)
        popupContainer.contentView?.addSubview(popupTitle); popupContainer.contentView?.addSubview(popupSurface)
        if let content = popupContainer.contentView {
            popupChrome.frame = content.bounds; popupChrome.autoresizingMask = [.width, .height]
            content.addSubview(popupChrome)
            content.addSubview(popupCloseButton)
        }
        settingsButton.target = self; settingsButton.action = #selector(showSettings(_:))
        settingsButton.symbolName = "wrench.and.screwdriver"; settingsButton.prepare(style: .utility)
        settingsButton.toolTip = L("shell.settings"); settingsButton.setAccessibilityLabel(L("shell.settings"))
        root.addSubview(settingsButton)
        root.addSubview(statusLight)
        status.font = TavernAppearance.statusFont; status.textColor = TavernAppearance.secondary
        status.lineBreakMode = .byTruncatingMiddle; status.setAccessibilityLabel(L("shell.connection.status")); root.addSubview(status)
        reconnectButton.role = .primary
        reconnectButton.target = self; reconnectButton.action = #selector(reconnect(_:)); reconnectButton.prepare(style: .utility)
        reconnectButton.setAccessibilityIdentifier("connection.reconnect")
        root.addSubview(reconnectButton)
        rootChrome.frame = root.bounds; rootChrome.autoresizingMask = [.width, .height]; root.addSubview(rootChrome)
        layoutBody(); mainSplit.setPosition(230, ofDividerAt: 0)
    }
    private func prepareSettings() -> TavernSettingsWindowController {
        if let settingsController { return settingsController }
        let controller = TavernSettingsWindowController(settings: soundSettings, player: soundPlayer,
                                                        integrations: agentIntegrations)
        settingsController = controller
        return controller
    }
    @objc private func showSettings(_ sender: Any?) {
        soundPlayer.play(.interfaceClick)
        prepareSettings().showWindow(sender)
    }
    @objc private func showAgentSettings(_ sender: Any?) {
        soundPlayer.play(.interfaceClick)
        prepareSettings().showAgents()
    }
    private func offerAgentSetup() {
        let key = "HerdrTavern.agentSetup.offered.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        agentWelcome = AgentWelcomeWindowController { [weak self] in
            self?.showAgentSettings(nil)
        }
        agentWelcome?.showWindow(nil)
        agentWelcome?.window?.makeKeyAndOrderFront(nil)
    }
    private func layoutBody() {
        guard surface != nil else { return }
        let w = body.bounds.width, h = body.bounds.height
        let availableTabWidth = max(0, w - 132)
        let lastTabEdge = tabButtons.values.reduce(CGFloat(8)) { max($0, $1.frame.maxX) }
        let legacyHeight = tabScroll.scrollerStyle == .legacy && lastTabEdge + 8 > availableTabWidth
            ? NSScroller.scrollerWidth(for: .small, scrollerStyle: .legacy) : 0
        let tabHeight = TavernAppearance.tabHeight + legacyHeight, inset = TavernAppearance.inset
        tabsChrome.frame = NSRect(x: 0, y: max(0, h - tabHeight), width: w, height: tabHeight)
        tabScroll.frame = NSRect(x: 23, y: max(0, h - tabHeight),
                                width: min(availableTabWidth, lastTabEdge + 8), height: tabHeight)
        tabScroll.tile()
        let tabViewport = tabScroll.contentView.convert(tabScroll.contentView.bounds, to: body)
        let buttonHeight = min(38, tabViewport.height)
        let documentWidth = max(lastTabEdge + 8, tabViewport.width)
        if tabbar.frame.width != documentWidth {
            tabbar.setFrameSize(NSSize(width: documentWidth, height: tabbar.frame.height))
        }
        TavernMotion.move(addTab, to: NSRect(x: min(tabViewport.maxX + 22, max(0, w - 86)), y: tabViewport.minY,
                                           width: 43, height: buttonHeight))
        tabRecess.frame = NSRect(x: tabViewport.minX - 18, y: tabScroll.frame.minY - 12,
                                width: tabViewport.width + 36,
                                height: tabViewport.minY - tabScroll.frame.minY + buttonHeight + 21)
        tabRecess.contentRect = tabRecess.convert(NSRect(x: tabViewport.minX, y: tabViewport.minY,
                                                        width: tabViewport.width, height: buttonHeight), from: body)
        terminalFrame.frame = NSRect(x: inset, y: inset, width: max(0, w - inset * 2), height: max(0, h - tabHeight - inset * 2))
        surface.frame = terminalFrame.bounds.insetBy(dx: 8, dy: 8)
        // Отделка занимает межпанельное поле; родной viewport и его input не меняются.
        terminalChrome.frame = NSRect(x: 0, y: 4, width: w, height: max(0, h - tabHeight - 4))
        let sw = sidebarPanel.bounds.width, sh = sidebarPanel.bounds.height
        let narrow = sw < 210
        let headerHeight: CGFloat = narrow ? 82 : sh < 420 ? 112 : 142
        let headingBottom: CGFloat = narrow ? 58 : sh < 420 ? 92 : 122
        sidebarHeading.font = narrow ? TavernAppearance.narrowWorkspaceHeadingFont : TavernAppearance.workspaceHeadingFont
        sidebarHeading.frame = NSRect(x: 18, y: max(0, sh - headingBottom), width: max(0, sw - 65), height: 32)
        createWorkspaceButton.frame = NSRect(x: max(20, sw - 43), y: max(0, sh - headingBottom + 3), width: 27, height: 27)
        let distanceFromTop = max(0, sidebar.bounds.height - sidebarScroll.documentVisibleRect.maxY)
        sidebarScroll.frame = NSRect(x: 8, y: 17, width: max(0, sw - 16), height: max(0, sh - headerHeight - 17))
        sidebar.scroll(NSPoint(x: 0, y: max(0, sidebar.bounds.height - sidebarScroll.contentSize.height - distanceFromTop)))
        layoutPopup()
        layoutPaneGrips()
        layoutStatusBar()
    }
    private func layoutStatusBar() {
        // Полезная область балки: над нижней рейкой и под mainSplit.
        let bar = NSRect(x: 8, y: 11, width: max(0, root.bounds.width - 16), height: 30)
        let centerY = bar.midY
        settingsButton.frame = NSRect(x: bar.maxX - 12 - 47, y: centerY - 20.5, width: 47, height: 41)
        reconnectButton.frame = NSRect(x: settingsButton.frame.minX - 12 - 158,
                                       y: centerY - 15, width: 158, height: 30)
        statusLight.frame = NSRect(x: bar.minX + 48, y: centerY - 6, width: 12, height: 12)
        let textX = statusLight.frame.maxX + 10
        let textEnd = (attached ? settingsButton.frame.minX : reconnectButton.frame.minX) - 12
        let textHeight = ceil(status.intrinsicContentSize.height)
        status.frame = NSRect(x: textX, y: centerY - textHeight / 2,
                              width: max(0, textEnd - textX), height: textHeight)
    }
    private func layoutPopup() {
        guard popupSurface != nil, !popupContainer.isHidden else { return }
        let w = CGFloat(popupSurface.width) * popupSurface.cellWidth, h = CGFloat(popupSurface.height) * popupSurface.cellHeight
        let area = surface.convert(surface.bounds, to: body)
        // Рама рисуется поверх содержимого; отступ оставляет свободными и угловые накладки.
        let inset: CGFloat = 24, titleHeight: CGFloat = 28, titleGap: CGFloat = 8
        let size = NSSize(width: w + inset * 2, height: h + inset * 2 + titleGap + titleHeight)
        popupContainer.frame = NSRect(x: area.minX + max(0, (area.width - size.width) / 2),
                                     y: area.minY + max(0, (area.height - size.height) / 2),
                                     width: size.width, height: size.height)
        popupSurface.frame = NSRect(x: inset, y: inset, width: w, height: h)
        popupCloseButton.frame = NSRect(x: inset + w - titleHeight, y: h + inset + titleGap,
                                       width: titleHeight, height: titleHeight)
        popupTitle.frame = NSRect(x: inset, y: h + inset + titleGap + 3,
                                 width: max(0, w - titleHeight - 8), height: titleHeight - 6)
    }
    @objc private func closePopup(_ sender: NSButton) {
        guard attached, !popupID.isEmpty, !popupContainer.isHidden else { return }
        publicCommand("popup.close", [:])
    }
    private func menu(_ title: String, parent: NSMenu) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let child = NSMenu(title: title); item.submenu = child; parent.addItem(item); return child
    }
    private func menuAction(_ title: String, action: String, parent: NSMenu, key: String = "", modifiers: NSEvent.ModifierFlags = .command, menuTarget: MenuTarget? = nil) {
        let item = NSMenuItem(title: title, action: #selector(menuCommand(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self; item.identifier = NSUserInterfaceItemIdentifier(action); item.representedObject = menuTarget; parent.addItem(item)
    }
    private func buildMenus() {
        if let herdrMenu = herdrMenuController?.menu {
            NSApp.mainMenu?.items.first(where: { $0.submenu === herdrMenu })?.submenu = nil
        }
        let main = NSMenu()
        let app = menu("Herdr Tavern", parent: main)
        let settings = NSMenuItem(title: L("shell.settings.menu"), action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.target = self; app.addItem(settings); app.addItem(.separator())
        let quit = NSMenuItem(title: L("shell.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.addItem(quit)
        let session = menu(L("shell.session"), parent: main)
        menuAction(L("shell.reconnect"), action: "reconnect", parent: session)
        menuAction(L("shell.workspace.new.menu"), action: "workspace.create", parent: session)
        if let options {
            let controller = herdrMenuController ?? HerdrMenuController(options: options, showIntegrations: { [weak self] in
                self?.showAgentSettings(nil)
            }, reload: { [weak self] completion in
                guard let self else {
                    completion(.failure(TavernShellError { L("shell.error.closed") })); return
                }
                self.reloadHerdrConfig(completion: completion)
            })
            herdrMenuController = controller
            controller.localize()
            let item = NSMenuItem(title: "herdr", action: nil, keyEquivalent: "")
            item.submenu = controller.menu
            main.addItem(item)
        }
        let edit = menu(L("shell.edit"), parent: main)
        for (title, selector, key) in [(L("shell.copy"), #selector(SurfaceView.copy(_:)), "c"), (L("shell.paste"), #selector(SurfaceView.paste(_:)), "v"), (L("shell.selectAll"), #selector(SurfaceView.selectAll(_:)), "a")] {
            edit.addItem(NSMenuItem(title: title, action: selector, keyEquivalent: key))
        }
        let tabs = menu(L("shell.tab"), parent: main)
        for (title, action) in [(L("shell.tab.new"), "tab.create"), (L("shell.tab.left"), "tab.move.left"), (L("shell.tab.right"), "tab.move.right"), (L("shell.tab.rename.menu"), "tab.rename"), (L("shell.tab.close.menu"), "tab.close")] {
            menuAction(title, action: action, parent: tabs, key: action == "tab.create" ? "t" : "")
        }
        tabs.addItem(.separator())
        let agentSetup = NSMenuItem(title: L("shell.agents.setup"), action: #selector(showAgentSettings(_:)), keyEquivalent: "")
        agentSetup.target = self
        tabs.addItem(agentSetup)
        let panes = menu(L("shell.pane"), parent: main)
        for (title, action) in [(L("shell.pane.split.right"), "pane.split.right"), (L("shell.pane.split.down"), "pane.split.down"), (L("shell.pane.zoom"), "pane.zoom"), (L("shell.pane.swap.left"), "pane.swap.left"), (L("shell.pane.swap.right"), "pane.swap.right"), (L("shell.pane.swap.up"), "pane.swap.up"), (L("shell.pane.swap.down"), "pane.swap.down"), (L("shell.pane.move.tab"), "pane.move.tab"), (L("shell.pane.move.workspace"), "pane.move.workspace"), (L("shell.pane.rename.menu"), "pane.rename"), (L("shell.pane.close.menu"), "pane.close")] {
            let key: String
            switch action {
            case "pane.split.right": key = "d"
            case "pane.split.down": key = "W"
            case "pane.close": key = "w"
            default: key = ""
            }
            let modifiers: NSEvent.ModifierFlags = action == "pane.split.down" ? [.command, .shift] : .command
            menuAction(title, action: action, parent: panes, key: key, modifiers: modifiers)
        }
        let view = menu(L("shell.view"), parent: main)
        menuAction(L("shell.sidebar.toggle"), action: "sidebar.toggle", parent: view)
        let windows = menu(L("shell.window"), parent: main)
        windows.addItem(NSMenuItem(title: L("shell.window.minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windows.addItem(NSMenuItem(title: L("shell.window.close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: ""))
        NSApp.mainMenu = main; NSApp.windowsMenu = windows
    }
    private func paneContextMenu(_ paneID: String) -> NSMenu? {
        let target = MenuTarget(kind: .pane, id: paneID, boot: string(snapshot["boot_id"]), generation: generation)
        guard !target.boot.isEmpty, menuTargetIsCurrent(target) else { return nil }
        let menu = NSMenu(title: L("shell.pane"))
        menuAction(L("shell.pane.split.right"), action: "pane.split.right", parent: menu, menuTarget: target)
        menuAction(L("shell.pane.split.down"), action: "pane.split.down", parent: menu, menuTarget: target)
        let pane = objects(snapshot["panes"]).first { string($0["pane_id"]) == paneID }
        let tabID = string(pane?["tab_id"])
        let zoomed = objects(snapshot["tabs"]).contains { string($0["tab_id"]) == tabID && flag($0["zoomed"]) }
        if zoomed || objects(snapshot["panes"]).filter({ string($0["tab_id"]) == tabID }).count > 1 {
            menuAction(zoomed ? L("shell.pane.restore") : L("shell.pane.zoom.only"),
                       action: "pane.zoom", parent: menu, menuTarget: target)
        }
        menu.addItem(.separator())
        menuAction(L("shell.pane.rename.menu"), action: "pane.rename", parent: menu, menuTarget: target)
        menuAction(L("shell.pane.close.menu"), action: "pane.close", parent: menu, menuTarget: target)
        return menu
    }
    private func tabContextMenu(_ tabID: String) -> NSMenu? {
        let target = MenuTarget(kind: .tab, id: tabID, boot: string(snapshot["boot_id"]), generation: generation)
        guard !target.boot.isEmpty, menuTargetIsCurrent(target) else { return nil }
        let panes = objects(snapshot["panes"]).filter { string($0["tab_id"]) == tabID }
        let menu: NSMenu
        if panes.count == 1, let paneMenu = paneContextMenu(string(panes[0]["pane_id"])) {
            menu = paneMenu
            menu.addItem(.separator())
        } else {
            menu = NSMenu(title: L("shell.tab"))
            for (index, pane) in panes.enumerated() {
                guard let paneMenu = paneContextMenu(string(pane["pane_id"])) else { continue }
                let label = string(pane["label"])
                let item = NSMenuItem(title: L("shell.pane.number", index + 1) + (label.isEmpty ? "" : ": " + label),
                                      action: nil, keyEquivalent: "")
                item.submenu = paneMenu
                menu.addItem(item)
            }
            if !panes.isEmpty { menu.addItem(.separator()) }
        }
        menuAction(L("shell.tab.rename.menu"), action: "tab.rename", parent: menu, menuTarget: target)
        menuAction(L("shell.tab.close.menu"), action: "tab.close", parent: menu, menuTarget: target)
        return menu
    }
    private func menuTargetIsCurrent(_ target: MenuTarget) -> Bool {
        attached && generation == target.generation && string(snapshot["boot_id"]) == target.boot &&
            objects(snapshot[target.kind == .pane ? "panes" : "tabs"]).contains(where: {
                string($0[target.kind.rawValue + "_id"]) == target.id
            })
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let action = item.identifier?.rawValue ?? ""
        if action == "reconnect" { return !attached && !connecting }
        if action == "sidebar.toggle" { return true }
        if action.isEmpty { return true }
        guard attached, !snapshot.isEmpty, window.attachedSheet == nil, !publicRequestBusy else { return false }
        if let target = item.representedObject as? MenuTarget { return menuTargetIsCurrent(target) }
        if action.hasPrefix("pane.") { return !string(snapshot["focused_pane_id"]).isEmpty }
        if action.hasPrefix("tab.") {
            guard !string(snapshot["focused_tab_id"]).isEmpty else { return false }
            let tabs = focusedTabs(), index = tabs.firstIndex(where: { string($0["tab_id"]) == string(snapshot["focused_tab_id"]) })
            if action == "tab.move.left" { return index != nil && index! > 0 }
            if action == "tab.move.right" { return index != nil && index! + 1 < tabs.count }
        }
        return true
    }
    @objc private func menuCommand(_ sender: NSMenuItem) {
        if let target = sender.representedObject as? MenuTarget {
            guard menuTargetIsCurrent(target) else { localizedError { L("shell.error.menuTarget") }; return }
            perform(sender.identifier?.rawValue ?? "", target: target.id)
        } else {
            perform(sender.identifier?.rawValue ?? "", target: "")
        }
    }
    @objc private func navigate(_ sender: NavigationButton) {
        guard sender.isEnabled else { return }
        soundPlayer.play(.interfaceClick)
        perform(sender.actionName, target: sender.targetID)
    }
    private func focusedTabs() -> [[String: Any]] { objects(snapshot["tabs"]).filter { string($0["workspace_id"]) == string(snapshot["focused_workspace_id"]) } }
    private func button(_ title: String, action: String, target: String, frame: NSRect, parent: NSView, buttons: inout [NavigationKey: NavigationButton], appearing: inout [NSView], selected: Bool, subtitle: String = "", context: String = "", indicator: NSColor? = nil, unread: AgentUnreadKind? = nil) -> NavigationButton {
        let key = NavigationKey(action: action, target: target)
        let button: NavigationButton
        if let existing = buttons[key] {
            button = existing
            if button.title != title { button.title = title }
            TavernMotion.move(button, to: frame)
        } else {
            button = NavigationButton(title: title, target: self, action: #selector(navigate(_:)))
            button.wantsLayer = true
            button.frame = frame; button.actionName = action; button.targetID = target
            button.setAccessibilityIdentifier("navigation.\(action).\(target)")
            if action == "agent.focus" || action == "tab.focus" {
                button.contextMenu = { [weak self] in
                    action == "agent.focus" ? self?.paneContextMenu(target) : self?.tabContextMenu(target)
                }
                button.dragMouseDown = { [weak self] button, event in
                    let source: TavernDragSource = action == "tab.focus" ? .tab(target) : .pane(target)
                    return self?.beginNavigationDrag(button, event: event, source: source) ?? false
                }
            }
            buttons[key] = button
            parent.addSubview(button); appearing.append(button)
        }
        button.isEnabled = attached && (parent !== sidebar || !sidebarPanel.isHidden)
        let style: TavernButton.Style
        switch action {
        case "tab.focus": style = .tab
        case "workspace.focus": style = .workspace
        case "agent.focus": style = .agent
        default: style = .utility
        }
        button.lampWindowPosition = { [weak self] in
            guard let chrome = self?.sidebarChrome else { return CGPoint(x: -500, y: -500) }
            return chrome.convert(chrome.lanternLightPoint, to: nil)
        }
        button.prepare(style: style, selected: selected, subtitle: subtitle, context: context, indicator: indicator, unread: unread, identity: target)
        return button
    }
    private func retireButtons(_ buttons: inout [NavigationKey: NavigationButton], keeping keys: Set<NavigationKey>) {
        let removedKeys = buttons.keys.filter { !keys.contains($0) }
        for key in removedKeys {
            guard let button = buttons.removeValue(forKey: key) else { continue }
            button.isEnabled = false; button.target = nil; button.action = nil
            button.contextMenu = nil
            button.dragMouseDown = nil
            button.setAccessibilityElement(false)
            // Удаляем именно уходящий экземпляр: его ID мог уже появиться снова.
            TavernMotion.disappear(button) { button.removeFromSuperview() }
        }
    }
    private func rebuildNavigation() {
        guard surface != nil else { return }
        let distanceFromTop = max(0, sidebar.bounds.height - sidebarScroll.documentVisibleRect.maxY)
        var appearing: [NSView] = []
        let ws = string(snapshot["focused_workspace_id"]), tab = string(snapshot["focused_tab_id"]), pane = string(snapshot["focused_pane_id"])
        let preservedOffset = ws == navigationWorkspace ? distanceFromTop : 0
        let revealFocusedAgent = pane != navigationPane || ws != navigationWorkspace
        let revealFocusedTab = tab != navigationTab || ws != navigationWorkspace
        navigationWorkspace = ws; navigationPane = pane; navigationTab = tab
        var focusedAgent: NSView?
        let workspaces = objects(snapshot["workspaces"])
        let allAgents = objects(snapshot["agents"])
        let agents = allAgents.filter { string($0["workspace_id"]) == ws }
        let agentCounts = allAgents.reduce(into: [String: Int]()) { $0[string($1["workspace_id"]), default: 0] += 1 }
        let panesByID = Dictionary(uniqueKeysWithValues: objects(snapshot["panes"]).map { (string($0["pane_id"]), $0) })
        let tabsByID = Dictionary(uniqueKeysWithValues: objects(snapshot["tabs"]).map { (string($0["tab_id"]), $0) })
        let chainCount = agents.indices.dropFirst().reduce(0) { count, index in
            let tabID = string(agents[index]["tab_id"])
            return count + (!tabID.isEmpty && tabID == string(agents[index - 1]["tab_id"]) ? 1 : 0)
        }
        let contentHeight = max(sidebarScroll.contentSize.height, CGFloat(workspaces.count) * 60
            + CGFloat(max(1, agents.count)) * 90 + CGFloat(chainCount) * AgentChainView.extraGap
            + CGFloat(max(0, agents.count - 1) - chainCount) * AgentChainView.groupGap + 79)
        sidebar.frame = NSRect(x: 0, y: 0, width: sidebarScroll.contentSize.width, height: contentHeight)
        sidebarScroll.tile()
        if sidebar.frame.width != sidebarScroll.contentSize.width {
            sidebar.setFrameSize(NSSize(width: sidebarScroll.contentSize.width, height: contentHeight))
        }
        sidebar.scroll(NSPoint(x: 0, y: max(0, contentHeight - sidebarScroll.contentSize.height - preservedOffset)))
        createWorkspaceButton.isEnabled = attached && !sidebarPanel.isHidden
        var top = contentHeight - 3
        let bw = max(0, sidebar.bounds.width - 8)
        for row in workspaces {
            let id = string(row["workspace_id"]), title = string(row["label"])
            let agentCount = agentCounts[id, default: 0]
            let subtitle = L("shell.agents.count", agentCount)
            _ = button(title.isEmpty ? id : title, action: "workspace.focus", target: id, frame: NSRect(x: 4, y: top - 54, width: bw, height: 54), parent: sidebar, buttons: &sidebarButtons, appearing: &appearing, selected: id == ws, subtitle: subtitle)
            top -= 60
        }
        top -= 6
        TavernMotion.move(agentsDivider, to: NSRect(x: 12, y: top - 3, width: max(0, bw - 24), height: 7))
        top -= 18
        TavernMotion.move(agentsHeading, to: NSRect(x: 12, y: top - 36, width: max(0, bw - 24), height: 36))
        top -= 42
        var previousTab = "", previousFrame = NSRect.zero
        var liveChains = Set<String>()
        for agent in agents {
            let id = string(agent["pane_id"])
            let tabID = string(agent["tab_id"])
            let connected = !tabID.isEmpty && tabID == previousTab
            if !previousFrame.isEmpty { top -= connected ? AgentChainView.extraGap : AgentChainView.groupGap }
            let paneRow = panesByID[id], tabRow = tabsByID[string(agent["tab_id"])]
            let tabTitle = string(tabRow?["label"])
            let agentType = [string(agent["display_agent"]), string(agent["agent"]), string(agent["name"]), L("shell.agent")].first(where: { !$0.isEmpty })!
            let title = [string(paneRow?["label"]), tabTitle, string(agent["name"]), agentType].first(where: { !$0.isEmpty })!
            let cwd = [string(paneRow?["foreground_cwd"]), string(paneRow?["cwd"])].first(where: { !$0.isEmpty }) ?? ""
            let shortPath = (cwd as NSString).abbreviatingWithTildeInPath
            let context = cwd.isEmpty ? L("shell.directory.unknown") : shortPath == "~" ? L("shell.directory.home") : shortPath
            let (state, color) = TavernAppearance.agentState(string(agent["agent_status"]))
            let subtitle = agentType + " · " + state
            let mark = unread.marks[id]
            let item = button(title, action: "agent.focus", target: id, frame: NSRect(x: 4, y: top - 84, width: bw, height: 84), parent: sidebar, buttons: &sidebarButtons, appearing: &appearing, selected: id == pane, subtitle: subtitle, context: context, indicator: color, unread: mark)
            item.setAgentVisualStatus(TavernAgentVisualStatus(agentStatus: string(agent["agent_status"])))
            if connected {
                liveChains.insert(id)
                let frame = NSRect(x: item.frame.minX, y: item.frame.maxY, width: item.frame.width,
                                   height: previousFrame.minY - item.frame.maxY)
                if let chain = agentChains[id] {
                    TavernMotion.move(chain, to: frame)
                } else {
                    let chain = AgentChainView(frame: frame)
                    chain.wantsLayer = true; chain.setAccessibilityElement(false)
                    agentChains[id] = chain; sidebar.addSubview(chain, positioned: .below, relativeTo: nil); appearing.append(chain)
                }
            }
            let details = [tabTitle.isEmpty ? "" : L("shell.tab.detail", tabTitle), L("shell.agent.dragHelp"),
                           subtitle, cwd.isEmpty ? context : cwd, L("shell.pane.detail", id), mark?.label ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
            item.toolTip = title + "\n" + details
            item.setAccessibilityHelp(details)
            if id == pane { focusedAgent = item }
            previousTab = tabID; previousFrame = item.frame
            top -= 90
        }
        for id in agentChains.keys.filter({ !liveChains.contains($0) }) {
            guard let chain = agentChains.removeValue(forKey: id) else { continue }
            TavernMotion.disappear(chain) { chain.removeFromSuperview() }
        }
        emptyAgentsLabel.isHidden = !agents.isEmpty
        emptyAgentsLabel.frame = NSRect(x: 20, y: top - 26, width: max(0, bw - 16), height: 26)
        var sidebarKeys = Set(workspaces.lazy.map { NavigationKey(action: "workspace.focus", target: string($0["workspace_id"])) })
        sidebarKeys.formUnion(agents.lazy.map { NavigationKey(action: "agent.focus", target: string($0["pane_id"])) })
        retireButtons(&sidebarButtons, keeping: sidebarKeys)
        if revealFocusedAgent, let focusedAgent { sidebar.scrollToVisible(focusedAgent.frame.insetBy(dx: 0, dy: -8)) }
        var x: CGFloat = 8
        var selected: NavigationButton?
        let tabs = focusedTabs()
        for row in tabs {
            let id = string(row["tab_id"]), title = string(row["label"])
            let label = title.isEmpty ? id : title
            let width = min(190, max(100, ceil((label as NSString).size(withAttributes: [.font: TavernAppearance.bodyFont]).width) + 52))
            let rect = NSRect(x: x, y: 0, width: width, height: 38)
            let item = button(title.isEmpty ? id : title, action: "tab.focus", target: id, frame: rect, parent: tabbar, buttons: &tabButtons, appearing: &appearing, selected: id == tab)
            if id == tab { selected = item }; x += width + 2
        }
        retireButtons(&tabButtons, keeping: Set(tabs.lazy.map { NavigationKey(action: "tab.focus", target: string($0["tab_id"])) }))
        tabbar.frame = NSRect(x: 0, y: 0, width: max(x, tabScroll.contentSize.width), height: tabScroll.contentSize.height)
        layoutBody()
        let viewportWidth = tabScroll.contentSize.width
        if revealFocusedTab || viewportWidth != navigationTabViewportWidth, let selected {
            tabbar.scrollToVisible(selected.frame)
        }
        navigationTabViewportWidth = viewportWidth
        addTab.isEnabled = attached && !ws.isEmpty
        navigationDrag.refresh()
        for view in appearing { TavernMotion.appear(view) }
        updateStatus()
    }
    private func updateStatus() {
        layoutStatusBar()
        let showReconnect = !attached
        reconnectButton.isEnabled = showReconnect && !connecting
        if reconnectVisible != showReconnect {
            reconnectVisible = showReconnect
            reconnectVisibilityGeneration += 1
            let visibilityGeneration = reconnectVisibilityGeneration
            if showReconnect {
                reconnectButton.layer?.removeAnimation(forKey: "opacity")
                reconnectButton.layer?.opacity = 1
                reconnectButton.isHidden = false
                TavernMotion.appear(reconnectButton)
            } else {
                TavernMotion.disappear(reconnectButton) { [weak self] in
                    guard let self, self.reconnectVisibilityGeneration == visibilityGeneration else { return }
                    self.reconnectButton.isHidden = true
                }
            }
        }
        statusLight.color = lastError != nil ? TavernAppearance.accent : attached ? TavernAppearance.success : connecting ? TavernAppearance.working : TavernAppearance.accent
        status.textColor = lastError != nil || !attached ? TavernAppearance.accent : TavernAppearance.secondary
        if let lastError { status.stringValue = lastError; status.toolTip = lastError; return }
        if !attached {
            status.stringValue = connecting ? L("shell.connection.connecting") : L("shell.connection.disconnected")
            status.toolTip = status.stringValue
            return
        }
        let id = string(snapshot["focused_pane_id"])
        let label = string(objects(snapshot["panes"]).first(where: { string($0["pane_id"]) == id })?["label"])
        let workspace = objects(snapshot["workspaces"]).first { string($0["workspace_id"]) == string(snapshot["focused_workspace_id"]) }
        let tab = objects(snapshot["tabs"]).first { string($0["tab_id"]) == string(snapshot["focused_tab_id"]) }
        let workspaceTitle = string(workspace?["label"]), tabTitle = string(tab?["label"])
        status.stringValue = L("shell.connection.ready", workspaceTitle.isEmpty ? string(snapshot["focused_workspace_id"]) : workspaceTitle, tabTitle.isEmpty ? string(snapshot["focused_tab_id"]) : tabTitle, label.isEmpty ? "" : "  │  " + label)
        status.toolTip = L("shell.connection.details", string(snapshot["focused_workspace_id"]), string(snapshot["focused_tab_id"]), id, label)
    }
    private func error(_ message: String) {
        lastErrorLocalization = nil; lastError = message; updateStatus(); soundPlayer.play(.error)
    }
    private func localizedError(_ render: @escaping () -> String) {
        error(render()); lastErrorLocalization = render
    }
    private func clearError() { lastErrorLocalization = nil; lastError = nil; updateStatus() }
    @objc private func languageDidChange(_ notification: Notification) {
        tavern_set_language(TavernLocalization.shared.language.nativeValue)
        guard window != nil else { return }
        sidebarHeading.stringValue = L("shell.workspaces")
        sidebarHeading.toolTip = L("shell.workspaces")
        agentsHeading.stringValue = L("shell.agents")
        emptyAgentsLabel.stringValue = L("shell.agents.empty")
        createWorkspaceButton.toolTip = L("shell.workspace.new")
        createWorkspaceButton.setAccessibilityLabel(L("shell.workspace.new"))
        addTab.setAccessibilityLabel(L("shell.tab.new"))
        popupCloseButton.toolTip = L("shell.dialog.close")
        popupCloseButton.setAccessibilityLabel(L("shell.dialog.close"))
        settingsButton.toolTip = L("shell.settings")
        settingsButton.setAccessibilityLabel(L("shell.settings"))
        status.setAccessibilityLabel(L("shell.connection.status"))
        reconnectButton.title = L("shell.connect")
        if let lastErrorLocalization { lastError = lastErrorLocalization() }
        sidebarTransitionView?.removeFromSuperview(); sidebarTransitionView = nil
        navSignature = nil
        buildMenus()
        rebuildNavigation()
    }
    @objc private func reconnect(_ sender: Any?) { if !attached && !connecting { connect() } }
    private func connect() {
        guard let options, !connecting else { return }
        generation += 1; let epoch = generation
        connection?.close(); connection = nil
        requests.removeAll(); inFlight = nil; requestTimeout?.invalidate(); requestTimeout = nil
        pendingSnapshot = nil
        snapshot = [:]; surface.clear(); popupSurface.clear(); popupContainer.isHidden = true; surface.isHidden = true
        lastGeometry = ""; navSignature = nil; resumeRequested = false
        connecting = true; attached = false; clearError(); rebuildNavigation()
        let cols = surface.cols, rows = surface.rows, scale = window.backingScaleFactor
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try options.ensureServer()
                let pointer = try RustConnection.open(path: options.socketPath, cols: cols, rows: rows, cellWidth: Int(8 * scale), cellHeight: Int(20 * scale))
                DispatchQueue.main.async {
                    guard let self, self.generation == epoch, !self.terminated else {
                        DispatchQueue.global().async { tavern_client_close(pointer); tavern_client_free(pointer) }; return
                    }
                    self.connection = RustConnection(pointer: pointer) { [weak self] result in
                        guard let self, self.generation == epoch, !self.terminated else { return }
                        switch result { case .success(let event): self.receive(event); case .failure(let error): self.disconnect { error.localizedDescription } }
                    }
                    self.connecting = false; self.attached = true; self.surfaceActive = true
                    self.clearError(); self.surface.updateGeometry(); self.rebuildNavigation()
                    self.send(["type":"focus", "focused": self.window.isKeyWindow])
                    self.soundPlayer.play(.connected)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.generation == epoch, !self.terminated else { return }
                    self.connecting = false; self.disconnect { error.localizedDescription }
                }
            }
        }
    }
    private func disconnect(_ message: String) { disconnect { message } }
    private func disconnect(_ message: @escaping () -> String) {
        attached = false; connecting = false; connection?.close(); connection = nil
        surface.commandKeybindings.update(commands: [], prefixes: [], context: "")
        surface.commandKeybindings.resetInput()
        navigationDrag.cancel()
        for grip in paneGrips.values { grip.isHidden = true }
        requestTimeout?.invalidate(); requestTimeout = nil; inFlight = nil; requests.removeAll()
        pendingSnapshot = nil
        popupContainer.isHidden = true; surface.isHidden = true
        localizedError { L("shell.error.disconnected", message()) }; rebuildNavigation()
    }
    private func send(_ command: [String: Any], completion: ((Bool) -> Void)? = nil) {
        guard attached, let connection else { localizedError { L("shell.error.notConnected") }; completion?(false); return }
        let epoch = generation
        connection.send(command) { [weak self] failure in
            guard let self, self.generation == epoch, !self.terminated else { return }
            if let failure { self.localizedError { failure.localizedDescription }; completion?(false) }
            else { completion?(true) }
        }
    }
    private func resize(cols: Int, rows: Int, width: Int, height: Int) {
        guard attached else { return }
        let signature = "\(cols):\(rows):\(width):\(height)"
        guard signature != lastGeometry else { return }
        lastGeometry = signature
        send(["type":"resize", "cols":cols, "rows":rows, "cell_width_px":width, "cell_height_px":height])
    }
    private func invokeConfiguredCommand(_ id: String, selection: [String: Any]?) {
        guard attached, popupID.isEmpty, window.attachedSheet == nil,
              string(surface.scene["boot_id"]) == string(snapshot["boot_id"]),
              integer(surface.scene["projection_revision"]) == integer(snapshot["revision"]),
              let command = objects(snapshot["commands"]).first(where: { string($0["command_id"]) == id }) else {
            localizedError { L("shell.error.commandUnavailable") }
            return
        }
        var params: [String: Any] = ["command_id": id]
        for key in ["workspace_id", "tab_id", "pane_id"] {
            if let value = snapshot["focused_" + key] as? String { params[key] = value }
        }
        if string(command["action"]) == "PluginAction", let selection { params["selection"] = selection }
        request("command.invoke", params)
    }
    private func request(_ method: String, _ params: [String: Any], completion: (([String: Any]) -> Void)? = nil) {
        let boot = string(snapshot["boot_id"])
        guard attached, !boot.isEmpty else { localizedError { L("shell.error.noSession") }; return }
        let action = EndpointAction(id: UUID().uuidString, boot: boot, method: method, params: params, completion: completion)
        if method == "layout.set_split_ratio", let index = requests.lastIndex(where: { $0.method == method && string($0.params["pane_id"]) == string(params["pane_id"]) }) {
            requests[index] = action
        } else {
            guard requests.count < 64 else { localizedError { L("shell.error.queueFull") }; return }
            requests.append(action)
        }
        pumpRequests()
    }
    private func pumpRequests() {
        guard attached, inFlight == nil, !requests.isEmpty else { return }
        let action = requests.removeFirst()
        guard action.boot == string(snapshot["boot_id"]) else { localizedError { L("shell.error.sessionChanged") }; pumpRequests(); return }
        inFlight = action
        let command: [String: Any] = ["type":"request", "request_id":action.id, "boot_id":action.boot, "method":action.method, "params":action.params]
        send(command) { [weak self] sent in
            guard let self, self.inFlight?.id == action.id else { return }
            if !sent { self.inFlight = nil; self.requests.removeAll(); return }
            self.requestTimeout = Timer.scheduledTimer(withTimeInterval: 16, repeats: false) { [weak self] _ in
                guard let self, self.inFlight?.id == action.id else { return }
                self.disconnect { L("shell.error.requestTimeout", action.method) }
            }
        }
    }
    private func receive(_ event: NativeEvent) {
        precondition(Thread.isMainThread)
        switch event.kind {
        case UInt32(TAVERN_SNAPSHOT):
            let oldBoot = string(snapshot["boot_id"]), newBoot = string(event.metadata["boot_id"])
            if !oldBoot.isEmpty && oldBoot != newBoot {
                requests.removeAll(); inFlight = nil; requestTimeout?.invalidate(); requestTimeout = nil; surface.clear()
                snapshot = [:]
                localizedError { L("shell.error.serverRestarted") }
            }
            pendingSnapshot = event.metadata
            publishPendingSnapshot()
            updateVisibility()
        case UInt32(TAVERN_FULL), UInt32(TAVERN_PATCH):
            do {
                try surface.apply(metadata: event.metadata, segments: event.segments, assets: event.assets, patch: event.kind == UInt32(TAVERN_PATCH))
                if event.kind == UInt32(TAVERN_FULL) { try installPopup(event) }
                publishPendingSnapshot()
                updateVisibility()
            } catch { disconnect { error.localizedDescription } }
        case UInt32(TAVERN_RESPONSE):
            guard let action = inFlight,
                  string(event.metadata["request_id"]) == action.id, string(event.metadata["boot_id"]) == action.boot else {
                localizedError { L("shell.error.responseMismatch") }; return
            }
            requestTimeout?.invalidate(); requestTimeout = nil; inFlight = nil
            let response = dictionary(event.metadata["response"]), rejection = dictionary(response["error"])
            if !rejection.isEmpty {
                error("\(action.method): \(string(rejection["message"])) (\(string(rejection["code"])))")
                requests.removeAll()
            } else { action.completion?(dictionary(response["result"])) }
            pumpRequests()
        case UInt32(TAVERN_NOTICE): handleNotice(event.metadata)
        case UInt32(TAVERN_ERROR):
            let message = string(event.metadata["message"])
            localizedError { message.isEmpty ? L("shell.error.herdr") : message }
        case UInt32(TAVERN_CLOSED):
            let message = string(event.metadata["message"])
            let previousError = lastErrorLocalization, previousMessage = lastError
            disconnect { message.isEmpty ? previousError?() ?? previousMessage ?? L("shell.error.serverClosed") : message }
        default: localizedError { L("shell.error.unknownEvent") }
        }
    }
    private func publishPendingSnapshot() {
        guard let replacement = pendingSnapshot else { return }
        // Состояние и кадр приходят отдельно. До готовности пары оставляем
        // предыдущую согласованную поверхность, не показывая пустой промежуток.
        let matches = string(surface.scene["boot_id"]) == string(replacement["boot_id"]) &&
            integer(surface.scene["projection_revision"]) == integer(replacement["revision"])
        guard matches || !surfaceActive else { return }
        if !snapshot.isEmpty, string(snapshot["boot_id"]) == string(replacement["boot_id"]) {
            let previous = Set(objects(snapshot["agents"]).map { string($0["pane_id"]) })
            if objects(replacement["agents"]).contains(where: { !previous.contains(string($0["pane_id"])) }) {
                soundPlayer.play(.agentStarted)
            }
        }
        snapshot = replacement; pendingSnapshot = nil
        surface.commandKeybindings.update(commands: objects(snapshot["commands"]),
            prefixes: snapshot["command_prefixes"] as? [String] ?? [],
            context: [string(snapshot["boot_id"]), string(snapshot["focused_workspace_id"]),
                      string(snapshot["focused_tab_id"]), string(snapshot["focused_pane_id"])].joined(separator: ":"))
        var statuses: [String: String] = [:]
        for agent in objects(snapshot["agents"]) { statuses[string(agent["pane_id"])] = string(agent["agent_status"]) }
        let unreadChanged = unread.synchronize(bootID: string(snapshot["boot_id"]), statuses: statuses, viewedPane: viewedPaneID())
        let keys = ["workspaces","tabs","panes","agents","focused_workspace_id","focused_tab_id","focused_pane_id"]
        let navigation = snapshot.filter { keys.contains($0.key) }
        let signature = try? JSONSerialization.data(withJSONObject: navigation, options: .sortedKeys)
        if signature != navSignature || unreadChanged { navSignature = signature; rebuildNavigation() }
        else { updateStatus() }
    }
    private func viewedPaneID() -> String? {
        guard attached, surfaceActive, NSApp.isActive, window.isKeyWindow, window.isVisible,
              !window.isMiniaturized, window.occlusionState.contains(.visible),
              window.attachedSheet == nil, popupID.isEmpty, !surface.isHidden,
              !snapshot.isEmpty, string(surface.scene["boot_id"]) == string(snapshot["boot_id"]),
              integer(surface.scene["projection_revision"]) == integer(snapshot["revision"]) else { return nil }
        let id = string(snapshot["focused_pane_id"])
        guard !id.isEmpty, let pane = objects(surface.scene["panes"]).first(where: {
            string($0["pane_id"]) == id && flag($0["focused"])
        }) else { return nil }
        let r = dictionary(pane["inner_rect"])
        let rect = NSRect(x: number(r["x"]), y: number(r["y"]), width: number(r["width"]), height: number(r["height"]))
        return rect.intersects(NSRect(x: 0, y: 0, width: surface.width, height: surface.height)) ? id : nil
    }
    private func markVisiblePaneRead() {
        guard !unread.marks.isEmpty else { return }
        if unread.markViewed(viewedPaneID()) { rebuildNavigation() }
    }
    private func updateVisibility() {
        let matches = !snapshot.isEmpty && string(surface.scene["boot_id"]) == string(snapshot["boot_id"]) && integer(surface.scene["projection_revision"]) == integer(snapshot["revision"])
        let becameVisible = matches && surface.isHidden
        surface.isHidden = !matches
        popupContainer.isHidden = !matches || popupID.isEmpty
        if matches && !popupID.isEmpty {
            layoutPopup()
            if window.attachedSheet == nil { window.makeFirstResponder(popupSurface) }
        } else if matches && window.attachedSheet == nil && (becameVisible || window.firstResponder === popupSurface) {
            window.makeFirstResponder(surface)
        }
        markVisiblePaneRead()
        layoutPaneGrips()
    }
    private func installPopup(_ event: NativeEvent) throws {
        let popup = dictionary(event.metadata["popup"])
        guard !popup.isEmpty else { popupID = ""; popupContainer.isHidden = true; popupSurface.clear(); return }
        var frame = dictionary(popup["frame"])
        let width = integer(frame["width"]), height = integer(frame["height"])
        guard width > 0, height > 0, !event.popupSegments.isEmpty else { throw TavernShellError { L("shell.error.popupSurface") } }
        let id = string(popup["terminal_id"])
        frame["boot_id"] = event.metadata["boot_id"]; frame["projection_revision"] = event.metadata["projection_revision"]
        frame["surface_revision"] = event.metadata["surface_revision"]
        frame["panes"] = [["pane_id":id, "focused":true, "mouse_reporting":flag(popup["mouse_reporting"]),
                            "inner_rect":["x":0,"y":0,"width":width,"height":height]]]
        try popupSurface.apply(metadata: frame, segments: event.popupSegments, assets: [], patch: false)
        popupID = id; popupTitle.stringValue = string(popup["title"])
        popupContainer.isHidden = false; layoutPopup()
    }
    private func handleNotice(_ notice: [String: Any]) {
        switch string(notice["type"]) {
        case "terminal_bell": soundPlayer.play(.bell)
        case "notify":
            // herdr отдельно присылает legacy Sound для терминального клиента:
            // звук здесь уже обрабатывается через SemanticNotification.
            if string(notice["kind"]) != "Sound" { status.stringValue = string(notice["message"]) }
            if string(notice["kind"]) == "SystemToast" {
                notifications.show(title: string(notice["message"]), body: string(notice["body"]), context: [:])
            }
        case "semantic_notification":
            let notification = dictionary(notice["notification"])
            if let kind = AgentUnreadKind(notification: notification) {
                let boot = string(pendingSnapshot?["boot_id"] ?? snapshot["boot_id"])
                let viewed = boot == string(snapshot["boot_id"]) ? viewedPaneID() : nil
                if unread.record(kind, paneID: string(notification["pane_id"]), bootID: boot, viewedPane: viewed) {
                    rebuildNavigation()
                }
            }
            status.stringValue = string(notification["title"]) + " " + string(notification["body"])
            var context: [String: String] = ["boot_id": string(snapshot["boot_id"])]
            for key in ["workspace_id", "tab_id", "pane_id"] {
                if let value = notification[key] as? String { context[key] = value }
            }
            notifications.show(title: string(notification["title"]), body: string(notification["body"]), context: context)
            switch string(notification["sound"]) {
            case "Done": soundPlayer.play(.complete)
            case "Request": soundPlayer.play(.attention)
            default: break
            }
        case "window_title": break // The application title stays stable; no path is opened.
        case "clipboard": localizedError { L("shell.error.clipboard") }
        case "unsupported", "graphics_file": localizedError { L("shell.error.unsupported") }
        case "error": error(string(notice["message"]))
        case "server_shutdown": disconnect(string(notice["reason"]))
        default: break
        }
    }
    private func openNotification(_ context: [String: String]) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        guard attached, context["boot_id"] == string(snapshot["boot_id"]),
              let tab = context["tab_id"],
              objects(snapshot["tabs"]).contains(where: { string($0["tab_id"]) == tab }) else { return }
        let boot = string(snapshot["boot_id"]), epoch = generation
        request("tab.focus", ["tab_id": tab]) { [weak self] _ in
            guard let self, self.generation == epoch, string(self.snapshot["boot_id"]) == boot,
                  let pane = context["pane_id"],
                  objects(self.snapshot["panes"]).contains(where: {
                      string($0["pane_id"]) == pane && string($0["tab_id"]) == tab
                  }) else { return }
            self.request("pane.focus", ["pane_id": pane])
        }
    }
    private func perform(_ action: String, target: String) {
        if action == "sidebar.toggle" { toggleSidebar(); return }
        if action == "reconnect" { reconnect(nil); return }
        guard attached, !snapshot.isEmpty, window.attachedSheet == nil else { localizedError { L("shell.error.commandSession") }; return }
        clearError()
        let pane = action.hasPrefix("pane.") && !target.isEmpty ? target : string(snapshot["focused_pane_id"])
        let tab = action.hasPrefix("tab.") && !target.isEmpty ? target : string(snapshot["focused_tab_id"])
        let workspace = string(snapshot["focused_workspace_id"])
        if action.hasPrefix("pane."), !objects(snapshot["panes"]).contains(where: { string($0["pane_id"]) == pane }) {
            localizedError { L("shell.error.paneCommand") }; return
        }
        switch action {
        case "workspace.focus": request(action, ["workspace_id":target])
        case "workspace.create": createWorkspace()
        case "tab.focus": request(action, ["tab_id":target])
        case "tab.create": request(action, ["workspace_id":workspace,"focus":true,"label":L("shell.tab.new"),"env":terminalLaunchEnvironment])
        case "tab.rename", "tab.close": editOrClose(action, target: tab)
        case "pane.rename", "pane.close": editOrClose(action, target: pane)
        case "tab.move.left", "tab.move.right":
            let tabs = focusedTabs()
            guard let index = tabs.firstIndex(where: { string($0["tab_id"]) == tab }) else { return }
            let destination = action.hasSuffix("left") ? index - 1 : index + 2
            guard destination >= 0, destination <= tabs.count else { return }
            request("tab.move", ["tab_id":tab,"insert_index":destination])
        case "agent.focus":
            guard let agent = objects(snapshot["agents"]).first(where: { string($0["pane_id"]) == target }) else { localizedError { L("shell.error.agentUnavailable") }; return }
            let boot = string(snapshot["boot_id"]), tabID = string(agent["tab_id"])
            request("tab.focus", ["tab_id":tabID]) { [weak self] _ in
                guard let self, string(self.snapshot["boot_id"]) == boot,
                      objects(self.snapshot["panes"]).contains(where: { string($0["pane_id"]) == target }) else { return }
                self.request("pane.focus", ["pane_id":target])
            }
        case "pane.split.right", "pane.split.down":
            request("pane.split", ["target_pane_id":pane,"direction":action.hasSuffix("right") ? "right" : "down","ratio":0.5,"focus":true,"env":terminalLaunchEnvironment])
        case "pane.zoom": request(action, ["pane_id":pane,"mode":"toggle"])
        case "pane.swap.left", "pane.swap.right", "pane.swap.up", "pane.swap.down":
            request("pane.swap", ["pane_id":pane,"direction":action.components(separatedBy: ".").last!])
        case "pane.move.tab", "pane.move.workspace": movePane(action, pane: pane, workspace: workspace)
        default: localizedError { L("shell.error.unknownCommand") }
        }
        window.makeFirstResponder(surface)
    }
    private func createWorkspace() {
        let boot = string(snapshot["boot_id"])
        let alert = TavernDialog(); alert.messageText = L("shell.workspace.new"); alert.addButton(withTitle: L("shell.create")); alert.addButton(withTitle: L("shell.cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24)); field.stringValue = L("shell.workspace.new"); field.setAccessibilityLabel(L("shell.name"))
        field.font = TavernAppearance.controlFont
        alert.accessoryView = field
        alert.localizationUpdater = { dialog in
            dialog.messageText = L("shell.workspace.new")
            dialog.buttons[0].title = L("shell.create")
            dialog.buttons[1].title = L("shell.cancel")
            field.setAccessibilityLabel(L("shell.name"))
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            guard boot == string(self.snapshot["boot_id"]) else { self.localizedError { L("shell.error.workspaceSession") }; return }
            self.request("workspace.create", ["label":field.stringValue,"focus":true,"env":self.terminalLaunchEnvironment]); self.window.makeFirstResponder(self.surface)
        }
        window.attachedSheet?.makeFirstResponder(field)
    }
    private func editOrClose(_ action: String, target: String) {
        let isPane = action.hasPrefix("pane."), closing = action.hasSuffix(".close")
        let key = isPane ? "pane_id" : "tab_id", collection = isPane ? "panes" : "tabs"
        let boot = string(snapshot["boot_id"]), epoch = generation
        guard let original = objects(snapshot[collection]).first(where: { string($0[key]) == target }) else { return }
        let originalLabel = string(original["label"]), label = originalLabel.isEmpty ? target : originalLabel
        let alert = TavernDialog()
        alert.messageText = closing ? (isPane ? L("shell.pane.close.question") : L("shell.tab.close.question")) : (isPane ? L("shell.pane.rename") : L("shell.tab.rename"))
        alert.informativeText = "\(label) (\(target))"
        if closing {
            alert.warningText = isPane ? L("shell.pane.close.warning") : L("shell.tab.close.warning")
        }
        let lastWorkspaceTab = closing && !isPane && objects(snapshot["tabs"]).filter({ string($0["workspace_id"]) == string(original["workspace_id"]) }).count == 1
        if lastWorkspaceTab {
            alert.warningText += L("shell.tab.close.last")
        }
        if isPane && !closing { alert.informativeText += "\n" + L("shell.pane.rename.help") }
        var field: NSTextField?
        if closing {
            alert.alertStyle = .warning
            alert.addButton(withTitle: L("shell.cancel"))
            alert.addButton(withTitle: isPane ? L("shell.pane.close") : L("shell.tab.close")).hasDestructiveAction = true
        }
        else {
            alert.addButton(withTitle: L("shell.save")); alert.addButton(withTitle: L("shell.cancel"))
            let text = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24)); text.stringValue = isPane ? originalLabel : label; text.setAccessibilityLabel(L("shell.name"))
            text.font = TavernAppearance.controlFont
            field = text; alert.accessoryView = text
        }
        alert.localizationUpdater = { dialog in
            dialog.messageText = closing ? (isPane ? L("shell.pane.close.question") : L("shell.tab.close.question")) : (isPane ? L("shell.pane.rename") : L("shell.tab.rename"))
            dialog.informativeText = "\(label) (\(target))"
            if closing {
                dialog.warningText = (isPane ? L("shell.pane.close.warning") : L("shell.tab.close.warning"))
                    + (lastWorkspaceTab ? L("shell.tab.close.last") : "")
                dialog.buttons[0].title = L("shell.cancel")
                dialog.buttons[1].title = isPane ? L("shell.pane.close") : L("shell.tab.close")
            } else {
                if isPane { dialog.informativeText += "\n" + L("shell.pane.rename.help") }
                dialog.buttons[0].title = L("shell.save")
                dialog.buttons[1].title = L("shell.cancel")
                field?.setAccessibilityLabel(L("shell.name"))
            }
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == (closing ? .alertSecondButtonReturn : .alertFirstButtonReturn), let self else { return }
            guard self.attached, self.generation == epoch, boot == string(self.snapshot["boot_id"]), objects(self.snapshot[collection]).contains(where: { string($0[key]) == target }) else {
                self.localizedError { L("shell.error.targetUnavailable") }; return
            }
            var params: [String: Any] = [key:target]
            if let field { params["label"] = field.stringValue }
            if isPane, !closing, let field {
                let newLabel = field.stringValue
                self.request(action, params) { [weak self] _ in
                    guard let self, self.attached, self.generation == epoch,
                          boot == string(self.snapshot["boot_id"]),
                          let pane = objects(self.snapshot["panes"]).first(where: { string($0["pane_id"]) == target }) else { return }
                    let tabID = string(pane["tab_id"])
                    guard objects(self.snapshot["tabs"]).contains(where: { string($0["tab_id"]) == tabID }) else { return }
                    self.request("tab.rename", ["tab_id": tabID, "label": newLabel])
                }
            } else { self.request(action, params) }
            self.window.makeFirstResponder(self.surface)
        }
        if let field { window.attachedSheet?.makeFirstResponder(field) }
    }
    private func movePane(_ action: String, pane: String, workspace: String) {
        guard !pane.isEmpty, !publicRequestBusy else { return }
        let boot = string(snapshot["boot_id"]), epoch = generation
        let destination: [String: Any] = action.hasSuffix("tab") ? ["type":"new_tab","workspace_id":workspace,"label":L("shell.pane.moved")] : ["type":"new_workspace","label":L("shell.workspace.new")]
        let alert = TavernDialog(); alert.messageText = L("shell.pane.move.question")
        alert.informativeText = action.hasSuffix("tab") ? L("shell.pane.move.tab.message", pane) : L("shell.pane.move.workspace.message", pane)
        alert.addButton(withTitle: L("shell.move")); alert.addButton(withTitle: L("shell.cancel"))
        alert.localizationUpdater = { dialog in
            dialog.messageText = L("shell.pane.move.question")
            dialog.informativeText = action.hasSuffix("tab") ? L("shell.pane.move.tab.message", pane) : L("shell.pane.move.workspace.message", pane)
            dialog.buttons[0].title = L("shell.move")
            dialog.buttons[1].title = L("shell.cancel")
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            guard self.attached, self.generation == epoch, boot == string(self.snapshot["boot_id"]),
                  objects(self.snapshot["panes"]).contains(where: { string($0["pane_id"]) == pane }) else { self.localizedError { L("shell.error.paneUnavailable") }; return }
            self.publicCommand("pane.move", ["pane_id":pane,"destination":destination,"focus":true])
        }
    }
    private func reloadHerdrConfig(completion: @escaping (Result<String, Error>) -> Void) {
        guard let options, attached, !publicRequestBusy, !string(snapshot["boot_id"]).isEmpty else {
            completion(.failure(TavernShellError { L("shell.error.reloadBusy") })); return
        }
        publicRequestBusy = true
        let epoch = generation, boot = string(snapshot["boot_id"])
        let command: [String: Any] = ["id": UUID().uuidString, "method": "server.reload_config", "params": [:]]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try RustConnection.publicRequest(path: options.publicSocketPath, request: command) }
            DispatchQueue.main.async {
                guard let self else {
                    completion(.failure(TavernShellError { L("shell.error.closed") })); return
                }
                self.publicRequestBusy = false
                guard !self.terminated, self.attached, self.generation == epoch,
                      string(self.snapshot["boot_id"]) == boot else {
                    completion(.failure(TavernShellError { L("shell.error.reloadSession") })); return
                }
                do {
                    let response = try result.get()
                    let rejection = dictionary(response["error"])
                    guard rejection.isEmpty else { throw NativeError.message(string(rejection["message"])) }
                    let report = dictionary(response["result"])
                    let status = string(report["status"])
                    let diagnostics = (report["diagnostics"] as? [String] ?? []).joined(separator: "\n")
                    guard status == "applied" else {
                        throw TavernShellError { (status == "partial" ? L("shell.error.configPartial") : L("shell.error.configNotApplied")) + "\n" + diagnostics }
                    }
                    completion(.success(diagnostics))
                } catch { completion(.failure(error)) }
            }
        }
    }
    private func publicCommand(_ method: String, _ params: [String: Any]) {
        guard let options, attached, !publicRequestBusy, !string(snapshot["boot_id"]).isEmpty else {
            localizedError { L("shell.error.publicUnavailable") }; return
        }
        publicRequestBusy = true
        let epoch = generation, boot = string(snapshot["boot_id"])
        let command: [String: Any] = ["id":UUID().uuidString,"method":method,"params":params]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<[String: Any], Error>
            do { result = .success(try RustConnection.publicRequest(path: options.publicSocketPath, request: command)) }
            catch { result = .failure(error) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.publicRequestBusy = false
                guard self.generation == epoch, !self.terminated else { return }
                switch result {
                case .failure(let failure): self.localizedError { failure.localizedDescription }
                case .success(let response):
                    let rejection = dictionary(response["error"])
                    if !rejection.isEmpty { self.error(method + ": " + string(rejection["message"])); return }
                    guard params["focus"] as? Bool == true, string(self.snapshot["boot_id"]) == boot else { return }
                    let result = dictionary(response["result"])
                    let destination: [String: Any]
                    let paneKey: String
                    switch method {
                    case "pane.move":
                        destination = dictionary(dictionary(result["move_result"])["pane"]); paneKey = "pane_id"
                    case "layout.apply":
                        destination = dictionary(result["layout"]); paneKey = "focused_pane_id"
                    default: return
                    }
                    let tab = string(destination["tab_id"]), pane = string(destination[paneKey])
                    guard !tab.isEmpty, !pane.isEmpty else { self.localizedError { L("shell.error.destinationResponse", method) }; return }
                    // Public API focus belongs to the server, not this endpoint's projection.
                    self.request("tab.focus", ["tab_id":tab]) { [weak self] _ in
                        guard let self, string(self.snapshot["boot_id"]) == boot else { return }
                        self.request("pane.focus", ["pane_id":pane])
                    }
                }
            }
        }
    }
    private func toggleSidebar() {
        let hiding = !sidebarPanel.isHidden
        sidebarTransitionView?.removeFromSuperview(); sidebarTransitionView = nil
        if hiding {
            sidebarWidth = sidebarPanel.frame.width
            // Снимок только навигации; геометрия терминала меняется сразу.
            if TavernMotion.enabled, window.isVisible,
               let bitmap = sidebarPanel.bitmapImageRepForCachingDisplay(in: sidebarPanel.bounds) {
                sidebarPanel.cacheDisplay(in: sidebarPanel.bounds, to: bitmap)
                let image = NSImage(size: sidebarPanel.bounds.size); image.addRepresentation(bitmap)
                let overlay = NavigationTransitionView(frame: sidebarPanel.convert(sidebarPanel.bounds, to: root))
                overlay.image = image; overlay.imageScaling = .scaleAxesIndependently
                overlay.setAccessibilityElement(false)
                root.addSubview(overlay, positioned: .below, relativeTo: rootChrome)
                sidebarTransitionView = overlay
                TavernMotion.disappear(overlay) { [weak self, weak overlay] in
                    overlay?.removeFromSuperview()
                    if self?.sidebarTransitionView === overlay { self?.sidebarTransitionView = nil }
                }
            }
        }
        sidebarPanel.isHidden = hiding
        createWorkspaceButton.isEnabled = attached && !hiding
        for button in sidebarButtons.values { button.isEnabled = attached && !hiding }
        if hiding { sidebarPanel.removeFromSuperview() }
        else { mainSplit.insertArrangedSubview(sidebarPanel, at: 0) }
        mainSplit.adjustSubviews()
        if !hiding { mainSplit.setPosition(sidebarWidth, ofDividerAt: 0) }
        layoutBody(); rebuildNavigation()
        if !hiding { TavernMotion.appear(sidebarPanel) }
    }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { subview === sidebarPanel }
    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool { view === body }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { 180 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { min(360, max(180, splitView.bounds.width - 400)) }
    func splitViewDidResizeSubviews(_ notification: Notification) { layoutBody(); rebuildNavigation() }
    func windowDidResize(_ notification: Notification) { layoutBody(); rebuildNavigation() }
    func windowDidChangeBackingProperties(_ notification: Notification) { surface.updateGeometry() }
    func applicationDidBecomeActive(_ notification: Notification) { markVisiblePaneRead() }
    func windowDidChangeOcclusionState(_ notification: Notification) { markVisiblePaneRead() }
    func windowDidResignKey(_ notification: Notification) {
        navigationDrag.cancel()
        if attached {
            surface.releasePressedKeys(); popupSurface.releasePressedKeys()
            send(["type": "focus", "focused": false])
        }
    }
    func windowDidBecomeKey(_ notification: Notification) {
        guard attached, !snapshot.isEmpty else { return }
        send(["type":"focus","focused":true]); resumeSurface()
        markVisiblePaneRead()
    }
    private func resumeSurface() {
        let tab = string(snapshot["focused_tab_id"]), boot = string(snapshot["boot_id"])
        guard !resumeRequested else { return }
        if !surfaceActive {
            resumeRequested = true
            request("client_shell.surface.set", ["active":true]) { [weak self] _ in
                guard let self, string(self.snapshot["boot_id"]) == boot else { return }
                self.surfaceActive = true
                self.resumeRequested = false
                if !tab.isEmpty { self.request("tab.focus", ["tab_id":tab]) }
            }
        } else if !tab.isEmpty { request("tab.focus", ["tab_id":tab]) }
    }
    func windowDidMiniaturize(_ notification: Notification) {
        guard attached, surfaceActive else { return }
        // Mark local intent immediately because BecomeKey may precede Deminiaturize;
        // endpoint requests remain serialized and resume awaits the active reply.
        surfaceActive = false
        request("client_shell.surface.set", ["active":false])
    }
    func windowDidDeminiaturize(_ notification: Notification) { if attached { resumeSurface() } }
    func windowWillClose(_ notification: Notification) { detach(); NSApp.terminate(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Между окнами установки основного окна приложения ещё нет.
        herdrSetup == nil
    }
    func applicationWillTerminate(_ notification: Notification) {
        herdrSetup?.cancel()
        detach()
    }
    private func detach() {
        guard !terminated else { return }
        terminated = true; generation += 1
        navigationDrag.cancel()
        soundPlayer.stop()
        requestTimeout?.invalidate(); requests.removeAll(); inFlight = nil
        connection?.close(); connection = nil
    }
}

private extension TavernDelegate {
    func sourcePane(_ source: TavernDragSource) -> [String: Any]? {
        guard case .pane(let id) = source else { return nil }
        return objects(snapshot["panes"]).first { string($0["pane_id"]) == id }
    }

    func dragSourceExists(_ source: TavernDragSource) -> Bool {
        switch source {
        case .tab(let id): return objects(snapshot["tabs"]).contains { string($0["tab_id"]) == id }
        case .pane: return sourcePane(source) != nil
        }
    }

    func beginNavigationDrag(_ button: NSButton, event: NSEvent, source: TavernDragSource,
                             visual: (() -> NSImage?)? = nil) -> Bool {
        guard attached, !publicRequestBusy, window.attachedSheet == nil, popupID.isEmpty,
              dragSourceExists(source) else { return false }
        let epoch = generation, boot = string(snapshot["boot_id"])
        let workspace = string(snapshot["focused_workspace_id"])
        let sourceTab = sourcePane(source).map { string($0["tab_id"]) } ?? ""
        let sidebarSource = (button as? NavigationButton)?.actionName == "agent.focus"
        var draggedIDs: [String] = []
        let members: () -> [NSButton] = { [weak self] in
            guard let self else { return [] }
            if self.navigationDrag.tracking {
                draggedIDs = objects(self.snapshot["agents"]).filter {
                    string($0["tab_id"]) == sourceTab && string($0["workspace_id"]) == workspace
                }.map { string($0["pane_id"]) }
            }
            return draggedIDs.compactMap { self.sidebarButtons[NavigationKey(action: "agent.focus", target: $0)] }
        }
        let limits: () -> NSRect = { [weak self] in
            guard let self else { return .zero }
            if case .tab = source { return self.tabScroll.contentView.convert(self.tabScroll.contentView.bounds, to: self.root) }
            return self.mainSplit.convert(self.mainSplit.bounds, to: self.root).insetBy(dx: 4, dy: 4)
        }
        return navigationDrag.track(button: button, event: event, root: root, limits: limits, valid: { [weak self] in
            guard let self else { return false }
            return self.attached && self.generation == epoch && string(self.snapshot["boot_id"]) == boot
                && string(self.snapshot["focused_workspace_id"]) == workspace
                && self.popupID.isEmpty && self.window.attachedSheet == nil && self.dragSourceExists(source)
        }, visual: visual, members: sidebarSource ? members : nil, connections: { [weak self] cards in
            guard let self, sidebarSource else { return [] }
            let ids = Set(cards.compactMap { ($0 as? NavigationButton)?.targetID })
            let agents = objects(self.snapshot["agents"]).filter { string($0["workspace_id"]) == workspace }
            var links: [NSView] = []
            for index in agents.indices.dropFirst() {
                let lower = string(agents[index]["pane_id"]), upper = string(agents[index - 1]["pane_id"])
                if ids.contains(lower) || ids.contains(upper), let chain = self.agentChains[lower] {
                    links.append(chain)
                }
            }
            return links
        }, bundleAt: { [weak self] point, proposal in
            guard let self, sidebarSource else { return false }
            if let proposal, case .tabSlot = proposal.target { return true }
            return !self.sidebarPanel.isHidden
                && self.sidebarScroll.contentView.convert(self.sidebarScroll.contentView.bounds, to: self.root).contains(point)
        }, proposal: { [weak self] point in
            self?.navigationDrop(source: source, at: point)
        }, autoscroll: { [weak self] point in
            self?.scrollDragTabs(at: point)
            if case .pane = source { self?.scrollDragAgents(at: point) }
        }, perform: { [weak self] target, completion in
            guard let self else { completion(false); return }
            self.performNavigationMove(source: source, target: target, completion: completion)
        })
    }

    func scrollDragTabs(at point: NSPoint) {
        let viewport = tabScroll.contentView.convert(tabScroll.contentView.bounds, to: root)
        guard viewport.contains(point) else { return }
        let delta: CGFloat = point.x < viewport.minX + 24 ? -12 : point.x > viewport.maxX - 24 ? 12 : 0
        guard delta != 0 else { return }
        let clip = tabScroll.contentView
        let x = max(0, min(tabbar.bounds.width - clip.bounds.width, clip.bounds.minX + delta))
        if x != clip.bounds.minX {
            clip.scroll(to: NSPoint(x: x, y: clip.bounds.minY)); tabScroll.reflectScrolledClipView(clip)
        }
    }

    func scrollDragAgents(at point: NSPoint) {
        guard sidebarPanel.superview != nil, !sidebarPanel.isHidden else { return }
        let viewport = sidebarScroll.contentView.convert(sidebarScroll.contentView.bounds, to: root)
        guard viewport.contains(point) else { return }
        let delta: CGFloat = point.y > viewport.maxY - 24 ? 12 : point.y < viewport.minY + 24 ? -12 : 0
        guard delta != 0 else { return }
        let clip = sidebarScroll.contentView
        let y = max(0, min(sidebar.bounds.height - clip.bounds.height, clip.bounds.minY + delta))
        if y != clip.bounds.minY {
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y)); sidebarScroll.reflectScrolledClipView(clip)
        }
    }

    func agentGroupDrop(sourcePaneID: String, sourceTabID: String, at point: NSPoint) -> TavernDropProposal? {
        guard sidebarPanel.superview != nil, !sidebarPanel.isHidden else { return nil }
        let viewport = sidebarScroll.contentView.convert(sidebarScroll.contentView.bounds, to: root)
        guard viewport.contains(point) else { return nil }
        let agents = objects(snapshot["agents"])
        var hovered: (id: String, tab: String, rect: NSRect)?
        var nearestDistance = CGFloat.greatestFiniteMagnitude
        var firstTop = -CGFloat.greatestFiniteMagnitude
        for agent in agents {
            let id = string(agent["pane_id"])
            guard let button = sidebarButtons[NavigationKey(action: "agent.focus", target: id)], button.isEnabled else { continue }
            let rect = button.convert(button.bounds, to: root)
            firstTop = max(firstTop, rect.maxY)
            let distance = max(0, max(rect.minY - point.y, point.y - rect.maxY))
            if distance < nearestDistance {
                hovered = (id: id, tab: string(agent["tab_id"]), rect: rect)
                nearestDistance = distance
            }
        }
        guard let hovered, point.y <= firstTop + 3 else { return nil }
        var group = NSRect.null, related: [NSRect] = []
        var count = 0
        for agent in agents {
            let tab = string(agent["tab_id"])
            if tab == sourceTabID { count += 1 }
            guard let button = sidebarButtons[NavigationKey(action: "agent.focus", target: string(agent["pane_id"]))] else { continue }
            let rect = button.convert(button.bounds, to: root)
            if tab == hovered.tab { group = group.union(rect) }
        }
        guard !group.isNull else { return nil }
        let after = point.y < group.midY
        guard let slot = try? TavernNavigationMoves.agentTabSlot(sourcePaneID: sourcePaneID, targetPaneID: hovered.id,
                                                                 after: after, snapshot: snapshot) else { return nil }
        if let tabButton = tabButtons[NavigationKey(action: "tab.focus", target: sourceTabID)] {
            let tabViewport = tabScroll.contentView.convert(tabScroll.contentView.bounds, to: root)
            let visible = tabButton.convert(tabButton.bounds, to: root).intersection(tabViewport)
            if !visible.isEmpty { related.append(visible) }
        }
        let edge = after ? group.minY : group.maxY
        let y = min(max(viewport.minY + 1, edge - 2), viewport.maxY - 5)
        let marker = NSRect(x: viewport.minX + 4, y: y, width: max(0, viewport.width - 8), height: 4)
        let tab = objects(snapshot["tabs"]).first { string($0["tab_id"]) == sourceTabID }
        let label = string(tab?["label"]).isEmpty ? sourceTabID : string(tab?["label"])
        return TavernDropProposal(target: .tabSlot(slot), rect: marker,
                                  title: L("shell.drag.entireTab", label, count), relatedRects: related)
    }

    func navigationDrop(source: TavernDragSource, at point: NSPoint) -> TavernDropProposal? {
        let tabs = focusedTabs()
        if case .tab(let id) = source {
            let viewport = tabScroll.contentView.convert(tabScroll.contentView.bounds, to: root)
            guard viewport.contains(point), let oldIndex = tabs.firstIndex(where: { string($0["tab_id"]) == id }) else { return nil }
            let local = tabbar.convert(point, from: root)
            var slot = tabs.count
            for (index, row) in tabs.enumerated() {
                if let button = tabButtons[NavigationKey(action: "tab.focus", target: string(row["tab_id"]))],
                   local.x < button.frame.midX { slot = index; break }
            }
            guard slot != oldIndex && slot != oldIndex + 1 else { return nil }
            let markerX: CGFloat
            if slot < tabs.count, let button = tabButtons[NavigationKey(action: "tab.focus", target: string(tabs[slot]["tab_id"]))] { markerX = button.frame.minX - 1 }
            else { markerX = tabButtons.values.map { $0.frame.maxX }.max() ?? 8 }
            let marker = tabbar.convert(NSRect(x: markerX - 1, y: 0, width: 4, height: 38), to: root).intersection(viewport)
            return TavernDropProposal(target: .tabSlot(slot), rect: marker, title: L("shell.drag.reorderTab"))
        }
        guard case .pane(let id) = source, let pane = sourcePane(source) else { return nil }
        let sourceTab = string(pane["tab_id"])
        if let group = agentGroupDrop(sourcePaneID: id, sourceTabID: sourceTab, at: point) { return group }
        guard !objects(snapshot["tabs"]).contains(where: { string($0["tab_id"]) == sourceTab && flag($0["zoomed"]) }) else { return nil }
        if addTab.convert(addTab.bounds, to: root).contains(point) {
            return TavernDropProposal(target: .newTab(string(snapshot["focused_workspace_id"])),
                                      rect: addTab.convert(addTab.bounds, to: root), title: L("shell.drag.newTab"))
        }
        let viewport = tabScroll.contentView.convert(tabScroll.contentView.bounds, to: root)
        if viewport.contains(point) {
            for button in tabButtons.values where button.convert(button.bounds, to: root).contains(point) {
                guard button.targetID != sourceTab,
                      !tabs.contains(where: { string($0["tab_id"]) == button.targetID && flag($0["zoomed"]) }) else { return nil }
                return TavernDropProposal(target: .tab(button.targetID), rect: button.convert(button.bounds, to: root).intersection(viewport),
                                          title: L("shell.drag.moveTab"))
            }
        }
        guard !surface.isHidden else { return nil }
        let local = surface.convert(point, from: root)
        guard surface.bounds.contains(local) else { return nil }
        let cell = NSPoint(x: floor(local.x / surface.cellWidth), y: floor(local.y / surface.cellHeight))
        // Drop на рамку принадлежит панели, хотя ввод мыши в PTY ограничен inner_rect.
        let target = surface.paneAt(cell) ?? objects(surface.scene["panes"]).first { pane in
            let r = dictionary(pane["rect"])
            return NSRect(x: number(r["x"]), y: number(r["y"]), width: number(r["width"]), height: number(r["height"])).contains(cell)
        }
        guard let target else { return nil }
        let targetID = string(target["pane_id"])
        guard targetID != id, let row = objects(snapshot["panes"]).first(where: { string($0["pane_id"]) == targetID }),
              !tabs.contains(where: { string($0["tab_id"]) == string(row["tab_id"]) && flag($0["zoomed"]) }) else { return nil }
        let geometry = dictionary(target["inner_rect"])
        let rect = surface.convert(NSRect(x: number(geometry["x"]) * surface.cellWidth, y: number(geometry["y"]) * surface.cellHeight,
                                          width: number(geometry["width"]) * surface.cellWidth, height: number(geometry["height"]) * surface.cellHeight), to: root)
        let x = (point.x - rect.minX) / max(1, rect.width), y = (point.y - rect.minY) / max(1, rect.height)
        if sourceTab == string(row["tab_id"]) {
            guard x > 0.22 && x < 0.78 && y > 0.22 && y < 0.78 else { return nil }
            let center = rect.insetBy(dx: rect.width * 0.22, dy: rect.height * 0.22)
            return TavernDropProposal(target: .pane(targetID, .center), rect: center, title: L("shell.drag.swap"))
        }
        if x >= 0.75 && 1 - x <= y {
            return TavernDropProposal(target: .pane(targetID, .right),
                                      rect: NSRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height), title: L("shell.drag.right"))
        }
        if y <= 0.25 {
            return TavernDropProposal(target: .pane(targetID, .bottom),
                                      rect: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2), title: L("shell.drag.down"))
        }
        return nil
    }

    func layoutPaneGrips() {
        guard surface != nil else { return }
        let available = attached && !surface.isHidden && popupID.isEmpty && window.attachedSheet == nil
        let visible = available ? objects(surface.scene["panes"]) : []
        let ids = Set(visible.map { string($0["pane_id"]) })
        for id in Array(paneGrips.keys) where !ids.contains(id) { paneGrips.removeValue(forKey: id)?.removeFromSuperview() }
        for pane in visible {
            let id = string(pane["pane_id"]), geometry = dictionary(pane["inner_rect"])
            let rect = surface.convert(NSRect(x: number(geometry["x"]) * surface.cellWidth, y: number(geometry["y"]) * surface.cellHeight,
                                              width: number(geometry["width"]) * surface.cellWidth, height: number(geometry["height"]) * surface.cellHeight), to: terminalFrame)
            let grip: TavernPaneGrip
            if let existing = paneGrips[id] { grip = existing }
            else {
                grip = TavernPaneGrip(title: "", target: self, action: #selector(focusPaneGrip(_:)))
                grip.identifier = NSUserInterfaceItemIdentifier(id)
                grip.setAccessibilityIdentifier("navigation.pane.grip." + id)
                grip.onPress = { [weak self] button, event in
                    guard let self else { return }
                    if event.modifierFlags.contains(.control) {
                        if let menu = self.paneContextMenu(id) { TavernContextMenu.popUp(menu, with: event, for: button) }
                        return
                    }
                    _ = self.beginNavigationDrag(button, event: event, source: .pane(id), visual: { [weak self] in self?.paneDragImage(id) })
                }
                grip.contextMenu = { [weak self] in self?.paneContextMenu(id) }
                paneGrips[id] = grip; terminalFrame.addSubview(grip)
            }
            grip.setAccessibilityLabel(L("shell.pane.drag.label", id))
            grip.toolTip = L("shell.drag.help")
            grip.frame = NSRect(x: rect.maxX - 26, y: rect.maxY - 16, width: 24, height: 14)
            grip.isHidden = rect.width < 40 || rect.height < 24
        }
    }

    @objc func focusPaneGrip(_ sender: TavernPaneGrip) {
        if let id = sender.identifier?.rawValue { request("pane.focus", ["pane_id": id]) }
    }

    func paneDragImage(_ id: String) -> NSImage? {
        guard let pane = objects(surface.scene["panes"]).first(where: { string($0["pane_id"]) == id }) else { return nil }
        let r = dictionary(pane["inner_rect"])
        let rect = NSRect(x: number(r["x"]) * surface.cellWidth, y: number(r["y"]) * surface.cellHeight,
                          width: number(r["width"]) * surface.cellWidth, height: number(r["height"]) * surface.cellHeight).intersection(surface.bounds)
        guard !rect.isEmpty, let bitmap = surface.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        surface.cacheDisplay(in: rect, to: bitmap)
        let image = NSImage(size: rect.size); image.addRepresentation(bitmap); return image
    }

    func performNavigationMove(source: TavernDragSource, target: TavernDropTarget, completion: @escaping (Bool) -> Void) {
        guard attached, !publicRequestBusy, let options, dragSourceExists(source) else { completion(false); return }
        publicRequestBusy = true
        let epoch = generation, boot = string(snapshot["boot_id"]), state = snapshot
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<TavernMoveOutcome, Error>
            do {
                result = .success(try TavernNavigationMoves.execute(source: source, target: target, snapshot: state) { method, params in
                    let response = try RustConnection.publicRequest(path: options.publicSocketPath,
                                                                    request: ["id": UUID().uuidString, "method": method, "params": params])
                    let rejection = dictionary(response["error"])
                    if !rejection.isEmpty { throw NativeError.message(method + ": " + string(rejection["message"])) }
                    return dictionary(response["result"])
                })
            } catch { result = .failure(error) }
            DispatchQueue.main.async {
                guard let self else { completion(false); return }
                self.publicRequestBusy = false
                guard self.generation == epoch, self.attached, !self.terminated,
                      string(self.snapshot["boot_id"]) == boot else { completion(false); return }
                switch result {
                case .failure(let failure): self.localizedError { failure.localizedDescription }; completion(false)
                case .success(let outcome):
                    if outcome.changed {
                        self.soundPlayer.play(.interfaceMove)
                        if let tab = outcome.tabID {
                            self.request("tab.focus", ["tab_id": tab]) { [weak self] _ in
                                guard let self, self.generation == epoch, string(self.snapshot["boot_id"]) == boot else { return }
                                if let pane = outcome.paneID { self.request("pane.focus", ["pane_id": pane]) }
                            }
                        } else if let pane = outcome.paneID { self.request("pane.focus", ["pane_id": pane]) }
                    }
                    completion(outcome.changed)
                }
            }
        }
    }
}

_ = TavernLocalization.shared
tavern_set_language(TavernLocalization.shared.language.nativeValue)
let application = NSApplication.shared
application.setActivationPolicy(.regular)
let delegate = TavernDelegate()
application.delegate = delegate
application.run()
