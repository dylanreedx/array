# 91-agent-tile-ux — execution ledger

## heartbeat

last-touch 2026-07-28T06:28:52Z · ticket P0.2-agent-content-target.md · attempt 1 · pid — · status done

## states

`pending` · `in-progress` · `done` · `blocked`

| Ticket | State | Commit | Updated | Note |
|---|---|---|---|---|
| `P0.1-program-contract.md` | done | this commit | 2026-07-28T04:48:16Z | Recovered the worker's preserved patch after upgrading Codex CLI 0.135.0 → 0.145.0. The guard now cross-validates the fixed packet header, exact dependency grammar/order/uniqueness, ledger state metadata with real BSD-date UTC validation, 50 packet/ledger rows, three supervised gates, and a fail-fast script-relative matrix invocation locked at executable line 4; 25 isolated negative mutations must all go red while the live program remains untouched. Negative witness from the worker and recovery: deleting forged-pending protection failed; independent Codex review then found and drove fixes for misleading header text, regex/trailing/duplicate dependencies, swallowed/disabled matrix calls, malformed done metadata, and invalid calendar timestamps. Final `./scripts/check-agent-tile-ux-program.sh`, `swift build`, matrix inventory, and full headless `run-matrix.sh` passed; matrix artifact `qa-runs/20260728T044806Z/app-bundle/manifest.json`. Codex 0.145 final review: APPROVE. |
| `P0.2-agent-content-target.md` | done | this commit | 2026-07-28T06:28:52Z | Stood up `ContinuumRevivedAgentContent` (Foundation only, no dependencies, one namespace file) plus the `ContinuumRevivedAgentContentChecks` leg wired into the matrix after the AgentUI leg. The leg holds the platform-neutral boundary with four gates: (1) module identity/linkage — the checks target links AgentContent ALONE, so a reverse dependency stops compiling (witnessed: `import ContinuumRevivedCore` in AgentContent fails the build, exit 1); (2) a source import ALLOWLIST of exactly `Foundation`, scanned over a small Swift lexer (nesting block comments, single-line/multiline/raw literals with escapes, `\(…)` interpolations incl. comments inside them, backtick identifiers); (3) SwiftPM's EVALUATED manifest via `swift package dump-package --scratch-path <temp>` — each of the two target dicts must match exactly, any extra key (path/sources/pluginUsages/linkerSettings/swiftSettings) is red; (4) the COMPILER's own record — the `.d` files in `<dir of this executable>/ContinuumRevivedAgentContent.build/`, so no forbidden module can reach the built module by any route, with a freshness assertion that every current source appears in it. Negative witnesses, each observed red against the final check: 12 source-import evasions (plain, `@_exported`, tab, `;`-joined, leading `/* */`, `import class AppKit.NSView`, `internal import`, `public import SwiftUI`, `@preconcurrency package import`, `import/**/AppKit`, newline-split `import\nAppKit`, `import Network` bracketed by two `try! /"/` regex literals) — all FAIL by assertion except the Core one, which fails at compile; 8 manifest evasions (Core dependency; `.product(name:"GRDB")` that no blocklist named; `dependencies :` with a space; block-commented decoy; raw-string decoy; unused clean decoy + constant-named live target; `package.targets[i].dependencies.append("ContinuumRevivedCore")` after construction; `linkerSettings = [.linkedFramework("AppKit")]` after construction; `Target.Dependency` constant smuggled into the checks array) plus `linkerSettings`/`path`/`swiftSettings` arguments; and gate 4 proven live by widening the import allowlist to permit AppKit — `import AppKit` still failed with "the BUILT … module consumed [AppKit, QuartzCore]". False-positive guards verified GREEN on compiling source: interpolation with a nested literal, interpolation with a quote inside a comment, `value! / 2`, `values.count / count`, a multiline doc string containing the words `import AppKit`, and a planted stale `release/…/stale.d` naming AppKit. Verification: `swift build` clean; `swift run ContinuumRevivedAgentContentChecks` passed (~1.1s, all four legs); `CONTINUUM_SKIP_SURFACE_CHECKS=1 ./scripts/run-matrix.sh` exit 0 with the new leg green and `Matrix inventory checks passed (282 committed records)`; matrix artifact `qa-runs/20260728T062705Z/app-bundle/manifest.json`. Inventory regenerated: exactly two records ADDED (`leg run swift run ContinuumRevivedAgentContentChecks`, `count ContinuumRevivedAgentContentChecks 4`), none removed or lowered; no matrix leg, floor, contrast requirement, baseline or I5 boundary touched. Independent review: Codex 0.145.0, read-only, eight rounds; rounds 1–7 returned REQUEST-CHANGES with 19 blocking findings, all accepted and fixed except one, and round 8 returned APPROVE with no findings. The line-oriented scanner was twice replaced rather than patched — first by the lexer, then by deleting the static manifest parse in favour of `dump-package` — because each patch met a new evasion. Honest limits: (a) `dump-package` is a SECOND evaluation of the manifest, so a manifest deliberately written to answer the probe differently from the build that launched it could still lie to gate 3; not chased, documented in the code at that gate — these gates exist to catch accidental coupling by a future ticket, an author gaslighting a probe they could equally delete is outside what an in-repo check can hold, and the consequence that matters is covered by gate 4 without trusting the manifest at all; (b) gate 2 refuses a bare regex literal in an ambiguous position rather than lexing it, so a future AgentContent ticket wanting one must extend the lexer — it fails closed and says so; (c) gate 4's forbidden list is a blocklist of UI frameworks and Continuum modules, not an allowlist, because Foundation itself pulls in a toolchain-dependent set (Combine, Dispatch, XPC, Observation, Security) that would rot with every SDK; (d) `AgentContentModule` is a bare namespace — the semantic types are P1.1's work — and the allowlists deliberately do NOT pre-authorise swift-markdown, so P2.1 must extend them under review; (e) no AppKit/UI work in this ticket, so no geometry/contrast/Component Lab/baseline flag applies beyond the full matrix run. |
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
