import Foundation

enum TavernDragSource: Equatable {
    case tab(String)
    case pane(String)
}

enum TavernDropEdge: Equatable {
    case center, right, bottom
}

enum TavernDropTarget: Equatable {
    // Индекс зазора в исходной ленте, до удаления переносимой вкладки.
    case tabSlot(Int)
    case pane(String, TavernDropEdge)
    case tab(String)
    case newTab(String)
}

struct TavernMoveOutcome {
    let changed: Bool
    let tabID: String?
    let paneID: String?
}

enum TavernNavigationMoveError: LocalizedError, Equatable {
    case missingObject(String)
    case invalidTarget
    case unsupportedDrop
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingObject(let id):
            return L("core.move.missingObject", id)
        case .invalidTarget:
            return L("core.move.invalidTarget")
        case .unsupportedDrop:
            return L("core.move.unsupportedDrop")
        case .invalidResponse(let method):
            return L("core.move.invalidResponse", method)
        }
    }
}

// Только публичные операции, сохраняющие процессы. layout.apply пересоздаёт
// терминалы, а pane.move не перестраивает панели внутри одной вкладки.
// На один drop — не более одной мутации, без повторов и отката.
enum TavernNavigationMoves {
    static func execute(source: TavernDragSource, target: TavernDropTarget,
                        snapshot: [String: Any],
                        request: (String, [String: Any]) throws -> [String: Any]) throws -> TavernMoveOutcome {
        let tabs = rows(snapshot["tabs"])
        let panes = rows(snapshot["panes"])
        switch source {
        case .tab(let tabID):
            let tab = try object(tabID, key: "tab_id", in: tabs)
            guard case .tabSlot(let slot) = target else { throw TavernNavigationMoveError.invalidTarget }
            let workspaceID = try identifier(tab, "workspace_id")
            guard workspaceID == (snapshot["focused_workspace_id"] as? String) else {
                throw TavernNavigationMoveError.invalidTarget
            }
            let ordered = tabs.filter { $0["workspace_id"] as? String == workspaceID }
            guard let index = ordered.firstIndex(where: { $0["tab_id"] as? String == tabID }),
                  (0...ordered.count).contains(slot) else { throw TavernNavigationMoveError.invalidTarget }
            // Для зазора справа herdr сам вычитает единицу из индекса.
            // Оба зазора рядом с исходной вкладкой означают отсутствие изменения.
            let destination = slot > index ? slot - 1 : slot
            guard destination != index else { return unchanged }
            let result = try request("tab.move", ["tab_id": tabID, "insert_index": slot])
            guard let returned = result["tabs"] as? [[String: Any]],
                  let movedIndex = returned.firstIndex(where: { $0["tab_id"] as? String == tabID }) else {
                throw TavernNavigationMoveError.invalidResponse("tab.move")
            }
            guard movedIndex != index else { return unchanged }
            return TavernMoveOutcome(changed: true, tabID: tabID, paneID: nil)

        case .pane(let paneID):
            let pane = try object(paneID, key: "pane_id", in: panes)
            let sourceTabID = try identifier(pane, "tab_id")
            let sourceTab = try object(sourceTabID, key: "tab_id", in: tabs)
            switch target {
            case .tabSlot:
                return try execute(source: .tab(sourceTabID), target: target, snapshot: snapshot, request: request)
            case .pane(let targetID, let edge):
                let targetPane = try object(targetID, key: "pane_id", in: panes)
                if targetID == paneID { return unchanged }
                let targetTabID = try identifier(targetPane, "tab_id")
                let targetTab = try object(targetTabID, key: "tab_id", in: tabs)
                if edge == .center {
                    guard sourceTabID == targetTabID else { throw TavernNavigationMoveError.unsupportedDrop }
                    let result = try request("pane.swap", ["source_pane_id": paneID, "target_pane_id": targetID])
                    guard let swap = result["swap"] as? [String: Any],
                          let changed = swap["changed"] as? Bool else {
                        throw TavernNavigationMoveError.invalidResponse("pane.swap")
                    }
                    guard changed else { return unchanged }
                    guard let layout = swap["layout"] as? [String: Any],
                          let tabID = nonempty(layout["tab_id"]),
                          let focusedPaneID = nonempty(swap["focused_pane_id"]) else {
                        throw TavernNavigationMoveError.invalidResponse("pane.swap")
                    }
                    return TavernMoveOutcome(changed: true, tabID: tabID, paneID: focusedPaneID)
                }
                guard sourceTabID != targetTabID else { throw TavernNavigationMoveError.unsupportedDrop }
                if isZoomed(sourceTab) || isZoomed(targetTab) { return unchanged }
                return try move(paneID, destination: ["type": "tab", "tab_id": targetTabID,
                                "target_pane_id": targetID, "split": edge == .right ? "right" : "down"], request: request)
            case .tab(let targetTabID):
                let targetTab = try object(targetTabID, key: "tab_id", in: tabs)
                if sourceTabID == targetTabID { return unchanged }
                let candidates = panes.filter { $0["tab_id"] as? String == targetTabID }
                guard let targetPane = candidates.first(where: { $0["focused"] as? Bool == true }) ?? candidates.first else {
                    throw TavernNavigationMoveError.missingObject(targetTabID)
                }
                let targetPaneID = try identifier(targetPane, "pane_id")
                if isZoomed(sourceTab) || isZoomed(targetTab) { return unchanged }
                return try move(paneID, destination: ["type": "tab", "tab_id": targetTabID,
                                "target_pane_id": targetPaneID, "split": "right"], request: request)
            case .newTab(let workspaceID):
                _ = try object(workspaceID, key: "workspace_id", in: rows(snapshot["workspaces"]))
                if isZoomed(sourceTab) { return unchanged }
                // herdr забирает существующий терминал, в том числе последний,
                // и сам удаляет пустую прежнюю вкладку. Закрывать её не нужно.
                return try move(paneID, destination: ["type": "new_tab", "workspace_id": workspaceID], request: request)
            }
        }
    }

