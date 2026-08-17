# 96 — Ledger

Append-only record of witnesses, in the order they were observed. Every entry
records what was RUN and what it PRINTED, not what was intended.

Source commit: `d334f019ac3aa855ffda40402f6dfb9ed8550247` (`array/integration`).
Worktree: `~/array-worktrees/sidebar-96`, branch `array/sidebar-96`, clean at start
(`## array/sidebar-96` with no modified paths). The uncommitted canvas-performance
changes in the main checkout belong to `array/canvas-perf` and are deliberately
absent from this worktree.

---

## P0 baseline — 2026-08-14

All green before any edit, so a later red is attributable to this program:

| leg | result |
|---|---|
| `swift build --product Array` | GREEN, 76.23s |
| `.build/debug/Array --sidebar-ux-check` | GREEN — `ContinuumRevivedSidebarUXChecks passed` |
| `swift run ContinuumRevivedAgentUIChecks` | GREEN — includes `SidebarDefectCorpus checks passed: 11 declared shapes ↔ 11 corpus arms…` |
| `.build/debug/Array --agent-inbox-check` | GREEN — `ContinuumRevivedAgentInboxChecks passed` |

**Measured current geometry, harvested from `--agent-inbox-check`'s own output** (so
S0's reference anchor is measured rather than quoted from prose): parked/slim rows
`35.0pt`, full cards `79.0pt`, and the lifecycle crossfade holds the outgoing card at
`(0.0, 83.0, 303.0, 83.0)` — i.e. **79 pt card on an 83 pt pitch**, at a 303 pt
content width. This is consistent with `performance`-style prose in the design
(§2.2's "79 pt card + 4 pt gap = 83 pt pitch") and is now witnessed.

---

## P0.1 — entry witness, RED — 2026-08-14

### Half 1: the existing corpus passes

`.build/debug/Array --sidebar-ux-check` → GREEN (above). The queue-94 corpus,
`LabFixtures.sidebarDefectRows`, covers 11 declared shapes with two-way parity and
full state/attention/lifecycle/variant/depth coverage — and it is all hand-written
`AgentInboxRow` literals.

### Half 2: the product still renders the owner-screenshot row

New leg `.build/debug/Array --sidebar-production-corpus-check`, **exit 1**:

```
FAIL: P0.1 inventory missing at …/96-agent-sidebar-product-redesign/P0.1-fixture-inventory.md
      — every declared flow must map to its resulting row and surface in a committed document
SidebarProductionCorpus: observed rows per flow
  blankCmdKDraft: title='New agent' state='Unconfirmed' meta='' branch='' elapsed='' providerGlyph='◈'
```

That row was produced by driving the real writer the ⌘K path reaches
(`AgentSupervisor.spawn(role: nil, prompt: nil, …)`, AgentSupervisor.swift:1458 →
`makeAgent` :1545 → `persist` :1618) against real on-disk stores, then read off the
**rendered cell** through the real join (`refreshAgentSurfaces` →
`buildAgentInboxRows` → `AgentContextIndex.build` → `AgentInboxRowBuilder.rows` →
`AgentInboxView`). Nothing in the flow constructs an `AgentInboxRow`.

So both halves of §6/P0.1's stated entry witness are observed together: the current
corpus passes while an owner-screenshot-equivalent row renders a sentinel subject,
three empty detail bands, and an unexplained Unicode mark. Specifically:

- `title='New agent'` — a durable record exists before the user typed anything
  (design §2.4). The sentinel beats the model-named tile title.
- `meta=''`, `branch=''`, `elapsed=''` — **every** detail band is empty. This is the
  measurable form of "mostly empty 83 pt rows" (§2.2): of the row's bands, only the
  subject and a glyph carry anything.
- `providerGlyph='◈'` — the `AgentProviderGlyph` map's OpenAI arm. The design's
  complaint is the class of mark, not one codepoint; the unknown-provider arm of the
  same map returns `'◇'` and is covered by the `unknownProvider` flow.
- `state='Unconfirmed'` — a never-observed record is frozen as unconfirmed
  (`UnconfirmedElapsedFreeze`, ContinuumApp.swift:7861), so even the state word is
  about Array's own bookkeeping rather than the agent's work.

### Declared fence deviation

The plan's fence did not include `AgentInboxView.swift`. Witnessing the provider mark
requires four QA-only additions there, declared here per §7.1:

1. `AgentInboxRowCell.qaProviderGlyph` (protocol requirement);
2. `AgentInboxCellView.qaProviderGlyph` — reads `providerGlyphLabel`;
3. `AgentInboxSlimCellView.qaProviderGlyph` — `""`, because a slim row draws no
   provider mark (its one glyph is the status glyph);
4. `AgentInboxView.providerGlyphsForQA`.

Why it is necessary rather than convenient: the card cell's existing `qaGlyph`
deliberately returns `""` (it means the STATUS glyph, and a card carries state as a
word), and the provider diamond lives on `providerGlyphLabel`, which had no accessor
at all. The alternative — asserting on `AgentProviderGlyph.glyph(for:)` — would
re-derive what production derives and would stay green if the row painted something
else entirely. No behaviour changed; no existing accessor changed meaning.

## P0.1 — GREEN — 2026-08-14

`.build/debug/Array --sidebar-production-corpus-check`, **exit 0**:

```
SidebarProductionCorpus checks passed: 30 production flows drove real writers and were
read off rendered cells, 30 inventory rows in two-way parity
```

Focused legs re-run after the change, all still green: `--sidebar-ux-check`,
`swift run ContinuumRevivedAgentUIChecks` (including the queue-94
`SidebarDefectCorpus` gate), `--agent-inbox-check`. `git diff` shows **no change** to
`ComponentLab.swift`, so the queue-94 marker region and its text-scanning gate are
untouched.

The observed rows are tabulated in `P0.1-fixture-inventory.md`. The product facts they
establish, each from a rendered cell rather than a fixture:

1. **The row carries two facts and a glyph.** Of six painted bands, `meta` and `branch`
   are empty in **every one of 30 flows**, and the placement band never holds more than a
   project name. "Too sparse" is now a measurement.
2. **`Project › Zone` never renders.** Not even for `exactPlacement`, whose tile really is
   on the project canvas and geometrically inside the zone (`SidebarTree.tiles(for:)`
   assigns by tile centre). The Zone half of §4.3's first line does not exist today.
3. **The placement band is the FIRST casualty of width.** `firstSendTitleFallback`,
   `generatedTitleLanded` and `longUnicodeRTL` render no project at all — all three are
   the long-title rows, and the measured-fit tier (`tier.drawsProject`) drops placement at
   the DEFAULT 280 pt width. §4.3 puts placement fourth in the sacrifice order and
   requires it to survive in tooltip/AX.
4. **Three of five terminal outcomes render no state at all.** `succeeded`, `interrupted`
   and `cancelled` all paint `state=''`; `failed` and `runtimeError` both paint `Failed`.
   Success, interruption and cancellation are pixel-identical.
5. **No row anywhere carries a completion time.**
6. **Approval and input are the same word** (`Needs attention`).
7. **Provider identity is one of three Unicode glyphs** — `◈` / `✦` / `◇` — with no model
   text; the unknown-provider arm is the bare diamond the owner rejected.
8. **A blank ⌘K is durable work** (`New agent` / `Unconfirmed` / `array-scratch` / three
   empty bands — the owner screenshot verbatim), and an accepted image-only send keeps the
   sentinel.

### A wrong claim caught before it was published

The first version of the inventory recorded `meta` as the placement band and therefore
asserted "placement is empty in every flow". That was **false**: `metaLabel` composes
isolation and child rollup, while placement is a separate `projectLabel` that had no QA
accessor at all, so it was never observed. Adding `qaProject` showed every row painting
`array-scratch` — which is what the owner screenshot shows, and a materially different
finding from "empty". The inventory now names all six bands and what each composes. The
lesson is the design's own: a band you have not read is not a band you know.

### Two harness defects found and fixed before they could produce false evidence

Recorded because each would have made a green run mean nothing:

1. **Index-paired observation.** The first version zipped `rowIdsForQA` (the whole row
   model) against `titlesForQA` (only MATERIALIZED cells). Once rows outnumbered the
   viewport those lists had different lengths, so it attributed one agent's paint to
   another agent's id. Now every fact is read off one cell, keyed by that cell's own
   `qaAgentID`.
2. **Vacuous rendering.** Observing through the sidebar's own table returned **zero**
   cells for 23 of 24 flows while the table reported 24 rows — the shipped push is
   incremental and, as `AgentInboxView.rebuildRowsForQA`'s own comment records, an
   offscreen window defers that reload indefinitely. Rows are now rendered for
   observation in a sized, frame-pinned `AgentInboxView` (the arrangement
   `--sidebar-ux-check` already relies on). The VALUES are still production's, read back
   via `qaAllRowsForQA`; only the reload strategy and viewport belong to the probe.

### A product behaviour confirmed as correct, not a defect

`claudeAnthropic` and `unknownProvider` initially rendered the sentinel title after a
send. That looked like a naming defect; it was `sendPrepared` **correctly refusing**
(`IntentRefusal.invalidAttachment`) a model that does not belong to the harness's own
catalogue — AGENTS.md non-negotiable #5, exact model ids and no cross-CLI fallback.
Those flows now spawn and `rename` instead, so they isolate provider identity from send
admission. `FlowResult.acceptance` exists so a future refusal can never again be
mistaken for a row defect.

### Additional declared fence deviations (QA-only, no behaviour change)

Beyond the four provider-glyph accessors above, two more additions to
`AgentInboxView.swift`, both forced by the vacuity defect:

5. `qaAllRowsForQA` — the rows the last production push handed the view, so the corpus
   can render exactly those values.
6. `fullReloadForQA()` and `qaTableGeometryForQA` — the second was the diagnostic that
   located the deferred-reload defect (table reporting 24 rows, 1 column, a 548 pt
   visible rect, and zero built cells). `fullReloadForQA` is retained as the documented
   escape from the incremental path.

### Not yet covered

Five §6/P0.1 shapes remain, listed at the foot of the inventory rather than quietly
omitted: `restoredPendingRequest` (needs a relaunch world), `exactPlacement` /
`ambiguousPlacement` (needs real canvas tiles — also the only way `meta` becomes
non-empty), `piAnthropic` / `piOpenAI`, a dedicated `unconfirmed` flow, and
`fiftyActiveWithHistory`. The packet is not done until these exist.

---

Also required, and declared: `AppDelegate.makeSidebarCorpusWorld(now:)` lives in
`ContinuumApp.swift` rather than beside the corpus, because the wiring it performs
touches `private` members of `AppDelegate` (Swift grants that only to same-file
extensions) and `configureWorkspaceSidebar`'s declaration is pinned verbatim by a
program source-scan at ContinuumApp.swift:26751 — widening it would break that gate.
Every flow, expectation, and the inventory gate stay in
`SidebarProductionCorpus.swift`.

---

## P0.2 — entry witness, RED — 2026-08-14

No capture artifact in the repo was §3.3-traceable. `QACapture.Manifest` carries only
`flow`, `generatedAt`, and per entry `step`/`tSec`/`png`/`canvasState`/`notes`;
`UITourCheck` writes a Markdown index with surface/state/size/appearance. Neither
records a commit, a bundle hash, a fixture id, or — the one that matters most — a
`captureType` distinguishing a live-window capture from an offscreen render. §3.3 says
an offscreen probe is a geometry gate, not proof of the live product, and nothing on
disk could tell the two apart.

## P0.2 — GREEN — 2026-08-14

`--sidebar-screenshot-check` (offscreen): **38 images**, 4 widths × 2 appearances plus
accessibility variants and the three density proposals, with a machine-readable
`manifest.json` carrying every §3.3 field. Gate asserts mechanics only: every planned
PNG on disk, manifest ↔ directory parity in both directions, no empty provenance field,
no blank image (`VisualSnapshot.metrics.isBlank`), and Aqua ≠ Dark Aqua per fixture.

`--sidebar-live-capture-check` + `scripts/capture-sidebar-96.sh` (live): PASS at 220,
280 and 360 pt on `~/Desktop/Array Dev 96.app` over `~/array-scratch-96`, each width
capturing both `live-window` (CGWindowListCreateImage) and `live-view-cache`
(cacheDisplay), with requested width == measured width.

### The number that answers S0

Counted off painted cells, not divided out of a constant:

| | card | pitch | complete rows in 662 pt |
|---|---:|---:|---:|
| today, shipping | 79.0 pt | 83.0 pt | **7** |
| proposal A | 66 pt | 68 pt | **9** |
| proposal B | 72 pt | 75 pt | 8 |
| proposal C (= today, redrawn) | 79 pt | 83 pt | 7 |

§8.1's floor is nine. Only A meets it. **But proposal C — today's pitch with the intended
bands filled in — reads perfectly well**, so the sparseness is mostly a content problem
rather than a height problem. That is in the S0 doc, because it changes what Dylan is
being asked to approve.

### A false green caught in the live check

The first version of `runSidebarLiveCaptureCheck` reported **PASS over a screenshot
reading "No agents yet"**. Two independent causes, both the exact failure mode this
program exists to prevent:

1. it waited a fixed 1.0 s, and the app's own boot reloaded the sidebar after the push;
2. it counted rows by walking the view tree, which also finds cells AppKit has not yet
   removed — so five stale views were reported as "5 rows" over a picture of the empty
   state.

It now polls until the rows are in the model AND painted as agent cells AND the empty
state is gone, re-pushing each tick, and **exits nonzero if that never happens**. A
capture indistinguishable from an empty sidebar is worse than no capture.

### A false number caught in the density arithmetic

`SidebarDensityProposal.completeRows(in:)` first computed `(viewport + gap) / pitch` and
claimed **8** rows for proposal C, where the real sidebar paints **7**. Since C *is*
today's geometry, a teeth check now requires C's computed card, pitch and row count to
equal the measured values; the formula became `(viewport − outerGutter) / pitch` and
agrees. Without that check the 9 reported for A would have been unfalsifiable.

### Matrix

Registered `--sidebar-production-corpus-check` and `--sidebar-screenshot-check` after the
`--sidebar-ux-check` line. Confirmed in a real run under an isolated tmux namespace
(disposable `TMUX_TMPDIR`, `TMUX`/`TMUX_PANE` unset, socket path resolved with `pwd -P`
and verified inside it before starting — the naive string compare failed only because
`/tmp` is a symlink to `/private/tmp`):

```
---- Matrix: 156 leg(s) run ----
KNOWN-RED, expected (6): swift run ContinuumRevivedPaletteChecks
  --palette-first-responder-restore-check --agent-supervisor-check --nav-mode-check
  --perf-budget-zoom-check scripts/check-root-docs.sh
Matrix passed.
```

Both new legs printed and passed inside that run. `MATRIX_KNOWN_RED` untouched. Inventory
323 → 327 records; the three lines that appear to move are alphabetical re-sorting of
`--perf-budget-check`, `--perf-budget-zoom-check` and `--strict-agent-harness-check`,
proven by an empty old-minus-new set difference. `ComponentLab.swift` has **zero** lines
in `git diff d334f01..HEAD`, so the queue-94 corpus gate is intact.

### Additional declared fence deviation

`UIProbe.bitmap(of:id:scale:)` `private` → internal. The harness cannot use
`UIProbe.render`: it re-parents the view it is handed and places it centred at a fixed
frame, and its `make` closure runs before the view is in a window, so an offscreen
`NSTableView` would never materialize a cell. Reusing the bitmap step keeps the six
font-smoothing knobs and the declared 2.0 scale — the display-independence the
ENV-BLOCKER notes bought — in one place instead of a copy that drifts.

---

## Adversarial review (§7.4) — 2026-08-14

An independent reviewer was asked to falsify Phase 0's claims. It confirmed 18 findings.
The two it would have blocked Phase 1 on were both real, and both are fixed:

### Blocker 1 — the P0.1 witness had no teeth

The gate asserted only that 30 flows ran and that the inventory had 30 rows. **No
assertion touched a rendered value.** Every product fact this packet "establishes" — the
diamond, the missing Zone, three outcomes with no state word — was a `print`. A regression
that blanked every row would have stayed green, and the file's own claim to be "the
ratchet that proves those fixes landed" was false.

Fixed: `expectation(for:)` now pins today's rendered values per flow (state word, provider
mark, and whether each band is empty), plus two cross-flow assertions — that
`exactPlacement` and `ambiguousPlacement` are identical, and that success/interrupted/
cancelled are all blank. Each failure message names the design section a packet must come
back and flip. **Teeth-tested**: claiming `succeeded` shows `Done` produces
`FAIL: flow 'succeeded' state must be 'Done' today — got ''`, and restoring it is green.

