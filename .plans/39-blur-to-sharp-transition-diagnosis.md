# The blur→sharp transition: eight mechanisms, one symptom

Dylan, 2026-08-19, on the release preview after the blank-tile fix:

> "the transition between blury and focused tile is still so janky, stuttery,
> glitchy the whole tile shifts as well as the content inside... furthest thing
> from smooth"

"The whole tile shifts as well as the content inside" is a GEOMETRY report, not
a resolution report. A pure density change sharpens in place. Something moves —
so the surface and the native body disagree about where things are, and/or the
body's content genuinely re-lays-out across the swap.

Eight-agent fan-out over the swap path, the geometry, the park round trip, the
zoom mechanism, the cadence, the layer tree, the witnesses, and the prior art.
Nothing below is a proposal; it is what the code does. Confidence is marked.

## Ground truth established first

- **Zoom is AppKit bounds scaling on ONE view** — `CanvasWorldPlaneView.applyCamera`
  (:96-116) writes `setBoundsSize(viewportSize / zoom)` and `setBoundsOrigin`.
  No transforms anywhere in `Canvas/` (a raw transform on an AppKit-owned backing
  layer is explicitly out of bounds — performance-budgets.md:855).
- **Tile frames are never recomputed per zoom step.** Tiles are children of the
  plane at WORLD frames; the parent bounds scale does all the scaling. The body's
  frame is deliberately zoom-independent (`contentTopInsetWorldHeight`, a
  constant — TileNSView.swift:915).
- **Therefore a descendant's effective scale is `zoom × backingScale`** — the
  canvas asserts this model itself at CanvasNSView.swift:1722-1725.
- **The park is a SIBLING of the world plane** (CanvasNSView.swift:566-579), so a
  PARKED body's effective scale is `1 × backingScale`. This single fact drives
  mechanisms 5 and 6.
- The swap replaces only the tile's CONTENT view. Chrome, border, title bar stay
  live and keep re-rendering at the zoomed device scale.

## The mechanisms, ranked by (visual impact × confidence ÷ cost to fix)

### 1. Scroll offset is not in the surface revision — CERTAIN
`TileSurfaceRevision` (TileSurfaceStore.swift:11-19) is content version + body
size + appearance name. **No scroll offset.** Neither family's
`surfaceContentRevision` moves when the user merely scrolls
(NoteTileNSView.swift:83; ManagedAgentTileNSView.swift:333-337). So a scroll
between bake and swap leaves the surface a faithful picture of a DIFFERENT
scroll position, and the swap snaps to the real one. This is the largest single
displacement available in the system.

### 2. The hosted root layer's frame is written from `bounds`, not `frame` — **CONFIRMED AND FIXED (2026-08-19)**
Measured, both branches resolved: AppKit sets the root layer's frame correctly
from the view's frame in the swap turn, and then `layout()` **corrupts** it.
```
pre-pump   layer.frame = (0, 24, 420, 276)   correct, AppKit's sync
post-pump  layer.frame = (0,  0, 420, 276)   layout() moved it 24 pt UP
```
Not on every tile in the same pass — tile 2 of 3 kept the correct frame — which
is why the shift looked intermittent rather than uniform. The write was also
UNNECESSARY: AppKit already maintains a root layer's frame, which is why the
pre-pump value was right before `layout()` had ever run. Fixed by deleting the
override; witnessed by `checkTheSurfaceLandsExactlyWhereTheBodyDrew` (RED at
24 pt before, GREEN after), which also covers a reused host across a zoom.

