# 37 — Next: always-surfaced residency (slice 2)

Date: 2026-08-18

Handoff and forward plan for the unbounded-canvas program after slice 1 shipped.
**Read this first.** Then `.plans/36` (what slice 1 built and why its policy was
refuted), then `.plans/34` (design + decision ledger I1–I16).
`.plans/31`/`32`/`33` are the frozen evidence, target architecture, and test
architecture.

## Repository state

- branch `array/integration`, HEAD **`10c49c2`** — "Add tile surface residency
  behind a default-off flag". 13 files, 2,664 insertions, 0 deletions.
- **Uncommitted (2026-08-18, Step 0):**
  `Sources/ContinuumRevived/App/TileSurfaceResidencyChecks.swift` (+287) —
  `checkBakeCost`, plus a `tileSize` parameter on the `World` fixture, plus the
  new "no bake while parked" gate. Check-only; **no production code changed**.
  Docs updated alongside it: `docs/internals/performance-budgets.md` and this
  file. The leg is green in 11.7 s and still fails under
  `TILE_SURFACE_HALF_SCALE=1`.
- `scripts/run-matrix.sh` ran **green** before that commit: 172 legs, 11
  KNOWN-RED all documented and expected, zero unexpected failures, zero
  stale-allowlist passes. Both new legs printed in the end-of-run summary and
  passed.
- **15 untracked files are Dylan's — preserve every one.** `.plans/17`–`21`,
  `.plans/29`–`37`,
  `docs/38-tickets/96-agent-sidebar-product-redesign/_DESIGN.md`,
  `docs/internals/iteration-time.md`. All `.plans/` files in this program are
  deliberately untracked, matching `17`–`33`. **Dylan has not ruled on whether
  to commit them** — asked once, not answered; do not decide it unilaterally.

## What exists now, and is reused unchanged

Flag `continuum.tileSurfaceResidency.enabled` / env
`ARRAY_TILE_SURFACE_RESIDENCY`, **default OFF**, deliberately not in Settings.

| piece | file |
|---|---|
| the flag + caps | `Sources/ContinuumRevivedCore/TileSurfaceResidencyConfig.swift` |
| layer-hosting surface body, owns `viewDidChangeBackingProperties` | `Canvas/TileSurfaceHostView.swift` |
| surface + revision + `cacheDisplay` producer | `Canvas/TileSurfaceStore.swift` |
| demote/promote, `surfaceableBody` hooks, `hitTest` promotion | `Canvas/TileNSView.swift` |
| the only family opted in | `Canvas/ManagedAgentTileNSView.swift` |
| `onActivityBegin`, symmetric with `onSettle` | `Canvas/CanvasCameraDriver.swift` |
| park, transitions, per-step sharpness, cleanup, counters | `Canvas/CanvasNSView.swift` |
| the witness | `App/TileSurfaceResidencyChecks.swift` |

Proven: camera step **25.18 ms → 0.16 ms** at 12 real agent tiles; the producer
is **pixel-exact** (mean channel difference 0.000, and 1.156 under
`TILE_SURFACE_HALF_SCALE=1` so the gate bites); streaming survives a park;
`hitTest` promotion is lossless; nothing is stranded on tile removal or zone
switch; flag off changes nothing.

## Why slice 2 is always-surfaced

**Partly superseded by Step 0 below** — the cost argument here still holds, but
the producer cannot bake a parked body, so read the fork before implementing
anything. The reasoning is kept because it is still why "in motion only" is dead.

Slice 1's policy — native at rest, surfaced in motion — is refuted by its own
witness. Entering motion costs ~4.7x a native step, attributed per call: host
construction/reuse **0.00 ms**, `setContentView` removing the deep body **~2.1
ms/tile**, `park.addSubview` re-adding it **~2.9 ms/tile**. Plain AppKit subtree
surgery. Any policy that reparents per *gesture* pays that twice per tile per
gesture.

Always-surfaced reparents once per *interaction* instead, and interactions are
rare next to camera gestures. That is the only cost structure the measurement
leaves open. It is also I5, which Dylan already approved — slice 1 narrowed away
from it and the numbers sent us back.

## Step 0 — DONE, and it changed the plan

**Question: what does ONE `cacheDisplay` bake of a real agent body cost?**
Measured 2026-08-18 in `--tile-surface-residency-check` (`checkBakeCost`), at two
body sizes so it extrapolates by area rather than by hope. The leg is green and
the numbers are published in
[docs/internals/performance-budgets.md](../docs/internals/performance-budgets.md).

