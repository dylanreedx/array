# 96 — Handoff

Written 2026-08-14, before a context compaction. Everything needed to pick this up cold.

Read first: `_DESIGN.md` (the authority), then this file, then `_LEDGER.md` (every
witness and every wrong turn, in the order they happened). `S0-density-review.md` holds
the open rulings; `P0.1-fixture-inventory.md` records what production actually renders.

---

## Where the work is

| | |
|---|---|
| worktree | `~/array-worktrees/sidebar-96` |
| branch | `array/sidebar-96`, base `d334f01` |
| HEAD | `990e563`, **clean tree**, 21 commits |
| preview app | `~/Desktop/Array Dev 96.app` on `~/array-scratch-96` |
| latest artifact | `qa-runs/2026-08-14T215401Z/sidebar-96/` (gitignored) |

`_DESIGN.md` is untracked in Dylan's main checkout and therefore absent from this branch.
Read it from
`/Users/dylan/Documents/personal/Array/docs/38-tickets/96-agent-sidebar-product-redesign/_DESIGN.md`.

## The one-paragraph version

Phase 0 built the evidence: the shipped row carries two facts and a diamond, and the
proof is production-driven, not asserted. Gate S0 then went from static mocks to **a real
redesigned cell rendered by the shipped `AgentInboxView`**, injected through a
nil-by-default override so nothing in production or in queue-94's gates moved. Six rounds
of Dylan's feedback have shaped the row: mark-only providers, a three-glyph attention
column, one colour per meaning, and a new state for work that finished and nobody looked
at. **Nothing is locked** — the pitch ruling is still open and the row is still a preview.

---

## HOW TO ITERATE — read this before anything else

Dylan, 2026-08-14: *"let's start iterating faster, these changes don't require a super
intense testing flow to get into my hands."* He is right, and here is the rule.

```sh
cd ~/array-worktrees/sidebar-96
scripts/sidebar-96-preview.sh        # build + reinstall + relaunch, ~25s
# → View → Component Lab → Sidebar 96 → Live Sidebar
```

**Why skipping the gates is legitimate here, not lazy.** The redesigned row reaches the
screen only through `AgentInboxView.cardStyleOverride`, which is nil everywhere except
the Lab section that sets it. A visual change to that row cannot alter production, cannot
alter what any queue-94 gate renders, and cannot touch a committed baseline. Running
seven checks to look at a colour is ceremony.

**Run the full pass at these three moments, and not otherwise:**

1. **Before locking a decision** — writing a ruling into `S0-density-review.md`, or a
   ledger entry that claims something is true. That is when someone starts relying on it.
2. **Before the 96 row becomes the default** rather than an injected override — plus a
   tmux-isolated matrix run. That is when it stops being a preview and becomes the
   product.
3. **Any time a change leaves the preview path.** `AgentInbox96CellView.swift` is shared
   with `SidebarScreenshotChecks`; `DesignTokens.swift` is shared with the entire app and
   iOS. Those are not preview-only edits, whatever they are for.

The full pass is listed at the top of `scripts/sidebar-96-preview.sh`.

---

## What exists

### The redesigned row — `AgentInbox96CellView.swift`

A real `AgentInboxRowCell`, so the **shipped list renders it**: scrolling, hover,
multi-selection, context menu, disclosure, jump pills, rename and accessibility are all
queue 94's and are not reimplemented. The list's *behaviour* was never this program's
complaint.

Anatomy: leading attention glyph · placement / state+time · **title** · branch + provider
mark. Three bands, fixed pitch, every band always drawn.

Also owns `InkAlignedSymbol` and `BrandMark96`, which `SidebarScreenshotChecks` calls —
so the review images, the live row and the alignment witness are **one implementation**.

### The seam — `AgentInboxView.cardStyleOverride`

