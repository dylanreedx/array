# Sync/observation type split: SpatialOp vs ActivityEvent

## What this delivers

After this ticket lands, the codebase has two distinct, structurally incompatible types for the two kinds of state that flow through the distributed canvas. `SpatialOp` is the unit of bidirectional sync — it carries only canvas geometry and membership deltas, and it is physically incapable of holding a pid, a pane target, a runtime handle, or a transcript body. `AgentActivityEvent` is the unit of one-way observation — it carries what an agent did, at what time, with what derived status, and nothing that binds it to a specific host process. An `ActivityStore` actor appends events, folds them into a materialized `ActivityTreeSnapshot` with a pure function, and delivers the snapshot-then-tail stream to observers.

The system outcome is invariant I5 becoming a compile-time guarantee rather than a convention: the synced spatial layer and the projected activity layer cannot accidentally exchange payloads because their types do not overlap. A device that receives a `SpatialOp` literally cannot find a pane target in it. A device that receives an `AgentActivityEvent` literally cannot find a tmux window handle in it. This is the boundary that makes iOS observer-only safe by construction (D5), and it is the boundary that makes the convergence fuzz meaningful (you can fuzz the spatial layer without worrying that activity state has leaked in).

## How it fits

This ticket builds directly on the op enum and the store-protocol seam. The op enum defines `SpatialOp` as the closed vocabulary of spatial state changes — move, resize, membership-set, z-order-set, tombstone — and this ticket imports that vocabulary as the type whose payload domain is provably host-handle-free. The store-protocol seam put the project and workspace stores behind a protocol; this ticket introduces `ActivityStore` as the sibling protocol for the observation side, giving the sync transport seam (which comes later) two clean topics to carry rather than one undifferentiated stream (locked-decisions D3, open-question 7 in `04-orchestration-sessions-projections.md`).

What this ticket unblocks is substantial. The taint-scan ticket that follows immediately depends on the type boundary existing so it can assert at compile time that no synced or projected payload carries forbidden fields. The activity tree snapshot ticket that follows depends on `ActivityTreeSnapshot` being defined here as a `Codable, Equatable, Sendable` struct so it can be serialized at every seam (D26 requires it as a phase-0 snapshot). The session observer (phase 3) depends on `ActivityStore.append(_:)` being the write API it calls after deriving a status from a reader. The iOS projection (phase 6) depends on `ActivityStore.subscribe()` delivering the snapshot-then-tail stream the phone consumes.

This ticket does not wire any of those consumers. It defines the types and the store, proves the pure fold correct, proves the persistence round-trip exact, and stops. Wiring happens in the tickets that name this one as a dependency.

## The approach

Two new files in `Sources/ContinuumRevivedCore/`. One defines `AgentActivityEvent`, its draft input `AgentActivityEventDraft`, and `ActivityTreeSnapshot` with their pure fold. The other defines the `ActivityStore` actor that wraps an in-memory log, maintains the materialized snapshot, and fans out to observers via `AsyncStream`.

**Persistence is a single JSON-document log through the existing `AtomicWriter`, not NDJSON.** This is a deliberate resolution of open-question 1 in `04-orchestration-sessions-projections.md` (which floated NDJSON-vs-SQLite). The existing `AtomicWriter` exposes exactly one write method — `write<T: Codable>(_ value: T, to url: URL)` (`AtomicWriter.swift:26`) — a whole-value JSON encoder with backup + fsync + round-trip validation, and **no append or line-oriented API**. `ProjectStore` uses it to write whole `.json` documents (`ProjectStore.swift:78,92`). To stay in-grain with that seam and add zero new writer code, the activity log is flushed as **one JSON document** — an `ActivityLogFile` envelope wrapping the ordered event array — via that same `AtomicWriter.write`. On load, `AtomicWriter.read` decodes the envelope back and the events seed a fresh store. NDJSON (true append-per-event) is a future optimization that would live behind the same `flush(to:)`/load seam and require a new line-append writer; it is explicitly **not** built here, and no code below claims append semantics.

