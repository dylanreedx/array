# Managed agent capabilities — complete change record

Last updated: 2026-08-10

This document records the design and implementation work on
`array/managed-agent-capabilities` from base commit `825bbe8` through Phase 2.
It is the durable handoff for what changed, why it changed, how the pieces fit,
what has executable evidence, and what remains intentionally unimplemented.

## Repository state

- Isolated checkout: `/Users/dylan/Documents/personal/Array/.worktrees/managed-agent-capabilities`
- Branch: `array/managed-agent-capabilities`
- Base: `825bbe8` — `Resolve relay program preflight`
- Design: `ffc53f0` — `docs: plan managed agent capabilities`
- Phase 1: `721a1d2` — `feat: add semantic agent completions`
- Progress handoff: `a132b04` — `docs: record capability implementation progress`
- Phase 2: `5e24e72` — `feat: add fuzzy managed agent file navigation`
- Remote state: local only; none of these commits were pushed

The primary checkout, `/Applications/Array.app`, production Array state, and
Dylan's live project roots were not modified or launched by this work.

## Product outcome

The managed-agent composer now has a provider-neutral semantic completion
foundation and a real checkout-scoped `@` file navigator.

Before this work, completion rows were fundamentally text insertion fixtures.
After Phase 1, a row can carry an explicit semantic payload and provenance.
After Phase 2, a managed tile obtains its exact checkout root from its agent
record, indexes that checkout, lets the user browse directories without adding
directory paths to prompt text, and turns accepted files into the same
structured `AgentPromptFileReference` used by drag/drop.

No Pi, Claude Code, or Codex capability discovery/invocation adapter was added.
Those providers remain behind the typed registry seam for a later phase.

## Architecture introduced

The completion path now has five distinct responsibilities:

1. `AgentCompletionContext` captures immutable agent/backend/root/trust scope.
2. `AgentCompletionProvider` discovers rows and returns typed payloads.
3. `AgentCompletionProviderRegistry` merges, ranks, deduplicates, and preserves provenance.
4. `CompletionPopoverController` owns request cancellation, stale-generation rejection, and presentation.
5. `AgentComposerView` applies only the semantic action represented by the selected payload.

For `@`, the flow is:

```text
managed agent record.cwd
        ↓
AgentCompletionContext.checkoutRoot
        ↓
AgentFileCompletionProvider
        ↓
AgentFileIndex actor
        ↓
.directory navigation or .file reference
        ↓
AgentComposerView
        ↓
breadcrumb navigation or structured file-reference chip
```

The index never derives its root from the process current directory, Array's
globally active project, or a repository helper intended for worktree creation.

## Phase 1 — semantic completion foundation

### Typed payloads

`AgentCompletionPayload` gained explicit cases for:

- `.insertText(String)`
- `.file(AgentPromptFileReference)`
- `.skill(ResolvedSkillInvocation)`
- `.promptTemplate(ResolvedPromptTemplate)`
- `.runtimeCommand(ResolvedRuntimeCommand)`
- `.directory(DirectoryNavigationTarget)`

Legacy completion construction remains source-compatible: omitting `payload`
creates `.insertText(insertionText)`. That compatibility is intentional for
existing text fixtures, but semantic rows cannot silently degrade into text.

### Provenance

`AgentCompletionProvenance` records:

- backend;
- scope (`system`, `personal`, `project`, `plugin`, `package`, `temporary`, `runtime`, or `fixture`);
- source identifier;
- provider-native invocation name.

The registry retains the chosen row's payload and provenance through
deduplication while also recording every provider ID that returned the row.

### Immutable query context

`AgentCompletionContext` carries:

- `agentID`;
- `backend`;
- exact `checkoutRoot`;
- optional `gitRoot`;
- `arrayProjectRoot`;
- `trustState`.

It is host-local and non-Codable. Query text, replacement ranges, local paths,
and provider handles do not enter the sync projection.

### Semantic acceptance

Only `.insertText` is applied by the completion controller through TextKit.
Everything else is dispatched by payload type:

- `.file` removes the query and enters the structured file-reference rail;
- `.directory` changes navigation scope;
- skill/template/runtime payloads use `onCompletionAction`;
- rejected semantic actions leave the original query intact.

This prevents a capability with a missing adapter from becoming plausible but
incorrect prompt prose.

### Context rebinding and stale requests

