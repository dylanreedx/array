import ContinuumRevivedCore
import Foundation

// Plan: .plans/02-codex-backend-and-toggle.md (codex CLI backend).
//
// Pins the codex → AgentRuntimeEvent mapping against the REAL `codex exec
// --json` schema captured live from codex-cli 0.145.0 on 2026-08-09/10 (event
// vocabulary confirmed from the shipped binary: thread.started / turn.started /
// turn.completed / turn.failed / item.started / item.updated / item.completed;
// item types agent_message / reasoning / command_execution / file_change / …).
// Fixture lines are the actual shapes with the command / aggregated_output /
// file paths kept deliberately "secret" so the I5 assertion has something to
// catch. Also pins the runner's argv (fresh + resume), the stale-resume failure
// predicate, the backend routing/policy, and the catalogue union.
func runCodexAgentBackendChecks() {
    runCodexTranslatorMappingChecks()
    runCodexRolloutTelemetryChecks()
    runCodexTranslatorGateChecks()
    runCodexRunnerArgvChecks()
    runCodexBackendPolicyChecks()
    runCodexCatalogUnionChecks()
    runCodexLoginProbeStderrChecks()
}

private let codexTID = "019fe980-21f0-7df1-b2a0-49d7839c7937"

/// codex reports `turn.completed.usage.input_tokens` CUMULATIVELY for the
/// session. Measured against the real CLI on 2026-08-11 — two turns of one
/// thread, the same trivial exchange each time:
///
///     turn 1  input_tokens 15005
///     turn 2  input_tokens 30026
///
/// Neither the cumulative figure nor a delta is context occupancy. Dividing the
/// cumulative figure by a context window is what put 237% on the meter and left
/// it climbing; exact occupancy is rollout `last_token_usage.total_tokens`.
///
/// Also pinned here: the `codex exec --json` vocabulary is `thread.started`,
/// `turn.started`, `item.completed`, `turn.completed` and NOTHING else. codex's
/// own rollout log carries a live per-request `token_count`; that file is not
/// this stream, and a handler for it here fires never — which is exactly the
/// mistake this check exists to stop being made a second time.
private func runCodexRolloutTelemetryChecks() {
    let observedAt = Date(timeIntervalSince1970: 1_786_000_000)
    func turn(_ input: Int) -> String {
        #"{"type":"turn.completed","usage":{"input_tokens":\#(input),"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":0}}"#
    }
    let opening = [#"{"type":"thread.started","thread_id":"t"}"#, #"{"type":"turn.started"}"#]

    // Stdout's turn usage remains cumulative accounting and can never create a
    // context event, even on a fresh turn where a zero-baseline delta looks
    // superficially plausible.
    var blind = CodexEventTranslator(runToken: "c1", now: { observedAt })
    _ = blind.translate(stream: opening)
    let blindEvents = blind.translate(line: turn(643_673))
    expect(!blindEvents.contains { if case .contextWindowUpdated = $0 { return true }; return false },
           "cumulative stdout usage must never become context occupancy")
    var sawUsage = false
    for case let .tokenUsageUpdated(_, snapshot) in blindEvents where snapshot.inputTokens == 643_673 { sawUsage = true }
    expect(sawUsage, "cumulative stdout usage must remain available for accounting")

    var rollout = CodexEventTranslator(runToken: "c2", now: { observedAt })
    _ = rollout.translate(stream: opening)
    let rolloutLine = #"{"type":"token_count","info":{"last_token_usage":{"input_tokens":73176,"total_tokens":74379},"model_context_window":258400}}"#
    expect(rollout.translate(line: rolloutLine).isEmpty,
           "a rollout-log token_count is not part of `codex exec --json` and must translate to nothing")

    // The exact rollout envelope. `total_tokens`, not input, is the numerator;
    // the provider's model_context_window, not the catalogue, is the denominator.
    let exactLine = #"{"timestamp":"2026-08-10T12:34:56.000Z","type":"event_msg","payload":{"type":"token_count","private_text":"SECRET-ROLLOUT-PAYLOAD","info":{"last_token_usage":{"input_tokens":73176,"cached_input_tokens":70400,"output_tokens":1203,"total_tokens":74379},"model_context_window":258400}}}"#
    let exact = CodexRolloutTelemetry.snapshot(from: exactLine, fallbackDate: observedAt)
    expect(exact?.usedTokens == 74_379 && exact?.usedTokens != exact?.inputTokens,
           "rollout occupancy numerator must be last_token_usage.total_tokens")
    expect(exact?.maxTokens == 258_400 && exact?.source == .codexRolloutTokenCount,
           "rollout denominator/source must be provider authoritative")
    expect(exact?.source.isAuthoritativeForContextOccupancy == true,
           "codex rollout token_count must be authoritative")
    let roundTrip = try! JSONDecoder().decode(
        AgentContextWindowSnapshot.self,
        from: JSONEncoder().encode(exact!))
    expect(roundTrip == exact, "new rollout source must survive Codable round trip")
    expect(!String(decoding: try! JSONEncoder().encode(exact!), as: UTF8.self)
        .contains("SECRET-ROLLOUT-PAYLOAD"),
        "raw rollout text must never cross the normalized telemetry boundary")

    for rejected in [
        rolloutLine,
        #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":1},"model_context_window":0}}}"#,
        #"{"type":"event_msg","payload":{"type":"message","info":{"last_token_usage":{"total_tokens":1},"model_context_window":100}}}"#,
        #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":1.5},"model_context_window":100}}}"#,
        #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":true},"model_context_window":100}}}"#,
        "{partial SECRET-ROLLOUT-PAYLOAD",
    ] {
        expect(CodexRolloutTelemetry.snapshot(from: rejected, fallbackDate: observedAt) == nil,
               "wrong envelope, invalid window, non-token event, and malformed lines must be inert")
    }

    // Final event ordering is the lifecycle contract: accounting, exact
    // occupancy, then terminal/ready. It applies to completed and failed turns;
    // an interrupted run with new rollout telemetry publishes only the exact
    // snapshot, while no new request publishes nothing.
    let usage = AgentRuntimeEvent.tokenUsageUpdated(
        threadId: "t", snapshot: TokenUsageSnapshot(inputTokens: 99, outputTokens: 1, totalCostUsd: nil))
    let failed = AgentRuntimeEvent.turnCompleted(threadId: "t", turnId: "x", outcome: .failed, errorMessage: "x")
    let ready = AgentRuntimeEvent.sessionStateChanged(.ready)
    let ordered = CodexRolloutTelemetry.orderedFinalEvents(
        threadId: "t", terminalEvents: [usage, failed, ready], snapshot: exact)
    expect(ordered == [usage, .contextWindowUpdated(threadId: "t", snapshot: exact!), failed, ready],
           "terminal join ordering must be accounting -> exact context -> terminal -> ready")
    expect(CodexRolloutTelemetry.orderedFinalEvents(threadId: "t", terminalEvents: [], snapshot: exact).count == 1,
           "an interrupted/failed process with a new request must retain its exact snapshot")
    expect(CodexRolloutTelemetry.orderedFinalEvents(threadId: "t", terminalEvents: [], snapshot: nil).isEmpty,
           "an interrupted process with no new request must publish no context snapshot")

    // File witness: exact thread matching, current-run byte offset, a tool-loop
    // token_count, later compaction, delayed final append, partial-line safety,
    // and ambiguity abstention.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("array-codex-rollout-\(UUID().uuidString)", isDirectory: true)
    let sessions = root.appendingPathComponent("sessions/2026/08/10", isDirectory: true)
    try! FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = sessions.appendingPathComponent("rollout-2026-08-10-\(codexTID).jsonl")
    let meta = #"{"type":"session_meta","payload":{"id":"\#(codexTID)"}}"# + "\n"
    let old = #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":230000,"total_tokens":237000},"model_context_window":258400}}}"# + "\n"
    try! Data((meta + old).utf8).write(to: url)
    let otherThread = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    let otherURL = sessions.appendingPathComponent("rollout-2026-08-10-\(otherThread).jsonl")
    let other = #"{"type":"session_meta","payload":{"id":"\#(otherThread)"}}"# + "\n"
        + #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":999999},"model_context_window":1000000}}}"# + "\n"
    try! Data(other.utf8).write(to: otherURL)
    let offset = CodexRolloutTelemetry.fileSize(of: url)!
    expect(CodexRolloutTelemetry.rolloutURL(threadId: codexTID, codexHome: root)?.standardizedFileURL.path
            == url.standardizedFileURL.path,
           "rollout resolver must validate the full session_meta thread id")
    let toolLoop = #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":21000,"output_tokens":500,"total_tokens":22000},"model_context_window":258400}}}"# + "\n"
    let compacted = #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":15000,"output_tokens":700,"total_tokens":16000},"model_context_window":258400}}}"# + "\n"
    let handle = try! FileHandle(forWritingTo: url)
    try! handle.seekToEnd()
    handle.write(Data((toolLoop + compacted + "{partial SECRET\n").utf8))
    try! handle.close()
    let latest = CodexRolloutTelemetry.latestSnapshot(in: url, afterOffset: offset)
    expect(latest?.usedTokens == 16_000,
           "latest post-offset request must win, including a compaction drop 237k -> 16k")

    let partialURL = sessions.appendingPathComponent("partial-offset-witness.jsonl")
    try! Data((meta + "unfinished-prefix").utf8).write(to: partialURL)
    let partialOffset = CodexRolloutTelemetry.fileSize(of: partialURL)!
    let partialHandle = try! FileHandle(forWritingTo: partialURL)
    try! partialHandle.seekToEnd()
    partialHandle.write(Data((exactLine + "\n").utf8))
    try! partialHandle.close()
    expect(CodexRolloutTelemetry.latestSnapshot(in: partialURL, afterOffset: partialOffset) == nil,
           "an offset in the middle of an unfinished JSONL line must discard that line")

    let archived = root.appendingPathComponent("archived_sessions", isDirectory: true)
    try! FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
    try! Data(meta.utf8).write(to: archived.appendingPathComponent("duplicate-\(codexTID).jsonl"))
    expect(CodexRolloutTelemetry.rolloutURL(threadId: codexTID, codexHome: root) == nil,
           "multiple exact rollout matches must abstain rather than guess")

    print("Codex rollout telemetry checks passed: stdout accounting separated, exact total/window parsed, ordering pinned, offset/compaction/partial/ambiguity file cases covered")
}

private func runCodexTranslatorMappingChecks() {
    // Real captured schema: thread.started (mints the id) → turn.started → a
    // whole agent_message → a command round-trip → a file_change round-trip → a
    // FAILING command → a second agent_message → turn.completed with usage.
    let fixture: [String] = [
        #"{"type":"thread.started","thread_id":"019fe980-21f0-7df1-b2a0-49d7839c7937"}"#,
        #"{"type":"turn.started"}"#,
        #"{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"Working on it."}}"#,
        #"{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc 'echo SECRET-COMMAND'","aggregated_output":"","exit_code":null,"status":"in_progress"}}"#,
        #"{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc 'echo SECRET-COMMAND'","aggregated_output":"SECRET-OUTPUT\n","exit_code":0,"status":"completed"}}"#,
        #"{"type":"item.started","item":{"id":"item_2","type":"file_change","changes":[{"path":"/private/tmp/SECRET-PATH/note.txt","kind":"add"}],"status":"in_progress"}}"#,
        #"{"type":"item.completed","item":{"id":"item_2","type":"file_change","changes":[{"path":"/private/tmp/SECRET-PATH/note.txt","kind":"add"}],"status":"completed"}}"#,
        #"{"type":"item.started","item":{"id":"item_3","type":"command_execution","command":"/bin/zsh -lc 'SECRET-FAILING-COMMAND'","aggregated_output":"","exit_code":null,"status":"in_progress"}}"#,
        #"{"type":"item.completed","item":{"id":"item_3","type":"command_execution","command":"/bin/zsh -lc 'SECRET-FAILING-COMMAND'","aggregated_output":"SECRET-FAILURE-OUTPUT\n","exit_code":2,"status":"failed"}}"#,
        #"{"type":"item.completed","item":{"id":"item_4","type":"agent_message","text":"Done."}}"#,
        #"{"type":"turn.completed","usage":{"input_tokens":46162,"cached_input_tokens":41216,"cache_write_input_tokens":0,"output_tokens":231,"reasoning_output_tokens":0}}"#,
    ]

    let observedAt = Date(timeIntervalSinceReferenceDate: 123)
    var translator = CodexEventTranslator(runToken: "run1", now: { observedAt })
    let events = translator.translate(stream: fixture)

    let turnId = "\(codexTID)#run1-t1"
    let expected: [AgentRuntimeEvent] = [
        .sessionStateChanged(.ready),
        .sessionStateChanged(.running),
        .turnStarted(threadId: codexTID, turnId: turnId),
        .contentDelta(threadId: codexTID, turnId: turnId, streamKind: .assistant, delta: "Working on it."),
        .itemStarted(threadId: codexTID, itemId: "run1-item_1", kind: .commandExecution, title: "Shell"),
        .itemCompleted(threadId: codexTID, itemId: "run1-item_1", kind: .commandExecution, status: .completed),
        .itemStarted(threadId: codexTID, itemId: "run1-item_2", kind: .fileChange, title: "Edit"),
        .itemCompleted(threadId: codexTID, itemId: "run1-item_2", kind: .fileChange, status: .completed),
        .itemStarted(threadId: codexTID, itemId: "run1-item_3", kind: .commandExecution, title: "Shell"),
        .itemCompleted(threadId: codexTID, itemId: "run1-item_3", kind: .commandExecution, status: .failed),
        .contentDelta(threadId: codexTID, turnId: turnId, streamKind: .assistant, delta: "Done."),
        .tokenUsageUpdated(threadId: codexTID, snapshot: TokenUsageSnapshot(
            // input_tokens is ALREADY the total — NOT summed with cached (the
            // opposite of the claude backend). 46162, not 46162+41216.
            inputTokens: 46162, outputTokens: 231, totalCostUsd: nil)),
        .turnCompleted(threadId: codexTID, turnId: turnId, outcome: .completed, errorMessage: nil),
        .sessionStateChanged(.ready),
    ]

    // 1. Exact mapping — sequence, threadId capture, whole-message deltas,
    //    salted item ids, exit-code status, the NOT-summed usage.
    expect(events == expected,
           "CodexEventTranslator: mapping must equal the expected sequence.\n  got: \(events)\n  want: \(expected)")

    // 2. Both agent_messages surface as assistant deltas (whole, at once — no
    //    token streaming in exec --json), and item ids are salted with the run
    //    token so separate processes' `item_0` never collide.
    let assistantDeltas = events.compactMap { event -> String? in
        if case let .contentDelta(_, _, streamKind, delta) = event, streamKind == .assistant { return delta }
        return nil
    }
    expect(assistantDeltas == ["Working on it.", "Done."],
           "CodexEventTranslator: each agent_message must surface once as a whole assistant delta, got \(assistantDeltas)")

    // 3. I5 by construction — no command, tool output, or path in any encoded
    //    event; the generic titles (never the command) survive.
    let encoded = String(decoding: try! JSONEncoder().encode(events), as: UTF8.self)
    for secret in ["SECRET-COMMAND", "SECRET-OUTPUT", "SECRET-PATH", "SECRET-FAILING-COMMAND", "SECRET-FAILURE-OUTPUT"] {
        expect(!encoded.contains(secret), "CodexEventTranslator I5: \(secret) crossed into the events")
    }
    expect(encoded.contains("Shell") && encoded.contains("Edit"),
           "CodexEventTranslator: generic titles must survive as item titles")

    // 4. The whitelisted observation side channel projects the edit target and
    //    the captured thread_id (and the path ONLY through it — assertion 3
    //    already proved the events stay clean).
    final class ObservationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var observations: [AgentRuntimeObservation] = []
        func append(_ observation: AgentRuntimeObservation) { lock.withLock { observations.append(observation) } }
        func snapshot() -> [AgentRuntimeObservation] { lock.withLock { observations } }
    }
    let box = ObservationBox()
    var observing = CodexEventTranslator(runToken: "run1", now: { observedAt })
    observing.onRuntimeObservation = { box.append($0) }
    _ = observing.translate(stream: fixture)
    let observed = box.snapshot()
    let editTargets = observed.compactMap { observation -> String? in
        guard case let .toolActivity(_, activity) = observation, activity.operation == .editing else { return nil }
        return activity.targetPath?.path
    }
    expect(editTargets == ["/private/tmp/SECRET-PATH/note.txt"],
           "CodexEventTranslator: the edit target must project out of band, got \(editTargets)")
    let capturedThreadIds = observed.compactMap { observation -> String? in
        guard case let .threadId(value) = observation else { return nil }
        return value
    }
    expect(capturedThreadIds == [codexTID],
           "CodexEventTranslator: the minted thread_id must project on the observation side channel (STORED continuity), got \(capturedThreadIds)")

    // 5. `.plans/45` S2 — the toolDetail supply. The ended detail for a
    //    command carries the INTEGER exit code and the aggregated output as a
    //    bounded preview; a file_change start carries every changed basename;
    //    and the command body itself never crosses, even host-locally.
    let details = observed.compactMap { observation -> (String, AgentToolDetailObservation)? in
        guard case let .toolDetail(itemId, detail) = observation else { return nil }
        return (itemId, detail)
    }
    let commandEnd = details.first { $0.0 == "run1-item_1" && $0.1.phase == .ended }?.1
    expect(commandEnd?.exitCode == 0 && commandEnd?.outputPreview == "SECRET-OUTPUT",
           "CodexEventTranslator: the ended detail must carry exit code 0 and the output preview, got \(String(describing: commandEnd))")
    let failedEnd = details.first { $0.0 == "run1-item_3" && $0.1.phase == .ended }?.1
    expect(failedEnd?.exitCode == 2 && failedEnd?.outputPreview == "SECRET-FAILURE-OUTPUT",
           "CodexEventTranslator: the failing command's detail must carry exit code 2 and its output, got \(String(describing: failedEnd))")
    let editStart = details.first { $0.0 == "run1-item_2" && $0.1.phase == .started }?.1
    expect(editStart?.fields.map { "\($0.key)=\($0.value)" } == ["file=note.txt"],
           "CodexEventTranslator: a file_change start must carry the changed basenames only, got \(String(describing: editStart?.fields))")
    let detailDescription = String(describing: details)
    for secret in ["SECRET-COMMAND", "SECRET-FAILING-COMMAND", "SECRET-PATH"] {
        expect(!detailDescription.contains(secret),
               "CodexEventTranslator: \(secret) leaked into the toolDetail channel")
    }

    // 6. `.plans/45` S2 — mcp_tool_call / web_search / todo_list stop being
    //    swallowed: each now produces an item row, and web_search carries its
    //    query on the detail channel.
    var unswallowed = CodexEventTranslator(runToken: "run1", now: { observedAt })
    let unswallowedBox = ObservationBox()
    unswallowed.onRuntimeObservation = { unswallowedBox.append($0) }
    let extraEvents = unswallowed.translate(stream: [
        #"{"type":"thread.started","thread_id":"019fe980-21f0-7df1-b2a0-49d7839c7937"}"#,
        #"{"type":"turn.started"}"#,
        #"{"type":"item.started","item":{"id":"item_5","type":"mcp_tool_call","server":"linear","tool":"create_issue","status":"in_progress"}}"#,
        #"{"type":"item.completed","item":{"id":"item_5","type":"mcp_tool_call","server":"linear","tool":"create_issue","status":"completed"}}"#,
        #"{"type":"item.started","item":{"id":"item_6","type":"web_search","query":"swift diffable snapshot","status":"in_progress"}}"#,
        #"{"type":"item.completed","item":{"id":"item_6","type":"web_search","query":"swift diffable snapshot","status":"completed"}}"#,
        #"{"type":"item.started","item":{"id":"item_7","type":"todo_list","items":[],"status":"in_progress"}}"#,
        #"{"type":"item.completed","item":{"id":"item_7","type":"todo_list","items":[],"status":"completed"}}"#,
    ])
    let itemEvents = extraEvents.compactMap { event -> (String, ItemKind)? in
        if case let .itemStarted(_, itemId, kind, _) = event { return (itemId, kind) }
        return nil
    }
    expect(itemEvents.map(\.0) == ["run1-item_5", "run1-item_6", "run1-item_7"]
        && itemEvents.map(\.1) == [.mcpToolCall, .webSearch, .plan],
           "CodexEventTranslator: mcp_tool_call/web_search/todo_list must produce rows, got \(itemEvents)")
    expect(extraEvents.filter { if case .itemCompleted = $0 { return true } else { return false } }.count == 3,
           "CodexEventTranslator: each un-swallowed item must also complete")
    let searchStart = unswallowedBox.snapshot().compactMap { observation -> AgentToolDetailObservation? in
        guard case let .toolDetail(itemId, detail) = observation,
              itemId == "run1-item_6", detail.phase == .started else { return nil }
        return detail
    }.first
    expect(searchStart?.fields.map { "\($0.key)=\($0.value)" } == ["query=swift diffable snapshot"],
           "CodexEventTranslator: web_search must carry its query on the detail channel, got \(String(describing: searchStart?.fields))")

    print("CodexEventTranslator checks passed: \(events.count) events from the real codex-cli 0.145.0 exec --json schema map exactly, whole messages surface once, item ids salted, input_tokens NOT summed, I5-safe by construction, thread_id captured out of band")
}

