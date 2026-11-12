import Foundation

/// Per-lead policy, owned and serialized by the supervisor on main.
/// Hook transport failures remain fail-open.
public struct ManagedLeadHookState {
    // Permanent context: paid again on every later message. Keep this brief tight.
    public static let brief = """
    You are an Array Managed lead. Plan first: 1–6 steps, each with an owner (helper, lead, or you); post it with array_status and update it as steps change. Delegate implementation and bulk investigation with array_delegate. Give each helper a self-contained brief: goal, where to look, constraints, and what done means. Send a follow-up to an existing helper with array_message_agent instead of delegating again. Helpers can edit files; you cannot. Use reads, searches, or commands to orient. After delegating, end your turn or keep working; results arrive by themselves. Never wait, poll or message a helper to check on it. Trust a helper's report unless it names a failure or a gap. One review per change; don't re-run a helper's passing checks. Keep context and updates concise.
    """
    /// The tools a Claude Managed lead starts with loaded: the two the brief
    /// names first, and the one it follows up on a helper with. Claude defers
    /// every other MCP tool behind tool search; a lead that had to search for
    /// these did its work through the shell, or sent `array_delegate` before
    /// its schema loaded (`docs/internals/managed-lead-tool-loading.md`).
    public static let alwaysLoadedTools = ["array_status", "array_delegate", "array_message_agent"]
    /// Appended to a Managed lead's helper's first prompt only. Permanent
    /// context for that helper: keep it one short line.
    public static let helperReportLine = "When done, call array_report with a summary and any check that failed or that you could not run."
    public static let editDenial = "Managed leads cannot edit files. Delegate this to a helper with array_delegate."
    // Codex rust-v0.165.0: apply_patch is canonical (Edit/Write are matcher
    // aliases only). Notes extension names are flattened namespace + tool.
    public static let codexEditTools: Set<String> = ["apply_patch", "noteswrite_file", "notesappend_to_file"]
    public var briefedSessions: Set<String> = []

    public init() {}

    public mutating func reply(payload: [String: Any], harness: AgentHarness = .claudeCode) -> [String: Any]? {
        // Native children share the lead's token/session id. Their reads must
        // neither consume the lead's budget nor inherit its lead instructions.
        guard payload["agent_id"] == nil,
              let event = payload["hook_event_name"] as? String else { return nil }
        switch event {
        case "SessionStart":
            guard let source = payload["source"] as? String,
                  ["startup", "resume", "compact", "clear", "fork"].contains(source),
                  let session = payload["session_id"] as? String, !session.isEmpty,
                  (source == "compact" || source == "clear" || !briefedSessions.contains(session)) else { return nil }
            briefedSessions.insert(session)
            return ["hookSpecificOutput": ["hookEventName": event, "additionalContext": Self.brief]]
        case "UserPromptSubmit":
            return nil
        case "PreToolUse":
            guard let tool = payload["tool_name"] as? String, !tool.isEmpty else { return nil }
            // Deny by identity even when an oversized patch's input was trimmed
            // by the hook transport. Freeform patches use {command: patch}.
            if harness == .codex && Self.codexEditTools.contains(tool) {
                return Self.deny(Self.editDenial)
            }
            return nil
        default:
            return nil
        }
    }

    private static func deny(_ reason: String) -> [String: Any] {
        ["hookSpecificOutput": ["hookEventName": "PreToolUse",
            "permissionDecision": "deny", "permissionDecisionReason": reason]]
    }

}
