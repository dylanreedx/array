# Injectable substrates: TmuxControl, fake clock, fake host, fake sync transport

## What this delivers

Every piece of timing- and daemon-dependent logic in the session topology and observer layers can be exercised in a pure Swift process — no running tmux server, no wall clock, no SSH host, no CloudKit account. The payoff is a check harness that is deterministic, fast, and honest: time advances only when a test advances it, tmux responds only to commands the test pre-programs, and the sync transport can drop, reorder, or duplicate ops on demand. Later tickets that build the observer, the idle reaper, the convergence fuzz, and the transport soak all depend on these primitives being in place before they arrive.

This is the substrate half of decision **D26** (phase-0 harness: injectable substrates stood up first). It rests directly on **D3** (deterministic op-log with a Lamport + replicaId clock) for the sync-transport seam, **D16** (detach-never-kill lifecycle) for what the tmux fake must model, and **D8/D9** (localhost + ssh-wrap reach) for what the host fake must model.

## How it fits

This ticket is a standalone phase-0 foundation. It builds on nothing except the existing `ContinuumRevivedCore` module. It does not change any production behavior — it adds protocols behind which existing concrete types are retrofitted, and ships fakes alongside them. Everything that follows in phases 1–6 touches at least one of these four seams. The idle reaper (which detaches stale sessions based on elapsed time) needs the fake clock so its threshold logic can be exercised without sleeping. The session topology tickets need `TmuxControl` to prove spawn, kill-window, and liveness-probe behavior in the check harness. The convergence fuzz and the transport soak need the fake sync transport that can partition and reorder. The `Host` model for remote execution needs the fake host so SSH-path logic runs without a VPS. None of those tickets can be written cleanly without these substrates existing first.

This ticket also enforces the wall-clock ban that the architecture mandates. Today several Core types already receive `now: Date` as a parameter — `AgentStatusEngine.ingest(_:at:)` (`Sources/ContinuumRevivedCore/AgentStatusEngine.swift:37`), `AgentStatusEngine.tick(at:)` (`:66`), `AgentDescriptor.restoredForBoot(now:)` (`TerminalSessionDescriptor.swift:113`), and the `BrowserState` family — demonstrating that the pattern is already established in this codebase. This ticket extends it systematically: any new type in the session/observer layers that needs a notion of "now" receives a `Clock` dependency rather than calling `Date()` directly.

### The op-envelope provenance question, resolved up front

> **RULING (2026-07-01 — supersedes the paragraphs below where they conflict):** Ticket 02
> (the op enum & LoggedOp envelope) has ALREADY landed **both** `OpId` and
> `LoggedOp { opId; op: Op }` in `ContinuumRevivedCore` (`SpatialOp.swift`). To avoid a
> name collision with those shipped types, this ticket must: **(1) reuse ticket 02's existing
> `OpId` verbatim — do NOT re-declare it;** and **(2) name this ticket's op-agnostic transport
> envelope `TransportLoggedOp { opId: OpId; payload: Data }`.** Everywhere the text below says
> `LoggedOp` for the *transport envelope*, read `TransportLoggedOp`. Ticket 02's `LoggedOp`
> (which carries a typed `Op`) stays untouched; the two coexist cleanly — one carries a typed
> op, the other an opaque `payload` the transport never inspects.

The sync transport moves ops, so it needs a *type of op* to move. The SYNC-MODEL spike (`docs/2026-06-30-orchestration-spikes/SYNC-MODEL.md:290-319`) defines the full op vocabulary — `OpId`, `Op`, `LoggedOp` — and locates it in a *future* dependency-free `ContinuumRevivedSync` target that does not exist yet. That target is out of scope here: this ticket must not pull in the whole spatial op enum, and it must stay standalone against Core.

So **this ticket creates a minimal `OpId` and `LoggedOp` in `ContinuumRevivedCore`** — the smallest shape the transport needs to be a real seam — with fields that match the spike verbatim so the future `ContinuumRevivedSync` work re-homes (or re-exports) them without a rename:

- `OpId { lamport: UInt64; replica: UUID }`, `Comparable`/`Codable`/`Hashable`/`Sendable`, compared `(lamport, replica)` lexicographically. This is D3's Lamport + replicaId clock, exactly as the spike specifies.
- `LoggedOp { opId: OpId; payload: Data }`, `Codable`/`Sendable`. The transport is deliberately **op-agnostic**: it carries an opaque `payload` and sorts/dedupes by `opId`. It does *not* know about `Op` (the spatial enum), so the future sync module can define `Op` and encode it into `LoggedOp.payload` without touching the transport at all.

`LoggedOp.opId` is the sort key the transport test relies on ("sort both sets by op id and compare") and the idempotency key CloudKit will use for upsert (D4). This makes the seam fully specified today and forward-compatible with the spike: when `ContinuumRevivedSync` lands, `LoggedOp` either moves there (and Core re-exports it) or the spike's richer `LoggedOp { opId; op: Op }` supersedes this one behind the same `SyncTransport` protocol — a documented, non-breaking swap.

## The approach

Define four protocols in `ContinuumRevivedCore`, each accompanied by a concrete in-memory fake in the same module (or in a dedicated `ContinuumRevivedCoreTestSupport` library target if Package.swift already separates test helpers — it does not today, so default to the same module unless that changes). Wire the four real implementations behind those protocols. Ban direct `Date()` calls in all new topology and observer code by making the `Clock` protocol the only blessed path. Add the minimal `OpId`/`LoggedOp` op-envelope the transport carries.

**TmuxControl** is the central seam. Today `TmuxSession` is a pure enum of static functions that construct argv strings; the actual subprocess invocation lives in `TileSpawner` and `ContinuumApp`. The protocol captures the *operations* the rest of the system needs tmux to perform, not the argv strings themselves. The fake records every call and returns pre-programmed responses. The real implementation shells out via `Process`.

**Clock** is tiny — a single `now() -> Date` requirement. Every new type that previously would have called `Date()` inline instead takes a `Clock` in its initializer. The fake holds a `var current: Date` that tests advance explicitly.

