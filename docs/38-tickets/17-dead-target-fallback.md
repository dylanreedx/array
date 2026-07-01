# Dead-target to new-window fallback

Rests on decision **D25** (upgrade migration: bind via `tmuxWindowTarget`, with a dead-target
→ `new-window` fallback; never silently orphan) in `docs/38-locked-decisions.md`, and on
the topology spike's "Rebind under the new key" section
(`docs/2026-06-30-orchestration-spikes/TOPOLOGY.md`).

## What this delivers

When `restartTerminalTile` runs and the tile's persisted `tmuxWindowTarget` is no longer alive in tmux — because the user typed `exit` inside the pane, or ran `tmux kill-pane` from a CLI, or the pane simply never had a target captured (a pre-upgrade descriptor) — the tile is silently orphaned today: the ghostty surface relaunches with `-A` against the session but no longer lands at the correct window. After this ticket, the restart path performs an explicit liveness probe against the stored `tmuxWindowTarget`; if the pane is dead (or the field is nil), it creates a fresh window in the project session, captures the new `%pane_id`, persists it, and the tile binds cleanly to the new window. The tile retains its canvas identity — its `UUID`, frame, profile, cwd — throughout. The user's view snaps to a live terminal; nothing is dropped.

This means invariant I1 (tile ↔ window bijection, no orphan tile pointing at a dead target) holds unconditionally across restart.

## How it fits

This ticket is a direct continuation of the project-window spawn work delivered by the ticket
**"New terminal tile spawns a window in the project session, not a fresh session"**
(`docs/38-tickets/15-new-tile-new-window.md`). That predecessor is the one that (a) creates
the shared `continuum-proj-<projectId>` session via `TmuxControl.newSession` and adds windows
via `TmuxControl.newWindow`, (b) adds `tmuxWindowTarget: String?` to
`TerminalSessionDescriptor` with `decodeIfPresent` decoding and `currentSchemaVersion` bumped
from 2 to 3, and (c) captures + persists the `%pane_id` at spawn. This ticket must not begin
until ticket 15 is merged: without ticket 15 there is no `continuum-proj-<projectId>` session
for the fallback to target, no `TmuxSession.projectSessionName(projectId:)` to name it (that
function is introduced by ticket 14, **"Project session naming & lifecycle ownership"**,
`docs/38-tickets/14-project-session-naming.md`, on which ticket 15 depends), and no
`tmuxWindowTarget` field to probe or write. The injectable `TmuxControl` seam (protocol +
`InMemoryTmuxControl` + `ProcessTmuxControl`) comes from ticket 12,
**"Injectable substrates"** (`docs/38-tickets/12-injectable-substrates.md`); this ticket
consumes it, it does not create it.

With that predecessor in place, ticket 15 already does the *happy-path* rebind — re-run the
create path and capture a target — but it deliberately defers the *liveness check*: it does
not probe the stored target and reuse a live pane, and its restart path does not yet detect a
dead target before creating a replacement. This ticket adds exactly that missing piece: probe
the stored `tmuxWindowTarget`, reuse the window when it is alive, and take the compensating
new-window fallback only when the probe fails or the field is nil.

The TOPOLOGY spike names this behavior explicitly in its "Rebind under the new key" section: "fallback when the window can't be re-found (target nil, pane dead, or session gone): spawn a new window in the project session, capture a new `tmuxWindowTarget`, and persist it." This ticket operationalizes that prose into a concrete, tested implementation.

It unblocks the de-mirror work (grouped view-sessions, `docs/38-tickets/27-grouped-view-session.md`): grouped view-sessions can only be pinned to a window if the rebind path reliably holds a live `tmuxWindowTarget`. A dead-target fallback that silently succeeds (by producing a fresh live target) is the safety net that makes the de-mirror path confident.

## The approach

