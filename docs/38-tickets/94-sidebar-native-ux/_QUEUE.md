# 94-sidebar-native-ux — dependency queue

Exactly 40 tickets. The loop selects the first row whose dependencies are `done` and whose own
state is `pending`. `blocked` is never retried automatically. When a supervised row becomes first
eligible, the loop stops and reports it; it must not skip ahead, because every later density,
naming, and interaction decision depends on the review before it.

| # | Ticket | Depends on | Execution |
|---:|---|---|---|
| 1 | `P0.1-program-contract.md` | — | autonomous |
| 2 | `P0.2-sidebar-check-seam.md` | P0.1 | autonomous |
| 3 | `P0.3-row-fixture-corpus.md` | P0.2 | autonomous |
| 4 | `P0.4-inbox-geometry-gate.md` | P0.3 | autonomous |
| 5 | `P0.5-row-token-vocabulary.md` | P0.1 | autonomous |
| 6 | `P1.1-remove-row-borders.md` | P0.4, P0.5 | autonomous |
| 7 | `P1.2-interaction-fill-ladder.md` | P1.1 | autonomous |
| 8 | `P1.3-header-shelf-hairlines.md` | P1.2 | autonomous |
| 9 | `P1.4-focus-ring-and-floors.md` | P1.3 | autonomous |
| 10 | `P1.5-containment-supervised-review.md` | P1.4 | supervised |
| 11 | `P2.1-title-line-ownership.md` | P1.5 | autonomous |
| 12 | `P2.2-measured-fit-tiers.md` | P2.1 | autonomous |
| 13 | `P2.3-content-derived-row-height.md` | P2.2 | autonomous |
| 14 | `P2.4-provider-glyph-meta-line.md` | P2.3 | autonomous |
| 15 | `P2.5-elapsed-formatter-column.md` | P2.4 | autonomous |
| 16 | `P2.6-slim-variant-parity.md` | P2.5 | autonomous |
| 17 | `P3.1-launch-reconciliation-sweep.md` | P0.3 | autonomous |
| 18 | `P3.2-gated-snapshot-read.md` | P3.1 | autonomous |
| 19 | `P3.3-single-status-owner.md` | P3.2 | autonomous |
| 20 | `P3.4-unconfirmed-frozen-clock.md` | P3.3 | autonomous |
| 21 | `P3.5-status-vocabulary-unification.md` | P3.4 | autonomous |
| 22 | `P3.6-status-supervised-review.md` | P3.5, P2.6 | supervised |
| 23 | `P4.1-agent-name-sentinel.md` | P3.6 | autonomous |
| 24 | `P4.2-first-prompt-name-seed.md` | P4.1 | autonomous |
| 25 | `P4.3-rename-guard-hardening.md` | P4.2 | autonomous |
| 26 | `P4.4-derived-child-naming.md` | P4.3 | autonomous |
| 27 | `P4.5-generated-name-oneshot.md` | P4.4 | autonomous |
| 28 | `P5.1-custom-row-context-menu.md` | P4.3 | autonomous |
| 29 | `P5.2-filter-band-scope-search.md` | P5.1 | autonomous |
| 30 | `P5.3-custom-bulk-action-bar.md` | P5.2 | autonomous |
| 31 | `P5.4-keyboard-traversal-jump-hints.md` | P5.3 | autonomous |
| 32 | `P5.5-width-resize-persistence.md` | P5.4 | autonomous |
| 33 | `P5.6-interaction-supervised-review.md` | P5.5, P4.5 | supervised |
| 34 | `P6.1-lifecycle-pure-derivation.md` | P5.6 | autonomous |
| 35 | `P6.2-auto-settle-window.md` | P6.1 | autonomous |
| 36 | `P6.3-snooze-derived-wake.md` | P6.2 | autonomous |
| 37 | `P6.4-attention-read-watermark.md` | P6.3 | autonomous |
| 38 | `P6.5-child-fanout-attention-rollup.md` | P6.4 | autonomous |
| 39 | `P6.6-accessibility-motion-sweep.md` | P6.5 | autonomous |
| 40 | `P7.1-final-supervised-acceptance.md` | P6.6 | supervised |
