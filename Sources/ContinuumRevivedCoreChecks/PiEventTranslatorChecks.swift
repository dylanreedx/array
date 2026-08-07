import ContinuumRevivedCore
import Foundation

// Ticket: docs/38-tickets/88-provider-adapter-pi-gpt.md
//
// Pins the Pi → AgentRuntimeEvent mapping against the REAL `--mode json` schema
// captured live from GPT-5.6 (openai-codex) on 2026-07-22. The fixture below is
// the actual event shape Pi emits (curated to representative lines, with the
// cwd/path/file-content payloads kept deliberately "secret" so the I5-safety
// assertion has something to catch).
func runPiEventTranslatorChecks() {
    runPiContextWindowTelemetryChecks()

    // Real captured schema: session → agent_start → turn_start → streamed text
    // → a read tool round-trip → turn_end → a second turn → agent_settled.
    let fixture: [String] = [
        #"{"type":"session","version":3,"id":"SID-abc","timestamp":"2026-07-22T22:05:25.001Z","cwd":"/private/tmp/SECRET-PATH/pi-probe"}"#,
        #"{"type":"agent_start"}"#,
        #"{"type":"turn_start"}"#,
        #"{"type":"message_update","assistantMessageEvent":{"type":"text_start","contentIndex":0}}"#,
        #"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"hello"}}"#,
        #"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":" world"}}"#,
        #"{"type":"message_update","assistantMessageEvent":{"type":"text_end","contentIndex":0,"content":"hello world"}}"#,
        #"{"type":"tool_execution_start","toolCallId":"call_1","toolName":"read","args":{"path":"/private/tmp/SECRET-PATH/notes.txt"}}"#,
        #"{"type":"tool_execution_end","toolCallId":"call_1","toolName":"read","result":{"content":[{"type":"text","text":"SECRET-FILE-BODY"}]},"isError":false}"#,
        #"{"type":"turn_end","message":{"role":"assistant"}}"#,
        #"{"type":"turn_start"}"#,
        #"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"done"}}"#,
        #"{"type":"turn_end","message":{"role":"assistant"}}"#,
        #"{"type":"agent_settled"}"#,
    ]

    var translator = PiEventTranslator()
    let events = translator.translate(stream: fixture)

    let expected: [AgentRuntimeEvent] = [
        .sessionStateChanged(.ready),
        .sessionStateChanged(.running),
        .turnStarted(threadId: "SID-abc", turnId: "SID-abc#t1"),
        .contentDelta(threadId: "SID-abc", turnId: "SID-abc#t1", streamKind: .assistant, delta: "hello"),
        .contentDelta(threadId: "SID-abc", turnId: "SID-abc#t1", streamKind: .assistant, delta: " world"),
        .itemStarted(threadId: "SID-abc", itemId: "call_1", kind: .commandExecution, title: "read"),
        .itemCompleted(threadId: "SID-abc", itemId: "call_1", kind: .commandExecution, status: .completed),
        .turnCompleted(threadId: "SID-abc", turnId: "SID-abc#t1", outcome: .completed, errorMessage: nil),
        .turnStarted(threadId: "SID-abc", turnId: "SID-abc#t2"),
        .contentDelta(threadId: "SID-abc", turnId: "SID-abc#t2", streamKind: .assistant, delta: "done"),
        .turnCompleted(threadId: "SID-abc", turnId: "SID-abc#t2", outcome: .completed, errorMessage: nil),
        .sessionStateChanged(.ready),
    ]

    // 1. Exact mapping — sequence, threadId capture, streamKind, tool round-trip.
    expect(events == expected,
           "PiEventTranslator: mapping must equal the expected sequence.\n  got: \(events)\n  want: \(expected)")

    // 2. Turn-id synthesis — Pi gives none; two turns get distinct stable ids.
    let turnIds = events.compactMap { event -> String? in
        if case let .turnStarted(_, turnId) = event { return turnId }
        return nil
    }
    expect(turnIds == ["SID-abc#t1", "SID-abc#t2"], "PiEventTranslator: turn ids synthesised distinctly, got \(turnIds)")

    // 3. I5 by construction — encode every produced event and prove the
    //    sensitive Pi payloads (cwd, tool arg path, file-result body) never
    //    made it into any event. The target model has no field for them, and
    //    tool items carry only the tool name.
    let encoded = try! JSONEncoder().encode(events)
    let json = String(decoding: encoded, as: UTF8.self)
    expect(!json.contains("SECRET-PATH"), "PiEventTranslator I5: cwd / tool path must not appear in any event")
    expect(!json.contains("SECRET-FILE-BODY"), "PiEventTranslator I5: tool result body must not appear in any event")
    expect(json.contains("read"), "PiEventTranslator: the tool name is preserved as the item title")

    print("PiEventTranslator checks passed: \(events.count) events from the real GPT-5.6 json schema map exactly, turn ids synthesised (\(turnIds)), I5-safe by construction (cwd/path/file-body dropped, tool name kept)")
}

