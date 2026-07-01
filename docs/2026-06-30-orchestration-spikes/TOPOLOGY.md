# Session Topology Spike — project = session, tile = window

Status: **spike** (per `docs/37`) — research/design only. Output is locked-ish
decisions + follow-up tickets, NOT implementation-ready PRs. No repo code was
modified producing this doc.

Date: 2026-06-30. Author context: implements Decision **A** (project = session,
tile = window) and Decision **B** (de-mirror via grouped sessions) from
`docs/38`, against the current per-tile-session model in `docs/34`.

Every claim below is grounded in code read on 2026-06-30 with `file:line`. Where
the code disagrees with prose in `docs/38`, the code wins and the discrepancy is
flagged.

---

## Goal

Make a tmux **session belong to a project** and each terminal **tile a window**
in that session (single-pane), replacing today's "one tile = one
`continuum-<tileId>` session." This kills the per-tile re-`cd` ceremony and gives
a shared env, while preserving the four invariants this spike must not break:

- **I1** — binding bijection: tile ↔ window 1:1; no orphan window, no tile
  pointing at a dead target.
- **I2** — no-mirror: distinct tiles render distinct active-window targets.
- **I3** — no session leak: live `continuum-*` sessions ⊆ live projects/zones;
  last-tile-close kills the session.
- **I8** — restart survival: pid + window target + cwd preserved across a ghostty
  client teardown.

This doc resolves the three things `docs/38` left open in Decision A — **ambient
zone session ownership**, **project-release kill vs detach**, and **migration** —
plus cwd inheritance, de-mirror viability, and an invariant edge-case list.

---

## Current mapping (grounded, file:line)

### The binding chain today

A terminal tile binds to a tmux session through the **launch argv stored in its
descriptor**, not through any tmux query. The chain:

1. **Session name = f(tileId).** `TmuxSession.sessionName(tileId:)` returns
   `"continuum-<uuid>"` (`Sources/ContinuumRevivedCore/TmuxSession.swift:8-10`).
   This is the single weld `docs/38` calls "Weld 1."

2. **Spawn wraps the profile.** `TileSpawner.spawnTerminal(profileId:at:)`
   (`Sources/ContinuumRevived/App/TileSpawner.swift:108`) resolves a
   `LaunchProfile`, makes a new `Tile` with a fresh `UUID()`
   (`TileSpawner.swift:167-175`), then wraps the profile via
   `tmuxWrappedProfileIfAvailable(profile, tileId: tile.id)`
   (`TileSpawner.swift:176-177`, `:221-227`). `wrap` sets
   `command = tmuxPath`, `arguments = ["new-session","-A","-s","continuum-<tileId>","-c",cwd] (+ inner cmd)`
   (`TmuxSession.swift:12-25`). The runtime gets its own UUID
   (`TileSpawner.swift:179-181`); `tile.runtimeRef = RuntimeRef(.terminalSession, runtime.id)`
   (`TileSpawner.swift:188`).

3. **The descriptor is the durable record.** A `TerminalSessionDescriptor` is
   built with `id: runtime.id`, `tileId: tile.id`, and crucially
   `command = launchProfile.command` (= tmuxPath) and
   `args = launchProfile.arguments` (= the `new-session -A -s continuum-<tileId> …`)
   (`TileSpawner.swift:194-207`). It is persisted to disk at
   `sessions/<descriptor.id>.json` keyed by the **runtime UUID**, not tileId
   (`ProjectStore.saveSession` `Sources/ContinuumRevivedCore/ProjectStore.swift:136-137`,
   `sessionFile(id:)` `:71`). `listSessions()` reads every file and callers filter
   by `tileId` (`ProjectStore.swift:157-174`).

4. **The surface is just argv.** `GhosttyTerminalView.createSurface`
   (`Sources/ContinuumRevived/TerminalEngine/GhosttyTerminalView.swift:480`) builds
   `config.command` from `commandLine(for: launchProfile)` — a shell-quoted join of
   `[command] + arguments` (`:469-471`, `:498-505`) — and `config.working_directory`
   from `launchProfile.cwd` (`:499-502`), then `ghostty_surface_new`. **There is no
   tmux-specific code in the renderer**: the entire tmux wrap is carried in the
   `LaunchProfile`. This confirms `docs/38`'s claim that re-wrapping needs no
   libghostty change.

### Restart (reattach) — by re-running identical argv

`restartTerminalTile(tileId:)` (`TileSpawner.swift:276`) is **not** a tmux query.
It:
- finds the existing `Tile` on the canvas by id (`:279-281`),
- re-resolves the profile from `metadata.launchProfileId` (`:282-298`),
- reads the persisted descriptor's cwd as the restore cwd
  (`persistedDescriptor = listSessions().first{ tileId == }` `:303`,
  `restoredCwd = persistedDescriptor?.cwd ?? profile.cwd` `:304`),
- **re-wraps with the same tileId** (`tmuxWrappedProfileIfAvailable(profileWithCwd, tileId: existing.id)`
  `:312`) → produces the **same `continuum-<tileId>` session name** →
- ghostty re-runs identical `new-session -A` argv → tmux reattaches the live
  session because `-A` means "attach if exists."

So the "rebind" `docs/38:92` describes as
`listSessions().first(where: tileId==)` is real — but it rebinds by **re-deriving
the session name from tileId**, and `listSessions()` here is the **on-disk
descriptor list (ProjectStore)**, not a `tmux ls`. **Flag:** there is *no*
production code anywhere that queries live tmux (`tmux ls` / `list-sessions` /
`has-session` / `list-windows` appear only inside self-checks at
`TileSpawner.swift:3362,3488,3590,3641`). The reattach is purely "same argv,
`-A` does the work."