The `SpatialOp` type lives in the op enum ticket and is imported here only to establish the documented separation: the two types share no fields and no nesting. That relationship is captured by a compile-time-adjacent mirror check in the test target, not by Swift inheritance or protocol conformance — the types are simply distinct and the test asserts they cannot be accidentally confused at the API boundary.

The activity sequence is per-host, namespaced by a `replicaId: UUID`, reusing the same Lamport discipline as the spatial op-log (D3; open-question 2 in `04-orchestration-sessions-projections.md`). A `(sequence: UInt64, replicaId: UUID)` pair is globally unique across any number of devices without coordination. When an iOS observer reconnects after a gap it calls `replay(fromSequenceExclusive:replicaId:)` to catch up, exactly as a lagging op-log peer would.

The pure fold function `apply(_:_:)` is the load-bearing primitive. It is a free function (not a method) so the test target can call it directly without constructing an `ActivityStore`. It must be the same function used inside `ActivityStore.append` to advance the live snapshot and used in the store initializer's replay to rebuild the snapshot from a sequence of events — one pure fold, three uses, zero divergence.

## Where it lives

**New files to create:**

- `Sources/ContinuumRevivedCore/AgentActivityEvent.swift` — defines `AgentActivityEvent`, `AgentActivityEventDraft`, `ActivityEventTone`, `ActivityTreeSnapshot`, `TileActivity`, `ActivityStreamItem`, `ActivityLogFile`, and the pure `apply(_:_:)` fold
- `Sources/ContinuumRevivedCore/ActivityStore.swift` — defines the `ActivityStore` actor and the `ActivityStoreProtocol` protocol it satisfies

**Existing seams this ticket reads but does not modify:**

- `Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift:85` — `AgentStatus` enum (`configuring | working | idle | needsAttention | done | stale`) is the status vocabulary `AgentActivityEvent.status` uses directly; do not duplicate or alias it
- `Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift:99` — `AgentDescriptor.runId: String?` (the field is at line 99; the `AgentDescriptor` struct is declared at line 94) is the existing partial version of the resume cursor; `AgentActivityEvent.runId` follows the same optional-string shape
- `Sources/ContinuumRevivedCore/SidebarTree.swift:135` — `SidebarTreeBuilder.build(registry:documents:projectCanvases:agentStatusesByTileId:)` is the existing consumer of `[UUID: AgentStatus]` (the `agentStatusesByTileId:` parameter); the `ActivityTreeSnapshot.byTile` dictionary, projected to `[UUID: AgentStatus]`, produces exactly that argument, establishing the downstream wiring point without touching `SidebarTree.swift` yet. There is no `workspace:` parameter — the builder takes the registry + documents and derives workspaces itself
- `Sources/ContinuumRevivedCore/CanvasState.swift:39` — `Tile` is declared here; `Tile.id: UUID` (line 40) is the aggregate key; `AgentActivityEvent.tileId: UUID` keys off this same identity
- `Sources/ContinuumRevivedCore/AtomicWriter.swift:26` — `AtomicWriter.write<T: Codable>(_:to:)` (whole-value JSON, backup + fsync + round-trip validation) is the persistence primitive `ActivityStore.flush(to:)` calls, and `AtomicWriter.read<T: Codable>(at:)` (`:52`) is what the load path uses; call-pattern mirrors `ProjectStore` (`ProjectStore.swift:78,92`). Neither `AtomicWriter` nor this ticket appends — the whole log is written as one document per flush

**Test file to create:**

- `Tests/ContinuumRevivedCoreTests/ActivityStoreTests.swift`

## Implementation breadcrumbs

