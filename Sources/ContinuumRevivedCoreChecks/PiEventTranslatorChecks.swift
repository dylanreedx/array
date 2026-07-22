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
