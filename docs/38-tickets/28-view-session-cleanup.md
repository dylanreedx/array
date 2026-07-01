# View-session cleanup on tile close

**Rests on:** **D19** (grouped-session naming `continuum-view-<tileId>` off `continuum-proj-<projectId>`, cleaned on tile close) and **D16** (close = `kill-window`; project release = detach, never kill). The view-session kill this ticket adds is exactly the "cleaned on tile close" clause of D19; the ordering rule (window first, view session second) is what keeps D16's kill-window semantics intact. The real-tmux integration evidence uses the `SessionTopologySnapshot` primitive from **D26** (phase-0 harness), so that criterion is gated on the phase-0 harness ticket having landed (see Depends on).

## What this delivers

When a terminal tile is closed, the `continuum-view-<tileId>` grouped session that backed its ghostty surface is killed. Because a view session owns no tmux windows of its own — all windows belong to the project session `continuum-proj-<projectId>` — this kill is unconditionally safe: it tears down only the client attachment, never a window or a running process. The project session, and every other tile still viewing it, is completely unaffected.

From the system's perspective, this is the bookkeeping half of de-mirror: the grouped-session attach work (the de-mirror attach ticket) creates a `continuum-view-<tileId>` session at spawn; this ticket ensures that session is cleaned up at close, so dead view sessions do not accumulate in `tmux ls` after tiles are deleted.

## How it fits

This ticket builds directly on the grouped-view-session spawn work (the de-mirror attach ticket). That ticket introduces the `tmux new-session -t continuum-proj-<projectId> -s continuum-view-<tileId>` attach pattern and the `select-window` pinning step; by the time this ticket runs, every terminal tile is guaranteed to have a live `continuum-view-<tileId>` session at the moment its ghostty surface is active. Without that foundation there is no view session to clean up and this ticket has no target.

The close path already routes through `deleteTile(id:)` in `ContinuumApp.swift` (line 3010). Its terminal branch calls the tmux-teardown helper on close. Today that helper is named `killTmuxSessionForDeletedTerminalTile` (line 3108) and it issues a single `kill-session -t continuum-<tileId>` for the legacy per-tile session. The close-tile/kill-window ticket rewrites that helper so the project-window teardown becomes a `kill-window` instead of a `kill-session`; this ticket then adds a second, parallel call inside the same helper: after the project window is torn down, the view session is killed via `kill-session -t continuum-view-<tileId>`. The two kills are independent — one removes the window/process, the other removes the client-attachment shell — and neither can fail the other.

**Current-tree note (read before you start).** The names this ticket adds a call *beside* (`killWindowCommand`, a window-target descriptor, a `tmuxWindowTarget` field) are introduced by the close-tile/kill-window ticket and **do not exist in the tree today** — today the helper calls `TmuxSession.killSessionCommand(tileId:tmuxPath:)` directly (line 3113). This ticket therefore has a hard prerequisite on that ticket (see Depends on). If you find the helper still issuing a bare `kill-session` for the project session, the kill-window ticket has not landed and this ticket must not proceed on top of it — the two would need to be merged into one change rather than layered.

This ticket unblocks the view-session reuse and reconnect work (the dogfood-verify ticket that confirms de-mirror is actually non-mirroring). That ticket's real-path check needs clean teardown — stale view sessions would cause `new-session -t` to name-clash on reconnect.

## The approach

The implementation is a new pure function in `TmuxSession` named `killViewSessionCommand(tileId:tmuxPath:)`, which emits `tmux kill-session -t continuum-view-<tileId>`. The target is derived from `tileId` using a parallel of the existing `sessionName` helper; a new `viewSessionName(tileId:)` function produces the canonical `continuum-view-<UUID>` string so the naming is in one place and consistent with how the attach ticket creates the session (per D19, this is the single source of truth for the view-session name — see Watch out for).

The kill is issued in `killTmuxSessionForDeletedTerminalTile` (renamed by the close-tile/kill-window ticket) in `ContinuumApp.swift`, immediately after that helper's project-window teardown call. The ordering is: tear down the project window first (stops the process and removes the window from the project session), then kill the view session (removes the client-attachment shell). If the view-session kill fails — because, for instance, the tile was closed while the app was quit and the view session already died naturally — the error is logged to `stderr` and suppressed, not propagated. A missing view session at close time is not a bug; it is a legal state after a restart.

