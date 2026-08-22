# 33 — Unbounded canvas testing and measurement architecture

Date: 2026-08-17

Status: test-architecture discussion draft. This document defines how Array
should prove rendering changes are causal, correct, faithful, scalable, and
perceptibly faster. It does not plan implementation order, tickets, branches,
or estimates.

Related documents:

- `.plans/31-unbounded-canvas-rendering-findings.md` — evidence record;
- `.plans/32-unbounded-canvas-target-architecture.md` — target architecture.

## Purpose

Define a testing and measurement system that can answer, for every optimization
or architectural change:

1. Did the intended mechanism actually run?
2. Did the forbidden work actually stop?
3. Did required pixels, state, interaction, and accessibility remain correct?
4. Did the causal reduction improve the real Release experience?
5. Did the result preserve the required scaling law rather than improve one
   convenient fixture?

The harness should make incorrect conclusions difficult. A fast result is not
admissible merely because a timer printed a lower number.

## Non-goals

This document does not decide:

- which renderer change is implemented first;
- milestone or ticket sequencing;
- implementation estimates;
- exact final freshness thresholds for browser, terminal, or streaming agents;
- the final CA-versus-Metal choice;
- the final native-island count or residency policy;
- what production data Dylan should disclose.

Where an architecture product contract remains open, the harness records the
relevant distribution and exposes the decision instead of inventing a passing
threshold.

## Governing rule: three gates for every claim

Every optimization claim must pass three independent gates.

### 1. Structural gate

Prove the predicted work changed:

- the intended arm executed;
- forbidden work counters reached the expected value;
- required work still occurred;
- the treatment was not a no-op;
- work moved only to an explicitly measured stage.

### 2. Correctness and fidelity gate

Prove the optimization did not become fast by doing less product:

- complete real pixels remain present;
- geometry, coverage, resolution, color, and z-order are correct;
- semantic and visible revisions are compatible;
- focus, hit testing, selection, IME, drag/drop, and exactly-once input hold;
- state survives parking/promotion where promised;
- accessibility identity, order, geometry, focus, and actions hold;
- memory and sensitive-surface lifetime remain valid.

### 3. End-to-end performance gate

Prove the user-visible Release path improved:

- real display-paced gesture;
- real display/CA transaction path;
- correct fixture and treatment fingerprint;
- raw frame/timeline evidence;
- active motion and settle reported separately;
- pan-relative result on the same fixture and environmental block;
- synchronized external-process/system evidence where applicable.

Each gate can catch a lie the others cannot:

- a blank canvas is fast;
- a correct screenshot can hide repeated layout and allocation;
- zero layout counters can coexist with WindowServer stalls;
- a lower median can hide catastrophic tails;
- a retained image can look correct while losing updates, clicks, IME, or AX;
- an affine benchmark can exclude the producer that dominates the product.

The existing `PerfBudget` doctrine remains foundational:

> Counts are the assertion; time is the guard.

For the renderer program it expands to:

> Counts prove causality; visual and behavioral teeth prove required work still
> exists; Release timing proves the user benefited.

## Existing foundation to preserve

Array already has unusually strong pieces. The new system should extend them,
not create a disconnected benchmark framework.

### `PerfBudget`, `PerfScenarioResult`, and `PerfReport`

Existing strengths:

- stable dotted metric names;
- exact, maximum, and minimum budgets;
- rationale printed beside failures;
- deterministic count assertions beside duration guards;
- explicit budget utilization and watch list;
- human table and flat JSON output;
- product targets rather than “current plus headroom.”

Reuse:

- metric naming and rationales;
- exact positive and negative teeth;
- scenario registry;
- machine-readable artifacts;
- explicit publication of passing metrics near budget.

Extension needed:

- raw per-trial and per-frame artifacts;
- richer environment and fixture identity;
- paired/block comparison metadata;
- validity status and invalidation reason;
- revision, coverage, memory, and multi-process fields.

`PerfBudget.Unit` currently covers only milliseconds, counts, FPS, and MB. The
renderer schema will need explicit units for bytes, pixels, percentages,
cadence multiples, rates, and energy rather than mislabeling them as counts.
Metric IDs remain stable, and an instrumentation/schema revision records any
change in how a metric is acquired or overlaps another counter.

### `PerfScenarios`

Patterns demonstrated by existing hand-written scenarios:

- real `NSWindow` fixtures;
- `layoutSubtreeIfNeeded()`, `displayIfNeeded()`, and
  `CATransaction.flush()` when the measured stage requires them;
- installed-count and history-depth slopes;
- independently derived geometry oracles;
- real managed-agent fixtures;
- ABBA treatment order in selected probes;
- local warmup, reset, and counter snapshots;
- opt-in stress scenarios that report when skipped;
- scenario filtering and JSON output.

The current geometry-hold ABBA probe aggregates observations by arm. The new
trial schema must preserve every observation, block, order, and process-level
replicate before paired or bootstrap analysis; the existing aggregate is a
causal witness, not yet the general statistical engine.

Current relevant scenarios:

- `canvas.pan`;
- `canvas.fractional-pan`;
- `canvas.zoom`;
- `canvas.camera-slope`;
- `canvas.magnify-slope`;
- `canvas.gesture-transition`;
- `canvas.raster`;
- `canvas.geometry-hold-probe`;
- `canvas.proxy-scene-probe`;
- `canvas.scroll-magnification-probe`;
- `transcript.delta`;
- `canvas.stress`.

These remain valuable witnesses. Their documented blind spots must remain
attached to their results.

The scenario functions are currently monolithic rather than a shared trial
orchestration API. The fixture/trial/artifact components proposed below are new
shared infrastructure built around these patterns, not capabilities already
provided by `PerfScenarios`.

### `QAPerf`, perf ceilings, and `qa-runs`

Existing strengths:

- opt-in per-flow output directories;
- raw sample arrays and p50/p95/p99 fields;
- resident-memory measurement;
- JSON reports and Markdown findings;
- isolated temporary project/app-support roots;
- established `qa-runs/<run>/...` artifact convention;
- external QA flows with manifests, screenshots, and a rule that a passing flow
  must contain a positive machine assertion.

The new renderer artifacts should extend/version the existing `qa-runs`
convention rather than introduce a competing root. `PerfBudget` publishes
deterministic product targets and causal work counts; current `QAPerf` ceilings
are older locally measured limits with headroom. These are distinct policies.
The renderer program must not silently create a third baseline philosophy.

`scripts/run-perf-ceilings.sh` currently defaults to a Debug executable. Tier 3
product timing must pass an explicit released/signed Release executable; reuse
of that runner does not by itself satisfy the Release requirement.

### Check execution convention

The repository currently gates behavior through Swift `*Checks` executables and
application flags wired into `scripts/run-matrix.sh`, not a standing XCTest test
target. Tier 1/2 checks use those established lanes unless a later architecture
decision explicitly replaces them. A check existing in source is not coverage
until dispatch, a positive witness, and matrix/inventory registration are all
proven.

### `CanvasFrameRecorder` and the HUD

Existing strengths:

- records the camera-active interval rather than arbitrary wall time;
- preserves the leading camera step;
- includes the delayed interval after the final applied camera update;
- removes the smooth quiet tail;
- uses the display's refresh information;
- reports time-weighted average FPS, p50, p95, worst, and late count;
- HUD reuses the recorder and adds no timer or display link;
- logging is opt-in and can write to a dogfood file sink.

Meaning of the current signal:

- honest main-thread/display-link starvation symptom;
- useful feel-correlated tripwire;
- not a WindowServer presented-frame timestamp;
- not enough to distinguish sustained one-second steps from one catastrophic
  stall without raw intervals.

Extension needed:

- retain raw intervals and timestamps;
- p90/p99 and missed-cadence severity;
- longest late-frame run;
- explicit gesture/phase labels;
- active/final-delivery/settle/bake separation;
- camera revision associated with each interval;
- observed idle cadence calibration for variable refresh;
- stage/signpost correlation.

### Camera correctness oracles

Existing strengths:

- independent model-derived screen frames;
- real AppKit view-tree comparisons;
- dense point/hit grids;
- overlapping z-order cases;
- fractional pan and zoom;
- final viewport assertions;
- anti-vacuity counters proving a camera mutation occurred.

Reuse:

- every fast camera arm must preserve independently computed geometry;
- renderer, native hit, semantic hit, and AX hit should be compared against the
  same declared scene generation.

### Raster and geometry-hold probes

Reusable lessons:

- a layer-backed `draw(_:)` witness requires a real transaction flush;
- pump the actual stage being claimed;
- compare a treatment to a no-op/held control;
- assert both zero forbidden work and positive required work;
- separate preparation, active motion, and final bake;
- geometry hold proves the effective-scale boundary but does not apportion
  layout, backing allocation, raster, CA, or WindowServer work;
- prepared synthetic surfaces prove affine cost, not product fidelity.

### UI probes and PNG baselines

Existing strengths:

- explicit size and appearance;
- retained native window host;
- deterministic 2x graphics context;
- aqua/darkAqua coverage;
- explicit baseline blessing;
- stale/missing baseline failure;
- normalized sRGB RGBA comparison;
- actual and magenta-diff failure artifacts;
- pixel existence and clipping probes.

Extension needed:

- physical-resolution-aware comparisons instead of normalizing every case to
  one pixel per point;
- whole-scene coverage and LOD transitions;
- revision and semantic-content inventories paired with pixels;
- WKWebView and Ghostty-specific acquisition/oracles;
- dynamic, animation, selection, effect, and color-space cases;
- a rule that no real-workspace pixels become test artifacts.

### Matrix and inventory protection

Existing strengths:

- matrix continues after failures so one red cannot hide later coverage;
- known reds are classified and printed separately;
- an unexpected known-red pass is reported as stale allowlist state;
- app checks receive isolated project/app-support roots;
- disposable tmux namespace protects the user's live sessions;
- matrix inventory prevents silently deleting flags, legs, or check-suite calls;
- display-dependent skips are printed rather than silently treated as coverage.

These conventions remain mandatory for any new harness leg.

The inventory protects presence and minimum call counts. It does not prove a
flag dispatches correctly, exercises an independent path, or retains causal
teeth. Every registered check still needs positive/negative treatment witnesses.

### Two independent scalability gates

Preserve `docs/internals/scalability-tdd.md`'s distinction:

- **regression ceiling** — reviewed accepted work for the exact versioned
  fixture;
- **product target** — the architecture Array needs, which may remain known red.

The honest states are pass/pass, regression-pass/product-fail known debt, and
regression failure. Fixture shrinkage or counter-definition changes create a new
version and overlap old/new witnesses; they never silently green the old defect.

## Five evidence tiers

Different tiers answer different questions. A green result at one tier must not
be described as a result from another.

### Tier 1 — Deterministic contracts and work counts

Purpose:

- architecture shape;
- exact invariants;
- reducers, state machines, dirty propagation, indexing, revision arbitration;
- causal work counts;
- resource-lifetime counts.

Environment:

- ordinary matrix;
- Debug acceptable;
- no claim about user-visible FPS.

Examples:

- zero semantic reduction on a camera-only change;
- one admitted scene generation per intended publication;
- stale producer completion never replaces newer compatible content;
- exact hit and z-order oracle;
- bounded queue and cancellation state machine;
- no full-history visit on tail-only changes;
- no admitted-coverage holes in region algebra;
- balanced residency pins and no leaked subscriptions.

### Tier 2 — Deterministic rendered integration

Purpose:

- real AppKit layout/display/CA paths;
- pixel and geometry fidelity;
- isolated causal mechanisms;
- producer behavior and exact treatment fingerprints.

Environment:

- real window/display when needed;
- programmatic deterministic operations;
- Release required for performance conclusions;
- Debug useful for structural regression only.

Examples:

- native installed versus raster-suppressed installed versus parked;
- gyro count sweep;
- Source/Preview block sweep;
- Ghostty unchanged-scale A/B;
- identical thumbnail key guard;
- exact prebuilt CA surfaces;
- native/custom agent renderer declared visual/semantic equivalence;
- surface coverage and resolution transitions.

A synchronous loop here may answer operation CPU cost. It must not be reported
as gesture FPS.

### Tier 3 — Display-paced Release scenarios

Purpose:

- frame pacing;
- input-to-observable-commit latency, with the endpoint named precisely;
- active versus settle experience;
- pan-relative product gates;
- faithful mixed workload.

Environment:

- Release build;
- visible WindowServer-backed window;
- deterministic seeded two-second camera traces;
- real display cadence;
- isolated support/project state;
- raw artifact bundle.

Required gestures:

- pan at 1.0, 0.35, and overview zoom;
- zoom in and out;
- center and corner anchors;
- pinch-to-pan transition;
- glide;
- rapid reversal;
- normal settle;
- cold admission/teleport;
- live-churn zoom.

### Tier 4 — Supervised dogfood and whole-system diagnosis

Purpose:

- real trackpad/input feel;
- released/signed application shape;
- driver and run-loop behavior;
- WebContent/GPU/WindowServer attribution;
- production distribution comparison.

Environment:

- sanitized reproduction fixture for repeatability;
- real production workspace only for privacy-safe counters and voluntary local
  observation;
- Instruments/system traces are diagnostic, not regression timing numbers.

The existing external QA driver is the right pattern: it records manifests and
screenshots, requires a positive machine assertion, and runs with supervised
Accessibility/Screen Recording permissions when necessary. Screenshots remain
evidence, never the sole pass condition. Real CGEvent and system-AX exactly-once
witnesses live here; deterministic internal/state-machine equivalents remain in
Tier 1/2 so ordinary automation does not depend on OS permissions.

### Tier 5 — Soak, recovery, and hardware qualification

Purpose:

- memory equilibrium;
- cache eviction and cold recovery;
- resource leakage;
- thermal behavior;
- display/appearance/color-space transitions;
- external process lifecycle;
- cross-hardware confidence.

Examples:

- long-running streaming plus camera motion;
- repeated park/promote;
- workspace switching;
- memory pressure and cache purge;
- WebContent crash/replacement;
- Ghostty surface/runtime recovery;
- display migration 1x/2x and 60/120 Hz;
- simulated compositor/device loss where possible.