```swift
// AgentActivityEvent.swift

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

    public init(tileId: UUID, runId: String?, tone: ActivityEventTone,
                kind: String, status: AgentStatus, summary: String, occurredAt: Date) {
        self.tileId = tileId; self.runId = runId; self.tone = tone
        self.kind = kind; self.status = status; self.summary = summary
        self.occurredAt = occurredAt
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
    }

    // Fields that MUST NOT appear here (I5 — sync-boundary purity, locked-decisions D3):
    // pid, pane_id / tmuxWindowTarget, pty file descriptor, scrollback bytes,
    // raw transcript content, host-local file path to an agent session.
    // If you are tempted to add one, it belongs in ManagedAgentSessionRecord instead.
}

// The materialized read model — a cache, never the source of truth.
// Rebuilt from the event log via apply(); snapshot equality is the I4 analogue for activity.
public struct ActivityTreeSnapshot: Codable, Equatable, Sendable {
    public var snapshotSequence: UInt64     // sequence of the last event folded in
    public var snapshotReplicaId: UUID      // replicaId of that event
    public var byTile: [UUID: TileActivity] // keyed by Tile.id

    public static let empty = ActivityTreeSnapshot(
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
}

// THE pure fold — free function, not a method, so tests call it directly.
// This exact function is used in ActivityStore.append AND in the init replay. Never diverge.
public func apply(_ tree: ActivityTreeSnapshot, _ event: AgentActivityEvent) -> ActivityTreeSnapshot {
    var next = tree
    next.snapshotSequence = event.sequence
    next.snapshotReplicaId = event.replicaId
    var tile = next.byTile[event.tileId] ?? TileActivity(
        status: .idle, lastSummary: "", recent: [], updatedAt: event.occurredAt
    )
    tile.status = event.status
    tile.lastSummary = event.summary
    tile.recent = Array((tile.recent + [event]).suffix(200))
    tile.updatedAt = event.occurredAt
    next.byTile[event.tileId] = tile
    return next
}

// Stream item: exactly the two cases a subscriber can receive.
// snapshot always arrives first; events tail from there.
public enum ActivityStreamItem: Sendable {
    case snapshot(ActivityTreeSnapshot)
    case event(AgentActivityEvent)
}

// The on-disk envelope. The whole ordered log is one JSON document written via
// AtomicWriter.write — matching ProjectStore's single-document pattern. NOT NDJSON:
// AtomicWriter has no append API (AtomicWriter.swift:26 is its only writer).
public struct ActivityLogFile: Codable, Sendable {
    public var schemaVersion: Int          // start at 1; gate on load like ProjectStore does
    public var events: [AgentActivityEvent] // ordered by (replicaId, sequence) on flush
    public init(schemaVersion: Int = 1, events: [AgentActivityEvent]) {
        self.schemaVersion = schemaVersion
        self.events = events
    }
}
```