private func runPiContextWindowTelemetryChecks() {
    let observedAt = Date(timeIntervalSince1970: 1_785_037_741.229)
    var translator = PiEventTranslator(now: { Date(timeIntervalSinceReferenceDate: 123) })
    let messageEndEvents = translator.translate(line:
        #"{"type":"message_end","message":{"role":"assistant","usage":{"input":1026,"output":43,"cacheRead":7,"cacheWrite":11,"reasoning":13,"totalTokens":1069,"cost":{"input":0.00513,"output":0.00129,"cacheRead":0.00007,"cacheWrite":0.00011,"total":0.00642}},"timestamp":1785037741229,"content":[{"type":"toolCall","arguments":{"prompt":"SECRET-TOOL-DETAIL"}}]}}"#
    )
    expect(messageEndEvents.contains(.tokenUsageUpdated(threadId: "pi-unknown", snapshot: TokenUsageSnapshot(inputTokens: 1026, outputTokens: 43, totalCostUsd: 0.00642))),
           "Pi usage: message_end must still update per-message token usage; got \(messageEndEvents)")
    guard case let .contextWindowUpdated(threadId, snapshot)? = messageEndEvents.first(where: {
        if case .contextWindowUpdated = $0 { return true }
        return false
    }) else {
        fputs("FAIL: Pi usage: message_end with committed usage shape produced no contextWindowUpdated event: \(messageEndEvents)\n", stderr)
        Foundation.exit(1)
    }
    expect(threadId == "pi-unknown", "Pi usage: context telemetry uses current thread id, got \(threadId)")
    expect(snapshot == AgentContextWindowSnapshot(
        usedTokens: nil,
        maxTokens: nil,
        inputTokens: 1026,
        outputTokens: 43,
        cacheReadTokens: 7,
        cacheWriteTokens: 11,
        totalProcessedTokens: 1069,
        totalCostUsd: 0.00642,
        automaticCompaction: nil,
        observedAt: observedAt,
        source: .piMessageUsage,
        freshness: .live
    ), "Pi usage: context snapshot must preserve usage counters without inventing occupancy; got \(snapshot)")
    expect(snapshot.occupancyFraction == nil && snapshot.occupancyPercentage == nil,
           "Pi usage: input+output/cache totals must not be inferred as context occupancy; got \(String(describing: snapshot.occupancyFraction))")
    let encoded = String(decoding: try! JSONEncoder().encode(messageEndEvents), as: UTF8.self)
    expect(!encoded.contains("SECRET-TOOL-DETAIL"), "Pi context telemetry I5: raw tool detail crossed in events: \(encoded)")

    let turnEndEvents = translator.translate(line:
        #"{"type":"turn_end","message":{"role":"assistant","usage":{"input":1086,"output":4,"cacheRead":0,"cacheWrite":0,"totalTokens":1090,"cost":{"total":0.00555}},"timestamp":1785037743287}}"#
    )
    expect(turnEndEvents.contains(.tokenUsageUpdated(threadId: "pi-unknown", snapshot: TokenUsageSnapshot(inputTokens: 1086, outputTokens: 4, totalCostUsd: 0.00555))),
           "Pi usage: turn_end must parse committed usage shape before completion; got \(turnEndEvents)")
    expect(turnEndEvents.contains(.turnCompleted(threadId: "pi-unknown", turnId: "pi-unknown#t0", outcome: .completed, errorMessage: nil)),
           "Pi usage: turn_end must keep emitting turn completion; got \(turnEndEvents)")
    let duplicatedTurnEnd = translator.translate(line:
        #"{"type":"turn_end","message":{"role":"assistant","usage":{"input":1026,"output":43,"cacheRead":7,"cacheWrite":11,"reasoning":13,"totalTokens":1069,"cost":{"total":0.00642}},"timestamp":1785037741229}}"#
    )
    expect(!duplicatedTurnEnd.contains { if case .tokenUsageUpdated = $0 { return true }; return false }
           && !duplicatedTurnEnd.contains { if case .contextWindowUpdated = $0 { return true }; return false }
           && duplicatedTurnEnd.contains(.turnCompleted(threadId: "pi-unknown", turnId: "pi-unknown#t0", outcome: .completed, errorMessage: nil)),
           "Pi usage: duplicate message_end/turn_end usage from committed fixture shape must not double-count telemetry, while completion remains; got \(duplicatedTurnEnd)")

    let authoritative = AgentContextWindowSnapshot(
        usedTokens: 256,
        maxTokens: 1024,
        inputTokens: nil,
        outputTokens: nil,
        cacheReadTokens: nil,
        cacheWriteTokens: nil,
        totalProcessedTokens: nil,
        totalCostUsd: nil,
        automaticCompaction: true,
        observedAt: observedAt,
        source: .providerSessionStats,
        freshness: .live
    )
    expect(authoritative.occupancyFraction == 0.25 && authoritative.occupancyPercentage == 25,
           "Context occupancy: authoritative used/max should yield 25%, got fraction \(String(describing: authoritative.occupancyFraction))")
    let missingMax = AgentContextWindowSnapshot(usedTokens: 256, maxTokens: nil, observedAt: observedAt, source: .providerSessionStats, freshness: .live)
    let nonAuthoritative = AgentContextWindowSnapshot(usedTokens: 256, maxTokens: 1024, observedAt: observedAt, source: .piMessageUsage, freshness: .live)
    let zeroMax = AgentContextWindowSnapshot(usedTokens: 256, maxTokens: 0, observedAt: observedAt, source: .providerSessionStats, freshness: .live)
    expect(missingMax.occupancyFraction == nil && nonAuthoritative.occupancyFraction == nil && zeroMax.occupancyFraction == nil,
           "Context occupancy: missing max, non-authoritative source, or zero max must stay unknown")

    let unknownJSON = #"{"usedTokens":5,"maxTokens":10,"observedAt":0,"source":"future-rpc","freshness":"future-freshness"}"#.data(using: .utf8)!
    let decodedUnknown = try! JSONDecoder().decode(AgentContextWindowSnapshot.self, from: unknownJSON)
    expect(decodedUnknown.source == .unknown("future-rpc") && decodedUnknown.freshness == .unknown("future-freshness") && decodedUnknown.occupancyFraction == nil,
           "Context snapshot Codable: unknown source/freshness must decode without fabricating authoritative occupancy; got \(decodedUnknown)")

    let legacyTokenUsageJSON = #"{"type":"tokenUsageUpdated","threadId":"thread-main","snapshot":{"inputTokens":120,"outputTokens":34,"totalCostUsd":0.015}}"#.data(using: .utf8)!
    expect((try? JSONDecoder().decode(AgentRuntimeEvent.self, from: legacyTokenUsageJSON)) == .tokenUsageUpdated(threadId: "thread-main", snapshot: TokenUsageSnapshot(inputTokens: 120, outputTokens: 34, totalCostUsd: 0.015)),
           "AgentRuntimeEvent Codable: legacy tokenUsageUpdated payload must remain decodable after adding context telemetry")
}

