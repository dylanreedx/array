import Foundation

// Ticket: docs/38-tickets/88-provider-adapter-pi-gpt.md
//
// First provider adapter — the PURE half. Translates Pi's `--mode json` event
// stream (verified live against GPT-5.6 via the openai-codex provider) into
// the normalized `AgentRuntimeEvent` the managed-agent tile + transcript model
// already consume. No process management here (that is PiAgentRunner, the
// impure half) — this is line-in → events-out, so it is exhaustively testable
// in the matrix against the real captured schema.
//
// I5 by construction: `AgentRuntimeEvent` has no field for a cwd, a file path,
// or a tool result body, so mapping into it *drops* Pi's sensitive payloads
// (`session.cwd`, `tool args.path`, `tool result.content`). Tool items carry
// only the tool NAME as their title, never the arguments. Proven in
// `runPiEventTranslatorChecks`.
//
// Pi gives no turn IDs, so they are synthesised here as `<sessionId>#t<n>`,
// stable within a session.
//
// Placement note (same as AgentUI): lives in Core for the first slice to avoid
// new-module wiring; extract to a dedicated agents module once there are
// multiple providers.
public struct PiEventTranslator {
    private var threadId: String = "pi-unknown"
    private var turnCounter: Int = 0
    private var currentTurnId: String = "pi-unknown#t0"

    public init() {}

    /// Translate one line of Pi json output into zero or more normalized
    /// events. Unrecognised or purely-structural lines (text_start markers,
    /// the redundant agent_end transcript dump, user message echoes) return [].
    public mutating func translate(line: String) -> [AgentRuntimeEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else {
            return []
        }

        switch type {
        case "session":
            if let id = object["id"] as? String {
                threadId = id
            }
            return [.sessionStateChanged(.ready)]

        case "agent_start":
            return [.sessionStateChanged(.running)]

        case "turn_start":
            turnCounter += 1
            currentTurnId = "\(threadId)#t\(turnCounter)"
            return [.turnStarted(threadId: threadId, turnId: currentTurnId)]

        case "message_update":
            return translateMessageUpdate(object)

        case "tool_execution_start":
            guard let toolCallId = object["toolCallId"] as? String,
                  let toolName = object["toolName"] as? String else { return [] }
            // title = tool NAME only. Never args (args.path is I5-sensitive).
            return [.itemStarted(
                threadId: threadId,
                itemId: toolCallId,
                kind: Self.itemKind(forTool: toolName),
                title: toolName
            )]

        case "tool_execution_end":
            guard let toolCallId = object["toolCallId"] as? String,
                  let toolName = object["toolName"] as? String else { return [] }
            let isError = (object["isError"] as? Bool) ?? false
            return [.itemCompleted(
                threadId: threadId,
                itemId: toolCallId,
                kind: Self.itemKind(forTool: toolName),
                status: isError ? .failed : .completed
            )]

        case "turn_end":
            return [.turnCompleted(
                threadId: threadId,
                turnId: currentTurnId,
                outcome: .completed,
                errorMessage: nil
            )]

        case "agent_settled":
            return [.sessionStateChanged(.ready)]

        default:
            // session/user message echoes, agent_end transcript dump, etc.
            return []
        }
    }

    /// Convenience: translate a whole stream (e.g. a captured `.log`).
    public mutating func translate(stream lines: [String]) -> [AgentRuntimeEvent] {
        lines.flatMap { translate(line: $0) }
    }

    // MARK: - message_update sub-protocol

    private func translateMessageUpdate(_ object: [String: Any]) -> [AgentRuntimeEvent] {
        guard let event = object["assistantMessageEvent"] as? [String: Any],
              let subtype = event["type"] as? String else { return [] }
        switch subtype {
        case "text_delta":
            guard let delta = event["delta"] as? String, !delta.isEmpty else { return [] }
            return [.contentDelta(threadId: threadId, turnId: currentTurnId, streamKind: .assistant, delta: delta)]
        case "thinking_delta":
            guard let delta = event["delta"] as? String, !delta.isEmpty else { return [] }
            return [.contentDelta(threadId: threadId, turnId: currentTurnId, streamKind: .reasoning, delta: delta)]
        default:
            // start/end markers and toolcall_* arg streaming (tools are handled
            // via the top-level tool_execution_* events) carry no body.
            return []
        }
    }

    // MARK: - tool → ItemKind

    /// Coarse category for iconography. The exact tool name rides `title`; this
    /// only buckets for the UI. Inspection tools (read/grep/ls/glob) fall to
    /// `.commandExecution` as the generic tool-execution bucket — a fuller
    /// taxonomy is a follow-up, deliberately not expanding the shared enum here.
    static func itemKind(forTool tool: String) -> ItemKind {
        switch tool.lowercased() {
        case "edit", "write", "multiedit", "apply_patch", "applypatch":
            return .fileChange
        case "web_search", "websearch", "web":
            return .webSearch
        default:
            return .commandExecution
        }
    }
}
