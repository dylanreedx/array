import ContinuumRevivedCore
import Foundation

// Plan: .plans/01-provider-cli-backends.md (claude CLI backend, first slice).
//
// Pins the claude → AgentRuntimeEvent mapping against the REAL stream-json
// schema captured live from claude 2.1.226 on 2026-08-09 (`-p --output-format
// stream-json --verbose --include-partial-messages`, haiku turns with a Bash
// tool round-trip). Fixture lines are the actual shapes, curated and with the
// cwd/command/output payloads kept deliberately "secret" so the I5 assertion
// has something to catch. Also pins the runner's argv, the resume-first
// failure predicates (both stderr shapes captured live), and the backend
// routing policy.
func runClaudeAgentBackendChecks() {
    runClaudeTranslatorMappingChecks()
    runClaudeTranslatorGateChecks()
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
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_02","name":"Edit","input":{"file_path":"/private/tmp/SECRET-PATH/notes.txt","old_string":"a","new_string":"b"}}]},"parent_tool_use_id":null,"session_id":"11111111-2222-3333-4444-555555555555"}"#,
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
        .itemStarted(threadId: claudeSID, itemId: "toolu_02", kind: .fileChange, title: "Edit"),
        .itemCompleted(threadId: claudeSID, itemId: "toolu_02", kind: .fileChange, status: .failed),
        .tokenUsageUpdated(threadId: claudeSID, snapshot: TokenUsageSnapshot(
            inputTokens: 24406, outputTokens: 40, totalCostUsd: 0.014992)),
        .contextWindowUpdated(threadId: claudeSID, snapshot: AgentContextWindowSnapshot(
            usedTokens: nil,
            maxTokens: nil,
            inputTokens: 10,
            outputTokens: 40,
            cacheReadTokens: 17900,
            cacheWriteTokens: 6496,
            totalProcessedTokens: 24446,
            totalCostUsd: 0.014992,
            automaticCompaction: nil,
            observedAt: observedAt,
            source: .claudeResultUsage,
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
        "--model", "claude-haiku-4-5-20251001",
        "--effort", "high",
        "--dangerously-skip-permissions",
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
        "--model", "claude-haiku-4-5-20251001",
        "--dangerously-skip-permissions",
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
