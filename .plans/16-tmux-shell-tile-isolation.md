# 16 — Restore tmux shell-tile isolation

Status: **implemented; automated real-tmux and visual verification blocked by
the sandbox and deliberately not run against Array's live tmux server**

## Outcome

Opening a second shell tile must create a second independently usable terminal.
Project terminals may remain windows in one persistent project-owned tmux
session, but each Ghostty surface must have its own active-window state. Opening,
focusing, restarting, or closing one tile must never redirect another tile to the
same shell.

The intended topology is:

```text
array-proj-<projectId>       persistent owner of project terminal windows
├── window/pane A            shell for tile A
└── window/pane B            shell for tile B

array-view-<tileAId>         grouped view pinned to window A; Ghostty A attaches here
array-view-<tileBId>         grouped view pinned to window B; Ghostty B attaches here
```

This keeps project-level observability and lifecycle ownership without coupling
the visual selection of otherwise independent terminal tiles.

## What worked, and when

There was a real working interval. From June 17 until July 2, 2026, every
tmux-backed terminal tile owned a separate tmux session.

### June 17: isolated persistence lands

- `545947f` (`feat(core): add tmux session construction`) introduced stable
  tile-keyed names: `array-<tile UUID>`.
- `0a16ff1` at 13:53 EDT (`feat(app): wrap terminal tiles with tmux`) wired the
  app to launch each terminal as:

  ```text
  tmux new-session -A -s array-<tileId> -c <cwd>
  ```

- `d1cd54d` added a live persistence check later that afternoon.
- `ce945c2` on June 20 hardened the app-restart witness.

Because each tile had a different tmux **session**, its current-window state was
independent by construction. Multiple shell tiles could not mirror through tmux.

### July 2, 05:40: the regression is introduced

`947847e` (`feat(sessions): spawn project terminals as tmux windows`) changed the
model from one session per tile to one session per project with one window per
tile. That architectural direction was intentional, but only its first half
landed.

The new production path:

1. creates `array-proj-<projectId>`;
2. creates a different tmux window/pane for every tile;
3. captures each `%pane_id`;
4. launches every Ghostty surface with:

   ```text
   tmux attach-session -t <paneId>
   ```

A pane target chooses the window initially, but it does not give the client an
independent active-window pointer. In tmux, the selected window is session state.
All Ghostty clients attached directly to `array-proj-<projectId>` therefore
follow the same selected window. When the second tile attaches or selects its
window, both surfaces converge and mirror.

This is the first broken commit. The relevant production behavior remains in:

- `TileSpawner.tmuxWrappedProfileIfAvailable`, which creates/reuses project
  windows and returns `attachWindowProfile` for both new and restored tiles;
- `TmuxSession.attachWindowProfile`, which produces
  `attach-session -t <paneId>`.

### July 2, 06:15: the shared topology is fully wired

`934ad50` (`feat(sessions): share ambient tmux sessions per workspace`) added the
session-target provider used by the app. Project zones select
`.project(projectId)` and enter the broken shared-project path. It also added an
opt-in shared ambient/workspace topology with the same mirroring risk. Ambient
sharing defaults off, but project sharing is the normal path.

### July 2, 07:24: cleanup lands before creation

`5293064` (`feat(sessions): clean up tmux view sessions`) added deletion of
`array-view-<tileId>`. Production did not yet create such a view session, so the
cleanup targeted a nonexistent object. The archived audit later called this out
explicitly in `docs/38-tickets/_archive/_CODEX_AUDIT.md`.

### July 5: the solution is proven, but not wired

`bb49f83` (`test(tmux): add no-mirror real-path check`) added:

- grouped-view-session argv helpers;
- per-view `select-window` helpers;
- a real-tmux check proving two grouped sessions can hold different active
  windows.

That commit did **not** change `TileSpawner` to use the mechanism. The Core check
manually constructs the correct topology, while production continues to call
`attachWindowProfile`. There is no later commit that restores production
isolation.

### Why the incomplete state shipped

The architecture deliberately split the work into two phases:

1. project = session, tile = window;
2. de-mirror via one grouped view session per tile.

Phase 1 landed in `947847e`. Phase 2 was written as
`docs/38-tickets/27-grouped-view-session.md` but never implemented; every Done
when item in that ticket remains unchecked. The archived progress ledger states
that downstream ticket 30 was skipped because ticket 27 never landed. Ticket 28
cleanup and ticket 29's synthetic no-mirror check nevertheless landed around
the missing production step.

The regression predates the first public release (`0.2.0`, August 9), so there
is no known public release with the shared-project topology and correct
isolation. The last known-good implementation is the per-tile topology before
`947847e`.

## Why the current gates are green

Two checks validate opposite, disconnected realities:

1. The production persistence scenario in `TileSpawner.swift` spawns several
   project terminals, proves their pane targets differ, and then explicitly
   expects every descriptor to contain `attach-session -t <pane>`. Distinct
   panes do not imply distinct session active-window state; this assertion
   codifies the defect.
