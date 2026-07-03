# Activity projection over the sync transport

> **Retry rulings C-20260703-020 (read before implementing — supersede any conflicting line below):**
> 1. **Synchronous demux registration (the real production bug):** demux subscriptions MUST be
>    registered synchronously BEFORE any send — in `ActivityProjectionReceiver.connect()` (the prior
>    attempt sent `.activitySubscribe` before its receiveLoop Task registered; see
>    `SyncMessageDemux.swift:52` drain-time broadcast) and symmetrically in
>    `ActivityProjectionSender.start()`. Add a Checks case with a PRE-EXISTING spatial subscriber on
>    the SAME shared demux — fresh/private-demux checks never gate this race.
> 2. **Deterministic loopback harness:** the count-based delay model stranded trailing replay /
>    cold-reconnect messages (~25% red). The harness must drain/flush pending until
>    convergence-or-timeout, be deterministic across many runs, and prove convergence happens via the
>    REAL replay / cold-reconnect path (not a lucky extra send).
> A prior attempt is stashed (`git stash list`) and may be salvaged where its code survives review findings.

> **Ruling C-20260701-009 (read before implementing):** where this ticket says `ActivityTreeSnapshot`
> meaning the **byTile fold read-model** (ticket 08's summary-per-tile snapshot), that type was renamed
> to **`ActivityLogSnapshot`**. The name `ActivityTreeSnapshot` now belongs to ticket 11's SidebarTree
> envelope. Use `ActivityLogSnapshot` for the fold read-model.

## What this delivers

After this ticket lands, the `ActivityStore` — which already knows how to produce a
snapshot-then-tail stream of `AgentActivityEvent`s — is wired to the `SyncTransport` seam
so that projection items flow out to connected observers. On the receiving side, an
`ActivityProjectionReceiver` consumes the transport stream, reconstructs the
`ActivityTreeSnapshot` using the same pure `apply(_:_:)` fold the host uses, and exposes it
to local consumers (the sidebar tree, the iOS fleet list) via its own `subscribe()` call.

The system outcome is a live, gap-free activity projection delivered to any observer that
attaches to the transport — initially the Mac itself over the in-process fake, and later the
CloudKit transport that the iOS app will consume. The iOS app never polls, never queries the
event log directly, and never sends events upstream: it is a read-only subscriber of a
one-way projection, enforced by the `Scope` OptionSet type (specifically `.observe`) which
makes it structurally impossible for a subscriber to call any write API. I5 (sync-boundary
purity) holds across this boundary because `AgentActivityEvent` contains no pid, no
`tmuxWindowTarget`, no transcript bodies, and no host-local handles — those constraints were
baked into the type in the sync/observation type split.

The projection is always gap-free because the protocol is snapshot-then-tail: the host sends
the current `ActivityTreeSnapshot` first, then trails live `AgentActivityEvent`s as they
arrive. A subscriber that reconnects after a gap sends its last-seen `(sequence, replicaId)`
cursor; the host calls `replay(fromSequenceExclusive:replicaId:)` on the `ActivityStore` and
re-emits the missing events before resuming the live tail. No events are ever silently
skipped.

## How it fits

This ticket sits at the intersection of two complete foundations. The sync/observation type
split defined `AgentActivityEvent`, `ActivityTreeSnapshot`, `ActivityStreamItem`, the pure
`apply(_:_:)` fold, and the `ActivityStore` actor with its `subscribe()` and
`replay(fromSequenceExclusive:replicaId:)` APIs — all of which this ticket wires to the
outside world without modifying. The `SyncTransport` seam defined the protocol the transport
fake and the CloudKit implementation both satisfy, including the `FakeTransport`'s ability to
partition, reorder, delay, drop, and duplicate messages — which is what makes the gap-fill
logic testable without a real network.

What this ticket unblocks: the CloudKit transport implementation can now carry the activity
channel alongside the spatial op-log channel (two logical topics, one transport); the iOS
observer app has a defined subscription surface to attach to; and the connection supervisor
can include activity-projection resubscription in its reconnect state machine. The
activity-projection receiver also becomes the exact `[UUID: AgentStatus]` source that feeds
`SidebarTreeBuilder.build(registry:documents:projectCanvases:agentStatusesByTileId:)` at
`SidebarTree.swift:139`, replacing the mock status map with a live, transport-backed one
once the sidebar-tree feed ticket completes.

## The approach

Two new types, both in `Sources/ContinuumRevivedCore/`.

**`ActivityProjectionSender`** wraps the `ActivityStore` and the `SyncTransport`. When
started, it subscribes to the activity store's `subscribe()` stream and forwards each item
to the transport on the activity channel. When a new observer connects and requests a
subscription (arriving as a transport control message on the activity channel), the sender
calls `ActivityStore.currentSnapshot()` to get the snapshot, then replays any events since
the subscriber's cursor before letting the live stream take over — all sent in strict
sequence order so the receiver can fold them gap-free.

**`ActivityProjectionReceiver`** holds its own `ActivityTreeSnapshot` (starting from
`.empty`), subscribes to the transport's activity channel, and folds incoming
`ActivityStreamItem`s with the same `apply(_:_:)` function. On receipt of a `.snapshot`
item it replaces its local snapshot entirely; on receipt of `.event` items it folds them in.
If the receiver detects a gap (an event's `sequence` is not exactly `localSnapshot.snapshotSequence + 1`
for the same `replicaId`), it sends a catch-up request message carrying its current
`(sequence, replicaId)` cursor; the sender responds with the missing events and then resumes
the live tail. The receiver exposes its own `subscribe()` method returning
`AsyncStream<ActivityStreamItem>`, so local consumers of the projection (sidebar, iOS UI)
use the identical API whether they are on the host or a remote device.

The two types never communicate directly — they speak only through the transport. This is
what makes swapping the fake for CloudKit a zero-callsite change.

The **`Scope` OptionSet** guard is enforced at the transport level: `ActivityProjectionSender`
requires the caller's scope to include `.observe` before accepting a subscription request.
The sender itself is a host-side writer and carries `.host` scope; a receiver with only
`.observe` scope can subscribe but cannot call `append` on the `ActivityStore`. The scope
check is a function call, not an `if`-statement, so it is tested in the logic suite.

The **I5 taint hold** is asserted in the existing taint-scan suite (established in the
sync/observation type split ticket and the taint-scan ticket). This ticket adds one new
assertion to that suite: that `ActivityStreamItem` (as it exits the sender and enters the
receiver) contains no forbidden fields. Because `ActivityStreamItem` wraps
`ActivityTreeSnapshot` and `AgentActivityEvent` — both already taint-scanned — this
assertion is expected to be trivially fast to write and green immediately.

## Where it lives

**New files to create:**

- `Sources/ContinuumRevivedCore/ActivityProjectionSender.swift` — defines the `ActivityProjectionSender` actor and its `start(store:transport:)` entry point
- `Sources/ContinuumRevivedCore/ActivityProjectionReceiver.swift` — defines the `ActivityProjectionReceiver` actor and its `subscribe() -> AsyncStream<ActivityStreamItem>` API

**Existing seams this ticket reads and depends on, but does not modify:**

- `Sources/ContinuumRevivedCore/AgentActivityEvent.swift` (created in the sync/observation type split) — `AgentActivityEvent`, `ActivityTreeSnapshot`, `ActivityStreamItem`, `ActivityEventTone`, `apply(_:_:)`, `TileActivity`
- `Sources/ContinuumRevivedCore/ActivityStore.swift` (created in the sync/observation type split) — `ActivityStoreProtocol` and `ActivityStore`; specifically `subscribe()`, `replay(fromSequenceExclusive:replicaId:)`, and `currentSnapshot()`
- `Sources/ContinuumRevivedCore/SyncTransport.swift` (created in the transport seam ticket) — `SyncTransportProtocol`, `FakeTransport`, and the channel-addressing model; the activity channel is `TransportChannel.activity`, distinct from `TransportChannel.spatialOps`
- `Sources/ContinuumRevivedCore/SidebarTree.swift:134` — `SidebarTreeBuilder.build(registry:documents:projectCanvases:agentStatusesByTileId:)` is the downstream consumer this receiver's projected `[UUID: AgentStatus]` will eventually feed; this ticket does not touch that file but must produce a compatible output type
- `Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift:85` — `AgentStatus` is the status vocabulary carried in `AgentActivityEvent.status` and surfaced through the receiver's projected snapshot

**Test file to create:**

- `Tests/ContinuumRevivedCoreTests/ActivityProjectionTransportTests.swift`

## Implementation breadcrumbs

```swift
// ActivityProjectionSender.swift

// Transport channel identity — must match whatever the SyncTransport seam names it.
// The spatial-ops channel is the sibling; the two never carry each other's payloads.
extension TransportChannel {
    static let activity = TransportChannel(rawValue: "activity")
}

public actor ActivityProjectionSender {
    private let store: any ActivityStoreProtocol
    private let transport: any SyncTransportProtocol
    private var subscriptionTask: Task<Void, Never>?

    public init(store: any ActivityStoreProtocol, transport: any SyncTransportProtocol) {
        self.store = store
        self.transport = transport
    }

    // Call once. Drives the live-tail forwarding loop and handles incoming subscription requests.
    public func start() {
        subscriptionTask = Task {
            // Two concurrent work streams: forward live events, handle new-subscriber requests.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.forwardLiveTail() }
                group.addTask { await self.handleSubscriptionRequests() }
            }
        }
    }

    // Forwards every ActivityStreamItem from the store onto the transport activity channel.
    private func forwardLiveTail() async {
        let stream = await store.subscribe()
        for await item in stream {
            // Encode item as Codable and send — exact encoding matches the transport seam's contract.
            await transport.send(item, on: .activity)
        }
    }

    // Listens for incoming subscription requests (carrying a catch-up cursor) from observers.
    private func handleSubscriptionRequests() async {
        for await request in transport.incomingMessages(on: .activity, type: ActivitySubscribeRequest.self) {
            guard request.scope.contains(.observe) else { continue }  // scope guard
            // Send the current snapshot first, then replay any missing events.
            let snapshot = await store.currentSnapshot()
            await transport.send(ActivityStreamItem.snapshot(snapshot), on: .activity, to: request.subscriberId)
            if let cursor = request.cursor {
                let missed = await store.replay(fromSequenceExclusive: cursor.sequence, replicaId: cursor.replicaId)
                for event in missed {
                    await transport.send(ActivityStreamItem.event(event), on: .activity, to: request.subscriberId)
                }
            }
            // The live tail continues from forwardLiveTail(); no additional wiring needed here.
        }
    }
}

// The control message a receiver sends to request a projection subscription.
struct ActivitySubscribeRequest: Codable, Sendable {
    let subscriberId: UUID           // the receiver's identity on the transport
    let scope: Scope                 // must include .observe; sender enforces this
    let cursor: ActivityCursor?      // nil on first connect; non-nil on reconnect
}
struct ActivityCursor: Codable, Sendable {
    let sequence: UInt64
    let replicaId: UUID
}
```

```swift
// ActivityProjectionReceiver.swift

public actor ActivityProjectionReceiver {
    private var snapshot: ActivityTreeSnapshot = .empty
    private var observers: [UUID: AsyncStream<ActivityStreamItem>.Continuation] = [:]
    private let transport: any SyncTransportProtocol
    private let subscriberId: UUID
    private let scope: Scope   // must include .observe

    public init(transport: any SyncTransportProtocol, subscriberId: UUID, scope: Scope) {
        precondition(scope.contains(.observe))
        self.transport = transport
        self.subscriberId = subscriberId
        self.scope = scope
    }

    // Sends the subscription request and starts the fold loop.
    // Call once after initializing the receiver.
    public func connect(cursor: ActivityCursor? = nil) async {
        let request = ActivitySubscribeRequest(subscriberId: subscriberId, scope: scope, cursor: cursor)
        await transport.send(request, on: .activity)
        Task { await self.receiveLoop() }
    }

    // Folds incoming ActivityStreamItem events into the local snapshot.
    private func receiveLoop() async {
        for await item in transport.incomingMessages(on: .activity, type: ActivityStreamItem.self) {
            switch item {
            case .snapshot(let snap):
                // Full snapshot replacement — used on first connect and after a detected gap.
                snapshot = snap
                fan(item)
            case .event(let event):
                let expectedSeq = snapshot.snapshotSequence + 1
                if event.replicaId == snapshot.snapshotReplicaId && event.sequence != expectedSeq {
                    // Gap detected. Request a catch-up replay.
                    let cursor = ActivityCursor(sequence: snapshot.snapshotSequence, replicaId: snapshot.snapshotReplicaId)
                    let request = ActivitySubscribeRequest(subscriberId: subscriberId, scope: scope, cursor: cursor)
                    await transport.send(request, on: .activity)
                    // Do NOT fold this event yet; wait for the replay to re-deliver it in order.
                    continue
                }
                snapshot = apply(snapshot, event)
                fan(item)
            }
        }
    }

    // Fan out to local subscribers — identical API to ActivityStore.subscribe().
    public func subscribe() -> AsyncStream<ActivityStreamItem> {
        let current = snapshot
        return AsyncStream { continuation in
            continuation.yield(.snapshot(current))
            let id = UUID()
            observers[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        }
    }

    // Project the current snapshot to the [UUID: AgentStatus] map SidebarTreeBuilder expects.
    public func agentStatusesByTileId() -> [UUID: AgentStatus] {
        snapshot.byTile.mapValues(\.status)
    }

    private func fan(_ item: ActivityStreamItem) {
        for cont in observers.values { cont.yield(item) }
    }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
}
```

```swift
// ActivityProjectionTransportTests.swift — three suites

// ── LOGIC: gap-free delivery over FakeTransport ──

func testSnapshotThenTailIsGapFree() async {
    // Set up a store with two events already appended, then subscribe via sender/receiver pair.
    let replicaId = UUID(), tileId = UUID()
    let store = ActivityStore(replicaId: replicaId)
    await store.append(makeEvent(tone: .info, status: .working, tileId: tileId, store: store))
    await store.append(makeEvent(tone: .tool, status: .working, tileId: tileId, store: store))

    let transport = FakeTransport()   // in-process, no partitions
    let sender = ActivityProjectionSender(store: store, transport: transport)
    await sender.start()

    let receiverId = UUID()
    let receiver = ActivityProjectionReceiver(transport: transport, subscriberId: receiverId, scope: .observe)
    await receiver.connect(cursor: nil)   // no cursor — cold start

    // Wait for the snapshot to arrive (deterministic with the fake transport's synchronous delivery).
    let items = await collectItems(from: receiver.subscribe(), count: 1, timeout: .milliseconds(100))
    guard case .snapshot(let snap) = items[0] else { XCTFail("expected snapshot first"); return }
    // Snapshot must reflect both events.
    XCTAssertEqual(snap.byTile[tileId]?.status, .working)
    XCTAssertEqual(snap.snapshotSequence, 2)
}

func testGapDetectionTriggersReplay() async {
    // Deliver events 1 and 3 to the receiver (simulating a dropped event 2 via FakeTransport.drop).
    // Assert the receiver requests a replay and eventually reaches the correct snapshot.
    let replicaId = UUID(), tileId = UUID()
    let store = ActivityStore(replicaId: replicaId)
    let e1 = await appendEvent(status: .working, tileId: tileId, store: store)
    let e2 = await appendEvent(status: .needsAttention, tileId: tileId, store: store)
    let e3 = await appendEvent(status: .done, tileId: tileId, store: store)

    let transport = FakeTransport()
    transport.dropMessages(matching: { msg in msg.contains(sequence: e2.sequence) })  // simulate drop

    let sender = ActivityProjectionSender(store: store, transport: transport)
    await sender.start()
    let receiver = ActivityProjectionReceiver(transport: transport, subscriberId: UUID(), scope: .observe)
    await receiver.connect()

    // After the replay the receiver's snapshot must reflect all three events.
    let finalSnapshot = await receiver.snapshot()  // expose for test only
    XCTAssertEqual(finalSnapshot.byTile[tileId]?.status, .done)
    XCTAssertEqual(finalSnapshot.snapshotSequence, 3)
}

// ── LOGIC: scope guard — observer cannot inject events ──
func testObserverScopeCannotCallAppend() async {
    // Confirm that the Scope OptionSet does not contain a write bit for .observe.
    let observeOnly = Scope.observe
    XCTAssertFalse(observeOnly.contains(.appendActivity))
    // The sender rejects a subscription request from a non-observe scope.
    let transport = FakeTransport()
    let store = ActivityStore(replicaId: UUID())
    let sender = ActivityProjectionSender(store: store, transport: transport)
    await sender.start()
    // Send a subscription request with no scope — sender should not deliver any items.
    let badRequest = ActivitySubscribeRequest(subscriberId: UUID(), scope: Scope(), cursor: nil)
    await transport.send(badRequest, on: .activity)
    let items = await collectItems(from: /* receiver stream */, count: 1, timeout: .milliseconds(50))
    XCTAssertTrue(items.isEmpty)  // nothing delivered
}

// ── LOGIC: I5 taint — ActivityStreamItem carries no forbidden fields ──
func testActivityStreamItemCarriesNoForbiddenFields() {
    // Mirror all stored properties of AgentActivityEvent.
    // Fail if any property name matches the forbidden set.
    let forbidden: Set<String> = ["pid", "paneid", "tmuxwindowtarget", "scrollback", "transcript", "ptyfd"]
    let mirror = Mirror(reflecting: AgentActivityEvent.dummy)
    for child in mirror.children {
        let label = (child.label ?? "").lowercased().replacingOccurrences(of: "_", with: "")
        XCTAssertFalse(forbidden.contains(label), "I5 violation: field '\(child.label ?? "?")' must not appear in AgentActivityEvent")
    }
}
```

## How we test it

### Logic (pure Core checks)

All logic checks run without a real transport, a real tmux daemon, or any network. They use
`ActivityStore`, `FakeTransport`, and the pure `apply(_:_:)` function in the Core test target.

The snapshot-then-tail ordering check confirms that a cold-connect receiver always receives
exactly one `.snapshot` item before any `.event` items, and that the snapshot reflects the
full state of the store at subscription time — not just the events emitted after the
subscriber joined.

The gap-detection replay check uses `FakeTransport`'s drop API to simulate a missing event,
then asserts that the receiver detects the sequence discontinuity, sends a catch-up request,
and eventually arrives at the byte-identical `ActivityTreeSnapshot` that the sender holds.
The terminal snapshot after replay must equal `apply(apply(apply(.empty, e1), e2), e3)` —
the same result the sender computed live — because the pure fold is the single source of
truth for both sides.

The scope-guard check confirms that a subscription request bearing an empty or
insufficient `Scope` receives no projection items. The `Scope.observe` bit must be present;
the test mirrors the bit table to confirm `.observe` does not imply `.appendActivity` or any
other write capability.

The I5 taint continuation check mirrors the stored properties of `AgentActivityEvent` and
asserts that none of their names (case-insensitively, stripped of underscores) appear in the
forbidden set `{pid, paneid, tmuxwindowtarget, scrollback, transcript, ptyfd}`. This extends
the existing taint-scan suite without touching any other file.

### Backend (real-path integration)

The backend check wires a real `ActivityStore` (seeded with ten events across three tiles) to
a real `ActivityProjectionSender`, routes through the `FakeTransport` configured with a
two-message delay and a one-message drop in the middle of the sequence, and drives a real
`ActivityProjectionReceiver` to completion. The check asserts:

1. The receiver's final `ActivityTreeSnapshot` is byte-identical to `store.currentSnapshot()`
   after all events are delivered (including the replayed gap).
2. The receiver's `agentStatusesByTileId()` output matches `store.currentSnapshot().byTile.mapValues(\.status)`.
3. No event is double-applied: a tile that goes `working → needsAttention → done` must end at
   `done`, not cycle back.
4. The gap-fill round-trip completes within 100 ms on the fake transport (no wall-clock budget
   on the real transport, but this gates a latent infinite-retry bug).

This check does not use the CloudKit transport — that implementation lives in a later ticket.
The fake transport is the real integration surface for this ticket's correctness.

### UX (visual gate + dogfood snippet)

This ticket produces no new UI of its own. The projection it wires is the data source for the
sidebar tree, which is rendered by the dock that the "render the left dock" ticket ships. A
deferred visual gate is therefore correct: once both tickets land, the combined gate is:

Open the app with at least one terminal tile running Claude. Navigate to the left dock (toggle
with the dock keybind if hidden). Confirm that the tile's row in the dock shows a blue pulse
status indicator (the `working` state, rendered as a blue pulse per the established status
vocabulary). Start a new task in Claude so it transitions to `needsAttention`. Confirm the
tile's row immediately shows the orange diamond with the `needs you` label — without a manual
refresh, within the 250 ms debounce budget. This is the end-to-end proof that `SessionObserver`
→ `ActivityStore.append` → `ActivityProjectionSender` → `ActivityProjectionReceiver` →
`SidebarTreeBuilder.build` → dock render is gap-free and live.

For the purposes of this ticket alone, the intermediate verification is: run the logic suite
green, then add a temporary `print(receiver.agentStatusesByTileId())` call in a test harness
target that seeds the store with three known events and drives the sender/receiver pair — confirm
the output dictionary matches the expected statuses by hand. Remove the print before merging.

## Execution mode

**Autonomous.** Every correctness property of this ticket — gap-free delivery, gap detection
and replay, scope enforcement, I5 taint hold, snapshot-before-events ordering — is provable
by pure Core logic checks and the fake-transport backend check. No human eyes are needed for
any of these assertions: they produce measured values (final snapshot byte-equality,
round-trip latency, taint field enumeration), not subjective judgments. The UX gate belongs
to the dock-render ticket, which is supervised; this ticket does not ship any UI and
therefore does not inherit the supervised classification. All checks run in CI without a
CloudKit account, a real iOS device, or a live agent.

## Done when

- [ ] `Sources/ContinuumRevivedCore/ActivityProjectionSender.swift` exists, compiles, and
  satisfies the `ActivityProjectionSenderProtocol` (or the concrete type, if no protocol is
  needed for the fake path).
- [ ] `Sources/ContinuumRevivedCore/ActivityProjectionReceiver.swift` exists and its
  `subscribe() -> AsyncStream<ActivityStreamItem>` API is callable without any network.
- [ ] `ActivityProjectionReceiver.agentStatusesByTileId() -> [UUID: AgentStatus]` returns a
  map that is structurally compatible with `SidebarTreeBuilder.build`'s
  `agentStatusesByTileId:` parameter (same key type, same value type, confirmed by the
  type-checker).
- [ ] The gap-free snapshot-then-tail logic check passes: a cold-connect receiver receives
  `.snapshot` first, then `.event`s, and the final snapshot equals the host's snapshot.
- [ ] The gap-detection replay logic check passes: a dropped event causes a replay request and
  the receiver converges to the byte-identical final snapshot.
- [ ] The scope-guard logic check passes: a scope-less subscription request delivers zero
  items to the requester.
- [ ] The I5 taint continuation check passes: no property of `AgentActivityEvent` or
  `ActivityStreamItem` bears a forbidden name.
- [ ] The backend integration check passes with a two-message delay and a one-message drop,
  completing within 100 ms on the fake transport, with final snapshots byte-identical on both
  sides and no double-application of any event.
- [ ] The existing taint-scan suite (`ActivityTaintScanTests.swift`) remains fully green —
  this ticket must not introduce any new field that breaks I5.
- [ ] No new public API that carries a pid, pane target, host-local handle, or transcript body.

## Depends on / unblocks

This ticket depends directly on two completed foundations. The sync/observation type split
established every type this ticket wires: `AgentActivityEvent`, `ActivityTreeSnapshot`,
`ActivityStreamItem`, the pure `apply(_:_:)` fold, `ActivityStoreProtocol`, and
`ActivityStore` with `subscribe()`, `replay(fromSequenceExclusive:replicaId:)`, and
`currentSnapshot()`. The transport seam established `SyncTransportProtocol`, the
`FakeTransport` with its drop/delay/partition capabilities, and the channel-addressing model
that distinguishes `TransportChannel.spatialOps` from `TransportChannel.activity`.

This ticket unblocks the CloudKit transport implementation, which needs a defined activity
channel sender/receiver pair to carry alongside the spatial op-log channel. It also unblocks
the iOS observer app, which attaches to an `ActivityProjectionReceiver` for its fleet list,
and the connection supervisor, which must include activity-projection resubscription in its
reconnect state machine. Separately, the `agentStatusesByTileId()` output this receiver
exposes is the feed that the sidebar-tree-from-observer ticket plugs into
`SidebarTreeBuilder.build` to replace the mock status map.

## Watch out for

**The gap-fill loop must be bounded.** If the sender is slow or the transport drops the
replay response, the receiver's gap-detection logic must not retry infinitely. Put a
per-gap retry cap of three attempts with a 500 ms back-off between retries; on exhaustion,
fall through to re-sending a cold-connect request (cursor-less), accepting a full snapshot
re-delivery rather than stalling forever. This is the single most likely production failure
mode: a receiver stuck in a gap-fill loop that never converges because a replay response is
also dropped.

**The sender's `forwardLiveTail` loop must not skip events that arrived between the snapshot
fetch and the subscription.** The sequence is: (1) sender fetches the snapshot with
`currentSnapshot()`, (2) sender sends the snapshot, (3) live events may arrive in the store
before step 4, (4) sender continues the live tail. If step 3 happens and those events are
not included in the replay, the receiver will detect a gap on the first live event and
trigger an unnecessary round-trip. The safe implementation fetches the snapshot and records
its `snapshotSequence` before starting the live tail forward, then for each new subscriber
replays all events with `sequence > snapshotSequence` before forwarding the live tail. The
order of operations inside `handleSubscriptionRequests` is load-bearing.

**Do not use wall-clock timestamps for event ordering.** The `AgentActivityEvent.sequence`
field is the canonical order; `occurredAt` is for display only. Any comparison or
gap-detection logic that uses `occurredAt` instead of `sequence` will produce
non-deterministic behavior across devices with skewed clocks, violating I4's analogue for
the activity layer.

**The `Scope` check is not a soft guard.** The sender must silently discard subscription
requests that lack `.observe` — not log a warning and proceed, not crash. A future attacker
(or a bug) sending a crafted subscription request must receive no activity items. Test this
explicitly with the scope-guard logic check; do not leave it as a code comment.

**I5 must hold through serialization.** The `ActivityStreamItem` is encoded and decoded by
the transport. If the `Codable` synthesis includes any synthesized field that was not in the
type definition (a rare but real Swift bug with property wrappers or nested types), the taint
scan can pass while the wire payload carries something unexpected. Run the taint check against
the *decoded* value after a round-trip through `JSONEncoder`/`JSONDecoder`, not just against
the struct definition's stored properties.
