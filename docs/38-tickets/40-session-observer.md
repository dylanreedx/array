# SessionObserver: per-project agent detection, reader dispatch, and status budgets

## What this delivers

A `SessionObserver` — owned by `ZoneRuntimeController` — that watches every live terminal
tile in a project, detects which agent (if any) is running in each pane, dispatches the
correct `AgentStateReader` for that kind, calls `deriveAgentStatus` on the assembled
signals, and writes the result into `AgentDescriptor.status`. The observer is always on
and self-managing: it debounces file-watch bursts to 250 ms, caps status-change emissions
at 10 per minute per tile, and keeps tmux entirely out of the hot path (detection is
occasional, not per-tick).

From the user's perspective, every tile in the canvas and sidebar shows a status that
reflects what the agent is actually doing — blue for working, orange for attention, green
for done — and that status updates within roughly one second of the agent's own store
changing, without any polling loop hammering the disk or the tmux server.

From the system's perspective, this is the component that closes the loop between the
three concrete readers (Claude, Codex, Pi) and the `AgentDescriptor` field that the
sidebar tree, the zone rollup, and the future push path all consume. Nothing upstream of
this observer needs to know which store format a given agent uses; everything downstream
needs nothing more than `AgentDescriptor.status`.

## How it fits

The observer builds directly on two prior tickets. The closed `AgentKind` enum (the
agentKind closed enum ticket) is the type that lets the observer dispatch — switching on
`.claude`, `.codex`, `.pi`, `.shell`, `.unknown` is a compile-checked exhaustive match,
not a string comparison. The pure status-derivation function (the pure status-derivation
function ticket) is the observer's one output operation: once the reader produces an
`AgentSnapshot`, the observer fills a `StatusSignals` struct from it and calls
`deriveAgentStatus(signals:)` to get the `AgentStatus` it writes back. Without those two
tickets the observer cannot be typed correctly and cannot produce a verified status.

The observer also depends on the three concrete readers (Claude, Codex, and Pi) being
present and conforming to the `AgentStateReader` protocol defined in the reader-protocol
ticket. The Claude reader ticket, the Codex reader ticket, and the Pi reader ticket
produce those readers; the observer treats them as injectable protocol values and never
instantiates them itself — this is the seam that makes the observer testable with fakes.

What the observer unblocks is substantial. The sidebar rollup replacement (which swaps the
mock `WorkspaceSidebarView` data feed for real `AgentDescriptor` values) cannot be wired
until the observer is running. The zone status rollup (the `needs you` count badge on a
zone header) draws from the same data. The push path (APNS on `needsAttention` entry)
listens for status changes emitted by the observer. The consent-hook installation for
Claude (the one-time prompt that installs the `Notification` hook into
`~/.claude/settings.json`) must coordinate with the observer so the breadcrumb file lands
where the observer is already watching.

## The approach

The observer is a class that `ZoneRuntimeController` owns as a stored property and starts
when the controller reaches a live hydration state. It holds one entry per live terminal
tile: a `TileObservation` value that tracks the tile's detected `AgentKind`, the URL(s) it
is watching via FSEvents, the last-read `AgentSnapshot`, the current change counter (for
the 10-changes/min budget), and the debounce state.

Detection runs on a slow cadence — once on observer start and then whenever a tile's
`pane_current_command` changes. The observer does not call tmux every tick. It calls
`tmux display-message -p -t <windowTarget> '#{pane_current_command}'` once, maps the
result to an `AgentKind` using the same rule from the AGENT-READERS spike (`claude` →
`.claude`; `pi` → `.pi`; `codex` or `node` → probe for a rollout before committing;
anything else → `.shell` or `.unknown`), and then registers FSEvents watchers on the
agent's store paths. Detection re-runs only when a tile's underlying process changes —
which is detected by comparing the pane command across periodic tmux polls done on the
slow cadence (every 5 s).

The fast path is pure filesystem: FSEvents fires when any watched file changes, the
observer's debounce logic coalesces bursts within the 250 ms window, and the appropriate
reader is called. The reader returns an `AgentSnapshot`. The observer fills `StatusSignals`
from the snapshot's fields, calls `deriveAgentStatus`, and — only if the status actually
changed — writes the new value into `AgentDescriptor.status` and records the change
against the per-tile counter. If the tile has already emitted 10 status changes in the
current 60-second window, it drops further emissions (the status stays at its last written
value) until the window resets. This is the budget that prevents a thrashing agent from
flooding the UI.

