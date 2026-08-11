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
    private var threadId: String = "codex-unknown"
    private let runToken: String
    private var turnCounter: Int = 0
    private var currentTurnId: String
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

        case "token_count":
            return tokenCountEvents(object)

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

    private func translateItemStarted(_ object: [String: Any]) -> [AgentRuntimeEvent] {
        guard let item = object["item"] as? [String: Any],
              let rawId = item["id"] as? String,
              let itemType = item["type"] as? String
        else { return [] }
        let itemId = saltedItemId(rawId)
        switch itemType {
        case "command_execution":
            // DROP `command` + `aggregated_output` (I5): the command is the
            // sensitive payload, so the title is a generic literal, NOT the
            // command (unlike claude, whose tool NAME is the safe title).
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
            return [.itemStarted(threadId: threadId, itemId: itemId, kind: .fileChange, title: "Edit")]

        default:
            // reasoning/agent_message have no item.started; mcp_tool_call /
            // web_search / todo_list are not surfaced yet — inert.
            return []
        }
    }

    private func translateItemCompleted(_ object: [String: Any]) -> [AgentRuntimeEvent] {
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
            let succeeded = Self.intValue(item["exit_code"]) == 0
            return [.itemCompleted(
                threadId: threadId,
                itemId: saltedItemId(rawId),
                kind: .commandExecution,
                status: succeeded ? .completed : .failed)]

        case "file_change":
            guard let rawId = item["id"] as? String else { return [] }
            let ok = (item["status"] as? String) == "completed"
            return [.itemCompleted(
                threadId: threadId,
                itemId: saltedItemId(rawId),
                kind: .fileChange,
                status: ok ? .completed : .failed)]

        default:
            return []
        }
    }

    // MARK: - turn completion

    private func translateTurnCompleted(_ object: [String: Any]) -> [AgentRuntimeEvent] {
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

    private func translateTurnFailed(_ object: [String: Any]) -> [AgentRuntimeEvent] {
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

    /// codex `token_count`, which arrives **DURING** a turn, repeatedly, and is
    /// the only honest source for "how full is the context right now".
    ///
    /// THREE THINGS THIS GETS RIGHT THAT `turn.completed.usage` CANNOT
    /// (measured against a real rollout in `~/.codex/sessions`, after the meter
    /// was observed reading 237%):
    ///
    ///   1. `last_token_usage` is THIS request; `total_token_usage` is the whole
    ///      session added up. The context holds the former. Reading the latter
    ///      makes the meter climb past 100% and never come down — 643,673
    ///      cumulative input against a 272,000 window is where 237% came from.
    ///   2. `model_context_window` is the provider's own number (258,400 for
    ///      gpt-5.6-sol) and it disagrees with pi's catalogue (272,000). The
    ///      provider running the turn is the authority on its own window.
    ///   3. It is emitted mid-turn, so the ring fills while the agent works
    ///      instead of jumping once the turn ends.
    ///
    /// `usedTokens` is `last.total_tokens` (prompt + completion): the next
    /// request carries this turn's output back in as input, so it is the closest
    /// thing to "what the model is about to be handed".
    private func tokenCountEvents(_ object: [String: Any]) -> [AgentRuntimeEvent] {
        guard let info = object["info"] as? [String: Any] else { return [] }
        let last = info["last_token_usage"] as? [String: Any]
        let total = info["total_token_usage"] as? [String: Any]
        // Prefer the per-request block; a `token_count` without one is not worth
        // guessing at, because the only other number available is cumulative.
        guard let last else { return [] }
        let used = Self.intValue(last["total_tokens"])
        let input = Self.intValue(last["input_tokens"])
        let output = Self.intValue(last["output_tokens"])
        let window = Self.intValue(info["model_context_window"])
        guard (used ?? 0) > 0 else { return [] }
        var events: [AgentRuntimeEvent] = []
        // Cost/usage accounting still wants the SESSION total — that is a
        // different question from occupancy and the cumulative number is the
        // right answer to it.
        if let total, let totalInput = Self.intValue(total["input_tokens"]) {
            events.append(.tokenUsageUpdated(
                threadId: threadId,
                snapshot: TokenUsageSnapshot(
                    inputTokens: totalInput,
                    outputTokens: Self.intValue(total["output_tokens"]) ?? 0,
                    totalCostUsd: nil)))
        }
        events.append(.contextWindowUpdated(
            threadId: threadId,
            snapshot: AgentContextWindowSnapshot(
                usedTokens: used,
                maxTokens: window,
                inputTokens: input,
                outputTokens: output,
                cacheReadTokens: Self.intValue(last["cached_input_tokens"]),
                cacheWriteTokens: Self.intValue(last["cache_write_input_tokens"]),
                totalProcessedTokens: used,
                totalCostUsd: nil,
                automaticCompaction: nil,
                observedAt: now(),
                source: .codexTurnUsage,
                freshness: .live)))
        return events
    }

    /// codex `turn.completed.usage`. **Token semantics differ from claude:**
    /// `input_tokens` is already the TOTAL prompt tokens and `cached_input_tokens`
    /// is a SUBSET of it (OpenAI convention) — do NOT sum, or you double-count.
    /// No cost field (subscription, not metered) → `totalCostUsd = nil`. A
    /// zero-token block publishes nothing (don't clobber real telemetry).
    ///
    /// THIS BLOCK IS CUMULATIVE and therefore never sets `usedTokens`: it is the
    /// session's running total, not what is in the context. `token_count` above
    /// is what fills the meter; this stays for the turn-end cost/usage summary
    /// and for a codex build that emits no `token_count` at all.
    private func usageEvents(_ raw: Any?) -> [AgentRuntimeEvent] {
        guard let usage = raw as? [String: Any] else { return [] }
        let input = Self.intValue(usage["input_tokens"])
        let output = Self.intValue(usage["output_tokens"])
        let cacheRead = Self.intValue(usage["cached_input_tokens"])
        let cacheWrite = Self.intValue(usage["cache_write_input_tokens"])
        let total = (input ?? 0) + (output ?? 0)
        guard total > 0 else { return [] }
        return [
            .tokenUsageUpdated(
                threadId: threadId,
                snapshot: TokenUsageSnapshot(
                    inputTokens: input ?? 0,
                    outputTokens: output ?? 0,
                    totalCostUsd: nil)),
            .contextWindowUpdated(
                threadId: threadId,
                snapshot: AgentContextWindowSnapshot(
                    usedTokens: nil,
                    maxTokens: nil,
                    inputTokens: input,
                    outputTokens: output,
                    cacheReadTokens: cacheRead,
                    cacheWriteTokens: cacheWrite,
                    totalProcessedTokens: total,
                    totalCostUsd: nil,
                    automaticCompaction: nil,
                    observedAt: now(),
                    source: .codexTurnUsage,
                    freshness: .live)),
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