```swift
// ActivityStore.swift

// Protocol first — the fake used by tests and the injectable substrate satisfy this.
public protocol ActivityStoreProtocol: Actor {
    func append(_ draft: AgentActivityEventDraft) async
    func subscribe() -> AsyncStream<ActivityStreamItem>
    func replay(fromSequenceExclusive sequence: UInt64, replicaId: UUID) -> [AgentActivityEvent]
    func currentSnapshot() async -> ActivityTreeSnapshot
    func flush(to url: URL) throws
}

public actor ActivityStore: ActivityStoreProtocol {
    // The in-memory log — the authoritative live copy. Flushed as ONE JSON document
    // (ActivityLogFile) via AtomicWriter.write on flush(to:). Disk is the recovery source.
    private var log: [AgentActivityEvent] = []
    private var snapshot: ActivityTreeSnapshot = .empty
    private var observers: [UUID: AsyncStream<ActivityStreamItem>.Continuation] = [:]
    private let replicaId: UUID  // injected at init; identifies this host in the global order
    private var nextSequence: UInt64 = 1
    private let writer: AtomicWriter

    public init(replicaId: UUID, existing: [AgentActivityEvent] = [], writer: AtomicWriter = AtomicWriter()) {
        self.replicaId = replicaId
        self.writer = writer
        // Replay any previously persisted events to rebuild the snapshot.
        // Events must arrive in sequence order; the loader (loadEvents) sorts them.
        // Only OUR replicaId's events advance nextSequence — foreign events (arriving
        // later via the transport) never dictate this host's next number.
        for event in existing {
            self.log.append(event)
            self.snapshot = apply(self.snapshot, event)
            if event.replicaId == replicaId {
                self.nextSequence = max(self.nextSequence, event.sequence + 1)
            }
        }
    }

    // The single write entry point. Takes a DRAFT, stamps sequence + replicaId,
    // folds into snapshot, fans out. Callers never construct a full AgentActivityEvent.
    public func append(_ draft: AgentActivityEventDraft) async {
        // Soft I5 tripwire: a long summary smells like a leaked transcript body (D7: ≤160
        // is the push soft-guard; 500 is the loud dev tripwire before a body lands in the log).
        precondition(draft.summary.count <= 500, "summary too long — transcript body leaked? (I5)")
        let event = AgentActivityEvent(stamping: draft, sequence: nextSequence, replicaId: replicaId)
        log.append(event)
        snapshot = apply(snapshot, event)   // THE pure fold — no inline duplicate
        nextSequence += 1
        for continuation in observers.values {
            continuation.yield(.event(event))
        }
    }

    // snapshot-then-tail — the exact pattern from t3code ws.ts:subscribeShell (:1062–1090).
    // The subscriber always sees a consistent snapshot before any live events.
    public func subscribe() -> AsyncStream<ActivityStreamItem> {
        let current = snapshot
        return AsyncStream { continuation in
            continuation.yield(.snapshot(current))
            let id = UUID()
            observers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(id) }
            }
        }
    }

    // Catch-up for a lagging observer — returns events strictly after the given cursor.
    // The iOS reconnect path calls this after receiving a snapshot with a newer sequence.
    public func replay(fromSequenceExclusive sequence: UInt64, replicaId: UUID) -> [AgentActivityEvent] {
        // Filter by replicaId: each device's event stream is independent.
        // Cross-device activity arrives via the sync transport, not this method.
        log.filter { $0.replicaId == replicaId && $0.sequence > sequence }
    }

    public func currentSnapshot() async -> ActivityTreeSnapshot { snapshot }

    // Persist the WHOLE log as one JSON document via AtomicWriter (backup + fsync +
    // round-trip validation come free). NOT append/NDJSON — AtomicWriter has no such API.
    public func flush(to url: URL) throws {
        let sorted = log.sorted {
            ($0.replicaId.uuidString, $0.sequence) < ($1.replicaId.uuidString, $1.sequence)
        }
        try writer.write(ActivityLogFile(events: sorted), to: url)
    }

    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
}

// Free loader — mirrors ProjectStore.loadProject: read the document, gate the schema,
// hand the events to ActivityStore(replicaId:existing:). Kept a free function so the
// store constructor stays pure (no I/O in init).
public func loadActivityEvents(from url: URL, writer: AtomicWriter = AtomicWriter()) throws -> [AgentActivityEvent] {
    let file: ActivityLogFile = try writer.read(at: url)
    // (schema gate elided — mirror ProjectStore.checkSchema when the file format evolves)
    return file.events
}
```

