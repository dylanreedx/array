# tmux Integration For Persistent Terminal Sessions

**Status:** Proposed
**Date:** 2026-05-09
**Scope:** Design only. No production implementation is included in this task.

## Problem Statement

Today every terminal tile spawns a fresh PTY. Closing the app or quitting the canvas window kills all in-flight processes. A long-running Claude Code or Codex session, a build, or a `dev` server all die when the user quits — even though the user almost always wants to come back to the same agent state.

Phase 4 explicitly listed "tmux attach profile" in `docs/04-terminal-ghostty-plan.md:293` as future work. The goal is simple: each terminal tile attaches to a deterministically named tmux session. App relaunch reattaches. Closing the canvas without killing the agent. tmux becomes the persistence layer; Ghostty remains the renderer.

This spec also has to coexist with:

- The existing `TerminalSessionDescriptor` persistence model (one descriptor per tile, `lastExit` set on close).
- The existing close-path ordering invariants in ADR-0010, 0014, 0015.
- The Core purity rule (`ContinuumRevivedCore` does not import AppKit, Ghostty, etc.).
- Users who do not have tmux installed.

## Decision

Add an opt-in `sessionStrategy` field to `LaunchProfileSpec` that selects between the current ephemeral PTY behavior and a new tmux-backed persistent strategy. tmux is detected via the existing `ToolDetector` pattern. When a tmux-backed profile resolves, the resulting `LaunchProfile` runs `tmux new-session -A -s <name>` so a single command both attaches to an existing session and creates one if missing — no separate `has-session` round trip required from the app process. If tmux is not installed, a tmux-backed profile gracefully falls back to its base command via the same `LaunchProfileResolution.missing(executableName: "tmux")` path the rest of the resolver already uses, with a one-time UI nudge.

`sessionStrategy` is added to `LaunchProfileSpec` (not `Kind`) because tmux-backedness is orthogonal to whether the profile is `.shell`, `.tool`, or `.custom`. A user can mark a Claude profile, a shell profile, or a custom profile tmux-persistent without combinatorial explosion in the `Kind` enum.

Session names are deterministic and survive relaunch by being derived from persisted UUIDs:

```text
continuum-<projectId8>-<tileId8>
```

…where `projectId8` and `tileId8` are the first 8 hex characters of the project and tile UUIDs. The `continuum-` prefix lets users — and the app — safely list their continuum sessions without colliding with the user's own tmux sessions. tmux session names tolerate hyphens and have practical length limits in the kilobytes, so this naming scheme is safe.

The `TerminalSessionDescriptor` keeps one entry per tile as before. tmux-backed descriptors gain an optional `tmuxSessionName: String?` so we can audit which tile maps to which tmux session and so a future "kill the tmux session for this tile" command has something to target. Restart logic does not change shape: `tmux new-session -A -s <name>` is idempotent, so the boot loop's existing "spawn runtime for this terminal tile" path can be reused without special-casing whether the session was alive at boot.

The app does not own tmux's lifecycle. tmux's own daemon keeps sessions alive across app quits. The app's `windowWillClose` handler stamps `lastExit` on every descriptor as it does today (the PTY closing represents the tile being closed, not the agent dying), but does not run `tmux kill-session`. The user can reattach by launching the app and seeing the same tile reattach to the same tmux session.

## What's In

### Core additions

- Extend `LaunchProfileSpec` with:

  ```swift
  public enum SessionStrategy: Equatable, Sendable {
      case ephemeral
      case tmuxPersistent
  }

  public struct LaunchProfileSpec {
      // existing fields…
      public let sessionStrategy: SessionStrategy
  }
  ```

  Default is `.ephemeral` for every existing built-in spec so behavior is unchanged unless a profile explicitly opts in.

