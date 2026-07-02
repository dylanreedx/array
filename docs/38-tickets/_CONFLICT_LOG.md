# Ticket conflict log

Durable blocker ledger for the agent-orchestration tickets. This supplements `_PROGRESS.md`:
`_PROGRESS.md` records attempts; this file records **why** an attempt could not honestly land and
what Fable/Sonnet must do before retrying. Do not delete or weaken original ticket content; use this
log to add explicit rulings, prompt amendments, and recovery actions.

## Status values

| status | meaning | recovery |
| --- | --- | --- |
| `open` | active conflict; do not treat ticket as ready | resolve/amend/split first |
| `amended` | ticket/prompt has an explicit winning ruling | retry using the amendment |
| `split` | original ticket preserved, but work is decomposed into micro-tickets | run micro-tickets in order |
| `resolved` | conflict landed in a commit or no longer applies | continue |
| `terminal-skip` | intentionally not retried by unattended loop | human-only |

## Class values / reason codes

| class | meaning |
| --- | --- |
| `VFY-NONGATING` | proof exists but matrix does not run it, e.g. XCTest-only |
| `VFY-HEADLESS-DEFERRED` | headless pass skipped GUI/surface checks; supervised matrix still owed |
| `VFY-MATRIX-RED` | executable matrix failed |
| `BUILD-RED` | `swift build` failed |
| `REVIEW-REJECTED` | Fable/GPT-5.5 reviewer found merge-blocking issue |
| `CONTRACT-CONFLICT` | ticket contradicts itself or a landed ruling |
| `SCOPE-FENCE` | correct fix requires files/seams forbidden by ticket scope |
| `DEP-BLOCKED` | dependency is not done/resolved |
| `MIGRATION-DATALOSS` | schema/load/save path risks silent downgrade/drop/clobber |
| `I5-TAINT` | runtime/transcript/host-local data crosses sync/activity boundary |
| `REALPATH-MISSING` | required real-path proof replaced by surrogate/mock-only proof |
| `DETERMINISM-GAP` | random/clock/order-dependent proof, no fixed seed/fixture |
| `HARNESS-FAIL` | loop/tool/args/token/session issue, not ticket implementation |
| `PROVIDER-QUOTA` | provider/session/rate limit; retryable after reset |
| `DIRTY-UNTRACKED` | review/commit would miss files, or dirty attempt needs classification |

## Summary table