2. The I2 no-mirror block in `ContinuumRevivedCoreChecks/main.swift` manually
   creates grouped view sessions, selects a different window in each, and proves
   their active window IDs differ. It establishes that the proposed tmux
   mechanism works, but it never drives `TileSpawner` or a production-generated
   launch profile.

The matrix therefore proves “tmux can isolate these views” without proving
“Array launches terminals that way.”

## Repair plan

### 1. Make the existing production witness fail first

Change the project section of `--terminal-tmux-persistence-check` so it rejects
bare `attach-session -t %pane` for project tiles.

For two or more project terminal spawns, require:

- one shared base project session;
- a distinct captured pane/window target per tile;
- a stable, distinct `array-view-<tileId>` name per tile;
- launch argv that creates/attaches that view and selects its owned target;
- no production descriptor whose project launch is only
  `attach-session -t <pane>`.

Run it against the current implementation and retain the RED output as the
behavioral regression witness.

### 2. Add one production view-session profile builder

Add a Core helper, following ticket 27's existing contract, that builds a
`LaunchProfile` equivalent to:

```text
tmux new-session -t array-proj-<projectId> \
  -s array-view-<tileId> -A \
  ; select-window -t <paneTarget>
```

Requirements:

- `";"` is a literal argv element, not `"\\;"`;
- no inner shell/agent command is appended—the command already started when
  the project window was created;
- the original cwd and title remain on the launch profile;
- the view name derives only from the stable tile ID;
- project/base session name and pane target are explicit inputs;
- argument construction remains independently testable.

The existing `groupedViewSessionArguments` and `selectWindowArguments` helpers
can be composed or replaced by this one production-shaped API. Do not leave a
second hand-assembled version in the checks.

### 3. Use it for both fresh spawn and restart

Update `TileSpawner.tmuxWrappedProfileIfAvailable`:

- For `.project(projectId)`, create or recover the tile window exactly as today,
  then return the grouped view profile instead of `attachWindowProfile`.
- When a persisted pane target is still alive, reuse the same target, recreate
  or attach `array-view-<tileId>`, and explicitly select the target again.
- When the pane is dead, create a replacement window, persist its new target,
  and repin the same stable view-session name.
- Keep nil-target and non-shared ambient terminals on the existing per-tile
  `TmuxSession.wrap` path.

The fix must cover both return sites currently using `attachWindowProfile`; a
fresh-only repair would break again after app restart.

### 4. Decide and implement the shared-ambient rule

`ambientPerWorkspace=true` also puts several tiles into one base session. It
must not retain direct pane attaches.

Preferred rule: apply the same per-tile grouped view topology using
`array-ws-<workspaceId>` as the base session. If that cannot be completed in the
same slice, make shared ambient unavailable and fall back to isolated per-tile
sessions rather than knowingly preserving mirroring behind a setting.

Add an explicit check for whichever rule is chosen.

### 5. Preserve lifecycle ownership

On deliberate tile deletion:

1. kill the tile's owned project/workspace window;
2. kill `array-view-<tileId>`;
3. leave the shared base session and all sibling windows/views alive.

On app/window teardown or project release, detach only. On a failure after a
new window or view was created but before persistence completes, compensate by
removing only the newly created resources. Never kill the shared base session
as generic rollback.

The existing view-session close code becomes meaningful after production starts
creating the sessions; retain it but replace fake-only success assumptions with
real absence/error semantics.

### 6. Keep tmux control on the correct host

The current targeted path computes `RemoteReach` but then performs grouped
project/workspace control through a local `ProcessTmuxControl`. A remote project
must create, query, select, attach, restart, and clean up its view session on the
same remote host/socket that owns the base session.

Before declaring the fix complete:

- trace localhost, SSH-forward, and Tailscale paths through one host-aware
  control abstraction;
- ensure launch argv and control operations cannot accidentally mix a remote
  base session with local cleanup or selection;
- add argv/control tests for remote reach even if live remote dogfood remains a
  supervised gate.

Do not broaden this repair into the unfinished tunnel transport.

### 7. Replace the disconnected I2 witness

Keep the real-tmux proof, but make it execute the exact profile generated by the
production builder. It must:

1. create one base session with two windows;
2. obtain two production-generated tile view profiles;
3. execute those exact argv arrays;
4. query each `array-view-*` session's `#{window_id}`;
5. assert the IDs are distinct;
6. exercise a deliberate shared-view case as the negative/control exception;
7. kill one view and prove the other view and base session survive.

Add or promote an app self-check such as `--terminal-tmux-no-mirror-check` that
drives the real `TileSpawner` dispatch for fresh spawn and restart. Register it
in `scripts/run-matrix.sh`, and confirm the final matrix summary reports that
the leg actually ran. A tmux-absent skip cannot be the only accepted proof on
the macOS release path.

## Verification sequence

1. Capture RED from the corrected production persistence/no-mirror assertion.
2. Add and pass pure Core argv tests for view naming, literal separator,
   project/base target, selected pane, and omission of the inner command.