The rebind path in `restartTerminalTile` adds a liveness probe before it builds the new runtime. The probe is `TmuxControl.isAlive(paneTarget:)` — the async liveness call already introduced by ticket 12's substrate (it shells out `tmux display -p -t <target> '#{pane_id}'` inside `ProcessTmuxControl` and returns pre-programmed results inside `InMemoryTmuxControl`). If the probe returns `true`, the target is alive and the existing reattach path proceeds unchanged, reusing the same window. If the probe returns `false`, or `tmuxWindowTarget` is nil, the fallback fires: `TmuxControl.newWindow(inSession: continuum-proj-<projectId>, cwd:, innerCommand:)` creates a replacement window and returns the new `%pane_id`; if that call throws because the project session no longer exists, the code falls back to `TmuxControl.newSession(name: continuum-proj-<projectId>, cwd:, innerCommand:)` — which uses tmux `-A` (create-or-attach) semantics and lands in the session's first window — exactly the try/`newWindow`-then/`newSession` pattern ticket 15 already established for the spawn path. The returned pane id is stored as the descriptor's new `tmuxWindowTarget`, the descriptor is persisted, and the newly constructed runtime uses the updated descriptor. The tile does not close; its canvas frame, profile id, and cwd are all preserved.

The liveness probe is a single tmux query against a pane id — an O(1) call with no enumeration. It adds negligible latency to the restart path.

The fallback produces exactly the same observable state as a first-time spawn: a live `%pane_id`, a persisted descriptor with a valid `tmuxWindowTarget`, and a ghostty surface attached to the right window. There is no special-casing in downstream code for "this was a fallback" — the path converges.

## Where it lives

**Primary implementation site — `Sources/ContinuumRevived/App/TileSpawner.swift`:**

- `restartTerminalTile(tileId:)` — the method begins at line 276 (`func restartTerminalTile`). The persisted descriptor is loaded at line 303 (`let persistedDescriptor = try? projectStore.listSessions().first(where:)`) and `restoredCwd` is derived at line 304. The `tmuxWrappedProfileIfAvailable` call is at line 312, and the `TerminalSessionDescriptor(...)` is built starting at line 332. **The probe-and-fallback block is inserted between line 304 (after `restoredCwd` is derived) and line 312 (before the wrap), so the descriptor built at line 332 can pass the resolved target into its new `tmuxWindowTarget` argument** (that argument is added to the initializer by ticket 15). Read `persistedDescriptor?.tmuxWindowTarget` here and either validate it (reuse) or replace it (fallback).
- The project id the fallback targets comes from the existing `terminalProjectContextProvider` closure — a stored `var terminalProjectContextProvider: (() -> ProjectEntry?)?` at line 45, already wired to `activeZoneProjectEntry()` at `ContinuumApp.swift:2423-2425`. Read it as `terminalProjectContextProvider?()?.id` (a `UUID?`; `ProjectEntry.id` is a `UUID`, defined at `Sources/ContinuumRevivedCore/Registry.swift:164-165`). There is no `activeProjectId()` symbol — the project id is this provider's `.id`. When the provider yields nil (ambient tile, no project context), there is no project session and no fallback runs; the tile takes the unchanged per-tile restart path (see "Watch out for").
- The tmux binary path comes from the existing `tmuxPathResolver` closure — `private let tmuxPathResolver: (UserDefaults) -> String?` at line 35, already used by `tmuxWrappedProfileIfAvailable` at line 223. `tmuxPathResolver(defaults) == nil` means tmux is disabled/absent; in that case the probe and fallback are skipped entirely.
- The probe and the window/session creation go through the **injectable `TmuxControl`** the spawner already holds for the ticket-15 spawn path — the same instance ticket 15 wired into `TileSpawner` (an `InMemoryTmuxControl` in checks, a `ProcessTmuxControl` in production). This ticket does **not** introduce a bespoke `probePane` helper or shell out through any `tmuxProcessRunner` (no such symbol exists in `TileSpawner.swift` — the only process-runner in that file's neighborhood is `tmuxPathResolver`; the raw `tmuxProcessRunner` used for kill-session lives in `ContinuumApp.swift`, not here). Reusing `TmuxControl` keeps this ticket on the same seam as tickets 12/15/16 and makes it drivable by `InMemoryTmuxControl` in the check harness.

**Descriptor type — `Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift`:**

- `tmuxWindowTarget: String?` must already exist on `TerminalSessionDescriptor` and `currentSchemaVersion` must already be 3 — both delivered by ticket 15. This ticket's logic reads and writes the field but does not own the schema change. If the field is absent, this ticket cannot compile; that is the hard predecessor gate. (The v2-back-compat decode via `decodeIfPresent` is also ticket 15's; this ticket only relies on nil being a valid, decodable value.)

