# Supervised gate S0 — row density

Status: **AWAITING DYLAN'S RULING.** Nothing in the program locks 66/68 until the
ruling below is filled in. Silence is not approval (§3.2).

§6/P0.2 asks for exactly this: *"Dylan reviews the current red baseline and three
proposed static row-density variants before implementation locks 66/68 geometry. The
documented target is the default proposal, not approval inferred in advance."*

---

## The question, in one number

How many complete agent rows fit in a 662 pt sidebar?

| | card | pitch | rows in a **bare inbox** | rows inside a **real sidebar** |
|---|---:|---:|---:|---:|
| **Today (shipping)** | **79.0** | **83.0** | 7 | **7** |
| **A — documented target** | 66 | 68 | 9 | **8** |
| B — comfort midpoint | 72 | 75 | 8 | **8** |
| C — today, redrawn | 79 | 83 | 7 | **7** |

**Read the right-hand column.** §8.1 asks for *"at least nine complete active rows in
662 pt"*, and **no proposal reaches it** — including the documented 66/68 target.

An earlier draft of this document said "only proposal A meets that floor". That was
wrong, and an adversarial review caught it. Both sides of that comparison measured a bare
`AgentInboxView` handed the whole 662 pt. The shipped `WorkspaceSidebarView` never does
that: it pins the inbox below an "Agents" title and a management message, and the harness
now measures the result — **a 662 pt sidebar gives its inbox 610 pt**, 52 pt of chrome. At
610 pt, A's 68 pt pitch yields 8 rows, not 9. It misses its own floor by 0.2 pt of pitch.

Today's 7 is robust either way; A's 9 was the one number that moved, and it moved in the
direction that flattered the densest proposal.

### There is 18 pt of reclaimable chrome, and it decides whether A works

The 52 pt is `10 + titleH + 4 + msgH + 8` from the sidebar's own constraints
(`WorkspaceSidebarView.swift:346-365`). `managementMessageLabel` is `isHidden = true` with
an empty string — **and still reserves its height**, because a hidden view with active
constraints keeps its intrinsic size. Collapsing it reclaims that label plus its 4 pt gap:
roughly 18 pt, giving the inbox ~628 pt, at which A's 68 pt pitch yields **9** rows.

So the real options are:

1. **A (66/68) plus collapsing the hidden label** → 9 rows, meets §8.1.
2. **A alone** → 8 rows, misses the floor by a hair.
3. **B or C** → 8 or 7 rows; the floor is not met and is not pretended to be.
4. **Change the floor** — nine rows in 662 pt may simply be the wrong requirement now
   that the chrome is measured rather than assumed.

Every number above is measured off painted cells, not divided out of a constant. Proposal
C exists to keep that honest: C *is* today's geometry, so a teeth check requires C's
computed card, pitch and row count to equal what the shipped sidebar paints. That check
has now caught two wrong formulas — an early `(viewport + gap)/pitch` that claimed 8 rows
for today's 7, and a card measurement that sampled a slim settled row and reported a 35 pt
card on a 78 pt pitch.

---

## The red baseline — the shipped app, live window

`live-w280/live-window-280pt.png` (also captured at 220 and 360 pt, plus a
`live-view-cache` render of the same instant for comparison).

Five rows, driven through the real writers on the live app's own supervisor. What the
row actually carries:

- **Three of the five rows are titled `New agent`.** Untouched ⌘K drafts are durable
  work today (§4.1/§2.4).
- Every row's placement band holds a **project name only** — `array-scratch-96`. Never
  `Project › Zone`.
- The third band contains **nothing but a diamond**. §2.2 named this exactly: a band can
  exist "only because the provider diamond counts as detail".
- The row that **completed a turn** reads `Unconfirmed`, not `Done`, and carries **no
  completion time**.
- One row (`Replace sidebar identity and co…`) renders **no placement at all** — its long
  title displaced the band, at the default width.

## The same rows, offscreen, at every width and appearance

`dense662-{220,280,320,360}x662-{aqua,darkAqua}.png` and the taller
`corpus-*` sweeps. These are the P0.1 production corpus — 30 flows driven through the
real writers — so the images show what the app produces, not a fixture. The offscreen
set matches the live window, which is what makes it usable as a geometry gate.

One interaction reference at 280 pt: `interaction-280x662-{aqua,darkAqua}-selected.png`,
a selected row so the fill and the 4 pt gutter §4.4 describes are visible.

