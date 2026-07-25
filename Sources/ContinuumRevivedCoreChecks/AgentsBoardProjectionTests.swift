import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

private let agentsBoardReplica = UUID(uuidString: "61000000-0000-4000-8000-000000000061")!

private func boardEvent(
    agentId: UUID,
    tileId: UUID? = nil,
    sequence: UInt64,
    status: AgentStatus,
    summary: String,
    occurredAt: Date,
    approvalRequestId: String? = nil,
    replicaId: UUID = agentsBoardReplica
) -> AgentActivityEvent {
    AgentActivityEvent(
        stamping: AgentActivityEventDraft(
            agentId: agentId,
            tileId: tileId,
            runId: nil,
            tone: status == .needsAttention ? .approval : .info,
            kind: status == .needsAttention ? "needs-attention" : "status.\(status.rawValue)",
            status: status,
            summary: summary,
            occurredAt: occurredAt,
            approvalRequestId: approvalRequestId
        ),
        sequence: sequence,
        replicaId: replicaId
    )
}

func runAgentsBoardProjectionChecks() {
    let agentA = UUID(uuidString: "61000000-0000-4000-8000-00000000000A")!
    let agentB = UUID(uuidString: "61000000-0000-4000-8000-00000000000B")!
    let agentC = UUID(uuidString: "61000000-0000-4000-8000-00000000000C")!
    let agentD = UUID(uuidString: "61000000-0000-4000-8000-00000000000D")!
    let base = Date(timeIntervalSinceReferenceDate: 6_100)

    let snapshot = ActivityLogSnapshot(
        snapshotSequence: 4,
        snapshotReplicaId: agentsBoardReplica,
        byAgent: [
            agentA: AgentActivity(status: .done, lastSummary: "done older", recent: [], updatedAt: base.addingTimeInterval(10)),
            agentB: AgentActivity(status: .working, lastSummary: "working newest", recent: [], updatedAt: base.addingTimeInterval(30)),
            agentC: AgentActivity(status: .needsAttention, lastSummary: "approval needed", recent: [], updatedAt: base.addingTimeInterval(20)),
            agentD: AgentActivity(status: .needsAttention, lastSummary: "approval tie", recent: [], updatedAt: base.addingTimeInterval(20)),
        ]
    )

    let rows = AgentsBoardProjection.rows(from: snapshot)
    expect(rows.map(\.agentId) == [agentC, agentD, agentB, agentA], "AgentsBoardProjection sort: needsAttention first, working second, then rest; ties by agentId")
    expect(rows.map(\.lastSummary) == ["approval needed", "approval tie", "working newest", "done older"], "AgentsBoardProjection rows carry summaries")
    let measuredOrder = rows.map { $0.agentId.uuidString }.joined(separator: ",")
    let measuredStatuses = rows.map { $0.status.rawValue }.joined(separator: ",")
    print("AgentsBoardProjection sort measuredOrder=\(measuredOrder) statuses=\(measuredStatuses)")

    var incremental = ActivityLogSnapshot.empty
    let events = [
        boardEvent(agentId: agentA, sequence: 1, status: .working, summary: "a working", occurredAt: base),
        boardEvent(agentId: agentB, sequence: 2, status: .needsAttention, summary: "b needs", occurredAt: base.addingTimeInterval(1)),
        boardEvent(agentId: agentA, sequence: 3, status: .done, summary: "a done", occurredAt: base.addingTimeInterval(2)),
        boardEvent(agentId: agentC, sequence: 4, status: .working, summary: "c working", occurredAt: base.addingTimeInterval(3)),
    ]
    for event in events {
        incremental = AgentsBoardProjection.applyEvent(event, to: incremental)
    }
    let refolded = events.reduce(ActivityLogSnapshot.empty) { apply($0, $1) }
    expect(incremental == refolded, "AgentsBoardProjection applyEvent must equal full ActivityLogSnapshot fold")
    expect(AgentsBoardProjection.rows(from: incremental).map(\.agentId) == [agentB, agentC, agentA], "AgentsBoardProjection incremental rows sort from folded snapshot")
    print("AgentsBoardProjection incremental measuredSequence=\(incremental.snapshotSequence) rowCount=\(AgentsBoardProjection.rows(from: incremental).count)")

    // MARK: P2B.7 — incremental refresh: the fold stays equal, and the change-set
    // names exactly what moved.
    //
    // Ticket: docs/38-tickets/90-agent-ux/P2B.7-incremental-refresh.md

    // Fold equality under a REVERSED arrival order, not just the sorted one above:
    // the desktop now folds an event the moment it observes it, so "incrementally
    // equals from scratch" has to hold for an arrival order that is not canonical
    // order. (The fold is a merge on `(sequence, replicaId)` — see `apply`.)
    var reversedFold = ActivityLogSnapshot.empty
    for event in events.reversed() {
        reversedFold = AgentsBoardProjection.applyEvent(event, to: reversedFold)
    }
    expect(reversedFold == refolded, "P2B.7: folding the same events in reverse arrival order must equal the from-scratch fold")
    expect(
        AgentsBoardProjection.changeSet(from: .empty, to: reversedFold)
            == AgentsBoardProjection.changeSet(from: .empty, to: refolded),
        "P2B.7: the change-set is a function of the snapshots, so arrival order cannot change it"
    )

    // ONE agent's event, and the change-set names ONE agent. This is the assertion
    // the ticket exists for: a list view diffing on this must not be told to
    // re-render agents that did not move.
    let oneAgentDraft = AgentActivityEventDraft(
        agentId: agentB,
        tileId: nil,
        runId: nil,
        tone: .approval,
        kind: "approval.requested",
        status: .needsAttention,
        summary: "b raised its hand",
        occurredAt: base.addingTimeInterval(40)
    )
    let afterOne = AgentsBoardProjection.appendLocal(oneAgentDraft, to: incremental, replicaId: agentsBoardReplica)
    let oneChange = AgentsBoardProjection.changeSet(from: incremental, to: afterOne)
    expect(oneChange.updated == [agentB], "P2B.7: one agent's event updates exactly that agent — got \(oneChange.updated.count) updated")
    expect(oneChange.added.isEmpty && oneChange.removed.isEmpty, "P2B.7: an event on a known agent adds and removes nobody")
    expect(oneChange.touched == [agentB], "P2B.7: touched is the union and names only the agent that moved")
    // …and the fold actually took it: a change-set over a snapshot that ignored the
    // event would be empty, which would satisfy "only that agent" vacuously.
    expect(afterOne.byAgent[agentB]?.status == .needsAttention, "P2B.7: appendLocal must move the agent's status — got \(String(describing: afterOne.byAgent[agentB]?.status))")
    expect(afterOne.byAgent[agentB]?.lastSummary == "b raised its hand", "P2B.7: appendLocal must move the agent's summary")

    // THE SEQUENCE RULE. `appendLocal` must sort after everything already folded,
    // or the fold would ingest the event and then keep deriving from the older one.
    // Witnessed by stamping the same draft with a LOW sequence, the way a naive
    // "just use 1" would: the status does not move.
    expect(afterOne.snapshotSequence == incremental.snapshotSequence + 1, "P2B.7: appendLocal stamps one past the snapshot's sequence — got \(afterOne.snapshotSequence)")
    let stale = AgentsBoardProjection.applyEvent(
        AgentActivityEvent(stamping: oneAgentDraft, sequence: 1, replicaId: agentsBoardReplica),
        to: incremental
    )
    expect(
        stale.byAgent[agentB]?.lastSummary == "b needs",
        "P2B.7: a low-sequence stamp must NOT become the agent's current state — that is why appendLocal stamps snapshotSequence + 1 — got \(stale.byAgent[agentB]?.lastSummary ?? "nil")"
    )
    print("P2B.7 lowSequenceStamp measuredSummary=\(stale.byAgent[agentB]?.lastSummary ?? "nil") appendLocalSummary=\(afterOne.byAgent[agentB]?.lastSummary ?? "nil")")

    // ADDED and REMOVED, both directions, on the same pair of snapshots.
    let newcomer = UUID(uuidString: "61000000-0000-4000-8000-00000000000E")!
    let withNewcomer = AgentsBoardProjection.appendLocal(
        AgentActivityEventDraft(
            agentId: newcomer, tileId: nil, runId: nil, tone: .info, kind: "agent.created",
            status: .configuring, summary: "e configuring", occurredAt: base.addingTimeInterval(50)
        ),
        to: afterOne,
        replicaId: agentsBoardReplica
    )
    let addChange = AgentsBoardProjection.changeSet(from: afterOne, to: withNewcomer)
    expect(addChange.added == [newcomer] && addChange.updated.isEmpty && addChange.removed.isEmpty,
           "P2B.7: an agent with no row before is ADDED, and nobody else moves — got added \(addChange.added.count) updated \(addChange.updated.count)")
    let removeChange = AgentsBoardProjection.changeSet(from: withNewcomer, to: afterOne)
    expect(removeChange.removed == [newcomer] && removeChange.added.isEmpty && removeChange.updated.isEmpty,
           "P2B.7: an agent whose row is gone is REMOVED — got removed \(removeChange.removed.count)")

    // NOTHING moved → nothing is reported. A change-set that reported the whole
    // board on every rebuild would be the full reload it replaces.
    expect(AgentsBoardProjection.changeSet(from: withNewcomer, to: withNewcomer).isEmpty,
           "P2B.7: identical snapshots produce an empty change-set")
    // …including across the POSITIONAL RENUMBERING a full rebuild does. Same three
    // agents, same statuses/summaries/clocks, sequence numbers shifted by 100 —
    // which is what `AgentInventory.snapshot` does to every later-sorting agent when
    // one agent is created. `AgentActivity` equality would call all of them updated.
    func renumbered(_ snapshot: ActivityLogSnapshot, by offset: UInt64) -> ActivityLogSnapshot {
        var next = ActivityLogSnapshot.empty
        for event in snapshot.byAgent.values.flatMap(\.recent).sorted(by: { $0.sequence < $1.sequence }) {
            next = apply(next, AgentActivityEvent(
                stamping: AgentActivityEventDraft(
                    agentId: event.agentId, tileId: event.tileId, runId: event.runId, tone: event.tone,
                    kind: event.kind, status: event.status, summary: event.summary,
                    occurredAt: event.occurredAt, approvalRequestId: event.approvalRequestId
                ),
                sequence: event.sequence + offset,
                replicaId: event.replicaId
            ))
        }
        return next
    }
    let shifted = renumbered(withNewcomer, by: 100)
    expect(shifted.byAgent.count == withNewcomer.byAgent.count && shifted != withNewcomer,
           "P2B.7: the renumbering fixture must really shift sequences, or the assertion below is vacuous")
    expect(AgentsBoardProjection.changeSet(from: withNewcomer, to: shifted).isEmpty,
           "P2B.7: positional renumbering alone must NOT report a row as changed — got \(AgentsBoardProjection.changeSet(from: withNewcomer, to: shifted).touched.count) touched")
    print("P2B.7 changeSet measured one=\(oneChange.touched.count) added=\(addChange.added.count) removed=\(removeChange.removed.count) renumbered=\(AgentsBoardProjection.changeSet(from: withNewcomer, to: shifted).touched.count)")

    // AT THE 200-EVENT CAP (from the cross-review): a new event EVICTS the oldest,
    // so `recent.count` stops moving. An event whose status, summary, clock and tile
    // hint all match the one it follows would then be invisible to a count-only
    // witness, while the row's timeline really did change. The oldest survivor's
    // clock is what still moves, and renumbering cannot touch it.
    let capped = UUID(uuidString: "61000000-0000-4000-8000-00000000000F")!
    var atCap = ActivityLogSnapshot.empty
    for index in 1...200 {
        atCap = AgentsBoardProjection.applyEvent(
            boardEvent(
                agentId: capped, sequence: UInt64(index), status: .working,
                summary: "same summary", occurredAt: base.addingTimeInterval(Double(index))
            ),
            to: atCap
        )
    }
    expect(atCap.byAgent[capped]?.recent.count == 200, "P2B.7: the cap fixture must sit exactly at the ring cap — got \(String(describing: atCap.byAgent[capped]?.recent.count))")
    // Identical in every derived field: same status, same summary, same clock as the
    // event it follows, same (nil) tile hint.
    let atCapPlusOne = AgentsBoardProjection.appendLocal(
        AgentActivityEventDraft(
            agentId: capped, tileId: nil, runId: nil, tone: .info, kind: "status.working",
            status: .working, summary: "same summary", occurredAt: base.addingTimeInterval(200)
        ),
        to: atCap,
        replicaId: agentsBoardReplica
    )
    expect(atCapPlusOne.byAgent[capped]?.recent.count == 200, "P2B.7: at the cap the count must NOT move, or this case is not the one being tested — got \(String(describing: atCapPlusOne.byAgent[capped]?.recent.count))")
    expect(
        atCapPlusOne.byAgent[capped]?.status == atCap.byAgent[capped]?.status
            && atCapPlusOne.byAgent[capped]?.lastSummary == atCap.byAgent[capped]?.lastSummary
            && atCapPlusOne.byAgent[capped]?.updatedAt == atCap.byAgent[capped]?.updatedAt,
        "P2B.7: the cap fixture's new event must be indistinguishable in the derived fields, or the witness below is not about the ring"
    )
    expect(
        AgentsBoardProjection.changeSet(from: atCap, to: atCapPlusOne).updated == [capped],
        "P2B.7: an event that evicts the oldest at the cap must still report the row as updated — got \(AgentsBoardProjection.changeSet(from: atCap, to: atCapPlusOne).updated.count)"
    )
    print("P2B.7 ringCap measuredCount=\(atCapPlusOne.byAgent[capped]?.recent.count ?? -1) oldestBefore=\(atCap.byAgent[capped]?.recent.first?.occurredAt.timeIntervalSinceReferenceDate ?? 0) oldestAfter=\(atCapPlusOne.byAgent[capped]?.recent.first?.occurredAt.timeIntervalSinceReferenceDate ?? 0)")

    let skewedTimeline = AgentActivity(
        status: .needsAttention,
        lastSummary: "last in ring order",
        recent: [
            boardEvent(agentId: agentA, sequence: 1, status: .needsAttention, summary: "older ring newer clock", occurredAt: base.addingTimeInterval(100)),
            boardEvent(agentId: agentA, sequence: 2, status: .working, summary: "middle ring", occurredAt: base.addingTimeInterval(50)),
            boardEvent(agentId: agentA, sequence: 3, status: .needsAttention, summary: "last in ring order", occurredAt: base),
        ],
        updatedAt: base
    )
    expect(
        AgentsBoardProjection.timelineEvents(for: skewedTimeline).map(\.summary) == ["last in ring order", "middle ring", "older ring newer clock"],
        "AgentsBoardProjection timelineEvents reverses canonical per-agent ring order"
    )
    expect(
        AgentsBoardProjection.latestPendingAttentionEvent(in: skewedTimeline)?.summary == "last in ring order",
        "AgentsBoardProjection latestPendingAttentionEvent selects the last needs-attention event in ring order"
    )
    print("AgentsBoardProjection detailTimeline measured=\(AgentsBoardProjection.timelineEvents(for: skewedTimeline).map(\.summary).joined(separator: ","))")

    // P1.8: this block used to pin `AgentsBoardProjection.presentation(for:)`'s
    // own glyph/colorToken map, which was one of the six duplicates — and its
    // `◍`/"teal" for `configuring` is exactly the drift the ticket removed. The
    // row no longer carries a presentation at all, so what there is to assert is
    // that a row's appearance is reachable ONLY through the shared presenter and
    // agrees with it for every status.
    let expectedGlyphs: [(AgentStatus, String)] = [
        (.working, "●"),
        (.needsAttention, "◆"),
        (.done, "✓"),
        (.stale, "◌"),
        (.configuring, "◐"),
        (.idle, "○"),
    ]
    for (status, glyph) in expectedGlyphs {
        expect(StatusChipPresenter.display(for: status).glyph == glyph,
               "AgentsBoard row glyph for \(status.rawValue) comes from StatusChipPresenter")
    }
    let boardRow = AgentsBoardProjection.rows(from: snapshot).first { $0.status == .needsAttention }
    expect(boardRow != nil, "AgentsBoardProjection: a needs-attention row is projected")
    if let boardRow {
        let display = StatusChipPresenter.display(for: boardRow.status)
        expect(display.glyph == "◆" && display.accent.resolved(for: .dark).hexKey == AccentToken.accentApproval.color.resolved(for: .dark).hexKey,
               "AgentsBoard row presentation is the presenter's, accent sourced from AccentToken")
    }
    print("AgentsBoardProjection presentation measured=\(expectedGlyphs.map { "\($0.0.rawValue):\($0.1)" }.joined(separator: ","))")

    let approvalWithId = boardEvent(
        agentId: agentA,
        sequence: 10,
        status: .needsAttention,
        summary: "approve deployment",
        occurredAt: base.addingTimeInterval(10),
        approvalRequestId: "approval-1"
    )
    let approvalWithoutId = boardEvent(
        agentId: agentB,
        sequence: 11,
        status: .needsAttention,
        summary: "legacy approval",
        occurredAt: base.addingTimeInterval(11)
    )
    let completed = boardEvent(
        agentId: agentC,
        sequence: 12,
        status: .done,
        summary: "finished",
        occurredAt: base.addingTimeInterval(12)
    )
    let approvalsSnapshot = [approvalWithId, approvalWithoutId, completed].reduce(ActivityLogSnapshot.empty) { apply($0, $1) }
    let inboxRows = AgentsBoardProjection.approvalsInboxRows(from: approvalsSnapshot)
    expect(inboxRows.map(\.agentId) == [agentB, agentA], "Approvals inbox rows filter needsAttention and preserve board order")
    expect(AgentsBoardProjection.attentionCount(from: approvalsSnapshot) == 2, "Approvals inbox attentionCount counts needsAttention rows")
    expect(
        AgentsBoardProjection.respondableRequest(in: approvalsSnapshot.byAgent[agentA]!) == ApprovalResponseTarget(agentId: agentA, approvalRequestId: "approval-1"),
        "respondableRequest returns agentId and approvalRequestId when latest pending attention event has an id"
    )
    expect(
        AgentsBoardProjection.respondableRequest(in: approvalsSnapshot.byAgent[agentB]!) == nil,
        "respondableRequest returns nil for legacy pending attention events without approvalRequestId"
    )
    expect(
        AgentsBoardProjection.respondableRequest(in: approvalsSnapshot.byAgent[agentC]!) == nil,
        "respondableRequest returns nil for non-pending activity"
    )
    print("Approvals inbox measured attentionCount=\(AgentsBoardProjection.attentionCount(from: approvalsSnapshot)) rows=\(inboxRows.map(\.lastSummary).joined(separator: ",")) respondable=\(AgentsBoardProjection.respondableRequest(in: approvalsSnapshot.byAgent[agentA]!)?.approvalRequestId ?? "nil")")

    let encodedApproval = try! JSONEncoder().encode(approvalWithId)
    let decodedApproval = try! JSONDecoder().decode(AgentActivityEvent.self, from: encodedApproval)
    expect(decodedApproval == approvalWithId, "AgentActivityEvent approvalRequestId round-trips when present")
    let legacyJSON = """
    {"sequence":13,"replicaId":"61000000-0000-4000-8000-000000000061","tileId":"61000000-0000-4000-8000-00000000000A","tone":"approval","kind":"needs-attention","status":"needsAttention","summary":"legacy","occurredAtReferenceInterval":6113}
    """
    let legacyEvent = try! JSONDecoder().decode(AgentActivityEvent.self, from: Data(legacyJSON.utf8))
    expect(legacyEvent.approvalRequestId == nil, "AgentActivityEvent legacy JSON without approvalRequestId decodes nil")
    print("AgentActivityEvent approvalRequestId codable measured present=\(decodedApproval.approvalRequestId ?? "nil") legacy=\(legacyEvent.approvalRequestId == nil)")

    runP2A8AggregateKeyMigrationChecks()
}

