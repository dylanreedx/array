# Stream 1: tidy engine

Date: 2026-11-09. Branch `array/aln-tidy-engine`, on top of `0bb5fb19`.

## What changed, in one paragraph

Tidy used to close gaps (an n² compaction) and then shrink the zone around
the result. It never resized a tile and never filled the zone. It is now
`CanvasTidyPacker` (`Sources/ContinuumRevivedCore/CanvasTidyPacker.swift`): a
pure, deterministic justified-row packer. It fills the zone's content rect
edge to edge at the gap, shapes every tile by `TileGeometry.shapeRule`, keeps
reading order, keeps a lead agent's helpers in one block with it, grows the
zone's height when the tiles cannot fit, and shrinks an oversized zone in
proportion. `.settle`, moves, resizes and spawns are untouched (the
trajectory and fan-out probe outputs are byte-identical to before).

## Commits

- `126a2617` feat(auto-layout): fill the zone on tidy with a justified-row packer
- `f07949b8` test(auto-layout): witness zone-filling tidy on seeded mixed zones
- `a08ef4f0` fix(auto-layout): land tidy edges on a 1/64 pt grid
- `4d260b51` feat(auto-layout): give tidy each tile's kind and its lead cluster
- `ecfb07d3` test(auto-layout): witness tidy through the mounted canvas

## The rules, and why

How it works: tiles go in reading order. A dynamic program picks the row
breaks. Every row is justified to the content width. The rows then share out
the height so they fill the zone. The cheapest result wins.

- **Shape rules.** `TileGeometry.shapeRule` is unchanged: browser 16:9,
  terminal 0.6–0.9, agents 0.6–1.0, `.keep` for iOS preview and shared tiles.
  A tile with no kind uses the loose band 0.6–1.8. **`.keep` means fixed
  size.** The tile is moved, never resized. In a row taller than the tile, it
  sits at the top and leaves a hole below. A row of only `.keep` tiles cannot
  be justified, so it costs a lot and is used only when nothing else fits.
- **Area band.** A uniform area scale s is searched over [0.6, 1.6] of each
  tile's current area. That is 0.77×–1.26× in each direction. The DP target is
  s × current area, at the tile's preferred ratio (its current ratio clamped
  into its band).
- **Per-tile cap: 2.56× area (1.6× linear).** I added this after the first
  pictures. The 1.6 limit on the mean could not see one stretched tile: a lone
  browser became a full-width row at 7× its area. Now row heights cannot be
  fitted past the cap, and a row that starts past it pays a steep penalty.
- **Cost.** Each tile is charged the squared log change of its area, plus
  twice the squared log change of its ratio. The total is the mean of those,
  plus half the worst tile. Changing the zone height is charged
  `growWeight` = 2 or `shrinkWeight` = 4 per squared log of the change.
  Shrinking costs more because the goal is to fill.
- **Zone growth.** Height first. A tile that can't fit at the floor scale, or
  a shape that can't fit the zone (tall terminals in a short zone), grows the
  zone downward. Width grows only when a single tile can't fit across at its
  minimum. The origin never moves, except for the 1/64 pt snap below.
- **Zone shrink.** This applies when the zone is too big: mean stretch past
  1.6, or the fill would lose more than a tenth of the height. The packer then
  tries uniform scales k < 1 (whole points) and charges each one per
  dimension. For the same area, a proportional shrink costs less than a
  height-only one, so the zone keeps its shape. Before this rule, the zone
  became a one-row strip (3301×2801 → 3301×589). Before that, with
  width-only narrowing, it became a tall column (4328×4040 → 2171×4040).
- **Clusters.** Lead first, then its helpers, gathered where the cluster's
  first member reads. A row may not cut a cluster unless the row lies wholly
  inside it. So the cluster is either inside one row or a run of whole rows.
- **Idempotent by construction.** At s = 1, the current row breaks of a tidy
  layout cost exactly zero and fill exactly, so a second tidy picks them
  again. The engine treats a re-solve as all-or-nothing: if every frame and
  the zone size are within 0.02 pt, nothing changes. A rounding wobble of one
  grid step therefore never mixes old and new frames.
