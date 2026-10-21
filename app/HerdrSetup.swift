import AppKit

final class HerdrSetupController {
    private let installer: HerdrInstaller
    private var dialog: TavernDialog?
    private var installationTask: Task<Void, Never>?
    private var completion: ((Bool) -> Void)?

    init(installer: HerdrInstaller = HerdrInstaller()) {
        self.installer = installer
    }

    deinit { installationTask?.cancel() }

    func present(completion: @escaping (Bool) -> Void) {
        precondition(Thread.isMainThread)
        guard self.completion == nil else { return }
        self.completion = completion
        let offer = TavernDialog()
        offer.messageText = L("installer.offer.title")
        offer.informativeText = L("installer.offer.message", installer.release.version, installer.destination.path)
        offer.addButton(withTitle: L("installer.offer.install"))
            .setAccessibilityIdentifier("herdr.install.accept")
        offer.addButton(withTitle: L("core.dialog.cancel"))
            .setAccessibilityIdentifier("herdr.install.cancel")
        offer.localizationUpdater = { [weak self] dialog in
            guard let self else { return }
            dialog.messageText = L("installer.offer.title")
            dialog.informativeText = L("installer.offer.message", self.installer.release.version,
                                       self.installer.destination.path)
            dialog.buttons[0].title = L("installer.offer.install")
            dialog.buttons[0].setAccessibilityLabel(dialog.buttons[0].title)
            dialog.buttons[1].title = L("core.dialog.cancel")
            dialog.buttons[1].setAccessibilityLabel(dialog.buttons[1].title)
        }
        dialog = offer
        offer.show { [weak self] response in
            guard let self else { return }
            self.dialog = nil
            if response == .alertFirstButtonReturn { self.beginInstallation() }
            else { self.finish(installed: false) }
        }
    }

    func cancel() {
        installationTask?.cancel()
        installationTask = nil
    }

    private func beginInstallation() {
        let progress = TavernDialog()
        progress.messageText = L("installer.progress.title")
        progress.informativeText = L("installer.progress.message", installer.release.version)
        progress.addButton(withTitle: L("core.dialog.cancel"))
            .setAccessibilityIdentifier("herdr.install.cancel")
        let spinner = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        spinner.style = .spinning
        spinner.setAccessibilityIdentifier("herdr.install.progress")
        spinner.setAccessibilityLabel(L("installer.progress.title"))
        spinner.startAnimation(nil)
        progress.accessoryView = spinner
        progress.localizationUpdater = { [weak self, weak spinner] dialog in
            guard let self else { return }
            dialog.messageText = L("installer.progress.title")
            dialog.informativeText = L("installer.progress.message", self.installer.release.version)
            dialog.buttons[0].title = L("core.dialog.cancel")
            dialog.buttons[0].setAccessibilityLabel(dialog.buttons[0].title)
            spinner?.setAccessibilityLabel(L("installer.progress.title"))
        }
        dialog = progress
        progress.show { [weak self] response in
            guard response != .OK, let self else { return }
            self.cancel()
            self.dialog = nil
            self.finish(installed: false)
        }
        let installer = self.installer
        installationTask = Task { @MainActor [weak self] in
            let result: Result<URL, Error>
            do { result = .success(try await installer.install()) }
            catch { result = .failure(error) }
            guard !Task.isCancelled else { return }
            self?.installationFinished(result)
        }
    }

    private func installationFinished(_ result: Result<URL, Error>) {
        installationTask = nil
        let previous = dialog
        dialog = nil
        previous?.dismiss(with: .OK)
        switch result {
        case .success:
            finish(installed: true)
        case .failure(let error):
            let failure = TavernDialog()
            failure.alertStyle = .critical
            failure.messageText = L("installer.error.title")
            failure.informativeText = L("installer.error.message", error.localizedDescription)
            failure.addButton(withTitle: L("core.dialog.close"))
                .setAccessibilityIdentifier("herdr.install.close")
            failure.localizationUpdater = { dialog in
                dialog.messageText = L("installer.error.title")
                dialog.informativeText = L("installer.error.message", error.localizedDescription)
                dialog.buttons[0].title = L("core.dialog.close")
                dialog.buttons[0].setAccessibilityLabel(dialog.buttons[0].title)
            }
            dialog = failure
            failure.show { [weak self] _ in
                self?.dialog = nil
                self?.finish(installed: false)
            }
        }
    }

    private func finish(installed: Bool) {
        let callback = completion
        completion = nil
        callback?(installed)
    }
}
