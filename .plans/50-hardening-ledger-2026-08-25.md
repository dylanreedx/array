# Hardening ledger — 2026-08-25 (continues `.plans/49`)

Branch `array/transcript-ux`. Every entry below is red-then-green with the
witness teeth-verified by reverting only the fix.

## M1 — the three defects introduced yesterday

| # | defect | fix | witness |
|---|---|---|---|
| 1.1 | a live-tailed pi child said its whole answer TWICE | recovery decided per MESSAGE (`streamedTextInCurrentMessage`), not per reader | `PiDelegateSupplyChecks` §2b over a new PRE-compaction fixture; RED at 248 chars for a 124-char answer |
| 1.2 | "Worked for Ns" measured TIME-TO-FIRST-TOKEN | `AgentEntry.finishedAt`, stamped by `finishEntry` only | `--transcript-rhythm-check` (RED said `45s` for a 2m turn) + `AgentEntryTimestampChecks` §7 for the producer |
| 1.3 | the gyro spun after the agent was done | `TurnLiveness`, moved by the event stream, with two exits | `--agent-first-paint-check`, `statusIsActive: true` on purpose |

## M2 — the perf gate drove a seam production never calls

`apply(document:patch:)` has **zero** production callers. A streaming tile goes
through `enqueue()` with an EMPTY patch → `applyCoalesced` → full walk per token.

- Gate re-pointed at the production seam: **93.149 ms/delta at 10,000 rows**,
  against the 5.556 ms it had been reporting.
- Fixture was uniformly `.assistant`, so turn folding was unreachable by
  construction. Alternates roles now.
- Fix: the reducer's own patch is accumulated (`TouchedNodes`), drained by the
  tile, unioned across coalescing in `enqueue`.
- **93.149 ms → 5.920 ms**, 0 full flattens, 0 history scans, rows checked
  against a from-scratch walk.
- New leg drives the TILE, not the list. Its first draft passed with the fix
  reverted (markup is wall-clock debounced, so nothing presented) — it now
  carries a positive control on presentations.

## M3 — per-frame and per-apply walks

| site | was | now |
|---|---|---|
| turn-chrome boundary hash in `layout()` | O(all rows) **per display cycle** | maintained on the full walk only |
| turn-start lookups | `first(where:)`, one per `mouseMoved` | dictionary |

| settled cluster summaries | recomputed per apply, O(members + turn length) each | memoised, cleared by the projection and by tool-detail arrival |

`transcript-delta.worstDeltaDuration` sits at **5.7-6.0 ms** over three runs
(10,000 rows). A single 4.736 ms sample was measured after the hover fix and is
**not** the honest number — the scenario neither hovers nor renders cluster
headers, so two of the three fixes above are invisible to it. Their value is
real but unwitnessed by THIS leg; the display-cycle fix has its own witness in
`--transcript-rhythm-check`.

**Still linear**: 0.3 ms at 10 rows against ~5.8 ms at 10,000. Remaining
per-apply O(rows) suspects, none yet fixed: `boundarySignature` before
`prepare()`'s fast-path guard, `measurementCache.invalidate` filtering an
unbounded never-evicted height cache, and `Set(toolDetailIDByBlockID.values)`.

## Row/glyph over-reach (from yesterday)

- `echoNamesFile` dropped BOTH lines for same-basename files, and swallowed a
  file named `test` under "Ran npm test". Now single-file only, and only for
  labels whose title is built around a basename.
- Glyph needles matched `cat` inside `locate`, and any name containing `agent`
  or `task` rendered as a subagent. Word-boundary matching; bare nouns must be
  the whole name.

## Verified, no longer assumed

pi 0.84.1 `--tools` is a pure allow-set filter over the live registry
(`agent-session.js:1945`, `:1996-2001`). Live A/B with a bogus name: exit 0
both, zero bytes stderr both. **T5.2 stays.**

## Matrix, run 1 (this branch, `CONTINUUM_SKIP_UI_BASELINES=1`)

**181 legs run. 6 expected KNOWN-RED. 1 regression:
`--browser-inspector-network-lite-check`.**

It **passes in isolation** on a rerun. Two agents were compiling Swift
concurrently during the run, and this is a timing-sensitive WebKit leg, so the
working theory is contention rather than a real regression — nothing in this
branch touches the browser inspector. **Owed: one clean matrix run on a quiet
machine before this branch is called green.**

Note the shape of the trap, again: the shell reported **exit 0** while the
report said `Matrix FAILED`. Judge by the summary, never the exit code.

## A `.plans/49` claim that did NOT reproduce

`.plans/49` §2.6 lists `measurementCache.invalidate(id:)` filtering an
**"unbounded, never-evicted"** height cache, on the reasoning that the cache key
includes the block revision and a streaming block's revision advances per chunk
— so one permanent entry per token.

**Measured instead:** 150 chunks streamed into one answer through the real tile
grew the cache by **1 entry** (46 total), *with revision-eviction deliberately
disabled*. So the cache is not growing per token on this path, and
`invalidate(id:)` is filtering tens of entries, not thousands.

An index and a revision-eviction were written and then **reverted**: with the
premise unreproduced, the eviction has no demonstrable benefit and the index
optimises a walk over ~46 items. Neither could be given a witness that failed
without it, and an unwitnessed change to a cache is exactly what this project's
rules exist to refuse.

Recorded rather than silently dropped, because §2.6's other entries were derived
the same way and should be measured before they are trusted.

## M4 — polish, debt, and the observed-run subsystem