**Neither accessibility setting ships as a still image, deliberately.** Reduce Motion
gates the crossfade, so two stills of a settled list are the same picture; Increase
Contrast is a ≤1.5% alpha step on an interaction fill. Both already have better, numeric
witnesses in `--sidebar-ux-check` (crossfade count 0 vs 1; resolved fill and measured
contrast ratio per interaction role). An earlier version of this harness shipped four
images for them that were **byte-identical** to the baseline and to each other; the gate
now refuses duplicate images outright.

**Aqua is offscreen-only, by your earlier ruling.** The app hard-pins `.darkAqua` at
boot (`ContinuumApp.swift:3479`), so a live Aqua window is not reachable without a
product change; every capture records its appearance and `captureType` so the
distinction is never inferred.

## The three proposals

`proposals/proposal{A,B,C}-{220,280,360}x662-{aqua,darkAqua}.png`. Each is a static mock
of §1's intended three-band anatomy — placement + outcome/time, subject, branch + model
— drawn with realistic content including a long RTL title, a middle-truncating branch,
and the terminal outcomes §4.6 wants distinguished (`✓ Done · 4m`, `Working · 1m 24s`,
`Approval`, `Failed · 12m`, `Stopped · 30m`, `Cancelled · 1h`, `Input`).

They are proposals about **pitch**, not about content. The content is there so the
density judgement is made against real information rather than grey boxes.

- **A — 66 pt card / 68 pt pitch.** `8 + 14 + 3 + 17 + 2 + 14 + 8 = 66`, §4.3 as
  written. 8 rows in a real sidebar (9 if the hidden label is collapsed).
- **B — 72 pt / 75 pt.** The same anatomy with 10 pt insets and 3 pt band gaps, if A
  reads cramped at 220 pt. 8 rows.
- **C — 79 pt / 83 pt.** Today's pitch with the intended bands filled in — the control
  that separates "the rows are too tall" from "the rows are empty". 7 rows.

**C is the one worth looking at hardest, and it changes the framing.** Having rendered
it: at today's 79/83 pitch, with the bands carrying real information, the row reads
*fine*. Airier than A, but legible and scannable — nothing like the baseline.

So the honest reading of this evidence is that **the sparseness is mostly a content
problem, not a height problem.** The baseline looks bad because two of three bands are
empty and the third holds a diamond, not because 83 pt is too tall. Proposal A buys one
extra row in a real sidebar (7 → 8) on top of that. That is a real gain, but it is one
row — and combined with the corrected floor arithmetic above, it means **density is the
smaller half of this problem.**

That distinction matters for what you approve: picking A commits the program to a
sidebar-specific geometry change (§4.3 is explicit that global `Inset.card` and title
typography must not move to achieve it), whereas picking C commits only to filling the
bands, which Phases 1–3 do anyway.

---

## The artifact

`~/array-worktrees/sidebar-96/qa-runs/2026-08-14T171935Z/sidebar-96/`

Captured from a **clean tree** at commit `b9d3768`, bundle `~/Desktop/Array Dev 96.app`
(binary SHA-256 `69a7fc9b…e00b9097`, build 1) over `~/array-scratch-96`. Four legs, all
PASS, 42 images:

| leg | what |
|---|---|
| `live-w220/`, `live-w280/`, `live-w360/` | the shipped app, real window, 2 captures each |
| `offscreen/` | 36 images — corpus sweeps, the 662 pt density fixtures, one interaction reference, and `proposals/` |

**The offscreen half has since been re-rendered** with the new row anatomy and the status
sweep: `qa-runs/2026-08-14T200632Z/sidebar-96/`, 42 images, gate PASS. The live half is
unchanged and does not need re-capturing — those images are the *shipped* sidebar, and no
product behaviour has changed. Regenerate the offscreen set alone with
`.build/debug/Array --sidebar-screenshot-check`.

The two worth opening first: `live-w280/live-window-280pt.png` (the baseline) and
`offscreen/proposals/proposalC-280x662-darkAqua.png` (today's pitch with the design's
content — the image that reframes the question).

`qa-runs/` is gitignored, so the images live outside the repo; the manifest records
everything needed to regenerate them.

## Traceability (§3.3)

Recorded in `manifest.json` per run and merged by `scripts/capture-sidebar-96.sh`:
commit, dirty tracked/untracked paths, bundle path, binary SHA-256, bundle version,
build channel, scratch project root, app-support root, and per image the fixture,
requested **and measured** width, appearance, Reduce Motion / Increase Contrast state,
scale, and `captureType` (`live-window` / `live-view-cache` / `offscreen-probe`).

Reproduce with:

```sh
scripts/capture-sidebar-96.sh                 # live + offscreen + merged manifest
.build/debug/Array --sidebar-screenshot-check  # offscreen only
```

