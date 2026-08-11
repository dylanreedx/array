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
    runCodexTranslatorGateChecks()
    runCodexRunnerArgvChecks()
    runCodexBackendPolicyChecks()
    runCodexCatalogUnionChecks()
}

private let codexTID = "019fe980-21f0-7df1-b2a0-49d7839c7937"

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
        // `token_count` arrives DURING the turn and is the only per-request
        // reading codex gives. Shape copied from a real rollout in
        // ~/.codex/sessions: `last_token_usage` is this request,
        // `total_token_usage` is the whole session, and the provider states its
        // own window. Deriving occupancy from the cumulative block is what put
        // 237% on the meter.
        #"{"type":"token_count","info":{"total_token_usage":{"input_tokens":643673,"cached_input_tokens":557824,"cache_write_input_tokens":0,"output_tokens":3938,"reasoning_output_tokens":1700,"total_tokens":647611},"last_token_usage":{"input_tokens":73176,"cached_input_tokens":70400,"cache_write_input_tokens":0,"output_tokens":1203,"reasoning_output_tokens":516,"total_tokens":74379},"model_context_window":258400}}"#,
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
        // token_count, mid-turn: usage accounting takes the SESSION total…
        .tokenUsageUpdated(threadId: codexTID, snapshot: TokenUsageSnapshot(
            inputTokens: 643673, outputTokens: 3938, totalCostUsd: nil)),
        // …while occupancy takes the PER-REQUEST block, with the provider's own
        // window. 74,379 of 258,400 is 29%; the cumulative 643,673 against a
        // catalogue 272,000 was the 237% the meter used to paint.
        .contextWindowUpdated(threadId: codexTID, snapshot: AgentContextWindowSnapshot(
            usedTokens: 74379,
            maxTokens: 258400,
            inputTokens: 73176,
            outputTokens: 1203,
            cacheReadTokens: 70400,
            cacheWriteTokens: 0,
            totalProcessedTokens: 74379,
            totalCostUsd: nil,
            automaticCompaction: nil,
            observedAt: observedAt,
            source: .codexTurnUsage,
            freshness: .live)),
        .tokenUsageUpdated(threadId: codexTID, snapshot: TokenUsageSnapshot(
            // input_tokens is ALREADY the total — NOT summed with cached (the
            // opposite of the claude backend). 46162, not 46162+41216.
            inputTokens: 46162, outputTokens: 231, totalCostUsd: nil)),
        .contextWindowUpdated(threadId: codexTID, snapshot: AgentContextWindowSnapshot(
            usedTokens: nil,
            maxTokens: nil,
            inputTokens: 46162,
            outputTokens: 231,
            cacheReadTokens: 41216,
            cacheWriteTokens: 0,
            totalProcessedTokens: 46393,
            totalCostUsd: nil,
            automaticCompaction: nil,
            observedAt: observedAt,
            source: .codexTurnUsage,
            freshness: .live)),
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
    // Routing truth table for all three backends × availability.
    expect(AgentBackendConfig.route(model: "anthropic/x", backend: .pi, claudeAvailable: true, codexAvailable: true) == .claude,
           "route: pi + anthropic + claude present → claude")
    expect(AgentBackendConfig.route(model: "openai-codex/x", backend: .pi, claudeAvailable: true, codexAvailable: true) == .codex,
           "route: pi + openai-codex + codex present → codex")
    expect(AgentBackendConfig.route(model: "openai-codex/x", backend: .pi, claudeAvailable: true, codexAvailable: false) == .pi,
           "route: pi + openai-codex without codex → pi")
    expect(AgentBackendConfig.route(model: "anthropic/x", backend: .pi, claudeAvailable: false, codexAvailable: true) == .pi,
           "route: pi + anthropic without claude → pi")
    expect(AgentBackendConfig.route(model: "google/x", backend: .pi, claudeAvailable: true, codexAvailable: true) == .pi,
           "route: pi + a third provider → pi")

    expect(AgentBackendConfig.route(model: "openai-codex/x", backend: .codex, claudeAvailable: true, codexAvailable: true) == .codex,
           "route: Codex backend + openai-codex + codex present → codex")
    expect(AgentBackendConfig.route(model: "openai-codex/x", backend: .codex, claudeAvailable: true, codexAvailable: false) == .pi,
           "route: Codex backend without codex → pi")
    expect(AgentBackendConfig.route(model: "anthropic/x", backend: .codex, claudeAvailable: true, codexAvailable: true) == .pi,
           "route: Codex backend narrows — a non-openai-codex model → pi")

    expect(AgentBackendConfig.route(model: "anthropic/x", backend: .claudeCode, claudeAvailable: true, codexAvailable: true) == .claude,
           "route: Claude Code backend + anthropic + claude present → claude")
    expect(AgentBackendConfig.route(model: "anthropic/x", backend: .claudeCode, claudeAvailable: false, codexAvailable: true) == .pi,
           "route: Claude Code backend without claude → pi")
    expect(AgentBackendConfig.route(model: "openai-codex/x", backend: .claudeCode, claudeAvailable: true, codexAvailable: true) == .pi,
           "route: Claude Code backend narrows — a non-anthropic model → pi")

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

    // Dropdown filter + the one-copy provider split.
    expect(AgentBackendConfig.provider(forID: "openai-codex/gpt-5.6-sol") == "openai-codex",
           "AgentBackendConfig: provider prefix split")
    expect(AgentBackendConfig.provider(forID: "bare") == "other",
           "AgentBackendConfig: a slashless id groups under other")
    let all = ["openai-codex/a", "anthropic/b", "google/c"]
    expect(AgentBackendConfig.filter(all, for: .codex) == ["openai-codex/a"],
           "AgentBackendConfig.filter: Codex → openai-codex only")
    expect(AgentBackendConfig.filter(all, for: .claudeCode) == ["anthropic/b"],
           "AgentBackendConfig.filter: Claude Code → anthropic only")
    expect(AgentBackendConfig.filter(all, for: .pi) == all,
           "AgentBackendConfig.filter: pi → every provider (byte-identical)")

    print("CodexCLIBackend/AgentBackendConfig policy checks passed: routing truth table, model-argument stripping, effort exact-match/omit, auth parse, and dropdown filter pinned")
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
