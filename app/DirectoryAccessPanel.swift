import AppKit

final class TavernDirectoryAccessController {
    private var presenting = false
    private var scopes: [URL] = []
    private var sheetObserver: NSObjectProtocol?

    deinit {
        if let sheetObserver { NotificationCenter.default.removeObserver(sheetObserver) }
        for url in scopes { url.stopAccessingSecurityScopedResource() }
    }

    func present(directory: URL, for window: NSWindow, isCurrent: @escaping () -> Bool,
                 report: @escaping (String) -> Void) {
        guard !presenting, sheetObserver == nil, isCurrent() else { return }
        if window.attachedSheet != nil {
            // First-run agent setup can already own the sheet slot when startup fails.
            sheetObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didEndSheetNotification, object: window, queue: .main
            ) { [weak self, weak window] _ in
                guard let self else { return }
                if let observer = self.sheetObserver { NotificationCenter.default.removeObserver(observer) }
                self.sheetObserver = nil
                DispatchQueue.main.async { [weak self, weak window] in
                    guard let window else { return }
                    self?.present(directory: directory, for: window, isCurrent: isCurrent, report: report)
                }
            }
            return
        }
        presenting = true
        let alert = TavernDialog()
        alert.messageText = L("shell.directoryAccess.title")
        alert.informativeText = L("shell.directoryAccess.message", directory.path)
        alert.addButton(withTitle: L("shell.directoryAccess.choose"))
        alert.addButton(withTitle: L("shell.directoryAccess.settings"))
        alert.addButton(withTitle: L("shell.cancel"))
        alert.localizationUpdater = { dialog in
            dialog.messageText = L("shell.directoryAccess.title")
            dialog.informativeText = L("shell.directoryAccess.message", directory.path)
            dialog.buttons[0].title = L("shell.directoryAccess.choose")
            dialog.buttons[1].title = L("shell.directoryAccess.settings")
            dialog.buttons[2].title = L("shell.cancel")
        }
        alert.beginSheetModal(for: window) { [weak self, weak window] response in
            guard let self else { return }
            self.presenting = false
            guard isCurrent(), let window else { return }
            if response == .alertSecondButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!)
                report(L("shell.directoryAccess.settingsHelp"))
                return
            }
            guard response == .alertFirstButtonReturn else { return }
            self.choose(directory: directory, window: window, isCurrent: isCurrent, report: report)
        }
    }

    private func choose(directory: URL, window: NSWindow, isCurrent: @escaping () -> Bool,
                        report: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        TavernMotion.configureWindow(panel)
        panel.title = L("shell.directoryAccess.title")
        panel.message = L("shell.directoryAccess.select", directory.path)
        panel.prompt = L("shell.directoryAccess.allow")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = directory.deletingLastPathComponent()
        panel.nameFieldStringValue = directory.lastPathComponent
        presenting = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.presenting = false
            guard isCurrent(), response == .OK, let selected = panel.url else { return }
            // Do not authorize a different location and replay a command in the wrong folder.
            guard selected.standardizedFileURL == directory.standardizedFileURL else {
                report(L("shell.directoryAccess.wrongFolder")); return
            }
            let scoped = selected.startAccessingSecurityScopedResource()
            do {
                try TavernDirectoryAccess.check(selected)
                if scoped { self.scopes.append(selected) }
                report(L("shell.directoryAccess.retry"))
            } catch {
                if scoped { selected.stopAccessingSecurityScopedResource() }
                report(L("shell.directoryAccess.stillDenied"))
            }
        }
    }
}
