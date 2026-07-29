import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

func runAgentTranscriptProjectionChecks() {
    let thread = "projection-thread"
    var projection = AgentTranscriptProjection(threadId: thread)

    projection.appendUserPrompt("What changed?")
    let events: [AgentRuntimeEvent] = [
        .sessionStateChanged(.running),
        .turnStarted(threadId: thread, turnId: "turn-1"),
        .contentDelta(threadId: thread, turnId: "turn-1", streamKind: .assistant, delta: "I will check."),
        .itemStarted(threadId: thread, itemId: "cmd-1", kind: .commandExecution, title: "swift build"),
        .itemCompleted(threadId: thread, itemId: "cmd-1", kind: .commandExecution, status: .completed),
        .itemStarted(threadId: thread, itemId: "plan-1", kind: .plan, title: "Fix projection"),
        .itemCompleted(threadId: thread, itemId: "plan-1", kind: .plan, status: .completed),
        .itemStarted(threadId: thread, itemId: "diff-1", kind: .fileChange, title: "Sources/Safe.swift"),
        .itemCompleted(threadId: thread, itemId: "diff-1", kind: .fileChange, status: .completed),
        .itemStarted(threadId: thread, itemId: "error-1", kind: .error, title: "Provider rejected the operation"),
        .itemCompleted(threadId: thread, itemId: "error-1", kind: .error, status: .failed),
        .turnCompleted(threadId: thread, turnId: "turn-1", outcome: .completed, errorMessage: nil)
    ]
    events.forEach { projection.ingest($0) }

    var cardProjection = ManagedAgentTranscriptModel(threadId: thread)
    cardProjection.appendUserPrompt("What changed?")
    events.forEach { cardProjection.ingest($0) }
    let parity = transcriptSnapshotDivergences(
        TranscriptCompatibilitySnapshot.capture(projection),
        TranscriptCompatibilitySnapshot.capture(cardProjection)
    )
    expect(parity.isEmpty,
           "P1.5 six-kind fixture must preserve the compatibility card projection exactly: \(parity)")

    let rows = projection.compatibilityRows
    expect(rows.map(\.kind) == ["userMessage", "message", "toolCall", "plan", "diff", "error"],
           "P1.5 compatibility fixture must project all existing six kinds in order; got \(rows.map(\.kind))")
    expect(rows.map(\.status) == [nil, nil, .completed, .completed, .completed, .failed],
           "P1.5 item completion must survive the semantic projection")
    expect(projection.rejectedMutationCount == 0, "P1.5 valid runtime events must not produce rejected semantic mutations")

    let entries = projection.document.entries
    expect(entries.map(\.role) == [.user, .assistant, .system, .system, .system, .system],
           "P1.5 semantic entries must preserve authorship independently of card presentation")
    expect(entries.dropFirst(2).map { $0.blocks.first!.kind } == [.toolCall, .plan, .diff, .error],
           "P1.5 provider items must remain typed structured blocks")
    expect(entries.dropFirst(2).compactMap { entry -> String? in
        if case .providerItem(provider: "runtime", itemID: let itemID) = entry.provenance { return itemID }
        return nil
    } == ["cmd-1", "plan-1", "diff-1", "error-1"],
           "P1.5 provider item IDs must be stable entry provenance")

    // A kind switch, an interleaved item, and a new turn are all hard run
    // boundaries. This is the positive assertion for the named merge failure.
    var boundaries = AgentTranscriptProjection(threadId: thread)
    let boundaryEvents: [AgentRuntimeEvent] = [
        .turnStarted(threadId: thread, turnId: "turn-a"),
        .contentDelta(threadId: thread, turnId: "turn-a", streamKind: .assistant, delta: "assistant one"),
        .contentDelta(threadId: thread, turnId: "turn-a", streamKind: .reasoning, delta: "reasoning one"),
        .contentDelta(threadId: thread, turnId: "turn-a", streamKind: .assistant, delta: "assistant two"),
        .turnStarted(threadId: thread, turnId: "turn-b"),
        .contentDelta(threadId: thread, turnId: "turn-b", streamKind: .assistant, delta: "assistant three")
    ]
    boundaryEvents.forEach { boundaries.ingest($0) }
    expect(boundaries.document.entries.map(\.role) == [.assistant, .reasoning, .assistant, .assistant],
           "P1.5 assistant/reasoning runs must not merge across kind or turn boundaries")
    expect(Set(boundaries.document.entries.map(\.id)).count == 4,
           "P1.5 every separated stream run must retain a distinct stable identity")

    var outputs = AgentTranscriptProjection(threadId: thread)
    outputs.ingest(.contentDelta(threadId: thread, turnId: "turn-output", streamKind: .commandOutput, delta: "build output"))
    outputs.ingest(.runtimeError(threadId: thread, message: "runtime disconnected"))
    expect(outputs.document.entries.map { $0.blocks.first!.kind } == [.commandOutput, .error],
           "P1.5 command deltas and runtime errors must map to typed blocks")
    expect(outputs.compatibilityRows.map(\.body) == ["build output", "runtime disconnected"],
           "P1.5 explicit safe display text must survive projection")

    var filtering = AgentTranscriptProjection(threadId: thread)
    filtering.ingest(.contentDelta(threadId: "other-thread", turnId: "other-turn", streamKind: .assistant, delta: "must not appear"))
    expect(filtering.document.entries.isEmpty, "P1.5 must ignore body events belonging to another thread")

    let secretCommand = "printf SUPER_SECRET"
    var privacy = AgentTranscriptProjection(threadId: thread)
    privacy.ingest(.itemStarted(threadId: thread, itemId: "private-tool", kind: .commandExecution, title: "shell"))
    let encoded = try! JSONEncoder().encode(privacy.document)
    let projected = String(decoding: encoded, as: UTF8.self)
    expect(!projected.contains(secretCommand),
           "P1.5 must not invent or interpolate raw tool arguments absent from AgentRuntimeEvent")

    print("Agent transcript projection checks passed: six compatibility kinds, stable provenance, stream boundaries, command/error typing, and thread filter")
}