## Implementation breadcrumbs

```swift
// In restartTerminalTile, inserted after restoredCwd is derived (line 304) and before
// the tmuxWrappedProfileIfAvailable call (line 312). All TmuxControl calls are async;
// restartTerminalTile becomes async, or this block runs inside the existing async context
// ticket 15 established for the spawn/restart path.

let tmuxPath = tmuxPathResolver(defaults)                  // nil if tmux disabled/absent
let projectId = terminalProjectContextProvider?()?.id      // nil for ambient (no project session)
let storedTarget = persistedDescriptor?.tmuxWindowTarget

// Liveness probe: only when tmux is enabled AND we have a target to check.
let targetIsAlive: Bool
if tmuxPath != nil, let target = storedTarget {
    targetIsAlive = (try? await tmuxControl.isAlive(paneTarget: target)) ?? false
} else {
    targetIsAlive = false
}

// Resolve the target the rebuilt descriptor will carry.
let resolvedTarget: String?
if targetIsAlive {
    resolvedTarget = storedTarget                          // reuse the live pane
} else if tmuxPath != nil, let projectId {
    // Fallback: create a replacement window in the project session.
    let session = TmuxSession.projectSessionName(projectId: projectId)  // from ticket 14
    let inner = innerCommand(for: profile)                 // same helper ticket 15 uses
    resolvedTarget = try? await {
        do {
            // Subsequent-window case: session already exists.
            return try await tmuxControl.newWindow(inSession: session, cwd: restoredCwd, innerCommand: inner)
        } catch {
            // Session-doesn't-exist case: -A create-or-attach lands in the first window.
            // This is the SAME create-or-fallback pattern ticket 15 uses at spawn — NOT an
            // open either/or. newSession wraps `new-session -A -s <session>`; newWindow
            // cannot create a missing session, so newSession is the create path.
            return try await tmuxControl.newSession(name: session, cwd: restoredCwd, innerCommand: inner)
        }
    }()
    // resolvedTarget is the captured "%N" pane id, or nil if BOTH calls failed.
} else {
    resolvedTarget = nil                                   // tmux disabled or ambient tile
}
```

```swift
// The descriptor built at line 332 gains the resolved target (tmuxWindowTarget arg
// added to the initializer by ticket 15):
let descriptor = TerminalSessionDescriptor(
    id: runtime.id,
    tileId: tile.id,
    // ... existing fields unchanged ...
    scrollback: persistedDescriptor?.scrollback,
    tmuxWindowTarget: resolvedTarget
)
// persisted by the existing saveSession call at line 348.
```

The key invariant to enforce in code: if both the `newWindow` and `newSession` calls fail (tmux not running, permission issue), `resolvedTarget` is nil and the fallback must not leave the tile in a worse state than before. A nil `resolvedTarget` is valid — the tile still restarts, it just won't have a target to probe on the next restart (falling back again). This is graceful, not a crash. (If the requirement is instead to surface the failure, return `.failure` from the existing error path — see "Watch out for"; either way, do not delete the tile.)

## How we test it

### Logic (pure Core / harness checks)

Drive these in the check harness (`ContinuumRevivedCoreChecks`, or the existing `TileSpawner`
self-check suite for the restart-path cases) using `InMemoryTmuxControl` from ticket 12 — no
daemon, no ghostty, no app:

1. **Nil target round-trips cleanly.** Construct a `TerminalSessionDescriptor` with `tmuxWindowTarget: nil`, encode it to JSON, decode it — the decoded value's `tmuxWindowTarget` is nil. (This is ticket 15's decode contract; re-asserting it here guards the field this ticket reads.)
2. **Target round-trips cleanly.** Same with `tmuxWindowTarget: "%42"` — decoded value equals `"%42"`.
3. **Probe reuses a live target.** Wire a `TileSpawner` with an `InMemoryTmuxControl` seeded so `isAlive(paneTarget: "%5")` returns `true`, and a persisted descriptor whose `tmuxWindowTarget == "%5"`. Run the restart rebind logic. Assert `tmuxControl.log` contains an `isAlive("%5")` call, contains **no** `newWindow`/`newSession` call, and the rebuilt descriptor's `tmuxWindowTarget` is still `"%5"`.
4. **Dead target falls back to newWindow.** Seed `isAlive(paneTarget: "%5")` to return `false` and program `newWindow(inSession:)` to return `"%9"`. Run the rebind. Assert `tmuxControl.log` contains `isAlive("%5")` then `newWindow(inSession: "continuum-proj-<id>")`, and the rebuilt descriptor's `tmuxWindowTarget == "%9"` (not `"%5"`).
5. **Nil target falls back to newWindow.** Persisted descriptor has `tmuxWindowTarget == nil`. Run the rebind. Assert **no** `isAlive` call is made (nothing to probe), a `newWindow` call is made, and the rebuilt descriptor carries the returned non-nil target.
6. **Session-gone falls back to newSession.** Program `newWindow(inSession:)` to throw (session missing) and `newSession(name:)` to return `"%2"`. With a dead stored target, run the rebind. Assert the log shows `isAlive` → `newWindow` (throws) → `newSession(name: "continuum-proj-<id>")`, and the rebuilt descriptor's `tmuxWindowTarget == "%2"`. This is the concrete resolution of the session-doesn't-exist case — one behavior, not an either/or.
7. **Tmux disabled is a no-op.** Wire `tmuxPathResolver` to return nil. Run the rebind with any stored target. Assert `tmuxControl.log` is empty (no `isAlive`, no `newWindow`, no `newSession`) and the rebuilt descriptor's `tmuxWindowTarget` is unchanged from the persisted value.

### Backend (real-path integration)

This check drives `restartTerminalTile` against a real tmux server via `ProcessTmuxControl` — the same style as the topology self-checks that already live in `TileSpawner.swift`. It must go through the production code path, not a bypassed executor. It is gated on `TmuxLocator.resolve() != nil`; if tmux is absent it skips explicitly and records `tmux_absent=true` in the manifest (skip, never a silent pass).

Because the current spawn path is per-tile `continuum-<tileId>`, these checks must first stand
up a real `continuum-proj-<projectId>` session **through the production spawn path ticket 15
delivers** (via `ProcessTmuxControl.newSession` / `newWindow`), so the fallback has a real
project session to target. Do not hand-assert against a session no cited spawn path produces.

**Test: dead-target fallback creates a new window and persists the target.**

Setup: through the ticket-15 spawn path, create `continuum-proj-<projectId>` and spawn a tile in it; capture its `tmuxWindowTarget` (e.g., `%5`). `tmux kill-pane -t %5` (or `ProcessTmuxControl.killWindow(target: "%5")`) to make it dead. Call `restartTerminalTile(tileId:)`. Assert:
- The call returns `.restarted` (not `.failure`).
- `projectStore.listSessions().first(where: { $0.tileId == tileId })?.tmuxWindowTarget` is non-nil and differs from `%5`.
- The new target is alive: `ProcessTmuxControl.isAlive(paneTarget: newTarget)` returns true.
- The tile's canvas frame is unchanged (same origin, same size).
- Manifest records `oldTarget`, `newTarget`, `newTargetAlive`, `frameUnchanged` — measured values, never `{passed: true}`.

**Test: live-target reattach does not create a new window.**

Setup: through the ticket-15 spawn path, spawn a tile with a live `tmuxWindowTarget` in `continuum-proj-<projectId>`. Call `restartTerminalTile`. Assert:
- `tmuxWindowTarget` in the persisted descriptor is the same value as before the restart (the pane was reused, not replaced).
- `tmux list-windows -t continuum-proj-<projectId>` reports the same window count as before the restart (no extra window was created).

**Test: nil target (pre-upgrade descriptor) falls back gracefully.**

