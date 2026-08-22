# Unbounded canvas: the 2026-08-19 close-out

The day the residency program went from "super disappointed" to "this feels
good", in eight commits. This file is the timeline, the architecture as it now
stands, and the improvement map. Release: 0.5.1 (build 26), residency default
OFF for the alpha, ON via defaults for Dylan's prod install.

## Timeline (all on `array/integration`, shipped in 0.5.1)

The program's foundation predates today: `10c49c2` (residency behind a
default-off flag) through `d94ac3f` (occlusion sleep) built Option A — a quiet
tile parks its real body and shows a baked picture; anything uncertain stays
native. Today's arc was making it *feel* right at 83 real tiles.

| Commit | What | Why (measured) |
|---|---|---|
| `8254c2a` | Draw the surface where the body drew | The host's `layout()` wrote the root layer's frame in the wrong coordinate space — every surfaced tile's picture shoved up 24 pt, intermittently. "The whole tile shifts." |
| `b6efb82` | Check fixture windows off-screen | Check runs seized Dylan's display for 30–45 s. Fixture windows now order front at (-60000,-60000). |
| `912b40a` | Never show a picture of an old scroll position | A scroll bumps no revision, so a pre-scroll bake was handed back verbatim — the largest jump this design can produce. |
| `6369317` | **The gesture hold** (S1+S2) | 738 surface↔native crossings in one 2m45s session. Nothing crosses while the camera moves, in either direction; the flaky `zoomingIn` delta-derivation deleted. Witness: 0 crossings during a real 8-step zoom (was 8). |
| `09f08df` | Log every crossing, with attribution (S6) | The old log skipped passes whose promotes and demotes cancelled — blind to exactly the flicker case. `why:` fields decompose every crossing. |
| `8af00a4` | AX gate: body handed back only to assistive clients | One passive accessibility sweep (Raycast/Rectangle both run here) demoted all 83 tiles at once; recovery at 4 bakes/pass took 20 s of flips while a zoom ran through it at 5 fps. 332 AX reads at boot — 4 full sweeps — refuted "this path is never exercised". |
| `bb321f1` | Hide the surface park | A 20 s sample of the real session: tracking-area updates, Auto Layout passes and deep layout chains recursed through ~80 *parked* transcript trees every display cycle. Clipped-out is not free; hidden is pruned. |
| `d5efe66` | No git spawns on app switch | `applicationDid{Become,Resign}Active` → sidebar rebuild → 2 synchronous `rev-parse` spawns per agent repo on the main thread (2 s TTL). ~0.4 s frozen per activation edge. Now: cache-only reads (witnessed zero spawns cold) + one coalesced off-main warm. |
| `22aba06` | Density follows visibility | Bakes inherit zoom density; at zoom 2 a full canvas needs ~650 MB against a 256 MB budget. Off-screen tiles bake at rest density; the lead-rect catch-up re-bakes them dense just before they arrive on screen. |
| `f7bf393` | Byte-bound every surface; degrade, never strand | Two holes in the cap re-pinned the budget (261 MB, refusedMemory 4110): whole-body bakes of barely-visible giants, and dense orphans after zoom-out. Now: one shared `requiredSurfaceScale` (lead + off-screen cap + 24 MB whale cap), degrade-to-rest under pressure instead of refusing residency (stranded natives at ~4.5 ms/step each WERE the lag), an in-place slim pass (zero flips), and `bakeWouldFit` crediting back the surface a re-bake replaces. |
| `1c0eed3` | One-beat sharpen + tolerance band (S3+S5) | "Blurry to hi res is not the best": the settle edge rationed sharpening 2 promotes + 4 bakes per pass — a parade of pops. Now the settle edge promotes every soft visible tile together, a 12-bake visible budget returns them together (anchor-outward), and a ~19% sharpness band (one chrome bucket) means zoom nudges re-bake nothing. |

Process notes worth keeping: every commit carries a RED-first or teeth-checked
witness; three of today's witnesses caught real bugs during their own
development (whale stranding via downscaler truncation vs the 0.0001 epsilon,
the re-bake blocked by its own old surface's bytes, the catch-up fighting the
degrade). One methodology trap: a new witness that bakes ~100 MB before the
timing legs shifted `checkCost` +0.5 ms through heap state alone — measured
both orders, witness moved after the timing legs, reason documented in the
suite.

## Architecture as it stands

**One flag, two states, camera-driven.** `TileSurfaceResidencyConfig` —
env `ARRAY_TILE_SURFACE_RESIDENCY` (dies with the launch) or defaults key
`continuum.tileSurfaceResidency.enabled`; default OFF. Anything uncertain
stays native.

**Residency (CanvasNSView + TileResidencyPolicy).** A 10 Hz pass computes each
tile's liveness (focus, resting pointer, assistive-AX access, animation,
content change) and decides native vs surfaced. Live = real body in the world
plane. Quiet = body parked (hidden park, pruned from AppKit's display-cycle
walks), picture shown by `TileSurfaceHostView` (layer-hosting, contentsScale
follows the display only).

