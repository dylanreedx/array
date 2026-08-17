# 26 — Session handoff: pan is the control; zoom still pays the cascade (2026-08-15)

Status: the code state is complete through `ff99949` on `array/zoom-unify`,
**14 program commits** on top of `array/zoom-feel` before this documentation
commit. Pan/zoom ownership is unified and Dylan-confirmed.

> 2026-08-15 continuation: read `.plans/27-bounded-canvas-presentation.md`
> before implementing geometry hold. The all-or-nothing opaque-live fallback
> below is superseded. A later synthetic-shell dogfood build was also explicitly
> rejected by Dylan on 2026-08-16: every tile must retain full visual detail
> during zoom, including browsers and terminals. See `.plans/27` for the current
> full-detail contract.
Pan is effectively at target. Zoom feels materially better after the driver and
symbol freeze, but the live HUD now makes the remaining gap unambiguous: pan
barely moves off cadence; zoom falls as low as ~30 FPS on the same 10-agent
canvas. The cause, recoverable fraction, rejected alternatives, and surviving
architecture are all measured below. Do not start another attribution pass.

Read first:

1. This file — current orientation and continuation contract.
2. [24](24-canvas-camera-unification.md) — complete program/mechanism record.
3. [25](25-session-handoff-2026-08-14.md) — the unification/profile session.
4. `docs/internals/performance-budgets.md` — standing witnesses and exact runs.

## Current product truth

- One `CanvasCameraDriver` owns scroll pan, Cmd-scroll zoom, pinch, glide, live
  anchor composition, display-paced submission, pinch→pan stickiness, and one
  settle signal. Dylan: “they feel unified.”
- Pan remains the control: all-zero camera-work counters, ~0.34 ms offline;
  clean dogfood example p50/p95 **8.33/8.33 ms**, **3% late**.
- Zoom is still not O(1)-feeling. Clean dogfood examples after symbol freeze:
  **23.13/33.60 ms, 59% late** and **22.87/51.04 ms, 53% late**. Dylan with the
  live HUD: “it barely drops when panning … as soon as I zoom it goes as low as
  30.” Believe this over green layout-only legs.
- The tripwire stack is unchanged in kind: each world-plane `setBoundsSize`
  fires `_NSViewHierarchyDidChangeBackingProperties`; AppKit re-tiles nested
  scroll views, re-solves Auto Layout, walks the native tree, and commits/rasterizes
  the ~10 real managed-agent subtrees every zoom frame.
- `canvas.geometry-hold-probe` proves **98.5% recoverable including one final
  bake**: stepped ~30–31/37–39 ms p50/p95 versus held 0.01/0.01–0.02 ms;
  120 bounds-size writes → 1,200 transcript layouts versus held 0 → 0.

## Continuation commits after the original handoff

| commit | result |
|---|---|
| `574e7f7` | Every SF Symbol below the canvas plane is now a shared explicit 2x template bitmap; tint/appearance and compact-status geometry probes green. |
| `2682a29` | Real 10-agent geometry-hold A/B, exact world-plane bounds-size counter, dedicated display-dependent flag/matrix leg, docs; 98.5% recoverable. |
| `208bd93` | Preserved and rejected supported live magnification and gesture-time snapshot candidates with real display numbers. |
| `135523a` | Opt-in on-canvas frame HUD, click/AX transparent and absent by default. |
| `ff99949` | HUD is live: rolling 30-frame time-weighted FPS / late share / p95 at 4 Hz, using the existing recorder link. |

## Rejected presentation paths — do not rediscover these

1. **Transforming `worldPlane.layer` or another AppKit-owned backing layer.**
   Explicitly rejected: view/layer geometry, hit testing, AX, and AppKit ownership
   desynchronize.
2. **A layer-hosting view containing the native tile tree.** Apple explicitly
   says not to add subviews to a layer-hosting view. An owned root layer is not
   a loophole for carrying AppKit-created descendant layers.
3. **`NSScrollView` magnification.** Correct anchor (`0.000 px` error), wrong
   cost: 32.62/43.25 ms p50/p95 on the real fixture, 100% late, 1,200 transcript
   layouts over 120 ticks. It reproduces the cascade through a supported API.
4. **Fresh viewport snapshot at gesture start.** Proxy transforms are excellent
   (0.04/0.07 ms p50/p95, zero native layouts), but capture is 22.07 ms and
   24.4 MiB at 1600x1000 Retina, misses newly exposed zoom-out world, and
   `cacheDisplay` cannot generically composite WKWebView/Ghostty pixels.
5. **Recursive redraw-policy tricks.** They may suppress some raster work but do
   not remove the bounds-scale backing/layout cascade and are unsafe for native
   controls and heavyweight surfaces.

## The surviving geometry-hold architecture

Build a **precomputed, byte-bounded tile/zone presentation cache** while idle;
never capture the whole viewport synchronously on pinch.

