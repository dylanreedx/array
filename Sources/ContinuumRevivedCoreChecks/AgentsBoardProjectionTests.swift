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