### Blocker 2 — proposal A's nine-row claim did not survive the real sidebar

Both sides of "only A meets the nine-row floor" measured a bare `AgentInboxView` given
the whole 662 pt. The shipped `WorkspaceSidebarView` pins the inbox below its title and
management message. Now measured: **a 662 pt sidebar gives the inbox 610 pt** (52 pt of
chrome), at which A yields **8** rows, not 9 — so **no proposal meets §8.1's floor**, which
is a materially different question. Also found: `managementMessageLabel` is `isHidden` with
an empty string and **still reserves ~18 pt**, and reclaiming it would put A back at 9.

The S0 doc has been corrected, reports both columns, and offers the reclaim option.

### Other confirmed findings, all fixed

- **`settle` was being REFUSED on every run** (a send installs a runner; `canSettle`
  refuses while one exists) while the inventory claimed the row reached the Settled
  surface. It now settles without a send and **asserts the verb returned true** — which
  changed the observed row, because a settled row is SLIM and a slim cell draws no
  placement and no provider mark. The inventory row was wrong and is corrected.
- **The four accessibility images were byte-identical** to the baseline and to each other.
  Root cause was two-layered: interaction fills are layer background colours that
  `displayIgnoringOpacity` does not composite (so `cacheDisplay` is required for them),
  and Reduce Motion cannot appear in a still at all. The harness now ships ONE interaction
  reference and states plainly that both accessibility settings have better numeric
  witnesses in `--sidebar-ux-check`. A **duplicate-digest gate** now refuses any two
  byte-identical images outright.