Binding a new context dismisses the current surface, cancels the active task,
increments the generation, and refreshes from the new context. A provider that
ignores task cancellation still cannot repaint results from an older agent,
backend, checkout, or query.

### Fixture policy

The fallback slash and skill rows remain text fixtures. They demonstrate the
surface without advertising semantic capabilities that no provider adapter can
execute. Phase 2 replaces only the fake file fixture in managed tiles.

## Phase 2 — real fuzzy `@` navigation

### Core-owned file index

`AgentFileIndex` is an actor with:

- a cache keyed by agent ID, backend, and standardized checkout root;
- a default 50,000-entry ceiling;
- a default 50-result ceiling;
- explicit context/all-cache invalidation;
- cancellation checks before discovery, after discovery, during materialization,
  before returning suggestions, and throughout fallback traversal.

Cache identity deliberately includes agent/backend context even when two agents
point at similar paths, preventing one tile rebind from inheriting another
tile's catalog identity.

### Root boundary

`AgentSupervisor.completionContext(for:)` sets `checkoutRoot` from the exact
standardized `AgentRecord.cwd`. Managed tile attach/re-attach binds that context;
detach clears it.

This is distinct from `AgentSupervisor.repositoryRoot(of:)`, whose purpose is
choosing the parent repository for child worktree creation. Using that helper
for completion would incorrectly widen a worktree or nested repository search.

The Falcon witness constructs:

```text
falcon-platform/
├── OUTER.md            # must never appear
└── falcon/             # AgentRecord.cwd / allowed root
    ├── README.md
    └── Sources/
```

Only `falcon-platform/falcon` is indexed.

### Git discovery

When the checkout contains `.git`—directory or worktree metadata file—the index
runs:

```sh
git -C <checkout> ls-files -z --cached --others --exclude-standard
```

This provides:

- tracked files;
- untracked, non-ignored files;
- standard Git ignore handling;
- NUL-delimited paths, preserving spaces, quotes, and shell metacharacters;
- correct operation from a real Git worktree root.

The command receives the root as one `Process` argument. No shell command is
constructed from a user path.

### Non-Git fallback

If Git discovery is unavailable, a bounded breadth-first traversal is used. It:

- sorts every directory lexically for deterministic output;
- skips hidden descendants and package descendants;
- skips `.git`, `.array`, `.build`, `build`, `DerivedData`, `node_modules`, and `.cache`;
- never follows symbolic links;
- stops at the entry ceiling;
- checks cancellation while traversing.

This fallback is intentionally conservative. Git is authoritative for ignore
semantics whenever the checkout is a repository.

### Materialization and path safety

Raw discovered paths are normalized to checkout-relative paths. `.` and `..`
segments cannot widen the root. Every materialized URL must remain equal to or
below the standardized checkout root.

Symbolic links are excluded instead of traversed or accepted. Parent directory
rows are derived from discovered files and are themselves checked as real
directories. Existence is checked again for every query, so a file deleted
after cache construction immediately stops being actionable.

### Referenceable file types

`AgentFileReferenceRules.referenceableContentType(for:)` is now shared by
drag/drop and indexed acceptance.

It first uses a registered resource content type. Headless and newly-created
files can receive dynamic UTIs that do not conform to text/source types, so a
conservative extension allowlist provides a plain-text fallback for common
text, source, markup, configuration, and data files. PDF remains explicitly
allowed. Images, archives, binaries, audio/video, and unknown extensions remain
excluded.

Because both paths call the same resolver, accepting `@Sources/File.swift` and
dropping that file produce the same three-field structure:

- display filename;
- resolved content-type identifier;
- literal local file URL.

### Fuzzy ranking

Non-empty searches rank in this order:

1. exact basename;
2. basename prefix;
3. basename subsequence;
4. path-segment prefix;
5. relative-path subsequence.

Within a tier, ordering is stable by:

1. smaller subsequence gap;
2. directory before file;
3. shorter relative path;
4. fixed lexical relative path.

The implementation uses POSIX-locale case/diacritic folding rather than
locale-aware natural sorting, keeping deterministic witness output.

### Empty-query browsing

An empty `@` query shows only immediate children of the current scope.
Directories sort before files. Descendant search becomes fuzzy when query text
is present.

Directory rows carry `.directory(DirectoryNavigationTarget)` and never attach a
directory. File rows carry `.file(AgentPromptFileReference)`.

### Navigation and breadcrumbs

