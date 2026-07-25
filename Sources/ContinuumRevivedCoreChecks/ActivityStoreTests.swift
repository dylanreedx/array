import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

// Ticket: docs/38-tickets/08-sync-observation-type-split.md
//
// Logic + backend checks for AgentActivityEvent / ActivityLogSnapshot / ActivityStore.
// This project has no XCTest target — `run-matrix.sh` never runs `swift test` — so these
// checks live in the ContinuumRevivedCoreChecks executable, printing PASS/FAIL via `expect`
// (defined in main.swift) and exiting non-zero on failure, matching every other ticket's
// verification convention (see SpatialOpTests.swift for the sibling ticket 02 checks).

// A tiny fixture helper — builds a DRAFT (never a stamped event; the store stamps).
// P2A.8: these fixtures are tile-bound agents, so the agent key and the tile hint are
// the same value; every assertion below therefore addresses the same aggregate it did
// before the key moved.
private func makeDraft(tileId: UUID, status: AgentStatus, kind: String,
                        tone: ActivityEventTone = .info, summary: String = "ok",
                        runId: String? = nil, at: Date = Date()) -> AgentActivityEventDraft {
    AgentActivityEventDraft(agentId: tileId, tileId: tileId, runId: runId, tone: tone,
                             kind: kind, status: status, summary: summary, occurredAt: at)
}

// For pure-fold tests that need a stamped event without a store:
private func makeEvent(seq: UInt64, replicaId: UUID, tileId: UUID, status: AgentStatus,
                        kind: String, summary: String = "ok", at: Date = Date()) -> AgentActivityEvent {
    AgentActivityEvent(stamping: makeDraft(tileId: tileId, status: status, kind: kind,
                                            summary: summary, at: at),
                        sequence: seq, replicaId: replicaId)
}

func runActivityStoreTests() {
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        await runActivityStoreTestsAsync()
        semaphore.signal()
    }
    semaphore.wait()
}