Every reader is injected at construction time as an `AgentStateReader` protocol value.
`ZoneRuntimeController` passes the real readers in production; tests pass fakes. The tmux
query is similarly injected as a closure — `(TmuxWindowTarget) async throws -> String` —
so tests can supply canned `pane_current_command` responses without a live tmux server.

## The three seams this ticket pins (read before implementing)

This ticket writes `AgentStatus` back onto a persisted `AgentDescriptor`. Three collaborator
seams make that possible, and each is injected into `init` so the observer stays testable
with fakes and never reaches into `ZoneRuntimeController` internals. They are stated here
once, concretely, so nothing below is a guess.

**Seam 1 — how the observer obtains a tile's `windowTarget` and store join-keys.** The
observer does not read `windowTarget` off `TerminalSessionDescriptor` — that struct has no
such field (its fields are `tileId`, `cwd`, `lastStartedAt`, `agentDescriptor`, and the
usual launch fields). The captured-at-spawn `%pane_id` (`TmuxWindowTarget`, introduced by
the topology/spawn ticket per D25) lives in the runtime layer, keyed by `tileId`. The
observer takes an injected read-only accessor:

```swift
typealias WindowTargetLookup = @MainActor (UUID) -> TmuxWindowTarget?   // tileId → %pane_id
```

`ZoneRuntimeController` supplies a closure that resolves the tile's runtime and returns its
captured `windowTarget`; if the tile has no live runtime (no target yet), it returns `nil`
and the observer leaves the tile's kind untouched. The other join-keys the readers need —
`cwd` and `runId` — come straight off the `TerminalSessionDescriptor` the observer is
already handed (`descriptor.cwd`, `descriptor.agentDescriptor?.runId`). No new field is
added to any Core type.

**Seam 2 — how the observer writes and persists the status.** The observer holds **no**
`ProjectStore` reference and does **not** own the descriptor list (`ZoneRuntimeController`
does). It writes through a single injected callback:

```swift
typealias StatusWriter = @MainActor (_ tileId: UUID, _ status: AgentStatus, _ asOf: Date) -> Void
```

`ZoneRuntimeController` supplies the implementation, and it is the *only* place that
touches the store. Its body is exactly the load-mutate-save shape the controller's
`close()` path already uses for `lastExit`: look up the tile's persisted
`TerminalSessionDescriptor` by its store id, mutate `agentDescriptor.status` and
`agentDescriptor.statusUpdatedAt`, and call `projectStore.saveSession(descriptor)`. Because
`ProjectStore.saveSession`/`loadSession` are keyed by the descriptor's **store id**, not by
`tileId`, the controller's closure is responsible for the `tileId → descriptor` resolution
(it already maintains that mapping via its runtimes); the observer only ever speaks in
`tileId`. This keeps the persisted-vs-derived boundary on the controller side and matches
the "same pattern as the existing save-timer path" the previous draft only gestured at.

**Seam 3 — who owns hysteresis: the engine, not `deriveAgentStatus`.** `AgentStatusEngine`
(`Sources/ContinuumRevivedCore/AgentStatusEngine.swift:3`) is a **struct** whose `ingest`
and `tick` are `mutating` and which *already* performs hysteresis and stale detection
internally. `deriveAgentStatus(signals:)` is a **pure priority resolver** — it applies the
override order (pending approval > pending input > working > … > idle) over already-derived
inputs; it does **not** re-run hysteresis. To avoid double-derivation:

- The per-tile `AgentStatusEngine` is the single owner of hysteresis/stale timing. On each
  serviced read the observer feeds the reader's snapshot into the engine via
  `engine.ingest(.explicit(snapshot.status), at: now)` (an explicit status signal), which
  returns the hysteresis-smoothed status.
- That smoothed value is what fills `StatusSignals.engineStatus`. `deriveAgentStatus` then
  resolves it against the approval/input override flags and returns the final `AgentStatus`.
- `deriveAgentStatus` never applies time-based hysteresis of its own; the engine already did.

Because the engine is a value type, the observer must mutate the engine **in place inside
its `TileObservation`** (`observations[tileId]?.engine.ingest(...)`), never on a `let`-bound
copy — otherwise the mutation is discarded and hysteresis silently never advances. Every
helper that ticks or ingests takes the observation `inout` (see breadcrumbs).

## Where it lives

