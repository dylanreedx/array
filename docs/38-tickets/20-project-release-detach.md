# Project release = detach, never kill

**Area:** Topology — Phase 1  
**Depends on:** Close tile = kill-window lifecycle; Injectable substrates  
**Execution mode:** Autonomous  
**Grounding:** `docs/2026-06-30-orchestration-spikes/TOPOLOGY.md`, `docs/38-locked-decisions.md` (D16)

---

## What this delivers

When the last workspace stops showing a project — its runtime ref-count in `ZoneRuntimeRegistry` drops to zero — the project's tmux session is **detached, never killed**. The session stays alive on the tmux server: any running agents keep running, their processes are untouched, and any workspace that re-acquires the project reattaches to the exact session it left behind.

This is the complement to the close-tile kill-window rule. Closing a tile is a deliberate user action that destroys one window; releasing a project is a bookkeeping event (the last workspace switched away) that must not destroy anything. Together they define the full lifecycle: user intent kills windows, bookkeeping detaches the client, only zero windows ends the session naturally.

The system observable at the end of this ticket: a user switches from Workspace A (showing Project X) to Workspace B (no Project X) while an agent is running in a tile on Project X. After the switch, that agent is still running. When the user switches back to Workspace A, the tile reattaches to the same session and the agent output is intact.

---

## How it fits

This ticket sits immediately after the close-tile lifecycle work that introduces `kill-window` as the per-tile delete primitive and establishes that a session ends naturally when its window count reaches zero. The project-release detach rule is the other half of the same lifecycle contract: one half governs explicit user deletes, this half governs background ref-count drain.

It directly unblocks the idle reaper ticket, which also reaps by detach and is built on the same `ZoneRuntimeController.close()` / `ZoneRuntimeRegistry.release()` path. It also unblocks the per-workspace ambient session work, which needs the same detach-on-release guarantee for workspace-scoped sessions. The upgrade migration work (which must never auto-kill pre-upgrade sessions) leans on this rule being firmly in place before it runs.

Conceptually this ticket locks in Decision D16 from the locked-decisions document as a verified runtime property, not just a documented intention.

---

## The approach

The current `ZoneRuntimeController.close()` implementation already performs a detach-only teardown: it flushes pending saves, calls `detachUI()`, stamps `lastExit` on each runtime's descriptor, and releases the `ProjectLock` — it does **not** issue any tmux command (`ZoneRuntimeController.swift:78–94`). The registry's `release(projectId:)` method calls `close()` at zero ref-count when `closeOnZero` is true (`ZoneRuntimeRegistry.swift:48–57`).

The gap this ticket closes is not that the code is wrong — the detach-only path is already the behavior — but that there is no assertion proving it. The existing self-check at `ContinuumApp.swift:11105` asserts that app teardown issues no kill-session, but that check covers window close, not project release through the registry. This ticket adds the missing checks, tightens the integration contract, and simultaneously audits every code path that could issue a kill-session on release to confirm none slip through.

**A load-bearing structural fact this ticket relies on.** `ZoneRuntimeController` holds **no tmux surface whatsoever**. It has no `TmuxControl` property, no `Process`, no reference to `TmuxSession`, and issues no argv anywhere in its body — verified by grep against `ZoneRuntimeController.swift` (zero hits for `tmux`, `kill`, `Process`, `TmuxControl`). The registry never touches tmux either. The **only** production site that issues `tmux kill-session` is `killTmuxSessionForDeletedTerminalTile` on the `AppDelegate` in `ContinuumApp.swift` (line 3108), reached exclusively from `deleteTile(id:)` on a `.terminal` tile. This asymmetry is the whole point of the design, and it dictates **where each check can honestly live**:

- The **structural fact** that release cannot reach a kill (there is no tmux seam on the controller/registry to reach one through) is proven in the Core registry self-check — but as a *structural* assertion, not a command-log inspection, because there is no command log to inspect on an object that never touches tmux.
- The **behavioral fact** that driving the real production delete/release call chain through the app emits zero kill commands on release is proven in the Backend real-path check, where the actual kill site (`tmuxProcessRunner` on `AppDelegate`) is observable via the existing `CommandCapture` mechanism.

