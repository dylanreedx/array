# 90-agent-ux — Overnight-executable set

Dependency-ordered. The loop takes the first ticket that is (a) not `done`, (b) not `blocked`, and
(c) whose `Depends on` are all `done`. **Never re-attempt a `blocked` ticket** — a block means it
failed honest verification; it needs a human, not a retry.

All Phase 0 tickets are tagged `autonomous`.

**Rows `48a` / `48b` are two Phase 6 tickets deliberately inserted OUT OF PHASE ORDER**, by the
owner's explicit instruction on 2026-07-26, after they saw the built app and reported the transcript
presentation and the missing per-agent model/effort control. Both are corrections of defects the
owner named on sight, both depend only on work that is already `done`, and both are self-contained
(no Phase 4 lifecycle, no Phase 5 RPC). Each packet carries a `## Why this is out of order` section.
Take them in order, then resume at row 49. **Do not pull any further Phase 6 ticket forward** — the
rest of Phase 6 (`P6.2`–`P6.12`) stays behind Phase 4 and Phase 5 where it can be wired for real.

**Row `48c` (`P3.15-wire-destructive-row-actions`) is the HIGHEST-PRIORITY ticket in this queue.**
The owner cannot delete an agent — at all, by any route. `P2A.7` landed restore-on-relaunch, so every
record on disk returns every launch, and nothing was ever wired to remove one: the shipped app assigns
neither `onRowAction` nor `onBulkAction`, so all nine row-menu items are greyed and the bulk bar's menu
never appears. `AgentSupervisor.archive(_:)` already implements the whole deletion correctly and has no
caller. This is a hole in the plan, not a missing phase — `P4.10` only governs what the selection does
AFTER an action performs. Take `48c` as soon as `48b` commits.

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
| 12 | `P1.1-agentui-module.md` | — |
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
| 48a | `P6.0-prose-is-not-a-card.md` | P1.11 |
| 48b | `P6.1-per-agent-model-effort.md` | P2A.3, P0.10 |
| 48c | `P3.15-wire-destructive-row-actions.md` | P3.12, P2A.7, P4.1 |
| 48d | `P3.16-inbox-lists-agents-only.md` | P2B.4, P3.1, P3.8 |
| 49 | `P2D.5-child-rollup.md` | P2D.4, P4.2 |
| 50 | `P2D.6-fan-out.md` | P2D.5 |
| 51 | `P3.1-inbox-row-model.md` | P2B.3 |
| 52 | `P3.2-five-states-three-colours.md` | P3.1, P1.8 |
| 53 | `P3.3-attention-axis.md` | P3.2 |
| 54 | `P3.4-frozen-sort.md` | P3.1 |
| 55 | `P3.5-in-flight-fade.md` | P3.2, P3.3 |
| 56 | `P3.6-inbox-list-view.md` | P3.4, P3.5, P1.10 |
| 57 | `P3.7-slim-rows.md` | P3.6 |
| 58 | `P3.8-scope-dropdown.md` | P3.6 |
| 59 | `P3.9-reveal-on-click.md` | P3.6, P2A.5 |
| 60 | `P3.10-jump-shortcuts.md` | P3.6 |
| 61 | `P3.11-multi-select-bulk.md` | P3.6 |
| 62 | `P3.12-row-context-menu.md` | P3.11 |
| 63 | `P3.13-inline-rename.md` | P3.6 |
| 64 | `P3.14-preserve-workspace-management.md` | P3.8 |
| 65 | `P4.1-lifecycle-state.md` | P2A.2, P3.1 |
| 66 | `P4.2-effective-settled.md` | P4.1 |
| 67 | `P4.3-auto-settle-inactivity.md` | P4.2 |
| 68 | `P4.4-auto-unsettle.md` | P4.2 |
| 69 | `P4.5-snooze-presets.md` | P4.1 |
| 70 | `P4.6-snooze-raised-hand.md` | P4.5, P4.2 |
| 71 | `P4.7-snoozed-shelf.md` | P4.6, P3.7 |
| 72 | `P4.8-settled-tail-paging.md` | P4.7 |
| 73 | `P4.9-reading-is-free.md` | P4.4, P3.9 |
| 74 | `P4.10-post-action-advance.md` | P4.2, P3.11 |
| 75 | `P4.11-undo-toast.md` | P4.10 |
| 76 | `P4.12-crossfade-in-place.md` | P3.7, P4.7 |
| 77 | `P4.13-precedence-matrix.md` | P4.2, P4.3, P4.4, P4.6, P2D.5 |
| 78 | `P5.1-pi-rpc-client.md` | P2A.3 |
| 79 | `P5.2-persistent-session.md` | P5.1 |
| 80 | `P5.3-abort-stop-button.md` | P5.2 |
| 81 | `P5.4-set-model.md` | P5.2 |
| 82 | `P5.5-set-thinking-level.md` | P5.4 |
| 83 | `P5.6-compact.md` | P5.2 |
| 84 | `P5.7-steer-follow-up.md` | P5.2 |
| 85 | `P5.8-session-stats-cost.md` | P5.2 |
| 86 | `P5.9-real-approvals.md` | P5.2 |
| 87 | `P5.10-agent-settled-signal.md` | P5.2 |

