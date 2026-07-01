# New terminal tile spawns a window in the project session, not a fresh session

## What this delivers

When a user spawns a terminal tile inside a project zone, the tile's process now lives as a
single-pane window in the project's shared tmux session (`continuum-proj-<projectId>`) instead
of an isolated per-tile session (`continuum-<tileId>`). Because all tiles in a project share one
session, the new window inherits the environment of the session — shell functions, exported
variables, any background processes the user launched in an earlier tile — for free, with no
re-`cd` ceremony. Three tiles in the same project become one tmux session and three windows; the
expensive-session-per-tile design that motivated the whole topology program is gone for project
zones.

From the system's perspective the binding is explicit and durable: the exact pane id (`%N`) of
the new window is captured immediately after the `new-window` call and persisted into the
descriptor synchronously. This is the seam every downstream ticket (liveness probe, dead-target
fallback, idle reaper, de-mirror attach) depends on.

## How it fits

This ticket is the first behavior change in phase 1 and the one that makes the topology shift
real. It builds directly on the project session naming and ownership work (which provides
`TmuxSession.projectSessionName(projectId:)` and establishes the per-project `ZoneRuntimeController`
as the session owner) and on the injectable substrates (which provide `TmuxControl` and
`InMemoryTmuxControl` so spawn logic can be exercised in the check harness without a live tmux
daemon).

It immediately unblocks three follow-on tickets: the cwd inheritance policy (which can only be
wired once there is a `new-window` code path that accepts a cwd), the close-tile kill-window
change (which needs a real `tmuxWindowTarget` on the descriptor to know which window to kill),
and the dead-target fallback (which is the graceful-degradation arm of the exact rebind logic
introduced here).

For ambient/group-zone tiles — those where `ZonePlacement.projectId == nil` — this ticket makes
no change. They stay on the existing per-tile `continuum-<tileId>` session model, exactly as the
locked decision mandates for phase 1. The per-tile code path in `TileSpawner` is preserved intact
and gated by the presence of a `projectId`.

## The approach

### The one mechanism this ticket uses (and the one it does not)

There are two conceivable ways to capture the new pane's id, and this ticket commits to
exactly one. Read this first, because the rest of the ticket assumes it and every breadcrumb
below is written to it.

**Rejected:** letting ghostty run `tmux new-window … -P -F '#{pane_id}'` as its own argv and
reading the pane id back. This cannot work. Ghostty forks a pty and runs the argv *inside* it;
the `-P` output goes to that pty (rendered as terminal text), not to any Swift `Process` pipe
Continuum can read. There is no code path by which Swift sees ghostty's child stdout. So this
ticket never puts `-P -F '#{pane_id}'` in ghostty's argv. (This is why the old `newWindowArgv`
breadcrumb is gone — it built exactly the impossible thing.)

**Adopted — the two-step create-then-attach:**

1. **Create the window out-of-band and capture its pane id, via the injectable
   `TmuxControl` substrate** (the phase-0 harness dependency; fake in checks,
   `ProcessTmuxControl` running real `tmux` in production). `TmuxControl` runs `tmux` as a
   Swift `Process` whose stdout *is* readable, so `-P -F '#{pane_id}'` works there. The
   substrate call returns the captured `%pane_id` as its Swift return value. Continuum decides
   which substrate call to make (see next section):
   - first tile in the project → `TmuxControl.newSession(name:cwd:innerCommand:)` →
     runs `tmux new-session -d -s continuum-proj-<projectId> -c <cwd> -P -F '#{pane_id}' [-- inner]`
     and returns the first window's pane id.
   - subsequent tiles → `TmuxControl.newWindow(inSession:cwd:innerCommand:)` →
     runs `tmux new-window -t continuum-proj-<projectId> -c <cwd> -P -F '#{pane_id}' [-- inner]`
     and returns the new window's pane id.
   Both create the window **detached** (`new-session -d`; `new-window` is detached by
   default). The window fully exists, with a known pane id, before ghostty is involved.

