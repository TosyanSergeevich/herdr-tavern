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
        workspaceAttentionPrioritizesAllAgents()
        workspaceBlockedUsesCurrentSnapshot()
        workspaceSelectionDoesNotReadOtherAgents()
        workspaceProjectionFollowsAgentMoveAndRemoval()
        workspaceProjectionDoesNotInheritPreviousBoot()
        workspaceProjectionIgnoresEmptyIdentities()
        print("Пройдено 14 проверок состояния непрочитанного")
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

    static func agent(_ paneID: String, _ workspaceID: String, _ status: String = "idle") -> [String: Any] {
        ["pane_id": paneID, "workspace_id": workspaceID, "agent_status": status]
    }

    static func workspaceAttentionPrioritizesAllAgents() {
        var tracker = AgentUnreadTracker()
        tracker.record(.reply, paneID: "a", bootID: "boot", viewedPane: nil)
        tracker.record(.attention, paneID: "b", bootID: "boot", viewedPane: nil)
        tracker.record(.reply, paneID: "c", bootID: "boot", viewedPane: nil)
        let agents = [agent("a", "one"), agent("b", "one"), agent("c", "two")]
        let marks = tracker.workspaceMarks(agents: agents, selectedWorkspaceID: "")
        precondition(marks == ["one": .attention, "two": .reply], "Запрос внимания важнее завершений других агентов")
        precondition(tracker.workspaceMarks(agents: Array(agents.reversed()), selectedWorkspaceID: "") == marks,
                     "Приоритет не зависит от порядка агентов")
    }

    static func workspaceBlockedUsesCurrentSnapshot() {
        var tracker = AgentUnreadTracker()
        tracker.synchronize(bootID: "boot", statuses: ["a": "blocked"], viewedPane: "a")
        precondition(tracker.marks.isEmpty)
        let blocked = [agent("a", "one", "blocked")]
        precondition(tracker.workspaceMarks(agents: blocked, selectedWorkspaceID: "two")["one"] == .attention,
                     "blocked требует ответа уже на первом снимке без unread")
        precondition(tracker.workspaceMarks(agents: blocked, selectedWorkspaceID: "one").isEmpty)
        tracker.markViewed("a")
        precondition(tracker.workspaceMarks(agents: blocked, selectedWorkspaceID: "two")["one"] == .attention,
                     "Уход после просмотра не отменяет текущий blocked")
        tracker.synchronize(bootID: "boot", statuses: ["a": "working"], viewedPane: nil)
        precondition(tracker.workspaceMarks(agents: [agent("a", "one", "working")], selectedWorkspaceID: "two").isEmpty,
                     "После снятия blocked без unread эффект исчезает")
    }

    static func workspaceSelectionDoesNotReadOtherAgents() {
        var tracker = AgentUnreadTracker()
        tracker.synchronize(bootID: "boot", statuses: ["a": "working", "b": "working"], viewedPane: nil)
        tracker.synchronize(bootID: "boot", statuses: ["a": "done", "b": "done"], viewedPane: "a")
        let agents = [agent("a", "one", "done"), agent("b", "one", "done")]
        precondition(tracker.marks == ["b": .reply], "Просмотр одной панели не читает остальных")
        precondition(tracker.workspaceMarks(agents: agents, selectedWorkspaceID: "one").isEmpty,
                     "Выбранное пространство не имеет ореола")
        precondition(tracker.marks == ["b": .reply], "Выбор пространства не очищает unread")
        precondition(tracker.workspaceMarks(agents: agents, selectedWorkspaceID: "two")["one"] == .reply)
        tracker.markViewed("b")
        precondition(tracker.workspaceMarks(agents: agents, selectedWorkspaceID: "two").isEmpty)
    }

    static func workspaceProjectionFollowsAgentMoveAndRemoval() {
        var tracker = AgentUnreadTracker()
        tracker.record(.reply, paneID: "a", bootID: "boot", viewedPane: nil)
        precondition(tracker.workspaceMarks(agents: [agent("a", "old")], selectedWorkspaceID: "") == ["old": .reply])
        precondition(tracker.workspaceMarks(agents: [agent("a", "new")], selectedWorkspaceID: "") == ["new": .reply],
                     "Отметка следует реальному workspace_id, не старой карточке")
        precondition(tracker.workspaceMarks(agents: [], selectedWorkspaceID: "").isEmpty,
                     "Исчезнувший агент не создаёт эффекта даже до pruning отметки")
    }

    static func workspaceProjectionDoesNotInheritPreviousBoot() {
        var tracker = AgentUnreadTracker()
        tracker.record(.attention, paneID: "a", bootID: "old", viewedPane: nil)
        tracker.synchronize(bootID: "new", statuses: ["a": "done", "b": "blocked"], viewedPane: nil)
        let agents = [agent("a", "one", "done"), agent("b", "two", "blocked")]
        precondition(tracker.workspaceMarks(agents: agents, selectedWorkspaceID: "") == ["two": .attention],
                     "Новый boot не наследует завершение, но показывает текущий blocked")
    }

    static func workspaceProjectionIgnoresEmptyIdentities() {
        let tracker = AgentUnreadTracker()
        let agents = [agent("", "one", "blocked"), agent("a", "", "blocked"),
                      ["workspace_id": "two", "agent_status": "blocked"],
                      ["pane_id": "b", "agent_status": "blocked"]]
        precondition(tracker.workspaceMarks(agents: agents, selectedWorkspaceID: "").isEmpty)
    }
}
