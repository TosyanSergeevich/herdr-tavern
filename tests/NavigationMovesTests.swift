import Foundation

@main struct NavigationMovesTests {
    static let state: [String: Any] = [
        "focused_workspace_id": "w1", "workspaces": [["workspace_id": "w1"]],
        "tabs": [["tab_id": "a", "workspace_id": "w1"], ["tab_id": "b", "workspace_id": "w1"]],
        "panes": [["pane_id": "p1", "tab_id": "a"], ["pane_id": "p2", "tab_id": "a"], ["pane_id": "p3", "tab_id": "b"]]
    ]
    static func noRequest(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        preconditionFailure("Недопустимая или пустая операция не должна обращаться к серверу: \(method)")
    }
    static func main() throws {
        try agentGroupsUseTabBoundaries()
        try agentGroupsPreserveAgentlessTabs()
        for slot in [0, 1] {
            let outcome = try TavernNavigationMoves.execute(source: .tab("a"), target: .tabSlot(slot), snapshot: state, request: noRequest)
            precondition(!outcome.changed && outcome.tabID == nil && outcome.paneID == nil)
        }
        print("PASS: оба соседних зазора исходной вкладки не создают мутацию")
        for target: TavernDropTarget in [.pane("p1", .center), .tab("a")] {
            let outcome = try TavernNavigationMoves.execute(source: .pane("p1"), target: target, snapshot: state, request: noRequest)
            precondition(!outcome.changed && outcome.tabID == nil && outcome.paneID == nil)
        }
        print("PASS: перенос панели на себя и в свою вкладку не создаёт мутацию")
        try rejected(.tab("a"), .tabSlot(-1), expected: .invalidTarget)
        try rejected(.tab("a"), .tabSlot(3), expected: .invalidTarget)
        try rejected(.pane("p1"), .pane("p2", .right), expected: .unsupportedDrop)
        try rejected(.pane("p1"), .pane("p2", .bottom), expected: .unsupportedDrop)
        try rejected(.pane("p1"), .pane("p3", .center), expected: .unsupportedDrop)
        try rejected(.pane("gone"), .newTab("w1"), expected: .missingObject("gone"))
        try rejected(.pane("p1"), .tab("gone"), expected: .missingObject("gone"))
        try rejected(.tab("a"), .newTab("w1"), expected: .invalidTarget)
        print("PASS: неподдерживаемые края/обмен, недоступные объекты и индексы отклоняются до мутации")
        var zoomed = state
        zoomed["tabs"] = [["tab_id": "a", "workspace_id": "w1", "zoomed": true], ["tab_id": "b", "workspace_id": "w1"]]
        let outcome = try TavernNavigationMoves.execute(source: .pane("p1"), target: .newTab("w1"), snapshot: zoomed, request: noRequest)
        precondition(!outcome.changed)
        print("PASS: развёрнутая панель не уходит в неподдерживаемый перенос")
    }
    static func agentGroupsUseTabBoundaries() throws {
        let forward = try TavernNavigationMoves.agentTabSlot(sourcePaneID: "p1", targetPaneID: "p3", after: true, snapshot: state)
        let sibling = try TavernNavigationMoves.agentTabSlot(sourcePaneID: "p2", targetPaneID: "p3", after: true, snapshot: state)
        precondition(forward == 2 && sibling == forward, "Обе карточки одной вкладки должны переносить всю вкладку одинаково")
        let backward = try TavernNavigationMoves.agentTabSlot(sourcePaneID: "p3", targetPaneID: "p1", after: false, snapshot: state)
        precondition(backward == 0)
        for after in [false, true] {
            let sameGroup = try TavernNavigationMoves.agentTabSlot(sourcePaneID: "p1", targetPaneID: "p2", after: after, snapshot: state)
            precondition(sameGroup == nil, "Нельзя вставить вкладку внутрь её собственной группы")
        }
        let adjacent = try TavernNavigationMoves.agentTabSlot(sourcePaneID: "p1", targetPaneID: "p3", after: false, snapshot: state)
        precondition(adjacent == nil)
        let outcome = try TavernNavigationMoves.execute(source: .pane("p2"), target: .tabSlot(1), snapshot: state, request: noRequest)
        precondition(!outcome.changed)
        print("PASS: карточки перемещают целую вкладку; оба направления, своя группа и соседний зазор")
    }

    static func agentGroupsPreserveAgentlessTabs() throws {
        var withEmpty = state
        withEmpty["tabs"] = [["tab_id": "a", "workspace_id": "w1"], ["tab_id": "empty", "workspace_id": "w1"],
                             ["tab_id": "b", "workspace_id": "w1"], ["tab_id": "foreign", "workspace_id": "w2"]]
        let slot = try TavernNavigationMoves.agentTabSlot(sourcePaneID: "p1", targetPaneID: "p3", after: false, snapshot: withEmpty)
        precondition(slot == 2, "Индекс берётся из полной ленты, включая вкладки без агентов")
        withEmpty["panes"] = (state["panes"] as! [[String: Any]]) + [["pane_id": "remote", "tab_id": "foreign"]]
        do {
            _ = try TavernNavigationMoves.agentTabSlot(sourcePaneID: "p1", targetPaneID: "remote", after: false, snapshot: withEmpty)
            preconditionFailure("Перестановка между пространствами не поддерживается")
        } catch let error as TavernNavigationMoveError { precondition(error == .invalidTarget) }
        do {
            _ = try TavernNavigationMoves.agentTabSlot(sourcePaneID: "p1", targetPaneID: "gone", after: false, snapshot: state)
            preconditionFailure("Исчезнувшая карточка не может быть целью")
        } catch let error as TavernNavigationMoveError { precondition(error == .missingObject("gone")) }
        print("PASS: вкладки без агентов учитываются; чужое пространство и исчезнувшая цель отклоняются")
    }

    static func rejected(_ source: TavernDragSource, _ target: TavernDropTarget, expected: TavernNavigationMoveError) throws {
        do {
            _ = try TavernNavigationMoves.execute(source: source, target: target, snapshot: state, request: noRequest)
            preconditionFailure("Ожидалось отклонение недопустимого переноса")
        } catch let error as TavernNavigationMoveError { precondition(error == expected) }
    }
}