**Primary new type:** `SessionObserver` lives in a new file,
`Sources/ContinuumRevived/App/SessionObserver.swift`. It is `@MainActor` because it reads
and writes `ZoneRuntimeController`'s tile list and calls back into `AgentDescriptor` on
the main actor. All heavy file I/O dispatches to a dedicated serial queue and hops back to
`@MainActor` to write results.

**Owned by:** `ZoneRuntimeController`
(`Sources/ContinuumRevived/App/ZoneRuntimeController.swift`). Add a single stored
property:

```swift
// ZoneRuntimeController.swift — add below the existing timer properties (~line 24)
private var sessionObserver: SessionObserver?
```

Start the observer in `attachUI(canvasView:tileSpawner:focusBroker:)` (line 96) after
`focusBroker.activationFallbackSurfaces` is wired, constructing it with the three injected
seams above (the controller closes over `self` for the window-target lookup and the status
writer). Stop it in `close()` (line 78) before `flushPendingSaves()`.

**Reads from / writes to:**

- `AgentDescriptor.status` and `AgentDescriptor.statusUpdatedAt` on
  `TerminalSessionDescriptor` — the fields set by the observer on every confirmed status
  change, written exclusively through the injected `StatusWriter` (Seam 2). The observer
  itself never imports `ProjectStore`.
- `RunArtifactsWatcher` (`Sources/ContinuumRevivedCore/RunArtifactsWatcher.swift:25`) —
  reuse the debounce/rate-limit pattern. The observer borrows `RunArtifactsWatcherConfig`
  values but manages its own per-tile state rather than instantiating a
  `RunArtifactsWatcher` directly (the watcher is directory-keyed by runId; the observer
  is tile-keyed by `UUID`, and a Claude tile watches a JSONL, not a run directory).
- `AgentStatusEngine` (`Sources/ContinuumRevivedCore/AgentStatusEngine.swift:3`) — each
  `TileObservation` holds one `AgentStatusEngine` value for its tile. The engine owns
  hysteresis and stale detection (Seam 3); its `mutating` `tick(at:)` and `ingest(_:at:)`
  are called via `inout` on the observation, and its `status` output feeds
  `StatusSignals.engineStatus`.
- `deriveAgentStatus(signals:)` (defined by the pure status-derivation function ticket in
  `Sources/ContinuumRevivedCore/AgentStatusEngine.swift`) — the one call the observer
  makes to convert assembled signals into the written status. It is a pure priority
  resolver, not a second hysteresis pass.

**No changes to `AgentStatusEngine.swift` or `TerminalSessionDescriptor.swift`** beyond
what the prior tickets introduced. The observer is purely additive.

## Implementation breadcrumbs

