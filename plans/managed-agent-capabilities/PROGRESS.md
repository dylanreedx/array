# Managed agent capabilities — implementation progress

Last updated: 2026-08-10

## Working state

- Branch: `array/managed-agent-capabilities`
- Isolated checkout: `/Users/dylan/Documents/personal/Array/.worktrees/managed-agent-capabilities`
- Base: `825bbe8` (`array/integration`, `Resolve relay program preflight`)
- Design commit: `ffc53f0` (`docs: plan managed agent capabilities`)
- Phase 1 implementation commit: `721a1d2` (`feat: add semantic agent completions`)
- Remote state: local only; nothing pushed

The primary checkout and production Array app/state were not modified or launched.

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

## Deterministic witnesses

Passed:

```sh
/Users/dylan/Documents/personal/Array/.build/debug/ContinuumRevivedCoreChecks --agent-completion-check
/Users/dylan/Documents/personal/Array/.build/debug/Array --agent-completion-semantic-check
```

The Core witness covers all payload cases, immutable query context, source-compatible text defaults, preferred payload/provenance retention through deduplication, trigger isolation, cancellation, and the existing required RED subprocess.

The AppKit witness proves:

- a rejected runtime command returns its exact typed payload and does not insert deliberately poisonous fallback text;
- a resolved file removes only the `@` query and becomes one structured file-reference chip;
- rebinding replaces agent/backend/checkout context for the visible query.

The `Array` app product and `ContinuumRevivedCoreChecks` product both build successfully. `git diff --check` passed before the implementation commit.

## Known verification constraint

`--agent-supervisor-check` fails in this sandbox at its existing native completion undo assertion: one Undo clears the text instead of restoring `/hel`. The identical failure was reproduced from the untouched baseline clone at `825bbe8`, so it was not introduced by this branch. The new semantic behavior therefore has its own focused self-check rather than weakening or bypassing the legacy assertion.

The visual-plan package was not cached, and network package resolution is blocked. The plan passed local lint before the final wording/checklist-only update; that final update could not be re-linted here.

## Not completed yet

- No managed-agent tile currently binds a real `AgentCompletionContext`; only the contract, composer seam, and rebind witness exist.
- No real file index or fuzzy `@` navigation exists.
- No Pi, Claude, or Codex capability catalog adapter exists.
- No provider-native skill/template/runtime invocation is wired.
- No precedence/conflict UI, trust-disabled rows, breadcrumbs, or live invalidation exists.
- Nothing has been pushed, merged, packaged, or released.

## Recommended next slice: Phase 2, real `@` navigation

1. Add a Core-owned bounded file-index actor keyed by immutable completion context.
2. Resolve the allowed root from the managed agent checkout, not Array's globally active project or process cwd.
3. Use a deterministic fuzzy rank with stable tie-breaking and bounded result count.
4. Respect ignored files, deletion, symlinks, spaces, quotes, and worktree roots.
5. Return `.directory` payloads for navigation and `.file` payloads for acceptance.
6. Add breadcrumb/navigation state outside draft text.
7. Bind the registry plus context from the managed agent tile and cancel/rebuild on backend or checkout changes.
8. Prove the Falcon nested-root case: index `falcon-platform/falcon`, never its outer folder.
9. Prove file selection produces the same `AgentPromptFileReference` shape as drag/drop.

Do not start provider adapters until the `@` index/root boundary and semantic acceptance path are green together.
