import AppKit

final class TavernDirectoryAccessController {
    typealias Verify = () -> TavernDirectoryAccess.ServerCheck
    private(set) var busy = false
    private var scopes: [URL] = []
    private var sheetObserver: NSObjectProtocol?

    deinit {
        if let sheetObserver { NotificationCenter.default.removeObserver(sheetObserver) }
        for url in scopes { url.stopAccessingSecurityScopedResource() }
    }

    /// The first real app-side enumeration can trigger macOS's native TCC prompt.
    /// A picker grant alone never proves that an already-running server can read.
    @discardableResult
    func request(directory: URL, for window: NSWindow, explicit: Bool,
                 isCurrent: @escaping () -> Bool, verify: Verify?,
                 report: @escaping (String) -> Void, finished: @escaping () -> Void) -> Bool {
        guard !busy, isCurrent() else { return false }
        busy = true
        check(directory: directory, window: window, explicit: explicit, isCurrent: isCurrent,
              verify: verify, report: report, finished: finished)
        return true
    }

    private func check(directory: URL, window: NSWindow, explicit: Bool,
                       isCurrent: @escaping () -> Bool, verify: Verify?,
                       report: @escaping (String) -> Void, finished: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak window] in
            let local = Result {
                let authorization = TavernDirectoryAccess.authorizationDirectory(for: directory)
                try TavernDirectoryAccess.check(authorization)
                if authorization.standardizedFileURL != directory.standardizedFileURL {
                    try TavernDirectoryAccess.check(directory)
                }
            }
            let server = verify?() ?? .unsupported
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self else { return }
                guard isCurrent(), let window else { self.complete(finished); return }
                if case .success = local, case .available = server {
                    if explicit { report(L("shell.directoryAccess.verified")) }
                    self.complete(finished)
                    return
                }
                let detail: () -> String
                switch server {
                case .unsupported:
                    detail = { L("shell.directoryAccess.unsupported") }
                case .failed(let message):
                    detail = { L("shell.directoryAccess.checkFailed", message) }
                case .invalidResponse:
                    detail = { L("shell.error.responseMismatch") }
                case .denied:
                    detail = { L("shell.directoryAccess.serverDenied") }
                case .available:
                    detail = { L("shell.directoryAccess.stillDenied") }
                }
                if case .success = local {
                    if case .unsupported = server, !explicit {
                        // An old server's missing API is not evidence of a permission denial.
                        self.complete(finished)
                        return
                    }
                    switch server {
                    case .failed, .invalidResponse:
                        report(detail())
                        self.complete(finished)
                        return
                    default: break
                    }
                }
                if case .failure(let error) = local {
                    let code = (error as? POSIXError)?.code
                    if code != .EPERM && code != .EACCES {
                        report(L("shell.directoryAccess.checkFailed", error.localizedDescription))
                        self.complete(finished)
                        return
                    }
                }
                self.present(directory: directory, for: window, detail: detail, isCurrent: isCurrent,
                             verify: verify, report: report, finished: finished)
            }
        }
    }

    private func complete(_ finished: () -> Void) {
        busy = false
        finished()
    }

    private func present(directory: URL, for window: NSWindow, detail: @escaping () -> String,
                         isCurrent: @escaping () -> Bool, verify: Verify?,
                         report: @escaping (String) -> Void, finished: @escaping () -> Void) {
        guard isCurrent() else { complete(finished); return }
        if window.attachedSheet != nil {
            sheetObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didEndSheetNotification, object: window, queue: .main
            ) { [weak self, weak window] _ in
                guard let self else { return }
                if let observer = self.sheetObserver { NotificationCenter.default.removeObserver(observer) }
                self.sheetObserver = nil
                DispatchQueue.main.async { [weak self, weak window] in
                    guard let self else { return }
                    guard let window, isCurrent() else { self.complete(finished); return }
                    self.present(directory: directory, for: window, detail: detail, isCurrent: isCurrent,
                                 verify: verify, report: report, finished: finished)
                }
            }
            return
        }
        let alert = TavernDialog()
        let authorization = TavernDirectoryAccess.authorizationDirectory(for: directory)
        let authorizationHelp: () -> String = {
            authorization == directory.standardizedFileURL ? "" : "\n\n" + L("shell.directoryAccess.authorizationFolder", authorization.path)
        }
        alert.messageText = L("shell.directoryAccess.title")
        alert.informativeText = L("shell.directoryAccess.message", directory.path) + authorizationHelp() + "\n\n" + detail()
        alert.addButton(withTitle: L("shell.directoryAccess.choose"))
        alert.addButton(withTitle: L("shell.directoryAccess.settings"))
        alert.addButton(withTitle: L("shell.cancel"))
        alert.localizationUpdater = { dialog in
            dialog.messageText = L("shell.directoryAccess.title")
            dialog.informativeText = L("shell.directoryAccess.message", directory.path) + authorizationHelp() + "\n\n" + detail()
            dialog.buttons[0].title = L("shell.directoryAccess.choose")
            dialog.buttons[1].title = L("shell.directoryAccess.settings")
            dialog.buttons[2].title = L("shell.cancel")
        }
        alert.beginSheetModal(for: window) { [weak self, weak window] response in
            guard let self else { return }
            guard isCurrent(), let window else { self.complete(finished); return }
            if response == .alertSecondButtonReturn {
                let opened = NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!)
                report(L(opened ? "shell.directoryAccess.settingsHelp" : "shell.directoryAccess.settingsUnavailable"))
                self.complete(finished)
                return
            }
            guard response == .alertFirstButtonReturn else { self.complete(finished); return }
            self.choose(directory: directory, window: window, isCurrent: isCurrent,
                        verify: verify, report: report, finished: finished)
        }
    }

    private func choose(directory: URL, window: NSWindow, isCurrent: @escaping () -> Bool,
                        verify: Verify?, report: @escaping (String) -> Void, finished: @escaping () -> Void) {
        let authorization = TavernDirectoryAccess.authorizationDirectory(for: directory)
        let panel = NSOpenPanel()
        TavernMotion.configureWindow(panel)
        panel.title = L("shell.directoryAccess.title")
        panel.message = L("shell.directoryAccess.select", authorization.path)
        panel.prompt = L("shell.directoryAccess.allow")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = authorization.deletingLastPathComponent()
        panel.nameFieldStringValue = authorization.lastPathComponent
        panel.beginSheetModal(for: window) { [weak self, weak window] response in
            guard let self else { return }
            guard isCurrent(), let window, response == .OK, let selected = panel.url else {
                self.complete(finished); return
            }
            guard selected.standardizedFileURL == authorization else {
                report(L("shell.directoryAccess.wrongFolder")); self.complete(finished); return
            }
            if selected.startAccessingSecurityScopedResource() {
                if self.scopes.contains(selected) { selected.stopAccessingSecurityScopedResource() }
                else { self.scopes.append(selected) }
            }
            // Both checks run off the main thread, including the post-picker server check.
            self.check(directory: directory, window: window, explicit: true, isCurrent: isCurrent,
                       verify: verify, report: report, finished: finished)
        }
    }
}
