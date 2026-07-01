# Grouped view session per tile — attach each ghostty surface via continuum-view-<tileId>

## What this delivers

After this ticket lands, every ghostty surface that renders a terminal tile attaches to tmux
not as a standalone client to a shared project session, but as a **grouped session** named
`continuum-view-<tileId>`, pinned to that tile's own window via `select-window`. The project
session `continuum-proj-<projectId>` continues to own the windows — N tiles still share one
session, agents still run when ghostty surfaces are torn down — but each surface now carries
its own named view-client that tracks a different active window. Two tiles in the same project
never mirror each other's active window; they each see exactly the window they own.

From the user's perspective the behavior appears natural: open two terminal tiles in one
project zone, switch focus between them, and each shows what it should. No flickering active
window. No tile suddenly jumping to display a different agent's shell. From the system's
perspective, invariant I2 — no unintentional mirror — holds across any number of tiles in the
same project session, and view-session cleanup is fully deterministic: closing a tile kills its
view session, which owns no windows, so no project content is lost.

This ticket rests on locked decision **D19** (grouped-session naming/cleanup:
`continuum-view-<tileId>` off `continuum-proj-<projectId>`, cleaned on tile close) and on
**D20** (two tiles may deliberately view the same window; that case is exempt from I2). It is
the de-mirror step (Decision B / spike ticket T3) that the project=session topology (Decision
A / spike ticket T2) makes necessary.

## How it fits

This ticket is the grouped-session de-mirror step that Decision B in the architecture document
settled on and that Decision D19 in the locked decisions document named in detail. It builds
directly on three upstream pieces, none of which exist in the tree today — this ticket **must
not be started until all three have landed**, because their exact shapes are load-bearing here
and are named as hard dependencies in the "Depends on" section:

- **The project-session-naming work** (spike ticket T2), which mints
  `continuum-proj-<projectId>` as the base session name this ticket groups onto and adds the
  Core function that produces it.
- **The new-window spawn work** (spike ticket T2), which changed tile spawn to `new-window`
  inside a project session and established that each tile has a tmux window.
- **The capture-window-target work** (spike ticket T1), which adds `tmuxWindowTarget: String?`
  to `TerminalSessionDescriptor` and persists the tile's `%pane_id` there — the very handle
  that `select-window` needs to pin a view client to the right window. **Verified against the
  current tree:** `TerminalSessionDescriptor`
  (`Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift`) today has **no**
  `tmuxWindowTarget` field (its fields end at `scrollback`, and `currentSchemaVersion == 2`);
  T1 adds the field and bumps the schema to 3. This ticket reads that field and does not add it.

Without the window target captured and on disk, a view session could be created but not
pinned: the `select-window` call needs `tmuxWindowTarget` to be present, valid, and non-nil.
That is a hard dependency on the capture-window-target work.

This ticket unblocks the restart-survival story (reattaching a ghostty surface after teardown
now means re-creating the grouped view session and re-running `select-window` to the same
target), and it closes the open I2 edge case in the invariant spine harness (which currently
has no real-path proof that two simultaneous tiles show distinct windows). The close-tile work
that kills the tmux window on tile delete gains a companion obligation here: it must also kill
`continuum-view-<tileId>` at teardown.

## The tmux command-separator token — LOCKED, not a runtime discovery

This is the single hardest detail, and it is **resolved to one value here so no implementer
ever hits a fork.** The separator token this ticket passes to tmux is the literal string
`";"` — a bare semicolon, as its own element in the `arguments` array. **Never `"\\;"`.**

The reasoning is deterministic, not empirical, so there is nothing to "discover at runtime":

- `GhosttyTerminalView.createSurface`
  (`Sources/ContinuumRevived/TerminalEngine/GhosttyTerminalView.swift`) forks the tmux binary
  **directly, with no shell** — it builds `config.command` from a shell-quoted join of
  `[command] + arguments` and hands it to ghostty, which execs the process. There is no
  `/bin/sh -c` in this path.
- The backslash in `\;` exists **only** to protect the `;` from a shell that would otherwise
  interpret it as a shell statement separator. When there is no shell, there is nothing to
  protect against: tmux's own argument parser reads a bare `;` argument as its multi-command
  separator. Passing `"\\;"` would deliver a literal backslash-semicolon to tmux, which tmux
  does **not** treat as a separator — it would try to parse `\;` as (part of) a command name
  and fail. That is the wrong value.
- The one exception — the integration check below — issues tmux commands from a real shell
  (it runs `tmux …` command lines, not `Process`-forked argv). In that shell context, and
  **only** there, the separator must be shell-escaped as `\;`. This is not a contradiction:
  the production argv uses `";"` because there is no shell; the shell-based check uses `\;`
  because there is one. The rule is a function of "is there a shell between me and tmux," and
  it is decided per-call-site, not left open.