2. **Attach ghostty to the already-created window.** Only *now* does Continuum build a
   `LaunchProfile`. Its argv is a plain attach to the captured pane target — no window
   creation, no `-P`:

   ```
   tmux attach-session -t <capturedPaneId>
   ```

   Attaching with a pane target (`%N`) selects that pane's window, so ghostty lands on exactly
   the window step 1 created. This is a *plain re-attach* — deliberately not the grouped
   view-session form (`new-session -t <proj> -s continuum-view-<tileId> \; select-window …`).
   Grouped view-sessions and their `continuum-view-<tileId>` naming/cleanup are **D19's job
   (the de-mirror ticket) and are explicitly out of scope here.** This ticket ships the plain
   attach; the de-mirror ticket swaps this one argv for the grouped form. Because two tiles
   attaching plainly to two *different* pane targets already land on two different windows, the
   plain form is correct for the single-tile-per-window default and only becomes insufficient
   when de-mirror needs per-client active-window isolation.

**The net contract.** `TmuxControl.newSession`/`newWindow` is called first, its returned
`%pane_id` is stored as `tmuxWindowTarget` on the descriptor, the descriptor is saved
synchronously before `.spawned(runtime)` is returned, and only then does ghostty attach via the
plain `attach-session -t <paneId>` profile. A save failure after window creation is a
compensating-action site: call `TmuxControl.killWindow(target: capturedId)` before returning the
error so no orphan window accumulates.

### Deciding first-tile vs. subsequent-tile — a deterministic session-exists check, not try/catch

Whether to call `newSession` or `newWindow` must be decided *before* the call, deterministically,
so the acceptance assertion ("exactly one `newSession` and two `newWindow` calls" for three
tiles) is achievable. A try-`newWindow`-catch-fall-back-to-`newSession` strategy cannot do this:
on the first tile it would log a failed `newWindow` attempt *and then* a `newSession`, breaking
the call-count assertion and leaving a stray error in the log.

This ticket therefore requires one read-only probe on the `TmuxControl` substrate:

```
TmuxControl.sessionExists(name:) -> Bool
```

The fake answers it from its in-memory session map; `ProcessTmuxControl` answers it with
`tmux has-session -t <name>` (exit status 0 = true). The dispatcher branches on it:

- `sessionExists("continuum-proj-<projectId>") == false` → call `newSession` (this is the first
  tile; it creates the session and its first window).
- `sessionExists(...) == true` → call `newWindow` (a window is added to the existing session).

This is the *only* new query surface this ticket asks of the substrate, and it is read-only.
Deeper liveness probing of a specific `tmuxWindowTarget` (is this pane still alive on restart?)
is **not** this ticket's job — it belongs to the rebind/dead-target-fallback ticket. This ticket
only needs "does the project session exist yet," which `has-session` answers exactly.

> **Substrate dependency, stated plainly.** `TmuxControl` (with `newSession`, `newWindow`,
> `killWindow`, and `sessionExists`), its `InMemoryTmuxControl` fake, and `ProcessTmuxControl`
> come from the phase-0 harness (D26) and are a hard dependency of this ticket (see *Depends on*).
> If the harness's `TmuxControl` does not yet expose `sessionExists`, adding it is part of *this*
> ticket's landing — it is a one-line read-only method and the acceptance criteria below cannot
> be met without it.

`tmuxWrappedProfileIfAvailable` in `TileSpawner.swift` is the current chokepoint. It becomes a
dispatcher: if a `projectId` is available (from `terminalProjectContextProvider`) and tmux is
enabled, it runs the create-then-attach path — `TmuxControl.sessionExists` → `newSession`/
`newWindow` to create the detached window and capture its pane id → `TmuxSession.attachWindowProfile`
to build the plain-attach profile — and returns `(attachProfile, capturedPaneId)`; otherwise it
falls back to the existing `TmuxSession.wrap` per-tile path unchanged. The `projectId` comes from
`terminalProjectContextProvider()?.id`, which is already wired to `activeZoneProjectEntry()` at
`ContinuumApp.swift:2423-2425`.