| id | ticket | status | class | source | required ruling / recovery action | owner | resolved in |
| --- | --- | --- | --- | --- | --- | --- | --- |
| C-20260701-001 | `03-membership-tile-register.md` | open | `SCOPE-FENCE`, `MIGRATION-DATALOSS`, `REVIEW-REJECTED` | `_PROGRESS.md`, dry-run agents | Loosen/split schema re-stamp scope; run 03A–03D micro-sequence before marking 03 retryable. | Dylan/Fable | - |
| C-20260701-002 | `04-zorder-fractional-index.md` | open | `SCOPE-FENCE`, `MIGRATION-DATALOSS`, `REVIEW-REJECTED` | `_PROGRESS.md`, dry-run agents | Split into FracIndex hardening, tile migration, workspace migration, render/hit-test migration. | Dylan/Fable | - |
| C-20260701-003 | `05-delete-tombstone.md` | open | `DIRTY-UNTRACKED`, `DEP-BLOCKED`, `REVIEW-REJECTED` | `_PROGRESS.md`, stash list, dry-run agents | Retryable after file-hygiene guard; forbid drift into ticket 06 materialize/compactor. | Fable | - |
| C-20260701-004 | `08-sync-observation-type-split.md` | resolved | `DIRTY-UNTRACKED`, `PROVIDER-QUOTA`, `HARNESS-FAIL` | current dirty tree, run `20260701T195840` | Classify current uncommitted attempt before any new ticket; provider regex missed “session limit”. | Dylan/Fable | 368cf7e |
| C-20260701-005 | `10-session-topology-snapshot.md` | resolved | `CONTRACT-CONFLICT` | `_HANDOFF.md`, dry-run agents | Prompt/ticket amendment: empty or whitespace tmux output is a valid zero-session snapshot; no `emptyInput` case. | Fable | c8e6a56 |
| C-20260701-006 | `06-oplog-apply-compaction.md` | open | `DEP-BLOCKED` | dry-run agents | Do not attempt until 03/04/05 semantics are landed or explicitly decomposed. | Fable | - |
| C-20260701-007 | `07-convergence-fuzz-red-green.md` | open | `DEP-BLOCKED`, `DETERMINISM-GAP` | dry-run agents | Do not attempt until 06 lands; seed-derived fixed UUIDs required. | Fable | - |
| C-20260701-008 | `09-taint-scan-i5.md` | open | `DEP-BLOCKED`, `CONTRACT-CONFLICT` | dry-run agents | Wait for 08; clarify legitimate geometry integer handling vs pid-shaped taint. | Fable | - |
| C-20260702-010 | `14-project-session-naming.md` | amended | `CONTRACT-CONFLICT`, `REVIEW-REJECTED` | run `20260701T225402` wf_d58b30f6, Fable+Codex round-3 reviews | Ticket's "No change to ContinuumApp.swift" fence vs its flag-wired backend-check requirement; ruling: check-only flag wiring (`--zone-project-session-naming-check` + matrix line) is required, fence guards spawn/kill/descriptor paths only. Ruling banner added to ticket. | Fable | - |
| C-20260701-009 | `11-activity-tree-snapshot.md` | resolved | `CONTRACT-CONFLICT`, `REVIEW-REJECTED` | fix-round-2/3 diffs, GPT-5.5/Codex review | Rename ticket 08's fold-derived `ActivityTreeSnapshot` (byTile read model) to `ActivityLogSnapshot`; reserve `ActivityTreeSnapshot` for ticket 11's SidebarTree-wrapping envelope, matching ticket 13's assumption. Downstream tickets 21/57/58/61/74 still name the byTile type `ActivityTreeSnapshot` in prose/code samples and must be read as `ActivityLogSnapshot` (or amended) when picked up. | Fable | (uncommitted, fix-round-3) |

---

## C-20260701-001 — `03-membership-tile-register.md`

- **Class:** `SCOPE-FENCE`, `MIGRATION-DATALOSS`, `REVIEW-REJECTED`
- **Evidence:** `_PROGRESS.md` reviewer notes; dry-run `explorer-20260702T004047Z-4090dd`.
- **Conflict:** The correct migration likely needs edits to schema re-stamp/save paths such as
  `ProjectStore.saveCanvas` and workspace profile persistence, while the original ticket's safe fence
  made those edits questionable. Prior attempts also clobbered non-membership `Tile` fields.
- **Content to preserve:** `Tile.zoneId` as LWW membership register; `WorkspaceDocument.ambientTiles`;
  old `groupZoneTiles` decode; v1→v2 canvas and v2→v3 workspace migration; no public
  `GroupZoneTiles`; I5 production projection check.
- **Winning directive / required ruling:** Do not retry as a monolith. Either loosen the scope fence
  to permit the required schema re-stamp paths, or split the re-stamp into an explicit prerequisite.
- **Prompt amendment required:** Include prior failures verbatim: schema version must not masquerade,
  `setTiles(_:forZone:)` may only mutate membership, profile save must not bypass v3, and I5 must use
  the production sync projection.
- **Proposed micro-sequence:**
  1. `03A-schema-restamp-contract` — old-shape decode followed by save writes the new schema version.
  2. `03B-zoneid-ambienttiles-migration` — pure model/Codable migration.
  3. `03C-membership-mutation-semantics` — preserve all non-`zoneId` fields under stale callers.
  4. `03D-production-membership-projection` — real rendering/projection wiring + I5 check.
- **Recovery:** Author packets/micro-tickets, then retry high-effort with schema and clobber gates.

## C-20260701-002 — `04-zorder-fractional-index.md`

- **Class:** `SCOPE-FENCE`, `MIGRATION-DATALOSS`, `REVIEW-REJECTED`
- **Evidence:** `_PROGRESS.md` reviewer notes; dry-run `explorer-20260702T004047Z-4090dd`.
- **Conflict:** Ticket requires broad mechanical and semantic migration: `Tile.zIndex` removal,
  `ZonePlacement.zPosition`, legacy rank migration, engine ordering, hit-testing, and call-site
  migration. Prior attempts kept compatibility shims or collapsed legacy order.
