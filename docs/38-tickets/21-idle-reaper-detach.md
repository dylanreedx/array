# Idle reaper: detach stale no-active-turn sessions, never kill, never on disconnect

## What this delivers

A `SessionPruner` actor in `ContinuumRevivedCore` runs on a repeating timer and detaches
any project session that has been idle long enough, provided no active turn is in flight for
any of that session's tiles. "Idle" is measured purely against an injectable clock — no
wall-clock reads in the logic. The reaper never kills a session; it detaches it, leaving the
tmux session and its windows alive for later re-adoption. Crucially, the reaper is entirely
indifferent to whether any client is connected: an iOS observer dropping its socket, a user
closing the app, or a Ghostty surface going away are all invisible to the reaper. Only
elapsed idle time and the absence of an active agent turn can trigger a detach.

This rests on D16 (project release = DETACH, never kill; the idle reaper also reaps by detach,
never kill, and never on disconnect) and D26 (the phase-0 injectable substrates and the
`ActivityTreeSnapshot` type this reaper reads).

The user-visible outcome is that a workspace containing several long-lived project zones can
accumulate sessions that have sat unused for hours without any manual cleanup, and those
sessions will eventually be detached — freeing resources — while sessions with live agent
work are never touched. Because detach leaves the tmux session intact, re-focusing a tile
later re-adopts the existing session seamlessly through the lazy-resume path described by the
prior topology work.

## How it fits

**Read this section carefully — this ticket sits on top of prerequisites that DO NOT EXIST in
the codebase yet.** They are planned in the locked decisions and the steal-docs, not built.
An implementer who searches `Sources/` for the types below will find nothing; that is expected.
The dependencies are real and legitimate, but every one of them is UNBUILT. Do not treat any
of them as delivered.

**Prerequisite 1 — the phase-0 injectable substrates (UNBUILT; D26).** D26 says the test
primitives are "stood up first, before any behavior change": injectable substrates
(`TmuxControl` fake, fake clock, fake `Host`, fake `SyncTransport`) plus serializable
snapshots at every seam. As of this writing NONE of these exist:

- `grep -rn "TmuxControl" Sources/` → zero hits. There is no `TmuxControl` protocol, no
  `InMemoryTmuxControl`, no `ProcessTmuxControl`. The only tmux abstraction in the repo is the
  `TmuxSession` enum (`Sources/ContinuumRevivedCore/TmuxSession.swift`) — free functions
  `sessionName(tileId:)`, `wrap(...)`, `killSessionCommand(tileId:tmuxPath:)`. There is no
  detach command anywhere in the codebase.
- `grep -rn "FakeClock\|protocol Clock\|SystemClock" Sources/` → zero hits. There is no clock
  protocol. The checks harness currently injects a plain `Date` as a clock stand-in
  (`ContinuumRevivedCoreChecks/main.swift` around line 1236 passes `now:` into
  `restoredForBoot(now:)`).
- `grep -rn "FakeSyncTransport\|SyncTransport" Sources/` → zero hits.

**Prerequisite 2 — the `ActivityTreeSnapshot` type (UNBUILT; D26 + steal-doc §4.1).**
`ActivityTreeSnapshot` and its `byTile[tileId].status` accessor appear ONLY as a proposal in
`docs/2026-06-30-t3code-steal/04-orchestration-sessions-projections.md` §4.1, which states
explicitly: *"All Swift below is illustrative [judgment] — it does not exist in the repo yet."*
D26 lists `ActivityTreeSnapshot` (with the evidence behind each status) among the phase-0
snapshots to stand up first. `grep -rn "ActivityTreeSnapshot\|ActivityStore" Sources/` → zero
hits.

**Prerequisite 3 — the managed-agent session record store (UNBUILT; steal-doc §4.2).** The
`ManagedAgentSessionRecord` (PK `tileId`, `lastSeenAt` bumped on every interaction) is the
would-be source of a per-session `lastSeenAt` idleness signal. It also is only a proposal in
steal-doc §4.2 and is gated on the DRIVE fork (D1). `grep -rn "ManagedAgentSessionRecord\|
lastSeenAt(forProject" Sources/` → zero hits.

