# 90-agent-ux — Morning report

Branch `overnight/agent-ux` (worktree `continuum-overnight`). Updated by the supervising session
2026-07-25 ~12:00Z. Live state is always `_LEDGER.md` + `git log`; this is the narrative.

*(An earlier version of this file reported a dependency-cycle deadlock and asked you for two
decisions. Both are resolved — the cycle was mine and is fixed; the four colour questions are ruled
into `P1.3`.)*

**One thing IS waiting on you now, and it is not code:** your external display became primary, which
flipped the render scale 2x → 1x and reddened every visual baseline. See "THE ONE THING WAITING ON
YOU" below.

## TL;DR

**Phase 0 is complete. Phase 1 is nearly done, and — the part you asked about — the tile now
actually renders readably in BOTH appearances; I opened the renders to confirm it.** 20 tickets landed, each independently verified by me rather than
taken on trust. Matrix: 23 legs green, 1 red purely from a display-scale change (below). The loop
stopped itself, correctly.

The night's real finding: **the tooling I built around the workers was the weak link, not the
workers.** Six supervisor mistakes, one worker wedge, zero worker contract violations.

## What landed (20)

**Phase 0.** Why the night went here first: the entire pre-existing visual gate was
`distinctSampledColors <= 1` — "the image has more than one colour." It had happily passed
black-on-dark text, half-width cards, and a completely blank transcript.

| Ticket | What it gives you |
|---|---|
| P0.1 | **iOS builds in the matrix.** Yesterday's `Process`-on-iOS break cannot reach you again |
| P0.2 | `UIProbe` — render any component at an explicit size *and* appearance |
| P0.3 | Geometry gates incl. `hasAmbiguousLayout` (reports the exact unpinned-stack bug I shipped) + a 320pt survival pass |
| P0.5 | Pixel probes, thresholds **measured not chosen** (spread ≥0.05 vs worst real 0.141; invisible text measures 0.000) |
| P0.6 | 46 committed PNG baselines; blessing explicit, never implicit |
| P0.8 | Shared element lookup + a `waitUntil` that *cannot* block the main thread — Swift rejects the wrong pattern in async, so it can't come back |
| P0.9 | `--ui-tour-check`: 38 labelled renders, every filename carrying surface·state·size·appearance |
| P0.10 | **Fixed a latent bug**: there is no bare `gpt-5.6`; we had been fuzzy-matching across three variants. Now `gpt-5.6-sol`, verified against `pi --list-models` |
| P0.11 | Matrix inventory guard — 248 records; a vanished *or commented-out* check fails red |

**Phase 1 (11 of 12).** `ContinuumRevivedAgentUI` (imports only Foundation, declares zero
dependencies, so `AgentUI → Core` is structurally impossible), `TokenColor{light,dark}`, a 7-role
type scale whose guard *derives* the readability boundary from Core, a 2pt spacing/radius scale
fixing the inverted nesting (tile radius 6 was nesting cards at 8), and — the important one —
**P1.3, the named light+dark palette**:

> 22 tokens × 2 themes, **104 documented pairs all clearing their floor** (tightest: border on
> cardUserMessage in dark at 3.44:1 against a 3.00 floor), 1 reasoned exemption, and **witnesses that
> fail on purpose**: border 1.68:1, tertiary 2.07:1, secondary 3.98:1.

