# Auto layout night: tidy that fills the zone

Date: 2026-11-09, overnight. Branch `array/auto-layout-night`, local only,
built on `array/spawn-framing-release` and its regression fixes. The lead is
F6CD3569, with three Claude helpers. Board card: "Tidy fills the zone, fast,
with proper tile shapes" (79EE3C01). The card's comments are the night's full
history.

Status at the time of writing: DRAFT, updated as streams land. The final
version comes with the morning build.

## What Dylan asked for

"i want proper tidying to work, it is laggy and delayed, it should fill as much
of the zone as possible even with leniency with growing the zone if needed,
resizing tiles (browser tiles 16:9 … terminals more vertical …) general
performance feel and practicality."

## What changed

1. **Tidy fills the zone, and big tiles stay big.** The old tidy closed gaps
   and then shrank the zone around the result. It never resized a tile, so a
   messy zone stayed full of holes. Tidy is now `CanvasTidyPacker`, a
   deterministic packer.
   - Tiles are grouped by size into rows that fill the zone's width.
   - A tile much bigger than the rest gets a column that spans several rows,
     so it stays the biggest.
   - Each tile stays within 0.5–2.0× its current area, and is shaped by its
     kind.
   - **The zone keeps its width** and changes only its height. The one
     exception: when keeping the width would stretch tiles past 2.56×, the
     zone narrows in proportion. It never widens.
   - A second tidy changes nothing.
   - Reading order is not kept; size grouping wins.
2. **Each kind has a shape** (`TileGeometry.shapeRule`, table below). Tidy and
   creation use the same rule, so a new tile is born in the shape tidy would
   give it.
3. **A lead and its helpers stay one block.** The lead keeps its agent shape.
   Its helpers stack in a column on its right, as tall as the lead, at equal
   heights. Two columns past four helpers.
4. **New tiles start in their tidy shape and fit the zone.** In an auto-layout
   zone a new tile takes the largest of its default, 7/8 or 3/4 size that fits.
   It no longer lands past the edge and grows the zone.
5. **Tidy starts moving sooner.**
   - The canvas write now runs after the first animation frame is on screen,
     not before it.
   - Tiles that only moved no longer redraw their title or body.
   - The solve is about 10× faster than the first version.
   - The layout save loads and writes only the projects whose tiles changed.
6. **Sizes animate with the move.** A resized tile's layer grows from its old
   size over the same 110 ms ease-out as its slide, and the zone outline morphs
   alongside. Nothing is stretched, no picture stands in for a tile, and
   nothing is re-laid out per frame.
7. **⌥⌘T tidies the current zone.** It is a registered command you can rebind,
   and it shows on its ⌘K row. It skips the ~120 ms the zone menu spends
   blinking and fading before AppKit fires the action.
8. **A zone that tidy grows pushes its neighbours clear.** Neighbouring zones
   move as rigid bodies, carrying their tiles, and nothing changes zone. Before
   this fix, a grown zone was left lying over the zone it grew into, with auto
   layout either on or off. Undo restores everything. Witness:
   `--tidy-zone-neighbours-check`.
9. **The undo toast after a tidy** hugs its message and stays clear of the
   floating toolbar, whichever edge it sits on, and of the shortcut rail.
   Before, it stretched across the whole canvas.

## Shape rule for each kind (width / height of the whole tile)

| Kind | Rule | Size at creation |
|---|---|---|
| Browser | exactly 16:9 | 1024×576 |
| Terminal | 0.6–0.9 (taller than wide) | 720×804 (80×39 cells) |
| Agent (a lead, or on its own) | 0.6–1.0 | 576×640 |
| Helper agent | its column, 0.9–2.6 | 576×316 (half its lead) |
| Note, file, diff | its own ratio, held to 0.75–1.8 | unchanged |
| File tree, run artifacts | its own ratio, held to 0.6–1.8 | unchanged |
| Inspector, queues, kanban | its own ratio, held to 0.8–2.0 | unchanged |
| iOS preview, shared tiles | never reshaped, only moved | unchanged |