`AgentCompletionQuery.navigationPath` and
`AgentComposerView.completionNavigationPath` hold browser scope outside the
persisted composer draft.

Navigation behavior:

- Return accepts the focused directory or file;
- Right or Tab descends only when the focused row is a directory;
- Left ascends when an empty scoped `@` query is active;
- Backspace ascends when an empty scoped `@` query is active;
- Escape dismisses without mutation;
- selecting a directory replaces the visible token with only `@`, not its path;
- a disabled first row displays `<checkout> › <directory> › …` breadcrumbs and
  the ascent hint;
- leaving `@` completion or rebinding context resets the navigation scope.

The passive popover continues to leave the native text view as first responder.

### Managed-tile composition

Every managed tile constructs a real default completion registry containing:

- the existing text-only slash fixture provider;
- the existing text-only skill fixture provider;
- `AgentFileCompletionProvider` backed by a tile-owned index actor.

The fake `fixture.files` provider is filtered out. An explicitly supplied
registry remains supported for deterministic tests or later runtime adapters.

Attach binds the registry and exact supervisor context. Re-attaching the same
agent after a Home change refreshes context. Detach cancels suggestions and
clears context/navigation state.

## File-by-file change map

### Design and progress files

- `plans/managed-agent-capabilities/plan.mdx`
  - Added the complete capability architecture, provider comparison, decisions,
    phased implementation map, verification gate, and acceptance checklist.
  - Marked semantic acceptance, query context, file-shape equivalence,
    navigation safety, and host-local privacy complete after their witnesses passed.
- `plans/managed-agent-capabilities/canvas.mdx`
  - Added the visual architecture canvas for discovery, registry, composer, and
    provider invocation boundaries.
- `plans/managed-agent-capabilities/.plan-state.json`
  - Added visual-plan state for the managed-capability plan.
- `plans/managed-agent-capabilities/PROGRESS.md`
  - Added the resumable working-state handoff, completed behavior, exact checks,
    known baseline issue, limitations, and next slice.
- `plans/managed-agent-capabilities/CHANGES.md`
  - Added this complete implementation record.

### Core

- `Sources/ContinuumRevivedCore/AgentCompletionProvider.swift`
  - Added semantic payload types, provenance, scopes, directory targets,
    provider IDs on merged results, and preferred-payload/provenance preservation.
- `Sources/ContinuumRevivedCore/AgentCompletionQuery.swift`
  - Added immutable agent completion context and host-only navigation scope.
- `Sources/ContinuumRevivedCore/AgentFileIndex.swift`
  - Added the bounded actor, Git/fallback discovery, path materialization,
    deterministic fuzzy ranking, typed file/directory completion provider, cache,
    invalidation, deletion filtering, and cancellation.
- `Sources/ContinuumRevivedCore/AgentFileReferenceRules.swift`
  - Added the shared URL-to-referenceable-content-type resolver and conservative
    text/source extension fallback.
- `Sources/ContinuumRevivedCore/AgentBackendConfig.swift`
  - Added explicit backend equality for immutable completion-context comparison.

### Composer and tile UI

- `Sources/ContinuumRevived/Canvas/AgentComposer/CompletionPopoverController.swift`
  - Bound context/navigation to queries, preserved stale-generation cancellation,
    displayed breadcrumb rows, and made Right/Tab directory-only operations.
- `Sources/ContinuumRevived/Canvas/AgentComposer/AgentComposerView.swift`
  - Added semantic acceptance routing, structured file acceptance, host-only
    directory state, ascent/descent, context rebinding, and QA accessors.
- `Sources/ContinuumRevived/Canvas/AgentComposer/ChoiceListView.swift`
  - Added open and ascend commands without changing existing list selection paths.
- `Sources/ContinuumRevived/Canvas/AgentComposer/ComposerTextView.swift`
  - Forwarded Right/Tab and Left/Backspace completion navigation while preserving
    native behavior when navigation does not consume the event.
- `Sources/ContinuumRevived/Canvas/AgentComposer/ComposerFileReferencePasteboardDecoder.swift`
  - Switched drag/drop to the same Core content-type resolver used by `@`.
- `Sources/ContinuumRevived/Canvas/ManagedAgentTileNSView.swift`
  - Added the real default file provider registry and lifecycle context binding.

### App composition and witnesses

