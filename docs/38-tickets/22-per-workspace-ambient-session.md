# Per-workspace session for ambient tiles

Rests on **D15** ("Ambient / group-zone tiles → per-workspace session `continuum-ws-<id>`, behind
a per-tile fallback for phase 1") and **D16** ("Close tile = `kill-window`; session dies at 0
windows; project release = DETACH, never kill") in `docs/38-locked-decisions.md`, and confirms the
TOPOLOGY spike's recommendation (a) with (c) as the shipped phase-1 fallback.

## What this delivers

After this lands, every terminal tile that lives in an ambient (group) zone — meaning its zone has
`ZonePlacement.projectId == nil` — is hosted as a window inside a shared per-workspace session
named `continuum-ws-<workspaceId>`, rather than as its own isolated `continuum-<tileId>` session.
Two ambient tiles in the same workspace now share an environment, inherit the focused tile's working
directory when spawning, and coexist inside one tmux session exactly the way project tiles coexist
inside `continuum-proj-<projectId>`.

The per-tile fallback path (`continuum-<tileId>`, still used today for ambient tiles because the
new-tile-as-window spawn work deliberately left ambient tiles on the per-tile model) is kept as a
runtime setting and stays selected by default until the per-workspace path has passed its checks.
Once those checks pass, the default flips and the fallback becomes dead code ready for a follow-up
removal.

The system outcome: I3 (no session leak) gains a workspace arm — live sessions are now a subset of
live projects **plus** live workspaces — and ambient tiles shed the one-tile-one-session overhead
that motivated this entire topology program.

## How it fits

This work is the direct follow-on to three earlier pieces of the phase-1 topology program, all of
which must be merged before this can begin. It does not re-establish any of them; it consumes them.

- **Project session naming & lifecycle ownership** is where `TmuxSession.ambientSessionName(workspaceId:)`
  is defined (it returns `"continuum-ws-<workspaceId.uuidString>"`). This work does not add that
  function — it calls it. Nothing here compiles until that function exists in
  `TmuxSession.swift`. If the naming work has not merged, stop and land it first.
- **New terminal tile spawns a window in the project session** is where the two-step
  create-then-attach mechanism was resolved for project zones: create the window out-of-band via the
  injectable `TmuxControl` substrate (which captures the `%pane_id` from a readable `Process`
  stdout), persist that pane id as `TerminalSessionDescriptor.tmuxWindowTarget`, then attach ghostty
  with a plain `attach-session -t <paneId>` profile built by `TmuxSession.attachWindowProfile`. That
  work also added the `sessionExists(name:)` read-only probe to `TmuxControl`, and added the
  `tmuxWindowTarget: String?` field plus schema v3 to the descriptor. This work reuses that exact
  mechanism, keyed on `continuum-ws-<workspaceId>` instead of `continuum-proj-<projectId>`. Every
  breadcrumb below is written to that mechanism — a ghostty-argv `-P -F '#{pane_id}'` capture is
  impossible (ghostty's child stdout is not readable by Swift) and is not used anywhere here.
- **Close tile = kill-window** is where the close path became window-scoped:
  `killTmuxWindowForDeletedTerminalTile` in `ContinuumApp.swift` reads
  `descriptor.tmuxWindowTarget` and, when it is non-nil, issues `kill-window -t <target>` via
  `TmuxSession.killWindowCommand(target:tmuxPath:)`; when it is nil (a pre-topology tile), it falls
  back to the legacy `kill-session -t continuum-<tileId>`. This work reuses that same typed
  `tmuxWindowTarget != nil` dispatch for ambient tiles — an ambient window is killed by
  `kill-window` on its captured pane id, identical to a project window.

It also depends on the membership register work (the re-modeling of `groupZoneTiles` into the
tile-level `zoneId` register on `Tile`, with `WorkspaceDocument.ambientTiles` as the populated
per-workspace membership store). That is what makes the per-workspace home clean: once membership is
a property of the tile itself, the spawn path can answer "which workspace does this ambient tile
belong to?" from the active `WorkspaceRuntime` directly, without the previously clear-only `setTiles`
write path that per-zone sessions would have required. The TOPOLOGY spike rejected per-zone sessions
for exactly this reason (D15).

This work is what the grouped view-session de-mirror work needs before it can de-mirror ambient
tiles (that work forms `continuum-view-<tileId>` grouped onto a base session, and for ambient tiles
the base session must be `continuum-ws-<workspaceId>`, which only exists once this ships). It also
gives the activity-surface work a complete, non-mocked session owner for every tile kind.

## The approach

The spawn path already has a branching point: `activeZoneProjectEntry()` in `ContinuumApp`
(`ContinuumApp.swift:6969`) resolves the active zone's `projectId`, returning nil for ambient zones.
That same branch is where the session target is chosen. The new-tile-as-window work already wired a
`projectId: UUID?` through `tmuxWrappedProfileIfAvailable`; this work widens that from "project id or
nothing" to a typed target that also carries the ambient case.

### The one mechanism this work uses (and the one it does not)

This work commits to exactly the mechanism the new-tile-as-window work resolved. Read this first —
every breadcrumb below assumes it.

**Rejected:** letting ghostty run `tmux new-session -A -s continuum-ws-<id> … -P -F '#{pane_id}'`
as its own argv and reading the pane id back. This cannot work, for two independent reasons:
1. Ghostty forks a pty and runs the argv *inside* it; the `-P` output goes to that pty (rendered as
   terminal text), not to any Swift `Process` pipe Continuum can read. There is no code path by which
   Swift sees ghostty's child stdout.
2. `new-session -A` unconditionally would, on the second tile, attach a **second client to the same
   window** (that is what `-A` means: attach-if-exists) — a mirror, breaking I1 and I2 silently. It
   never creates a *new window* for the second tile.

So this work never puts window creation or `-P -F '#{pane_id}'` in ghostty's argv, and never uses
`new-session -A` for ambient windows.

**Adopted — the two-step create-then-attach, via the injectable `TmuxControl` substrate:**

1. **Create the window out-of-band and capture its pane id, via `TmuxControl`** (fake in checks,
   `ProcessTmuxControl` running real `tmux` in production). `TmuxControl` runs `tmux` as a Swift
   `Process` whose stdout *is* readable, so `-P -F '#{pane_id}'` works there and the substrate call
   returns the captured `%pane_id` as its Swift return value. Which call to make is decided
   **deterministically, before the call**, by the read-only `sessionExists(name:)` probe the
   new-tile-as-window work added to `TmuxControl` (fake: in-memory map; `ProcessTmuxControl`:
   `tmux has-session -t <name>`, exit 0 = true):
   - `sessionExists("continuum-ws-<workspaceId>") == false` → first ambient tile in the workspace →
     `TmuxControl.newSession(name:cwd:innerCommand:)`, which runs
     `tmux new-session -d -s continuum-ws-<workspaceId> -c <cwd> -P -F '#{pane_id}' [-- inner]` and
     returns the first window's pane id.
   - `sessionExists(...) == true` → subsequent ambient tile → `TmuxControl.newWindow(inSession:cwd:innerCommand:)`,
     which runs `tmux new-window -t continuum-ws-<workspaceId> -c <cwd> -P -F '#{pane_id}' [-- inner]`
     and returns the new window's pane id.
   Both create the window **detached** (`new-session -d`; `new-window` is detached by default). The
   window fully exists, with a known pane id, before ghostty is involved. This is *not* a
   try-`newWindow`-catch-`newSession` scheme — the probe decides up front, which is what makes the
   acceptance assertion ("exactly one `newSession` + one `newWindow` for two tiles") achievable with
   no stray caught error in the log.

2. **Attach ghostty to the already-created window** via the plain-attach profile the new-tile-as-window
   work established: `TmuxSession.attachWindowProfile(paneTarget: capturedId, cwd:, tmuxPath:)`,
   whose argv is `["attach-session", "-t", capturedId]` — no creation, no `-P`. Attaching with a
   pane target (`%N`) selects that pane's window, so ghostty lands on exactly the window step 1
   created. (The grouped view-session form is the de-mirror work's job, out of scope here.)

The captured `%pane_id` is stored as `tmuxWindowTarget` on the descriptor and the descriptor is
saved synchronously before the spawn returns. On a save failure after window creation, the
compensating action is `TmuxControl.killWindow(target: capturedId)` before returning the error —
identical to the project path, so no orphan window accumulates.

### Wiring the ambient case into the target dispatch

`tmuxWrappedProfileIfAvailable` in `TileSpawner` currently takes a `projectId: UUID?` and branches
"project window path if non-nil, legacy per-tile path if nil." This work replaces that single
optional with a typed target resolved by a new `terminalSessionTargetProvider` closure — parallel to
the existing `terminalProjectContextProvider` — that returns:

```
enum TerminalSessionTarget: Sendable {
    case project(projectId: UUID)
    case ambient(workspaceId: UUID)
}
```

The provider is set from `ContinuumApp` at startup, reading `activeZoneProjectEntry()`: a non-nil
`projectId` yields `.project`; a nil `projectId` with a live active `WorkspaceRuntime` yields
`.ambient(workspaceId: runtime.workspace.id)`. When there is no active zone at all, the provider
returns nil and the spawn takes the legacy per-tile path unchanged (this is the same nil-safety the
project path already has).

The ambient path is selected only when the per-workspace setting is on (see next section). When it
is off, an `.ambient` target is treated exactly as today: the spawn falls through to
`TmuxSession.wrap(profile:tileId:tmuxPath:)`, the tested per-tile path. This is the D15 phase-1
fallback.

### The phase-1 fallback setting

Per D15 the per-workspace path ships behind the tested per-tile fallback. The selector is a single
`Bool`, `ambientPerWorkspaceEnabled`, read from a new `TmuxPersistenceConfig` key
`continuum.terminal.tmux.ambientPerWorkspace` (default `false`). **The default is flipped to `true`
only after the checks below pass** — but, crucially, the checks do **not** depend on the default:
`ambientPerWorkspaceEnabled(defaults:)` takes an injectable `UserDefaults`, and every Logic and
Backend check constructs a fresh suite with the key written `true` to exercise the per-workspace
path directly. The shipped default is a separate one-line change whose only justification is that the
injected-`true` checks already pass. This is the only place the setting is read; it is never threaded
into business logic elsewhere.

### The kill path

Because ambient tiles now carry a real `tmuxWindowTarget`, closing one reuses the close-tile
work's typed dispatch with **no ambient-specific branch**: `killTmuxWindowForDeletedTerminalTile`
sees a non-nil `tmuxWindowTarget` and issues `kill-window -t <target>` (via
`TmuxSession.killWindowCommand`). When the killed window is the last in the workspace session, tmux
ends the session on its own — no extra call. The nil-target legacy fallback (`kill-session -t
continuum-<tileId>`) remains for pre-topology descriptors. Dispatch is on the **typed
`tmuxWindowTarget` field**, never on sniffing session names out of `descriptor.args`.

The one ambient-specific kill is on **workspace delete**: `deleteWorkspaceAndRelaunch`
(`ContinuumApp.swift:6598`) must, while the workspace's id is still reachable, issue
`TmuxControl.killSession(name: TmuxSession.ambientSessionName(workspaceId:))` to prevent a leaked
workspace session — analogous to the way project deletion is the one legitimate `kill-session` for a
project session. This is the workspace arm of I3.

Restart/rebind and flush need no ambient-specific logic: the dead-target-to-new-window fallback
already rebinds by `tmuxWindowTarget` universally, and an ambient tile's target is captured and
persisted the same way a project tile's is.

## Where it lives

**`Sources/ContinuumRevivedCore/TmuxSession.swift`** — the `TerminalSessionTarget` enum is added
here (pure). `TmuxSession.ambientSessionName(workspaceId:)` is **not added here** — it is provided by
the merged project-session-naming work and only called from this work. No new argv constructor is
needed: window creation is `TmuxControl`'s job and the plain-attach
`TmuxSession.attachWindowProfile` is provided by the merged new-tile-as-window work.

**`Sources/ContinuumRevivedCore/TmuxSession.swift` (`TmuxPersistenceConfig`, lines 78–96)** — new key
`continuum.terminal.tmux.ambientPerWorkspace` and `ambientPerWorkspaceEnabled(defaults:) -> Bool`,
mirroring the existing `enabled(defaults:)` pattern (default via `object(forKey:) != nil ? bool :
default`). Default `false`; flipped to `true` in a follow-on one-line change after the checks pass.

**`Sources/ContinuumRevivedCore/AmbientZoneHome.swift`** — no changes to resolution logic. The cwd
fallback for a new ambient window reads `AmbientZoneHome.current` exactly as today. Listed as a seam
only because the spawn path reads it for the ambient cwd fallback and this work must confirm that
reading still works when the target switches to per-workspace.

**`Sources/ContinuumRevived/App/TileSpawner.swift`** — the `terminalSessionTargetProvider` closure
property is added alongside `terminalProjectContextProvider`. `tmuxWrappedProfileIfAvailable` (whose
project path already uses `TmuxControl.sessionExists` → `newSession`/`newWindow` →
`attachWindowProfile`) gains the `.ambient(workspaceId:)` arm, gated by `ambientPerWorkspaceEnabled`;
when the setting is off it falls through to `TmuxSession.wrap` for the ambient case. `restartTerminalTile`
is unchanged (it rebinds by `tmuxWindowTarget`).

**`Sources/ContinuumRevived/App/ContinuumApp.swift`** — wires `terminalSessionTargetProvider` at
startup in the tileSpawner setup region (`ContinuumApp.swift:2400-2445`). `deleteWorkspaceAndRelaunch`
(`ContinuumApp.swift:6598`) gains the workspace-session `killSession` before the runtime is released.
`killTmuxWindowForDeletedTerminalTile` (from the close-tile work) needs **no change** — its typed
`tmuxWindowTarget` dispatch already handles ambient windows.

## Implementation breadcrumbs

```swift
// TmuxSession.swift — the typed target (pure). ambientSessionName is provided by the
// merged project-session-naming work; this only adds the enum.
public enum TerminalSessionTarget: Sendable {
    case project(projectId: UUID)
    case ambient(workspaceId: UUID)
}
```

```swift
// TmuxPersistenceConfig — phase-1 fallback selector, injectable so checks don't touch the default.
public static let ambientPerWorkspaceKey = "continuum.terminal.tmux.ambientPerWorkspace"
public static let ambientPerWorkspaceDefault = false // flipped to true after checks pass

public static func ambientPerWorkspaceEnabled(defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: ambientPerWorkspaceKey) != nil
        ? defaults.bool(forKey: ambientPerWorkspaceKey)
        : ambientPerWorkspaceDefault
}
```

```swift
// TileSpawner.swift — the ambient arm added to tmuxWrappedProfileIfAvailable.
// The project arm (already shipped by the new-tile-as-window work) is shown for parallelism.
// NOTE: window creation + pane-id capture is TmuxControl's (readable Process), never ghostty argv.

let target: TerminalSessionTarget? = terminalSessionTargetProvider?()

switch target {
case .project(let projectId):
    // existing project path (unchanged) — sessionExists → newSession/newWindow → attachWindowProfile
    ...

case .ambient(let workspaceId) where TmuxPersistenceConfig.ambientPerWorkspaceEnabled(defaults: defaults):
    let wsSession = TmuxSession.ambientSessionName(workspaceId: workspaceId)
    // DETERMINISTIC branch — decide BEFORE the call, no try/catch fallback.
    let paneId: String
    if try await tmuxControl.sessionExists(name: wsSession) {
        paneId = try await tmuxControl.newWindow(inSession: wsSession, cwd: profile.cwd, innerCommand: innerCmd(profile))
    } else {
        paneId = try await tmuxControl.newSession(name: wsSession, cwd: profile.cwd, innerCommand: innerCmd(profile))
    }
    let attachProfile = TmuxSession.attachWindowProfile(paneTarget: paneId, cwd: profile.cwd, tmuxPath: tmuxPath)
    return (attachProfile, paneId)   // paneId → descriptor.tmuxWindowTarget, saved synchronously

case .ambient, .none:
    // setting off, or no active zone → tested per-tile fallback, unchanged
    return (TmuxSession.wrap(profile: profile, tileId: tile.id, tmuxPath: tmuxPath), nil)
}
```

```swift
// ContinuumApp.swift — provider wiring at startup, beside terminalProjectContextProvider.
tileSpawner.terminalSessionTargetProvider = { [weak self] in
    guard let self else { return nil }
    if let projectId = self.activeZoneProjectEntry()?.id {
        return .project(projectId: projectId)
    }
    if let workspaceId = self.workspaceRuntime?.workspace.id {
        return .ambient(workspaceId: workspaceId)   // active zone is ambient (projectId == nil)
    }
    return nil // no active zone — legacy per-tile fallback
}
```

```swift
// ContinuumApp.swift — deleteWorkspaceAndRelaunch: kill the workspace session BEFORE releasing
// the runtime, while workspaceId is still reachable.
let wsSession = TmuxSession.ambientSessionName(workspaceId: runtime.workspace.id)
try? await tmuxControl.killSession(name: wsSession)   // the one legitimate kill-session for a ws session
// ... then tear down the runtime as today.
```

## How we test it

### Logic (pure Core checks)

Deterministic checks in `ContinuumRevivedCoreChecks`, using `InMemoryTmuxControl` from the injectable
substrates and fixed UUIDs, no I/O. Every check that exercises the per-workspace path constructs a
fresh `UserDefaults` suite with `ambientPerWorkspace` written `true`, so it proves the true path
regardless of the shipped default.

1. **Two ambient tiles → one session, two windows, distinct targets.** Wire a `TileSpawner` with an
   `InMemoryTmuxControl` seeded with no sessions, a `terminalSessionTargetProvider` returning
   `.ambient(workspaceId: fixedId)`, and the injected `ambientPerWorkspace = true` suite. Spawn two
   ambient tiles. Assert `tmuxControl.log` contains **exactly one** `newSession` call (first tile:
   `sessionExists == false`) and **exactly one** `newWindow` call (second tile: `sessionExists ==
   true`), with **no** caught/failed calls. Assert `sessions["continuum-ws-<fixedId>"]` holds exactly
   two pane ids. Assert the two persisted descriptors have distinct non-nil `tmuxWindowTarget` values
   and each descriptor's `args` is the plain attach `["attach-session", "-t", <its target>]` — never a
   `new-session`/`new-window` argv, and never `new-session -A`. Manifest records the full log and both
   targets, not a boolean.

2. **Ambient target enum check.** Construct `TerminalSessionTarget.ambient(workspaceId: id)` and
   assert it does not equal `.project(projectId: id)` for the same UUID; assert a `.project` value
   round-trips through a switch without entering the ambient arm. Proves the two cases are distinct
   regardless of payload.

3. **Kill dispatch is target-typed.** Build an ambient descriptor with a non-nil `tmuxWindowTarget`
   and drive the close-tile dispatch: assert it selects `TmuxSession.killWindowCommand(target:…)`
   (`["kill-window", "-t", <target>]`), not any `kill-session`. Build a nil-target descriptor and
   assert it falls back to `killSessionCommand(tileId:…)`. Proves dispatch keys on the typed field,
   not on sniffing `args`.

4. **Workspace-delete kill argv.** Assert the workspace-delete path issues exactly one
   `TmuxControl.killSession(name:)` with `name == "continuum-ws-<id>"` for a fixed workspace id, and
   that it is distinct from any project-session kill. Manifest records the argument verbatim.

5. **Fallback-setting gate.** With the injected suite set `false`, spawn an `.ambient` tile and assert
   `tmuxControl.log` contains **no** `newSession`/`newWindow` calls, the descriptor's
   `tmuxWindowTarget` is nil, and the wrapped profile's argv begins `new-session -A -s
   continuum-<tileId>` (the tested per-tile path is untouched). With the suite `true`, assert the
   per-workspace path is taken. Also assert `ambientPerWorkspaceEnabled(defaults: fresh)` returns
   `false` for a suite with no value written — proving the shipped default cannot silently enable the
   path.

### Backend (real-path / integration, not bypassed)

Drives an actual tmux daemon via `ProcessTmuxControl`, gated on `TmuxLocator.resolve() != nil` (skips
cleanly, recording `tmux_absent=true`, when tmux is missing). It runs against a fresh `UserDefaults`
suite with `ambientPerWorkspace = true` — so it exercises the true path **without** depending on the
shipped default; the default-flip is a separate line the check does not gate on. Asserts, recording
measured values (never `{passed: true}`):

- Spawning two ambient tiles in one workspace produces exactly **one** session named
  `continuum-ws-<workspaceId>` (via `TmuxControl.listSessions()`) with exactly **two** windows.
- The two tiles' `tmuxWindowTarget` values are two distinct alive `%pane_id`s
  (`isAlive(paneTarget:)` true for both) — satisfying I1 and catching the mirror bug (a `new-session
  -A` regression would yield one shared window / one pane id, which this assertion fails on).
- Closing one ambient tile issues `kill-window -t <that target>` and reduces the window count to one;
  the session is still alive (`sessionExists` true).
- Closing the last ambient tile ends the session (`sessionExists` returns false).
- The workspace-delete path issues `killSession(name: "continuum-ws-<id>")` and the session is gone.
- With the suite `false`, the same spawn still produces `continuum-<tileId>` per-tile sessions and a
  `kill-session` (not `kill-window`) on close — proving the fallback is intact.

Manifest records: session names observed, window counts before/after each close, the pane ids per
tile, `isAlive` per pane, and every kill argument issued.

### UX (visual gate + dogfood snippet)

This work introduces no new UI surface, so its visual gate is an **observable-state** gate driven the
same way the new-tile-as-window work's gate is — through `tmux` state a human can read, not through
any affordance-inspector label (the inspector overlays hitboxes and screen-px metrics only; it has no
session-name display, and building one is not in scope here).

Dogfood snippet (this is the falsifiable proof): open Continuum with the per-workspace setting on →
open a workspace with at least one ambient (group) zone → spawn two terminal tiles inside that zone.
In the first tile's shell run `export HELLO=world`; in the second run `echo $HELLO` — you must see
`world`, proving the two windows share one session's environment (if it prints nothing, the spawn is
still per-tile). Then in either tile run `tmux ls` → see **exactly one** session named
`continuum-ws-<uuid>` reporting `2 windows`, not two separate `continuum-<tileId>` sessions. Close one
tile and run `tmux ls` in the survivor → the same session now shows `1 windows`, and the survivor is
still alive. This is the human-runnable confirmation that the shared session is live and that closing
one tile does not kill its sibling.

## Execution mode

**Autonomous.** The Logic checks are pure Core functions over `InMemoryTmuxControl` and fixed inputs
— no daemon, no disk, no device. The Backend check drives a real local tmux daemon through
`ProcessTmuxControl` (which the harness starts and stops within the check process, exactly as the
new-tile-as-window check does) and asserts measured tmux state — no human gate. The per-workspace
path is exercised by injecting `ambientPerWorkspace = true` into a fresh `UserDefaults` suite, so
correctness is fully established before any human opens the app and independent of the shipped
default. The dogfood snippet is a supervised convenience, not a required human judgment. No cloud
account, no real device, no iOS, no affordance-inspector UI work, and no human review is required.

## Done when

- [ ] `TerminalSessionTarget` enum exists in Core with `.project(projectId:)` and
  `.ambient(workspaceId:)` cases, distinct regardless of payload.
- [ ] `TmuxPersistenceConfig.ambientPerWorkspaceEnabled(defaults:)` exists, defaults `false`, reads
  the `continuum.terminal.tmux.ambientPerWorkspace` key, and is injectable so checks pass the setting
  explicitly.
- [ ] `TileSpawner.terminalSessionTargetProvider` closure property exists; `ContinuumApp` wires it at
  startup, returning `.project` for a non-nil active `projectId`, `.ambient(workspaceId:)` for a nil
  `projectId` with a live workspace, and nil when there is no active zone.
- [ ] With the setting on, spawning two ambient tiles in one workspace (via `InMemoryTmuxControl`)
  produces exactly one `newSession` call and one `newWindow` call, two distinct non-nil
  `tmuxWindowTarget` values, and each descriptor's `args` is the plain `["attach-session", "-t",
  <target>]` — never `new-session -A`.
- [ ] With the setting off, an `.ambient` spawn takes the unchanged per-tile
  `TmuxSession.wrap(profile:tileId:tmuxPath:)` path, `tmuxWindowTarget == nil`, and no new
  workspace session is created.
- [ ] Closing one ambient tile dispatches to `kill-window -t <tmuxWindowTarget>` via the existing
  typed close-tile dispatch (no ambient-specific branch, no `args` string-sniff); a nil-target
  pre-topology tile still falls back to `kill-session -t continuum-<tileId>`.
- [ ] `deleteWorkspaceAndRelaunch` issues `killSession(name: "continuum-ws-<id>")` before releasing
  the runtime.
- [ ] All Logic checks pass with measured-value manifests.
- [ ] The Backend real-path check passes (run against an injected `ambientPerWorkspace = true` suite):
  two ambient tiles share one `continuum-ws-<workspaceId>` session with two distinct alive panes;
  one-tile close is `kill-window` and leaves the session alive; last-tile close ends the session;
  workspace delete kills the session; the setting-off arm still produces per-tile sessions and
  `kill-session`. Skips cleanly when tmux is absent.
- [ ] After the Backend check passes, a separate one-line change flips
  `ambientPerWorkspaceDefault` to `true`. The checks above do **not** depend on that flip.
- [ ] The dogfood snippet reproduces: two ambient tiles share one `continuum-ws-<uuid>` session
  (`tmux ls` shows one session, two windows; `echo $HELLO` prints the exported value); closing one
  leaves the survivor and the session alive at one window.
- [ ] No changes to `AmbientZoneHome.swift` other than the existing cwd-fallback read in the spawn
  path — its resolution logic is untouched.

## Depends on / unblocks

Depends on, and does not re-establish, three merged pieces of the phase-1 topology program:
**Project session naming & lifecycle ownership** (provides `TmuxSession.ambientSessionName(workspaceId:)`);
**New terminal tile spawns a window in the project session** (provides the `TmuxControl`
create-then-attach mechanism, the `sessionExists` probe, `attachWindowProfile`, and the
`tmuxWindowTarget`/schema-v3 descriptor field); and **Close tile = kill-window** (provides the typed
`tmuxWindowTarget` close dispatch and `killWindowCommand`). It also depends on the
**membership-as-a-tile-register** work for a clean "which workspace owns this ambient tile" signal.
If any of these has not merged, stop and land it before starting here — every breadcrumb above calls
into them.

It unblocks the grouped view-session de-mirror work for ambient tiles (which forms
`continuum-view-<tileId>` grouped onto `continuum-ws-<workspaceId>`, and needs the workspace session
to exist first) and the launch-time `continuum-*` session sweep (which must treat `continuum-ws-*`
names as live workspace sessions to preserve, not legacy orphans to reap).

## Watch out for

**Never use `new-session -A` for an ambient window.** `-A` attaches a second client to the *same*
window on the second tile — a mirror that breaks I1/I2 silently. Window creation goes through
`TmuxControl.newSession`/`newWindow` (detached, capturing the pane id), with the first-vs-subsequent
choice made deterministically by the read-only `sessionExists` probe *before* the call — never a
try/catch fallback. The Backend check's "two distinct alive pane ids" assertion is the tripwire for
this exact bug.

**The default must stay `false` until the Backend check passes on the injected-`true` suite.**
Flipping it before the kill-window path, the workspace-delete kill, and the window-count close are
proven against a real tmux daemon risks orphaning ambient tiles or reaping the shared session when
only one tile closes. The default-flip is a separate one-line change; its sole justification is that
the injected-`true` checks already pass, so there is no chicken-and-egg — the checks exercise the true
path without the flip.

**The workspace-delete kill must run before the `WorkspaceRuntime` is torn down**, or the
`workspaceId` needed to form `continuum-ws-<workspaceId>` is no longer reachable. Read the id, issue
`killSession`, then release the runtime — not after.

**Old descriptors on disk** — written before this work — have `tmuxWindowTarget == nil` and per-tile
`continuum-<tileId>` names. This is a **typed** condition, not a heuristic: the close path already
routes nil-target descriptors to the legacy `kill-session`, and the dead-target-to-new-window rebind
already handles a nil/stale target by spawning a fresh window and capturing a new
`tmuxWindowTarget`. No `args` string-sniffing (no "does `args` contain `continuum-ws-`") is used or
needed — the presence of the typed field is the sole discriminator, and both paths are already
covered by the close-tile and dead-target-fallback work.

**Stop conditions.** Do not mark done if: an ambient window is created with `new-session -A` (mirror);
window creation or `-P -F '#{pane_id}'` appears in ghostty's argv (unreadable — capture must be via
`TmuxControl`); the first-vs-subsequent choice is made by try/catch instead of `sessionExists`; kill
dispatch sniffs `descriptor.args` instead of reading the typed `tmuxWindowTarget`; the default is
flipped to `true` in the same change as the checks (they must pass on the injected suite first); or
the workspace-delete kill runs after the runtime is released.
