# Sidebar work — handoff: from overnight loop to a focused session

Written 2026-08-03 at Dylan's direction, replacing the loop approach for the sidebar. **Nothing is
in flight. Read this first, then `_DESIGN.md`, then `plan-sidebar-t3code-study.md`.**

## The decision

The overnight loop is the wrong tool for this surface. Dylan's call, and the two hours of evidence
agrees: **three of the four stalls were caused by packet fencing, not by implementation.**

| Event | Cause |
|---|---|
| P0.1 review round 1 `REWORK` | Guard/loop parse mismatch I authored (shadow rows) |
| P0.1 review round 2 `REWORK` | Same class, second vector (same-line shadow cells) |
| P0.2 worker `BLOCKED` | `scripts/run-matrix.sh` not in P0.2's fence, so its own check leg could not be wired |

The loop's core assumption is that a ticket is an *independent* unit with a clean file fence. The
sidebar is the opposite: one 4,200-line view file plus a row model, a builder, and four probe files,
where nearly every change touches the same handful of files and the same gates. Fences that small
fight each other; fences that large stop being fences. Add the fixed costs — ~7 min matrix per
ticket, 40–75 min per ticket, ~34 h projected — and a focused session with delegated subagents is
both faster and better suited.

**What survives, and it is most of the value:** the 40 packets are still the best decomposition of
this work, and `_DESIGN.md` is still the contract. Treat the packets as a **work list**, not a queue.

## State at handoff

- Branch `overnight/agent-ux`, local only, never pushed.
- **`ac468a4`** — queue 94 authored (40 packets, design, runbook, queue, ledger, guard, loop
  machinery) plus the two evidence docs.
- **`6fe6cd4`** — `feat(sidebar): program contract` = **P0.1 done and legitimately good.** The guard
  is now 631 lines with mutation self-tests and a matrix leg wired *after* queue 91's locked
  four-line prefix. Verified: 4 files, all in fence, Dylan's identity, no trailers, ledger row
  `done | this commit | 2026-08-03T22:15:24Z`. Keep it.
- **Loop stopped and disarmed.** `STOP` present at `docs/38-tickets/94-sidebar-native-ux/STOP`, loop
  pid gone, overwatch monitor stopped, 20-minute cron job deleted. Nothing will resume on its own.
- **Ledger:** P0.1 `done`, P0.2–P7.1 `pending`. `./scripts/check-sidebar-native-ux-program.sh --check`
  is green. Do not hand-edit the ledger; if the loop is abandoned for good, either leave the rows
  `pending` or record the switch in a note row — the guard forbids forged bookkeeping.
- **Working tree is DIRTY with P0.2's in-flight work** (see below). Decide before doing anything
  destructive.

## The preserved P0.2 work — do not throw this away

The blocked worker's output is nearly complete and directly useful to the new approach. Saved
outside the repo at:

```text
~/.pi/sidebar-native-ux-preserved/P0.2-worker-inflight.patch   # 475 lines, sha256 09281720a6edd764…
```

and still present in the working tree (`git diff` reproduces it):

| File | + lines | What it adds |
|---|---:|---|
| `Sources/ContinuumRevived/App/UIProbeGeometry.swift` | 242 | `runSidebarUXChecks`, `makeSidebarProbeHost`, `checkSidebarProbe`, `AgentInboxRowGeometryForQA`, `AgentInboxLabelGeometryForQA`, `inboxLabelGeometryForQA` — a real offscreen probe host that refuses a zero-sized viewport, iterates widths and both appearances, and measures **per-label drawable-vs-needed width** |
| `Sources/ContinuumRevived/App/AgentInboxView.swift` | 140 | `qaMaterializedRowCells`, `qaMaterializedRowCellCount`, `qaRowGeometriesForQA`, `rowVariantsForQA`, and a per-cell `qaAgentID`/`qaVariant`/`qaGeometry` protocol implemented by both the card and slim cells |
| `Sources/ContinuumRevived/App/ContinuumApp.swift` | 12 | `--sidebar-ux-check` flag dispatch |

The worker reported: builds clean, focused semantic and geometry checks pass, Component Lab has
**pre-existing** baseline mismatches, and it changed no baselines. It blocked only on wiring the
matrix leg, which needed `run-matrix.sh` — outside P0.2's fence.

**Recommended first action on resume:** finish that one wiring step (append the leg after the
existing sidebar/agent-tile checks and add the inventory record), verify, and commit it as the
foundation. It is ~5 minutes of work and it gives every later change the gate it needs.

## The new plan shape

One focused session, with subagents delegated per coherent slice rather than per fenced packet.

**Why this is better here:** the expensive part is not typing the code, it is holding the whole
surface in mind at once — the row model, the four probe files, the moved appearance floors, and how
a change at 220 pt interacts with a change to row height. A session can hold that; forty
independently-fenced tickets cannot, which is exactly why P0.1 and P0.2 stalled on fences.

Suggested slices, each a natural subagent task with a real verification command. Order matters:
gates first, so every later change is measurable.

