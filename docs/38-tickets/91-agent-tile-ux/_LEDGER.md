# 91-agent-tile-ux — execution ledger

## heartbeat

last-touch 2026-07-28T04:48:16Z · ticket P0.1-program-contract.md · attempt 1 recovery · pid — · status done

## states

`pending` · `in-progress` · `done` · `blocked`

| Ticket | State | Commit | Updated | Note |
|---|---|---|---|---|
| `P0.1-program-contract.md` | done | this commit | 2026-07-28T04:48:16Z | Recovered the worker's preserved patch after upgrading Codex CLI 0.135.0 → 0.145.0. The guard now cross-validates the fixed packet header, exact dependency grammar/order/uniqueness, ledger state metadata with real BSD-date UTC validation, 50 packet/ledger rows, three supervised gates, and a fail-fast script-relative matrix invocation locked at executable line 4; 25 isolated negative mutations must all go red while the live program remains untouched. Negative witness from the worker and recovery: deleting forged-pending protection failed; independent Codex review then found and drove fixes for misleading header text, regex/trailing/duplicate dependencies, swallowed/disabled matrix calls, malformed done metadata, and invalid calendar timestamps. Final `./scripts/check-agent-tile-ux-program.sh`, `swift build`, matrix inventory, and full headless `run-matrix.sh` passed; matrix artifact `qa-runs/20260728T044806Z/app-bundle/manifest.json`. Codex 0.145 final review: APPROVE. |
| `P0.2-agent-content-target.md` | pending | — | — | — |
| `P0.3-semantic-tile-tokens.md` | pending | — | — | — |
| `P0.4-transcript-fixture-corpus.md` | pending | — | — | — |
| `P0.5-compatibility-pipeline-harness.md` | pending | — | — | — |
| `P1.1-document-schema.md` | pending | — | — | — |
| `P1.2-stable-node-identity.md` | pending | — | — | — |
| `P1.3-mutation-patch-vocabulary.md` | pending | — | — | — |
| `P1.4-document-reducer.md` | pending | — | — | — |
| `P1.5-runtime-event-projection.md` | pending | — | — | — |
| `P1.6-local-user-notice-nodes.md` | pending | — | — | — |
| `P1.7-unknown-node-forward-compat.md` | pending | — | — | — |
| `P1.8-content-diagnostics.md` | pending | — | — | — |
| `P1.9-card-compatibility-projection.md` | pending | — | — | — |
| `P2.1-markdown-parser-seam.md` | pending | — | — | — |
| `P2.2-inline-markup-runs.md` | pending | — | — | — |
| `P2.3-paragraph-heading-blocks.md` | pending | — | — | — |
| `P2.4-list-quote-rule-blocks.md` | pending | — | — | — |
| `P2.5-fenced-code-blocks.md` | pending | — | — | — |
| `P2.6-link-policy.md` | pending | — | — | — |
| `P2.7-partial-streaming-markdown.md` | pending | — | — | — |
| `P2.8-ast-identity-reconciliation.md` | pending | — | — | — |
| `P2.9-parser-corpus-fuzz-performance.md` | pending | — | — | — |
| `P3.1-renderer-registry.md` | pending | — | — | — |
| `P3.2-reusable-block-host.md` | pending | — | — | — |
| `P3.3-assistant-prose-renderer.md` | pending | — | — | — |
| `P3.4-user-prompt-renderer.md` | pending | — | — | — |
| `P3.5-rich-inline-text-renderer.md` | pending | — | — | — |
| `P3.6-code-block-renderer.md` | pending | — | — | — |
| `P3.7-tool-command-renderer.md` | pending | — | — | — |
| `P3.8-plan-diff-renderers.md` | pending | — | — | — |
| `P3.9-interactive-error-unknown-renderers.md` | pending | — | — | — |
| `P3.10-transcript-collection-list.md` | pending | — | — | — |
| `P3.11-incremental-scroll-copy-accessibility.md` | pending | — | — | — |
| `P3.12-transcript-supervised-review.md` | pending | — | — | — |
| `P4.1-custom-composer-shell.md` | pending | — | — | — |
| `P4.2-growing-text-layout.md` | pending | — | — | — |
| `P4.3-key-ime-undo-contract.md` | pending | — | — | — |
| `P4.4-per-agent-draft-store.md` | pending | — | — | — |
| `P4.5-prompt-history.md` | pending | — | — | — |
| `P4.6-send-stop-intent-state.md` | pending | — | — | — |
| `P4.7-custom-choice-popover.md` | pending | — | — | — |
| `P4.8-model-effort-controls.md` | pending | — | — | — |
| `P4.9-completion-query-providers.md` | pending | — | — | — |
| `P4.10-composer-supervised-review.md` | pending | — | — | — |
| `P5.1-agent-tile-header-shell.md` | pending | — | — | — |
| `P5.2-capability-driven-turn-states.md` | pending | — | — | — |
| `P5.3-pending-action-dock.md` | pending | — | — | — |
| `P5.4-live-tile-migration.md` | pending | — | — | — |
| `P5.5-final-supervised-acceptance.md` | pending | — | — | — |