- `Sources/ContinuumRevived/App/AgentSupervisor.swift`
  - Added exact-record completion-context construction.
  - Expanded the semantic AppKit witness with typed runtime rejection, structured
    file acceptance, directory browsing, breadcrumbs, Right descent, Backspace
    ascent, context rebinding, and managed-tile nested-root binding.
- `Sources/ContinuumRevived/App/ContinuumApp.swift`
  - Added the focused `--agent-completion-semantic-check` pre-AppKit-boot gate.
- `Sources/ContinuumRevivedCoreChecks/AgentCompletionChecks.swift`
  - Added typed contract, provenance/deduplication, context, cancellation, and
    real temporary Git/Falcon/worktree file-index witnesses.

## Deterministic evidence

The final focused commands passed:

```sh
/Users/dylan/Documents/personal/Array/.build/debug/ContinuumRevivedCoreChecks --agent-completion-check
CONTINUUM_APP_SUPPORT=<isolated-temp> /Users/dylan/Documents/personal/Array/.build/debug/Array --agent-completion-semantic-check
```

The Core check proves:

- all semantic payload cases;
- quote/escape/UTF-16/middle-caret query detection;
- immutable context retention;
- deterministic provider merge, rank, deduplication, and provenance;
- cancellation of stale registry and file-index requests;
- required negative-witness RED execution;
- exact Falcon nested-root isolation;
- a real Git worktree indexes its worktree, not its primary repository;
- Git ignored files are absent;
- cached deleted files are absent;
- symlink escape is absent;
- spaces and quotes survive as literal URLs;
- empty-query directories-first behavior;
- bounded result count;
- deterministic fuzzy ordering;
- untrusted contexts expose no file capabilities;
- directory payload shape;
- indexed and drag/drop file-reference equality.

The AppKit semantic check proves:

- rejected runtime commands cannot insert poison fallback text;
- file selection becomes exactly one structured chip;
- Right descends into a directory;
- breadcrumb state is visible while the draft contains only `@`;
- empty-query Backspace ascends without draft mutation;
- context rebind replaces backend/checkout identity;
- a real managed tile receives its record's exact nested checkout root.

Both the `Array` and `ContinuumRevivedCoreChecks` SwiftPM products built
successfully. `git diff --check` passed before the Phase 2 commit.

## Verification notes

The shared `.build` scratch path is also used by other checkouts. During final
verification another SwiftPM build could replace the executable between a build
and a later invocation. The definitive AppKit witness therefore rebuilt the
isolated worktree and invoked its semantic check immediately in the same shell
command; that run passed.

`--agent-supervisor-check` retains its known sandbox failure at the historical
native completion undo assertion. The identical failure was reproduced from an
untouched clone at base `825bbe8`. The assertion was not weakened or removed;
the new semantic behavior has the focused check above.

The full matrix was not run for this phase. The visual-plan package could not be
re-fetched because network access was unavailable; the plan had passed local
lint before its final checklist-only edit.

## Safety and persistence boundaries

- File URLs, provider handles, completion queries, replacement ranges, and
  navigation state remain host-local and non-Codable.
- No file bytes are embedded by `@`; accepted files remain reference-only paths
  for the provider's Read capability.
- No directory is attachable.
- No symlink is indexed or accepted through `@`.
- Untrusted contexts return no file suggestions.
- Semantic actions never fall back to prompt text.
- Existing user-facing fallback fixtures remain text-only.
- No API keys or provider credentials are introduced or stored.
- Nothing was pushed, merged, packaged, released, or installed.
- `/Applications/Array.app` and production state were not touched.

## Intentionally incomplete

- Pi `get_commands` discovery and structured invocation.
- Claude Code personal/project command and skill discovery.
- Codex `skills/list` and structured app-server invocation.
- Provider-native prompt-template and runtime-command execution.
- Precedence/conflict badges and trust-disabled catalog rows.
- Filesystem watching for newly added/renamed files.
- Live backend-default observation without a tile reattach/rebind.
- Shared use of the index by the standalone file-tree tile.
- Full matrix and isolated Array Dev manual product smoke.

Deleted cached paths are already filtered on every query. Newly created paths
appear after explicit invalidation or context rebind until filesystem watching
is added.

## Next authorized slice

Phase 3 can add read-only provider discovery adapters behind the existing
registry. Discovery should land and be witnessed before provider-native
invocation. Pi/Claude/Codex adapters must not bypass typed payloads, immutable
context, trust state, or provenance, and must not recreate a universal text
insertion path.