That last clause matters: the three defects behind your complaint are now pinned as regression
witnesses, so they cannot come back silently. Apple's semantic label colours appear nowhere in the
palette (they *cannot* clear 4.5:1 — `secondaryLabelColor` composites to #808080), accents carry a
darker light-appearance variant with hue identity preserved, card fills are appearance-aware, and
`borderStrong` now measures 6.91:1 on canvas where the old tile border was 1.68:1.

Since then **P1.7** added a colour-hygiene gate whose allowlist can only shrink (94 line-scoped
entries, each with a reason and an owning adoption ticket; a stale entry fails), and **P1.8**
collapsed the six status→colour maps and three glyph maps onto the one presenter — so `configuring`
can no longer be purple in the tile, teal on the board and invisible-grey in the sidebar, and `◌`
can no longer mean *stale* in one place and *configuring* in another. iOS's stringly-typed
`AppColors.color(for token:)` channel is deleted.

Then **P1.9** made the appearance live: `TokenThemed.applyTokens()` is the one place a view assigns
layer colours, called from `init` *and* `viewDidChangeEffectiveAppearance`, policed by a gate that
paints a **magenta sentinel** over every layer colour, flips the appearance for real, and fails on
any sentinel that survived — i.e. on any colour assigned anywhere else. It deliberately changed no
colour *values*.

## P1.10 — your complaint is fixed. I looked.

`9799b62`. **The six hardcoded dark card fills are gone.** `NSColor(red: 0.13, green: 0.15,
blue: 0.18)` and its five siblings were dark in *both* appearances — that was the actual
black-text-on-dark-blue bug — and they are now appearance-aware `SurfaceToken`s. The 1.68:1 hairline
`NSColor(white: 1, alpha: 0.14)` is now `LineToken.border`, which carries a 3:1 floor. Text is
`textPrimary`/`textSecondary`.

**16 colour-hygiene allowlist entries deleted, zero added.** That ratchet only turns one way, and
this is the first ticket to turn it.

I opened the moved baselines rather than trusting the green:

- **Light (aqua) is genuinely light-surfaced** — light card fills, dark text. Not dark fills with
  dark text. The card kinds are distinguished by *tint* (neutral for assistant, pale teal for tool,
  pale green for diff) instead of by six unrelated dark literals, and the tints are quiet enough to
  read as one family.
- **Dark (darkAqua) is structurally identical with properly inverted surfaces.** Same layout, same
  hierarchy, legible in both.
- **Card edges read as edges** in both appearances — that was the 1.68:1 border, and it now shows.
- The approval-dock render shows all three states stacked, and the attention state carries an amber
  ring around the whole tile, so "needs you" is visible without reading a word.

Honest caveats: the secondary status labels (`done`, `running`) are deliberately quiet and sit near
their floor rather than comfortably above it — legible, not prominent. And the tile's **title bar was
still dark in the light render** at this point; that is chrome, and P1.11 fixed it (below).

The gate also got *stronger* here, not weaker: it gained a minimum-sentinelled-slots floor, so
silently dropping coverage now fails, plus a stale-fixture witness asserted to fail every run.

**My own independent matrix pass on this is now done** — see the dedicated section below. 23 legs
green; the only red leg is display-scale, not colour.

## P1.11 — the chrome follows too, and the title bar is fixed

`8b0b777`. **90 allowlist lines deleted, zero added** — the allowlist is now 33 entries, down from 94.
Scope was exactly the ten chrome files its packet names. I opened four more baselines:

- **The tile's title bar is now light in the light appearance.** That was my one open caveat from
  P1.10, and it's gone: light bar, dark text, and the "Needs attention" chip is a light pill with
  dark amber text instead of a dark chip.
- **The sidebar renders correctly in both appearances** — the white-on-white chrome bug from Friday
  is gone. Light: light surface, dark text. Dark: properly inverted.
- Visually confirmed P1.3's accent claim: the amber is a deeper brown-amber in light and a brighter
  orange in dark — same hue family, different lightness. The blue behaves the same way.

**One deviation, and it's owner-visible.** The descriptor tile had eleven per-`TileKind` background
literals; P1.11 collapsed them onto one surface token, so tile kinds no longer differ by fill. It
didn't just assert that was safe — it measured all **55 pairwise contrast ratios** among the retired
literals and pinned two checks: one fails if the widest reaches 1.20:1 ("the fills WERE
distinguishable and collapsing them lost real information"), another fails if fewer than 46 of 55
pairs are under 1.10:1. They were already indistinguishable. **If you disagree and want tile kinds
colour-coded, that is a design call to make — the evidence is in `UIProbeAppearance.swift`.**

The sentinel gate's slot floor moved 26→23, which looks like a weakening and isn't: retiring eleven
real painted fills lowers the count. `minimumThemedViews` rose 10→11 and the assertion count doubled
(27→54) in the same commit.

## P1.6 — the contrast gate is ON, and it went green honestly

`c4d3516`. The gate P0.4 built and refused to wire is now a real gate. **177 → 78 → 11 → 0** failing
pairs of 446. What makes it legitimate:

- **`UIProbeContrast.swift` — the gate itself — was never touched.** The measuring apparatus is
  byte-identical to what P0.4 built, so it cannot have been tuned to pass.
- **No exemptions, no allowlist, no floors moved.** Every `skip`/`exempt` string in the diff is a
  comment forbidding one.
- **The last 11 were closed by fixing a colour.** `FocusBorderConfig.attentionColor = "Orange"`
  resolved to `systemOrange`, which the gate measured at **2.07:1 on a light tile**. Deleted; the
  semantic ("orange means human action is required") now rides P1.8's single status→appearance
  mapping, whose amber has a darkened light variant.
- `matrix-inventory.txt` grew to record the check, so it can never be silently dropped.

**So P0.4 is no longer blocked** — its gate went green legitimately during Phase 1, exactly as the
re-sequencing intended. Its findings doc remains the record of how.

## I ran the matrix myself — 23 legs pass, 1 fails, and the failure is your monitor

Owed for five wakes; paid at 09:15Z on a clean tree. Independently confirmed:

- `--ui-contrast-check`: **452 pairs gated in both appearances, 0 exempt.** Worst text 5.88:1
  (floor 4.5), worst non-text 3.70:1 (floor 3.0).
- **132 layer colours + 172 non-layer colours across 19 adopted owners** hold a token value in
  *both* appearances.
- Tile outline **6.91:1 light / 8.90:1 dark**, against the pinned 1.68:1 pre-ticket witness.
- The stale-fixture witness failed as required, and 23 sentinelled layer colours all re-resolved.

The one red leg is `--ui-pixel-check` → `witness.visibleBorder`, luminance delta **0.000**. Not a
colour regression — see below.

## STOPPED AGAIN 2026-07-25 — same substrate, different half of it

The loop stopped a second time, mid-`P1.12`, and again on the environment rather than
on a ticket. Full measurements: `_ENV-BLOCKER-2-text-antialiasing.md`.

Short version: `5080adc` pinned the probe's SCALE, which fixed the 1x/2x blocker below.
It did **not** pin glyph rasterisation. With the tree clean at `881a458`,
`--ui-baseline-check` is red on **24 of 46** baselines — deterministic across runs,
identical with and without P1.12's diff, and the diff images are magenta **only on
letterforms** (layout unmoved, fills unmoved, text-free renders still match). The same
tree ran this leg green earlier today, under the display configuration described below;
the built-in Retina panel is now the only display.

The worker again refused to bless (the forbidden move), parked its complete P1.12
implementation in `git stash@{0}` (`2c7cc86`), and stopped rather than burning the rest
of the queue on a leg no ticket can fix.

**Your call, and I recommend the first:**

1. **Pin the probe's font rendering** in `UIProbe.render` (own `CGContext`, explicit
   smoothing/antialiasing rather than inheriting the window's), then one deliberate
   46-baseline bless commit. This makes the gate host-independent and ends this class.
2. **Re-bless on this host** and do not change displays for the rest of the run. One
   commit, but it will recur.

P1.12 itself is done and verified as far as it can be here: `swift build` green, the iOS
`xcodebuild` leg green, colour hygiene green with 7 negative tests observed red. Still
owed once the substrate works: the full matrix, codex cross-review, and the simulator
confirmation. The ledger row has the whole diff described.

## The FIRST display blocker (2026-07-25 09:14) — resolved, kept for the record

The loop **stopped itself** at 09:14 (`a44c0cf`) mid-P0.7 and it was right to. Your 1920×1080
external became **Main Display**, so the window backing scale flipped 2x → 1x. Every visual baseline
was blessed on the Retina host, so at 1x antialiasing differs by 8–9% of pixels: **46 of 46 baselines
red**, and `expectVisibleBorder`'s fixed 1px edge skip steps clean past a 1pt border at scale 1.

The worker **refused to bless the baselines** (the forbidden move), parked its P0.7 implementation in
`git stash@{0}`, wrote `_ENV-BLOCKER-1x-display.md` with the measurements, and stopped. Zero contract
violations, again.

Two routes, and it's your call:

1. **Make the Retina display primary** — no code change, unblocks immediately.
2. **Fix the substrate to render at a fixed declared scale** — one ticket, and this can never recur
   whenever you dock or undock.

My recommendation: do 1 now to unblock, and queue 2, because baselines that depend on which monitor
is primary will bite again.

## The one formerly-blocked ticket — P0.4, and it's the interesting one

P0.4 built the per-appearance contrast gate, ran it against the **real view tree**, and found it red
on **177 of 446 pairs**. It then refused both routes to green because my own packet closed them:
allowlisting is forbidden, and recolouring belongs to Phase 1 files it wasn't allowed to touch. So it
committed the gate **deliberately unwired**, wrote `P0.4-FINDINGS.md` with every measured ratio, and
blocked. It proved the gate first: 269 pairs pass, compositing validated against AppKit's documented
alphas, and when Codex review found 4 real defects in it, coverage grew 432→446 while the failing set
did not move — so none of the 177 is an artifact.

The 177 decompose into four causes, and one is exactly your long-standing complaint:

| Cause | Pairs |
|---|---|
| Apple's own `secondary`/`tertiaryLabelColor` cannot clear 4.5:1 (composites to `#808080` = 3.95:1) | 74 |
| Accents used as text on white | ~44 |
| Hairline borders at 1.56–1.68 | 28 |
| **Black text on hardcoded dark fills in light appearance — the shipped bug** | ~25 |

**No action needed.** I ruled the four questions into `P1.3` (they implement the light+dark decision
you already locked), re-sequenced so `P1.6` wires the gate after adoption, and verified the graph
acyclic. It goes green legitimately during Phase 1, or it doesn't go green.

## What I got wrong (six times)

The honest shape of the night:

1. **Swept a worker's staged work into my own commits, twice.** `git add <paths>` does not scope a
   commit; bare `git commit` takes the whole index. It destroyed a worker's index mid-ticket.
2. **Mis-sequenced P0.4** — demanded a green gate before the tokens that make it green existed.
3. **Created a dependency cycle** fixing that (`P1.1 → P0.7 → P1.6 → … → P1.1`). The loop halted and
   diagnosed it precisely rather than thrashing.
4. **Tried a separate git index to commit "safely"** — it commits fine, then advancing HEAD leaves the
   worker's stale index seeing my new files as *deleted*. Repaired; the rule is now simply "commit
   only when no child is alive."
5. **Mis-calibrated stall detection** — nearly killed a healthy 30-minute ticket, then later trusted
   "staged work" that was stale. Now requires four signals: CPU, log growth, subprocess, elapsed.
6. **Left a killed ticket's row as `in-progress`**, so the relaunched loop re-picked finished work.

All six are written into `_RUNBOOK.md` so they cannot recur silently.

## What the workers did — the good news

- **Refused to fake green** (P0.4) and blocked with measured data instead.
- **Reverted an out-of-scope experiment** on its own (P0.6 touched a card view, then didn't ship it).
- **Reported a pre-existing flaky check unprompted** rather than "fixing" it by weakening it.
- **Found that `--managed-agent-live-check` can't run headlessly** (it blocks on an `NSAlert`) and said
  so rather than claiming coverage. → **Phase 5's live RPC work needs a supervised GUI pass.**
- Built a guard that *derives* the readability boundary from Core instead of hardcoding it.
- One **wedged** (0% CPU, 45 min). Its work was complete but for a single wrong constant — 0.60 where
  `.managedAgent` uses 0.70, which its own failure message already stated. I fixed that, verified the
  matrix, and committed on its behalf with a `SUPERVISOR-COMPLETED` note.

## Where it's going

**87 tickets queued, acyclic**, full packets authored for Phases 0–5:

- **Phase 1 (2 left)** — the visible payoff: tokens adopted, tile + chrome readable in *both*
  appearances, six status→colour maps and three glyph maps collapsed onto one presenter, contrast gate
  wired.
- **Phase 2 (27)** — the agent decoupled from its tile (an `AgentSupervisor` owns runners, so closing a
  tile stops killing an agent, and >4 agents stop being frozen by a *canvas layout* budget), per-agent
  git worktrees, and the `spawn_agent` orchestrator.
- **Phase 3 (14)** — the sidebar becomes the inbox.
- **Phase 4 (13)** — settle / snooze / archive with blocker precedence.
- **Phase 5 (10)** — Pi RPC: interrupt, real approvals, mid-run model/effort, real `/compact`,
  per-agent cost.

At ~20 min/ticket it keeps going as long as it's left running. `touch STOP` in the repo root halts it
cleanly between iterations.

## If you want to look at one thing

`qa-runs/<newest>/tour/index.md` — the labelled contact sheet of every agent surface at three widths
in both appearances. Fastest way to see the current visual state, and the direct fix for my worst QA
failure yesterday: judging a 460pt fixture in an unknown appearance and calling it clean.

Also `docs/38-tickets/90-agent-ux/P0.4-FINDINGS.md` for every failing colour pair with its ratio.
