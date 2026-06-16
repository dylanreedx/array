# T09 — `switchWorkspace(to:)` in-process (retire relaunch) ⚠

Status: todo
Tag: overnight [appkit-checkable]
Depends on: T06 (WorkspaceRuntime shell) · Blocks: T16 (sidebar click-to-switch)

⚠ This is one of the two highest-risk steps (docs/23 S7). The fear is AppKit
stale-pointers / lost-firstResponder during the swap. **The mitigation is that the swap's
*correctness* is fully headless-checkable** — this task's check asserts the swap
invariants programmatically; only pure visuals (flicker, z-paint) are left for the
morning. Get the check exhaustive and this stops being scary.

## Goal
Switching workspace happens **in-process** — tear down the old workspace's zone layers +
runtimes, install the new workspace's, restore its viewport + focus — with **no app
relaunch**. Replaces `switchWorkspaceAndRelaunch` / `relaunchApplication`. Also: creating
a workspace opens a fresh empty canvas in place (not a relaunch).

## ⚠ ORCHESTRATOR CARRY-FORWARD (added mid-sprint from the T06 review — IN SCOPE for T09)
T06's `install()` (the shell) currently layers ALL zones — INCLUDING the active one — as `DescriptorTileNSView`s in `ZoneLayer`s, leaving the canvas's own `canvasState.tiles` empty ("shape B"). That was fine while `install` was dormant, but **T09 is the first task to call the swap for real**, so T09 MUST reconcile where the active zone's LIVE tiles live after a switch:
- After `switchWorkspace(to:)`, the target workspace's ACTIVE zone must present its tiles as the live, interactive canvas tiles the rest of the app expects (the ~71 `canvasState.tiles` read-sites + focus/hit-test), NOT descriptor-only layer tiles — OR adopt a deliberate, documented model where active-zone tiles live in a `ZoneLayer` with full interactivity. Pick one and make the swap honor it.
- Add a swap-invariant assertion that, after switching to workspace B, B's active-zone tile is a LIVE interactive tile (focusable via the broker AND hit-testable AND present where the app reads active tiles) — not a descriptor placeholder. This closes the T06 shape-B gap with a real guard.
If full reconciliation exceeds T09's scope, implement the swap with the active zone genuinely live, add the assertion, and flag any residual shape-B unification as needs-human — do NOT silently ship descriptor-only active tiles.

## Exact scope — files & symbols
- **`Sources/ContinuumRevived/App/WorkspaceRuntime.swift`** (created in T06) — implement
  `switchWorkspace(to workspaceId: UUID)`: flush current, compute the target's zone set,
  diff against live (release controllers via `ZoneRuntimeRegistry` ref-count, keeping
  shared projects that persist into the target — D4: offscreen shared-project zones
  demote to Snapshot), install the target's `ZoneLayer`s on the canvas (T05 API), load
  the target `WorkspaceDocument`, set viewport, re-establish focus.