```swift
// ActivityStoreTests.swift — logic checks + one real-path flush/reload; no processes

// A tiny fixture helper — builds a DRAFT (never a stamped event; the store stamps).
func makeDraft(tileId: UUID, status: AgentStatus, kind: String,
               tone: ActivityEventTone = .info, summary: String = "ok",
               runId: String? = nil, at: Date = Date()) -> AgentActivityEventDraft {
    AgentActivityEventDraft(tileId: tileId, runId: runId, tone: tone,
                            kind: kind, status: status, summary: summary, occurredAt: at)
}
// For pure-fold tests that need a stamped event without a store:
func makeEvent(seq: UInt64, replicaId: UUID, tileId: UUID, status: AgentStatus,
               kind: String, at: Date = Date()) -> AgentActivityEvent {
    AgentActivityEvent(stamping: makeDraft(tileId: tileId, status: status, kind: kind, at: at),
                       sequence: seq, replicaId: replicaId)
}

// --- LOGIC: pure fold is associative over order (within one replicaId) ---
func testApplyFoldIsAssociative() {
    let rid = UUID(), tid = UUID()
    let e1 = makeEvent(seq: 1, replicaId: rid, tileId: tid, status: .working, kind: "turn.start")
    let e2 = makeEvent(seq: 2, replicaId: rid, tileId: tid, status: .needsAttention, kind: "approval")
    let e3 = makeEvent(seq: 3, replicaId: rid, tileId: tid, status: .done, kind: "exit.clean")

    let forward = [e1, e2, e3].reduce(ActivityTreeSnapshot.empty, apply)
    // Simulate a replay from checkpoint: start from snapshot after e1, replay e2+e3
    let fromCheckpoint = [e2, e3].reduce(apply(.empty, e1), apply)
    XCTAssertEqual(forward, fromCheckpoint)
}

// --- LOGIC: append stamps sequence + replicaId; caller supplies neither ---
func testAppendStampsSequenceAndReplica() async {
    let rid = UUID(), tid = UUID()
    let store = ActivityStore(replicaId: rid)
    await store.append(makeDraft(tileId: tid, status: .working, kind: "turn.start"))
    await store.append(makeDraft(tileId: tid, status: .done, kind: "exit.clean"))
    let replayed = await store.replay(fromSequenceExclusive: 0, replicaId: rid)
    XCTAssertEqual(replayed.map(\.sequence), [1, 2])
    XCTAssertTrue(replayed.allSatisfy { $0.replicaId == rid })
}

// --- LOGIC: subscribe delivers snapshot-then-events in the correct order ---
func testSubscribeDeliversSnapshotFirst() async {
    let store = ActivityStore(replicaId: UUID())
    let tid = UUID()
    await store.append(makeDraft(tileId: tid, status: .working, kind: "turn.start"))

    var items: [ActivityStreamItem] = []
    let stream = await store.subscribe()
    var iter = stream.makeAsyncIterator()
    // First item must be a snapshot
    if let first = await iter.next() { items.append(first) }
    guard case .snapshot(let snap) = items[0] else { XCTFail("expected snapshot first"); return }
    XCTAssertEqual(snap.byTile[tid]?.status, .working)
    // Second item must be the next appended event
    await store.append(makeDraft(tileId: tid, status: .done, kind: "exit.clean"))
    if let second = await iter.next() { items.append(second) }
    guard case .event(let ev) = items[1] else { XCTFail("expected event"); return }
    XCTAssertEqual(ev.status, .done)
}

// --- LOGIC: I5 taint check — AgentActivityEvent fields enumerated, none are forbidden ---
func testActivityEventHasNoForbiddenFields() {
    let mirror = Mirror(reflecting: makeEvent(seq: 1, replicaId: UUID(), tileId: UUID(),
                                              status: .idle, kind: "turn.start"))
    let forbidden: Set<String> = ["pid", "paneId", "tmuxWindowTarget", "ptyFd",
                                   "scrollback", "transcriptBody", "sessionPath"]
    let actual = Set(mirror.children.compactMap { $0.label })
    XCTAssertTrue(actual.isDisjoint(with: forbidden),
                  "Forbidden fields found: \(actual.intersection(forbidden))")
}

// --- LOGIC: ring buffer caps at 200 events per tile ---
func testRecentEventsCapAt200() {
    let tid = UUID(), rid = UUID()
    let events = (1...250).map { i in makeEvent(seq: UInt64(i), replicaId: rid, tileId: tid,
                                                status: .working, kind: "tool.bash") }
    let snap = events.reduce(ActivityTreeSnapshot.empty, apply)
    XCTAssertEqual(snap.byTile[tid]?.recent.count, 200)
    // Verify it kept the LAST 200, not the first
    XCTAssertEqual(snap.byTile[tid]?.recent.first?.sequence, 51)
}

// --- LOGIC: replay returns only events after the cursor ---
func testReplayFromSequence() async {
    let rid = UUID(), tid = UUID(), store = ActivityStore(replicaId: rid)
    for _ in 1...5 { await store.append(makeDraft(tileId: tid, status: .working, kind: "tool.bash")) }
    let replayed = await store.replay(fromSequenceExclusive: 3, replicaId: rid)
    XCTAssertEqual(replayed.map(\.sequence), [4, 5])
}
```

