import ContinuumRevivedCore
import Foundation

func runAgentAwarenessChecks() throws {
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("FAIL: Agent awareness: \(message)\n", stderr)
            exit(1)
        }
    }

    expect(AgentGitOperationClassifier.operations(in: "git push origin feature") == [.gitPushSucceeded],
           "direct git push is classified")
    expect(AgentGitOperationClassifier.operations(in: "/usr/bin/git -C repo merge --no-ff topic") == [.gitMergeSucceeded],
           "absolute git with global option is classified")
    expect(AgentGitOperationClassifier.operations(in: "TOKEN=nope env -i PATH=/bin command git push && git merge main") == [.gitPushSucceeded, .gitMergeSucceeded],
           "wrappers and compound commands classify both operations")
    expect(AgentGitOperationClassifier.operations(in: "echo 'git push'; printf git\\ merge").isEmpty,
           "quoted/output text is not classified")
    expect(AgentGitOperationClassifier.operations(in: "github push").isEmpty,
           "lookalike executable is not classified")

    let tileID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    let agentID = AgentID(rawValue: UUID(uuidString: "10000000-0000-4000-8000-000000000002")!)
    var reducer = AgentSignalReducer()
    let completed = AgentRuntimeEvent.turnCompleted(threadId: "thread", turnId: "turn", outcome: .completed, errorMessage: nil)
    expect(reducer.ingest(event: completed, agentID: agentID, tileID: tileID)?.kind == .completed,
           "completion emits a signal")
    expect(reducer.ingest(event: completed, agentID: agentID, tileID: tileID) == nil,
           "replayed completion is deduplicated")
    let request = AgentRuntimeEvent.userInputRequested(
        threadId: "thread", requestId: "request", questions: [.init(key: "q", prompt: "Choose")])
    expect(reducer.ingest(event: request, agentID: agentID, tileID: tileID)?.kind == .actionRequired,
           "user input emits action required")
    expect(AgentSignalKind.actionRequired.priority > AgentSignalKind.failed.priority &&
           AgentSignalKind.failed.priority > AgentSignalKind.completed.priority &&
           AgentSignalKind.completed.priority > AgentSignalKind.gitMergeSucceeded.priority,
           "priority ladder is stable")

    let metadata = TileMetadata(agentSoundOverrides: AgentSoundOverrides(values: [
        .completed: .mute,
        .gitPushSucceeded: .sound(.init(rawValue: "orbit")),
    ]))
    let encodedMetadata = try JSONEncoder().encode(metadata)
    let decodedMetadata = try JSONDecoder().decode(TileMetadata.self, from: encodedMetadata)
    expect(decodedMetadata.agentSoundOverrides == metadata.agentSoundOverrides,
           "per-tile sound overrides round trip")
    expect(AgentSoundRules.defaults.count == AgentSignalKind.allCases.count &&
           AgentSoundRules.defaults.values.allSatisfy { !$0.enabled },
           "all five suggested global rules are opt-in")
    let suite = "array.agent-awareness.core-check.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: AgentSoundConfig.masterEnabledKey)
    let custom = AgentSoundReference(rawValue: "custom")
    let global = AgentSoundReference(rawValue: "bloom")
    let selected = AgentSoundConfig.resolvedSound(
        for: .completed,
        tileOverrides: AgentSoundOverrides(values: [.completed: .sound(custom)]),
        available: [custom, global],
        defaults: defaults)
    expect(selected == custom, "a selected per-tile sound overrides a disabled global event rule")
    defaults.set(true, forKey: AgentSoundConfig.enabledKey(for: .completed))
    let missingFallback = AgentSoundConfig.resolvedSound(
        for: .completed,
        tileOverrides: AgentSoundOverrides(values: [.completed: .sound(.init(rawValue: "missing"))]),
        available: [global],
        defaults: defaults)
    expect(missingFallback == global, "a missing imported sound falls back to the inherited global rule")

    // Provider lifecycle invariant: tool/message completion is activity, not a
    // completed user run. This is what protects both the tile timer anchor and
    // the completion sound dispatcher from per-tool resets/rings.
    var lifecyclePi = PiEventTranslator()
    let piPrefix = [
        #"{"type":"session","id":"thread-pi-lifecycle"}"#,
        #"{"type":"agent_start"}"#,
        #"{"type":"turn_start"}"#,
        #"{"type":"tool_execution_start","toolCallId":"tool-1","toolName":"read","args":{"path":"safe"}}"#,
        #"{"type":"tool_execution_end","toolCallId":"tool-1","toolName":"read","isError":false}"#,
        #"{"type":"turn_end","message":{"role":"assistant","stopReason":"toolUse"}}"#,
        #"{"type":"turn_start"}"#,
        #"{"type":"turn_end","message":{"role":"assistant","stopReason":"stop"}}"#,
        #"{"type":"agent_end","willRetry":false}"#,
    ]
    let piBeforeSettled = lifecyclePi.translate(stream: piPrefix)
    expect(piBeforeSettled.filter { if case .turnStarted = $0 { return true }; return false }.count == 1,
           "Pi tool cycles must preserve one run/timer start")
    expect(!piBeforeSettled.contains { if case .turnCompleted = $0 { return true }; return false },
           "Pi turn_end and agent_end must not complete before agent_settled")
    let piSettled = lifecyclePi.translate(line: #"{"type":"agent_settled"}"#)
    expect(piSettled.filter { if case .turnCompleted = $0 { return true }; return false }.count == 1,
           "Pi agent_settled must emit exactly one completion")
    expect(!lifecyclePi.translate(line: #"{"type":"agent_settled"}"#).contains {
        if case .turnCompleted = $0 { return true }; return false
    }, "replayed Pi agent_settled must not emit another completion")
    var piSignalReducer = AgentSignalReducer()
    let piCompletionSignals = (piBeforeSettled + piSettled).compactMap {
        piSignalReducer.ingest(event: $0, agentID: agentID, tileID: tileID)
    }.filter { $0.kind == .completed }
    expect(piCompletionSignals.count == 1,
           "one Pi tool-using run must dispatch one completion sound signal")

    var lifecycleClaude = ClaudeEventTranslator(runToken: "lifecycle")
    let claudeBeforeResult = lifecycleClaude.translate(stream: [
        #"{"type":"system","subtype":"init","session_id":"thread-claude-lifecycle"}"#,
        #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tool-1","name":"Read","input":{"path":"safe"}}]}}"#,
        #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tool-1","is_error":false,"content":"ok"}]}}"#,
    ])
    expect(!claudeBeforeResult.contains { if case .turnCompleted = $0 { return true }; return false },
           "Claude tool completion must not complete the run")
    expect(lifecycleClaude.translate(line: #"{"type":"result","subtype":"success","is_error":false}"#).filter {
        if case .turnCompleted = $0 { return true }; return false
    }.count == 1, "Claude result must emit one completion")

    var lifecycleCodex = CodexEventTranslator(runToken: "lifecycle")
    let codexBeforeTurn = lifecycleCodex.translate(stream: [
        #"{"type":"thread.started","thread_id":"thread-codex-lifecycle"}"#,
        #"{"type":"turn.started"}"#,
        #"{"type":"item.started","item":{"id":"item-1","type":"command_execution","command":"pwd"}}"#,
        #"{"type":"item.completed","item":{"id":"item-1","type":"command_execution","exit_code":0}}"#,
    ])
    expect(!codexBeforeTurn.contains { if case .turnCompleted = $0 { return true }; return false },
           "Codex item completion must not complete the run")
    expect(lifecycleCodex.translate(line: #"{"type":"turn.completed"}"#).filter {
        if case .turnCompleted = $0 { return true }; return false
    }.count == 1, "Codex turn.completed must emit one completion")

    var codex = CodexEventTranslator(runToken: "signal")
    let codexLines = [
        #"{"type":"thread.started","thread_id":"thread-c"}"#,
        #"{"type":"turn.started"}"#,
        #"{"type":"item.started","item":{"id":"item_0","type":"command_execution","command":"git push origin main"}}"#,
        #"{"type":"item.completed","item":{"id":"item_0","type":"command_execution","exit_code":0}}"#,
    ]
    expect(codex.translate(stream: codexLines).contains {
        if case .semanticSignal(_, _, .gitPushSucceeded) = $0 { return true }; return false
    }, "Codex emits push only at successful completion")

    var failedCodex = CodexEventTranslator(runToken: "failed")
    let failedLines = [
        #"{"type":"thread.started","thread_id":"thread-c"}"#,
        #"{"type":"turn.started"}"#,
        #"{"type":"item.started","item":{"id":"item_0","type":"command_execution","command":"git merge topic"}}"#,
        #"{"type":"item.completed","item":{"id":"item_0","type":"command_execution","exit_code":1}}"#,
    ]
    expect(!failedCodex.translate(stream: failedLines).contains {
        if case .semanticSignal = $0 { return true }; return false
    }, "failed Codex command does not emit Git success")

    var pi = PiEventTranslator()
    let piLines = [
        #"{"type":"session","id":"thread-p"}"#,
        #"{"type":"turn_start"}"#,
        #"{"type":"tool_execution_start","toolCallId":"tool-1","toolName":"bash","args":{"command":"git merge topic"}}"#,
        #"{"type":"tool_execution_end","toolCallId":"tool-1","toolName":"bash","isError":false}"#,
    ]
    expect(pi.translate(stream: piLines).contains {
        if case .semanticSignal(_, _, .gitMergeSucceeded) = $0 { return true }; return false
    }, "Pi emits merge only at successful completion")

    var claude = ClaudeEventTranslator(runToken: "signal")
    let claudeLines = [
        #"{"type":"system","subtype":"init","session_id":"thread-a"}"#,
        #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tool-1","name":"Bash","input":{"command":"git push"}}]}}"#,
        #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tool-1","is_error":false,"content":"ok"}]}}"#,
    ]
    expect(claude.translate(stream: claudeLines).contains {
        if case .semanticSignal(_, _, .gitPushSucceeded) = $0 { return true }; return false
    }, "Claude emits push only at successful completion")

    print("Agent awareness checks: signals, deduplication, priorities, sound defaults/overrides, privacy-safe Git classification, and Claude/Codex/Pi success semantics passed")
}

