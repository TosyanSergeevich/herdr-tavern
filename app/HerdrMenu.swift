import AppKit
import Darwin

private struct HerdrConfigDocument: Decodable {
    struct Settings: Decodable {
        let theme: String
        let auto_switch: Bool
        let indicators: String
        let sound: Bool
        let toast: String
    }
    let content: String
    let settings: Settings
}

private struct HerdrConfigSnapshot {
    let url: URL
    let bytes: Data?
    let document: HerdrConfigDocument
}

// Только локальный глобальный config: upstream не разделяет его по сессиям.
private final class HerdrConfigService {
    static let maximumBytes = 1024 * 1024
    private let options: LaunchOptions
    private let worker = DispatchQueue(label: "org.local.HerdrTavern.herdrConfig", qos: .userInitiated)
    private let environment = ProcessInfo.processInfo.environment
    private let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)

    init(options: LaunchOptions) { self.options = options }

    private func configURL() -> URL {
        if let path = environment["HERDR_CONFIG_PATH"] {
            return URL(fileURLWithPath: path, relativeTo: workingDirectory).standardizedFileURL
        }
        let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        let base = environment["XDG_CONFIG_HOME"] ?? home + "/.config"
        return URL(fileURLWithPath: base, relativeTo: workingDirectory)
            .appendingPathComponent("herdr/config.toml").standardizedFileURL
    }

    private func readBytes(_ url: URL) throws -> Data? {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
            return nil
        }
        defer { try? handle.close() }
        var bytes = Data()
        while let chunk = try handle.read(upToCount: Self.maximumBytes + 1 - bytes.count), !chunk.isEmpty {
            bytes.append(chunk)
            guard bytes.count <= Self.maximumBytes else {
                throw TavernShellError { L("shell.herdr.error.configSize") }
            }
        }
        return bytes
    }

    private func transform(_ bytes: Data?, edit: [String: Any]? = nil) throws -> HerdrConfigDocument {
        guard let content = String(data: bytes ?? Data(), encoding: .utf8) else {
            throw TavernShellError { L("shell.herdr.error.encoding") }
        }
        var request: [String: Any] = ["content": content]
        if let edit { request["edit"] = edit }
        let data = try JSONSerialization.data(withJSONObject: request)
        guard data.count <= Self.maximumBytes else {
            throw TavernShellError { L("shell.herdr.error.editorSize") }
        }
        var response: UnsafeMutablePointer<CChar>?, error: UnsafeMutablePointer<CChar>?
        let result = data.withUnsafeBytes { bytes in
            tavern_config_json(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &response, &error)
        }
        guard result == 0, let response else {
            if let response { tavern_string_free(response) }
            throw NativeError.message(ownedString(error))
        }
        if let error { tavern_string_free(error) }
        return try JSONDecoder().decode(HerdrConfigDocument.self, from: Data(ownedString(response).utf8))
    }

    private func snapshot() throws -> HerdrConfigSnapshot {
        let url = configURL().resolvingSymlinksInPath()
        let bytes = try readBytes(url)
        return HerdrConfigSnapshot(url: url, bytes: bytes, document: try transform(bytes))
    }

    private func deliver<T>(_ result: Result<T, Error>, _ completion: @escaping (Result<T, Error>) -> Void) {
        DispatchQueue.main.async { completion(result) }
    }

    func read(completion: @escaping (Result<HerdrConfigSnapshot, Error>) -> Void) {
        worker.async { [self] in deliver(Result { try snapshot() }, completion) }
    }

    private func run(_ arguments: [String], config: URL? = nil, completion: @escaping (Result<String, Error>) -> Void) {
        do {
            var selectedEnvironment = environment
            if let config { selectedEnvironment["HERDR_CONFIG_PATH"] = config.path }
            let command = HerdrConfigProcess(executable: try options.resolveExecutable(), arguments: arguments,
                                             environment: selectedEnvironment, directory: workingDirectory,
                                             worker: worker, completion: completion)
            command.start()
        } catch { completion(.failure(error)) }
    }

    private func validate(_ content: String, relativeTo config: URL, completion: @escaping (Result<String, Error>) -> Void) {
        do {
            // herdr разрешает относительные пути от каталога config.toml.
            // Проверочная копия рядом с исходником сохраняет этот смысл.
            let parent = config.deletingLastPathComponent()
            let temporaryDirectory: URL?
            let directory: URL
            if FileManager.default.fileExists(atPath: parent.path) {
                temporaryDirectory = nil
                directory = parent
            } else {
                let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("tavern-config-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                temporaryDirectory = temporary
                directory = temporary
            }
            let url = directory.appendingPathComponent(".tavern-check-" + UUID().uuidString + ".toml")
            guard FileManager.default.createFile(atPath: url.path, contents: Data(content.utf8),
                                                 attributes: [.posixPermissions: 0o600]) else {
                if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
                throw TavernShellError { L("shell.herdr.error.validationCopy") }
            }
            run(["config", "check"], config: url) { result in
                try? FileManager.default.removeItem(at: url)
                if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
                completion(result)
            }
        } catch { completion(.failure(error)) }
    }

    func check(completion: @escaping (Result<String, Error>) -> Void) {
        worker.async { [self] in
            do {
                let current = try snapshot()
                // Проверяем копию именно прочитанного файла, не меняя пользовательский config.
                validate(current.document.content, relativeTo: current.url) { self.deliver($0, completion) }
            } catch { deliver(.failure(error), completion) }
        }
    }

    func edit(kind: String, value: Any, completion: @escaping (Result<HerdrConfigSnapshot, Error>) -> Void) {
        worker.async { [self] in
            do {
                let original = try snapshot()
                let proposed = try transform(original.bytes, edit: ["kind": kind, "value": value])
                let bytes = Data(proposed.content.utf8)
                guard bytes.count <= Self.maximumBytes else {
                    throw TavernShellError { L("shell.herdr.error.editedSize") }
                }
                validate(proposed.content, relativeTo: original.url) { validation in
                    let result = validation.flatMap { _ in Result { () -> HerdrConfigSnapshot in
                        guard self.configURL().resolvingSymlinksInPath() == original.url,
                              try self.readBytes(original.url) == original.bytes else {
                            throw TavernShellError { L("shell.herdr.error.conflict") }
                        }
                        try self.save(bytes, to: original.url, replacing: original.bytes != nil)
                        return HerdrConfigSnapshot(url: original.url, bytes: bytes, document: proposed)
                    } }
                    self.deliver(result, completion)
                }
            } catch { deliver(.failure(error), completion) }
        }
    }

    private func save(_ bytes: Data, to url: URL, replacing: Bool) throws {
        if replacing {
            try bytes.write(to: url, options: .atomic)
            return
        }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staged = directory.appendingPathComponent(".config-" + UUID().uuidString + ".tmp")
        guard FileManager.default.createFile(atPath: staged.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw TavernShellError { L("shell.herdr.error.save") }
        }
        defer { try? FileManager.default.removeItem(at: staged) }
        let handle = try FileHandle(forWritingTo: staged)
        do {
            try handle.write(contentsOf: bytes)
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        // Публикуем готовый файл атомарно и без перезаписи появившегося config.
        try FileManager.default.linkItem(at: staged, to: url)
    }

    func openConfig(completion: @escaping (Result<URL, Error>) -> Void) {
        worker.async { [self] in
            let url = configURL().resolvingSymlinksInPath()
            // Даже некорректный или слишком большой файл можно открыть для исправления.
            if FileManager.default.fileExists(atPath: url.path) {
                deliver(.success(url), completion)
                return
            }
            run(["--default-config"]) { output in
                let result = output.flatMap { content in Result { () -> URL in
                    _ = try self.transform(Data(content.utf8))
                    try self.save(Data(content.utf8), to: url, replacing: false)
                    return url
                } }
                self.deliver(result, completion)
            }
        }
    }

    func defaultConfig(completion: @escaping (Result<String, Error>) -> Void) {
        worker.async { [self] in run(["--default-config"]) { self.deliver($0, completion) } }
    }
}

// Process завершает операцию callbacks-ами: main и рабочая очередь не ждут процесс.
private final class HerdrConfigProcess {
    private let process = Process()
    private let worker: DispatchQueue
    private let completion: (Result<String, Error>) -> Void
    private let arguments: [String]
    private var temporaryDirectory: URL?
    private var outputURL: URL?
    private var output: FileHandle?
    private var timer: DispatchSourceTimer?
    private var deadline = Date.distantFuture
    private var stopError: Error?
    private var killDeadline = Date.distantFuture
    private var finished = false

    init(executable: String, arguments: [String], environment: [String: String], directory: URL,
         worker: DispatchQueue, completion: @escaping (Result<String, Error>) -> Void) {
        self.worker = worker; self.completion = completion; self.arguments = arguments
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
    }

    func start() {
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tavern-config-command-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            temporaryDirectory = directory
            let url = directory.appendingPathComponent("output")
            outputURL = url
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw TavernShellError { L("shell.herdr.error.output") }
            }
            output = try FileHandle(forWritingTo: url)
            process.standardOutput = output
            process.standardError = output
            process.terminationHandler = { [self] _ in worker.async { self.finish() } }
            try process.run()
            deadline = Date().addingTimeInterval(15)
            let timer = DispatchSource.makeTimerSource(queue: worker)
            timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        } catch { finish(error: error) }
    }

    private func tick() {
        guard !finished else { return }
        if stopError == nil {
            if Date() >= deadline {
                stopError = TavernShellError { L("shell.herdr.error.timeout") }
            } else if let outputURL {
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
                    if (attributes[.size] as? NSNumber)?.intValue ?? 0 > HerdrConfigService.maximumBytes {
                        stopError = TavernShellError { L("shell.herdr.error.outputSize") }
                    }
                } catch { stopError = error }
            }
            if stopError != nil {
                if process.isRunning { process.terminate() }
                killDeadline = Date().addingTimeInterval(1)
            }
        } else if Date() >= killDeadline {
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            finish(error: stopError)
        }
    }

    private func finish(error: Error? = nil) {
        guard !finished else { return }
        finished = true
        timer?.cancel(); timer = nil
        process.terminationHandler = nil
        try? output?.close(); output = nil
        defer { if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) } }
        if let error = error ?? stopError { completion(.failure(error)); return }
        let result = Result { () -> String in
            guard let outputURL else { throw TavernShellError { L("shell.herdr.error.outputUnavailable") } }
            let handle = try FileHandle(forReadingFrom: outputURL)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: HerdrConfigService.maximumBytes + 1) ?? Data()
            guard data.count <= HerdrConfigService.maximumBytes, let text = String(data: data, encoding: .utf8) else {
                throw TavernShellError { L("shell.herdr.error.invalidOutput") }
            }
            guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                let command = arguments.joined(separator: " "), status = Int(process.terminationStatus)
                throw TavernShellError { L("shell.herdr.error.exit", command, status, text) }
            }
            return text
        }
        completion(result)
    }
}

