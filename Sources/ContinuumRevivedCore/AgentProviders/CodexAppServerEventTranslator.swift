import Foundation

// Ticket: codex app-server parity harness (.plans/46, "Codex — the decision,
// settled by measurement", 2026-08-24). De-risking step before any
// CodexAgentRunner rewrite: this is the PURE half of a prospective app-server
// transport, built to answer one question — does `codex app-server`'s
// JSON-RPC-over-stdio protocol carry a superset of the single-agent event
// shapes `codex exec --json` already gives `CodexEventTranslator`?
//
// It maps the app-server notification stream into the SAME `AgentRuntimeEvent`
// vocabulary the existing translator emits. `AgentRuntimeEvent` is test-pinned
// (I5) and this ticket does NOT widen it — every shape here lands on an
// existing case.
//
// SCOPE: the single-agent path only, matching `CodexEventTranslator`'s 9
// handled shapes. Multi-agent item kinds this translator can already SEE on
// the wire but does not map (`subAgentActivity`, `collabAgentToolCall`,
// `dynamicToolCall`, and others) are listed, with the measured shapes, in the
// parity report appended to `.plans/46-transcript-program-ledger.md`. Mapping
// those is the next ticket, not this one.
//
// Measured live against codex-cli 0.148.0 (ChatGPT auth, throwaway `/tmp`
// cwd, `scripts/codex-appserver-capture.py`) on 2026-08-24. Fixtures:
// `Fixtures/codex-appserver-single-agent.jsonl` (this translator's target) and
// `Fixtures/codex-appserver-delegating-turn.jsonl` (the ordering-hazard
// witness only — this translator does not attempt to map its subagent items).
//
// Three restructures from `codex exec --json`, all measured rather than
// inferred:
//   1. `agent_message`/`reasoning` STREAM real token deltas
//      (`item/agentMessage/delta`) before the item arrives whole on
//      `item/completed` — exec's "the whole reply arrives at once" comment is
//      architecturally false here. This translator emits one `contentDelta`
//      per streamed delta and does NOT re-emit the item's full text on
//      `item/completed` (that would double the text the transcript renders).
//   2. Token usage arrives as a SEPARATE `thread/tokenUsage/updated`
//      notification correlated by `threadId`/`turnId`, not inline on
//      `turn.completed`.
//   3. There is no standalone `turn.failed` frame. A failed turn folds into
//      `turn/completed` with `turn.status == "failed"` and `turn.error`
//      inline — see `translateTurnCompleted`.
//
// THE ORDERING HAZARD (measured, not hypothetical): a delegating session's
// child thread can post its `item/completed` and its own `turn/completed`
// AFTER the parent thread's `turn/completed` — 12-16s later in the captured
// fixture. This translator has NO "the run is over" flag keyed off any single
// thread's turn/completed: every method is switched on independently, keyed by
// the `threadId` the frame itself carries, so a late child frame arriving
// after the parent's terminal event translates exactly as it would if it had
// arrived first. `runCodexAppServerOrderingHazardChecks` pins this by replaying
// the delegating fixture and asserting the child's post-parent-completion
// frames still produce events (see that check's file for the naive version
// that failed RED first).
public struct CodexAppServerEventTranslator {
    /// The FIRST thread this translator observes via `thread/started` — codex
    /// app-server does not deliver its own `thread/started` for a spawned
    /// child in the captured fixtures, so "first" and "primary" coincide in
    /// every observed session.
    public private(set) var providerThreadId: String?

    /// codex app-server mints real turn ids on `turn/start`'s response and
    /// `turn/started`'s notification — unlike `codex exec --json`, nothing
    /// here needs synthesizing or salting. Kept per-thread so a child thread's
    /// turn id is never confused with the parent's.
    private var sawSessionStart = false
    private var workingDirectory: URL?
    private let now: @Sendable () -> Date

    public var onRuntimeObservation: (@Sendable (AgentRuntimeObservation) -> Void)?

    public init(
        workingDirectory: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.workingDirectory = workingDirectory?.standardizedFileURL
        self.now = now
    }

