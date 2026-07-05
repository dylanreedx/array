import Foundation

// Ticket: docs/38-tickets/08-sync-observation-type-split.md
//
// The observation-side sibling of SpatialOp (Sources/ContinuumRevivedCore/SpatialOp.swift).
// AgentActivityEvent carries what an agent did, derived status, and nothing that binds it
// to a host process — it is structurally incapable of holding a pid, a pane target, a
// runtime handle, or a transcript body (I5, locked-decisions D3).

// Tone mirrors t3code's OrchestrationThreadActivity.tone
// (04-orchestration-sessions-projections.md §2.2, contracts/orchestration.ts:305).
// Four values, closed — adding a tone is a deliberate, reviewed decision.
public enum ActivityEventTone: String, Codable, Sendable {
    case info       // status update, navigation event
    case tool       // bash, file-write, read — something the agent *did*
    case approval   // a pending or resolved approval request
    case error      // failure, timeout, unexpected exit
}

// The DRAFT — what a caller (SessionObserver) hands to ActivityStore.append.
// It has EVERY field of AgentActivityEvent EXCEPT sequence and replicaId.
// The store stamps those two. This is the one concrete mechanism for
// sequence assignment — no builder, no memberwise-copy-of-a-let ambiguity.
public struct AgentActivityEventDraft: Sendable {
    public let tileId: UUID
    public let runId: String?
    public let tone: ActivityEventTone
    public let kind: String
    public let status: AgentStatus
    public let summary: String
    public let occurredAt: Date
    public let approvalRequestId: String?

    public init(tileId: UUID, runId: String?, tone: ActivityEventTone,
                kind: String, status: AgentStatus, summary: String, occurredAt: Date,
                approvalRequestId: String? = nil) {
        self.tileId = tileId; self.runId = runId; self.tone = tone
        self.kind = kind; self.status = status; self.summary = summary
        self.occurredAt = occurredAt
        self.approvalRequestId = approvalRequestId
    }
}

public struct AgentActivityEvent: Codable, Equatable, Sendable {
    // (sequence, replicaId) is the global order key — Lamport discipline, no wall clock.
    // Assigned by ActivityStore.append from a draft; callers never set them.
    public let sequence: UInt64
    public let replicaId: UUID          // the host that generated this event
    public let tileId: UUID             // aggregate key — matches Tile.id in CanvasState
    public let runId: String?           // opaque link to the agent's own store (Pi/Claude), if known
    public let tone: ActivityEventTone
    public let kind: String             // "turn.started", "tool.bash", "needs-attention", "exit.clean", …
    public let status: AgentStatus      // the DERIVED status — from TerminalSessionDescriptor.swift:85
    public let summary: String          // short human label — NEVER a transcript body; I5 enforced here
    public let occurredAt: Date         // wall-clock only for display; ordering uses sequence
    public let approvalRequestId: String? // opaque adapter request id, present only for pending approvals

    // Stamp a draft into a full event. The store owns sequence + replicaId.
    public init(stamping draft: AgentActivityEventDraft, sequence: UInt64, replicaId: UUID) {
        self.sequence = sequence
        self.replicaId = replicaId
        self.tileId = draft.tileId
        self.runId = draft.runId
        self.tone = draft.tone
        self.kind = draft.kind
        self.status = draft.status
        self.summary = draft.summary
        self.occurredAt = draft.occurredAt
        self.approvalRequestId = draft.approvalRequestId
    }

    // Fields that MUST NOT appear here (I5 — sync-boundary purity, locked-decisions D3):
    // pid, pane_id / tmuxWindowTarget, pty file descriptor, scrollback bytes,
    // raw transcript content, host-local file path to an agent session.
    // If you are tempted to add one, it belongs in ManagedAgentSessionRecord instead.

