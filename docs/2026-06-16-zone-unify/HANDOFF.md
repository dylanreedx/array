# Zone Unification — Handoff (2026-06-16)

Branch: **`overnight/workspaces-zones`** · tip **`89c8d9b`** · **not merged to `main`**.
Plan (design + phases): `~/.claude/plans/deep-puzzling-quill.md`.
This session reworked how zones behave so they're real containers you can
create / move / resize / fill / empty / close. 10 commits, each RED-first +
matrix-gated + dogfooded.

---

## 1. What we built (the commit spine)

| Commit | What |
|---|---|
| `52eff49` | **P0** unified live model: `liveZones` + `tileZoneMembership` index on `CanvasNSView`, seeded at boot; chrome/lookup routed through it (parity step) |
| `cb494a6` | **P1** move a zone via the mutable model → no snap-back; hit-test/layout unified |
| `8b06c3c` | **P2** create registers a live zone (not a ZoneLayer) + adopts enclosed tiles → no orphaned/unclickable tiles |
| `e552887` | **correctness**: members store **world frames**, membership is a pure overlay tag (project canvas stays valid on reload); move translates members explicitly |
| `d41074e` | persist member positions after a zone move |
| `73a70a4` | **P3** stable **stored** zone frame → move works (grab == visible chrome), moving a tile inside doesn't reshape, resizing a tile grows the zone |
| `9363cf0` | **P4** break a tile out (drag far past the edge → bare) + adopt on drop (drag a tile in) |
| `da2445e` | **P5** close a zone via the ✕ → Keep/Delete (project zones never delete their tiles) |
| `d19c536` | **z-order fix**: zone chrome paints **behind** its tiles (was painting over them) |
| `89c8d9b` | resize a zone by its **edges/corners** like a tile; members stay put |

Net interaction model now works end-to-end: **create · move · resize · add-tile
(drag in) · break-out (drag out) · close (keep/delete)**.

---

## 2. The architecture (the decisions that matter)

**The problem we found:** the app had **three** zone representations and the live
app ran on the two weak ones —
- `activeZone` (single project zone, tiles rendered through it),
- `zoneRenderModels` (persisted, immutable → "move" snap-backed),
- `ZoneLayer` (mutable, works, but its own `tileViews` hold non-interactive
  `DescriptorTileNSView` placeholders, disjoint from the real tile views).

