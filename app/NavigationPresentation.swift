import Foundation

// Only values read by navigation rendering participate in equality. The full
// snapshot remains authoritative for actions and is not retained by this value.
struct TavernNavigationPresentation: Equatable {
    struct Workspace: Equatable {
        let workspaceID: String
        let label: String
    }
    struct Tab: Equatable {
        let tabID: String
        let workspaceID: String
        let label: String
        let customLabel: Bool
    }
    struct Pane: Equatable {
        let paneID: String
        let label: String
        let foregroundCwd: String
        let cwd: String
    }
    struct Agent: Equatable {
        let paneID: String
        let workspaceID: String
        let tabID: String
        let displayAgent: String
        let agent: String
        let name: String
        let agentStatus: String
        let title: String
        let terminalTitle: String
        let terminalTitleStripped: String
    }
    let workspaces: [Workspace]
    let tabs: [Tab]
    let panes: [Pane]
    let agents: [Agent]
    let focusedWorkspaceID: String
    let focusedTabID: String
    let focusedPaneID: String

    init(snapshot: [String: Any]) {
        workspaces = objects(snapshot["workspaces"]).map {
            Workspace(workspaceID: string($0["workspace_id"]), label: string($0["label"]))
        }
        tabs = objects(snapshot["tabs"]).map {
            Tab(tabID: string($0["tab_id"]), workspaceID: string($0["workspace_id"]),
                label: string($0["label"]), customLabel: $0["custom_label"] as? Bool == true)
        }
        panes = objects(snapshot["panes"]).map {
            Pane(paneID: string($0["pane_id"]), label: string($0["label"]),
                 foregroundCwd: string($0["foreground_cwd"]), cwd: string($0["cwd"]))
        }
        agents = objects(snapshot["agents"]).map {
            Agent(paneID: string($0["pane_id"]), workspaceID: string($0["workspace_id"]),
                  tabID: string($0["tab_id"]), displayAgent: string($0["display_agent"]),
                  agent: string($0["agent"]), name: string($0["name"]), agentStatus: string($0["agent_status"]),
                  title: string($0["title"]), terminalTitle: string($0["terminal_title"]),
                  terminalTitleStripped: string($0["terminal_title_stripped"]))
        }
        focusedWorkspaceID = string(snapshot["focused_workspace_id"])
        focusedTabID = string(snapshot["focused_tab_id"])
        focusedPaneID = string(snapshot["focused_pane_id"])
    }
}