```swift
// SessionObserver.swift

@MainActor
final class SessionObserver {
    // Injected readers — one per kind; keyed by AgentKind
    struct Readers {
        var claude: any AgentStateReader   // the Claude reader ticket
        var codex:  any AgentStateReader   // the Codex reader ticket
        var pi:     any AgentStateReader   // the Pi reader ticket
    }

    // Injected collaborators (the three seams)
    typealias PaneCommandQuery  = @MainActor (TmuxWindowTarget) async throws -> String
    typealias WindowTargetLookup = @MainActor (UUID) -> TmuxWindowTarget?               // Seam 1
    typealias StatusWriter       = @MainActor (_ tileId: UUID, _ status: AgentStatus, _ asOf: Date) -> Void  // Seam 2

    private struct TileObservation {
        var tileId: UUID
        var windowTarget: TmuxWindowTarget  // resolved via windowTargetLookup at detection
        var cwd: String                     // join-key for the reader's locate()
        var runId: String?                  // Pi join-key (descriptor.agentDescriptor?.runId)
        var detectedKind: AgentKind
        var engine: AgentStatusEngine       // per-tile hysteresis OWNER (Seam 3)
        var lastWrittenStatus: AgentStatus?
        // budget
        var changeCount: Int = 0
        var windowStart: Date = .distantPast
        // debounce
        var dirtyAt: Date?
        var readScheduled: Bool = false     // a one-shot read timer is pending
    }

    private var observations: [UUID: TileObservation] = [:]
    private let readers: Readers
    private let paneCommandQuery: PaneCommandQuery
    private let windowTargetLookup: WindowTargetLookup
    private let writeStatus: StatusWriter
    private let queue: DispatchQueue          // serial; off main actor for file I/O
    private var detectionTimer: DispatchSourceTimer?

    // Configuration (user-configurable; defaults from D13)
    var debounceInterval: TimeInterval = 0.250
    var maxChangesPerMinute: Int = 10
    var detectionPollInterval: TimeInterval = 5.0

    init(readers: Readers,
         paneCommandQuery: @escaping PaneCommandQuery,
         windowTargetLookup: @escaping WindowTargetLookup,
         writeStatus: @escaping StatusWriter) {
        self.readers = readers
        self.paneCommandQuery = paneCommandQuery
        self.windowTargetLookup = windowTargetLookup
        self.writeStatus = writeStatus
        self.queue = DispatchQueue(label: "continuum.session-observer", qos: .utility)
    }

    func start(tiles: [TerminalSessionDescriptor]) {
        // 1. Detect kind for each tile on first run, register FSEvents watchers.
        for descriptor in tiles {
            Task { await detectAndRegister(descriptor) }
        }
        // 2. Slow-cadence re-detection loop (every detectionPollInterval seconds).
        //    Checks pane_current_command; re-registers if the running process changed.
        //    This timer is DETECTION ONLY — it never services reads (see fileDidChange).
        scheduleDetectionTimer()
    }

    func stop() {
        detectionTimer?.cancel()
        detectionTimer = nil
        observations.removeAll()
        // cancel any pending FSEvents sources and any pending one-shot read timers
    }

    // Called from ZoneRuntimeController when a tile spawns or closes
    func tileDidSpawn(_ descriptor: TerminalSessionDescriptor) {
        Task { await detectAndRegister(descriptor) }
    }
    func tileDidClose(tileId: UUID) {
        observations.removeValue(forKey: tileId)
        // remove its FSEvents source
    }

    // MARK: - Detection

    private func detectAndRegister(_ descriptor: TerminalSessionDescriptor) async {
        // Seam 1: resolve the captured-at-spawn %pane_id from the runtime layer.
        guard let target = windowTargetLookup(descriptor.tileId) else { return }

        let comm: String
        do { comm = try await paneCommandQuery(target) }
        catch { return }   // tmux unavailable; leave existing kind in place

        let kind = AgentKind.detected(from: comm, cwd: descriptor.cwd, paneStartedAt: descriptor.lastStartedAt)
        // AgentKind.detected is a static helper that applies the D10/D14 detection rule:
        //   "claude" → .claude
        //   "pi"     → .pi
        //   "codex" | "node" → probe for rollout → .codex or .shell
        //   anything else → .shell or .unknown
        // It is a pure function on a background queue (no I/O for shell/claude/pi;
        // a rollout mtime scan for codex/node).

        if observations[descriptor.tileId]?.detectedKind == kind { return }  // no change

        var obs = TileObservation(
            tileId: descriptor.tileId,
            windowTarget: target,
            cwd: descriptor.cwd,
            runId: descriptor.agentDescriptor?.runId,
            detectedKind: kind,
            engine: AgentStatusEngine()
        )

        // Register FSEvents watcher for the store files this kind uses. The reader owns
        // path derivation via its own locate(); the observer asks the reader where to watch.
        // Claude: ~/.claude/projects/<encode(cwd)>/<sessionId>.jsonl + sessions/<pid>.json
        // Codex:  matched rollout-*.jsonl path
        // Pi:     <projectRoot>/.pi/agent-runs/<runId>/ + ~/.pi/agent-runs/<runId>/
        // Shell / unknown: no watcher (process signal only, via slow detection poll)
        registerWatcher(for: &obs)
        observations[descriptor.tileId] = obs
    }

    // MARK: - FSEvents callback → one-shot debounce timer (pins the 350 ms path)

    private func fileDidChange(tileId: UUID, at now: Date) {
        // Called on self.queue from the FSEvents source handler. The detection timer does
        // NOT service reads — a change schedules its OWN one-shot read timer so latency is
        // ~debounceInterval (250 ms), never up to detectionPollInterval (5 s).
        queue.async {
            guard var obs = self.observations[tileId] else { return }
            if obs.dirtyAt == nil { obs.dirtyAt = now }
            self.observations[tileId] = obs
            guard !obs.readScheduled else { return }   // a timer is already pending; coalesce
            obs.readScheduled = true
            self.observations[tileId] = obs
            // One-shot timer fires at (dirtyAt + debounceInterval). Any further changes
            // inside the window are absorbed (dirtyAt stays, no new timer) → one read.
            let fireDelay = self.debounceInterval
            self.queue.asyncAfter(deadline: .now() + fireDelay) {
                self.serviceRead(tileId: tileId, at: Date())   // real clock in production
            }
        }
    }

    // MARK: - Read + derive for ONE tile (on queue; result dispatched to main actor)

    private func serviceRead(tileId: UUID, at now: Date) {
        // Runs on self.queue. Services exactly the one tile whose one-shot timer fired.
        guard var obs = observations[tileId], obs.readScheduled, let dirtyAt = obs.dirtyAt
        else { return }
        // Debounce satisfied by construction (fired at dirtyAt + debounceInterval), but
        // recheck defends against a re-armed timer; if not yet elapsed, reschedule the remainder.
        let elapsed = now.timeIntervalSince(dirtyAt)
        if elapsed < debounceInterval {
            queue.asyncAfter(deadline: .now() + (debounceInterval - elapsed)) {
                self.serviceRead(tileId: tileId, at: Date())
            }
            return
        }
        obs.readScheduled = false
        obs.dirtyAt = nil

        // Budget check: reset window if > 60 s since window start
        if now.timeIntervalSince(obs.windowStart) >= 60 {
            obs.changeCount = 0
            obs.windowStart = now
        }
        guard obs.changeCount < maxChangesPerMinute else {
            observations[tileId] = obs
            return   // drop this read; budget exhausted for this window
        }
        observations[tileId] = obs

        // Dispatch the read; the reader owns locate() from the join-keys we hold.
        let kind = obs.detectedKind
        let locator = ReaderLocator(cwd: obs.cwd, runId: obs.runId, windowTarget: obs.windowTarget)
        guard let reader = self.reader(for: kind) else { return }
        guard let snapshot = try? reader.read(locator: locator) else { return }
        DispatchQueue.main.async {
            self.applyDerivedStatus(snapshot: snapshot, tileId: tileId, at: now)
        }
    }

    @MainActor
    private func applyDerivedStatus(snapshot: AgentSnapshot, tileId: UUID, at now: Date) {
        guard var obs = observations[tileId] else { return }

        // Seam 3: engine owns hysteresis. Ingest the reader's status as an explicit signal,
        // MUTATING the stored engine (never a let-copy). The returned value is smoothed.
        let smoothed = obs.engine.ingest(.explicit(snapshot.status), at: now)

        let signals = buildSignals(from: snapshot, engineStatus: smoothed, kind: obs.detectedKind, at: now)
        let derived = deriveAgentStatus(signals: signals)   // pure priority resolve; no hysteresis

        // Only write if status actually changed; count against the budget if so.
        guard derived != obs.lastWrittenStatus else {
            observations[tileId] = obs   // persist the engine mutation even when no write
            return
        }
        obs.changeCount += 1
        obs.lastWrittenStatus = derived
        observations[tileId] = obs

        // Seam 2: the injected writer does the load-mutate-saveSession on the controller side.
        writeStatus(tileId, derived, snapshot.asOf)
    }

    // MARK: - Helpers

    private func reader(for kind: AgentKind) -> (any AgentStateReader)? {
        switch kind {
        case .claude:  return readers.claude
        case .codex:   return readers.codex
        case .pi:      return readers.pi
        case .shell, .unknown, .managed: return nil
        }
    }

    private func buildSignals(from snapshot: AgentSnapshot, engineStatus: AgentStatus, kind: AgentKind, at now: Date) -> StatusSignals {
        // Map AgentSnapshot fields to StatusSignals fields. engineStatus is ALREADY
        // hysteresis-smoothed by the engine (Seam 3) — deriveAgentStatus does not re-smooth.
        return StatusSignals(
            agentKind: kind,
            hasPendingApproval: false,   // observed shell tiles: only managed sets these
            hasPendingUserInput: false,
            hookBreadcrumbPresent: snapshot.evidence.source == "hook",
            hookBreadcrumbAge: snapshot.evidence.source == "hook"
                ? now.timeIntervalSince(snapshot.asOf) : nil,
            isError: false,
            isStarting: false,
            isRunning: snapshot.status == .working,
            isCompleted: snapshot.status == .done,
            engineStatus: engineStatus
        )
    }
}
```

