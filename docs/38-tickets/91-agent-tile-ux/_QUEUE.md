# 91-agent-tile-ux — dependency queue

Exactly 50 tickets. The loop selects the first row whose dependencies are `done` and whose own
state is `pending`. `blocked` is never retried automatically. When a supervised row becomes first
eligible, the loop stops and reports it; it must not skip ahead because later visual decisions depend
on that review.

| # | Ticket | Depends on | Execution |
|---:|---|---|---|
| 1 | `P0.1-program-contract.md` | — | autonomous |
| 2 | `P0.2-agent-content-target.md` | P0.1 | autonomous |
| 3 | `P0.3-semantic-tile-tokens.md` | P0.1 | autonomous |
| 4 | `P0.4-transcript-fixture-corpus.md` | P0.2 | autonomous |
| 5 | `P0.5-compatibility-pipeline-harness.md` | P0.4 | autonomous |
| 6 | `P1.1-document-schema.md` | P0.5 | autonomous |
| 7 | `P1.2-stable-node-identity.md` | P1.1 | autonomous |
| 8 | `P1.3-mutation-patch-vocabulary.md` | P1.2 | autonomous |
| 9 | `P1.4-document-reducer.md` | P1.3 | autonomous |
| 10 | `P1.5-runtime-event-projection.md` | P1.4 | autonomous |
| 11 | `P1.6-local-user-notice-nodes.md` | P1.5 | autonomous |
| 12 | `P1.7-unknown-node-forward-compat.md` | P1.6 | autonomous |
| 13 | `P1.8-content-diagnostics.md` | P1.7 | autonomous |
| 14 | `P1.9-card-compatibility-projection.md` | P1.8 | autonomous |
| 15 | `P2.1-markdown-parser-seam.md` | P1.9 | autonomous |
| 16 | `P2.2-inline-markup-runs.md` | P2.1 | autonomous |
| 17 | `P2.3-paragraph-heading-blocks.md` | P2.2 | autonomous |
| 18 | `P2.4-list-quote-rule-blocks.md` | P2.3 | autonomous |
| 19 | `P2.5-fenced-code-blocks.md` | P2.4 | autonomous |
| 20 | `P2.6-link-policy.md` | P2.5 | autonomous |
| 21 | `P2.7-partial-streaming-markdown.md` | P2.6 | autonomous |
| 22 | `P2.8-ast-identity-reconciliation.md` | P2.7 | autonomous |
| 23 | `P2.9-parser-corpus-fuzz-performance.md` | P2.8 | autonomous |
| 24 | `P3.1-renderer-registry.md` | P2.9, P0.3 | autonomous |
| 25 | `P3.2-reusable-block-host.md` | P3.1 | autonomous |
| 26 | `P3.3-assistant-prose-renderer.md` | P3.2 | autonomous |
| 27 | `P3.4-user-prompt-renderer.md` | P3.3 | autonomous |
| 28 | `P3.5-rich-inline-text-renderer.md` | P3.4 | autonomous |
| 29 | `P3.6-code-block-renderer.md` | P3.5 | autonomous |
| 30 | `P3.7-tool-command-renderer.md` | P3.6 | autonomous |
| 31 | `P3.8-plan-diff-renderers.md` | P3.7 | autonomous |
| 32 | `P3.9-interactive-error-unknown-renderers.md` | P3.8 | autonomous |
| 33 | `P3.10-transcript-collection-list.md` | P3.9 | autonomous |
| 34 | `P3.11-incremental-scroll-copy-accessibility.md` | P3.10 | autonomous |
| 35 | `P3.12-transcript-supervised-review.md` | P3.11 | supervised |
| 36 | `P4.1-custom-composer-shell.md` | P3.12 | autonomous |
| 37 | `P4.2-growing-text-layout.md` | P4.1 | autonomous |
| 38 | `P4.3-key-ime-undo-contract.md` | P4.2 | autonomous |
| 39 | `P4.4-per-agent-draft-store.md` | P4.3 | autonomous |
| 40 | `P4.5-prompt-history.md` | P4.4 | autonomous |
| 41 | `P4.6-send-stop-intent-state.md` | P4.5 | autonomous |
| 42 | `P4.7-custom-choice-popover.md` | P4.6, P0.3 | autonomous |
| 43 | `P4.8-model-effort-controls.md` | P4.7 | autonomous |
| 44 | `P4.9-completion-query-providers.md` | P4.8 | autonomous |
| 45 | `P4.10-composer-supervised-review.md` | P4.9 | supervised |
| 46 | `P5.1-agent-tile-header-shell.md` | P4.10 | autonomous |
| 47 | `P5.2-capability-driven-turn-states.md` | P5.1 | autonomous |
| 48 | `P5.3-provider-current-work-projection.md` | P5.2 | autonomous |
| 49 | `P5.4-live-tile-migration.md` | P5.2 | autonomous |
| 50 | `P5.5-final-supervised-acceptance.md` | P5.4 | supervised |
