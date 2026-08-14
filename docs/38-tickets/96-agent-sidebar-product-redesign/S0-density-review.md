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