The reader locator — `ReaderLocator(cwd:runId:windowTarget:)` — is the join-key bundle the
observer hands the reader's `read(locator:)`. It carries only observer-local join keys
(`cwd`, `runId`, the `%pane_id` from which the reader may resolve a pid for Claude's
`sessions/<pid>.json` link); it never leaves the observer and is I5-clean by shape (no
bodies). The reader owns turning those keys into an actual store URL via its own `locate()`
(exactly the `locate(pid, cwd, runId?)` step in the AGENT-READERS spike) — the observer does
not build store paths itself. For a Claude tile the reader resolves `pid` from the
`windowTarget` (tmux pane pid), then `sessions/<pid>.json → sessionId → cwd`; for Pi it uses
`runId`; for Codex it uses `cwd` + spawn mtime. If the reader cannot locate a store it
returns `nil` and the observer writes nothing.

The detection helper — `AgentKind.detected(from:cwd:paneStartedAt:)` — is a static method
on `AgentKind` that implements exactly the rule from D10 and D14. For `codex` or `node`
it scans `~/.codex/sessions/**/rollout-*.jsonl` by mtime, reads only the first line of
each, and selects the newest rollout whose `session_meta.payload.cwd` matches the tile's
cwd and whose file mtime is after `paneStartedAt`. If no rollout matches, the command
falls back to `.shell`. This scan happens on a background queue and is the only place the
observer touches a directory listing during detection.

