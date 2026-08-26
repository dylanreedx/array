import ContinuumRevivedCore
import Foundation

/// T6 (translator half) — Array receives a pi `delegate_agent` child and stops
/// calling it a shell command.
///
/// Dylan: *"delegate agent in Pi doesn't work."* `delegate_agent` is not pi-native
/// and not Array's: it comes from the third-party `harness-agents` extension, and
/// it dispatches its child as a SEPARATE `pi --mode json -p --no-session` process
/// whose stdout the parent appends to `.pi/agent-runs/<runId>/events.jsonl`. So
/// unlike claude — where a child's frames arrive inline keyed by
/// `parent_tool_use_id` — the child has to be read from a file whose name only
/// arrives in the tool's RESULT.
///
/// Every shape asserted here was measured on pi 0.84.1 in a throwaway /tmp repo,
/// not read off the extension's source. Behaviour, never source text: both halves
/// drive the production translator over the committed captures.
func runPiDelegateSupplyChecks() {
    func fixture(_ name: String) -> [String]? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)", isDirectory: false)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
    guard let parentLines = fixture("pi-delegate-agent-turn.jsonl"),
          let childLines = fixture("pi-delegate-run-events.jsonl") else {
        expect(false, "T6: a committed pi delegate capture is missing")
        return
    }

    // MARK: the fixtures' own teeth
    //
    // A fixture-backed witness's favourite failure is asserting over a capture
    // that no longer contains the thing under test. Prove the shapes exist first.
    func objects(_ lines: [String]) -> [[String: Any]] {
        lines.compactMap {
            guard let data = $0.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }
    let parentObjects = objects(parentLines)
    expect(parentObjects.count == parentLines.count,
           "T6: the parent capture has unparseable lines")
    expect(parentObjects.contains { ($0["toolName"] as? String) == "delegate_agent" },
           "T6: the parent capture contains no delegate_agent call — it witnesses nothing")
    let childObjects = objects(childLines)
    expect(childObjects.count == childLines.count, "T6: the child capture has unparseable lines")
    // Measured: the extension REWRITES events.jsonl when the run completes and the
    // rewrite strips every `message_update` (24 → 0 in the probe). The committed
    // capture is deliberately in that post-compaction shape, because that is the
    // shape a completed run actually has — a fixture full of deltas would prove
    // the easy case and ship the broken one.
    expect(!childObjects.contains { ($0["type"] as? String) == "message_update" },
           "T6: the child capture still has message_update lines, so it is not the post-compaction shape the replay path exists for")
    expect(childObjects.contains {
        ($0["type"] as? String) == "message_end"
            && (($0["message"] as? [String: Any])?["role"] as? String) == "assistant"
    }, "T6: the child capture has no completed assistant message — nothing to recover prose from")

    let taskText = "Survey the recipe column helpers and report what they share."

    // MARK: 1 · the parent's stream announces an OBSERVED child, and binds its run

    final class Collected: @unchecked Sendable {
        var requests: [SpawnRequest] = []
        var runs: [ObservedRunHandle] = []
        var details: [(String, [(key: String, value: String)])] = []
    }
    let collected = Collected()
    var parent = PiEventTranslator(
        workingDirectory: URL(fileURLWithPath: "/private/tmp/fixture-repo", isDirectory: true),
        now: { Date(timeIntervalSinceReferenceDate: 900) })
    parent.onSpawnRequest = { collected.requests.append($0) }
    parent.onObservedRun = { collected.runs.append($0) }
    parent.onRuntimeObservation = { observation in
        if case let .toolDetail(itemId, detail) = observation {
            collected.details.append((itemId, detail.fields))
        }
    }
    let parentEvents = parentLines.flatMap { parent.translate(line: $0) }

    expect(collected.requests.count == 1,
           "T6: expected exactly one delegation from the parent turn, got \(collected.requests.count)")
    if let request = collected.requests.first {
        // The child is the EXTENSION's, not Array's. This is what stops a composer
        // and a Stop appearing on a process Array cannot prompt.
        expect(request.observedOnly,
               "T6: a delegate_agent child must be observedOnly — Array does not run it and must not offer to")
        expect(request.role == "code-scout",
               "T6: `agent` must map to the role, got \(String(describing: request.role))")
        expect(request.prompt == taskText,
               "T6: `task` must map to the prompt, got \(request.prompt)")
        // Keyed on the tool call id, never the runId: the runId embeds a timestamp
        // and a random suffix, so it is not re-derivable and would mint a fresh
        // child on every re-observation.
        expect(request.sourceItemID == "call_fixture_delegate_1",
               "T6: the child must be identified by its tool call id, got \(String(describing: request.sourceItemID))")
        expect(!request.isolated,
               "T6: `worktree: false` must not be read as isolated")
    }
    expect(collected.runs.count == 1,
           "T6: expected one observed-run binding, got \(collected.runs.count)")
    expect(collected.runs.first?.runId == "code-scout-20260825T141759Z-a23808",
           "T6: the runId must come from the tool result's details, got \(String(describing: collected.runs.first?.runId))")
    expect(collected.runs.first?.toolUseID == "call_fixture_delegate_1",
           "T6: the run binding must name the same tool call the child was minted from")

    // The task body reached the supervisor out of band and NOWHERE else. It is in
    // the tool result's `details.task` on the wire, so this is a live risk, not a
    // theoretical one.
    for event in parentEvents {
        expect(!"\(event)".contains(taskText),
               "T6: the child's task body crossed the I5 boundary in \(event)")
    }
    for (itemId, fields) in collected.details {
        for field in fields {
            expect(!field.value.contains(taskText),
                   "T6: the child's task body was published as a tool-detail field \(field.key) on \(itemId)")
        }
    }
    // The delegation is not a shell command.
    let delegationKinds = parentEvents.compactMap { event -> ItemKind? in
        if case let .itemStarted(_, _, kind, _) = event { return kind }
        return nil
    }
    expect(delegationKinds.contains(.subagent),
           "T6: a delegate_agent call must start a .subagent item, got \(delegationKinds)")

    // MARK: 2 · replaying the child's file gives the child's work — prose included

    func replayChild(recoveringProse: Bool) -> [AgentRuntimeEvent] {
        var child = PiEventTranslator(
            workingDirectory: URL(fileURLWithPath: "/private/tmp/fixture-repo", isDirectory: true),
            now: { Date(timeIntervalSinceReferenceDate: 900) },
            replayingCompletedMessages: recoveringProse)
        return childLines.flatMap { child.translate(line: $0) }
    }
    func assistantText(_ events: [AgentRuntimeEvent]) -> [String] {
        events.compactMap { event in
            if case let .contentDelta(_, _, streamKind, delta) = event, streamKind == .assistant {
                return delta
            }
            return nil
        }
    }
    let recovered = replayChild(recoveringProse: true)
    let notRecovered = replayChild(recoveringProse: false)

    // The flag's own teeth: >0 with it, exactly 0 without. Without that pair the
    // assertion below would pass on a translator that had always read message_end,
    // which would double every word on the LIVE path.
    expect(!assistantText(recovered).isEmpty,
           "T6: replaying a completed child recovered no assistant prose — the run's deltas are stripped at completion, so message_end is the only source left")
    expect(assistantText(notRecovered).isEmpty,
           "T6: the live path must not read completed messages, or every streamed word is emitted twice")
    expect(assistantText(recovered).contains { $0.contains("shared descriptor") },
           "T6: the recovered prose is not what the child actually said: \(assistantText(recovered))")

    // The child's own tool calls arrive as the child's work.
    let childTools = recovered.compactMap { event -> String? in
        if case let .itemStarted(_, _, _, title) = event { return title }
        return nil
    }
    expect(childTools.contains("read") && childTools.contains("grep"),
           "T6: the child's tool calls did not survive the replay, got \(childTools)")

    // And the ONE line in the child's file that holds the prompt body is the one
    // line the replay refuses to read. Measured: the task text appears in the
    // child's `started` argv and in its user `message_start`/`message_end`.
    expect(childLines.contains { $0.contains(taskText) },
           "T6: the child capture no longer contains the task text, so the exclusion below is vacuous")
    for event in recovered {
        expect(!"\(event)".contains(taskText),
               "T6: replaying the child republished its prompt body in \(event)")
    }

    // MARK: 2b · the shape production ACTUALLY reads while the run is live
    //
    // The capture above is the post-compaction shape. Production does not wait for
    // it: the tail polls at 0.25s and the extension only rewrites `events.jsonl`
    // when the run ENDS, so for the whole duration of the run Array reads a file
    // that holds BOTH forms of the same words — `message_update` deltas AND the
    // `message_end` that closes them. A recovery keyed on the reader's mode says
    // every sentence twice for that entire window.
    //
    // So the recovery is keyed on the MESSAGE, not on the reader: text is
    // recovered from `message_end` only for a message that never streamed. That
    // rule is correct in both file shapes, which is why this check and the one
    // above run the SAME production flag over two different captures.
    guard let liveLines = fixture("pi-delegate-run-events-live.jsonl") else {
        expect(false, "T6: the pre-compaction pi delegate capture is missing")
        return
    }
    let liveObjects = objects(liveLines)
    expect(liveObjects.count == liveLines.count, "T6: the live child capture has unparseable lines")
    // The fixture's own teeth, both halves: this capture must contain the deltas
    // the post-compaction one lacks, AND the completed message that duplicates
    // them. Without either, the doubling cannot occur and the check is vacuous.
    expect(liveObjects.contains { ($0["type"] as? String) == "message_update" },
           "T6: the live child capture has no message_update lines, so it is not the pre-compaction shape")
    expect(liveObjects.contains {
        ($0["type"] as? String) == "message_end"
            && (($0["message"] as? [String: Any])?["role"] as? String) == "assistant"
    }, "T6: the live child capture has no completed assistant message, so nothing could double")

    var liveTranslator = PiEventTranslator(
        workingDirectory: URL(fileURLWithPath: "/private/tmp/fixture-repo", isDirectory: true),
        now: { Date(timeIntervalSinceReferenceDate: 900) },
        // Exactly what `AgentSupervisor.bindObservedRun` builds. A witness that
        // passed `false` here would be testing a translator production never makes.
        replayingCompletedMessages: true)
    let liveEvents = liveLines.flatMap { liveTranslator.translate(line: $0) }
    let liveProse = assistantText(liveEvents).joined()
    let sentence = "Both helpers build their column list from the same shared descriptor, then diverge only in how they format the blend column."
    expect(liveProse == sentence,
           "T6: a live-tailed child said its answer more than once — got \(liveProse.count) characters of prose for a \(sentence.count)-character answer")

    // And the streamed path still streams: the words must arrive as the deltas
    // they were, not as one block delivered at message_end.
    expect(assistantText(liveEvents).count >= 3,
           "T6: the live child's prose arrived in \(assistantText(liveEvents).count) pieces — the deltas were dropped in favour of the completed message, which is the opposite defect")

    print("Pi delegate supply checks passed: a third-party delegate_agent call mints one observed read-only child keyed on its tool call id, binds its run directory from the tool result, keeps the task body off the event boundary and off the detail channel, and a completed run's prose is recovered from message_end without the live path reading it twice")
}
