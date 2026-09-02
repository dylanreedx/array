import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

// Plan: .plans/01-provider-cli-backends.md (claude CLI backend, first slice).
//
// Pins the claude → AgentRuntimeEvent mapping against the REAL stream-json
// schema captured live from claude 2.1.226 on 2026-08-09 (`-p --output-format
// stream-json --verbose --include-partial-messages --forward-subagent-text`,
// haiku turns with a Bash
// tool round-trip). Fixture lines are the actual shapes, curated and with the
// cwd/command/output payloads kept deliberately "secret" so the I5 assertion
// has something to catch. Also pins the runner's argv, the resume-first
// failure predicates (both stderr shapes captured live), and the backend
// routing policy.
func runClaudeAgentBackendChecks() {
    runClaudeTranslatorMappingChecks()
    runClaudeTranslatorGateChecks()
    runClaudeCompactBoundaryChecks()
    runClaudeResolvedModelContextWindowChecks()
    runClaudeContextOccupancyChecks()
    runClaudeRunnerArgvChecks()
    runClaudeBackendPolicyChecks()
    runClaudeCatalogUnionChecks()
}

private let claudeSID = "11111111-2222-3333-4444-555555555555"

private func runClaudeTranslatorMappingChecks() {
    // Real captured schema: init → thinking/text deltas → an assistant
    // message carrying the tool_use (plus the SAME text again, which must not
    // re-emit) → tool_result → a failing edit round-trip → result.
    let fixture: [String] = [
        #"{"type":"system","subtype":"init","cwd":"/private/tmp/SECRET-PATH/claude-probe","session_id":"11111111-2222-3333-4444-555555555555","tools":["Bash","Edit"],"model":"claude-haiku-4-5-20251001","permissionMode":"bypassPermissions","apiKeySource":"none"}"#,
        #"{"type":"system","subtype":"thinking_tokens","estimated_tokens":128,"estimated_tokens_delta":128,"session_id":"11111111-2222-3333-4444-555555555555"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"checking"}},"parent_tool_use_id":null,"session_id":"11111111-2222-3333-4444-555555555555"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"hello"}},"parent_tool_use_id":null,"session_id":"11111111-2222-3333-4444-555555555555"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":" world"}},"parent_tool_use_id":null,"session_id":"11111111-2222-3333-4444-555555555555"}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hello world"},{"type":"tool_use","id":"toolu_01","name":"Bash","input":{"command":"SECRET-COMMAND"}}]},"parent_tool_use_id":null,"session_id":"11111111-2222-3333-4444-555555555555"}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_01","is_error":false,"content":"SECRET-TOOL-OUTPUT"}]},"parent_tool_use_id":null,"session_id":"11111111-2222-3333-4444-555555555555"}"#,
        // A real assistant frame carries the `usage` of the ONE API response it
        // is — this is the occupancy reading, and the curated fixture used to
        // omit it, which is part of why the summed `result.usage` looked like
        // the only source available.
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_02","name":"Edit","input":{"file_path":"/private/tmp/SECRET-PATH/notes.txt","old_string":"a","new_string":"b"}}],"usage":{"input_tokens":4,"cache_creation_input_tokens":1200,"cache_read_input_tokens":17900,"output_tokens":12}},"parent_tool_use_id":null,"session_id":"11111111-2222-3333-4444-555555555555"}"#,
        // A sub-agent frame: everything about it must be skipped.
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_sub","name":"Bash","input":{"command":"SECRET-SUBAGENT-COMMAND"}}]},"parent_tool_use_id":"toolu_02","session_id":"11111111-2222-3333-4444-555555555555"}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_02","is_error":true,"content":"SECRET-ERROR-BODY"}]},"parent_tool_use_id":null,"session_id":"11111111-2222-3333-4444-555555555555"}"#,
        #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"},"session_id":"11111111-2222-3333-4444-555555555555"}"#,
        #"{"type":"result","subtype":"success","is_error":false,"duration_ms":1194,"num_turns":1,"session_id":"11111111-2222-3333-4444-555555555555","total_cost_usd":0.014992,"usage":{"input_tokens":10,"cache_creation_input_tokens":6496,"cache_read_input_tokens":17900,"output_tokens":40},"permission_denials":[]}"#,
    ]

    let observedAt = Date(timeIntervalSinceReferenceDate: 123)
    var translator = ClaudeEventTranslator(runToken: "run1", now: { observedAt })
    let events = translator.translate(stream: fixture)

    let expected: [AgentRuntimeEvent] = [
        .sessionStateChanged(.ready),
        .sessionStateChanged(.running),
        .turnStarted(threadId: claudeSID, turnId: "\(claudeSID)#run1-t1"),
        .contentDelta(threadId: claudeSID, turnId: "\(claudeSID)#run1-t1", streamKind: .reasoning, delta: "checking"),
        .contentDelta(threadId: claudeSID, turnId: "\(claudeSID)#run1-t1", streamKind: .assistant, delta: "hello"),
        .contentDelta(threadId: claudeSID, turnId: "\(claudeSID)#run1-t1", streamKind: .assistant, delta: " world"),
        .itemStarted(threadId: claudeSID, itemId: "toolu_01", kind: .commandExecution, title: "Bash"),
        .itemCompleted(threadId: claudeSID, itemId: "toolu_01", kind: .commandExecution, status: .completed),
        // Occupancy, from that one request: 4 + 1,200 + 17,900 = 19,104.
        .contextWindowUpdated(threadId: claudeSID, snapshot: AgentContextWindowSnapshot(
            usedTokens: nil,
            maxTokens: nil,
            inputTokens: 4,
            outputTokens: 12,
            cacheReadTokens: 17900,
            cacheWriteTokens: 1200,
            totalProcessedTokens: nil,
            totalCostUsd: nil,
            automaticCompaction: nil,
            observedAt: observedAt,
            source: .claudeAssistantUsage,
            freshness: .live)),
        .itemStarted(threadId: claudeSID, itemId: "toolu_02", kind: .fileChange, title: "Edit"),
        .itemCompleted(threadId: claudeSID, itemId: "toolu_02", kind: .fileChange, status: .failed),
        .tokenUsageUpdated(threadId: claudeSID, snapshot: TokenUsageSnapshot(
            inputTokens: 24406, outputTokens: 40, totalCostUsd: 0.014992)),
        // The result's OWN counters (10 / 17,900 / 6,496) are the run's sum and
        // are cost accounting, published as `totalProcessedTokens`/cost. The
        // occupancy carried here is still the last request's, so closing a turn
        // does not blank the ring — and does not paint the sum.
        .contextWindowUpdated(threadId: claudeSID, snapshot: AgentContextWindowSnapshot(
            usedTokens: nil,
            maxTokens: nil,
            inputTokens: 4,
            outputTokens: 40,
            cacheReadTokens: 17900,
            cacheWriteTokens: 1200,
            totalProcessedTokens: 24446,
            totalCostUsd: 0.014992,
            automaticCompaction: nil,
            observedAt: observedAt,
            source: .claudeAssistantUsage,
            freshness: .live)),
        .turnCompleted(threadId: claudeSID, turnId: "\(claudeSID)#run1-t1", outcome: .completed, errorMessage: nil),
        .sessionStateChanged(.ready),
    ]

    // 1. Exact mapping — sequence, threadId capture, deltas-not-bodies, the
    //    tool round-trips, the summed usage, the sub-agent skip.
    expect(events == expected,
           "ClaudeEventTranslator: mapping must equal the expected sequence.\n  got: \(events)\n  want: \(expected)")

    // 2. Assistant text arrived ONCE (as deltas) though the fixture carries
    //    the same prose again in the assistant message.
    let assistantText = events.compactMap { event -> String? in
        if case let .contentDelta(_, _, streamKind, delta) = event, streamKind == .assistant { return delta }
        return nil
    }.joined()
    expect(assistantText == "hello world",
           "ClaudeEventTranslator: assistant prose must stream exactly once, got \(assistantText)")

    // 3. I5 by construction — no cwd, command, tool output, error body, or
    //    sub-agent payload in any encoded event; tool names survive as titles.
    let encoded = String(decoding: try! JSONEncoder().encode(events), as: UTF8.self)
    for secret in ["SECRET-PATH", "SECRET-COMMAND", "SECRET-TOOL-OUTPUT", "SECRET-ERROR-BODY", "SECRET-SUBAGENT-COMMAND", "toolu_sub"] {
        expect(!encoded.contains(secret), "ClaudeEventTranslator I5: \(secret) crossed into the events")
    }
    expect(encoded.contains("Bash") && encoded.contains("Edit"),
           "ClaudeEventTranslator: tool names must survive as item titles")

    // 4. The whitelisted observation side channel projects the edit target
    //    (and only through it — assertion 3 already proved the events stay
    //    clean).
    final class ObservationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var observations: [AgentRuntimeObservation] = []
        func append(_ observation: AgentRuntimeObservation) {
            lock.withLock { observations.append(observation) }
        }
        func snapshot() -> [AgentRuntimeObservation] {
            lock.withLock { observations }
        }
    }
    let box = ObservationBox()
    var observing = ClaudeEventTranslator(runToken: "run1", now: { observedAt })
    observing.onRuntimeObservation = { box.append($0) }
    _ = observing.translate(stream: fixture)
    let observed = box.snapshot()
    let editTargets = observed.compactMap { observation -> String? in
        guard case let .toolActivity(_, activity) = observation,
              activity.operation == .editing else { return nil }
        return activity.targetPath?.path
    }
    expect(editTargets == ["/private/tmp/SECRET-PATH/notes.txt"],
           "ClaudeEventTranslator: the edit target must project out of band, got \(editTargets)")
    let observedDirectories = observed.compactMap { observation -> String? in
        guard case let .workingDirectory(url, _) = observation else { return nil }
        return url.path
    }
    expect(observedDirectories == ["/private/tmp/SECRET-PATH/claude-probe"],
           "ClaudeEventTranslator: init.cwd must project out of band, got \(observedDirectories)")

    // B7.1 — the same side channel carries claude's own reported session id,
    // so a later `--fork-session` can be adopted instead of re-derived. The
    // event's own threadId cannot carry this (the supervisor rebinds it to
    // the agent's derived id before delivery), hence the observation.
    let observedProviderSessionIds = observed.compactMap { observation -> String? in
        guard case let .providerSessionId(value) = observation else { return nil }
        return value
    }
    expect(observedProviderSessionIds == [claudeSID],
           "ClaudeEventTranslator: system/init's session_id must project out of band as .providerSessionId, got \(observedProviderSessionIds)")

    // 5. `.plans/45` S2 — the toolDetail supply. One started+ended pair per
    //    TOP-LEVEL tool in stream order (sub-agent frames still skipped); the
    //    edit start carries the basename only; the result body rides as the
    //    bounded outputPreview; and a Bash start carries NO field — the
    //    command body never crosses even on the host-local channel.
    let details = observed.compactMap { observation -> (String, AgentToolDetailObservation)? in
        guard case let .toolDetail(itemId, detail) = observation else { return nil }
        return (itemId, detail)
    }
    expect(details.map(\.0) == ["toolu_01", "toolu_01", "toolu_02", "toolu_02"],
           "ClaudeEventTranslator: expected a started+ended detail pair per top-level tool, got \(details.map(\.0))")
    expect(details.map(\.1.phase) == [.started, .ended, .started, .ended],
           "ClaudeEventTranslator: detail phases out of order: \(details.map(\.1.phase))")
    expect(details[0].1.fields.isEmpty && details[0].1.toolName == "Bash",
           "ClaudeEventTranslator: a Bash start must carry no detail fields, got \(details[0].1.fields)")
    expect(details[1].1.outputPreview == "SECRET-TOOL-OUTPUT",
           "ClaudeEventTranslator: the tool_result body must ride as the bounded outputPreview, got \(String(describing: details[1].1.outputPreview))")
    expect(details[2].1.fields.map { "\($0.key)=\($0.value)" } == ["file=notes.txt"],
           "ClaudeEventTranslator: an Edit start must carry the basename only, got \(details[2].1.fields)")
    let detailDescription = String(describing: details)
    for secret in ["SECRET-COMMAND", "SECRET-SUBAGENT-COMMAND", "SECRET-PATH", "toolu_sub"] {
        expect(!detailDescription.contains(secret),
               "ClaudeEventTranslator: \(secret) leaked into the toolDetail channel")
    }

    print("ClaudeEventTranslator checks passed: \(events.count) events from the real claude 2.1.226 stream-json schema map exactly, text streams once, sub-agent frames skipped, I5-safe by construction")
}

