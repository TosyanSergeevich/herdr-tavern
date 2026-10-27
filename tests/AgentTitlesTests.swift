import Foundation

@main
struct AgentTitlesTests {
    static func main() {
        ompSessionTitleKeepsIconWithoutStateChrome()
        ompPlainTitlesKeepTheirMeaning()
        manualTabAndPaneNamesAreIndependent()
        suppliedTitlesAndTerminalFallbacks()
        leadingAgentDoesNotFollowFocusOrOrder()
        updatesAndAgentExitUseCurrentMetadata()
        liveTitlesSurviveStaleSnapshots()
        liveTitlesRespectManualLabelsAndPaneIdentity()
        liveTitleClearsAndClosedPanes()
        liveRevisionOrderingAndNormalizedDuplicates()
        liveUpdatesBeforeSnapshotAndReconnect()
        retainedUpdatesAreBounded()
        print("AgentTitlesTests passed")
    }

    private static func agent(_ pane: String = "p1", tab: String = "t1", kind: String = "omp", title: String = "") -> [String: Any] {
        ["pane_id": pane, "tab_id": tab, "agent": kind, "terminal_title_stripped": title]
    }

    private static func resolver(_ agents: [[String: Any]]) -> AgentTitles {
        AgentTitles(snapshot: ["agents": agents])
    }

    private static let tab: [String: Any] = ["tab_id": "t1", "label": "1", "custom_label": false]

    private static func ompSessionTitleKeepsIconWithoutStateChrome() {
        let idle = agent(title: "π > 🧪 FLAKY: Починить тесты")
        precondition(resolver([idle]).tabTitle(tab) == "🧪 Починить тесты", "OMP own title and emoji override numeric tabs")
        let working = agent(title: "π ⠋ 🧪 FLAKY: Починить тесты")
        precondition(resolver([working]).tabTitle(tab) == resolver([idle]).tabTitle(tab), "Spinner changes must not rename tabs")
        let attention = agent(title: "π ! \u{F0C3} Z3: Проверить сборку")
        precondition(resolver([attention]).tabTitle(tab) == "\u{F0C3} Проверить сборку", "Nerd Fonts icons survive normalization")
        let disabled = agent(title: "π: 🧪 FLAKY: Починить тесты")
        precondition(resolver([disabled]).tabTitle(tab) == "🧪 Починить тесты", "State-disabled OMP uses the same session title")
    }

    private static func ompPlainTitlesKeepTheirMeaning() {
        let plain = agent(title: "π > FIX: обычный заголовок")
        precondition(resolver([plain]).tabTitle(tab) == "FIX: обычный заголовок", "A plain prefix is not a card code")
        let custom = agent(title: "π science")
        precondition(resolver([custom]).tabTitle(tab) == "π science", "Unknown extension-owned title chrome stays intact")
        let other = agent(kind: "codex", title: "🧪 FLAKY: собственный формат")
        precondition(resolver([other]).tabTitle(tab) == "🧪 FLAKY: собственный формат", "OMP card rewriting must not affect other agents")
    }

    private static func manualTabAndPaneNamesAreIndependent() {
        let value = agent(title: "π > 🧭 PLAN: План миграции")
        let titles = resolver([value])
        let customTab: [String: Any] = ["tab_id": "t1", "label": "Релиз", "custom_label": true]
        precondition(titles.tabTitle(customTab) == "Релиз", "Custom tab label wins over automatic title")
        precondition(titles.cardTitle(agent: value, pane: ["label": "Мой агент"], fallback: "Агент") == "Мой агент", "Pane label wins only its card")
        precondition(titles.cardTitle(agent: value, pane: nil, fallback: "Агент") == "🧭 План миграции", "A group label must not replace individual session names")
        precondition(titles.tabTitle(tab) == "🧭 План миграции", "Pane labels cannot rename their containing tab")
    }

