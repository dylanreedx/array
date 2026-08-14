# Supervised gate S0 — row density

Status: **AWAITING DYLAN'S RULING.** Nothing in the program locks 66/68 until the
ruling below is filled in. Silence is not approval (§3.2).

§6/P0.2 asks for exactly this: *"Dylan reviews the current red baseline and three
proposed static row-density variants before implementation locks 66/68 geometry. The
documented target is the default proposal, not approval inferred in advance."*

---

## The question, in one number

How many complete agent rows fit in a 662 pt sidebar viewport?

| | card | pitch | complete rows in 662 pt |
|---|---:|---:|---:|
| **Today (shipping)** | **79.0 pt** | **83.0 pt** | **7** |
| **A — documented target** | 66 pt | 68 pt | **9** |
| B — comfort midpoint | 72 pt | 75 pt | 8 |
| C — today, redrawn with the intended anatomy | 79 pt | 83 pt | 7 |

§8.1 requires *"at least nine complete active rows in 662 pt"*. **Only proposal A
meets that floor.**

Today's numbers are **measured, not divided out**: the harness counts cells whose
painted frame lies wholly inside 662 pt, at all four widths. Proposal C exists to keep
that arithmetic honest — C *is* today's geometry, so a teeth check requires C's computed
card, pitch and row count to equal what the shipped sidebar paints. The first version of
the formula added the row gap instead of accounting for the leading gutter and claimed
8 rows where the real list draws 7; it now agrees, which is the only reason A's 9 and
B's 8 are worth anything.

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

Accessibility variants at 280 pt: `a11y-280x662-{aqua,darkAqua}-{rm,ic}.png`.

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
  written. Nine rows. Every band carries text.
- **B — 72 pt / 75 pt.** The same anatomy with 10 pt insets and 3 pt band gaps, if A
  reads cramped at 220 pt. Eight rows.
- **C — 79 pt / 83 pt.** Today's pitch with the intended bands filled in — the control
  that separates "the rows are too tall" from "the rows are empty". Seven rows.

**C is the one worth looking at hardest, and it changes the framing.** Having rendered
it: at today's 79/83 pitch, with the bands carrying real information, the row reads
*fine*. Airier than A, but legible and scannable — nothing like the baseline.

So the honest reading of this evidence is that **the sparseness is mostly a content
problem, not a height problem.** The baseline looks bad because two of three bands are
empty and the third holds a diamond, not because 83 pt is too tall. Proposal A buys two
more rows per screen on top of that; it is a real gain, and it is the only option meeting
§8.1's nine-row floor, but C shows the floor is not what makes today's sidebar unusable.

That distinction matters for what you approve: picking A commits the program to a
sidebar-specific geometry change (§4.3 is explicit that global `Inset.card` and title
typography must not move to achieve it), whereas picking C commits only to filling the
bands, which Phases 1–3 do anyway.

---

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

- [ ] **A — 66 pt / 68 pt** (the documented target; the only option meeting §8.1's
      nine-row floor)
- [ ] **B — 72 pt / 75 pt**
- [ ] **C — keep 79 pt / 83 pt** and fix only the band content
- [ ] something else:

Notes:

Zone display in the placement band — required in Phase 2, or cut?