// The 88.4b wiring boundary: a tile keyed by `managed-<uuid>` ingests events
// whose threadId the adapter synthesised from Pi's session id. withThreadId
// must rebind EVERY thread-bearing case to the tile's thread (so the tile's
// threadId filter matches) while leaving session-level events untouched.
func runAgentRuntimeEventRemapChecks() {
    let tileThread = "managed-TILE"
    let piThread = "SID-abc"

    // 1. Thread-bearing cases are all rebound to the tile thread. Build one of
    //    every case that carries a threadId, remap, and assert.
    let bearing: [AgentRuntimeEvent] = [
        .turnStarted(threadId: piThread, turnId: "\(piThread)#t1"),
        .turnCompleted(threadId: piThread, turnId: "\(piThread)#t1", outcome: .completed, errorMessage: nil),
        .itemStarted(threadId: piThread, itemId: "call_1", kind: .commandExecution, title: "read"),
        .itemCompleted(threadId: piThread, itemId: "call_1", kind: .commandExecution, status: .completed),
        .contentDelta(threadId: piThread, turnId: "\(piThread)#t1", streamKind: .assistant, delta: "hi"),
        .requestOpened(threadId: piThread, requestId: "r1", kind: .commandExecutionApproval),
        .requestResolved(threadId: piThread, requestId: "r1", decision: "approve"),
        .userInputRequested(threadId: piThread, requestId: "q1", questions: [UserInputQuestion(key: "q", prompt: "Continue?")]),
        .userInputResolved(threadId: piThread, requestId: "r1"),
        .tokenUsageUpdated(threadId: piThread, snapshot: TokenUsageSnapshot(inputTokens: 1, outputTokens: 2, totalCostUsd: nil)),
        .contextWindowUpdated(threadId: piThread, snapshot: AgentContextWindowSnapshot(observedAt: Date(timeIntervalSinceReferenceDate: 0), source: .piMessageUsage, freshness: .live)),
        .runtimeError(threadId: piThread, message: "boom"),
    ]
    for event in bearing {
        let remapped = event.withThreadId(tileThread)
        let encoded = String(decoding: try! JSONEncoder().encode(remapped), as: UTF8.self)
        // Check the threadId FIELD precisely — turnId legitimately embeds the
        // old session id (e.g. "SID-abc#t1"), so a whole-string search would
        // false-positive on it.
        expect(encoded.contains(#""threadId":"\#(tileThread)""#)
                && !encoded.contains(#""threadId":"\#(piThread)""#),
               "withThreadId: \(event) must rebind threadId to \(tileThread), got \(encoded)")
    }

    // 2. Feeding a remapped Pi stream into the tile's transcript model (keyed
    //    by the tile thread) actually lands cards — proving the filter matches.
    var translator = PiEventTranslator()
    let raw = translator.translate(stream: [
        #"{"type":"session","version":3,"id":"SID-abc","timestamp":"t","cwd":"/x"}"#,
        #"{"type":"agent_start"}"#,
        #"{"type":"turn_start"}"#,
        #"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"hello"}}"#,
        #"{"type":"turn_end","message":{"role":"assistant"}}"#,
        #"{"type":"agent_settled"}"#,
    ])
    var model = ManagedAgentTranscriptModel(threadId: tileThread)
    for event in raw { model.ingest(event.withThreadId(tileThread)) }
    expect(model.cards.contains { $0.body.contains("hello") },
           "withThreadId: remapped stream must produce a tile card; got \(model.cards)")

    // 3. Sanity: WITHOUT remap, the mismatched threadId means no card lands —
    //    this is exactly the bug the remap fixes.
    var unmatched = ManagedAgentTranscriptModel(threadId: tileThread)
    for event in raw { unmatched.ingest(event) }
    expect(!unmatched.cards.contains { $0.body.contains("hello") },
           "control: un-remapped Pi-thread events must NOT land in a tile-thread model")

    print("AgentRuntimeEvent remap checks passed: all thread-bearing cases rebind, remapped stream lands cards, un-remapped control drops them")
}