    private static func suppliedTitlesAndTerminalFallbacks() {
        var value = agent(kind: "codex", title: "Исправить оплату")
        value["title"] = "План релиза"
        precondition(resolver([value]).tabTitle(tab) == "План релиза", "Supplied task titles beat terminal fallback")
        value.removeValue(forKey: "title")
        precondition(resolver([value]).tabTitle(tab) == "Исправить оплату", "Other agents can supply terminal titles")
        value["terminal_title_stripped"] = "codex"
        value["terminal_title"] = "Проверить контракт"
        precondition(resolver([value]).tabTitle(tab) == "Проверить контракт", "Generic program names cannot shadow useful fallback titles")
        value["terminal_title"] = "node"
        precondition(resolver([value]).cardTitle(agent: value, pane: nil, fallback: "Codex") == "Codex", "Cards never borrow numeric tab labels")
    }

    private static func leadingAgentDoesNotFollowFocusOrOrder() {
        var first = agent("p1", title: "π > Первый")
        var second = agent("p2", title: "π > Второй")
        first["focused"] = true
        second["focused"] = false
        let before = resolver([first, second]).tabTitle(tab)
        first["focused"] = false
        second["focused"] = true
        precondition(resolver([second, first]).tabTitle(tab) == before, "Focus or sidebar ordering cannot change a split-tab title")
        precondition(resolver([second]).tabTitle(tab) == "Второй", "Removing the leader selects the remaining agent")
    }

    private static func updatesAndAgentExitUseCurrentMetadata() {
        let old = agent(title: "π > Старое имя")
        let renamed = agent(title: "π > Новое имя")
        precondition(resolver([old]).tabTitle(tab) == "Старое имя")
        precondition(resolver([renamed]).tabTitle(tab) == "Новое имя", "Session rename is reflected without terminal input or model requests")
        let moved = agent(tab: "t2", title: "π > Новое имя")
        precondition(resolver([moved]).tabTitle(tab) == "1", "Moved agents cannot leave stale titles on the old tab")
        precondition(resolver([]).tabTitle(tab) == "1", "Agent exit releases its automatic tab title")
    }

    private static func livePane(_ id: String = "p1", terminal: String = "term1", revision: UInt64 = 3,
                                 title: String = "π > Новое имя") -> [String: Any] {
        ["pane_id": id, "terminal_id": terminal, "revision": revision, "agent": "omp",
         "terminal_title": title, "terminal_title_stripped": title, "tab_id": "t1"]
    }

    private static func updated(_ pane: [String: Any]) -> [String: Any] {
        ["event": "pane_updated", "data": ["type": "pane_updated", "pane": pane]]
    }

    private static func liveTitlesSurviveStaleSnapshots() {
        var updates = AgentTitleUpdates()
        precondition(updates.consume(event: updated(livePane())))
        let stale = livePane(revision: 1, title: "π > Старое имя")
        let snapshot: [String: Any] = ["agents": [stale]]
        let titles = AgentTitles(snapshot: snapshot, updates: updates)
        precondition(titles.tabTitle(tab) == "Новое имя", "A stale endpoint cannot undo a public title update")
        precondition(titles.cardTitle(agent: stale, pane: nil, fallback: "OMP") == "Новое имя")
        precondition((snapshot["agents"] as? [[String: Any]])?.first?["terminal_title"] as? String == "π > Старое имя",
                     "Projection must not mutate core metadata")
        let newer = livePane(revision: 4, title: "π > Ещё новее")
        precondition(AgentTitles(snapshot: ["agents": [newer]], updates: updates).tabTitle(tab) == "Ещё новее")
    }

    private static func liveTitlesRespectManualLabelsAndPaneIdentity() {
        var updates = AgentTitleUpdates()
        var pane = livePane()
        pane["label"] = "Не копировать"
        pane["tab_id"] = "wrong-tab"
        precondition(updates.consume(event: updated(pane)))
        let first = livePane(revision: 1, title: "π > Старое имя")
        let second = livePane("p2", terminal: "term2", revision: 1, title: "π > Второй")
        let titles = AgentTitles(snapshot: ["agents": [first, second]], updates: updates)
        precondition(titles.tabTitle(tab) == "Новое имя", "Live metadata never moves a pane between tabs")
        precondition(titles.tabTitle(["tab_id": "t1", "label": "Моя группа", "custom_label": true]) == "Моя группа")
        precondition(titles.cardTitle(agent: first, pane: ["label": "Мой агент"], fallback: "OMP") == "Мой агент")
        precondition(titles.cardTitle(agent: second, pane: nil, fallback: "OMP") == "Второй", "Updates are isolated by pane ID")
        let replaced = livePane(terminal: "replacement", revision: 1, title: "π > Новый терминал")
        precondition(AgentTitles(snapshot: ["agents": [replaced]], updates: updates).tabTitle(tab) == "Новый терминал",
                     "A recycled pane cannot inherit another terminal's title")
    }