- **Content to preserve:** `FracIndex` z-order model; no production `zIndex` shim; legacy order
  preservation; render/hit-test by `(zPosition, id)`; op cases for tile/zone z-position.
- **Winning directive / required ruling:** Split before retry. No compatibility shim that defeats
  compile-enforced migration.
- **Prompt amendment required:** Explicitly require `FracIndex: Hashable`, remove `Tile.init(zIndex:)`,
  migrate all call sites, preserve old `groupZoneTiles` rank order, and prove hit-testing order.
- **Proposed micro-sequence:**
  1. `04A-fracindex-hardening`
  2. `04B-tile-zposition-migration`
  3. `04C-workspace-zone-zposition-migration`
  4. `04D-engine-render-hittest-order`
- **Recovery:** Run grep gate: no production `zIndex` except decode-only legacy keys.

## C-20260701-003 — `05-delete-tombstone.md`

- **Class:** `DIRTY-UNTRACKED`, `DEP-BLOCKED`, `REVIEW-REJECTED`
- **Evidence:** `_PROGRESS.md`; stash list; dry-run `explorer-20260702T004047Z-4090dd`.
- **Conflict:** Mostly additive, but prior attempt left `Tombstone.swift` untracked while package/tests
  referenced it. There is also scope-creep risk into ticket 06's real materializer/compactor.
- **Content to preserve:** delete op cases, `TombstoneSet`, `TombstoneRecord`, `CompactionLedger`,
  delete-wins policy, local test-only fold, no production materialize/compactor.
- **Winning directive / required ruling:** Retryable after file-hygiene preflight, but do not use it to
  hide unresolved 03/04 semantics.
- **Prompt amendment required:** New files must be `git add -N` before review; fresh checkout build must
  not depend on untracked files; forbid `materialize`/`compact` implementation here.
- **Proposed micro-sequence:**
  1. `05A-sync-target-file-hygiene`
  2. `05B-tombstone-vocabulary`
  3. `05C-delete-policy-checks`
- **Recovery:** Review package target membership and `git status --short` before any reviewer pass.

## C-20260701-004 — `08-sync-observation-type-split.md`

- **Class:** `DIRTY-UNTRACKED`, `PROVIDER-QUOTA`, `HARNESS-FAIL`
- **Evidence:** current `git status --short`; run
  `~/.pi/overnight-runs/continuum-overnight/run-20260701T195840`; log tail says
  `You've hit your session limit · resets 10:10pm (America/Toronto)`; harness stopped as
  `harness-malformed-output` because it matched neither a LOOP token nor the quota regex.
- **Conflict:** There is an uncommitted ticket-08 attempt in the tree. Starting a new ticket now would
  mix diffs. The provider-limit detector also needs to match “session limit”, not just “usage limit”.
- **Content to preserve:** `AgentActivityEvent`, `ActivityStore`, `ActivityTreeSnapshot`, pure
  `apply(_:_:)`, snapshot-then-tail stream, real `AtomicWriter` flush/load, no host/runtime handles.
- **Winning directive / required ruling:** Classify the dirty attempt first: continue after reset,
  stash as rejected attempt, or discard by explicit human command.
- **Prompt amendment required:** No XCTest proof; all checks in `ContinuumRevivedCoreChecks` or another
  `*Checks` executable wired into `run-matrix.sh`.
- **Recovery:** Before a new loop run: `git status --short`; decide fate of the four dirty files;
  update quota regex for `session limit` in the next Ralph loop.
- **Resolution (2026-07-01, run `20260701T225402` iter 1):** Dirty attempt classified
  **continue-after-reset** — the four files were a post-ruling retry (checks already in
  `ContinuumRevivedCoreChecks`, no XCTest) interrupted mid-flight by the session limit. A safety
  stash of the interrupted state was taken, the workflow continued from it, and ticket 08 landed
  in `368cf7e` (round 2, Fable + Codex both clear). The quota regex already matches
  `session limit` (`overnight-orchestration-loop.sh:424`), so that recovery item was done.