/// WS4 · the PURE half of completion awareness: the active-view predicate, the
/// arrival decision table, the deliberate-visit classification, and the finite
/// acknowledgment plan. The AppKit half (`--completion-awareness-check`) drives
/// the same types through the real window/supervisor/tile path.
func runCompletionAwarenessCoreChecks() throws {
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("FAIL: Completion awareness core: \(message)\n", stderr)
            exit(1)
        }
    }

    // 1 · the predicate is a conjunction of live facts, and every single one of
    // them can refuse on its own. Written as "flip exactly one field of a fully
    // viewed set" so that adding a field to the struct without adding it to the
    // predicate cannot pass here unnoticed.
    let viewed = AgentActiveViewFacts(
        appActive: true, windowNotUpstaged: true, windowVisible: true,
        windowOcclusionVisible: true, tileMounted: true, responderInTile: true,
        focusScopeIsTile: true, modalPresented: false)
    expect(viewed.isActivelyViewed, "a fully established set of facts must be actively viewed")
    expect(viewed.blockingReasons.isEmpty, "a viewed set must report no blocking reason")
    expect(!AgentActiveViewFacts.away.isActivelyViewed, "the default facts must be away")

    var flips: [(String, AgentActiveViewFacts)] = []
    var f = viewed; f.appActive = false; flips.append(("appActive", f))
    f = viewed; f.windowNotUpstaged = false; flips.append(("windowNotUpstaged", f))
    f = viewed; f.windowVisible = false; flips.append(("windowVisible", f))
    f = viewed; f.windowOcclusionVisible = false; flips.append(("windowOcclusionVisible", f))
    f = viewed; f.tileMounted = false; flips.append(("tileMounted", f))
    f = viewed; f.responderInTile = false; flips.append(("responderInTile", f))
    f = viewed; f.focusScopeIsTile = false; flips.append(("focusScopeIsTile", f))
    f = viewed; f.modalPresented = true; flips.append(("modalPresented", f))
    for (name, facts) in flips {
        expect(!facts.isActivelyViewed, "\(name) alone must be able to refuse active viewing")
        expect(facts.blockingReasons.count == 1, "\(name) alone must report exactly one blocking reason — got \(facts.blockingReasons)")
    }

    // 2 · the decision table. Away changes nothing at all; watched success is the
    // only thing that earns the visual acknowledgment; watched failure is read
    // but keeps its live signal and never borrows the success treatment.
    let away = AgentActiveViewFacts.away
    for kind in [AgentTerminalArrivalKind.completed, .failed] {
        let decision = AgentAwarenessTransition.decide(arrival: kind, facts: away)
        expect(decision == AgentAwarenessDecision.none,
               "an arrival while away must change nothing — \(kind.rawValue) gave \(decision)")
    }
    let watchedSuccess = AgentAwarenessTransition.decide(arrival: .completed, facts: viewed)
    expect(watchedSuccess.advancesReadWatermark && watchedSuccess.clearsLiveSignal
           && watchedSuccess.acknowledgesVisually,
           "a watched completion must read, clear and acknowledge — got \(watchedSuccess)")
    let watchedFailure = AgentAwarenessTransition.decide(arrival: .failed, facts: viewed)
    expect(watchedFailure.advancesReadWatermark, "a watched failure was still watched")
    expect(!watchedFailure.clearsLiveSignal,
           "a watched failure must keep its live signal — failure may not collapse into success")
    expect(!watchedFailure.acknowledgesVisually,
           "a watched failure must not play the success acknowledgment")

    // 2b · the table's own invariant, which the app relies on: nothing may ask
    // for the visual acknowledgment without also retiring the live signal.
    // `AppDelegate.applyPendingWatchedArrival` mirrors these two fields in that
    // order, so a table that violated this would leave a green glow sitting on
    // top of a live attention signal.
    for facts in [viewed, away] {
        for kind in [AgentTerminalArrivalKind.completed, .failed] {
            let decision = AgentAwarenessTransition.decide(arrival: kind, facts: facts)
            expect(!decision.acknowledgesVisually || decision.clearsLiveSignal,
                   "a decision that acknowledges must also clear — \(kind.rawValue) gave \(decision)")
            expect(!decision.clearsLiveSignal || decision.advancesReadWatermark,
                   "a decision that clears the live signal must also have counted as read — \(kind.rawValue) gave \(decision)")
        }
    }

    // 3 · restoration is not a visit.
    for reason in [FocusRequest.appActivated, .modalDismissed, .recovery] {
        expect(!reason.isDeliberateVisit, "\(reason.rawValue) is restoration, not a visit")
    }
    for reason in [FocusRequest.userClick, .tileSpawned, .modalOpened, .tileClosed, .runtimeExited] {
        expect(reason.isDeliberateVisit, "\(reason.rawValue) must stay a deliberate visit")
    }

    // 4 · the acknowledgment plan is finite, inside the contract window, and
    // static (never persistent, never repeating) under Reduce Motion.
    let motion = AgentCompletionAcknowledgmentPlan.plan(reduceMotion: false)
    let still = AgentCompletionAcknowledgmentPlan.plan(reduceMotion: true)
    expect(motion.isWithinContractWindow && still.isWithinContractWindow,
           "both plans must fall in 1.2–1.6s — got \(motion.duration) / \(still.duration)")
    expect(motion.duration == still.duration,
           "Reduce Motion keeps the same finite window, it does not shorten or extend it")
    expect(motion.pulseCount > 0 && !motion.isStatic, "the ordinary plan pulses")
    expect(still.pulseCount == 0 && still.isStatic, "the Reduce Motion plan is static")
    expect(AgentCompletionAcknowledgmentPlan(duration: 99, pulseCount: 2).duration
           == AgentCompletionAcknowledgmentPlan.maximumDuration,
           "an out-of-contract duration is clamped, never honoured")
    expect(AgentCompletionAcknowledgmentPlan(duration: 0.1, pulseCount: 2).duration
           == AgentCompletionAcknowledgmentPlan.minimumDuration,
           "a too-short duration is clamped up")

    print("Completion awareness core checks passed: 8 refusing facts, decision table, visit classification, finite plans")
}