## How we test it

### Logic — pure core checks

The test suite in `ActivityStoreTests.swift` exercises six properties without any I/O:

The **fold associativity check** builds the same final snapshot two ways: applying all three events in order from empty, versus applying event one to get a checkpoint and then replaying events two and three from it. `XCTAssertEqual` on the resulting `ActivityTreeSnapshot` (which is `Equatable`) proves the pure fold is a lawful fold — the same property the I4 convergence fuzz proves for spatial ops. This is the activity-layer analogue of that fuzz.

The **stamping check** appends two drafts to a fresh store and asserts the store assigned sequences `[1, 2]` and stamped its own `replicaId` on both — proving that `sequence`/`replicaId` are owned by `append` and never supplied by the caller (the caller hands an `AgentActivityEventDraft`, which has no such fields to set).

The **subscribe ordering check** creates a store, appends one draft, subscribes, and asserts that the first item from the stream is a `snapshot` case whose `byTile` reflects the pre-subscription state. It then appends a second draft and asserts the next stream item is an `event` case with the right status. This proves the snapshot-before-tail contract without any network or concurrency tricks — just `AsyncStream` and `async/await`.

The **I5 taint check** uses `Mirror` to enumerate all stored properties of `AgentActivityEvent` at runtime and asserts that none match the set of forbidden field names: `pid`, `paneId`, `tmuxWindowTarget`, `ptyFd`, `scrollback`, `transcriptBody`, `sessionPath`. This is the lightweight version of the taint scan that the full taint-scan ticket will harden; it catches accidental additions here first.

The **ring-buffer cap check** applies 250 events to the same tile and asserts that `recent.count == 200` and that the oldest surviving event has `sequence == 51` — proving it kept the last 200, not the first.

The **replay-from-sequence check** appends five drafts to a live store and calls `replay(fromSequenceExclusive: 3, replicaId:)`, asserting it returns exactly sequences 4 and 5.

All six checks are pure: no filesystem, no tmux daemon, no clock calls beyond what `Date()` provides.

### Backend — real-path integration

Two integration checks drive the real event path without faking the store:

**Flush and reload.** Create an `ActivityStore`, append a sequence of ten drafts across three tiles, call `flush(to:)` — which writes the whole log as one `ActivityLogFile` JSON document via `AtomicWriter.write` (`AtomicWriter.swift:26`) — then read it back with `loadActivityEvents(from:)` (`AtomicWriter.read`, `:52`) and construct a new `ActivityStore(replicaId:existing:)` from the decoded events. Assert that `currentSnapshot()` on the reloaded store equals `currentSnapshot()` on the original. This proves the persistence round-trip is exact — no fields are lost in JSON encoding, no ordering is disrupted (flush sorts by `(replicaId, sequence)`; the reloaded store re-folds in that order). It uses a real temporary directory, a real `AtomicWriter` (real `FileManager` write + fsync + backup), and real JSON encoding: no mocks. This is the one integration check the "Autonomous" execution mode depends on, and every method it names — `flush(to:)`, `loadActivityEvents(from:)`, `ActivityStore(replicaId:existing:)`, `currentSnapshot()` — is defined in the breadcrumbs above.

