# ENV BLOCKER — the visual gates are retina-only, and this host went 1x mid-run

Found 2026-07-25 ~13:12Z while starting `P0.7-retire-isblank-gate`. **Not caused by any ticket.**
`HEAD` (32a0364 / c4d3516) is red on two matrix legs right now, with an unmodified tree.

## What is red at HEAD

```
--ui-pixel-check   FAIL: witness.visibleBorder: border is invisible —
                   luminance delta 0.000 (left 0.000, top 0.000), needs >= 0.030
--ui-baseline-check FAIL: 46 baseline(s) did not match  (0 other render(s) matched)
                   e.g. terminal.topology-migration-note-520x180-aqua.png:
                   7464 of 93600 pixels differ (7.9744%, worst channel delta 111),
                   tolerance 0.0300%
```

Every one of the 46 committed baselines mismatches — not a design change: a rendering change.

## Cause, measured

The host's window backing scale changed from **2 to 1** during this session. Two renders of Lab
cards, 27 seconds apart, written by the app itself:

| time (UTC) | card | logical size | PNG written | implied scale |
|---|---|---|---|---|
| 13:09:25 | `agent.adapter.projection` | 520x260pt | 1040x520px | **2** |
| 13:09:52 | `tiles.managedAgent` | 560x560pt | 560x560px | **1** |
| 13:12:33 | `agent.kind` | 280x96pt | 280x96px | **1** |

`system_profiler SPDisplaysDataType` now reports the **1920x1080 external as `Main Display: Yes`**
(the built-in Retina XDR is the secondary). A borderless offscreen `NSWindow` lands on the main
screen, so `bitmapImageRepForCachingDisplay` follows a 1x backing store.

Both failures follow from that:

1. **`--ui-baseline-check`.** `UIProbeBaseline` normalises to one pixel per point, so dimensions
   still match — but glyph antialiasing and layer compositing at 1x differ from 2x by far more than
   the 0.03% tolerance (measured 8–9% of pixels, worst channel delta 111–140). The 46 committed PNGs
   were blessed on a 2x host.
2. **`--ui-pixel-check`.** `UIProbePixels.expectVisibleBorder` samples
   `borderEdgeSkipPixels = 1` then `borderPixels = round(borderWidth * scale)`. At scale 2 a 1pt
   border occupies pixels 0–1 and the band (offsets 1..2) still lands on it. At scale 1 it occupies
   pixel 0 only, the skip steps past it, and the "border band" is really the fill — hence a delta of
   exactly 0.000 on a correct border, on the fixture as well as the real tile.

## What must NOT happen

Do not bless the baselines to make this green. That would overwrite 46 2x-derived baselines with 1x
renders, and the gate would then be red for whoever runs the matrix on a Retina main display —
trading a real signal for a moving one.

## Two ways out, owner's call

1. **Cheap, immediate:** make the Retina built-in the main display (System Settings ▸ Displays ▸
   drag the menu bar), then re-run `./scripts/run-matrix.sh`. Expected: both legs green again with
   no code change. This restores the run.
2. **Real fix, a ticket of its own:** make the render substrate scale-independent instead of
   host-dependent — `UIProbe.bitmap(of:)` should draw into a `CGContext` at a fixed, declared scale
   rather than through `bitmapImageRepForCachingDisplay`, and `expectVisibleBorder` should sample
   from the edge rather than skipping a fixed pixel count. That makes the committed baselines a
   property of the layout instead of a property of whoever's monitor was primary, which is what P0.6
   claims in its own doc comment. Costs one bless commit at the chosen fixed scale.

Until one of those happens, no ticket in this program can be honestly verified: `run-matrix.sh` is
red before any diff is applied.

## State of `P0.7` when this was found

Implementation is complete and builds; it is parked in `git stash@{0}` ("P0.7-wip", sources only) so
the working tree stays clean. It composes the P0.3–P0.6 gates per static card in both appearances
(`ComponentLabPanel.runStaticCardGates`), by extracting reusable `UIProbeContrast.evaluate`,
`UIProbePixels.sweep` and `UIProbeBaseline.mismatch` out of the three existing legs so there is one
implementation rather than two, and it removes the four hand-picked `distinctSampledColors`
assertions the baselines subsume. It ran to completion at 2x (failing only a provisional coverage
floor, since fixed); at 1x it fails on the same border probe as `--ui-pixel-check`. Two numbers it
still needs, to be measured on a 2x host before commit: the aggregate text-rect and border floors.
