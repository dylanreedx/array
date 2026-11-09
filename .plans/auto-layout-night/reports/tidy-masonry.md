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
