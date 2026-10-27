import Foundation
import CoreFoundation

// Public metadata is deliberately kept apart from endpoint geometry and labels.
struct AgentTitleUpdates {
    private struct Entry {
        let terminalID: String
        let revision: UInt64?
        let fields: [String: String]
        let closed: Bool
        let sequence: UInt64
    }
    private static let keys = ["title", "terminal_title", "terminal_title_stripped", "agent", "display_agent"]
    private static let capacity = 4096
    private var entries: [String: Entry] = [:]
    private var sequence: UInt64 = 0

    init() {}

    // True means that the title projection may visibly change. Revision-only
    // updates still advance the watermark without rebuilding navigation.
    mutating func consume(event: [String: Any]) -> Bool {
        guard let data = event["data"] as? [String: Any] else { return false }
        switch Self.text(event["event"]) {
        case "pane_closed":
            let paneID = Self.text(data["pane_id"])
            guard !paneID.isEmpty, entries[paneID]?.closed != true else { return false }
            sequence &+= 1
            entries[paneID] = Entry(terminalID: "", revision: nil,
                                    fields: [:], closed: true, sequence: sequence)
            trim()
            return true
        case "pane_updated", "pane_created":
            guard let pane = data["pane"] as? [String: Any] else { return false }
            let paneID = Self.text(pane["pane_id"]), terminalID = Self.text(pane["terminal_id"])
            guard !paneID.isEmpty, !terminalID.isEmpty else { return false }
            let previous = entries[paneID]
            // A closed public pane identity cannot be revived by a queued update.
            guard previous?.closed != true else { return false }
            let revision = Self.revision(pane["revision"])
            let sameTerminal = previous?.terminalID == terminalID
            if sameTerminal, let oldRevision = previous?.revision, let revision, revision < oldRevision { return false }
            let fields = Self.fields(pane)
            let changed = previous == nil || !sameTerminal ||
                AgentTitles.automaticTitle(previous!.fields) != AgentTitles.automaticTitle(fields)
            store(paneID: paneID, pane: pane)
            return changed
        default:
            return false
        }
    }

    // nil suppresses only a closed pane's automatic title, never shell state.
    func applying(to agent: [String: Any]) -> [String: Any]? {
        guard let entry = entries[Self.text(agent["pane_id"])] else { return agent }
        if entry.closed { return nil }
        let terminalID = Self.text(agent["terminal_id"])
        guard terminalID.isEmpty || terminalID == entry.terminalID else { return agent }
        if let snapshotRevision = Self.revision(agent["revision"]), let revision = entry.revision,
           snapshotRevision > revision { return agent }
        var result = agent
        for key in Self.keys {
            // PaneInfo omits absent optional values: absence clears old metadata.
            result[key] = entry.fields[key]
        }
        return result
    }

    private mutating func store(paneID: String, pane: [String: Any]) {
        sequence &+= 1
        entries[paneID] = Entry(terminalID: Self.text(pane["terminal_id"]), revision: Self.revision(pane["revision"]),
                                fields: Self.fields(pane), closed: false, sequence: sequence)
        trim()
    }

    private mutating func trim() {
        if entries.count > Self.capacity, let oldest = entries.min(by: { $0.value.sequence < $1.value.sequence })?.key {
            entries.removeValue(forKey: oldest)
        }
    }

    private static func fields(_ pane: [String: Any]) -> [String: String] {
        var fields: [String: String] = [:]
        for key in keys {
            let value = text(pane[key])
            if !value.isEmpty { fields[key] = value }
        }
        return fields
    }

    private static func revision(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return UInt64(number.stringValue)
    }

    private static func text(_ value: Any?) -> String {
        (value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