- **1/64 pt grid.** Every tidy edge, and the zone origin, sits on a 1/64 pt
  grid. The canvas rejects a layered commit when a world frame has no exact
  zone-local. On this grid that conversion is exact by construction. To be
  honest about this one: I could not make the witness go red without the grid
  (the ±4-ulp search found exact locals for 320 arbitrary frames). So it is a
  cheap guarantee, not a witnessed fix. The cost is that browsers are 16:9 to
  within 1/32 pt rather than to the last bit.
- **Rejected:** "any exact fill beats any zone change". It produced the 7×
  browser. Also rejected: a 12-tile row limit (now 8), bisection solvers
  (replaced by an exact breakpoint walk), and narrowing width only (see
  above).

## Numbers (`--tidy-packer-check`, debug build, team builds running)

Fill means tile area over content area. Before = the seeded messy zone.
After = the tidied zone.

| zone | tiles | fill before → after | zone before → after | solve |
|---|---|---|---|---|
| two | 2 | 0.801 → 0.992 | 2100×733 → 2100×830 | 1.9 ms |
| three | 3 | 0.605 → 0.989 | 3457×896 → 3013×866 | 1.5 ms |
| five | 5 | 0.411 → 0.978 | 2945×1726 → 2239×1371 | 3.0 ms |
| eight | 8 | 0.460 → 0.977 | 3113×2825 → 2714×2467 | 5.9 ms |
| thirteen | 13 | 0.316 → 0.967 | 4328×4040 → 2866×2284 | 12.4 ms |
| lead + 3 helpers | 8 | 0.431 → 0.969 | 3301×2801 → 2509×1359 | 4.2 ms |
| cramped | 8 | 2.576 → 0.962 | 2400×700 → 2400×927 (grows taller) | 0.7 ms |
| roomy | 3 | 0.134 → 0.986 | 4152×2567 → 2398×759 (shrinks) | 1.7 ms |
| dust (coords near 81,234) | 8 | 0.424 → 0.976 | 3500×2765 → 2660×2319 | 7.4 ms |
| sixty | 60 | — | — | best 74 ms, worst 126 ms |

App, `--auto-layout-fanout-app-check`, mounted layered zone with 6 tiles:
`tidyAutoLayout(zoneId:)` takes 8–13 ms on the main thread in a debug build.
Zone 2600×1800 → 1982×1273, fill 0.985.

The fill floor in the witness is 0.80. Justified rows leave only the gaps
and the hole under a `.keep` tile, so 0.96–0.99 is normal. 0.80 leaves
headroom for a zone with several fixed tiles.

Before/after pictures: `qa-runs/aln-tidy-engine/pictures/*.png` in this
worktree (gitignored). Left is before, right is after. Browser blue, terminal
dark, agent purple, iOS preview orange, everything else green. The cluster is
outlined in yellow, with the lead's outline thicker.

## Checks, with exit codes (final runs at `ecfb07d3`)

CoreChecks (`.build/debug/ContinuumRevivedCoreChecks`):

- `--tidy-packer-check qa-runs/aln-tidy-engine/pictures`: **0**. This is new.
  It drives `CanvasAutoLayoutEngine.solve(.tidy)` exactly as the app calls
  it. It asserts: fill ≥ 0.80; browsers 16:9; terminals taller than wide; the
  iOS preview never resized; nothing below its minimum; nothing outside the
  content rect; no pair closer than the gap; every right and bottom edge meets
  the content edge or a neighbour exactly one gap away; reading order kept;
  the cluster forms one block with the lead first; an exact zone-local for
  every frame; idempotent; the same result for shuffled input; height growth
  ≤ 15% and never wider; cramped grows taller, not wider; roomy shrinks with
  no tile past 2.56×; a zone the tiles already fill keeps its size and every
  tile's size; 60 tiles best-of-5 under 250 ms.