**What this means for sequencing.** This ticket CANNOT begin until Prerequisites 1 and 2 land
as their own phase-0 tickets. Their exact surfaces — the ones this ticket compiles against —
are pinned in "Substrate contract this ticket requires" below so the phase-0 tickets and this
ticket agree byte-for-byte. Prerequisite 3 is NOT required to land first: this ticket ships
with a specified project-level `lastSeenAt` stand-in (see "The session binding source"),
and the managed-record path is a documented later swap, not a blocker.

**How D16 makes the reaper necessary.** D16 locks that project release
(`ZoneRuntimeRegistry` → 0) DETACHES rather than kills, so `continuum-proj-<projectId>`
sessions may accumulate in a detached-but-alive state. The idle reaper is the mechanism that
eventually detaches sessions left running — without it, long-idle sessions persist indefinitely.

**What this ticket unblocks:** the per-workspace ambient session work (D15; its
`continuum-ws-<workspaceId>` sessions will register as reaper bindings once that path ships),
and the managed-agent session record work (steal-doc §4.2; it will contribute a real
`lastSeenAt` the reaper reads instead of the project-level stand-in). Neither requires this
ticket to be done first, but both assume a reaper exists.

## Substrate contract this ticket requires

These are the EXACT surfaces this ticket compiles against. They do not exist yet; they are
delivered by the phase-0 substrate tickets (Prerequisites 1 and 2). This section is the
contract between those tickets and this one — if the phase-0 surfaces differ, this ticket's
breadcrumbs and checks must be updated to match, but the semantics below are non-negotiable
for the reaper to work.

**`Clock` (from Prerequisite 1).**

```swift
public protocol Clock: Sendable {
    func now() -> Date
}
public struct SystemClock: Clock { public init() {} ; public func now() -> Date { Date() } }
public final class FakeClock: Clock {          // test substrate
    private var current: Date
    public init(_ start: Date) { current = start }
    public func now() -> Date { current }
    public func advance(by seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
}
```

**`TmuxControl` (from Prerequisite 1).** This ticket needs exactly three verbs. The reaper only
ever calls `detachSession`; `killSession`/`killWindow` exist on the protocol so the never-kill
scan can assert they are NEVER emitted by the pruner.

```swift
public protocol TmuxControl: Sendable {
    func detachSession(name: String) async throws
    func killSession(name: String) async throws
    func killWindow(target: String) async throws
}
```

`detachSession(name:)` in the production impl (`ProcessTmuxControl`) MUST run
`tmux detach-client -s <name>` — never `tmux kill-session`. This is the make-or-break contract
(see "Watch out for").

**`InMemoryTmuxControl.log` — the recording contract (from Prerequisite 1).** The fake records
every call as an enum case, in order. The never-kill scan and the detach assertions depend
entirely on this shape, so it is pinned here:

```swift
public actor InMemoryTmuxControl: TmuxControl {
    public enum Call: Equatable, Sendable {
        case detachSession(name: String)
        case killSession(name: String)
        case killWindow(target: String)
    }
    public private(set) var log: [Call] = []
    public init() {}
    public func detachSession(name: String) async throws { log.append(.detachSession(name: name)) }
    public func killSession(name: String) async throws { log.append(.killSession(name: name)) }
    public func killWindow(target: String) async throws { log.append(.killWindow(target: target)) }
}
```

The seam "`InMemoryTmuxControl.log` contains `.detachSession(name:)`" is now verifiable: it is
an `Equatable` enum case in an ordered array. A test asserts
`await tmux.log == [.detachSession(name: expectedSessionName)]` (or scans for absence of the
kill cases).

**`ActivityTreeSnapshot` (from Prerequisite 2).** The reaper reads exactly one path:
`snapshot.byTile[tileId]?.status`. The minimal shape it needs (a subset of steal-doc §4.1):

```swift
public struct ActivityTreeSnapshot: Sendable, Equatable {
    public var byTile: [UUID: TileActivity]
    public init(byTile: [UUID: TileActivity]) { self.byTile = byTile }
}
public struct TileActivity: Sendable, Equatable {
    public var status: AgentStatus          // existing enum, TerminalSessionDescriptor.swift:85
    public init(status: AgentStatus) { self.status = status }
}
```

`AgentStatus` already exists (`Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift`,
values include `.working`). The reaper's active-turn gate is
`snapshot.byTile[tileId]?.status == .working`. The phase-0 `ActivityTreeSnapshot` will carry
more (recent events, evidence, sequence) per D26 — the reaper only reads `byTile[_].status`.

