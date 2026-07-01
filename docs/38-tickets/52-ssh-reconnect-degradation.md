# SSH link drop: keepalive detection, stale state, and graceful reconnect

## What this delivers

When the SSH link to a remote host drops mid-session — whether because the VPS went away, the
laptop slept, the network changed, or the carrier silently killed an idle TCP connection — the
tile never shows wrong data. It transitions immediately to a `stale` status with a hollow-gray
indicator, pauses all observer polling so no stale reads can overwrite the last-known-good
snapshot, and begins a bounded retry loop. The moment the link is re-established it re-runs
an initial readiness probe, confirms the remote tmux session is still there, resumes the
observer, and snaps back to `working`/`idle`/`needsAttention` from fresh evidence. The user
sees an honest status at all times: `stale` means "we lost contact and are trying," never
silence or — worse — a fabricated `working` that is actually a cached artifact.

The system guarantee (from locked decision D9) is: **a dropped link makes status stale,
never wrong.** This ticket makes that guarantee mechanically enforced rather than aspirational.

## How it fits

The remote-attach real-path ticket establishes the `sshForward` reach path and the model
types — `Host`, `RemoteReach`, and the SSH-wrapped tmux attach command — that this ticket
builds on. It cannot proceed until those types exist and an ssh-wrapped attach is actually
working end-to-end. This ticket's job is solely the degradation and recovery behavior that
sits on top of that working substrate.

What this ticket unblocks: the Tailscale reach-path extension (which needs the same reconnect
machinery when a tailnet peer is temporarily unreachable), and any future iOS observer work
(the `ConnectionSupervisor` actor introduced here is the Swift-side port of the t3code
`EnvironmentSupervisor` that the iOS link will reuse verbatim).

