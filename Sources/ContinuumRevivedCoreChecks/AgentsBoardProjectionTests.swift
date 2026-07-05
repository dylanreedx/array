import ContinuumRevivedCore
import Foundation

private let agentsBoardReplica = UUID(uuidString: "61000000-0000-4000-8000-000000000061")!

private func boardEvent(
    tileId: UUID,
    sequence: UInt64,
    status: AgentStatus,
    summary: String,
    occurredAt: Date,
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
            occurredAt: occurredAt
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

    let expectedPresentation: [(AgentStatus, String, String)] = [
        (.working, "●", "blue"),
        (.needsAttention, "◆", "orange"),
        (.done, "✓", "green"),
        (.stale, "◌", "gray"),
        (.configuring, "◍", "teal"),
        (.idle, "○", "tertiaryLabel"),
    ]
    for (status, glyph, token) in expectedPresentation {
        let presentation = AgentsBoardProjection.presentation(for: status)
        expect(presentation.glyph == glyph, "AgentsBoardProjection presentation glyph for \(status.rawValue)")
        expect(presentation.colorToken == token, "AgentsBoardProjection presentation color token for \(status.rawValue)")
    }
    print("AgentsBoardProjection presentation measured=\(expectedPresentation.map { "\($0.0.rawValue):\($0.1):\($0.2)" }.joined(separator: ","))")
}