- **The offscreen manifest hard-coded `verdict: "PASS"` and was written before the gate
  ran**, so a failing run left a manifest claiming success — which is the field
  `QARunManifestReader` reads. The manifest is now written after the gate, and a failing
  assertion writes `FAIL` before propagating.
- **The density fixture was seven rows of `Bulk agent` filler** (50 bulk agents sort
  newest-first and filled the viewport). It now uses the 29 product rows; the bulk agents
  remain in the taller corpus sweep, where scale is the point.
- **The live check had no state fence.** It mints five durable `AgentRecord`s and never
  deletes them, and only refused a `~/Documents/personal` root — so from the prod bundle
  against any other root it would have written junk agents into Dylan's real store. It now
  requires `CONTINUUM_APP_SUPPORT` and refuses the prod bundle identifier.
- **The live capture never checked its own PNG was non-blank**, and **never verified the
  requested width was applied** (`constrainedWidth` clamps against a 640 pt content
  floor). Both are now asserted, and the verdict depends on them.
- **Two of the three new flags were invisible** to the flag enumeration AGENTS.md
  prescribes for hazard 7, because they were referenced through constants. The `contains`
  calls now use the literal strings; all four sidebar flags appear in the documented grep.
- **Four QA accessors were dead code** in a production file. Removed
  (`fullReloadForQA`, `providerGlyphsForQA`, `projectLinesForQA`, `qaTableGeometryForQA`).
- `isInRowModel` read the DISPLAYED collection, not the row model; renamed
  `isInDisplayedList` so the name matches the source.

### Confirmed and NOT fixed, recorded instead

- **The S0 proposal mocks are richer than production can render** (they show Zone,
  completion times, model text, distinct outcome words — none of which the app paints
  today). This is §2.3's failure mode pointed at the decision artifact. It is *deliberate*
  — they are proposals about pitch — but it means an A-vs-baseline comparison differs in
  content and chrome as well as pitch. Mitigated by proposal C, which is today's pitch with
  the design's content, isolating the pitch variable; and the S0 doc now leads with the
  conclusion that content is the larger problem. Left as a stated limitation.
