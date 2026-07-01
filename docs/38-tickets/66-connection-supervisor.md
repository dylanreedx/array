# Connection supervisor — reconnect state machine for the iOS observer and remote-attach control channel

## What this delivers

After this ticket, the iOS observer and the remote-attach control path both have a single, principled owner of their connection lifecycle. A `ConnectionSupervisor` actor manages the full reconnect state machine: it drives the link from the initial socket open through an initial config round-trip before ever declaring `connected`, executes an exponential backoff schedule of `[1, 2, 4, 8, 16]` seconds with a 30-second stability reset, holds a monotonically increasing `generation` integer that subscribers use to revalidate finite fetches after reconnect, and exposes an `AsyncStream<ConnectionState>` that the UI and every durable subscription can observe.

Every durable subscription — "give me the live activity projection for this host" — is wired as a `switchMap` over the supervisor's current `RemoteSession`. When the supervisor reconnects and publishes a replacement session, all subscriptions silently re-establish against the new one: the call sites see no error and carry no reconnect logic of their own. The supervisor is the only retry owner on the entire control path; individual RPCs carry no per-call retry policy.

An offline snapshot cache means the UI renders stale-but-correct data while the link is down, and a monotonic sequence guard prevents a fast-reconnect race from overwriting fresh live data with a slightly older cached projection. The system degrades gracefully: a dropped link moves the UI to `stale`, never to `unknown` or fabricated state.

## How it fits

The connection supervisor is the client-side runtime engine for Phase 6's multi-device story. It consumes the `SyncTransport` seam — specifically the `connectionState: AsyncStream<ConnectionState>` signal that the transport emits — and sits above it, turning raw link events into a structured state machine the rest of the app can reason about. On the iOS side it is the bridge between "the CloudKit subscription fired" and "the activity tree is live and trustworthy." On the Mac side it is the equivalent bridge for the remote-attach control channel over SSH.

This ticket's direct predecessor is the `SyncTransport` seam, which establishes the `SyncTransport` protocol and the `FakeSyncTransport` adversarial fake. The supervisor consumes `SyncTransport.connectionState` and drives reconnect by calling back into the transport's underlying socket or SSH channel. The `FakeSyncTransport`'s `goOffline`/`reconnect` API is exactly the adversarial harness the supervisor's logic checks exercise — the seam was designed with this ticket in mind.

The supervisor also depends on the `Scope` OptionSet model, which establishes that the iOS link carries only `.observe` scope: the supervisor manages this scoped session and must refuse to publish a `RemoteSession` whose scope exceeds what was negotiated. The `generation` integer the supervisor publishes feeds the activity projection's revalidation gate: when `generation` increments, any component holding a generation-keyed snapshot re-fetches; while `generation` is `nil` (offline), those components suspend rather than error.

What this ticket directly unblocks: the iOS observer app, which cannot be built until there is a supervisor to bind its views to; the APNS push service, which needs a live session to deliver to; and the deep-link validation work, which needs to know whether the link is live before navigating.

## The approach

The supervisor is a Swift `actor` named `ConnectionSupervisor`, with an `AsyncStream<ConnectionState>`-based signal bus and a `run()` method that the host actor launches as a long-lived `Task`. The state machine mirrors the t3code `EnvironmentSupervisor` shape almost exactly, ported to Swift Concurrency. All timer waits are interruptible: the supervisor races a `sleep` against the next signal from its internal `AsyncStream<Signal>` so that a wakeup (network change, explicit retry request, credential refresh) cancels the backoff immediately rather than waiting out the countdown.

The "connected only after socket-open AND initial config RPC" gate is the load-bearing correctness rule. Opening the socket is necessary but not sufficient. The supervisor calls a cheap readiness probe — a `tmux list-sessions -F` round-trip over the SSH channel, which doubles as the `SessionTopologySnapshot` reconciliation oracle — and only transitions to `.connected` after that probe returns a valid response within the 15-second establishment timeout. A socket that opens but whose host never answers the probe is treated as a transient failure and goes to backoff; it does not briefly flash `.connected` to subscribers.