The scratch bundle is `~/Desktop/Array Dev 96.app` on `~/array-scratch-96`, deliberately
its own bundle and root so this program never disturbs the shared preview app or your
workspace.

---

## An open question this evidence raised early

Not part of the density ruling, but it surfaced while gathering it and it changes how
much the row must carry:

**`Project › Zone` does not exist today, and placement is the first thing width
sacrifices.** The corpus includes an agent whose tile really is on the canvas,
geometrically inside a zone — it still renders the project name alone. A second agent in
a *different zone of the same project* renders byte-identically, which §8.1 requires to
"remain distinct". And three flows render no placement at all because a long title
displaces the band at 280 pt, where §4.3 puts placement fourth in the sacrifice order
and requires it to survive in tooltip/AX.

That is Phase 2 (stable placement identity) and Phase 4 (measured-fit) work. It is
flagged here because a decision to keep Zone display costs row width, which interacts
with the density you pick.

---

## Feedback taken on the mock (2026-08-14)

Applied and visible in the current images: icons were upside down (a double flip);
`Done` was showing an icon *and* a `✓` *and* a colour; Working now poses Array's own
`DualPlaneGyroTiltedThinkingIndicatorView` instead of a generic refresh symbol; Stopped
and Failed were confusable and now differ by silhouette (triangle / square / slash); and
the provider slot draws the real vendor marks.

Still open, and they change the row anatomy rather than its pitch:

- **Drop the model text, keep the mark alone** (T3 does this: repo + time, title, branch +
  small trailing icons, no model name). §4.3's sacrifice order currently *ends* by removing
  model text while keeping the mark — this asks to start there. The exact model ID must
  still be reachable in tooltip and accessibility detail either way.
- **More visual aid for status.** Untried options: a leading status rail on the card, a
  larger status icon, a coloured left edge, or a small static attention mark distinct from
  the outcome glyph (§4.7 allows exactly that).
- **The Working throbber is too small at 11 pt** — it reduces to a couple of dots. It
  likely needs a ~14 pt slot to read as the gyro it is.

These are cheap to try in the mock and do not block the pitch ruling below.

### Both are now built — `status/`, and a second ruling below

`status/status-{rail,leadingIcon,pill}-280x662-{aqua,darkAqua}.png`, plus the control,
which is `proposals/proposalA-280x662-darkAqua.png` — same pitch, same width, same
content, so the only thing that differs is the treatment. There is deliberately no
fourth "trailing text" image: it would have been byte-identical to that control, which
is exactly the relabelled-duplicate trap the gate catches.

**Anatomy and pitch are now separate variables in the code.** `SidebarDensityProposal`
is pitch only; `SidebarRowAnatomy` is content and emphasis. Every proposal image uses
one anatomy and every status image uses one pitch, so no image changes two things at
once. The first mock did, and that is why "the provider text" and "the row height" got
argued about together.

#### What changed in every image, including the pitch proposals

- **The model name is gone.** The provider mark now sits alone at the right of the branch
  line. §4.3's ladder *ends* here; this starts here.