| body | surface | clean bake, in plane | clean bake, parked | streaming refresh (layout + bake), parked | one streamer at 30 Hz | 50 surfaces |
|---|---|---:|---:|---:|---:|---:|
| 420x300 | 840x552 (0.46 MP) | 0.90 ms | 1.29 ms | 4.45 ms | 13.4% of a core | 88 MB |
| 760x900 | 1520x1752 (2.66 MP) | 1.91 ms | 3.93 ms | 12.31 ms | 36.9% of a core | 508 MB |

**The cost answer: a bake is affordable, refreshing a streamer is not.**
Allocation is 0.01 ms and the draw is the whole cost. One bake fits a frame (now
gated). But at a realistic agent-tile size only **0.7 refreshes fit an 8.3 ms
frame**, and one visible streamer at the transcript's 30 Hz gate is **37% of a
core**, continuously. The kill condition named above fires.

**The correctness answer is the real finding, and it is stronger: a body cannot
be baked while it is parked at all.** Against an in-plane bake of the same body
at the same content, a parked bake differs by **3.2844** (420x300) and **7.4126**
(760x900) mean channel difference. A row that arrives while parked advances the
model — rows 10 -> 11 — and changes the pixels by **0.0000**.

The cause is measured, not inferred. The transcript's `visibleRect` in the plane
is `{{0, -132}, {420, 300}}`, the clip over its own document; in the park it is
`{{0, -1132}, {1600, 1000}}`, the canvas-sized rect offset nowhere near a 613 pt
document. So the collection view materialises no item for the new row, and the
offset it does present is not the one the native body presents. **Sizing the park
does not fix it** — the offset degenerates, not the size (that hypothesis was
tested and refuted here, for the second time in this program).

Two instrument mistakes on the way, both worth not repeating:

- The first A/B compared bakes taken either side of a settle AND a streaming
  loop, and reported 3.2844 as if it were the park's fault when most of it was
  the fixture's own progress. The comparison has to be: residency on, settle,
  quiesce, bake in plane, ONE gesture whose only effect is the demotion, bake
  parked.
- The second compared 840x552 against 757x497 and got `.infinity`.
  `bitmapImageRepForCachingDisplay` sizes from the view's EFFECTIVE scale, and a
  parked body is out of the camera's cascade while a native one is not. Useful
  in itself: a parked bake's resolution is camera-independent.

`TILE_SURFACE_DUMP_DIR=<dir>` writes both bakes as PNGs. That is what turned
3.2844 into a cause — the parked bake shows the transcript scrolled to its Notice
card while the native body shows the tail. No scalar would have said that.

**The gate this earned:** `refreshTileSurfaces()` with every body parked must
bake nothing. Slice 1 satisfies it by construction; it is now pinned.

## The fork Step 0 leaves — RULED: Option A, and BUILT

**Dylan chose Option A on 2026-08-18**, from the rule as stated below, and it is
now implemented behind the same default-off flag. I2 stays unbuilt.

**See [.plans/38-quiet-surfaced-residency-slice-2.md](38-quiet-surfaced-residency-slice-2.md)
for what shipped, the measured headroom (~2.9 ms per live tile, so ~2.8 live tiles
in an 8.3 ms frame), the two production discrepancies it found, and what is still
to earn.** Everything below is the reasoning that led there; Step 1's rule is
superseded by `.plans/38`'s four clauses, which add the self-animation case.

Always-surfaced **as written below cannot use the `cacheDisplay`-from-park
producer**. Two ways forward, and they are not close in size.

**Option A — quiet-surfaced residency. Recommended, needs no I2.** Invert the
axis from *is the camera moving* to *is this tile live*:

> A tile is **native** while it is live — streaming within the last few seconds,
> holding the first responder, or under the pointer — and **surfaced** while it
> is quiet.

Why it fits every number this program has: every bake is taken while native,
which is the only state where a bake is faithful, and that is now a gate rather
than a hope. Reparenting is paid per quiet<->live transition instead of per
gesture, which is what the demote breakdown demands (~2.1 ms out + ~2.9 ms back
per tile). A quiet surfaced tile that receives content is stale by
`TileSurfaceRevision` and gets promoted immediately — the existing freshness
rule already refuses it, so the mechanism is in place. Camera cost becomes
native-cost x live-tile-count: at 2 ms/tile/step, three live agents is ~6 ms and
fits a frame; the other 47 tiles are free.

What it needs before it can be believed: **how many tiles are live at once in a
real workspace?** That is the number Option A stands on, exactly as the bake cost
gated this step. If it is routinely more than ~4, Option A does not fit either
and I2 becomes the answer regardless.

What it does NOT need: a solution to the frozen-park problem, because nothing is
ever baked from the park.

**Option B — I2 first (`.plans/34`).** Own the content rendering with a per-block
display list produced off-main, so a surface exists without AppKit view geometry
or item materialisation. This removes both halves of the Step 0 finding and is
the only path to a literal always-surfaced canvas. It is also a much larger
piece of work, and nothing measured so far says it is required yet.

