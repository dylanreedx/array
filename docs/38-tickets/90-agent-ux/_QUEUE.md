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
| 11 | `P0.7-retire-isblank-gate.md` | P0.3, P0.5, P0.6, **P1.6** |
| 12 | `P1.1-agentui-module.md` | P0.7 |
| 13 | `P1.2-tokencolor-light-dark.md` | P1.1 |
| 14 | `P1.4-type-scale.md` | P1.1 |
| 15 | `P1.5-spacing-radius-scale.md` | P1.1 |
| 16 | `P1.3-surface-text-border-tokens.md` | P1.2 |
| 17 | `P1.6-token-contrast-gate.md` | P1.3, P1.10, P1.11 |
| 18 | `P1.7-raw-color-lint.md` | P1.3 |
| 19 | `P1.8-one-status-presenter.md` | P1.3 |
| 20 | `P1.9-live-appearance-switching.md` | P1.3 |
| 21 | `P1.10-adopt-tokens-tile.md` | P1.3, P1.4, P1.5, P1.9 |
| 22 | `P1.11-adopt-tokens-chrome.md` | P1.10 |
| 23 | `P1.12-ios-consumes-tokens.md` | P1.3, P1.8 |
| 24 | `P2A.1-agent-record.md` | P1.12 |
| 25 | `P2A.2-agent-store.md` | P2A.1 |
| 26 | `P2A.3-agent-supervisor.md` | P2A.2 |
| 27 | `P2A.4-tile-as-subscriber.md` | P2A.3 |
| 28 | `P2A.5-attach-detach-lifecycle.md` | P2A.4 |
| 29 | `P2A.6-headless-agents.md` | P2A.5 |
| 30 | `P2A.7-restore-on-relaunch.md` | P2A.6 |
| 31 | `P2A.8-sync-key-migration.md` | P2A.7 |
| 32 | `P2B.1-agent-inventory.md` | P2A.8 |
| 33 | `P2B.2-cross-project-walk.md` | P2B.1 |
| 34 | `P2B.3-row-context-join.md` | P2B.2 |
| 35 | `P2B.4-feed-all-consumers.md` | P2B.3 |
| 36 | `P2B.5-drop-terminal-filters.md` | P2B.4 |
| 37 | `P2B.6-stop-badge-clobbering.md` | P2B.5 |
| 38 | `P2B.7-incremental-refresh.md` | P2B.4 |
| 39 | `P2B.8-observer-independence.md` | P2B.2 |
| 40 | `P2C.1-worktree-manager.md` | P2B.8 |
| 41 | `P2C.2-isolated-spawn.md` | P2C.1 |
| 42 | `P2C.3-worktree-cleanup.md` | P2C.2 |
| 43 | `P2C.4-branch-on-rows.md` | P2C.3 |
| 44 | `P2C.5-per-agent-diff.md` | P2C.4 |
| 45 | `P2D.1-spawn-agent-extension.md` | P2C.5 |
| 46 | `P2D.2-detect-spawn-tool-call.md` | P2D.1 |
| 47 | `P2D.3-role-registry.md` | P2D.2 |
| 48 | `P2D.4-parent-child-nesting.md` | P2D.3, P3.6 |
| 49 | `P2D.5-child-rollup.md` | P2D.4, P4.2 |
| 50 | `P2D.6-fan-out.md` | P2D.5 |

Phases 0, 1, 2A, 2B and 2C are authored. 2C (worktrees) MUST precede 2D (orchestration): parallel agents without isolation corrupt each other. Phase 2D is authored. Phases 3–9 are authored during the run.

Note: P2D.4/P2D.5 depend on Phase 3 (inbox rows) and Phase 4 (blocker precedence), so the loop will correctly skip them until those land — that is intended, not a stall. and appended here as they land. Full backlog shape lives in
the session plan; see `_RUNBOOK.md` for the operating contract.

## Re-sequenced 2026-07-25 (supervisor)

`P0.4` is **blocked by design, not by failure**: the gate is built and correct, and is red on 177
real pairs because the app's colours are broken until Phase 1. My packet was mis-sequenced — it
asked for a green gate before the tokens existed. Resolution: `P0.4`'s enablement moves into
`P1.6` (which now also depends on the adoption tickets `P1.10`/`P1.11`), and `P0.7` now waits on
`P1.6` instead of `P0.4`. `P0.5`, `P0.6` and `P0.9` are unaffected and proceed. The four colour
decisions are ruled at the end of `P1.3`.