## The approach

`SessionPruner` is a new `actor` in `ContinuumRevivedCore`. It holds an `any TmuxControl` and
an `any Clock`, a configurable pair of thresholds (`inactivityThreshold: TimeInterval` and
`sweepInterval: TimeInterval`), and two async closures: one that yields the session bindings
to consider, one that yields the current activity snapshot. On start it runs a detached `Task`
that calls `sweep()` on a repeating schedule driven by `Task.sleep(nanoseconds:)`. The
`sweep()` function iterates over all bindings, skips any session last seen within the
inactivity threshold (measured against `clock.now()`), skips any session with a live active
turn (read from the snapshot), and calls `tmuxControl.detachSession(name:)` for the rest. It
never calls `killSession` or `killWindow`, not even in error branches.

The reaper consults the derived read model (the `ActivityTreeSnapshot`), it does not poll tmux.
This mirrors the t3code pattern where `getThreadShellById(threadId)` is read and
`activeTurnId != nil` blocks the reap — the reaper should never be the entity that discovers an
active turn by racing a live agent.

### The session binding source

The binding source is an injected async closure, `@Sendable () async -> [SessionBinding]`, so
the actor stays decoupled from whatever concrete store provides the data. This ticket wires a
concrete implementation of that closure in `ZoneRuntimeController`, and the closure's data
source is SPECIFIED here — there is no "closest equivalent" choice left to the implementer.

Because the managed-agent session record store (Prerequisite 3) is UNBUILT, this ticket does
NOT read `lastSeenAt` from a per-session record. Instead it uses a specified stand-in:

- **`sessionName`** — `TmuxSession.sessionName(tileId:)` for the tile that represents the
  project's session anchor. NOTE: there is no `continuum-proj-<projectId>` naming helper in the
  codebase today (`grep -rn "projectSessionName\|continuum-proj" Sources/` → zero hits); the
  only session-name helper is `TmuxSession.sessionName(tileId:)` which yields
  `continuum-<tileId-uuid>`. Until the project=session topology ships its own naming helper, the
  reaper uses the existing per-tile name. The binding's `sessionName` field is a plain `String`,
  so swapping in a `continuum-proj-<projectId>` name later is a one-line change at the wiring
  site, not a change to `SessionPruner`.
- **`tileIds`** — the tile IDs the controller knows about for its project. The controller reads
  these from its own already-loaded `CanvasState` (the tiles it manages), NOT by scanning tmux.
- **`lastSeenAt`** — the STAND-IN idleness signal is `project.createdAt`
  (`Sources/ContinuumRevivedCore/Project.swift:10`, a real existing field). This is a
  deliberately conservative stand-in: a freshly created project is never immediately idle, and
  a long-lived project becomes eligible for a reap only after `inactivityThreshold` has elapsed
  since creation AND no tile is working. When Prerequisite 3 lands, the wiring site swaps
  `project.createdAt` for the managed record's `lastSeenAt` (bumped on every interaction); the
  `SessionPruner` itself does not change.

This is the honest contract: the reaper's PRIMARY idleness signal is `lastSeenAt` on the
`SessionBinding`; the SOURCE of that value is `project.createdAt` today and the managed record
later. No unbuilt store is required to ship this ticket.

### Default thresholds

These are user-configurable via a persisted Settings entry, following the configurable-first
doctrine (the exact keys and Settings registration are specified in "The Settings seam").

- **Inactivity threshold:** 30 minutes. A session idle for less than 30 minutes is never
  detached, even if no client is connected.
- **Sweep interval:** 5 minutes. The reaper wakes every 5 minutes and evaluates all bindings.

Both are global defaults; a per-project override is the natural follow-on once the global
default is dogfooded (not built here).

### Disconnect blindness

The reaper never fires on disconnect. There is no hook into the Ghostty surface teardown, the
iOS observer socket close, or any network-level event. Those are invisible by design; the
binding's `lastSeenAt` is the only idleness signal.

## The Settings seam

This resolves the configurability requirement CONCRETELY against the pattern the codebase
already uses, so there is no "once the Settings entry exists — whose job is that?" hole. The
Settings entry is THIS ticket's job, and it follows the exact shape of
`WorkspaceSidebarConfig` + `SettingsSchema`.