- **`bundleVersion` is `"n/a (cli binary)"`** in the offscreen manifest, which the
  no-empty-field gate accepts. The offscreen leg never runs from a bundle; the real bundle
  version comes from the live leg and the wrapper's merged manifest.
- **The probe never exercises cell reuse or the incremental push.** Every observation is a
  first-load render into a fresh view. The values are production's, but nothing here can
  see a staleness bug in the incremental `apply`/recycling path. Recorded as the honest
  boundary of this instrument.
- The reviewer noted the corpus calls `recordManagedActivity` **before** `qaDeliver` while
  production is the reverse. It could not show this changes any observed value (the push is
  synchronous and follows both), so the ordering is left alone and the docstring's "exactly
  as production does" is now the only overstatement remaining in that comment.

### What the reviewer tried to falsify and could not

Queue-94's gate weakened (`ComponentLab.swift` diff is empty; both program checks and the
inventory check pass); a capture mislabelled `live-window`; a second owner of
state/title/location in production; width not applied offscreen; un-gated UI at boot; any
tmux contact; any risk to Dylan's state; and the inventory's observed-row column, which it
verified verbatim against a fresh run.

---

## Feedback round 2 — anatomy, and the status experiments (2026-08-14)

Mock-only. **No production code touched**; the whole round lives in
`SidebarScreenshotChecks.swift`, whose `Checks.swift` suffix keeps it out of the
ui-probe census and the colour-hygiene scan. Artifact:
`qa-runs/2026-08-14T193650Z/sidebar-96/`, 42 images, gate PASS.

### Structural: pitch and anatomy are now separate types

`SidebarDensityProposal` is pitch. `SidebarRowAnatomy` is content and status emphasis.
One mock view is driven twice — across pitches at a fixed anatomy, across anatomies at a
fixed pitch. Before this, every proposal image varied both, which is why the first
round's feedback about *the provider text* arrived tangled with the ruling about *row
height*.

### What the images now show, and what each change was driven by

| change | driven by |
|---|---|
| model text dropped, provider mark alone | Dylan, after the T3 Code reference |
| marks drawn flat in the theme's colour | Dylan — **conflicts with §4.5, see below** |
| leading branch glyph on band 3 | T3's band 3; offered for veto |
| throbber at 18 pt | measured, see below |
| Working given its own (blue) accent | fell out of building the rail |
| unknown-provider row moved to position 5 | it was clipped by the caption at position 10 |

### Numbers, not impressions

- **The throbber was drawn below the size it exists at.**
  `DualPlaneGyroTiltedThinkingIndicatorView.Metrics.side` is **18**; guide rings are
  `side × 0.036` at 30% alpha; orbit radius is `side × 0.296`. At the first mock's 11 pt
  that is a 0.55 pt ring around a 3.3 pt orbit — Dylan's "couple of dots", explained.
  Production agrees on 18: `AgentTranscriptListView` installs it at its intrinsic size.
  It now renders at 18. **It still reads as dots in a still, and that is not a size
  problem** — it is a motion glyph and a fixed-phase snapshot has no motion. Two
  consequences recorded rather than guessed at: it can only be judged live, and a full
  sidebar would animate up to nine of them where the transcript tail animates one.
- **A translucent `sourceAtop` tint blends rather than replaces.** Anthropic's `#D97757`
  under a 72%-black fill rendered *maroon* in Aqua, not grey. Caught by looking at the
  Aqua image, not by the gate — no mechanical check can see it. Fixed by flattening with
  an opaque fill and applying opacity at draw time. The same bug was silently affecting
  every SF Symbol drawn with a translucent colour.
- **Tinted copies were being built at the source's size** — 1024×1024 for the xAI mark —
  and thrown into a 14 pt slot. Now built at 3× the destination.

### The one thing here that contradicts the design

**§4.5 forbids tinting vendor marks** without explicit per-vendor permission for template
treatment, and this round tints all of them. Done at Dylan's direction, for a local mock,
and recorded as an OPEN question in `brand-marks/PROVENANCE.md` rather than as a settled
one — it adds "is monochrome permitted, per vendor" to P3.1's trademark review, plus the
follow-on question of what a row looks like if some vendors permit it and others do not.
Nothing here ships.

### Why there is no fourth status image

`trailingText` at proposal A's pitch and 280 pt would be byte-identical to
`proposals/proposalA-280x662-*.png`. That control already exists; emitting it again under
a second name is precisely the relabelled-duplicate trap of round 1, so the sweep is three
images and the doc names the control.

The duplicate-digest gate also earns its keep here as **teeth**: `leadingRail` and `pill`
are conditional treatments, so if the attention predicate ever returned false for every
row, both would collapse onto that same control and the gate would fail rather than ship
two images of nothing.

### Verified

`--sidebar-screenshot-check` (42 images, PASS), `--sidebar-production-corpus-check`
(30/30), `--sidebar-ux-check`, `--agent-inbox-check`,
`swift run ContinuumRevivedAgentUIChecks` (incl. the queue-94 corpus gate),
`scripts/check-color-hygiene.sh` (27 allowlisted, 0 new). `ComponentLab.swift` still
shows 0 lines against `d334f01`. No matrix run this round — nothing outside the mock
changed, and the live app is in use.

---

## Feedback round 3 — borders, and an alignment defect measured (2026-08-14)

Mock-only again; nothing outside `SidebarScreenshotChecks.swift` and the ticket docs.
Artifact: `qa-runs/2026-08-14T195203Z/sidebar-96/`, **52 images**, gate PASS.

Dylan ruled the pitch proposals and the row anatomy green, **locked the flat
theme-coloured provider marks**, cut the pill, and asked for a thinner side border and
for other border kinds — naming the canvas's dashed focused-tile border.

### The witness caught me building a fix that fixed nothing

The leading-icon column looked misaligned. My first correction normalised each glyph's
**largest** dimension and re-centred it. The new alignment check refused it:

> the raw status glyphs differ by only 0.047 of their box — ink normalisation is
> correcting nothing

That is right, and it is the interesting finding. SF Symbols already agree on their
largest dimension to within 5%. What varies is **width** — 68% of the box for
`hand.raised.fill` against 86% for the circles — so what moves when you centre them is the
**left edge**: 1.44 pt of scatter in a 16 pt slot, which in a column reads as a ragged
margin. That is what Dylan was seeing.

The leading column now aligns ink **left edges**. Measured after the fix, through the real
draw path: every glyph starts at 0.00 pt, on one centre line, at one extent.

Two things about this witness are worth keeping:

1. **It re-measures pixels rather than re-running the arithmetic.** It paints each glyph
   through the same `alignedRect` the mock uses, into a bitmap, and finds the alpha extent.
   Re-deriving the placement formula would have passed no matter which formula was wrong.
2. **It has a floor that asserts the fix is doing work** — if centring would scatter the
   left edges by less than the tolerance, the check fails as theatre. That floor is what
   fired above, and the guess it killed was mine.

### What is in the sweep

Eight anatomies at proposal A's pitch: `rail` (3 pt), `railThin` (2 pt), `outline`,
`dashed`, `bracket`, `leadingIcon` (distinct shapes, ink-aligned), `leadingEnclosed` (one
common disc), `combo` (`railThin` + disc column). The pill is gone.

`dashed` quotes `FocusBorderOverlayView.lineWidth` (1.5) and `dashPattern` ([6,4]) from
`CanvasNSView.swift:5891-5892` rather than inventing a dash — and that is also the
argument against it, recorded in the review: on the canvas that dash **means focused
tile**, and the two surfaces are on screen together.

### Recorded, not fixed

- **The Working row breaks the disc column.** In `leadingEnclosed` and `combo` every
  status glyph is the same disc except the throbber, which is orbiting dots. Giving it a
  disc-sized track would be new art; out of scope for a mock round.
- **`leadingEnclosed` costs `Failed` its triangle.** An earlier round bought that
  silhouette specifically because three filled circles at 11 pt read as one shape. At 16 pt
  in a column the inner marks may carry it. That is the trade the two images exist to
  settle, and it is not settled here.

### Verified

`--sidebar-screenshot-check` (52 images, PASS, incl. the new alignment witness),
`--sidebar-production-corpus-check` (30/30), `--sidebar-ux-check`, `--agent-inbox-check`,
`swift run ContinuumRevivedAgentUIChecks`, `scripts/check-color-hygiene.sh` (27
allowlisted, 0 new). `ComponentLab.swift` still 0 lines against `d334f01`.

---

## Feedback round 4 — the icon set collapses to three (2026-08-14)

Mock-only. Artifact: `qa-runs/2026-08-14T203752Z/sidebar-96/`, 42 images, gate PASS.

Ruled: keep the left-aligned column; cut the glyph set to hand (approval AND input),
throbber (working), error mark (failed). Done, Stopped and Cancelled draw nothing.

**This overturned my round-three recommendation, and it was right to.** I argued against a
leading column because it was unconditional — a solid line of ticks weights finished rows
as heavily as broken ones. The fix is not to abandon the column but to make it
conditional: the glyph answers "does this concern me", not "what state is this", because
the word beside it already answers the second question. A hole in the column is
information.

Approval and input now share one glyph. Recorded explicitly because it *looks* like the
P0.1 defect and is not: that defect was the two sharing a **word**, so the row could not
tell you which. Icon = "you are needed", word = which kind. Two layers, each carrying
something.

### The witness now reads the glyph set off the product

`statusSymbolsInUse` is derived from the mock's own rows, so the alignment check can never
measure a glyph that was cut or skip one that was added — the set went six → two in this
round and the check followed it without being edited. It also refuses to run on fewer than
two symbols, because with one there is no column to align and the assertions would pass
vacuously.

Measured after the cut: centring the two remaining glyphs would scatter their left edges
by 1.19 pt of a 16 pt slot; ink-left alignment puts both at 0.00.

### The reserved icon lane came out too

Dylan: *"we have an indent we dont need"*, pointing at band 1 on a row with no glyph. He
was right and the reasoning behind the lane was wrong. A reserved lane was supposed to keep
the column straight; the column is made of the ICONS, which are pinned to one x and
ink-aligned to each other, so it is straight either way. All the lane did was indent band 1
away from the title and branch beneath it on seven rows out of ten.

### The fallback badge failed its first reader, who was its author

The mock carried a `Gemini 3 Pro` row specifically to expose what "mark only" costs a
provider with no bundled asset. It rendered §4.5's two-character badge, `GE`, and Dylan
asked what it was supposed to be — which is the finding, arrived at the only way this kind
of thing can be: by someone looking at it cold.

The badge is not a degraded identity on that row, it is the ONLY identity, because the
model name has already been removed. The mock now falls back to the model's name instead.
Mark or name, never a cipher. **Needs a §4.5 amendment** — recorded in
`brand-marks/PROVENANCE.md` and in the review, not changed quietly.

`providerInitials` and `drawProviderChip` deleted with it — code added earlier the same day
and now unreachable.

Noted, not acted on: **the xAI mark does not survive at 14 pt**; Grok's logo reduces to
roughly a slashed circle. Needs a bigger slot or a vendor small-size variant. P3.1.

### Removed

`GlyphStyle` / `enclosedStateSymbol` and the five-way border sweep, all added earlier the
same day and superseded by this ruling. `outline` and `dashed` were dropped rather than
re-rendered, with the reason recorded in the review and the old images still on disk.

### Verified

`--sidebar-screenshot-check` (42 images, PASS), `--sidebar-production-corpus-check`
(30/30), `--sidebar-ux-check`, `--agent-inbox-check`,
`swift run ContinuumRevivedAgentUIChecks`, `scripts/check-color-hygiene.sh`.
`ComponentLab.swift` still 0 lines against `d334f01`.

---

## Round 5 — the row becomes a real cell (2026-08-14)

Dylan: *"we need to replace the sidebar we have now… the Row Playground (96) option
has a non interactable sidebar."* Correct — everything before this was a painting.
`SidebarDensityProposalView` draws chosen strings into a bitmap; you cannot click it.

**`AgentInbox96CellView` is a real `AgentInboxRowCell`, rendered by the shipped
`AgentInboxView`.** Scroll, hover, multi-select, right-click, disclosure, jump pills,
rename and accessibility are queue 94's and are not reimplemented — the list's
*behaviour* was never program 96's complaint. What is swapped is the card.

### The seam, and why it is this small

