import Foundation

@main struct NavigationPresentationTests {
    static func main() throws {
        let snapshot: [String: Any] = [
            "workspaces": [["workspace_id": "w1", "label": "One"], ["workspace_id": "w2", "label": "Two"]],
            "tabs": [["tab_id": "t1", "workspace_id": "w1", "label": "Shell"], ["tab_id": "t2", "workspace_id": "w1", "label": "Build"]],
            "panes": [["pane_id": "p1", "label": "Code", "foreground_cwd": "/tmp/foreground", "cwd": "/tmp/base"], ["pane_id": "p2", "label": "Logs"]],
            "agents": [["pane_id": "p1", "workspace_id": "w1", "tab_id": "t1", "display_agent": "Display", "agent": "codex", "name": "helper", "agent_status": "working"], ["pane_id": "p2", "workspace_id": "w1", "tab_id": "t1"]],
            "focused_workspace_id": "w1", "focused_tab_id": "t1", "focused_pane_id": "p1"
        ]
        let baseline = TavernNavigationPresentation(snapshot: snapshot)
        let encoded = try JSONSerialization.data(withJSONObject: snapshot, options: .sortedKeys)
        var reordered = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        reordered["surface_revision"] = 999
        reordered["future_optional"] = ["arbitrary": [1, 2, 3]]
        var panes = objects(reordered["panes"])
        panes[0]["inner_rect"] = ["x": 10, "width": 20]
        panes[0]["scroll"] = ["offset_from_bottom": 100]
        reordered["panes"] = panes
        precondition(TavernNavigationPresentation(snapshot: reordered) == baseline)
        print("PASS: JSON key order and non-navigation state do not invalidate navigation")
        for collection in ["workspaces", "tabs", "panes", "agents"] {
            var changed = snapshot
            changed[collection] = Array(objects(snapshot[collection]).reversed())
            precondition(TavernNavigationPresentation(snapshot: changed) != baseline, "Array order lost: \(collection)")
        }
        let fields: [String: [String]] = [
            "workspaces": ["workspace_id", "label"], "tabs": ["tab_id", "workspace_id", "label"],
            "panes": ["pane_id", "label", "foreground_cwd", "cwd"],
            "agents": ["pane_id", "workspace_id", "tab_id", "display_agent", "agent", "name", "agent_status"]
        ]
        for (collection, names) in fields {
            for field in names {
                var changed = snapshot, rows = objects(snapshot[collection])
                rows[0][field] = "changed"; changed[collection] = rows
                precondition(TavernNavigationPresentation(snapshot: changed) != baseline, "Displayed field lost: \(collection).\(field)")
            }
        }
        for field in ["focused_workspace_id", "focused_tab_id", "focused_pane_id"] {
            var changed = snapshot; changed[field] = "different"
            precondition(TavernNavigationPresentation(snapshot: changed) != baseline, "Focus change lost: \(field)")
        }
        print("PASS: row order, displayed values and focused IDs affect equality")
        let missing: [String: Any] = ["workspaces": [["workspace_id": "w"]]]
        let nulls: [String: Any] = ["workspaces": [["workspace_id": "w", "label": NSNull()]], "tabs": NSNull(), "focused_pane_id": NSNull()]
        precondition(TavernNavigationPresentation(snapshot: missing) == TavernNavigationPresentation(snapshot: nulls))
        print("PASS: missing and null fields normalize like navigation rendering")
    }
}