- **`Sources/ContinuumRevived/App/ContinuumApp.swift`** — replace
  `switchWorkspaceAndRelaunch` (~:2942) call path with `workspaceRuntime.switchWorkspace`;
  fix `createWorkspace…` to open a new empty canvas in place; remove the
  `relaunchApplication` use for workspace switching (keep it only where genuinely needed,
  e.g. project root change if still required — note it, don't over-remove).
- **`Sources/ContinuumRevivedCore/`** — if any pure diff/demote planning helps, put it in
  a pure helper with its own table; keep AppKit out of Core.
- **Do NOT touch:** the 4 window-scoped NSEvent monitors (stay on AppDelegate, ADR-0024);
  `CanvasEngine` transforms; the leader nav.

## Data / API changes
`WorkspaceRuntime.switchWorkspace(to: UUID)` (async or sync per T06's shape). Internally
uses `ZoneRuntimeRegistry.acquire/release(projectId:)` and the mutable-canvas API from
T05 (`setZones` / `upsertZoneLayer` / `removeZoneLayer`). No new public types expected;
if you add a pure `WorkspaceSwitchPlan` (which controllers to release/keep/demote), give
it a Core table.

## The check, written FIRST (spec-as-test) — `--workspace-switch-check`
Register in `scripts/run-matrix.sh` + the `ContinuumApp.swift` arg dispatch. Build two
workspaces in memory (A and B) sharing one project P (so ref-count sharing is exercised)
and each with a unique project (Pa only in A, Pb only in B). Install A live, focus a tile
in A. Then call the **real** `workspaceRuntime.switchWorkspace(to: B)` and assert the
**swap invariants**:
1. **Layers:** the canvas's installed `ZoneLayer` set == B's zones exactly (A-only zones
   gone, B-only zones present, shared-P zone present).
2. **Focus scope:** `focusBroker.activeSurface` == B's expected surface (B's
   `lastActiveZone`'s `lastActiveTile`, else `.canvas`) — **not** a dangling A tile, not
   a stale modal.
3. **Adapter registration:** every A-only tile/zone focus adapter is **unregistered**
   from the broker; every B tile adapter is **registered**. (Probe via the broker:
   `requestFocus(.tile(aOnlyId))` returns false / focuses nothing; `.tile(bId)` succeeds.)
4. **Runtime ref-count:** P's `ZoneRuntimeController` is the **same instance** before and
   after (shared, not recreated); Pa's controller is **released** (ref-count 0 → closed);
   Pb's controller now **exists**. Assert via `ZoneRuntimeRegistry` introspection.
5. **Demotion:** if P also appears in A offscreen after the switch context, it's
   Snapshot, not torn down (D4) — assert tier.
6. **Viewport:** `canvas.viewport` == B's saved `WorkspaceDocument.viewport`.
7. **No relaunch:** a relaunch spy (inject a closure / flag in place of
   `relaunchApplication`) is **never called**.
8. **Round-trip:** switch back to A → A's tile focus + viewport restored; B-only adapters
   released. (Proves the swap is symmetric and leaves no residue.)
Plus a pure `WorkspaceSwitchPlan` table if you extracted one (which controllers
release/keep/demote for the A→B diff).

Run it → RED (no `switchWorkspace` yet, or relaunch still wired). Implement to GREEN.

## Implementation steps
1. Write `--workspace-switch-check` with all 8 invariants + register it → RED.
2. Implement `switchWorkspace(to:)`: `flushAll()` current → compute target zone set →
   `registry.release` departing project controllers (ref-count; demote shared per D4) →
   `registry.acquire` arriving ones → canvas `setZones(targetLayers)` (T05) → load target
   `WorkspaceDocument`, `setViewport` → re-establish focus to the target's
   last-active-tile (or canvas) via `focusBroker.enterScope`.
2b. Ensure broker adapter **unregister on layer removal** (T05's `removeZoneLayer` must
    unregister its tile/zone adapters) and **register on add** — assertion 3 depends on it.
3. Repoint `ContinuumApp` workspace-switch call sites to `workspaceRuntime.switchWorkspace`;
   replace `createWorkspace…Relaunch` with in-place new-empty-canvas; introduce the
   relaunch spy seam so the check can assert no-relaunch.
4. `swift build` → check GREEN → full `./scripts/run-matrix.sh` (NOT just --fast — this
   touches focus + persistence; run `--focus-broker-activation-check`,
   `--zone-save-isolation-check`, `--multi-zone-render-check`, `--zindex-relaunch-hit-test-check`).
5. **Stage for morning** (this is appkit-checkable but the *visual* swap still needs eyes):
   rebuild the bundle, leave a note for Dylan to watch for flicker / z-paint / cursor-rect
   correctness during a live switch. The commit can land (checks green) but flag the
   visual gate as pending in the task status.

## Acceptance criteria
- [ ] All 8 swap invariants asserted through the real `switchWorkspace` (no bypass).
- [ ] `switchWorkspaceAndRelaunch` / workspace-switch `relaunchApplication` path removed;
      relaunch spy proves it's not called.
- [ ] `createWorkspace` opens a fresh canvas in place.
- [ ] Shared-project controller is the same instance across the switch (ref-count works).
- [ ] Full matrix green; focus/save-isolation/zindex checks green.
- [ ] Morning visual gate noted as pending until Dylan confirms.

## Verification commands
```
swift build
P=$(mktemp -d); A=$(mktemp -d); CONTINUUM_PROJECT_ROOT=$P CONTINUUM_APP_SUPPORT=$A \
  .build/debug/continuum-revived --workspace-switch-check; rm -rf "$P" "$A"
./scripts/run-matrix.sh
```

## Review rubric
- **Bypass audit (critical):** the check must call `workspaceRuntime.switchWorkspace`, the
  REAL method the sidebar/⌘K will call — not a hand-assembled teardown. If it stubs the
  swap, REWORK.
- **Focus invariant is the bug-magnet** — assertion 2+3 must actually probe the broker
  (re-`requestFocus` an A-only id and see it fail), not just read a stored field that the
  swap might set without truly re-registering adapters.
- **Ref-count correctness:** confirm shared-P controller identity is asserted by
  *instance* (`===`), and Pa's controller `close()`/release was actually invoked (spy or
  registry count == 0), not just "removed from a dict."
- **No-relaunch** is proven by a spy, not by absence of a crash.
- Symmetric round-trip (assertion 8) present — a one-way check hides residue leaks.
- Morning note lists the visual items to eyeball.

## Out of scope / gotchas
- Lock degradation on acquire failure = S9 (stretch); here, an acquire failure may
  surface as a degraded/cold tier but full degradation UX is deferred.
- Viewport-driven tier transitions on pan/zoom = T10; here only the post-switch viewport
  + initial tiers matter.
- The sidebar that *calls* switchWorkspace = T16; ⌘K already has a switch row to repoint.
- Keep the 4 global monitors on AppDelegate; do not move them into WorkspaceRuntime.