`AgentInboxView.cardStyleOverride` — nil by default and nil everywhere except the Lab
section that sets it. Two things are handed in: how a card row is built, and how tall it
is (a 96 card's height is fixed by its pitch, because every band always has content,
where queue-94's is derived from which bands are populated).

Three lines of production behaviour change, all guarded by that nil. Rebuilding the list
instead would have meant a second sidebar with its own bugs; making 96 the DEFAULT is
Phase 1–3 and needs the S0 ruling, because the pitch is still a proposal.

`inboxLabelGeometryForQA` went `private` → internal so both cells describe themselves to
a gate through one helper.

### No second owner

`InkAlignedSymbol` and `BrandMark96` moved into the cell's file and
`SidebarScreenshotChecks` now calls them. The review images, the live cell and the
alignment witness are one implementation — a witness measuring a copy of the alignment
would have proved nothing about the thing you click on.

### Rendering it found three bugs the mock could not

The live render went into the artifact (`live96-A-280x662-*.png`) precisely so this
would be caught by looking:

1. **The bands came out upside down.** `AgentInboxCardView` is not flipped; the anatomy
   is specified top-down. The model name drew above the title and the placement below it.
2. **`Done` rendered as `Do…`.** `NSAttributedString.size()` is not a label's width — an
   `NSTextField` spends part of its frame on its own inset. Measured at 30.0 pt for a
   word needing 32. This codebase already knew: `minimumTextWidth` adds
   `Metrics.cellTextInset` and says why. Fixed by reusing that constant, not a new fudge.
3. **No production row ever matched a brand mark.** The mock used display names
   (`GPT-5.6 Sol`), so `hasPrefix("GPT")` worked. Real ids are fully qualified
   `provider/model` — `openai-codex/gpt-5.6-sol` — exactly as non-negotiable #5 requires.
   Every production row fell through to printing its whole model id across band 3.
   Marks are now keyed off the PROVIDER segment, and the name fallback prints the model's
   trailing segment with the exact id kept in tooltip and AX (§4.3).

All three were invisible in every mock image and obvious in the first live one. That is
the argument for the live fixture existing.

### What the live image shows, which is the point

Production rows in the new anatomy: **band 3 is empty but for the provider mark** on
almost every row, one row carries a state word, none carries a time. The redesign does
not fix that by itself — Phases 1–3 do. The mock's good data is not evidence that they
have.

### Verified

`--sidebar-ux-check`, `--agent-inbox-check`, `--sidebar-production-corpus-check`,
`--ui-probe-check`, `--ui-contrast-check`, `ContinuumRevivedAgentUIChecks` (incl. the
queue-94 corpus gate), `scripts/check-color-hygiene.sh` — all PASS, with the override nil.
`--sidebar-screenshot-check` 44 images. `--component-lab-check` and `--ui-baseline-check`
remain red and remain in `MATRIX_KNOWN_RED`: the first fails on the composer provider
footer, the second on a provider-controls pixel diff plus 12 `chrome.agentInbox`
baselines orphaned by a size change. Neither mentions anything added here.

### ComponentLab.swift is no longer at zero diff, deliberately

It could not be: a Lab entry lives in that file. The gate's actual contract was checked
first — `runSidebarDefectCorpusChecks` scans only between the two
`P0.3 SIDEBAR DEFECT CORPUS` markers (lines 415–607), and every added line is past 1165.
Both new entries are `.reviewSurface`, not `.staticCard`, so the baseline, contrast and
probe sweeps skip them — verified: `--ui-baseline-check` mentions the new ids zero times.

---

## Round 6 — three UX rules, and why the live row was worse than the mock (2026-08-14)

Dylan: *"im kinda disappointed… our static one looks so much better."* He was right, and
the cause was not the cell. Rendering the SAME live cell over two row sets separated it:

- `live96-production-*` — what the app makes. Sparse because production is sparse.
- `live96-capability-*` — queue-94's fixtures, which is what the Lab shows and therefore
  what he was comparing. **This is where the problem was.**

The capability render showed the actual defect: `Needs attention` in amber directly above
`Needs attention` in violet — same words, same glyph, different colour, no difference in
meaning — plus blue Working, red Failed, grey Done, and a right-hand column where some
rows carried a mark and others carried text. Five hues and two right-hand treatments for
one question. The mock looked better because it had one consistent trailing element and a
tighter colour story, not because the mock's geometry was better.

### Rule 1 — one colour, one meaning

Approval, input, failed and finished-but-unseen all take `accentApproval` (`#FFB347`
dark / `#845000` light), which is already token-legal at 4.5:1 on every surface in both
themes — no new token. WHICH kind of attention is carried by the glyph and the word,
which is where §8.2 wants it anyway.

**Working is deliberately uncoloured.** A running agent is not asking for anything, and
it already owns the loudest thing on the row: a moving glyph.

This diverges from `InboxState.accent`, queue-94's four-accent mapping. Recorded as a
deliberate program-96 divergence, not a drift.

### Rule 2 — finished, and nobody looked

Both halves come off the existing model; nothing is invented or stored.
`InboxState.ready` + `InboxAttention.unread`, whose own doc comment already says the
thing this design needed: *"Unread is a MARK, not a word."*

Two rungs, separated only by AGE:

| | when | shows |
|---|---|---|
| `landed` | finished, unseen | orange dot, word `Landed` |
| `waiting` | unseen past 10 min | the same dot, **pulsing**, word `Waiting` |

Dylan's reasoning, and it is the right one: the failure this prevents has not happened
yet. With enough tiles you forget an agent finished, and a grey `Done` is
indistinguishable from the forty other grey `Done`s.

**The pulse is 0.5 Hz and bottoms out at 0.4 opacity** — far below the 3 Hz seizure
threshold, and never to zero, because a glyph that vanishes reads as a rendering fault
rather than as insistence. Under Reduce Motion it does not run, and **nothing is lost**:
the word changes `Landed` → `Waiting` either way, so the escalation is legible without a
frame of animation. A cue that exists only as movement is a cue some people never get.

The names are provisional and Dylan said he does not have one yet — `ReviewState` is one
enum, so renaming is one line.

### Rule 3 — glanceable

Confirmed: the leading column stays, conditional, ink-left-aligned. The unread dot draws
at ink fraction 0.42 rather than the shared 0.82, or a filled circle is a blob the size
of the error triangle — "finished" would shout louder than "broken".

### The throbber was never started

`DualPlaneGyroTiltedThinkingIndicatorView.startAnimating()` exists and the first version
of this cell never called it, so the sidebar showed a frozen gyro — three dots that read
as a rendering bug rather than a running agent. Now started, and posed at a fixed phase
under Reduce Motion instead.

### Two more bugs the new fixture caught

- **Marks matched no lab row.** The provider lookup keyed off the `provider/` segment
  after the last round, but fixtures carry bare model names (`gpt-5.6-sol`). Both forms
  match now — a right-hand column where some rows show a logo and others show text has no
  rhythm at all.
- **Both escalation rungs rendered `Landed`.** `AgentInboxView` hands every cell `now`
  from its OWN `clock`, which defaults to the wall clock, while the fixture dated its
  rows against a pinned instant in 2030 — so every age came out negative. Rule 2 is an
  age comparison and cannot be witnessed without pinning the list's clock too.

### New fixture, named as one

`AgentInbox96Fixtures` — the rows this program ADDS answers for. Neither existing corpus
has a finished-and-unlooked-at row, because until rule 2 there was no such thing: a
completed turn and a completed turn you walked away from rendered identically. That is
the problem, stated as a fixture.

### Verified

All seven gates green (`--sidebar-ux-check`, `--agent-inbox-check`,
`--sidebar-production-corpus-check`, `--ui-probe-check`, `--ui-contrast-check`,
`ContinuumRevivedAgentUIChecks`, colour hygiene). `--sidebar-screenshot-check` 48 images,
and it now prints the escalation per row including whether the mark is actually
animating — `Landed … pulsing no` / `Waiting … pulsing YES`, which is the one fact about
rule 2 no still image can carry.

### Still open

The right-click menu. Array's row menu today is Open / Rename / Settle / Snooze › /
Mark Unread / Archive / Delete, with unavailable actions hidden rather than greyed
(P3.14's rule). Dylan asked how T3 Code's looks — **I cannot see T3's app and did not
guess**; waiting on a screenshot.

---

## Round 7 — the palette, corrected (2026-08-14)

Round 6 read "one colour for important things" as "one colour, full stop" and painted
working, done, stopped and cancelled all grey. Wrong. The rule is **one colour per
MEANING, with the two kinds of asking sharing one** — the original defect was never
"too many colours", it was `Needs attention` in amber directly above `Needs attention`
in violet.

| state | colour | token |
|---|---|---|
| working | blue, plus the moving glyph | `accentWorking` |
| approval **and** input | amber — one colour for both | `accentApproval` |
| failed | red | `accentFailed` |
| done, and you saw it | green | `accentDone` |
| landed / waiting | rose | **`accentReview`, new** |

### A sixth accent, and the gates made us earn it

`accentReview` — light `#A83259`, dark `#E5799B` (Dylan's pick). Neither neighbour can
carry this state: green loses it among the rows you already read, amber makes it look
like something is blocking when nothing is.

Adding it went red **five times in a row**, and every one of those was a pin doing its
job rather than an obstacle:

1. `expected 5 accents, got 6` — the count is pinned so an accent cannot arrive by drift.
2. `expected 22 tokens in total, got 23`.
3. `expected 104 documented pairs, got 116` — one accent costs twelve pairs.
4. `the pinned-margin table must cover exactly the gated foregrounds` — a new token
   cannot skip the provenance table.
5. `expected 27 documented sidebar pairs, got 30` — plus its own margin table.

**Nothing was guessed.** Every number written into those tables was read out of the
check's own measurement, including one where a placeholder of `0.00` was committed
specifically so the harness would report the real figure (`4.75:1`) rather than have it
estimated.

Measured, and recorded because the margins are thin:

- Tightest across all 11 surfaces: **4.78:1** on `cardUserMessage` dark, floor 4.50.
- Tightest against an interaction fill: **4.75:1** on `sidebarActive` light — a quarter
  of a point of headroom, and now the tightest entry in that whole table.
- `textOnAccent` on `accentReview` dark is 6.99:1, which **displaces `accentInput` as the
  worst case** for that foreground; the pin moved with it.

So `#E5799B` ships as chosen. It clears every floor, but it is the least forgiving colour
in the palette, and a future nudge to it will go red before it goes out.

### Still open

The right-click menu. Dylan's latest T3 screenshot is of the LIST, not a menu, so the
question is still unanswered — **and it was not guessed at.** What the list shot does
show, and is worth taking:

- **Quiet rows carry only a relative time**, no state word. Exactly one row in the shot
  says anything (`Working`). Array now says `Done` in green on a finished row, which is
  the opposite choice; it is survivable because a settled row collapses to a slim variant
  quickly, so green never accumulates — but it is a choice, not an accident.
- The settled section is visually demoted rather than hidden.
- Scope is filter CHIPS across the top, where Array uses a popup.

Array's row menu today, for the comparison when the screenshot arrives: Open / Rename /
Settle / Snooze › / Mark Unread / Archive / Delete, unavailable actions hidden rather
than greyed, and a multi-selection offering only what every member can take.

---

## Round 8 — the rose dies, and the gate learns why

Dylan, on sight: *"i dont love the colour we chose... it's too similar to error."*

He was right and it was measurable. Dark `accentFailed` is hue **3°**; the rose
`#E5799B` was **342°**. Twenty-one degrees apart, stacked four rows apart in the same
list, and **every gate in the file was green**.

### What the suite could not see

`runDesignTokenChecks` asked two questions about accents and neither was this one:
whether a single accent holds its hue *across themes* (≤10° drift), and whether two
accents are *exactly equal* values. Nothing compared two DIFFERENT accents to each other.
A palette can converge to indistinguishability one token at a time and stay green
throughout.

So the complaint became a check. Accents that can share a list now need **30°** between
them. Calibration was read off the live palette rather than chosen: the tightest real
pair is red↔amber at **32°**, and the rose measures **21.40°**. Proven in both
directions — palette green, rose red — before it was believed.

`accentDone`/`accentReview` sit at 25° and are exempted **by name**, with the reason
written at the exemption: they are the same family, and the row paints exactly one of
them. An exception that stays visible beats a floor quietly lowered for everybody.

### The colour, and why the first candidate failed on paper

Dylan proposed `#79E5CA`. Before touching it, the accent band ceiling
(`4.50…8.00`) was checked by back-solving the dark surface luminance from two pinned
accents — amber 7.48 and green 6.74, both of which reproduced to two decimals. `#79E5CA`
computes to **≈8.8:1 at worst**: right hue, one stop too pale, over the ceiling.

Shipped instead at the same hue and a legal value: **light `#096B57`, dark `#4CD6B4`**.
Predicted 5.41 / 7.34; the harness measured **5.41 / 7.35**, and handed `textOnAccent`'s
worst dark case back to `accentInput` at 7.82 exactly as expected. Sidebar pairs 4.77 /
7.75. Every figure written into the five pinned tables was read out of the check's own
output.

### Retiring green was not cosmetic

Mint is 25° from `accentDone`. Keeping green on the row would have repeated the rose's
failure one hue over. So `.ready` returns **no accent at all** — which costs nothing (a
settled row is the one row asking for nothing) and buys mint a **48°** gap, the widest in
the palette. Colour on a row now means exactly one thing: this wants you.

### One word, then none

`Landed` / `Waiting` collapsed to `Unseen`, then — after Dylan's *"we are
overcomplicating it"* — to this:

> done means agent is done, we remove status when we looked at it... we then have the
> pill nudge when it has been seen for long enough

Which is better, and it exposed why the pulse was wrong. The pulse was arming on the
UNREAD row: the row that is already coloured, already marked, already sorted where you
will see it. The row that actually gets lost is the one you read two hours ago and never
closed — and blinking at a different row was never going to help with that. The pulse is
gone; `escalationDelay` became `settleNudgeDelay` and now measures how long a row you
have READ sits before it asks to be put away.

Every finished row also got its age back. `row.elapsed` is a live turn's duration, so
every terminal row rendered its state with no time at all — including, absurdly, the one
state whose entire meaning is how long it has been sitting there.

Glyph: `eye.circle.fill` for one round, then `checkmark.circle.fill` — it states the
outcome rather than issuing an instruction. Both circular, because the column scales each
symbol by its LARGEST dimension and a bare eye is 2:1, which would land it at half the
height of the triangle beside it.

---

## Round 9 — the header, the hover card, and two bugs that were not taste

### The header preview had three defects and only one was a design opinion

**`Field`.** The search box contained that literal string. A programmatically created
`NSTextFieldCell` arrives carrying AppKit's default title, and swapping the cell in handed
it to the field. It looked exactly like a placeholder — because the real placeholder is
hidden whenever `stringValue` is non-empty — and it never filtered anything, because
`controlTextDidChange` fires on edits and not on a value the field was born with. It could
have sat there indefinitely looking like a design choice.

**The outline.** Not a focus ring:

```swift
window?.firstResponder === searchField.currentEditor()
```

An unfocused field has no field editor, so that is `nil === nil`, which is `true` — and
during `init` there is no window either. The border was painted at construction and
nothing ever cleared it. Dylan reported it as a styling complaint; it was a comparison bug.

**The box itself**, which was the actual opinion — and the reference settled it. T3's
input is `unstyled` inside a row that draws no border and no resting fill, only
`hover:bg-sidebar-row-hover`. Ours is now a magnifier plus text at rest, a hover fill, and
the focus hairline only while a caret is genuinely in it, with the clear button's space
reserved permanently so typing does not shove the text sideways.

### The clipping was older than the header, and I said otherwise first

Reported as *"it is clipping"* alongside the header change, and the first diagnosis —
that the taller header overflowed a stack — was **wrong**. `place()` centred a fixed frame
in the Lab host without clamping, so any surface larger than the host got a **negative
origin** and lost equal slices off both ends. The sidebar playground asked for 860pt in a
640pt host and had been losing 110pt off each end since it was written; the tilted gallery
asks for 960pt in a 720pt host and had been losing 120pt off each side.

Nobody could see it because **every sweep guards on `.staticCard` and skips review
surfaces** — correct, since a review surface owes no baseline, and also precisely how a
surface came to be declared larger than the panel that shows it.

The check that now asks that question had to be **hoisted to run first**, and the reason
is the more useful finding: placed where it naturally belonged, it sat after
`--component-lab-check`'s known-red composer leg and **stayed completely silent with a
surface declared at 1600pt**. This is the matrix-halt lesson at method scale — a gate
after a red leg does not run at all. Verified by oversizing a surface both before and
after the hoist.

### The hover card is not a feature, it is the missing half of §4.3

The measured-fit sacrifice order lets a narrowing row drop placement, model text and
branch detail **on the stated condition** that they "remain in tooltip and accessibility
detail". No tooltip has ever existed, so every one of those drops has been a plain loss —
P0.1 measured three long-title flows rendering no project at all at 280pt.

Three of its nine lines are facts the sidebar has never rendered anywhere: **zone**,
**harness**, and a **branch mismatch**. All three already existed in `AgentRowContext`
and were being discarded by `AgentInboxRowBuilder`. `zoneName` had **zero consumers in the
entire application**.

**Harness does not come from `agentKind`, and never could.** `AgentContextIndex` folds
every `AgentRecord`-backed agent in as `.managed`, and the inbox filters to managed
agents — so `agentKind` is the same value for every row the sidebar draws. It comes from
`AgentRecord.harness`, whose rawValues are already display text. That is what makes a Pi
agent distinguishable from a Codex one for the first time.

Placement was decided by two hazards the app had already recorded: a subview overhanging
the sidebar's trailing edge is **occluded** by the canvas pane (added to the split after
the sidebar) rather than clipped — invisible, not cut — and the `NSSplitView` **adopts**
an added subview as a pane and overwrites its frame, which is how ⌘K once rendered as a
full-height sidebar. So the card lives in the window's content view, which is a plain
container for exactly that reason.

It hangs off `setHovered`, the single hover choke point, so every existing dismissal —
scroll under a still pointer, window resigning key, any full re-render — applies to it
without knowing it exists.

### Two gates, satisfied rather than worked around

The token census hunted the new `TokenThemed` view and wanted it in **both** sweeps: the
appearance surfaces and `adoptedSurfaces()`. Registering the name alone produced *"adopted
owners that painted nothing in the probed surfaces"*. It is now rendered standalone in
each, with the mismatch line included so the warning accent is painted rather than merely
declared.

The timestamp is POSIX with an explicit `dateFormat`, never `dateStyle`/`timeStyle` — the
rule written on `InboxUndoToast.wakeTimeFormatter`: a locale-dependent rendering makes an
assertion depend on whose machine ran it.

### The witness asserts the claim, not the pixels

Not "a card appeared". It hovers the mismatch row, reads the card's lines, requires zone,
harness and the mismatch to be present, **and requires the row beside it to still not
print them** — so if a future row starts saying them, the duplication gets decided rather
than drifting into both places.

It also witnesses `withUnconfirmed`, which rebuilds a row by hand, runs on the live path
against the rows whose state is least certain, and silently drops any field it does not
name. Removing one field reports `zone nil, harness Codex, checkout main`. Verified.

### Still open

The settle nudge pill — designed by Dylan, not built — plus the pointing-hand cursor, the
bounded local project-favicon ladder, and the ink-alignment witness, which measures the
mock's symbol set (hand + triangle) while the live cell now draws a checkmark. That last
one is non-negotiable #2 and has been true since the file's header claimed otherwise.

## 2026-08-17 — command menus adopt their own anatomy

The final polish tail is now part of the program record. Value pickers keep their
selected-value checkmark rows and 36 pt pitch. Sidebar row and bulk actions opt into a
distinct `commands` presentation: 30 pt rows, caller-owned leading symbols, no selection
checkmarks, and one quiet separator before the first destructive action. Snooze presets
use clock symbols; row and bulk verbs use stable semantic symbols. The shared popover
still owns keyboard navigation, typeahead, accessibility, focus return, placement, and
token painting—this is a presentation mode, not a second menu implementation.

The Lab sidebar now wires inert host callbacks so its right-click review surface exposes
the same capability-driven production menu instead of honestly hiding commands its fake
host did not support.

Verification before commit:

- `swift build --product Array` — green;
- `--ui-geometry-check` — green, including compact command density, dynamic icons,
  checkmark suppression, and destructive grouping;
- `--agent-inbox-check`, `--sidebar-ux-check`, and
  `--sidebar-production-corpus-check` — green;
- `--sidebar-screenshot-check` — green, 48 images;
- `--ui-probe-check`, `--ui-contrast-check`,
  `ContinuumRevivedAgentUIChecks`, and colour hygiene — green;
- `--component-lab-check` — the same documented pre-existing known-red composer-provider
  footer leg; no new failure was observed before it halted that process.