Area limits:
- Tidy scales tiles to between 0.6× and 1.6× of their current area on
  average.
- One tile may stretch to at most 2.56× (a soft cap). Without that cap, a lone
  browser stretched to 7× across a wide zone.

## Measured

**Fill** is tile area divided by the zone's content area.
- On the seeded zones (`--tidy-packer-check`): 32–80% before, 96–99% after.
- In the real app, on the eight-tile film zone: 98%.
- On Dylan's real canvas, five zones tidied offline from read-only copies: 15–56%
  before, 97–99% after.
  - Every tile stays within 0.5–2.0×.
  - The agents he made big stay the biggest after tidy: 2.79× the next tile in
    one zone, 1.34× in another.
  - A second tidy changes nothing.
  - 89 tiles take about 22 ms to solve (debug build).

**Latency from trigger to first movement.** This uses the production mount
with menu dispatch, in a debug build on a loaded Mac
(`--auto-layout-tidy-latency-check`).

| | Before tonight | After |
|---|---|---|
| Tidy, 30 tiles | 34 ms | 27 ms |
| Tidy, 89 tiles, all in view | 145 ms | 90 ms |
| Tidy, 89 tiles, camera on 12 | 95–101 ms (night, before the deferral) | 62–72 ms |
| Drag release, 89 tiles | 37 ms | 17 ms |

At 89 tiles the solve is 13 ms. Most of the rest is AppKit laying out and
redrawing the scroll views of every resized tile once. That cost comes with
resizing at all, and it is smaller in release builds.

Tiles far off screen are now left parked when tidy resizes them. Each comes
back laid out once, at its new size, before it comes into view. With 12 of 89
tiles in view, a tidy lays out 37 tile bodies before moving instead of 89.
Terminals and browsers cannot park (Ghostty surface, WKWebView), so an
off-screen one still resizes in the commit. Witness:
`--tidy-offscreen-defer-check`.

**Real app, filmed at 60 fps:**
- About 130 ms passed between the menu click and the first tile movement, and
  almost all of it was the zone menu's own blink and fade before AppKit sends
  the action. AppKit spends a further 26–35 ms inside its menu code. ⌥⌘T
  avoids both.
- Before tonight's fixes, the tiles slid for 110 ms. Sizes now animate together
  with the move.

**Layout save:** a move in one project reads 2 store files where it used to read
4, 8 or 23 (with 1, 5 or 20 extra projects in the workspace).

## Films

All in `~/Movies/Array/auto-layout-night/`.
- `tidy-before.mov` and `tidy-after.mov`, each with an end frame (`-end.png`)
  and its `canvas.json`. Both are real-app window-server captures of the same
  messy eight-tile zone. Each film app ran with its own bundle id and
  app-support folder.
- `real-canvas/`: before and after pictures of tidy on each of Dylan's real
  zones, plus `table.md`.

## Tried and rejected

- **"Any exact fill beats any zone change":** a lone browser grew to 7× its area.
- **Shrinking an oversized zone in height only, or width only:** that made a
  one-row strip or a tall column. It now shrinks in proportion.
- **A helper column width worked out from the lead's current height:** a second
  tidy then moved tiles by 1/32 pt.
- **Snapping the first tile of an empty zone to the zone's edge:** it broke the
  rule that a new tile appears centred where you're looking.
- **Raising the terminal cap to 1.0:** terminals would become square, and Dylan
  asked for vertical.
- **Committing the motion before the resized content is laid out:** it would
  start about 60 ms sooner at 89 tiles, but content would pop mid-motion,
  which is a visible picture swap.
- **Featured bands within strict reading order (a big tile spans 2–3 rows)
  with a hard per-tile limit of 0.5–2.0×:** this cannot fill Dylan's two most
  mixed zones, where tiles of 333k–2.8M pt² sit side by side in reading order.
  Grouping by size solved it. The code is kept off this branch on
  `array/aln-tidy-engine` (`64a67ce5`).
- **The first masonry round changed the zone's width:** a wide two-tile zone
  became a tall stack. Rejected; the width belongs to the user.

