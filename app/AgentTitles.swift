import Foundation

// A client-only projection: automatic titles never rename server tabs or panes.
struct AgentTitles: Equatable {
    private let leadingPaneIDs: [String: String]
    private let automaticTitles: [String: String]

    init(snapshot: [String: Any], updates: AgentTitleUpdates = AgentTitleUpdates()) {
        let agents = snapshot["agents"] as? [[String: Any]] ?? []
        // Choose by pane identity, not focused/agent_order, so switching focus
        // or rearranging cards cannot rename a split tab.
        var leaders: [String: String] = [:]
        var titles: [String: String] = [:]
        for agent in agents {
            guard let agent = updates.applying(to: agent) else { continue }
            let paneID = Self.text(agent["pane_id"]), tabID = Self.text(agent["tab_id"])
            guard !paneID.isEmpty, !tabID.isEmpty else { continue }
            titles[paneID] = Self.automaticTitle(agent)
            if leaders[tabID].map({ paneID < $0 }) ?? true { leaders[tabID] = paneID }
        }
        leadingPaneIDs = leaders
        automaticTitles = titles
    }

    func tabTitle(_ tab: [String: Any]) -> String {
        let label = Self.text(tab["label"])
        if tab["custom_label"] as? Bool == true, !label.isEmpty { return label }
        if let paneID = leadingPaneIDs[Self.text(tab["tab_id"])], let title = automaticTitles[paneID] {
            return title
        }
        return label.isEmpty ? Self.text(tab["tab_id"]) : label
    }

    func cardTitle(agent: [String: Any], pane: [String: Any]?, fallback: String) -> String {
        let label = Self.text(pane?["label"])
        if !label.isEmpty { return label }
        // A tab's custom label describes the group, not every agent in it.
        return automaticTitles[Self.text(agent["pane_id"])] ?? fallback
    }

    static func automaticTitle(_ agent: [String: Any]) -> String? {
        let kinds = [text(agent["agent"]), text(agent["display_agent"])].map { $0.lowercased() }
        let omp = kinds.contains("omp") || kinds.contains("oh-my-pi") || kinds.contains("pi")
        let terminal = (omp ? ["terminal_title", "terminal_title_stripped"] : ["terminal_title_stripped", "terminal_title"])
            .map { text(agent[$0]) }
        // OMP's OSC title is its authoritative session name, including its icon.
        // Herdr 0.9.5 forwards it, but only strips leading Claude-style activity.
        let candidates = omp
            ? terminal + [text(agent["title"]), text(agent["name"])]
            : [text(agent["title"]), text(agent["name"])] + terminal
        for candidate in candidates {
            let title = omp ? ompTitle(candidate) : candidate
            if !title.isEmpty, !generic(title, kinds: kinds) { return title }
        }
        return nil
    }

    private static func generic(_ title: String, kinds: [String]) -> Bool {
        let value = title.lowercased()
        return kinds.contains(value) || ["agent", "terminal", "shell", "bash", "zsh", "fish", "sh", "node", "bun", "pi", "π", "omp", "oh-my-pi", "claude", "claude code", "codex", "opencode", "gemini", "kimi", "kilo", "mastracode"].contains(value)
    }

    private static func ompTitle(_ raw: String) -> String {
        var title = raw
        if title.hasPrefix("π:") {
            title = text(String(title.dropFirst(2)))
        } else if title.hasPrefix("π ") {
            let rest = title.dropFirst(2)
            if let separator = rest.first,
               ">!:-\\|/○◔◑◕●".contains(separator) || separator.unicodeScalars.allSatisfy({ (0x2800...0x28FF).contains($0.value) }),
               rest.dropFirst().isEmpty || rest.dropFirst().first?.isWhitespace == true {
                title = text(String(rest.dropFirst()))
            }
        }
        // OMP's documented card grammar: one emoji/Nerd glyph, 1–6 ASCII
        // capitals/digits, colon, title. Never strip arbitrary prose prefixes.
        let pieces = title.split(separator: " ", maxSplits: 2)
        if pieces.count == 3, pieces[0].count == 1, pieces[1].hasSuffix(":"), isIcon(pieces[0]) {
            let code = pieces[1].dropLast()
            if (1...6).contains(code.count), code.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }) {
                return String(pieces[0]) + " " + String(pieces[2])
            }
        }
        return title
    }

    private static func isIcon(_ value: Substring) -> Bool {
        value.unicodeScalars.contains {
            $0.properties.isEmojiPresentation || $0.value == 0xFE0F ||
                (0xE000...0xF8FF).contains($0.value) || (0xF0000...0xFFFFD).contains($0.value) ||
                (0x100000...0x10FFFD).contains($0.value)
        }
    }

    private static func text(_ value: Any?) -> String {
        (value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
