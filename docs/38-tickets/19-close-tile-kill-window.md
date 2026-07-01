# Close tile = kill-window; session reaps at zero windows

Rests on **D16** ("Close tile = `kill-window`; session dies at 0 windows; project release = DETACH, never kill") in `docs/38-locked-decisions.md`. This ticket implements D16 verbatim for the close-tile side: closing one tile kills exactly that tile's window, the session self-terminates at zero windows, and project release stays detach-only (handled by the project-release detach work, not here).

## What this delivers

When a user closes a terminal tile, exactly its tmux window is killed — no more, no less. The project session that hosted it stays alive unless that was its last window, in which case tmux ends the session naturally at zero windows. This is the correct lifecycle for the project=session world: a deliberate, scoped user action removes exactly one window from the shared session, and the session lives as long as any tile in the project is alive.

From the system's perspective, closing a tile stops being a session-scoped operation and becomes a window-scoped one. The invariant I3 — no session leak, live sessions ⊆ live projects/zones — is maintained because the last tile's close lets the session self-terminate, not because the app has to issue a kill-session.

## How it fits

This ticket sits immediately after the capture-tmuxWindowTarget-at-spawn work. That work adds the durable `%pane_id` field to `TerminalSessionDescriptor` and populates it synchronously at spawn time; this ticket reads that field to identify which window to kill. Without a captured and persisted target, close cannot be window-scoped — there is no reliable, session-independent handle to give `kill-window`. That dependency is strict.

It also aligns with the project-session naming work and the new-window spawn work, both of which establish that N tiles share one `continuum-proj-<projectId>` session and that each tile's identity is its `tmuxWindowTarget`, not a session name derived from its tile id.

This ticket unblocks the project-release detach work: its job is to ensure releasing a project runtime does not kill the session, which only makes sense once the close-tile path itself correctly uses kill-window rather than kill-session. It also unblocks the idle reaper work and the per-workspace ambient session work, both of which reason about session lifetime at the window level.

## The approach

The close path today calls `TmuxSession.killSessionCommand(tileId:tmuxPath:)` which emits `tmux kill-session -t continuum-<tileId>`. Under project=session, that session name no longer exists — the tile lives as a window in `continuum-proj-<projectId>`. The fix is surgical: replace the kill-session call with a kill-window call targeting `descriptor.tmuxWindowTarget`.

The call becomes `tmux kill-window -t <tmuxWindowTarget>`, where `tmuxWindowTarget` is the `%pane_id` string captured and persisted by the capture-tmuxWindowTarget-at-spawn work. Because pane ids are stable for the lifetime of the pane and survive client detach/reattach, this is a reliable handle even after the ghostty surface has been torn down.

When the killed window is the last one in the project session, tmux ends the session on its own — no extra kill-session call is needed or issued. This is the designed behavior: session death is a natural consequence of zero windows, not a separate app-orchestrated operation.

If `tmuxWindowTarget` is nil on the descriptor (a pre-upgrade tile that has not yet been given a target by the spawn changes), the close path falls back to `TmuxSession.killSessionCommand(tileId:tmuxPath:)` — the old kill-session behavior — so that legacy tiles still clean up correctly. This fallback is not a regression; it is the honest behavior for a tile that predates the new topology and carries no window target.

A new `TmuxSession.killWindowCommand(target:tmuxPath:)` static function is added alongside the existing `killSessionCommand`. The dispatch logic lives in `killTmuxSessionForDeletedTerminalTile` in `ContinuumApp.swift`, which reads the descriptor and routes to the correct command. The function is renamed to `killTmuxWindowForDeletedTerminalTile` to make the new semantics clear at the call site.

The self-check at `ContinuumApp.swift:11082–11083` currently asserts that a terminal tile close issues exactly one `kill-session` command. This check must be updated to assert exactly one `kill-window` command targeting the correct pane id. The assertion at `ContinuumApp.swift:11105` that app teardown issues no kill-session is unchanged and continues to be correct (teardown still only detaches).

## Where it lives

**`Sources/ContinuumRevivedCore/TmuxSession.swift`**

