# s10 — Witness inventory for complaints A-D (zone drift/naming, agent home, tile/zone geometry, titlebar merge)

Cross-refs: s3-zone-project-binding.md (binding stores/writers/rebuilders),
s11-foreign-zone.md (unlanded foreign-zone hydration fix, port target for A),
s1-titlebar.md (titlebar merge status for D).

## 1. Relevant witness table

Flag | Asserts (outcome) | Production-driven? | Registered in matrix-inventory (479)?
---|---|---|---
`--zone-arming-check` (ZoneArmingChecks.swift) | Creating in zone B after arming zone B resolves project/Home/world-frame from B, not a stale zone A; a stale user pick doesn't outrank the armed zone | **Y** — drives `mountWorkspaceSceneAtBoot` explicitly (file header states this, "M1.10 rule") | Y
`--zone-unacquired-project-check` (ZoneUnacquiredProjectChecks.swift) | A zone whose project wasn't `.live` at boot still spawns into ITS OWN project (scope AND spawner AND persisted `.array/` path agree), not the active project's spawner | Y (boot mount + hydration reconcile) | Y
`--workspace-boot-persistence-check` (`AppDelegate.runWorkspaceBootPersistenceSelfCheck`) | Zone display name ("Review") and zone/tile membership survive a from-disk reload via `loadActiveWorkspaceDocument`+`zoneRenderModels`; empty-workspace boot doesn't drag in a foreign project | **N (b)** — calls `loadActiveWorkspaceDocument`/`zoneRenderModels`/`isolatedBootCanvasState` directly, never `mountWorkspaceSceneAtBoot` or `install(into:)` | Y
`--workspace-restart-fault-check` / `-child-check` | An actual child-process restart (persistence-crash-safe family) preserves workspace state across a real relaunch boundary | Y — spawns a real child process re-running boot | Y
`--workspace-switch-check` (`AppDelegate.runWorkspaceSwitchSelfCheck`) | Real `workspaceRuntime.switchWorkspace(to:)` in-process swap: 8 invariants incl. exclusive project ownership, no cross-workspace bleed | Y — calls the real `switchWorkspace(to:)` | Y
`--workspace-scene-owner-check`, `--workspace-runtime-install-check` | Scene-ownership/install plumbing generally (per s3) | mixed | Y
`--zone-autoname-check` (CanvasNSView) | First/second zone auto-names "Zone 1"/"Zone 2"; name Codable round-trips in memory | **N (b)** — builds a bare `CanvasNSView` directly, no boot mount, no disk write/reread | Y
`--zone-rename-inline-check` | Double-click-to-rename commits display name + `onZoneRenamed`; empty commit keeps old name | **N (b)** — same bare-view construction, single in-process session only | Y
`--zone-project-session-naming-check` | tmux session-name/kill-command derivation is per-project-id-unique (pure function, no UI/persistence) | N/A (unit-level) | Y
`--zone-hydration-lifecycle-check`, `--zone-save-isolation-check`, `--zone-lazy-resume-check`, `--zone-registry-refcount-check` | `ZoneRuntimeController` lifecycle: hydration ordering, per-zone save isolation, lazy resume, refcounted registry acquire/release | Y (via `ZoneRuntimeController`/`ZoneRuntimeRegistry`, same objects boot uses) | Y
`--ambient-tile-frame-space-check` (AmbientTileFrameSpaceChecks.swift) | Round trip: move a tile, relaunch, it is where you left it — WORLD-frame persistence through `onLayoutCommitted` wired in `mountWorkspaceSceneAtBoot` | **Y** — file header: "wired in `applicationDidFinishLaunching`… now wired in `mountWorkspaceSceneAtBoot` and this drives that mount" | Y
`--relationship-geometry-check` | Agent↔document connector paints on tile endpoints at non-zero camera pan/zoom (world-frame conversion correctness, not zone membership) | Y (real canvas/camera, no boot mount) | Y
`--zone-tile-detach-sweep-check` | A tile leaving the scene (e.g. workspace switch) has ALL 4 observer/subscription leaks torn down, not just event-subscription | Y (real `detach()`/supervisor wiring) | Y
`--zone-create-encloses-check` | At CREATE time: tiles geometrically inside the drag rect join the new zone; a tile outside stays bare; world position preserved on adopt | Y (real CanvasNSView mouse-event gesture) | Y
`--zone-breakout-check` | A member dragged past the edge (grace, then break-out distance) detaches; a bare tile dropped inside is adopted — MOVE-time membership, not creation-time | Y (real drag events) | Y
`--multi-zone-render-check` | Overlapping zones: hit-test resolves to the topmost render-model zone (paint-order correctness) — does **not** assert zones never overlap, it asserts correct behavior *given* an overlap | Y | Y
`--zone-adaptive-bounds-check` | Zone auto-grows/shrinks to fit member tiles; tile frames match expected geometry after adaptive resize | Y | Y
`--tile-world-bounds-check` | Content-inset/title-bar-vs-body sizing across zoom levels (layout correctness, unrelated to zone membership/drift) | Y | Y
`--managed-agent-model-spawn-check` (TileSpawner) | Model-catalog resolution/refusal on spawn (departed/partial model ids refused, not substituted); wiring order into `ManagedAgentTileNSView` | Y (real `TileSpawner.spawnManagedAgentForSelectedModel`) | Y
`--new-tile-cwd-check`, `--project-root-resolution-check`, `--project-picker-resolution-check` | New tile inherits correct working directory / project root resolution | Y | Y
`--file-tile-zoom-check` | "title compositor drift" — a title-bar/zoom-scale rendering measurement (KNOWN unowned red, see below) | Y | Y
`--session-resume-check` | Persisted session state (incl. a persisted browser URL) restores correctly after resume (KNOWN unowned red, see below) | Y | Y
`--agent-supervisor-check` | Agent process supervision lifecycle, incl. deliberate crash-witness subprocesses (KNOWN unowned red: SIGSEGV, see below) | Y (real subprocess) | Y