nil by default. Hands in two things: how a card row is built, and how tall it is (96's
height is fixed by pitch; queue-94's is derived from which bands have content). Three
lines of production behaviour, all guarded by that nil.

### The Lab — `ComponentLab.swift`, category **"Sidebar 96"**

- **Live Sidebar** — the real list, with a `96 row` / `Today's row` A/B switch, a
  `96 rules` / `Queue 94` row-set switch, and pitch / border / glyph-placement /
  model-name controls. The throbber spins and the escalated row pulses here.
- **Row Playground (static)** — the original painted mock, kept for pitch comparison.

Both are `.reviewSurface`, not `.staticCard`. Every baseline, contrast and probe sweep
guards on `.staticCard` and skips the rest, so these owe no committed baseline. Verified:
`--ui-baseline-check` mentions their ids zero times.

### The checks

| flag | what |
|---|---|
| `--sidebar-production-corpus-check` | 30 flows through the real writers, read off rendered cells. Has teeth. |
| `--sidebar-screenshot-check` | 48 images + manifest. Mocks, proposals, status sweep, and three live renders. |
| `--sidebar-live-capture-check` | the shipped app in a real window (needs a display) |

The screenshot check renders the live cell over **three** row sets, and the trio is the
point: `production` (what the app makes — sparse), `capability` (queue-94's fixtures —
what the Lab shows), `rules` (`AgentInbox96Fixtures`, the states 96 *adds*). Rendering
one alone cannot separate "the cell draws badly" from "the data is poor".

---

## The design as it now stands

### Colour — one per meaning, with the two kinds of asking sharing one

| state | colour | token |
|---|---|---|
| working | blue + the moving glyph | `accentWorking` |
| approval **and** input | amber, one colour for both | `accentApproval` |
| failed | red | `accentFailed` |
| done, and you saw it | green | `accentDone` |
| landed / waiting | rose | `accentReview` **(new)** |

The defect this fixed was never "too many colours" — it was `Needs attention` in amber
directly above `Needs attention` in violet. Same words, same glyph, no difference in
meaning.

**Dylan does not like the rose he picked** (`#E5799B`) and wants to revisit. Before
changing it, know that it is the least forgiving colour in the palette: **4.78:1** at its
worst surface and **4.75:1** against the strongest interaction fill, against a 4.50 floor.
A replacement must be re-measured, and five pinned tables must be updated with figures
read out of the harness — see `_LEDGER.md` round 7 for the list and the method.

### Glyphs — three, and most rows get none

Running (the app's own throbber, spinning) · wants-you (one hand, for **both** approval
and input) · broke (error triangle) · finished-but-unseen (a small dot).

Approval and input sharing the hand is **not** the P0.1 defect of the two sharing a
*word*: the icon says "you are needed", the word still says which kind.

The column is ink-**left**-aligned, and the slot is not reserved on rows that draw
nothing. SF Symbols agree on their largest dimension to within 5% but not on width
(68% vs 86%), so centring scatters left edges by 1.44 pt in a 16 pt slot.

### Rule 2 — work that finished and nobody looked at it

Both halves come off the existing model: `InboxState.ready` + `InboxAttention.unread`,
whose own comment already says *"Unread is a MARK, not a word."* Two rungs separated only
by age: `Landed`, then `Waiting` with a **pulsing** mark past 10 minutes.

The pulse is 0.5 Hz and bottoms out at 0.4 opacity — far under the 3 Hz seizure
threshold, and never to zero because a glyph that vanishes reads as a rendering fault.
Reduce Motion drops it with nothing lost: the word changes either way.

Names are provisional; `ReviewState` is one enum, renaming is one line.

**Unresolved:** if nine rows pulse at once, none of them do. A cap — oldest few only, or
only when the list is otherwise quiet — has been raised and not decided.

---

## Open rulings

1. **Pitch** — A (66/68), B (72/75), or keep today's 79/83 and fix only content? The
   arithmetic is in `S0-density-review.md`; no proposal meets §8.1's nine-row floor.
2. **Collapse the hidden management label?** ~18 pt, the difference between A meeting the
   floor and missing it.
3. **Is nine rows still the right floor**, now the 52 pt of chrome is measured?
4. **Zone in the placement band** — Phase 2 requirement, or cut?
5. **Card border** — none / 2 pt rail / bracket. My read: none, the glyph column does it.
6. **The rose**, per above.
7. **Branch glyph** — keep it?
8. **Right-click menu** — Dylan asked how T3's looks. **I cannot see T3's app and did not
   guess**; the screenshot he sent is of the list, not a menu. Still waiting on one.
   Array's row menu today: Open / Rename / Settle / Snooze › / Mark Unread / Archive /
   Delete, unavailable actions hidden rather than greyed.

Also observed from T3's list shot, not yet acted on: **quiet rows there carry only a
relative time**, no state word — exactly one row in the whole screenshot says anything.
Array now paints `Done` in green, which is the opposite choice.

---

## Brand marks

`brand-marks/` holds anthropic, openai (light/dark), xai (light/dark), gemini, with
`PROVENANCE.md` recording source, hashes and open questions. **Design-time only** — they
are loaded by repo-relative path and are NOT bundled, so a released build would find
nothing.

Three things are open, all P3.1:
- **Trademark review per vendor**, now including whether **monochrome/template treatment
  is permitted** — the mock tints them flat, which §4.5 forbids without permission.
- **Missing marks**: OpenRouter, Mistral, Groq, Cerebras, and the three harness marks
  (Codex, Claude Code, **Pi** — the reason a Pi agent is indistinguishable from the
  others).
- **The name fallback replaces §4.5's two-character badge.** `GE` was unreadable to the
  person who commissioned it. Needs a §4.5 amendment.

The mock deliberately keeps one unbundled provider on screen (`Mistral Large 3`) so the
fallback stays visible as marks arrive.

---

## Rules that bit, or nearly did

- **`ComponentLab.swift` is no longer at zero diff, and that is fine** — a Lab entry
  lives there. The queue-94 gate scans only between the two `P0.3 SIDEBAR DEFECT CORPUS`
  markers (lines 415–607); everything added is past 1165. Verified by running it.
- **Never `CONTINUUM_UPDATE_BASELINES=1`.** Never touch `MATRIX_KNOWN_RED`.
- `--component-lab-check` and `--ui-baseline-check` are **red and pre-existing**, both in
  `MATRIX_KNOWN_RED`. The first fails on the composer provider footer; the second on a
  provider-controls pixel diff plus 12 `chrome.agentInbox` baselines orphaned by a size
  change. Neither mentions anything this program added. Do not chase them.
- Never rebuild `~/Desktop/Array Dev.app` (the shared preview) — this program has its own.
- The parallel branch `array/canvas-perf` owns `PerfScenarios.swift`, `CanvasNSView.swift`
  and the perf docs. Stay out.
- An offscreen `NSTableView` **defers its incremental reload indefinitely**. Use
  `rebuildRowsForQA()`.
- **The list hands cells `now` from its own `clock`**, which defaults to the wall clock.
  Any age-based rendering needs the clock pinned too, or the fixture measures nothing.

## Traps this program fell into — all of them found by LOOKING

1. A check asserting only that flows *ran*, while every product fact was a `print`.
2. A live check reporting PASS over a screenshot reading "No agents yet".
3. Four "accessibility variant" images byte-identical to the baseline.
4. A manifest hard-coding `verdict: "PASS"` before the gate ran.
5. A density formula over-counting in the direction that flattered the proposal.
6. Recording `meta` as the placement band when placement is a different label.
7. An ink normalisation that equalised the dimension which was already equal.
8. A cell whose bands drew **upside down** (the card view is not flipped).
9. `Done` rendering as `Do…` — a text field's width is not its string's width.
10. Brand marks matching **no** production row, because the mock used display names
    while real ids are `provider/model`.
11. A throbber that never span: `startAnimating()` exists and was never called.

The pattern behind all eleven: **an artifact that looks like evidence but was never
checked against what the product paints.** Items 8–11 were invisible in every mock image
and obvious in the first live render — which is why the live fixture exists.
