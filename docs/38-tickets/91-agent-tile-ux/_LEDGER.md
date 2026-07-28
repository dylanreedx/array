# 91-agent-tile-ux — execution ledger

## heartbeat

last-touch 2026-07-28T04:12:00Z · ticket P0.1-program-contract.md · attempt 1 · pid 25627 · status blocked-review-provider

## states

`pending` · `in-progress` · `done` · `blocked`

| Ticket | State | Commit | Updated | Note |
|---|---|---|---|---|
| `P0.1-program-contract.md` | blocked | — | 2026-07-28T04:12:00Z | Implementation complete and green, but the independent review provider is down, so nothing was committed. `codex exec` rejects every model this account can reach: configured `gpt-5.6-sol` → 400 "requires a newer version of Codex"; `gpt-5.6`, `gpt-5.6-codex`, `gpt-5.5-codex`, `gpt-5.2-codex`, `gpt-5.1-codex`, `gpt-5` → 400 "not supported when using Codex with a ChatGPT account". `codex login status` = logged in; `codex doctor` = auth configured, current 0.135.0, 0.145.0 available. Auth is fine; the CLI is stale, which is a supervisor-side precondition, not an implementation failure. Per the runbook the missing reviewer fails closed, so the check-script work was reverted from the tree and preserved as a patch outside the checkout at `~/.pi/agent-tile-ux-runs/continuum-overnight/run-20260727T233225/preserved/P0.1-check-script.patch` (377 lines) with provider evidence beside it. That work was verified before revert: `./scripts/check-agent-tile-ux-program.sh` exit 0 with `self-test: ok (14 negative cases red, live program untouched)`; `swift build` exit 0; `CONTINUUM_SKIP_SURFACE_CHECKS=1 ./scripts/run-matrix.sh` exit 0 (Matrix passed, no inventory growth, no leg removed); program dir sha before/after self-test identical (`bc8184b6…`). Negative witness: deleting the `is pending but records commit` assertion made the run go red with `case 'forged commit on a pending row' passed the check but must fail` / `1 of 14 case(s) did not go red as required`, exit 1; restored byte-identical from a /tmp copy. Recovery: upgrade codex (`npm i -g @openai/codex@latest`), `git apply` the preserved patch, re-run the review, then set this row `pending`. |
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