// P2A.8: the aggregate key moved from `tileId` to `agentId`. Everything this
// migration promises is asserted here — the OLD wire shape still decoding, the tile
// becoming an optional hint that no longer gates a row, and the two tile-keyed
// consumers (the sidebar's statuses, the tmux pruner) still able to find their tile.
private func runP2A8AggregateKeyMigrationChecks() {
    let agentA = UUID(uuidString: "61000000-0000-4000-8000-0000000000AA")!
    let tile1 = UUID(uuidString: "61000000-0000-4000-8000-000000000011")!
    let base = Date(timeIntervalSinceReferenceDate: 6_200)

    // --- the COMMITTED old-shape fixture (Fixtures/activity-log-pre-p2a8.json): no
    // agentId, schemaVersion 1, tileId as the aggregate key. Read off disk rather than
    // inlined so the payload this migration is verified against is a real artifact that
    // cannot be quietly reshaped along with the code that reads it.
    let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)
        .appendingPathComponent("activity-log-pre-p2a8.json", isDirectory: false)
    guard let fixtureData = try? Data(contentsOf: fixtureURL),
          let fixture = (try? JSONSerialization.jsonObject(with: fixtureData)) as? [String: Any] else {
        fputs("FAIL: P2A.8 pre-migration fixture missing or unreadable at \(fixtureURL.path)\n", stderr)
        Foundation.exit(1)
    }
    func fixtureJSON(_ key: String) -> Data {
        guard let value = fixture[key],
              let data = try? JSONSerialization.data(withJSONObject: value) else {
            fputs("FAIL: P2A.8 fixture has no \"\(key)\" payload\n", stderr)
            Foundation.exit(1)
        }
        return data
    }
    let legacyEventData = fixtureJSON("event")
    expect(!String(decoding: legacyEventData, as: UTF8.self).contains("agentId"),
           "P2A.8: the committed fixture really is the OLD shape — it names no agentId")
    let migrated = try! JSONDecoder().decode(AgentActivityEvent.self, from: legacyEventData)
    expect(migrated.agentId == agentA && migrated.tileId == agentA,
           "P2A.8: an old-shape event decodes with agentId == its tileId (measured agentId=\(migrated.agentId.uuidString) tileId=\(migrated.tileId?.uuidString ?? "nil"))")
    expect(apply(.empty, migrated).byAgent[agentA] != nil,
           "P2A.8: a migrated old-shape event folds under its agent key")

    // --- an old-shape SNAPSHOT (byTile) decodes into byAgent, KEEPING the hint: the
    // legacy key was the tile, so a phone on this build still offers "Show on canvas"
    // for a row published by a desktop on the old one.
    let migratedSnapshot = try! JSONDecoder().decode(ActivityLogSnapshot.self, from: fixtureJSON("snapshot"))
    expect(migratedSnapshot.byAgent.keys.sorted(by: { $0.uuidString < $1.uuidString }) == [agentA],
           "P2A.8: an old-shape byTile snapshot decodes under byAgent (measured keys=\(migratedSnapshot.byAgent.keys.map(\.uuidString).sorted()))")
    expect(migratedSnapshot.byAgent[agentA]?.tileId == agentA && migratedSnapshot.activity(forTile: agentA) != nil,
           "P2A.8: a migrated byTile entry keeps its legacy key as the tile hint (measured \(migratedSnapshot.byAgent[agentA]?.tileId?.uuidString ?? "nil"))")

    // --- a new payload round-trips, and a headless event keeps no tile
    let headless = boardEvent(agentId: agentA, tileId: nil, sequence: 1, status: .working,
                              summary: "headless working", occurredAt: base)
    let roundTripped = try! JSONDecoder().decode(AgentActivityEvent.self, from: try! JSONEncoder().encode(headless))
    expect(roundTripped == headless && roundTripped.tileId == nil,
           "P2A.8: a headless event round-trips with no tile hint")

    // --- THE POINT OF THE TICKET: a headless agent is observable. Under the old key
    // it had no aggregate key at all, so it could not appear on the phone.
    let headlessRows = AgentsBoardProjection.rows(from: apply(.empty, headless))
    expect(headlessRows.count == 1 && headlessRows[0].agentId == agentA && headlessRows[0].tileId == nil,
           "P2A.8: an agent with no tile still projects a row, with no view hint (measured rows=\(headlessRows.count))")

    // --- the hint follows the view binding through attach, in canonical order
    let attached = boardEvent(agentId: agentA, tileId: tile1, sequence: 2, status: .working,
                              summary: "attached", occurredAt: base.addingTimeInterval(1))
    let detached = boardEvent(agentId: agentA, tileId: nil, sequence: 3, status: .working,
                              summary: "detached again", occurredAt: base.addingTimeInterval(2))
    let afterAttach = [headless, attached].reduce(ActivityLogSnapshot.empty) { apply($0, $1) }
    expect(afterAttach.byAgent[agentA]?.tileId == tile1,
           "P2A.8: attaching a tile sets the snapshot's view hint")
    expect(afterAttach.activity(forTile: tile1)?.lastSummary == "attached",
           "P2A.8: activity(forTile:) finds the agent bound to a tile")
    // Order-independence of the hint, the same property status/lastSummary have:
    // folding the same three events in either order must agree.
    let forward = [headless, attached, detached].reduce(ActivityLogSnapshot.empty) { apply($0, $1) }
    let shuffled = [detached, headless, attached].reduce(ActivityLogSnapshot.empty) { apply($0, $1) }
    expect(forward == shuffled, "P2A.8: the tile hint folds order-independently")
    expect(forward.byAgent[agentA]?.tileId == nil && forward.activity(forTile: tile1) == nil,
           "P2A.8: detaching clears the hint, so the tile has no activity — the agent still does")
    expect(forward.byAgent[agentA]?.recent.count == 3,
           "P2A.8: detaching does not drop the agent's timeline (measured \(forward.byAgent[agentA]?.recent.count ?? -1) events)")

    // --- the file schema marker moved, and a version-1 file is still loadable
    expect(ActivityLogFile.currentSchemaVersion == 2,
           "P2A.8: ActivityLogFile.currentSchemaVersion bumped for the key move (measured \(ActivityLogFile.currentSchemaVersion))")
    let legacyFile = try! JSONDecoder().decode(ActivityLogFile.self, from: fixtureJSON("logFile"))
    expect(legacyFile.schemaVersion < ActivityLogFile.currentSchemaVersion && legacyFile.events.first?.agentId == agentA,
           "P2A.8: a version-1 log file still decodes, its events migrated")
    print("P2A.8 migration measured legacyAgentId=\(migrated.agentId.uuidString) headlessRows=\(headlessRows.count) hintAfterAttach=\(afterAttach.byAgent[agentA]?.tileId?.uuidString ?? "nil") hintAfterDetach=\(forward.byAgent[agentA]?.tileId?.uuidString ?? "nil")")
}
