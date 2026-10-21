import AppKit
import UserNotifications

final class TavernNotifications: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var lastDelivery: (title: String, body: String, time: TimeInterval)?
    var onOpen: (([String: String]) -> Void)?
    var onError: ((String) -> Void)?

    func prepare() {
        center.delegate = self
        center.requestAuthorization(options: [.alert]) { [weak self] _, error in
            if let error { self?.report(error) }
        }
    }

    func show(title: String, body: String, context: [String: String]) {
        precondition(Thread.isMainThread)
        guard !NSApp.isActive, !title.isEmpty else { return }
        // herdr может доставить одно событие и семантически, и как SystemToast.
        let now = ProcessInfo.processInfo.systemUptime
        if let previous = lastDelivery, previous.title == title, previous.body == body,
           now - previous.time < 2 { return }
        lastDelivery = (title, body, now)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = context
        // Звуки принадлежат Tavern: системный сигнал не дублирует WAV.
        content.sound = nil
        center.getNotificationSettings { [weak self] settings in
            guard let self, settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            DispatchQueue.main.async {
                guard !NSApp.isActive else { return }
                let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                self.center.add(request) { [weak self] error in
                    if let error { self?.report(error) }
                }
            }
        }
    }

    private func report(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.onError?(L("core.notifications.failed", error.localizedDescription))
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        DispatchQueue.main.async {
            completionHandler(NSApp.isActive ? [] : [.banner, .list])
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { completionHandler(); return }
        let context = response.notification.request.content.userInfo as? [String: String] ?? [:]
        DispatchQueue.main.async { [weak self] in
            self?.onOpen?(context)
            completionHandler()
        }
    }
}