**Concurrent appends do not corrupt the snapshot.** Spawn ten `Task`s simultaneously, each appending drafts to the same `ActivityStore` with distinct `tileId`s. After all tasks complete, assert that `byTile.count == 10` and that each tile's `status` equals the last event appended for that tile. This exercises the `actor` isolation guarantee: no torn reads, no lost events, and no duplicated sequence numbers (the store serializes `nextSequence`). Use a `withTaskGroup` and await all tasks before asserting. This is a real concurrency check, not a synthetic serial replay.

### UX — visual gate and dogfood snippet

This ticket introduces no visible UI. `ActivityTreeSnapshot.byTile`, projected to `[UUID: AgentStatus]`, is the data that will feed `SidebarTreeBuilder.build(registry:documents:projectCanvases:agentStatusesByTileId:)` (`SidebarTree.swift:135`) via its `agentStatusesByTileId:` argument in the activity-surface ticket (D21) — but that wiring is that ticket's responsibility.

The visual gate here is a compilation gate: the project must build cleanly on `swift build` with zero warnings related to the new files. The taint-scan ticket that follows immediately will add an `#error` directive if the forbidden-field check fails at compile time, promoting the runtime mirror check above to a proper compile-time assertion. Until that ticket lands, the mirror check serves as the gate.

There is no dogfood snippet for this ticket because no user-visible behavior changes. The agent executing this ticket marks the UX gate as satisfied by the passing logic and backend checks combined with a clean build.

## Execution mode

**Autonomous.** Every correctness property this ticket introduces is proven by the pure logic checks and the flush-and-reload integration check, neither of which requires human eyes, a real device, or a real cloud account. The `ActivityStore` is a pure Swift actor depending only on the standard library and the existing `AtomicWriter`. The persistence path is a single-document JSON write through `AtomicWriter.write` — the exact call `ProjectStore` already makes — so it round-trips deterministically in a temp directory. The concurrency check requires a real `Task` scheduler but no external process. The fold associativity check is purely functional. There is no UI, no tmux, no iCloud, and no agent to observe. A matrix run on CI proves this ticket with zero human input required.

## Done when

- `swift build` succeeds with zero warnings on the new files.
- `swift test --filter ActivityStoreTests` passes all six logic checks and both integration checks.
- `AgentActivityEvent` has no properties named `pid`, `paneId`, `tmuxWindowTarget`, `ptyFd`, `scrollback`, `transcriptBody`, or `sessionPath` — verified by the mirror check passing.
- `apply(_:_:)` is a free function in `AgentActivityEvent.swift`, not a method on `ActivityStore` — enforced by the fold associativity test calling it directly with no store instance.
- `ActivityStore.append` takes an `AgentActivityEventDraft` and stamps `sequence` + `replicaId` itself — verified by the stamping test (caller supplies neither field).
- `ActivityStore` satisfies `ActivityStoreProtocol` (including `flush(to:)`) — verified by the compiler.
- `flush(to:)` writes one `ActivityLogFile` JSON document via `AtomicWriter.write`; `loadActivityEvents(from:)` reads it back via `AtomicWriter.read`. No append/NDJSON code exists.
- `ActivityStreamItem` has exactly two cases: `.snapshot(ActivityTreeSnapshot)` and `.event(AgentActivityEvent)` — no other cases.
- `ActivityTreeSnapshot` is `Codable`, `Equatable`, and `Sendable` — the compiler enforces this.
- The flush-and-reload integration check passes against a real temporary directory: reloaded `currentSnapshot()` equals the original.
- No existing source files are modified. This ticket is purely additive.

## Depends on / unblocks