So: **production `wrapViewSession` argv → `";"`. Shell-issued integration-check command lines
→ `\;`.** Both are correct for their context; neither is a guess. The integration check below
still exercises the production `wrapViewSession` output (it forks the exact argv the profile
carries) so the `";"` choice is proven end-to-end, but the choice itself is already made.

## The approach

The ghostty surface's launch argv, carried in the `LaunchProfile` and consumed verbatim by
`GhosttyTerminalView.createSurface`, changes from the current per-tile session attach to a
grouped-session attach. Today the wrap function (`TmuxSession.wrap` in
`Sources/ContinuumRevivedCore/TmuxSession.swift`, verified present) produces:

```
tmux new-session -A -s continuum-<tileId> -c <cwd> [inner cmd...]
```

After this ticket, for project tiles, `wrapViewSession` produces argv equivalent to:

```
tmux new-session -t continuum-proj-<projectId> -s continuum-view-<tileId> -A ; select-window -t <tmuxWindowTarget>
```

The `;` separator is tmux's own multi-command syntax within one invocation, passed as the
literal argument token `";"` per the locked decision above. The two logical commands —
`new-session -t … -s … -A` (create-or-attach the view client grouped onto the project session)
and `select-window -t <target>` (pin it to the tile's window) — are joined this way because
`GhosttyTerminalView.createSurface` forks exactly one process: the tmux binary with one argv.
There is no shell involved, so a pipe or `&&` would not work; the tmux `;` form is the
correct mechanism.

The `new-session -t <projectSession> -s <viewSession>` form creates a grouped session: it
shares the project session's window list but maintains its own active-window pointer. Each
grouped client has an independent `select-window` state. After `select-window -t
<tmuxWindowTarget>` runs, the view client's active window is pinned to the tile's `%pane_id`.
A second tile with its own view session runs the same sequence and pins to its own
`%pane_id`. They are independent; no mirroring occurs.

The `;` join means `shouldPassInnerCommand` logic from `TmuxSession.wrap` no longer applies
to this attach path: the inner command was already baked into the window when it was
pre-created by `new-window` with the correct `[inner cmd...]`. The view-session attach is
a pure attach operation; it must not re-run the inner command. The new `wrapViewSession`
function (see below) takes the already-known `projectSessionName`, `tileId`, and
`tmuxWindowTarget` as parameters and produces a `LaunchProfile` whose command+arguments
encode the two-command tmux invocation.

On tile teardown, the view session is killed explicitly. A new
`TmuxSession.killViewSessionCommand(tileId:tmuxPath:)` static function produces `tmux
kill-session -t continuum-view-<tileId>`. The tile delete path in `ContinuumApp.swift` gains a
second command: after the window kill removes the tile's window from the project session,
`kill-session -t continuum-view-<tileId>` removes the view client. Because a view session owns
no windows of its own (it is grouped onto the project session), killing it is always safe:
tmux does not reap any content. (The exact function that runs the window kill, and the exact
`killWindowCommand` shape, come from the close-tile work — see the "Where it lives" and
"Depends on" sections; this ticket appends a second command after it, wherever it lands.)

The observer — `SessionObserver` or any read-only caller that issues `tmux display -p` to read
pane state — must never call `select-window`. `select-window` steers a client's active window;
if the observer called it on a view session, it would overwrite the user's pinning and cause a
visible jump. The observer reads via `tmux display -p -t <tmuxWindowTarget> '#{…}'`, which
targets the pane directly by its stable `%pane_id` and does not involve the view session's
active-window pointer at all. This is the correct and only read pattern.

For ambient tiles, which remain on the per-tile session fallback (per D15's phase-1 decision
and spike option (c)), the spawn path continues to produce the existing
`new-session -A -s continuum-<tileId>` wrap. The `wrapViewSession` function is only called when
`tmuxWindowTarget` is non-nil, which is only true for project-zone tiles that went through the
`new-window` pre-create path. No ambiguity: nil target means the old path, non-nil target means
the grouped view-session path.

The reattach path in `TileSpawner.restartTerminalTile` must be updated to match. After this
ticket, reattaching a tile means re-running the grouped view-session attach argv (same
`wrapViewSession` output) against the existing `tmuxWindowTarget`. The `-A` flag on the outer
`new-session` is important here: if `continuum-view-<tileId>` already exists (the ghostty
surface detached without the view session being killed), `-A` causes tmux to attach to the
existing view session rather than creating a new one, and `select-window` re-pins it. This is
correct for I8: reattaching after a ghostty teardown lands on the same window as before.

## Where the tile's own projectId comes from — the resolution seam

**This is the seam gap that must be closed explicitly.** D16 states that a project is **shared
across workspaces**, so the app-global "active project" is *not* a reliable source for a given
tile's own project — two workspaces can show two different projects while both route spawns
through one app-level `TileSpawner`, and the spike's "Current mapping" section confirms
descriptors always land in the boot store regardless of the visual zone. Deriving
`continuum-proj-<projectId>` from any global "active project" accessor would build the **wrong**
session name and group the view onto the wrong session. There is therefore **no** app-global
accessor named or used by this ticket.

The authoritative source for a tile's projectId is **the same source the upstream new-window
spawn work (T2) already uses to decide which `continuum-proj-<projectId>` session to create the
window in.** That work must expose the tile's target project as a value threaded to the wrap
layer — the spike calls this a **session-target provider** (`{ project(UUID) | ambient(…) }`,
resolved from the active *zone's* placement, not a global active-project). This ticket consumes
exactly that provider's `project(UUID)` case:

- **For spawn** (`tmuxWrappedProfileIfAvailable`): the projectId is the `project(UUID)` the
  session-target provider reports for the zone the tile is being spawned into — the identical
  value T2 used to build the `new-window -t continuum-proj-<projectId>` argv moments earlier.
  If the provider reports the ambient case (`projectId == nil`), this is an ambient tile and
  the code falls through to `TmuxSession.wrap` unchanged (D15 fallback (c)).
- **For reattach** (`restartTerminalTile`): the projectId is resolved the same way T2 resolves
  it when re-creating a window — from the persisted binding of the tile to its project, not
  from a global active-project. (T2 owns "how a restarted tile knows its project"; this ticket
  reuses that resolved value verbatim to build the same `projectSessionName`.)

Because both the spawn and reattach projectId are supplied by the T2 seam, this ticket does
**not** invent its own project-resolution logic and does **not** call any global
active-project accessor. If T2's provider is not yet in the tree, this ticket is blocked (see
"Depends on"). The pseudo-code below shows the projectId arriving as a parameter/closure
result from that seam, never derived locally.

## Where it lives

**`Sources/ContinuumRevivedCore/TmuxSession.swift`** (verified: `TmuxSession` enum begins at
line 7; today it contains `sessionName`, `wrap`, `killSessionCommand`, `shouldPassInnerCommand`
and there is no view-session or project-session function yet):

- New static function `viewSessionName(tileId: UUID) -> String` — returns
  `"continuum-view-\(tileId.uuidString)"`. Added as a peer of the existing
  `sessionName(tileId:)` and the project naming function `projectSessionName(projectId:)` that
  the upstream project-session-naming work (T2) adds. **Dependency shape (from T2, named
  here so this ticket can be written against it):** `projectSessionName(projectId: UUID) ->
  String` returns `"continuum-proj-\(projectId.uuidString)"`. This ticket calls it but does
  not define it.
- New static function
  `wrapViewSession(profile: LaunchProfile, tileId: UUID, projectSessionName: String, tmuxWindowTarget: String, tmuxPath: String) -> LaunchProfile`
  — produces the two-command grouped-session attach argv. Peer of the existing
  `wrap(profile:tileId:tmuxPath:)`; the existing `wrap` is not modified.
- New static function
  `killViewSessionCommand(tileId: UUID, tmuxPath: String) -> (command: String, arguments: [String])`
  — returns `(tmuxPath, ["kill-session", "-t", "continuum-view-<tileId>"])`. Peer of the
  existing `killSessionCommand(tileId:tmuxPath:)`.
- `shouldPassInnerCommand` remains unchanged and is not called from `wrapViewSession` (the
  view-session attach carries no inner command).

**`Sources/ContinuumRevived/App/TileSpawner.swift`** — `tmuxWrappedProfileIfAvailable` is the
dispatch point. **Verified current signature** (this is the *actual* code today, so the
implementer knows exactly what they are editing):

```swift
private func tmuxWrappedProfileIfAvailable(_ profile: LaunchProfile, tileId: UUID) -> LaunchProfile {
    guard TmuxPersistenceConfig.enabled(defaults: defaults),
          let tmuxPath = tmuxPathResolver(defaults) else {
        return profile
    }
    return TmuxSession.wrap(profile: profile, tileId: tileId, tmuxPath: tmuxPath)
}
```

Note the real names: the gate uses `defaults` (the spawner's stored `UserDefaults`) and
`tmuxPathResolver(defaults)` (a stored closure, `{ TmuxLocator.resolve(defaults: $0) }` by
default). There is **no** `appDefaults`, no direct `TmuxLocator.resolve(defaults:)` call, and
no `projectStore.listSessions()` / `activeProjectId()` in this function today. Any edit must
preserve those real names. After T1+T2 land, this function will already be reading the
descriptor's `tmuxWindowTarget` and the T2 session-target provider (T2's edit); this ticket's
change is to branch on that already-available target and, when non-nil, call `wrapViewSession`
instead of the project new-window wrap-for-attach that T2 introduced. When the target is nil
(ambient tile), it continues to call `TmuxSession.wrap` unchanged. The `restartTerminalTile`
path is updated to rebuild the grouped view-session attach argv from the stored
`descriptor.tmuxWindowTarget` when non-nil, using the T2-resolved projectId.

**`Sources/ContinuumRevived/App/ContinuumApp.swift`** — the terminal-tile delete path. **Ground
truth in the current tree:** the `.terminal` case of `deleteTile(id:)` calls
`killTmuxSessionForDeletedTerminalTile(tileId:)`, and that function
(`killTmuxSessionForDeletedTerminalTile`) issues `TmuxSession.killSessionCommand` via
`tmuxProcessRunner`. The **close-tile work (upstream) renames/rewrites this** to kill the tile's
**window** (`kill-window -t <target>`) instead of the whole session, and the architecture calls
that renamed function `killTmuxWindowForDeletedTerminalTile`. **That renamed function does not
exist in the current tree** — do not search for it by a fixed line number; it lands with the
close-tile work. This ticket's edit is: **immediately after that function issues its
`kill-window` command, add a second `tmuxProcessRunner` call that runs
`TmuxSession.killViewSessionCommand(tileId:tmuxPath:)`.** Locate the edit by the function's
role (the terminal-tile teardown tmux call, whatever its final name and line), not by a line
pin. Both commands run sequentially; the view-session kill is unconditional (a `kill-session`
on an absent session is a tmux no-op).

**`Sources/ContinuumRevived/TerminalEngine/GhosttyTerminalView.swift`** — `createSurface` is
unchanged. It consumes `config.command` and `config.working_directory` from the `LaunchProfile`
without any tmux-specific knowledge. The grouped-session attach argv is entirely carried in the
profile produced by `wrapViewSession`; no libghostty change is needed or made.

## Implementation breadcrumbs

The key types, functions, and control flow in the order an implementer would write them. Every
symbol below is either verified-present in the current tree, or explicitly named as coming from
a listed upstream dependency (T1's `tmuxWindowTarget`, T2's `projectSessionName` +
session-target provider, the close-tile work's window-kill function). No symbol is invented.

```swift
// In TmuxSession.swift — three new static functions added to the TmuxSession enum.
// (projectSessionName is NOT defined here — it comes from the T2 project-session-naming work.)

public static func viewSessionName(tileId: UUID) -> String {
    "continuum-view-\(tileId.uuidString)"
}

public static func wrapViewSession(
    profile: LaunchProfile,
    tileId: UUID,
    projectSessionName: String,   // "continuum-proj-<projectId>" — from T2's projectSessionName(projectId:)
    tmuxWindowTarget: String,     // "%N" pane id read from descriptor.tmuxWindowTarget (T1); caller guarantees non-nil
    tmuxPath: String
) -> LaunchProfile {
    let viewName = viewSessionName(tileId: tileId)
    // Build the two-command tmux argv:
    //   tmux new-session -t <projectSession> -s <viewSession> -A ; select-window -t <target>
    // The separator is the literal string ";" — a bare semicolon as its own array element.
    // NOT "\\;": there is no shell in createSurface's fork, so nothing needs backslash-escaping,
    // and tmux reads a bare ";" argument as its command separator. This is LOCKED (see the
    // "tmux command-separator token" section) — it is not something the real-path check decides.
    // "-A" means "attach if the view session already exists" (I8 reattach survival).
    let arguments: [String] = [
        "new-session",
        "-t", projectSessionName,
        "-s", viewName,
        "-A",
        ";",               // tmux multi-command separator (NOT a shell operator, NOT "\\;")
        "select-window",
        "-t", tmuxWindowTarget
    ]
    // working_directory is consumed by createSurface as config.working_directory. Keep it
    // unchanged; the window's cwd was already set at new-window time (T2).
    return LaunchProfile(
        command: tmuxPath,
        arguments: arguments,
        cwd: profile.cwd,
        title: profile.title
    )
}

public static func killViewSessionCommand(
    tileId: UUID,
    tmuxPath: String
) -> (command: String, arguments: [String]) {
    (command: tmuxPath,
     arguments: ["kill-session", "-t", viewSessionName(tileId: tileId)])
}
```

```swift
// In TileSpawner.tmuxWrappedProfileIfAvailable — the dispatch.
// REAL current signature/names shown; the guard is exactly today's code (defaults +
// tmuxPathResolver). The `tmuxWindowTarget` read and `sessionTargetProvider` are already
// present after T1+T2; this ticket adds the wrapViewSession branch.

private func tmuxWrappedProfileIfAvailable(_ profile: LaunchProfile, tileId: UUID) -> LaunchProfile {
    guard TmuxPersistenceConfig.enabled(defaults: defaults),
          let tmuxPath = tmuxPathResolver(defaults) else {
        return profile
    }
    // descriptor.tmuxWindowTarget is added by T1 (schema v3). The tile's own projectId comes
    // from T2's session-target provider (resolved from the ACTIVE ZONE, never a global
    // active-project — see "Where the tile's own projectId comes from"). Both reads below are
    // exactly the ones T2 already performs to build the new-window argv; this ticket reuses them.
    let descriptor = try? projectStore.listSessions().first(where: { $0.tileId == tileId })
    if let target = descriptor?.tmuxWindowTarget,
       case .project(let projectId)? = sessionTargetProvider?() {
        // Project tile with a captured window target — grouped view-session attach.
        return TmuxSession.wrapViewSession(
            profile: profile,
            tileId: tileId,
            projectSessionName: TmuxSession.projectSessionName(projectId: projectId), // from T2
            tmuxWindowTarget: target,
            tmuxPath: tmuxPath
        )
    }
    // Ambient tile (provider reports .ambient) or no target yet — existing per-tile wrap, unchanged.
    return TmuxSession.wrap(profile: profile, tileId: tileId, tmuxPath: tmuxPath)
}
```

```swift
// In ContinuumApp's terminal-tile teardown tmux function.
// Locate by ROLE, not line number: it is the function deleteTile's .terminal case calls to
// mutate tmux on close. Today that function is killTmuxSessionForDeletedTerminalTile and it
// issues killSessionCommand. The close-tile work renames it (arch name:
// killTmuxWindowForDeletedTerminalTile) and switches it to kill-window. This ticket appends a
// SECOND command right after the window kill, whatever the final name/line:

// (the close-tile work's existing window kill — shape owned by that work, shown for context)
let (killWindowCmd, killWindowArgs) = TmuxSession.killWindowCommand(/* target, tmuxPath — from close-tile work */)
try? tmuxProcessRunner(killWindowCmd, killWindowArgs)

// This ticket's addition — kill the view session AFTER the window kill:
let killView = TmuxSession.killViewSessionCommand(tileId: tileId, tmuxPath: tmuxPath)
try? tmuxProcessRunner(killView.command, killView.arguments)
// No guard on the view-session kill — kill-session on an absent session is a tmux no-op.
```

```swift
// In TileSpawner.restartTerminalTile — the reattach path for project tiles.
// When tmuxWindowTarget is non-nil and the liveness probe (owned by T2) passes, rebuild the
// grouped attach. projectId is the T2-resolved project for this tile (NOT a global accessor).

if let target = descriptor.tmuxWindowTarget,
   case .project(let projectId)? = sessionTargetProvider?() {
    let wrappedProfile = TmuxSession.wrapViewSession(
        profile: profileWithCwd,
        tileId: tileId,
        projectSessionName: TmuxSession.projectSessionName(projectId: projectId), // from T2
        tmuxWindowTarget: target,
        tmuxPath: tmuxPath
    )
    return spawnSurface(profile: wrappedProfile, tile: existing)
}
// Fallback: dead/nil target or ambient — existing new-window / per-tile path (T2 owns this).
```

**On the two named upstream shapes this ticket calls but does not define** (so the implementer
never has to guess them): `projectSessionName(projectId:)` returns
`"continuum-proj-\(projectId.uuidString)"` (T2); `descriptor.tmuxWindowTarget` is a
`String?` holding a `%N` pane id (T1); the session-target provider yields
`.project(UUID) | .ambient(…)` resolved from the active zone (T2); the window-kill function and
`killWindowCommand` shape belong to the close-tile work. If any of these is absent when this
ticket is picked up, **stop and confirm the dependency has landed** — do not stub it.

## How we test it

### Logic (pure Core checks)

Write these checks in `ContinuumRevivedCoreChecks` — pure Swift, no daemon, no display. These
depend only on Core symbols this ticket adds, so they can be written and pass **before** the
app-layer T2 wiring exists:

1. **View session name.** Table-driven: three fixed UUIDs, each asserts
   `TmuxSession.viewSessionName(tileId: id)` equals `"continuum-view-\(id.uuidString)"`.
   Assert that the view name for a given UUID differs from `sessionName(tileId:)` for the same
   UUID — the prefix is load-bearing.

2. **wrapViewSession argv shape.** Call `TmuxSession.wrapViewSession` with known inputs and
   assert the resulting `arguments` array equals, in order: `"new-session"`, `"-t"`, the
   project session name, `"-s"`, the view session name, `"-A"`, `";"`, `"select-window"`,
   `"-t"`, the window target. **Explicitly assert the separator element is exactly `";"` and
   is NOT `"\\;"`** — this is the locked-token regression guard. Assert `command == tmuxPath`.
   Assert no inner command appears anywhere in the array (the view-session attach must not
   re-run the profile's command). Run for both a shell profile and a non-shell profile —
   neither should carry an inner command in the attach argv.

3. **killViewSessionCommand argv shape.** Assert the `arguments` array equals
   `["kill-session", "-t", "continuum-view-<id>"]` for a known UUID.

4. **Distinctness from killSessionCommand.** For the same tileId, assert
   `killViewSessionCommand` produces a different target string than `killSessionCommand` (the
   per-tile session kill). This catches a copy-paste that accidentally reuses the old session
   name.

5. **wrapViewSession vs wrap produce different commands.** For the same profile and tileId,
   assert that `wrapViewSession(...)` and `wrap(profile:tileId:tmuxPath:)` produce different
   `arguments` arrays. This is a simple regression guard that the dispatch logic in
   `tmuxWrappedProfileIfAvailable` is actually branching.

All checks produce manifests with measured argument arrays, not `{passed: true}`.

### Backend (real-path / integration)

This check requires a real tmux daemon and drives the full grouped-session attach. It must not
bypass `TmuxSession.wrapViewSession` or fake the process fork: it forks the **exact argv** the
profile carries so the production `";"` token is exercised end-to-end. (Where the check issues
tmux command lines through a shell for *setup*, it uses `\;` — the shell context per the locked
token section. The one place it exercises production output, it forks argv, not a shell.)

The check:

1. Resolves a real tmux binary via `TmuxLocator.resolve()`. If nil, skip explicitly with a
   message — never pass silently.
2. Creates a project session with two windows:
   ```
   tmux new-session -d -s continuum-proj-RPTST -c /tmp
   tmux new-window  -d -t continuum-proj-RPTST -c /tmp -P -F '#{pane_id}'
   ```
   Capture both pane ids (`%A` and `%B`).
3. Creates two grouped view sessions by **forking the argv produced by
   `TmuxSession.wrapViewSession`** for two distinct tileIds (targets `%A` and `%B`), so the
   production `";"` separator is under test. (For readability, the equivalent shell form — used
   only if this step is hand-run in a shell — is
   `tmux new-session -t continuum-proj-RPTST -s continuum-view-TILE1 -A -d \; select-window -t %A`;
   the `\;` there is the shell escape, not the argv token.) The `-d` flag creates them detached
   so no actual client terminal is needed.
4. Reads the active window for each view session:
   ```
   tmux display -p -t continuum-view-TILE1 '#{window_id}'
   tmux display -p -t continuum-view-TILE2 '#{window_id}'
   ```
   Asserts that the two returned window ids are **different** — this is the I2 proof. If they
   are the same, the view sessions are mirroring each other and the ticket has not fixed the
   problem. (This also proves the `";"` token worked: if `select-window` never fired, both
   sessions would default to the same active window.)
5. Kills `continuum-view-TILE1` via the argv from `TmuxSession.killViewSessionCommand`. Asserts
   that `continuum-proj-RPTST` still exists (killing a view session must not kill the project
   session or its windows). Asserts that `continuum-view-TILE2` still exists and still shows
   window `%B`.
6. Kills `continuum-view-TILE2`. Asserts that `continuum-proj-RPTST` and both its windows
   still exist (view session kills are never project-window kills).
7. Kills `continuum-proj-RPTST` to clean up.

The manifest records: `tile1ActiveWindow`, `tile2ActiveWindow`, `areDifferent: true`,
`projectSessionSurvivedViewKill: true`, and the literal separator token forked (`";"`). These
are measured values.

### UX (visual gate + dogfood snippet)

**Visual gate.** In the Component Lab, load a sandbox with two terminal tiles in the same
project zone (the existing sandbox tile fixture). With this ticket wired: open the affordance
inspector (the existing affordance inspector tile in the lab), look at the argv shown for each
tile's launch profile. Each tile's displayed command string must contain `new-session -t
continuum-proj-` and `select-window -t %`, and the two `select-window` targets must be
different values. If both tiles show the same target, or if the command still shows
`new-session -A -s continuum-<tileId>`, the dispatch logic has not been updated.

**Dogfood snippet.** Open the real app. Open a project zone. Spawn two terminal tiles so they
both belong to the same project session. In each terminal, run a command that produces
distinguishable output — for example `echo "tile A"` in the first and `echo "tile B"` in the
second. Click back and forth between the two tiles. Each tile must persistently show its own
shell and its own output; neither tile should ever flash to show the other tile's content.
Then, in a third terminal (any shell outside Continuum), run:

```
tmux ls
```

You should see lines like:
```
continuum-proj-<uuid>: 2 windows (created …)
continuum-view-<uuid1>: 2 windows (created …) (grouped with continuum-proj-<uuid>)
continuum-view-<uuid2>: 2 windows (created …) (grouped with continuum-proj-<uuid>)
```

The two view sessions must both appear as grouped with the project session, and neither should
list 0 windows. Close one of the two tiles in Continuum. Re-run `tmux ls`. Only one
`continuum-view-` line should remain. The project session line should still show 1 window, not
disappear — the view session kill must not have reaped the project session.

## Execution mode

Supervised. The logic checks are pure and autonomous, but the I2 proof — that two tiles
simultaneously rendering in the same project session do not mirror each other — requires a
real-app visual confirmation. It is not enough to show that `tmux display` returns different
window ids in the integration check; the ghostty renderer must be observed to maintain two
independent active-window pointers across user interactions. The dogfood snippet is the honest
verification gate: click between two tiles and watch that neither flashes to the other's
content. That is a human-eyes check, not a matrix assertion.

The real-path check (backend tier) is machine-verifiable and must be green before the dogfood
is attempted, but green integration plus failing dogfood means the ticket is not done.

This ticket is also **blocked** (not merely supervised) until the three upstream dependencies
(T1 descriptor field, T2 project-session naming + new-window + session-target provider, the
close-tile window-kill function) have landed in the tree. The Core-only logic checks can be
written first; the app-layer wiring and both real-path/dogfood gates cannot run before the
dependencies exist.

## Done when

- [ ] `TmuxSession.viewSessionName(tileId:)` exists in Core, returns
  `"continuum-view-\(tileId.uuidString)"`, and the naming check passes with measured values.
- [ ] `TmuxSession.wrapViewSession(profile:tileId:projectSessionName:tmuxWindowTarget:tmuxPath:)`
  exists and produces a `LaunchProfile` whose `arguments` encode
  `new-session -t <projectSession> -s <viewSession> -A ; select-window -t <target>` with the
  separator element exactly `";"` (never `"\\;"`) and with no inner command in the argv.
- [ ] `TmuxSession.killViewSessionCommand(tileId:tmuxPath:)` exists and produces
  `["kill-session", "-t", "continuum-view-<tileId>"]`.
- [ ] `tmuxWrappedProfileIfAvailable` dispatches to `wrapViewSession` when
  `descriptor.tmuxWindowTarget` is non-nil **and** the T2 session-target provider reports
  `.project(projectId)`, and to the existing `wrap` when the target is nil or the provider
  reports `.ambient`. The projectId used is the provider's, never a global active-project.
- [ ] `restartTerminalTile` rebuilds the grouped view-session attach argv from the stored
  `tmuxWindowTarget` when non-nil, re-running `wrapViewSession` with the persisted target and
  the T2-resolved projectId.
- [ ] The tile delete path kills the view session with `killViewSessionCommand` immediately
  after the close-tile work's window kill.
- [ ] All five logic checks pass (view name, argv shape incl. the `";"`-not-`"\\;"` assertion,
  kill argv, distinctness, wrap comparison) with measured-value manifests.
- [ ] The real-path integration check passes: two grouped view sessions show different active
  window ids; killing a view session leaves the project session and remaining view session
  intact. Manifest carries measured `tile1ActiveWindow`, `tile2ActiveWindow`, and the forked
  separator token `";"`.
- [ ] The visual gate passes: Component Lab affordance inspector shows per-tile `select-window`
  targets that differ between two tiles in the same project zone.
- [ ] The dogfood snippet passes: two tiles in the real app maintain independent content
  without mirroring; `tmux ls` shows two grouped view sessions; closing one tile removes
  exactly its view session without removing the project session.
- [ ] No existing ambient-tile behavior changes: tiles with `tmuxWindowTarget == nil` still
  spawn via the existing `TmuxSession.wrap` path.
- [ ] The observer code contains no `select-window` calls; all reads go through
  `tmux display -p -t <target>`.

## Depends on / unblocks

This ticket has three **hard** upstream dependencies and must not be started until all three
have landed. For each, the exact shape this ticket relies on is named so the implementer never
guesses (the shapes themselves are owned by the upstream ticket — do not stub them here):

- **Project-session-naming + new-window spawn + session-target provider (spike ticket T2).**
  Provides `TmuxSession.projectSessionName(projectId: UUID) -> String` (=
  `"continuum-proj-<projectId>"`), the `new-window`-based project spawn, and the
  **session-target provider** that reports `.project(UUID) | .ambient(…)` **resolved from the
  active zone's placement, not a global active-project** (this is the seam this ticket reads
  for the tile's own projectId — see D16: projects are shared across workspaces, so no global
  accessor is authoritative).
- **Capture-window-target (spike ticket T1).** Adds `tmuxWindowTarget: String?` to
  `TerminalSessionDescriptor` (schema v2 → v3, `decodeIfPresent`) holding the tile's `%N` pane
  id, populated synchronously at spawn. Verified absent in the current tree — this ticket reads
  the field, does not add it. Without a non-nil `tmuxWindowTarget`, `wrapViewSession` has no
  target to pass to `select-window`.
- **Close-tile window-kill (close-tile work).** Provides the terminal-tile teardown function
  (arch name `killTmuxWindowForDeletedTerminalTile`) that issues `kill-window -t <target>` and
  the `TmuxSession.killWindowCommand` it calls. Verified absent: today the tree has
  `killTmuxSessionForDeletedTerminalTile` calling `killSessionCommand` instead. This ticket
  appends its `killViewSessionCommand` call after that function's window kill.

This ticket unblocks the restart-survival work for the grouped-session model (reattaching a
surface after teardown now goes through `wrapViewSession`, which needs to exist and be
correct). It also closes the I2 real-path gap in the invariant spine harness, which is waiting
for a non-degenerate proof that two tiles in one project session render different windows. The
launch-time sweep work (spike ticket T5, the I3 backstop that reaps orphaned sessions) gains a
new session prefix to handle — `continuum-view-` — and cannot be considered complete until this
ticket has defined what a view session is.

## Watch out for

**The `";"` separator token is LOCKED — do not re-litigate it at runtime.** When tmux is
called from Swift's `Process`/ghostty fork (no shell), the multi-command separator is the
literal string `";"` as its own element in the `arguments` array, no surrounding spaces. tmux
parses its own argument vector for this token before invoking commands. **`"\\;"` is wrong in
this context** (it is the *shell* escape and would deliver a literal backslash to tmux); it is
only correct when issuing tmux from a real shell (as the integration check's setup lines do).
Embedding `"; select-window …"` as a single string (tmux won't split it) and using a wrapper
script are also wrong. The value is decided (`";"` for argv, `\;` for shell); the real-path
integration check *confirms* it end-to-end but does not *choose* it. Run the check early; if
`select-window` never fires, inspect the raw argument array and the tmux invocation log.

**The tile's projectId must come from the T2 session-target provider, never a global
active-project.** D16 makes projects shared across workspaces, so any app-global "active
project" accessor can name the wrong session and group the view onto the wrong project session.
Always read the projectId from the same seam T2 used to create the window; if that seam is
unavailable, the tile is ambient and falls through to `TmuxSession.wrap`.

**The view session must use `-A` in its `new-session` call.** Without `-A`, re-launching a
surface for a tile whose view session already exists (because ghostty tore down without the
view session being killed) creates a duplicate named session, which tmux rejects with an
error. The `-A` flag is what gives I8 its "reattach, not recreate" property for view sessions.

**The observer must never call `select-window`.** If any future code in `SessionObserver` or
its dependencies is tempted to call `select-window` to "navigate to" a pane for reading
purposes, that must be rejected. The observer reads pane state by targeting the `%pane_id`
directly with `tmux display -p -t <tmuxWindowTarget>`. That command reads the pane without
moving any client's active window. Using `select-window` would overwrite the user's view
pinning and cause a visible jump. The rule is: **if your code is reading, use `-t <pane_id>`;
if your code is calling `select-window`, it is driving, and driver code does not belong in
the observer**.

**View session kill must happen after window kill, not before.** The `kill-window` call
removes the tile's content from the project session. The `kill-session` of the view client
removes the client. If `kill-session` runs first on a grouped session, tmux behavior for the
project session's windows may be undefined (tmux versions differ here). Always: `kill-window
-t <target>` first, then `kill-session -t continuum-view-<tileId>`.

**Ambient tiles must not be touched.** Ambient tiles use the per-tile session fallback
(`continuum-<tileId>`, the existing `TmuxSession.wrap` path) for the duration of phase 1 (D15
fallback (c)). The dispatch in `tmuxWrappedProfileIfAvailable` gates on `tmuxWindowTarget !=
nil` **and** the provider reporting `.project`. If the target is nil — which is exactly the
case for ambient tiles, since the `new-window` pre-create path never ran for them — the code
must fall through to `TmuxSession.wrap` unchanged. Do not add a fallback that calls
`wrapViewSession` with an empty-string target; that would produce a malformed `select-window`
call and fail silently.
