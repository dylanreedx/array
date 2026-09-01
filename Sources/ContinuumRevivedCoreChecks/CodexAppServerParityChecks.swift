import ContinuumRevivedCore
import Foundation

// Ticket: codex app-server parity harness (.plans/46, "Codex — the decision,
// settled by measurement", 2026-08-24). This file is the witness half of the
// de-risking step: it does NOT touch `CodexAgentRunner` or `CodexEventTranslator`
// (both read-only for this ticket) and does not widen `AgentRuntimeEvent`.
//
// Three things pinned here:
//   1. `CodexAppServerEventTranslator`'s own frame → event mapping, I5-safe by
//      construction, against synthetic app-server JSON-RPC lines shaped exactly
//      like the real ones captured by `scripts/codex-appserver-capture.py`
//      (codex-cli 0.148.0, 2026-08-24).
//   2. Single-agent PARITY: replaying `Fixtures/codex-appserver-single-agent.jsonl`
//      through `CodexAppServerEventTranslator` and
//      `Fixtures/codex-exec-single-agent-parity.jsonl` (the SAME two-step task —
//      run a shell command, then edit a file — captured separately through
//      `codex exec --json`) through the existing `CodexEventTranslator` produce
//      the same STRUCTURAL event shape. "Same structural shape" is defined
//      precisely by `normalizedShape` below: session/turn/item event kinds must
//      match exactly; consecutive `contentDelta`s collapse to one content block
//      each (app-server STREAMS text where exec delivers it whole — restructure
//      #1, not a mismatch); `tokenUsageUpdated` is checked for PRESENCE on both
//      sides rather than exact count, because app-server publishes usage after
//      every tool call while exec bundles it once on `turn.completed`
//      (restructure #2). Both differences are the measured restructures in the
//      parity report appended to `.plans/46-transcript-program-ledger.md`, not
//      translator bugs.
//   3. The ORDERING HAZARD: replaying `Fixtures/codex-appserver-delegating-turn.jsonl`
//      (a real capture — the child's `item/completed` and `turn/completed` land
//      12-16s after the PARENT's `turn/completed`) through a deliberately naive
//      wrapper that gates on "primary thread's turn/completed = session over"
//      (mirroring `CodexAgentRunner.emit()`'s terminal-event gate, per the
//      ledger) proves that naive shape drops the child's events — RED. The real
//      `CodexAppServerEventTranslator` has no such gate and is asserted to keep
//      producing events for the child thread after the parent's terminal event
//      — GREEN.
func runCodexAppServerParityChecks() {
    runCodexAppServerTranslatorMappingChecks()
    runCodexAppServerSingleAgentParityChecks()
    runCodexAppServerOrderingHazardChecks()
}

// MARK: - 1. mapping pins

