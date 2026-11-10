# Experiment: size-grouped rows with a big-tile column

Date: 2026-11-09. Branch `array/aln-tidy-masonry`, off `array/auto-layout-night`
at `3ade43f7`, local only. Not merged; the lead decides after reviewing the
pictures.

## What it does

Dylan said tidy should "try to match the existing dimensions". On his real
canvas he made two agents 3–4× the size of the others, and the uniform packer
shrank them to 0.29×. This packer keeps them big. Four parts:

1. **Hard per-tile band.** Every tile stays within 0.5–2.0× of its area.
   Tidy first looks only for layouts that keep that. If none exists, it falls
   back to the soft solve, so it always produces something.
2. **Size-grouped rows.** Tiles are ordered by the height at which each keeps
   its own area at its preferred shape (√(area ÷ ratio)), tallest first.
   Within 0.5% of the same height they keep reading order. A fixed-size tile
   takes its row's height, so it stays with its row mates. Rows are stacked
   tallest first. A row's shared height can then keep every tile in band.
   Reading order is given up across sizes, which the lead allowed.
3. **Area-fit rows.** Besides the classic row (every tile at its preferred
   ratio), a row can keep its tiles' widths in proportion to √(ratio × area)
   and take the height that best keeps their areas. The cost picks per row.
4. **Big-tile column.** Tiles at least 2× the zone's median area (not
   browsers, which must stay 16:9, and not fixed or block tiles) stack in a
   column at the left, sharing one width at their preferred ratios. The other
   tiles fill size-grouped rows beside them. The column's width is set so its
   height equals the rows' height, so the zone fills edge to edge. The
   column's height is searched (0.7–1.75× its own) by one score computed from
   the final frames. When the column holds the band, it is used: big tiles
   keep their size, which is the lead's decision, not a preference. A column
   a tidy already made is recognised by geometry and kept in its own order, so
   a second tidy reads it back the same.

The switch is `featuredBands` / `sizeGroupedRows` in `CanvasTidyPacker`.

## The bar

Real canvas (read-only copies, his gap of 20). Pictures are in
`~/Movies/Array/auto-layout-night/real-canvas/*-masonry.png`, with the table
in `table-masonry.md`.

| zone | tiles | fill | zone before → after | area change (min–max) | 2nd tidy no-op | big tiles ÷ next |
|---|---|---|---|---|---|---|
| z01 | 22 | 0.973 | 16289×8298 → 7462×3831 | 0.97–2.00× | yes | 2.79× |
| z02 | 10 | 0.976 | 5855×4002 → 5281×2295 | 0.66–1.69× | yes | 1.18× |
| z03 | 24 | 0.972 | 9330×7106 → 6317×4624 | 0.77–2.00× | yes | 1.34× |
| z04 | 2 | 0.992 | 2511×2049 → 2511×1334 | 0.75–2.00× | yes | — |
| z05 | 6 | 0.971 | 3686×2060 → 2532×1663 | 1.12–1.95× | yes | — |

- **Fill ≥ 0.90:** met in every zone.
- **Every tile within 0.5–2.0×:** met.
- **Big agents visibly largest in z01 and z03:** met. In z01 they form the
  left column at 2.79× the next tile, with the zone keeping its 2:1 shape. In
  z03 the three biggest agents form the column at 1.34×.
- **A second tidy changes nothing:** met in every zone.
- **89 tiles ≤ 25 ms (debug):** met, about 23 ms (24.1–24.4 ms worst while
  the Mac was loaded). There is little margin, so it may flake under heavy
  build load.

## `--tidy-packer-check`: what holds and what changed

These hold unchanged: browser 16:9, terminal band (0.6–0.9), the lead/helper
column geometry, the text floor (0.75), file tree 0.6, iOS preview never
resized, fill ≥ 0.80, gaps exact, edges meet, no overlap, minimum sizes, the
shuffled input giving the same result, idempotence, and every spawn preset
inside its band.

What changed, and why:
- **Reading order** is not asserted under size-grouped rows. The order is
  deliberately by size: tallest rows first, reading order only within one
  height.
- **"Zone grew more than needed"** now limits growth of the zone's area to
  15%, instead of forbidding wider zones and capping height growth at 15%.
  With the hard band, the two-tile seed (a terminal and a browser in a
  2100×985 zone) can't sit side by side without stretching past 2×, so the
  tiles stack: 1102×1871. That is the same area (2.07 → 2.06 M pt²) in a
  different shape.
- **The 30-tile budget** is now 12 ms (was 8). It measures about 9.5 ms: the
  in-band pass and the column search cost about 1.5 ms there.
- **Real seeds:** the bounds tightened from 0.25–3.0× to the hard 0.5–2.0×,
  plus a new assertion that big tiles are at least 1.25× the next.
- **Output digests** are re-pinned for every seed, since the layout model
  changed.

Other checks, all exit 0:
- CoreChecks: `--layout-pressure-check`, `--jelly-trajectory-probe`,
  `--auto-layout-fanout-check`.
- App: `--auto-layout-fanout-app-check`, `--jelly-auto-layout-check`,
  `--undo-toast-placement-check`, `--spawn-sizing-check`,
  `--auto-layout-tidy-latency-check`, `--zone-arming-check`,
  `--canvas-undo-check`.

## Costs and caveats