## Where it lives

**`Sources/ContinuumRevivedCore/TmuxSession.swift` — lines 8–33 (the pure argv constructors).**
Add two new static functions: `projectSessionName(projectId: UUID) -> String` alongside
`sessionName(tileId:)` at line 8, and `attachWindowProfile(paneTarget:cwd:tmuxPath:) -> LaunchProfile`
alongside `wrap(profile:tileId:tmuxPath:)` at line 12. `attachWindowProfile` builds the *plain
attach* profile ghostty runs after the window already exists — argv
`["attach-session", "-t", paneTarget]`, command = `tmuxPath`, cwd = `cwd`. It creates nothing and
carries no `-P`; it only connects to the already-created pane's window. This is the load-bearing
attach seam. The existing `sessionName`, `wrap`, and `killSessionCommand` functions are untouched.
There is deliberately **no** `wrapWindow`/`newWindowArgv` here that puts `-P -F '#{pane_id}'` in
ghostty's argv — capture happens through `TmuxControl` (see *The approach*), never through
ghostty's stdout.

**`Sources/ContinuumRevived/App/TileSpawner.swift` — `tmuxWrappedProfileIfAvailable(_:tileId:)`
at line 221 and the private `spawnTerminal(profile:launchProfileId:agentDescriptor:createdAt:at:allowTmuxPersistence:)`
at line 151.**
`tmuxWrappedProfileIfAvailable` gains a `projectId: UUID?` parameter. When `projectId != nil`
and tmux is enabled, it (1) calls `TmuxControl.sessionExists` to decide first-tile vs.
subsequent, (2) calls `TmuxControl.newSession` or `TmuxControl.newWindow` accordingly to create
the detached window and capture its `%pane_id`, then (3) builds the attach profile via
`TmuxSession.attachWindowProfile(paneTarget: capturedId, …)` and returns
`(attachProfile, capturedId)`. When `projectId == nil`, it falls back to the existing
`TmuxSession.wrap` path unchanged and returns a nil window target. The private `spawnTerminal`
passes the project id through, records the returned `tmuxWindowTarget` on the descriptor, and —
on descriptor-save failure when a window was created — calls `TmuxControl.killWindow` before
returning `.failure`.

**`Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift` — lines 3–76.**
Add `public var tmuxWindowTarget: String?` to the struct. Bump `currentSchemaVersion` from 2 to
3. Add `tmuxWindowTarget` to `CodingKeys`. In the memberwise init, add `tmuxWindowTarget: String?
= nil` with a default of `nil` so every existing call site compiles unchanged. In the custom
`init(from:)` decoder, decode it with `decodeIfPresent` using the same pattern as `scrollback`
at line 75. A v2 descriptor file (no `tmuxWindowTarget` key) decodes with `tmuxWindowTarget ==
nil`; a v3 file round-trips.

## Implementation breadcrumbs

```swift
// TmuxSession.swift — new pure constructors, no side effects.
// NOTE: window CREATION + pane-id capture is NOT here — it lives in TmuxControl
// (a real Process whose stdout is readable). These are only the pure name + the
// plain-attach argv ghostty runs AFTER the window already exists.

public static func projectSessionName(projectId: UUID) -> String {
    "continuum-proj-\(projectId.uuidString)"
}

// The plain re-attach argv. ghostty runs this to connect to a window that
// TmuxControl already created. Attaching with a pane target (%N) selects that
// pane's window. No -P, no window creation. (The de-mirror ticket, D19, will
// replace this with the grouped `new-session -t <proj> -s continuum-view-<tileId>
// \; select-window` form — out of scope here.)
public static func attachWindowProfile(paneTarget: String, cwd: String, tmuxPath: String) -> LaunchProfile {
    LaunchProfile(command: tmuxPath, arguments: ["attach-session", "-t", paneTarget], cwd: cwd, title: nil)
}
```

```swift
// TileSpawner.swift — dispatcher in tmuxWrappedProfileIfAvailable