## C-20260701-005 — `10-session-topology-snapshot.md`

- **Class:** `CONTRACT-CONFLICT`
- **Evidence:** `_HANDOFF.md` says ruling landed; dry-run agents found stale prose/breadcrumbs still
  mentioning `emptyInput`.
- **Conflict:** The winning ruling is that empty/whitespace tmux output returns a zero-session snapshot,
  but stale ticket text can lead implementors back to `ParseError.emptyInput`.
- **Content to preserve:** six-field tmux format parser, no process calls, stable order, JSON round-trip,
  malformed/invalid-pid errors, pane lookup.
- **Winning directive / required ruling:** No `emptyInput` case. Empty string, newlines, spaces, and tabs
  all parse as a valid snapshot with zero sessions/windows.
- **Prompt amendment required:** Fable must state this override directly in the implementor packet.
- **Recovery:** Update ticket text or add an amendment packet before retry.
- **Resolution (2026-07-01, run `20260701T225402` iter 2):** Ticket text carries the ruling banner
  (added in `feded6b`) and the packet states the override; the retry landed in `c8e6a56` (round 2,
  Fable + Codex both clear) with empty/whitespace inputs returning zero-session snapshots and no
  `emptyInput` case.

## C-20260701-006 — `06-oplog-apply-compaction.md`

- **Class:** `DEP-BLOCKED`
- **Evidence:** dry-run `explorer-20260702T004047Z-c55974`.
- **Conflict:** Requires real membership, fractional z-order, and tombstone semantics from 03/04/05.
- **Recovery:** Do not stub placeholder models. Attempt only after 03/04/05 or their micro-sequence lands.

## C-20260701-007 — `07-convergence-fuzz-red-green.md`

- **Class:** `DEP-BLOCKED`, `DETERMINISM-GAP`
- **Evidence:** dry-run `explorer-20260702T004047Z-c55974`.
- **Conflict:** Depends on 06. Breadcrumbs risk nondeterministic `UUID()` use in seeded fuzz.
- **Recovery:** Use seed-derived fixed UUIDs; require manifest lines for seeds/steps/compactions.

## C-20260701-008 — `09-taint-scan-i5.md`

- **Class:** `DEP-BLOCKED`, `CONTRACT-CONFLICT`
- **Evidence:** dry-run `explorer-20260702T004047Z-c55974`.
- **Conflict:** Depends on 08 and all shipped `Op` cases. Pid-shaped integer scan may flag legitimate
  geometry/z-order integers unless the ticket/prompt clarifies key-path handling or safe fixtures.
- **Recovery:** Wait for 08; clarify scanner behavior before unattended implementation.

## C-20260701-009 — `11-activity-tree-snapshot.md`

- **Class:** `CONTRACT-CONFLICT`, `REVIEW-REJECTED`
- **Evidence:** fix-round-2 diff (`Sources/ContinuumRevivedCore/AgentActivityEvent.swift`,
  `Sources/ContinuumRevivedCore/SidebarTree.swift`); GPT-5.5/Codex fix-round-2 and fix-round-3 review
  notes.
- **Conflict:** Ticket 08 (`08-sync-observation-type-split.md`, landed in `368cf7e`) already ships a
  public `ActivityTreeSnapshot` in `AgentActivityEvent.swift` — the `ActivityStore`'s fold-derived,
  per-tile read model (`snapshotSequence`/`snapshotReplicaId`/`byTile`). Ticket 11 independently names
  its own new SidebarTree-wrapping envelope `ActivityTreeSnapshot` too. Two public types cannot share
  one name in one module. This collision predates ticket 11's implementation: ticket 13
  (`13-invariant-spine-harness.md:60`) already writes "`ActivityTreeSnapshot` is owned by the … 'Activity
  tree snapshot type' ticket [11]" as an established fact, which only makes sense if ticket 08's type
  was always going to need a different name. Tickets 21, 57, 58, 61, and 74, by contrast, all use
  `ActivityTreeSnapshot` in prose and code samples to mean ticket 08's `byTile` fold-derived type (e.g.
  `21-idle-reaper-detach.md:148`'s `public struct ActivityTreeSnapshot { … byTile … }`,
  `57-cloudkit-transport-impl.md:87`'s `pushActivitySnapshot(_ snapshot: ActivityTreeSnapshot, …)`) — so
  the doc corpus itself is internally inconsistent about which type owns the name.
