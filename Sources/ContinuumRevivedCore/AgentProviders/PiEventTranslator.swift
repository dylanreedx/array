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
// Pi's "turn" is one model/tool cycle, not one user-visible agent run. A
// single prompt that calls three tools can therefore contain four
// turn_start/turn_end pairs. Array's lifecycle boundary is agent_start through
// agent_settled; mapping Pi's internal turns to AgentRuntimeEvent.turn* resets
// the run clock and emits a completion notification after every tool.
//
// Pi gives no agent-run IDs, so they are synthesised here as `<sessionId>#t<n>`,
// stable within a session.
//
// Placement note (same as AgentUI): lives in Core for the first slice to avoid
// new-module wiring; extract to a dedicated agents module once there are
// multiple providers.
public struct PiEventTranslator {
    private var threadId: String = "pi-unknown"
    private var runCounter: Int = 0
    private var currentTurnId: String = "pi-unknown#t0"
    private var runIsActive = false
    private var pendingRunOutcome: TurnOutcome = .completed
    private var pendingRunErrorMessage: String?
    private var seenUsageSignatures = Set<String>()
    private var semanticSignalsByItemID: [String: Set<AgentSemanticSignalKind>] = [:]
    /// Did the message currently being assembled already emit its text as deltas?
    ///
    /// This is what keeps `replayingCompletedMessages` honest. See the doc on that
    /// flag: a run's `events.jsonl` holds BOTH forms of the same words for the
    /// whole time the run is live, so recovery has to be decided per message, not
    /// per reader.
    private var streamedTextInCurrentMessage = false
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

    /// Where an observed pi child's transcript will be found.
    ///
    /// The third-party `delegate_agent` tool runs its child as a separate process
    /// and appends that child's stdout to `.pi/agent-runs/<runId>/events.jsonl`.
    /// The `runId` is only in the tool's RESULT, so it arrives strictly after the
    /// `SpawnRequest` that mints the child — the chip appears on the call, the
    /// transcript binds on the return. In practice that gap is milliseconds
    /// (`background` defaults true and the tool returns as soon as the run is
    /// created), which is why no discovery-by-scan exists to close it: matching a
    /// role and a timestamp against sibling run directories is a duplicate-minting
    /// machine.
    ///
    /// Local-only and non-Codable for the same I5 reason as `onSpawnRequest`.
    public var onObservedRun: (@Sendable (ObservedRunHandle) -> Void)?

    /// Queue 91 P2 — the general host-local observation side channel.
    ///
    /// Like `onSpawnRequest`, this never widens `AgentRuntimeEvent`. It exposes
    /// only an explicit runtime cwd and a whitelisted operation/path projection;
    /// raw args, commands, queries, prompts, and result bodies remain discarded.
    /// The callback fires on the translator's owner queue before the matching
    /// normalized event is returned.
    public var onRuntimeObservation: (@Sendable (AgentRuntimeObservation) -> Void)?

    /// Recover assistant prose from COMPLETED messages instead of from deltas.
    ///
    /// Off for the live path, which must stay byte-identical: pi streams assistant
    /// text as `message_update` → `text_delta`, and `message_end` contributes only
    /// usage, so reading both would duplicate every word.
    ///
    /// On for reading an observed child's `events.jsonl`, where it is the only
    /// way to get the prose once the run has ended. It does NOT mean "this file is
    /// finished": the same reader tails the run live, and a live file holds both
    /// the deltas and the `message_end` that closes them. So this flag only grants
    /// PERMISSION to recover; `streamedTextInCurrentMessage` decides whether there
    /// is anything left to recover. Measured, not assumed: the `harness-agents`
    /// extension rewrites that file when the run completes and the rewrite strips
    /// **every** `message_update` line (24 → 0 in a probe), leaving `message_end`
    /// holding the full text. Replaying a finished run without this yields tools,
    /// turns and usage — and not one word of what the child said.
    private let replayingCompletedMessages: Bool