final class HerdrMenuController: NSObject, NSMenuDelegate {
    let menu = NSMenu(title: "herdr")
    private let service: HerdrConfigService
    private let showIntegrations: () -> Void
    private let reload: (@escaping (Result<String, Error>) -> Void) -> Void
    private var choices: [NSMenuItem] = []
    private var operations: [NSMenuItem] = []
    private let status = NSMenuItem(title: L("shell.herdr.status.unread"), action: nil, keyEquivalent: "")
    private let automaticTheme = NSMenuItem(title: L("shell.herdr.theme.autoOff"), action: nil, keyEquivalent: "")
    private var current: HerdrConfigSnapshot?
    private var busy = false
    private var reading = false
    private var readGeneration = 0
    private var localizedTitles: [() -> Void] = []
    private var statusText: () -> String = { L("shell.herdr.status.unread") }

    init(options: LaunchOptions, showIntegrations: @escaping () -> Void,
         reload: @escaping (@escaping (Result<String, Error>) -> Void) -> Void) {
        service = HerdrConfigService(options: options)
        self.showIntegrations = showIntegrations
        self.reload = reload
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        let themes = submenu(L("shell.herdr.theme"))
        explanation(L("shell.herdr.theme.help"), in: themes)
        explanation(L("shell.herdr.theme.manual"), in: themes)
        automaticTheme.isEnabled = false
        themes.addItem(automaticTheme)
        themes.addItem(.separator())
        for name in ["catppuccin", "catppuccin-latte", "terminal", "tokyo-night", "tokyo-night-day", "dracula", "nord", "gruvbox", "gruvbox-light", "one-dark", "one-light", "solarized", "solarized-light", "kanagawa", "kanagawa-lotus", "rose-pine", "rose-pine-dawn", "vesper"] {
            choice(name, kind: "theme", value: name, in: themes)
        }
        let indicators = submenu(L("shell.herdr.indicators"))
        explanation(L("shell.herdr.indicators.help"), in: indicators)
        choice(L("shell.herdr.indicators.dots"), kind: "indicators", value: "dots", in: indicators)
        choice(L("shell.herdr.indicators.symbols"), kind: "indicators", value: "symbols", in: indicators)
        let sound = submenu(L("shell.herdr.sound"))
        explanation(L("shell.herdr.sound.help"), in: sound)
        choice(L("shell.herdr.enabled"), kind: "sound", value: true, in: sound)
        choice(L("shell.herdr.disabled"), kind: "sound", value: false, in: sound)
        let toast = submenu(L("shell.herdr.notifications"))
        explanation(L("shell.herdr.notifications.help"), in: toast)
        for (title, value) in [("shell.herdr.notifications.off", "off"), ("shell.herdr.notifications.herdr", "herdr"), ("shell.herdr.notifications.terminal", "terminal"), ("shell.herdr.notifications.system", "system")] {
            choice(L(title), kind: "toast", value: value, in: toast)
        }
        action(L("shell.herdr.integrations"), selector: #selector(integrations), serialized: false)
        menu.addItem(.separator())
        explanation(L("shell.herdr.config.shared"), in: menu)
        if options.connectOnly {
            explanation(L("shell.herdr.config.socket"), in: menu)
        }
        status.isEnabled = false
        menu.addItem(status)
        action(L("shell.herdr.config.open"), selector: #selector(openConfig))
        action(L("shell.herdr.config.defaults"), selector: #selector(showDefault))
        action(L("shell.herdr.config.check"), selector: #selector(checkConfig))
        action(L("shell.herdr.config.reload"), selector: #selector(reloadConfig))
        updateEnabled()
    }

    private func submenu(_ title: @autoclosure @escaping () -> String) -> NSMenu {
        let child = NSMenu(title: title())
        child.autoenablesItems = false
        let item = NSMenuItem(title: title(), action: nil, keyEquivalent: "")
        localizedTitles.append { item.title = title(); child.title = title() }
        item.submenu = child
        menu.addItem(item)
        return child
    }

    private func explanation(_ text: @autoclosure @escaping () -> String, in parent: NSMenu) {
        let item = NSMenuItem(title: text(), action: nil, keyEquivalent: "")
        localizedTitles.append { item.title = text() }
        item.isEnabled = false
        parent.addItem(item)
    }

    private func choice(_ title: @autoclosure @escaping () -> String, kind: String, value: Any, in parent: NSMenu) {
        let item = NSMenuItem(title: title(), action: #selector(selectSetting(_:)), keyEquivalent: "")
        localizedTitles.append { item.title = title() }
        item.target = self
        item.representedObject = ["kind": kind, "value": value]
        item.identifier = NSUserInterfaceItemIdentifier("herdr.config.\(kind).\(value)")
        choices.append(item)
        parent.addItem(item)
    }

    private func action(_ title: @autoclosure @escaping () -> String, selector: Selector, serialized: Bool = true) {
        let item = NSMenuItem(title: title(), action: selector, keyEquivalent: "")
        localizedTitles.append { item.title = title() }
        item.target = self
        menu.addItem(item)
        if serialized { operations.append(item) }
    }

    private func updateEnabled() {
        for item in choices { item.isEnabled = !busy && !reading && current != nil }
        for item in operations { item.isEnabled = !busy }
    }

    private func display(_ snapshot: HerdrConfigSnapshot?) {
        current = snapshot
        let settings = snapshot?.document.settings
        for item in choices {
            item.state = .off
            guard let setting = item.representedObject as? [String: Any], let kind = setting["kind"] as? String,
                  let settings else { continue }
            switch kind {
            case "theme": item.state = (setting["value"] as? String == settings.theme && !settings.auto_switch) ? .on : .off
            case "indicators": item.state = setting["value"] as? String == settings.indicators ? .on : .off
            case "sound": item.state = setting["value"] as? Bool == settings.sound ? .on : .off
            case "toast": item.state = setting["value"] as? String == settings.toast ? .on : .off
            default: break
            }
        }
        automaticTheme.title = settings.map { $0.auto_switch ? L("shell.herdr.theme.autoOn") : L("shell.herdr.theme.autoOff") } ?? L("shell.herdr.theme.autoUnknown")
        updateEnabled()
    }
    func localize() {
        localizedTitles.forEach { $0() }
        status.title = statusText()
        display(current)
    }

    private func setStatus(_ text: @escaping () -> String) {
        statusText = text
        status.title = text()
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu, !busy, !reading else { return }
        refresh()
    }

    private func refresh() {
        readGeneration += 1
        let generation = readGeneration
        reading = true
        display(nil)
        setStatus { L("shell.herdr.status.reading") }
        service.read { [weak self] result in
            guard let self, generation == self.readGeneration else { return }
            self.reading = false
            switch result {
            case .success(let snapshot):
                self.display(snapshot)
                self.setStatus { snapshot.bytes == nil ? L("shell.herdr.status.defaults") : L("shell.herdr.status.loaded") }
                self.status.toolTip = snapshot.url.path
            case .failure(let error):
                self.display(nil)
                self.setStatus { L("shell.herdr.status.failed") }
                self.show(L("shell.herdr.error.read"), text: error.localizedDescription, failure: true)
            }
        }
    }

    private func beginOperation() -> Bool {
        guard !busy else { return false }
        busy = true
        readGeneration += 1
        reading = false
        updateEnabled()
        return true
    }

    private func endOperation() {
        busy = false
        updateEnabled()
    }

    @objc private func integrations() { showIntegrations() }

    @objc private func selectSetting(_ sender: NSMenuItem) {
        guard let setting = sender.representedObject as? [String: Any],
              let kind = setting["kind"] as? String, let value = setting["value"], beginOperation() else { return }
        service.edit(kind: kind, value: value) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.display(nil)
                self.endOperation()
                self.setStatus { L("shell.herdr.status.notSaved") }
                self.show(L("shell.herdr.error.notChanged"), text: error.localizedDescription, failure: true)
            case .success(let snapshot):
                self.display(snapshot)
                self.requestReload(saved: true)
            }
        }
    }

    @objc private func openConfig() {
        guard beginOperation() else { return }
        service.openConfig { [weak self] result in
            guard let self else { return }
            self.endOperation()
            switch result {
            case .success(let url):
                if !NSWorkspace.shared.open(url) {
                    self.show(L("shell.herdr.error.open"), text: L("shell.herdr.error.editor", url.path), failure: true)
                } else {
                    self.setStatus { L("shell.herdr.status.edited") }
                    self.status.toolTip = url.path
                }
            case .failure(let error): self.show(L("shell.herdr.error.open"), text: error.localizedDescription, failure: true)
            }
        }
    }

    @objc private func showDefault() {
        guard beginOperation() else { return }
        service.defaultConfig { [weak self] result in
            guard let self else { return }
            self.endOperation()
            switch result {
            case .success(let text): self.show(L("shell.herdr.defaults.title"), text: text, scroll: true)
            case .failure(let error): self.show(L("shell.herdr.error.defaults"), text: error.localizedDescription, failure: true)
            }
        }
    }

    @objc private func checkConfig() {
        guard beginOperation() else { return }
        service.check { [weak self] result in
            guard let self else { return }
            self.endOperation()
            switch result {
            case .success(let output): self.show(L("shell.herdr.check.success"), text: output)
            case .failure(let error): self.show(L("shell.herdr.check.failed"), text: error.localizedDescription, failure: true)
            }
        }
    }

    @objc private func reloadConfig() {
        guard beginOperation() else { return }
        service.check { [weak self] result in
            guard let self else { return }
            switch result {
            case .success: self.requestReload(saved: false)
            case .failure(let error):
                self.endOperation()
                self.show(L("shell.herdr.reload.notSent"), text: error.localizedDescription, failure: true)
            }
        }
    }

    private func requestReload(saved: Bool) {
        reload { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.endOperation()
                switch result {
                case .success(let diagnostics):
                    self.setStatus { L("shell.herdr.status.reloaded") }
                    if !saved || !diagnostics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.show(saved ? L("shell.herdr.reload.saved") : L("shell.herdr.reload.success"),
                                  text: diagnostics.isEmpty ? L("shell.herdr.reload.applied") : diagnostics)
                    }
                case .failure(let error):
                    self.setStatus { saved ? L("shell.herdr.status.savedReloadFailed") : L("shell.herdr.status.reloadFailed") }
                    let prefix = { saved ? L("shell.herdr.reload.savedWarning") : "" }
                    self.show(saved ? L("shell.herdr.reload.savedFailed") : L("shell.herdr.reload.failed"),
                              text: prefix() + error.localizedDescription, failure: true)
                }
            }
        }
    }

    private func show(_ title: @autoclosure @escaping () -> String,
                      text: @autoclosure @escaping () -> String, failure: Bool = false, scroll: Bool = false) {
        let dialog = TavernDialog()
        dialog.messageText = title()
        dialog.alertStyle = failure ? .warning : .informational
        let longContent = scroll || text().count > 600
        var textContent: NSTextView?
        if longContent {
            dialog.informativeText = failure ? L("shell.herdr.details.error") : L("shell.herdr.details.copy")
            let view = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 360))
            view.hasVerticalScroller = true
            view.hasHorizontalScroller = true
            let content = NSTextView(frame: view.bounds)
            content.isEditable = false
            content.isSelectable = true
            content.isRichText = false
            content.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            content.isVerticallyResizable = true
            content.autoresizingMask = [.width]
            content.textContainer?.widthTracksTextView = true
            content.string = text()
            textContent = content
            view.documentView = content
            dialog.accessoryView = view
        } else {
            dialog.informativeText = text()
        }
        dialog.addButton(withTitle: L("shell.close"))
        dialog.localizationUpdater = { dialog in
            dialog.messageText = title()
            dialog.buttons[0].title = L("shell.close")
            if longContent {
                dialog.informativeText = failure ? L("shell.herdr.details.error") : L("shell.herdr.details.copy")
                let selection = textContent?.selectedRanges
                textContent?.string = text()
                if let selection { textContent?.selectedRanges = selection }
            } else {
                dialog.informativeText = text()
            }
        }
        if let parent = NSApp.mainWindow ?? NSApp.keyWindow {
            dialog.beginSheetModal(for: parent)
        } else {
            dialog.runModal()
        }
    }
}