The live bugs (can't move, create orphans tiles) came from that split.

**The fix — a surgical unification, NOT a rewrite:**
- A **single live model on `CanvasNSView`**: `liveZones: [ZonePlacement]` (mutable
  source of truth) + `tileZoneMembership: [UUID: UUID]` (tileId → zoneId; absent =
  bare) + `zoneDisplayByZoneId` (chrome metadata). The one physical tile store
  (`canvasState.tiles` + the one `tileViews` dict) is untouched.
- **Tiles store WORLD frames.** Membership is a pure overlay tag — moving a zone
  translates members' world frames explicitly; resizing a zone does NOT move them.
  (We briefly tried zone-local frames; it corrupts the project canvas on reload —
  see commit `e552887`. Don't go back to zone-local.)
- **Zones render at their STORED frame** (placement), not an adaptive hug. This is
  what makes the visible chrome == the move-grab rect (so move works) and keeps the
  size the user drew (room for tiles). Resizing a *tile* past the edge grows the
  zone; moving a tile inside doesn't.
- **The keystone (`ZoneLayer` / `setZones` / `WorkspaceRuntime`) is deliberately
  untouched** — it's the dormant multi-project future (T20) and drives ~8 matrix
  checks. The live gestures operate on `liveZones`; `zoneLayers` stays empty in the
  live app. Don't "retire" it.

**Coordinate facts:** world coords Y-down, top-left origin. The active project zone
is pinned to origin (0,0) (`DefaultWorkspaceMigration`), so world == that zone's
local — that's why the world-frame switch was behavior-neutral for existing data.

---

## 3. How we worked (the method — keep doing this)

Per-phase loop, every time:
1. **Write the named real-path check FIRST**, run it, watch it go **RED**. The
   check synthesizes real `NSEvent`s through `CanvasNSView.mouseDown/Dragged/Up`
   (or tile/chrome clicks) and asserts observable model/render/hit-test state.
   **No calling executors directly** — a bypass counts as no check.
2. Implement the minimum to **GREEN**.
3. `./scripts/run-matrix.sh --fast` green + `swift build` clean.
4. **Commit** (plain `type(scope): summary`, no co-author footer).
5. Rebuild the release bundle + dogfood; fold feedback into the next phase.

When a check passed before I'd shown it RED (fix-first), I did a quick
**RED demo** — temporarily neuter the fix, confirm the check fails, restore — so
every guard is proven non-vacuous (see the move + z-order checks).

The **regression that wasn't caught** (chrome-over-tiles) taught the lesson: checks
asserted *frames and hit-test* but not *paint order*. We added
`--zone-chrome-zorder-check` (subview-index comparison) to close that gap. When a
visual bug slips through, add the check that would've caught it.

---

## 4. The checks (17 zone entries in `scripts/run-matrix.sh`)

New this session (run any with `.build/debug/continuum-revived --<name>`):
`--unified-model-boot-check` · `--zone-move-unified-check` ·
`--zone-create-encloses-check` · `--zone-breakout-check` ·
`--zone-close-keep-delete-check` · `--zone-chrome-zorder-check` ·
`--zone-resize-check`. Repurposed: `--zone-adaptive-bounds-check` now tests the
**stable-frame** spec (move = no reshape, resize = grow). All check functions live
in `CanvasNSView.swift` as `static func run…SelfCheck()`; dispatch is in
`ContinuumApp.swift` (search the `--…-check` blocks).

---

## 5. Tips for context (gotchas)

- **Stale SourceKit diagnostics are NOISE.** You'll constantly see "Cannot find
  ZoneBoundsConfig / WorkspaceRuntime", "ZonePlacement has no member navKey",
  "CanvasEngine has no member zone", a bogus "Duration → Double". `swift build` is
  authoritative — it builds clean. Don't chase these. A *real* error shows up in
  `swift build` output (e.g. the `touchesLeft is inaccessible` cross-module one we
  hit was real; `ResizeEdge.touches*` are `internal` to Core — compute locally).
- **The full matrix is flaky under load.** Three different *timing* checks flaked
  across runs (control-file, terminal-snapshot timeout, a git-probe SIGTERM that hit
  657s) — all environmental (concurrent builds + the open app starving the box),
  none zone-related. When the matrix fails, check *which* check: if it's a zone
  check, it's real; if it's a timing/terminal/git-probe check, re-run or verify the
  zone suite directly (they're deterministic).
- **`CanvasNSView.swift` is huge** (~7k lines) and holds the canvas, the gestures,
  `ZoneChromeNSView`, and ALL the self-checks. Grep by symbol; don't read top-down.
- **Zone chrome is hit-transparent** (`hitTest` returns nil) — the **canvas** owns
  every zone click. That's why move/resize/close are detected in
  `CanvasNSView.mouseDown` (close-button → resize-edge → header-move → create),
  not in the chrome view.
- **macOS has no GNU `timeout`** (EXIT 127). Headless checks must drive NSEvents
  **synchronously** and `Foundation.exit` — never spin a run loop, never
  `NSAlert.runModal` in a check (inject the decision instead). A prior sidebar check
  hung the matrix this way (T16).

---

## 6. Open items / next steps

1. **Relaunch persists positions but NOT grouping.** Membership is in-session only.
   Follow-up: persist group-zone members to `WorkspaceDocument.groupZoneTiles` (or a
   tileId→zoneId map) + reload at boot so memberships survive a restart.
2. **Project-zone box visibility (undecided).** Your persisted workspace has one
   project zone (`49C85E84`, 1280×800, blue) that now renders as a big background
   box. Decide: hide project-zone chrome in the live app (only group zones you draw
   are visible — recommended for now) vs keep it as a project frame. If hidden, mind
   `--multi-zone-render-check` (it asserts a project zone *does* render chrome for
   the T20 future).
3. **Spawn-into-zone:** ⌘T spawns a bare tile; it doesn't auto-join the zone under
   it. Could wire spawn placement to adopt into the zone at the spawn point.
4. **Keep/Delete is a plain `NSAlert`** — fine for now; could be a nicer sheet.
5. **T20 / session-bundle bridge** remain the dormant multi-project keystone work
   (separate from this) — see `docs/2026-06-15-overnight-sprint-workspaces/`.

---

## 7. Key files
- `Sources/ContinuumRevived/Canvas/CanvasNSView.swift` — the live model
  (`liveZones`/`tileZoneMembership`), all gestures (mouseDown/Dragged/Up zone
  classification), `closeZone`/`reevaluateZoneMembership`/`growZoneToFitMembers`/
  `resizedZonePlacement`, `ZoneChromeNSView`, and every `run…SelfCheck`.
- `Sources/ContinuumRevived/Canvas/TileNSView.swift` — tile move/resize; calls
  `updateTile(recalculateZoneBounds:)` (false on move) + `reevaluateZoneMembership`.
- `Sources/ContinuumRevived/App/ContinuumApp.swift` — boot wiring (`onZoneCreated/
  Moved/CloseRequested/Closed`), `persistCreatedGroupZone/persistMovedZone/
  persistClosedZone/presentZoneCloseConfirm`, and the `--…-check` dispatch.
- `Sources/ContinuumRevivedCore/ZoneBreakoutConfig.swift` (new) · `ZoneGestureConfig`
  · `ZoneBoundsConfig` · `CanvasEngine` (`zone(draggedByScreenDelta:)`, `worldFrame`,
  `tileScreenFrame`, `ResizeEdge`).
- `scripts/run-matrix.sh` — check registry (`--fast` for the quick gate).
