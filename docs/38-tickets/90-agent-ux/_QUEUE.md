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
| 12 | `P1.1-agentui-module.md` | P0.7 |
| 13 | `P1.2-tokencolor-light-dark.md` | P1.1 |
| 14 | `P1.4-type-scale.md` | P1.1 |
| 15 | `P1.5-spacing-radius-scale.md` | P1.1 |
| 16 | `P1.3-surface-text-border-tokens.md` | P1.2 |
| 17 | `P1.6-token-contrast-gate.md` | P1.3 |
| 18 | `P1.7-raw-color-lint.md` | P1.3 |
| 19 | `P1.8-one-status-presenter.md` | P1.3 |
| 20 | `P1.9-live-appearance-switching.md` | P1.3 |
| 21 | `P1.10-adopt-tokens-tile.md` | P1.3, P1.4, P1.5, P1.9 |
| 22 | `P1.11-adopt-tokens-chrome.md` | P1.10 |
| 23 | `P1.12-ios-consumes-tokens.md` | P1.3, P1.8 |

Phase 1 is authored (tokens, light+dark). Phases 2–9 are authored during the run and appended here as they land. Full backlog shape lives in
the session plan; see `_RUNBOOK.md` for the operating contract.