3. Pass the TileSpawner check for two fresh project shells.
4. Pass live-target restart and dead-target replacement cases.
5. Pass close/rollback checks proving sibling survival and no base-session kill.
6. Pass the shared-ambient decision's check.
7. Pass local and remote-reach construction/control checks.
8. Run the repaired real-tmux I2 check using production-generated argv.
9. Run `--terminal-tmux-live-integration-check` with surface checks enabled.
10. Run the full matrix and judge it by its final leg summary, separating only
    the documented KNOWN-RED legs.
11. Rebuild `~/Desktop/Array Dev.app` only through `scripts/dev-app.sh`, pointed
    at `~/array-scratch`, and perform the visual dogfood:
    - open two project shell tiles;
    - print distinguishable markers in each;
    - type and change directories independently;
    - alternate focus repeatedly;
    - restart the app and confirm both reattach to their own shells;
    - close one and confirm the other continues uninterrupted;
    - inspect `tmux ls` for one base session and two, then one, grouped view
      sessions.

## Scope and fallback

The proper repair completes the existing project=session, tile=window design.
It does not redesign terminal rendering, replace tmux, add tmux control mode, or
change project persistence.

If the grouped-view repair cannot be made safe quickly, the recovery fallback is
to restore the pre-`947847e` per-tile session topology. That is known to isolate
tiles, but it gives up shared project-session observability and should be treated
as a deliberate rollback—not as the final architecture.

## Done when

- Two project shell tiles never mirror during spawn, focus changes, or typing.
- Fresh launch and app restart both bind each tile through its own stable view
  session.
- Each tile retains a distinct persistent window/pane target.
- Closing or failing one tile cannot kill or redirect a sibling.
- Shared ambient mode is either independently isolated or unavailable.
- Remote project operations address the remote tmux owner consistently.
- The production TileSpawner witness, production-generated real-tmux I2 check,
  live surface check, and full matrix all report the behavior.
- The Array Dev dogfood passes after relaunch, not only within one process run.

## Implemented on `array/tmux-shell-isolation`

Production now builds every shared project/workspace terminal launch through
`TmuxSession.groupedViewProfile`. Its exact local argv is:

```text
tmux new-session -t <array-proj-* or array-ws-*> -s array-view-<tileId> -A ; select-window -t <paneTarget>
```

The builder preserves the source profile's cwd/title, passes `";"` as one
literal argv token, and never repeats the shell/agent command already started
inside the owned window. `TileSpawner` uses it for fresh creation, live-target
restart, dead-target replacement, and opted-in shared ambient terminals. The
non-shared ambient path remains the isolated `array-<tileId>` fallback.

Rollback now records whether the failed attempt created a window and whether
the stable view already existed. It kills only a newly created window and a
newly created view, never a reused window/view or the shared base session.
Deliberate deletion remains ordered window then view; app/project release
remains detach-only.

`ProcessTmuxControl` is reach-aware. Local operations execute local tmux;
SSH-forward and Tailscale operations use the same hardened SSH owner and token
quoting as the Ghostty launch. Observer, reaper, lazy recovery, and deliberate
tile cleanup now construct control/query paths with the owning project's
`RemoteReach`. Tunnel returns an explicit unsupported error rather than falling
through to local control.

The Core I2 check now obtains and executes production-generated grouped-view
profiles rather than assembling grouped/select commands separately. The new
app check `--terminal-tmux-no-mirror-check` drives production `TileSpawner`
fresh, live-restart, and dead-replacement paths and is registered literally in
`scripts/run-matrix.sh`; the committed matrix inventory was regenerated.

## Evidence captured

Corrected production witness RED, after rebuilding the app and before changing
production behavior:

```text
FAIL: ambient descriptor should attach through its stable grouped view, got ["attach-session", "-t", "%1"]
```

GREEN app witnesses after implementation:

```text
ContinuumRevivedTerminalTmuxPersistenceChecks passed
ContinuumRevivedTerminalTmuxNoMirrorChecks passed
ContinuumRevivedTerminalTmuxDeleteLifecycleChecks passed
ContinuumRevivedTerminalAmbientWorkspaceChecks passed
```

The persistence/no-mirror artifacts prove distinct fresh pane targets and view
names, stable view identity across live restart, the same stable view repinned
to a replacement pane after death, shared-ambient isolation, and preservation
of the non-shared ambient fallback. The delete lifecycle check proves window
then view ordering, failure-tolerant cleanup, and no shared base-session kill.

The app and `ContinuumRevivedCoreChecks` products rebuild successfully. Pure
Core coverage includes the literal separator, cwd/title preservation, omission
of the inner command, local/SSH/Tailscale invocation construction, noninteractive
remote control construction, and explicit tunnel refusal.

### Remaining supervised verification

No real tmux check was allowed to contact the default socket: doing so can
crash or disrupt the live Array app. The sandbox also denied creation of a
disposable socket under a unique `TMUX_TMPDIR` (`Operation not permitted`).
Consequently production-generated real-tmux I2 execution, the Ghostty live
integration check, full matrix final summary, and Array Dev visual dogfood are
unverified in this checkout. `AGENTS.md` now permanently requires automated
tmux checks to unset inherited `TMUX`/`TMUX_PANE`, use a unique disposable
`TMUX_TMPDIR`, verify `#{socket_path}` lies inside it, and fail closed otherwise.