private func runActivityStoreTestsAsync() async {
    // --- LOGIC: pure fold sets every ActivityLogSnapshot field to concrete, checkable values ---
    // (Not "forward == fromCheckpoint" splitting the same three apply calls two ways — that
    // holds trivially for any deterministic binary function and cannot catch a wrong fold.
    // Assert the actual field values a correct fold must produce instead.)
    do {
        let rid = UUID(), otherTid = UUID(), tid = UUID()
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let t2 = t1.addingTimeInterval(1)
        let t3 = t1.addingTimeInterval(2)
        let e0 = makeEvent(seq: 1, replicaId: rid, tileId: otherTid, status: .idle,
                            kind: "turn.start", summary: "other tile", at: t1)
        let e1 = makeEvent(seq: 2, replicaId: rid, tileId: tid, status: .working,
                            kind: "turn.start", summary: "starting", at: t1)
        let e2 = makeEvent(seq: 3, replicaId: rid, tileId: tid, status: .needsAttention,
                            kind: "approval", summary: "needs approval", at: t2)
        let e3 = makeEvent(seq: 4, replicaId: rid, tileId: tid, status: .done,
                            kind: "exit.clean", summary: "done", at: t3)

        let snapshot = [e0, e1, e2, e3].reduce(ActivityLogSnapshot.empty, apply)

        expect(snapshot.snapshotSequence == 4, "apply fold: snapshotSequence tracks the last folded event")
        expect(snapshot.snapshotReplicaId == rid, "apply fold: snapshotReplicaId tracks the last folded event")
        expect(snapshot.byAgent.count == 2, "apply fold: byAgent has one entry per distinct agentId touched")
        let tile = snapshot.byAgent[tid]
        expect(tile?.status == .done, "apply fold: byAgent status is the LAST applied event's status, not the first")
        expect(tile?.lastSummary == "done", "apply fold: lastSummary is the last applied event's summary")
        expect(tile?.updatedAt == t3, "apply fold: updatedAt is the last applied event's occurredAt")
        expect(tile?.recent.map(\.sequence) == [2, 3, 4], "apply fold: recent preserves full application order for this tile only")
        expect(snapshot.byAgent[otherTid]?.status == .idle, "apply fold: a different tile's state is untouched by events for tid")
    }

    // --- LOGIC: init-replay fold converges to the same snapshot as live append fold ---
    // This is the falsifiable version of the old associativity check: it exercises the two
    // real call sites named in the ticket's "Watch out for" section (ActivityStore.append's
    // live fold and ActivityStore.init's replay fold) and would fail if either ever diverged
    // from the shared `apply` function.
    do {
        let rid = UUID(), tid = UUID()
        let store = ActivityStore(replicaId: rid)
        await store.append(makeDraft(tileId: tid, status: .working, kind: "turn.start", summary: "go"))
        await store.append(makeDraft(tileId: tid, status: .needsAttention, kind: "approval", summary: "wait"))
        await store.append(makeDraft(tileId: tid, status: .done, kind: "exit.clean", summary: "done"))
        let liveSnapshot = await store.currentSnapshot()

        let replayed = await store.replay(fromSequenceExclusive: 0, replicaId: rid)
        let rebuilt = ActivityStore(replicaId: rid, existing: replayed)
        let rebuiltSnapshot = await rebuilt.currentSnapshot()
        expect(rebuiltSnapshot == liveSnapshot,
               "init(replicaId:existing:) replay fold converges to the same snapshot as the live append fold")
    }

    // --- LOGIC: append stamps sequence + replicaId; caller supplies neither ---
    do {
        let rid = UUID(), tid = UUID()
        let store = ActivityStore(replicaId: rid)
        await store.append(makeDraft(tileId: tid, status: .working, kind: "turn.start"))
        await store.append(makeDraft(tileId: tid, status: .done, kind: "exit.clean"))
        let replayed = await store.replay(fromSequenceExclusive: 0, replicaId: rid)
        expect(replayed.map(\.sequence) == [1, 2], "append stamps sequences 1, 2 in order")
        expect(replayed.allSatisfy { $0.replicaId == rid }, "append stamps this store's replicaId on every event")
    }

    // --- LOGIC: subscribe delivers snapshot-then-events in the correct order ---
    do {
        let store = ActivityStore(replicaId: UUID())
        let tid = UUID()
        await store.append(makeDraft(tileId: tid, status: .working, kind: "turn.start"))

        let stream = await store.subscribe()
        var iter = stream.makeAsyncIterator()
        let first = await iter.next()
        if case .snapshot(let snap) = first {
            expect(snap.byAgent[tid]?.status == .working, "subscribe: pre-subscription snapshot reflects prior appends")
        } else {
            expect(false, "subscribe: expected a snapshot as the first stream item")
        }

        await store.append(makeDraft(tileId: tid, status: .done, kind: "exit.clean"))
        let second = await iter.next()
        if case .event(let ev) = second {
            expect(ev.status == .done, "subscribe: tail event after the snapshot carries the newly appended status")
        } else {
            expect(false, "subscribe: expected an event as the second stream item")
        }
    }

    // --- LOGIC: I5 taint check — AgentActivityEvent fields enumerated, none are forbidden ---
    do {
        let mirror = Mirror(reflecting: makeEvent(seq: 1, replicaId: UUID(), tileId: UUID(),
                                                   status: .idle, kind: "turn.start"))
        let forbidden: Set<String> = ["pid", "paneId", "tmuxWindowTarget", "ptyFd",
                                       "scrollback", "transcriptBody", "sessionPath"]
        let actual = Set(mirror.children.compactMap { $0.label })
        expect(actual.isDisjoint(with: forbidden),
               "I5 taint check: AgentActivityEvent must not carry forbidden fields, found: \(actual.intersection(forbidden))")
    }

    // --- LOGIC: ring buffer caps at 200 events per tile ---
    do {
        let tid = UUID(), rid = UUID()
        let events = (1...250).map { i in makeEvent(seq: UInt64(i), replicaId: rid, tileId: tid,
                                                     status: .working, kind: "tool.bash") }
        let snap = events.reduce(ActivityLogSnapshot.empty, apply)
        expect(snap.byAgent[tid]?.recent.count == 200, "ring buffer caps recent events at 200")
        // Verify it kept the LAST 200, not the first
        expect(snap.byAgent[tid]?.recent.first?.sequence == 51, "ring buffer keeps the last 200 events, not the first")
    }

    // --- LOGIC: replay returns only events after the cursor ---
    do {
        let rid = UUID(), tid = UUID(), store = ActivityStore(replicaId: rid)
        for _ in 1...5 { await store.append(makeDraft(tileId: tid, status: .working, kind: "tool.bash")) }
        let replayed = await store.replay(fromSequenceExclusive: 3, replicaId: rid)
        expect(replayed.map(\.sequence) == [4, 5], "replay(fromSequenceExclusive:) returns only events strictly after the cursor")
    }

    // --- BACKEND: flush and reload round-trips exactly through the real AtomicWriter ---
    do {
        let rid = UUID()
        let tileIds = [UUID(), UUID(), UUID()]
        let store = ActivityStore(replicaId: rid)
        // AgentActivityEvent encodes occurredAt as Date's native timeIntervalSinceReferenceDate
        // (Double), not as a Date routed through the encoder's dateEncodingStrategy and not
        // via timeIntervalSince1970 (which is itself lossy on round-trip) — so a real Date()
        // with full sub-second precision round-trips exactly. No truncation needed.
        for i in 0..<10 {
            let tid = tileIds[i % tileIds.count]
            await store.append(makeDraft(tileId: tid, status: i % 2 == 0 ? .working : .done,
                                          kind: "tool.bash.\(i)", at: Date()))
        }
        let originalSnapshot = await store.currentSnapshot()

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("activity-store-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appendingPathComponent("activity-log.json")

        do {
            try await store.flush(to: fileURL)
            let reloadedEvents = try loadActivityEvents(from: fileURL)
            let reloadedStore = ActivityStore(replicaId: rid, existing: reloadedEvents)
            let reloadedSnapshot = await reloadedStore.currentSnapshot()
            expect(reloadedSnapshot == originalSnapshot,
                   "flush-and-reload: reloaded currentSnapshot() equals the original store's snapshot")
        } catch {
            expect(false, "flush-and-reload: unexpected error \(error)")
        }
    }

    // --- BACKEND: flush and reload is exact for a multi-replica log ---
    // The ticket's total-order key for cross-device ordering is (sequence, replicaId)
    // ("Watch out for" section). Seed a store via `existing:` with two replicas'
    // events handed in an order that matches NEITHER (replicaId, sequence) NOR
    // (sequence, replicaId) — the store itself, not the caller, must impose the
    // canonical order — then prove flush -> loadActivityEvents -> reload converges
    // to the exact same snapshot as the originally-constructed store.
    do {
        let replicaA = UUID(), replicaB = UUID(), tid = UUID()
        let eventsFromTwoReplicas = [
            makeEvent(seq: 2, replicaId: replicaA, tileId: tid, status: .working, kind: "a.2", summary: "a-2"),
            makeEvent(seq: 1, replicaId: replicaB, tileId: tid, status: .idle, kind: "b.1", summary: "b-1"),
            makeEvent(seq: 1, replicaId: replicaA, tileId: tid, status: .configuring, kind: "a.1", summary: "a-1"),
            makeEvent(seq: 2, replicaId: replicaB, tileId: tid, status: .done, kind: "b.2", summary: "b-2"),
        ]
        let store = ActivityStore(replicaId: replicaA, existing: eventsFromTwoReplicas)
        let originalSnapshot = await store.currentSnapshot()
        // Both remaining candidates share sequence==2; the tie-break is replicaId
        // (activityEventOrder / apply's canonical order), so the winner is deterministic
        // — compute it the same way the fold does rather than accepting either value.
        let expectedWinner: AgentStatus = replicaA.uuidString > replicaB.uuidString ? .working : .done
        expect(originalSnapshot.byAgent[tid]?.status == expectedWinner,
               "multi-replica fold: the (sequence, replicaId) tie-break determines a single deterministic winner, independent of `existing:` array order")

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("activity-store-multireplica-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appendingPathComponent("activity-log.json")

        do {
            try await store.flush(to: fileURL)
            let reloadedEvents = try loadActivityEvents(from: fileURL)
            let reloadedStore = ActivityStore(replicaId: replicaA, existing: reloadedEvents)
            let reloadedSnapshot = await reloadedStore.currentSnapshot()
            expect(reloadedSnapshot == originalSnapshot,
                   "multi-replica flush-and-reload round-trips exactly across two replicas")
        } catch {
            expect(false, "multi-replica flush-and-reload: unexpected error \(error)")
        }
    }

    // --- BACKEND: a live local append after seeding with a higher-sequence foreign
    // event does not tail-clobber the live snapshot, and the live snapshot agrees with
    // a sorted disk reload of the same events. This is the exact failure mode named in
    // apply()'s doc comment: seed this host's store with a foreign replica's event at a
    // high sequence, then append a LOCAL draft — which this host stamps with its own
    // low sequence (this host's counter is independent of the foreign replica's) — and
    // assert the LIVE currentSnapshot() (no flush/reload involved) still reflects the
    // higher-sequence foreign event, because canonical order — not append/arrival
    // order — decides the winner. Then flush + reload and assert it matches exactly.
    do {
        let localReplica = UUID(), foreignReplica = UUID(), tid = UUID()
        let foreignEvent = makeEvent(seq: 100, replicaId: foreignReplica, tileId: tid,
                                      status: .done, kind: "exit.clean", summary: "foreign-done")
        let store = ActivityStore(replicaId: localReplica, existing: [foreignEvent])

        // This append is stamped with THIS host's own sequence (starts at 1), which is
        // far below the foreign event's sequence 100 — but chronologically it happens
        // "now", after the seed. A tail-clobbering fold would let it win live.
        await store.append(makeDraft(tileId: tid, status: .working, kind: "turn.start", summary: "local-working"))

        let liveSnapshot = await store.currentSnapshot()
        expect(liveSnapshot.byAgent[tid]?.status == .done,
               "live append after seeding with a higher-sequence foreign event must NOT tail-clobber the live snapshot: canonical order still picks the foreign event")
        expect(liveSnapshot.snapshotSequence == 100 && liveSnapshot.snapshotReplicaId == foreignReplica,
               "live snapshot watermark tracks the canonically-highest event seen, not the most-recently-applied one")

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("activity-store-live-vs-replay-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appendingPathComponent("activity-log.json")

        do {
            try await store.flush(to: fileURL)
            let reloadedEvents = try loadActivityEvents(from: fileURL)
            let reloadedStore = ActivityStore(replicaId: localReplica, existing: reloadedEvents)
            let reloadedSnapshot = await reloadedStore.currentSnapshot()
            expect(reloadedSnapshot == liveSnapshot,
                   "live-vs-replay convergence: a sorted disk reload after flush must equal the live snapshot exactly, including the foreign event's status winning")
        } catch {
            expect(false, "live-vs-replay flush-and-reload: unexpected error \(error)")
        }
    }

    // --- BACKEND: loadActivityEvents gates on schemaVersion like ProjectStore.checkSchema ---
    do {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("activity-store-schema-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appendingPathComponent("activity-log.json")
        let writer = AtomicWriter()
        let futureVersion = ActivityLogFile.currentSchemaVersion + 1
        do {
            try writer.write(ActivityLogFile(schemaVersion: futureVersion, events: []), to: fileURL)
            _ = try loadActivityEvents(from: fileURL, writer: writer)
            expect(false, "loadActivityEvents: expected unknownFutureSchema to be thrown for schemaVersion \(futureVersion)")
        } catch ActivityStoreError.unknownFutureSchema(_, let version, let supported) {
            expect(version == futureVersion && supported == ActivityLogFile.currentSchemaVersion,
                   "loadActivityEvents: unknownFutureSchema reports the offending and supported versions")
        } catch {
            expect(false, "loadActivityEvents: expected unknownFutureSchema, got \(error)")
        }
    }

    // --- BACKEND: cancelling a subscriber's consuming task frees its observer slot ---
    // ("Watch out for": AsyncStream continuation lifecycle needs care — a dropped subscriber
    // that never triggers onTermination would leak an observer entry forever.)
    do {
        let store = ActivityStore(replicaId: UUID())
        let stream = await store.subscribe()
        let countAfterSubscribe = await store.observerCount()
        expect(countAfterSubscribe == 1, "subscribe: registers exactly one observer")

        let consumer = Task {
            var iter = stream.makeAsyncIterator()
            _ = await iter.next()   // consumes the initial snapshot item
            _ = await iter.next()   // suspends waiting for a live event — cancellation interrupts this
        }
        // Give the consumer a moment to reach the second, suspending `next()` call
        // before cancelling it out from under it.
        try? await Task.sleep(nanoseconds: 20_000_000)
        consumer.cancel()

        // onTermination dispatches an async Task to remove the observer; poll with a
        // bounded timeout rather than asserting (or blocking) immediately.
        var countAfterCancel = await store.observerCount()
        var attempts = 0
        while countAfterCancel != 0 && attempts < 50 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            countAfterCancel = await store.observerCount()
            attempts += 1
        }
        expect(countAfterCancel == 0, "subscribe: cancelling the consuming task triggers onTermination and frees the observer slot")
    }

    // --- BACKEND: concurrent appends do not corrupt the snapshot ---
    do {
        let store = ActivityStore(replicaId: UUID())
        let tileIds = (0..<10).map { _ in UUID() }
        await withTaskGroup(of: Void.self) { group in
            for tid in tileIds {
                group.addTask {
                    await store.append(makeDraft(tileId: tid, status: .working, kind: "turn.start"))
                    await store.append(makeDraft(tileId: tid, status: .done, kind: "exit.clean"))
                }
            }
            for await _ in group {}
        }
        let snapshot = await store.currentSnapshot()
        expect(snapshot.byAgent.count == 10, "concurrent appends: every distinct agent lands exactly once in byAgent")
        expect(tileIds.allSatisfy { snapshot.byAgent[$0]?.status == .done },
               "concurrent appends: each tile's status reflects its own last-appended event, no cross-tile corruption")
        let allSequences = snapshot.byAgent.values.flatMap { $0.recent.map(\.sequence) }
        expect(Set(allSequences).count == allSequences.count,
               "concurrent appends: sequence numbers are unique across all concurrently appending tasks")
    }

    print("ActivityStoreTests passed")
}