The FSEvents watcher per tile is a `DispatchSourceFileSystemObject` (or a
`FileSystemEventStreamRef`) registered on the specific JSONL or run-directory URL. When
the source fires it calls `fileDidChange(tileId:at:)` on the observer's serial queue, which
schedules the one-shot 250 ms read timer described above. Reuse the same
`directorySignature` pattern from `RunArtifactsWatcher` to avoid re-reading unchanged files.

## How we test it

### Logic (pure Core checks)

Write `SessionObserverTests` in `ContinuumRevivedCoreTests/`. The key test is the budget
enforcer: create a `SessionObserver` with injected fake readers, a fake `paneCommandQuery`,
a fake `windowTargetLookup`, and a fake `StatusWriter` that records every write. Drive it
with 15 simulated file-change events for the same tile within a 60-second window, and
assert that exactly 10 writes reach the fake `StatusWriter`. Each simulated event calls the
observer's internal `serviceRead(tileId:at:)` directly via `@testable import` (or a thin
internal testing hook), supplying a controllable `now` date. Assert the 11th through 15th
events are dropped silently (no write, status stays at the last written value).

A second test covers the debounce: fire 5 rapid file-change events within 100 ms (all
within the 250 ms debounce window) so only one one-shot timer is armed, then fire one event
at 300 ms. Assert exactly one read reaches the fake reader per window (two total). The `now`
parameter is the control lever — inject it as a value, never call `Date()` inside the budget
or debounce logic.

A third test covers the kind-detection dispatch table: feed `pane_current_command` values
of `"claude"`, `"pi"`, `"zsh"`, and `"node"` (with no matching rollout present) and
assert the resolved `AgentKind` values are `.claude`, `.pi`, `.shell`, and `.shell`
respectively. This is pure logic; no actual tmux is called.

A fourth test pins Seam 3 (hysteresis ownership): feed the observer a reader snapshot
sequence `working → idle` inside the engine's `workingHysteresis` window and assert the
written status stays `working` (the engine smoothed it), and that a second identical
`idle` snapshot after the window elapses writes `idle` exactly once. This proves the engine
— not `deriveAgentStatus` — owns time-based smoothing and that the engine mutation persists
across reads (the `inout`/subscript mutation, not a discarded copy).

All four tests run with `swift test --filter SessionObserverTests`, zero daemons, zero
real file I/O beyond fixture files in the test bundle.

### Backend (real-path / integration, not bypassed)

The integration check drives a real tmux session. Using the injectable substrate from the
injectable substrates ticket (`TmuxControl` fake is already planned, but this test uses
the real `tmux` binary with a throwaway session):

1. Create a throwaway tmux session with a window running a sentinel shell script that
   writes a two-event Claude-style JSONL to a temp path at intervals.
2. Start the observer pointed at that temp path, with real FSEvents, the real one-shot
   debounce timer, and the real Claude reader. The `StatusWriter` records the timestamp of
   each write into an array the test inspects.
3. Assert that within 350 ms of the JSONL write, the recorded `StatusWriter` write for that
   tile transitions from `.idle` to `.working`. The timing assertion uses a 1-second
   timeout with polling every 50 ms — not a fixed sleep. The 350 ms budget is meetable
   because the read is scheduled by the per-change one-shot timer at ~250 ms, not by the
   5 s detection poll.
4. Stop the observer. Assert no further status changes arrive after stop.

This test lives in `ContinuumRevivedCoreTests/` (not the UI test bundle) because it uses
real filesystem and real tmux but no AppKit. Run it with `swift test
--filter SessionObserverIntegrationTests`. It may be skipped in CI environments without
tmux by checking for tmux availability before running (`guard let _ = which("tmux") else {
throw XCTSkip("tmux not available") }`).

