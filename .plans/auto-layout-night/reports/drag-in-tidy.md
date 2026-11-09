# Does a tidied zone stay tidy under everyday drags?

Date: 2026-11-09. Branch: array/aln-drag-in-tidy (local, not pushed).
Base: array/auto-layout-night 9f04a5ba (at 309cf255).

## Finding and fix

What was wrong: a latched swap of two tiles of different widths exchanged
their raw ORIGINS. With similar tiles that was exact. In a tidied zone,
where rows hold tiles of different widths at exact gap contact, it dropped
a wide tile on a narrow tile's origin, over its new neighbours, and left a
hole where the wide tile had been. Through real drags (tidied zone,
web1 652 wide, note1 324 wide, same row): web1 landed at 1084..1736, over
agent1, and agent1, pushed only partway by the live push cap, landed over
the terminal.

Why: `CanvasAutoLayoutEngine.solveMemberMove` → `arrange(.swap)` set the
displaced sibling to the mover's old origin and the mover's slot to the
sibling's origin, whatever their widths.

Fix (f7e5d97c), in the engine's swap only:
- `unequalSwapReflow`: when the widths differ, the two tiles trade ROW
  POSITIONS. The tiles after the exchanged place in each affected row shift
  by the width difference; each row keeps its own gap sequence; tiles
  before the place do not move; nothing is resized. Equal widths keep the
  exact origin exchange (it returns nil).
- Across rows, a row that gets longer may run past the content edge; the
  drop grows the zone as before and a tidy restores it.
- The live push budget no longer counts the exchange's own shifts. Counting
  them deferred every cross-row unequal swap forever: the latch never
  landed (found by the witness's "did the pair really exchange" check).
- One CoreChecks expectation pinned the raw exchange ("unequal tiles
  exchange origins"): it asserted the displaced tile at 376, under the
  mover's slot (108..448). Updated to the row-position exchange (456) and a
  new assertion on the mover's slot; its "the neighbour past both does not
  move" and "the zone keeps its size" assertions are unchanged and pass.

## Witness: --drag-in-tidy-check (real drags, NSApp.sendEvent)

Zone A1 rebuilt with eight mixed tiles (two browsers, a terminal, two
agents with real supervisor records, three notes), auto layout on, the
palette's Tidy Canvas first (fill 1.000). Real drags with the focus
monitor installed, a dwell before release, the pointer aimed at the target:
1. swap the wide browser onto a narrow note in its row;
2. swap a tile across rows;
3. slide a tile to its row's end;
4. drag a tile to the zone's right edge and back;
5. drop the wide browser half over a narrow neighbour with no latch.
After each drop: no overlaps; every tile inside the zone; no tile resized;
a same-row swap needs no zone growth; no tile above the zone; a named swap
really exchanged the pair; then Tidy restores fill ≥ 0.95. All pass; every
fill after tidy is 1.000.

Red before the fix (same witness, pointer aimed): the same-row swap left
web1 over agent1 and agent1 over the terminal.

## Trajectory probe: --jelly-trajectory-probe

Gains `runTidiedMixedTrajectories`: eight mixed tiles packed by
`CanvasTidyPacker` (app gap 8, padding 24, header 34), four swaps frame by
frame with the same TELEPORT rule over every tile, and each drop checked
for overlaps; plus an unlatched drop with the app's own pointer.

Before the fix (drops):
- web1 onto note1: slot (1084,358) → OVERLAP agent1/web1
- note1 onto web1: slot (424,358) → OVERLAP agent1/term, agent1/web1
- web1 across rows onto note3: past the content edge, and no reflow
- note1 across rows onto agent2: clean
After:
- web1 onto note1: slot (756,358) clean
- note1 onto web1: slot (424,358) clean
- web1 onto note3: clean, zone grows 378pt (the row got longer)
- note1 onto agent2: clean, zone grows 5pt
- unlatched drop of web1 over note1: settles home (424,358), inside
The original three-tile fixtures (also unequal widths, so now on the new
path) stay free of ORTHO/FLIP/TELEPORT/STUCK. Probe exit 0, 0 anomalies.
It is now registered in the matrix (it was not before).

## Not changed: the escape slot

With no latch, a tile dragged across a full cluster gets the magnet's
escape slot: the nearest free contact slot, shown as the drop ghost. In a
full tidied zone that slot can lie outside the zone. Seen once: web1
dropped 374pt above its row, and the zone grew upward, although its own
vacated slot was free. The drop is legal, the ghost shows where it will
land, and a tidy restores the fill, so this is a UX policy question, not a
bug: should the escape slot prefer the tile's own vacated place, or any
in-zone slot, before one that grows the zone? Left for Dylan.

## Checks (offscreen, isolated app support and TMUX_TMPDIR)

All exit 0: drag-in-tidy, jelly-auto-layout, tile-insert-slide,
canvas-pointer-path, tile-multiselect, tidy-zone-neighbours,
auto-layout-tidy-latency, tile-drag-grab, spawn-arrange-commit,
zone-move-unified, and the regression set (subagent-tile-zone, leader-jump,
tile-reveal-work, agent-local-file-link, canvas-zoom-momentum,
spawn-placement, spawn-sizing, auto-layout-fanout-app, zone-arming,
canvas-undo, layout-commit-scope). CoreChecks --jelly-trajectory-probe exit 0.
Full CoreChecks (isolated tmux): the jelly and auto-layout sections pass;
exit 1 only on the unrelated "bridge concurrency: turn completes" pi bridge
timeout seen on every branch tonight.

## Commits

- 23ea54a4 test(auto-layout): witness everyday drags in a tidied mixed zone
- f7e5d97c fix(auto-layout): swap tiles of different widths by row position
- 6293d018 test(auto-layout): register the drag-in-tidy leg and the trajectory probe
- 5f7f2c2a test(auto-layout): cover an unlatched drop over a neighbour in a tidied zone
