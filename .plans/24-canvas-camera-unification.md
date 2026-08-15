# 24 — One camera: the pan/zoom unification (2026-08-14)

Status: **built and witnessed on `array/zoom-unify`; awaiting Dylan's hand-tuning
pass, then merge.** Successor to [23](23-canvas-zoom-handoff.md) — read that for
the two-problems-one-costume reframe this program executed.

## The reframe that finished the reframe

23 established that zoom was throughput + interaction. This session Dylan added
the sentence that named the real architecture defect: **"it lags when zooming
when you start panning … they should be unified."** An 8-agent exploration
confirmed it mechanically. The lag lived at the *seams* between three handlers
that each wrote the viewport per event and did not know the others existed:

1. **Glide-vs-pan fighting** (prototype build): nothing on any pan path stopped
   the momentum glide; it kept zooming around a FROZEN anchor while the pan
   divided `dx / zoom` by a zoom changing underneath it. A pointer-tracking
   error — felt as lag at any frame rate.
2. **Settle burst displaced into the pan**: every glide step re-armed the
   0.10 s settle, so its ~48-invalidation burst fired 330–470 ms after finger
   lift — mid-pan.
3. **The post-gesture cliff (every build)**: `canvasDidChange` re-armed two
   debounce timers per camera step; both fired ~200 ms after the LAST step —
   exactly when the next gesture begins. One of them ran a main-thread JSON
   encode + decode-validation + backup copy + **two fsyncs**.
4. **Monitor asymmetry**: pinch zoomed the canvas over tile content, but the
   follow-through scroll went to the tile — the canvas stopped dead mid-handoff.
5. **No coalescing anywhere**: N events per frame = N full `setViewport`
   passes; below zoom ~1.22 an SF Symbol NSImage was minted per tile per step;
   the focus border re-added its marching-ants animation per step.

Two prototype findings from the exploration mattered as much as the fixes:
`ARRAY_EXP_ZOOM_CACHE` was **placebo** (it suppressed redraw only on the tile's
own backing layer, which has no `draw(_:)` and paints nothing, and leaked
`.onSetNeedsDisplay` onto tiles panned off-screen before settle), and the
zoom-feel branch carried a default-on pan regression (`layoutChrome`'s
unconditional `addSubview` z-reorder per visible tile per pan event, invisible
to every counter).

## What landed, commit by commit (`array/zoom-unify`, branched from zoom-feel)

- `ba4dfba` — chrome-pass repairs: conditional z-order repair (+ counter),
  bucketed close-button floors, shared glyph-image cache; both experiments
  removed.
- `7e767e9` — **`CanvasCameraDriver`** (Slice 2 of .plans/22, built at last):
  one owner for scroll pan, Cmd+scroll zoom, pinch, and the glide. Accumulate
  input (pan in screen px, zoom in log space), commit at most once per display
  interval, leading-edge apply so sparse input keeps today's latency. Glide is
  display-linked with a Timer backstop, decays by real dt, composes with pan
  around a live anchor, stops at the clamp, dies on any external viewport
  write. One curve, per-device gains. Session stickiness routes the
  pinch→pan follow-through to the camera even over tile content.
  `setViewport` stays synchronous and remains the single truth.
- `17e6461` — the cliff moved off the gesture path: driver commits defer
  cursor rects + delegate to the driver's settle; the debounced canvas save
  persists on a serial background queue (synchronous flush serializes behind
  it); marching ants attach-if-missing.
- `96d07fc`, `8951073` — witnesses registered: `--canvas-camera-coalesce-check`
  (6 events in one interval: 6 applies before, **2** after),
  `--canvas-zoom-momentum-check` (glide/cancel/clamp/compose mechanics),
  `canvas.gesture-transition` (the seam itself: pan-after-zoom inherits **0**
  chrome and **0** layout passes; interleave adds exactly zero over its
  pure-zoom control; first-5-pan-steps spike 0.05 ms over the pan median).

## Numbers

```
coalesce:            6 events/interval  6 applies -> 2, final viewport preserved
canvas.zoom          chromeRedraws      1,392 -> 144   (bucket bound 192)
canvas.zoom          tileLayoutPasses   1,380 -> 144   (KNOWN-RED vs product 12)
invalidation probe   C − E              696 -> 144
gesture-transition   T-pan chrome/layout 0 / 0; I − Zc = 0 / 0; spike 0.05 ms
canvas.pan           unchanged          all zeros, ~0.34 ms/step
magnify-slope        work slopes 0 / 0; durationSlope ~1.9–2.3 ms (AppKit traversal, KNOWN-RED)
```

