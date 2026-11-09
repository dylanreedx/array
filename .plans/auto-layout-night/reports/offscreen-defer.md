# Stream: defer offscreen tile relayout on tidy

Branch `array/aln-offscreen-defer`, worktree `.worktrees/aln-offscreen-defer`,
off `array/auto-layout-night` at `f52c85bb`. 2026-11-09, debug build, local
commits only.

## In short

With the camera on 12 of 89 tiles, a tidy now lays out 37 bodies before the
movement starts instead of all 89. Motion starts at 62–72 ms instead of
95–101 ms.

Why it was paying for all 89:
- The canvas already parks offscreen tile bodies ("far parking"): a body more
  than half a viewport off screen is moved out of the view tree, leaving an
  empty stand-in.
- But `TileNSView.setFrameSize` brought any surfaced body back on a size
  change, and a far-parked tile counts as surfaced. That rule exists for baked
  pictures, which would be stale at a new size.
- A far-parked tile has no picture. Still, every resize pulled its body back
  into the tree and AppKit re-tiled its scroll views inside the commit.

## What changed

- `050c52b1` perf(auto-layout): leave far-parked bodies parked when tidy resizes them
- `92907f52` test(auto-layout): witness that tidy defers offscreen body relayout

How it works:
- **Parked bodies stay parked on resize.** `TileNSView.setFrameSize` no
  longer brings a far-parked body back. The tile's frame and model change at
  once.
- **They come back once, at the new size.** The existing return path
  (`returnFarParkedTiles`, a quarter-viewport lead-in on every camera step;
  tiles already on screen always return) installs the body at its new size,
  laid out exactly once, before the commit that shows it.
- **Tidy can carry a parked tile into view with no camera step.** So
  `applyLayoutTransaction` now returns any of the transaction's tiles that are
  parked and whose new frame lies within the lead-in margin
  (`returnFarParkedTiles(movedBy:)`). It checks only the transaction's own
  tiles, which the function already walks, so a drag event pays no
  visibility-index rebuild.
- **A counter fix with no behaviour change.** `promoteBodyToNative` clears
  `isFarParked` before installing the body, so the install's layout counts as
  the body's relayout (`qaBodyResizeCount`).
- **Persistence is untouched.** The model and frames change at once; only the
  parked body's layout waits.
- **Scope.** This uses the existing parking machinery only: no new per-frame
  or per-tile scan, no picture stand-in.
- **Kinds covered.** Kinds that can park: notes, files outside source view,
  agents. Terminals and browsers can't park (Ghostty surface, WKWebView), so
  an offscreen terminal or browser still resizes in the commit.

## Before / after: 89 tiles, camera on 12 (60 parked by production's own pass)

| | bodies laid out in the commit | movement start | present layout | commit (flush) |
|---|---|---|---|---|
| before (resize guard reverted) | 89 (all 60 parked ones pulled back) | 95.1 / 99.2 / 101.2 ms | 46–51 ms | 17–18 ms |
| after | 37 (29 native in view + margin, 8 moved into view) | 62.4 / 62.7 / 63.8 / 65.4 / 72.1 ms | 27–32 ms | 14–17 ms |

The solve is 11–14 ms in both. What remains before motion is laying out the
37 bodies that are in or near view, which has to happen before they're seen.

## Witness: `--tidy-offscreen-defer-check`

Setup:
- Production mount, offscreen window, 89 untidy notes in one zone.
- Camera at 1.5× on the zone's corner, so 12 tiles are in view.
- Production's settled parking pass, run to completion: 60 tiles parked.
- Tidy dispatched exactly as the zone menu dispatches it.

It asserts:
- Every parked tile the tidy left outside the return margin is still parked,
  with no body relayout.
- Every tile in view is a real body, not parked, at its new width.
- Panning onto a still-parked tile brings it back laid out exactly once, at
  its new size, before anything is drawn. A later pan doesn't lay it out again.
- Positive control: native resized tiles do register their relayout.

Teeth: with the `setFrameSize` guard reverted it fails with "52 parked tiles
still outside the return margin were unparked by the resize".

## Checks (exit codes)

On the final code, all exit 0: `--tidy-offscreen-defer-check` (4 runs),
`--shared-area-zone-check`, `--canvas-visibility-index-check`,
`--auto-layout-tidy-latency-check`, `--tidy-zone-shortcut-check`,
`--jelly-auto-layout-check`, `--auto-layout-fanout-app-check`,
`--layout-commit-truth-check`, `--canvas-pointer-path-check`,
`--zone-arming-check`, `--spawn-sizing-check`, `--canvas-undo-check`,
`--tile-insert-slide-check`.

That list ran on the binary before the last test-only edit, which added the
direct parking assertion. The changed check was rerun green on the final
binary.

`--tile-surface-residency-check` exits 1, already red on the base. It fails
with "flag off must still pay the native cascade — a gesture that laid nothing
out was not a gesture" on base `f52c85bb` (built and run in this worktree),
identically with my resize guard reverted, and with the display awake
(`caffeinate -u`). Not caused by this change.

Every leg was checked for `makeKeyAndOrderFront` / `orderFront` before running;
all use offscreen windows.

## Not done

- An offscreen terminal or browser that tidy resizes still lays out in the
  commit; neither kind can park.
- A parked tile whose animation path crosses the view but whose start and end
  are both outside the lead-in margin is not returned for the slide. That
  would need a path test, and is rare at a 110 ms slide.