private func runCodexTranslatorGateChecks() {
    // A turn.completed with no turn.started before it is the stale-resume shape;
    // the translator must stay silent so no spurious card is painted.
    var orphan = CodexEventTranslator(runToken: "run1")
    let orphanEvents = orphan.translate(line:
        #"{"type":"turn.completed","usage":{"input_tokens":5,"output_tokens":1}}"#)
    expect(orphanEvents.isEmpty,
           "CodexEventTranslator: a turn.completed before any turn.started must emit nothing, got \(orphanEvents)")

    // A turn.failed completes the turn as .failed with the error CODE only —
    // never the message body (which can quote tool output / model text, I5).
    var failing = CodexEventTranslator(runToken: "run1")
    _ = failing.translate(line: #"{"type":"thread.started","thread_id":"019fe980-21f0-7df1-b2a0-49d7839c7937"}"#)
    _ = failing.translate(line: #"{"type":"turn.started"}"#)
    let failedEvents = failing.translate(line:
        #"{"type":"turn.failed","error":{"code":"usage_limit_exceeded","message":"SECRET-ERROR-BODY quoting tool output"}}"#)
    expect(failedEvents == [
        .turnCompleted(threadId: codexTID, turnId: "\(codexTID)#run1-t1", outcome: .failed, errorMessage: "usage_limit_exceeded"),
        .sessionStateChanged(.ready),
    ], "CodexEventTranslator: a turn.failed must fail the turn with the code only, got \(failedEvents)")
    let failedEncoded = String(decoding: try! JSONEncoder().encode(failedEvents), as: UTF8.self)
    expect(!failedEncoded.contains("SECRET-ERROR-BODY"),
           "CodexEventTranslator I5: the turn.failed body must never reach an event")

    // A zero-token usage block publishes no telemetry (don't clobber real
    // occupancy with zeros) — only the turn completion + ready.
    var zeroUsage = CodexEventTranslator(runToken: "run1")
    _ = zeroUsage.translate(line: #"{"type":"thread.started","thread_id":"019fe980-21f0-7df1-b2a0-49d7839c7937"}"#)
    _ = zeroUsage.translate(line: #"{"type":"turn.started"}"#)
    let zeroEvents = zeroUsage.translate(line:
        #"{"type":"turn.completed","usage":{"input_tokens":0,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0}}"#)
    expect(zeroEvents == [
        .turnCompleted(threadId: codexTID, turnId: "\(codexTID)#run1-t1", outcome: .completed, errorMessage: nil),
        .sessionStateChanged(.ready),
    ], "CodexEventTranslator: a zero-usage turn.completed must publish no telemetry, got \(zeroEvents)")

    print("CodexEventTranslator gate checks passed: stale-resume shape silent, turn.failed carries the code only, zero usage skipped")
}

private func runCodexRunnerArgvChecks() {
    // The exact argv, both session modes. Sandbox + approval ride as `-c`
    // overrides (they work on resume too, unlike -s); `-C` is exec-only; the
    // prompt is one trailing positional.
    let fresh = CodexCLIBackend.processArguments(
        model: "gpt-5.6-sol",
        effort: "high",
        sessionMode: .fresh,
        threadId: nil,
        cwdPath: "/tmp/work",
        extraArgs: [],
        prompt: AgentPrompt("do the thing"))
    expect(fresh == [
        "exec",
        "--json", "--skip-git-repo-check",
        "-c", "approval_policy=never",
        "-c", "sandbox_mode=workspace-write",
        "-m", "gpt-5.6-sol",
        "-c", "model_reasoning_effort=high",
        "-C", "/tmp/work",
        "do the thing",
    ], "CodexCLIBackend argv (fresh) drifted: \(fresh)")

    // Resume: no -C, effort omitted (a pi-only level maps to nil), extra args
    // before the prompt, the thread id positional right after `resume`.
    let resume = CodexCLIBackend.processArguments(
        model: "gpt-5.6-sol",
        effort: CodexCLIBackend.effortArgument(forThinking: "xhigh"),
        sessionMode: .resume,
        threadId: codexTID,
        cwdPath: "/tmp/work",
        extraArgs: ["--extra"],
        prompt: AgentPrompt("recall"))
    expect(resume == [
        "exec", "resume", codexTID,
        "--json", "--skip-git-repo-check",
        "-c", "approval_policy=never",
        "-c", "sandbox_mode=workspace-write",
        "-m", "gpt-5.6-sol",
        "--extra",
        "recall",
    ], "CodexCLIBackend argv (resume) drifted: \(resume)")

    // The sandbox posture is one named constant (so danger-full-access is a
    // one-line change later) and it is the plan's recommended default.
    expect(CodexCLIBackend.sandboxMode == "workspace-write",
           "CodexCLIBackend: the pinned sandbox posture must be workspace-write")

    #if os(macOS)
    // Executable resolution mirrors pi's/claude's GUI-thin-PATH strategy.
    let absolute = CodexAgentRunner.resolvedCommand(
        pathDirs: ["/usr/bin"],
        extraDirs: ["/Users/qa/.nvm/bin"],
        fileExists: { $0 == "/Users/qa/.nvm/bin/codex" })
    expect(absolute == PiAgentRunner.ResolvedCommand(executable: "/Users/qa/.nvm/bin/codex", prefixArgs: []),
           "CodexAgentRunner: an installed codex must resolve absolutely, got \(absolute)")
    let fallback = CodexAgentRunner.resolvedCommand(
        pathDirs: ["/usr/bin"], extraDirs: [], fileExists: { _ in false })
    expect(fallback == PiAgentRunner.ResolvedCommand(executable: "/usr/bin/env", prefixArgs: ["codex"]),
           "CodexAgentRunner: missing codex must fall back to env, got \(fallback)")
    #endif

    // The stale/unknown-session stderr, captured live — the self-heal trigger.
    expect(CodexCLIBackend.isUnknownSessionFailure(
        stderr: "Error: thread/resume: thread/resume failed: no rollout found for thread id \(codexTID) (code -32600)\n"),
        "CodexCLIBackend: the unknown-session stderr must trigger the fresh-exec self-heal")
    expect(CodexCLIBackend.isUnknownSessionFailure(stderr: "some error (code -32600)"),
           "CodexCLIBackend: the -32600 code alone must also match")
    expect(!CodexCLIBackend.isUnknownSessionFailure(stderr: "Error: network unreachable"),
           "CodexCLIBackend: unrelated failures must not trigger the self-heal")

    print("CodexCLIBackend argv checks passed: fresh + resume pinned, sandbox constant, resolution mirrors pi, stale-session predicate matches the captured stderr")
}

private func runCodexBackendPolicyChecks() {
    expect(CodexCLIBackend.transportOverride(environment: [:]) == .appServer,
           "Codex app-server must be the default transport so structured subagents surface")
    expect(CodexCLIBackend.transportOverride(environment: ["CONTINUUM_CODEX_TRANSPORT": "exec"]) == .exec,
           "CONTINUUM_CODEX_TRANSPORT=exec must remain the emergency escape hatch")
    expect(CodexCLIBackend.transportOverride(environment: ["CONTINUUM_CODEX_TRANSPORT": "app-server"]) == .appServer,
           "the former explicit app-server spelling must remain app-server")
    // Strict harness identity is independent of installed neighbours.
    expect(AgentHarness.allCases == [.claudeCode, .codex, .pi], "harness order")
    expect(AgentHarnessConfig.defaultHarness == .claudeCode, "Claude Code is the default")
    expect(AgentHarnessConfig.isProviderCompatible(model: "anthropic/opus", harness: .claudeCode), "Claude owns anthropic")
    expect(AgentHarnessConfig.isProviderCompatible(model: "openai-codex/gpt-5.6-sol", harness: .codex), "Codex owns openai-codex")
    expect(AgentHarnessConfig.isProviderCompatible(model: "openai-codex/gpt-5.6-sol", harness: .pi), "Pi may own the same model id")
    expect(LegacyAgentHarnessMigration.resolve(evidence: .init(hasCodexThread: false, hasClaudeConversation: true, hasPiSession: true), storedPreference: nil) == nil, "dual session evidence fails closed")
    expect(LegacyAgentHarnessMigration.resolve(evidence: .init(hasCodexThread: true, hasClaudeConversation: true, hasPiSession: true), storedPreference: nil) == .codex, "stored Codex thread is decisive")

    // Model argument: the catalogue prefix is Array's namespacing, never sent.
    expect(CodexCLIBackend.modelArgument(forCatalogId: "openai-codex/gpt-5.6-sol") == "gpt-5.6-sol",
           "CodexCLIBackend: the provider prefix must be stripped")
    expect(CodexCLIBackend.modelArgument(forCatalogId: "gpt-5.6-sol") == "gpt-5.6-sol",
           "CodexCLIBackend: a bare slug passes through")

    // Effort: exact pass-through for codex's set, omission for pi-only levels.
    expect(CodexCLIBackend.effortArgument(forThinking: "medium") == "medium",
           "CodexCLIBackend: matching thinking levels pass through as effort")
    expect(CodexCLIBackend.effortArgument(forThinking: "minimal") == "minimal",
           "CodexCLIBackend: minimal is in codex's set")
    expect(CodexCLIBackend.effortArgument(forThinking: "off") == nil,
           "CodexCLIBackend: pi-only 'off' omits the config")
    expect(CodexCLIBackend.effortArgument(forThinking: "xhigh") == nil,
           "CodexCLIBackend: pi-only 'xhigh' omits the config")
    expect(CodexCLIBackend.effortArgument(forThinking: "max") == nil,
           "CodexCLIBackend: pi-only 'max' omits the config")

    // Auth: exit 0 + "Logged in" (text-based, there is no --json).
    expect(CodexCLIBackend.isLoggedIn(statusOutput: "Logged in using ChatGPT\n", exitCode: 0),
           "CodexCLIBackend: the real logged-in shape must read as logged in")
    expect(!CodexCLIBackend.isLoggedIn(statusOutput: "Logged in using ChatGPT\n", exitCode: 1),
           "CodexCLIBackend: a nonzero exit must read as logged out")
    expect(!CodexCLIBackend.isLoggedIn(statusOutput: "Not logged in", exitCode: 0),
           "CodexCLIBackend: 'Not logged in' must read as logged out")
    expect(!CodexCLIBackend.isLoggedIn(statusOutput: "", exitCode: 0),
           "CodexCLIBackend: empty output must read as logged out")

    let suite = UserDefaults(suiteName: "strict-harness-\(UUID().uuidString)")!
    defer { suite.removePersistentDomain(forName: suite.volatileDomainNames.first ?? "") }
    suite.set("pi (all providers)", forKey: AgentHarnessConfig.key)
    expect(AgentHarnessConfig.resolved(defaults: suite) == .pi, "legacy Pi preference migrates strictly")
    print("CodexCLIBackend strict-harness policy checks passed: ownership, defaults, migration ambiguity, model arguments, effort, and auth pinned")
}

private func runCodexCatalogUnionChecks() {
    // The codex backend UNIONS into the catalogue, independently of pi and
    // claude: pi's list keeps standing, the curated codex ids append without
    // dup, and losing the CLI clears them again.
    let catalog = AgentModelCatalog()
    catalog.resetForQA(options: ["openai-codex/gpt-5.6-sol", "anthropic/opus"])
    catalog.apply(codexBackendAvailable: true)
    expect(catalog.options() == [
        "openai-codex/gpt-5.6-sol", "anthropic/opus",
        "openai-codex/gpt-5.6-terra", "openai-codex/gpt-5.6-luna",
        "openai-codex/gpt-5.5", "openai-codex/gpt-5.4",
        "openai-codex/gpt-5.4-mini", "openai-codex/gpt-5.3-codex-spark",
    ], "AgentModelCatalog: codex entries must append without duplicating ids already present, got \(catalog.options())")
    expect(catalog.displayName(for: "openai-codex/gpt-5.6-terra") == "GPT-5.6 Terra",
           "AgentModelCatalog: codex ids must carry their curated display names")

    // pi's display names win when both know an id (pi's are model-specific).
    catalog.apply(displayNames: ["openai-codex/gpt-5.6-terra": "Terra from pi"])
    expect(catalog.displayName(for: "openai-codex/gpt-5.6-terra") == "Terra from pi",
           "AgentModelCatalog: pi display names must take precedence over curated codex ones")

    catalog.apply(codexBackendAvailable: false)
    expect(catalog.options() == ["openai-codex/gpt-5.6-sol", "anthropic/opus"],
           "AgentModelCatalog: an uninstalled/logged-out codex must clear its entries, got \(catalog.options())")

    // The claude and codex stores are independent: applying one must not touch
    // the other.
    catalog.apply(claudeBackendAvailable: true)
    catalog.apply(codexBackendAvailable: true)
    expect(catalog.options().contains("anthropic/sonnet") && catalog.options().contains("openai-codex/gpt-5.6-terra"),
           "AgentModelCatalog: claude and codex unions must coexist, got \(catalog.options())")
    catalog.apply(codexBackendAvailable: false)
    expect(catalog.options().contains("anthropic/sonnet") && !catalog.options().contains("openai-codex/gpt-5.6-terra"),
           "AgentModelCatalog: clearing codex must leave the claude union intact, got \(catalog.options())")

    catalog.resetForQA()
    expect(catalog.options(fallback: ["frozen/id"]) == ["frozen/id"],
           "AgentModelCatalog: resetForQA must clear codex entries too, got \(catalog.options(fallback: ["frozen/id"]))")

    print("AgentModelCatalog codex-union checks passed: append/clear semantics, pi name precedence, independence from the claude store, QA reset pinned")
}

/// codex prints its login state to STDERR with an EMPTY stdout — verified live
/// on the installed CLI, 2026-08-26:
///
///     codex login status → stdout: (empty), exit 0
///                          stderr: "Logged in using ChatGPT"
///
/// The probe used to read stdout only (stderr went into an unread, discarded
/// pipe), so the "Logged in" text check was structurally unsatisfiable and a
/// signed-in codex ALWAYS read as logged out. These checks drive the REAL
/// pipeline — `probeCodexBackend(command:)` → `boundedProbeOutput` (actual
/// Process + pipes) → `isLoggedIn` → `apply(codexBackendAvailable:)` — with
/// fixture executables reproducing the exact stream shapes. An injected
/// `probeExecutor` would bypass the pipe handling under test, which is the
/// known witness trap (re-deriving what production derives).
private func runCodexLoginProbeStderrChecks() {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-login-probe-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    func fixtureCLI(_ name: String, _ body: String) -> PiAgentRunner.ResolvedCommand {
        let url = dir.appendingPathComponent(name)
        try? ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return PiAgentRunner.ResolvedCommand(executable: url.path, prefixArgs: [])
    }

    // NO probeExecutor: the point is the real bounded subprocess path.
    let catalog = AgentModelCatalog()
    catalog.resetForQA(options: ["frozen/id"])

    // The real captured shape: stderr-only "Logged in", empty stdout, exit 0.
    catalog.probeCodexBackend(
        command: fixtureCLI("codex-stderr", "echo 'Logged in using ChatGPT' 1>&2\nexit 0"),
        timeout: 5)
    expect(catalog.snapshot(for: .codex).readiness == .ready,
           "codex login probe: the REAL stream shape (stderr-only 'Logged in using ChatGPT', empty stdout, exit 0) must read as logged in, got \(catalog.snapshot(for: .codex).readiness)")
    expect(catalog.options().contains("openai-codex/gpt-5.6-terra"),
           "codex login probe: a logged-in probe must union the curated codex models, got \(catalog.options())")

    // Negative: silence on both streams, exit 0 → logged out.
    catalog.probeCodexBackend(command: fixtureCLI("codex-silent", "exit 0"), timeout: 5)
    expect(catalog.snapshot(for: .codex).readiness == .loggedOut,
           "codex login probe: silence on both streams must read as logged out, got \(catalog.snapshot(for: .codex).readiness)")

    // stdout keeps counting (combined output is a superset of the old read).
    catalog.probeCodexBackend(
        command: fixtureCLI("codex-stdout", "echo 'Logged in using ChatGPT'\nexit 0"),
        timeout: 5)
    expect(catalog.snapshot(for: .codex).readiness == .ready,
           "codex login probe: a stdout 'Logged in' must still read as logged in, got \(catalog.snapshot(for: .codex).readiness)")

    // A nonzero exit stays logged out even when the text is present.
    catalog.probeCodexBackend(
        command: fixtureCLI("codex-fail", "echo 'Logged in using ChatGPT' 1>&2\nexit 1"),
        timeout: 5)
    expect(catalog.snapshot(for: .codex).readiness == .loggedOut,
           "codex login probe: a nonzero exit must read as logged out regardless of text, got \(catalog.snapshot(for: .codex).readiness)")

    print("AgentModelCatalog codex login-probe checks passed: the real subprocess path reads stderr-only 'Logged in' as signed in, silence and nonzero exits as signed out, stdout still honored")
}
