import Foundation

// Plan: .plans/02-codex-backend-and-toggle.md (codex CLI backend).
//
// The PURE half of the codex adapter. Translates `codex exec --json` JSONL
// (verified live against codex-cli 0.145.0 on 2026-08-09/10) into the normalized
// `AgentRuntimeEvent` the managed-agent tile already consumes. No process
// management here (that is CodexAgentRunner, the impure half) — line-in →
// events-out, exhaustively pinned in the matrix against the captured schema.
//
// codex's exec event vocabulary is high-level and much simpler than claude's raw
// stream-json: `thread.started / turn.started / turn.completed / turn.failed /
// item.started / item.updated / item.completed`, with item types `agent_message,
// reasoning, command_execution, file_change, mcp_tool_call, web_search,
// todo_list`.
//
// I5 by construction, same as the pi/claude translators: `AgentRuntimeEvent` has
// no field for a command, a tool output, or a path, so mapping into it DROPS
// codex's sensitive payloads (`command`, `aggregated_output`, `file_change`
// paths). A command_execution's generic title is the literal "Shell" — the
// command itself is the payload and must never become the title (this differs
// from claude, where the tool NAME is the safe title). Paths reach the host only
// through `onRuntimeObservation`, never an event. Proven in
// `runCodexAgentBackendChecks`.
//
// The one hard difference from claude: codex mints its own `thread_id` (no flag
// to set it), so continuity is STORED. The id is captured on `thread.started`
// and fired on the observation side channel (`.threadId`) — NOT on an event,
// because the supervisor rebinds every event's threadId before delivery. The
// supervisor persists it to `AgentRecord.codexThreadId`.
//
// codex item ids restart at `item_0` every process, so across turns (each a
// separate process) they would collide — they are salted with a per-process
// `runToken`. Turn ids are salted for the same reason (the thread id is stable
// across processes, like claude's).
public struct CodexEventTranslator {
    public private(set) var providerThreadId: String?
    private var threadId: String = "codex-unknown"
    private let runToken: String
    private var turnCounter: Int = 0
    private var currentTurnId: String
    private var semanticSignalsByItemID: [String: Set<AgentSemanticSignalKind>] = [:]
    private var workingDirectory: URL?
    private let now: @Sendable () -> Date

    /// Same host-local side channel as the pi/claude translators': an explicit
    /// runtime cwd, a whitelisted operation/path projection, and (codex-only)
    /// the captured thread id — never the raw args. Fires on the translator's
    /// owner queue before the matching normalized event is returned.
    public var onRuntimeObservation: (@Sendable (AgentRuntimeObservation) -> Void)?

    public init(
        workingDirectory: URL? = nil,
        runToken: String = UUID().uuidString.lowercased().prefix(8).description,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.workingDirectory = workingDirectory?.standardizedFileURL
        self.runToken = runToken
        self.now = now
        self.currentTurnId = "codex-unknown#\(runToken)-t0"
    }

    /// Translate one line of `codex exec --json` output into zero or more
    /// normalized events. Unrecognised lines and item types return [] (inert,
    /// never a crash) — the same drop-the-unknown discipline as the other
    /// translators.
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
        case "thread.started":
            // Codex mints the thread id here (and re-fires the SAME id on
            // resume). Capture it, set the internal thread id, and project it
            // out of band so the supervisor persists it — it cannot ride an
            // event (threadIds are rebound before delivery). No turn yet.
            if let id = object["thread_id"] as? String, !id.isEmpty {
                threadId = id
                providerThreadId = id
                onRuntimeObservation?(.threadId(id))
            }
            return [.sessionStateChanged(.ready), .sessionStateChanged(.running)]

        case "turn.started":
            turnCounter += 1
            currentTurnId = "\(threadId)#\(runToken)-t\(turnCounter)"
            return [.turnStarted(threadId: threadId, turnId: currentTurnId)]

        case "item.started":
            return translateItemStarted(object)

        case "item.completed":
            return translateItemCompleted(object)

        case "turn.completed":
            return translateTurnCompleted(object)