Titlebar merge (complaint D): **zero** flags in the enumerated list, zero source
hits for `titlebar`/`Titlebar` anywhere under `Sources/`. `--window-chrome-check`
exists only on the unmerged `array/topbar-merge` branch (61416361), never
reached array/integration, so it is absent from both the flag enumeration and
`matrix-inventory.txt` on this branch (per s1-titlebar.md).

No flag anywhere touches `ProjectHomePickerController`/`ProjectHomeSelection`
directly (the agent-tile-in-zone home selector UI). `--zone-arming-check`
covers *scope resolution* (which project a zone-spawned tile is stamped with)
but never opens/exercises the actual picker UI or its "inert until restart"
symptom.

## 2. Coverage map, complaints A–D

**A — zone names / zone↔project bindings revert after workspace switch or relaunch.**
- Covered: exclusive-ownership switch invariants (`--workspace-switch-check`),
  boot-time zone name/membership survival via re-derived state
  (`--workspace-boot-persistence-check`, checks-only), unacquired-project spawn
  correctness (`--zone-unacquired-project-check`), a real child-process
  relaunch fault path (`--workspace-restart-fault-check`/`-child-check`).
- Gap, **no witness**: the exact "revert after switch, come back after
  relaunch" round trip through the REAL `mountWorkspaceSceneAtBoot` — the boot
  witness that exists is checks-only (hazard 9b), and none of the switch/boot
  legs reproduce a *foreign* zone getting silently re-hydrated by
  `reconcileHydration()` between explicit switches (a distinct bug class from
  the switch-time filter). s11-foreign-zone.md's unlanded
  `--workspace-foreign-zone-hydration-check` is written specifically to close
  this gap and drives the real boot path — it is real, un-duplicated work sitting
  unmerged. Also no witness for `zoneScopeLabel`'s registry-miss fallback
  (silently shows "Needs Project" when Registry lookup misses even though the
  zone's own `projectId` is intact) — per s3, this is the single cheapest
  explanation for the reported symptom and has zero dedicated witness.
- Gap: "zone rename survives quit+relaunch" — `--zone-rename-inline-check` is
  single-session, in-memory only (checks-only, bare `CanvasNSView`); no leg
  writes a renamed zone to disk and reboots through the real path to reread it.

**B — agent tile born with blank project home; home selector inert until restart.**
- Covered (adjacent, not direct): `--zone-arming-check` proves the *scope*
  resolver picks the right project/Home for a zone-spawned tile once arming
  works; `--managed-agent-model-spawn-check` proves model-catalog resolution
  on spawn.
- Gap, **no witness at all**: nothing exercises `ProjectHomePickerController`/
  `ProjectHomeSelection` — no flag opens the picker, no flag asserts a home
  selector becomes interactive without an app restart, no flag asserts an
  agent tile spawned in a zone resolves a non-blank home end-to-end through
  the real spawn UI path. This is the sharpest of the four gaps: zero
  self-check touches the reported symptom's actual code (`ProjectHomePickerController.swift`).

**C — tiles inside zones shift after switch/over time; zones overlap; tiles
outside a zone rect remain members.**
- Covered: world-frame persistence round trip through the real
  `mountWorkspaceSceneAtBoot`-wired commit path (`--ambient-tile-frame-space-check`,
  the strongest witness of the four complaints — it is literally the
  "committed layout must survive a relaunch in the SAME place" defect, already
  fixed and driving production); creation-time enclosure/exclusion
  (`--zone-create-encloses-check`: outside tile stays bare, inside tiles join,
  world position preserved); move-time break-out/re-adopt
  (`--zone-breakout-check`); leak-free detach on workspace switch
  (`--zone-tile-detach-sweep-check`); adaptive zone resize geometry
  (`--zone-adaptive-bounds-check`).
- Gap: "tiles shift ... over time" (not just at relaunch) — the existing
  witness is a single commit→reload round trip, not a repeated
  switch-away/switch-back/idle-drift scenario; no leg asserts tile world
  frames are bit-identical after N consecutive workspace switches or after
  idle reconcile passes.
- Gap, **no witness that zones never overlap**: `--multi-zone-render-check`
  explicitly builds two OVERLAPPING zones and asserts correct *hit-test*
  behavior given the overlap — it treats overlap as a tolerated, decidable
  state rather than asserting the invariant "zones never overlap after boot/
  creation/move." No leg exercises zone-create or zone-move/resize against an
  existing zone's rect and asserts rejection or repositioning.
- Gap: "a tile outside a zone rect remains a member" is witnessed only at
  CREATE time (`--zone-create-encloses-check`) and at drag-time
  (`--zone-breakout-check`, grace + break-out distance). Neither covers a tile
  that ends up outside a zone rect through some OTHER path (e.g. the zone
  itself shrinking/resizing away from a stationary tile, or drift accumulated
  by the "shift over time" defect above) — `--zone-adaptive-bounds-check`
  covers the zone growing/shrinking to fit tiles, not a tile being left
  outside after the zone moves independently.

**D — window titlebar merge never landed.**
- No production witness exists on `array/integration`: zero `--*-check` flags
  and zero source occurrences of titlebar/`fullSizeContentView`/
  `titlebarAppearsTransparent` anywhere under `Sources/` on this branch.
- A complete witness (`--window-chrome-check`) exists and reportedly passes on
  the unmerged `array/topbar-merge` worktree (61416361), asserting content
  spans the frame, title hidden, top bar touches the frame top, split view
  starts where the bar ends, label clears traffic lights ≥12pt, fullscreen
  inset toggles — but it never runs against integration and is absent from
  `matrix-inventory.txt`/`run-matrix.sh` here. Per s1, the reviewer's own
  caveat was "no real fullscreen/window-drag/taste QA," so even landing the
  branch as-is would leave manual QA as the only witness for actual fullscreen
  and drag behavior.

## 3. Red legs table

**MATRIX_KNOWN_RED (documented, `scripts/run-matrix.sh`, 8 entries + 1 already-red build step):**

Leg | Reason (one line)
---|---
`--component-lab-check` | (listed, not detailed at top of array — pre-existing exempt leg)
`--ui-baseline-check` | display-dependent baseline leg, skippable via `CONTINUUM_SKIP_UI_BASELINES`
`--nav-mode-check` | pre-existing exempt leg
`--empty-workspace-creation-check` | Pre-existing since 0.7.17 release commit, reproduced byte-for-byte on a clean detached worktree; empty-workspace fixture omits an already-registered project from the palette, unrelated to this release's project-picker/palette code
`--palette-captures-keys-over-browser-check` | Pre-existing frontmost/focus fixture red since 0.7.17: note keeps focus while palette is open
`swift run ContinuumRevivedCoreChecks` | arm64 seed-1 canonical-byte baseline already 5 bytes behind clean 0.7.17 commit; no sync/materialize code touched this slice
`--perf-budget-zoom-check` | Zoom's chrome-refresh witness measures durationSlope; a ~2ms/step AppKit view-tree-traversal cost at 128 tiles isn't reachable without culling installed views (forbidden by always-render-live); published as an open target, not a regression
`--perf-budget-magnify-slope-check` | Inherited host-calibration red on macOS 26.6.1/SDK 26.5; exact release commit also fails 3/3; keep strict target until a display/OS-calibrated witness replaces the single-worst-sample alarm
`--perf-budget-gesture-transition-check` | Passes by ~4 microseconds at the top of its own spread on a quiet machine — a coin flip, not a fixed leg; stays listed until it has real headroom

**Nine unowned pre-existing reds** (from `.plans/66-release-0.7.21-nightly.md` gate result, 2026-09-22, 235 legs run, reproduced byte-for-byte on a clean detached worktree at the base commit `2cec73ff`):

Leg | Reason | Touches A–C?
---|---|---
`--agent-supervisor-check` | exit 139, SIGSEGV, reproduced both on candidate and clean base | Adjacent — agent lifecycle crash, not zone geometry, but a crashing supervisor mid-session plausibly explains "agent tile born blank" if the crash interrupts home resolution before it wires the record. Flagged by the ticket prompt explicitly.
`--note-click-focus-check` | `keyDown should edit note text; got ""` | No
`--agent-tile-click-focus-check` | `padding click alone should focus the editor` | No
`--workspace-api-open-check` | `capabilities from the preset grant` | No direct — workspace-api/MCP surface, not canvas geometry or zone binding, but ticket calls it out explicitly as touching workspace-api-open; no clear A–C link found beyond shared "workspace" naming
`--file-tile-zoom-check` | `title compositor drift; difference 2.439717294900222` — "identical to the digit," a rendering-scale/title-compositor measurement | **Yes — C**: this is exactly the "shift ... over time" drift family (title/zoom compositor positional drift), currently unowned and red
`--session-resume-check` | `A12 FAIL: browser URL must be the specific persisted URL` | **Yes — A/C adjacent**: a persisted-state resume mismatch is the same class of defect as "bindings revert after relaunch," though the concrete failure here is a browser tile's URL, not a zone name/binding
`--terminal-tmux-observer-check` | host toolchain: `ld: tapi error: malformed file`, macOS 27.0 SDK's `libSystem.B.tbd` has an unknown `arm64e.x1-macos` arch | No — host/toolchain damage
`--terminal-tmux-observer-wiring-check` | same linker failure | No — host/toolchain damage
`npm test --prefix Tools/TaskEditor` | `ERR_MODULE_NOT_FOUND: Cannot find package 'jsdom'` — missing dev dependency | No

Per CLAUDE.md's Verifying section, all nine are outside `MATRIX_KNOWN_RED` and
therefore currently unowned: "the gate has NINE failing legs that are not in
`MATRIX_KNOWN_RED` and that nobody owns... they should be triaged and either
fixed or documented in `MATRIX_KNOWN_RED` with a reason." Of the four
complaints, `--file-tile-zoom-check` is the most direct hit (C's drift), with
`--session-resume-check` and `--agent-supervisor-check` as plausible
contributors to A and B respectively; none of the nine bears on D (no titlebar
leg exists to be red).