**The gesture contract (Dylan's ruling).** While the camera moves, NOTHING
crosses — tiles may go progressively soft, softness is counted
(`softDeferred`), demotions are suppressed. At the settle edge, every soft
in-lead tile promotes in one beat and the visible bake budget (12/settled
pass, anchor-outward) returns them together. Small zooms (<~19%, one chrome
bucket) never invalidate anything.

**Density policy — one decision point.** `requiredSurfaceScale(for:)`:
full zoom density inside the lead rect (viewport +25%), rest density outside
it, never more than 24 MB per surface (whale cap), never less than rest
density. The bake, the admission gate, the catch-up and the per-step sweep all
judge by it — two of them disagreeing is a permanent flap, and the whale
witness pins that they can't.

**Byte budget (256 MB) with graceful pressure.** `bakeWouldFit` (credits the
replaced surface) gates every bake; under pressure the ask degrades to rest
density rather than refusing residency — soft beats stranded on both axes.
A settled slim pass (2/pass) downscales over-dense surfaces in place: same
picture, fewer bytes, zero flips. Eviction remains only as the overflow
backstop. Bytes now scale with the visible set at any zoom.

**Truth-keeping.** A scroll is compared at admission (`bakedScrollOffsets`,
native tiles only); a stale revision (content/size/appearance) promotes and
drops; uniform bakes of content-bearing tiles are refused; occluded windows
bake nothing; parked bakes are never trusted (unfaithful, measured). The
residency log prints every crossing with full attribution — `why: stale,
softDeferred, suppressedDemotes, evictions, refusedMemory, degraded, slims,
refusedBudget` — so the next "it feels wrong" session starts from data.

**Outside the canvas.** Branch chips are stale-while-revalidate
(`branchContextCachedOnly` + off-main warm) — app activation never spawns git.
The AX hand-back rule fires only for VoiceOver/Switch Control.

## Improvement areas

### Performance, near-term (ordered by expected felt impact)

1. **Compositor share.** With Array's camera path at ~0.2 ms surfaced, the
   frame time during gestures is now dominated by WindowServer (~50% CPU in
   samples) and `CATransaction.flush` (published, not gated: 2.7 ms none-live).
   Next probe: layer count / offscreen effects on surfaced tiles (shadows,
   masks) — the checkCost epilogue already prints the split.
2. **`refusedBudget` churn.** Counter runs hot (47k in minutes), suggesting
   residency passes run far more often than 10 Hz — likely per camera step via
   the settle path. Cheap to confirm from the log; wasted passes are wasted
   main-thread time during gestures.
3. **Prose measurement during gestures.** Down from ~4,000 to ~150 per gesture
   after the park hide, but `AssistantProseView` still measures on live tiles
   mid-gesture. The performance doc's standing item.
4. **S4 headroom baking** — the only way to remove the *one* remaining
   transition (big zoom-in: hold-soft → settle sharpen). Needs the explicit-
   density producer (UIProbe technique), gated on the pixel-equivalence
   witness and the upsample negative control; carries a text-rendering
   fidelity risk. Stop-and-discuss if the control fails (Dylan's standing
   instruction).
5. **Bake off the main thread.** Bakes are 1.7–7 ms each on main; a
   settle beat of 12 is ~40–80 ms once per gesture. `cacheDisplay` is
   main-thread-bound, but the downscale/slim half could move off.

### UX, near-term

1. **Residency default-on decision.** Dylan runs it in prod via defaults from
   0.5.1; alpha default flips only after he has lived on it. The witnesses are
   in place (`checkDefaultIsOff` pins the current default deliberately).
2. **Pan-in softness at high zoom.** A far tile panned quickly into view can
   arrive one beat soft (lead is +25%). If noticed, widen the lead along the
   pan direction (velocity-aware) rather than everywhere.
3. **Terminal/note/browser/agent spawn migration** (hazard 9) — still on the
   `install` + `saveCanvas` path; file-open was migrated in 0.4.15, the rest
   were not.
4. **Leg C, spatial connector** — the entity-index / navigation work deferred
   from the earlier program.
5. **Markdown/prose renderer** — `AssistantProseView.layout()` row re-measure
   noted in the 0.4.16/0.4.17 ledger rows survives in transcripts.

### Verification debt

- `--agent-supervisor-check` KNOWN-RED on a naming clause blocks everything
  after it in that leg, including the branch-chip witnesses — fix the naming
  check or reorder so later clauses run.
- The live-tile cost gate sits at 4.4–4.6 ms against a 4.5 threshold on a
  loaded box — flapping run-to-run at HEAD. Re-baseline it on a quiet machine
  or gate on a ratio to the native arm instead of an absolute.

## The stress workspace

`~/array-stress-workspace` is a frozen snapshot of the 89-tile test canvas
(copied from `~/array-scratch` on 2026-08-19, `.array/lock` excluded).
Registered in no install, so it is never anyone's default. Visit it with
`CONTINUUM_PROJECT_ROOT=$HOME/array-stress-workspace` on any single install at
a time — hazard 10 applies to it like any root.