### Flush

`flushTerminalSessionSnapshot(tileId:runtime:…)` (`TileSpawner.swift:371`) reads
the live descriptor by tileId (`:378`), captures `runtime.capturedCwd` (OSC-7
`GHOSTTY_ACTION_PWD`, falling back to launch cwd —
`GhosttyTerminalRuntime.swift:169-171`) and capped scrollback, rebuilds the
descriptor preserving `id`, `tileId`, `command`, `args`, and re-saves
(`:393-408`). It never touches tmux.

### Delete / close (kill-session — the only explicit tmux mutation in production)

`deleteTile(id:)` (`Sources/ContinuumRevived/App/ContinuumApp.swift:3010`) on a
`.terminal` tile (`:3038-3049`):
1. calls `killTmuxSessionForDeletedTerminalTile(tileId: id)`
   (`:3040`) → `TmuxSession.killSessionCommand(tileId:tmuxPath:)` →
   `tmux kill-session -t continuum-<tileId>` run via `tmuxProcessRunner`
   (`ContinuumApp.swift:3108-3119`, `TmuxSession.swift:27-29`),
2. terminates the runtime, stamps `lastExit`, and deletes the descriptor
   (`:3041-3048`).

App-quit / teardown is **detach-only** (no kill): `ZoneRuntimeController.close()`
just stamps `lastExit` on each runtime's descriptor and releases the lock
(`ZoneRuntimeController.swift:78-94`); the live integration check explicitly
asserts teardown issues no kill-session
(`ContinuumApp.swift:11105`). On boot, `pruneExitedSessions` deletes descriptors
with non-nil `lastExit` (`Sources/ContinuumRevivedCore/SessionPruner.swift:10-26`,
called from `ZoneRuntimeController.init` `:67`).

This is exactly `docs/34`'s locked "detach on quit, kill on delete."

### ZoneRuntimeController / Registry — runtimes per project