Original framing:
`TileSurfaceHostView.layout()` (:56-61) writes `surfaceLayer.frame = bounds`,
i.e. `{0,0,w,h}`. But `surfaceLayer` IS the view's root layer (`layer =
surfaceLayer`, :47), whose frame in its superlayer's space is the view's FRAME —
`{0, 24, w, h-24}` (TileNSView.swift:504). Exactly one of these is true:
- AppKit's geometry sync overwrites it every layout → the guard `if
  surfaceLayer.frame != bounds` is permanently false-negative and re-dirties the
  layer on EVERY layout pass — the identity-write mistake its own comment claims
  to avoid; or
- it is not overwritten → the surface sits 24 world pt off in y.
Disambiguate by printing `surfaceLayer.frame` right after a layout pass. Cheap.

### 3. Implicit CA animation on the swap — **REFUTED BY MEASUREMENT (2026-08-19)**
`surfaceLayer.animationKeys()` is EMPTY at the swap turn, after a pump, and after
a camera step, on every surfaced tile. No implicit animation attaches. This was
the leading hypothesis and it is wrong; the assertion is kept as a regression
guard inside `checkTheSurfaceLandsExactlyWhereTheBodyDrew` so a future
transaction-less write cannot start animating the picture unnoticed.

Original reasoning, retained because it is sound and only the fact is wrong:
The host is layer-**hosting**, so AppKit is NOT the layer's delegate; no
`actions` dict is set, and no call site on the swap path is wrapped in a
`CATransaction` with actions disabled (the only `setDisableActions` uses in these
files are the corner brackets and the focus border). A hosted layer's
`frame`/`position`/`contents` change is therefore eligible for CALayer's default
implicit animation — **~0.25 s**. If it fires, every demote animates the content
sliding/scaling into place. That is the reported symptom almost verbatim.
Witness: `surfaceLayer.animationKeys()` non-empty after a demote + pump.

### 4. The layer's geometry lands a frame late — CERTAIN
A freshly built host has `surfaceLayer.frame == .zero` until AppKit next runs
`layout()`; a REUSED retained host (TileNSView.swift:178-181) carries the
PREVIOUS gesture's frame until the same pass. The host VIEW's frame is assigned
synchronously (TileNSView.swift:436). With `contentsGravity = .resize` (:41) a
wrong-sized layer does not clip — it **stretches**. One visibly wrong presented
frame per demote, minimum.

### 5. The park changes effective scale, which re-wraps text — CERTAIN
Correction to an early guess: the body's frame does NOT collapse in the park —
size is preserved, only the origin moves (TileNSView.swift:170/194). The real
path is effective scale: plane-scaled (`zoom × backing`) → park-unscaled
(`1 × backing`). Auto Layout snaps interior widths to the backing grid of
whichever applies, and this repo already measured the consequence:
`AssistantProseRenderer.swift:133-141` — "pixel snapping at the effective scale
(which includes the zoom) re-rounds interior widths by up to one device pixel —
±1.3 pt at zoom 0.4". The transcript's measurement cache buckets width at 1 pt
(AgentBlockMeasurementCache.swift:84) and the layout at rounded points, so that
jitter is a guaranteed cache miss → re-measure → re-wrap → every row below moves.
Prose rows are laid out at the CACHED width, not the current one
(AssistantProseRenderer.swift:167), so inside the 2 pt hysteresis content keeps
its PARKED width after the swap, and outside it everything re-wraps. Both
branches are visible motion.

### 6. Parked layout advances without repositioning; no scroll anchor — CERTAIN
- `transcriptLayout.prepare()` is forced while parked, but item views are
  re-framed only for `indexPathsForVisibleItems()`, which is degenerate in the
  park (AgentTranscriptListView.swift:1034-1040). Attributes move, materialized
  views do not. On promote the live display cycle repositions them all at once.
- Nothing captures scroll at demote or restores it at promote
  (TileNSView.swift:209-220); the only anchor logic
  (AgentTranscriptScrollController.swift:37-66) is never called from the promote
  path.
- Stick-to-bottom RUNS while parked and writes a new offset from degenerate
  geometry (:52-61). That offset becomes visible in one jump on promote.

### 7. Rounding asymmetry, `.resize`, and default filtering — CERTAIN ARITHMETIC
The bake rounds OUT to integral backing pixels; the destination rect is raw
`bounds` with no snapping anywhere (`backingAlignedRect|convertToBacking|
NSIntegralRect` — zero call sites in `Canvas/`). `.resize` squeezes the surplus
back in, scaling the whole picture by `bounds / roundedBounds`, origin-anchored —
up to ~1.4 world pt at zoom 0.35. `bakedScale` measures WIDTH only
(TileSurfaceStore.swift:112), so vertical rounding is unmeasured and the aspect
can differ → **non-uniform** stretch. No `minificationFilter`/
`magnificationFilter` is set anywhere → default `.linear`, so the surface is
bilinearly smeared while the native body renders text at the true subpixel phase.

### 8. It all fires several times a second — MEASURED IN DYLAN'S LOG
`80 → 78 → 80 → 76 → 78 → 80` every 50-250 ms; ~30 promotions and ~33 demotions
in 9 s; surface memory 70 → 122 MB from repeated re-bakes. Each crossing is a
measured ~5 ms promote + ~5 ms demote of AppKit subtree surgery, and the promote
runs INLINE in `setViewport` — on the gesture's own frame. Two drivers:
- the catch-up path is promote-only BY DESIGN (promote on pass N, re-bake and
  demote on pass N+1), so every caught-up tile pays a full round trip;
- `zoomingIn` is computed from the zoom delta BETWEEN 10 Hz passes, not from
  gesture direction (CanvasNSView.swift:1799-1801, `lastResidencyZoom` :2010), so
  any pass where zoom did not happen to increase re-opens the demotion budget
  mid-zoom.
**The log undercounts**: `logResidencyIfChanged` early-returns unless the
surfaced COUNT changed (:1957-1959), so every pair that nets to zero is invisible.

### Also present, unrelated to surfaces
Chrome floors are quantised into geometric buckets, 4 steps/octave, rounding DOWN
(TileNSView.swift:881-901). Crossing a bucket changes the title bar's world
height and the close button's size and re-mints the SF Symbol — a visible chrome
snap roughly every 19% of zoom, entirely independent of residency.

## Why the witnesses are all green

- `checkPixelEquivalence` (TileSurfaceResidencyChecks.swift:606-660) compares the
  stored surface against a fresh `bake(body)` — **both sides go through
  `bitmapImageRepForCachingDisplay`**, so every bake-vs-display disagreement in
  mechanism 7 is invisible to it by construction. It compares two images at their
  own origins and never looks at a rect, a frame, or a position: a tile drawn 3 px
  off still scores 0.000. Its own history records the calibration trap — a
  resampled comparison once gave 4.44 vs 4.62, "a gate that cannot fail".
- `qaTileScreenFrameMismatchCount` checks the tile CONTAINER, never the content
  view, the host, or the parked body — and is only ever read by perf scenarios at
  settle points, never during a swap.
- **No witness anywhere asserts surface-vs-body placement.** None asserts anything
  temporal about a swap — no intermediate-frame, no-flicker, or cadence property.
  The harness pumps `layoutSubtreeIfNeeded` + `displayIfNeeded` +
  `CATransaction.flush()` synchronously (:177-181), which is precisely why
  fixtures never observe the deferred turn that mechanisms 2, 3 and 4 live in.

## Reading

The visual symptom is not one bug. Mechanisms 2, 3, 4 and 7 make a single
transition render wrong; 1, 5 and 6 make the content genuinely move across it;
8 fires the whole set several times a second. Softness — the thing Leg B was
scoped to fix with headroom baking — is not in this list. Headroom baking would
make these transitions RARER without making any one of them CLEAN, which is
why Leg B should not go first.

The park being a sibling of the world plane is the shared root of 5 and 6, and
plausibly of part of 1. A park INSIDE the plane (offscreen but real, clipped)
would preserve effective scale and give a non-degenerate `visibleRect` — killing
three mechanisms at their source. That is an architectural option to weigh, not
a patch, and it trades against the cost the zero-sized park exists to avoid.