- `TmuxSession.killSessionCommand(tileId:tmuxPath:)` at line 27 is the current kill-session builder. A new parallel function `killWindowCommand(target:tmuxPath:)` is added here, emitting `["kill-window", "-t", target]`. The existing `killSessionCommand` is kept for the nil-target fallback.

**`Sources/ContinuumRevived/App/TileSpawner.swift`**

- No direct changes here for the kill path itself, but the descriptor read in the close path relies on `projectStore.loadSession(id: runtime.id)` or `projectStore.listSessions().first(where: { $0.tileId == tileId })`, both of which are already present in `TileSpawner`.

**`Sources/ContinuumRevived/App/ContinuumApp.swift`**

- `killTmuxSessionForDeletedTerminalTile(tileId:)` at line 3108 is the only production site that issues a tmux kill during tile close. This is the function to rewrite. It reads the runtime's descriptor to find `tmuxWindowTarget`, then dispatches to `killWindowCommand` or falls back to `killSessionCommand`.
- `deleteTile(id:)` at line 3010 calls `killTmuxSessionForDeletedTerminalTile` at line 3040. The call site itself does not change — only the callee's implementation and name.
- The self-check at lines 11082–11083 (currently asserting `kill-session`) must be updated to assert `kill-window` with the expected target. The teardown-detach assertion at line 11105 is unchanged.

**`Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift`**

- The `tmuxWindowTarget: String?` field added by the capture-tmuxWindowTarget-at-spawn work is read here. No structural changes to the descriptor in this ticket.

## Implementation breadcrumbs

```swift
// In TmuxSession.swift — new function beside killSessionCommand
public static func killWindowCommand(target: String, tmuxPath: String) -> (command: String, arguments: [String]) {
    (command: tmuxPath, arguments: ["kill-window", "-t", target])
}

// In ContinuumApp.swift — rewritten close helper
private func killTmuxWindowForDeletedTerminalTile(tileId: UUID) {
    guard TmuxPersistenceConfig.enabled(defaults: tmuxDefaults),
          let tmuxPath = tmuxPathResolver(tmuxDefaults) else { return }

    // Read the descriptor to discover the window target.
    // Use the runtime id if available; fall back to tileId scan.
    let descriptor: TerminalSessionDescriptor? = runtimes
        .first(where: { $0.tileId == tileId })
        .flatMap { runtime in try? projectStore?.loadSession(id: runtime.id) }
        ?? (try? projectStore?.listSessions().first(where: { $0.tileId == tileId }))

    let killCmd: (command: String, arguments: [String])
    if let target = descriptor?.tmuxWindowTarget {
        // New path: window-scoped kill using the captured pane id.
        killCmd = TmuxSession.killWindowCommand(target: target, tmuxPath: tmuxPath)
    } else {
        // Fallback for pre-upgrade tiles with no window target.
        killCmd = TmuxSession.killSessionCommand(tileId: tileId, tmuxPath: tmuxPath)
    }

    do {
        try tmuxProcessRunner(killCmd.command, killCmd.arguments)
    } catch {
        fputs("tmux kill-window failed for tile=\(tileId.uuidString): \(error)\n", stderr)
    }
}
```

The call site in `deleteTile` changes only the function name:

```swift
// was: killTmuxSessionForDeletedTerminalTile(tileId: id)
killTmuxWindowForDeletedTerminalTile(tileId: id)
```

The self-check update looks like:

The capture records each command as a dictionary — the assertions read `commands.first?["command"] as? String` and `commands.first?["arguments"] as? [String]` separately, not a whole-tuple `==`:

```swift
// was:
let expectedKill = TmuxSession.killSessionCommand(tileId: terminalTileId, tmuxPath: fakeTmuxPath)
try expect(deleteCapture.commands.count == 1, "terminal tile user close should issue exactly one tmux kill-session command, got \(deleteCapture.commands)")
try expect(deleteCapture.commands.first?["command"] as? String == expectedKill.command, "unexpected tmux kill command: \(deleteCapture.commands)")
try expect(deleteCapture.commands.first?["arguments"] as? [String] == expectedKill.arguments, "unexpected tmux kill arguments: \(deleteCapture.commands)")

// becomes:
let expectedKill = TmuxSession.killWindowCommand(target: fakeWindowTarget, tmuxPath: fakeTmuxPath)
try expect(deleteCapture.commands.count == 1, "terminal tile close should issue exactly one tmux kill-window command, got \(deleteCapture.commands)")
try expect(deleteCapture.commands.first?["command"] as? String == expectedKill.command, "kill command must be tmux: \(deleteCapture.commands)")
try expect(deleteCapture.commands.first?["arguments"] as? [String] == expectedKill.arguments, "kill-window must target the captured pane id: \(deleteCapture.commands)")
```