Deterministic simulated pressure, cache purge, process loss, and device-loss
policy tests are labeled separately from qualification under real OS memory
pressure, process termination, display migration, or device failure. Passing a
simulation is not evidence that the operating-system path behaved correctly.

## Unified harness model

The test system has six conceptual components. Names are descriptive, not
implementation commitments.

### Fixture manifest and builder

Owns:

- privacy-safe structural shape;
- deterministic synthetic content seed;
- topology and normalized geometry;
- tile family/mode/count composition;
- history/block/activity shapes;
- expected runtime and installed-view classes;
- required process/surface presence;
- fixture and shape hashes.

It must prove the fixture actually contains the requested workload before any
timing result is admissible.

### Trial orchestrator

Owns:

- warmup readiness;
- treatment order and random seed;
- identical reset state;
- deterministic camera/input traces;
- block and trial identity;
- environment validity;
- A/A, ABBA, balanced multi-arm, slope, and factorial designs;
- invalidation reasons;
- post-trial artifact flush.

### Instrumentation registry

Owns cheap counters and buffered signposts by subsystem:

- camera;
- semantic ingestion;
- render-description production;
- native hierarchy;
- external producers;
- spatial scene/cache;
- compositor;
- interaction/AX;
- resources.

It must not allocate strings, sort collections, or perform file I/O on the
camera hot path.

### Correctness and fidelity oracle

Owns:

- scene and semantic inventory;
- geometry and coverage;
- pixels and resolution;
- revision compatibility;
- hit/z-order;
- state round-trip;
- interaction exactly-once;
- accessibility;
- privacy sentinels.

### Artifact writer

Owns immutable, privacy-checked raw artifacts. It buffers during measurement and
writes after the critical interval.

### Offline analyzer and dashboard

Owns:

- statistical comparison;
- plots and timelines;
- artifact validation;
- reanalysis under versioned methodology;
- human-readable evidence packages.

Raw artifacts are never rewritten when analysis logic changes.

## Privacy-safe faithful fixture

### Production census

The released app exposes an explicit, user-triggered structural export. It must
not export:

- titles, transcript text, prompts, or responses;
- file paths, names, or contents;
- URLs, origins, page titles, cookies, or screenshots;
- terminal text, commands, cwd, argv, or session names;
- branch or project names;
- identifiers copied from production;
- unsalted hashes of private values;
- arbitrary object descriptions.

Use export-local random ordinals such as `zone-0` and `tile-0`, normalized
geometry, allowlisted class vocabulary, and coarse count/size buckets.

### Census schema

Run-level:

- schema version and export nonce;
- git SHA/version/configuration/architecture;
- macOS/hardware/RAM class;
- display pixels/points/backing scale/observed cadence;
- window geometry/occlusion;
- normalized camera and world bounds.

Zone-level:

- anonymous ordinal;
- normalized frame;
- expanded/collapsed;
- color role;
- member tile ordinals;
- layer/effect facts.

Tile-level common shape:

- ordinal, family, concrete allowlisted view class;
- normalized frame and z rank;
- installed/visible/preload/focused/first-responder;
- live/snapshot/occluded/runtime-resident;
- view/layer/constraint counts and maximum depth;
- hidden subtree counts;
- scroll/collection/stack/TextKit/WebView/Metal-layer counts;
- semantic revisions received/applied/coalesced;
- layouts/draws/backing callbacks over a bounded activity window.

Family shapes:

- agent: semantic rows by renderer kind, materialized/visible rows, history
  bucket, expanded/collapsed bodies, image/file references, composer shape,
  running/streaming/visible-gyro facts;
- file: Source/Preview, byte/line/block buckets, block-kind histogram, mounted
  block count and TextKit depth;
- browser: WebView presence, viewport, and a versioned allowlisted aggregate
  activity class when safely observable; production census supports `unknown`
  rather than inspecting content to infer static/animated/media/canvas/WebGL;
- terminal: rows/columns, scrollback bucket, activity class, surface dimensions,
  scale, and buffer count where supported, otherwise `unknown`;
- zones/chrome: geometry, masks, translucency, shadows, and pixel coverage.

### Fixture parity

Two identities are retained:

- `shapeHash` — canonical structural manifest;
- `fixtureHash` — shape plus deterministic synthetic content/assets/seed.

The first faithful fixture reproduces:

- four expanded zones plus one unzoned tile;
- counts `5/1/11/2 + 1`;
- twelve agents, six files, one real isolated browser, one real isolated Ghostty;
- overview near 0.2;
- normalized world area and screen occupancy within declared census-bucket
  tolerances;
- census-matched history, file modes/block shapes, and activity counts.

A real Ghostty surface and real deterministic local WKWebView are mandatory for
the faithful cell. Missing external integration is reported as missing coverage,
not silently replaced by a cheap view.

Fixture admission publishes a parity table for every census axis, accepted
bucket distance, and mismatch. Because the census is privacy-bucketed, this is
structural/distributional similarity, not exact reproduction.

## Composable fixture axes

No single “representative” fixture is sufficient.

### Topology

- current four-zone/twenty-tile shape;
- sparse distant world;
- dense packed world;
- arbitrary overlaps;
- many zones;
- huge positive/negative coordinates;
- cold teleport targets.

### Measurement counts

- 5/15/25/50 as comparison points;
- larger points for slope confirmation;
- never described as capacity ceilings.

### Agents

- idle;
- visible gyro;
- streaming;
- synchronized and phase-staggered streams;
- short and long history;
- images/tools;
- expanded and collapsed bodies;
- selected/scrolled/editing/IME states.

### Files

- Source;
- small Preview;
- census-heavy Preview;
- maximum admitted Preview;
- wide code/table fallback;
- external source mutation/disappearance.

### WebKit

- static DOM;
- fixed content;
- CSS animation;
- canvas;
- WebGL;
- video/media;
- selection/forms/input;
- dialogs/download/file chooser;
- process replacement.

### Terminal

- idle;
- bounded output;
- cursor animation;
- alternate screen;
- scrollback/selection;
- wide/combining glyphs;
- resize;
- IME;
- rapid output and runtime recovery.

### Camera

- pan;
- zoom in/out;
- overview/deep zoom;
- mixed handoff;
- glide;
- reversal;
- teleport;
- center/corner anchors;
- absolute zoom centers near 0.15/0.2/0.25/0.5/1/2.

### Environment/resource state

- 1x/2x;
- light/dark;
- 60/120 Hz and observed variable cadence;
- display/color-space transition;
- warm/cold/partially cached;
- memory pressure;
- cancellation storm;
- long soak.

Use pairwise or factorial combinations for suspected interactions. Do not assume
tile-family costs are additive.

## One honest timeline

Array-local events use a declared monotonic clock source. WebContent, GPU,
WindowServer, and Instruments streams may use different domains and require
explicit offset/conversion markers plus an alignment-uncertainty estimate.
Never claim ordering finer than that uncertainty.

Every trial carries shared IDs:

- `runID`;
- `trialID`;
- `blockID`;
- `gestureID`;
- `frameSequence`;
- `sceneGeneration`;
- camera and semantic revisions.

Required stages:

```text
input event timestamp
handler begin/end
desired viewport revision
camera coalescing decision
presentation apply begin/end
Array-owned layout interval begin/end
explicit display pump begin/end
explicit CA transaction flush begin/end
next display-link callback
scene generation admitted
latest semantic/resource revision visible
settle/bake begin/end
```

Record `CADisplayLink.timestamp`, target timestamp where available, and the
latest camera/scene revision applied or committed before the callback. The
callback does not prove that revision was presented.

Name software stages precisely:

- `inputToHandler`;
- `handlerToDesiredViewport`;
- `desiredToPresentationApply`;
- `applyCPU`;
- `layoutCPU`;
- `displayCPU`;
- `transactionFlushCPU`;
- `inputToTransactionFlushEnd` or another precisely named observable endpoint;
- `displayCallbackInterval`;
- `semanticRevisionAge`;
- `resourceRevisionAge`;
- `settleDuration`.

The harness can bracket Array-owned work and its explicit pumps; it cannot
comprehensively bracket AppKit's implicit layout/display/commit through public
production hooks. `CATransaction.flush()` or a later display-link callback must not be labeled
“presented to screen.” Until a trustworthy compositor presentation signal
exists, Array owns input-to-explicit-flush (or another named software endpoint)
and callback-pacing metrics; actual
compositor behavior comes from synchronized system evidence. A future Metal
backend may expose scheduled and presented drawable times separately.

Synthetic traces name their origin precisely (`syntheticTraceDue`,
`eventDequeued`, or `handlerBegin`). They do not claim physical trackpad-to-
photon latency. Physical input remains a separate supervised tier.

Active, final-delivery, settle, bake, and complete-drain phases have mutually
exclusive mechanical timestamp rules. Overall start-to-rest and start-to-drain
durations are always reported so work cannot be made invisible by moving it
between phases.

## Frame statistics

Store every raw interval. For each gesture report:

- observed idle and active cadence;
- interval count and camera-commit count;
- total gesture duration;
- time-weighted FPS;
- p50, p90, p95, p99, worst;
- late-frame share;
- missed-vsync severity histogram:
  - on time;
  - one cadence missed;
  - two;
  - three;
  - four or more;
- longest consecutive late run;
- catastrophic-stall frequency above declared cadence multiples;
- active-motion, final-delivery, settle, and forced-bake distributions;
- paired pan-relative effects and ratios.

Callback-rate FPS is:

```text
included callback intervals / included elapsed seconds
```

It is never the mean of reciprocal interval FPS values and is never labeled
presented FPS. The leading timestamp establishes the interval origin; the final
included interval follows the document's mechanical phase rule.

### Motion-truth and progress gate

Smooth callbacks are insufficient if the implementation drops camera revisions,
repeats old pixels, or defers all content until after measurement. Per interval
record where observable:

- desired camera transform/revision;
- latest applied/committed transform/revision;
- presented transform/revision only when a trustworthy presentation witness
  exists;
- camera revision age;
- spatial/anchor error and integrated error over time;
- velocity discontinuity;
- repeated-frame count;
- semantic/resource revision age;
- outstanding producer/settle/drain work.

Gate maximum and time-integrated camera error, maximum coalescing age, repeated
frames, and post-gesture drain. Accepted semantic events are conserved even when
intermediate pixel revisions are superseded. Exact final viewport alone is not
enough.

Late thresholds use declared tolerance and boundary rounding from target
timestamps/requested frame-rate information where trustworthy, plus an active
no-op trace under the same window/display conditions. Quiet cadence remains
context but may be throttled differently under variable refresh. Record regime
changes and results in both milliseconds and cadence multiples.

Never make average FPS the only presentation. A bimodal gesture and a uniformly
mediocre gesture may have the same average and require different architecture.

## Counter and signpost taxonomy

Every field declares its acquisition tier:

- `ownedCounter` — exact Array-owned seam;
- `runnerSample` — process/environment sample;
- `systemTrace` — diagnostic system observation;
- `unsupported` or `unknown` — unavailable, never encoded as zero.

Constraint/TextKit internals are exact only where Array owns a seam. Process GPU,
energy, WindowServer, allocation-wide activity, and child-process association are
runner/system evidence. WebKit child-PID association may be ambiguous with
multiple apps/process pools. Ghostty frame-lease/copy/present counters exist only
if a supported integration exposes them.

Hot-path coverage derives from immutable region metadata or low-cost occupancy
summaries. Device-pixel screenshots are post-trial oracle artifacts, not a
per-frame blank-pixel scan.

### Camera/presentation

- inputs received/coalesced/discarded;
- desired and presented camera revisions;
- root affine mutations;
- native world origin/size writes;
- changed versus identity frame/bounds writes;
- presentation eligibility/activation/denial reason;
- mode transitions and scene-generation swaps;
- requested/available/admitted coverage;
- exact/lower-resolution/stale/missing coverage by family;
- blank/exposed pixels;
- settle/bake count and duration.

### Semantic/render descriptions

- events and revisions received;
- nodes/entries/blocks visited;
- prefixes reused versus rebuilt;
- full-history flatten/scans;
- dirty fragments/regions;
- snapshots/display lists produced/discarded;
- stale/compatible/incompatible publications;
- source-to-description and source-to-visible age.

### Native hierarchy

- layout calls and duration by concrete owner;
- `layoutSubtreeIfNeeded` calls;
- constraint passes;
- TextKit measurements/glyph invalidations;
- transcript prepare/attribute queries/attributes visited;
- visible/materialized row updates;
- actual draw/layer-display calls and dirty area;
- backing-property callbacks;
- hidden/collapsed descendants visited;
- gyro rebuilds and keyframe/value counts;
- image request/cancel/cache/decode/completion;
- changed versus identity scroller/frame/selection writes.

### External producers

- WK navigation/activity/snapshot begin/end/completion;
- WebContent/GPU process identity and lifecycle;
- Ghostty content-scale changed/unchanged calls;
- Ghostty resize/draw/present/frame-lease/copy/blit;
- browser/terminal resource revisions and frame age;
- protected/unsupported surface reasons;
- bytes transferred or uploaded.

### Spatial scene/cache

- spatial queries and candidates;
- visible/admitted chunk count;
- page/tile surface count;
- resolution bucket/hysteresis transitions;
- coverage bitmap holes;
- dirty-area-to-produced-area ratio;
- cache hit/miss/eviction;
- CPU/GPU/external/transient bytes;
- last-parent retention;
- cold-admission state and duration.

### Interaction/accessibility

- promote/demote requests/transitions/cancellations;
- pin acquire/release by reason;
- initiating-event nonce and semantic delivery count;
- promotion latency;
- stale-target reconciliation/cancellation;
- native/semantic/render/AX hit owner;
- AX node creation/removal/update and focus transitions;
- state-equivalence failures.

### System/resources

- installed/visible/materialized/runtime-resident counts by family;
- view/layer/constraint counts and maximum depth;
- allocation/deallocation rate;
- resident/physical/dirty/compressed memory;
- page faults and pressure state;
- IOSurface/texture/surface high-water where observable;
- process CPU/GPU time, wakeups, I/O, and energy;
- thermal and power facts.

