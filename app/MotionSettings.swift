import AppKit

extension Notification.Name {
    static let tavernMotionDidChange = Notification.Name("tavernMotionDidChange")
}

final class TavernMotionSettings {
    static let shared = TavernMotionSettings()
    static let preferenceKey = "HerdrTavern.animations.enabled"
    private let defaults: UserDefaults
    private let reduceMotion: () -> Bool
    private let center: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private var workspaceObserver: NSObjectProtocol?
    private(set) var animationsEnabled: Bool
    private(set) var enabled: Bool

    init(defaults: UserDefaults = .standard, center: NotificationCenter = .default,
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.defaults = defaults
        self.center = center
        self.reduceMotion = reduceMotion
        animationsEnabled = defaults.object(forKey: Self.preferenceKey) as? Bool ?? true
        enabled = animationsEnabled && !reduceMotion()
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) {
            [weak self] _ in self?.refresh()
        })
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
    }

    deinit {
        observers.forEach { center.removeObserver($0) }
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
    }

    func setAnimationsEnabled(_ value: Bool) {
        defaults.set(value, forKey: Self.preferenceKey)
        refresh()
    }

    func refresh() {
        let preference = defaults.object(forKey: Self.preferenceKey) as? Bool ?? true
        let allowed = preference && !reduceMotion()
        guard preference != animationsEnabled || allowed != enabled else { return }
        animationsEnabled = preference
        enabled = allowed
        center.post(name: .tavernMotionDidChange, object: self)
    }
}