**Step 1 — a Core config enum.** Add `Sources/ContinuumRevivedCore/IdleReaperConfig.swift`,
mirroring `WorkspaceSidebarConfig.swift` (a `UserDefaults`-backed resolver with a default and a
clamp). This is the single source of truth for the keys and defaults:

```swift
public enum IdleReaperConfig {
    public static let inactivityThresholdKey = "continuum.idleReaper.inactivityThresholdSeconds"
    public static let sweepIntervalKey       = "continuum.idleReaper.sweepIntervalSeconds"

    public static let defaultInactivityThreshold: TimeInterval = 30 * 60   // 30 min
    public static let defaultSweepInterval: TimeInterval       = 5 * 60     // 5 min
    public static let minSweepInterval: TimeInterval           = 10         // never thrash

    public static func resolveInactivityThreshold(defaults: UserDefaults = .standard) -> TimeInterval {
        guard defaults.object(forKey: inactivityThresholdKey) != nil else { return defaultInactivityThreshold }
        return max(0, defaults.double(forKey: inactivityThresholdKey))
    }
    public static func resolveSweepInterval(defaults: UserDefaults = .standard) -> TimeInterval {
        guard defaults.object(forKey: sweepIntervalKey) != nil else { return defaultSweepInterval }
        return max(minSweepInterval, defaults.double(forKey: sweepIntervalKey))
    }
}
```

**Step 2 — register the fields in the settings UI.** Append two `.text` fields to the
`SettingsSchema.sections()` "general" section (or a new "Sessions" section), keyed to the exact
`UserDefaults` keys above — identical in shape to the existing
`NavKeymap.leaderDwellDefaultsKey` / `DefaultBrowserURL.userDefaultsKey` fields already there:

```swift
.text(key: IdleReaperConfig.inactivityThresholdKey,
      label: "Idle Reaper Threshold (seconds)",
      default: String(Int(IdleReaperConfig.defaultInactivityThreshold))),
.text(key: IdleReaperConfig.sweepIntervalKey,
      label: "Idle Reaper Sweep Interval (seconds)",
      default: String(Int(IdleReaperConfig.defaultSweepInterval))),
```

Because `SettingsSchema` fields bind to the EXACT `UserDefaults` key of a Core resolver
(the file header says so), editing the field in Settings drives `IdleReaperConfig.resolve*`
live, and the values persist across launches for free — no new persistence store, no bespoke
keybind machinery. `startReaper` reads `IdleReaperConfig.resolve*` when constructing the
`Configuration`, so hardcoded defaults are impossible: the defaults live in the resolver and
are overridable from Settings.

There is no conflict-guarded keybind for thresholds (they are numeric text fields, not a
shortcut). The keybind conflict-guard applies to the Keybindings section; these two settings
are values, so the doctrine is satisfied by "persisted default + Settings entry", which this
provides.

## Where it lives

**`Sources/ContinuumRevivedCore/SessionPruner.swift`** — this file already exists (it currently
houses `pruneExitedSessions(in:)`, a free function that removes descriptors with a non-nil
`lastExit` on boot). The new `SessionPruner` actor is added alongside the existing free
function. The free function is unchanged; it handles a different pruning concern (boot-time
stale descriptor cleanup) and is not replaced or removed.

**`Sources/ContinuumRevivedCore/IdleReaperConfig.swift`** — NEW file, the config enum above.

**`Sources/ContinuumRevivedCore/SettingsSchema.swift`** — the two `.text` fields appended.

**`Sources/ContinuumRevived/App/ZoneRuntimeController.swift`** — `ZoneRuntimeController` is
declared at line 6. It grows a `sessionPruner: SessionPruner?` property and a
`startReaper(tmuxControl:activitySnapshotSource:clock:)` method that constructs the pruner from
`IdleReaperConfig`, the injected clock, and the specified binding source. The pruner starts
lazily when the controller attaches to the UI (from `attachUI(...)` around line 96), NOT at
`init` (init has no tmux control). It is stopped in `close()` (line 78).

**Key symbols added:**

- `ContinuumRevivedCore.SessionPruner` — the new actor type (in `SessionPruner.swift`)
- `ContinuumRevivedCore.SessionPruner.Configuration` — value type holding `inactivityThreshold`,
  `sweepInterval`, both `TimeInterval`
- `ContinuumRevivedCore.SessionPruner.SessionBinding` — value type the pruner reads:
  `sessionName: String`, `tileIds: [UUID]`, `lastSeenAt: Date`
