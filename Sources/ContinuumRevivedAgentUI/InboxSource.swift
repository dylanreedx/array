import Foundation

// Plan: .plans/87-sidebar-liveness/README.md (quick hide/show, Dylan 2026-10-27)
//
// THE SECOND DIMENSION OF THE SIDEBAR'S FILTER. The workspace set
// (`InboxWorkspaceFilter`) says WHERE; this says WHO RUNS IT: Array's own agents,
// or a session from another app on the Mac (Terminal, the Claude app, cmux). A
// row is shown when both dimensions keep it. The toggle pills under the search
// field are both dimensions side by side; the scope popover is the first alone.
//
// Stored as a set of HIDDEN source keys, so a source that appears later (a new
// app) shows by default — the same open-ended reading an exclude set gives a new
// workspace. `array` is the key for Array's own agents: it has no pill of its
// own (the workspace pills stand for them) and is hidden only by soloing an
// outside source.
public enum InboxSource {
    public static let arrayAgents = "array"

    /// The source a row belongs to: `array` for Array's own agents and their
    /// subagents, the outside session's app otherwise.
    public static func key(for row: AgentInboxRow) -> String {
        guard let external = row.externalSession else { return arrayAgents }
        if let source = external.source, !source.isEmpty { return source }
        guard let text = row.whereMarker?.text else { return "Elsewhere" }
        let host = text.components(separatedBy: " · ").first ?? text
        return host == "tmux" ? "Terminal" : host
    }

    /// The rows the hidden sources leave, in the order they arrived.
    public static func filter(_ rows: [AgentInboxRow], hidden: Set<String>) -> [AgentInboxRow] {
        guard !hidden.isEmpty else { return rows }
        return rows.filter { !hidden.contains(key(for: $0)) }
    }

    /// Pill order, fixed so a pill never moves under the pointer: Terminal, the
    /// Claude app, then every other app by name.
    public static func ordered(_ keys: Set<String>) -> [String] {
        let leading = ["Terminal", "Claude app"]
        return leading.filter(keys.contains)
            + keys.subtracting(leading).subtracting([arrayAgents])
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

/// How many agents a pill or a popover row speaks for: TOP-LEVEL agents only,
/// live ones only. A parent with 26 subagents is one piece of work, and counting
/// its children made a workspace with two agents read "28 agents" (Dylan,
/// 2026-10-27).
public enum InboxTally {
    public struct Count: Equatable, Sendable {
        public let agents: Int
        public let needsYou: Int
    }

    public static func needsYou(_ row: AgentInboxRow) -> Bool {
        row.state == .approval || row.state == .input
    }

    /// `needsYou` counts every live row that waits on you, a subagent included:
    /// a child asking for approval is something here that needs you.
    public static func count(_ rows: [AgentInboxRow]) -> Count {
        let live = rows.filter { $0.lifecycle == .active }
        return Count(agents: live.filter { $0.parentId == nil }.count,
                     needsYou: live.filter(needsYou).count)
    }

    /// "4 agents · 1 needs you".
    public static func detail(_ count: Count) -> String {
        var text = count.agents == 1 ? "1 agent" : "\(count.agents) agents"
        if count.needsYou > 0 { text += " · \(count.needsYou) needs you" }
        return text
    }
}