No change is made to the `windowWillClose` / teardown path. App teardown detaches, never kills (D16). View sessions survive app quit alongside project sessions; on reattach, the grouped-view-session attach ticket re-creates them. This ticket does not touch the teardown path.

The view-session kill is guarded by the same `TmuxPersistenceConfig.enabled` check that guards the window kill. If tmux persistence is disabled, no view session was created at spawn, so no cleanup is needed or issued.

## Where it lives

**`Sources/ContinuumRevivedCore/TmuxSession.swift`** (lines 1–34)

- Add `TmuxSession.viewSessionName(tileId: UUID) -> String` returning `"continuum-view-\(tileId.uuidString)"`. This is the canonical name that both the attach ticket (spawn side) and this ticket (close side) use. It lives beside the existing `sessionName(tileId:)` at line 8.
- Add `TmuxSession.killViewSessionCommand(tileId: UUID, tmuxPath: String) -> (command: String, arguments: [String])` returning `(command: tmuxPath, arguments: ["kill-session", "-t", viewSessionName(tileId: tileId)])`. This lives beside `killSessionCommand(tileId:tmuxPath:)` at line 27.

**`Sources/ContinuumRevived/App/ContinuumApp.swift`**

- `killTmuxSessionForDeletedTerminalTile(tileId:)` (line 3108, renamed by the close-tile/kill-window ticket) gains a second `tmuxProcessRunner` call after its project-window teardown, issuing `killViewSessionCommand(tileId:tmuxPath:)`. The error is caught and logged; it does not re-throw or modify `deleteOutcome`.
- `deleteTile(id:)` at line 3010 does not change structurally — the new kill is absorbed entirely inside the helper.
- The existing self-check around line 11082 that asserts exactly one command for a terminal tile close must be updated to assert exactly **two** commands: first the project-window teardown command, then the `kill-session -t continuum-view-<tileId>` command from this ticket. The ordering must be asserted, not just the count. See the Self-check precondition note below for exactly what the assertion looks like in the current tree versus after the kill-window ticket. The teardown assertion at line 11105 (zero commands on app close) is unchanged and must continue to pass.

**Self-check precondition (read this — the tree does not match the naive assumption).** In the tree **today**, the self-check at line 11082 builds `expectedKill = TmuxSession.killSessionCommand(...)` and asserts `deleteCapture.commands.count == 1` for a **kill-session** command targeting the legacy per-tile session. The close-tile/kill-window ticket rewrites *that* line to expect a **kill-window** command instead (still count `== 1`). This ticket then raises the count to `== 2` and adds the view-session assertion as the second command. **Do not** write the self-check against `TmuxSession.killWindowCommand` or a `fakeWindowTarget` unless the kill-window ticket has already introduced them — those symbols do not exist in the current tree, and referencing them before that ticket lands produces an unverifiable seam. The correct sequencing is: kill-window ticket lands (converts command 0 from kill-session to kill-window, count stays `== 1`) → this ticket lands (raises count to `== 2`, adds command 1 = kill-view-session).

**`Sources/ContinuumRevivedCoreChecks/main.swift`**

- New pure-logic checks for `killViewSessionCommand` and `viewSessionName` (exact argv shape, exact name format). These live beside the existing `killSessionCommand` check at line 313.

## Implementation breadcrumbs

```swift
// TmuxSession.swift — new beside existing sessionName and killSessionCommand

public static func viewSessionName(tileId: UUID) -> String {
    "continuum-view-\(tileId.uuidString)"
}

public static func killViewSessionCommand(
    tileId: UUID,
    tmuxPath: String
) -> (command: String, arguments: [String]) {
    (command: tmuxPath, arguments: ["kill-session", "-t", viewSessionName(tileId: tileId)])
}
```

