# Reattach-by-target + replay scrollback

**Area:** Topology — Phase 1
**Execution mode:** Needs-substrate
**Grounding:** `docs/2026-06-30-t3code-steal/05-resilience-terminals-reconnect.md`, `docs/2026-06-30-orchestration-spikes/TOPOLOGY.md`, `docs/38-locked-decisions.md` (D16, D25, D26), `docs/38-agent-orchestration-architecture.md` (invariants I1, I8)

---

## What this delivers

After this ticket lands, Continuum satisfies the I1/I8 acceptance contract end-to-end on real hardware: a terminal tile can be torn down — the ghostty client terminated, the app quit, the descriptor pruned as it would be at boot — and on restart it finds the same tmux window by its durable `%pane_id` target, confirms the sentinel process is still alive with the same pid, and native tmux scrollback repaints onto the new surface so the user sees exactly where they left off. When the session did not survive (clean reboot, fresh daemon, remote host unreachable), the persisted scrollback snapshot is replayed onto the new surface instead. This is the transition from "we have the pieces" to "the system provably survives the full teardown-and-reattach cycle."

The user-visible outcome is simple: quit and reopen Continuum, and each terminal tile comes back where it was — same window, same live process, same scrollback visible on screen — with no re-spawn of any agent. The system-visible outcome is more specific: `pidBefore == pidAfter`, `targetBefore == targetAfter`, and the scrollback appears rendered in the ghostty surface within the timeout budget.

This ticket also closes the deferred no-op that has sat in the codebase since the scrollback capture work landed. `TileSpawner.swift:354-355` reads: "Scrollback replay is option (c): persisted to disk (descriptor.scrollback above), on-screen replay deferred (NEEDS-HUMAN mechanism decision pending)." That decision is now made. The mechanism, and the precedence rule governing when native tmux scrollback wins versus when the persisted snapshot fires, is specified below and implemented here.

---

## How it fits

This ticket is the capstone of the session topology sprint. It builds directly on the target-capture work (ticket 15, `docs/38-tickets/15-new-tile-new-window.md`), which added `tmuxWindowTarget` to `TerminalSessionDescriptor` and guaranteed the pane id is on disk before the ghostty surface launches.

**It builds directly on the dead-target recovery work (ticket 17, `docs/38-tickets/17-dead-target-fallback.md`), and does not reinvent any of it.** Ticket 17 is the ticket that gives `restartTerminalTile` its liveness probe and its alive-vs-dead branch. Concretely, ticket 17 delivers, inside `restartTerminalTile`:

- the probe — `let targetIsAlive = (try? await tmuxControl.isAlive(paneTarget: target)) ?? false` — using the `TmuxControl` protocol from ticket 12 (`docs/38-tickets/12-injectable-substrates.md`), whose typed `func isAlive(paneTarget:) async throws -> Bool` is *the* production liveness call. There is no `tmuxControl.run(arguments:)` method on that protocol and this ticket must not invent one;
- the alive branch — reuse the live pane, `resolvedTarget = storedTarget`;
- the dead/nil branch — `tmuxControl.newWindow(inSession:)` with a `newSession(name:)` fallback, capturing the new `%pane_id` into `resolvedTarget`;
- the async signature — ticket 17 already makes `restartTerminalTile` async (or runs the probe/fallback inside the async context ticket 15 established), because every `TmuxControl` method is `async throws`.

**This ticket owns exactly one new thing: on-screen scrollback replay, added to the branch ticket 17 already created.** It does not add a second probe, a second fallback, or a second insertion point. It reads the `targetIsAlive` / `resolvedTarget` values ticket 17 computed and, in the *dead/nil* branch only, replays the persisted snapshot after the new surface is installed. In the *alive* branch it does nothing extra — native tmux scrollback repaints on reattach (that reattach itself is delivered by tickets 15/17/19, not here).