## Experimental design

### Treatment fingerprints

Every arm declares counters that prove it ran.

Example: held geometry must assert:

- zero active-motion bounds-size writes;
- zero active-motion native layouts;
- one intended camera presentation mutation per commit;
- exactly the expected settle behavior;
- exact final viewport and screen frames.

The stepped control must assert its intended size writes and descendant work.

Every experiment includes an A/A stability run. If identical arms differ
materially, the environment or fixture is not ready for an A/B conclusion.

The A/A rule uses a predeclared equivalence band and estimates drift/noise; it
does not prove absence of environmental bias.

### Complete phase accounting

An arm may not win by pre-rendering everything, consuming unreported memory, or
moving work into settle/background drain. Report for every arm:

- cold launch/restore to equivalent ready state;
- content mutation to ready state;
- preparation CPU/wall/bytes/energy;
- active motion;
- final delivery and settle/bake;
- complete queued-work drain;
- memory/resource high-water across the entire interval.

Ready-state equivalence requires the same semantic revision, admitted coverage,
resolution/quality policy, external-producer state, and declared outstanding
work. Include cold, warm, partial-cache, cache-reset, and immediate-motion-after-
mutation cells. Cache reset itself needs teeth.

ABBA cannot reset global WebKit/font/GPU caches by assertion. Use fresh-process
blocks or model runtime/session identity as a blocking factor when carryover
cannot be eliminated.

### Shipping-path and oracle provenance

The measured Release uses the shipping code path. Fixture hooks may orchestrate
state and input but production code may not branch on fixture seed, localhost,
scenario name, or known test classes.

Artifacts record feature flags, backend/provider identity, semantic inventory,
LOD/resolution/color/effect policy, and producer readiness for every arm. Use
randomized and withheld seeds/manifests plus at least one independently authored
fixture. A pixel oracle captured from the same candidate renderer is circular;
the reference renderer/acquisition and comparator provenance must be independent.

### Instrumentation modes and observer effect

Define three modes:

1. production-off;
2. cheap production telemetry;
3. forensic instrumentation.

Randomized instrumented-versus-uninstrumented comparisons measure absolute and
treatment-effect perturbation. Budget atomic contention, event volume, buffer
memory, overflow/drop count, and post-gesture flush. Overflow or sequence gaps
invalidate causal completeness. Include a race-sensitive run without signposts
because instrumentation can serialize bugs. Counters need independent effect
witnesses; incrementing or relabeling a counter is not proof the work vanished.

### Temporal fidelity

Static screenshots do not prove animated behavior. Control or observe:

- animation phase and rate;
- terminal cursor/output progression;
- gyro cadence;
- WK canvas/WebGL/video evolution;
- repeated/stuck frames;
- LOD transition timing and seam exposure;
- selection, caret, IME, popover, and drag-image timing.

Device-resolution comparisons include exact content/geometry/inventory and a
declared resolution-aware tolerance or perceptual mask. Exact bytes are required
only for same-renderer immutable-surface arms. Text sharpness needs anti-blur
teeth such as stable text masks/edge metrics, not permissive pixel tolerance.
Supervised real-trackpad randomized or blinded A/B remains an architecture
acceptance row where practical.

Every family declares its visual/temporal acquisition and oracle status as
`supported`, `bounded`, `humanReviewed`, or `missingCoverage`. WK video/WebGL and
Ghostty accelerated surfaces must not silently inherit AppKit `cacheDisplay`
coverage; Array's existing nonblank snapshot check remains only a smoke floor.

### ABBA for two arms

Use the existing within-block pattern:

```text
A -> B -> B -> A
```

Reset to an identical settled state before each arm. Reverse subsequent blocks
where useful. Preserve block/order identity in analysis. ABBA does not itself
remove carryover: verify cache, memory, producer, thermal, and runtime reset
teeth; otherwise use randomized sequences and block on session/runtime identity.

### More than two arms

Use a seeded balanced Latin square or randomized complete-block order. Store the
seed in the artifact.

The independent hierarchy is explicit: gestures nest in blocks, blocks in
sessions/days, and sessions in machines. The replication unit depends on the
claim; frames are never independent replicates.

### Factorial attribution

The first activity interaction study crosses:

- agents idle/active;
- stream updates held/applied;
- WK static/animated;
- Ghostty idle/outputting.

For two factors, calculate interaction on additive matched quantities:

```text
I(A, B) = T(A+B) - T(A) - T(B) + T(baseline)
```

Do not subtract FPS, ratios, or separately computed percentiles.
The four-factor study uses replicated randomized factorial blocks and
predeclared main-effect/interaction contrasts on the original additive scale.
Unpowered higher-order interactions remain exploratory.

Family replacement attribution distinguishes:

1. live native visible;
2. exact surface visible with native installed and still drawable;
3. conditionally, exact surface visible with native installed but raster-
   suppressed under a family-specific public policy whose teeth prove raster
   stopped without changing the traversal being isolated;
4. exact surface visible with native parked outside the scale-changing
   hierarchy;
5. subscription/runtime activity independently held or removed.

An opaque overlay alone only adds overlay cost; it does not prove native raster
stopped. Hiding/opacity changes may alter traversal and require their own teeth.

### Dose-response slopes

Sweep the actual claimed driver:

- total semantic tiles;
- visible presentation chunks;
- viewport pixels;
- overdraw/masks;
- native descendants;
- history depth;
- Markdown blocks;
- active streams/gyros;
- pinned native islands;
- dirty pixels;
- retained bytes/world extent.

Predeclare predictor/response transformation, expected or segmented functional
form, randomized level order, replication, session/machine blocking, residual
diagnostics, and the slope/nonlinearity margin considered flat enough. Report
raw points, uncertainty, and threshold/cliffs. A good twenty-tile result is not
proof of the target scaling law.

Scaling claims use a multidimensional tested envelope across tile count, history,
dirty/churn rate, viewport pixels/scale, overlap/effects, native islands,
retained bytes, and world extent. Use geometric doubling toward saturation and
report overload/recovery. Never extrapolate beyond the tested envelope.

## Statistical policy

- Five observations are an exploration floor, not decision-quality evidence.
- Decision replication derives from a predeclared minimum useful effect or
  non-inferiority margin, A/A/historical variance, desired precision/power, and
  the true independent session/day/machine unit.
- Predeclare maximum sample count, interim looks, and stopping rule.
- Retain every raw gesture and frame.
- Compute paired additive effects per block; use ratios/log-ratios only for
  stable positive denominators.
- Use a named estimator and interval method appropriate to independent block
  count. Ordinary percentile bootstrap for a small-sample median is not the
  universal default; exact sign/permutation methods or Hodges–Lehmann effects
  may be preferable.
- Cluster/resample by block/session, never individual frames.
- Predeclare one confirmatory primary metric/direction/margin. Secondary metrics
  are diagnostic unless multiplicity is handled explicitly.
- Report every registered metric even when metrics disagree.
- Never remove an outlier merely because it is slow.

Per-gesture p50/p95/worst are descriptive. P99 requires predeclared larger
exposure with trials retained as clusters. Catastrophic-stall rates report
numerator, denominator, and active-motion exposure, with cluster-aware
uncertainty. Wide uncertainty is inconclusive, not a pass.