```swift
// ContinuumApp.swift — inside killTmuxSessionForDeletedTerminalTile.
// The project-window teardown block above is owned by the close-tile/kill-window ticket;
// this ticket only appends the view-session kill AFTER it.

private func killTmuxSessionForDeletedTerminalTile(tileId: UUID) {
    guard TmuxPersistenceConfig.enabled(defaults: tmuxDefaults),
          let tmuxPath = tmuxPathResolver(tmuxDefaults) else { return }

    // 1. Project-window teardown — owned by the close-tile/kill-window ticket.
    //    (Today: TmuxSession.killSessionCommand; after that ticket: a kill-window.)
    //    Left as-is by this ticket.

    // 2. Kill the view session (this ticket). Safe even if already gone.
    let viewCmd = TmuxSession.killViewSessionCommand(tileId: tileId, tmuxPath: tmuxPath)
    do {
        try tmuxProcessRunner(viewCmd.command, viewCmd.arguments)
    } catch {
        // View session may already be gone (app-restart scenario). Log and continue.
        fputs("tmux kill-session (view) failed for tile=\(tileId.uuidString): \(error)\n", stderr)
    }
}
```

```swift
// ContinuumRevivedCoreChecks/main.swift — new pure-logic checks

let viewName = TmuxSession.viewSessionName(tileId: tileId)
expect(viewName == "continuum-view-\(tileId.uuidString)",
    "viewSessionName must produce deterministic continuum-view-<UUID> string")

let viewKill = TmuxSession.killViewSessionCommand(tileId: tileId, tmuxPath: tmuxPath)
expect(viewKill.command == tmuxPath,
    "killViewSessionCommand must use the provided tmux path")
expect(viewKill.arguments == ["kill-session", "-t", "continuum-view-\(tileId.uuidString)"],
    "killViewSessionCommand must emit kill-session targeting the view session name")
```

```swift
// ContinuumApp.swift self-check update — around line 11082.
// PRECONDITION: the close-tile/kill-window ticket has landed, so command 0 is a
// kill-window and its expected-value builder (e.g. killWindowCommand / a window target)
// already exists. This ticket adds command 1 (the view-session kill) and raises the count.

let expectedWindowKill = /* the kill-window expectation introduced by the kill-window ticket */
let expectedViewKill   = TmuxSession.killViewSessionCommand(tileId: terminalTileId, tmuxPath: fakeTmuxPath)

try expect(deleteCapture.commands.count == 2,
    "terminal tile close should issue exactly two tmux commands (window teardown then kill-view-session), got \(deleteCapture.commands)")
try expect(deleteCapture.commands[0]["arguments"] as? [String] == expectedWindowKill.arguments,
    "first command must be the project-window teardown from the kill-window ticket")
try expect(deleteCapture.commands[1]["arguments"] as? [String] == expectedViewKill.arguments,
    "second command must be kill-session targeting the view session name")
```

## How we test it

### Logic (pure Core checks)

In `ContinuumRevivedCoreChecks`, add three pure-function assertions:

1. `TmuxSession.viewSessionName(tileId:)` returns `"continuum-view-<UUID>"` for a known UUID — confirming the name is deterministic and uses the canonical prefix.
2. `TmuxSession.killViewSessionCommand(tileId:tmuxPath:)` returns `(command: tmuxPath, arguments: ["kill-session", "-t", "continuum-view-<UUID>"])` — confirming the exact argv shape.
3. `viewSessionName` and `sessionName` produce different strings for the same `tileId` — confirming the view namespace is distinct from the legacy per-tile namespace and there is no collision risk.

All three are pure value-type function calls with no filesystem or process dependencies.

### Backend (real-path / integration)

The existing terminal-tmux-delete-lifecycle self-check in `ContinuumApp.swift` (around line 11063) is the primary real-path gate. It drives the production `deleteTile` → `killTmuxSessionForDeletedTerminalTile` path through a fake `tmuxProcessRunner` that captures every issued command. The check must be updated to assert the full two-command sequence:

- Command 0: the project-window teardown (owned by the close-tile/kill-window ticket).
- Command 1: `kill-session -t continuum-view-<tileId>` (from this ticket).
- The assertion on count becomes `== 2`.
- The teardown sub-check (line 11105) continues to assert zero commands — teardown does not kill view sessions.
- The tmux-disabled sub-check (line 11132) continues to assert zero commands — no view session was created, so none is killed.

