# tmux-Backed Shell Persistence & Auto-Reattach

Status: design + implementation plan, 2026-06-17. Phase 1 of the "durable,
observable home" arc. Sibling follow-ups (separate docs): the observability
sidebar (#2) and browser deep-state restoration (deferred).

## Why

Continuum should be the durable home for your projects: close it, reopen it, and
everything is where you left it — layout, tiles, browser URLs, **and your live
shells/agents still running** — with zero manual reattach. You stop paying the
"rebuild my flow state" tax on every restart.

Today that promise breaks for shells. A terminal tile's shell is a child process
of the app; on quit/restart it dies. So if you run a coding agent by typing
`claude` into a shell tile and the app restarts (a frequent event while we build
Continuum *in* Continuum), **the agent is killed**. The tile re-spawns a fresh
shell in the same cwd, but the running process and your typed commands are gone.

The fix is to stop making the shell a child of the app. tmux is a separate daemon
that already does exactly this: it owns the process, survives the app, and lets a
client (re)attach. We make each terminal tile a tmux client over a per-tile
session. tmux does **persistence**; Continuum's canvas keeps doing
**observability**. Each tool does the job it is good at.

## Current state (grounded, 2026-06-17)

- **Shell = app child, dies on quit.** `GhosttyTerminalView.createSurface`
  (`Sources/ContinuumRevived/TerminalEngine/GhosttyTerminalView.swift:423`) spawns
  the command via `ghostty_surface_new`; `closeSurface` (`:484`) /
  `ghostty?.shutdown()` (`ContinuumApp.swift:3655`) free it on teardown/quit. No
  detach, no daemon. (`os.setsid()` exists only for harness-role agents in
  `HarnessRoleRunBuilder` — a separate path, not raw shell tiles.)
- **Command model is a shell-quoted string.** `commandLine(for:)`
  (`GhosttyTerminalView.swift:412`) joins `[command] + arguments` (shell-quoted)
  into `config.command`. So we can wrap in tmux purely by changing the
  `LaunchProfile` — **no libghostty changes**.
- **`LaunchProfile`** (`Sources/ContinuumRevivedCore/LaunchProfile.swift:3`):
  `command`, `arguments`, `cwd`, `title`.
- **Spawn cwd = project root.** `TileSpawner.spawnTerminal` (`:101`) →
  `terminalProjectRoot()` (`:203`) → `project.rootPath`; resolved into a
  `LaunchProfile` by `LaunchProfileRegistry.resolve` (`:20`).
- **Restore restores cwd only.** `TileSpawner.restartTerminalTile` (`:278`) reads
  the persisted `TerminalSessionDescriptor` and rebuilds the profile with the
  saved cwd; spawns a **fresh** shell there. Process + typed state lost.
- **Scrollback saved, not replayed.** `flushTerminalSessionSnapshot` (`:360`)
  persists capped scrollback (`SessionResumeConfig`, 2000 lines default);
  `GhosttyTerminalRuntime.replayScrollback` (`:174`) is a deferred no-op.
- **tmux: absent.** Zero references anywhere in `Sources/`.

## Design

### Core mechanism

A terminal tile launches, instead of the bare shell/command:

```
tmux new-session -A -s continuum-<tileId> -c <cwd> [-- <inner command...>]
```

- `-A` — **attach if the session exists, create if not.** The session name is
  keyed to the tile's stable UUID, so on relaunch the tile re-runs the *identical*
  command and tmux **reattaches the live session** rather than creating a new one.
- `-c <cwd>` — initial directory on create (ignored on attach; tmux already holds
  the pane's cwd).
- Inner command — omitted for a plain shell tile (tmux spawns the user's default
  shell); for a profile that runs a specific command, it is passed and runs as the
  session's first window on create (ignored on attach).
- **Default tmux server** (no `-L`), so sessions are reachable from the user's
  normal CLI (`tmux attach -t continuum-<id>`) — aligns with "tmux as the
  backbone" and keeps the door open to CLI bridging. Clutter in `tmux ls` is
  accepted (UUID names: ugly but findable).

Injection point: the `LaunchProfile` built in `TileSpawner` (both the spawn and
restart paths). Nothing in the terminal renderer changes.

### Lifecycle — detach vs kill (the crux)

| Event | What happens | Result |
|---|---|---|
| **App quit / restart** | `ghostty_surface_free` tears down the ghostty *client*; the tmux daemon and session are independent | Session + agent **stay alive**; relaunch re-runs the same command → **reattach**. Live agent, real history, real cwd — automatically. |
| **User deletes/closes a tile** | We explicitly run `tmux kill-session -t continuum-<tileId>` | Session ends; no idle orphan sessions accumulate. (Locked decision: close = kill.) |
| **User types `exit`** | Shell exits → last window closes → session ends → `ghostty_surface_process_exited` → tile shows exited | Today's behavior; session cleaned up naturally. |
| **User detaches inside the pane (`C-b d`)** | tmux client exits 0 → tile shows exited, session lives | Power-user edge; next launch reattaches. Acceptable. |

The only *new* explicit action is **kill-session on deliberate tile deletion**.
Everything else falls out of tmux's client/daemon split.

### cwd & scrollback — mostly free

- **cwd:** tmux preserves each pane's directory across detach/reattach → you land
  exactly where you left off. New sessions start at project root (unchanged). The
  existing OSC-7 capture stays as the reboot-tier fallback.
- **scrollback:** on reattach tmux replays the **real live history**, so the
  long-deferred on-screen replay gap is solved for the app-restart case for free.
  The disk snapshot remains only the reboot fallback.

### Detection, fallback, config (configurable-first)

- **`TmuxLocator.resolve()`** — find a tmux binary: explicit config path →
  `$PATH` → `/opt/homebrew/bin/tmux`, `/usr/local/bin/tmux`, `/usr/bin/tmux`.
- **Fallback:** if tmux is absent (or the toggle is off), build the bare command
  exactly as today — no persistence, no hard failure.
- **`TmuxPersistenceConfig`** (Core, mirrors `SessionResumeConfig` /
  `ResizeHUDConfig`):
  - `enabledKey = "continuum.terminal.tmux.enabled"`, default **true** (effective
    only when a binary resolves).
  - `pathKey = "continuum.terminal.tmux.path"`, default `""` (auto-resolve).
  - Surfaced in `SettingsSchema` (a new **Terminal** section): "Keep Shells Alive
    (tmux)" toggle + "tmux Path" text.

### Scope / non-goals

- **In:** regular shell/terminal tiles.
- **Out (this phase):**
  - Harness-spawned agent tiles — already survive via `setsid()`; left on that
    path (unify later if worthwhile).
  - **Machine reboot** — no process survives a reboot; the later tier restores
    layout + cwd + command (tmux-resurrect-style), not live processes.
  - CLI-friendly / human session names (UUID for now; door left open).
  - Browser deep-state, the observability sidebar — separate docs.

## Decisions (locked with Dylan, 2026-06-17)

1. **Close a tile = kill its tmux session** (no idle-session accumulation).
2. **UUID-named sessions** on the **default tmux server** (CLI-attachable; naming
   polish deferred).
3. **tmux as persistence only** — Continuum's canvas remains the observability
   layer (control-mode "sessions = tiles" is *not* pursued; it rides a risky
   libghostty-feed spike and isn't needed for the goal).
4. Persistence is **on by default** when tmux is present; silent fallback when not.

## Implementation phases

Doctrine: each phase writes its named real-path check **first** (RED), implements
to GREEN, `swift build` clean + `scripts/run-matrix.sh --fast` green, commit
(plain `type(scope): summary`), then continue. New config is user-configurable
(persisted default + Settings entry).

### P1 — tmux command construction + detection (pure Core)
- New `Sources/ContinuumRevivedCore/TmuxSession.swift`:
  - `sessionName(tileId:) -> "continuum-\(uuid)"`.
  - `wrap(_ profile: LaunchProfile, tileId:, tmuxPath:) -> LaunchProfile` →
    `command = tmuxPath`, `arguments = ["new-session","-A","-s",name,"-c",cwd] (+ inner command/args)`.
  - `killSessionCommand(tileId:, tmuxPath:) -> (command, arguments)`.
- New `TmuxLocator.resolve(defaults:) -> String?` and `TmuxPersistenceConfig`.
- **RED check** (`ContinuumRevivedCoreChecks`): `wrap` produces the exact argv with
  a stable name; cwd flows to `-c`; inner command preserved; `killSessionCommand`
  shape; name is stable for a given tileId and unique across tileIds.

### P2 — wire into TileSpawner (spawn + restart)
- In `spawnTerminal` and `restartTerminalTile`, when enabled **and** a binary
  resolves, pass the resolved `LaunchProfile` through `TmuxSession.wrap` keyed to
  the tile's id; otherwise use the bare profile (today's path).
- **RED check** `--terminal-tmux-persistence-check` (app): the `LaunchProfile`
  built for a terminal tile is tmux-wrapped with the **same session name across
  spawn → restart** (proves reattach keying); toggle-off and tmux-absent both fall
  back to the bare command. (Inject a fake tmux path + isolated `UserDefaults`.)

### P3 — kill session on tile deletion
- Hook the user-initiated tile-removal path (verify exact symbol during impl —
  the tile delete/close handler in `TileSpawner`/runtime, distinct from app-quit
  teardown) to run `tmux kill-session -t continuum-<tileId>` for terminal tiles.
- **RED check**: deleting a terminal tile issues the kill-session command for its
  id; the app-quit/teardown path does **not** (detach-only, session survives).

### P4 — settings + dogfood
- Add the Terminal section toggle + path to `SettingsSchema`; matrix
  `--settings-panel-check` covers rendering.
- **Dogfood gate:** run an agent in a shell tile → restart the app → the tile
  reattaches with the **live agent**, real scrollback, and correct cwd, no manual
  step. Toggle off → behaves exactly as today.

### P5 (optional) — gated live integration test
- A check that, **only when a real tmux resolves**, creates a session, rebuilds
  the profile ("restart"), reattaches, and asserts the pane survived + cwd
  preserved. Skipped cleanly where tmux is absent so CI stays green.

## Verification summary

- Pure construction + naming: P1 Core check.
- Spawn/restart wiring + reattach keying + fallbacks: P2 app check.
- Kill-on-delete vs detach-on-quit: P3 app check.
- Settings render: existing `--settings-panel-check`.
- End-to-end survival: P4 dogfood (+ optional P5 gated integration).

## Risks

- **tmux not installed** → handled by silent fallback (no persistence).
- **Inner-command profiles** (a tile that runs a specific command, not a shell):
  the command runs on create, is ignored on reattach — desired, but confirm the
  registry's resolved command composes correctly under `wrap`.
- **Manual in-pane detach** shows the tile as "exited" while the session lives;
  acceptable, documented above.
- **Default-server clutter**: Continuum sessions appear in the user's `tmux ls`.
  Accepted; revisit with a dedicated socket if it becomes noisy.
- **Session leak** if a delete path is missed in P3 — the check guards the primary
  path; a future `continuum-*` sweep on launch can backstop orphans.

## Out of scope / future

- #2 Observability sidebar (projects / workspaces / zones tree + agent status;
  `SidebarTree` exists in Core but is unrendered).
- Machine-reboot tier: restore layout + cwd + command (tmux-resurrect-style).
- CLI bridging: human-readable / sessionizer-aligned session names.
- Browser deep-state restoration.
