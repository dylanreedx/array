import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

private let agentsBoardReplica = UUID(uuidString: "61000000-0000-4000-8000-000000000061")!

private func boardEvent(
    tileId: UUID,
    sequence: UInt64,
    status: AgentStatus,
    summary: String,
    occurredAt: Date,
    approvalRequestId: String? = nil,
    replicaId: UUID = agentsBoardReplica
) -> AgentActivityEvent {
    AgentActivityEvent(
        stamping: AgentActivityEventDraft(
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
    let tileA = UUID(uuidString: "61000000-0000-4000-8000-00000000000A")!
    let tileB = UUID(uuidString: "61000000-0000-4000-8000-00000000000B")!
    let tileC = UUID(uuidString: "61000000-0000-4000-8000-00000000000C")!
    let tileD = UUID(uuidString: "61000000-0000-4000-8000-00000000000D")!
    let base = Date(timeIntervalSinceReferenceDate: 6_100)

    let snapshot = ActivityLogSnapshot(
        snapshotSequence: 4,
        snapshotReplicaId: agentsBoardReplica,
        byTile: [
            tileA: TileActivity(status: .done, lastSummary: "done older", recent: [], updatedAt: base.addingTimeInterval(10)),
            tileB: TileActivity(status: .working, lastSummary: "working newest", recent: [], updatedAt: base.addingTimeInterval(30)),
            tileC: TileActivity(status: .needsAttention, lastSummary: "approval needed", recent: [], updatedAt: base.addingTimeInterval(20)),
            tileD: TileActivity(status: .needsAttention, lastSummary: "approval tie", recent: [], updatedAt: base.addingTimeInterval(20)),
        ]
    )

    let rows = AgentsBoardProjection.rows(from: snapshot)
    expect(rows.map(\.tileId) == [tileC, tileD, tileB, tileA], "AgentsBoardProjection sort: needsAttention first, working second, then rest; ties by tileId")
    expect(rows.map(\.lastSummary) == ["approval needed", "approval tie", "working newest", "done older"], "AgentsBoardProjection rows carry summaries")
    let measuredOrder = rows.map { $0.tileId.uuidString }.joined(separator: ",")
    let measuredStatuses = rows.map { $0.status.rawValue }.joined(separator: ",")
    print("AgentsBoardProjection sort measuredOrder=\(measuredOrder) statuses=\(measuredStatuses)")

    var incremental = ActivityLogSnapshot.empty
    let events = [
        boardEvent(tileId: tileA, sequence: 1, status: .working, summary: "a working", occurredAt: base),
        boardEvent(tileId: tileB, sequence: 2, status: .needsAttention, summary: "b needs", occurredAt: base.addingTimeInterval(1)),
        boardEvent(tileId: tileA, sequence: 3, status: .done, summary: "a done", occurredAt: base.addingTimeInterval(2)),
        boardEvent(tileId: tileC, sequence: 4, status: .working, summary: "c working", occurredAt: base.addingTimeInterval(3)),
    ]
    for event in events {
        incremental = AgentsBoardProjection.applyEvent(event, to: incremental)
    }
    let refolded = events.reduce(ActivityLogSnapshot.empty) { apply($0, $1) }
    expect(incremental == refolded, "AgentsBoardProjection applyEvent must equal full ActivityLogSnapshot fold")
    expect(AgentsBoardProjection.rows(from: incremental).map(\.tileId) == [tileB, tileC, tileA], "AgentsBoardProjection incremental rows sort from folded snapshot")
    print("AgentsBoardProjection incremental measuredSequence=\(incremental.snapshotSequence) rowCount=\(AgentsBoardProjection.rows(from: incremental).count)")

    let skewedTimeline = TileActivity(
        status: .needsAttention,
        lastSummary: "last in ring order",
        recent: [
            boardEvent(tileId: tileA, sequence: 1, status: .needsAttention, summary: "older ring newer clock", occurredAt: base.addingTimeInterval(100)),
            boardEvent(tileId: tileA, sequence: 2, status: .working, summary: "middle ring", occurredAt: base.addingTimeInterval(50)),
            boardEvent(tileId: tileA, sequence: 3, status: .needsAttention, summary: "last in ring order", occurredAt: base),
        ],
        updatedAt: base
    )
    expect(
        AgentsBoardProjection.timelineEvents(for: skewedTimeline).map(\.summary) == ["last in ring order", "middle ring", "older ring newer clock"],
        "AgentsBoardProjection timelineEvents reverses canonical per-tile ring order"
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
        tileId: tileA,
        sequence: 10,
        status: .needsAttention,
        summary: "approve deployment",
        occurredAt: base.addingTimeInterval(10),
        approvalRequestId: "approval-1"
    )
    let approvalWithoutId = boardEvent(
        tileId: tileB,
        sequence: 11,
        status: .needsAttention,
        summary: "legacy approval",
        occurredAt: base.addingTimeInterval(11)
    )
    let completed = boardEvent(
        tileId: tileC,
        sequence: 12,
        status: .done,
        summary: "finished",
        occurredAt: base.addingTimeInterval(12)
    )
    let approvalsSnapshot = [approvalWithId, approvalWithoutId, completed].reduce(ActivityLogSnapshot.empty) { apply($0, $1) }
    let inboxRows = AgentsBoardProjection.approvalsInboxRows(from: approvalsSnapshot)
    expect(inboxRows.map(\.tileId) == [tileB, tileA], "Approvals inbox rows filter needsAttention and preserve board order")
    expect(AgentsBoardProjection.attentionCount(from: approvalsSnapshot) == 2, "Approvals inbox attentionCount counts needsAttention rows")
    expect(
        AgentsBoardProjection.respondableRequest(in: approvalsSnapshot.byTile[tileA]!) == ApprovalResponseTarget(tileId: tileA, approvalRequestId: "approval-1"),
        "respondableRequest returns tileId and approvalRequestId when latest pending attention event has an id"
    )
    expect(
        AgentsBoardProjection.respondableRequest(in: approvalsSnapshot.byTile[tileB]!) == nil,
        "respondableRequest returns nil for legacy pending attention events without approvalRequestId"
    )
    expect(
        AgentsBoardProjection.respondableRequest(in: approvalsSnapshot.byTile[tileC]!) == nil,
        "respondableRequest returns nil for non-pending activity"
    )
    print("Approvals inbox measured attentionCount=\(AgentsBoardProjection.attentionCount(from: approvalsSnapshot)) rows=\(inboxRows.map(\.lastSummary).joined(separator: ",")) respondable=\(AgentsBoardProjection.respondableRequest(in: approvalsSnapshot.byTile[tileA]!)?.approvalRequestId ?? "nil")")

    let encodedApproval = try! JSONEncoder().encode(approvalWithId)
    let decodedApproval = try! JSONDecoder().decode(AgentActivityEvent.self, from: encodedApproval)
    expect(decodedApproval == approvalWithId, "AgentActivityEvent approvalRequestId round-trips when present")
    let legacyJSON = """
    {"sequence":13,"replicaId":"61000000-0000-4000-8000-000000000061","tileId":"61000000-0000-4000-8000-00000000000A","tone":"approval","kind":"needs-attention","status":"needsAttention","summary":"legacy","occurredAtReferenceInterval":6113}
    """
    let legacyEvent = try! JSONDecoder().decode(AgentActivityEvent.self, from: Data(legacyJSON.utf8))
    expect(legacyEvent.approvalRequestId == nil, "AgentActivityEvent legacy JSON without approvalRequestId decodes nil")
    print("AgentActivityEvent approvalRequestId codable measured present=\(decodedApproval.approvalRequestId ?? "nil") legacy=\(legacyEvent.approvalRequestId == nil)")
}
