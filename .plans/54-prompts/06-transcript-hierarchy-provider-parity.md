# WS6 dispatch — transcript rhythm and Claude/Codex/Pi parity

## Shared workstream target

This packet defines **WS6: transcript hierarchy, rhythm, and provider parity** in Array. The rendered `<ROLE>` controls authority: a lead implements; a reviewer or tester evaluates the same locked target under only its selected overlay.

The fully rendered common protocol prepended to this dispatch is binding. The checked-in `00-agent-protocol.md` is an unresolved reference template and never overrides rendered values.

Read `<WORKTREE>/AGENTS.md`, the master plan, `00-agent-protocol.md`, and the current transcript rhythm/index/performance checks. This packet is binding; older transcript ledgers are historical and must not override it. Work only in `<WORKTREE>` at `<BASE_SHA>` and retain artifacts under `<EVIDENCE_DIR>`.

### Outcome

Make a long managed-agent transcript easier to scan without discarding the renderer work already present:

- Keep the virtualized semantic document, one aligned text column, restrained user-authorship rule, tool clustering, folding, selection/copy, and stable streaming behavior.
- Establish a clear three-level rhythm: compact within a semantic block, distinct between blocks, and a readable but not cavernous turn boundary. Evaluate and implement 24 pt inter-turn spacing from the current 32 pt unless deterministic rendering reveals clipping or a root-approved adjustment is required. Keep intra-entry spacing at 8 pt.
- Retain the hairline turn separator and make a short timestamp persistently visible as a quiet eyebrow instead of hover-only.
- Audit duplicate stacked insets around user prompts. Do not change the global 1.25 line-height token merely to alter this surface; AppKit clipping risk must remain local and measured.
- Claude, Codex, and Pi raw fixtures must project the same semantic hierarchy for equivalent events: user/assistant prose, reasoning, tool start/result/failure, tool summary, command output, file read/search, file edit/add/delete/rename, and diff.
- Provider-specific facts may differ; missing, reordered, flattened, or differently spaced equivalent semantics may not.

### Existing strengths and gaps

The transcript is already virtualized and substantially redesigned. Current likely scan friction is rhythm/hierarchy, not a renderer replacement. Existing provider-neutral checks can pass while an adapter drops a provider-specific raw event, and the inspected Component Lab has a real Claude replay without equivalent clearly audited Codex and Pi replay coverage.

### Inspect first

- `Sources/ContinuumRevivedAgentContent/` and its checks
- `Sources/ContinuumRevivedCore/AgentProviders/ClaudeEventTranslator.swift`
- `Sources/ContinuumRevivedCore/AgentProviders/CodexEventTranslator.swift`
- any Codex app-server translator/reader actually present
- `Sources/ContinuumRevivedCore/AgentProviders/PiEventTranslator.swift`
- provider transcript rehydration readers and fixtures
- `Sources/ContinuumRevivedCore/AgentTranscriptProjection.swift`
- `Sources/ContinuumRevivedCore/ManagedTranscriptCardProjection.swift`
- `Sources/ContinuumRevived/Canvas/AgentTranscript/`
- `Sources/ContinuumRevived/App/TranscriptRhythmChecks.swift`
- `Sources/ContinuumRevived/App/TranscriptIndexOracleChecks.swift`
- Component Lab/UIProbe transcript fixtures and baselines

### Owned scope

Own provider translator/projection normalization, transcript-only render/layout code, real scrubbed fixtures, and focused checks. Avoid `ManagedAgentTileNSView` unless root grants one narrow context seam. Do not change awareness/read semantics, page-zoom behavior, generic tile chrome, or unrelated provider runtime/auth behavior.

### Required witnesses

1. Build a scrubbed canonical raw corpus for each provider covering all required event types, nested/consecutive tools, reasoning, success/failure, summaries, and all file/diff operations.
2. Raw → semantic golden tests per provider. Normalize only genuinely provider-specific IDs/names/timestamps; assert node kind, order, nesting/parent linkage, status/outcome, summary/detail, file path/action, diff content, and turn boundaries.
3. Cross-provider parity oracle comparing equivalent normalized semantic documents. A shared authored document alone is insufficient.
4. Deterministic 20-minute transcript fixture with 12–20 varied turns and long history; test top/middle/bottom, folded/expanded, active streaming, incremental delta, and rehydrated state.
5. Geometry assertions at widths 320/480/640/900 in Aqua/Dark Aqua:
   - common text column;
   - exact row/block/turn spacing tiers;
   - timestamp/rule noncollision;
   - no clipping/overlap or duplicate user inset;
   - code/table/diff/tool widths and disclosure stable.
6. Preserve selection/copy/accessibility, semantic anchor, tail-following, delta-index oracle, and transcript performance. A style improvement that reintroduces full-history measurement is a failure.

Capture provider-neutral plus actual Claude/Codex/Pi projections at all key widths in both appearances. Also capture long-history top/middle/bottom and before/after one streaming delta. Produce masked parity diffs only for provider labels/facts explicitly allowed to differ; retain the absolute mask path, SHA-256, and a field-by-field allowed-region rationale. The unmasked semantic and geometry comparison remains blocking, and no mask may cover spacing, hierarchy, clipping, node order, or disclosure geometry.

### Required commands

```sh
export CONTINUUM_PROJECT_ROOT="<QA_PROJECT_ROOT>"
export CONTINUUM_APP_SUPPORT="<QA_APP_SUPPORT>"
export TMUX_TMPDIR="<QA_TMUX_TMPDIR>"
unset TMUX TMUX_PANE
swift build
swift run ContinuumRevivedAgentContentChecks
swift run ContinuumRevivedCoreChecks
.build/debug/Array --transcript-rhythm-check
.build/debug/Array --transcript-delta-index-oracle-check
.build/debug/Array --tool-detail-check
.build/debug/Array --perf-budget-transcript-delta-check
.build/debug/Array --transcript-provider-parity-check
scripts/check-matrix-inventory.sh
```

The lead must expose the raw Claude/Codex/Pi parity oracle under exact flag `--transcript-provider-parity-check` and register it in the matrix. Reviewer/tester dispatch is gated on the candidate containing it; both run it directly and prove its matrix leg executes. Enumerate current flags before the lead first invokes it. Run display-dependent candidate screenshots without blessing unrelated/stale baselines.

### Stop rules

Stop if a raw provider event is ambiguous enough that normalizing it would fabricate semantics, if a fixture contains private/user data, or if hierarchy work requires changing provider execution/auth. Represent an honest unknown rather than inventing a diff or outcome. Do not rewrite the virtualized list or globally alter typography.

### Success

Long transcripts scan with the agreed rhythm, quiet persistent turn metadata, no clipping or performance regression, and every required Claude/Codex/Pi raw event reaches an equivalent semantic/render hierarchy with independently inspected screenshots.

## Independent reviewer overlay

Trace every provider's raw fixture through translator, projection, document node, renderer, and rehydration. Flag dropped/reordered events, fabricated normalization, provider-only branches, lost parent linkage, incorrect file action/diff, global typography changes, duplicate spacing, and content-proportional layout work. Require actual raw fixtures for all three providers.

## Independent tester overlay

Replay the canonical raw corpus independently for Claude, Codex, and Pi; compare normalized semantic JSON and render at 320/480/640/900 in both appearances. Inspect every actual/diff plus long-history positions and streaming transition. FAIL on missing/reordered semantics, provider hierarchy drift, clipping/overlap, timestamp collisions, broken selection/anchor/tail-follow, or performance regression.