private func tmuxWrappedProfileIfAvailable(
    _ profile: LaunchProfile,
    tileId: UUID,
    projectId: UUID?           // NEW param; nil = ambient, use legacy path
) -> (profile: LaunchProfile, windowTarget: String?) {
    guard TmuxPersistenceConfig.enabled(defaults: defaults),
          let tmuxPath = tmuxPathResolver(defaults) else {
        return (profile, nil)
    }
    if let projectId {
        // Project zone path — create the window via TmuxControl, capture pane id.
        let projSession = TmuxSession.projectSessionName(projectId: projectId)
        // DETERMINISTIC branch — decide BEFORE the call, no try/catch fallback.
        // has-session (fake: in-memory map; prod: `tmux has-session -t`) is the only
        // new query. First tile => newSession; subsequent => newWindow. This is what
        // makes "exactly 1 newSession + 2 newWindow for 3 tiles" achievable.
        let paneId: String
        if tmuxControl.sessionExists(name: projSession) {
            paneId = try tmuxControl.newWindow(inSession: projSession, cwd: profile.cwd, innerCommand: innerCmd(profile))
        } else {
            paneId = try tmuxControl.newSession(name: projSession, cwd: profile.cwd, innerCommand: innerCmd(profile))
        }
        // Build the plain re-attach argv ghostty will run (connects to the
        // already-created window; NO -P, NO creation). Fully specified — no invention.
        let attachProfile = TmuxSession.attachWindowProfile(paneTarget: paneId, cwd: profile.cwd, tmuxPath: tmuxPath)
        return (attachProfile, paneId)
    } else {
        // Ambient/fallback path — unchanged per-tile session
        return (TmuxSession.wrap(profile: profile, tileId: tileId, tmuxPath: tmuxPath), nil)
    }
}
```

```swift
// private spawnTerminal — capture the window target and persist it synchronously

let (launchProfile, windowTarget) = allowTmuxPersistence
    ? tmuxWrappedProfileIfAvailable(profile, tileId: tile.id, projectId: activeProjectId)
    : (profile, nil)

// On failure after window creation, compensate before returning:
// if windowTarget != nil && descriptor save throws { try? tmuxControl.killWindow(target: windowTarget!) }

let descriptor = TerminalSessionDescriptor(
    id: runtime.id,
    tileId: tile.id,
    // ... all existing fields ...
    tmuxWindowTarget: windowTarget   // NEW
)
// Save descriptor — must succeed before returning .spawned
try projectStore.saveSession(descriptor)
```

```swift
// TerminalSessionDescriptor.swift — schema v3

public static let currentSchemaVersion = 3   // was 2

public var tmuxWindowTarget: String?          // new field