- `ZoneRuntimeController` owns one project's runtimes: `runtimes:
  [GhosttyTerminalRuntime]`, `browserRuntimes`, a `projectStore`, a `project`, and
  an optional `ProjectLock` (`ZoneRuntimeController.swift:6-32`). `init(root:)`
  acquires a `ProjectLock` and loads/creates the project
  (`:54-69`). `close()` flushes, stamps `lastExit`, releases the lock
  (`:78-94`).
- `ZoneRuntimeRegistry` ref-counts controllers **by `projectId`**
  (`ZoneRuntimeRegistry.swift:13-57`): `acquire(projectId:)` creates-if-missing and
  bumps the count (`:35-44`); `release(projectId:)` decrements and, at zero,
  removes the box and `close()`s the controller **iff `closeOnZero`** (default
  true) (`:48-57`). The refcount semantics are proven by the self-check
  (`:76-296`): second acquire returns the same instance (assertion 2), release to
  zero closes and removes (assertion 4), `closeOnZero == false` keeps the
  controller warm but still drops the box (assertion 8).
- **A project is shared across workspaces.** That is the whole point of the
  registry (`ZoneRuntimeRegistry.swift:5-11` doc comment; `docs/23` S2). So two
  workspaces showing the same project hold **one** controller / one lock / one PTY
  set, and the refcount can be > 1.

### How a tile is assigned to a zone/project today

This is the load-bearing surprise for the ambient question, so it is grounded
carefully:

- **There is one app-level `tileSpawner`** built once with the **boot project's**
  `projectStore` and `project` (`ContinuumApp.swift:2400-2438`). All
  `spawnTerminal` calls go through it and persist the descriptor to **that**
  store, and install the tile view into the **single app `canvasView`**.
- The spawner's only project-awareness is cwd: `terminalProjectContextProvider`
  is wired to `activeZoneProjectEntry()` (`ContinuumApp.swift:2423-2425`), and
  `terminalProjectRoot()` returns `provider()?.rootPath ?? project.rootPath`
  (`TileSpawner.swift:217-219`). So the **cwd root** follows the active zone's
  project, but the **store/canvas does not** — descriptors always land in the boot
  store.
- `activeZoneProjectEntry()` resolves
  `canvasView?.activeZone?.projectId ?? workspaceRuntime?.activeController?.project.id`
  (`ContinuumApp.swift:6969-6974`). For an **ambient zone (`projectId == nil`)**
  it falls through to the **active controller's project** — i.e. an ambient
  terminal tile's cwd resolves to whatever project is currently backing the
  workspace.
- Two membership mechanisms feed the **sidebar tree** (read-only projection):
  `SidebarTreeBuilder.tiles(for:)` (`Sources/ContinuumRevivedCore/SidebarTree.swift:184-192`)
  takes `document.tiles(forZone:)` (the inline `groupZoneTiles`, used for ambient
  zones) **plus** any project-canvas tile whose **center is spatially inside** the
  zone frame (`tileCenter(...).isInside(zone:)` `:188`, `:194-203`, using
  `CanvasEngine.zoneWorldFrame`). So a **project zone**'s membership is *spatial*;
  an **ambient zone**'s membership is the *explicit inline tile list*.
- `WorkspaceDocument.groupZoneTiles` is the ambient store
  (`WorkspaceDocument.swift:21`), read via `tiles(forZone:)` (`:39-41`) and written
  via `setTiles(_:forZone:)` (`:43-50`). **Flag:** in production, `setTiles` is
  effectively only called to **clear** a closed zone (`setTiles([], forZone:)`,
  `ContinuumApp.swift:6334` in `persistClosedZone`). There is **no production
  drag-to-assign path** that populates `groupZoneTiles` with spawned terminal
  tiles — every other `setTiles`/`GroupZoneTiles(...)` reference is inside a
  self-check. The ambient group controller is created rooted at
  `AmbientZoneHome.current` with `acquireLock: false`
  (`WorkspaceRuntime.swift:370-374`), but it is retained in `groupControllers`
  (`:32`, `:61`) and is **not** the spawner's store.

**Net current reality:** "which session hosts a tile" is decided entirely by
`tile.id` (session name) and "which store records it" is the boot project store —
regardless of which zone the tile visually sits in. The zone/project association
is, today, *spatial and advisory* (sidebar only) for project zones, and *inline
but unpopulated* for ambient zones.

---

## Ambient / group-zone session ownership (options + recommendation)

**The hole.** Under "project = session," a terminal's session is keyed off
`projectId`. An ambient/group zone has `ZonePlacement.projectId == nil`
(`WorkspaceDocument.swift:149`, set nil by `appendGroupZone` `:107` and
`_addGroupZone` `:382`). So there is no `projectId` to key a session on. What
session hosts an ambient terminal tile?

Three realistic options.

### (a) Per-workspace ambient session — `continuum-ws-<workspaceId>`

One shared session per workspace hosts all ambient tiles (across all that
workspace's group zones) as windows.

- **Code implications:**
  - New session-name function `TmuxSession.ambientSessionName(workspaceId:) ->
    "continuum-ws-<uuid>"` alongside the project one (`TmuxSession.swift:8`).
  - The spawn path must learn the **ambient workspaceId** when the active zone is
    a group zone. Today the spawner has no workspaceId; it has
    `terminalProjectContextProvider`. Add a parallel
    `terminalSessionTargetProvider` returning an enum
    `{ project(UUID) | ambient(workspaceId: UUID) }`, wired from
    `activeZoneProjectEntry()`'s sibling that also reports the active zone's
    `projectId == nil` case (`ContinuumApp.swift:6969`).
  - Window target stored on the descriptor (see Migration). cwd still comes from
    `AmbientZoneHome.current` or the focused tile (see New-window cwd).
- **Lifecycle:** session created on first ambient tile in the workspace; survives
  app quit (detach). Dies when its window count hits 0 (last ambient tile closed
  = kill-window → 0 windows → session ends) **or** when the workspace is deleted
  (`deleteWorkspaceAndRelaunch` `ContinuumApp.swift:6598`). Note the **ambient
  controller is workspace-scoped** already (`groupControllers`,
  `WorkspaceRuntime.swift:32`), so a `SessionObserver`/owner has a natural home.
- **I1/I3 fit:** **Best.** One stable key (workspaceId) → one session → N windows,
  exactly mirroring the project case. The "live sessions ⊆ live
  projects/workspaces" set in I3 simply gains a workspace arm. No per-tile session
  proliferation; bijection holds because each ambient tile = one window in the
  workspace session.

### (b) Per-zone session — `continuum-zone-<zoneId>`

One session per group zone.

- **Code implications:** session name keyed off `zoneId`
  (every group zone already has a stable `zoneId`,
  `WorkspaceDocument.swift:148`). Spawn target provider reports the active
  `zoneId` when `projectId == nil`. Membership becomes the inline
  `groupZoneTiles` list — but that list is **not populated in production today**
  (see Current mapping), so this option *forces* building the drag-to-assign
  write path first, or it can't know which zone a tile belongs to.
- **Lifecycle:** session per zone; dies at 0 windows or on zone close
  (`persistClosedZone` already clears `setTiles([], forZone:)`
  `ContinuumApp.swift:6334` and would gain a kill-session). More sessions than
  (a): one per group zone instead of one per workspace.
- **I1/I3 fit:** Holds, but with **more sessions to leak** and a hard dependency on
  populating `groupZoneTiles`. A zone deleted without going through
  `persistClosedZone` (e.g. break-out / merge paths from the zone-unification work,
  per MEMORY) would orphan its session. Higher leak surface than (a).

### (c) Keep per-tile session as an ambient-only fallback

Project zones move to project=session; ambient tiles keep today's
`continuum-<tileId>` model.

- **Code implications:** **smallest** — `tmuxWrappedProfileIfAvailable` already
  produces `continuum-<tileId>`; just gate the new project=session wrap on
  "active zone has a projectId," else fall back to the existing per-tile wrap. No
  new session-name function, no target provider for the ambient case.
- **Lifecycle:** identical to `docs/34` for ambient tiles — kill on delete
  (`killTmuxSessionForDeletedTerminalTile` already keys by tileId,
  `ContinuumApp.swift:3113`), detach on quit, prune exited on boot.
- **I1/I3 fit:** I1 trivially holds (one tile ↔ one session ↔ one window — the
  whole session *is* the window). I3 holds via the existing kill-on-delete path.
  **But** it *defeats the goal* for ambient tiles (no shared env, re-`cd` lives
  on), and it means two code paths for "what hosts a tile" forever.

### Recommendation: **(a) per-workspace ambient session**, with **(c) as the
shipped fallback for phase 1.**

Rationale: (a) is the only option that gives ambient tiles the *same* benefit as
project tiles (shared session/env, no re-cd) while keeping I1/I3 as clean as the
project case — one stable key, one session, N windows, a leak set that is just
"live workspaces." (b) multiplies sessions and hard-depends on a membership write
path that **does not exist in production yet** (`setTiles` is clear-only today),
making it riskier and slower. (c) is the cheapest and is a *correct* fallback —
because the per-tile kill-on-delete path already exists and is tested — so phase 1
can ship project=session for project zones and leave ambient tiles on per-tile
sessions until (a)'s target-provider + workspace-session plumbing lands. **Do not
pick (b).**

Concretely: phase-1 wrap selects on `activeZone.projectId`:
`projectId != nil` → project window session (Decision A); `projectId == nil` →
**(c)** per-tile session (unchanged). A follow-up promotes ambient to **(a)**.

---

## Project-release: kill vs detach

### The trace

`ZoneRuntimeRegistry.release(projectId:)` decrements the refcount; at
`<= 0` it removes the box and, if `closeOnZero` (default true,
`ZoneRuntimeBudgetConfig.defaultCloseOnZero`), calls
`controller.close()` (`ZoneRuntimeRegistry.swift:48-57`). `close()` today
**detaches only**: flush saves, `detachUI`, stamp `lastExit` on each runtime's
descriptor, release the `ProjectLock` (`ZoneRuntimeController.swift:78-94`). It
**does not** kill any tmux session. Releases happen when a workspace tears down /
switches and drops its acquired projectIds (`WorkspaceRuntime` tracks
`acquiredProjectIds`, `WorkspaceRuntime.swift:26`, `:322-324`).

Crucial fact: **a project can be shared by multiple workspaces** (the registry's
reason to exist). Refcount → 0 means *no workspace currently shows this project*,
not "the user deleted it."

### The tension

Decision 2 in `docs/38:445` says "close tile = kill-window; session dies at 0
windows **or project release**." But "close tile = kill" is a *deliberate user
delete* (`deleteTile`), whereas "project release" is *the last workspace stopped
showing the project* — which today is explicitly **detach, session survives** (the
whole `docs/34` promise: quit/switch away, agents keep running, reattach later).

### Recommendation: **DETACH on project release; KILL only on explicit close.**

Keep the kill surface to two deliberate user actions:
1. **Close one tile** → `kill-window` for that tile's window (replacing today's
   per-session kill at `ContinuumApp.swift:3113`).
2. **Last window in a project's session closed** → that session ends naturally
   (tmux ends a session at 0 windows) — no extra call needed; equivalently kill
   the session when window count hits 0.

**Project release (refcount → 0) must NOT kill the session.** It should remain
`close()`'s detach-only behavior. A released project whose windows are still alive
keeps its agents running and reattaches when any workspace re-acquires it
(`acquire` rebuilds the controller, which re-runs the spawn/reattach path).

This means `docs/38`'s "session dies at … project release" should be **revised to
"detach at project release."** Flag this back to Dylan as a correction to
Decision 2.

### Failure modes

- **Kill on release (rejected):**
  - *Multi-workspace kill:* workspace W1 and W2 both show project P. W1 closes →
    if release killed, P's session (and any running agent) dies **even though W2
    still shows it** — unless refcount gates it. Refcount *does* gate it (kill only
    at 0), so the true risk is: user closes the *last* window showing a long-running
    agent and the session is reaped out from under a still-running agent. This is
    the exact `docs/34` regression we must not reintroduce.
  - *Switch-away reap:* switching workspaces drops refcount; a transient 0 during a
    switch would kill sessions mid-switch. (The current `closeOnZero` already drops
    the box on release; a kill here would be destructive.)
- **Detach on release (recommended):**
  - *Orphan accumulation:* a project released but never re-acquired leaves a live
    `continuum-proj-<id>` session forever. Mitigation: the existing boot prune is
    descriptor-level only (`SessionPruner.swift`); add a **launch-time
    `continuum-*` sweep** (already named as a backstop in `docs/34:198`) that kills
    sessions with no live windows / no corresponding project. This is the I3
    backstop and should be a follow-up ticket.
  - *Stale reattach:* re-acquiring a project after a machine reboot finds the
    session gone (no process survives reboot); the spawn path's `-A` simply
    recreates it. Acceptable and already the documented reboot tier.

---

## Migration plan

### What is live at upgrade

Pre-upgrade, every terminal tile has a descriptor whose `args` begin
`["new-session","-A","-s","continuum-<tileId>", …]` (`TileSpawner.swift:194-207`,
shape proven at `TileSpawner.swift:3247`,`:3263`). The live tmux server holds N
sessions named `continuum-<tileId>`.

These **do not fold into windows cleanly**: each is a separate session with its
own window(s). There is no lossless "merge session X into session Y as a window"
that preserves pane pids without `move-window`/`join-pane` gymnastics across
servers — and we have *no* production code that even enumerates live tmux state to
attempt it. `docs/38:180-182` and `:491` already accept a one-time restart.

### Decision: **fresh project sessions on upgrade; one-time agent restart; loud note.**

1. On first launch of the new model, **leave existing `continuum-<tileId>`
   sessions alone** (do not auto-kill — that would reap a running agent silently).
   They become orphans relative to the new naming and are reaped by the launch-time
   `continuum-*` sweep backstop (follow-up ticket) or by the user's normal
   `tmux kill-server`. Document this in release notes.
2. New project zones spawn windows in `continuum-proj-<projectId>`; the *first*
   spawn/restart per project after upgrade creates the project session fresh, so a
   tile that was a live agent re-runs its launch command once (the agent restarts).
   This matches `docs/34`'s reboot tier (restore layout + cwd + command, not the
   live process).
3. cwd is preserved per-tile from the persisted descriptor (`descriptor.cwd`,
   already used by `restartTerminalTile` `:304`), so the restarted window lands in
   the right directory even though the process is fresh.

**Flag:** silently orphaning is the failure mode `docs/38:491` warns about — hence
"loud note" + the sweep backstop, not silent kill.

### New durable binding key — add `tmuxWindowTarget` to `TerminalSessionDescriptor`

Today the binding is implicit: session name = f(tileId), reattach by re-running
argv. Under project=session, **the session no longer identifies the tile** — many
tiles share `continuum-proj-<projectId>`. We need a per-tile **window target**.

- Add `public var tmuxWindowTarget: String?` to `TerminalSessionDescriptor`
  (`Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift:3-22`), bump
  `currentSchemaVersion` 2 → 3, decode with `decodeIfPresent` so v2 files load
  (mirror the existing `scrollback` pattern at `:75`). nil = "no target captured
  yet" (pre-upgrade or first spawn).
- Populate it at spawn time by capturing the created window/pane id. tmux can emit
  it: `tmux new-window -t <proj> -c <cwd> -P -F '#{pane_id}'` prints e.g. `%5`.
  Because ghostty owns the pty and we only pass argv, the spawn must either (i)
  pre-create the window out-of-band (`new-window -d -P -F`) and then attach the
  ghostty client to that specific window, or (ii) capture the pane id immediately
  after attach via a one-shot `tmux display -p -t <session> '#{pane_id}'`. The
  pre-create path (i) is cleaner for a deterministic target and is what the
  follow-up ticket should specify.
- `%`-prefixed **pane ids** are stable for the pane's lifetime and survive
  client detach/reattach (this is what I8 needs preserved). Store the pane id
  (`%N`), not the window index (`@N`/index), because window indices renumber.

### Rebind under the new key

`restartTerminalTile` (`TileSpawner.swift:276`) changes from "re-derive session
name from tileId + `-A`" to:
1. read `descriptor.tmuxWindowTarget`;
2. if present and the target's pane is still alive in
   `continuum-proj-<projectId>` (a single `tmux display -p -t <target>` liveness
   probe — the *first* production tmux query we introduce), re-attach a ghostty
   client pinned to that window (`select-window -t <target>`; see De-mirror);
3. **fallback** when the window can't be re-found (target nil, pane dead, or
   session gone): spawn a **new** window in the project session (re-run the
   create path), capture a new `tmuxWindowTarget`, and persist it. The tile keeps
   its identity; only the window is new. This is the graceful-degradation path and
   must be the explicit behavior, not a crash.

---

## New-window cwd

### Today

`spawnTerminal` cwd = `terminalProjectRoot()` =
`terminalProjectContextProvider()?.rootPath ?? project.rootPath`
(`TileSpawner.swift:112`, `:217-219`). Restart prefers the persisted descriptor's
cwd over project root (`restartTerminalTile` `:304`). The live cwd is captured from
OSC-7 into `runtime.capturedCwd` (`GhosttyTerminalRuntime.swift:169-171`) and
flushed (`flushTerminalSessionSnapshot` `:382`,`:399`).

### Decision: new tile cwd = **focused tile's `pane_current_path` if there is a
focused terminal in the same project session, else project root.**

This is the payoff of project=session — a new window inherits the directory of the
window you spawned it from, for free, exactly like `tmux new-window` from inside a
session. Specifics:

- **Source of truth for the focused tile's cwd:** prefer the live
  `runtime.capturedCwd` of the currently active terminal runtime
  (`canvasView.canvasState.lastActiveTileId` → its runtime), which is already OSC-7
  fresh. Equivalent tmux read is `tmux display -p -t <focusedTarget>
  '#{pane_current_path}'`, but reading the in-process `capturedCwd` avoids a tmux
  round-trip.
- **Fallback** when no terminal is focused (e.g. first tile in a project, or focus
  is on a browser/note): `terminalProjectRoot()` (today's behavior). For ambient
  tiles under fallback option (c): `AmbientZoneHome.current`.
- **Configurable** per `docs/37` numeric-policy rule: a
  `continuum.terminal.newTileCwd` enum default `inheritFocused`
  (`{ inheritFocused | projectRoot }`), surfaced in the Terminal settings section
  next to the tmux toggle.

### Exact new-window invocation

```
tmux new-window -t continuum-proj-<projectId> -c <cwd> -P -F '#{pane_id}' [-- <inner cmd…>]
```

- `-t continuum-proj-<projectId>` — the project session (created lazily; the very
  first window comes from `new-session -A -s continuum-proj-<projectId> -c <cwd>`
  so the session exists).
- `-c <cwd>` — the inherited or root cwd from the decision above.
- `-P -F '#{pane_id}'` — print the new pane id to capture `tmuxWindowTarget`.
- inner command — only for profiles that run a specific command, gated exactly as
  today by `shouldPassInnerCommand` (`TmuxSession.swift:31-33`).

This replaces the `new-session -A` argv inside `TmuxSession.wrap`
(`TmuxSession.swift:12-25`) for project tiles. `wrap` grows a variant
(`wrapWindow(profile:projectId:cwd:tmuxPath:)`) or a target enum param; the
existing `wrap` stays for the ambient-(c) fallback.

---

## De-mirror viability (Decision B)

### The mechanism

`docs/38:184-201` proposes: each tile's surface attaches via a **grouped session**
— `tmux new-session -t <projectSession> -s <perTileView>` — which shares the
project's windows but tracks its **own active window**, then `select-window` pins
it to that tile's window. N tiles → N grouped clients → N different active windows
→ no mirror.

### Does it hold against `createSurface`?

**Yes, mechanically.** `createSurface` only ever sees `config.command` (a
shell-quoted argv) and `config.working_directory`
(`GhosttyTerminalView.swift:498-505`). The grouped-session attach is just a
different argv in the `LaunchProfile`:

```
tmux new-session -t continuum-proj-<projectId> -s continuum-view-<tileId> \; select-window -t <tmuxWindowTarget>
```

(or two args: the `new-session -t … -s …` plus a follow-up `select-window`, which
in a single `LaunchProfile.command`/`arguments` pair needs `tmux … \; …` semantics
or a tiny wrapper script — the ticket must pick one; `tmux` accepts multiple
commands separated by `\;` in one invocation). Ghostty forks the pty for this
exactly as it does today; **no libghostty change**, same as the project=session
change. The shell-quoting in `commandLine`/`shellQuote`
(`GhosttyTerminalView.swift:469-478`) handles the argv fine.

### Code that assumes session == tile and would break

1. **`TmuxSession.killSessionCommand(tileId:)`** (`TmuxSession.swift:27-29`) and
   its caller `killTmuxSessionForDeletedTerminalTile`
   (`ContinuumApp.swift:3108-3119`) compute `kill-session -t continuum-<tileId>`.
   Under the new model, **close = kill-window** of `tmuxWindowTarget`, *not*
   kill-session — killing the session would reap every tile in the project. Plus
   the per-tile **view** grouped session (`continuum-view-<tileId>`) must be killed
   on tile teardown, else view-sessions leak. So this becomes two operations:
   `kill-window -t <target>` (the tile) + `kill-session -t continuum-view-<tileId>`
   (the view client), and never `kill-session` of the project session except at 0
   windows.

2. **`restartTerminalTile`'s re-derive-by-tileId reattach**
   (`TileSpawner.swift:303-312`) assumes the session name is f(tileId). It must
   rebind by `tmuxWindowTarget` + grouped view-session instead (see Migration).

3. **`TmuxSession.sessionName(tileId:)`** (`TmuxSession.swift:8`) and the spawn
   wrap (`TileSpawner.swift:176-177`, `:221-227`) — the session name is no longer
   the tile's identity; it is the *view* session's, and the project session is a
   separate name. Both new functions are needed.

4. **The theme-fidelity / lifecycle self-checks** that assert
   `descriptor.command == tmuxPath` and the `new-session -A -s continuum-<tileId>`
   argv (`TileSpawner.swift:2871`, `:3056`, `:3247`, `:3263`,
   `ContinuumApp.swift:11082`) bake in the per-tile session shape. They are checks,
   not production, but they will fail and must be rewritten for the new argv — flag
   so the migration ticket budgets for it.

### Open risks in B (per `docs/38:199-201`, confirmed plausible)

- `select-window` per view could race the `SessionObserver` (C) if both run
  concurrently; the observer is read-only (`display -p`) so the race is benign but
  must be debounced.
- Two tiles intentionally viewing the **same** window (a deliberate mirror) is
  *allowed* and falls out naturally — two grouped sessions both `select-window` the
  same target. I2 must whitelist this case ("except a deliberate shared view," per
  I2's own wording `docs/38:380`).
- Grouped-session cleanup: a crashed app leaves `continuum-view-<tileId>` sessions;
  the launch-time `continuum-*` sweep must reap view sessions too.

---

## Invariant edge cases

Concrete threats under project=session + grouped-view + ambient-(a):

**I1 — binding bijection (tile ↔ window 1:1)**
- *Orphan window:* spawn creates a window, then descriptor save fails
  (`TileSpawner.swift:208-213` returns `.failure` *after* the window exists) →
  window with no tile. Threat is new because the window outlives the failed tile.
  Need: create window → capture target → persist descriptor; on persist failure,
  `kill-window` the just-created target (compensating action).
- *Tile → dead target:* `tmuxWindowTarget` points at a pane killed out-of-band
  (user typed `exit`, or `tmux kill-pane` from CLI). Restart fallback must detect
  dead target and re-create (Migration step 3).
- *Window index reuse:* storing window index instead of `%pane_id` would alias a
  reused index to the wrong tile. Mitigated by storing `%pane_id` (Migration).

**I2 — no mirror**
- *Two clients, no `select-window`:* if the grouped-view attach omits or races the
  `select-window`, two clients default to the session's active window → mirror.
  The real-path check must prove two tiles show two *different* windows.
- *Deliberate shared view:* must be explicitly allowed (see B); a naive I2 check
  that asserts "all targets distinct" would false-fail here.

**I3 — no session leak**
- *Project session orphan:* project released (detach, per our decision) but never
  re-acquired → live `continuum-proj-<id>` forever. Backstop: launch-time sweep.
- *View-session leak:* `continuum-view-<tileId>` not killed on tile teardown or app
  crash. Backstop: sweep + explicit kill in delete path.
- *Ambient leak (option a):* `continuum-ws-<workspaceId>` survives a deleted
  workspace if `deleteWorkspaceAndRelaunch` (`ContinuumApp.swift:6598`) doesn't
  kill it. Delete-workspace must kill the ambient session.
- *0-window race:* killing the project session "at 0 windows" must not race a
  concurrent new-window spawn (close last tile + spawn new tile near-simultaneously).

**I8 — restart survival**
- *Target not persisted before teardown:* if `tmuxWindowTarget` is captured only
  lazily, an app crash between window-create and descriptor-flush loses the binding
  → restart can't find the window (falls back to new window, agent restarts).
  Capture + persist the target synchronously at spawn.
- *cwd drift:* I8 needs cwd preserved; `capturedCwd` is OSC-7 and may be stale if no
  OSC-7 fired (`GhosttyTerminalRuntime.swift:169-171` falls back to launch cwd).
  Under project=session the *window's* `pane_current_path` is authoritative on
  reattach anyway — prefer reading it on restore over the persisted descriptor cwd.

---

## Follow-up tickets

All **spike output — NOT implementation-ready.** Each names seams + acceptance
criteria per `docs/37`. Dependency order roughly T1 → T2 → (T3, T4) → T5.

### T1 — `tmuxWindowTarget` on the descriptor + schema v3 (foundational)
- **Goal:** durable per-tile window-target field so tiles can bind to windows in a
  shared session.
- **Scope:** add `tmuxWindowTarget: String?` to `TerminalSessionDescriptor`
  (`TerminalSessionDescriptor.swift:3-58`); bump `currentSchemaVersion` to 3;
  `decodeIfPresent` for back-compat (mirror `scrollback` `:75`).
- **Out of scope:** changing the wrap or rebind (T2).
- **Seams:** `TerminalSessionDescriptor`, every `TerminalSessionDescriptor(...)`
  initializer call (spawn `:194`, restart `:332`, flush `:393`,
  `makeTerminalSessionDescriptor` `:238`).
- **Acceptance:** v2 session JSON (no `tmuxWindowTarget`) decodes with field nil;
  v3 round-trips; `ContinuumRevivedCoreChecks` covers both. No behavior change yet.

### T2 — Project = session, tile = window (project zones only) + migration
- **Goal:** project zones spawn windows in `continuum-proj-<projectId>`; close =
  kill-window; reattach by `tmuxWindowTarget`.
- **Scope:** new `TmuxSession.projectSessionName(projectId:)` and
  `wrapWindow(...)` producing the `new-session -A -s continuum-proj-<id>` (first
  window) / `new-window -t … -P -F '#{pane_id}'` argv; capture + persist target;
  `restartTerminalTile` rebinds by target with new-window fallback; `deleteTile`
  uses `kill-window` not `kill-session`. **Ambient tiles stay on per-tile sessions
  (fallback c) — explicitly out of scope.** Fresh sessions on upgrade + launch note.
- **Out of scope:** de-mirror grouped sessions (T3); ambient promotion (T4); the
  `continuum-*` sweep (T5).
- **Seams:** `TmuxSession.swift:8-33`; `TileSpawner.swift:176-227,276-358`;
  `ContinuumApp.swift:3038-3049,3108-3119`; rewrite per-tile-session self-checks
  (`TileSpawner.swift:3247,3263`; `ContinuumApp.swift:11082`).
- **Product policy:** session name = `continuum-proj-<projectId>`; close one tile
  = `kill-window -t <target>`; project session ends at 0 windows; **project
  release = detach, never kill.**
- **Acceptance (falsifiable):** spawning 3 tiles in one project yields 1 session, 3
  windows, 3 distinct `%pane_id`s recorded; restart with live target reuses the same
  pane (pid unchanged); restart with dead target creates a new window and persists a
  new target; closing 1 tile kills 1 window and leaves the other 2; closing the last
  tile ends the session; switching workspace away (release→0) leaves the session
  alive. Gated real-tmux integration records `pidBefore==pidAfter`,
  `targetBefore==targetAfter`, `exitObserved=false`.
- **Stop conditions:** do not mark done if close issues `kill-session` of the
  project session; if release kills the session; if the rebind has no new-window
  fallback; if migration auto-kills pre-upgrade `continuum-<tileId>` sessions.

### T3 — De-mirror via grouped view-sessions
- **Goal:** N tiles on one project session render N distinct windows, no mirror.
- **Scope:** per-tile attach argv
  `new-session -t continuum-proj-<id> -s continuum-view-<tileId> \; select-window -t <target>`;
  kill `continuum-view-<tileId>` on tile teardown; allow deliberate shared view.
- **Seams:** `TmuxSession.wrap`/`wrapWindow` (`TmuxSession.swift`); `createSurface`
  consumes argv unchanged (`GhosttyTerminalView.swift:498-505`); delete path
  (`ContinuumApp.swift:3038-3049`).
- **Acceptance:** real-path check spawns 2 tiles, asserts two *different*
  `pane_current_command`/window targets active (not a mirror); a deliberate
  shared-view case asserts the *same* target is allowed without failing I2.
- **Stop conditions:** check bypasses production `createSurface`; view sessions leak
  after teardown.

### T4 — Promote ambient tiles to per-workspace session (option a)
- **Goal:** ambient/group-zone tiles become windows in `continuum-ws-<workspaceId>`.
- **Scope:** `TmuxSession.ambientSessionName(workspaceId:)`; spawn target provider
  reporting `ambient(workspaceId:)` when `activeZone.projectId == nil`
  (`ContinuumApp.swift:6969`); kill the ambient session on workspace delete
  (`ContinuumApp.swift:6598`). **Depends on T2 + a target provider; conditional on
  whether `groupZoneTiles` needs population — confirm membership source first.**
- **Seams:** `WorkspaceRuntime._addGroupZone` (`WorkspaceRuntime.swift:370-374`),
  `groupControllers` (`:32`), `activeZoneProjectEntry` (`ContinuumApp.swift:6969`).
- **Acceptance:** 2 ambient tiles in a workspace yield 1 `continuum-ws-<id>` session,
  2 windows; deleting the workspace kills the session; closing the last ambient tile
  ends the session.
- **Status:** `conditional` — blocked on confirming there is a membership signal
  for "this spawned tile belongs to this ambient zone" (today `setTiles` is
  clear-only).

### T5 — Launch-time `continuum-*` sweep (I3 backstop)
- **Goal:** reap orphaned `continuum-proj-*`, `continuum-view-*`, `continuum-ws-*`
  (and legacy `continuum-<tileId>`) sessions with no live binding on boot.
- **Scope:** the *first* production use of `tmux list-sessions`/`list-windows`;
  cross-reference against live project ids / workspace ids / persisted targets; kill
  the unmatched. Honor the tmux toggle/path config.
- **Seams:** boot path near `pruneExitedSessions` (`ZoneRuntimeController.swift:67`,
  `SessionPruner.swift`); `TmuxLocator.resolve` (`TmuxSession.swift:43`).
- **Acceptance:** a session not matching any live project/workspace/target is killed
  on boot; a session that *does* match is left alive; toggle-off / tmux-absent =
  no-op. Manifest records swept vs retained session names.
- **Stop conditions:** sweeps a session belonging to a live binding; runs when tmux
  disabled.

---

## Sources

Code (read 2026-06-30):
- `Sources/ContinuumRevivedCore/TmuxSession.swift:8-33` (sessionName, wrap,
  killSessionCommand, shouldPassInnerCommand), `:36-73` (TmuxLocator), `:78-96`
  (TmuxPersistenceConfig)
- `Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift:3-58` (descriptor +
  init), `:60-76` (decoder, decodeIfPresent scrollback), `:85-119` (AgentStatus,
  AgentDescriptor)
- `Sources/ContinuumRevivedCore/CanvasState.swift:39-65` (Tile), `:94-109`
  (RuntimeRef, RuntimeRefKind), `:111-188` (TileMetadata)
- `Sources/ContinuumRevivedCore/WorkspaceDocument.swift:13-50` (WorkspaceDocument,
  groupZoneTiles, tiles/setTiles forZone), `:62-118` (appendProjectZone,
  appendGroupZone projectId nil), `:147-211` (ZonePlacement, projectId optional)
- `Sources/ContinuumRevivedCore/SidebarTree.swift:92-205` (SidebarZoneRow,
  SidebarTreeBuilder.build, tiles(for:), tileCenter/isInside, zoneWorldFrame use)
- `Sources/ContinuumRevivedCore/ProjectStore.swift:71` (sessionFile), `:136-174`
  (saveSession, loadSession, deleteSession, listSessions)
- `Sources/ContinuumRevivedCore/SessionPruner.swift:10-26` (pruneExitedSessions)
- `Sources/ContinuumRevived/App/TileSpawner.swift:108-134` (spawnTerminal entry),
  `:151-215` (spawnTerminal core, wrap, descriptor save), `:217-227`
  (terminalProjectRoot, tmuxWrappedProfileIfAvailable), `:276-358`
  (restartTerminalTile), `:371-409` (flushTerminalSessionSnapshot); self-check-only
  tmux argv/queries `:2871,3056,3247,3263,3362,3473,3488,3590,3641`
- `Sources/ContinuumRevived/App/ContinuumApp.swift:2400-2445` (single app
  tileSpawner, terminalProjectContextProvider, attachUI), `:3010-3119` (deleteTile,
  terminal kill path, killTmuxSessionForDeletedTerminalTile), `:6310-6343`
  (persistClosedZone, setTiles clear-only), `:6969-6974` (activeZoneProjectEntry),
  `:11082-11172` (delete-lifecycle self-check assertions)
- `Sources/ContinuumRevived/App/ZoneRuntimeController.swift:6-94` (controller,
  init+lock, close detach-only), `:136-189` (setTier, hydrate/dehydrate)
- `Sources/ContinuumRevived/App/ZoneRuntimeRegistry.swift:13-73` (acquire, release,
  closeOnZero, introspection), `:130-252` (refcount self-check assertions)
- `Sources/ContinuumRevived/App/WorkspaceRuntime.swift:14-61` (workspace runtime,
  activeController, ambientControllers), `:292-409` (addZone, _addProjectZone,
  _addGroupZone rooted at AmbientZoneHome, acquireLock false)
- `Sources/ContinuumRevived/TerminalEngine/GhosttyTerminalView.swift:469-515`
  (commandLine, shellQuote, createSurface, config.command/working_directory)
- `Sources/ContinuumRevived/TerminalEngine/GhosttyTerminalRuntime.swift:169-171`
  (capturedCwd = OSC-7), `:750-751,822` (GHOSTTY_ACTION_PWD delivery)
- `Sources/ContinuumRevivedCore/AmbientZoneHome.swift:11-30` (current resolution)

Docs:
- `docs/38-agent-orchestration-architecture.md` — Decision A `:133-183`, Decision B
  `:184-201`, lifecycle table `:166-172`, invariant spine I1/I2/I3/I8 `:377-387`,
  open questions `:523-537`
- `docs/34-tmux-shell-persistence.md` — current per-tile model, locked decisions
  `:123-132`, lifecycle table `:79-84`, sweep backstop note `:198`
- `docs/37-ticket-authoring-style-guide.md` — ticket section format `:60-187`,
  spike status `:30-38`
