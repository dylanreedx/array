import Foundation

/// Experimental Claude-only chooser. Never inferred from the strict-lead switch.
public enum ManagedChooser {
    public static let enabledKey = "agents.managedMode.chooser"
    public static let environmentKey = "ARRAY_MANAGED_CHOOSER"
    public static let serverEnvironmentKey = "ARRAY_WORKSPACE_CHOOSER"
    public static func isEnabled(defaults: UserDefaults,
                                 environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if let value = environment[environmentKey] { return ["1", "true", "yes", "on"].contains(value.lowercased()) }
        return defaults.object(forKey: enabledKey) as? Bool == true
    }
    public static let delegationIntent = "In Managed mode, choose helpers when a split is justified without another delegation request. Honor requests to work alone; Array’s Agent permissions still apply."
    public static let brief = delegationIntent + " Do it yourself unless there are at least two independent parts touching different files, each needing real reading. Declare solo or split once with array_plan; a split needs a title and contract for every part. When splitting, start every part at once with array_delegate and its contract. Never hand the whole task to one helper: if only one part needs doing, do it. A helper re-reads the files, roughly doubling the task's tokens in the small-task pilot. Read-only investigation or review uses readOnly: true. After delegating implementation, your file and command tools close until every implementation helper finishes. Continue coordination or end your turn; results arrive automatically. Trust passing checks; one review per change."
    public static let denial = "Array: implementation helpers own this task's changes. Your editing and command tools reopen after every implementation helper finishes. Coordinate through Array or end your turn."
    public static let unavailable = "Array: the chooser's host policy could not be checked. This tool was refused. Resume or relaunch this lead in Array to restore its policy; retrying the orphaned CLI alone cannot recover it."
    public static let handoffAdvice = "One-helper hand-off: if this is the whole task, do it yourself next time; use a split only for two or more independent parts."

    public static func deny(_ reason: String = denial) -> [String: Any] {
        ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": reason]]
    }
    /// Deliberately deny command execution, even a purported read command:
    /// aliases, substitutions, git pagers and interpreters are write routes.
    /// Array's authenticated coordination tools and native reads remain usable.
    /// Unknown MCP/plugin routes fail closed; no name-based “read” inference.
    public static func toolReply(_ payload: [String: Any], latched: Bool) -> [String: Any]? {
        guard latched, payload["hook_event_name"] as? String == "PreToolUse" else { return nil }
        guard payload["agent_id"] == nil else { return deny() } // native children cannot bypass their lead's policy
        guard let tool = payload["tool_name"] as? String else { return deny() }
        if ["Read", "Grep", "Glob", "ToolSearch", "mcp__array_workspace__wait_agents"].contains(tool) { return nil }
        if let own = ArrayWorkspaceTool(toolName: tool),
           [.workspaceContext, .canvasQuery, .findAgent, .inspectAgent, .delegate, .messageAgent,
            .getOperation, .report, .status, .plan, .standards].contains(own) { return nil }
        return deny()
    }
}

public struct AgentTaskPlan: Codable, Equatable, Sendable {
    public enum Choice: String, Codable, Sendable { case solo, split }
    public struct Part: Codable, Equatable, Sendable {
        public var title: String
        public var contract: AgentDelegationContract
    }
    public var choice: Choice
    public var reason: String
    public var parts: [Part]?
    public var line: String {
        let reason = reason.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return choice == .solo ? "Solo: \(reason)" : "Split into \(parts?.count ?? 0): \(reason)"
    }
    public func prepared(checkoutRoot: String) throws -> AgentTaskPlan {
        guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, reason.count <= 400,
              (parts?.count ?? 0) <= 16 else {
            throw WorkspaceAPIError(code: .invalidRequest, message: "Use a one-line reason (1–400 characters) and at most 16 parts.")
        }
        guard choice != .solo || parts?.isEmpty != false else {
            throw WorkspaceAPIError(code: .invalidRequest, message: "A solo plan has no delegated parts.")
        }
        // A one-part split is accepted and advised, never a delegation refusal.
        var result = self
        result.parts = try parts?.map { part in
            guard !part.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, part.title.count <= 200 else {
                throw WorkspaceAPIError(code: .invalidRequest, message: "Every part needs a short title.")
            }
            var normalized = part
            normalized.contract = part.contract.prepared(checkoutRoot: checkoutRoot).contract ?? .init()
            return normalized
        }
        return result
    }
}

/// One host request, independent of hook prompt ids and provider session ids.
/// A declaration never latches; an implementation effect does. Repeated and
/// late terminal events are compared against their original request binding.
public struct ManagedChooserRequest {
    public let id = UUID()
    public var plan: AgentTaskPlan?
    public var implementationChildren = Set<UUID>()
    public var finishedChildren = Set<UUID>()
    public var delegationSources = Set<String>()
    public var turnIDs = Set<String>()
    public var leadEnded = false
    public var latched: Bool { !implementationChildren.subtracting(finishedChildren).isEmpty }
    public init() {}
}
