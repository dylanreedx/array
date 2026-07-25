# 90-agent-ux — Overnight-executable set

Dependency-ordered. The loop takes the first ticket that is (a) not `done`, (b) not `blocked`, and
(c) whose `Depends on` are all `done`. **Never re-attempt a `blocked` ticket** — a block means it
failed honest verification; it needs a human, not a retry.

All Phase 0 tickets are tagged `autonomous`.

## Overnight-executable set

| # | Ticket | Depends on |
|---|---|---|
| 1 | `P0.1-ios-target-in-matrix.md` | — |
| 2 | `P0.2-uiprobe-harness.md` | — |
| 3 | `P0.8-shared-selector-and-wait.md` | — |
| 4 | `P0.10-explicit-model-id.md` | — |
| 5 | `P0.11-matrix-check-count-guard.md` | — |
| 6 | `P0.3-geometry-gates.md` | P0.2 |
| 7 | `P0.4-appearance-contrast-gate.md` | P0.2 |
| 8 | `P0.5-pixel-probes.md` | P0.2, P0.3 |
| 9 | `P0.6-png-baselines.md` | P0.2 |
| 10 | `P0.9-ui-tour-check.md` | P0.2 |
| 11 | `P0.7-retire-isblank-gate.md` | P0.3, P0.4, P0.5, P0.6 |

Phases 1–9 are authored during the run and appended here as they land. Full backlog shape lives in
the session plan; see `_RUNBOOK.md` for the operating contract.
