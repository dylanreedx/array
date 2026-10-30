import Foundation

/// Per-lead policy, owned and serialized by the supervisor on main.
/// Hook transport failures remain fail-open; malformed events never spend a look.
public struct ManagedLeadHookState {
    // Permanent context: paid again on every later message. Keep this brief tight.
    public static let brief = """
    You are an Array Managed lead. Plan first: 1–6 steps, each with an owner (helper, lead, or you); post it with array_status and update it as steps change. Delegate implementation and bulk investigation with array_delegate. Give each helper a self-contained brief: goal, where to look, constraints, and what done means. Helpers default to free mode and can edit files; you cannot edit files. You have 3 quick looks (reads, searches, or commands) per user request; git status, git log, and git diff are free, as are Array's workspace tools. Use quick looks to orient and judge, then hand deeper work to helpers. Collect reports with wait_agents, evaluate their evidence and open issues, and start whatever their results unblock in the same turn. Keep your own context small and your updates concise.
    """
    public static let denial = "Quick-look budget used (3 per request). Hand this to a helper with array_delegate."
    /// Data retrieval and command execution, including external MCP tools.
    /// Coordination (Agent/Task, waits, planning, questions, ToolSearch) is free.
    public static let quickLookTools: Set<String> = [
        "Read", "Grep", "Glob", "Bash", "WebFetch", "WebSearch",
        "LS", "NotebookRead", "LSP", "TaskOutput", "ReadMcpResourceTool", "ListMcpResourcesTool",
    ]
    public static let editDenial = "Managed leads cannot edit files. Delegate this to a helper with array_delegate."
    // Codex rust-v0.165.0: apply_patch is canonical (Edit/Write are matcher
    // aliases only). Notes extension names are flattened namespace + tool.
    public static let codexEditTools: Set<String> = ["apply_patch", "noteswrite_file", "notesappend_to_file"]
    public static let codexShellTools: Set<String> = ["Bash", "exec_command", "shell", "shell_command"]
    public static let codexQuickLookTools: Set<String> = codexShellTools.union([
        "write_stdin", "read_file", "grep_files", "list_dir", "view_image",
        "read_mcp_resource", "list_mcp_resources", "list_mcp_resource_templates",
        "web_search", "webrun", "notesread_file", "noteslist_files_by_prefix", "notessearch_contents",
        "historylist_windows", "historylist_items", "historyread_item", "historysearch_contents",
    ])
    private var briefedSessions: Set<String> = []
    private var quickLooks = 0

    public init() {}

    public mutating func reply(payload: [String: Any], harness: AgentHarness = .claudeCode) -> [String: Any]? {
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
            guard let tool = payload["tool_name"] as? String, !tool.isEmpty else { return nil }
            // Deny by identity even when an oversized patch's input was trimmed
            // by the hook transport. Freeform patches use {command: patch}.
            if harness == .codex && Self.codexEditTools.contains(tool) {
                return Self.deny(Self.editDenial)
            }
            guard let input = payload["tool_input"] as? [String: Any],
                  !tool.hasPrefix("mcp__array_workspace__"),
                  (harness == .codex ? Self.codexQuickLookTools : Self.quickLookTools).contains(tool)
                    || tool.hasPrefix("mcp__") else { return nil }
            if harness == .codex ? Self.codexShellTools.contains(tool) : tool == "Bash" {
                // Native shell/exec hooks normalize to Bash + command. Accept
                // raw exec's cmd too; shell arrays spend a look conservatively.
                let command = input["command"] as? String ?? (harness == .codex ? input["cmd"] as? String : nil)
                if let command {
                    if Self.isFreeGitInspection(command) { return nil }
                } else if !(harness == .codex && input["command"] is [String]) {
                    return nil
                }
            }
            // Saturating counter: the fourth and every later look is refused.
            quickLooks = min(quickLooks + 1, 4)
            guard quickLooks > 3 else { return nil }
            return Self.deny(Self.denial)
        default:
            return nil
        }
    }

    private static func deny(_ reason: String) -> [String: Any] {
        ["hookSpecificOutput": ["hookEventName": "PreToolUse",
            "permissionDecision": "deny", "permissionDecisionReason": reason]]
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
