# Sidebar — morning review

Written during the overnight focus session of 2026-08-03/04. **Read this first, then walk the
"What I want your eyes on" list.** Nothing here is blocked waiting on you; the four supervised
gates are prepped but deliberately NOT marked done, because approval is never inferred from
silence.

## Before you touch anything

```bash
cd /Users/dylan/Documents/personal/continuum-overnight
git log --oneline ac468a4..HEAD          # what landed
./scripts/check-sidebar-native-ux-program.sh --check   # program guard
grep -c '| done |' docs/38-tickets/94-sidebar-native-ux/_LEDGER.md
```

**Drag the menu bar to the built-in Retina display before any visual review.** You were on an
external at `backingScale=1.0` all night, which makes `--ui-baseline-check` red for the *display*
rather than the code. Every baseline move is therefore still uncommitted and waiting for you. Check
with `swift scripts/check-retina-main.swift`.

## What landed

| Ticket | What it actually changed |
|---|---|
| P0.1 | Program guard hardened to 631 lines with mutation self-tests + matrix wiring |
| P0.2 | Offscreen sidebar probe: refuses a zero-sized viewport, sweeps 220/280/320 in both appearances, measures per-label drawable-vs-needed width. Wired into the matrix and the inventory |
| P0.3 | 53-row defect corpus: a title that IS a `provider/model` id, nil role + nil branch, 100h elapsed, an unobserved agent, a 40-child parent, an over-long project name, a bidi title with combining marks. Two-way declaration↔usage parity, coverage pinned, runtime I5 hygiene scan |
| P0.4 | The truncation gate. 1302 labels measured at min/default/wide × both appearances |
| P0.5 | `SidebarSurfaceRole` fill ladder + `LineWidth.hairline = 0.5`. Nothing adopted in a view yet |
| P3.1 | Launch reconciliation sweep — a persisted record can no longer claim liveness across a relaunch |

| P1.1–P1.4 | **Containment.** A row paints no perimeter in any state; resting is unfilled *structurally* (nil fill, so the layer gives up its owned colour slot). State is fill from P0.5's ladder, resolved route-active > hover > selected > resting. Focus is a separate hairline ring view, armed only by a keyDown |
| P3.1 fix | The sweep as first committed **did not write** — see the correction below |

*(See `git log` and `_LEDGER.md` for the authoritative list, which is what the guard validates.
Anything not listed as `done` there is not done, whatever any commit message suggests.)*

## The one thing I got wrong, and how it was caught

**P3.1 as committed at `6af7616` never wrote to disk.** It shipped containing a *negative witness's
own mutation* — a read-time reinterpretation flag — which I left in the tree and committed, and my
ledger note claimed the opposite. The byte-migration assertion did not catch it because that
assertion read *through the store* rather than the raw file.

It was found by the next agent to touch the area, which is the argument for independent verification
rather than for my own re-reading. It mattered beyond cosmetics: the cross-project walk builds a
fresh store per root per call, so the flag never reached the listing and the gate built on top of it
would have gated nothing.

Fixed in `bf966cb`: the flag is gone, the sweep rebuilds and upserts, and the assertion now reads
`Data(contentsOf:)`. The P3.1 ledger note carries the correction rather than a quiet amendment.
**Worth your scepticism in the morning:** if a witness ever "passed but must fail", suspect the
assertion, not the mutation.

## Designs ready to execute (in the session scratchpad, not the repo)

Three read-only design passes produced apply-ready briefings that outlived their agents:

- `laneV-P2-design-key-findings.md` — row anatomy. Decomposes the 117-key table exactly (109 titles,
  4 project, 4 branch; only rows 50/51 are slim) and sets a healing floor per ticket, so "did it
  work" is arithmetic. Seven findings beyond the brief, including a **height-cache hole** (a folded
  parent's rollup changes its drawn line count with no height invalidation) and that **the gate never
  pins the probe's clock**, which is why one settled fixture measures ~23,900 hours.
- `laneV-P5-design-key-findings.md` — interaction, with your custom context menu first. Resolves the
  hide-vs-grey conflict on one axis (hide what *no host wired*; keep visible-and-disabled what *this
  agent* blocks) and flags the cost you should weigh: with today's wiring the menu drops from 9 items
  to 4. Also names the one place P5.1 legitimately moves an existing green assertion.
- `laneM-P3-app-pairs.md` — the verbatim `ContinuumApp.swift` application spec for the gated read.

## The number that matters

P0.4's entry witness went red naming **117 truncations** in the shipped row, almost every one a
**title** at 220 pt or 280 pt. That is the yields-first defect quantified: `titleLabel` is set to
`.defaultLow` compression resistance so the *name* is the first thing to give up width while the
project chip survives. One fixture's oversized project name crushes its own title by 110 pt at
*every* width, 320 included.

Those 117 keys became the `expectedSidebarTruncations` table in `UIProbeGeometry.swift`, and it rots
in **both** directions — a new truncation is red, and a tracked truncation that *heals* without being
removed is also red. So row anatomy cannot quietly improve things: it has to delete its entries in
the same change.