A trial may be invalid only for a pre-treatment eligibility failure or clearly
exogenous interruption:

- fixture already mismatched before the arm;
- foreground/thermal/readiness already outside the declared starting envelope;
- unrelated user/system interruption;
- unrelated display reconfiguration.

Treatment-induced thermal escalation, process death, queue/recorder overflow,
fingerprint mismatch, incomplete output under load, or cadence change remain
failure outcomes or observations. They are not censored. Report all-started-
trials analysis plus any sensitivity analysis excluding documented exogenous
interruptions.

Invalid trials remain in the artifact with their reason.

Preferred gate order:

1. exact invariants and counts;
2. scaling slopes;
3. paired pan-relative effects;
4. hardware-specific absolute ceilings.

Cross-machine absolute milliseconds are the last line of defense, not the
primary causal proof.

## Environment and warmup validity

Every performance artifact records:

- SHA and dirty state;
- build configuration/compiler/app version;
- fixture schema/hash/seed;
- macOS build and hardware CPU/GPU/RAM;
- display identity/resolution/advertised refresh/measured cadence/backing scale/
  color space;
- window size/placement/foreground/occlusion;
- power source, Low Power Mode, thermal state;
- memory pressure;
- Array/WebContent/GPU child-process identities;
- profiling enabled or disabled.

Each field declares its owner and availability. SHA/dirty/compiler are runner or
build-manifest facts; display/power/thermal/process facts are runner/system
facts; missing values are explicit `unknown`, never fabricated defaults.

Capacity and product conclusions require Release, target hardware/display class,
stable power/thermal state, foreground visibility, and no display migration
within a block.

Warmup is state-based rather than “sleep N seconds,” using common arm-independent
readiness criteria. Quiescent arms may require counter stability. Animated,
video, terminal-cursor, or controlled-streaming arms instead require explicit
family ready handshakes, then begin identical seeded churn at a declared epoch.
Do not warm until a treatment-specific expensive operation disappears unless
that warm state is itself the product condition under test.

Realistic modes remain explicit:

- cold restore;
- warm quiescent;
- controlled live churn;
- long soak.

Background work is controlled and measured, not secretly disabled.

## Architecture-layer test matrix

### Revisioned snapshots/display lists

Contract/property tests:

- identical state/revision produces equivalent descriptions;
- no NSView/CALayer/Metal/runtime object is semantic truth;
- snapshot plus arbitrary tail equals direct final reduction;
- publications are monotonic and compatibility rules explicit;
- stale completion cannot replace newer compatible state;
- dirty bounds contain every changed dependency;
- camera-only changes produce no semantic reduction/description rebuild.

Incrementality sweep:

- append a small suffix to histories of 10/100/1,000/10,000 blocks;
- work follows changed suffix/fragments, not unchanged history;
- unchanged prefixes preserve reusable identity/storage.

Fidelity:

- native and candidate backends consume the same description;
- compare pixels, geometry, content inventory, hit regions, and AX;
- include prose, code, commands, images, collapsed content, selection, scroll,
  light/dark, 1x/2x, and pathological text.

Reject if a delta copies/traverses total history or backend-specific ownership
leaks into semantic truth.

### Family pixel producers

Common contract:

- coverage/effect padding/dimensions/scale/color/alpha/revisions/timestamps/
  bytes are internally consistent;
- completion is immutable;
- cancellation is idempotent;
- cancelled/stale output cannot publish;
- dependency invalidation is exact;
- failure retains the last complete compatible surface.

Metrics:

- latency by family/resolution;
- main-thread time;
- changed versus produced pixels;
- cancellation/supersession;
- source-to-visible age;
- CPU/GPU/external/transient bytes.

Family-specific failure does not invalidate unrelated layers or producers.

External fixtures use bundled fonts/assets, a loopback server with recorded
request schedule and network blocked after load, controllable JS/media time
where possible, a seeded terminal byte/timing generator, explicit ready
handshakes, and recorded process-pool/runtime identity. Restart/crash arms are
separate. Nondeterministic producers are judged by bounded distributions plus
exact content/state invariants, not impossible timestamp equality.

### Sparse spatial/resolution scene

Compare the optimized index to a brute-force oracle on generated small worlds:

- viewport intersection;
- z/hit order;
- chunk coverage;
- dirty union/effect expansion;
- resolution selection;
- eviction candidates.

Metamorphic properties:

- translate world and camera together: identical screen result;
- split/merge equivalent chunks: identical pixels and hit order;
- insertion order: no semantic z-order change;
- floating-origin rebase: no persisted/visible change;
- adjacent resolution bucket: sharpness may change, content may not.

Adversaries:

- reversal, diagonal seam crossing, zoom-out, teleport, cold open, purge, memory
  pressure, display/style/color change, device loss, overlapping effects.

Use both exact region algebra and a coverage bitmap. No admitted pixel may be
uncovered or replaced by a shell.

### Revisions, scheduling, and backpressure

Generate interleavings of:

- semantic updates;
- presentation/resource/style changes;
- resolution requests;
- completion/cancellation/eviction;
- camera movement;
- park/promote.

Assert:

- bounded queues;
- superseded work discarded;
- visible revision never moves backward;
- compatibility vector holds;
- camera never waits for producer lanes;
- semantic events are never lost;
- every visible family advances within its declared freshness contract under
  continuous load.

Until D2/D8/D9 absolute freshness is decided, require treatment non-inferiority
to control for source-to-visible age, maximum starvation interval, accepted-to-
visible progress, and complete-drain time under equal input. Also record the age
distributions rather than inventing arbitrary absolute product thresholds.

### Compositor-owned camera

Exact zero budgets apply to work causally initiated by, carrying the cause ID of,
or synchronously awaited by a camera commit:

- semantic reductions;
- TextKit layouts;
- native captures;
- WK snapshots;
- terminal readbacks;
- image decodes;
- animation graph rebuilds;
- native tile layouts caused by camera presentation;
- synchronous missing-resolution production.

Independent producer work may overlap the same wall-clock frame during live
churn. Record it separately as contention; do not falsely fail the causal camera
invariant merely because unrelated work is concurrent.

Positive teeth:

- camera mutation occurred;
- presentation moved;
- anchor error within one device pixel;
- final semantic viewport exact;
- presentation-set switches only at prepared atomic boundaries.

CA-versus-Metal comparisons use identical immutable prebuilt surfaces and
exclude producers. Measure Array CPU, transaction/command cost, actual available
presentation timing, uploads, GPU/WindowServer time, draw/layer count, overdraw,
and memory. A slow producer is not evidence for Metal.

### Native interaction and state parking

State-machine tests:

- only legal surface/promoting/native/demoting transitions;
- balanced pin reasons;
- unsafe demotion refused;
- cancellation safe from every transition;
- repeated transitions idempotent.

Exactly-once nonce tests:

- click/double-click/wheel/key/link/disclosure/drag/context menu/AX action;
- target changes/disappears between surface event and promotion;
- reconcile by represented revision and stable identity or explicitly cancel;
- never act on a different target.

Family round-trip:

- agent: exceed 500-event replay gap while parked; preserve transcript, anchor,
  disclosure, selections, draft, attachments, focus/completion;
- browser: preserve WebView/runtime identity, history, forms, scroll, selection,
  find, media/dialog state;
- terminal: preserve process, exact grid/frame, scrollback, selection, alternate
  screen, cursor, mouse capture, IME;
- file: preserve owned content revision, mode, scroll, selection, anchor, parsed
  state, pending reveal.

Demount is not accepted until the same suite passes after destruction and
reconstruction. Until then only parking is proven.

Performance sweep uses 0/1/2/5 genuinely active pinned TextKit/WK/Ghostty
islands. Static placeholders are not evidence.

In addition to named round trips, a stateful model/property harness generates
long sequences of camera updates, semantic updates, edits, selections, IME,
park/promote, workspace switch, memory pressure, process crash, and teardown/
restore. It compares a renderer-neutral state fingerprint after every step,
including updates while parked, more than 500 agent events, and repeated
promotion during in-flight input.

### Z-order and overlap

Generate overlapping rectangles and compare per tested pixel:

- rendered paint owner;
- semantic hit owner;
- native hit owner;
- accessibility hit owner.

Include lower-z native islands, higher-z surfaces, translucency, clipping,
shadows, popovers, menus, drags, and transitions.

### Accessibility mirror

Deterministic tests:

- stable IDs/roles/labels/values/actions/order;
- incremental intended-node-only changes;
- camera changes geometry without rebuilding semantic AX;
- frames within one device pixel;
- native promotion suppresses duplicate mirror nodes atomically;
- focus survives camera, parking, promotion, demotion, and rebase.

Integration invokes actions through macOS accessibility APIs, not only internal
closures. Supervised VoiceOver traversal remains a product acceptance row.

### Coordinates, cold admission, recovery, privacy

Coordinate properties:

- huge positive/negative positions;
- deep fractional zoom;
- repeated floating-origin rebase;
- world/viewport/screen/native/AX round trips;
- chunk seams, snapping, effects, 1x/2x.

Cold admission:

- initial open, teleport, zoom-out, full purge, display/style change, producer
  failure, device loss;
- visible scene is the previous complete scene or newly complete envelope under
  D13, never a partially admitted target.

Privacy/resource lifetime:

- sentinel private strings in every family;
- scan logs, JSON, census, descriptions, temp/cache dirs, and diagnostics;
- schema allowlist rather than blacklist redaction;
- no real workspace screenshots/surfaces in artifacts;
- repeated open/close/evict/switch/park cycles return subscriptions, observers,
  timers, views, layers, WebContent processes, Ghostty surfaces, and CPU/GPU
  resources to bounded steady state.

Allowlisted JSON is the primary privacy control; sentinel scanning is secondary.
String scans cannot detect encoded/compressed content, sensitive pixels, trace
metadata, raw argv, or split/truncated values. Opaque Instruments traces,
screenshots, and crash/memory diagnostics are prohibited for production
workspaces by default and run only on synthetic faithful fixtures. Production
dogfood artifacts remain local/non-exportable unless separately approved.

## Multi-process and system profiling

Run lightweight counters first. Confirm fixture and treatment teeth, then profile
the same manifest/seed in a separate diagnostic run.

Do not use profiled timings as regression numbers; Instruments changes cost and
scheduling.

Capture and align:

- Array Time Profiler and Points of Interest;
- Array Allocations/VM Tracker;
- WebContent and WebKit GPU process CPU/memory/thread state;
- WindowServer/Core Animation/System Trace;
- GPU activity and Metal System Trace when applicable;
- wakeups, runnable queues, page faults, pressure, energy;
- Array raw frame/counter timeline.

Record observable child-process lifetimes before and after each trial. Array can
emit marker intervals; WebContent/GPU/WindowServer cannot be required to emit
Array IDs. Align clock sources through recorded conversion/offset markers and
report association ambiguity and uncertainty. Do not exonerate external
processes because Array CPU is low,
and do not sum concurrent process percentages into fictional wall time. Use
critical-path overlap with each delayed cadence interval.

Whole-system/presentation qualification is mandatory before accepting changes
that affect native hierarchy/backing, CA/Metal composition, WKWebView, Ghostty,
surface memory, or resource residency. Without a trustworthy presentation
witness the result is labeled submission/callback improvement, not proven user-
visible smoothness. System traces localize correlation; causal attribution still
requires an intervention that changes the suspected stage and produces the
predicted end-to-end effect.

## Memory, resource, and energy shapes

Measure:

1. cold peak — restore, first overview, first zoom;
2. warm steady state — repeated gestures after caches settle;
3. long soak — camera plus controlled churn through eviction/thermal equilibrium.

Report Array and child-process:

- resident/physical footprint;
- allocation/deallocation rate;
- surface/image/IOSurface/texture accounting;
- page faults/compression;
- CPU/GPU time;
- wakeups and energy;
- resource counts after return to idle.

Account ownership to avoid double-counting shared IOSurface/GPU memory and label
unobservable bytes explicitly. Separate allocator caching from live-resource
counts. “Steady” and “converged” require a declared observation window plus
memory/resource slope and high-water criteria. Thermal escalation and process
replacement during soak are product outcomes, not invalid trials.

Required invariants:

- cache stays under declared byte limits;
- repeated identical gestures converge rather than grow memory;
- eviction returns resources within declared behavior;
- camera changes inside one resolution bucket do not reload resources;
- settled idle returns to bounded CPU/wakeup activity.

## Artifact format

Each run creates an immutable directory beneath the established
`qa-runs/<run-id>/renderer/` root:

```text
run/
  manifest.json
  fixture.json
  trials.jsonl
  frames.jsonl
  events.jsonl
  spans.jsonl
  counters.jsonl
  correctness.jsonl
  summary.json
  analysis-version.json
  digests.json
  COMPLETE
  screenshots/
  traces/
  logs/
```

`manifest.json` contains environment, build, a sanitized allowlisted invocation
description, schemas, clock sources/units, privacy declaration, and availability
facts. Never store raw argv/environment/working paths by default.

`fixture.json` contains only sanitized shape and deterministic fixture inputs.

Every trial includes:

- IDs/block/order/arm/seed;
- gesture and camera path;
- start/end state;
- environment validity;
- treatment fingerprint;
- structural/correctness/fidelity verdicts;
- summary metrics;
- invalidation reason.

`frames.jsonl` stores each interval, cadence multiple, activity phase, latest
applied/committed revisions, and selected counter deltas. Timestamped events and
spans remain separate because framework work does not map one-to-one to a frame;
the analyzer joins them under explicit attribution rules and clock uncertainty.

Every schema/version/unit/process/optional-field reason is explicit. Record
buffer capacity, overflow/drop counts, sequence gaps, timestamp precision, boot/
session identity, and record-count cross-checks. `digests.json` stores per-file
hashes/byte counts without circularly hashing itself. `COMPLETE` is written
atomically only after referential-integrity, privacy, checksum, and recorder-
completeness checks pass. Missing `COMPLETE` means incomplete, never partial
success.