    // Custom Codable: `occurredAt` is encoded as Date's own native storage value —
    // `timeIntervalSinceReferenceDate` — as a raw Double, NOT as a Date routed through
    // the encoder's dateEncodingStrategy and NOT as `timeIntervalSince1970`.
    // Two independent reasons, both load-bearing:
    //  1. JSONCodec.makeEncoder sets .iso8601 with no fractional-second component
    //     (JSONCodec.swift), which would truncate real Date() sub-second precision.
    //  2. `timeIntervalSince1970` is itself lossy on round-trip: it is computed as
    //     `timeIntervalSinceReferenceDate + 978307200`, and reconstructing a Date via
    //     `Date(timeIntervalSince1970:)` re-subtracts that same constant — floating-point
    //     rounding in that add-then-subtract round-trip does NOT always invert exactly
    //     (empirically ~49% of `Date()` values fail `Date(timeIntervalSince1970: d.timeIntervalSince1970) == d`).
    //     `timeIntervalSinceReferenceDate` is Date's actual internal storage, so
    //     round-tripping through it involves no arithmetic conversion and is always exact.
    private enum CodingKeys: String, CodingKey {
        case sequence, replicaId, tileId, runId, tone, kind, status, summary, occurredAtReferenceInterval, approvalRequestId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sequence = try container.decode(UInt64.self, forKey: .sequence)
        replicaId = try container.decode(UUID.self, forKey: .replicaId)
        tileId = try container.decode(UUID.self, forKey: .tileId)
        runId = try container.decodeIfPresent(String.self, forKey: .runId)
        tone = try container.decode(ActivityEventTone.self, forKey: .tone)
        kind = try container.decode(String.self, forKey: .kind)
        status = try container.decode(AgentStatus.self, forKey: .status)
        summary = try container.decode(String.self, forKey: .summary)
        let referenceInterval = try container.decode(Double.self, forKey: .occurredAtReferenceInterval)
        occurredAt = Date(timeIntervalSinceReferenceDate: referenceInterval)
        approvalRequestId = try container.decodeIfPresent(String.self, forKey: .approvalRequestId)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(replicaId, forKey: .replicaId)
        try container.encode(tileId, forKey: .tileId)
        try container.encodeIfPresent(runId, forKey: .runId)
        try container.encode(tone, forKey: .tone)
        try container.encode(kind, forKey: .kind)
        try container.encode(status, forKey: .status)
        try container.encode(summary, forKey: .summary)
        try container.encode(occurredAt.timeIntervalSinceReferenceDate, forKey: .occurredAtReferenceInterval)
        try container.encodeIfPresent(approvalRequestId, forKey: .approvalRequestId)
    }
}

// The materialized read model — a cache, never the source of truth.
// Rebuilt from the event log via apply(); snapshot equality is the I4 analogue for activity.
// Renamed from `ActivityTreeSnapshot` (its name when ticket 08 shipped) to
// `ActivityLogSnapshot` by ticket 11 (docs/38-tickets/11-activity-tree-snapshot.md),
// which reserves the name `ActivityTreeSnapshot` for its own SidebarTree-wrapping
// envelope. Both types cannot share the name `ActivityTreeSnapshot` in the same
// module — this fold-derived, per-tile activity cache is the one that yields.
public struct ActivityLogSnapshot: Codable, Equatable, Sendable {
    public var snapshotSequence: UInt64     // sequence of the last event folded in
    public var snapshotReplicaId: UUID      // replicaId of that event
    public var byTile: [UUID: TileActivity] // keyed by Tile.id

    public init(snapshotSequence: UInt64, snapshotReplicaId: UUID, byTile: [UUID: TileActivity]) {
        self.snapshotSequence = snapshotSequence
        self.snapshotReplicaId = snapshotReplicaId
        self.byTile = byTile
    }

    public static let empty = ActivityLogSnapshot(
        snapshotSequence: 0,
        snapshotReplicaId: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
        byTile: [:]
    )
}

public struct TileActivity: Codable, Equatable, Sendable {
    public var status: AgentStatus
    public var lastSummary: String
    public var recent: [AgentActivityEvent]   // capped ring; keep last 200 events per tile
    public var updatedAt: Date

