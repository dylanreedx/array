import ContinuumRevivedCore
import Foundation

func runAgentCompactionChecks() {
    let operationID = UUID(uuidString: "00000000-0000-4000-8000-000000000058")!
    let lifecycle = AgentCompactionLifecycleEvent(
        operationID: operationID,
        boundaryID: "boundary-1",
        phase: .succeeded,
        trigger: .overflowRecovery,
        beforeTokens: AgentCompactionTokenReading(120_000, precision: .exact),
        afterTokens: AgentCompactionTokenReading(20_000, precision: .estimated),
        provider: "pi",
        willRetryInterruptedTurn: true,
        observedAt: Date(timeIntervalSinceReferenceDate: 58))
    let event = AgentRuntimeEvent.compactionChanged(threadId: "thread", event: lifecycle)
    let roundTrip = try! JSONDecoder().decode(
        AgentRuntimeEvent.self, from: JSONEncoder().encode(event))
    expect(roundTrip == event, "compaction lifecycle must survive runtime-event persistence")

    var claude = ClaudeEventTranslator(
        runToken: "compact-check",
        now: { Date(timeIntervalSinceReferenceDate: 58) })
    let claudeLine = #"{"type":"system","subtype":"compact_boundary","session_id":"session","uuid":"claude-boundary","compact_metadata":{"trigger":"manual","pre_tokens":154000,"post_tokens":22000}}"#
    let claudeEvents = claude.translate(line: claudeLine)
    guard case .compactionChanged(_, let claudeBoundary)? = claudeEvents.first else {
        expect(false, "Claude compact_boundary must emit a first-class lifecycle event")
        return
    }
    expect(claudeBoundary.boundaryID == "claude-boundary", "Claude must retain its stable boundary UUID")
    expect(claudeBoundary.trigger == .manual, "Claude manual trigger must remain manual")
    expect(claudeBoundary.beforeTokens == AgentCompactionTokenReading(154000, precision: .exact),
           "Claude pre-compaction tokens must be exact")
    expect(claudeBoundary.afterTokens == AgentCompactionTokenReading(22000, precision: .exact),
           "Claude post-compaction tokens must be exact")

    var pi = PiEventTranslator(now: { Date(timeIntervalSinceReferenceDate: 58) })
    _ = pi.translate(line: #"{"type":"session","id":"pi-session"}"#)
    let piStart = pi.translate(line: #"{"type":"compaction_start","reason":"overflow"}"#)
    let piEnd = pi.translate(line: #"{"type":"compaction_end","result":{"summary":"SECRET SUMMARY","firstKeptEntryId":"entry-9","tokensBefore":99000,"estimatedTokensAfter":19000},"willRetry":true}"#)
    guard case .compactionChanged(_, let piStarted)? = piStart.first,
          case .compactionChanged(_, let piBoundary)? = piEnd.first else {
        expect(false, "Pi compaction start/end must emit lifecycle events")
        return
    }
    expect(piStarted.trigger == .overflowRecovery && piBoundary.trigger == .overflowRecovery,
           "Pi overflow recovery must not collapse into generic automatic compaction")
    expect(piBoundary.boundaryID == "pi:pi-session:entry-9:99000", "Pi boundary identity must be stable")
    expect(piBoundary.afterTokens == AgentCompactionTokenReading(19000, precision: .estimated),
           "Pi post-compaction count must remain estimated")
    expect(!String(describing: piEnd).contains("SECRET SUMMARY"),
           "Pi provider summary must not enter normalized runtime events")

    var codex = CodexAppServerEventTranslator(
        compactionOperationID: operationID,
        compactionTrigger: .manual,
        now: { Date(timeIntervalSinceReferenceDate: 58) })
    let codexStart = codex.translate(line: #"{"method":"item/started","params":{"threadId":"codex-thread","turnId":"","item":{"id":"compact-item","type":"contextCompaction","encryptedContent":"DO NOT READ"}}}"#)
    let codexEnd = codex.translate(line: #"{"method":"item/completed","params":{"threadId":"codex-thread","turnId":"","item":{"id":"compact-item","type":"contextCompaction","encryptedContent":"DO NOT READ"}}}"#)
    guard case .compactionChanged(_, let codexRunning)? = codexStart.first,
          case .compactionChanged(_, let codexBoundary)? = codexEnd.first else {
        expect(false, "Codex contextCompaction items must emit lifecycle events")
        return
    }
    expect(codexRunning.phase == .running && codexBoundary.phase == .succeeded,
           "Codex item lifecycle must map start through success")
    expect(codexBoundary.boundaryID == "compact-item" && codexBoundary.operationID == operationID,
           "Codex must retain item and operation identities separately")
    expect(codexBoundary.beforeTokens == nil && codexBoundary.afterTokens == nil,
           "Codex must not fabricate compaction token counts")
    expect(!String(describing: codexEnd).contains("DO NOT READ"),
           "Codex opaque compaction content must not enter normalized events")
    let codexLegacyDuplicate = codex.translate(line: #"{"method":"thread/compacted","params":{"threadId":"codex-thread","boundaryId":"compact-item","summary":"PRIVATE SUMMARY","message":"PRIVATE COMPACTED PROMPT"}}"#)
    expect(codexLegacyDuplicate.isEmpty,
           "Codex legacy thread/compacted must deduplicate against the contextCompaction item boundary")
    expect(!String(describing: codexLegacyDuplicate).contains("PRIVATE"),
           "Codex compacted summary and message must remain private")
    let codexLegacyOnly = codex.translate(line: #"{"method":"thread/compacted","params":{"threadId":"legacy-thread","boundaryId":"legacy-boundary","summary":"PRIVATE SUMMARY"}}"#)
    guard case .compactionChanged(_, let codexLegacyBoundary)? = codexLegacyOnly.first else {
        expect(false, "Codex legacy thread/compacted must emit a first-class boundary")
        return
    }
    expect(codexLegacyBoundary.phase == .succeeded && codexLegacyBoundary.boundaryID == "legacy-boundary",
           "Codex legacy compact notification must retain its stable boundary identity")
    expect(!String(describing: codexLegacyOnly).contains("PRIVATE"),
           "Codex legacy compacted summary must not enter normalized events")
    expect(codex.translate(line: #"{"method":"thread/compacted","params":{"threadId":"legacy-thread","boundaryId":"legacy-boundary"}}"#).isEmpty,
           "replayed Codex legacy compact notifications must not advance the boundary twice")

    // The error code is the last recovery signal app-server provides when a
    // failed Codex turn reaches its context ceiling. Keep this as a normalized
    // marker so the shared recovery surface can offer the same actions for all
    // three harnesses without retaining provider diagnostics.
    var codexFailure = CodexAppServerEventTranslator(now: { Date(timeIntervalSinceReferenceDate: 58) })
    let contextFull = codexFailure.translate(line: #"{"method":"turn/completed","params":{"threadId":"codex-thread","turn":{"id":"turn-1","status":"failed","error":{"codexErrorInfo":"contextWindowExceeded","message":"private provider diagnostic 768-SECRET"}}}}"#)
    guard case .turnCompleted(_, _, .failed, let contextFullMessage)? = contextFull.first else {
        expect(false, "Codex contextWindowExceeded must still complete the failed turn")
        return
    }
    expect(contextFullMessage == AgentContextFullRecovery.canonicalErrorMessage,
           "Codex codexErrorInfo must become the shared context-full recovery marker")
    expect(!String(describing: contextFull).contains("768-SECRET"),
           "context-full recovery must not retain raw provider diagnostics")

    var claudeFailure = ClaudeEventTranslator(
        runToken: "context-full-check",
        now: { Date(timeIntervalSinceReferenceDate: 58) })
    _ = claudeFailure.translate(line: #"{"type":"system","subtype":"init","session_id":"claude-context-full","model":"claude-opus-5"}"#)
    let claudeFull = claudeFailure.translate(line: #"{"type":"result","is_error":true,"subtype":"error_prompt_too_long","result":"private transcript excerpt"}"#)
    guard case .turnCompleted(_, _, .failed, let claudeFullMessage)? = claudeFull.first else {
        expect(false, "Claude prompt-too-long result must complete the failed turn")
        return
    }
    expect(claudeFullMessage == AgentContextFullRecovery.canonicalErrorMessage,
           "Claude context-limit error must become the shared recovery marker")

    var piFailure = PiEventTranslator(now: { Date(timeIntervalSinceReferenceDate: 58) })
    _ = piFailure.translate(line: #"{"type":"agent_start"}"#)
    _ = piFailure.translate(line: #"{"type":"turn_end","message":{"role":"assistant","stopReason":"error","errorMessage":"The prompt exceeds the model context window"}}"#)
    let piFull = piFailure.translate(line: #"{"type":"agent_settled"}"#)
    guard case .turnCompleted(_, _, .failed, let piFullMessage)? = piFull.first else {
        expect(false, "Pi context-limit result must complete the failed run")
        return
    }
    expect(piFullMessage == AgentContextFullRecovery.canonicalErrorMessage,
           "Pi context-limit error must become the shared recovery marker")

    expect(AgentContextFullRecovery.isContextFull(
        provider: "claude", candidates: ["error_prompt_too_long", nil]),
        "Claude prompt-over-context error codes must qualify for recovery")
    expect(AgentContextFullRecovery.isContextFull(
        provider: "pi", candidates: ["The prompt exceeds the model context window", nil]),
        "Pi context-limit messages must qualify for recovery")
    expect(!AgentContextFullRecovery.isContextFull(
        provider: "claude", candidates: ["error_max_tokens", "maximum output tokens reached"]),
        "output-token limits must not be mistaken for full context")
    expect(AgentContextFullRecovery.actions == [
        .compactAndRetry, .forkWithSummary, .copyTranscript,
    ], "context-full recovery must expose compact/retry, summary fork, and transcript copy")

    print("AgentCompactionChecks passed")
}
