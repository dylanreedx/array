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

Mock-only. Artifact: `qa-runs/2026-08-14T201842Z/sidebar-96/`, 42 images, gate PASS.

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