A second self-check scenario exercises the case where the view-session kill call throws (simulated by a fake runner that throws on the second invocation). Assert that `deleteTile` still completes (tile is removed from canvas, canvas is saved) and the window teardown was still attempted — the view-session kill failure must not abort the close path. This scenario needs no new primitives and can land with this ticket regardless of the phase-0 harness.

A real-tmux integration check (gated on the real `TmuxControl` implementation, not the fake runner) verifies the end-to-end lifecycle: create a project session with two windows, attach two grouped view sessions, close one tile, then call `tmux ls` and assert: (a) the project session still exists with one window, (b) the closed tile's `continuum-view-<tileId>` session is gone, (c) the surviving tile's `continuum-view-<otherTileId>` session is still present. This check writes a `SessionTopologySnapshot` before and after, recording actual session names as measured values in the manifest — not a boolean. **This integration check depends on the phase-0 harness ticket (D26), which introduces `SessionTopologySnapshot`.** If that ticket has not landed, this check cannot be written; in that case ship the pure-logic checks + the two self-check scenarios above (which are fully sufficient to prove the view-session kill fires in the correct position and is non-fatal), and land the snapshot-backed integration check as a follow-on once the harness exists. The corresponding Done-when box is marked accordingly.

### UX (visual gate + dogfood snippet)

The visual gate is `tmux ls` output before and after a tile close. A non-degenerate gate: before close, `tmux ls` must list both `continuum-proj-<projectId>` and `continuum-view-<tileId>`; after close, the project session must remain and the view session must be absent.

**Dogfood snippet.** Open the app and open a project. Spawn two terminal tiles into the project — verify in a separate terminal that `tmux ls` shows `continuum-proj-<projectId>` (the project session), `continuum-view-<tile1Id>`, and `continuum-view-<tile2Id>` (the two view sessions). Select the first tile on the canvas and close it with the delete keybind (default `q`). Observe: the tile disappears from the canvas immediately; the other tile is unaffected. Now run `tmux ls` in your external terminal and confirm: `continuum-proj-<projectId>` still appears with one window, `continuum-view-<tile2Id>` still appears, and `continuum-view-<tile1Id>` is gone. Close the second tile. Run `tmux ls` again and confirm both view sessions are gone; the project session may also be gone if it auto-reaped at zero windows, or still present if the project release detach path is live (D16). No `continuum-view-` entries should remain in any case.

## Execution mode

Autonomous, with one gated seam. The behavioral change is confined to two new pure functions in `TmuxSession` and one additional `tmuxProcessRunner` call in the existing close helper. The real-path self-check already drives the full production `deleteTile` path through an injectable fake runner; extending it to assert two commands instead of one proves the view-session kill fires in the correct position without requiring a human to run the app. The one gated piece is the snapshot-backed real-tmux integration check, which cannot be written until the phase-0 harness (D26) lands `SessionTopologySnapshot`; the pure-logic checks and the two fake-runner self-check scenarios stand alone and provide autonomous, falsifiable evidence in the meantime. No UI judgment is required: the canvas tile disappearance behavior is unchanged; only the post-close tmux state changes.

## Done when

- [ ] `TmuxSession.viewSessionName(tileId:)` exists and its pure-logic check passes, asserting the exact `"continuum-view-<UUID>"` format.
- [ ] `TmuxSession.killViewSessionCommand(tileId:tmuxPath:)` exists and its pure-logic check passes, asserting the exact `["kill-session", "-t", "continuum-view-<UUID>"]` argv.
- [ ] A third pure-logic check confirms `viewSessionName` and `sessionName` return different strings for the same `tileId`.
- [ ] `killTmuxSessionForDeletedTerminalTile` issues the view-session kill **after** the project-window teardown, in that order.
- [ ] The view-session kill error is caught and logged; a thrown error from the fake runner on the second call does not prevent tile removal or canvas save (proven by the throwing-second-call self-check scenario).
- [ ] The terminal-tmux-delete-lifecycle self-check asserts exactly two commands for a normal tile close: the project-window teardown first, `kill-session -t continuum-view-<tileId>` second.
- [ ] The teardown sub-check still asserts zero commands (unchanged).
- [ ] The tmux-disabled sub-check still asserts zero commands (unchanged).
- [ ] **(Gated on the phase-0 harness ticket, D26.)** The real-tmux integration check writes a `SessionTopologySnapshot` before and after close and records measured session names — not a boolean — in the manifest. After close: project session present with one fewer window; closed tile's view session absent; surviving tile's view session present. If the harness has not landed, this box is deferred to the follow-on and the two fake-runner self-check scenarios stand as the acceptance evidence.
- [ ] No `continuum-view-` session appears in `tmux ls` for any tile that has been closed (verified by the dogfood snippet, and by the integration check once the harness lands).