### UX (visual gate + dogfood snippet)

**Visual gate:** In the running app, open the Component Lab (menu bar Developer →
Component Lab) and navigate to the Sidebar Tile fixture. Before this ticket, the status
badges are driven by hardcoded mock data. After this ticket, the fixture should still
render cleanly (no crash, no empty rows) — the mock data path is not removed by this
ticket, so the visual gate is a non-regression check.

**Dogfood snippet:** Open the app with at least one terminal tile running an active Claude
session (the session must be started as a normal `claude` invocation, not a Continuum
harness run). Look at the sidebar row for that tile. Within 1 second of Claude beginning a
tool call (which appends an `assistant` event with `stop_reason == tool_use` to the
`.jsonl`), the sidebar row's status indicator should flip from the grey `idle` ring to the
blue `working` pulse. No manual refresh, no app restart. Confirm by watching Claude run a
Bash tool — the status indicator should turn blue when the tool call appears and revert to
grey `idle` within the `idleWindow` (120 s default) after Claude's final `end_turn` event.

To verify the budget: open 5 tiles, each running a rapid-writing script that touches a
Claude JSONL every 2 seconds. After 60 seconds, confirm in the app logs (or via a
temporary `print` in the injected `StatusWriter`) that each tile emitted at most 10 status
changes. The sidebar should not flicker faster than the budget allows.

## Execution mode

**Supervised.** The observer integrates three moving parts — FSEvents, tmux process
detection, and per-tile reader dispatch — and its correctness at the UI layer depends on
live filesystem events firing in the correct sequence. The logic, budget, debounce, and
hysteresis-ownership tests are fully autonomous (deterministic, clock-injected). The
integration test requires a real tmux binary and is skippable in CI but must run on the
developer machine. The dogfood snippet requires a real Claude session running in a tile and
a human observing the sidebar transition in real time. The verification doctrine requires a
real-path check with a live process and a visual gate, neither of which is satisfiable by a
unit test alone.

## Done when

- [ ] `SessionObserver.swift` exists in `Sources/ContinuumRevived/App/` and compiles
  cleanly with no warnings.
- [ ] `ZoneRuntimeController` holds a `private var sessionObserver: SessionObserver?`,
  constructs it with the injected window-target lookup and status-writer closures, starts
  it in `attachUI(canvasView:tileSpawner:focusBroker:)`, and stops it in `close()`.
- [ ] The observer never imports `ProjectStore` and never reads a `windowTarget` field off
  `TerminalSessionDescriptor`; it obtains the `%pane_id` via the injected
  `WindowTargetLookup` and persists via the injected `StatusWriter` (the controller does
  the load-mutate-`saveSession`, same shape as the `lastExit` write in `close()`).
- [ ] The observer dispatches to the correct reader for `AgentKind` values `.claude`,
  `.codex`, and `.pi`, and silently skips `.shell` and `.unknown`.
- [ ] The 250 ms debounce is applied per tile via a per-change one-shot read timer (not the
  detection poll): rapid file-change events within 250 ms arm exactly one timer and coalesce
  to one read. The debounce interval is a stored property (not a constant) and uses an
  injected `now: Date` parameter throughout — never `Date()` in the budget/debounce logic.
- [ ] The 10-changes/min/tile budget is enforced: the 11th status change within a 60 s
  window is dropped without invoking the `StatusWriter`. The window and cap are stored
  properties, not literals.
- [ ] Hysteresis is owned by the per-tile `AgentStatusEngine` (mutated in place on the
  stored `TileObservation`, never on a `let` copy), and `deriveAgentStatus` consumes the
  already-smoothed `engineStatus` without re-deriving — no double-derivation.
- [ ] The slow detection poll runs every 5 s on a `DispatchSourceTimer`, calls
  `pane_current_command` via the injected closure, and re-registers the FSEvents watcher
  only when the detected kind changes. The detection timer never services reads.
- [ ] tmux is never called in the FSEvents callback path (the fast path is pure
  filesystem).
- [ ] The budget logic test passes: 15 events in 60 s → exactly 10 writes reach the
  `StatusWriter`.
- [ ] The debounce logic test passes: 5 events in 100 ms + 1 event at 300 ms → exactly 1
  reader call per window.
- [ ] The hysteresis-ownership test passes: `working → idle` inside the hysteresis window
  keeps the written status `working`; `idle` after the window writes `idle` once.