- Extend `LaunchProfileRegistry.resolve` to wrap the resolved `LaunchProfile.command` and `arguments` in a tmux invocation when `sessionStrategy == .tmuxPersistent` and tmux is locatable on `PATH`:

  ```text
  command: <tmux>
  arguments: ["new-session", "-A", "-s", <name>, "--", <originalCommand>, <originalArgs>...]
  ```

  When tmux is not locatable, return `LaunchProfileResolution.missing(executableName: "tmux")`. The boot loop already handles `.missing` by installing a `TerminalRestartTileNSView` and surfacing the missing executable name; we will add a one-line "Install tmux to enable persistent sessions" hint in that placeholder when the missing exe is `"tmux"` specifically.

- Extend `LaunchProfileRegistry.resolve` to accept a `tmuxSessionNameProvider: (LaunchProfileSpec) -> String?` closure (Sendable). Core does not know about projects or tiles, so the closure is injected by the app. When `sessionStrategy == .tmuxPersistent`, the resolver calls the provider; if the provider returns nil, the resolver returns `.missing(executableName: "tmux-session-name")` to make the misconfiguration loud rather than silent.

- Extend `TerminalSessionDescriptor` with an optional `tmuxSessionName: String?` (default nil). Bump `currentSchemaVersion` to 2; provide a decode-time default of nil for v1 descriptors so existing project state migrates without a write.

- Add `TmuxSessionNamer` in Core, a Sendable helper that returns a deterministic name for a `(projectId, tileId)` pair: `"continuum-\(projectIdShort)-\(tileIdShort)"` where `*Short` is the first 8 hex characters of the UUID's lowercase string. Pure data; trivially testable.

### App-side wiring

- `AppDelegate` (or `TileSpawner`) injects a `TmuxSessionNamer` instance and the active `Project` into the resolve call. Boot-loop tile spawn paths read `sessionStrategy` from the resolved `LaunchProfileSpec` and pass `tmuxSessionName` into the resulting `TerminalSessionDescriptor`.
- The Ghostty surface launch path is unchanged — Ghostty receives a `command` and `arguments` and does not care whether those are `claude` directly or `tmux new-session -A -s … -- claude`.
- A new "Install tmux" string in `TerminalRestartTileNSView` is shown only when the placeholder was installed because of a missing tmux executable. Other missing-exe placeholders keep their existing copy.
- Cmd-K palette gains a per-spec checkbox (or a profile-editor field, post-MVP) to toggle `sessionStrategy` for custom profiles. Built-in profiles keep their default strategy and are not user-editable in the MVP.

### Default strategy per built-in spec

- `shell` → `.ephemeral`. Most shells are short-lived noise; persisting them would clutter `tmux ls`.
- `claude` → `.tmuxPersistent`. The primary motivation for the feature.
- `codex` → `.tmuxPersistent`. Same motivation.
- `nvim` → `.ephemeral`. Editor processes are short-lived per session and Neovim has its own session/state model.
- `custom` → `.ephemeral` by default; user-editable.

### Session lifecycle

- **App launch.** Boot loop walks the canvas and re-runs `LaunchProfileRegistry.resolve` for each terminal tile. A tmux-backed tile resolves to `tmux new-session -A -s continuum-<…> -- <baseCommand>`, which attaches if the session exists and creates it (running the base command) if not. The resulting Ghostty surface shows the same scrollback and same agent state as before.
- **Tile close.** The user's "close tile" intent should not kill the agent. Closing a tile detaches the Ghostty surface from tmux but leaves the tmux session alive. We achieve this by sending a graceful `kill -HUP` to the local PTY (or letting Ghostty close its surface), which detaches tmux without `kill-session`. The descriptor's `lastExit` records the tile-close event, not an agent exit.
- **Tile restart from placeholder.** Identical to first launch — `tmux new-session -A -s …` reattaches.
- **App quit.** ADR-0015 close-path ordering is unchanged. Each Ghostty runtime terminates its surface, which detaches tmux. tmux daemon keeps the session alive on the system for next launch. No tmux-specific code in `windowWillClose`.
- **Project deletion.** When the user deletes a project, the app must run `tmux kill-session -t continuum-<projectId8>-*` for every tile in the project's canvas. This is the only place we proactively destroy tmux state. The kill is best-effort; failures are logged and do not block deletion.
- **Orphan reaping.** A future "tmux housekeeping" command (post-MVP) lists `tmux list-sessions -F '#S'`, filters to `continuum-` prefixed names, and offers to reap any whose `(projectId, tileId)` no longer corresponds to a live tile or a known archived project.