Setup: with a live `continuum-proj-<projectId>` session standing (from the ticket-15 spawn path), write a descriptor to the project store with `tmuxWindowTarget: nil` (simulating a pre-upgrade file). Call `restartTerminalTile`. Assert:
- Returns `.restarted`.
- The descriptor now has a non-nil `tmuxWindowTarget`.
- The new target is alive.

### UX (visual gate + dogfood snippet)

This feature has no visible UI of its own — the fallback is transparent to the user. The dogfood verification confirms the user never sees an error or a blank tile when their tmux pane was killed out-of-band.

**Dogfood snippet:**

1. Open Continuum with tmux persistence enabled and a project zone on canvas.
2. Spawn a new terminal tile in the project zone (this goes through ticket 15's project-window spawn, landing in `continuum-proj-<projectId>`). Note the tile's title.
3. In a separate terminal window, run `tmux list-panes -a` to find the pane id for that tile's pane (e.g., `%7`).
4. Kill the pane from outside: `tmux kill-pane -t %7`.
5. The tile in Continuum shows a crashed/exited state (black surface or exit message — existing behavior).
6. Click the tile's restart button (or invoke the restart keyboard shortcut for that tile).
7. **Expected:** the tile relaunches within two seconds, displaying a live shell prompt in the project's cwd. No error dialog. No "tile orphaned" message. The tile stays on the canvas in the same position. A second `tmux list-panes -a` shows a new pane id (not `%7`) in the project session for this tile.

The visual gate is: the restarted tile shows a live prompt at the correct cwd, and no second tile appears (the canvas tile count is unchanged).

## Execution mode

**Supervised.** The logic checks and the backend integration tests are fully automatable, but the dogfood gate requires visually confirming that the tile relaunches to a live prompt in the correct position — a claim that depends on ghostty surface creation, canvas layout, and real tmux process state cooperating. The real-path integration check proves the session/descriptor plumbing is correct; a human eye confirms the surface lands and no visual artifact appears. Per the verification doctrine, any change touching `GhosttyTerminalRuntime` creation and canvas view installation requires the real-app visual gate.

## Done when

- [ ] `restartTerminalTile` reads `persistedDescriptor?.tmuxWindowTarget`, probes it via `TmuxControl.isAlive(paneTarget:)` when non-nil and tmux is enabled, and takes the new-window fallback when the probe returns false or the field is nil.
- [ ] The fallback creates a replacement window via `TmuxControl.newWindow(inSession: continuum-proj-<projectId>, …)`, and falls back to `TmuxControl.newSession(name: continuum-proj-<projectId>, …)` (the `-A` create-or-attach path) when the session does not exist — the session-doesn't-exist case is resolved by this one pattern, matching ticket 15's spawn path.
- [ ] The project id is read from `terminalProjectContextProvider?()?.id`; no `activeProjectId()` symbol is introduced.
- [ ] The probe and creation go through the spawner's existing injectable `TmuxControl` (from ticket 12); no bespoke `probePane`/`tmuxProcessRunner` shell-out is added to `TileSpawner`.
- [ ] Logic check: a live stored target is reused — no `newWindow`/`newSession` call, target unchanged (harness with `InMemoryTmuxControl`).
- [ ] Logic check: a dead stored target falls back to `newWindow` and persists the new target.
- [ ] Logic check: a nil stored target skips the probe, falls back, and persists a non-nil target.
- [ ] Logic check: a `newWindow` throw (session gone) falls back to `newSession` and persists its target.
- [ ] Logic check: tmux disabled makes the whole block a no-op (empty `TmuxControl` log; stored target untouched).
- [ ] Backend integration test: kill-pane-then-restart leaves the tile alive with a new, live `tmuxWindowTarget` stored in the descriptor.
- [ ] Backend integration test: restart with live target does not create an extra tmux window (window count unchanged).
- [ ] Backend integration test: nil target (pre-upgrade descriptor) falls back and stores a live target.
- [ ] Dogfood: tile restarts to a live prompt after its backing pane was killed externally; canvas tile count is unchanged; tile is in the same canvas position.
- [ ] No existing self-checks regress. (This ticket does not change the spawn/wrap argv shape ticket 15 established — only the restart probe/fallback logic — so ticket 15's rewritten argv self-checks are unaffected.)

## Depends on / unblocks

**Depends on** the ticket **"New terminal tile spawns a window in the project session, not a fresh session"** (`docs/38-tickets/15-new-tile-new-window.md`), which delivers: the `continuum-proj-<projectId>` shared session (created via `TmuxControl.newSession`, windows via `TmuxControl.newWindow`), the `tmuxWindowTarget: String?` field on `TerminalSessionDescriptor` with `decodeIfPresent` decoding and `currentSchemaVersion` bumped to 3, and the capture-and-persist-at-spawn behavior. Ticket 15 in turn depends on ticket **"Project session naming & lifecycle ownership"** (`docs/38-tickets/14-project-session-naming.md`) for `TmuxSession.projectSessionName(projectId:)`. This ticket also consumes the `TmuxControl` protocol + `InMemoryTmuxControl` + `ProcessTmuxControl` from ticket **"Injectable substrates"** (`docs/38-tickets/12-injectable-substrates.md`). Do not begin this ticket until ticket 15 is merged and the `tmuxWindowTarget` field compiles. Rests on decision **D25**.

**Unblocks** the de-mirror work (grouped view-sessions, `docs/38-tickets/27-grouped-view-session.md`), which requires a reliably live `tmuxWindowTarget` at rebind time to issue a correct `select-window` to the right pane. It also unblocks the launch-time `continuum-*` sweep (the I3 backstop, `docs/38-tickets/…`), which will cross-reference live pane ids against stored targets and needs those targets to be trustworthy — a target that silently points at a dead pane would cause the sweep to incorrectly spare an orphan session.

## Watch out for

**The pane-id vs window-index trap.** tmux `newWindow`/`newSession` return a `%N`-prefixed pane id (`-P -F '#{pane_id}'` under the hood). This is the right thing to store — pane ids are stable for the pane's lifetime and survive client detach/reattach. Do not store the window index (the bare integer or `@N` form), which renumbers when other windows close and would alias to the wrong tile. `TmuxControl.isAlive(paneTarget:)` expects the `%N` form and tmux accepts it directly.

**The session-doesn't-exist-yet case is resolved, not open.** The fallback first tries `TmuxControl.newWindow(inSession: <projectSession>)`. If the project session was never created (e.g. first restart after upgrade when the migration created no project session), `newWindow` throws because the target session doesn't exist. The implementation handles this by falling back to `TmuxControl.newSession(name: <projectSession>, …)`, which wraps `new-session -A -s <session>` (create-or-attach) and lands in the session's first window — the identical pattern ticket 15 uses in its spawn path. This is a single deterministic behavior: **try `newWindow`, on throw call `newSession`.** It is not an implementer either/or, and no gating "does the session exist?" pre-check is required — the `-A` semantics make `newSession` idempotent. If **both** calls fail, `resolvedTarget` is nil; the tile restarts without a target and falls back again on the next restart (or return `.failure` from the existing error path if surfacing the failure is preferred). A nil target must never crash.

**Race: two restarts of the same tile in quick succession.** If the user triggers restart twice before the first `newWindow`/`newSession` call has completed, two windows could be created for one tile. Gate the restart path at the `TileSpawner` level with the same in-flight guard that other restart paths use (or add one if absent). Only one create call should be in-flight per tile at a time.

**Do not remove the tile on fallback failure.** If both create calls return an error (tmux not running, permission issue), the correct behavior is to return `.failure(error)` from `restartTerminalTile` — which is the existing error path — and leave the tile on canvas for the user to retry. Do not delete the tile's descriptor or remove it from the canvas as a cleanup action; that would silently destroy user state. The tile stays orphaned but deletable.

**tmux-disabled and ambient paths must be no-ops.** When `TmuxPersistenceConfig.enabled(defaults:)` returns false (so `tmuxPathResolver(defaults) == nil`), the probe and fallback must not run — there is no tmux server to query. Likewise when `terminalProjectContextProvider?()?.id` is nil (an ambient tile with no project session), there is no `continuum-proj-<projectId>` to target; the restart path falls through to the existing profile-only / per-tile restart exactly as today. No new behavior is introduced for non-tmux or ambient tiles.