This ticket depends on the op enum and logged-op envelope ticket, which defines `SpatialOp` and establishes the Lamport + replicaId clock discipline that `AgentActivityEvent.sequence` and `AgentActivityEvent.replicaId` mirror (D3). It also depends on the store-protocol seam ticket, which established the pattern of putting storage behind a protocol — `ActivityStoreProtocol` follows that same pattern for the observation side.

This ticket directly unblocks the taint-scan ticket, which needs the type boundary to exist in order to assert at compile time that neither the synced spatial payload nor the projected activity payload contains forbidden host-local fields. It unblocks the activity tree snapshot ticket, which depends on `ActivityTreeSnapshot` being defined here with its full `Codable, Equatable, Sendable` conformance (D26). It unblocks the injectable substrates ticket, which will add a fake `ActivityStore` satisfying `ActivityStoreProtocol` for use in observer tests. And it is the write API that the session observer (phase 3) calls: `ActivityStore.append(_:)` is the one seam the observer crosses to push a derived status into the activity layer — handing a draft, never a stamped event.

## Watch out for

**The pure fold must be the same function used everywhere.** The single most dangerous mistake in this ticket is allowing `ActivityStore.append` to fold the snapshot with inline logic that diverges from the free-function `apply`. If they ever differ, a replayed store (built via `init(replicaId:existing:)`) will produce a different snapshot than a live store given the same events — a silent correctness bug that the flush-and-reload integration check exists specifically to catch. The rule is simple: `ActivityStore.append` calls `apply(self.snapshot, event)` and nothing else; the init replay calls the same `apply`; neither duplicates the fold logic.

**The `summary` field is the I5 boundary in prose.** The type system prevents a `pid` from appearing as a `UInt64` field, but it cannot prevent a transcript body from being stuffed into `summary: String`. The 160-character limit from the push notification spec (D7) applies here as a soft guard: any `summary` longer than 160 characters is a smell that a transcript excerpt has leaked in. The session observer must extract metadata — event type, mode, last tool name — not message content. The `precondition(draft.summary.count <= 500)` in `append` is the loud runtime tripwire during development; it fires before a body makes it into the log.

**Persistence is whole-document, not append.** `AtomicWriter` has exactly one write method (`write<T: Codable>(_:to:)`, `AtomicWriter.swift:26`) and no line-append or NDJSON API. `flush(to:)` therefore serializes the *entire* log to one `ActivityLogFile` document every time — cheap at this scale, and it inherits `AtomicWriter`'s backup + fsync + round-trip-validate guarantees for free. Do not invent an append path or a second writer here; true NDJSON is a deferred optimization behind the same `flush(to:)` seam (open-question 1, `04-orchestration-sessions-projections.md`).

**`AsyncStream` continuation lifecycle needs care.** The `onTermination` handler in `subscribe()` captures `self` weakly and dispatches a `Task` to call the actor method. If the `ActivityStore` is deallocated before the task runs, the `weak self` resolves to nil and the observer entry leaks harmlessly — but if the store is long-lived (it is), the main risk is a subscriber that drops its stream without triggering `onTermination`. Test this explicitly with the concurrent-appends check by cancelling one of the ten tasks early and asserting the observer dictionary shrinks.

**Sequence numbering is per-host, not global.** A future implementer may be tempted to use a single global sequence across all devices, anticipating the sync transport. Do not (open-question 2, `04-orchestration-sessions-projections.md`; D3). The sequence is per-replicaId. Cross-device activity ordering uses `(sequence, replicaId)` as the total-order key, consistent with the Lamport discipline in the op-log. `init(replicaId:existing:)` only advances `nextSequence` from events matching *this* host's `replicaId`, so seeding a store with foreign events (which will arrive later via the transport) never corrupts local numbering. Introducing a global sequence now would require coordination that does not exist until the transport arrives, and it would make the local-only path dependent on a future seam. Keep it per-host.
