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

`transcript-delta.worstDeltaDuration`: 5.970 → **4.736 ms**.

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
