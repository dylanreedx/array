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
| C-20260701-001 | `03-membership-tile-register.md` | resolved | `SCOPE-FENCE`, `MIGRATION-DATALOSS`, `REVIEW-REJECTED` | `_PROGRESS.md`, dry-run agents | Fence loosened by human-authorized ruling (see entry note); 03A–03D landed as one unit. | Dylan/Fable | 0468b4b |
| C-20260701-002 | `04-zorder-fractional-index.md` | resolved | `SCOPE-FENCE`, `MIGRATION-DATALOSS`, `REVIEW-REJECTED` | `_PROGRESS.md`, dry-run agents, 4-agent adversarial review 2026-07-02 | Split executed as 04A/04B/04C micro-commits (see entry note); no compat shim; legacy order preserved. **04B wire-format amendment (createTile/setTileZIndex Int→FracIndex) RATIFIED by Dylan 2026-07-02** — reviewer CLEAR (no op-log producers/consumers until ticket 06; more consistent with the pre-existing FracIndex `setZonePosition` case). Debt: add symmetric `setTileZIndex` legacy-Int-throws fixture. | Dylan/Fable | 993c684, ab4811f, f2b0e44 |
| C-20260701-003 | `05-delete-tombstone.md` | resolved | `DIRTY-UNTRACKED`, `DEP-BLOCKED`, `REVIEW-REJECTED` | `_PROGRESS.md`, stash list, dry-run agents | File-hygiene guard applied (git add -N + fresh-checkout build proof); ticket-06 scope untouched. | Fable | 99eabb8 |
| C-20260701-004 | `08-sync-observation-type-split.md` | resolved | `DIRTY-UNTRACKED`, `PROVIDER-QUOTA`, `HARNESS-FAIL` | current dirty tree, run `20260701T195840` | Classify current uncommitted attempt before any new ticket; provider regex missed “session limit”. | Dylan/Fable | 368cf7e |
| C-20260701-005 | `10-session-topology-snapshot.md` | resolved | `CONTRACT-CONFLICT` | `_HANDOFF.md`, dry-run agents | Prompt/ticket amendment: empty or whitespace tmux output is a valid zero-session snapshot; no `emptyInput` case. | Fable | c8e6a56 |
| C-20260701-006 | `06-oplog-apply-compaction.md` | resolved | `DEP-BLOCKED` | dry-run agents | **UNBLOCKED 2026-07-02: 03/04/05 landed (0468b4b, 04A/B/C, 99eabb8) + reviewed CLEAR.** 06 is now ready to attempt. Implementer: fold all Op cases — incl. the FracIndex z-payloads (04B) and tombstone delete-wins (05) — into materialize/compaction. | Fable | dep cleared |
| C-20260701-007 | `07-convergence-fuzz-red-green.md` | amended | `DEP-BLOCKED`, `DETERMINISM-GAP` | dry-run agents | Dep on 06 (loop dep-check orders it after 06 lands). **DETERMINISM RULING (overwatch 2026-07-02):** the fuzz must use seed-derived fixed UUIDs/timestamps (NO live `UUID()`/`Date()`) so red/green is reproducible. | overwatch | - |
| C-20260701-008 | `09-taint-scan-i5.md` | amended | `DEP-BLOCKED`, `CONTRACT-CONFLICT` | dry-run agents | 08 landed (368cf7e). **TAINT RULING (overwatch 2026-07-02):** legitimate small-integer geometry (frame coords, counts, indices) is NOT taint; only pid/handle/pane-id-shaped values or host paths crossing the sync/activity boundary are taint — scan for the latter pattern, allow the former. | overwatch | - |
| C-20260702-010 | `14-project-session-naming.md` | amended | `CONTRACT-CONFLICT`, `REVIEW-REJECTED` | run `20260701T225402` wf_d58b30f6, Fable+Codex round-3 reviews | Ticket's "No change to ContinuumApp.swift" fence vs its flag-wired backend-check requirement; ruling: check-only flag wiring (`--zone-project-session-naming-check` + matrix line) is required, fence guards spawn/kill/descriptor paths only. Ruling banner added to ticket. | Fable | - |
| C-20260701-009 | `11-activity-tree-snapshot.md` | resolved | `CONTRACT-CONFLICT`, `REVIEW-REJECTED` | fix-round-2/3 diffs, GPT-5.5/Codex review | Rename ticket 08's fold-derived `ActivityTreeSnapshot` (byTile read model) to `ActivityLogSnapshot`; reserve `ActivityTreeSnapshot` for ticket 11's SidebarTree-wrapping envelope, matching ticket 13's assumption. Downstream tickets 21/57/58/61/74 still name the byTile type `ActivityTreeSnapshot` in prose/code samples and must be read as `ActivityLogSnapshot` (or amended) when picked up. Queue tickets 58 + 74 now carry a C-009 ruling banner. | Fable | 988095e; banners 58/74 |
| C-20260702-011 | `33-status-derivation-golden.md` | resolved | `VFY-CONVENTION` | `_CODEX_AUDIT.md` Tier-4 | Golden-table manifest used a distinct `invariantId "I6-status-soundness-pure-derivation"` instead of the shared `"I6-status-soundness"` + `via` tag the aggregator (ticket 39) depends on; changed to the shared id (the `via: pure_derivation_golden_table` measurement already distinguishes the leg). | overwatch | 33 invariantId fix |
| C-20260702-012 | `70-approvals-needsattention.md` | amended | `SCOPE-FENCE`, `I5-TAINT` | `_CODEX_AUDIT.md` 54/59 audit | `respondToApproval` must not rely on the `.observer` scope floor; gate it on session ownership of the target approval (or operator+ scope) before clearing the pending entry. Ruling banner added to ticket. | overwatch | - |
| C-20260702-013 | `30-shared-view-exemption.md` | open | `DEP-BLOCKED` | queue readiness check | Depends on the grouped-view-session spawn (ticket 27), which never landed and is NOT in the autonomous queue (supervised/substrate). Do not attempt until 27 is built by hand. Marked skipped in `_PROGRESS.md`. | Dylan/overwatch | - |
| C-20260703-014 | `39-reader-golden-fixtures.md` | open | `DEP-BLOCKED` | queue readiness check | Depends on all three agent-state readers incl. the **Codex** reader (`CodexStateReader`), which does not exist on disk; ticket 38-codex-reader is UNCLASSIFIED/excluded from the autonomous queue with no ledger row. The I6 replay block calls `CodexStateReader().locate/read` and cannot compile without it. Do not attempt until 38 is built by hand. Also: shipped readers are named `ClaudeAgentStateReader`/`PiAgentStateReader` (not `ClaudeStateReader`/`PiStateReader`) and lack `AgentSnapshot.taintCheck`/`ClaudeStateReader.defaultStaleWindowSeconds` — the ticket needs an API-reconciliation amendment before retry. Marked skipped in `_PROGRESS.md`. | Dylan/overwatch | - |
| C-20260703-016 | `56-transport-fuzz-soak.md` | open | `DEP-BLOCKED` | queue readiness check | Depends on the convergence fuzz (**ticket 07**, `skipped` — needs human hands per its ledger row). 56 rewires the *existing* convergence-fuzz block to push/subscribe through `FakeSyncTransport` and reuses `canonicalEncode` + the shared `randomSpatialOp` helper + the `LCG`/fuzz scaffolding — all owned by 07, and all grep-confirmed **absent** from `Sources/ContinuumRevivedCoreChecks/main.swift` (07 never landed). Ticket text: "Both must be merged and green before any code here is written." Cannot build on a missing foundation. Do not attempt until 07 lands by hand. NB: the transport *seam* (ticket 55) IS done (568532a) — the missing dep is the fuzz, not the seam. Marked skipped in `_PROGRESS.md`. | Dylan/overwatch | - |
| C-20260703-015 | `41-fsevents-push-watch.md` | open | `DEP-BLOCKED` | queue readiness check | Depends *entirely* on the `SessionObserver` (with budgets), built by ticket **40-session-observer**, which is **Supervised** (its Execution-mode: "Supervised. The observer integrates three moving parts — FSEvents, tmux process detection, and per-tile reader dispatch — and its correctness at the UI layer depends on…") — excluded from the autonomous queue, never built, no commit, no ledger row. `SessionObserver` does not exist on disk (only a comment mention in `AgentActivityEvent.swift:20`); there is no `armWatchers`/`readAndUpdate`/`subscribe` host method for ticket 41's `AgentStoreWatcher` to wire into. Cannot build on a missing foundation. Do not attempt until 40 is built by hand. Marked skipped in `_PROGRESS.md`. | Dylan/overwatch | - |
| C-20260703-017 | `66-connection-supervisor.md` | open | `DEP-BLOCKED` | queue readiness check | Its "Depends on" section (line 310) names the **transport fuzz and soak (ticket 56)** as a hard dependency; 56 is `skipped` (dep-blocked on the unbuilt convergence fuzz **ticket 07**, which needs human hands per its ledger row — C-20260703-016). The *code* substrate for 66 IS present (55 `FakeSyncTransport` `goOffline`/`reconnect` at 568532a; 59 `Scope` at 71ecc95; 12 injectable substrates), so 66 could probably compile — but the ticket explicitly ties the trustworthiness of its green to the soak: "the supervisor's logic checks reuse that same API, and a bug in the fake would produce false green results here" (line 310). Without 56 having exercised the fake under adversarial delivery, a green from 66's fake-driven logic checks is untrustworthy — the exact false-green the runbook forbids. This is a *verification-trust* block, not a missing-symbol block: skip until 07 → 56 land by hand, then re-attempt 66 (likely straightforward since the code foundation exists). NB downstream: 66 unblocks the (supervised/substrate) iOS observer, APNS push, and deep-link validation — none in the autonomous queue. Marked skipped in `_PROGRESS.md`. | Dylan/overwatch | - |

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
- **Ruling + Resolution (2026-07-02, human-authorized pass, commit `0468b4b`):** The ticket's
  "Stop if" fence was AMENDED to permit the schema re-stamp/save paths and the production render
  wiring. Fences loosened: (1) `CanvasState`/`WorkspaceDocument` `encode(to:)` now ALWAYS writes
  `currentSchemaVersion` — this structurally covers `ProjectStore.saveCanvas`, `WorkspaceStore.save`,
  and the `WorkspaceDocument` nested in `WorkspaceProfile` (no per-store edits needed; the prior
  masquerade bug is impossible at the type level); decoders migrate supported older versions forward
  in memory and stamp them current. (2) `CanvasNSView` (outside the original file list) gained the
  production `setTileZone` sink — every membership mutation writes the `Tile.zoneId` register, which
  persists via the existing canvas save path; `install(tileView:for:)` no longer clobbers the stored
  register when replacing a tile record. (3) `WorkspaceRuntime` renders ambient zones from
  `document.tiles(forZone:)` in install/switch/addZone. `setTiles(_:forZone:)` and `setTileZone` are
  field-scoped (zoneId only). LWW checks fold through the production `setTileZone` write in `OpId`
  order (no local fold state); I5 check scans the real `setTileZone` wire bytes from
  `JSONCodec.makeOpLogEncoder()`. Schema sequence: canvas v1→2, workspace v2→3 (ticket 04 takes them
  to 3/4). Matrix green (headless) at the commit.

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
- **Ruling + Resolution (2026-07-02, human-authorized pass, commits `993c684`/`ab4811f`/`f2b0e44`):**
  Landed as the prescribed split — 04A FracIndex hardening (Hashable, distribute, fromLegacyRank,
  after/before with exhaustion-tie semantics), 04B tile migration (`Tile.zIndex` REMOVED, no
  `init(zIndex:)` shim, ~150 call sites migrated under compile enforcement; canvas v2→3), 04C zone
  migration (`ZonePlacement.zPosition`, stored `zoneZOrder` removed, workspace v3→4; legacy order
  stamped listed-then-unlisted-on-top, never collapsed to 0.5). `bringToFront`/`bringZoneToFront`
  are no-ops on the already-frontmost item; `renormalizeZOrder` deleted; all render/hit-test sorts
  key on `(zPosition, id)` — zone hit-testing reads each placement's register, not array order.
  Grep gate passes: remaining `zIndex` tokens are the decode-only legacy CodingKey, legacy JSON
  migration fixtures, comments, and an unrelated CSS property. WIRE AMENDMENT needing human
  sign-off: `Op.createTile` z payload → `zPosition: FracIndex` (key `"zPosition"`) and
  `Op.setTileZIndex` payload → `z: FracIndex` (key `"z"`), amending ticket 02's frozen wire format
  while the op log has zero producers/consumers/persisted data (pre-ticket-06); frozen fixtures
  updated and a check pins that pre-amendment Int payloads fail loudly. Matrix green (headless).

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
- **Ruling + Resolution (2026-07-02, human-authorized pass, commit `99eabb8`):** Landed with the
  file-hygiene guard: new files (`Sources/ContinuumRevivedSync/Tombstone.swift`,
  `Sources/ContinuumRevivedSyncChecks/main.swift`) were `git add -N`'d before review and a fresh
  checkout of the commit (`git archive HEAD`) builds and passes `ContinuumRevivedSyncChecks`.
  `ContinuumRevivedSync` stood up per ticket 06's layout (pure Swift, Core-only dependency) with the
  tombstone vocabulary ONLY — no materialize, no compactor, no tombstone state on the snapshot
  types; `Op.deleteTile`/`deleteZone` already existed on Core's frozen enum (ticket 02), so no wire
  change. Delete-wins policy pinned by a local test-only fold whose field-set upsert makes the
  `isTombstoned` guard load-bearing (with a sanity leg proving resurrection WOULD occur without the
  tombstone). New `ContinuumRevivedSyncChecks` line added to `run-matrix.sh` (additive). ComponentLab
  close-middle-tile visual gate rides `--component-lab-check`. Matrix green (headless).

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
- **Update (2026-07-02):** 03/04/05 landed (`0468b4b`, `993c684`/`ab4811f`/`f2b0e44`, `99eabb8`) —
  the dependency is satisfied. Note for the implementer: `Op.setTileZIndex` now carries
  `z: FracIndex` and `Op.createTile` carries `zPosition: FracIndex` (C-002 wire amendment);
  `materialize` writes `Tile.zPosition`/`Tile.zoneId`/`ZonePlacement.zPosition` registers and must
  cite `TombstoneSet`'s delete-wins doc comment.

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