private func runClaudeTranslatorGateChecks() {
    // The `--resume <unknown id>` failure shape, captured live: the process
    // emits ONLY an error result (no init) and exits 1. The translator must
    // stay silent so the runner's --session-id retry paints no spurious turn.
    var translator = ClaudeEventTranslator(runToken: "run1")
    let orphanResult = translator.translate(line:
        #"{"type":"result","subtype":"error_during_execution","duration_ms":0,"duration_api_ms":0,"is_error":true,"num_turns":0,"session_id":"11111111-2222-3333-4444-555555555555","total_cost_usd":0,"usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}"#
    )
    expect(orphanResult.isEmpty,
           "ClaudeEventTranslator: a result before any init is the failed-resume shape and must emit nothing, got \(orphanResult)")

    // After a real init, an error result completes the turn as failed with
    // the SUBTYPE as the message (never the body) and publishes no zero usage.
    var failing = ClaudeEventTranslator(runToken: "run1")
    _ = failing.translate(line:
        #"{"type":"system","subtype":"init","cwd":"/private/tmp/x","session_id":"11111111-2222-3333-4444-555555555555","model":"claude-haiku-4-5-20251001"}"#)
    let errorEvents = failing.translate(line:
        #"{"type":"result","subtype":"error_max_turns","is_error":true,"num_turns":8,"session_id":"11111111-2222-3333-4444-555555555555","total_cost_usd":0,"usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0},"result":"SECRET-RESULT-BODY"}"#)
    expect(errorEvents == [
        .turnCompleted(threadId: claudeSID, turnId: "\(claudeSID)#run1-t1", outcome: .failed, errorMessage: "error_max_turns"),
        .sessionStateChanged(.ready),
    ], "ClaudeEventTranslator: error result must fail the turn with the subtype and skip zero usage, got \(errorEvents)")

    print("ClaudeEventTranslator gate checks passed: failed-resume shape silent, error results carry the subtype only")
}

// B6.1: `compact_boundary` used to fall through the `subtype == "init"` gate
// with every other non-init system frame, so an automatic compaction left the
// context ring showing the pre-compaction percentage indefinitely. Replayed
// against the real frame captured live (claude 2.1.241, `/compact` on a
// resumed session; see Fixtures/claude-compact-boundary.jsonl) — with the old
// `guard subtype == "init" else { return [] }` restored, this fixture
// produces ZERO events (not "wrong number"), which is the failure this check
// must catch.
private func runClaudeCompactBoundaryChecks() {
    let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/claude-compact-boundary.jsonl", isDirectory: false)
    guard let text = try? String(contentsOf: fixtureURL, encoding: .utf8) else {
        expect(false, "ClaudeEventTranslator: the committed compact_boundary capture is missing")
        return
    }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    expect(lines.count == 3,
           "ClaudeEventTranslator: the compact_boundary fixture must carry init + an ordinary status frame + the boundary, got \(lines.count) lines")

    let sid = "00000000-0000-4000-8000-000000000001"
    let observedAt = Date(timeIntervalSinceReferenceDate: 456)
    var translator = ClaudeEventTranslator(runToken: "run1", now: { observedAt })

    // Line 1 (init) starts the session/turn as usual.
    let initEvents = translator.translate(line: lines[0])
    expect(initEvents.count == 3,
           "ClaudeEventTranslator: init must still emit its usual 3 events, got \(initEvents.count)")

    // Line 2: Claude announces the in-progress interval separately from the
    // eventual boundary. It must become a running lifecycle event without
    // creating a transcript item or completing the surrounding turn.
    let statusEvents = translator.translate(line: lines[1])
    guard case .compactionChanged(let statusThreadID, let running)? = statusEvents.first else {
        expect(false,
               "ClaudeEventTranslator: system/status compacting must emit a running lifecycle event, got \(statusEvents)")
        return
    }
    expect(statusEvents.count == 1 && statusThreadID == sid && running.phase == .running
               && running.trigger == .providerAutomatic && running.provider == "claude",
           "ClaudeEventTranslator: compacting status must only announce the running provider lifecycle, got \(statusEvents)")

    // Line 3: the real compact_boundary frame must produce the B6.2 compaction
    // item (begin/finish, real pre/post tokens from `compact_metadata`) plus
    // the one contextWindowUpdated built from `post_tokens`/`trigger`.
    let compactEvents = translator.translate(line: lines[2])
    let compactionKind = ItemKind.compaction
    let boundaryID = "00000000-0000-4000-8000-000000000202"
    let compactionTitle = AgentCompactionPayload.encodeTitle(
        preTokens: 26268,
        postTokens: 2140,
        automaticCompaction: false,
        provider: "claude",
        boundaryID: boundaryID,
        trigger: "manual")
    guard case .compactionChanged(let boundaryThreadID, let boundary)? = compactEvents.first else {
        expect(false,
               "ClaudeEventTranslator: compact_boundary must begin with a successful lifecycle event, got \(compactEvents)")
        return
    }
    expect(boundaryThreadID == sid && boundary.phase == .succeeded
               && boundary.boundaryID == boundaryID
               && boundary.trigger == .manual
               && boundary.beforeTokens == AgentCompactionTokenReading(26268, precision: .exact)
               && boundary.afterTokens == AgentCompactionTokenReading(2140, precision: .exact),
           "ClaudeEventTranslator: compact_boundary must preserve its stable identity, manual trigger, and exact counts, got \(boundary)")
    expect(Array(compactEvents.dropFirst()) == [
        .itemStarted(threadId: sid, itemId: boundaryID, kind: compactionKind, title: compactionTitle),
        .itemCompleted(threadId: sid, itemId: boundaryID, kind: compactionKind, status: .completed),
        .contextWindowUpdated(threadId: sid, snapshot: AgentContextWindowSnapshot(
            usedTokens: 2140,
            maxTokens: nil,
            automaticCompaction: false,
            observedAt: observedAt,
            source: .claudeCompactBoundary,
            freshness: .live)),
    ], "ClaudeEventTranslator: compact_boundary must emit the compaction item pair (real pre/post tokens) then contextWindowUpdated, got \(compactEvents)")

    print("ClaudeEventTranslator compact_boundary checks passed: compacting status maps to running and the captured boundary maps to success, a compaction item, and context telemetry")
}

// The context ring was empty for EVERY claude agent, always. Not a rendering
// bug: there was no denominator. `AgentModelCatalog`'s window map is keyed by
// concrete model ids (`anthropic/claude-opus-5`), but the Claude harness offers
// three ALIASES — `anthropic/opus`, `anthropic/sonnet`, `anthropic/haiku` — and
// the tile looked the window up by the alias, which is not a key. Miss, nil
// maxTokens, `occupancyFraction` nil, empty ring.
//
// Guessing which concrete model an alias means would be worse than an empty
// ring: `anthropic/claude-opus-4-5` is a 200k window and `anthropic/claude-opus-5`
// is 1M, so a wrong guess misreports occupancy by 5x. claude states the resolved
// id itself on `system/init`; the translator dropped it. It now rides the
// runtime-observation side channel, qualified with its provider.
private func runClaudeResolvedModelContextWindowChecks() {
    let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/claude-compact-boundary.jsonl", isDirectory: false)
    guard let text = try? String(contentsOf: fixtureURL, encoding: .utf8),
          let initLine = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) else {
        expect(false, "resolved-model: the committed claude capture is missing")
        return
    }

    final class ObservationSink: @unchecked Sendable {
        let lock = NSLock()
        var values: [AgentRuntimeObservation] = []
        func append(_ value: AgentRuntimeObservation) { lock.lock(); values.append(value); lock.unlock() }
    }
    let sink = ObservationSink()
    var translator = ClaudeEventTranslator(runToken: "run1", now: { Date(timeIntervalSinceReferenceDate: 456) })
    translator.onRuntimeObservation = { sink.append($0) }
    _ = translator.translate(line: initLine)
    let observations = sink.values

    // The fixture's init frame carries `"model":"claude-fable-5"`.
    expect(observations.contains(.resolvedModel("anthropic/claude-fable-5")),
           "resolved-model: init must report the concrete model, provider-qualified for the catalogue; got \(observations)")

    // The real shape of pi's models-store, through the PRODUCTION parser, with
    // the two windows that make the alias guess dangerous.
    let store = Data("""
    {"anthropic":{"models":[
      {"id":"claude-fable-5","contextWindow":1000000},
      {"id":"claude-opus-5","contextWindow":1000000},
      {"id":"claude-opus-4-5","contextWindow":200000}
    ]}}
    """.utf8)
    let windows = AgentModelCatalog.parse(modelsStoreContextWindows: store)

    // THE BUG, stated as a contrast: the alias the user picks is not a key.
    expect(windows["anthropic/opus"] == nil,
           "resolved-model: the fixture must keep the alias unkeyed, or this witnesses nothing")
    expect(windows["anthropic/claude-fable-5"] == 1_000_000,
           "resolved-model: the production parser must key the concrete id; got \(String(describing: windows["anthropic/claude-fable-5"]))")
    // Two concrete opus ids, 5x apart. This is why an alias is never guessed.
    expect(windows["anthropic/claude-opus-5"] == 1_000_000 && windows["anthropic/claude-opus-4-5"] == 200_000,
           "resolved-model: the fixture must keep a 1M and a 200k model apart")

    // End to end: a real claude per-request `assistant` usage block over the
    // resolved window produces a real percentage. Occupancy is the prompt —
    // fresh input plus both cache counters — never the output, and never the
    // `result` block, which sums every request of the run (see
    // `runClaudeContextOccupancyChecks`).
    let turn = AgentContextWindowSnapshot(
        inputTokens: 1_000, outputTokens: 5_000,
        cacheReadTokens: 240_000, cacheWriteTokens: 9_000,
        observedAt: Date(timeIntervalSinceReferenceDate: 456),
        source: .claudeAssistantUsage, freshness: .live)
    expect(AgentContextOccupancy.promptTokens(from: turn) == 250_000,
           "resolved-model: claude prompt tokens must sum input + cacheRead + cacheWrite")
    // `usedTokens`/`maxTokens` are the two fields the meter divides
    // (`AgentRadialContextMeterPresenter.occupancyArithmetic`); the stricter
    // `occupancyFraction` accessor additionally demands an authoritative source
    // and is NOT what the ring reads.
    let derived = AgentContextOccupancy.withDerivedOccupancy(
        turn, contextWindow: windows["anthropic/claude-fable-5"])
    expect(derived.usedTokens == 250_000 && derived.maxTokens == 1_000_000,
           "resolved-model: the resolved window must fill both meter fields; got used=\(String(describing: derived.usedTokens)) max=\(String(describing: derived.maxTokens))")

    // WITHOUT a window — the shipped behaviour for every claude agent — the
    // meter has nothing to divide and the ring is empty. This is the bug.
    let unresolved = AgentContextOccupancy.withDerivedOccupancy(
        turn, contextWindow: windows["anthropic/opus"])
    expect(unresolved.maxTokens == nil,
           "resolved-model: an unresolved alias must leave the ring empty, never invent a denominator")

    // The same turn against the WRONG concrete model reads 125% instead of 25%.
    // This is why an alias is resolved from what claude reported and never guessed.
    let wrong = AgentContextOccupancy.withDerivedOccupancy(
        turn, contextWindow: windows["anthropic/claude-opus-4-5"])
    expect(wrong.usedTokens == 250_000 && wrong.maxTokens == 200_000,
           "resolved-model: the contrast case must show the 5x error a guessed window causes")

    print("Claude resolved-model context window checks passed: init reports the concrete id, the alias is not a catalogue key, and a real result usage block fills the meter at 250k/1M from the resolved id, stays empty on the alias, and would read 250k/200k against a guessed one")
}

private func runClaudeRunnerArgvChecks() {
    #if os(macOS)
    // The exact argv, both session modes. `--verbose` is required by the CLI
    // for stream-json in print mode; the session flag is the resume/create
    // switch the two-attempt strategy pivots on.
    let resume = ClaudeAgentRunner.processArguments(
        model: "claude-haiku-4-5-20251001",
        effort: "high",
        sessionMode: .resume,
        sessionId: claudeSID,
        extraArgs: [],
        prompt: AgentPrompt("do the thing")
    )
    expect(resume == [
        "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
        "--include-hook-events",
        // C7: without this the stream carries a subagent's tool_use/tool_result
        // blocks and nothing it SAID, so a child transcript is tool calls with no
        // answer in them. Pinned in the exact argv because that is the only place
        // a silently-dropped flag would show up.
        "--forward-subagent-text",
        "--model", "claude-haiku-4-5-20251001",
        "--effort", "high",
        "--resume", claudeSID,
        "do the thing",
    ], "ClaudeAgentRunner argv (resume) drifted: \(resume)")

    let start = ClaudeAgentRunner.processArguments(
        model: "claude-haiku-4-5-20251001",
        effort: nil,
        sessionMode: .start,
        sessionId: claudeSID,
        extraArgs: ["--extra"],
        prompt: AgentPrompt("first turn")
    )
    expect(start == [
        "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
        "--include-hook-events",
        // C7: without this the stream carries a subagent's tool_use/tool_result
        // blocks and nothing it SAID, so a child transcript is tool calls with no
        // answer in them. Pinned in the exact argv because that is the only place
        // a silently-dropped flag would show up.
        "--forward-subagent-text",
        "--model", "claude-haiku-4-5-20251001",
        "--session-id", claudeSID,
        "--extra",
        "first turn",
    ], "ClaudeAgentRunner argv (start) drifted: \(start)")

    // Executable resolution mirrors pi's GUI-thin-PATH strategy.
    let absolute = ClaudeAgentRunner.resolvedCommand(
        pathDirs: ["/usr/bin"],
        extraDirs: ["/Users/qa/.local/bin"],
        fileExists: { $0 == "/Users/qa/.local/bin/claude" })
    expect(absolute == PiAgentRunner.ResolvedCommand(executable: "/Users/qa/.local/bin/claude", prefixArgs: []),
           "ClaudeAgentRunner: an installed claude must resolve absolutely, got \(absolute)")
    let fallback = ClaudeAgentRunner.resolvedCommand(
        pathDirs: ["/usr/bin"], extraDirs: [], fileExists: { _ in false })
    expect(fallback == PiAgentRunner.ResolvedCommand(executable: "/usr/bin/env", prefixArgs: ["claude"]),
           "ClaudeAgentRunner: missing claude must fall back to env, got \(fallback)")
    #endif

    // Both live-captured stderr shapes, ANSI-styled as claude emits them.
    expect(ClaudeCLIBackend.isUnknownSessionFailure(
        stderr: "No conversation found with session ID: \(claudeSID)\n"),
        "ClaudeCLIBackend: the unknown-session stderr must trigger the retry")
    expect(ClaudeCLIBackend.isSessionInUseFailure(
        stderr: "\u{1B}[0m\u{1B}[31m\u{1B}[31mError: Session ID \(claudeSID) is already in use.\u{1B}[39m\u{1B}[0m\n"),
        "ClaudeCLIBackend: the session-in-use stderr must be recognised through its ANSI styling")
    expect(!ClaudeCLIBackend.isUnknownSessionFailure(stderr: "Invalid API key"),
           "ClaudeCLIBackend: unrelated failures must not trigger the session retry")

    // THE ORDERING, and why it is a check rather than a comment: an agent with no
    // recorded turn used to spawn a whole `claude --resume` process purely to be
    // told the conversation did not exist, in front of the user's first prompt. A
    // regression here is invisible — the turn still works, it just wastes a CLI
    // launch — so the decision is pinned instead of observed.
    let fresh = ClaudeCLIBackend.sessionModeOrder(conversationMayExist: false)
    expect(fresh == (.start, .resume),
           "ClaudeCLIBackend: an agent with no conversation must CREATE first, got \(fresh)")
    let established = ClaudeCLIBackend.sessionModeOrder(conversationMayExist: true)
    expect(established == (.resume, .start),
           "ClaudeCLIBackend: an established conversation must RESUME first, got \(established)")

    // Self-healing in both directions: each mode retries on exactly the failure
    // that means the belief was wrong, and on nothing else.
    expect(ClaudeCLIBackend.retryIsWarranted(
        after: .resume, stderr: "No conversation found with session ID: \(claudeSID)\n"),
        "ClaudeCLIBackend: a resume of a missing conversation must retry as create")
    expect(ClaudeCLIBackend.retryIsWarranted(
        after: .start, stderr: "Error: Session ID \(claudeSID) is already in use.\n"),
        "ClaudeCLIBackend: a create over an existing conversation must retry as resume")
    expect(!ClaudeCLIBackend.retryIsWarranted(
        after: .start, stderr: "No conversation found with session ID: \(claudeSID)\n"),
        "ClaudeCLIBackend: a create must not retry on the resume failure — that would spawn a second doomed process")
    expect(!ClaudeCLIBackend.retryIsWarranted(
        after: .resume, stderr: "Error: Session ID \(claudeSID) is already in use.\n"),
        "ClaudeCLIBackend: a resume must not retry on the create failure")
    for mode in [ClaudeSessionMode.resume, .start] {
        expect(!ClaudeCLIBackend.retryIsWarranted(after: mode, stderr: "Invalid API key"),
               "ClaudeCLIBackend: \(mode) must treat an auth failure as terminal, not retry it")
    }

    print("ClaudeAgentRunner argv checks passed: both session modes pinned, resolution mirrors pi, failure predicates match the captured stderr, fresh agents create before resuming and each direction retries only its own failure")
}

private func runClaudeBackendPolicyChecks() {
    // Routing: anthropic models prefer the claude CLI exactly when the
    // machine has it; everything else stays on pi.
    expect(ClaudeCLIBackend.routesToClaude(model: "anthropic/claude-opus-5", claudeCLIAvailable: true),
           "ClaudeCLIBackend: anthropic + claude present must route to claude")
    expect(!ClaudeCLIBackend.routesToClaude(model: "anthropic/claude-opus-5", claudeCLIAvailable: false),
           "ClaudeCLIBackend: anthropic without claude must stay on pi")
    expect(!ClaudeCLIBackend.routesToClaude(model: "openai-codex/gpt-5.6", claudeCLIAvailable: true),
           "ClaudeCLIBackend: non-anthropic models must stay on pi")

    // Model argument: the catalogue prefix is Array's namespacing, never sent.
    expect(ClaudeCLIBackend.modelArgument(forCatalogId: "anthropic/claude-opus-5") == "claude-opus-5",
           "ClaudeCLIBackend: the provider prefix must be stripped")
    expect(ClaudeCLIBackend.modelArgument(forCatalogId: "opus") == "opus",
           "ClaudeCLIBackend: a bare alias passes through")

    // Effort: exact pass-through or omission — never an invented mapping.
    expect(ClaudeCLIBackend.effortArgument(forThinking: "high") == "high",
           "ClaudeCLIBackend: matching thinking levels pass through as effort")
    expect(ClaudeCLIBackend.effortArgument(forThinking: "xhigh") == "xhigh",
           "ClaudeCLIBackend: xhigh passes through")
    expect(ClaudeCLIBackend.effortArgument(forThinking: "off") == nil,
           "ClaudeCLIBackend: pi-only levels omit the flag")
    expect(ClaudeCLIBackend.effortArgument(forThinking: "minimal") == nil,
           "ClaudeCLIBackend: minimal omits the flag")

    print("ClaudeCLIBackend policy checks passed: routing, model-argument stripping, and effort pass-through pinned")
}

private func runClaudeCatalogUnionChecks() {
    // The claude backend UNIONS into the catalogue: pi's list (or the frozen
    // fallback) keeps standing, the curated aliases append, and losing the
    // CLI clears them again. QA instances never probe, so this is all
    // fixture-driven.
    let catalog = AgentModelCatalog()
    catalog.resetForQA(options: ["openai-codex/gpt-5.6", "anthropic/opus"])
    catalog.apply(claudeBackendAvailable: true)
    expect(catalog.options() == ["openai-codex/gpt-5.6", "anthropic/opus", "anthropic/sonnet", "anthropic/haiku"],
           "AgentModelCatalog: claude entries must append without duplicating ids already present, got \(catalog.options())")
    expect(catalog.displayName(for: "anthropic/sonnet") == "Claude Sonnet (latest)",
           "AgentModelCatalog: claude aliases must carry their curated display names")

    // pi's display names win when both know an id (pi's are model-specific).
    catalog.apply(displayNames: ["anthropic/sonnet": "Sonnet from pi"])
    expect(catalog.displayName(for: "anthropic/sonnet") == "Sonnet from pi",
           "AgentModelCatalog: pi display names must take precedence over curated ones")

    catalog.apply(claudeBackendAvailable: false)
    expect(catalog.options() == ["openai-codex/gpt-5.6", "anthropic/opus"],
           "AgentModelCatalog: an uninstalled/logged-out claude must clear its entries, got \(catalog.options())")

    catalog.resetForQA()
    expect(catalog.options(fallback: ["frozen/id"]) == ["frozen/id"],
           "AgentModelCatalog: resetForQA must clear claude entries too, got \(catalog.options(fallback: ["frozen/id"]))")

    // The auth-status parse, against the real `claude auth status --json`
    // shape captured live on 2026-08-09.
    let loggedIn = #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","email":"user@example.com","subscriptionType":"team"}"#
    expect(ClaudeCLIBackend.isLoggedIn(authStatusJSON: Data(loggedIn.utf8)),
           "ClaudeCLIBackend: the real logged-in shape must read as logged in")
    expect(!ClaudeCLIBackend.isLoggedIn(authStatusJSON: Data(#"{"loggedIn":false}"#.utf8)),
           "ClaudeCLIBackend: loggedIn=false must read as logged out")
    expect(!ClaudeCLIBackend.isLoggedIn(authStatusJSON: Data("not json".utf8)),
           "ClaudeCLIBackend: garbage output must read as logged out")

    print("AgentModelCatalog claude-union checks passed: append/clear semantics, pi name precedence, QA reset, auth-status parse pinned")
}

/// Claude's context OCCUPANCY must come from a per-request `assistant` frame,
/// never from `result.usage`.
///
/// The reported defect: the ring read **348%**. `result.usage` sums every API
/// request the run made — an agentic turn issues one per tool round trip, and
/// each re-reads the whole conversation from cache — so its summed cache
/// counters are a multiple of anything the model ever held at once. This is the
/// codex 237% trap in a second costume, and the source's own doc comment already
/// said "per-turn aggregate … not occupancy" while this code summed it anyway.
///
/// Replayed against the committed capture, whose numbers make the difference
/// arithmetic rather than rhetorical:
///
/// | frame | input | cache write | cache read | prompt |
/// |---|---|---|---|---|
/// | last MAIN assistant | 2 | 491 | 25,588 | **26,081** |
/// | a SUBAGENT assistant | 2 | 898 | 12,765 | 13,665 |
/// | `result` (the sum) | 4 | 9,586 | 42,081 | 51,671 |
///
/// A witness that only asserted "occupancy is not nil" passes on all three.
func runClaudeContextOccupancyChecks() {
    let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/claude-subagent-turn.jsonl", isDirectory: false)
    guard let text = try? String(contentsOf: fixtureURL, encoding: .utf8) else {
        expect(false, "claude occupancy: the committed subagent capture is missing")
        return
    }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    // The child channel has to be read too. Subagent events never appear in the
    // parent's returned list — the translator routes them here instead — so an
    // assertion about a child that only inspects the parent's list is vacuous.
    // Mutating the `!isSubagent` guard away proved exactly that: the check
    // stayed green.
    final class ChildSink: @unchecked Sendable {
        let lock = NSLock()
        var events: [(String, AgentRuntimeEvent)] = []
        func append(_ parent: String, _ event: AgentRuntimeEvent) {
            lock.lock(); events.append((parent, event)); lock.unlock()
        }
    }
    let childSink = ChildSink()
    var translator = ClaudeEventTranslator(runToken: "run1", now: { Date(timeIntervalSinceReferenceDate: 99) })
    translator.onSubagentEvent = { childSink.append($0, $1) }
    let events = translator.translate(stream: lines)

    var snapshots: [AgentContextWindowSnapshot] = []
    for event in events {
        if case let .contextWindowUpdated(_, snapshot) = event { snapshots.append(snapshot) }
    }

    // CONTROL. The capture must actually carry usage, or every assertion below
    // is satisfied by a translator that emits nothing at all.
    expect(!snapshots.isEmpty, "claude occupancy control: the capture produced no context snapshots")
    expect(snapshots.allSatisfy { $0.source == .claudeAssistantUsage },
           "claude occupancy: every published snapshot must come from a per-request assistant "
           + "frame; got \(snapshots.map(\.source))")

    // The reading the meter will use is the LAST one published.
    guard let latest = snapshots.last else { return }
    let occupancy = AgentContextOccupancy.promptTokens(from: latest)
    expect(occupancy == 26_081,
           "claude occupancy: the ring must read the last MAIN request's prompt (26,081), not "
           + "the run's summed 51,671 and not a subagent's 13,665; got \(String(describing: occupancy))")

    // A subagent's context is a different conversation, and an adopted child is
    // `observedReadOnly` with no model of its own, so there is no window to
    // divide its prompt by. Neither surface may carry one.
    let published = snapshots.compactMap { AgentContextOccupancy.promptTokens(from: $0) }
    expect(!published.contains(13_665),
           "claude occupancy: a subagent's own prompt reached the parent's meter; got \(published)")
    // CONTROL: the child channel must have carried real traffic, or the next
    // assertion is satisfied by a capture with no subagent in it.
    expect(!childSink.events.isEmpty,
           "claude occupancy control: the capture produced no subagent events at all")
    let childContext = childSink.events.compactMap { pair -> AgentContextWindowSnapshot? in
        if case let .contextWindowUpdated(_, snapshot) = pair.1 { return snapshot }
        return nil
    }
    expect(childContext.isEmpty,
           "claude occupancy: an adopted child must get no occupancy reading of its own — there "
           + "is no window on file to divide it by; got \(childContext.count) snapshot(s)")
    expect(!published.contains(51_671),
           "claude occupancy: the run's summed result usage reached the meter; got \(published)")

    // The result frame still has to publish COST, which is what it is genuinely
    // for. Losing it would trade one defect for another.
    var usageSnapshots: [TokenUsageSnapshot] = []
    for event in events {
        if case let .tokenUsageUpdated(_, snapshot) = event { usageSnapshots.append(snapshot) }
    }
    expect(usageSnapshots.last?.inputTokens == 51_671,
           "claude occupancy: cost accounting still wants the run's SUM; got "
           + "\(String(describing: usageSnapshots.last?.inputTokens))")
    expect(latest.totalProcessedTokens == 52_001,
           "claude occupancy: the meter's detail text keeps the run's processed total; got "
           + "\(String(describing: latest.totalProcessedTokens))")

    // And the percentage the ring actually paints, through the production
    // denominator. 26,081 of a 200k window is 13% — not 26%, which is what the
    // summed number would have painted against the same window.
    let derived = AgentContextOccupancy.withDerivedOccupancy(latest, contextWindow: 200_000)
    expect(derived.usedTokens == 26_081 && derived.maxTokens == 200_000,
           "claude occupancy: derived reading must be 26,081/200,000; got "
           + "\(String(describing: derived.usedTokens))/\(String(describing: derived.maxTokens))")

    // A legacy record persisted while the summed number was believed must not
    // keep painting it: a result-sourced snapshot is sanitized, never trusted.
    let legacy = AgentContextWindowSnapshot(
        usedTokens: 696_000, maxTokens: 200_000,
        observedAt: Date(timeIntervalSinceReferenceDate: 0),
        source: .claudeResultUsage, freshness: .live)
    let sanitized = AgentContextOccupancy.withDerivedOccupancy(legacy, contextWindow: 200_000)
    expect(sanitized.usedTokens == nil && sanitized.maxTokens == nil,
           "claude occupancy: a stored result-usage occupancy must be dropped, not re-published; "
           + "got \(String(describing: sanitized.usedTokens))/\(String(describing: sanitized.maxTokens))")

    print("Claude context occupancy checks passed: the real capture reads 26,081 from its last "
          + "main-thread request (13% of 200k), never the run's summed 51,671 (the 348% reading) "
          + "and never the subagent's 13,665; cost accounting keeps the sum")
}