private func runCodexAppServerTranslatorMappingChecks() {
    var translator = CodexAppServerEventTranslator()

    // thread/started mints the provider thread id and opens the session —
    // exactly like exec's thread.started, just carried on a notification
    // envelope instead of a flat object.
    let started = translator.translate(line: #"""
        {"jsonrpc":"2.0","method":"thread/started","params":{"thread":{"id":"th-SECRET-THREAD"}}}
        """#)
    expect(started == [.sessionStateChanged(.ready), .sessionStateChanged(.running)],
           "thread/started must open the session exactly like exec's thread.started")
    expect(translator.providerThreadId == "th-SECRET-THREAD",
           "the provider thread id must be captured for the runtime observation side channel")

    // A second thread/started (a hypothetical child notification — never
    // observed live, but must not be able to re-fire session-open events)
    // is a no-op.
    let secondStart = translator.translate(line: #"""
        {"jsonrpc":"2.0","method":"thread/started","params":{"thread":{"id":"th-child"}}}
        """#)
    expect(secondStart.isEmpty, "a second thread/started must not re-fire session-open events")

    let turnStarted = translator.translate(line: #"""
        {"jsonrpc":"2.0","method":"turn/started","params":{"threadId":"th-SECRET-THREAD","turn":{"id":"turn-1"}}}
        """#)
    expect(turnStarted == [.turnStarted(threadId: "th-SECRET-THREAD", turnId: "turn-1")],
           "turn/started must carry the SERVER's own turn id — nothing to salt, unlike exec")

    // command_execution -> commandExecution: I5 posture identical to exec —
    // command/aggregatedOutput never cross, the title is the generic "Shell".
    final class ObservationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [AgentRuntimeObservation] = []
        func append(_ observation: AgentRuntimeObservation) { lock.withLock { stored.append(observation) } }
        func snapshot() -> [AgentRuntimeObservation] { lock.withLock { stored } }
    }
    let observationBox = ObservationBox()
    translator.onRuntimeObservation = { observationBox.append($0) }

    let cmdStart = translator.translate(line: #"""
        {"jsonrpc":"2.0","method":"item/started","params":{"threadId":"th-SECRET-THREAD","turnId":"turn-1","item":{"id":"exec-1","type":"commandExecution","command":"echo SECRET-COMMAND","aggregatedOutput":null,"exitCode":null,"status":"inProgress"}}}
        """#)
    expect(cmdStart == [.itemStarted(threadId: "th-SECRET-THREAD", itemId: "exec-1", kind: .commandExecution, title: "Shell")],
           "commandExecution item/started must map to itemStarted(.commandExecution, \"Shell\")")

    let cmdEnd = translator.translate(line: #"""
        {"jsonrpc":"2.0","method":"item/completed","params":{"threadId":"th-SECRET-THREAD","turnId":"turn-1","item":{"id":"exec-1","type":"commandExecution","command":"echo SECRET-COMMAND","aggregatedOutput":"SECRET-OUTPUT\n","exitCode":0,"status":"completed"}}}
        """#)
    expect(cmdEnd == [.itemCompleted(threadId: "th-SECRET-THREAD", itemId: "exec-1", kind: .commandExecution, status: .completed)],
           "a zero-exit commandExecution item/completed must map to .completed")

    // agent_message stream: item/started is inert (exec has no analogue
    // either); each delta becomes its own contentDelta; item/completed does
    // NOT re-emit the text (it already crossed as deltas — this is
    // restructure #1, and double-emitting here would double the transcript).
    let msgStart = translator.translate(line: #"""
        {"jsonrpc":"2.0","method":"item/started","params":{"threadId":"th-SECRET-THREAD","turnId":"turn-1","item":{"id":"msg-1","type":"agentMessage","text":"","phase":"final_answer"}}}
        """#)
    expect(msgStart.isEmpty, "agentMessage item/started has no exec analogue and must be inert")

    let delta1 = translator.translate(line: #"""
        {"jsonrpc":"2.0","method":"item/agentMessage/delta","params":{"threadId":"th-SECRET-THREAD","turnId":"turn-1","itemId":"msg-1","delta":"Hello"}}
        """#)
    expect(delta1 == [.contentDelta(threadId: "th-SECRET-THREAD", turnId: "turn-1", streamKind: .assistant, delta: "Hello")],
           "item/agentMessage/delta must map to one contentDelta per delta — the streaming restructure")

    let msgEnd = translator.translate(line: #"""
        {"jsonrpc":"2.0","method":"item/completed","params":{"threadId":"th-SECRET-THREAD","turnId":"turn-1","item":{"id":"msg-1","type":"agentMessage","text":"Hello","phase":"final_answer"}}}
        """#)
    expect(msgEnd.isEmpty, "agentMessage item/completed must not re-emit text already streamed as deltas")

    // fileChange: same `changes[].path` shape as exec's file_change, generic
    // "Edit" title, path stays out of band.
    let fileStart = translator.translate(line: #"""
        {"jsonrpc":"2.0","method":"item/started","params":{"threadId":"th-SECRET-THREAD","turnId":"turn-1","item":{"id":"exec-2","type":"fileChange","changes":[{"path":"/tmp/SECRET-PATH/note.txt","kind":{"type":"add"},"diff":"SECRET-DIFF"}],"status":"inProgress"}}}
        """#)
    expect(fileStart == [.itemStarted(threadId: "th-SECRET-THREAD", itemId: "exec-2", kind: .fileChange, title: "Edit")],
           "fileChange item/started must map to itemStarted(.fileChange, \"Edit\")")
    let fileEnd = translator.translate(line: #"""
        {"jsonrpc":"2.0","method":"item/completed","params":{"threadId":"th-SECRET-THREAD","turnId":"turn-1","item":{"id":"exec-2","type":"fileChange","changes":[{"path":"/tmp/SECRET-PATH/note.txt","kind":{"type":"add"},"diff":"SECRET-DIFF"}],"status":"completed"}}}
        """#)
    expect(fileEnd == [.itemCompleted(threadId: "th-SECRET-THREAD", itemId: "exec-2", kind: .fileChange, status: .completed)],
           "a completed fileChange item/completed must map to .completed")
    _ = translator.translate(line: #"""
        {"jsonrpc":"2.0","method":"item/started","params":{"threadId":"th-SECRET-THREAD","turnId":"turn-1","item":{"id":"hostile-files","type":"fileChange","changes":[{"path":"C:\\Users\\Alice\\Secrets\\token.txt","kind":{"type":"update"},"diff":"+ Authorization: Bearer appserver-secret\n+ /Users/alice/private"},{"path":"Sources/AppServerSafe.swift","kind":{"type":"update"},"diff":"+safe"}],"status":"inProgress"}}}
        """#)
    let hostileDetails = observationBox.snapshot().compactMap { observation -> AgentToolDetailObservation? in
        guard case let .toolDetail(itemId, detail) = observation, itemId == "hostile-files" else { return nil }
        return detail
    }.flatMap(\.fileChanges)
    let hostileSurface = hostileDetails.map { [$0.path, $0.renamePath ?? "", $0.diffPreview ?? ""].joined(separator: "\n") }.joined(separator: "\n")
    expect(!hostileSurface.contains("Alice") && !hostileSurface.contains("appserver-secret")
        && !hostileSurface.contains("/Users/") && hostileSurface.contains("AppServerSafe.swift"),
        "Codex app-server hostile file facts must be safe at raw construction: \(hostileSurface)")

    // thread/tokenUsage/updated: the separate-notification restructure (#2).
    // `total` is the cumulative accounting figure — same semantics as exec's
    // turn.completed.usage.
    let usage = translator.translate(line: #"""
        {"jsonrpc":"2.0","method":"thread/tokenUsage/updated","params":{"threadId":"th-SECRET-THREAD","turnId":"turn-1","tokenUsage":{"total":{"inputTokens":100,"outputTokens":20},"last":{"inputTokens":100,"outputTokens":20},"modelContextWindow":200000}}}
        """#)
    expect(usage == [.tokenUsageUpdated(threadId: "th-SECRET-THREAD", snapshot: TokenUsageSnapshot(inputTokens: 100, outputTokens: 20, totalCostUsd: nil))],
           "thread/tokenUsage/updated must map to tokenUsageUpdated off the cumulative `total` block")

    // turn/completed: no standalone turn.failed frame exists — a failure
    // folds into turn/completed with turn.status == "failed" and turn.error
    // inline (restructure #3). errorMessage is the short code only, never
    // the body (I5).
    let ok = translator.translate(line: #"""
        {"jsonrpc":"2.0","method":"turn/completed","params":{"threadId":"th-SECRET-THREAD","turn":{"id":"turn-1","status":"completed","error":null}}}
        """#)
    expect(ok == [.turnCompleted(threadId: "th-SECRET-THREAD", turnId: "turn-1", outcome: .completed, errorMessage: nil),
                  .sessionStateChanged(.ready)],
           "a completed turn/completed must map to turnCompleted(.completed) + session ready")

    let failed = translator.translate(line: #"""
        {"jsonrpc":"2.0","method":"turn/completed","params":{"threadId":"th-SECRET-THREAD","turn":{"id":"turn-2","status":"failed","error":{"code":"usage_limit_exceeded","message":"SECRET-ERROR-BODY quoting tool output"}}}}
        """#)
    expect(failed == [.turnCompleted(threadId: "th-SECRET-THREAD", turnId: "turn-2", outcome: .failed, errorMessage: "usage_limit_exceeded"),
                       .sessionStateChanged(.ready)],
           "a failed turn/completed must map to turnCompleted(.failed, code) — never the error body")

    // I5 by construction: none of the collected AgentRuntimeEvents (encoded)
    // and none of the runtime-observation side channel's whitelisted fields
    // carry any of the raw secrets.
    let allEvents = started + turnStarted + cmdStart + cmdEnd + msgStart + delta1 + msgEnd
        + fileStart + fileEnd + usage + ok + failed
    let encoded = String(decoding: try! JSONEncoder().encode(allEvents), as: UTF8.self)
    for secret in ["SECRET-COMMAND", "SECRET-OUTPUT", "SECRET-PATH", "SECRET-DIFF", "SECRET-ERROR-BODY"] {
        expect(!encoded.contains(secret), "CodexAppServerEventTranslator I5: \(secret) crossed into the events")
    }
    var observedFieldValues: [String] = []
    for observation in observationBox.snapshot() {
        if case let .toolDetail(_, detail) = observation {
            observedFieldValues.append(contentsOf: detail.fields.map { $0.value })
            if let preview = detail.outputPreview { observedFieldValues.append(preview) }
        }
    }
    expect(!observedFieldValues.contains(where: { $0.contains("SECRET-COMMAND") }),
           "CodexAppServerEventTranslator I5: the command body must never reach even the whitelisted observation channel")

    print("CodexAppServerEventTranslator mapping checks passed")
}

// MARK: - 2. single-agent parity equivalence

/// A structural shape token: session/turn/item event KINDS only, with
/// consecutive `contentDelta`s of the same stream collapsed into one block.
/// `tokenUsageUpdated` is deliberately excluded here (checked for presence
/// separately) — see the file header for why exact-count equality would be
/// dishonest given the two transports' different usage granularity.
private enum NormalizedShape: Equatable, CustomStringConvertible {
    case session(AgentSessionState)
    case turnStarted
    case turnCompleted(TurnOutcome)
    case itemStarted(ItemKind)
    case itemCompleted(ItemKind, ItemStatus)
    case contentBlock(ContentStreamKind)

    var description: String {
        switch self {
        case .session(let s): return "session(\(s))"
        case .turnStarted: return "turnStarted"
        case .turnCompleted(let o): return "turnCompleted(\(o))"
        case .itemStarted(let k): return "itemStarted(\(k))"
        case .itemCompleted(let k, let s): return "itemCompleted(\(k),\(s))"
        case .contentBlock(let k): return "contentBlock(\(k))"
        }
    }
}

private func normalizedShape(_ events: [AgentRuntimeEvent]) -> [NormalizedShape] {
    var out: [NormalizedShape] = []
    var pendingContentKind: ContentStreamKind?
    func flushContent() {
        if let kind = pendingContentKind {
            out.append(.contentBlock(kind))
            pendingContentKind = nil
        }
    }
    for event in events {
        switch event {
        case .sessionStateChanged(let state):
            flushContent(); out.append(.session(state))
        case .turnStarted:
            flushContent(); out.append(.turnStarted)
        case .turnCompleted(_, _, let outcome, _):
            flushContent(); out.append(.turnCompleted(outcome))
        case .itemStarted(_, _, let kind, _):
            flushContent(); out.append(.itemStarted(kind))
        case .itemCompleted(_, _, let kind, let status):
            flushContent(); out.append(.itemCompleted(kind, status))
        case .contentDelta(_, _, let streamKind, _):
            if pendingContentKind != streamKind {
                flushContent()
                pendingContentKind = streamKind
            }
        case .tokenUsageUpdated:
            continue
        default:
            flushContent()
        }
    }
    flushContent()
    return out
}

private func runCodexAppServerSingleAgentParityChecks() {
    let fixturesDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures", isDirectory: true)

    func lines(_ name: String) -> [String] {
        let url = fixturesDir.appendingPathComponent(name, isDirectory: false)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            fputs("FAIL: codex app-server parity fixture missing at \(url.path)\n", stderr)
            Foundation.exit(1)
        }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    // The SAME two-step task (run a shell command, then edit a file with the
    // file-editing tool) captured separately through each transport —
    // codex-cli 0.148.0, 2026-08-24. Not byte-identical (the model is not
    // deterministic across two live runs), which is exactly why the
    // comparison below is structural, not textual.
    var execTranslator = CodexEventTranslator(runToken: "parity")
    let execEvents = execTranslator.translate(stream: lines("codex-exec-single-agent-parity.jsonl"))

    var appServerTranslator = CodexAppServerEventTranslator()
    let appServerEvents = appServerTranslator.translate(stream: lines("codex-appserver-single-agent.jsonl"))

    expect(!execEvents.isEmpty && !appServerEvents.isEmpty,
           "both fixtures must actually produce events — an empty run here would make the equivalence check vacuous")

    let execShape = normalizedShape(execEvents)
    let appServerShape = normalizedShape(appServerEvents)
    expect(execShape == appServerShape, """
        codex exec and codex app-server must produce the SAME structural event shape \
        for the same single-agent task.
        exec:       \(execShape.map(\.description))
        app-server: \(appServerShape.map(\.description))
        """)

    let execSawUsage = execEvents.contains { if case .tokenUsageUpdated = $0 { return true }; return false }
    let appServerSawUsage = appServerEvents.contains { if case .tokenUsageUpdated = $0 { return true }; return false }
    expect(execSawUsage && appServerSawUsage,
           "both transports must surface token usage somewhere in the turn, even though app-server's granularity differs (restructure #2)")

    print("codex app-server single-agent parity holds: \(appServerShape.count) normalized events agree with exec's \(execShape.count)")
}

// MARK: - 3. the ordering hazard

/// The bug `CodexAgentRunner.emit()` actually has today (per the ledger:
/// "treats turnCompleted as terminal and fires it at process exit"), rebuilt
/// here as a minimal wrapper so it can be run against the SAME fixture as the
/// real translator, side by side, in one process. This is deliberately NOT
/// `CodexAppServerEventTranslator` (read/write access to that file is this
/// ticket's own) — it exists only to prove that gating on "primary thread's
/// turn/completed" drops real, measured child events, and that the real
/// translator does not have that gate.
private struct NaiveTerminalGateTranslator {
    private var inner = CodexAppServerEventTranslator()
    private var primaryThreadId: String?
    private var finished = false

    mutating func translate(line: String) -> [AgentRuntimeEvent] {
        guard !finished else { return [] }
        let events = inner.translate(line: line)
        if primaryThreadId == nil { primaryThreadId = inner.providerThreadId }
        for event in events {
            if case .turnCompleted(let threadId, _, _, _) = event, threadId == primaryThreadId {
                finished = true
            }
        }
        return events
    }
}

private func runCodexAppServerOrderingHazardChecks() {
    let fixturesDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures", isDirectory: true)
    let url = fixturesDir.appendingPathComponent("codex-appserver-delegating-turn.jsonl", isDirectory: false)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        fputs("FAIL: codex app-server delegating fixture missing at \(url.path)\n", stderr)
        Foundation.exit(1)
    }
    let fixtureLines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)

    // RED: the naive process-exit-shaped gate. Captured live, 2026-08-24: the
    // child's item/completed(commandExecution) and its own turn/completed
    // arrive 12-16s AFTER the parent's turn/completed. A translator (or
    // runner) that treats the parent's turn/completed as "the run is over"
    // drops both.
    var naive = NaiveTerminalGateTranslator()
    let naiveEvents = fixtureLines.flatMap { naive.translate(line: $0) }
    let naiveSawChildCommandCompletion = naiveEvents.contains {
        if case .itemCompleted(_, _, .commandExecution, _) = $0 { return true }; return false
    }
    let naiveChildTurnCompletions = naiveEvents.filter {
        if case .turnCompleted = $0 { return true }; return false
    }.count
    expect(!naiveSawChildCommandCompletion,
           "RED (expected): a naive parent-turn/completed-is-terminal gate must drop the late child commandExecution completion")
    expect(naiveChildTurnCompletions == 1,
           "RED (expected): the naive gate must see only the parent's turn/completed, not the child's — got \(naiveChildTurnCompletions)")

    // GREEN: the real translator has no such gate. Every method switches
    // independently, keyed by the threadId the frame itself carries — a late
    // child frame translates exactly as it would have if it arrived first.
    final class AnnouncementBox: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [(String, String, String, String?)] = []
        func append(_ value: (String, String, String, String?)) { lock.withLock { values.append(value) } }
        func snapshot() -> [(String, String, String, String?)] { lock.withLock { values } }
    }
    let announcements = AnnouncementBox()
    var real = CodexAppServerEventTranslator()
    real.onSubagentAnnouncement = { parent, child, item, label in
        announcements.append((parent, child, item, label))
    }
    let realEvents = fixtureLines.flatMap { real.translate(line: $0) }
    let realSawChildCommandCompletion = realEvents.contains {
        if case .itemCompleted(_, _, .commandExecution, .completed) = $0 { return true }; return false
    }
    let realTurnCompletions = realEvents.filter {
        if case .turnCompleted = $0 { return true }; return false
    }.count
    expect(realSawChildCommandCompletion,
           "GREEN: CodexAppServerEventTranslator must still translate the child's commandExecution completion after the parent's turn/completed")
    expect(realTurnCompletions == 2,
           "GREEN: CodexAppServerEventTranslator must report BOTH the parent's and the child's turn/completed — got \(realTurnCompletions)")
    let observedAnnouncements = announcements.snapshot()
    expect(observedAnnouncements.count == 1,
           "the captured delegating turn must announce exactly one structured child, got \(observedAnnouncements.count)")
    if let announcement = observedAnnouncements.first {
        expect(announcement.0 == "00000000-0000-4000-8000-000000000001"
               && announcement.1 == "00000000-0000-4000-8000-000000000004"
               && announcement.2 == "call_fixture0005"
               && announcement.3 == "slow child",
               "the structured child announcement must preserve parent thread, child thread, source item, and safe label")
    }

    print("codex app-server ordering hazard: naive gate drops the late child event (RED), real translator does not (GREEN)")
}