Phases 0, 1, 2A, 2B and 2C are authored. 2C (worktrees) MUST precede 2D (orchestration): parallel agents without isolation corrupt each other. Phases 2D, 3, 4 and 5 are authored. Phases 6–9 are authored during the run.

Phase 5 note: live rpc behaviour cannot be verified headlessly, so every Phase-5 packet specifies a deterministic fixture/fake-client check for the matrix PLUS a separate supervised manual step. A worker must not claim live coverage from the matrix.

Note: P2D.4/P2D.5 depend on Phase 3 (inbox rows) and Phase 4 (blocker precedence), so the loop will
correctly skip them until those land — that was intended, not a stall. **SUPERSEDED 2026-07-26: both
have landed.** `P2D.4` is `done`, and `P4.2-effective-settled` is `done`, so **`P2D.5-child-rollup`
(row 49) is ELIGIBLE NOW and must not be skipped again.** Take it in queue order. It is not optional
polish: until it lands, a folded orchestrator silently conceals a child's approval request, because
`P2D.4` ruled that nothing folds a group on your behalf and A PUSH DOES NOT UNFOLD. The only
mitigation today is the app-wide dock badge, which counts needs-attention agents but cannot say which
row to open. and appended here as they land. Full backlog shape lives in
the session plan; see `_RUNBOOK.md` for the operating contract.

## Re-sequenced 2026-07-25 (supervisor)

`P0.4` is **blocked by design, not by failure**: the gate is built and correct, and is red on 177
real pairs because the app's colours are broken until Phase 1. My packet was mis-sequenced — it
asked for a green gate before the tokens existed. Resolution: `P0.4`'s enablement moves into
`P1.6` (which now also depends on the adoption tickets `P1.10`/`P1.11`), and `P0.7` now waits on
`P1.6` instead of `P0.4`. `P0.5`, `P0.6` and `P0.9` are unaffected and proceed. The four colour
decisions are ruled at the end of `P1.3`.

## Cycle fix 2026-07-25T08:05Z (supervisor)

The loop correctly halted with `dependencies-blocked`: my 06:50 re-sequencing pointed `P0.7` at
`P1.6` while `P1.1` still pointed at `P0.7`, closing
`P0.7→P1.6→P1.11→P1.10→P1.3→P1.2→P1.1→P0.7`.

Broken at the wrong link: **`P1.1` no longer depends on `P0.7`.** Standing up the AgentUI module
and moving StatusChip needs nothing from retiring the `isBlank` gate — that dependency was lazy
"previous phase" sequencing on my part. `P0.7` keeps waiting on `P1.6` (retire the weak gate only
once contrast + baselines are real), which is the ordering that matters.
