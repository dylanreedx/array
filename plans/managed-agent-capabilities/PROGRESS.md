# Managed agent capabilities — implementation progress

Last updated: 2026-08-10

## Working state

- Branch: `array/managed-agent-capabilities`
- Isolated checkout: `/Users/dylan/Documents/personal/Array/.worktrees/managed-agent-capabilities`
- Base: `825bbe8` (`array/integration`, `Resolve relay program preflight`)
- Design commit: `ffc53f0` (`docs: plan managed agent capabilities`)
- Phase 1 implementation commit: `721a1d2` (`feat: add semantic agent completions`)
- Phase 2 implementation commit: `5e24e72` (`feat: add fuzzy managed agent file navigation`)
- Complete change record: [`CHANGES.md`](./CHANGES.md)
- Remote state: local only; nothing pushed

The primary checkout and production Array app/state were not modified or launched.

For the complete architecture, file-by-file delta, verification evidence, safety
boundaries, and intentionally deferred work, see [`CHANGES.md`](./CHANGES.md).

## Completed

### Design and architecture

- Documented the cross-provider capability model for Pi, Claude Code, and Codex.
- Separated provider-native discovery/invocation from Array-owned presentation.
- Defined `@` as a checkout-scoped fuzzy file navigator, with directory selection reserved for navigation rather than attachment.
- Preserved user-facing fallback fixtures as text completions so placeholder data cannot create fake capabilities.

### Phase 1 foundation

- Added typed completion payloads for text, files, skills, prompt templates, runtime commands, and directory navigation.
- Added host-local provenance with backend, scope, source identifier, and provider-native invocation name.
- Added immutable `AgentCompletionContext` carrying agent ID, backend, checkout root, git root, Array project root, and provider trust state.
- Attached context to provider queries at the completion-controller boundary.
- Added an atomic composer context-rebind seam that cancels the old completion generation before refreshing.
- Changed acceptance so only `.insertText` reaches native TextKit insertion.
- Routed semantic provider actions through `onCompletionAction`; rejected actions leave the query intact and never insert fallback text.
- Routed resolved file selections through the same structured draft reference/chip collection used by drag/drop.
- Preserved the registry's existing async cancellation, deterministic ranking, deduplication, and provider aggregation while retaining the preferred row's payload and provenance.

### Phase 2 real `@` navigation

- Added a Core-owned `AgentFileIndex` actor with context-keyed caching, a 50,000-entry default ceiling, a 50-result default ceiling, cancellation guards, and explicit invalidation.
- Made Git the authoritative discovery path for repositories through `git ls-files --cached --others --exclude-standard`, preserving tracked files while honoring standard ignore rules.
- Added a bounded, hidden/cache-excluding, symlink-safe fallback walker for non-Git folders.
- Kept the exact managed record `cwd` as the checkout/index root; the Array project, repository helper, and process current directory are never consulted by the index.
- Added stable fuzzy ordering: exact basename, basename prefix, basename subsequence, path-segment prefix, then relative-path subsequence, with deterministic gap/directory/path-length/lexical ties.
- Rechecked existence at query time so a path deleted after indexing cannot remain actionable, and excluded symlinks from both navigation and acceptance.
- Centralized conservative file content-type resolution in `AgentFileReferenceRules`, shared by drag/drop and indexed acceptance, so both produce the same `AgentPromptFileReference` contract even when Launch Services returns a dynamic UTI.
- Added host-only `navigationPath` query state, visible disabled-row breadcrumbs, Return/Right/Tab descent, and Left/empty-query Backspace ascent without placing the selected directory path into draft text.
- Bound each managed tile to a real file registry and an immutable completion context derived from its supervisor record. Reattach/Home changes rebind and cancel the previous completion generation; detach clears the context.
- Replaced only the fake `@README.md` tile provider. Existing slash/skill fallback fixtures remain text-only and cannot claim semantic capabilities.

## Deterministic witnesses

Passed:

```sh
/Users/dylan/Documents/personal/Array/.build/debug/ContinuumRevivedCoreChecks --agent-completion-check
/Users/dylan/Documents/personal/Array/.build/debug/Array --agent-completion-semantic-check
```

The Core witness covers all payload cases, immutable query context, source-compatible text defaults, preferred payload/provenance retention through deduplication, trigger isolation, cancellation, and the existing required RED subprocess. Its real temporary Git fixture additionally proves:

- `falcon-platform/falcon` is the only indexed root; an `OUTER.md` decoy cannot leak in;
- ignored and deleted files cannot appear;
- symlinks cannot escape the checkout;
- files with spaces and quotes remain literal capabilities;
- empty-query directory-first browsing, deterministic fuzzy order, result bounds, cancellation, untrusted-context refusal, and directory payloads;
- indexed acceptance equals the drag/drop `AgentPromptFileReference` shape.

The AppKit witness proves:

- a rejected runtime command returns its exact typed payload and does not insert deliberately poisonous fallback text;
- a resolved file removes only the `@` query and becomes one structured file-reference chip;
- Right-arrow directory descent shows a breadcrumb while leaving only `@` in the draft;
- empty-query Backspace ascends without draft mutation;
- rebinding replaces agent/backend/checkout context for the visible query;
- a real managed tile binds the supervisor record's exact nested checkout root.

The `Array` app product and `ContinuumRevivedCoreChecks` product both build successfully. `git diff --check` passed before the implementation commit.

## Known verification constraint

`--agent-supervisor-check` fails in this sandbox at its existing native completion undo assertion: one Undo clears the text instead of restoring `/hel`. The identical failure was reproduced from the untouched baseline clone at `825bbe8`, so it was not introduced by this branch. The new semantic behavior therefore has its own focused self-check rather than weakening or bypassing the legacy assertion.

The visual-plan package was not cached, and network package resolution is blocked. The plan passed local lint before the final wording/checklist-only update; that final update could not be re-linted here.

## Not completed yet

- No Pi, Claude, or Codex capability catalog adapter exists.
- No provider-native skill/template/runtime invocation is wired.
- No precedence/conflict UI, trust-disabled rows, or filesystem/backend-settings live invalidation exists. Deleted indexed paths are filtered immediately; adding a new path requires explicit index invalidation or a context rebind.
- Nothing has been pushed, merged, packaged, or released.

## Recommended next slice: Phase 3, provider discovery

The `@` index/root/navigation/semantic-acceptance gate is green together. The next separately authorized slice can add discovery-only Pi/Claude/Codex catalogs behind the existing typed registry. Keep discovery read-only first; provider-native invocation should remain a later independently witnessed step.