1. **Gates and fixtures** (packets P0.2–P0.4). Finish the probe leg above; add the
   defect-expressing fixture corpus (`title == provider/model`, nil role + nil branch, three-digit
   elapsed, unobserved agent, forty-child fan-out, over-long project name, RTL/combining marks);
   add the 220/280/320 geometry leg and un-pin the 79 pt height assertions. **Expect the first red
   to be real** — the committed baselines already contain a truncated title.
2. **Containment** (P0.5, P1.1–P1.4). Border to zero, resting fill removed, `AgentSurfaceRole`
   interaction ladder with selection quieter than hover, hairline token, focus ring, and
   **re-measure `minimumThemedViews`/`minimumSentineledSlots` in the same change** — removing a
   border drops each row's outline slot from the owner census.
3. **Row anatomy** (P2.1–P2.6). Name owns its line and yields last; measured-fit tiers with the
   `+4` cell inset everywhere; content-derived height; provider glyph instead of a repeated model
   id; one capped elapsed formatter shared with the tile header; slim-variant parity.
4. **Status truth** (P3.1–P3.5). Launch reconciliation sweep with a stated reason; gated read so no
   surface can see pre-sweep state; supervisor snapshot as the single owner; unconfirmed rows with a
   **frozen** clock; one vocabulary across sidebar, chip, header, phone.
5. **Identity** (P4.1–P4.5). One sentinel constant; first-prompt seed inside
   `AgentSupervisor.send(_:to:)`; rename compare-and-swap; child naming by precedence; the one-shot
   generated name last and optional.
6. **Interaction** (P5.1–P5.5). Custom context menu (Dylan asked for this explicitly), filter band
   with a `ChoiceButton` scope control plus search, bulk bar, keyboard traversal and overlay jump
   hints, width/resize/persistence.
7. **Lifecycle and children** (P6.1–P6.6) then a full pass at 220/280/320 in both appearances.

Dylan reviews at the natural seams — after 2, after 4, after 6, and at the end. Those are the same
four checkpoints the loop's supervised gates encoded (P1.5, P3.6, P5.6, P7.1); they are still the
right places to stop, they just no longer need to be packet files.

**Delegation guidance.** Subagents are good at: reading a slice and reporting what is actually
there, writing a self-contained check leg, and adversarially verifying a claim. They are bad at
coordinating a shared 4,200-line file — so give one agent write access to a slice at a time and keep
the sequencing in the session. Read-only exploration can fan out freely.

## What remains authoritative

- **`_DESIGN.md`** — the locked decisions. The guard greps eleven of them by name; they were not
  invalidated by dropping the loop.
- **`plan-sidebar-t3code-study.md`** — five audits of T3 Code at `subagent-obs/05-thread-visibility`
  (`573255c6c`), including the three places T3 Code has our bugs too (ticking "Working" on
  unreachable environments, no turn timeout, an unread lease field) and the one place we can be
  better (freeze the clock when observation is not live).
- **`plan-sidebar-and-state-findings.md`** — our own defects with line numbers, and why the existing
  gates never caught them.
- **`_RUNBOOK.md`** — the verification stance still applies even without the loop: gate at the
  widths that ship, assert drawable width not frames or strings, assert absence structurally,
  materialize offscreen lists before applying content, re-measure floors in the same change, and
  never bless a baseline outside a supervised review.

An exploration worktree of T3 Code's newest sidebar branch is at
`<scratchpad>/t3code-newest` (detached at `573255c6c`); `git worktree remove` it when done. Dylan's
own `t3code` checkout was left on `main`.

## Process rules that still apply

- Quit Dylan's running instance before any app probe, build, or relaunch — shared store and tmux,
  and the boot probe hangs against a live instance.
- Never `swift build` while a matrix run is in flight.
- Baselines only at a supervised review with `swift scripts/check-retina-main.swift` passing; glyph
  drift across untouched surfaces means the wrong display, not a regression.
- Local commits only, never push; Dylan's identity; **no trailers of any kind**; no
  `git reset/clean/stash` on this tree while the P0.2 patch is uncommitted.
- `./scripts/check-sidebar-native-ux-program.sh --check` and
  `./scripts/check-agent-tile-ux-program.sh --check` must both stay green — queue 91's guard pins
  `run-matrix.sh` lines 1–4 exactly.

## Open decisions for Dylan

1. **The P0.2 patch:** commit it as a foundation (recommended), or re-derive it in the new session?
2. **The queue and its ledger:** leave the 39 `pending` rows as a work list (recommended — the guard
   stays green and the packets stay readable), or formally retire the queue with a note?
3. **The loop machinery** (`sidebar-native-ux-{loop,loopctl,prompt}`, the guard): keep committed but
   dormant (recommended — the guard is genuinely useful and P0.1 hardened it), or remove?
4. **Children:** still keep inline nesting with a bounded fan-out per parent, rather than T3 Code's
   hide-and-panel approach? This was the one genuinely open design question from the study.
