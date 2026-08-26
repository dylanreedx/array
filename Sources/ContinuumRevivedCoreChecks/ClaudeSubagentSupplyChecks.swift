import ContinuumRevivedCore
import Foundation

/// C7 (translator half) — Array receives a claude subagent and stops calling it
/// a shell command.
///
/// Replayed against the real capture in `Fixtures/claude-subagent-turn.jsonl`,
/// taken with production argv plus `--forward-subagent-text` on claude 2.1.241.
/// Anthropic's own headless documentation states the contract this asserts:
/// subagent messages carry the spawning tool call's id in `parent_tool_use_id`,
/// and the main conversation carries null.
///
/// Behaviour, never source text: every assertion below drives the production
/// translator over real captured bytes.
func runClaudeSubagentSupplyChecks() {
    let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/claude-subagent-turn.jsonl", isDirectory: false)
    guard let text = try? String(contentsOf: fixtureURL, encoding: .utf8) else {
        expect(false, "C7: the committed claude subagent capture is missing")
        return
    }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    expect(lines.count > 20,
           "C7: the subagent fixture looks truncated at \(lines.count) lines")

    // The capture must actually contain what it claims to, or every assertion
    // below is vacuous — the failure mode a fixture-backed witness is most prone
    // to. This is the fixture's own teeth.
    let parented = lines.filter {
        guard let data = $0.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        guard let parent = object["parent_tool_use_id"] else { return false }
        return !(parent is NSNull)
    }
    expect(parented.count >= 4,
           "C7: the fixture carries \(parented.count) frames with a non-null parent_tool_use_id — a capture with none witnesses nothing")

    final class Collected: @unchecked Sendable {
        var requests: [SpawnRequest] = []
        var details: [(String, [(key: String, value: String)])] = []
        var subagentEvents: [(String, AgentRuntimeEvent)] = []
    }
    let collected = Collected()
    var translator = ClaudeEventTranslator(
        runToken: "run1", now: { Date(timeIntervalSinceReferenceDate: 900) })
    translator.onSpawnRequest = { collected.requests.append($0) }
    translator.onSubagentEvent = { toolUseID, event in
        collected.subagentEvents.append((toolUseID, event))
    }
    translator.onRuntimeObservation = { observation in
        if case let .toolDetail(itemId, detail) = observation {
            collected.details.append((itemId, detail.fields))
        }
    }
    let events = lines.flatMap { translator.translate(line: $0) }

    // 1. Exactly one child was announced, and it is the harness's, not ours.
    expect(collected.requests.count == 1,
           "C7: expected one spawn request from the Agent tool call, got \(collected.requests.count)")
    guard let request = collected.requests.first else { return }
    expect(request.observedOnly,
           "C7: a claude Agent call reports a child claude ALREADY started — Array must never claim to run it")
    expect(request.role == "general-purpose",
           "C7: subagent_type must become the child's role, got \(String(describing: request.role))")
    expect(!(request.prompt.isEmpty),
           "C7: the child's task must reach the local spawn channel")

    // 2. The announcement is keyed by the id the child's own frames carry.
    //    Without this the child's work cannot be tied to the call that made it.
    guard let toolUseID = request.sourceItemID else {
        expect(false, "C7: the spawn request carries no tool_use id")
        return
    }
    let parentIDs = Set(parented.compactMap { line -> String? in
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["parent_tool_use_id"] as? String
    })
    expect(parentIDs == [toolUseID],
           "C7: the child's frames name \(parentIDs), the announcement names \(toolUseID) — they must be the same id")

    // 3. The row is a subagent, not a command execution. It used to reach
    //    `.commandExecution` through `default:`.
    let agentItems = events.compactMap { event -> (String, ItemKind, String?)? in
        guard case let .itemStarted(_, itemId, kind, title) = event else { return nil }
        return (itemId, kind, title)
    }.filter { $0.0 == toolUseID }
    expect(agentItems.count == 1,
           "C7: expected one itemStarted for the Agent call, got \(agentItems.count)")
    expect(agentItems.first?.1 == .subagent,
           "C7: the Agent call must be an .subagent item, got \(String(describing: agentItems.first?.1)) — delegating is not running a command")

    // 4. The role id is published; the model-authored prompt is not.
    let agentFields = collected.details.first(where: { $0.0 == toolUseID })?.1 ?? []
    expect(agentFields.contains(where: { $0.key == "subagent_type" && $0.value == "general-purpose" }),
           "C7: subagent_type is a role id and must reach the tool-detail channel, got \(agentFields.map(\.key))")
    expect(!agentFields.contains(where: { $0.key == "prompt" }),
           "C7: a model-authored prompt must NEVER cross the tool-detail boundary")
    for (_, fields) in collected.details {
        for field in fields {
            expect(!field.value.contains("/Users/"),
                   "C7: a host path reached the tool-detail channel: \(field.key)")
        }
    }

    // 5. THE HALF THAT WAS MISSING. Announcing a child and never delivering its
    //    work produces exactly what shipped first: a chip, an empty tile, and a
    //    parent that looks hung. Every frame the child authored must arrive on
    //    the child channel keyed by the id that spawned it, and NONE of it may
    //    reach the parent's own timeline — the parent stays an index.
    let childEvents = collected.subagentEvents
    expect(!childEvents.isEmpty,
           "C7: the child's own frames produced no events — the child transcript can never fill")
    expect(Set(childEvents.map(\.0)) == [toolUseID],
           "C7: child events are keyed by \(Set(childEvents.map(\.0))), expected only \(toolUseID)")

    // The child said something, not merely called tools. That is what
    // `--forward-subagent-text` buys, and without the flag this is empty.
    let childSpoke = childEvents.contains { _, event in
        if case .contentDelta = event { return true }
        if case let .itemStarted(_, _, kind, _) = event { return kind == .assistantMessage }
        return false
    }
    expect(childSpoke,
           "C7: the child produced no prose at all — capture argv is missing --forward-subagent-text, or its text frames are being dropped")

    // And the parent's timeline never carried the child's work.
    let parentItemIDs = Set(events.compactMap { event -> String? in
        if case let .itemStarted(_, itemId, _, _) = event { return itemId }
        return nil
    })
    let childItemIDs = Set(childEvents.compactMap { _, event -> String? in
        if case let .itemStarted(_, itemId, _, _) = event { return itemId }
        return nil
    })
    expect(parentItemIDs.isDisjoint(with: childItemIDs),
           "C7: the parent's timeline carried the child's items \(parentItemIDs.intersection(childItemIDs)) — a parent is an index, not a mirror")

    print("Claude subagent supply checks passed: one observed-only child announced from the real capture, keyed by the id its own frames carry, rendered as a subagent rather than a command execution, with the role id published and the prompt withheld, and the child's own frames - prose included - routed to the child while the parent's timeline stayed an index")
}