It also builds on the injectable substrates (ticket 12), which supply the fake `TmuxControl` and fake clock that make the logic tier of this check deterministic without a daemon, and on the private managed-agent session record, the host-local store keyed by tile id that carries the opaque runtime payload — including the window target — and is explicitly never synced.

What it unblocks is the de-mirror work (`docs/38-tickets/27-grouped-view-session.md`) and the broader Phase 2 work on grouped view sessions, both of which assume the reattach-by-target path is already proven on real code. It also unblocks the upgrade migration ticket (D25), which documents the one-time agent restart — that note only makes sense once the nominal path (no restart, same pid) is proven on a surviving session.

---

## The approach

The approach has two parts. Part 1 is a precedence *rule* layered on top of ticket 17's existing branch; Part 2 is the one new function this ticket introduces.

**Part 1 — the scrollback precedence rule, expressed against ticket 17's branch.** Ticket 17 already computes `targetIsAlive` and, from it, `resolvedTarget`. This ticket adds the following rule with no new probe:

- **Alive branch (`targetIsAlive == true`, ticket 17's reuse path):** the pane's own tmux scrollback buffer is the canonical source of truth — the session never dropped, the bytes are all there, and tmux repaints them naturally when the ghostty surface reattaches. **Do not replay the persisted snapshot.** The persisted snapshot is stale relative to whatever the session accumulated while the client was detached; injecting it would render duplicated, out-of-order text on top of a live pane.
- **Dead/nil branch (`targetIsAlive == false`, ticket 17's new-window fallback path):** ticket 17 has already spawned a fresh window and captured a new `resolvedTarget`. The fresh window has no history. **If `descriptor.scrollback` is non-nil and scrollback is enabled, call `replayScrollback` to inject the persisted text into the new ghostty surface.** This is the fallback path, equivalent to t3code's "open = recreate from disk `.log` when no session exists" path (`Manager.ts:2099-2158`).

Because the rule is keyed on `targetIsAlive` — the exact value ticket 17 computes — there is no second probe, and no ambiguity about which probe is real: the only probe is ticket 17's `TmuxControl.isAlive(paneTarget:)`.

**Part 2 — implement `replayScrollback`.** The replay mechanism writes the persisted scrollback text into the new ghostty surface using the runtime's existing `sendInput` path. This is intentionally simple: the surface is already a pty; writing the snapshot text to it causes the terminal emulator to render it as history. The implementation must:

- Write the text in chunks no larger than 4096 bytes, yielding between chunks (see "Concurrency model" for how the yield is spelled in an async context) so it does not overwhelm the pty buffer.
- Append a final `\r\n` after the last chunk so the cursor lands on a clean line when the shell prompt appears.
- Guard the entire call on `SessionResumeConfig.scrollbackEnabled(defaults:)` — if the user has disabled scrollback capture, replay is also disabled; do not inject stale text the user cannot attribute to the current session.
- Return immediately if `scrollback` is nil or empty.

The call site is the dead/nil branch of `restartTerminalTile` (new window, session was gone), after ticket 17's new runtime is installed and the ghostty surface is created.

---

## Concurrency model (resolved, not left to the implementer)

Ticket 17 makes `restartTerminalTile` **async** — this is a hard fact of the dependency chain, because `TmuxControl.isAlive`, `newWindow`, and `newSession` are all `async throws` (ticket 12). This ticket does **not** re-decide that; it inherits it. Two consequences the implementer must not have to guess at:

1. **The replay call site runs in that async context.** The dead/nil branch, where `replayScrollback` is called, executes after ticket 17's `await tmuxControl.newWindow(...)` — so it is already `async`. `replayScrollback` is called from there.

2. **`replayScrollback` yields via `await Task.yield()` / `try? await Task.sleep`, not `RunLoop.current.run`.** Because the enclosing context is async, the between-chunk yield is expressed with structured concurrency, not a nested run-loop spin. `replayScrollback` is therefore an `async` function:

   ```
   private func replayScrollback(_ text: String, into runtime: GhosttyTerminalRuntime) async
   ```

   Do not use `RunLoop.current.run(mode:before:)` — nesting a run loop inside an already-async `@MainActor` restart path risks re-entrancy against the very ghostty surface install that just happened. A cooperative `await Task.yield()` (or a short `try? await Task.sleep(nanoseconds:)`) between chunks lets the pty buffer drain without blocking or re-entering.

The logic-tier checks that exercise `replayScrollback`'s chunking therefore `await` it. The real-path check already runs its restart step through the async `restartTerminalTile`.

---

## Where it lives

**Primary seam — the dead/nil branch of `TileSpawner.restartTerminalTile`:**
`Sources/ContinuumRevived/App/TileSpawner.swift` — inside `restartTerminalTile` (begins at line 276), in the new-window fallback branch that **ticket 17 introduces**.

This ticket does not add or move the probe, and does not choose an insertion point for it — ticket 17 owns the probe and the branch. This ticket adds a single call, `await replayScrollback(...)`, guarded by `SessionResumeConfig.scrollbackEnabled`, at the tail of ticket 17's dead/nil branch, after the new runtime and surface are installed. The deferred no-op comment currently at `TileSpawner.swift:354-355` is deleted; conceptually this ticket's replay call replaces the *idea* that comment stood for, but the physical call lives inside ticket 17's fallback branch, not at line 354 verbatim (ticket 17 will have restructured that region).

**Primary seam — new `replayScrollback` function on `TileSpawner`:**
`Sources/ContinuumRevived/App/TileSpawner.swift` — new private async function, added near `flushTerminalSessionSnapshot` (line 371).

```
private func replayScrollback(_ text: String, into runtime: GhosttyTerminalRuntime) async
```

Uses `runtime.sendInput(Data(...))` to write in 4096-byte chunks. No new dependency; `sendInput` already exists on `GhosttyTerminalRuntime` (confirmed in Sources — used by the existing self-checks, e.g. `TileSpawner.swift:2864,3563`).

**Consumed seam — the liveness probe (owned by ticket 17, via ticket 12's `TmuxControl`):**
`Sources/ContinuumRevivedCore/Substrates/TmuxControl.swift` (created by ticket 12).

The probe this ticket keys its precedence rule on is ticket 17's:
```
let targetIsAlive = (try? await tmuxControl.isAlive(paneTarget: target)) ?? false
```
`isAlive(paneTarget:) async throws -> Bool` is the typed liveness call defined by ticket 12 (see `docs/38-tickets/12-injectable-substrates.md` lines 100-103). There is no `run(arguments:)` on `TmuxControl`. This ticket reads the resulting `targetIsAlive` boolean; it does not call the probe itself.

**Supporting seam — `GhosttyTerminalRuntime.sendInput`:**
`Sources/ContinuumRevived/TerminalEngine/GhosttyTerminalRuntime.swift`

Already exists. No modification needed. Used verbatim by `replayScrollback`.

**Supporting seam — `TerminalSessionDescriptor.tmuxWindowTarget` and `.scrollback`:**
`Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift`

`tmuxWindowTarget` added by ticket 15; `scrollback` already exists (`:20`). Both read here, neither written by this ticket (ticket 17 writes `tmuxWindowTarget`).

**Supporting seam — `SessionResumeConfig.scrollbackEnabled(defaults:)`:**
`Sources/ContinuumRevivedCore/SessionResumeConfig.swift`

Already exists (gating the flush path). Reused as the guard for replay.

---

## Implementation breadcrumbs

```swift
// This ticket adds ONLY the replay call, at the tail of ticket 17's dead/nil branch.
// Ticket 17 already computed `targetIsAlive` (via `await tmuxControl.isAlive(...)`) and
// `resolvedTarget` (via `await tmuxControl.newWindow(...)` with newSession fallback), and
// already installed the runtime/surface for both branches. The branch structure below is
// TICKET 17's; the marked line is the one thing THIS ticket contributes.

// --- Ticket 17's branch (shown for context; NOT re-implemented here) ---
if targetIsAlive {
    // Ticket 17 + tickets 15/19: reattach to the live pane. Native tmux scrollback
    // repaints on reattach — NOTHING from this ticket runs here.
    // Manifest: targetSurvived = true, scrollbackReplayed = false
} else {
    // Ticket 17: the fresh window has already been created (resolvedTarget captured),
    // its runtime built, its ghostty surface installed.

    // ---- THIS TICKET'S CONTRIBUTION: replay onto the fresh, historyless surface ----
    if let scrollback = persistedDescriptor?.scrollback,
       !scrollback.isEmpty,
       SessionResumeConfig.scrollbackEnabled(defaults: defaults) {
        await replayScrollback(scrollback, into: runtime)   // async yield between chunks
    }
    // Manifest: targetSurvived = false, scrollbackReplayed = (scrollback?.isEmpty == false)
}
```

```swift
// The replayScrollback implementation. Async because it runs in restartTerminalTile's
// async context (ticket 17) and yields cooperatively — NOT via RunLoop.current.run.
private func replayScrollback(_ text: String, into runtime: GhosttyTerminalRuntime) async {
    guard !text.isEmpty else { return }
    let chunkSize = 4096
    let data = Data(text.utf8)
    var offset = data.startIndex
    while offset < data.endIndex {
        let end = data.index(offset, offsetBy: chunkSize, limitedBy: data.endIndex) ?? data.endIndex
        runtime.sendInput(data[offset..<end])
        offset = end
        // Cooperative yield so the pty buffer drains between chunks (no nested run loop).
        await Task.yield()
        // (If a hard drain interval is needed on real hardware, use:
        //  try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms)
    }
    // Trailing newline so the shell prompt lands on a clean line.
    runtime.sendInput(Data("\r\n".utf8))
}
```

```swift
// The real-path check harness shape (inline in TileSpawner's check suite, following the
// EXISTING pattern of the current tmux-live restart check around TileSpawner.swift:3500-3650).
// All helpers below (run, expect, pump, comparablePath, visibleText, qaTerminalView?.surface)
// are LOCAL helpers built inside the check function exactly as the existing checks do — this
// ticket does NOT assume any shared tmuxPaneState()/tmuxHasSession() helper exists (none do).
//
// `run(tmuxPath, [...])` is the existing local subprocess helper (TileSpawner.swift:3322,
// signature `func run(_ command: String, _ arguments: [String], allowFailure: Bool = false)`),
// used verbatim by the current check for `has-session` and `list-panes -F`.

// Phase 1: spawn, write sentinel output, flush, capture pane state via a real tmux query.
let sentinelMarker = "i8-sentinel-\(UUID().uuidString.prefix(8))"
runtime1.sendInput(Data("printf '\(sentinelMarker)-pid-%d\\n' $$\n".utf8))
try pump(context1, timeout: 8.0, waitingFor: "sentinel output") {
    runtime1.visibleText().contains("\(sentinelMarker)-pid-")
}
try spawner1.flushTerminalSessionSnapshot(tileId: tile.id, runtime: runtime1)

// Capture pane id + pid + cwd BEFORE detach with a real tmux query (same idiom as the
// existing check's `run(tmuxPath, ["list-panes", "-t", sessionName, "-F", ...])`).
let target = descriptor.tmuxWindowTarget!
let beforeCols = try run(tmuxPath, ["display", "-p", "-t", target,
                                    "#{pane_id}\t#{pane_pid}\t#{pane_current_path}"])
                     .stdout.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\t")

// Phase 2: teardown (simulate app quit), then boot prune.
runtime1.terminate(policy: .force)
// ... shutdown context, close window, stamp lastExit, run pruneExitedSessions ...
let sessionAlive = try run(tmuxPath, ["has-session", "-t", projectSessionName],
                           allowFailure: true).status == 0
try expect(sessionAlive, "tmux session must survive ghostty-client teardown")

// Phase 3: reattach via the async restartTerminalTile.
switch await spawner2.restartTerminalTile(tileId: tile.id) {
case .restarted(let runtime2):
    try pump(context2, timeout: 8.0, waitingFor: "reattached surface") {
        runtime2.qaTerminalView?.surface != nil
    }
    let afterCols = try run(tmuxPath, ["display", "-p", "-t", target,
                                       "#{pane_id}\t#{pane_pid}\t#{pane_current_path}"])
                        .stdout.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\t")
    try expect(beforeCols[0] == afterCols[0],
               "pane id must survive teardown: before=\(beforeCols[0]), after=\(afterCols[0])")
    try expect(beforeCols[1] == afterCols[1],
               "pid must survive teardown: before=\(beforeCols[1]), after=\(afterCols[1])")
    try expect(comparablePath(beforeCols[2]) == comparablePath(afterCols[2]),
               "cwd must survive teardown")
    // I8 proven: same pane id, same pid, same cwd.

    // Scrollback: on a SURVIVING session the sentinel must be visible via native tmux
    // repaint (this ticket contributes no replay on the alive branch).
    try pump(context2, timeout: 8.0, waitingFor: "scrollback visible after reattach") {
        runtime2.visibleText().contains(sentinelMarker)
    }
    let scrollbackVisible = runtime2.visibleText().contains(sentinelMarker)
    try expect(scrollbackVisible, "sentinel marker must be visible in scrollback after reattach")
default:
    throw CheckError.failed("restartTerminalTile must succeed when target is alive")
}

// Manifest: measured values, not {passed: true}.
// pidBefore, pidAfter, targetBefore, targetAfter, cwdBefore, cwdAfter,
// scrollbackVisible, sessionAliveAfterDetach.
```

---

## How we test it

### Logic (pure Core checks)

These run in `ContinuumRevivedCoreChecks` (or the `TileSpawner` self-check suite for the restart-path cases) with no daemon, no display, no real tmux — driven by ticket 12's `InMemoryTmuxControl`. Because `restartTerminalTile` is async (ticket 17), the checks `await` it and `await replayScrollback`.

1. **Precedence follows ticket 17's `targetIsAlive`.** Seed `InMemoryTmuxControl` so `isAlive(paneTarget: "%5")` returns `true` (alive) in one run and `false` (dead) in another, with a persisted descriptor carrying both a target and a non-empty `scrollback`. Assert that in the alive run **no** `sendInput` is issued by replay (assert the mock runtime records no replay writes), and in the dead run replay **does** issue `sendInput` (the fallback window created by ticket 17 gets the snapshot). This proves the precedence rule keys correctly off ticket 17's probe value and never introduces a second probe (assert `tmuxControl.log` contains exactly one `isAlive` call).

2. **`replayScrollback` chunk boundaries.** `await replayScrollback` with a string of exactly 4096 bytes: assert `sendInput` is called exactly twice (one body chunk, one trailing `\r\n`). With a 1-byte string: assert `sendInput` is called twice (body + newline). With an empty string: assert `sendInput` is never called. Pure unit checks on the chunking logic using a mock runtime.

3. **Scrollback guard.** Construct a `UserDefaults` test suite with `scrollbackEnabled = false`. Drive the dead/nil branch's replay decision: assert `replayScrollback` is never called even when `descriptor.scrollback` is non-nil. This proves the guard respects the user's setting.

4. **Alive target → no replay, even with a non-nil snapshot.** Feed a descriptor with both a non-nil `tmuxWindowTarget` and a non-nil `scrollback`; seed `InMemoryTmuxControl` so the target is alive. Assert the descriptor's `scrollback` is never passed to `replayScrollback`. The alive-target path must never replay a stale snapshot over a live session.

### Backend (real-path check, not bypassed)

This check runs against a real tmux daemon and a real ghostty runtime. It is the I1/I8 proof. It is added **alongside the existing tmux-live restart check** in `TileSpawner.swift` (the inline block around `:3500-3650` that today spawns → `cd` → detaches → restarts → asserts `visibleText()` shows the marker). This ticket adds a new named check function, `reattachByTargetAndReplayScrollback`, following that block's exact structure and reusing its local-helper idiom (`run(tmuxPath, [...])`, `expect`, `pump`, `comparablePath`, `visibleText`, `qaTerminalView?.surface`) — none of which are shared free functions; each check builds its own, as the existing checks do. This ticket does **not** assume any `tmuxPaneState`/`tmuxHasSession` helper exists (they do not); pane/session state is read with real tmux queries via the existing local `run` helper (`display -p -F '#{pane_id}\t#{pane_pid}\t#{pane_current_path}'`, `has-session`, `list-panes`), exactly the commands the current check already uses.

The check runs in three phases:

**Phase 1 — spawn and write sentinel.** Spawn a terminal tile through the full `TileSpawner.spawnTerminal` path in a real ghostty context. Wait for the surface. Send `printf '<marker>-pid-%d\n' $$` via `runtime.sendInput` and wait for the output in `runtime.visibleText()`. Then `cd` to a distinct directory and wait for OSC-7 to report the change. Call `flushTerminalSessionSnapshot` to persist cwd and scrollback. Record `paneIdBefore`, `pidBefore`, `cwdBefore` via `run(tmuxPath, ["display", "-p", "-t", <target>, "#{pane_id}\t#{pane_pid}\t#{pane_current_path}"])` — reading `descriptor.tmuxWindowTarget` for `<target>`.

**Phase 2 — teardown (simulate app quit).** Call `runtime.terminate(policy: .force)`, detach the tile view's host, pump briefly, close the window, shut down the ghostty context. Stamp `lastExit` and call `pruneExitedSessions` to simulate boot prune. Assert the tmux session is still alive via `run(tmuxPath, ["has-session", "-t", <projectSession>], allowFailure: true).status == 0`. Assert the descriptor was pruned from disk (state at next boot).

**Phase 3 — restart and assert I8.** Create a fresh ghostty context and a fresh `TileSpawner` (same store, same project). `await restartTerminalTile(tileId:)`. Assert it returns `.restarted`. Wait for the new surface. Query pane state again via the same `display -p` command: assert `paneIdAfter == paneIdBefore`, `pidAfter == pidBefore`, `cwdAfter == cwdBefore`. Wait for the sentinel marker to appear in `runtime2.visibleText()` — this is native tmux scrollback surviving the reattach (no replay fires on the alive branch). Assert it appears within the 8-second timeout.

The check writes a manifest with measured values: `pidBefore`, `pidAfter`, `targetBefore`, `targetAfter`, `cwdBefore`, `cwdAfter`, `scrollbackVisible: true/false`, `sessionAliveAfterDetach: true/false`. A manifest entry of `scrollbackVisible: false` is a failing check, not a passing one with a caveat.

If tmux is not available (`TmuxLocator.resolve()` returns nil), the check skips with an explicit message and a manifest entry of `status: "skipped"`. It never passes silently when the real path is not exercised.

**Honest scope note on the alive branch.** This backend check proves that *native tmux scrollback repaints on reattach* only to the extent that tickets 15/17/19 have delivered a real by-target reattach path on the code as it stands when this ticket runs. If the project=session `new-window` reattach (tickets 15/19) has not yet landed and the code still reattaches via the legacy per-tile-session wrap, the pane-id/pid survival assertions still hold (the session survives detach either way under `-A`), and the sentinel is still visible via tmux's own repaint on `-A` reattach — but the "same window in a shared project session" claim is only as strong as the reattach path underneath. This check asserts what is true on the code present at run time and never fabricates the shared-session claim; the manifest records the actual `targetBefore`/`targetAfter` it measured.

### UX (visual gate + dogfood snippet)

**Visual gate.** The Component Lab is not the home for this check — there is no new UI component. The gate is a non-degenerate assertion on `runtime2.visibleText()`: the visible text must contain the sentinel marker string (e.g. `i8-sentinel-a7f3b1c2-pid-12345`). A check that only asserts `visibleText().count > 0` does not count; the assertion must name the sentinel.

**Dogfood snippet.** Open the app with at least one project zone. In a terminal tile, run:
```
echo "dogfood-$$" && sleep 9999
```
Wait for the output to appear. Then quit the app entirely (`Cmd-Q`). Wait two seconds. Reopen the app. The terminal tile must:
1. Reattach to the same tmux window — the `sleep 9999` process is still running (verify with `ps aux | grep sleep`).
2. Show `dogfood-<pid>` in the visible scrollback, where `<pid>` matches the running sleep process.

If either condition fails — the sleep process is gone, or the scrollback does not show the marker — this ticket is not done.

---

## Execution mode

This ticket is **needs-substrate** because the I8 acceptance contract cannot be proven without a real tmux daemon on the development machine. The session-survives-detach check (`has-session`), the pid-survival assertion (`#{pane_pid}`), and the scrollback-repaint verification all require a real tmux server and a real ghostty pty. An in-memory fake can verify the precedence rule and the scrollback chunking, but it cannot prove that native tmux scrollback actually repaints on a real surface after a real detach/reattach cycle. The dogfood snippet additionally requires human eyes to verify `sleep 9999` is still alive in the OS process table after the app restart.

---

## Done when

- [ ] This ticket adds **no new probe and no new fallback** to `restartTerminalTile`; it consumes ticket 17's `targetIsAlive` value and ticket 17's new-window branch. The only production code this ticket adds inside `restartTerminalTile` is the guarded `await replayScrollback(...)` call in ticket 17's dead/nil branch.
- [ ] The precedence rule holds: when `targetIsAlive == true`, `replayScrollback` is **never** called; when `targetIsAlive == false` and `descriptor.scrollback` is non-empty and `SessionResumeConfig.scrollbackEnabled` is true, `replayScrollback` **is** called with the persisted text.
- [ ] `replayScrollback` is an `async` function that writes in 4096-byte chunks with `await Task.yield()` (not `RunLoop.current.run`) between chunks and a trailing `\r\n`.
- [ ] `replayScrollback` is a no-op when called with an empty or nil string.
- [ ] `replayScrollback` is never called when `SessionResumeConfig.scrollbackEnabled` returns false.
- [ ] The deferred no-op comment at `TileSpawner.swift:354-355` is deleted.
- [ ] All four logic checks pass (precedence-follows-ticket-17-probe, chunk boundaries, scrollback guard, alive-target suppresses replay), each `await`ing the async paths.
- [ ] The real-path check (`reattachByTargetAndReplayScrollback`) passes with a manifest recording `pidBefore == pidAfter`, `targetBefore == targetAfter`, `cwdBefore == cwdAfter`, and `scrollbackVisible: true`, built with the existing local `run(tmuxPath, [...])`/`expect`/`pump` helpers — no fictional shared harness helper.
- [ ] The dogfood snippet passes: quit the app, reopen, the sentinel process is alive, scrollback shows the marker.
- [ ] No existing checks regress, including the existing tmux-live restart check (`TileSpawner.swift:~3500-3650`).

---

## Depends on / unblocks

This ticket depends on **ticket 15** (`docs/38-tickets/15-new-tile-new-window.md`) having shipped `tmuxWindowTarget` on `TerminalSessionDescriptor` (schema v3, `decodeIfPresent`) and the pre-create spawn path that captures it synchronously. Without a persisted target, there is nothing to probe and the branch collapses to the fallback.

It depends critically on **ticket 17** (`docs/38-tickets/17-dead-target-fallback.md`), which delivers the liveness probe (`await tmuxControl.isAlive(paneTarget:)`), the alive-vs-dead branch, the new-window fallback (`newWindow`/`newSession`) that this ticket replays into, and the **async** signature of `restartTerminalTile`. This ticket adds only replay onto ticket 17's dead/nil branch; it must not begin until ticket 17 is merged.

It depends on **ticket 12** (`docs/38-tickets/12-injectable-substrates.md`) for the `TmuxControl` protocol (whose `isAlive(paneTarget:)` is the only production probe) and `InMemoryTmuxControl` (which makes the logic checks deterministic). It depends on the private managed-agent session record for the host-local runtime payload that carries the window target across the restart boundary.

It unblocks the grouped-view session (de-mirror) work (`docs/38-tickets/27-grouped-view-session.md`), which can now assume the reattach-by-target path is proven. It unblocks the upgrade migration ticket (D25), which documents the one-time agent restart as a known exception to the nominal path proven here. And it unblocks Phase 2/3, which build on the assumption that a tile survives client teardown with its identity intact.

---

## Watch out for

**The alive-target branch must never replay stale scrollback.** When a session survives, the native tmux scrollback buffer contains everything that happened while the client was detached — output the persisted snapshot does not have. Injecting the snapshot on top of a live session would render it twice, out of order, mixed with the live output. The rule "replay only when `targetIsAlive == false`" is not optional. If ticket 17's probe is unreliable (network timeout on a remote host, flaky tmux response), ticket 17 already treats a failed probe as dead — which means this ticket replays the snapshot (safe under-replay) rather than skipping it (unsafe over-replay). That is the correct bias and it falls out of keying on ticket 17's value.

**Do not reinvent the probe.** The single most likely mistake is to write a fresh `tmux display -p` probe (or a `tmuxControl.run(arguments:)` call — a method that does not exist on the `TmuxControl` protocol) at a new insertion point. There is exactly one probe, `await tmuxControl.isAlive(paneTarget:)`, and it belongs to ticket 17. This ticket reads the boolean ticket 17 computed. If the code you are editing does not already have that probe, ticket 17 has not landed and this ticket cannot proceed.

**`replayScrollback` must be async and must not spin a run loop.** The enclosing `restartTerminalTile` is async (ticket 17) and `@MainActor`. Nesting `RunLoop.current.run(mode:before:)` inside it risks re-entrancy against the ghostty surface install. Yield with `await Task.yield()` (or a short `try? await Task.sleep`) instead.

**Scrollback chunk ordering must be preserved.** `data[offset..<end]` slicing must walk the data index strictly forward; any off-by-one will corrupt multi-byte UTF-8 at chunk boundaries. Slice `Data` by index with `data.index(offset, offsetBy: chunkSize, limitedBy: data.endIndex) ?? data.endIndex` exactly as shown — not on character boundaries. A chunk boundary that falls inside a multi-byte sequence renders a replacement character; the byte-index slice is safe because the emulator reassembles the stream across writes.

**The real-path check must not bypass `projectStore`, and must not assume helpers that do not exist.** Drive `TileSpawner.spawnTerminal` and `restartTerminalTile` through the real production path with a real `ProjectStore` on a temp directory; do not craft descriptors by hand. Build the check's helpers (`run`, `expect`, `pump`, `comparablePath`) locally in the check function, mirroring the existing tmux-live restart check — there is no shared `tmuxPaneState`/`tmuxHasSession`/global `pump` to call.

**Session name during the check.** The project-session naming may still use the legacy per-tile `continuum-<tileId>` naming if tickets 15/19 have not landed. Use `TmuxSession.sessionName(tileId:)` (legacy) or `TmuxSession.projectSessionName(projectId:)` (new) consistently — do not hardcode session-name strings. The `has-session` query and the `display -p` target must reference the same session the spawn path used.

**Pid survival depends on the pane process, not the shell.** `#{pane_pid}` gives the pid of the shell (or foreground process) the pane started with. If the sentinel is `sleep 9999`, the reported pid is the shell's, not sleep's, because sleep is a child. The correct sentinel for the pid assertion is `echo $$` (the shell's own pid); the dogfood `sleep 9999` is a long-running liveness sentinel that dies if the session dies, but the pid assertion in the check reads `#{pane_pid}`, which stays constant across teardown/reattach as long as the session survives.