## Open questions for Dylan

1. **Big tiles stay big, and reading order goes.** The first packer made a
   clean uniform grid but shrank your big agents to 0.29×. I chose the
   size-grouped packer instead. It keeps them biggest, at the cost of
   reading order. If you'd rather have the uniform grid, the earlier
   behaviour is in history at `3ade43f7`.
2. **A zone can shrink rather than stretch its tiles.** In the film zone, the
   height went from 1480 to 1084, because browsers at a fixed 16:9 allow only a
   few row layouts. Is shrinking acceptable, or should tidy keep the zone's
   height and leave a strip empty?
3. **Should tidy also run on its own** (after a close or a spawn), or stay an
   explicit action? It stays explicit tonight.
4. **Holding ⌥ alone past the nav-leader delay** before pressing ⌘ opens the
   leader first. The existing ⌥⌘R has the same race.
5. **The website demo** (`website/src/components/demo/command/CommandCenter.tsx`)
   still describes "Tidy canvas" with the old wording. The site deploys from
   main, so it was left alone.

## Also found tonight

- **Dragging a tile out of its zone.** Since the 2026-10-11 mount fix, a
  project's tile had to live inside one of its zones, so a tile dropped outside
  was pulled back in. The fix is built and green on `array/bare-tiles`: a
  per-project set of bare tiles, kept separate. Its witness is
  `--bare-tile-check`. It needs a daylight review before any merge. Card
  516DB43F.
- **The base carried 5 regressions**, found by the release matrix. The spawn lead
  fixed them (`cf86ae08`, `0d5187d1`, `507d1365`, `8675b50a`, `9e5d2b0a`,
  `e7ad51a3`), and all five pass on this branch.
- **Capture runs and the Documents prompt.** `ARRAY_SKIP_USER_GHOSTTY_CONFIG=1`
  (`8a6eae35`) lets capture runs skip the Ghostty config, which links into
  `~/Documents`. A Documents prompt still appeared once, probably when the
  palette checked CLI configs. It was dismissed without being answered.
- **Outage.** Every Claude agent failed from about 06:56Z to 08:20Z, about 80
  minutes lost. Work resumed cleanly.

## Checks run

Targeted only. There was no full matrix tonight, because a release had the
machine. Every run used a debug build, its own app-support dir and its own
tmux namespace.

- **CoreChecks:** `--tidy-packer-check`, `--layout-pressure-check`,
  `--jelly-trajectory-probe` (no ORTHO, FLIP, TELEPORT or STUCK flags),
  `--auto-layout-fanout-check`.
- **App checks:**
  - tidy and layout: `--auto-layout-fanout-app-check`,
    `--jelly-auto-layout-check`, `--zone-arming-check`, `--canvas-undo-check`,
    `--undo-toast-placement-check`, `--layout-commit-scope-check`,
    `--auto-layout-tidy-latency-check`, `--tidy-zone-shortcut-check`,
    `--workspace-scene-owner-check`, `--tidy-zone-neighbours-check`,
    `--tidy-offscreen-defer-check`;
  - spawn: `--spawn-sizing-check`, `--spawn-placement-check`,
    `--spawn-framing-check`;
  - the former regressions: `--subagent-tile-zone-check`,
    `--leader-jump-check`, `--tile-reveal-work-check`,
    `--agent-local-file-link-check`, `--canvas-zoom-momentum-check`.
- **Known to fail before tonight, not from this work:**
  - `--agent-tile-click-focus-check`, which fails the same way on untouched
    `c476ced9`;
  - `--tile-surface-residency-check` ("flag off must still pay the native
    cascade"), which fails the same way on base `f52c85bb`, with this change
    reverted and with the display awake. It needs an owner.

## Stream reports

`reports/tidy-engine.md`, `reports/tidy-latency.md`, `reports/spawn-sizing.md`,
`reports/persist-scope.md`, `reports/zone-growth.md`, `reports/offscreen-defer.md`, `reports/tidy-masonry.md`. Bare tiles: `reports/bare-tiles.md` on
`array/bare-tiles`.
