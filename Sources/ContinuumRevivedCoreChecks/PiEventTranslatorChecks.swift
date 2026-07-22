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
        .userInputResolved(threadId: piThread, requestId: "r1"),
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