    public init(
        workingDirectory: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        replayingCompletedMessages: Bool = false
    ) {
        self.workingDirectory = workingDirectory?.standardizedFileURL
        self.now = now
        self.replayingCompletedMessages = replayingCompletedMessages
    }

    /// Assistant text from a COMPLETED message, for the replay path only.
    ///
    /// `role == "user"` is skipped unconditionally, and that is not an
    /// optimisation: in a child's own `events.jsonl` the user message is the
    /// `Task: <task>` prompt body the parent handed it. That text is
    /// model-authored, I5-sensitive, and Array's own boundary says command bodies
    /// never cross — so the one line in the file that contains it is the one line
    /// this refuses to read.
    private func completedMessageText(from object: [String: Any]) -> [AgentRuntimeEvent] {
        guard let message = object["message"] as? [String: Any],
              (message["role"] as? String) == "assistant",
              let content = message["content"] as? [[String: Any]]
        else {
            return []
        }
        var events: [AgentRuntimeEvent] = []
        for block in content where (block["type"] as? String) == "text" {
            guard let text = block["text"] as? String, !text.isEmpty else { continue }
            events.append(.contentDelta(
                threadId: threadId,
                turnId: currentTurnId,
                streamKind: .assistant,
                delta: text))
        }
        return events
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
            return beginRun()

        case "turn_start":
            // One Pi agent run contains another turn after each tool result.
            // Keep those protocol cycles out of Array's user-visible lifecycle.
            // The fallback preserves streams captured before agent_start.
            return runIsActive ? [] : beginRun()

        case "message_start":
            // Purely structural, and deliberately not folded into `default`: this
            // is where the per-message recovery state resets.
            streamedTextInCurrentMessage = false
            return []

        case "message_update":
            return translateMessageUpdate(object)

        case "message_end":
            var events = translateUsageEvents(from: object)
            // Recover the completed text only for a message that never streamed.
            // A run being tailed live has not been compacted yet, so its deltas
            // are still in the file and this same `message_end` closes them —
            // recovering unconditionally repeats the entire answer.
            if replayingCompletedMessages && !streamedTextInCurrentMessage {
                events.insert(contentsOf: completedMessageText(from: object), at: 0)
            }
            streamedTextInCurrentMessage = false
            return events

        case "tool_execution_start":
            guard let toolCallId = object["toolCallId"] as? String,
                  let toolName = object["toolName"] as? String else { return [] }
            // The whitelisted tool's args go out of band (P2D.2), never into the
            // event below. `tool_execution_start` carries the WHOLE args object;
            // the `toolcall_delta` fragments in `message_update` are partial JSON
            // by construction, so this is the only line worth reading.
            if let args = object["args"] as? [String: Any] {
                if ["bash", "shell", "run", "exec", "execute_command"].contains(toolName.lowercased()),
                   let command = args["command"] as? String {
                    let signals = AgentGitOperationClassifier.operations(in: command)
                    if !signals.isEmpty { semanticSignalsByItemID[toolCallId] = signals }
                }
                if let onSpawnRequest,
                   let request = SpawnRequest.parse(toolName: toolName, args: args, sourceItemID: toolCallId) {
                    onSpawnRequest(request)
                }
                // pi's other delegation verb. Kept a separate call rather than
                // folded into `parse` because the child is already running and
                // Array must never claim to own it — `observedOnly` is what stops
                // a composer and a Stop appearing on a process Array cannot
                // prompt. `task` reaches the supervisor here and NOWHERE else:
                // `toolDetailFields` whitelists query/pattern/url/path/description,
                // so it does not cross the I5 boundary below.
                if let onSpawnRequest,
                   let request = SpawnRequest.parsePiDelegateTool(
                       toolName: toolName, args: args, toolUseID: toolCallId) {
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
            // `.plans/45` S2 — the detail supply. Whitelisted argument fields
            // and the provider-authored start instant go out of band; pi has no
            // Bash `description`, so a shell call carries NO field rather than
            // its command body.
            if let onRuntimeObservation {
                onRuntimeObservation(.toolDetail(itemId: toolCallId, detail: AgentToolDetailObservation(
                    phase: .started,
                    toolName: toolName,
                    fields: Self.toolDetailFields(
                        toolName: toolName, args: object["args"] as? [String: Any] ?? [:]),
                    fileChanges: Self.fileDetails(toolName: toolName, args: object["args"] as? [String: Any] ?? [:]),
                    parentItemID: (object["parentToolCallId"] as? String) ?? (object["parent_tool_call_id"] as? String),
                    observedAt: Self.timestamp(from: object) ?? now()
                )))
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
            // The `runId` that names the child's transcript on disk. Measured on
            // the wire: `result.details.runId`, alongside `details.task` — which
            // is the child's prompt body and is deliberately NOT read here.
            if let onObservedRun,
               toolName == SpawnRequest.piDelegateToolName,
               let result = object["result"] as? [String: Any],
               let details = result["details"] as? [String: Any],
               let runId = details["runId"] as? String,
               let handle = ObservedRunHandle.validated(toolUseID: toolCallId, runId: runId) {
                onObservedRun(handle)
            }
            // `.plans/45` S2 — this branch used to emit no observation at all:
            // the result text and the provider-authored end instant were both
            // parsed upstream and discarded here (C1's pi row of the table).
            if let onRuntimeObservation {
                onRuntimeObservation(.toolDetail(itemId: toolCallId, detail: AgentToolDetailObservation(
                    phase: .ended,
                    outputPreview: Self.resultPreview(object["result"]),
                    observedAt: Self.timestamp(from: object) ?? now()
                )))
            }
            var events: [AgentRuntimeEvent] = [.itemCompleted(
                threadId: threadId,
                itemId: toolCallId,
                kind: Self.itemKind(forTool: toolName),
                status: isError ? .failed : .completed
            )]
            let semantics = semanticSignalsByItemID.removeValue(forKey: toolCallId) ?? []
            if !isError {
                events += semantics.sorted { $0.rawValue < $1.rawValue }.map {
                    .semanticSignal(threadId: threadId, itemId: toolCallId, kind: $0)
                }
            }
            return events

        case "turn_end":
            recordOutcome(from: object)
            return translateUsageEvents(from: object)

        case "agent_end":
            // Current Pi follows this with agent_settled, after queued
            // continuations, automatic retry, and compaction have drained.
            // Older serialized logs ended here and omitted willRetry.
            guard object["willRetry"] == nil else { return [] }
            return finishRun()

        case "agent_settled":
            return finishRun()

        // M2 (`.plans/46`): the two rpc-only protocol frame types. The event
        // stream is the SAME function print-mode and rpc-mode both use
        // (`toJsonEvent` in `modes/json-event.js`); these two are the only
        // types rpc adds on top of it, and neither is part of the turn
        // transcript -- `response` is request/response correlation (handled
        // by `PiRpcTransport`, never reaching this translator in practice),
        // `extension_ui_request` is a UI prompt pi's own extension host
        // answers. Explicit here (rather than relying on `default:`) so the
        // ignore is a decision, not an accident of the fallthrough.
        case "response", "extension_ui_request":
            return []

        default:
            // session/user message echoes, etc.
            return []
        }
    }

    private mutating func beginRun() -> [AgentRuntimeEvent] {
        var events: [AgentRuntimeEvent] = []
        if runIsActive {
            events.append(.turnCompleted(
                threadId: threadId,
                turnId: currentTurnId,
                outcome: .interrupted,
                errorMessage: nil))
        }
        runCounter += 1
        currentTurnId = "\(threadId)#t\(runCounter)"
        runIsActive = true
        pendingRunOutcome = .completed
        pendingRunErrorMessage = nil
        events += [
            .sessionStateChanged(.running),
            .turnStarted(threadId: threadId, turnId: currentTurnId),
        ]
        return events
    }

    /// Completes exactly once, at Pi's agent-loop boundary rather than at an
    /// internal model/tool turn boundary.
    private mutating func finishRun() -> [AgentRuntimeEvent] {
        guard runIsActive else { return [.sessionStateChanged(.ready)] }
        runIsActive = false
        return [
            .turnCompleted(
                threadId: threadId,
                turnId: currentTurnId,
                outcome: pendingRunOutcome,
                errorMessage: pendingRunErrorMessage),
            .sessionStateChanged(.ready),
        ]
    }

    /// Pi places the terminal stop reason on the assistant message inside
    /// turn_end. Tool-use turns are provisional; a later internal turn replaces
    /// this value before agent_settled closes the run.
    private mutating func recordOutcome(from object: [String: Any]) {
        guard let message = object["message"] as? [String: Any],
              let rawReason = message["stopReason"] as? String
        else { return }
        switch rawReason.lowercased() {
        case "error", "failed", "failure":
            pendingRunOutcome = .failed
            pendingRunErrorMessage = rawReason
        case "aborted", "interrupted":
            pendingRunOutcome = .interrupted
            pendingRunErrorMessage = nil
        case "cancelled", "canceled":
            pendingRunOutcome = .cancelled
            pendingRunErrorMessage = nil
        default:
            pendingRunOutcome = .completed
            pendingRunErrorMessage = nil
        }
    }

    /// Convenience: translate a whole stream (e.g. a captured `.log`).
    public mutating func translate(stream lines: [String]) -> [AgentRuntimeEvent] {
        lines.flatMap { translate(line: $0) }
    }

    // MARK: - context / token telemetry

    private mutating func translateUsageEvents(from object: [String: Any]) -> [AgentRuntimeEvent] {
        guard let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return [] }

        let input = Self.intValue(usage["input"])
        let output = Self.intValue(usage["output"])
        let totalCost = (usage["cost"] as? [String: Any]).flatMap { Self.doubleValue($0["total"]) }
        let observedAt = Self.observedAt(from: message) ?? now()
        if let signature = Self.usageSignature(message: message, usage: usage) {
            guard seenUsageSignatures.insert(signature).inserted else { return [] }
        }

        var events: [AgentRuntimeEvent] = []
        if let input, let output {
            events.append(.tokenUsageUpdated(
                threadId: threadId,
                snapshot: TokenUsageSnapshot(inputTokens: input, outputTokens: output, totalCostUsd: totalCost)
            ))
        }

        let snapshot = AgentContextWindowSnapshot(
            usedTokens: nil,
            maxTokens: nil,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: Self.intValue(usage["cacheRead"]),
            cacheWriteTokens: Self.intValue(usage["cacheWrite"]),
            totalProcessedTokens: Self.intValue(usage["totalTokens"]),
            totalCostUsd: totalCost,
            automaticCompaction: nil,
            observedAt: observedAt,
            source: .piMessageUsage,
            freshness: .live
        )
        if snapshot.inputTokens != nil || snapshot.outputTokens != nil || snapshot.cacheReadTokens != nil
            || snapshot.cacheWriteTokens != nil || snapshot.totalProcessedTokens != nil || snapshot.totalCostUsd != nil {
            events.append(.contextWindowUpdated(threadId: threadId, snapshot: snapshot))
        }
        return events
    }

    private static func observedAt(from message: [String: Any]) -> Date? {
        guard let timestamp = doubleValue(message["timestamp"]) else { return nil }
        // Pi's committed fixtures carry millisecond epoch timestamps.
        return Date(timeIntervalSince1970: timestamp / 1000.0)
    }

    private static func usageSignature(message: [String: Any], usage: [String: Any]) -> String? {
        let responseId = (message["responseId"] as? String) ?? ""
        let timestamp = doubleValue(message["timestamp"]).map { String($0) } ?? ""
        guard !responseId.isEmpty || !timestamp.isEmpty else { return nil }
        let input = intValue(usage["input"]).map { String($0) } ?? ""
        let output = intValue(usage["output"]).map { String($0) } ?? ""
        let cacheRead = intValue(usage["cacheRead"]).map { String($0) } ?? ""
        let cacheWrite = intValue(usage["cacheWrite"]).map { String($0) } ?? ""
        let total = intValue(usage["totalTokens"]).map { String($0) } ?? ""
        return [responseId, timestamp, input, output, cacheRead, cacheWrite, total].joined(separator: "|")
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        case let value as Double where value.isFinite:
            return Int(value)
        default:
            return nil
        }
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let value as Double where value.isFinite:
            return value
        case let value as Int:
            return Double(value)
        case let value as NSNumber:
            return value.doubleValue.isFinite ? value.doubleValue : nil
        default:
            return nil
        }
    }

    // MARK: - message_update sub-protocol

    private mutating func translateMessageUpdate(_ object: [String: Any]) -> [AgentRuntimeEvent] {
        guard let event = object["assistantMessageEvent"] as? [String: Any],
              let subtype = event["type"] as? String else { return [] }
        switch subtype {
        case "text_delta":
            guard let delta = event["delta"] as? String, !delta.isEmpty else { return [] }
            streamedTextInCurrentMessage = true
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

    /// `.plans/45` S2 — pi's argument whitelist for `.toolDetail`, per tool
    /// per key: the query, the pattern, or the file's basename. A shell call
    /// carries NO field — pi has no `description` summary and the command body
    /// never crosses.
    private static func toolDetailFields(
        toolName: String,
        args: [String: Any]
    ) -> [(key: String, value: String)] {
        func string(_ key: String) -> String? {
            guard let value = args[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { return nil }
            return trimmed
        }
        // KEY-driven, deliberately. The first cut switched on the tool NAME and
        // returned nothing for names it did not recognise, so a pi `search`
        // whose args used any other shape rendered as the bare word "search"
        // with no query and nothing to expand. The privacy rule is about KEYS,
        // not names: these five keys may cross for ANY tool, and everything
        // else — command bodies, prompts, unknown schemas — never does.
        var fields: [(key: String, value: String)] = []
        if let query = string("query") ?? string("q") ?? string("search_query") {
            fields.append((key: "query", value: query))
        }
        if let pattern = string("pattern") ?? string("regex") {
            fields.append((key: "pattern", value: pattern))
        }
        if let url = string("url") {
            fields.append((key: "url", value: url))
        }
        if let path = string("path") ?? string("file") ?? string("file_path") {
            fields.append((key: "file", value: URL(fileURLWithPath: path).lastPathComponent))
        }
        if let description = string("description") {
            fields.append((key: "description", value: description))
        }
        return fields
    }

    private static func fileDetails(toolName: String, args: [String: Any]) -> [AgentToolDetailObservation.FileChange] {
        guard let path = (args["path"] as? String) ?? (args["file"] as? String) ?? (args["file_path"] as? String) else { return [] }
        let name = toolName.lowercased()
        let action: AgentToolDetailObservation.FileAction
        if name == "write" { action = .write }
        else if name.contains("edit") || name.contains("patch") { action = .edit }
        else { return [] }
        return [.init(action: action, path: path)]
    }

    /// A bounded preview of `result.content[].text`. Non-text blocks and
    /// unknown result shapes stay opaque.
    private static func resultPreview(_ result: Any?) -> String? {
        guard let result = result as? [String: Any],
              let content = result["content"] as? [[String: Any]] else { return nil }
        let parts = content.compactMap { block -> String? in
            guard (block["type"] as? String) == "text" else { return nil }
            return block["text"] as? String
        }
        guard !parts.isEmpty else { return nil }
        let trimmed = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The provider-authored instant on a tool event, when present. Pi stamps
    /// `ts` as ISO-8601 on some builds; absent, callers fall back to `now()`.
    /// Formatters are minted per call — `ISO8601DateFormatter` is not Sendable
    /// and tool events are rare enough that caching would buy nothing.
    private static func timestamp(from object: [String: Any]) -> Date? {
        guard let raw = object["ts"] as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
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
        // Delegation is not a command. Both pi delegation verbs bucket here:
        // Array's own inert extension tool and the third-party `delegate_agent`.
        case "spawn_agent", "delegate_agent":
            return .subagent
        default:
            return .commandExecution
        }
    }
}
