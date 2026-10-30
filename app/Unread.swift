import Foundation

enum AgentUnreadKind {
    case reply, attention

    var label: String { L(self == .reply ? "core.unread.reply" : "core.unread.attention") }
    var badgeTitle: String { L(self == .reply ? "core.unread.replyBadge" : "core.unread.attentionBadge") }

    init?(notification: [String: Any]) {
        switch notification["kind"] as? String {
        case "Finished": self = .reply
        case "NeedsAttention": self = .attention
        case "Custom":
            switch notification["sound"] as? String {
            case "Done": self = .reply
            case "Request": self = .attention
            default: return nil
            }
        default: return nil
        }
    }
}

// Локальное состояние клиента, независимое от звуков и глобального seen в herdr.
// boot_id защищает от повторного использования pane_id после перезапуска сервера.
struct AgentUnreadTracker {
    private(set) var bootID = ""
    private(set) var marks: [String: AgentUnreadKind] = [:]
    private var statuses: [String: String] = [:]
    private var hasSnapshot = false

    // Проекция текущих агентов, не отдельное состояние прочтения пространства.
    // blocked остаётся актуальным запросом даже после просмотра его панели.
    func workspaceMarks(agents: [[String: Any]], selectedWorkspaceID: String) -> [String: AgentUnreadKind] {
        var result: [String: AgentUnreadKind] = [:]
        for agent in agents {
            guard let paneID = agent["pane_id"] as? String, !paneID.isEmpty,
                  let workspaceID = agent["workspace_id"] as? String, !workspaceID.isEmpty,
                  workspaceID != selectedWorkspaceID else { continue }
            let kind = agent["agent_status"] as? String == "blocked" ? .attention : marks[paneID]
            guard let kind else { continue }
            if result[workspaceID] != .attention { result[workspaceID] = kind }
        }
        return result
    }

    @discardableResult
    private mutating func useBoot(_ boot: String) -> Bool {
        guard boot != bootID else { return false }
        let changed = !marks.isEmpty
        bootID = boot; marks.removeAll(keepingCapacity: true); statuses.removeAll(keepingCapacity: true)
        hasSnapshot = false
        return changed
    }

    @discardableResult
    mutating func record(_ kind: AgentUnreadKind, paneID: String, bootID: String, viewedPane: String?) -> Bool {
        guard !bootID.isEmpty, !paneID.isEmpty else { return false }
        var changed = useBoot(bootID)
        if paneID == viewedPane { return markViewed(paneID) || changed }
        if marks[paneID] != kind { marks[paneID] = kind; changed = true }
        return changed
    }

    @discardableResult
    mutating func markViewed(_ paneID: String?) -> Bool {
        guard let paneID else { return false }
        return marks.removeValue(forKey: paneID) != nil
    }

    @discardableResult
    mutating func synchronize(bootID: String, statuses next: [String: String], viewedPane: String?) -> Bool {
        guard !bootID.isEmpty else { return false }
        var changed = useBoot(bootID)
        for (paneID, status) in next {
            // Первый снимок — исходное состояние, а не повтор старых событий.
            let previous = statuses[paneID]
            guard hasSnapshot, status != previous else { continue }
            let kind: AgentUnreadKind?
            if status == "blocked" { kind = .attention }
            else if status == "done" || (previous == "working" && status == "idle") { kind = .reply }
            else { kind = nil }
            if let kind { changed = record(kind, paneID: paneID, bootID: bootID, viewedPane: viewedPane) || changed }
        }
        statuses = next
        hasSnapshot = true
        if marks.keys.contains(where: { next[$0] == nil }) {
            marks = marks.filter { next[$0.key] != nil }; changed = true
        }
        return markViewed(viewedPane) || changed
    }
}
