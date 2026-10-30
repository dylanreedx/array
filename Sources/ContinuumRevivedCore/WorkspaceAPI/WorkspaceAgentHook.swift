import Foundation

/// P1 of the agent communication layer (`.plans/102-managed-agent-mode`): the
/// hook bridge for Claude Code and Codex.
///
/// Array registers one command, `array-workspace-mcp hook …`, for a fixed set
/// of hook events through per-session `--settings` (Claude) or `-c` overrides
/// (Codex, with narrowly scoped trusted hashes). The command
/// posts the hook's stdin JSON to the app over the workspace endpoint, and the
/// app keeps a short receipt. Nothing reads a receipt to change behaviour.
/// The command prints a decision only when the app returns one: P2a's report
/// push-back, behind an opt-in setting (`reportPushBack`). Otherwise it prints
/// nothing, exactly as in P1.
///
/// Deliberately not a `WorkspaceAPIOp`: those are the model-facing operations
/// (the MCP tool catalogue and pi's bridge). This one is reachable only from
/// the MCP endpoint, with the calling agent's own token.
public enum WorkspaceAgentHook {
    /// The endpoint operation the hook command posts.
    public static let op = "agent.hook"
    /// argv[1] of `array-workspace-mcp` that selects hook mode.
    public static let subcommand = "hook"
    /// The events Array observes, in registration order. Measured on claude
    /// 2.1.312 (`.plans/102-managed-agent-mode/p0-claude.md`, V1).
    public static let claudeEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "Stop", "SubagentStart", "SubagentStop",
    ]
    // Codex 0.165.0: event config names and hooks/list key labels (P0 source).
    public static let codexEventKeys = [
        ("SessionStart", "session_start"), ("UserPromptSubmit", "user_prompt_submit"),
        ("PreToolUse", "pre_tool_use"), ("PostToolUse", "post_tool_use"),
        ("Stop", "stop"), ("SubagentStart", "subagent_start"), ("SubagentStop", "subagent_stop"),
    ]
    public static let codexEvents = codexEventKeys.map { $0.0 }

    public static func codexDefinitions(command: String) -> [String] {
        codexEvents.map { event in
            let matcher = toolMatcherEvents.contains(event) ? "matcher=\"*\"," : ""
            return "hooks.\(event)=[{\(matcher)hooks=[{type=\"command\",command=\(tomlString(command)),timeout=5}]}]"
        }
    }

    static func tomlString(_ value: String) -> String {
        // JSON basic strings are TOML basic strings for these scalar values.
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
    /// Events whose matcher is a tool name; `*` covers every tool. The others
    /// match a source or agent type, so no matcher means "all".
    public static let toolMatcherEvents: Set<String> = ["PreToolUse", "PostToolUse"]
    /// How long the hook command waits for the app. Claude waits for the
    /// slowest hook on an event (they run in parallel), so a busy or quit app
    /// may cost a tool call this much and no more.
    public static let postTimeoutSeconds: TimeInterval = 2
    /// Claude's own limit on the command, above `postTimeoutSeconds`. Claude's
    /// default is 600 s, so it is always set.
    public static let claudeHookTimeoutSeconds = 5
    /// A hook body above this is sent without its bulky fields: the endpoint
    /// reads at most 1 MB, and a receipt needs none of them.
    public static let maxPostedPayloadBytes = 512 * 1024
    public static let bulkyFields = ["tool_response", "tool_input", "last_assistant_message", "prompt"]

    /// One shell-quoted command line. Claude runs a hook `command` through a
    /// shell, and the dev bundle's path has a space in it.
    public static func command(executable: String, endpoint: String, agentID: String, tokenFilePath: String) -> String {
        ([executable, subcommand, "--endpoint", endpoint, "--agent-id", agentID, "--token-file", tokenFilePath])
            .map(shellQuoted).joined(separator: " ")
    }

    /// Claude's `--settings` JSON: the hook command on every observed event.
    /// It merges with the user's and the project's own hooks (P0 V2); Array
    /// never passes `--setting-sources`, which drops them.
    public static func claudeSettingsJSON(command: String) -> String {
        var hooks: [String: Any] = [:]
        for event in claudeEvents {
            var group: [String: Any] = [
                "hooks": [["type": "command", "command": command, "timeout": claudeHookTimeoutSeconds]],
            ]
            if toolMatcherEvents.contains(event) { group["matcher"] = "*" }
            hooks[event] = [group]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["hooks": hooks], options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    // MARK: P2a: the report push-back

    /// The app's answer rides here in the hook reply's `result`; the command
    /// prints it verbatim. Absent, the command prints nothing (P1 behaviour).
    public static let hookOutputKey = "hookOutput"
    /// Set by the command when it trims a body, so the app can still count
    /// `last_assistant_message` (`bulkyFields`).
    public static let trimmedWordCountKey = "array_last_assistant_message_words"

    /// The decision for one hook event while "Ask helpers for short reports" is
    /// on, or nil for "say nothing". Only a helper's hand-back qualifies: `Stop`
    /// from an agent that has a parent (created by `array_delegate`), and
    /// `SubagentStop` (Claude's own subagents, inside any Array agent). Once:
    /// a continuation Claude marks `stop_hook_active` is never pushed back.
    public static func reportPushBack(payload: [String: Any], callerHasParent: Bool) -> [String: Any]? {
        let event = payload["hook_event_name"] as? String
        let isHelperHandBack = (event == "Stop" && callerHasParent) || event == "SubagentStop"
        guard isHelperHandBack, payload["stop_hook_active"] as? Bool != true else { return nil }
        let words = (payload[trimmedWordCountKey] as? Int)
            ?? (payload["last_assistant_message"] as? String).map(AgentReport.wordCount) ?? 0
        guard words > AgentShortReportConfig.pushBackWordLimit else { return nil }
        return ["decision": "block", "reason": pushBackReason(words: words, offersReportTool: event == "Stop")]
    }

    /// Reaches the helper as `Stop hook feedback:` + this, as an instruction
    /// (P0 V4). It must never contradict the helper's brief: a brief that said
    /// "no files" made a helper refuse the file and only half-shorten (P0
    /// finding 5), so the brief is named as the one that wins. `array_report`
    /// is offered only on `Stop`: a Claude subagent shares its parent's
    /// workspace token, so its report would land on the parent.
    public static func pushBackReason(words: Int, offersReportTool: Bool) -> String {
        let keep = offersReportTool
            ? "Save the full details to a file and give its path, or call array_report with them."
            : "Save the full details to a file and give its path."
        return "Array: your final message is about \(words) words, and the agent that asked for this work reads all of it. "
            + "Please end with a shorter report of about \(AgentShortReportConfig.targetWords) words: the outcome, what you checked, and anything left open. "
            + keep + " "
            + "If your task says not to write files, just shorten it. If your task asks for the full text, return it unchanged."
    }
}

extension WorkspaceMCPConfiguration {
    /// The hook command for this agent: the same executable, endpoint and token
    /// FILE as its MCP server. The token never enters argv.
    public var claudeHookCommand: String {
        WorkspaceAgentHook.command(executable: serverExecutable, endpoint: endpoint,
                                   agentID: agentID, tokenFilePath: tokenFilePath)
    }

    public var claudeHookSettingsJSON: String {
        WorkspaceAgentHook.claudeSettingsJSON(command: claudeHookCommand)
    }
}

/// What the app keeps of one hook event. Small on purpose: no prompt, tool
/// input or output, and no transcript path.
public struct AgentHookReceipt: Equatable, Sendable {
    /// Assigned from the authenticated host record, never from hook input.
    public var harness: AgentHarness?
    public var event: String
    public var toolName: String?
    /// Claude's subagent id and type, on events fired by or about a subagent.
    public var subagentID: String?
    public var subagentType: String?
    /// On subagent events this is the PARENT's session (P0, stdin fields).
    public var sessionID: String?
    public var receivedAt: Date

    public init(event: String, toolName: String? = nil, subagentID: String? = nil,
                subagentType: String? = nil, sessionID: String? = nil, receivedAt: Date, harness: AgentHarness? = nil) {
        self.harness = harness
        self.event = event
        self.toolName = toolName
        self.subagentID = subagentID
        self.subagentType = subagentType
        self.sessionID = sessionID
        self.receivedAt = receivedAt
    }

    /// nil when the body names no event.
    public init?(hookPayload payload: [String: Any], receivedAt: Date, harness: AgentHarness? = nil) {
        guard let event = payload["hook_event_name"] as? String, !event.isEmpty else { return nil }
        func text(_ key: String) -> String? {
            (payload[key] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(256)) }
        }
        self.init(event: String(event.prefix(64)), toolName: text("tool_name"), subagentID: text("agent_id"),
                  subagentType: text("agent_type"), sessionID: text("session_id"), receivedAt: receivedAt, harness: harness)
    }

    /// How many receipts the app keeps per agent; the oldest go first.
    public static let ringCapacity = 128
}