    /// Translate one JSON-RPC frame the harness/runner received on
    /// `app-server`'s stdout. Only server-originated NOTIFICATIONS carry
    /// translator-relevant content; request/response frames (the `id`-bearing
    /// replies to `thread/start`, `turn/start`, `thread/read`) are inert here
    /// — the harness reads the thread id it needs directly off the
    /// `thread/start` response, same as it reads it off `thread/started`.
    /// Unrecognised or malformed lines return [] — same drop-the-unknown
    /// discipline as `CodexEventTranslator`.
    public mutating func translate(line: String) -> [AgentRuntimeEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = object["method"] as? String,
              let params = object["params"] as? [String: Any]
        else {
            return []
        }

        switch method {
        case "thread/started":
            return translateThreadStarted(params)
        case "turn/started":
            return translateTurnStarted(params)
        case "item/started":
            return translateItemStarted(params)
        case "item/agentMessage/delta":
            return translateAgentMessageDelta(params)
        case "item/completed":
            return translateItemCompleted(params)
        case "thread/tokenUsage/updated":
            return translateTokenUsage(params)
        case "turn/completed":
            return translateTurnCompleted(params)
        default:
            // thread/status/changed, mcpServer/startupStatus/updated,
            // account/rateLimits/updated, turn/diff/updated,
            // remoteControl/status/changed, and any method a newer app-server
            // adds. None of these are part of the normalized timeline.
            return []
        }
    }

    public mutating func translate(stream lines: [String]) -> [AgentRuntimeEvent] {
        lines.flatMap { translate(line: $0) }
    }

    // MARK: - session / turn lifecycle

    private mutating func translateThreadStarted(_ params: [String: Any]) -> [AgentRuntimeEvent] {
        guard let thread = params["thread"] as? [String: Any],
              let id = thread["id"] as? String, !id.isEmpty
        else { return [] }
        // Fire session-ready/running once, on the first thread/started this
        // translator ever sees (the primary thread). A measured caveat: no
        // captured session ever delivered a SECOND thread/started for a child,
        // so there is nothing to guard against yet — recorded here rather than
        // guessed at.
        guard !sawSessionStart else { return [] }
        sawSessionStart = true
        providerThreadId = id
        onRuntimeObservation?(.threadId(id))
        return [.sessionStateChanged(.ready), .sessionStateChanged(.running)]
    }

    private func translateTurnStarted(_ params: [String: Any]) -> [AgentRuntimeEvent] {
        guard let threadId = params["threadId"] as? String,
              let turn = params["turn"] as? [String: Any],
              let turnId = turn["id"] as? String
        else { return [] }
        return [.turnStarted(threadId: threadId, turnId: turnId)]
    }

    // MARK: - items

    private func translateItemStarted(_ params: [String: Any]) -> [AgentRuntimeEvent] {
        guard let threadId = params["threadId"] as? String,
              let item = params["item"] as? [String: Any],
              let itemId = item["id"] as? String,
              let itemType = item["type"] as? String
        else { return [] }

        switch itemType {
        case "commandExecution":
            // Same I5 posture as exec: `command`/`aggregatedOutput` are the
            // sensitive payload, so the title is the generic literal "Shell",
            // never the command itself.
            if let onRuntimeObservation {
                onRuntimeObservation(.toolDetail(itemId: itemId, detail: AgentToolDetailObservation(
                    phase: .started, toolName: "Shell", observedAt: now())))
            }
            return [.itemStarted(threadId: threadId, itemId: itemId, kind: .commandExecution, title: "Shell")]

        case "fileChange":
            // `changes[].path` / `.diff` are the SAME field shape as exec's
            // `file_change` (a rename of the outer type only, camelCase vs
            // snake_case). Path projects out of band only.
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
            if let onRuntimeObservation {
                onRuntimeObservation(.toolDetail(itemId: itemId, detail: AgentToolDetailObservation(
                    phase: .started,
                    toolName: "Edit",
                    fields: changeBasenames(item).map { (key: "file", value: $0) },
                    observedAt: now()
                )))
            }
            return [.itemStarted(threadId: threadId, itemId: itemId, kind: .fileChange, title: "Edit")]

        default:
            // userMessage (our own prompt echoed back — exec has no
            // equivalent), agentMessage/reasoning (no item.started analogue in
            // exec either; content arrives via delta + item.completed), and
            // any item kind out of this ticket's single-agent scope
            // (subAgentActivity, collabAgentToolCall, dynamicToolCall, …).
            return []
        }
    }

    /// exec's whole-message `contentDelta` becomes many small deltas here —
    /// this IS the restructure, not a bug. `streamKind` follows the item's own
    /// type field on the delta frame's sibling `item/started`... but
    /// app-server's delta notification carries no item TYPE, only itemId, so
    /// this translator assumes `.assistant` for every delta observed in the
    /// single-agent fixture (reasoning never streamed a delta live — see the
    /// header note). A future ticket mapping reasoning deltas needs to track
    /// itemId -> item type from `item/started` to disambiguate.
    private func translateAgentMessageDelta(_ params: [String: Any]) -> [AgentRuntimeEvent] {
        guard let threadId = params["threadId"] as? String,
              let turnId = params["turnId"] as? String,
              let delta = params["delta"] as? String, !delta.isEmpty
        else { return [] }
        return [.contentDelta(threadId: threadId, turnId: turnId, streamKind: .assistant, delta: delta)]
    }