## What is deliberately NOT done

- **Hand-tuning with Dylan.** Every glide constant is env-tunable for the
  session (`ARRAY_ZOOM_GLIDE_HALFLIFE_MS`, `ARRAY_ZOOM_GLIDE_ENGAGE`,
  `ARRAY_ZOOM_GLIDE_FLOOR`, `ARRAY_PINCH_ZOOM_GAIN`, `ARRAY_SCROLL_ZOOM_GAIN`,
  `ARRAY_CAMERA_STICKINESS_MS`); after sign-off the tuned values become code
  constants and the env keys go away. The preview app
  (`~/Desktop/Array Dev scalability.app` on `~/array-scratch-canvas-zoom`)
  runs the driver build with `CONTINUUM_FRAME_STATS=1`.
- **The rasterization witness (`canvas.raster`).** Still the biggest witness
  gap: nothing counts real draws. Draw counters in `TitleBarView.draw` +
  content sites, a windowed fixture pumping `window.displayIfNeeded()`.
- **`--perf-budget-magnify-slope-check` registration.** The scenario exists
  and its work slopes gate at 0, but it has no matrix leg yet; register it
  KNOWN-RED (durationSlope is the AppKit-traversal residual).
- **Profiling the driver build during a real pinch.** The dominant cost has
  moved after every fix; sample the new build before believing anything.
- `transcript.delta` duration RED — separate program, untouched.

## The real-pinch profile on the driver build (2026-08-14, tripwire sample)

Dylan on the unified build: "they feel unified! … but it is now distinctly the
zooming still choppy BUT this is the best it has felt." Frame stats agree and
sharpen it: zoom gestures run a PERFECT 8.33 ms median with **33–47% of frames
stalling at 40–120 ms** (pans in the same log: 2–5% late). A CPU-tripwire
`sample` during a real pinch (12 s, 8,963 main-thread samples, 10 managed-agent
tiles) names the mechanism:

- `CanvasNSView` zoom step → `setBoundsSize` on the world plane →
  **`_NSViewHierarchyDidChangeBackingProperties`** — AppKit treats every
  per-frame bounds-size change as a backing-properties change for the whole
  descendant hierarchy.
- Downstream, per frame, across 10 real agent subtrees: NSScrollView re-tiling
  (`tile`/`setFrameSize`/`reflectScrolledClipView`), Auto Layout re-solve
  (`NSISEngine`, `NSStackView updateConstraints`), full window layout
  recursion, and **SF Symbol re-rasterization** (`_NSSimpleImageView
  updateLayer` → `NSSymbolImageRep draw` → `CUINamedVectorGlyph
  rasterizeImageUsingScaleFactor:` — vector glyphs re-render at each new
  effective scale). ~52% of the main thread sits inside CA commits.
- OUR work is gone from the profile: `refreshZoomDependentChrome` 8 samples,
  TitleBarView 199, transcript 259, driver+funnel ~500, canvas-save queue 6.

**The remaining lever, named:** stop changing the plane's bounds-size on every
gesture frame. Hold real geometry during the pinch, present the zoom visually,
bake bounds once at settle — one backing cascade per gesture instead of ~120/s.
That is Slice-5-adjacent L2/L3 work with a real design question (the supported
way to present the held zoom; a raw transform on the view-backing layer is the
explicitly rejected shortcut), and it produces the scaled-not-relaid mid-pinch
content Dylan pre-approved contingent on exactly this profile. A cheaper trim
first: freeze chrome/status SF Symbols to bitmap images (template-preserving),
killing the vector re-raster (~10–15% of the commit cost) with no architecture
change.

## Traps this session added or re-confirmed

- Do not edit Sources while a matrix run is in flight in the same worktree —
  its `swift run` legs rebuild mid-run and compile your half-edited state.
- The inventory lists are alphabetical; a new leg goes in sorted position in
  BOTH the `check` and `leg` lists.
- All of .plans/23's traps stand (prefix-matched scenario filter, `grep -c`,
  zsh word-splitting, kill dev apps by pid, one root per install).