- `ContinuumRevivedCore.IdleReaperConfig` — the config/Settings resolver enum
- `ZoneRuntimeController.startReaper(tmuxControl:activitySnapshotSource:clock:)`
- `ZoneRuntimeController.stopReaper()` — called from `close()`

## Implementation breadcrumbs

The core actor shape and sweep logic. It depends only on the Substrate contract types above:

```swift
public actor SessionPruner {
    public struct Configuration: Sendable {
        public var inactivityThreshold: TimeInterval
        public var sweepInterval: TimeInterval
        public init(inactivityThreshold: TimeInterval = IdleReaperConfig.defaultInactivityThreshold,
                    sweepInterval: TimeInterval = IdleReaperConfig.defaultSweepInterval) {
            self.inactivityThreshold = inactivityThreshold
            self.sweepInterval = sweepInterval
        }
    }

    public struct SessionBinding: Sendable {
        public let sessionName: String     // e.g. "continuum-<tileId>" today (see binding source)
        public let tileIds: [UUID]
        public var lastSeenAt: Date
        public init(sessionName: String, tileIds: [UUID], lastSeenAt: Date) {
            self.sessionName = sessionName; self.tileIds = tileIds; self.lastSeenAt = lastSeenAt
        }
    }

    private let tmuxControl: any TmuxControl
    private let clock: any Clock
    public let configuration: Configuration
    private let bindingSource: @Sendable () async -> [SessionBinding]
    private let activitySnapshotSource: @Sendable () async -> ActivityTreeSnapshot?
    private var sweepTask: Task<Void, Never>?

    public init(
        tmuxControl: any TmuxControl,
        clock: any Clock,
        configuration: Configuration = .init(),
        bindingSource: @Sendable @escaping () async -> [SessionBinding],
        activitySnapshotSource: @Sendable @escaping () async -> ActivityTreeSnapshot?
    ) {
        self.tmuxControl = tmuxControl
        self.clock = clock
        self.configuration = configuration
        self.bindingSource = bindingSource
        self.activitySnapshotSource = activitySnapshotSource
    }

    public func start() {
        sweepTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.sweep()
                let interval = await self.configuration.sweepInterval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    public func stop() { sweepTask?.cancel(); sweepTask = nil }

    // Exposed for direct testing without waiting for the timer.
    public func sweep() async {
        let now = clock.now()
        let bindings = await bindingSource()
        let snapshot = await activitySnapshotSource()

        for binding in bindings {
            // Gate 1: idle long enough?
            let idleDuration = now.timeIntervalSince(binding.lastSeenAt)
            guard idleDuration >= configuration.inactivityThreshold else { continue }

            // Gate 2: any tile in this session actively working?
            let hasActiveTurn = binding.tileIds.contains { tileId in
                snapshot?.byTile[tileId]?.status == .working
            }
            guard !hasActiveTurn else { continue }

            // Both gates cleared: detach. NEVER kill.
            try? await tmuxControl.detachSession(name: binding.sessionName)
        }
    }
}
```