### tmux not installed

`ToolDetector.locate("tmux", in: PATH)` returns nil. The resolver returns `.missing(executableName: "tmux")`. The boot loop installs `TerminalRestartTileNSView` with the new "Install tmux to enable persistent sessions" hint. The user can either install tmux (via Homebrew) and click Restart, or edit the profile to drop tmux-persistence and click Restart. No silent fallback to ephemeral — silent fallback would defeat the persistence guarantee that motivated the profile.

The custom-profile path is the escape hatch: a user who explicitly wants Claude without tmux can clone the `claude` profile into a custom profile with `sessionStrategy = .ephemeral`.

### tmux available but tile already exists in tmux

`tmux new-session -A -s <name>` (note the `-A` flag) attaches to an existing session of that name if one exists. There is no race between "is the session alive?" and "spawn it" because tmux serializes the operation inside its own daemon. We never need to call `tmux has-session` from the app; the single command is the contract.

### tmux server not running yet

`tmux new-session` starts the tmux server if it is not running. No special setup. The first launch after install is the same as every subsequent launch.

### Mid-session exit handling

When a tmux-backed agent exits mid-session (e.g., `claude` returns 0 inside the tmux session), the tmux session itself stays alive (tmux's default for `new-session -d` and for `-A`-style attaches). The Ghostty surface sees a shell-like idle state, and the user can re-run the agent from inside the tile. The existing mid-exit handler in the app sees the surface still alive and does not install a `TerminalRestartTileNSView`. This is a behavior change from today, where mid-exit installs the placeholder; users get the trade-off of "the tile lives across agent restarts" in exchange for "no big restart button mid-session." We accept the trade-off because that's the user-visible reason to opt into tmux.

If the user wants the old placeholder behavior for a tmux profile, they can toggle the profile back to ephemeral.

## What's Deferred

- `.tmux.conf` import or app-managed tmux configuration.
- tmux pane splitting inside a single tile (tiles already do spatial splits; in-pane splits would conflict).
- Cross-machine session resume (would require remote tmux + ssh, out of scope).
- Session search ("which tile is running my long build?") via `tmux list-sessions`.
- Per-session resource quotas, idle reaping, or memory-pressure cleanup.
- `tmux kill-session` UI affordance per tile (post-MVP "kill agent" command).
- Renaming a tmux session when the tile gets renamed.
- `screen`, `zellij`, `dtach`, or any tmux alternative.
- mosh-like reconnect semantics on network change.
- iTerm2-style "show all my tmux sessions" cross-app inventory.

## Verification

- **Build gate:** `swift build` completes cleanly.
- **Core checks gate:** `swift run ContinuumRevivedCoreChecks` covers `LaunchProfileSpec` round trip with `sessionStrategy`, `TerminalSessionDescriptor` v1→v2 migration (decode v1 → encode v2 with `tmuxSessionName == nil`), and `TmuxSessionNamer` deterministic output.
- **Resolver checks gate:** new fixture cases — tmux-backed shell with tmux installed produces `command == <resolved tmux path>` and arguments leading with `["new-session", "-A", "-s", "continuum-…"]`; tmux-backed shell without tmux produces `.missing(executableName: "tmux")`; tmux-backed shell without a session-name provider produces `.missing(executableName: "tmux-session-name")`.
- **Smoke gate:** `CONTINUUM_SMOKE_TEST=1 .build/debug/continuum-revived` continues to exit 0 on a host without tmux (current macOS default). On a host with tmux, an additional gate spawns a tmux-backed terminal tile, verifies the descriptor records the tmux session name, restarts the smoke harness, and asserts the same tile reattaches with scrollback continuity (a sentinel string written before quit must be visible after relaunch). The smoke harness gates on the presence of tmux in the test environment; CI enables a tmux-installed lane.
- **Manual visual gate:** the user verifies — install tmux via Homebrew, enable the tmux strategy on the Claude profile, spawn a Claude tile, run a multi-turn session, quit the app, relaunch, confirm the same Claude session continues with full scrollback and agent state. Then quit the canvas window without quitting the app, confirm `tmux list-sessions` shows the `continuum-…` session still alive.
- **Crash gate:** `~/Library/Logs/DiagnosticReports/continuum-revived*` shows no new entries after three back-to-back smoke runs and a relaunch sequence on a tmux-installed host.
- **No-tmux gate:** on a host without tmux installed, the smoke harness still exits 0, the placeholder for a tmux-backed missing profile shows the "Install tmux" hint, and a non-tmux profile spawns ephemerally as before.

## Phase Exit Criteria

The tmux integration is ready to ship when all of the following are concurrently true:

1. `sessionStrategy` is part of `LaunchProfileSpec` with `.ephemeral` and `.tmuxPersistent` cases.
2. `TerminalSessionDescriptor` carries an optional `tmuxSessionName` and migrates v1 → v2 with default nil.
3. The Claude and Codex built-in profiles default to `.tmuxPersistent`; shell, nvim, and custom default to `.ephemeral`.
4. `LaunchProfileRegistry.resolve` wraps tmux-backed profiles in `tmux new-session -A -s … --` and short-circuits with `.missing(executableName: "tmux")` when tmux is absent.
5. `TmuxSessionNamer` produces deterministic, collision-free names for `(projectId, tileId)` pairs.
6. App relaunch reattaches every tmux-backed tile to its existing tmux session with full scrollback and agent state.
7. Quitting the canvas window without quitting the app leaves tmux sessions alive on the host.
8. ADR-0010, 0014, 0015 close-path ordering is unchanged; tmux integration adds no new shutdown step in `windowWillClose`.
9. `swift build`, Core checks, resolver checks, smoke gate (no-tmux + with-tmux lanes) all pass; no new diagnostic reports.

## Consequences

Positive:

- Long-running agents survive app and canvas restarts. The headline feature.
- Persistence is simple and robust: tmux's own daemon owns the survival problem.
- No new SPM dependencies, no libgit2-style packaging cost — `tmux` is shelled out to.
- The integration uses an existing well-understood tool; users who already use tmux are productive immediately.

Tradeoffs:

- Users have to install tmux to get the benefit. This is acceptable for a developer-targeted tool.
- Mid-session agent exits no longer trigger the restart-button placeholder for tmux-backed tiles. Users who want that UX must opt their profile back to ephemeral.
- Project deletion has to clean up tmux sessions, adding a side-effect to a previously file-only operation.
- Stale tmux sessions accumulate if a project is deleted while the app is not running (no chance to run `kill-session`). Future housekeeping can address this.
- Two persistence layers (tmux + descriptors). They are intentionally redundant — descriptors record intent, tmux records state. The boot loop reconciles them by re-resolving and reattaching.

Rejected alternatives:

- **Wrap tmux in a Swift library / dynamic linking.** Would couple us to libtmux's ABI and packaging. Shelling out to the user-installed tmux is simpler, more robust, and avoids licensing complexity.
- **Use `screen` or `dtach` instead.** tmux is dramatically more common on macOS dev machines and has better resize handling for high-DPI Ghostty surfaces.
- **Custom in-process PTY persistence (don't kill the child on tile close).** Would require app-managed daemonization, signal-handling, and cross-launch IPC. tmux already solves all of this.
- **Always-on tmux, no opt-out.** Forces tmux as a hard dependency on every user. Opt-in respects the existing ephemeral default.
- **Per-tile `sessionStrategy` instead of per-spec.** Allowed in a follow-up but adds UI surface (a per-tile toggle). The MVP keeps the strategy attached to the profile so the user picks once.
- **Use `tmux kill-session` on `windowWillClose`.** Defeats the persistence guarantee. The whole point is that the agent survives a close.
- **Let `tmuxSessionName` derive from `descriptor.id` rather than `(projectId, tileId)`.** Descriptor IDs are not stable across "delete and re-create the descriptor" flows; tile IDs are. Stable naming is the contract.