- [ ] The detection dispatch test passes: `"claude"` → `.claude`, `"pi"` → `.pi`,
  `"zsh"` → `.shell`, `"node"` (no rollout) → `.shell`.
- [ ] The integration test (real tmux + real JSONL write) passes on the developer machine:
  the `StatusWriter` records a `.working` transition within 350 ms of the JSONL append.
- [ ] The dogfood snippet produces the described sidebar transition with a live Claude
  session: `idle` ring → `working` pulse within 1 s of a tool-call event appearing in the
  JSONL.
- [ ] `swift build` passes with no new warnings. No existing tests are broken.

## Depends on / unblocks

This ticket depends on the agentKind closed enum ticket to be complete — `AgentKind` must
exist as a typed enum before the observer can dispatch on it or fill `StatusSignals`. It
depends on the pure status-derivation function ticket to be complete — `deriveAgentStatus`
and `StatusSignals` must exist before the observer can call them. It depends on the three
concrete reader tickets (the Claude reader ticket, the Codex reader ticket, the Pi reader
ticket) to be at least sufficiently complete that the `AgentStateReader` protocol exists
and each reader conforms to it; the observer is written against the protocol, so
partially-complete readers (e.g., a Claude reader that handles only the `idle`/`working`
states) are sufficient to unblock implementation and testing. It depends on the
topology/spawn ticket that captures `%pane_id` at spawn (per D25) for the `TmuxWindowTarget`
the `WindowTargetLookup` seam resolves.

The injectable substrates ticket is a soft dependency: the observer is written to accept
injected collaborators from the start, so the full `TmuxControl` fake substrate is not
required before the observer is written — but the integration test benefits from having it.

This ticket unblocks: the sidebar rollup replacement (which wires real `AgentDescriptor`
values into `WorkspaceSidebarView`), the zone rollup count badge, the consent-hook
installation flow (which needs an active observer to receive the breadcrumb the hook
writes), and the APNS push path (which listens for `needsAttention` status transitions
emitted by the observer).

## Watch out for

**The single hardest thing to get right is the budget-and-debounce interaction when a
tile's agent is writing events rapidly.** A Pi overnight run can append to `events.jsonl`
dozens of times per minute during an iteration. The per-change one-shot timer must coalesce
those writes into one read per debounce window, and the budget must cap the number of
downstream `StatusWriter` invocations. If either check is implemented with `Date()` at the
read site instead of injected clock values, the tests cannot control timing and will be
flaky. Use the injected `now` on every path that touches `dirtyAt`, `windowStart`, or
`changeCount` — no exceptions.

**Never call tmux inside the FSEvents callback.** The FSEvents source fires on the
observer's serial queue. If you call the tmux query from that callback — to re-detect the
kind after a file change, for example — you will either deadlock (if the query awaits on
the main actor while the queue is blocked) or introduce unbounded latency on the fast
path. Detection lives exclusively in the slow-cadence timer. The fast path is file read,
signal assembly, status derivation, and main-actor write — nothing else.

**Never mutate the engine on a copy.** `AgentStatusEngine` is a struct with `mutating`
methods. Ingesting or ticking on a `let`-bound `TileObservation` (or on a `for (_, var obs)`
loop copy that is never written back) silently discards the hysteresis state, so smoothing
never advances and the status flickers. Always mutate through the dictionary
(`observations[tileId]?.engine.ingest(...)`) or an explicit `inout` and write the
observation back.

**The Codex no-pid-link case must not crash or fabricate.** When the observer is
registering an FSEvents watcher for a Codex tile, it may find zero rollouts matching the
tile's cwd (rare, but possible if the tile started before Codex wrote its first line). In
that case the observer leaves the tile's kind as `.codex` (the detection already matched),
registers no watcher, and writes the status as `.configuring` — it does not guess a
rollout path. The watcher is registered again on the next slow-cadence detection pass
after a rollout appears. Under-claiming is always correct; over-claiming (attaching a
wrong rollout's status to this tile) is the invariant I6 violation that must be avoided.

**`stop()` must be called before deallocation.** The observer holds `DispatchSourceTimer`
and FSEvents sources that retain the observer. If `ZoneRuntimeController.close()` fails to
call `stop()` before releasing its reference, the observer leaks. The `close()` path in
`ZoneRuntimeController` already has a guard against double-close (`isClosed`); the
observer's `stop()` must be idempotent and safe to call multiple times, and must cancel any
pending one-shot read timers as well as the detection timer.