Auth runs on every path, including loopback. The supervisor holds a `Scope` value established at pairing time and enforces it before publishing a session: if the negotiated scope exceeds what the stored token grants, the supervisor enters `.blocked` state and parks until an external wakeup (a re-pairing flow). Loopback does not skip this check.

The offline snapshot cache is a `Codable` file written to the iOS app's `Application Support` directory (a `ContinuumActivitySnapshot` — the same type that the activity projection over transport produces). Writes are debounced 500 ms and guarded by a monotonic `snapshotSequence` integer: an incoming update that carries a sequence number less than or equal to the last written sequence is silently dropped, preventing a stale cache from clobbering fresher live data on a fast reconnect. Reads happen at app launch before the supervisor's `run()` loop fires, so the UI can render immediately in the offline state.

All five backoff delays, both 15-second timeouts, and the 30-second stability reset are user-configurable persisted settings with defaults matching the t3code constants. They live in the app's settings store under the `ConnectionSupervisor` settings group, exposed in Settings as a single "Reconnect aggressiveness" preset picker (`conservative | balanced | aggressive`, translating to scaled versions of the base constants) rather than seven individual raw-seconds knobs. An owner who wants raw control can hold-option to reveal the individual fields.

## Where it lives

All new code for this ticket goes in `Sources/ContinuumRevivedCore/` unless explicitly noted otherwise.

**New files:**

- `Sources/ContinuumRevivedCore/ConnectionSupervisor.swift` — the `ConnectionSupervisor` actor, `ConnectionPhase` enum, `ConnectionState` struct, `ConnectionSignal` enum, `AttemptOutcome` enum, and `ConnectionSupervisorSettings` struct.
- `Sources/ContinuumRevivedCore/RemoteSession.swift` — the `RemoteSession` protocol and its `ReadinessProbe` associated type; the SSH-backed `SSHRemoteSession` implementation lives here for the Mac, with the iOS `CloudKitRemoteSession` added when the iOS observer ships.
- `Sources/ContinuumRevivedCore/ActivitySnapshotCache.swift` — the `ActivitySnapshotCache` struct wrapping the debounced `Codable` write-path and the sequence-guarded read/update interface.

**Existing seams this ticket reads but does not modify:**

- `Sources/ContinuumRevivedCore/ProjectStore.swift:76` — `ProjectStore` and its `layout` property establish the on-disk layout pattern this ticket mirrors for the snapshot cache. The cache does not reuse `ProjectStore` directly (it targets the iOS app container, not a project root), but follows the same `AtomicWriter`-backed pattern.
- `Sources/ContinuumRevivedCore/ProjectStore.swift:157` — `listSessions()` reads on-disk descriptors, confirmed to read from file (not from a live tmux query). The supervisor's readiness probe fills this gap for the remote case: `tmux list-sessions -F` over the SSH channel is the live oracle the supervisor calls; `listSessions()` is the on-disk counterpart the Mac-local path already has.

**Types consumed from neighboring modules (not modified):**

- `SyncTransport.ConnectionState` from `ContinuumRevivedSync/SyncTransport.swift` — the supervisor observes this stream from the underlying transport and uses it as one of its signal sources.
- `ActivityProjection` from the activity projection over transport ticket — the supervisor's `RemoteSession` carries a reference to the projection for the currently live session.
- `Scope` from `ContinuumRevivedCore/ScopeModel.swift` (the `Scope` OptionSet model ticket) — the supervisor enforces that a published session's scope does not exceed the pairing grant.

## Implementation breadcrumbs