| what | before | after |
|---|---|---|
| short bash/tool output | clipped: a legacy scroller takes ~15pt from a 33pt pane | overlay scrollers, vertical decided per layout, wheel forwarded |
| "Thought" body | provider's whole-paragraph bold under our own title; body 60pt left of it; 2pt above vs 8pt between | heading flattened (phrase bold kept), body on the title's x, gaps equal |
| delegated-run cursor | line index into a file whose inode changes | inode-keyed; rewrite closes the binding |
| a quiet dead run | watcher polled for the life of the app, tile stuck mid-turn | pid liveness sweep, independent of the directory |
| a capped-refused child | buffered events forever | never tailed; a not-yet-adopted child still is |
| watcher filtering | via the records map, torn down mid-adoption-race | binding carries its parent |
| `events.jsonl` read | total, every poll: ~19ms/MB twice a second | byte cursor while inode and size hold; stops at the last `\n` |
| `check-root-docs.sh` | KNOWN-RED, asking the wrong file | GREEN, retired from `MATRIX_KNOWN_RED` (9 → 8) |

## Matrix, runs 2 and 3

Run 2 (quiet machine): **181 legs, 5 expected KNOWN-RED** (root-docs retired),
and run 1's `--browser-inspector-network-lite-check` flake **did not recur** —
confirming contention, not regression. One NEW failure,
`--agent-local-file-link-check`, and it was a real catch: two assertions in it
encoded the pre-world-space overlay design.

- One demanded 65 tile visits per CAMERA step — it pinned recomputation as the
  mechanism, so it now asserts the outcome (zero cost, connector still correct)
  plus a separate tile-move invalidation.
- One is a PIXEL test comparing a corridor from the route's own points against
  canvas pixels. Those coincided only while the overlay was viewport-sized. It
  now converts, and finds the connector's pixels — which is also the evidence
  that the redesign draws what it always drew.

**The zoom agent's own regression sweep ran `--relationship-geometry-check` and
missed this leg.** Endpoint math passed while a pixel test failed; only the full
matrix found it. That is the argument for the milestone gate, not the targeted one.

## Matrix, run 3 — **PASSED**

**181 legs, 4 expected KNOWN-RED, no real failures.**

The run also reported one KNOWN-RED that PASSED and told us to remove it:
`--perf-budget-gesture-transition-check`. **Re-judged instead of obeyed.** Five
consecutive runs on the same quiet machine: **7.878 / 7.737 / 7.817 / 8.041 /
8.296 ms** against a budget of **8.300**. It clears by four MICROseconds at the
top of its own spread — a coin flip, not a fixed leg. Removing it would turn the
gate red on any run that is not idle. The rationale is now recorded at the entry
so this is not re-litigated; it leaves the list when the measurement has
headroom.

That closes the "`--perf-budget-gesture-transition-check` needs re-judging on a
quiet machine" loose end from `.plans/49` §7 — verdict: **still KNOWN-RED, and
now for a measured reason instead of an assumed one.**

## What remains open

- **Two pixel baselines** (`tiles.managedAgent-560x560-{aqua,darkAqua}.png`)
  still await Dylan's supervised Retina-Main bless. `--component-lab-check` and
  `--ui-baseline-check` are both KNOWN-RED **and** skipped by
  `CONTINUUM_SKIP_UI_BASELINES=1`, which every run here used — so
  `ComponentLab.runTranscriptReviewCheck`'s row floors have still never executed
  in a gating run (`.plans/49` §6.2). **This is the largest remaining hole**, and
  it is the reason Dylan's eyes keep finding what a leg should have.
- `.plans/49` §3 (honesty: cap wording, steering advertised-then-refused, dead
  buttons), §4 (subagent chip affordance, open-file-as-tile), and §6.1's stale
  ledger tables are untouched.
- §2.6's remaining O(rows) suspects are unmeasured; one of its entries already
  failed to reproduce (above), so measure before trusting.

## Matrix, run 4 — five terminal legs red, and it is the MACHINE, not the branch

Run 4 (2026-08-26, ~01:00) reported 5 regressions, all terminal:
`--terminal-tmux-live-integration-check`, `--terminal-theme-fidelity-check`,
`--terminal-snapshot-tier-check`, `--terminal-fills-tile-check`,
`--session-resume-check`.

**Every failure is the same failure**: *"timed out waiting for initial real
terminal surface"*, *"spawned terminal surface missing"*, *"terminal surface
missing"*, *"check timed out"*. A surface that never came up.

Evidence it is not this branch:

- **Two of the five run with tmux explicitly DISABLED**
  (`-continuum.terminal.tmux.enabled NO`), so it is not the tmux socket.
- **Run 3 was green on every one of them**, and the only `Sources/` change since
  is `0f39b85e`, which is **comment-only** — verified by filtering the diff to
  non-`///` lines and getting nothing back.
- `ThirdParty/GhosttyKit.xcframework` resolves (it is a symlink into iCloud
  Drive; it was checked and lists its slices).
- `pmset -g assertions` reports `PreventUserIdleDisplaySleep 0` at ~1am, i.e.
  **nothing is holding the display awake**. These legs bring up REAL terminal
  surfaces, which is display-dependent work.

**Diagnosis: a sleeping display, not a regression.** This is the
`three-failures-one-costume` pattern again — a timeout and a crash and an
environment fault all read as "it broke".

**The branch's authoritative green is run 3** (181 legs, 4 expected KNOWN-RED),
which contained every behavioural change in this program. Everything committed
after it is documentation plus one comment.

**Owed: one terminal-leg run with the display awake**, which needs Dylan's
machine in a normal state. Do not "fix" anything here first.