- **Content to preserve:** Ticket 08's `AgentActivityEvent`/`ActivityStore`/pure `apply(_:_:)`/
  `TileActivity`/`ActivityStreamItem` semantics (all field shapes, behavior, and tests unchanged — only
  the type name changes). Ticket 11's `ActivityTreeSnapshot` exactly as it names it (no adaptation
  needed on ticket 11's side).
- **Winning directive / required ruling:** `ActivityTreeSnapshot` belongs to ticket 11 (the
  SidebarTree-wrapping envelope), matching ticket 13's pre-existing assumption. Ticket 08's type is
  renamed to `ActivityLogSnapshot` (fold-derived, byTile-keyed activity log read model — distinct from
  the tree-shaped snapshot). `ActivityStoreProtocol.currentSnapshot()`, `ActivityStore.snapshot`, and
  `ActivityStreamItem.snapshot(_:)` all update to the new name; no other call sites in `Sources/`
  reference the old name (verified by `grep -rn ActivityTreeSnapshot Sources/` after the rename — only
  ticket 11's files remain). This is a rename-only change: no field, behavior, or test assertion in
  ticket 08's type changes.
- **Prompt amendment required:** Tickets 21, 57, 58, 61, and 74 must be read with `ActivityTreeSnapshot`
  translated to `ActivityLogSnapshot` wherever their text/code samples mean the `byTile` fold-derived
  type (not ticket 11's tree envelope). Amend those ticket files (or attach an implementor-packet
  override, as done for ticket 10 / C-20260701-005) before any of them is picked up for implementation,
  so an unattended pass does not redeclare a colliding `ActivityTreeSnapshot` or wire the wrong type
  into a signature like `pushActivitySnapshot(_:)`.
- **Recovery:** No further action needed to land ticket 11 itself — the rename is complete and verified
  with no other in-repo Swift consumers of the old name. Before starting 21, 57, 58, 61, or 74, re-read
  this entry and translate `ActivityTreeSnapshot` references in those ticket files to
  `ActivityLogSnapshot` where they mean the byTile read model.

## C-20260702-010 — `14-project-session-naming.md`

- **Class:** `CONTRACT-CONFLICT`, `REVIEW-REJECTED`
- **Evidence:** run `20260701T225402` workflow `wf_d58b30f6-1da` (2026-07-02): 3 rounds, matrix green
  (headless), both reviewers rejected on one converged concern — `runProjectSessionNamingSelfCheck()`
  (`ZoneRuntimeController.swift:624`) shipped with zero callers: no `--zone-project-session-naming-check`
  flag in `ContinuumApp.swift`, no `run_app_check` line in `scripts/run-matrix.sh`.
- **Conflict:** The ticket's "Done when" requires the controller backend check to pass via the existing
  self-check-suite pattern (`runHydrationLifecycleSelfCheck` / `runSaveIsolationSelfCheck`), which is
  flag-wired through `ContinuumApp.swift` + `run-matrix.sh` — but the ticket also fences
  "No change to `TileSpawner.swift`, `ContinuumApp.swift`, or any descriptor type." An implementer
  honoring the fence ships an unrunnable check; both reviewers correctly reject dead-weight checks.
- **Winning directive / required ruling:** The fence guards spawn/attach/kill behavior and descriptor
  types, not check-only wiring. Adding the `--zone-project-session-naming-check` flag handler in
  `ContinuumApp.swift` (mirroring the two siblings) and the matching `run_app_check` line in
  `scripts/run-matrix.sh` is REQUIRED. No other `ContinuumApp.swift` change is permitted.
- **Prompt amendment required:** Ruling banner added to the top of the ticket file (this commit) —
  same mechanism as C-20260701-005 / `feded6b`.
- **Recovery:** Re-drive the workflow from the dirty round-3 tree (attempt is otherwise
  reviewer-shaped: naming functions, controller methods, Core checks, Component Lab panel all present).