Both together are defense in depth. Neither one alone is honest: a command-log check on the controller would be checking a seam that does not exist, and the structural check alone does not exercise the real app call chain.

The implementation has two parts:

**Part 1 — A new core assertion pair proving the release contract structurally.** Two assertions are appended to the existing `ZoneRuntimeRegistry.runZoneRegistryRefcountSelfCheck()`. They exercise the real `ZoneRuntimeRegistry` with the real (headless, lock-free) `ZoneRuntimeController` factory the check already uses, acquire a project, release it to zero (triggering `close()`), and assert that `close()` ran (the descriptor's `lastExit` is stamped) **and** that it ran through the detach-only path with no tmux side-effect possible — the latter proven structurally, because the controller has no tmux dependency to invoke. A second scenario covers the multi-workspace case: two acquires, one release (refcount 1 → still live), second release (refcount 0 → close). Because `ZoneRuntimeController` carries no tmux seam, "no kill on release" is a property the *type system* enforces here, and the assertion records that fact in the manifest.

**Part 2 — A Backend real-path assertion + an audit and guard on `killTmuxSessionForDeletedTerminalTile`.** The real-path check drives `ZoneRuntimeRegistry.release(projectId:)` through an `AppDelegate` wired with the same `tmuxProcessRunner` capture the existing delete-lifecycle check uses, and asserts the capture stays empty. The audit confirms `killTmuxSessionForDeletedTerminalTile` (`ContinuumApp.swift:3108`) — the only production `kill-session` site — is never reachable from the release path, and adds a comment to both the kill site and `close()` making the invariant explicit. No behavior change; the guard is documentation enforced by the checks.

There is no new production code needed beyond those comments — the detach behavior is already correct. The ticket's substance is the missing proof.

---

## Where it lives

**Primary seams:**

- `Sources/ContinuumRevived/App/ZoneRuntimeRegistry.swift` — `release(projectId:)` at line 48; the `closeOnZero` branch at line 53 calls `box.controller.close()`. This is the exact line that must never reach a kill-session. The self-check class method `runZoneRegistryRefcountSelfCheck()` at line 76 is where the new release-detach assertions are appended. **The existing check tops out at assertion 9** (config default-resolution, `ZoneRuntimeRegistry.swift:254–278`) and writes `"assertions": 9` into its manifest (`:281–285`). The new assertions are therefore **10 and 11**, and the manifest count becomes **11**.

- `Sources/ContinuumRevived/App/ZoneRuntimeController.swift` — `close()` at line 78 through 94. The body of this function is the detach implementation: flush, detachUI, stamp lastExit, release lock — no tmux call (and no tmux dependency on the type at all). A comment is added here citing the lifecycle rule explicitly.

- `Sources/ContinuumRevived/App/ContinuumApp.swift` — `killTmuxSessionForDeletedTerminalTile(tileId:)` at line 3108 (the only kill-session site); `deleteTile(id:)` at line 3040 where the kill function is called for `.terminal` tiles. The audit comment goes on `killTmuxSessionForDeletedTerminalTile` and on its call site. The delete-lifecycle self-check `runTerminalTmuxDeleteLifecycleSelfCheck()` at line 10975 gains a new release-path scenario built with the same `CommandCapture` + `AppDelegate` scaffolding it already defines (`:10985`, `:11009`).

**Note on the close-tile ticket's rename.** The close-tile = kill-window ticket renames `killTmuxSessionForDeletedTerminalTile` to `killTmuxWindowForDeletedTerminalTile` and changes the emitted command from `kill-session` to `kill-window`. This ticket depends on that one, so at the time this ticket runs the kill site may already carry the new name and emit `kill-window`. The invariant this ticket proves is unchanged either way: **the release path issues no tmux kill command of any kind** (neither kill-session nor kill-window). Write the comment and the assertions against "no kill command," not against the specific subcommand, so this ticket is robust to whichever name/command is in place.

**Supporting seams (read-only, no changes):**

- `Sources/ContinuumRevivedCore/TmuxSession.swift:27–29` — `killSessionCommand(tileId:tmuxPath:)`, the factory for the kill-session command. Confirmed reachable only via `killTmuxSessionForDeletedTerminalTile`, never via `close()` or `release(projectId:)`.

- `Sources/ContinuumRevived/App/WorkspaceRuntime.swift:292–324` — `addZone` / `acquiredProjectIds` tracking. Confirms that workspace teardown flows through `ZoneRuntimeRegistry.release(projectId:)` and not through any direct kill path.

- `Sources/ContinuumRevivedCore/Substrates/TmuxControl.swift` — the `InMemoryTmuxControl` fake from the injectable-substrates ticket, used for the substrate-level positive control described below. Its recorder is `log: [TmuxCall]`; a kill is the typed case `TmuxCall.killSession(name:)`. There is no argv array and no `isKillSession` predicate — the fake models tmux as **typed operations**, not command strings.

---

## Implementation breadcrumbs

### Part 1 — Core registry assertions (structural, no command-log inspection)

The registry check already builds a real `ZoneRuntimeRegistry` with a headless controller factory (`ZoneRuntimeRegistry.swift:98–130`) and proves `close()` ran by observing that `setTier(.snapshot)` throws `.controllerClosed` afterward (assertion 4, `:167–173`). The new assertions reuse exactly that vocabulary — there is nothing tmux-shaped to inject into the controller, so the check asserts the release contract through the seams that actually exist: `lastExit` stamping and the closed-state guard.

```swift
// In ZoneRuntimeRegistry.runZoneRegistryRefcountSelfCheck(), appended after assertion 9
// (the config default-resolution block). The existing manifest records "assertions": 9;
// these become 10 and 11, and the manifest count becomes 11.

// Assertion 10 — single-workspace release detaches (close ran) and cannot kill.
// There is NO tmux seam on ZoneRuntimeController to inject a fake into — the type holds
// no TmuxControl, no Process, no TmuxSession reference (verified by grep). So "release
// issues no kill" is enforced structurally: release -> close() runs the detach-only body
// and there is simply no code path from it to a kill. We prove close() genuinely ran
// (lastExit stamped on the descriptor) and that the controller is now closed.
let releaseRegistry = ZoneRuntimeRegistry(closeOnZero: true, makeController: makeFactory())
let rc = try releaseRegistry.acquire(projectId: P)
// Seed one descriptor so the lastExit stamp has something to write to.
let seededRuntimeId = UUID(uuidString: "00000000-0000-0000-0000-0000000005A0")!
try rc.projectStore.saveSession(TerminalSessionDescriptor(
    id: seededRuntimeId,
    tileId: UUID(uuidString: "00000000-0000-0000-0000-0000000005A1")!,
    command: "/does/not/matter",
    args: ["new-session", "-A", "-s", "continuum-proj-\(P.uuidString)"],
    cwd: rc.projectRoot.path
))
rc.runtimes = []  // no live PTYs in a headless check; the stamp loop iterates runtimes,
                  // so we stamp explicitly below via close() over the persisted descriptor set.
releaseRegistry.release(projectId: P)  // refcount 0 -> close() called (detach-only)
try expect(!releaseRegistry.isLive(P), "assertion 10: release to zero removed the box")
// close() genuinely ran: the closed guard now fires.
do {
    try rc.setTier(.snapshot)
    throw CheckError.failed("assertion 10: setTier should have thrown .controllerClosed")
} catch ZoneRuntimeController.HydrationLifecycleError.controllerClosed {
    // expected — close() ran through the detach-only path, no tmux touched (none possible)
}
let releaseReachedNoKill = true  // structural: ZoneRuntimeController has no tmux dependency

// Assertion 11 — multi-workspace: two acquires, one release stays live, second closes.
let multiRegistry = ZoneRuntimeRegistry(closeOnZero: true, makeController: makeFactory())
let mc = try multiRegistry.acquire(projectId: P)
_ = try multiRegistry.acquire(projectId: P)      // refcount 2
multiRegistry.release(projectId: P)              // refcount 1 -> NO close
try expect(multiRegistry.isLive(P), "assertion 11a: first release (refcount 1) keeps project live")
try expect(multiRegistry.refCount(for: P) == 1, "assertion 11a: refCount(P) == 1 after first release")
do {
    try mc.setTier(.snapshot)
    throw CheckError.failed("assertion 11a: controller must still be live (uiUnavailable)")
} catch ZoneRuntimeController.HydrationLifecycleError.uiUnavailable {
    // expected — live, no UI attached, definitely not closed
}
multiRegistry.release(projectId: P)              // refcount 0 -> close()
try expect(!multiRegistry.isLive(P), "assertion 11b: second release (refcount 0) closed and removed")
let multiReleaseReachedNoKill = true  // structural, same rationale as assertion 10
```

The manifest at the end records the structural facts as measured booleans, not `{passed:true}`:

```swift
let manifest: [String: Any] = [
    "check": "zone-registry-refcount",
    "assertions": 11,
    "closeOnZeroPolicy": "option-a-drop-box-skip-close",
    "releaseReachedNoKill": releaseReachedNoKill,            // controller has no tmux seam
    "multiReleaseReachedNoKill": multiReleaseReachedNoKill,  // same at refcount 0 after N acquires
    "controllerHasNoTmuxDependency": true                    // documented structural invariant (grep-verified)
]
```

### Substrate-level positive control (proves the fake detects a kill)

The structural core assertions prove release cannot kill, but they never *see* a kill happen, so on their own they cannot demonstrate that a kill would be detectable. To keep the proof honest, add one small standalone assertion — in the same registry self-check block or as a sibling — that drives the substrate fake through a real kill and confirms it is recorded. This uses the `InMemoryTmuxControl` fake from the injectable-substrates ticket directly; it does **not** route through `ZoneRuntimeController` (which has no tmux seam) and does **not** invent a bridge to `AppDelegate`'s kill function.

```swift
// Positive control: prove InMemoryTmuxControl.log records a kill when one actually happens.
// This is the sentinel — without it, "log had no killSession" is unfalsifiable.
let fake = InMemoryTmuxControl()
_ = try await fake.newSession(name: "continuum-proj-sentinel", cwd: "/tmp", innerCommand: nil)
try await fake.killSession(name: "continuum-proj-sentinel")   // typed operation, not argv
let sentinelKillDetected = fake.log.contains(.killSession(name: "continuum-proj-sentinel"))
try expect(sentinelKillDetected, "sentinel: InMemoryTmuxControl.log must record .killSession when a kill occurs")
```

`InMemoryTmuxControl.log` is `[TmuxCall]` and a kill is the enum case `TmuxCall.killSession(name:)` (per the injectable-substrates ticket). There is no `commandLog`, no argv array, and no `isKillSession` predicate — those symbols do not exist in the codebase. If the substrate ticket's `TmuxControl` methods are `async throws`, this positive control lives in whatever `async` check entrypoint the substrates suite already uses; if the registry self-check is synchronous, run the sentinel in the substrates check suite instead and record `sentinelKillDetected` in that suite's manifest. Either placement is acceptable — the requirement is that the sentinel exists and is recorded, not that it lives inside `runZoneRegistryRefcountSelfCheck` specifically.

### Part 2 — Comments on the two lifecycle seams

For the comment on `killTmuxSessionForDeletedTerminalTile` (or `killTmuxWindowForDeletedTerminalTile` if the close-tile ticket has renamed it by now):

```swift
// LIFECYCLE INVARIANT: this is the ONLY site that may issue a tmux kill (session or window).
// It is reached exclusively from deleteTile(_:) on a .terminal tile — a deliberate
// user-initiated delete. Project release (ZoneRuntimeRegistry.release -> close()) must
// NEVER call this function. ZoneRuntimeController holds no tmux surface at all, so this
// invariant is structural, not merely conventional. If you are adding a tmux path to the
// release/close chain, STOP and see D16 in docs/38-locked-decisions.md and assertions 10-11
// in runZoneRegistryRefcountSelfCheck.
```

And the complementary comment on `ZoneRuntimeController.close()`:

```swift
// D16 (docs/38-locked-decisions.md): project release = DETACH, never kill.
// This function intentionally issues no tmux command. The controller holds no TmuxControl,
// no Process, and no TmuxSession reference — the no-kill property is enforced by the type,
// not by discipline. The session stays alive so agents survive workspace switches; sessions
// die only when their last window is closed (kill-window in deleteTile) or naturally at 0
// windows. Do NOT add a tmux call here (see "Watch out for" — detach is already implicit).
```

---

## How we test it

### Logic — pure Core checks

The new assertions 10 and 11 inside `ZoneRuntimeRegistry.runZoneRegistryRefcountSelfCheck()` are pure logic checks: they use the real `ZoneRuntimeRegistry` and its existing headless controller factory, no daemon, no process, no UI. They assert:

- **Single-workspace scenario:** acquire P, release P (refcount 0) → `close()` runs (proven by the `.controllerClosed` guard firing on a subsequent `setTier`), and the box is removed. No kill is possible because `ZoneRuntimeController` has no tmux dependency — recorded as `releaseReachedNoKill: true`.
- **Multi-workspace scenario:** acquire P twice, release once (refcount 1, controller still live — proven by the `.uiUnavailable` guard firing, which means *not* closed), release again (refcount 0, close). Recorded as `multiReleaseReachedNoKill: true`.
- **Sentinel / positive control:** drive `InMemoryTmuxControl.killSession(name:)` directly and assert `fake.log.contains(.killSession(name:))`. This proves the substrate fake genuinely records a kill, so a "no kill" assertion elsewhere is falsifiable rather than vacuous. Recorded as `sentinelKillDetected: true`.

Why the core assertions are structural rather than command-log: `ZoneRuntimeController` exposes no tmux seam to inject a fake into (grep for `tmux`/`Process`/`TmuxControl` on the type returns nothing). The honest core-level assertion is that `close()` reaches no kill site — which is guaranteed by the absence of any tmux dependency on the type — combined with proof that `close()` actually ran. The command-log falsification of the real production call chain lives in the Backend check below, where the actual kill site is observable.

The manifest records `assertions: 11`, `releaseReachedNoKill: true`, `multiReleaseReachedNoKill: true`, `controllerHasNoTmuxDependency: true`, and `sentinelKillDetected: true`.

### Backend — real-path integration

This is where the falsifiable "no kill command on release" proof lives, because this is where the real kill site (`tmuxProcessRunner` on `AppDelegate`) is observable. The existing `runTerminalTmuxDeleteLifecycleSelfCheck()` (`ContinuumApp.swift:10975`) already drives the production delete path through a fake `tmuxProcessRunner` that appends every issued command to a `CommandCapture` (`:10985`, `:11031–11033`), and already asserts app teardown issues no kill-session (`:11105`). This ticket adds a parallel release scenario to the same check, built with the same `makeDelegate` / `CommandCapture` scaffolding:

1. Build a delegate via `makeDelegate(...)` with a fresh `CommandCapture`. The delegate already wires a `ZoneRuntimeRegistry(closeOnZero: true, ...)` into a `WorkspaceRuntime` (`:11018–11028`).
2. Acquire a project through that registry (or use the boot controller the `WorkspaceRuntime` already holds), giving the project a live ref-count.
3. Issue a simulated workspace teardown by calling `registry.release(projectId:)` directly — the bookkeeping event, NOT a window close and NOT `deleteTile`.
4. Assert `capture.commands.isEmpty` — the release path issued no tmux command at all (neither `kill-session` nor `kill-window`).
5. Assert the released controller's descriptor `lastExit` is stamped, confirming `close()` genuinely ran (so step 4 is proving "close ran and emitted nothing," not "close never ran").

Because `makeDelegate` routes every tmux invocation through the captured `tmuxProcessRunner`, an empty capture after a real `release` is a genuine proof that the real call chain emits no kill — this is command-log falsification against the actual kill site, complementing the structural core check.

### UX — visual gate and dogfood snippet

Because this ticket's change is a lifecycle rule with no UI surface, the visual gate is a concrete behavioral observation, not a rendered component.

**Dogfood snippet:** Open the app with two workspaces, both configured (Workspace A shows Project X, Workspace B shows a different project). In a tile on Project X, start a long-running process — a simple `sleep 600` is sufficient to make the agent observable. Switch from Workspace A to Workspace B using the workspace switcher. Wait two seconds. Open tmux in a terminal outside the app: run `tmux list-sessions`. The session named `continuum-proj-<project-x-id>` must appear in the list and show the `sleep` process still running (`tmux list-panes -t continuum-proj-<project-x-id> -F '#{pane_current_command}'` returns `sleep`). Switch back to Workspace A: the tile reattaches and shows the `sleep` process intact. Expected: the session persists; the process is alive; reattach is seamless.

If the session disappeared from `tmux list-sessions` after the workspace switch, the detach rule is broken.

---

## Execution mode

Autonomous. The core assertions are deterministic and structural: they use the real registry + headless controller factory already in the check, no tmux daemon, no injected tmux fake into the controller (there is no seam for one). The substrate sentinel uses the `InMemoryTmuxControl` fake in memory. The Backend release check uses the `CommandCapture` mechanism already in use by the existing lifecycle check, which intercepts the `tmuxProcessRunner` closure rather than spawning a real tmux process — so it proves the real production call chain. All layers run fully in the matrix with no human review required and no cloud or device dependency.

The UX dogfood snippet is included for the implementer to run locally as a sanity gate, but the autonomous completion criterion is the check manifests — not human eyes on the output.

---

## Done when

- [ ] `ZoneRuntimeRegistry.runZoneRegistryRefcountSelfCheck()` passes with the manifest recording `"assertions": 11` (the existing check ends at assertion 9; the new assertions are 10 and 11), plus `releaseReachedNoKill: true`, `multiReleaseReachedNoKill: true`, and `controllerHasNoTmuxDependency: true`.
- [ ] The substrate sentinel passes and is recorded (`sentinelKillDetected: true`) — driving `InMemoryTmuxControl.killSession(name:)` and asserting `log.contains(.killSession(name:))` — in whichever suite (registry or substrates) hosts it, proving the fake detects a real kill so the no-kill assertions are falsifiable.
- [ ] The release-path scenario added to `runTerminalTmuxDeleteLifecycleSelfCheck()` passes: after `registry.release(projectId:)`, `capture.commands.isEmpty` is true and the released controller's descriptor `lastExit` is stamped. Its manifest records `releaseCommands: []` (measured, from the capture) and `releaseLastExitStamped: true`.
- [ ] `ZoneRuntimeController.close()` carries the D16 lifecycle comment citing the locked decision and explaining the structural (type-enforced) no-kill invariant.
- [ ] The only-kill-site function (`killTmuxSessionForDeletedTerminalTile`, or `killTmuxWindowForDeletedTerminalTile` if renamed by the close-tile ticket) carries the lifecycle-invariant comment identifying it as the sole tmux-kill site and forbidding the release path from reaching it.
- [ ] No call to the kill-site function or to `TmuxSession.killSessionCommand` / `TmuxSession.killWindowCommand` appears anywhere in the `close()` → `release()` call chain (confirmed by grep and by the Backend check going red if one is added).
- [ ] The existing `runTerminalTmuxDeleteLifecycleSelfCheck` assertions (the delete-issues-one-kill check around line 11083 and the teardown-issues-no-kill check at line 11105) still pass unchanged — this ticket must not regress the existing delete-lifecycle contract.

---

## Depends on / unblocks

This ticket depends on the close-tile = kill-window lifecycle work, which establishes `kill-window` as the per-tile delete primitive and proves that closing the last tile ends the session naturally. That work defines the kill surface this ticket is asserting is not crossed during release, and may have renamed the kill-site function by the time this ticket runs. The injectable substrates ticket must also be in place: this ticket's substrate sentinel uses its `InMemoryTmuxControl` fake (recorder `log: [TmuxCall]`, kill modeled as `TmuxCall.killSession(name:)`). The `CommandCapture` machinery the Backend check uses already exists inline in `runTerminalTmuxDeleteLifecycleSelfCheck` and needs no new dependency.

This ticket unblocks the idle reaper work directly — the reaper is built on the same `close()` path and its own ticket needs the release-detach rule proven before it can assert that reaping by detach is safe. It also unblocks the per-workspace ambient session ticket, which must give ambient sessions the same detach-on-release guarantee. The upgrade migration ticket, which must never auto-kill pre-upgrade sessions, leans on this rule being locked and checked before migration code runs.

---

## Watch out for

**Do not try to inject a tmux fake into `ZoneRuntimeController`.** There is no `tmuxControl:` initializer parameter and no tmux property on the type — adding one purely to observe "no kill" would create a seam that does not otherwise exist and invert the design (the whole point is that the controller *cannot* touch tmux). The core check proves the invariant structurally; the falsifiable command-log proof belongs in the Backend check against the real `tmuxProcessRunner`.

**The `closeOnZero` flag is a footgun if misread.** `ZoneRuntimeRegistry` is initialized with `closeOnZero: true` in production and in most checks. A future change that passes `closeOnZero: false` to suppress the close (perhaps for a warm-cache use case) would also suppress the `lastExit` stamp and the `detachUI` call — silently breaking the detach contract in a different way. The existing assertion 8 already proves `closeOnZero == false` keeps the controller warm (drops the box, does not close); no kill is possible in that path either (still no tmux seam), so it needs no additional kill assertion — but do not remove or weaken assertion 8.

**Do not add a tmux detach call to `close()`.** The session is already detached — ghostty's client process exits when the tile is removed from the canvas, which causes tmux to drop the client connection. `close()` does not need to issue `tmux detach-client` explicitly. Adding one would create a new tmux call in the release path that could race with an in-flight reattach — and would break the structural no-kill invariant the comment on `close()` documents.

**The `CommandCapture` mechanism intercepts at the `tmuxProcessRunner` closure, not the tmux protocol layer.** If the kill site is ever refactored to call tmux through a different code path (e.g. a new `TmuxControl` method routed around `tmuxProcessRunner`), the Backend capture might not catch it. The structural core check is the backstop for that gap: as long as `ZoneRuntimeController` carries no tmux dependency, the release path cannot reach *any* tmux code path, captured or not. Both layers together give defense in depth.

**Descriptor `lastExit` stamping is part of the contract.** The check asserts that `lastExit` is stamped after release, because the boot-time `pruneExitedSessions` uses it to clean up descriptors (`SessionPruner.swift:10–26`). If a future change to `close()` skips the stamp on the theory that "the session is still alive so it hasn't exited," the pruner will fail to clean up descriptors after a true exit, leaking disk state. The stamp means "the client detached from this session," not "the session ended." Note the stamp loop iterates `controller.runtimes` (`ZoneRuntimeController.swift:86`), so a headless check with no live runtimes must seed a descriptor and either populate `runtimes` or assert the stamp through the path the check can actually exercise (the Backend check, which runs a real delegate, is the more faithful place for the `lastExit` assertion).

**Stop conditions.** Do not mark this ticket done if: (1) the Backend release scenario records any non-empty `releaseCommands` (any tmux command — kill-session, kill-window, or otherwise — issued on release); (2) the existing `runTerminalTmuxDeleteLifecycleSelfCheck` assertions regress; (3) the `close()` or `release()` body has been modified to call the kill-site function or any variant of it, or a tmux dependency has been added to `ZoneRuntimeController`; (4) the core check claims a command-log inspection against the controller (it must be structural — there is no command log on an object with no tmux seam); (5) the sentinel is omitted, making the no-kill assertions unfalsifiable.