## Depends on / unblocks

**Depends on — the grouped-view-session spawn work (the de-mirror attach ticket).** That ticket introduces the `continuum-view-<tileId>` naming convention (per D19), the grouped-session attach at spawn time, and the `select-window` pinning step. This ticket's cleanup is the mirror image of that spawn; without the spawn side, there is nothing to clean up and the `viewSessionName` naming would be defined nowhere else.

**Depends on — the close-tile/kill-window ticket.** It rewrites `killTmuxSessionForDeletedTerminalTile` from a project-session `kill-session` call to a `kill-window` call (per D16). This ticket adds a second call inside that same function; merging into the old single-call shape would require a rewrite rather than an addition. It is a hard prerequisite — the `killWindowCommand` / window-target symbols this ticket's self-check leans on are introduced there, not here.

**Depends on — the phase-0 harness ticket (D26)** for the `SessionTopologySnapshot`-backed integration check only. The pure-logic and fake-runner self-check evidence does not depend on it; the snapshot-backed real-tmux check is deferred to a follow-on if the harness has not landed (see Backend testing).

**Unblocks — the de-mirror verification work (the dogfood-verify ticket).** It confirms that two tiles viewing the same project session genuinely show different active windows. That ticket's real-path check needs a clean teardown cycle — stale view sessions from uncleaned closes would cause `new-session -t` to collide on the view session name at reconnect, making the verify check non-deterministic.

## Watch out for

**The kill ordering matters for safety (D16).** Always tear down the project window before the view session. If the view session were killed first, tmux would destroy the client connection to the project session before the window teardown runs, which could leave the window alive. Tear down the window, then remove the view-session shell. Do not swap this order.

**A missing view session is not an error.** If the app was quit and restarted, the view session may have already died (tmux cleans up sessions with no attached clients in some configurations). The `tmuxProcessRunner` call for the view-session kill will throw a non-zero exit; this must be caught and logged, not propagated. The self-check scenario that simulates a throwing second call is the backstop that confirms the error path is genuinely non-fatal.

**The self-check command-count assertion is a live gate.** After the close-tile/kill-window ticket lands, it asserts `commands.count == 1` (a single window teardown). This ticket must raise it to `== 2`. If it is relaxed to `>= 1` or checked only for the first command, the view-session kill will silently never fire in production without any test failure. The assertion must be strict and ordered. (In the current tree the same line still asserts `== 1` for a legacy `kill-session`; see the Self-check precondition note above — do not raise it to `== 2` until the kill-window ticket has converted command 0.)

**Do not issue the view-session kill during app teardown (D16).** The `windowWillClose` path must not call `killViewSessionCommand`. View sessions survive app quit so that on reattach the grouped-session attach at spawn can re-create them cleanly; killing them at quit would force a tmux reconnect dance on every restart. The teardown assertion (zero commands) is the guard — confirm it still passes after this ticket lands.

**Name consistency with the spawn ticket (D19 makes this a settled rule, not an open question).** D19 fixes `continuum-view-<tileId>` as the view-session name and this ticket's `viewSessionName(tileId:)` is its single definition site. The spawn ticket (the de-mirror attach ticket) MUST call `viewSessionName(tileId:)` when it issues `tmux new-session -s` rather than hard-coding the string inline — that is the D19 contract, not a per-implementation choice to negotiate. After both tickets land, a single source-of-truth grep for `"continuum-view-"` must show exactly one definition site (`viewSessionName`) with all callers going through it; if the grep shows a second inline occurrence, the spawn ticket violated the contract and the fix is to route it through `viewSessionName`, not to reconcile two strings by hand.