The nil-target fallback path needs its own self-check assertion: a legacy tile with no `tmuxWindowTarget` issues `kill-session`, not `kill-window`.

## How we test it

### Logic (pure Core checks)

Add tests in `ContinuumRevivedCoreChecks` (or the equivalent pure-Swift test target) that exercise `TmuxSession.killWindowCommand` directly:

- `killWindowCommand(target: "%7", tmuxPath: "/usr/bin/tmux")` returns `(command: "/usr/bin/tmux", arguments: ["kill-window", "-t", "%7"])` — verifies the exact argv shape.
- Contrast with `killSessionCommand` to prove they emit different subcommands; a test that wires up a fake `TmuxControl` confirming these are not interchangeable.
- A test that simulates a nil `tmuxWindowTarget` on the descriptor and asserts the fallback path emits `kill-session` rather than `kill-window`.

These are all pure functions operating on value types — no tmux daemon, no filesystem.

### Backend (real-path / integration)

The existing lifecycle self-check at `ContinuumApp.swift:11082` is a real-path check that drives the production `deleteTile` path through a fake `tmuxProcessRunner` and captures the emitted commands. This check must be updated (not bypassed) to assert the new behavior:

1. Spawn a tile whose descriptor carries a known fake `tmuxWindowTarget` (e.g. `"%42"`).
2. Call `deleteTile(id:)` through the production path.
3. Assert exactly one command was captured, and that it is `kill-window -t %42` — not `kill-session`.
4. Assert the project session name never appears in the captured commands (the session is not killed directly by the app).

A second self-check path validates the fallback: spawn a tile whose descriptor has `tmuxWindowTarget == nil`, close it, and assert exactly one command captured: `kill-session -t continuum-<tileId>`.

The existing teardown assertion at line 11105 — app teardown must issue zero kill commands — is re-run unchanged as a regression guard. It remains true: teardown is detach-only.

Separately, a real-tmux integration check (gated on the `TmuxControl` real impl, not the fake) verifies the end-to-end window count: spawn three tiles into one project session → assert three windows; close one tile → assert two windows remain; close the remaining two → assert the session no longer exists. This check produces a `SessionTopologySnapshot` before and after each close and records the window counts in the manifest as measured values, not just `{passed: true}`.

### UX (visual gate + dogfood snippet)

The visual gate is the session topology snapshot: after closing one tile in a multi-tile project, the reconciliation oracle (`SessionTopologySnapshot`) must show N-1 windows in the project session and no orphan sessions. This is a non-degenerate gate — it reads actual tmux state, not a boolean.

**Dogfood snippet.** Open the app. Open a project that has no existing tiles. Use the tile spawn gesture (canvas double-click or the new-tile keybind) to create three terminal tiles in the same project — each should appear on the canvas as a separate tile. In a terminal outside the app, run `tmux list-windows -t continuum-proj-<your-project-id>` and confirm three windows are listed. Now close the middle tile using the tile delete keybind (default `q` when the tile is selected). Observe: the tile disappears from the canvas immediately. Back in your external terminal, run `tmux list-windows -t continuum-proj-<your-project-id>` again and confirm exactly two windows remain — the session is still alive, and the other two tiles are unaffected. Finally, close both remaining tiles in sequence. After the last one, run `tmux ls` and confirm no `continuum-proj-` session for that project appears.

## Execution mode

Autonomous. The behavioral change — switching from `kill-session` to `kill-window` — is a pure function swap in `TmuxSession` and a descriptor-read in `ContinuumApp`. The existing self-check infrastructure already drives the production close path through a fake runner and captures commands; updating it to assert `kill-window` proves correctness without human eyes. The real-tmux integration check (window-count before/after) is gated on the real `TmuxControl` impl and is falsifiable by the snapshot manifest. No UI judgment is required: the canvas tile disappearance is an existing behavior; only the tmux side-effect changes.

