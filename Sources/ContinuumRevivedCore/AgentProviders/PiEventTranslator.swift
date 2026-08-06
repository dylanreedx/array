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
    private var workingDirectory: URL?
    private let now: @Sendable () -> Date

    /// P2D.2 — the LOCAL-ONLY side channel for `spawn_agent` (and nothing else).
    ///
    /// Deliberately NOT an `AgentRuntimeEvent`: widening the event would put
    /// model-authored tool arguments into the type that crosses the sync boundary,
    /// which is the one thing the I5 note above says this file must not do. A
    /// `SpawnRequest` is not `Codable`, so what arrives here cannot be published
    /// even by accident; the observed call still emits its `.itemStarted` carrying
    /// the tool NAME exactly as before, so nothing about the timeline changes.
    ///
    /// Invoked on whatever thread `translate` runs on — the runner's serial queue
    /// in production.
    public var onSpawnRequest: (@Sendable (SpawnRequest) -> Void)?

    /// Queue 91 P2 — the general host-local observation side channel.
    ///
    /// Like `onSpawnRequest`, this never widens `AgentRuntimeEvent`. It exposes
    /// only an explicit runtime cwd and a whitelisted operation/path projection;
    /// raw args, commands, queries, prompts, and result bodies remain discarded.
    /// The callback fires on the translator's owner queue before the matching
    /// normalized event is returned.
    public var onRuntimeObservation: (@Sendable (AgentRuntimeObservation) -> Void)?

    public init(
        workingDirectory: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.workingDirectory = workingDirectory?.standardizedFileURL
        self.now = now
    }

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
            if let cwd = object["cwd"] as? String,
               let directory = Self.absoluteDirectory(cwd) {
                workingDirectory = directory
                onRuntimeObservation?(.workingDirectory(directory, observedAt: now()))
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
            // The whitelisted tool's args go out of band (P2D.2), never into the
            // event below. `tool_execution_start` carries the WHOLE args object;
            // the `toolcall_delta` fragments in `message_update` are partial JSON
            // by construction, so this is the only line worth reading.
            if let args = object["args"] as? [String: Any] {
                if let onSpawnRequest,
                   let request = SpawnRequest.parse(toolName: toolName, args: args) {
                    onSpawnRequest(request)
                }
                if let onRuntimeObservation,
                   let activity = Self.toolActivity(
                       toolName: toolName,
                       args: args,
                       workingDirectory: workingDirectory,
                       at: now()) {
                    onRuntimeObservation(.toolActivity(itemId: toolCallId, activity: activity))
                }
            }
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

    // MARK: - host-local tool observation

    private static func toolActivity(
        toolName: String,
        args: [String: Any],
        workingDirectory: URL?,
        at observedAt: Date
    ) -> AgentObservedActivity? {
        let operation: AgentObservedActivity.Operation
        let pathKeys: [String]
        switch toolName.lowercased() {
        case "read", "cat":
            operation = .reading
            pathKeys = ["path", "file", "file_path"]
        case "edit", "write", "multiedit", "apply_patch", "applypatch":
            operation = .editing
            pathKeys = ["path", "file", "file_path"]
        case "bash", "shell", "run", "exec", "execute_command":
            // Never retain or parse args.command. In particular, textual `cd`
            // is not a runtime location operation and cannot change Where.
            operation = .running
            pathKeys = []
        case "grep", "find", "ls", "glob", "search", "web_search", "websearch", "web":
            // Search patterns/queries can contain source or secrets; preserve
            // only an optional filesystem scope.
            operation = .searching
            pathKeys = ["path", "directory", "root"]
        default:
            // Unknown tool arguments remain fully opaque. The operation itself
            // is still useful local evidence without guessing an args schema.
            operation = .inspecting
            pathKeys = []
        }

        let target = pathKeys.lazy.compactMap { args[$0] as? String }.first
            .flatMap { resolvedTarget($0, workingDirectory: workingDirectory) }
        return AgentObservedActivity(
            operation: operation,
            targetPath: target,
            startedAt: observedAt,
            updatedAt: observedAt,
            evidenceSource: .toolEvent)
    }

    private static let maximumObservedPathBytes = 4_096

    private static func absoluteDirectory(_ raw: String) -> URL? {
        guard isSafePathText(raw) else { return nil }
        let expanded = (raw as NSString).expandingTildeInPath
        guard (expanded as NSString).isAbsolutePath else { return nil }
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    }

    private static func resolvedTarget(_ raw: String, workingDirectory: URL?) -> URL? {
        guard isSafePathText(raw) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        if (expanded as NSString).isAbsolutePath {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        guard let workingDirectory else { return nil }
        return workingDirectory.appendingPathComponent(expanded).standardizedFileURL
    }

    private static func isSafePathText(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw.utf8.count <= maximumObservedPathBytes else { return false }
        return !raw.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
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
