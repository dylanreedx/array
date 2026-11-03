# 107 · Auto layout that fans out instead of lining up

Status: research and prototype, 2026-10-30. Nothing here is landed or meant
for 0.7.35. Bench: `.worktrees/auto-layout-fanout`, branch
`array/auto-layout-fanout` (from `array/release-0735`).

Dylan's report, verbatim: "for some reason they all want to go in a straight
line to the right and it is so hard to make a coherent layout… there is so
much flickering and 'false jumps' and swaps when moving a tile… it breaks the
ENTIRE layout often, which should not happen… we need to figure out a proper
way to fan out and grow agent tiles in a controllable manner… lead agent
tiles? factor in size? scale?"

## Built: model B, lead clusters (2026-10-30, on top of A)

A lead agent and its helper agents' tiles form a cluster, read from the real
agent records (`parentAgentID`), never guessed from geometry.

- **Size-aware helpers.** Under auto layout a helper opens at its lead's
  width and half its height (never below an agent's minimum), so two helpers
  stack exactly beside the lead. This applies to pop-outs and to opening a
  child from its parent's chip.
- **Helpers fan out around their lead.** A's fan-out runs with the lead and
  its helpers as the hosts, pulled toward the lead rather than toward
  wherever the camera went, and follows the growth direction.
- **Dragging a helper disturbs only its sibling helpers.** The lead and
  every tile outside the cluster are fixed: never pushed, swapped or slid.
  The lead is the cluster's anchor.
- **Dragging the lead carries its helpers**, rigidly, through the existing
  group-drag path (a "carry", which never becomes the visible selection).
  A carried cluster doesn't swap or slide in, because one step of a
  ~1,900pt block would throw a row ~1,300pt. It nudges neighbours under A's
  rules and docks at the nearest free spot when dropped. Group drags now get
  A's dwell gate, two-frame push budget and push relax too.
- **New slide-ins need a dwell as well.** Passing a tile's edge quickly no
  longer slides tiles aside and back. Sliding along a row already joined
  stays responsive.
- **Growth direction is a setting**: Canvas → Layout → "New tiles grow the
  zone" (Fan out / To the right / Downward).

Witnesses:

- `--auto-layout-fanout-check` adds an engine-level cluster scope check,
  with a control that must push when unscoped.
- `--auto-layout-fanout-app-check` adds a real-event cluster leg. A helper
  dragged into neighbouring notes moves no note and not the lead, with a
  control that it really pressed on a note. The lead's drag keeps both
  helpers at their exact offsets every frame and after the drop.
- `--subagent-tile-zone-check` asserts the half-height child size.
- Mutations that switch off the cluster scope, the carry or the helper size
  each turn a leg RED.

Also found while filming B:

- **A helper used to swap with its own lead** (a 640×520 tile jumping into
  a half-height slot). The lead is now frozen during a helper drag.
- **A fast drag that then goes still sends no further events**, so a dwell
  could not latch until the pointer moved again. A 120ms dwell timer
  re-solves the resting pointer. The slide-in leg now rests 0.2s before
  inspecting, which is the behaviour it witnesses.

Sheets (0.7.35, A, A+B): `sheets-b/`. Films:
`~/Movies/Array/auto-layout-fanout/model-b/` (`A-and-B-built--*.mp4`).

## Built: model A (2026-10-30, on 0.7.35)

Commits on `array/auto-layout-fanout`: 990b7361, 729bfa97, 5426cdb9.
Local only, nothing pushed.

What changed, in plain words:

- **A drag only nudges what it touches.** At most 3 other tiles move in any
  frame, and each moves at most a quarter of its own size. A push that would
  need a fourth tile doesn't happen; the dragged tile overlaps instead.
- **No pass-by swaps.** Dragging quickly across a tile no longer swaps it.
  A swap needs the pointer to slow down over the tile, and letting go always
  counts as slowing down.
- **No twitching neighbours.** Tiles that only meet the dragged one at a
  corner are never pushed. Hand jitter used to twitch them every frame.
- **The pointer owns the dragged tile.** The magnet may pull it up to its
  release distance (64 screen points) and no further. A farther snap target
  is only the drop preview. Before, the magnet held the tile up to ~400pt
  from the pointer and then jumped it.
- **Slide-in kept, made local.** Dropping between two tiles still works, but
  only the tiles in the way shift sideways, and nobody's height position
  changes. The old version re-laid the whole "row" and flattened the zone.
- **A drop moves only the dropped tile.** Pushes relax back and nothing else
  is re-clustered, so a hole stays a hole.
- **New tiles fan out.** In an auto-layout zone a new tile docks
  edge-aligned against any tile of the zone (a helper: against its lead or
  sibling helpers). It must be at least half visible; then it follows the
  growth direction; then it picks the side that keeps the zone
  screen-shaped. The right-hand tie-break is gone. A new setting,
  `continuum.canvas.autoLayout.growth` (Fan Out / Right / Down), exists with
  no Settings control yet.

Witnesses, all registered in `scripts/run-matrix.sh`:

- `--auto-layout-fanout-check` (CoreChecks, scripted production path).
- `--auto-layout-fanout-app-check` (real `NSApp.sendEvent` drag across a
  ragged 10-tile zone, plus six ⌘K agents with the camera following).
- `--jelly-trajectory-probe`, which now fails on any anomaly.
- Each one goes RED when an old behaviour is put back: unbounded push
  chains, uncapped pushes, the right tie-break, re-cluster at drop, and a
  magnet-held dragged tile.

Existing legs whose expectations encoded the old behaviour were changed on
purpose:

- `--spawn-placement-check`: edge-aligned, so y 300 instead of 220.
- `--subagent-tile-zone-check`: under auto layout, children fan out instead
  of stacking in a column.
- `--zone-arming-check`: its growth-push witness pins growth Right, so the
  push into a neighbour is still exercised.

19 related legs pass, including jelly, slide-in, multiselect, tile
selection, pointer path and the helper legs.

Sheets (0.7.35 against A): `sheets-a/`. Films:
`~/Movies/Array/auto-layout-fanout/model-a/`.

## Short version

- **The straight line is a placement rule, not bad luck.** A new tile docks
  beside whatever tile is under the camera centre, and "right" wins every tie.
  Your attention follows the newest tile, so the next one docks right of
  *that*. Ten spawns made one row 10.8 times wider than tall.
- **The whole-layout breaks happen during the drag, not at the drop.** Three
  seams in the live solver let one drag move up to 8 of 9 other tiles in a
  single frame: push chains, a "slide in" mode that flattens the zone into
  one row, and swap targets tested against where tiles *used to be*.
- **Recommendation: ship model A's four local fixes first, then build model
  B's lead clusters on top.** A is a small change to code you already
  approved. In the probe it cuts bystander motion from 8 tiles per frame to
  at most 3, false jumps from 31 to at most 4, and keeps the zone screen-shaped
  (aspect 1.6 instead of 10.8). B adds what A can't: a lead carries its
  helpers, and helpers reorder inside their own cluster with nothing else
  moving.

## 1 · Diagnosis

Every number below comes from `ContinuumRevivedCoreChecks --fanout-layout-probe`
(section 4). It runs the shipped Core solvers through a faithful copy of the
app code that calls them. Defaults throughout: gap 8, zone padding 24, header 34,
1512x945 screen, zoom 0.55.

### 1a · Why new tiles line up to the right

There are two placement paths, and both lean right.

1. **A helper or child agent** pops out through
   `AppDelegate.spawnPlacementBesideParent`
   (`Sources/ContinuumRevived/App/ContinuumApp.swift:13874`, unchanged on
   `array/managed-mode`). It scans for a free slot starting right of the
   parent, top-aligned to it. It goes down that column, then moves one column
   further right, and only searches *inside the zone's current rect*. A zone
   that hugs its tiles has no free slot inside, so the scan returns nil and
   falls through to path 2.
2. **Everything else** uses `TileSpawnPlacement.automatic`
   (`Sources/ContinuumRevivedCore/TileSpawnPlacement.swift`):
   - The anchor is the tile under the viewport centre.
   - Candidates are centre-aligned to the anchor (`immediate`, line 213).
   - The final tie-break is side order, right first (`Side`, line 64;
     `isBetter`, line 296).
   - On a 16:10 screen a right-hand slot is always at least as visible as a
     slot below it, so the visibility rules never overrule that tie-break.

   Then `arrangeAutoLayoutAfterSpawn` keeps the docked slot and grows the
   zone toward it.

The camera decides the rest. Spawns don't pan the camera themselves, but
API spawns with `camera: revealResult` do
(`WorkspaceAPIService.swift:910`), and so does every jump the user makes to
look at the new tile. Each new anchor is therefore the newest tile, and each
spawn docks right of it.

| 10 spawns (lead, 3 helpers, 6 mixed tiles) | aspect (width/height) | screen fill when fitted | helpers touching lead |
|---|---|---|---|
| camera stays on the lead | 1.64 | 0.98 | 3 |
| camera follows each new tile | **10.81** | **0.15** | **1** |

With the camera held still, the layout fans out but stays ragged. Centre
alignment gives tiles of different heights no shared edges: Note at y=118,
Web at y=−2, Term at y=−534. Ragged edges are what make seam 2 below so
destructive.

**Seen live tonight.** Three `array_open_document` calls in a row, with the
camera preserved, put all three file tiles on the *same* rect (640x560 at
11393, −1795). They covered each other and the header of an existing Opus
tile. The camera never moved, so the anchor never changed, and nothing
dodged the tiles the previous call had just placed. I moved them by hand.

### 1b · Why moving one tile reflows the whole zone

A live drag calls `CanvasAutoLayoutEngine.solve(.tile)` every frame, starting
from the pre-drag positions and carrying the latch forward
(`CanvasNSView.updateTile`, line 3038). Three seams there let one drag reach
every tile:

1. **Push chains.** `propagatePushes` (`CanvasAutoLayoutEngine.swift:525`) is a
   queue: a pushed tile pushes the next one, and so on. Pulling H1 out of the
   line pushed all 7 tiles to its right by 484pt, in lockstep, frame after
   frame.
2. **Slide-in flattens the zone.** `memberRows` (line 618) groups tiles into a
   row whenever their vertical spans overlap, and it chains: A overlaps B and
   B overlaps C makes one row. With ragged heights, the whole zone becomes
   one "row". When the pointer reaches a row edge, `slideOrSwapLatch`
   (line 682) latches `.insert`. `layoutInsertion` (line 724) then re-lays
   that whole row left to right with tops aligned. In the working-zone drag,
   one frame (#52) moved all 8 other tiles, some by 2,900pt, into a single
   line. Fourteen frames later a swap latched and they all snapped back.
   This is the flicker, and it is also a second source of "straight line".
3. **Swap targets are invisible.** The latch tests the pointer against each
   tile's *pre-drag* rect, but pushes have already moved the visible tile
   away. The pointer enters empty space where the Lead used to be, the latch
   fires, and the Lead teleports 648pt back to be swapped. Those are the
   false jumps.

There is also a smaller seam at the drop. `settleMembers` (line 751) rebuilds
the cluster starting from the tile with the *smallest y*
(`anchorPool`, line 781). Among centre-aligned tiles that is an arbitrary
pick (Web, at the far right), so closing H1's hole moved the **Lead** 648pt.

### 1c · Measurements (shipped engine)

Bystanders are every tile except the one being dragged. A false jump is a
bystander moving more than half its own size in one frame.

| drag (72-96 frames) | most bystanders moved in one frame | false jumps | latch flips | tiles moved at drop |
|---|---|---|---|---|
| lead+3: drag H1 down-left across | 2 of 3 | 3 | 2 | 0 |
| working zone: drag H2 right across 9 tiles | **8 of 9** | **19** | 3 | 0 |
| line of 10: pull H1 out, down-right | **8 of 9** | 8 | 3 | 1 (the Lead, 648pt) |
| working zone: Lead to empty space | **8 of 9** | **31** | 6 | 0 |

Raw traces: `/tmp/fanout-probe/all/shipped--*.json`. Per-frame listing:
`python3 -I /tmp/fanout-tools/trace.py <file>`.

## 2 · Three models

All three run the same scripts in the probe
(`Sources/ContinuumRevivedCoreChecks/FanoutLayoutModels.swift`).

### A · Local jelly: the shipped rules, made local

Keep the vocabulary you approved (the pointer owns the tile, single-axis
pushes, latched swap, zones push tiles) and bound every effect to the tiles
the pointer touches.

- **Spawn.** A helper docks onto its *lead's family* (the lead plus its
  siblings), never onto whatever is under the camera. Slots are
  edge-aligned, never centre-aligned. The side is chosen by the resulting
  zone shape (closest to the screen's aspect), then nearness to the lead,
  then a user growth setting. Right is no longer a hidden default.
- **Drag.** Pushes go one level deep, along the pair's own axis. If a third
  tile is in the way, nothing moves and the dragged tile simply floats over.
  There is no slide-in row mode. Swaps hit-test what is drawn on screen, and
  a swap holds while the pointer stays over the slot it will take.
- **Drop.** Only the dropped tile (and a swap partner too big for its new
  slot) is resolved, to the nearest free contact slot. Nothing compacts and
  holes stay.
- **Code.**
  - `TileSpawnPlacement` (edge-aligned candidates, shape-based score, family
    anchor).
  - `spawnPlacementBesideParent` (call the family placement instead of the
    rightward scan).
  - `CanvasAutoLayoutEngine.solveMemberMove` and `propagatePushes` (depth 1).
  - Delete the `.insert` latch, `memberRows` and `layoutInsertion`.
  - `slideOrSwapLatch` (displayed frames).
  - `settleMembers` (resolve the mover only; `tidy` stays the explicit
    compaction).
- **Risks.**
  - Without chains, a crowded drag overlaps tiles for a moment instead of
    clearing a path. That is honest, but it is a change in feel.
  - Losing slide-in removes a gesture someone may use; ⌥-swap stays.
  - `--jelly-auto-layout-check` asserts some of today's push chains and
    insert reflows, so those assertions have to be rewritten deliberately,
    not silenced.

### B · Lead clusters

A lead and its helpers form one rigid cluster, laid out by a template:

- Helpers spawn at half the lead's height (640x256).
- Two helpers stack to the lead's right, then two go below it, then a new
  column starts.
- Lone tiles are clusters of one.
- Clusters dock edge-aligned against other clusters, scored by shape as in A.

Dragging behaves differently by tile:

- **Dragging a lead** carries its whole cluster. Over another cluster's
  middle, the two clusters swap places.
- **Dragging a helper** reorders template slots inside its own cluster. Only
  the two helpers exchange.
- **Pulling a helper out** of its cluster makes it a lone tile where it is
  dropped.
- Nothing outside the gesture's own cluster moves during a drag.

Size and scale:

- **Size.** Helpers are smaller by design, so a lead with 2 helpers is
  exactly two tiles wide and one lead tall.
- **Scale.** Zoomed out, a cluster reads and drags as one unit.

Code and risks:

- **Code.**
  - A cluster notion in Core: membership comes from `AgentRecord.parent` plus
    a persisted slot index on the tile, which needs a
    `WorkspaceAPIExposure` classification.
  - A cluster pass in front of the solver.
  - Helper default size in the pop-out path.
  - A rigid-cluster move in `CanvasNSView`'s drag.
  - Builds on A for the cluster-to-cluster rules.
- **Risks.**
  - Half-height helpers are small at zoom 0.35. They may need a compact face
    below a zoom threshold.
  - Template slots need a rule for a helper the user resized.
  - Parent links must survive relaunch, managed versus free mode, and
    deleting a lead (what happens to orphaned helpers?).
  - The biggest blast radius of the three.

### C · Cell grid, displacement only

The zone is a grid of quarter-agent cells (an agent tile is exactly 4x4
cells). Every tile owns a span of cells, and its size snaps to that span.
Empty cells are allowed: no compaction, no gravity.

- **Spawn.** A new tile takes the free span nearest its lead: around the
  lead first, edge-sharing slots before corners, then shape, then growth
  direction.
- **Drag.** Only tiles under the target span move: into the vacated span if
  they fit there, else to the nearest free span. They stay put while that
  spot stays valid, and go home once the target moves off them. The target
  cell has hysteresis of 0.65 of a cell.
- **Scale.** The grid is in world units, so zoom never changes the layout.
- **Code.** A new solver beside `CanvasAutoLayoutEngine`, size snapping in
  spawn and resize, and a migration for existing free-form zones.
- **Risks.**
  - Snapping changes tile sizes: a terminal goes from 900x584 to 964x520,
    and terminals have cell-quantised sizes of their own.
  - Displacements are discrete hops (4-8 per long drag in the probe).
    Dylan has rejected visible jumps before.
  - Existing canvases need migrating.

### Growth direction (all three)

A per-zone setting: **Fan** (default, shape-driven), **Right**, or **Down**.
It only changes ranking, never pushes. The probe runs C with Down
(`c-cell-grid-down`) to show the same scenario growing down instead of out.

### Zoom (all three)

Shipped placement scores candidates by how visible they are in the current
view, so the layout you get depends on the zoom you spawned at. All three
models score by world-space shape instead. Drag thresholds (the 24pt release
band, hysteresis) should be in *screen* points, divided by zoom, so a
zoomed-out drag isn't hair-trigger.

## 3 · Results, same scripts

Same metrics as in 1c; "worst" is the highest value across that row's
scripts.

| | shipped | A local jelly | B lead clusters | C cell grid | C, grow down |
|---|---|---|---|---|---|
| zone aspect after 10 camera-follows spawns | 10.81 | 1.55 | 1.42 | 1.84 | 1.89 |
| helpers touching lead (of 3), camera follows | 1 | 3 | 3 | 3 | 3 |
| most bystanders moved in one frame, worst drag | 8 | 3 | 0 (1 inside cluster) | 3 | 3 |
| false jumps, worst drag | 31 | 4 | 3 (helper slot swaps) | 8 | 6 |
| latch flips, worst drag | 6 | 0 | 3 | 6 | 12 |
| tiles moved by the drop, worst | 1 | 0 | 0 | 0 | 0 |
| overlaps left after any drop | 0 | 0 | 0 | 0 | 0 |

B's false jumps are the deliberate one-step swaps of two helpers inside a
cluster. C's jumps and flips are its grid hops (the target cell changing).

## 4 · How to rerun

```sh
cd .worktrees/auto-layout-fanout
swift build --product ContinuumRevivedCoreChecks
.build/debug/ContinuumRevivedCoreChecks --fanout-layout-probe /tmp/fanout-probe/all
python3 -I /tmp/fanout-tools/table.py /tmp/fanout-probe/all        # the table above
python3 -I /tmp/fanout-tools/trace.py /tmp/fanout-probe/all/<run>.json   # per frame
```

The probe is pure Core. It never builds a window or touches tmux, and it is
not in the matrix. The app glue it copies is quoted in
`FanoutLayoutProbe.swift`, and it must be re-checked if that glue changes.

## 5 · Witness for whichever model lands

Turn the probe into a trajectory check with hard limits. The limits below
are for A; B tightens bystanders to 0 outside the cluster.

- At most 2 bystanders move in any frame, and none moves more than half its
  size unless it is the latched swap partner.
- At most one latch change per 10 frames of steady pointer motion.
- The drop moves no tile except the dropped one and its swap partner.
- After 10 spawns with the camera following, the zone aspect is between 0.8
  and 2.4, and every helper shares an edge with its lead or a sibling.
- It must go RED on today's engine. The table above shows it does: 8
  bystanders, 31 false jumps, aspect 10.8.
- Plus one app leg that drives the real event path (`NSApp.sendEvent` over a
  mounted zone, per the gesture-witness reference card), so the CanvasNSView
  glue is witnessed and not just copied.

## 6 · Films

The same scripts, rendered with real Array tile views. The renderer mounts an
isolated workspace fixture offscreen and draws note tiles named after each
recorded tile. Auto layout is off on that canvas: it only displays the
recorded frames, it never re-solves them. Each sheet has one row per model
and six key frames per row: after the last spawn, four drag frames, and the
drop.

- `sheets/lead+3.png`: the film script. A lead and 3 helpers spawn, then H1
  is dragged down-left across.
- `sheets/working-zone.png`: 10 tiles, H2 dragged right across all of them.
  The shipped row at "drag 63" is the whole zone flattened into one line.
- `sheets/working-zone-camera-follows.png`: the straight line (shipped)
  against four screen-shaped zones.
- `sheets/working-zone-lead-to-empty.png`: the Lead dragged to empty space.

Motion films (MP4, 30 fps, one per model per script), kept out of git:
`~/Movies/Array/auto-layout-fanout/<model>--<script>.mp4`. Watch
`shipped--working-zone.mp4` beside `a-local-jelly--working-zone.mp4` first.

Things the films show that the numbers don't:

- In A and C a pushed or displaced tile can cross the zone edge during the
  drag. The zone only grows at the drop. Shipped stops pushes at the wall,
  which is why its pushes pile up and chain.
- In C with "grow down", one long drag displaced the **Lead** up and out of
  its spot. Displacement doesn't know which tile matters, which is one more
  reason to prefer B's clusters.
- B's pulled-out helper leaves a hole in its cluster. That is deliberate (no
  compaction); the slot is reused by the next helper.

To regenerate (renderer: `Sources/ContinuumRevived/App/FanoutFilmRender.swift`,
written by a Codex helper):

```sh
swift build --product Array
.build/debug/Array --fanout-film-render /tmp/fanout-probe/all /tmp/fanout-films/all
```

## 7 · Open questions for Dylan

1. Is losing slide-in (the drop-between-two-tiles mode) acceptable, with ⌥
   swap kept? A removes it, because it is what flattened the zone.
2. Should helpers be smaller than their lead by default (B), or the same size
   (A)?
3. Does the growth setting belong per zone, or once app-wide?