```swift
// ConnectionPhase is what the UI observes. It is a closed set: there is no
// "unknown" phase. The supervisor always knows exactly which phase it is in.
enum ConnectionPhase: Equatable, Sendable {
    case available      // desired == false; supervisor is parked
    case offline        // network is down; not consuming a retry attempt
    case connecting     // attempt in progress
    case backoff        // waiting before next attempt; retryAt is set
    case connected      // socket open AND readiness probe passed
    case blocked        // auth/config failure; only an external wakeup can proceed
}

struct ConnectionState: Equatable, Sendable {
    var desired: Bool
    var network: NetworkStatus          // .unknown | .offline | .online
    var phase: ConnectionPhase
    var attempt: Int
    var generation: Int?                // nil while never-connected or offline
    var lastFailure: ConnectionError?
    var retryAt: Date?
}

// Signals fed into the supervisor's internal queue. The supervisor blocks on
// this queue between attempts; any signal interrupts the wait immediately.
enum ConnectionSignal: Sendable {
    case connectRequested
    case disconnectRequested
    case retryNow
    case networkChanged(NetworkStatus)
    case wakeup                         // credential refresh, foreground resume, etc.
}

actor ConnectionSupervisor {
    // Configurable constants — all user-settable, never hardcoded at call sites.
    private static let defaultRetryDelays: [Duration] = [
        .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16)
    ]
    private static let defaultEstablishTimeout: Duration = .seconds(15)
    private static let defaultProbeTimeout: Duration    = .seconds(15)
    private static let defaultBackoffReset: Duration    = .seconds(30)

    private(set) var state: ConnectionState
    private(set) var session: RemoteSession?    // nil when not connected

    private var settings: ConnectionSupervisorSettings
    private var intent = (desired: false, network: NetworkStatus.unknown)
    private let signals: AsyncStream<ConnectionSignal>
    private let signalContinuation: AsyncStream<ConnectionSignal>.Continuation
    private let driver: any ConnectionDriver    // injected; SSH-backed in production, fake in tests

    // The run() loop. Launch once as a long-lived Task from the owner actor.
    func run() async {
        var failureCount = 0
        for await _ in AsyncStream<Void>.justOnce() {  // enter the loop
            while true {
                if !intent.desired {
                    setPhase(.available); clearSession()
                    await waitForSignal(); continue
                }
                if intent.network == .offline {
                    setPhase(.offline); clearSession()   // does NOT increment failureCount
                    await waitForSignal(); continue
                }

                let outcome = await runAttempt(generation: (state.generation ?? 0) + 1)
                switch outcome {
                case .connectedThenClosed(let stable):
                    let newGen = (state.generation ?? 0) + 1
                    state.generation = newGen
                    if stable >= settings.backoffReset { failureCount = 0 }
                    // fall through to backoff
                    fallthrough
                case .failed:
                    failureCount += 1
                    let idx = min(failureCount - 1, settings.retryDelays.count - 1)
                    let delay = settings.retryDelays[idx]
                    let retryAt = Date.now.addingTimeInterval(delay.asSeconds)
                    state = state.with(phase: .backoff, retryAt: retryAt)
                    await raceFirstSignal(or: sleep(delay))
                case .blocked(let err):
                    state = state.with(phase: .blocked, lastFailure: err)
                    clearSession()
                    await waitForSignal()   // only an external wakeup exits .blocked
                case .interrupted:
                    continue
                }
            }
        }
    }

    // The gate: the supervisor only declares .connected after BOTH conditions hold.
    private func runAttempt(generation: Int) async -> AttemptOutcome {
        state = state.with(phase: .connecting)
        let socket: any RemoteSocket
        do {
            socket = try await withTimeout(settings.establishTimeout) {
                try await driver.openSocket()
            }
        } catch { return .failed }

        // Readiness probe: a cheap round-trip that proves the host is responsive.
        // For SSH: `tmux list-sessions -F #{session_name}` — also serves as the
        // SessionTopologySnapshot reconciliation oracle (reuse the result).
        let probe: ReadinessProbeResult
        do {
            probe = try await withTimeout(settings.probeTimeout) {
                try await socket.readinessProbe()
            }
        } catch is BlockedError { return .blocked(ConnectionError.authFailed) }
        catch { socket.close(); return .failed }

        // Only now do we publish the session to subscribers.
        let newSession = RemoteSession(socket: socket, probe: probe, scope: settings.scope)
        guard newSession.scope.isSubset(of: settings.grantedScope) else {
            socket.close(); return .blocked(ConnectionError.scopeExceeded)
        }
        publishSession(newSession, generation: generation)
        state = state.with(phase: .connected, generation: generation)

        let connectedAt = ContinuousClock.now
        // Race involuntary close against a health probe on app-active wakeup.
        await raceFirstSignal(
            or: socket.closed,
            or: monitorProbe(socket: socket)
        )
        clearSession()
        let stableDuration = ContinuousClock.now - connectedAt
        return .connectedThenClosed(stable: stableDuration)
    }
}
```

```swift
// Durable subscription pattern — the switchMap in Swift.
// Sessions is the supervisor's `session` property wrapped in an AsyncStream
// that yields a new value each time `publishSession` or `clearSession` is called.