The `AgentStatus.stale` case already exists in `AgentStatusEngine` and `TerminalSessionDescriptor`
(the engine's `tick()` applies `stale` after a `staleTimeout`). This ticket wires the SSH
drop-detection path so that going stale happens at keepalive time rather than waiting for the
engine's general timeout.

## The approach

The SSH connection carries `ServerAliveInterval=15` / `ServerAliveCountMax=3` in its option
string — already specified in the locked decisions. When those three consecutive unanswered
keepalives exhaust, the SSH client exits with a non-zero status. That process exit is the
drop signal.

On exit, a `ConnectionSupervisor` actor marks the link dropped, transitions the tile's
connection state to `.stale`, and pauses the observer. Pausing means: the FSEvents-over-ssh
polling loop stops issuing `ssh <host> cat <store>` calls, and the session observer for that
host stops emitting status updates. The last snapshot the observer delivered stays in place —
that is the "never wrong" half of the guarantee. The UI renders `AgentStatus.stale` (gray
hollow indicator) on every tile belonging to that host.

The supervisor then enters a retry loop using the exact backoff table from the t3code
`EnvironmentSupervisor`: `[1, 2, 4, 8, 16]` seconds, capped at 16 s, no maximum attempt
count, with a 30-second stability reset (a connection that stays up for 30 seconds resets the
failure counter so a genuinely-recovered link starts fresh rather than continuing to climb
the backoff table). The supervisor does not retry during network offline (`NWPathMonitor`
reporting unsatisfied) — offline does not consume an attempt.

A new attempt is "connected" only after **both** the SSH socket opens **and** an initial
readiness probe succeeds. The probe is a `tmux list-sessions -F '#{session_name}'` round-trip
over the new channel. A channel that opens but whose probe never answers within 15 seconds is
not connected — it is a failure and goes back to backoff. This two-gate rule (open + probe)
prevents a half-open TCP state from being declared healthy.

A connection that stays up for 30 seconds or more is marked stable and the failure counter
resets. An involuntary close (SSH process exit) goes to backoff and reconnects. A blocked
close (auth rejected, host key mismatch, `Permission denied`) parks without a timer — only a
user action (credential fix, explicit retry) unblocks it. A user-initiated disconnect marks
the link `available: false` and parks; it does not retry.

When the probe succeeds, the supervisor publishes the new live connection, the observer
resumes from the last snapshot sequence number, and all tiles on that host transition from
`stale` back to their freshly-derived status. The transition back must use live evidence —
the observer re-runs its derivation function from the new poll results, not from the cached
snapshot.

All thresholds are user-configurable with persisted defaults and a Settings entry each:
the five backoff steps (`[1, 2, 4, 8, 16]` s), the establish timeout (15 s), the probe
timeout (15 s), and the stability reset duration (30 s). The hardcoded values above are
the persisted defaults, not magic numbers burned in.

## Where it lives

**`Sources/ContinuumRevivedCore/TmuxSession.swift`** — add a static helper
`TmuxSession.remoteWrap(profile:host:tileId:sshPath:tmuxPath:)` that returns a `LaunchProfile`
with the SSH command as the outer process. The SSH option string must embed
`ServerAliveInterval=15 ServerAliveCountMax=3` via `-o` flags. This is a pure function
alongside the existing `TmuxSession.wrap` (line 12) and follows the same `LaunchProfile`
return shape. The existing `sessionName(tileId:)` (line 8) is reused as the tmux session
name on the remote host.

**`Sources/ContinuumRevivedCore/ConnectionSupervisor.swift`** — new file, `actor
ConnectionSupervisor`. Owns the retry loop, the `ConnectionState` struct, and the
`ConnectionPhase` enum. Has no UIKit/AppKit import — it is pure Core. Exposes an
`AsyncStream<ConnectionState>` for subscribers and a `connect()` / `disconnect()` /
`retryNow()` API.

**`Sources/ContinuumRevivedCore/RemoteReachConfig.swift`** — new file, `enum
ReconnectConfig` carrying the five thresholds as static computed properties reading from
`UserDefaults` with the persisted defaults. Pattern mirrors `TmuxPersistenceConfig` (line
78 of `TmuxSession.swift`).

**`Sources/ContinuumRevived/App/ZoneRuntimeController.swift`** — one `ConnectionSupervisor`
per remote `Host`. Created in `ZoneRuntimeController.init` when the project has a remote
host; the controller subscribes to `supervisor.stateStream` and calls
`setTileStale(hostId:) / clearTileStale(hostId:)` on the session observer when the phase
transitions to/from `.stale`. The `close()` method (line 78) disconnects the supervisor.
The `HydrationTier` machinery is unaffected — stale is an observer-level state, not a
hydration tier.

**`Sources/ContinuumRevivedCoreChecks/main.swift`** — pure logic checks added to the
existing check runner.

## Implementation breadcrumbs

### ConnectionPhase and ConnectionState (Core)

```swift
// Sources/ContinuumRevivedCore/ConnectionSupervisor.swift

public enum ConnectionPhase: Equatable, Sendable {
    case available    // desired == false; parked
    case offline      // network unsatisfied; parked, no attempt consumed
    case connecting   // attempt in flight
    case backoff(retryAt: Date)
    case connected
    case blocked(ConnectionBlockedReason)  // auth/hostKey; no timer, external wakeup only
    case stale        // drop detected; actively retrying (sub-state of backoff/connecting)
}

public enum ConnectionBlockedReason: Equatable, Sendable {
    case authRejected, hostKeyMismatch
}

public struct ConnectionState: Equatable, Sendable {
    public var phase: ConnectionPhase
    public var attempt: Int          // attempt number within the current connect desire
    public var generation: Int       // bumped on each successful (re)connection
    public var lastFailure: Date?
    public var retryAt: Date?        // non-nil while in backoff
}
```

### ConnectionSupervisor run loop (Core actor)

```swift
actor ConnectionSupervisor {
    private static let retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4),
                                                   .seconds(8), .seconds(16)]
    // Thresholds read from ReconnectConfig (UserDefaults) on each attempt start:
    // establishTimeout, probeTimeout, stabilityReset — NOT cached as constants here.

    private var state = ConnectionState(phase: .available, attempt: 0, generation: 0)
    private let continuation: AsyncStream<ConnectionState>.Continuation
    public  let stateStream: AsyncStream<ConnectionState>

    private var desired = false
    private var failureCount = 0
    private let driver: RemoteConnectionDriver  // injected; real impl = SSH process; fake = in-memory

    func run() async {
        while true {
            guard desired else { publish(.available); await waitForSignal(); continue }
            let networkOK = await checkNetworkPath()     // NWPathMonitor one-shot check
            guard networkOK else { publish(.offline); await waitForSignal(); continue }

            let outcome = await runAttempt()
            switch outcome {
            case .connectedThenClosed(let uptime):
                state.generation += 1
                if uptime >= ReconnectConfig.stabilityReset { failureCount = 0 }
                fallthrough
            case .failed:
                failureCount += 1
                let delay = Self.retryDelays[min(failureCount - 1, Self.retryDelays.count - 1)]
                let retryAt = Date.now.advanced(by: delay.timeInterval)
                publish(.backoff(retryAt: retryAt))
                // interruptible: a manual retryNow() signal cancels the sleep
                await raceFirstSignalOrSleep(delay)
            case .blocked(let reason):
                publish(.blocked(reason)); await waitForSignal()
            }
        }
    }

    private func runAttempt() async -> AttemptOutcome {
        publish(.connecting)
        // Gate 1: SSH process opens (driver.open throws on immediate exit / blocked error)
        let channel: RemoteChannel
        do {
            channel = try await withTimeout(ReconnectConfig.establishTimeout) {
                try await self.driver.open()
            }
        } catch let e as ConnectionBlockedError { return .blocked(e.reason) }
        catch { return .failed }

        // Gate 2: readiness probe — tmux list-sessions round-trip
        do {
            _ = try await withTimeout(ReconnectConfig.probeTimeout) {
                try await channel.probe()   // runs `tmux list-sessions -F '#{session_name}'`
            }
        } catch { channel.close(); return .failed }

        publish(.connected)
        let connectedAt = ContinuousClock.now

        // Race: voluntary disconnect signal vs involuntary SSH process exit
        await raceFirst(channel.closed, waitForSignal())   // channel.closed is async property
        channel.close()
        return .connectedThenClosed(uptime: ContinuousClock.now - connectedAt)
    }
}
```

### TmuxSession remote wrap (Core)

```swift
// TmuxSession.swift — alongside existing wrap()
public static func remoteWrap(
    profile: LaunchProfile,
    host: String,                 // e.g. "user@vps.example.com" or "100.x.y.z"
    tileId: UUID,
    sshPath: String,
    tmuxPath: String
) -> LaunchProfile {
    let name = sessionName(tileId: tileId)
    // Inline tmux command on the remote host — identical shape to local wrap()
    let remoteCommand = "\(tmuxPath) new-session -A -s \(name) -c \(profile.cwd)"
    return LaunchProfile(
        command: sshPath,
        arguments: [
            "-t",                           // force pty allocation (interactive)
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=accept-new",  // first-connect trust; locked to key thereafter
            host,
            remoteCommand
        ],
        cwd: profile.cwd,
        title: profile.title
    )
}
```

### ZoneRuntimeController wiring (App layer)

```swift
// ZoneRuntimeController — in init, after project is loaded:
if let remoteHost = project.host, remoteHost.reach != .localhost {
    let supervisor = ConnectionSupervisor(driver: SSHConnectionDriver(host: remoteHost))
    self.remoteSupervisor = supervisor
    Task { [weak self] in
        for await state in supervisor.stateStream {
            await self?.handleConnectionState(state, for: remoteHost.id)
        }
    }
    Task { await supervisor.run() }
    supervisor.connect()
}

// Handler: mark all tiles for this host stale/live based on phase
private func handleConnectionState(_ state: ConnectionState, for hostId: UUID) {
    let isStale = state.phase != .connected
    for runtime in runtimes where runtime.remoteHostId == hostId {
        if isStale {
            // Stop the observer from issuing new ssh reads for this host.
            // Freeze the last-known AgentStatus rather than overwriting it.
            sessionObserver.pause(hostId: hostId)
            // Force .stale on the AgentStatusEngine for this tile so the UI
            // renders the gray hollow immediately, without waiting for staleTimeout.
            projectStore.forceStale(tileId: runtime.tileId)
        } else {
            // Resume observer; it will re-poll and call ingest() with fresh signal,
            // overwriting .stale with the real derived status.
            sessionObserver.resume(hostId: hostId)
        }
    }
}
```

### ReconnectConfig (persisted thresholds)

```swift
// Sources/ContinuumRevivedCore/RemoteReachConfig.swift
public enum ReconnectConfig {
    // UserDefaults keys follow the continuum.remote.reconnect.* namespace
    public static let retryDelaysKey = "continuum.remote.reconnect.retryDelays"
    public static let defaultRetryDelays: [TimeInterval] = [1, 2, 4, 8, 16]

    public static let establishTimeoutKey = "continuum.remote.reconnect.establishTimeout"
    public static let defaultEstablishTimeout: TimeInterval = 15

    public static let probeTimeoutKey = "continuum.remote.reconnect.probeTimeout"
    public static let defaultProbeTimeout: TimeInterval = 15

    public static let stabilityResetKey = "continuum.remote.reconnect.stabilityReset"
    public static let defaultStabilityReset: TimeInterval = 30

    // Each property reads from UserDefaults with its default, no caching.
    public static var stabilityReset: Duration { ... }
    public static var establishTimeout: Duration { ... }
    // ...
}
```

## How we test it

### Logic (pure Core checks)

Add a suite in `Sources/ContinuumRevivedCoreChecks/main.swift` using the existing check
runner pattern. All checks use a `FakeConnectionDriver` (part of the injectable-substrates
seam) and a `FakeClock` — no real SSH, no sleep.

- **Backoff table progression.** Drive the supervisor through five consecutive failures. After
  each failure assert that `state.retryAt` advances by the corresponding delay (1, 2, 4, 8,
  16 s). A sixth failure asserts `retryAt` is 16 s (cap holds). Assert `failureCount` matches.
- **Stability reset.** Connect successfully, advance the fake clock by 31 s, then inject a drop.
  Assert `failureCount` resets to 0 and the next `retryAt` is 1 s (first position in table).
- **No attempt consumed on offline.** Set `networkOK = false`, call `run()` one iteration.
  Assert `phase == .offline` and `failureCount == 0`. Restore network, assert the loop
  proceeds to `connecting` on next signal without incrementing `failureCount`.
- **Blocked parks without timer.** Inject a `ConnectionBlockedError(reason: .authRejected)`.
  Assert `phase == .blocked(.authRejected)` and that advancing the clock by 60 s does not
  produce a new attempt. Send `retryNow()`, assert `phase` transitions to `connecting`.
- **Two-gate readiness rule.** Configure the fake driver to open the channel successfully but
  let the probe time out. Assert the attempt returns `.failed`, not `.connected`.
- **Generation bump on reconnect.** Drive through a full connect → drop → reconnect cycle.
  Assert `state.generation` is 1 after the first connection and 2 after the second.
- **stale is never wrong.** Inject a drop. Assert that `AgentStatusEngine.status` for the
  tile is `.stale` immediately after the drop signal (not after the engine's general
  `staleTimeout`). Assert no further `ingest()` calls are delivered to the engine until the
  supervisor publishes `.connected`.
- **TmuxSession.remoteWrap shape.** Assert that `remoteWrap(profile:host:tileId:sshPath:tmuxPath:)`
  returns a `LaunchProfile` whose `command` is `sshPath`, whose `arguments` contain `-t`,
  `-o ServerAliveInterval=15`, `-o ServerAliveCountMax=3`, the host string, and the tmux
  command with the correct `sessionName` embedded. Pure string/struct assertion, no process.

### Backend (real-path integration)

These checks run against a real SSH target. The CI matrix must provide a loopback SSH host
(`ssh localhost`) so these are not skipped in automation; they are the "gated real-ssh" checks
analogous to the "gated real-tmux" checks in the invariant spine.

- **Keepalive detection end-to-end.** Open an SSH channel with `ServerAliveInterval=1` /
  `ServerAliveCountMax=2` (shortened for the test). Kill the SSH server's sshd child process
  (simulating a network drop) using the channel's pid. Assert the `ConnectionSupervisor`
  transitions to `.stale` within 5 s and that the retry loop starts.
- **Probe gate enforced on real channel.** Open a real SSH channel but intercept the probe
  command and make it return a non-zero exit. Assert the supervisor treats this as `.failed`
  and goes to backoff, not `.connected`.
- **Reconnect recovers live status.** Run the supervisor through a full drop-and-recover cycle
  against the loopback SSH host. Assert that after recovery, `state.phase == .connected` and
  `state.generation == 2`. Assert that the session observer (subscribed to the supervisor's
  state stream) resumes polling and delivers a non-stale `AgentStatus` derived from fresh
  evidence.
- **Observer paused during stale.** Attach a recording stub to the session observer. Inject a
  drop. Assert the stub receives zero `ssh <host> cat <store>` calls during the stale period.
  After recovery, assert calls resume within one poll cycle.

### UX (visual gate + dogfood snippet)

**Visual gate.** Open the Component Lab and navigate to the "Remote Connection States" fixture.
This fixture renders a tile chrome in each connection phase: `connecting` (spinner), `stale`
(gray hollow indicator, "Reconnecting…" subtitle), `backoff` (gray hollow + "Retrying in Xs"
countdown), `blocked` (gray hollow + "Authentication failed"), and `connected` (normal status
indicator). Verify that `stale` renders identically to the `AgentStatus.stale` case already
used by the general status vocabulary (gray hollow ring, no pulse) — the same visual language,
not a new one. Verify that the "Reconnecting…" badge appears only on tiles belonging to the
dropped host, not on local tiles. The gate passes when all five phases render distinctly and
the `stale` visual is indistinguishable from the existing `AgentStatus.stale` rendering in the
sidebar fixture.

**Dogfood snippet.** With a remote project connected over SSH:

1. Open Continuum with a project whose `Host` is the VPS over `sshForward`. Confirm the tile
   shows a real status (blue pulse for `working`, gray ring for `idle`).
2. On the VPS, run `sudo iptables -I INPUT -p tcp --dport 22 -j DROP` to silently block the
   SSH port (simulates a network drop without an RST, forcing the keepalive to time out).
3. Wait 45 seconds (15 s × 3 keepalives + a small margin).
4. Observe: the tile indicator turns gray hollow with a "Reconnecting…" text badge. The sidebar
   row for the tile shows `stale`. No `working`/`needsAttention`/`done` flash appears — the
   indicator goes directly from the last live status to gray without any intermediate fabricated
   state.
5. Run `sudo iptables -D INPUT -p tcp --dport 22 -j DROP` to restore the SSH port.
6. Within 60 s (worst case: two full backoff cycles), the tile returns to a live status derived
   from a fresh observer poll. The "Reconnecting…" badge disappears. The gray hollow is gone.
7. Confirm the `generation` counter in the debug overlay incremented by exactly 1.

## Execution mode

**needs-substrate.** The keepalive detection test requires a real SSH daemon to kill and
revive; the only meaningful readiness probe is a real `tmux list-sessions` round-trip; and the
dogfood step requires a VPS with a controllable firewall. The logic suite (Core checks) is
autonomous, but the backend integration and UX gate cannot be completed without a real remote
host. Per the verification doctrine, this ticket is classified `needs-substrate` because the
core invariant ("stale, never wrong") cannot be proven by a fake driver alone — the drop must
actually be detected via a real keepalive timeout, not a simulated signal injected by the test.

## Done when

- [ ] `TmuxSession.remoteWrap(profile:host:tileId:sshPath:tmuxPath:)` exists and the pure
      logic check for its argument shape passes.
- [ ] `ConnectionSupervisor` actor exists in `ContinuumRevivedCore` with no AppKit/UIKit
      import and all five backoff-table checks pass in the core check runner.
- [ ] The two-gate rule check passes: open-but-probe-timeout → `.failed`, not `.connected`.
- [ ] The stability-reset check passes: 31-second uptime → `failureCount == 0` on next drop.
- [ ] The blocked-parks-without-timer check passes: clock advance does not trigger a retry.
- [ ] `ReconnectConfig` exists with all four threshold groups reading from `UserDefaults` with
      documented defaults; a Settings entry is present for each threshold.
- [ ] `ZoneRuntimeController` subscribes to `supervisor.stateStream` and calls
      `sessionObserver.pause(hostId:)` on phase != `.connected` and
      `sessionObserver.resume(hostId:)` on `.connected`.
- [ ] `projectStore.forceStale(tileId:)` immediately sets `AgentStatus.stale` for the affected
      tile(s) without waiting for the engine's `staleTimeout`.
- [ ] The "Observer paused during stale" backend check passes against the loopback SSH host
      with zero `cat` calls delivered during the stale window.
- [ ] The "Reconnect recovers live status" backend check passes: `state.generation == 2` and
      a non-stale `AgentStatus` is delivered within one poll cycle after recovery.
- [ ] The Component Lab "Remote Connection States" fixture exists and the visual gate passes
      (reviewer confirms `stale` matches the existing `AgentStatus.stale` visual, no new
      indicator shape is introduced).
- [ ] The dogfood snippet completes: the tile goes to gray hollow within 45 s of the firewall
      block, no fabricated live status appears during the stale window, and the tile recovers to
      a live status within 60 s of the firewall being restored.
- [ ] No `AgentStatus.working`/`done`/`needsAttention` event is emitted for a tile during its
      stale window in any of the integration checks (the "never wrong" invariant is
      mechanically enforced, not just asserted in prose).

## Depends on / unblocks

**Depends on** the remote-attach real-path ticket, which establishes the `Host`, `RemoteReach`,
and `sshForward` types that `ConnectionSupervisor` is parameterized over. The supervisor
wraps a `RemoteConnectionDriver` whose concrete `SSHConnectionDriver` implementation is
built in that prior ticket. This ticket adds only the drop-detection and retry machinery on
top of an already-functional SSH attach.

**Also depends on** the injectable-substrates seam (the `TmuxControl` protocol and fake clock)
for the pure Core checks, and on the session-observer seam (which must expose `pause(hostId:)`
and `resume(hostId:)` methods) for the observer-pause guarantee.

**Unblocks** the Tailscale reach-path extension (which needs the same reconnect loop for mesh
peers), and the iOS `ConnectionSupervisor` port (the iOS client reuses `ConnectionSupervisor`
nearly verbatim — same actor shape, same backoff table, same generation counter — differing
only in that the iOS link's driver connects to the Continuum host daemon or the ssh channel
over Tailscale rather than a local SSH process).

## Watch out for

**The two-gate rule is the most common place to get this wrong.** A half-open TCP connection
produces a channel that reports open but never answers the probe. If the gate is implemented
as "connected once the socket opens," the supervisor will publish `.connected` while the
remote is unreachable, the observer will resume, and stale data will be served as live. The
probe timeout must be `ReconnectConfig.probeTimeout` (15 s default), not inherited from the
establish timeout, and must be applied independently — both gates fail independently and both
produce a `.failed` outcome that goes to backoff.

**Do not let the observer's last-snapshot delivery race with the stale transition.** If
`sessionObserver.pause(hostId:)` is called after the observer has already dispatched a
fresh-looking result from a partially-completed `ssh cat` call that was in flight when the
drop occurred, that result will be marked live even though the channel is gone. The correct
ordering is: `ConnectionSupervisor` emits the drop signal → `ZoneRuntimeController` calls
`pause(hostId:)` → the observer drains any in-flight operation and stops. The in-flight result
must be discarded, not delivered. Implement `pause` as a structured cancellation of the
observer's current SSH task, not as a boolean flag the next poll checks.

**`forceStale` must bypass the engine's `staleTimeout`.** The `AgentStatusEngine.tick()`
method already transitions to `stale` after `staleTimeout` (300 s default). This ticket must
not rely on that mechanism — the tile must show `stale` within seconds of the keepalive
exhausting, not five minutes later. Implement `forceStale` as a direct call to
`AgentStatusEngine.ingest(.explicit(.stale))` or equivalent, which overrides the inferred
status immediately. The existing `AgentStatusEngine.Signal.explicit` path handles this.

**Backoff reset is conditioned on uptime, not on whether reconnect was clean.** A connection
that lasted 31 seconds before dropping resets the failure counter on the *next* attempt, even
if the drop was involuntary. A connection that lasted 29 seconds does not reset it. The
uptime is measured from when the supervisor first published `.connected` (after the probe
succeeded) to when the channel closed — not from when the SSH process opened.

**`StrictHostKeyChecking=accept-new` is the correct first-connect posture, not `no`.** The
`accept-new` value adds the host key on first contact and refuses if the key changes
thereafter, which is the security-correct behavior for a personal VPS. Using `no` silently
accepts changed keys and is a credential-theft vector. A key-change failure must produce
`.blocked(.hostKeyMismatch)`, not a retry loop.

**The `generation` counter must be visible in the debug overlay.** During the dogfood step,
confirming that `generation` incremented by exactly 1 is the proof that the reconnect path
ran once and not zero times (which would mean the link never actually dropped) or twice
(which would mean the retry loop overcounted). Add `generation` to whatever connection-state
debug overlay already exists in the app, or create a minimal one if none does.