The rule below is written for the always-surfaced shape. It stays as the target
for after I2; **Option A's rule is the one to implement next**, and it is the
same four clauses with "the camera is moving" replaced by "this tile is quiet".

## Step 1 — the residency rule

A tile is **native** if and only if any of these hold; otherwise it is surfaced:

1. it holds the first responder;
2. the pointer is inside it;
3. it has no admissible surface (no bake yet, stale, or less sharp than the
   screen needs — `TileSurface.isSharpEnough`);
4. its family has not opted in (`surfaceableBody == nil`), or the flag is off.

Rules 3 and 4 are already implemented and witnessed. Rules 1 and 2 are the new
work.

**Hysteresis is required, not optional.** Promote immediately on pointer enter;
demote only after the pointer has been gone for a delay AND the camera is
settled. Without it, sweeping the mouse across five tiles costs five
promote+demote pairs (~25 ms) during the sweep. `TileNSView.updateTrackingAreas`
and `mouseEntered`/`mouseExited` already exist (they animate the corner
brackets) and are the natural hook — today they track only the four corners, so
a body-wide tracking area is the addition.

## Step 2 — the discrepancy checklist, each with its own witness

This is the bill for always-surfaced, and Dylan's requirement is the bar: *"it
needs to work and can't notice any disadvantages due to this, any UX
discrepancies."* Each row is earned separately; none may be assumed.

| # | discrepancy | intended answer | witness |
|---|---|---|---|
| 1 | I-beam cursor over a transcript | pointer tile is native | pointer inside a surfaced tile ⇒ native within one mouse-moved event |
| 2 | drag-select, copy | `hitTest` promotion (shipped) | a full mouseDown→drag→up sequence selects real text |
| 3 | typing / IME in the composer | focus tile is native | see the bug below |
| 4 | tooltips, context menus | pointer tile is native | menu opens against real views |
| 5 | AX / VoiceOver | **open (Q8)** — see idea below | AX query returns the real tree |
| 6 | view-tree walkers | audit each | enumerate and decide per walker |

**A real bug slice 1 has, which only always-surfaced exposes.**
`TileNSView.acquireFocus` does `window?.makeFirstResponder(contentView)` — and
when surfaced, `contentView` **is** the surface host. Focus would land on a
picture. Slice 1 never hit it because at rest every tile was native. Fix:
promote at the top of `acquireFocus`. It needs a red-then-green witness, and it
is the first thing to write in slice 2.

**An idea worth testing for row 5:** promote on AX access, exactly the way
`hitTest` promotion works for input. AppKit queries `accessibilityChildren` /
`isAccessibilityElement` before handing anything to VoiceOver, so a
side-effecting override could promote in time and keep the real tree
authoritative — no `AXScene` needed for slice 2. Unverified; test it before
believing it.

**Row 6 needs an actual audit**, not a guess. The park is a `CanvasNSView`
subview, so walkers rooted at the canvas *do* reach parked bodies while walkers
rooted at `worldPlane` do not. That asymmetry is load-bearing and bit this
program twice already (see hazards).

## Step 3 — two new requirements always-surfaced adds

- **Memory.** Every tile permanently holds a surface: ~2 MB per 420×300 body at
  2x, so ~100 MB at 50 tiles. Slice 1 never had to care because surfaces were
  transient. Needs a budget, an eviction policy (coarse surfaces off-screen, or
  evict and re-bake on approach), and a published megabyte number.
  `TileSurfaceStore.totalBytes` already exists.
- **Bake scheduling.** Visible tiles re-bake at the transcript's gate cadence;
  off-screen tiles bake lazily when they approach the viewport, capped per
  frame, with the last complete surface retained until the new one lands (never
  a hole — `.plans/34` Part IX). `CanvasNSView.visibleTileViews` is the existing
  primitive.

## Hazards, including three earned this session

1. **`run-matrix.sh` is SAFE to run while Dylan uses Array** — it exports its
   own disposable `TMUX_TMPDIR` (`:9-22`). **Bare `swift run
   ContinuumRevivedCoreChecks` is not.** The old blanket "no matrix while he
   works" belief deferred verification for several sessions.
2. **CoreChecks' deliberate crash witnesses** endanger Array only when the agent
   runs *inside* it (macOS attributes the crash to the GUI host). Check ancestry
   (`ps -o ppid=,comm=` up the chain) **before** starting, not after. Ending at
   Ghostty/Terminal is fine; ending at `Array.app` is not.
3. **Never edit a source file while the matrix is running.** Doing so produced
   `error: input file ... was modified during the build`, **exit code 0**, and
   no summary. Judge a matrix run by its end-of-run summary, never its exit
   code.