## Done when

- [ ] `TmuxSession.killWindowCommand(target:tmuxPath:)` exists and its pure-logic check passes, asserting the exact `["kill-window", "-t", target]` argv.
- [ ] `killTmuxWindowForDeletedTerminalTile` dispatches to `kill-window` when `descriptor.tmuxWindowTarget` is non-nil, and falls back to `kill-session` when it is nil.
- [ ] The production delete self-check (formerly at `ContinuumApp.swift:11082`) has been updated and passes: it asserts `kill-window -t <target>` for a tile with a captured window target, not `kill-session`.
- [ ] A second self-check path asserts the nil-target fallback issues `kill-session -t continuum-<tileId>`, not `kill-window`.
- [ ] The teardown-detach self-check at line 11105 still passes unchanged: app teardown issues zero kill commands.
- [ ] The real-tmux integration check captures a `SessionTopologySnapshot` before and after each close and records measured window counts. Closing one of three tiles leaves the project session with exactly two windows. Closing the last tile results in the session no longer appearing in `tmux ls`.
- [ ] The manifest for the real-tmux check records actual window counts as measured values (e.g. `windowsBefore: 3, windowsAfter: 2`), never `{passed: true}`.
- [ ] No call to `kill-session` targeting a project session name (`continuum-proj-*`) appears anywhere in the production close path.

## Depends on / unblocks

This ticket depends on the capture-tmuxWindowTarget-at-spawn work, which establishes `tmuxWindowTarget` on `TerminalSessionDescriptor`. Without a persisted, non-nil `%pane_id` on the descriptor, the window-scoped kill cannot target a specific window; the nil-target fallback would fire on every close, which is correct for legacy tiles but defeats the purpose for newly spawned ones. That work is a hard prerequisite.

It also logically depends on the project-session naming work and the new-window spawn work, which establish that tiles share a session and each tile's identity is its pane id — the conceptual model this ticket operationalizes on the close side.

This ticket unblocks the project-release detach work, which handles the case where a project's runtime ref-count hits zero and must detach rather than kill. That work's guarantees only make sense once the close-tile path no longer kills the session directly. It also unblocks the idle reaper work and the per-workspace ambient session work, both of which reason about session lifetime in a world where window-close, not session-kill, is the close primitive.

## Watch out for

**The nil-target fallback must be correct, not elided.** Pre-upgrade tiles have no `tmuxWindowTarget`. If the fallback is dropped or broken, closing a legacy tile leaves a `continuum-<tileId>` session alive forever. The nil-target self-check is not optional — it is the guard that keeps the upgrade path clean.

**The self-check at line 11082 is a live gate, not a comment to update.** It is the only automated proof that the production `deleteTile` path emits the right tmux command. If it is updated to pass trivially (e.g., relaxed to `commands.count >= 0`), the behavioral regression will be invisible. Update the assertion to be strictly correct: exactly one command, exactly `kill-window`, exactly the captured target.

**Do not issue kill-session of the project session in the close path.** The project session must outlive the closed tile as long as any other tile in the project is alive. Any path that derives `continuum-proj-<projectId>` and passes it to `kill-session` is a bug. The session count assertion in the real-tmux check is the backstop for this.

**Window index vs pane id.** tmux window indices (`@N`) renumber when a window is removed. If `kill-window` is given a stale index instead of a `%pane_id`, it kills the wrong window after any reorder. The `tmuxWindowTarget` field stores the `%`-prefixed pane id precisely to avoid this; confirm the stored value starts with `%` before issuing the command, and surface a clear error if it does not.

**Race: close last tile + spawn new tile near-simultaneously.** If a new window is being spawned in the project session at the exact moment the last existing window is killed, tmux may briefly see zero windows and auto-terminate the session before the new window is created. This is an edge case the I3 real-tmux check should exercise: spawn, close, and re-spawn in rapid succession and assert no unexpected session death. The fix, if needed, is to issue `new-window` before `kill-window` in this sequence, but verify the problem is real before complicating the path.