        case "turn.failed":
            return translateTurnFailed(object)

        default:
            // item.updated, and any event the normalized timeline does not need.
            return []
        }
    }

    /// Convenience: translate a whole stream (e.g. a captured fixture).
    public mutating func translate(stream lines: [String]) -> [AgentRuntimeEvent] {
        lines.flatMap { translate(line: $0) }
    }

    // MARK: - items

    private mutating func translateItemStarted(_ object: [String: Any]) -> [AgentRuntimeEvent] {
        guard let item = object["item"] as? [String: Any],
              let rawId = item["id"] as? String,
              let itemType = item["type"] as? String
        else { return [] }
        let itemId = saltedItemId(rawId)
        switch itemType {
        case "command_execution":
            if let command = item["command"] as? String {
                let signals = AgentGitOperationClassifier.operations(in: command)
                if !signals.isEmpty { semanticSignalsByItemID[itemId] = signals }
            }
            // DROP `command` + `aggregated_output` (I5): the command is the
            // sensitive payload, so the title is a generic literal, NOT the
            // command (unlike claude, whose tool NAME is the safe title).
            // `.plans/45` S2 — the start instant rides the side channel so the
            // row can show a duration; codex offers no safe argument summary.
            if let onRuntimeObservation {
                onRuntimeObservation(.toolDetail(itemId: itemId, detail: AgentToolDetailObservation(
                    phase: .started, toolName: "Shell", observedAt: now())))
            }
            return [.itemStarted(threadId: threadId, itemId: itemId, kind: .commandExecution, title: "Shell")]

        case "file_change":
            // The edited path projects out of band only; the event carries the
            // generic title.
            if let onRuntimeObservation,
               let path = firstChangePath(item),
               let target = Self.resolvedTarget(path, workingDirectory: workingDirectory) {
                onRuntimeObservation(.toolActivity(
                    itemId: itemId,
                    activity: AgentObservedActivity(
                        operation: .editing,
                        targetPath: target,
                        startedAt: now(),
                        updatedAt: now(),
                        evidenceSource: .toolEvent)))
            }
            // `.plans/45` S2 — ALL changed basenames, not just changes[0]
            // (C1's codex row). Basenames only; full paths stay on the
            // activity channel above.
            if let onRuntimeObservation {
                onRuntimeObservation(.toolDetail(itemId: itemId, detail: AgentToolDetailObservation(
                    phase: .started,
                    toolName: "Edit",
                    fields: changeBasenames(item).map { (key: "file", value: $0) },
                    observedAt: now()
                )))
            }
            return [.itemStarted(threadId: threadId, itemId: itemId, kind: .fileChange, title: "Edit")]

        case "mcp_tool_call":
            // `.plans/45` S2 — previously swallowed: an MCP call produced NO
            // row at all. The tool and server names are identifiers, not
            // payload; arguments stay opaque.
            let tool = (item["tool"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let title = tool ?? "MCP tool"
            if let onRuntimeObservation {
                let server = (item["server"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                onRuntimeObservation(.toolDetail(itemId: itemId, detail: AgentToolDetailObservation(
                    phase: .started,
                    toolName: title,
                    fields: server.map { [(key: "server", value: $0)] } ?? [],
                    observedAt: now()
                )))
            }
            return [.itemStarted(threadId: threadId, itemId: itemId, kind: .mcpToolCall, title: title)]

        case "web_search":
            // `.plans/45` S2 — previously swallowed. The query is the same
            // whitelisted key claude carries.
            if let onRuntimeObservation {
                let query = (item["query"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                onRuntimeObservation(.toolDetail(itemId: itemId, detail: AgentToolDetailObservation(
                    phase: .started,
                    toolName: "Web search",
                    fields: query.map { [(key: "query", value: $0)] } ?? [],
                    observedAt: now()
                )))
            }
            return [.itemStarted(threadId: threadId, itemId: itemId, kind: .webSearch, title: "Web search")]

        case "todo_list":
            // `.plans/45` S2 — previously swallowed. Item contents (the todo
            // text) stay out; the row just exists now.
            return [.itemStarted(threadId: threadId, itemId: itemId, kind: .plan, title: "Plan")]

        default:
            // reasoning/agent_message have no item.started.
            return []
        }
    }

    private mutating func translateItemCompleted(_ object: [String: Any]) -> [AgentRuntimeEvent] {
        guard let item = object["item"] as? [String: Any],
              let itemType = item["type"] as? String
        else { return [] }
        switch itemType {
        case "agent_message":
            // The WHOLE reply arrives at once (no token streaming in exec
            // --json). Emit the full text as one delta — it IS the user-facing
            // reply, I5-safe to surface like claude's text_delta. `agent_message`
            // is atomic: no item.started for it.
            guard turnCounter > 0, let text = item["text"] as? String, !text.isEmpty else { return [] }
            return [.contentDelta(threadId: threadId, turnId: currentTurnId, streamKind: .assistant, delta: text)]

        case "reasoning":
            // Analogous to claude's thinking_delta. Not observed live in exec
            // --json today (reasoning is counted in usage, not surfaced as an
            // item), but pinned defensively against codex's own item vocabulary.
            guard turnCounter > 0, let text = item["text"] as? String, !text.isEmpty else { return [] }
            return [.contentDelta(threadId: threadId, turnId: currentTurnId, streamKind: .reasoning, delta: text)]

        case "command_execution":
            guard let rawId = item["id"] as? String else { return [] }
            let itemID = saltedItemId(rawId)
            let exitCode = Self.intValue(item["exit_code"])
            // `.plans/45` S2 — the integer exit code (not just its zero-ness)
            // and a bounded output preview ride the side channel for the
            // expanded pane. The event still carries only pass/fail.
            if let onRuntimeObservation {
                let output = (item["aggregated_output"] as? String)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .flatMap { $0.isEmpty ? nil : $0 }
                onRuntimeObservation(.toolDetail(itemId: itemID, detail: AgentToolDetailObservation(
                    phase: .ended,
                    outputPreview: output,
                    exitCode: exitCode,
                    observedAt: now()
                )))
            }
            var events: [AgentRuntimeEvent] = [.itemCompleted(
                threadId: threadId,
                itemId: itemID,
                kind: .commandExecution,
                status: exitCode == 0 ? .completed : .failed)]
            let semantics = semanticSignalsByItemID.removeValue(forKey: itemID) ?? []
            if exitCode == 0 {
                events += semantics.sorted { $0.rawValue < $1.rawValue }.map {
                    .semanticSignal(threadId: threadId, itemId: itemID, kind: $0)
                }
            }
            return events

        case "file_change":
            guard let rawId = item["id"] as? String else { return [] }
            let ok = (item["status"] as? String) == "completed"
            // `.plans/45` S2 — an end instant so the row can show a duration;
            // a file change has no output to preview.
            if let onRuntimeObservation {
                onRuntimeObservation(.toolDetail(itemId: saltedItemId(rawId), detail: AgentToolDetailObservation(
                    phase: .ended, observedAt: now())))
            }
            return [.itemCompleted(
                threadId: threadId,
                itemId: saltedItemId(rawId),
                kind: .fileChange,
                status: ok ? .completed : .failed)]

        case "mcp_tool_call", "web_search", "todo_list":
            // `.plans/45` S2 — previously swallowed alongside their starts.
            guard let rawId = item["id"] as? String else { return [] }
            let kind: ItemKind = itemType == "mcp_tool_call" ? .mcpToolCall
                : itemType == "web_search" ? .webSearch : .plan
            let failed = (item["status"] as? String) == "failed"
            if let onRuntimeObservation {
                onRuntimeObservation(.toolDetail(itemId: saltedItemId(rawId), detail: AgentToolDetailObservation(
                    phase: .ended, observedAt: now())))
            }
            return [.itemCompleted(
                threadId: threadId,
                itemId: saltedItemId(rawId),
                kind: kind,
                status: failed ? .failed : .completed)]

        default:
            return []
        }
    }

    // MARK: - turn completion

    private mutating func translateTurnCompleted(_ object: [String: Any]) -> [AgentRuntimeEvent] {
        // A turn.completed before any turn.started is the shape a failed resume
        // would leave; emitting a completion for a turn that never began would
        // paint a spurious card. Mirror the claude gate.
        guard turnCounter > 0 else { return [] }
        var events: [AgentRuntimeEvent] = usageEvents(object["usage"])
        events.append(.turnCompleted(
            threadId: threadId, turnId: currentTurnId, outcome: .completed, errorMessage: nil))
        events.append(.sessionStateChanged(.ready))
        return events
    }

    private mutating func translateTurnFailed(_ object: [String: Any]) -> [AgentRuntimeEvent] {
        guard turnCounter > 0 else { return [] }
        // errorMessage is a short code/subtype only, NEVER the error body — the
        // body can quote tool output or model text (I5). Launch/auth failures
        // don't reach here at all: the runner surfaces those from exit+stderr.
        var code: String?
        if let error = object["error"] as? [String: Any] {
            code = (error["code"] as? String) ?? (error["type"] as? String)
        }
        var events: [AgentRuntimeEvent] = usageEvents(object["usage"])
        events.append(.turnCompleted(
            threadId: threadId, turnId: currentTurnId, outcome: .failed, errorMessage: code))
        events.append(.sessionStateChanged(.ready))
        return events
    }

    /// codex `turn.completed.usage` — the ONLY usage the `codex exec --json`
    /// stream carries. (Its whole event vocabulary is `thread.started`,
    /// `turn.started`, `item.completed`, `turn.completed`; captured from the real
    /// CLI. codex's own rollout log under `~/.codex/sessions` additionally has a
    /// live `token_count` with per-request figures and `model_context_window`,
    /// but that file is not this stream, and a handler for it here fires never.)
    ///
    /// **Token semantics differ from claude:** `input_tokens` is already the
    /// TOTAL prompt tokens and `cached_input_tokens` is a SUBSET of it (OpenAI
    /// convention) — do NOT sum, or you double-count. No cost field
    /// (subscription, not metered) → `totalCostUsd = nil`. A zero-token block
    /// publishes nothing (don't clobber real telemetry).
    ///
    /// **AND IT IS CUMULATIVE FOR THE SESSION.** It remains useful for the row's
    /// accounting total, but never emits context occupancy. Exact occupancy is
    /// joined by `CodexAgentRunner` from the rollout log after process exit.
    private func usageEvents(_ raw: Any?) -> [AgentRuntimeEvent] {
        guard let usage = raw as? [String: Any] else { return [] }
        let input = Self.intValue(usage["input_tokens"])
        let output = Self.intValue(usage["output_tokens"])
        let total = (input ?? 0) + (output ?? 0)
        guard total > 0 else { return [] }
        return [
            .tokenUsageUpdated(
                threadId: threadId,
                snapshot: TokenUsageSnapshot(
                    inputTokens: input ?? 0,
                    outputTokens: output ?? 0,
                    totalCostUsd: nil)),
        ]
    }

    // MARK: - helpers

    /// codex item ids restart at `item_0` every process; salt with the
    /// per-process token so ids from separate turns never collide.
    private func saltedItemId(_ rawId: String) -> String {
        "\(runToken)-\(rawId)"
    }

    private func firstChangePath(_ item: [String: Any]) -> String? {
        guard let changes = item["changes"] as? [[String: Any]] else { return nil }
        return changes.lazy.compactMap { $0["path"] as? String }.first
    }

    /// `.plans/45` S2 — every changed file's basename, for the detail fields.
    /// The observation's own field cap bounds the list.
    private func changeBasenames(_ item: [String: Any]) -> [String] {
        guard let changes = item["changes"] as? [[String: Any]] else { return [] }
        return changes.compactMap { change in
            guard let path = change["path"] as? String,
                  !path.isEmpty,
                  !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { return nil }
            return URL(fileURLWithPath: path).lastPathComponent
        }
    }

    private static let maximumObservedPathBytes = 4_096

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
}