- **Main-thread cost in the app.** On the 6-tile fan-out zone, a tidy takes
  about 42 ms on the main thread, against about 37 ms for the uniform packer
  on the same build. Most of that is the app's apply-and-animate path from
  the night branch, not the packer.
- **Layout changes.** Rows group by size, so a tidy rearranges more than the
  uniform packer did. Tiles are no longer in reading order across sizes.
- **z02.** Its single big kanban stays the largest (1.18×) but gets no
  column: the column didn't hold the band there.
- **Rejected along the way.**
  - Featured bands in reading order: infeasible for z01 and z03 at any width;
    see the engine report, round 7.
  - Area-fit-only rows: slower, and not idempotent.
  - Sharing a row with the giants: z01 tied at 1.00× under an honest cost.
  - A 2% size class: it fixed a fixed-tile reorder, but made 89 tiles take
    34 ms.

## Round 2: the zone keeps its width

The lead's condition after reviewing round 1: the zone's width belongs to the
user. Tidy changes only the height, unless a tile cannot fit across at its
minimum.

**What changed in the packer.**
- The size search now moves only the height. The old search scaled width and
  height together, which is why the two-tile zone turned tall and narrow and
  the film zone went from 2300 to about 2000 wide.
- The big-tile column takes a width; the rows fill the rest of the zone's
  width. The column tiles then share the rows' height, each in its own shape
  band and within 0.5–2.0× of its area.
- Order of attempts (`packItems`):
  1. At the zone's width, every tile within 0.5–2.0× of its area.
  2. At the zone's width, every tile within 0.5–2.56× (the per-tile cap).
  3. Only then a narrower zone, keeping its proportions (round 1's search).
  4. Failing all three, the best layout at the zone's width.
- A one-row layout is no longer mistaken for an existing column on a second
  tidy (that broke idempotence for the three-tile seed).

**Why step 3 exists.** It does not meet the strict rule, so the lead has to
accept it. Some zones are far wider than their tiles can fill:
- z01 is 16289 wide for 22 tiles, at fill 0.148.
- At that width, no layout keeps every tile within 0.5–2.56×. One row
  cannot hold tiles whose areas differ by more than about 4×. With fewer
  tiles per row, each tile grows wider than its cap.
- Kept at its width, z01's tiles stretch up to 8.7×, and z03's up to 4×.

The alternative is to keep the width and leave the zone partly empty, which
fails the 0.90 fill bar. Step 3 only ever narrows a zone and never widens it.
The narrowed zones (z01, z03, and seeds five, lead-three-helpers,
lead-five-helpers, roomy, real-agents-22, real-agents-24, cost-30, cost-60
and cost-89) have the same layouts as round 1. Their fingerprints are
unchanged.

**Results on Dylan's real canvas (gap 20):**

| zone | width | fill | area range | big ÷ next | 2nd tidy |
|---|---|---|---|---|---|
| z01 | 16289 → 7462 (step 3) | 0.973 | 0.97–2.00 | 2.79 | no-op |
| z02 | 5855 kept | 0.976 | 0.61–1.54 | 2.02 (kanban now in a column) | no-op |
| z03 | 9330 → 6317 (step 3) | 0.972 | 0.77–2.00 | 1.34 | no-op |
| z04 | 2511 kept | 0.992 | 0.75–2.00 | — | no-op |
| z05 | 3686 kept | 0.973 | 0.83–1.43 | — | no-op |

- Two-tile seed: 2100 wide kept, side by side, 985 → 838 tall. Its browser
  sits at 2.31× (step 2). Side by side at that width, a browser below 2.0×
  cannot exist.
- Film scene: 2300 wide kept, 1480 → 972 tall, fill 0.980.

**What `--tidy-packer-check` asserts now.**
- Every seed's zone keeps its width to 1/64 pt, except:
  - `narrow`, a new seed: two terminals in a zone narrower than a terminal
    at its minimum. It widens to exactly that minimum.
  - The step-3 seeds named in `widthMoves`. Each must narrow and never
    widen.
- The film scene keeps 2300.
- The round-1 15%-area rule for the two-tile seed is gone. Width-kept
  replaces it.
- Fingerprints are re-pinned for two, three, eight, thirteen,
  lead-three-helpers, real-overhang-6, cost-30, cost-60 and the new narrow.
- The probe gains a "width kept" column.

**Cost (debug, best of five):**
- 30 tiles: 8.1 ms (budget 12)
- 60 tiles: 12–13 ms (budget 18)
- 89 tiles: 21–23 ms (budget 25)

The step-2 check runs as a hard pass at the looser cap rather than a full
soft solve, which saved 14 ms at 89 tiles. The width search's fine pass went
from 7 steps to 4, and z01 and z03 came out identical either way.

**Also green:**
- CoreChecks: `--layout-pressure-check`, `--auto-layout-fanout-check` and
  `--jelly-trajectory-probe`.
- The 7 app legs: `--auto-layout-fanout-app-check`, `--jelly-auto-layout-check`,
  `--undo-toast-placement-check`, `--spawn-sizing-check`,
  `--auto-layout-tidy-latency-check`, `--zone-arming-check` and
  `--canvas-undo-check`.

**Pictures:**
- Real canvas: `~/Movies/Array/auto-layout-night/real-canvas/z0N-masonry2.png`
  and `table-masonry2.md`.
- Seeds, including `0-two.png` and `film-scene.png`:
  `~/Movies/Array/auto-layout-night/seeds-masonry2/`.