4. **A counter keyed on where a view LIVES is blind** when the mechanism moves
   views between trees. `qaTotalTranscriptLayoutPassCount` walks the world plane
   and reads 0 for a surfaced tile — that looks like proof and is blindness.
   Root such counters at a stable handle (`surfaceableBody`). Three readings of
   one quantity in this session; two were confidently wrong (-72 and 84 against
   a truth of 12).
5. **Do not touch `AgentTranscriptListView.layout()` for performance.** Gating
   its unconditional forced offscreen pass moved a camera step 0.2 ms and was
   reverted. Those calls are nearly free; the ~960 profile samples belong to
   AppKit's own `NSWindow _layoutViewTree`. It is also on the streaming hot
   path.
6. Debug builds and `scripts/dev-app.sh` for iteration; never `--configuration
   release`. Never `CONTINUUM_UPDATE_BASELINES=1`.

## Still open

- **`_installLayer` never sets `tileView.canvas`** (`CanvasNSView.swift:2758`),
  unlike `install(tileView:for:)` and `installProjectTile`. Slice 1 sidestepped
  it by injecting the backing scale. Still owed its own red-then-green witness;
  do not "fix" it from a note.
- **Nothing measured so far is a presentation result.** Array's camera work is
  0.16 ms; WindowServer/GPU is unapportioned. Doc 31 item 11 and doc 33's T18
  want synchronised whole-system evidence before anyone claims end-to-end
  smoothness.
- **How many tiles are live at once in a real workspace?** The number Option A
  stands on (streaming, focused, or hovered — the tiles that stay native). If it
  is routinely more than ~4, Option A does not fit and I2 is the answer. Nothing
  measures it yet; a counter over Dylan's own session is the cheapest instrument.
- **Q3 / Q4 / Q8** carry recorded defaults in `.plans/34` Part XII and do not
  block.
- Whether to commit the `.plans/` series (see repository state).

## Paste-ready continuation prompt

```text
Continue Array's unbounded-canvas rendering program. Repository:
/Users/dylan/Documents/personal/Array, branch array/integration @ 10c49c2, with
Step 0's check-only change uncommitted (TileSurfaceResidencyChecks.swift, docs).

Read in this order:
  .plans/37-next-always-surfaced-residency.md   (state, next steps, hazards)
  .plans/36-tile-surface-residency-slice-1.md   (what shipped, why its policy died)
  .plans/34-unbounded-canvas-implementation-design.md   (design + ledger I1-I16)

Slice 1 shipped behind a default-off flag: an agent tile body renders from a
cacheDisplay surface while the camera moves, real body parked outside
CanvasWorldPlaneView. Camera step 25.18 ms -> 0.16 ms at 12 real agent tiles, and
the producer is pixel-exact. Its own witness refuted the POLICY: entering motion
costs ~4.7x a native step because reparenting a deep body is ~2.1 ms out and ~2.9
ms back per tile, so anything reparenting per gesture pays it twice per tile per
gesture. Always-surfaced (I5, already approved) reparents once per interaction and
is the only shape left.

Dylan's binding requirement: "it needs to work and can't notice any disadvantages
due to this, any UX discrepancies."

Step 0 is DONE and it changed the plan. A bake is affordable (0.90 ms in plane,
1.29 ms parked, for a 420x300 body) but a body cannot be baked WHILE PARKED at all:
parked pixels differ from the native body's by 3.28-7.41 mean channel difference,
and a row arriving while parked advances the model while changing zero pixels,
because the transcript's visibleRect degenerates to a canvas-sized rect offset off
its own document. Sizing the park does not fix it. The leg now gates "no bake while
a body is parked".

So decide the fork in .plans/37 first. Option A (recommended, no I2): invert the
axis to "native while LIVE (streaming/focused/hovered), surfaced while quiet" —
every bake is then taken while native, which is the only faithful state, and
reparenting is per quiet<->live transition rather than per gesture. Option B: do
I2's off-main per-block display list first and get literal always-surfaced.

Option A's own gating number is unmeasured: how many tiles are live at once in a
real workspace? More than ~4 and it does not fit either.

Then step 1 (the residency rule with pointer/focus hysteresis) and step 2 (the
discrepancy checklist, each row earned with its own witness). Start step 2 with the
acquireFocus bug named in .plans/37 - it makes contentView first responder, which
is the surface host when surfaced.

Hazards: run-matrix.sh IS safe alongside Dylan's Array (it isolates tmux itself);
bare CoreChecks is not; check your process ancestry does not pass through Array
before running it; never edit source while the matrix runs; judge a matrix run by
its end-of-run summary, never its exit code; do not touch
AgentTranscriptListView.layout() for performance (measured, reverted).

Preserve all 15 untracked files. Dylan has not ruled on whether to commit the
.plans/ series.
```
