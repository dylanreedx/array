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
