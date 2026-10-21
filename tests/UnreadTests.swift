import Foundation

@main struct UnreadTests {
    static func main() {
        baselineDoesNotReplayHistory()
        completionIsReadOnlyInItsPane()
        attentionSurvivesWorkingAndIsReplacedByReply()
        semanticEventsDoNotDependOnSound()
        reconnectAndServerRestart()
        closedAgentsArePruned()
        notificationBeforeSnapshot()
        newAgentCanNeedAttention()
        print("Пройдено 8 проверок состояния непрочитанного")
    }

    static func baselineDoesNotReplayHistory() {
        var tracker = AgentUnreadTracker()
        tracker.synchronize(bootID: "boot", statuses: ["a": "done", "b": "blocked"], viewedPane: nil)
        precondition(tracker.marks.isEmpty, "Исходный снимок не должен воспроизводить старые события")
    }
    static func newAgentCanNeedAttention() {
        var tracker = AgentUnreadTracker()
        tracker.synchronize(bootID: "boot", statuses: [:], viewedPane: nil)
        tracker.synchronize(bootID: "boot", statuses: ["a": "blocked"], viewedPane: nil)
        precondition(tracker.marks["a"] == .attention, "Новый агент после исходного снимка может сразу запросить ввод")
    }


    static func completionIsReadOnlyInItsPane() {
        var tracker = AgentUnreadTracker()
        tracker.synchronize(bootID: "boot", statuses: ["a": "working", "b": "idle"], viewedPane: "b")
        tracker.synchronize(bootID: "boot", statuses: ["a": "idle", "b": "idle"], viewedPane: "b")
        precondition(tracker.marks["a"] == .reply)
        tracker.markViewed("b")
        precondition(tracker.marks["a"] == .reply, "Фокус в другой панели не означает прочтение")
        tracker.markViewed("a")
        tracker.synchronize(bootID: "boot", statuses: ["a": "idle", "b": "idle"], viewedPane: "a")
        tracker.record(.reply, paneID: "a", bootID: "boot", viewedPane: "a")
        precondition(tracker.marks["a"] == nil, "Повтор события для просматриваемой панели не создаёт непрочитанное")
        tracker.synchronize(bootID: "boot", statuses: ["a": "working", "b": "idle"], viewedPane: "a")
        tracker.synchronize(bootID: "boot", statuses: ["a": "done", "b": "idle"], viewedPane: "a")
        precondition(tracker.marks["a"] == nil, "Завершение в просматриваемой панели уже прочитано")
    }

    static func attentionSurvivesWorkingAndIsReplacedByReply() {
        var tracker = AgentUnreadTracker()
        tracker.synchronize(bootID: "boot", statuses: ["a": "working"], viewedPane: nil)
        tracker.synchronize(bootID: "boot", statuses: ["a": "blocked"], viewedPane: nil)
        precondition(tracker.marks["a"] == .attention)
        tracker.synchronize(bootID: "boot", statuses: ["a": "working"], viewedPane: nil)
        precondition(tracker.marks["a"] == .attention, "Статус не должен сам снимать непрочитанное")
        tracker.synchronize(bootID: "boot", statuses: ["a": "done"], viewedPane: nil)
        precondition(tracker.marks["a"] == .reply, "Новое завершение заменяет прежний запрос внимания")
    }

    static func semanticEventsDoNotDependOnSound() {
        precondition(AgentUnreadKind(notification: ["kind": "Finished"]) == .reply)
        precondition(AgentUnreadKind(notification: ["kind": "NeedsAttention", "sound": "Done"]) == .attention)
        precondition(AgentUnreadKind(notification: ["kind": "Custom", "sound": "Request"]) == .attention)
        precondition(AgentUnreadKind(notification: ["kind": "UpdateInstalled", "sound": "Done"]) == nil)
        var tracker = AgentUnreadTracker()
        tracker.record(.attention, paneID: "a", bootID: "boot", viewedPane: nil)
        tracker.record(.attention, paneID: "a", bootID: "boot", viewedPane: nil)
        precondition(tracker.marks["a"] == .attention)
    }

    static func reconnectAndServerRestart() {
        var tracker = AgentUnreadTracker()
        tracker.synchronize(bootID: "boot-1", statuses: ["a": "working"], viewedPane: nil)
        tracker.synchronize(bootID: "boot-1", statuses: ["a": "done"], viewedPane: nil)
        tracker.synchronize(bootID: "boot-1", statuses: ["a": "done"], viewedPane: nil)
        precondition(tracker.marks["a"] == .reply, "Повторное подключение к тому же серверу сохраняет отметку")
        tracker.synchronize(bootID: "boot-2", statuses: ["a": "idle"], viewedPane: nil)
        precondition(tracker.marks["a"] == nil, "Повторное использование pane_id после рестарта не наследует отметку")
    }

    static func closedAgentsArePruned() {
        var tracker = AgentUnreadTracker()
        tracker.synchronize(bootID: "boot", statuses: ["a": "working", "b": "working"], viewedPane: nil)
        tracker.record(.reply, paneID: "a", bootID: "boot", viewedPane: nil)
        tracker.record(.attention, paneID: "b", bootID: "boot", viewedPane: nil)
        tracker.synchronize(bootID: "boot", statuses: ["b": "working"], viewedPane: nil)
        precondition(tracker.marks["a"] == nil && tracker.marks["b"] == .attention)
    }

    static func notificationBeforeSnapshot() {
        var tracker = AgentUnreadTracker()
        tracker.record(.reply, paneID: "a", bootID: "boot", viewedPane: nil)
        tracker.synchronize(bootID: "boot", statuses: ["a": "done"], viewedPane: nil)
        precondition(tracker.marks["a"] == .reply, "Первый снимок не должен потерять уже полученное событие")
        tracker.synchronize(bootID: "boot", statuses: ["a": "done"], viewedPane: "a")
        precondition(tracker.marks["a"] == nil)
    }
}
