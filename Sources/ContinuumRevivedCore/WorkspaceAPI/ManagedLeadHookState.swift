import Foundation

/// Per-Claude-session policy, owned and serialized by the supervisor on main.
/// Hook transport failures remain fail-open; malformed events never spend a look.
public struct ManagedLeadHookState {
    // Permanent context: paid again on every later message. Keep this brief tight.
    public static let brief = """
    You are an Array Managed lead. Plan first: 1–6 steps, each with an owner (helper, lead, or user). Delegate implementation and bulk investigation with array_delegate. Give each helper a self-contained brief: goal, where to look, constraints, and what done means. Helpers default to free mode and can edit files; you cannot edit files. You have 3 quick looks (reads, searches, or commands) per user request; git status, git log, and git diff are free, as are Array's workspace tools. Use quick looks to orient and judge, then hand deeper work to helpers. Collect reports with wait_agents, evaluate their evidence and open issues, and start whatever their results unblock in the same turn. Keep your own context small and your updates concise.
    """
    public static let denial = "Quick-look budget used (3 per request). Hand this to a helper with array_delegate."
    /// Data retrieval and command execution, including external MCP tools.
    /// Coordination (Agent/Task, waits, planning, questions, ToolSearch) is free.
    public static let quickLookTools: Set<String> = [
        "Read", "Grep", "Glob", "Bash", "WebFetch", "WebSearch",
        "LS", "NotebookRead", "LSP", "TaskOutput", "ReadMcpResourceTool", "ListMcpResourcesTool",
    ]
    private var briefedSessions: Set<String> = []
    private var quickLooks = 0

    public init() {}

    public mutating func reply(payload: [String: Any]) -> [String: Any]? {
        // Native children share the lead's token/session id. Their reads must
        // neither consume the lead's budget nor inherit its lead instructions.
        guard payload["agent_id"] == nil,
              let event = payload["hook_event_name"] as? String else { return nil }
        switch event {
        case "SessionStart":
            guard payload["source"] as? String == "startup",
                  let session = payload["session_id"] as? String, !session.isEmpty,
                  briefedSessions.insert(session).inserted else { return nil }
            return ["hookSpecificOutput": ["hookEventName": event, "additionalContext": Self.brief]]
        case "UserPromptSubmit":
            quickLooks = 0
            return nil
        case "PreToolUse":
            guard let tool = payload["tool_name"] as? String, !tool.isEmpty,
                  let input = payload["tool_input"] as? [String: Any],
                  !tool.hasPrefix("mcp__array_workspace__"),
                  Self.quickLookTools.contains(tool) || tool.hasPrefix("mcp__") else { return nil }
            if tool == "Bash" {
                guard let command = input["command"] as? String else { return nil }
                if Self.isFreeGitInspection(command) { return nil }
            }
            // Saturating counter: the fourth and every later look is refused.
            quickLooks = min(quickLooks + 1, 4)
            guard quickLooks > 3 else { return nil }
            return ["hookSpecificOutput": ["hookEventName": event,
                    "permissionDecision": "deny", "permissionDecisionReason": Self.denial]]
        default:
            return nil
        }
    }

    /// Deliberately conservative: a single literal git status/log/diff command.
    /// Shell composition, substitutions, redirection, quoted/escaped arguments,
    /// git configuration overrides and output/external diff flags spend a look.
    /// We don't attempt to implement a shell parser in a lifecycle hook.
    public static func isFreeGitInspection(_ command: String) -> Bool {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 /._-:=@+~%,")
        guard !command.isEmpty, command.unicodeScalars.allSatisfy({ safe.contains($0) }) else { return false }
        let words = command.split(separator: " ").map(String.init)
        guard words.count >= 2, words[0] == "git", ["status", "log", "diff"].contains(words[1]) else { return false }
        return !words.dropFirst(2).contains {
            $0.hasPrefix("--output") || $0 == "--ext-diff" || $0 == "--textconv"
        }
    }
}