- Cache capturable installed tile/zone chunks by content version, size/scale
  bucket, and appearance. Account decoded bytes (`pixelsWide × pixelsHigh × 4`),
  evict deterministically, and generate/refine a few entries per display interval
  only while idle.
- Installed view class is the live-surface authority—not `Tile.kind`:
  `TerminalTileNSView` (Ghostty) and `BrowserTileNSView` (WKWebView) are opaque
  live blockers. Restart/snapshot variants and `BrowserInspectorTileNSView` are
  capturable. Fail closed for new view classes.
- At zoom gesture start, if the desired/preload region has complete cached
  coverage and no opaque live blocker, hold native `worldPlane` geometry and
  display the Array-owned shallow proxy tree. Keep `canvasState.viewport` as
  desired truth.
- Presentation affine from baked B to desired D:
  `q = D.zoom / B.zoom`; screen translation
  `((B.x-D.x)*D.zoom, (B.y-D.y)*D.zoom)`. This composes pinch, glide, and sticky
  pan around the driver's live anchor.
- If zoom-out enters an uncached or opaque-live region, bake desired geometry
  once, remove the proxy, and latch stepped fallback until settle. Never
  oscillate within one gesture.
- During hold, native AppKit hit testing/AX describes baked geometry while the
  model describes desired geometry. Pre-dispatch pointer/drop/AX interaction
  must force a synchronous bake before AppKit chooses a descendant. Do not bake
  from `hitTest` recursively.
- On driver settle, keep the proxy visible, apply desired bounds once, flush the
  real display transaction, refresh zoom-dependent chrome/overlays once, then
  remove the proxy. Required count: 0 native bounds-size writes over N held
  commits, exactly 1 bake.

Acceptance on Dylan's preserved 10-agent canvas: live zoom HUD approaches the
pan shape, no blank/exposed regions, no anchor jump, final screen-frame/hit
oracle zero, and the one-bake stall is covered by the proxy rather than exposed.

## Frame instrumentation contract

Preview flags:

```text
CONTINUUM_FRAME_STATS=1
CONTINUUM_FRAME_STATS_FILE=/tmp/array-zoom-current-2026-08-14.log
CONTINUUM_FRAME_HUD=1
```

The file log remains a whole-gesture report with p50/p95/worst/late share. The
HUD is live: rolling last 30 intervals, **time-weighted average FPS**, late share,
and p95, published at 4 Hz. It owns no timer, display link, animation, traversal,
or event handling. A median-derived FPS was deliberately removed because a
bimodal trace could print 120 FPS with 40% late frames.

The current preview is `~/Desktop/Array Dev scalability.app`, project root
`~/array-scratch-canvas-zoom`, support `/tmp/zm-sup.lbZTuG`. Reuse that support
directory or duplicate managed-agent records are minted. Launch with `open
--env`, never the bare executable. Kill dev apps by pid because Desktop builds
share `dev.arrayapp.macos.dev`. `/Applications/Array.app` is untouchable.

## Witness inventory

- Green/trustworthy: `canvas.pan`, `canvas.fractional-pan`,
  `canvas.gesture-transition`, `canvas.raster`, camera coalesce, momentum,
  `canvas.geometry-hold-probe`.
- Known product gaps: `canvas.zoom` (144 layouts vs 12), zoom invalidation probe,
  `canvas.magnify-slope` duration slope.
- Opt-in/intentionally red research record: `canvas.scroll-magnification-probe`
  on live magnification p95 and gesture-start snapshot capture.
- Blind spot still owed: a deep-content raster witness for terminal/browser and
  transcript content beyond the real-agent geometry-hold fixture.

## Next steps, in order

1. Implement the bounded cached presenter behind an opt-in/default-off switch
   with deterministic lifecycle, byte, coverage, anchor, interaction, and
   one-bake witnesses. Prove it in the real 10-agent display fixture first.
2. Put that build in the preserved preview and let Dylan compare live pan/zoom
   HUD shapes. His feel report is the product gate.
3. If accepted, make it default, remove the experiment switch, and update
   `canvas.zoom`/invalidation budgets from per-bucket layouts to one bake per
   gesture.
4. Hand-tune glide/gain/stickiness with Dylan; freeze constants and delete all
   `ARRAY_ZOOM_*` / stickiness env knobs.
5. Run one clean full matrix, then merge `array/zoom-unify` →
   `array/integration` under Dylan's identity, no AI trailers. No release.

## Traps and working method

- Never edit Sources while a matrix runs in this worktree; `swift run` legs
  rebuild mid-run.
- Real display probes require `window.displayIfNeeded()` **and**
  `CATransaction.flush()`.
- Matrix inventory records and legs are alphabetical.
- A green count leg cannot overrule Dylan's feel report. Frame stats give the
  shape; a sample names the stack; exact counters prove attribution.
- Treat wording as architecture evidence: “when you start panning” found the
  seam; “still a little bit” found the residual; “pan barely drops, zoom hits
  30” is the acceptance boundary for geometry hold.