- **The marks are flat, in the theme's colour**, at your direction — one muted monochrome
  trailing column, as T3 has. This is the one change in this round that §4.5 currently
  forbids (*"do not tint vendor marks unless the brand rules explicitly permit template
  treatment"*), so it is fine in a local mock and **not yet established for shipping**.
  It adds a question to P3.1's per-vendor trademark review: is a one-colour treatment
  permitted, by whom, and what does the row look like if some vendors allow it and others
  do not? Recorded in `brand-marks/PROVENANCE.md`.
- **The branch line has a leading branch glyph**, as T3's does. Veto it freely — it was
  added because band 3 is otherwise a bare string with a logo floating at the far right.
- **The throbber is at 18 pt, its real size.** See below.
- **Working has its own colour** (blue). It had none, so a rail or a pill on a *running*
  agent came out grey — the shape said "notable", the colour said "idle".
- **Row 5 is now a provider with no bundled mark** (`Gemini 3 Pro` → a `GE` badge), moved
  up from row 10 because the last row is clipped by the caption. That row is the cost of
  "mark only" made visible: with the model text gone, an agent on any provider Array has
  no asset for is identified by two letters and nothing else. §4.5's initial set leaves
  Google, OpenRouter, Mistral, Groq and Cerebras in exactly that position today.

#### The throbber: 18 pt is its real size, and a still will always look like dots

`DualPlaneGyroTiltedThinkingIndicatorView.Metrics.side` is **18**, its guide rings are
`side × 0.036` wide at 30% alpha, and its orbit radius is `side × 0.296`. At the 11 pt of
the first mock that is a 0.55 pt invisible ring around a 3.3 pt orbit — which is exactly
the couple of dots you saw. It is now drawn at 18 pt, and production agrees: the agent
transcript tail installs it at its intrinsic size and never resizes it.

At 18 pt in a still it is **still a few dots**, and that is not a size problem. It is a
motion glyph: what makes it read is the orbit, and a fixed-phase snapshot has no orbit.
In the shipped sidebar it would animate. Two things follow, and neither is a mock
question:

1. **Judge it in the live app, not here.** No static image can settle it.
2. **Up to nine of them would animate at once** in a full sidebar, which the transcript
   tail never has to do. That is a performance question for whichever phase adopts it.

#### The three treatments

All three use one predicate for *when* to emphasise — Working, Approval, Input, Failed —
so the sweep varies only *how*. Done, Stopped and Cancelled stay quiet. That single
property is the loudest thing about the T3 reference: most rows carry nothing, so the few
that carry something are impossible to miss.

| | what it does | costs |
|---|---|---|
| **rail** | 3 pt coloured bar down the card's leading edge | 6 pt of row width, reserved on every row so text never jitters |
| **leadingIcon** | the status icon moves to the front of band 1 and grows to 16 pt, on **every** row | ~20 pt off the placement band; see below |
| **pill** | icon + word in a tinted capsule at the right of band 1 | width on precisely the rows likeliest to have long placement |

Having rendered them:

- **rail** is the one I would pick. Attention rows are unmissable at a glance, quiet rows
  are calmer than the control, and the icon and word are untouched so nothing is read by
  colour alone (§8.2).
- **leadingIcon** builds a clean scan column, but it is unconditional, so six green ticks
  march down the left edge and the *quiet* rows get as much emphasis as the loud ones —
  the opposite of what the reference achieves. Making it conditional would leave holes in
  the column, which is worse.
- **pill** is the most attractive single row and the worst list. The capsule competes with
  the title for weight, and it is the only treatment that **cannot** show the throbber at
  18 pt: a capsule tall enough to hold it collides with the title band at proposal A's
  pitch. It is clamped to 12 pt in that image.

They are rendered at **proposal A's pitch**, the tightest on the table, deliberately. A
treatment chosen at C's roomier 83 pt could break under whatever pitch S0 rules; one that
survives A cannot.

### Round three — borders, and the alignment defect measured

Ruled on 2026-08-14: **the pitch proposals and the row anatomy are green**, and the
**flat theme-coloured provider marks are locked in** (no brand colours). Status emphasis
stays open, with three new instructions: try a thinner side border, try other kinds of
border — the canvas's dashed focused-tile border was named — and the pill is out.

`status/status-{rail,railThin,outline,dashed,bracket,leadingIcon,leadingEnclosed,combo}`,
each at proposal A's pitch and 280 pt, in both appearances. Control unchanged:
`proposals/proposalA-280x662-*`.

#### The leading-column alignment was a real defect, and the fix is not the obvious one

*"They seem all a little off… too different to look properly aligned because of the
various shapes."* Correct, and the measurement says precisely why — every number below is
printed by the check:

| glyph | ink width | ink height |
|---|---:|---:|
| `checkmark.circle.fill` | 86% | 86% |
| `questionmark.circle.fill` | 86% | 86% |
| `slash.circle` | 86% | 86% |
| `exclamationmark.triangle.fill` | 83% | 84% |
| `stop.fill` | 77% | 83% |
| `hand.raised.fill` | **68%** | 88% |

My first attempt equalised each glyph's **largest** dimension — and the check refused it,
because SF Symbols already agree there to within 5%. It is **width** that varies, so a
centred glyph's *left edge* moves: centring this set scatters left edges over **1.44 pt of
a 16 pt slot**, which in a column is a ragged margin.

The leading column therefore aligns **ink left edges**, not bounding boxes. Measured after
the fix: every glyph starts at 0.00 pt, sits on the same centre line, and reaches the same
extent. That is asserted by painting each glyph through the real draw path and
re-measuring the pixels, not by re-running the arithmetic that placed it.

**`leadingEnclosed` is the other answer to the same complaint**: stop varying the shape.
Every glyph becomes the same disc with a different mark inside, so the column has one
silhouette and one optical mass. The cost is that `Failed` loses the triangle an earlier
round bought it, and Failed/Stopped/Cancelled differ only by their inner mark — at 11 pt
that was too little, at 16 pt it may be enough. Compare `leadingIcon` and
`leadingEnclosed` directly; that is the whole question.

#### The borders

| | reads as |
|---|---|
| `rail` (3 pt) | round two, kept for comparison |
| `railThin` (2 pt) | the same idea, quieter — the direct ask |
| `outline` (1 pt, whole card) | strong; four outlined cards in view is a lot of enclosure |
| `dashed` (1.5 pt, `[6,4]`) | the canvas's focused-tile language, quoted exactly |
| `bracket` | the outline's leading third, corners included |

One objection worth raising before you pick `dashed`: on the canvas that exact dash **means
focused tile**. Reusing it in the sidebar for "needs you" makes one visual language carry
two unrelated meanings, and the two surfaces are on screen together. `bracket` gets most of
the same shaping — rounded corners, an edge that feels deliberate rather than a slab —
without borrowing a word that is already taken.

My reading, having rendered them: **`bracket` or `railThin`, with the `combo`'s disc
column.** `combo` is `railThin` + `leadingEnclosed` and is the strongest single image in
the set. Its one flaw is that the Working row's throbber is not a disc, so it breaks the
column it sits in — fixable by giving the throbber a disc-sized track, which would be new
art and is not in this round.

### Round four — the icon set collapses to three

Ruled 2026-08-14: **keep the left-aligned column**, and cut the icons down to the ones
worth interrupting for — the hand for approval *and* input, the throbber for working, the
error mark for failed. Done, Stopped and Cancelled draw nothing.

`status/status-attention{Column,Rail,Bracket}-280x662-{aqua,darkAqua}.png`.

This is a better rule than the one I recommended, and worth writing down why. Round three
argued against a leading column because it was unconditional: a solid line of green ticks
gave the *finished* rows as much of the eye as the *broken* ones, which is the opposite of
what the T3 reference achieves. Making the column conditional fixes that at the root. The
glyph stops trying to name the state — the word beside it already does — and answers one
question instead: **is anything here that concerns me?** Three answers are worth a mark:
it's running, it wants you, it broke. Everything else is a hole in the column, and a hole
is information.

**Approval and input share the hand deliberately, and that is not the defect P0.1 found.**
That defect was the two sharing a *word*, so the row said "Blocked" and you could not tell
which. Here the icon says "you are needed" and the word still says which kind — two
layers, each carrying something.

**The slot is not reserved on rows that draw nothing.** It was, on the theory that a
reserved lane keeps the column straight — but the column is made of the *icons*, which are
pinned to one x and ink-aligned to each other, so it stays straight whether or not the text
beside them moves. Reserving the lane only indented band 1 away from the title and branch
below it, on seven rows out of ten, for nothing. Now a row with no icon runs all three
bands flush, and a row with one indents band 1 by exactly the space the icon fills.

Two glyphs remain in the alignment witness, and it now reads the set **off the mock's own
rows** rather than a list of its own — so it cannot end up measuring a glyph that was cut,
or skip one that was added. Centring these two would still scatter their left edges by
1.19 pt of a 16 pt slot; ink-left alignment puts both at 0.00.

## Dylan's ruling — does the card still need a border?

With the column already marking the rows that matter, an edge treatment may now be
redundant. All three images carry identical content and differ only at the card's leading
edge.

- [ ] **`attentionColumn`** — no border (recommended: the column is doing the work)
- [ ] `attentionRail` — + 2 pt rail
- [ ] `attentionBracket` — + leading bracket
- [ ] something else

`outline` and `dashed` were dropped rather than re-rendered — `outline` was the heaviest
of the five and `bracket` does its job better, and `dashed` borrows the canvas's
focused-tile language on a screen where both surfaces are visible at once. Both are still
in `qa-runs/2026-08-14T195203Z/` if they deserve another look.

And two sub-questions still open:

- **Keep the branch glyph?**
- **Should Done keep its green?** The word and its colour are all that mark a finished row
  now. That reads fine here, but it is the one place where state is carried by colour plus
  a word and no shape — §8.2 is satisfied (the word is the non-colour cue), but it is worth
  looking at deliberately rather than by default.

## Dylan's ruling

Pick one, or say what you want instead:

- [ ] **A — 66 pt / 68 pt, and collapse the hidden management label** → 9 rows, meets §8.1
- [ ] **A — 66 pt / 68 pt alone** → 8 rows, accepting that the floor is missed
- [ ] **B — 72 pt / 75 pt** → 8 rows
- [ ] **C — keep 79 pt / 83 pt** and fix only the band content → 7 rows
- [ ] **Revisit the nine-row floor itself**, now that the 52 pt of chrome is measured
- [ ] something else:

Notes:

Zone display in the placement band — required in Phase 2, or cut?