func durableActivityStream(
    sessions: AsyncStream<RemoteSession?>
) -> AsyncStream<ActivityProjectionEvent> {
    AsyncStream { continuation in
        let pump = Task {
            var inner: Task<Void, Never>?
            for await session in sessions {
                inner?.cancel()
                guard let session else { continue }  // offline → nothing
                inner = Task {
                    do {
                        for try await event in session.activityProjection.tail() {
                            continuation.yield(event)
                        }
                    } catch is TransportError {
                        // The socket died. The supervisor is already reconnecting;
                        // do nothing — the next session emission will restart this loop.
                    } catch {
                        continuation.yield(.error(String(describing: error)))
                    }
                }
            }
            inner?.cancel()
        }
        continuation.onTermination = { _ in pump.cancel() }
    }
}
```

```swift
// ActivitySnapshotCache — monotonic sequence guard, debounced write.
struct ActivitySnapshotCache {
    private let fileURL: URL
    private var lastWrittenSequence: Int = -1
    private var pendingWriteTask: Task<Void, Never>?

    // Update only if the incoming sequence is strictly newer.
    mutating func update(_ snapshot: ContinuumActivitySnapshot) {
        guard snapshot.snapshotSequence > lastWrittenSequence else { return }
        lastWrittenSequence = snapshot.snapshotSequence
        pendingWriteTask?.cancel()
        pendingWriteTask = Task {
            try? await Task.sleep(for: .milliseconds(500))  // 500 ms debounce
            guard !Task.isCancelled else { return }
            try? JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
        }
    }