    private func translateItemCompleted(_ params: [String: Any]) -> [AgentRuntimeEvent] {
        guard let threadId = params["threadId"] as? String,
              let item = params["item"] as? [String: Any],
              let itemId = item["id"] as? String,
              let itemType = item["type"] as? String
        else { return [] }

        switch itemType {
        case "agentMessage":
            // The text already crossed as streamed deltas (restructure #1) —
            // re-emitting the whole `item.text` here would double it in the
            // transcript. Nothing to do.
            return []

        case "commandExecution":
            let exitCode = Self.intValue(item["exitCode"])
            if let onRuntimeObservation {
                let output = (item["aggregatedOutput"] as? String)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .flatMap { $0.isEmpty ? nil : $0 }
                onRuntimeObservation(.toolDetail(itemId: itemId, detail: AgentToolDetailObservation(
                    phase: .ended,
                    outputPreview: output,
                    exitCode: exitCode,
                    observedAt: now())))
            }
            return [.itemCompleted(
                threadId: threadId,
                itemId: itemId,
                kind: .commandExecution,
                status: exitCode == 0 ? .completed : .failed)]

        case "fileChange":
            let ok = (item["status"] as? String) == "completed"
            if let onRuntimeObservation {
                onRuntimeObservation(.toolDetail(itemId: itemId, detail: AgentToolDetailObservation(
                    phase: .ended, observedAt: now())))
            }
            return [.itemCompleted(
                threadId: threadId,
                itemId: itemId,
                kind: .fileChange,
                status: ok ? .completed : .failed)]

        default:
            return []
        }
    }

    // MARK: - token usage

    /// A SEPARATE notification (restructure #2), correlated by
    /// `threadId`/`turnId` rather than riding `turn.completed`. `total` is the
    /// cumulative-for-session figure — the same accounting semantics
    /// `CodexEventTranslator` reads off exec's `turn.completed.usage`, so this
    /// maps to the identical `TokenUsageSnapshot`. `last` (this request's own
    /// tokens) and `modelContextWindow` are NOT mapped here — exact occupancy
    /// stays out of this ticket's scope; noted as a measured OPPORTUNITY in the
    /// parity report, not implemented.
    private func translateTokenUsage(_ params: [String: Any]) -> [AgentRuntimeEvent] {
        guard let threadId = params["threadId"] as? String,
              let usage = params["tokenUsage"] as? [String: Any],
              let total = usage["total"] as? [String: Any]
        else { return [] }
        let input = Self.intValue(total["inputTokens"])
        let output = Self.intValue(total["outputTokens"])
        let sum = (input ?? 0) + (output ?? 0)
        guard sum > 0 else { return [] }
        return [.tokenUsageUpdated(
            threadId: threadId,
            snapshot: TokenUsageSnapshot(inputTokens: input ?? 0, outputTokens: output ?? 0, totalCostUsd: nil))]
    }

    // MARK: - turn completion

    /// No standalone `turn.failed` frame exists on app-server (restructure
    /// #3): a failed turn folds into `turn/completed` with `turn.status ==
    /// "failed"` and `turn.error` populated inline. Mirrors exec's I5 posture
    /// — `errorMessage` is a short code only, never the error body (which can
    /// quote tool output or model text).
    private func translateTurnCompleted(_ params: [String: Any]) -> [AgentRuntimeEvent] {
        guard let threadId = params["threadId"] as? String,
              let turn = params["turn"] as? [String: Any],
              let turnId = turn["id"] as? String
        else { return [] }
        let failed = (turn["status"] as? String) == "failed"
        var code: String?
        if failed, let error = turn["error"] as? [String: Any] {
            code = (error["code"] as? String) ?? (error["type"] as? String)
        }
        return [
            .turnCompleted(threadId: threadId, turnId: turnId, outcome: failed ? .failed : .completed, errorMessage: code),
            .sessionStateChanged(.ready),
        ]
    }

    // MARK: - helpers

    private func firstChangePath(_ item: [String: Any]) -> String? {
        guard let changes = item["changes"] as? [[String: Any]] else { return nil }
        return changes.lazy.compactMap { $0["path"] as? String }.first
    }

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