Every screenshot/diff records acquisition API/stage, trial/frame/scene/content/
resource revisions, pixel and point dimensions, scale, pixel/alpha/color profile,
crop/world bounds, z/effect inventory, reference hash, and comparator version.

Raw artifacts are immutable. A versioned analyzer produces summaries and plots,
allowing statistical corrections without rerunning the app.

Privacy checking is itself a required harness gate. The artifact records the
privacy-policy/gate version and the decoded/decompressed formats inspected; an
uninspectable binary payload is not declared clean by a string scan.

Artifacts have an explicit retention/deletion policy, especially for traces and
surface/image data.

## HUD and offline visualization

### Live HUD

Keep it deliberately small and cheap:

```text
32 FPS · 48% late · p95 44 ms
zoom · 4+ miss: 3 · worst 612 ms
```

Optional additions:

- active versus settle indicator;
- recording/profile indicator;
- catastrophic-stall count.

It continues to reuse the recorder and publish at low cadence. No separate
timer/display link, per-frame sorting, or file I/O.

### Offline dashboard

The dashboard carries depth:

- raw frame timeline with camera and signpost spans;
- interval histogram and ECDF;
- cadence-severity bars;
- pan-versus-zoom paired plot;
- active-versus-settle plot;
- slope curves and confidence bands;
- factorial main-effect/interaction plots;
- frame intervals correlated with layouts, draws, allocations, WebContent, and
  WindowServer;
- memory/cache/eviction timeline;
- correctness/fingerprint panel;
- fixture/environment parity panel;
- links to exact raw artifacts and traces.

## Matrix, known-red, and reporting policy

- Tier 1 contract checks belong in the ordinary matrix.
- Stable Tier 2 display checks may be display-dependent matrix legs with loud
  skips when unavailable.
- Tier 3 Release labs and Tier 5 soaks are explicit suites, never implied by a
  normal matrix pass.
- Every new leg enters the matrix inventory.
- Known reds publish the product target and current number.
- A known-red pass is a stale allowlist warning until confirmed and removed.
- No source edit occurs while a same-worktree measurement build/run is active.
- A run summary says exactly which tiers and scenarios ran, skipped, failed,
  invalidated, or remained known red.

## Admission rule for performance evidence

A result may influence an architecture or optimization decision only if:

```text
fixture parity
AND environment validity
AND treatment fingerprint
AND structural gate
AND correctness/fidelity gate
AND raw artifact completeness
```

are all green.

Then, and only then, duration/FPS/resource results are interpreted.

Every proposed optimization must declare before measurement:

- which counters should change;
- which counters must remain unchanged;
- what visual/behavioral teeth protect required work;
- which timeline stage should improve;
- which scaling driver should flatten;
- what evidence would reject the hypothesis.

If timing improves without the predicted causal change—or if pixels, freshness,
interaction, state, accessibility, or resources change—the experiment does not
validate the optimization.

## Open decisions for walkthrough

### T1 — Standing Release lab

Which machine/display configurations are authoritative, how often does the lab
run, and which results gate changes versus inform trends?

### T2 — Raw recorder scope

Which stage/counter fields are safe and cheap enough for dogfood recording, and
which remain lab-only?

### T3 — Observed cadence policy

How should variable-refresh calibration define on-time and missed-cadence
buckets across 60/120 Hz displays?

### T4 — Primary product metrics

Which metrics are primary for camera acceptance: pan-relative p95, late share,
catastrophic stalls, input-to-explicit-flush, another named software endpoint,
or explicit
per-display profiles?

### T5 — Statistical confidence

How many paired blocks are required for exploratory, architectural, and release
decisions, and what minimum useful effect is worth detecting?

### T6 — Faithful fixture privacy

Review and approve the census allowlist, bucketing, export UX, retention, and
sentinel privacy gate.

### T7 — Visual equivalence

Define pixel tolerances, physical resolution requirements, animation-time
control, color-space cases, and when human review is required.

### T8 — External producer fidelity

Define WK/Ghostty/static/animated fixture oracles and what unsupported content
must report.

### T9 — Freshness metrics

Choose the family/state freshness contracts from D2/D8/D9, after first observing
real age distributions.

### T10 — Whole-system tooling

Choose the standard Instruments templates, capture duration, PID alignment,
artifact retention, and what evidence is considered sufficient to attribute a
WindowServer/GPU bottleneck.

### T11 — Memory/energy budgets

Choose byte accounting scope, pressure behavior, soak length, return-to-idle
expectations, and hardware-specific ceilings.

### T12 — Dashboard shape

Decide which plots are required for every run and which deep views remain
diagnostic.

### T13 — Known-red transition

Define when an exploratory probe becomes a standing contract, when a known red
may be removed, and how baseline/trend history is retained across architecture
changes.

### T14 — Harness overhead budget

Set allowable recorder/counter/signpost overhead and the A/A protocol that proves
instrumentation itself does not materially change the camera path.

### T15 — Camera truth and progress

What maximum desired-to-visible camera error, revision age, repeated-frame run,
and post-gesture drain are acceptable, and which presentation witnesses can
support each claim?

### T16 — Interim freshness protection

Before absolute family freshness contracts are chosen, what non-inferiority
margin applies to source-to-visible age, starvation interval, accepted-to-visible
progress, and complete drain?

### T17 — Charged phases and readiness

Which preparation, active-motion, settle, bake, and drain costs are charged for
each product state, and what exact semantic/coverage/resolution/runtime state
makes two arms equally ready?

### T18 — Presentation qualification

Which classes of renderer change require whole-system/presentation evidence,
which public or system witness is trusted, and when should harness qualification
use an independent screen-capture or high-speed-camera cross-check?

### T19 — Telemetry modes

What event-volume, atomic-contention, memory, overflow, and flush budgets apply
to production-off, cheap telemetry, and forensic instrumentation?

### T20 — Shipping-path and oracle independence

How will withheld fixtures, backend identity, feature flags, and independently
sourced references prove the benchmark did not select a test-only path or grade
its own output?

### T21 — Tested scaling envelope

Which combinations of tiles, history, churn, viewport pixels, scale, effects,
pinned islands, retained bytes, and world extent must pass before an “unbounded”
scaling claim is allowed?

### T22 — Artifact privacy boundary

Which artifacts are forbidden for real workspaces, which remain local-only, how
are binary/trace/image payloads handled, and what retention/deletion policy is
required?

### T23 — Human temporal-fidelity protocol

What standardized real-trackpad, animation, browser, terminal, IME, overlap, and
VoiceOver comparison must architecture milestones pass, with randomized or
blinded order where practical?

## Working testing statement

> Array's renderer program is governed by causal evidence, not benchmark scores
> alone. Deterministic counters prove that intended work changed; independent
> visual, semantic, interaction, state, and accessibility oracles prove required
> behavior remains; display-paced Release trials prove the user benefits; raw
> artifacts, paired experiments, scaling slopes, and whole-system traces prevent
> medians or app-only profiles from hiding failures. The harness reuses Array's
> existing performance budgets, camera oracles, raster pumps, UI baselines,
> matrix discipline, and HUD while adding faithful mixed fixtures, unified
> timelines, revision/coverage/resource accounting, multi-process evidence, and
> architecture-specific gates.