    /// Карточки одной вкладки перемещаются группой; зазор относится ко всей вкладке.
    static func agentTabSlot(sourcePaneID: String, targetPaneID: String, after: Bool,
                             snapshot: [String: Any]) throws -> Int? {
        let panes = rows(snapshot["panes"]), tabs = rows(snapshot["tabs"])
        let source = try object(sourcePaneID, key: "pane_id", in: panes)
        let target = try object(targetPaneID, key: "pane_id", in: panes)
        let sourceTabID = try identifier(source, "tab_id"), targetTabID = try identifier(target, "tab_id")
        let sourceTab = try object(sourceTabID, key: "tab_id", in: tabs)
        let targetTab = try object(targetTabID, key: "tab_id", in: tabs)
        let workspace = try identifier(sourceTab, "workspace_id")
        guard workspace == (snapshot["focused_workspace_id"] as? String),
              workspace == (targetTab["workspace_id"] as? String) else { throw TavernNavigationMoveError.invalidTarget }
        guard sourceTabID != targetTabID else { return nil }
        let ordered = tabs.filter { $0["workspace_id"] as? String == workspace }
        guard let sourceIndex = ordered.firstIndex(where: { $0["tab_id"] as? String == sourceTabID }),
              let targetIndex = ordered.firstIndex(where: { $0["tab_id"] as? String == targetTabID }) else {
            throw TavernNavigationMoveError.invalidTarget
        }
        let slot = targetIndex + (after ? 1 : 0)
        return slot == sourceIndex || slot == sourceIndex + 1 ? nil : slot
    }

    private static var unchanged: TavernMoveOutcome {
        TavernMoveOutcome(changed: false, tabID: nil, paneID: nil)
    }

    private static func move(_ paneID: String, destination: [String: Any],
                             request: (String, [String: Any]) throws -> [String: Any]) throws -> TavernMoveOutcome {
        let result = try request("pane.move", ["pane_id": paneID, "destination": destination, "focus": true])
        guard let move = result["move_result"] as? [String: Any], let changed = move["changed"] as? Bool else {
            throw TavernNavigationMoveError.invalidResponse("pane.move")
        }
        guard changed else { return unchanged }
        guard let pane = move["pane"] as? [String: Any],
              let tabID = nonempty(pane["tab_id"]),
              let movedPaneID = nonempty(pane["pane_id"]) else {
            throw TavernNavigationMoveError.invalidResponse("pane.move")
        }
        // Между пространствами публичный ID панели может измениться: берём
        // новые ID только из ответа, а не из захваченного снимка состояния.
        return TavernMoveOutcome(changed: true, tabID: tabID, paneID: movedPaneID)
    }

    private static func rows(_ value: Any?) -> [[String: Any]] { value as? [[String: Any]] ?? [] }
    private static func nonempty(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func object(_ id: String, key: String, in objects: [[String: Any]]) throws -> [String: Any] {
        guard !id.isEmpty, let object = objects.first(where: { $0[key] as? String == id }) else {
            throw TavernNavigationMoveError.missingObject(id)
        }
        return object
    }

    private static func identifier(_ row: [String: Any], _ key: String) throws -> String {
        guard let id = nonempty(row[key]) else { throw TavernNavigationMoveError.invalidTarget }
        return id
    }

    private static func isZoomed(_ tab: [String: Any]) -> Bool { tab["zoomed"] as? Bool == true }
}