**Host** models "a box we can reach tmux on" — for now, `localhost` or `sshForward` (D8's `RemoteReach` menu, first two arms). It answers exactly one question: given a host identity, hand me the `TmuxControl` I use to reach it. The fake returns canned `TmuxControl` instances keyed by host identity, throwing a typed error on an unknown host, making remote-path logic testable without SSH.

**SyncTransport** is the op-log push/pull seam for the spatial layer (D3/D4). It has exactly two protocol requirements — `push(_:)` and `subscribe(_:)` — and carries the opaque `LoggedOp` envelopes defined above. The fake adds one *test-only* affordance, `deliver()`, that flushes queued ops to subscribers according to a network `mode` (`.reliable`, `.partition`, `.reorder(seed:)`, `.lossy(dropRate:)`) — this is how the convergence fuzz and transport soak drive dropped/reordered delivery. `deliver()` is **not** on the protocol; the real CloudKit transport delivers continuously via `CKSubscription` pushes, with no manual flush.

None of these protocols are large. The value is in the boundary they draw, not in any complexity of their own.

## Where it lives

All new files go in `Sources/ContinuumRevivedCore/` unless a separate test-support target already exists (it does not).

**New protocols, fakes, and the op envelope:**

- `Sources/ContinuumRevivedCore/Substrates/OpEnvelope.swift` — the minimal `OpId` and `LoggedOp` this ticket creates (see provenance note above)
- `Sources/ContinuumRevivedCore/Substrates/TmuxControl.swift` — the `TmuxControl` protocol and `InMemoryTmuxControl` fake
- `Sources/ContinuumRevivedCore/Substrates/Clock.swift` — the `Clock` protocol, `SystemClock` (calls `Date()`), and `FakeClock`
- `Sources/ContinuumRevivedCore/Substrates/Host.swift` — the `Host` protocol, `HostIdentity`, `HostError`, and `FakeHost`
- `Sources/ContinuumRevivedCore/Substrates/SyncTransport.swift` — the `SyncTransport` protocol and `FakeSyncTransport`

**Existing seams retrofitted:**

- `Sources/ContinuumRevivedCore/TmuxSession.swift` lines 8–33: `TmuxSession.sessionName(tileId:)` and `TmuxSession.wrap(profile:tileId:tmuxPath:)` remain as pure argv constructors (they are already pure functions with no side effects). The new `TmuxControl` protocol sits *above* them — implementors use `TmuxSession` to build the argv and then pass it to `Process`. No changes needed to `TmuxSession.swift` itself.
- `Sources/ContinuumRevivedCore/TmuxSession.swift` lines 36–73: `TmuxLocator.resolve(defaults:)` is the real implementation of "find the tmux binary." The real `TmuxControl` implementation takes a `tmuxPath: String` at init, resolved once via `TmuxLocator.resolve()` at the call site. `TmuxLocator` itself is unchanged.
- `Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift` line 113: `AgentDescriptor.restoredForBoot(now: Date = Date())` already accepts an injected date; new topology code follows this same `now: Date` parameter pattern via the `Clock` protocol.
- `Sources/ContinuumRevivedCoreChecks/main.swift`: the four new check suites append to the existing file, following its `do { … }` block pattern.

## Implementation breadcrumbs

**Op envelope (created by this ticket):**

```swift
// The minimal op-transport shape. Fields match SYNC-MODEL.md:294-318 verbatim so the
// future ContinuumRevivedSync target can re-home these without a rename.
public struct OpId: Comparable, Codable, Hashable, Sendable {
    public var lamport: UInt64      // logical clock — max-seen + 1 on apply (D3)
    public var replica: UUID        // stable per-device id; total-order tie-break

    public init(lamport: UInt64, replica: UUID) { self.lamport = lamport; self.replica = replica }

    public static func < (a: OpId, b: OpId) -> Bool {   // compare (lamport, replica) lexicographically
        (a.lamport, a.replica.uuidString) < (b.lamport, b.replica.uuidString)
    }
}

// The transport is op-agnostic: it carries an opaque payload and sorts/dedupes by opId.
// It does NOT depend on the spatial `Op` enum (that lives in the future sync target).
public struct LoggedOp: Codable, Sendable, Equatable {
    public var opId: OpId
    public var payload: Data        // the encoded Op — opaque to the transport
    public init(opId: OpId, payload: Data) { self.opId = opId; self.payload = payload }
}
```

**TmuxControl protocol:**

```swift
public protocol TmuxControl: Sendable {
    // Spawn operations — return the captured pane id on success
    func newSession(name: String, cwd: String, innerCommand: [String]?) async throws -> String  // returns %pane_id
    func newWindow(inSession: String, cwd: String, innerCommand: [String]?) async throws -> String  // returns %pane_id

    // Teardown
    func killWindow(target: String) async throws        // target = %pane_id
    func killSession(name: String) async throws
    func detachSession(name: String) async throws

    // Query
    func isAlive(paneTarget: String) async throws -> Bool
    func paneCurrentPath(paneTarget: String) async throws -> String
    func listSessions() async throws -> [TmuxSessionInfo]
}

public struct TmuxSessionInfo: Equatable, Sendable {
    public let name: String
    public let windowCount: Int
    public let paneTargets: [String]
}
```

**InMemoryTmuxControl fake:**

```swift
public final class InMemoryTmuxControl: TmuxControl, @unchecked Sendable {
    // Pre-programmed state
    public var livePanes: [String: PaneStub] = [:]    // %pane_id -> stub
    public var sessions: [String: [String]] = [:]      // session name -> [%pane_id]

    // Call recording
    public private(set) var log: [TmuxCall] = []

    public enum TmuxCall: Equatable {
        case newSession(name: String, cwd: String)
        case newWindow(session: String, cwd: String)
        case killWindow(target: String)
        case killSession(name: String)
        case detachSession(name: String)
        case isAlive(target: String)
    }

    public struct PaneStub: Equatable, Sendable {
        public var cwd: String
        public var currentCommand: String
        public var isAlive: Bool
    }

    private var nextPaneIndex = 1
    private func nextPaneId() -> String { let id = "%\(nextPaneIndex)"; nextPaneIndex += 1; return id }

    public func newSession(name: String, cwd: String, innerCommand: [String]?) async throws -> String {
        log.append(.newSession(name: name, cwd: cwd))
        let paneId = nextPaneId()
        sessions[name] = [paneId]
        livePanes[paneId] = PaneStub(cwd: cwd, currentCommand: innerCommand?.first ?? "zsh", isAlive: true)
        return paneId
    }
    // … newWindow, killWindow, killSession, detachSession, isAlive follow the same pattern
}
```

**FakeClock:**

```swift
public protocol Clock: Sendable {
    func now() -> Date
}

public struct SystemClock: Clock {
    public init() {}
    public func now() -> Date { Date() }
}

public final class FakeClock: Clock, @unchecked Sendable {
    public var current: Date
    public init(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.current = start
    }
    public func now() -> Date { current }
    public func advance(by interval: TimeInterval) { current = current.addingTimeInterval(interval) }
}
```

**Host protocol:**

```swift
// D8's RemoteReach menu, first two arms only. Additive later: .tailscale, .tunnel.
public enum HostIdentity: Hashable, Sendable {
    case localhost
    case sshForward(host: String)   // an ssh-reachable box; `host` is the ssh target name
}

public enum HostError: Error, Equatable {
    case unknownHost(HostIdentity)   // no TmuxControl is registered/reachable for this identity
}

// Answers exactly one question: given a host, hand me the TmuxControl I reach it through.
public protocol Host: Sendable {
    func control(for identity: HostIdentity) throws -> any TmuxControl
}

public final class FakeHost: Host, @unchecked Sendable {
    private var controls: [HostIdentity: any TmuxControl] = [:]
    public init() {}
    public func register(_ control: any TmuxControl, for identity: HostIdentity) {
        controls[identity] = control
    }
    public func control(for identity: HostIdentity) throws -> any TmuxControl {
        guard let c = controls[identity] else { throw HostError.unknownHost(identity) }
        return c
    }
}
```

The real host implementation (a follow-up ticket, not this one) returns a `ProcessTmuxControl` for `.localhost` and an ssh-wrapping `TmuxControl` for `.sshForward` per D9; this ticket ships only the protocol, the identity/error types, and the fake.

**FakeSyncTransport:**

```swift
public enum TransportMode: Sendable {
    case reliable
    case partition                  // drops all ops
    case reorder(seed: UInt64)      // shuffles before delivery
    case lossy(dropRate: Double)    // drops each op with given probability
}

// The protocol is exactly push + subscribe. subscribe hands each delivered op to a
// closure and returns a token; cancelling the token stops delivery to that subscriber.
public protocol SyncTransport: Sendable {
    func push(_ op: LoggedOp) async throws
    @discardableResult
    func subscribe(_ onDelivery: @escaping @Sendable (LoggedOp) -> Void) -> SubscriptionToken
}

public struct SubscriptionToken: Hashable, Sendable {
    public let id: UUID
    public init(id: UUID = UUID()) { self.id = id }
}

public final class FakeSyncTransport: SyncTransport, @unchecked Sendable {
    public var mode: TransportMode = .reliable
    public private(set) var emitted: [LoggedOp] = []     // everything ever push()ed
    public private(set) var delivered: [LoggedOp] = []   // everything flushed to subscribers
    private var pending: [LoggedOp] = []                 // push()ed but not yet deliver()ed
    private var subscribers: [SubscriptionToken: @Sendable (LoggedOp) -> Void] = [:]

    public init() {}

    // Protocol: push queues the op (does NOT auto-deliver — tests control timing via deliver()).
    public func push(_ op: LoggedOp) async throws {
        emitted.append(op)
        pending.append(op)
    }

    // Protocol: register a subscriber, get a cancellable token.
    @discardableResult
    public func subscribe(_ onDelivery: @escaping @Sendable (LoggedOp) -> Void) -> SubscriptionToken {
        let token = SubscriptionToken()
        subscribers[token] = onDelivery
        return token
    }
    public func cancel(_ token: SubscriptionToken) { subscribers[token] = nil }

    // TEST-ONLY affordance — NOT part of the SyncTransport protocol. The real CloudKit
    // transport delivers continuously via CKSubscription push; there is no manual flush.
    // Applies `mode` to the pending queue, appends survivors to `delivered`, and fans them
    // out to every registered subscriber.
    public func deliver() {
        let batch: [LoggedOp]
        switch mode {
        case .reliable:            batch = pending
        case .partition:           batch = []
        case .reorder(let seed):   batch = shuffled(pending, seed: seed)
        case .lossy(let dropRate): batch = pending.filter { _ in nextUnit() >= dropRate }
        }
        pending.removeAll()
        for op in batch {
            delivered.append(op)
            for handler in subscribers.values { handler(op) }
        }
    }
    // shuffled(_:seed:) and nextUnit() use a small seeded PRNG so .reorder/.lossy are deterministic.
}
```

**Wiring real impls — the key pattern:**

The real `ProcessTmuxControl` is initialized with a `tmuxPath` resolved once by the caller via `TmuxLocator.resolve()`. It constructs argv using the existing `TmuxSession` static functions and runs `Process`. Any type in the topology or observer layer that previously held a `tmuxPath: String` and called `Process` directly is refactored to hold a `TmuxControl` instead.

**Wall-clock ban enforcement:** Any new type in the session/observer/transport layers that needs time receives `clock: any Clock` in its initializer with `SystemClock()` as the default. New types must not contain a bare `Date()` call — the check harness validates this at the logical level by running the fake-clock suite with a frozen clock and asserting that no time-dependent behavior fires without an explicit `clock.advance(by:)` call.

## How we test it

### Logic (pure Core checks)

All four suites run in `ContinuumRevivedCoreChecks`, following the existing `do { … }` block convention.

**TmuxControl suite.** Construct an `InMemoryTmuxControl`. Call `newSession`, `newWindow`, and `killWindow` in sequence. Assert that `log` records each call in order, that `sessions` reflects the expected window counts, that `isAlive` returns `true` for a live pane and `false` after `killWindow`. Assert that `listSessions()` returns exactly the pre-programmed sessions. Assert that calling `killSession` on a name removes it from `sessions`. No subprocess is spawned; the suite runs in milliseconds.

**FakeClock suite.** Construct a `FakeClock` at a fixed epoch. Construct an `AgentStatusEngine` using the fake clock. Call `tick(at: clock.now())` and assert status is `.configuring`. Call `clock.advance(by: engine.configuration.staleTimeout + 1)` then `tick(at: clock.now())` and assert status transitions to `.stale`. Assert that without advancing the clock, repeated `tick` calls produce no state change. This proves the time-gated logic is truly injectable and that no hidden `Date()` call can short-circuit it.

**FakeHost suite.** Construct a `FakeHost`. Register a named `InMemoryTmuxControl` for `.localhost` via `register(_:for:)`. Call `control(for: .localhost)` and assert (by object identity) the returned instance is the one that was registered. Call `control(for: .sshForward(host: "vps-1"))` — a host that was never registered — and assert it throws `HostError.unknownHost(.sshForward(host: "vps-1"))` (assert the exact associated value, not merely that *some* error was thrown). This confirms the host abstraction routes to the right control and fails typed-and-loud on an unknown host.

**FakeSyncTransport suite.** Construct a `FakeSyncTransport` in `.reliable` mode; register a subscriber that appends every delivered op to a local array. Build three `LoggedOp`s with ascending `OpId`s (increment `lamport`, fixed `replica`) and distinct `payload`s. Push all three, call `deliver()`; assert all three appear in `delivered` (and in the subscriber's array) in emission order. Switch to `.partition`; push two more and `deliver()`; assert `delivered` count is unchanged (the subscriber saw nothing new). Switch to `.reorder(seed: 42)`; push five ops and `deliver()`; assert all five eventually appear in `delivered` but not necessarily in emission order — **sort both the emitted and delivered sets by `LoggedOp.opId` and assert equality** (this is exactly what `opId` being the transport's sort key buys us). Switch to `.lossy(dropRate: 1.0)`; push ops and `deliver()`; assert nothing new appears in `delivered`. This set of four mode checks is the foundation on which the convergence fuzz (a later ticket) will build its random-network harness.

### Backend (real-path integration)

The real-path check for this ticket is narrow and intentional: it proves that `ProcessTmuxControl` — the real implementation backed by an actual tmux subprocess — satisfies the same protocol contract as the fake, without any bypass of the production code path.

The check: if `TmuxLocator.resolve()` returns `nil` (tmux not installed on the CI machine), skip gracefully and record `tmux_absent=true` in the manifest. If tmux is present: instantiate `ProcessTmuxControl` with the resolved path. Call `newSession(name: "continuum-substrate-check", cwd: "/tmp", innerCommand: nil)`. Assert a non-empty pane id is returned. Call `isAlive(paneTarget: returnedId)` and assert `true`. Call `killSession(name: "continuum-substrate-check")`. Call `isAlive(paneTarget: returnedId)` again and assert `false`. Record `pane_id`, `isAlive_before`, `isAlive_after`, and elapsed time in the manifest — never `{passed: true}`.

This check lives in `ContinuumRevivedCoreChecks` behind the same `TmuxLocator.resolve() != nil` guard that later topology checks will use.

### UX (visual gate + dogfood snippet)

There is no UX surface in this ticket — it is a pure infrastructure change invisible to the user. No visual gate is required. The dogfood verification is behavioral: after this ticket lands, open the app, create a terminal tile in a project zone, and confirm the tile appears and functions identically to before. The substrate change must be transparent; if anything visible changed, something was broken in the wiring.

## Execution mode

**Autonomous.** The logic checks are pure and deterministic; the real-path check is self-contained against a local tmux installation and gracefully skips when absent. There is no UI surface to gate and no cloud account or device to provision. A CI matrix that runs `ContinuumRevivedCoreChecks` fully proves this ticket.

## Done when

- [ ] `OpId { lamport: UInt64; replica: UUID }` and `LoggedOp { opId: OpId; payload: Data }` are defined in `ContinuumRevivedCore` with the field names from SYNC-MODEL.md, `OpId` comparing `(lamport, replica)` lexicographically; the transport carries `LoggedOp` and never references the spatial `Op` enum.
- [ ] `TmuxControl` protocol is defined in `ContinuumRevivedCore` with the operations listed above (newSession, newWindow, killWindow, killSession, detachSession, isAlive, paneCurrentPath, listSessions).
- [ ] `InMemoryTmuxControl` implements `TmuxControl`, records every call in `log`, manages `sessions` and `livePanes` entirely in memory, and returns deterministic pane ids.
- [ ] `ProcessTmuxControl` implements `TmuxControl`, takes `tmuxPath: String` at init (resolved by the caller via `TmuxLocator.resolve()`), uses `TmuxSession.sessionName`/`TmuxSession.wrap` for argv construction, and invokes `Process` for each operation.
- [ ] `Clock` protocol is defined with `now() -> Date`; `SystemClock` and `FakeClock` are implemented; `FakeClock.advance(by:)` is the only way time moves in tests.
- [ ] `Host` protocol is defined with `control(for: HostIdentity) throws -> any TmuxControl`; `HostIdentity` (`.localhost`, `.sshForward(host:)`) and `HostError.unknownHost(_:)` are defined; `FakeHost.register(_:for:)` seeds controls and `control(for:)` throws `HostError.unknownHost` on an unregistered identity.
- [ ] `SyncTransport` protocol is defined with exactly `push(_:)` and `subscribe(_:) -> SubscriptionToken`; `FakeSyncTransport` implements those two plus a **test-only, non-protocol** `deliver()` that applies all four `TransportMode` cases deterministically (seeded PRNG for `.reorder`/`.lossy`) and fans delivered ops to registered subscribers.
- [ ] No new file in the topology or observer layers contains a bare `Date()` call; any such site receives a `clock: any Clock` parameter with `SystemClock()` as the default argument.
- [ ] `TmuxSession.swift` and `TmuxLocator` (lines 8–73 of `TmuxSession.swift`) are unchanged — they remain pure static functions.
- [ ] The four logic check suites pass in `ContinuumRevivedCoreChecks` with no flakiness across three consecutive runs (the `.reorder(seed:)`/`.lossy` checks are deterministic by construction).
- [ ] The real-path check passes when tmux is present (manifest records measured `pane_id`, `isAlive_before=true`, `isAlive_after=false`) and skips cleanly when tmux is absent (`tmux_absent=true` in manifest).
- [ ] The app builds and all existing checks still pass after the retrofit.

## Depends on / unblocks

This ticket has no dependencies — it is a standalone phase-0 foundation that touches no in-flight work. It creates its own minimal `OpId`/`LoggedOp` rather than depending on the not-yet-existent `ContinuumRevivedSync` target.

It directly unblocks the project session naming and ownership work (which needs `TmuxControl` to prove session spawn and lifecycle in the check harness), the idle reaper (which needs `FakeClock` to exercise its detach-after-idle threshold), the convergence fuzz (which needs `FakeSyncTransport` in partition and reorder modes and `OpId` as the total-order key), and the invariant spine harness (which wires the I1–I8 checks and needs all four substrates to run its full suite). Every subsequent phase-1 ticket that touches session spawn or teardown will import `InMemoryTmuxControl` from day one.

When the `ContinuumRevivedSync` target (D3) lands, it either re-homes `OpId`/`LoggedOp` (Core re-exports them) or supersedes `LoggedOp` with the spike's `LoggedOp { opId; op: Op }` — a documented, non-breaking swap behind the unchanged `SyncTransport` protocol, since the transport only ever touches `opId` and treats the rest as opaque.

## Watch out for

**The make-or-break risk: `InMemoryTmuxControl` must faithfully model the real tmux invariant that pane ids are stable across detach/reattach but disappear on `kill-window`.** If the fake lets a "killed" pane id return `isAlive: true`, the topology tickets will write logic that silently diverges from real tmux behavior and the bugs won't surface until a needs-substrate check. The fake's `livePanes` dictionary must mark panes as `isAlive: false` (not remove them) on `killWindow`, so the distinction between "target we've never seen" and "target that was alive and is now dead" is preserved. Tests must assert both cases explicitly.

**`FakeSyncTransport.deliver()` must never leak onto the `SyncTransport` protocol.** It is a test affordance only. If a production caller ever reaches for `deliver()`, it means real code assumed manual flush control that the CloudKit transport (D4) does not offer — that is a design bug, not a missing method. Keep `deliver()` off the protocol and only on the concrete fake.

**Keep the op envelope minimal and op-agnostic.** Do not import or reference the spatial `Op` enum from the transport or `LoggedOp` — the whole point is that the transport carries opaque bytes keyed by `OpId`. Pulling `Op` in here would prematurely couple this standalone ticket to the sync module it is meant to precede.

**Stop if `TmuxLocator.resolve()` returns non-nil in CI but `ProcessTmuxControl.newSession` fails.** This almost certainly means a tmux version incompatibility with the `-P -F '#{pane_id}'` flag combination; do not paper over it with a skip — diagnose and fix the real-path check first.

**Do not leak `ProcessTmuxControl` into `ContinuumRevivedCore` in a way that pulls `Foundation.Process` into the module's public API.** Keep `ProcessTmuxControl` in an internal or separate file; the protocol itself stays public. The fake is the public test entry point.

**The wall-clock ban applies only to new code in the topology, observer, and transport layers.** Do not audit and refactor existing callers like `RunArtifactsWatcher` or `AtomicWriter` — those are pre-existing and out of scope. The ban is a forward-looking constraint enforced by code review on new files, not a retroactive refactor.
