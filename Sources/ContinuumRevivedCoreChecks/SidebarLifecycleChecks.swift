import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// Confidence pass, sidebar stream (`.plans/70`, S4): the pure derivations the
/// sidebar is drawn from. The app leg `--sidebar-truth-check` drives the same
/// facts through the real close paths and the rendered list; this arm pins each
/// rung on its own so a regression names the rung, not just the symptom.
func runSidebarLifecycleChecks() {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func record(
        _ name: String, tile: UUID? = UUID(), parent: AgentID? = nil,
        closeRequestedAt: Date? = nil, archivedAt: Date? = nil
    ) -> AgentRecord {
        AgentRecord(
            id: AgentID(rawValue: UUID()), displayName: name, model: "openai-codex/gpt-5.6-sol",
            thinking: "medium", cwd: "/tmp/sidebar-lifecycle", parentAgentID: parent,
            createdAt: now.addingTimeInterval(-600), lastActivityAt: now.addingTimeInterval(-60),
            tileId: tile, archivedAt: archivedAt, closeRequestedAt: closeRequestedAt)
    }

    // 1 · closeRequestedAt is durable and optional: it round-trips exactly, and a
    // record written before it existed decodes it as absent.
    let closing = record("closing", closeRequestedAt: now.addingTimeInterval(-30))
    do {
        let data = try JSONEncoder().encode(closing)
        let decoded = try JSONDecoder().decode(AgentRecord.self, from: data)
        expect(decoded.closeRequestedAt == closing.closeRequestedAt,
               "closeRequestedAt must round-trip exactly — got \(String(describing: decoded.closeRequestedAt))")
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        expect(object["closeRequestedAtReferenceInterval"] != nil,
               "closeRequestedAt must be written under its reference-interval key")
        object.removeValue(forKey: "closeRequestedAtReferenceInterval")
        let legacy = try JSONDecoder().decode(
            AgentRecord.self, from: JSONSerialization.data(withJSONObject: object))
        expect(legacy.closeRequestedAt == nil, "a record from before the field decodes it as absent")
        object["closeRequestedAtReferenceInterval"] = "not a number"
        let malformed = try JSONDecoder().decode(
            AgentRecord.self, from: JSONSerialization.data(withJSONObject: object))
        expect(malformed.closeRequestedAt == nil && malformed.id == closing.id,
               "a malformed close stamp reads as absent rather than dropping the agent")
    } catch {
        expect(false, "closeRequestedAt codec threw: \(error)")
    }

    // 2 · The rung. Idle + close intent → History, dated by the intent. Busy +
    // close intent → still active, and Finishing.
    let idleFacts = AgentLifecycleFacts()
    let busyFacts = AgentLifecycleFacts(hasLiveRunner: true)
    expect(closing.lifecycle(facts: idleFacts, now: now) == .archived(at: closing.closeRequestedAt!),
           "an idle agent whose tile was closed is History — got \(closing.lifecycle(facts: idleFacts, now: now))")
    expect(closing.closingSince(facts: idleFacts, now: now) == nil,
           "an idle closed agent is not 'Finishing' — it has finished")
    expect(closing.lifecycle(facts: busyFacts, now: now) == .active,
           "a WORKING agent whose tile was closed stays live until its turn ends")
    expect(closing.closingSince(facts: busyFacts, now: now) == closing.closeRequestedAt,
           "…and reads Finishing, counted from the close")
    let pendingFacts = AgentLifecycleFacts(attentionIsYours: true)
    expect(closing.lifecycle(facts: pendingFacts, now: now) == .active,
           "a closed agent holding a question for you is never buried in History")
    let childBlocked = AgentLifecycleFacts(descendantBlockers: .sessionRunning)
    expect(closing.closingSince(facts: childBlocked, now: now) != nil,
           "a closed parent whose subagent is still working is Finishing, not History")

    // 3 · R3: a binding nothing can find is a closed window — but only for a
    // record that HAS a tile, and the date is when it last did anything.
    let lost = record("lost")
    let unreachable = AgentLifecycleFacts(tileUnreachable: true)
    expect(lost.lifecycle(facts: unreachable, now: now) == .archived(at: lost.lastActivityAt),
           "a record naming a tile no document holds derives closed — got \(lost.lifecycle(facts: unreachable, now: now))")
    expect(lost.lifecycle(facts: AgentLifecycleFacts(hasLiveRunner: true, tileUnreachable: true), now: now) == .active,
           "…unless it is working, when it is Finishing")
    let headless = record("headless", tile: nil)
    expect(headless.lifecycle(facts: unreachable, now: now) == .active,
           "a headless agent has no tile to lose — never derived closed")

    // 4 · R2: children follow their topmost present ancestor — section, Finishing
    // and workspace — and a child with no parent in the list keeps its own.
    let parentId = UUID(), childId = UUID(), grandchildId = UUID(), orphanId = UUID()
    func row(_ id: UUID, parent: UUID?, lifecycle: InboxLifecycle,
             closingSince: Date? = nil, workspace: String?) -> AgentInboxRow {
        AgentInboxRow(
            id: id, title: "row", workspaceName: workspace, state: .ready,
            lifecycle: lifecycle, createdAt: now, parentId: parent, closingSince: closingSince)
    }
    let closedAt = now.addingTimeInterval(-10)
    let placed = AgentInboxRowBuilder.placingChildrenWithParents([
        row(parentId, parent: nil, lifecycle: .archived(at: closedAt), workspace: "Alpha"),
        row(childId, parent: parentId, lifecycle: .active, workspace: nil),
        row(grandchildId, parent: childId, lifecycle: .settled(at: now), workspace: "Beta"),
        row(orphanId, parent: UUID(), lifecycle: .active, workspace: nil),
    ])
    let byId = Dictionary(uniqueKeysWithValues: placed.map { ($0.id, $0) })
    expect(byId[childId]?.lifecycle == .archived(at: closedAt) && byId[childId]?.workspaceName == "Alpha",
           "a closed parent's child goes to History with it, in its workspace — got \(String(describing: byId[childId]))")
    expect(byId[grandchildId]?.lifecycle == .archived(at: closedAt),
           "a grandchild follows the ROOT, not just its parent")
    expect(byId[orphanId]?.lifecycle == .active,
           "a child whose parent is absent keeps its own lifecycle — nothing to follow, nothing lost")
    let finishingPlaced = AgentInboxRowBuilder.placingChildrenWithParents([
        row(parentId, parent: nil, lifecycle: .active, closingSince: closedAt, workspace: "Alpha"),
        row(childId, parent: parentId, lifecycle: .active, workspace: "Alpha"),
    ])
    expect(finishingPlaced.last?.closingSince == closedAt && finishingPlaced.last?.variant == .slim,
           "a Finishing parent's child draws slim with it")
    expect(row(parentId, parent: nil, lifecycle: .active, closingSince: closedAt, workspace: nil)
            .presentationLabel == AgentStatusVocabulary.finishing,
           "a Finishing row says Finishing")

    print("SidebarLifecycle: closeRequestedAt round-trips and decodes absent; idle close → History, busy close → Finishing; "
          + "an unreachable binding derives closed (never a headless one); children follow their root's section, Finishing and workspace")
}