Wiring into `ZoneRuntimeController`. Note the binding source is the SPECIFIED stand-in
(`project.createdAt` for `lastSeenAt`, controller's own tiles for `tileIds`), and the config
is read from `IdleReaperConfig` — never hardcoded:

```swift
// In ZoneRuntimeController

private var sessionPruner: SessionPruner?

// LIFECYCLE: detach, never kill — symmetric with close()'s detach-only comment.
func startReaper(
    tmuxControl: any TmuxControl,
    activitySnapshotSource: @escaping @Sendable () async -> ActivityTreeSnapshot?,
    clock: any Clock = SystemClock()
) {
    // Config from the persisted Settings resolver — not hardcoded.
    let config = SessionPruner.Configuration(
        inactivityThreshold: IdleReaperConfig.resolveInactivityThreshold(),
        sweepInterval: IdleReaperConfig.resolveSweepInterval()
    )

    let sessionName = TmuxSession.sessionName(tileId: /* project's anchor tile id */)
    let tileIds = self.tileIdsForCurrentProject   // from the controller's own CanvasState
    let createdAt = self.project.createdAt          // real existing field, the lastSeenAt stand-in

    let pruner = SessionPruner(
        tmuxControl: tmuxControl,
        clock: clock,
        configuration: config,
        bindingSource: {
            [SessionPruner.SessionBinding(
                sessionName: sessionName,
                tileIds: tileIds,
                lastSeenAt: createdAt          // swap for managed-record lastSeenAt when Prereq 3 lands
            )]
        },
        activitySnapshotSource: activitySnapshotSource
    )
    sessionPruner = pruner
    Task { await pruner.start() }
}

func stopReaper() {
    Task { await sessionPruner?.stop() }
    sessionPruner = nil
}
```

`tileIdsForCurrentProject` is the controller's own list of tile IDs read from its already-loaded
`CanvasState`; if the controller does not yet expose it, add a small private computed property
that maps its canvas tiles to their IDs — it does NOT enumerate tmux (see "Watch out for").

In `close()` (alongside the existing teardown at line 78), add:

```swift
stopReaper()
```

## How we test it

### Logic (pure Core checks)

All logic checks run in `ContinuumRevivedCoreChecks` following the existing `do { … }` block
convention. They use `InMemoryTmuxControl` and `FakeClock` from the Substrate contract — no
daemon, no real clock, no disk I/O. Each check reads the `InMemoryTmuxControl.log` (the ordered
`[Call]` array defined in the contract) and asserts on its enum cases.

**Idle gate check.** Construct a `SessionPruner` with a `FakeClock` fixed at T=0 and one
`SessionBinding` whose `lastSeenAt` is T=0. Call `sweep()`. Assert `await tmux.log` is empty —
not stale yet. Advance the clock by `inactivityThreshold - 1` seconds; call `sweep()`; assert
`log` still empty. Advance by 2 more seconds (crossing the threshold); call `sweep()`; assert
`log == [.detachSession(name: expectedSessionName)]`. The manifest records the threshold value,
the seconds advanced, and the observed log.

**Active-turn guard check.** Construct a pruner with the clock advanced past the threshold, so
Gate 1 is satisfied. Provide an `ActivityTreeSnapshot` where one of the binding's tile IDs has
`status == .working`. Call `sweep()`; assert `log` contains no `.detachSession` — Gate 2 blocks
the reap. Change that tile's status to `.idle`; call `sweep()`; assert `.detachSession` now
appears. This proves both gates must clear and Gate 2 is evaluated after Gate 1.

**Disconnect-blindness check.** Construct a pruner past the idle threshold; call `sweep()`;
confirm `.detachSession` appears exactly once. Then simulate a "client disconnect" by doing
nothing — there IS no disconnect signal. Reset the binding's `lastSeenAt` to `clock.now()` and
call `sweep()` again; assert no additional `.detachSession` — the reaper has no disconnect hook,
only the idle gate governs it.

**Never-kill check.** After every sweep permutation above, scan the full `InMemoryTmuxControl.log`
and assert no element matches `.killSession` or `.killWindow` — only `.detachSession` is ever
emitted by the pruner. This is a single-line filter over the `[Call]` array.

**Threshold configurability check.** Construct two pruners with different `Configuration`
values (10-second vs 60-second `inactivityThreshold`). Fix the clock 30 seconds past
`lastSeenAt`; call `sweep()` on both. Assert the 10-second pruner emits `.detachSession` and the
60-second pruner does not. Then, separately, assert `IdleReaperConfig.resolveInactivityThreshold`
returns the written override when a `UserDefaults` value is set and the default when it is not —
this proves the Settings key actually drives the value.

### Backend (real-path / integration)

The backend check runs against a real tmux daemon (guarded by `TmuxLocator.resolve() != nil`,
as the substrate/backend checks do) and exercises the detach path through the production
`ProcessTmuxControl`.

Sequence: use `ProcessTmuxControl` to create a session named `continuum-pruner-check-<uuid>`;
verify it is alive via `tmux ls`. Construct a `SessionPruner` with a `FakeClock` already past
the inactivity threshold, a binding pointing to that session name, an empty
`ActivityTreeSnapshot` (no active turns), and the real `ProcessTmuxControl`. Call `sweep()`.
Assert `tmux ls` still LISTS the session but shows it `(detached)`, not attached, not absent.
Record `session_name`, `found_after_detach: true`, `status_in_tmux_ls: "(detached)"`, and
`elapsed_ms`. Finally call `tmuxControl.killSession(name:)` to clean up.

Stop condition: if the session disappears entirely from `tmux ls` after the sweep (killed
rather than detached), the check fails loudly with a message explaining that `detachSession`
must run `tmux detach-client -s <name>`, not `tmux kill-session`.

### UX (visual gate + dogfood snippet)

There is no new visual UI element — the reaper runs invisibly. The visual gate is behavioral:
after a project session has been idle past the threshold, `tmux ls` in any terminal shows that
session as `(detached)` rather than `(attached)`; the session is still listed (not killed), and
re-opening a tile in that project re-attaches seamlessly.

Concrete dogfood snippet: open the app and open a project zone with a terminal tile. In that
tile, start a long-lived process (`sleep 10000`). In a separate terminal, `tmux ls` — it reads
`continuum-<uuid>: 1 windows (created …) [attached]`. For quick verification, set the threshold
low via Settings ▸ (General/Sessions) ▸ "Idle Reaper Threshold (seconds)" = 60 and
"Idle Reaper Sweep Interval (seconds)" = 10, then switch away from the zone and wait ~70s. Run
`tmux ls` again — you should see `[detached]`. Switch back to the zone — the tile re-attaches and
`sleep 10000` is still running (confirm via `tmux lsp -t continuum-<uuid>`). If the process is
gone, the session was killed rather than detached (a failure).

## Execution mode

**Autonomous, but BLOCKED on Prerequisites 1 and 2.** The logic checks are fully deterministic
once the substrates exist: `FakeClock`, `InMemoryTmuxControl`, and a hand-constructed
`ActivityTreeSnapshot` exercise every branch (idle gate, active-turn guard, never-kill,
configurability) with no daemon, wall clock, or human judgment. The backend real-path check
needs a local tmux install but no cloud/iOS/visual eval; it skips gracefully when tmux is absent
and produces a measured manifest a CI matrix can grade. The UX dogfood snippet is self-service,
not a gate on the run.

The block is real: an implementer must NOT start here until the `Clock`/`TmuxControl`/
`InMemoryTmuxControl`/`FakeClock` substrate ticket (Prereq 1) and the `ActivityTreeSnapshot`
snapshot ticket (Prereq 2) have landed with the surfaces pinned in "Substrate contract this
ticket requires". If those tickets choose different names or shapes, reconcile this ticket to
them before writing code. Prerequisite 3 (the managed-record store) is NOT a block — the
specified `project.createdAt` stand-in ships this ticket without it.

## Done when

- [ ] Prerequisites 1 and 2 have landed (the `Clock`/`TmuxControl`/`InMemoryTmuxControl`/
  `FakeClock` substrates and the `ActivityTreeSnapshot` type), matching the pinned Substrate
  contract; this ticket compiles against those real types, not stubs invented here.
- [ ] `SessionPruner` actor is defined in `Sources/ContinuumRevivedCore/SessionPruner.swift`
  alongside the existing `pruneExitedSessions(in:)` free function, which is unchanged.
- [ ] `SessionPruner.Configuration` holds `inactivityThreshold` and `sweepInterval`, both
  `TimeInterval`, both defaulted from `IdleReaperConfig` (30 min / 5 min).
- [ ] `IdleReaperConfig` exists in `Sources/ContinuumRevivedCore/IdleReaperConfig.swift` with
  `inactivityThresholdKey` / `sweepIntervalKey`, documented defaults, and resolvers; the two
  keys are registered as `.text` fields in `SettingsSchema.sections()`; both persist and are
  respected on the next launch. `startReaper` reads `IdleReaperConfig.resolve*` — no hardcoded
  thresholds.
- [ ] `SessionPruner.sweep()` is a public `async` method callable directly from checks; the
  timer loop calls it on the configured interval.
- [ ] The sweep evaluates the idle gate (`clock.now() - lastSeenAt >= inactivityThreshold`)
  before the active-turn gate; a not-yet-idle session is skipped without consulting the snapshot.
- [ ] The sweep never calls `killSession` or `killWindow` in any branch; only
  `detachSession(name:)` is emitted.
- [ ] There is no hook into any client-disconnect or socket-close event; the reaper is blind to
  connectivity state.
- [ ] `ZoneRuntimeController.startReaper(tmuxControl:activitySnapshotSource:clock:)` exists,
  builds the `SessionBinding` from the SPECIFIED stand-in source (`project.createdAt` for
  `lastSeenAt`, the controller's own `CanvasState` tiles for `tileIds`), and starts the pruner.
- [ ] `ZoneRuntimeController.stopReaper()` is called from `close()`.
- [ ] All five logic check suites (idle gate, active-turn guard, disconnect-blindness,
  never-kill scan, threshold configurability incl. the `IdleReaperConfig` resolver check) pass
  with measured-value manifests.
- [ ] The backend real-path check passes when tmux is present: `tmux ls` shows `(detached)` —
  not absent, not `(attached)` — after `sweep()` on a past-threshold session.
- [ ] The app builds and all existing checks pass.

## Depends on / unblocks

**Depends on (UNBUILT prerequisites — see "How it fits"):**

- The phase-0 injectable substrates ticket (D26): `Clock` protocol, `SystemClock`, `FakeClock`,
  `TmuxControl` protocol, `InMemoryTmuxControl` (with the `[Call]` log), `ProcessTmuxControl`.
  None exist today.
- The phase-0 `ActivityTreeSnapshot` snapshot ticket (D26): the type with `byTile[tileId].status`.
  Does not exist today.
- D16 (project release = DETACH, never kill), which is what makes detached project sessions
  accumulate and thus makes a reaper necessary.

Explicitly NOT a hard dependency:

- The managed-agent session record store (steal-doc §4.2, `ManagedAgentSessionRecord`). This
  ticket ships with the `project.createdAt` `lastSeenAt` stand-in; the managed record is a
  documented later swap at the wiring site only.

**Unblocks:**

- The per-workspace ambient session work (D15): its `continuum-ws-<workspaceId>` sessions will
  register as reaper bindings alongside project sessions.
- The managed-agent session record work: it contributes a real, per-session `lastSeenAt` the
  reaper reads instead of the project-level stand-in — a one-line swap in `startReaper`.

## Watch out for

**The make-or-break risk: `detachSession` must run `tmux detach-client -s <name>`, not
`tmux kill-session`.** These look similar in a subprocess invocation. If
`ProcessTmuxControl.detachSession` accidentally calls `kill-session`, the backend check catches
it because the session disappears from `tmux ls` instead of showing `(detached)`. Do NOT paper
over a missing session by treating "not found" as "detached." The never-kill scan (logic) and
the session-presence assertion (backend) both exist to catch this; either failing is a hard stop.

**The `lastSeenAt` source is a stand-in — do NOT invent a store.** Because the managed-record
store is UNBUILT, `lastSeenAt` comes from `project.createdAt`. Do not build a
`ManagedAgentSessionRecord` here to get a "better" `lastSeenAt`; that is a separate ticket. The
stand-in is conservative and correct for shipping the reaper; the swap point is a single line at
the `startReaper` wiring site.

**The active-turn guard must consult the snapshot, never tmux.** Calling
`tmux display -p '#{window_activity}'` or any tmux query to decide whether a turn is active
introduces a race (the reaper could ask tmux mid-write). The `ActivityTreeSnapshot` is the
authoritative read model; the reaper is a reader of it, not an independent interrogator of the
daemon.

**Do not start the reaper at `init` time.** `ZoneRuntimeController.init` (lines 54 and 71) has no
`TmuxControl`; start the reaper only from `startReaper`, called after the controller attaches to
the UI (`attachUI`, ~line 96) and the tmux control is available. Starting eagerly at init risks
a nil-control crash or a sweep firing before the watched session exists.

**Thresholds must come from `IdleReaperConfig`, not literals.** Per the configurable-first
doctrine, a user must be able to lower the threshold (quick testing) or raise it (long-idle
workloads) via Settings without touching source. `startReaper` reads
`IdleReaperConfig.resolveInactivityThreshold()` / `resolveSweepInterval()` when building the
`Configuration`. Defaults live in `IdleReaperConfig`, not inline in `startReaper`. If the
implementation hardcodes the numbers or skips the `SettingsSchema` registration, it is incomplete.

**The reaper must not sweep sessions it doesn't own.** In a workspace showing multiple projects,
each `ZoneRuntimeController` has its own pruner that only knows about its own project's
binding(s). The binding source closure must be scoped to this controller's own tiles/session —
it must NOT enumerate all sessions in tmux and reap any `continuum-*` name it finds. A stray reap
of another project's session would violate D16's detach-on-release safety property and silently
interrupt another project's agents.