// CodingKeys gains: case tmuxWindowTarget
// init(from:) gains: tmuxWindowTarget = try container.decodeIfPresent(String.self, forKey: .tmuxWindowTarget)
// memberwise init gains: tmuxWindowTarget: String? = nil
```

## How we test it

### Logic (pure Core checks)

The check suite runs in `ContinuumRevivedCoreChecks` using `InMemoryTmuxControl` from the
injectable substrates (the fake records every call, manages sessions and pane ids in memory, and
returns deterministic `%N` pane ids without spawning any process).

**Spawn three tiles in the same project.** Construct a `TileSpawner` wired with an
`InMemoryTmuxControl` seeded with no pre-existing sessions and a non-nil `projectId`. The fake's
`sessionExists(name:)` returns `false` until its `newSession` runs, then `true` — which is what
makes the call pattern deterministic. Call `spawnTerminal` three times. Assert that
`tmuxControl.log` contains **exactly one** `newSession` call (first tile: `sessionExists == false`)
and **exactly two** `newWindow` calls (tiles 2–3: `sessionExists == true`), with **no** failed/
caught calls in the log. Assert that `sessions["continuum-proj-<id>"]` contains exactly three pane
ids. Assert that the three persisted descriptors each have a distinct, non-nil `tmuxWindowTarget`
matching the three pane ids the fake returned, and that each descriptor's `args` is the plain
attach `["attach-session", "-t", <that descriptor's tmuxWindowTarget>]` — never a `new-window`/
`new-session` argv (creation is TmuxControl's, not ghostty's).

**Spawn an ambient tile (nil projectId).** Call `spawnTerminal` with a nil `activeProjectId`.
Assert that `tmuxControl.log` contains no `newWindow` calls and the descriptor's
`tmuxWindowTarget` is nil. Assert that the wrapped profile's argv still begins `new-session -A -s
continuum-<tileId>` — the legacy path is unmodified.

**Descriptor round-trip (schema v3).** Construct a `TerminalSessionDescriptor` with
`tmuxWindowTarget = "%7"`. Encode to JSON, decode back, and assert the field survives. Construct
a v2 JSON fixture (no `tmuxWindowTarget` key) and decode it; assert the field is nil and no
decode error is thrown. This is invariant I7.

**Compensating action on descriptor save failure.** Inject a `ProjectStore` stub that throws on
`saveSession`. Call `spawnTerminal` with a non-nil project id. Assert that
`tmuxControl.log` contains a `killWindow(target:)` call for the pane id that was created before
the save failed. Assert the method returns a `.failure` outcome and no new tile appears in
`canvasView.canvasState.tiles`.

### Backend (real-path integration, not bypassed)

The real-path check runs against an actual tmux daemon, gated on `TmuxLocator.resolve() != nil`
(skips cleanly if tmux is absent, recording `tmux_absent=true` in the manifest).

**Spawn two tiles in one project session.** Instantiate a `ProcessTmuxControl` with the resolved
tmux path. First assert `sessionExists(name: "continuum-proj-testcheck") == false` (proves the
probe's negative arm, which is what selects `newSession` for the first tile). Call
`newSession(name: "continuum-proj-testcheck", cwd: "/tmp", innerCommand: nil)` and record the
returned `pane1`. Now assert `sessionExists(name: "continuum-proj-testcheck") == true` (proves the
positive arm, which selects `newWindow` for subsequent tiles). Call
`newWindow(inSession: "continuum-proj-testcheck", cwd: "/tmp", innerCommand: nil)` and record
`pane2`. Assert `pane1 != pane2`. Call `isAlive(paneTarget: pane1)` and `isAlive(paneTarget:
pane2)` — both must return `true`. Call `listSessions()` and assert exactly one session named
`"continuum-proj-testcheck"` with `windowCount == 2`. Record all measured values in the manifest —
`exists_before`, `exists_after`, `pane1`, `pane2`, `pane1_alive`, `pane2_alive`,
`session_window_count` — never `{passed: true}`. (`isAlive`, `listSessions`, `killSession` are
read/teardown helpers on the substrate from the phase-0 harness; this ticket only *adds*
`sessionExists`, `newSession`, `newWindow`, and `killWindow` to the surface it drives.)

Tear down: call `killSession(name: "continuum-proj-testcheck")` and assert both pane ids return
`isAlive: false`. The check must drive the full production `ProcessTmuxControl` code path with no
bypass of `newWindow` or `newSession`.

### UX (visual gate + dogfood snippet)

The visual gate is: open the Component Lab, navigate to the tile lifecycle panel (or the session
topology panel introduced alongside this ticket), and confirm the panel shows a session row for
the active project with its window count incrementing from 1 to 2 to 3 as tiles are spawned. The
panel should show the `%pane_id` of each tile's window target. A static panel showing `%0` for
every tile is a failure.

Dogfood snippet: open Continuum with a project zone active. Spawn two terminal tiles using the
normal tile-spawn gesture (key or menu). In the first tile's shell, run `export HELLO=world`. In
the second tile's shell, run `echo $HELLO`. You should see `world` printed — the two windows
share the same session environment. If `echo $HELLO` prints nothing, the spawn is still using the
per-tile session and the environment is not shared. Additionally, run `tmux list-windows -t
continuum-proj-<your-project-id>` in any terminal outside Continuum and confirm there are exactly
two windows listed with two distinct `%pane_id`s.

## Execution mode

**Autonomous.** The logic checks are pure and deterministic, driven entirely by `InMemoryTmuxControl`
with no daemon required. The real-path integration check drives an actual local tmux instance but
requires no device, cloud account, or human visual judgment — it asserts measured tmux state from
`ProcessTmuxControl` and records values in the manifest. The UX gate and dogfood snippet are
included to give a supervised reviewer a concrete verification path, but this ticket's correctness
can be fully established by the logic and real-path checks before any human opens the app.

## Done when

- [ ] `TmuxSession.projectSessionName(projectId:)` exists and returns `"continuum-proj-<uuid>"`.
- [ ] `TmuxSession.attachWindowProfile(paneTarget:cwd:tmuxPath:)` exists as a pure static
  function returning the plain-attach profile (`["attach-session", "-t", paneTarget]`), with no
  side effects and no `-P`. Window creation and pane-id capture are NOT pure argv constructors —
  they live in `TmuxControl` (`newSession`/`newWindow`), whose real impl runs `tmux` as a
  readable `Process`.
- [ ] `TerminalSessionDescriptor` has a `tmuxWindowTarget: String?` field, `currentSchemaVersion`
  is 3, the field is decoded with `decodeIfPresent` (v2 files load with nil), and the field
  round-trips through encode/decode.
- [ ] `TmuxControl` exposes a read-only `sessionExists(name:) -> Bool` probe (fake: in-memory
  map; `ProcessTmuxControl`: `tmux has-session -t`). `tmuxWrappedProfileIfAvailable` dispatches on
  whether a `projectId` is present, and within the project path branches *deterministically* on
  `sessionExists` — `false` → `newSession`, `true` → `newWindow` — never try/catch-on-error.
  It captures the returned pane id and returns it alongside the `attachWindowProfile`.
  Ambient/nil-projectId tiles take the unchanged per-tile `TmuxSession.wrap` path.
- [ ] The captured pane id is stored as `tmuxWindowTarget` on the descriptor and the descriptor
  is saved synchronously before `spawnTerminal` returns `.spawned`.
- [ ] A descriptor-save failure after window creation triggers a compensating `killWindow` call
  before returning `.failure` — no orphan window is left behind.
- [ ] Spawning three tiles in the same project zone via `InMemoryTmuxControl` produces exactly
  one `newSession` call and two `newWindow` calls in `tmuxControl.log`, with three distinct
  non-nil `tmuxWindowTarget` values on the persisted descriptors.
- [ ] Spawning an ambient tile produces zero `newWindow` calls, `tmuxWindowTarget == nil`, and
  the legacy `continuum-<tileId>` argv in the launch profile.
- [ ] The real-path check passes (two distinct alive panes in one project session; manifest records
  measured values) or skips cleanly when tmux is absent.
- [ ] The schema v3 round-trip check passes; the v2 back-compat decode check passes.
- [ ] All pre-existing checks still pass. The existing `TmuxSession.wrap` and
  `TmuxSession.killSessionCommand` functions are byte-for-byte unchanged.
- [ ] The spawn-argv self-checks in `TileSpawner.swift` (lines 3247, 3263) that assert
  `["new-session", "-A", "-s", <continuum-tileId>, "-c", <cwd>]` are updated: the project-zone
  descriptor now carries the plain-attach `["attach-session", "-t", <capturedPaneId>]`; the
  ambient descriptor is unchanged.
- [ ] The delete-lifecycle self-check at `ContinuumApp.swift` line 11082 (which asserts a
  `kill-session` via `TmuxSession.killSessionCommand`, NOT a `new-session` argv, and exercises an
  ambient tile) is left unchanged and still passes — this ticket does not touch the close path.

## Depends on / unblocks

This ticket depends on the project session naming and ownership work — specifically the
`TmuxSession.projectSessionName(projectId:)` function and the establishment of
`ZoneRuntimeController` as the owner of the per-project session lifetime. It also depends on the
injectable substrates, which provide `TmuxControl`, `InMemoryTmuxControl`, and
`ProcessTmuxControl` so the spawn logic can be driven in the check harness and the real-path check
can exercise `ProcessTmuxControl` directly.

It directly unblocks the `tmuxWindowTarget` capture-at-spawn ticket (which adds deeper liveness
probing around the target — this ticket does the initial capture; that one hardens it), the cwd
inheritance policy (which plugs the focused tile's `pane_current_path` into the cwd passed to
`newWindow`), the close-tile kill-window change (which reads `tmuxWindowTarget` from the
descriptor to know which window to kill instead of killing the whole session), and the dead-target
fallback (which handles the case where the persisted target no longer exists in tmux and falls
back to creating a new window).

## Watch out for

**The make-or-break risk is pane id capture timing.** The pane id must be captured and persisted
synchronously as part of the same call that creates the window. Any laziness here — capturing it
on first focus, or in a background task — means an app crash or restart between window creation
and capture leaves a window with no tile binding and a tile with no window, silently breaking I1
and I8. The compensating `killWindow` on descriptor-save failure is the matching safeguard: if the
descriptor cannot be saved, the window is immediately destroyed so no orphan accumulates. Both
sides of this contract must be present; a ticket that ships one without the other is not done.

**`%pane_id` stability vs window-index aliasing.** Store the `%N` pane id, not the integer window
index. Window indices renumber when earlier windows close; a stored index would silently alias
the wrong tile after any window closure. The `%pane_id` is stable for the pane's lifetime,
which is exactly what I8 needs.

**Two different self-check families break, at two different seams — do not conflate them.**
- **Spawn-argv assertions (`TileSpawner.swift` lines 3247, 3263).** These build
  `expectedArgs = ["new-session", "-A", "-s", expectedSessionName, "-c", enabledRoot.path]` and
  assert both the spawned and restarted descriptor's `args` equal it. They bake in the per-tile
  `new-session -A -s continuum-<tileId>` shape and *will* fail for the project-window path.
  Update them to assert the correct shape per path: for a project zone the persisted descriptor's
  `args` is now the plain attach `["attach-session", "-t", <capturedPaneId>]`; for the ambient
  fallback it is unchanged (`new-session -A -s continuum-<tileId> …`). Verify against the live
  code before editing — the assertion is a `try expect(spawnedDescriptor.args == expectedArgs, …)`.
- **Delete-lifecycle assertion (`ContinuumApp.swift` line 11082).** This one does **not** assert a
  `new-session` argv. Verified against the code, line 11082 is
  `let expectedKill = TmuxSession.killSessionCommand(tileId: terminalTileId, tmuxPath: fakeTmuxPath)`
  and the following `expect`s assert the tile-close path issues exactly one
  `kill-session -t continuum-<tileId>`. This ticket does **not** change the close path (D16's
  kill-window change is a separate ticket), so this assertion stays valid **for the ambient
  fallback tile it exercises** (a `.terminal` tile with `launchProfileId: "shell"` and no project
  binding). Do not rewrite it to expect a `new-session` shape — it never had one. Only touch it if
  you change the fixture to a project-zone tile, which this ticket should not.

These checks are integrity guardrails, not dead code. Rewrite the spawn-argv ones; leave the
delete-lifecycle one alone.

**Stop conditions.** Do not mark this ticket done if: the descriptor is saved before the window
is created (wrong order — a tile with no window is worse than no tile at all); the per-tile
`continuum-<tileId>` session model is used for project zones (the whole point of this ticket is
the change); a project-zone tile's descriptor has `tmuxWindowTarget == nil` after spawn (the
field must be populated at spawn, not deferred); or the compensating kill is absent from the
save-failure path (orphan windows break I3).