    private static func liveTitleClearsAndClosedPanes() {
        var updates = AgentTitleUpdates()
        let stale = livePane(revision: 1)
        precondition(updates.consume(event: updated(livePane())))
        var cleared = livePane(revision: 4)
        cleared.removeValue(forKey: "terminal_title")
        cleared["terminal_title_stripped"] = NSNull()
        precondition(updates.consume(event: updated(cleared)))
        let titles = AgentTitles(snapshot: ["agents": [stale]], updates: updates)
        precondition(titles.tabTitle(tab) == "1", "Omitted and null fields clear stale titles")
        precondition(titles.cardTitle(agent: stale, pane: nil, fallback: "OMP") == "OMP")
        precondition(updates.consume(event: ["event": "pane_closed", "data": ["pane_id": "p1"]]))
        precondition(!updates.consume(event: ["event": "pane_closed", "data": ["pane_id": "p1"]]))
        precondition(!updates.consume(event: updated(livePane(revision: 5))))
        precondition(AgentTitles(snapshot: ["agents": [stale]], updates: updates).tabTitle(tab) == "1",
                     "Closed panes cannot leave automatic titles in a stale snapshot")
    }

    private static func liveRevisionOrderingAndNormalizedDuplicates() {
        var updates = AgentTitleUpdates()
        precondition(updates.consume(event: updated(livePane())))
        precondition(!updates.consume(event: updated(livePane())), "Duplicate public events do not rebuild navigation")
        precondition(!updates.consume(event: updated(livePane(revision: 2, title: "π > Устарело"))))
        precondition(!updates.consume(event: updated(livePane(revision: 4, title: "π ⠋ Новое имя"))),
                     "OMP state chrome does not change the normalized title")
        precondition(!updates.consume(event: updated(livePane(revision: 3, title: "π > Устарело"))),
                     "Even an invisible title update advances its revision")
        var metadata = livePane(revision: 4, title: "π > Название из metadata")
        metadata["title"] = "Другой заголовок"
        precondition(updates.consume(event: updated(metadata)), "Ordered metadata changes at equal revision must be accepted")
        precondition(!updates.consume(event: ["event": "pane_updated", "data": ["pane": ["pane_id": "p1"]]]))
    }

    private static func liveUpdatesBeforeSnapshotAndReconnect() {
        var updates = AgentTitleUpdates()
        precondition(updates.consume(event: updated(livePane())))
        precondition(AgentTitles(snapshot: ["agents": []], updates: updates).tabTitle(tab) == "1")
        let stale = livePane(revision: 1, title: "π > Старое имя")
        precondition(AgentTitles(snapshot: ["agents": [stale]], updates: updates).tabTitle(tab) == "Новое имя",
                     "Events preceding the initial endpoint snapshot are retained")
        updates = AgentTitleUpdates()
        precondition(AgentTitles(snapshot: ["agents": [stale]], updates: updates).tabTitle(tab) == "Старое имя",
                     "Reconnect clears the projection by replacing its value")
    }

    private static func retainedUpdatesAreBounded() {
        var updates = AgentTitleUpdates()
        for index in 0...4096 {
            _ = updates.consume(event: updated(livePane("pane-\(index)", terminal: "terminal-\(index)")))
        }
        let first = livePane("pane-0", terminal: "terminal-0", revision: 1, title: "π > Старое имя")
        precondition(AgentTitles(snapshot: ["agents": [first]], updates: updates).tabTitle(tab) == "Старое имя",
                     "Old entries are evicted instead of retaining every pane ever seen")
        let last = livePane("pane-4096", terminal: "terminal-4096", revision: 1, title: "π > Старое имя")
        precondition(AgentTitles(snapshot: ["agents": [last]], updates: updates).tabTitle(tab) == "Новое имя")
    }
}
