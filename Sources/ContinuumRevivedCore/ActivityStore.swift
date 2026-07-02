import Foundation

// Ticket: docs/38-tickets/08-sync-observation-type-split.md
//
// The observation-side sibling of the store-protocol seam (01-store-protocol-seam.md):
// ActivityStoreProtocol gives the sync transport a clean, host-handle-free topic to
// carry alongside SpatialOp.

// Mirrors ProjectStoreError.unknownFutureSchema (ProjectStore.swift:5) — the same
// fail-closed-on-unknown-future-schema policy applied to the activity log.
public enum ActivityStoreError: Error, Equatable {
    case unknownFutureSchema(path: String, version: Int, supported: Int)
}

// The single canonical total-order comparator for the activity log — (sequence, replicaId),
// primary sort by the Lamport-style logical sequence, tie-break by replicaId (D3, "Watch out
// for": cross-device ordering uses (sequence, replicaId) as the total-order key). Both
// flush(to:) and loadActivityEvents use this exact comparator so a multi-replica log folds
// into the identical snapshot whether it was just appended live or just reloaded from disk.
func activityEventOrder(_ lhs: AgentActivityEvent, _ rhs: AgentActivityEvent) -> Bool {
    (lhs.sequence, lhs.replicaId.uuidString) < (rhs.sequence, rhs.replicaId.uuidString)
}

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
        // `existing` must arrive in the (sequence, replicaId) total order — loadActivityEvents
        // sorts on load, and we sort again here defensively (existing is a public init
        // parameter; a caller building it by hand, e.g. from a foreign device's log, could
        // hand it over unsorted) so the fold is never applied out of causal order regardless
        // of caller. Only OUR replicaId's events advance nextSequence — foreign events
        // (arriving later via the transport) never dictate this host's next number.
        for event in existing.sorted(by: activityEventOrder) {
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
            .sorted { $0.sequence < $1.sequence }
    }

    public func currentSnapshot() async -> ActivityTreeSnapshot { snapshot }

    // Persist the WHOLE log as one JSON document via AtomicWriter (backup + fsync +
    // round-trip validation come free). NOT append/NDJSON — AtomicWriter has no such API.
    public func flush(to url: URL) throws {
        let sorted = log.sorted(by: activityEventOrder)
        try writer.write(ActivityLogFile(events: sorted), to: url)
    }

    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    // Test-only instrumentation: the number of live observers. Not part of
    // ActivityStoreProtocol — it exists so the AsyncStream continuation-lifecycle
    // invariant ("Watch out for" section) can be asserted from outside the actor
    // without exposing the `observers` dictionary itself.
    public func observerCount() -> Int { observers.count }
}

// Free loader — mirrors ProjectStore.loadProject: read the document, gate the schema,
// hand the events to ActivityStore(replicaId:existing:). Kept a free function so the
// store constructor stays pure (no I/O in init).
public func loadActivityEvents(from url: URL, writer: AtomicWriter = AtomicWriter()) throws -> [AgentActivityEvent] {
    let file: ActivityLogFile = try writer.read(at: url)
    // Mirrors ProjectStore.checkSchema (ProjectStore.swift:316): fail closed on an
    // unknown future schema rather than silently accepting a log format we don't understand.
    if file.schemaVersion > ActivityLogFile.currentSchemaVersion {
        throw ActivityStoreError.unknownFutureSchema(
            path: url.path,
            version: file.schemaVersion,
            supported: ActivityLogFile.currentSchemaVersion
        )
    }
    return file.events.sorted(by: activityEventOrder)
}