### Correction: the table is now 154, and that is the work succeeding

I told you earlier that "shrinking toward empty" was the progress bar. That was too simple, and the
honest picture is better. P2.1/P2.2 healed **64** keys — **every title at default and wide width, and
every project chip** — and then *added* 101 recorded sacrifices, almost all `branch`.

Why: the card is exactly three lines of type, and P2.1 may not move height (P2.3 owns that). So the
third band holds the meta line and the branch **together**, and the branch pays for it — which is
precisely what the recorded sacrifice order says should happen. The table is now split so a surviving
key cannot lie about which case it is:

- **`namesLongerThanTheRow` (49)** — a name genuinely longer than a 220 pt row *after* everything
  else has already yielded. A decision.
- **`sacrificedByOrder` (105)** — the recorded sacrifice. A caption or branch eliding *so the name
  does not*.

**The measure that matters is the first set, and that no card title elides at 280 or 320 pt at all.**
P2.4 will heal a large block of the `branch` keys legitimately, by dropping the model id from the
meta line (~85 pt shorter). Current size:

```bash
grep -c '@min"\|@default"\|@wide"' Sources/ContinuumRevived/App/UIProbeGeometry.swift
```

## Rulings I made so nothing waited on you

Five, written up with their evidence in **`plan-session-rulings.md`**. The three worth knowing
before you read code:

- **Snoozed rows now order by wake time, not spawn time.** `_DESIGN.md` says wake time; the code said
  spawn time and justified it on stability grounds — but `snoozedUntil` is a *stored constant*, so
  that premise is simply false. The locked decision wins and the wrong comment goes with it.
- **P4.5 (model-generated name) is blocked, and it costs nothing.** The packet specifies a
  `codex exec` CLI that **is never spawned anywhere in this repo** — only `pi` is. Rather than
  substitute a different provider (a new capability decision with I5 consequences), it is blocked
  with the evidence. Design decision 9 already makes naming best-effort, so a blocked P4.5 degrades
  to exactly the specified failure behaviour, and P4.2's deterministic first-prompt seed is what
  actually fixes your screenshot. Two-line change if you want it.
- **Phase 6 runs ahead of its stated gate.** Not just because lifecycle is never derived — nothing
  can *write* a parked fact either: both `settledOverride` assignments write `.neutral`, and
  `settledAt`/`snoozedUntil`/`snoozedAt` have no production assignment at all. Phase 6 is the wire
  for a third of what Phases 1–2 built.

## What I want your eyes on

These are the taste calls I could not make for you. Each is a judgment, not a bug.

1. **Containment.** Does the list read as one quiet surface rather than a stack of grey boxes? Is
   selection unmistakable at 220 pt when it is deliberately *quieter* than hover? Is focus obvious
   without a permanent outline? The measurement is settled (hover 8% > selected 7% mixes, ordering
   gated in both themes) — what I need is whether it *feels* right. If it doesn't, it's an alpha
   tweak in `SidebarSurfaceRole.emphasisAlpha`, not a rewrite.
2. **Density.** Row height now follows drawn content instead of a fixed 79 pt. A role-less,
   branch-less row used to reserve ~30 pt of dead space. Is the new rhythm right, or too tight?
3. **The provider glyph.** The model id used to print twice per row (once as the *name*, once in
   the meta line). Judge whether the glyph reads clearly enough to have earned that removal.
4. **Status words.** One vocabulary now spans sidebar, tree chip, tile header and phone. Read a few
   rows and tell me whether you'd act on what they say.

## Known limits, stated rather than buried

- **The four supervised gates are prepped, not passed.** Their ledger rows are still open.
- **No baseline was blessed.** Wrong display all night; candidates are uncommitted.
- **P3.1's writer fix has no deterministic red of its own** — no matrix leg reads a freshly spawned
  managed record's status word (`--managed-agent-live-check` is live-only and not in the matrix).
  Its witness comes from the gated-read work instead.
- **One P3.1 witness (N3, read-only-reinterpret) was not run** — a deliberate speed call. The byte
  assertion it targets is green and two other witnesses cover that write path.
- **`--agent-tile-click-focus-check`** was in the matrix but missing from the inventory (pre-existing,
  growth-only so it was green). Regenerating the inventory picked it up — that is the one extra
  inventory line you didn't ask for.
- **Stale `AgentInboxRowView` comment references** at `AgentInboxView.swift:581`, `:727` and
  `UIProbeAppearance.swift:263`. That class does not exist. Dead comments; left alone.

## Process facts that still bind

- Local commits only, never pushed. Your identity, no trailers.
- `STOP` is still in place at `docs/38-tickets/94-sidebar-native-ux/STOP` as an interlock against an
  accidental loop restart. Harmless; delete it whenever.
- Quit your running Continuum instance before any probe, build, or relaunch.
- Baselines only with `check-retina-main.swift` green, and never to make red go away.