    public init(status: AgentStatus, lastSummary: String, recent: [AgentActivityEvent], updatedAt: Date) {
        self.status = status
        self.lastSummary = lastSummary
        self.recent = recent
        self.updatedAt = updatedAt
    }
}

// THE pure fold — free function, not a method, so tests call it directly.
// This exact function is used in ActivityStore.append AND in the init replay. Never diverge.
//
// The fold is a COMMUTATIVE merge keyed on the canonical (sequence, replicaId) total
// order — the same key flush(to:)/loadActivityEvents sort by ("Watch out for": cross-
// device ordering uses (sequence, replicaId) as the total-order key). Folding the same
// set of events in ANY arrival order — live tail-apply as they occur locally, versus a
// sorted disk replay — must converge to the identical ActivityLogSnapshot. A fold that
// simply overwrote with "whichever event was just handed to it" would NOT have this
// property: seed a store with a foreign event at a high sequence (via `existing:`),
// then live-append a local event that gets a low local sequence (this host's own
// counter starts independently) — a blind overwrite would tail-clobber the live
// snapshot with the lower-sequence event, while a sorted disk reload folds the
// higher-sequence foreign event last and wins. That live-vs-replay divergence is
// exactly what this fold must not allow. So every derived field — snapshotSequence /
// snapshotReplicaId, and each tile's status / lastSummary / updatedAt — is read off a
// MAX over canonical order, never off "whichever event arrived most recently".
public func apply(_ tree: ActivityLogSnapshot, _ event: AgentActivityEvent) -> ActivityLogSnapshot {
    var next = tree

    if (event.sequence, event.replicaId.uuidString) > (next.snapshotSequence, next.snapshotReplicaId.uuidString) {
        next.snapshotSequence = event.sequence
        next.snapshotReplicaId = event.replicaId
    }

    var tile = next.byTile[event.tileId] ?? TileActivity(
        status: .idle, lastSummary: "", recent: [], updatedAt: event.occurredAt
    )

    // Insert in canonical order (not arrival order), then cap at 200 by dropping the
    // canonically-OLDEST survivors (not whichever arrived first). Deriving status /
    // lastSummary / updatedAt from the canonically-last element below is what makes
    // this fold order-independent: inserting the same set of events into a sorted
    // array in any order yields the same final array, hence the same last element.
    let insertIndex = tile.recent.firstIndex {
        (event.sequence, event.replicaId.uuidString) < ($0.sequence, $0.replicaId.uuidString)
    } ?? tile.recent.count
    tile.recent.insert(event, at: insertIndex)
    if tile.recent.count > 200 {
        tile.recent.removeFirst(tile.recent.count - 200)
    }

    if let winner = tile.recent.last {
        tile.status = winner.status
        tile.lastSummary = winner.summary
        tile.updatedAt = winner.occurredAt
    }
    next.byTile[event.tileId] = tile
    return next
}

// Stream item: exactly the two cases a subscriber can receive.
// snapshot always arrives first; events tail from there.
public enum ActivityStreamItem: Codable, Equatable, Sendable {
    case snapshot(ActivityLogSnapshot)
    case event(AgentActivityEvent)
}

// The on-disk envelope. The whole ordered log is one JSON document written via
// AtomicWriter.write — matching ProjectStore's single-document pattern. NOT NDJSON:
// AtomicWriter has no append API (AtomicWriter.swift:26 is its only writer).
public struct ActivityLogFile: Codable, Sendable {
    // Gated on load by loadActivityEvents, mirroring ProjectStore.checkSchema
    // (ProjectStore.swift:316) — a file with schemaVersion > currentSchemaVersion
    // throws rather than silently accepting an unknown future format.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    // Ordered by (sequence, replicaId) on flush — the same total-order key the
    // "Watch out for" section names for cross-device ordering (Lamport discipline,
    // D3): primary sort by the logical sequence, tie-break by replicaId.
    public var events: [AgentActivityEvent]
    public init(schemaVersion: Int = ActivityLogFile.currentSchemaVersion, events: [AgentActivityEvent]) {
        self.schemaVersion = schemaVersion
        self.events = events
    }
}