    func load() -> ContinuumActivitySnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(ContinuumActivitySnapshot.self, from: data)
    }
}
```

The `generation` integer from a newly-connected supervisor increments by one on each successful reconnect. Components that hold generation-keyed snapshots (e.g. a list of terminals fetched on the previous session) observe the `generation` stream and re-fetch when it changes. While `generation` is `nil` (never connected, or currently offline), those components suspend rather than error — they show stale cached data, not a spinner or an error state.

## How we test it

### Logic

All logic checks live in `ContinuumRevivedCoreChecks` and are fully in-process: the `FakeSyncTransport`'s `goOffline`/`reconnect` API serves as the network adversary, a `FakeConnectionDriver` replaces the SSH-backed driver, and a fake clock (from the injectable substrates ticket) controls all `Duration` values so no check has a real sleep.

**State machine transitions.** Construct a supervisor with `desired = false`. Assert phase is `.available`. Send `connectRequested`. Assert phase transitions to `.connecting` and then to `.connected` (after the fake driver resolves both the socket-open and the probe). Send `disconnectRequested`. Assert phase returns to `.available` and `session` is `nil`. Assert `generation` did not change (a deliberate disconnect is not a failure).

**Backoff schedule and reset.** Configure the fake driver to fail the probe five times before succeeding. Drive the supervisor with a fake clock. Assert the delay between attempts follows exactly `[1, 2, 4, 8, 16]` seconds (indexed by `failureCount - 1`, clamped to the last entry). Assert that when the sixth attempt succeeds and the connection remains stable for 30 simulated seconds, the next failure resets `failureCount` to zero and the next backoff starts at 1 second again. Assert that a connection that only lasts 29 simulated seconds does not trigger the reset.

**Blocked state: no timer.** Configure the fake driver to throw `BlockedError` (auth/config failure) on the probe. Assert the supervisor enters `.blocked` and does not schedule any retry timer. Assert it remains in `.blocked` through ten fake-clock ticks. Send a `wakeup` signal. Assert it re-enters `.connecting` and proceeds.

**Offline: no consumed attempt.** Set `network = .offline` before the supervisor starts. Assert phase is `.offline` and `failureCount` remains zero. Flip to `network = .online`. Assert the supervisor immediately begins a `.connecting` attempt with `attempt == 1` — no backoff step was consumed by the offline period.

**Involuntary close and reconnect.** Establish a connection with the fake driver. Simulate an involuntary socket close (the fake driver's socket fires its `closed` continuation). Assert the supervisor transitions back through `.backoff` and then to `.connected` on the next attempt. Assert `generation` incremented by exactly one. Assert that any durable subscription that was consuming the previous session's event stream is cancelled and re-started on the new session — verified by asserting the subscription emits a fresh event from the new fake session immediately after the transition.

**switchMap subscription resets cleanly.** Set up two fake sessions with distinct event streams. Establish connection on the first. Consume two events via a durable subscription. Force an involuntary close. Let the supervisor reconnect to the second. Assert the durable subscription emits events from the second session, with no events from the first appearing after the switch, and no gap in delivery — the snapshot from the second session's reconnect arrives before any tail events.

**Sequence guard on snapshot cache.** Write a `ContinuumActivitySnapshot` with `snapshotSequence = 10`. Immediately attempt to update with `snapshotSequence = 9`. Assert the file on disk still contains sequence 10. Attempt with `snapshotSequence = 11`. Advance the fake clock past the 500 ms debounce. Assert the file now contains sequence 11.

**Scope enforcement.** Construct a supervisor with `settings.grantedScope = [.observe]`. Configure the fake driver's probe to negotiate a session with scope `[.observe, .steer]`. Assert the supervisor returns `.blocked(ConnectionError.scopeExceeded)` from `runAttempt` and does not publish the session.

**Generation revalidation gate.** Construct a generation-keyed query component that observes the supervisor's `generation` stream. Assert it re-fetches when `generation` increments from 1 to 2. Assert it suspends (not errors) when `generation` is `nil`. Assert it does not re-fetch when the supervisor transitions within the same generation (e.g. `.connecting` → `.connected` on a first attempt).

### Backend

The backend check exercises the supervisor against a real SSH subprocess — not a fake — targeting a `tmux list-sessions -F` probe on the local machine (where tmux is guaranteed present because the app depends on it). This is not a happy-path-bypass check: the real `Process` API is used, a real TTY is forked, and the probe result is validated to contain at least the session name format `continuum-proj-` (or empty if no project session exists yet, which is also valid). This proves the SSH-channel probe composes correctly with the OS's process substrate.

The check stands up a real `ConnectionSupervisor` with a real `SSHConnectionDriver` targeting `localhost` (not a mock). It connects, asserts the supervisor reaches `.connected`, reads the `ReadinessProbeResult` from the session, and asserts it deserializes cleanly to a `SessionTopologySnapshot`. It then kills the fake socket (by closing the subprocess's stdin) and asserts the supervisor re-enters `.backoff` within 15 seconds. It does not wait for a successful reconnect (that would require tmux to still be alive, which it may not be in CI) — it only proves the involuntary-close detection fires. This check is gated on `tmux` being present in `$PATH` and is skipped with an explanatory message if it is not.

The snapshot cache backend check writes a `ContinuumActivitySnapshot` to a real temporary directory via `ActivitySnapshotCache.update`, waits for the debounce, and reads it back via `ActivitySnapshotCache.load`. It asserts the round-trip is clean and that the loaded snapshot's `snapshotSequence` matches the written value. It also asserts that writing a lower-sequence snapshot after a higher-sequence one leaves the file unchanged — the sequence guard holds end-to-end through the real file system.

### UX

The supervisor has no direct canvas UI, so there is no canvas dogfood snippet for this ticket alone. However, its output — the `ConnectionState` stream — feeds the iOS fleet list and the remote-status indicator in the Mac dock. The visual gate for this ticket is satisfied by the iOS observer app ticket, which renders the connection state as a visual badge on the fleet list header and is the first place a human sees the supervisor's output. The supervisor ticket's UX obligation is that its `ConnectionState` values map cleanly to the iOS observer's three-state projection: `.available | .offline | .backoff` → `disconnected`, `.connecting` → `synchronizing`, `.connected` → `ready`.

Dogfood snippet (to be run once the iOS observer is live): Open the app on iPhone. Force-quit the Mac host. The fleet list header should transition from `ready` (green) to `synchronizing` (blue spinner) within 15 seconds (the probe timeout), then to `disconnected` (gray) after the first backoff cycle completes. Relaunch the Mac host. The header should return to `ready` within the backoff schedule — at most 1 second on the first reconnect attempt after a short offline period, up to 16 seconds after repeated failures. The tile statuses in the list remain visible and stale-marked throughout; they do not blank out.

## Execution mode

Autonomous. The supervisor's state machine is a pure `actor` with injected dependencies: the `FakeConnectionDriver` replaces the SSH-backed driver, the fake clock controls all `Duration` waits, and the `FakeSyncTransport`'s adversarial API drives all offline/reconnect/partition scenarios. Every logic check is seeded and deterministic. The backend check targets localhost tmux and has a clean skip condition if tmux is absent. No CloudKit account, no real iOS device, and no human eye is required to reach a verdict. The check manifest carries measured values — phase-transition latency at each backoff step, snapshot cache write latency, durable-subscription reconnect gap in ticks — so the results are falsifiable without reading them.

## Done when

- [ ] `ConnectionSupervisor` actor is defined in `Sources/ContinuumRevivedCore/ConnectionSupervisor.swift` with `run()`, `state: ConnectionState`, `session: RemoteSession?`, and `send(_:)` for injecting signals; compiles under Swift 6.0 strict concurrency with no `@unchecked Sendable` workarounds.
- [ ] `ConnectionPhase` covers all six states (`available`, `offline`, `connecting`, `backoff`, `connected`, `blocked`) and the UI projection to three states (`disconnected`, `synchronizing`, `ready`) is a pure function over `ConnectionPhase` with no switch-default fallthrough.
- [ ] The "connected only after socket-open AND readiness probe" gate is implemented in `runAttempt`; a logic check proves a socket that opens but whose probe times out after 15 simulated seconds does not transition to `.connected`.
- [ ] Backoff schedule is exactly `[1, 2, 4, 8, 16]` seconds (clamped to last entry beyond five failures); the 30-second stability reset is proven by the logic check; all five delays and both timeouts are stored in `ConnectionSupervisorSettings` backed by the settings store, not hardcoded at call sites.
- [ ] `.blocked` state parks with no timer and exits only on a `wakeup` signal; proven by the logic check asserting ten fake-clock ticks produce no state change.
- [ ] Offline periods do not consume a retry attempt; `failureCount` is unchanged across an offline-then-online cycle; proven by the logic check.
- [ ] Auth-scope enforcement fires in `runAttempt` before the session is published; a logic check with `grantedScope = [.observe]` and a negotiated scope of `[.observe, .steer]` returns `.blocked(ConnectionError.scopeExceeded)`; loopback is not exempt.
- [ ] Durable subscription pattern is implemented as a `switchMap`-over-sessions; a logic check proves the inner task is cancelled and restarted on reconnect, with no events from the previous session leaking through and no gap before the first event from the new session.
- [ ] `ActivitySnapshotCache` writes are debounced 500 ms, guarded by monotonic `snapshotSequence`, and backed by an atomic file write; all three properties are proven by the backend cache check against a real temporary directory.
- [ ] `generation` is `nil` until first successful connection, increments by one on each successful reconnect, and revalidation-aware components suspend (not error) when `generation` is `nil`; proven by the generation gate logic check.
- [ ] The backend check against localhost tmux passes (or skips cleanly with a logged reason when tmux is absent from `$PATH`); it proves the supervisor reaches `.connected` and detects an involuntary close without hanging.
- [ ] Check manifest records measured values: phase-transition latency at each backoff step (fake clock ticks), durable-subscription reconnect gap (ticks from close to first new-session event), and snapshot cache write latency (milliseconds on real disk); no `{passed: true}` entries.
- [ ] No files in `Sources/ContinuumRevivedCore/ProjectStore.swift` were modified by this ticket; confirmed by a clean `git diff Sources/ContinuumRevivedCore/ProjectStore.swift`.

## Depends on / unblocks

This ticket depends on the `SyncTransport` seam for the `ConnectionState` enum shape and the `connectionState: AsyncStream<ConnectionState>` signal that the underlying transport emits. It depends on the transport fuzz and soak having confirmed that the `FakeSyncTransport`'s `goOffline`/`reconnect` API behaves correctly under adversarial delivery — the supervisor's logic checks reuse that same API, and a bug in the fake would produce false green results here. It depends on the `Scope` OptionSet model for the scope enforcement in `runAttempt`.

The supervisor directly unblocks the iOS observer app, which binds its fleet list to the supervisor's `ConnectionState` stream and its durable activity projection subscription to the supervisor's `session` property. It also unblocks the APNS push service, which needs a live `RemoteSession` to know whether a push should go to the Mac (local detection) or the VPS (remote detection), and deep-link validation, which needs to know whether the link is live before navigating to an agent detail screen. The notify categories setting ticket also depends on the supervisor being present, because the setting controls which `ConnectionState`-gated events fire a push.

## Watch out for

**The readiness probe must be the same call-site as the topology reconciliation oracle.** The `tmux list-sessions -F` probe was chosen precisely because it doubles as the `SessionTopologySnapshot` input. If an implementer substitutes a cheaper ping (e.g. a no-op `echo` over SSH), the supervisor will declare `.connected` before the host's topology is queryable, and the activity projection's first fetch will race the host's tmux daemon coming up. Do not substitute a ping. The probe must return a parseable `SessionTopologySnapshot` (even an empty one), and that result must be stored on the `RemoteSession` so the first fetch can use it without a second round-trip.

**`generation` is an opaque epoch, not a timestamp or a sequence.** It is an integer that increments on each successful reconnect. Components that depend on it must not compare it to wall clock values, infer elapsed time from it, or assume it is monotonically gapless across app restarts (the supervisor starts from `nil` each launch). The only valid operations on `generation` are: is it `nil` (offline/never connected), has it changed since last observed (re-fetch), and is it the same as when I made a previous request (result is still valid for this session). Anything else is a design smell.

**The `FakeConnectionDriver`'s socket must fire `closed` reliably, not just stop emitting events.** A common implementation mistake is to have the fake socket "go dead" by ceasing to yield events, rather than explicitly firing its `closed` continuation. The supervisor races against `socket.closed`; if that continuation never fires, the supervisor hangs in `.connected` indefinitely even when the fake is "offline." The fake must provide an explicit `kill()` method that fires `closed` synchronously. Assert this in the first logic check by calling `driver.killSocket()` and asserting the supervisor reaches `.backoff` within zero fake-clock ticks.

**The 500 ms debounce on snapshot cache writes must use the injected fake clock, not `Task.sleep`'s wall clock.** If the debounce calls `Task.sleep(for: .milliseconds(500))` directly, the sequence guard logic check will have a real 500 ms sleep in it, making the check slow and fragile in CI. Thread the fake clock through `ActivitySnapshotCache` the same way it is threaded through every other time-dependent component. The backend check — which runs against the real file system — is the one place where real elapsed time is acceptable.

**Scope enforcement must reject a session before it is published, not after.** The `publishSession` call in `runAttempt` must come after the scope check, not before. If the session is published first and then the scope check fires, durable subscriptions will briefly attach to an over-scoped session before the supervisor tears it down. The check that proves scope enforcement (the scope logic check above) must assert that `session` is `nil` throughout the `.blocked` transition — not that it was set and then cleared.

**A `.blocked` state caused by scope violation is distinct from one caused by auth failure.** Both park the supervisor with no timer, but the recovery path is different: a scope violation requires a re-pairing flow (which issues a new token with the correct scope); an auth failure may be recoverable by re-entering credentials. The `ConnectionError` enum must carry both cases, and the UI that observes `.blocked` must surface the right recovery affordance. Do not collapse them to a single `blocked` error.

**Stop if the `RemoteSession` protocol requires modifying `SyncTransport`.** The supervisor's `RemoteSession` wraps a transport socket and a readiness probe result. If the shape of this protocol turns out to require changes to the `SyncTransport` interface — adding a method, changing an `AsyncStream` type — stop and surface that dependency. The `SyncTransport` seam is settled; the connection supervisor adapts to it, not the other way around.
