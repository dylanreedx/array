# 90-agent-ux — Morning report

Stop reason: **dependency cycle in `_QUEUE.md`** — no ticket is eligible. Needs one owner decision.
Written 2026-07-25T08:55Z by the loop iteration that found nothing to run.

## The deadlock

`_QUEUE.md`'s re-sequencing (2026-07-25, supervisor) moved `P0.7`'s dependency from the blocked
`P0.4` onto `P1.6`, and simultaneously added `P1.10`/`P1.11` to `P1.6`'s dependencies. Those two
edits closed a loop:

```
P0.7 → P1.6 → P1.11 → P1.10 → P1.3 → P1.2 → P1.1 → P0.7
```

Every remaining pending ticket sits inside that loop or downstream of it, so the selection rule
("first ticket not done, not blocked, whose `Depends on` are all done") matches nothing. This is a
structural deadlock, not a stall that clears itself and not a failure of any individual ticket.

The cycle is an artifact of the queue table, **not** of the packets. Packet headers disagree with
the queue at exactly two points:

| ticket | packet header says | `_QUEUE.md` says |
|---|---|---|
| `P1.1-agentui-module` | `Depends on: none` | `P0.7` |
| `P1.6-token-contrast-gate` | `Depends on: P1.3` | `P1.3, P1.10, P1.11` |

## Recommended resolution (owner's call — the loop may not edit `_QUEUE.md` ordering)

Take `P1.1`'s own header as authoritative and drop `P0.7` from its queue row. Rationale: `P1.1`
creates the `AgentUI` module; it has no relationship to retiring the `isBlank` gate. The queue's
`P0.7` entry was phase-linear ordering, not a real edge. That one edit re-opens the whole Phase 1
chain (`P1.1 → P1.2 → P1.3 → P1.4/P1.5 → …`) and leaves `P0.7` correctly waiting on `P1.6`, which
is what the re-sequencing intended: the weak gate is retired only after real token contrast is
enforced *and* adopted.

Do not resolve it by dropping `P1.6` from `P0.7`'s deps — that would retire the `isBlank` gate
before its replacement is enforced, which is the exact hole Phase 0 exists to close.

## State at stop

Phase 0 is complete except for the two tickets that legitimately wait:

| ticket | state | commit |
|---|---|---|
| P0.1-ios-target-in-matrix | done | f61aff0 |
| P0.2-uiprobe-harness | done | 20a311c |
| P0.8-shared-selector-and-wait | done | 1096ba8 |
| P0.10-explicit-model-id | done | 7c3d75d |
| P0.11-matrix-check-count-guard | done | abfdb93 |
| P0.3-geometry-gates | done | 4bda832 (see attribution note in the ledger) |
| P0.5-pixel-probes | done | dbbdc5a |
| P0.6-png-baselines | done | 5187603 |
| P0.9-ui-tour-check | done | af4ad3d |
| P0.4-appearance-contrast-gate | **blocked** | 8d9d1b3 — 4 colour decisions in `P0.4-FINDINGS.md` |
| P0.7-retire-isblank-gate | pending | waits on `P1.6` by design |

## Needs the owner

1. **The queue cycle above** — one edit to `P1.1`'s row.
2. **`P0.4`'s four colour decisions** (`P0.4-FINDINGS.md`): house muted-text colour, light-appearance
   accent variants, appearance-aware card fills vs light text, and whether decorative borders are
   held to 3:1. Phase 1's token values depend on these, so answering them before `P1.2`/`P1.3` run
   avoids re-doing the adoption tickets.

No code changed in this iteration. Working tree carries one unrelated uncommitted supervisor edit to
`_RUNBOOK.md`, left untouched.
