import Foundation

/// What a delegated helper costs to start and to keep running. Pure, so a
/// check can drive each rule through the production caller.

/// The tier a helper gets when its lead names no model or effort: the same
/// harness's cheap class from the live catalogue, at effort medium. The class is
/// found by name inside the CLI's own listing; no model id is written here.
public enum HelperDefaultTier {
    /// Stored on the helper's record; the launch still sends it only when the
    /// model's own catalogue lists it.
    public static let effort = "medium"
    /// The brief line every lead sees.
    public static let briefLine = "Pick model and effort for the part, not for yourself."

    /// Name fragment of the cheap class, by harness. Pi has none: its helpers inherit.
    static func costClass(_ harness: AgentHarness) -> String? {
        switch harness {
        case .claudeCode: return "sonnet"
        case .codex: return "mini"
        case .pi: return nil
        }
    }

    /// The newest listed model of the harness's cheap class, or nil.
    public static func model(in snapshot: AgentHarnessCatalogSnapshot) -> String? {
        guard let fragment = costClass(snapshot.harness) else { return nil }
        func name(_ id: String) -> String { snapshot.displayNames[id] ?? id }
        return snapshot.models
            .filter { id in id.lowercased().contains(fragment) || name(id).lowercased().contains(fragment) }
            .max { name($0).compare(name($1), options: .numeric) == .orderedAscending }
    }
}

/// A lead asking about the same helper again inside the window gets a refusal,
/// not an answer: results arrive by themselves, and every poll is a tool call on
/// the lead's whole context.
public struct AgentPollLimiter {
    public static let window: TimeInterval = 5 * 60
    public static let refusal = "Results arrive by themselves. You inspected this agent \u{2264}5 minutes ago; do not poll. Wait for its result or message."
    private var last: [String: Date] = [:]
    public init() {}

    /// Nil to proceed (and the call is recorded); the refusal text otherwise.
    public mutating func check(caller: String, target: String, now: Date) -> String? {
        guard caller != target else { return nil }
        let key = caller + ">" + target
        if let at = last[key], now.timeIntervalSince(at) < Self.window { return Self.refusal }
        last[key] = now
        return nil
    }
}

/// The lean start a helper gets: six tools and one short text. The board pair
/// lets it keep its own task current (`BoardUpkeep`); the host limits a
/// helper's board changes to tasks it is assigned to.
public enum HelperLeanStart {
    public static let tools = ["array_report", "array_status", "array_workspace_context", "array_message_agent",
                               "array_board_query", "array_board_apply"]
    public static let environmentKey = "ARRAY_WORKSPACE_TOOL_ALLOWLIST"
    /// One text for both channels (Claude's MCP instructions, Codex's namespace note).
    public static let instructions =
        "You are a helper running in a tile on the user's Array canvas. Do the task you were given, then call array_report (mcp__array_workspace__array_report; load it with tool search if deferred) with a summary and any check that failed or that you could not run. array_status posts what you are doing, array_message_agent messages another agent, array_workspace_context says who and where you are. If your task names a board card, keep it current with array_board_apply (op comment). Your lead gets your result by itself: never poll."
}