- `--layout-pressure-check`: **0**. Its tidy block asserted the old contract
  ("closes gaps", "fits zone to compacted members", "one tile fits its
  zone"), so I rewrote it for the new one: runs with auto layout off, keeps
  the disabled mode, fills ≥ 0.85, leaves outside tiles alone, closes a
  cavity, stable, irregular fixed point, one tile fills the content exactly.
  `runCanvasAutoLayoutChecks` (in the same leg) had "tidy fits a disabled zone
  without changing member dimensions"; it now asserts the fill to the padded
  content edges.
- `--jelly-trajectory-probe`: **0**, output byte-identical to the baseline.
- `--auto-layout-fanout-check`: **0**. `--fanout-layout-probe <dir>`:
  **0**, output identical apart from the path.
- `--jelly-auto-layout-check` is not a CoreChecks flag. It falls through to
  the whole default suite, which has an unrelated pre-existing timing FAIL
  ("just-under-cap safe rows must remain useful within 100ms"). It is an app
  leg; see below.

App legs (`.build/debug/Array`, disposable `CONTINUUM_APP_SUPPORT` and
`TMUX_TMPDIR`, `ARRAY_AGENT_ID` unset):

- `--auto-layout-fanout-app-check`: **0**. It has a new tidy case: Tidy Zone
  Now on a mounted layered zone, with a real lead and two helpers from
  `AgentSupervisor` lineage, a browser, notes, and auto layout off. It
  asserts: no rejected transaction; fill ≥ 0.8; inside the content rect;
  browser 16:9; the cluster is one block; the persisted canvas equals the
  shown frames; a second tidy is a no-op. **Teeth:** with the cluster wiring
  disabled, it went red ("the lead's rows are shared with other tiles").
- `--jelly-auto-layout-check`: **0**. Its two fixture windows used
  `orderFrontRegardless` at (0,0), which put a 1000×700 window on the display.
  They now use `orderFrontOffscreenForChecks()`, and the leg passes offscreen.
  Its tidy assertions (undo/redo, a rejected commit restores, a disabled
  layered zone is fitted) pass against the new packer.
- `--zone-arming-check`: **0**.
- `--layout-commit-truth-check`: **0**. Its "persistLayoutTransaction failed"
  log lines are its own negative cases.

## Plumbing and per-frame cost

- `LayoutTile` gains `kind` and `clusterLead`, both defaulting to nil.
- `autoLayoutScene()` copies `kind` inside the loop it already runs. No new
  pass, no new lookup.
- Cluster lineage is read only by `tidyAutoLayout(compact: true)`, through
  `sceneWithAgentClusters`. That is one `autoLayoutClusterProvider` call per
  agent tile, per explicit tidy. Drags, settles and spawns never call it. It
  ignores the auto-layout switch on purpose, because an explicit Tidy runs
  regardless.
- The old `compactMembers` / `compactMembersOnce` had no other callers and
  are gone.

## Open, for the lead

1. **Tidy animation feel.** `applyLayoutTransaction` animates only origins,
   for 0.11 s. Sizes jump at once and the tiles then slide. Now that tidy
   resizes, a tile visibly snaps to its new size and then glides. I left this
   alone, since I believe that is the `aln-tidy-latency` stream's seam. The
   packer itself is not the lag: 8–13 ms for the whole call in debug.
2. **16:9 at creation.** `TileGeometry.preset(.browser)` is still 1024×640
   (1.6). Dylan said "maybe on creation". It is a one-line change
   (1024×576), but it touches spawn placement and its probes, so I left it
   out of this stream.
3. **A wide zone with two or three tiles** cannot be filled by shape alone
   (rows justify to the width). Its height grows instead: up to 13% in the
   seeds, and the witness caps it at 15%.
4. **Lead emphasis.** A cluster in one row gives the lead the same height as
   its helpers. Lead first, but not bigger. Making the lead bigger would need
   a composite block (lead | stacked helpers). I did not build it.
5. Shared build log: another helper also writes `/tmp/aln-tidy-build.log`, so
   I moved to `/tmp/aln-tidy-engine-*.log`.
