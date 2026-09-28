# s11 — workspace-foreign-zone-fix worktree investigation

Worktree: /Users/dylan/array-worktrees/workspace-foreign-zone-fix
Branch: array/workspace-foreign-zone-fix, HEAD 4a895f71 ("Publish Array 0.7.7 build 58"),
0 commits ahead of array/integration but 108 commits behind it.
Dirty diff: 433 insertions(+), 58 deletions(-) across 5 files (unchanged since the
2026-09-14 audit recorded in .plans/65).

## What the diff does

"Foreign zone" = a `ZonePlacement` that is legitimately persisted in a workspace
document's `document.zones` array but whose `projectId` is authoritatively owned
(per the app Registry) by a *different* workspace. These placements are kept in
the file (never deleted, to avoid destroying layout data) but must never be
mounted/hydrated/acquired while that other workspace is the live one.

Mechanism (WorkspaceRuntime.swift):
- Introduces a new private `mountedZoneIds: Set<UUID>` — "the live-scene boundary."
  `document.zones` remains the complete persisted record (including legacy
  foreign placements); every interactive/runtime decision now reads through
  `mountedZone(_:)` / `mountedZones` (ownership-filtered) instead of scanning
  `document.zones` directly. Updated call sites: `activeController`,
  `commitZonePlacement`, `commitClosedZone`, `arm(zoneId:)`, focus restore,
  `reconcileHydration` (tile spawn/zone lookups), transcript-tile routing.
- `mountedZoneIds` is (re)seeded at every place the mounted scene changes: boot
  install (`install(...)` sets it from `mountableZones`), workspace switch
  (sets it to `targetZoneIds` after a successful switch), zone-append paths,
  and `closeAll` (cleared to `[]`).
- `switchWorkspace(to:)` gets a rollback guard: project acquisitions made
  during a switch attempt are tracked in `attemptAcquisitions` and released if
  a later step throws (registry save, etc.), so a failed switch can't leave a
  controller acquired-but-untracked outside `acquiredProjectIds`.
- New `retireForeignAcquiredProjects(using:)`: defensive cleanup that releases
  any controller in `acquiredProjectIds` whose project's registry-recorded
  `workspaceId` no longer matches the runtime's own `workspaceId`. Called (a)
  at the start of `switchWorkspace` and (b) inside `reconcileHydration` on
  every debounced pass — this is the actual fix for the reported bug class:
  previously `reconcileHydration()` iterated raw `document.zones`, so a
  foreign zone that happened to intersect the saved viewport could get
  planned "live" and have its project's controller acquired/hydrated purely
  by camera movement, even though boot-time mount correctly filtered it out.
  `reconcileHydration` now also intersects `mountedZoneIds` against a freshly
  computed ownership set each pass, unmounts/evicts any layer that fell out of
  ownership, and repairs `lastActiveZoneId` if it pointed at a now-foreign zone.
- `WorkspaceSwitchError` gains `LocalizedError` conformance with human-readable
  `errorDescription` strings.

ContinuumApp.swift:
- Adds the `--workspace-foreign-zone-hydration-check` CLI flag wired to a new
  `AppDelegate.runWorkspaceForeignZoneHydrationSelfCheck()` static check. This
  check builds two workspaces (Work, Personal) where Work's document carries
  both its legitimate zone and a "preserved foreign zone" (owned by Personal,
  geometrically overlapping Work's saved viewport — reproducing the exact
  field failure shape). It mounts Work via the real production boot path
  (`mountWorkspaceSceneAtBoot`), forces a hydration reconcile through the real
  `CanvasNSViewDelegate` callback chain (`qaHydrationScheduleCount` /
  `flushPendingHydrationReconcile`), and asserts: only the legitimate zone is
  mounted, Personal's project is never acquired, `liveProjectIds`/
  `qaAcquiredProjectIds` stay correct, then does a round-trip
  Work→Personal→Work switch and asserts exact zone/viewport/registry
  restoration and that the foreign zone survives in the persisted document but
  is never remounted or reacquired.
- Also refactors the various "switch workspace" call sites (sidebar, top-bar
  popup, Command Center, "switch to owning workspace") onto one shared
  `performWorkspaceSwitch(to:)` helper with unified rollback-on-failure
  behavior (restores the AppKit popup selection, restores canvas/viewport,
  surfaces a `setWorkspaceManagementMessage` error) — this is a related but
  distinct UI-robustness change, not itself part of the foreign-zone fix. It
  adds substantial new self-check assertions (`failedPopupRolledBack`,
  `nextSelectionWasNotSuppressed`, `commandCenterUsedSameFailurePath`) inside
  the existing top-bar QA harness.

WorkspaceTopBarView.swift: adds one QA accessor, `selectedWorkspaceIdForQA`,
used only by the popup-rollback assertions above.

matrix-inventory.txt / run-matrix.sh: register
`--workspace-foreign-zone-hydration-check` in both the alphabetical inventory
list and the actual executed leg list (with an explanatory comment), placed
after `--workspace-switch-check`.

## Completeness

- The new witness (`--workspace-foreign-zone-hydration-check`) is properly
  registered in both `matrix-inventory.txt` and `run-matrix.sh`, matching
  hazard 9/"witnessed behavior" requirements structurally.
- The check asserts *outcomes* (mounted zone sets, live registry project ids,
  acquired-project sets, viewport equality, persisted-document survival of the
  foreign zone) rather than source strings — consistent with the CLAUDE.md
  witness standard.
- No TODO/FIXME markers were introduced in the diff.
- `targetZoneIds` (used at `mountedZoneIds = targetZoneIds` in switchWorkspace)
  is defined earlier in the same function pre-existing code, so that line is
  self-consistent within the diff.
- The diff reads as a complete, self-contained unit: it was NOT actually
  compiled/run in this investigation (read-only, per instructions), but no
  obviously dangling reference, unclosed brace, or missing declaration was
  found by inspection; the large ContinuumApp.swift hunk is a fully worked
  self-check with its own fixture project/workspace/registry setup, matching
  the style of neighboring self-checks in that file.
- Caveat from .plans/65 (2026-09-14 audit, still applicable — dirty diff is
  byte-identical in size to what was recorded then): the ContinuumApp.swift
  diff bundles an *unrelated* switch-error/chrome refactor (unified
  `performWorkspaceSwitch` with popup-rollback UI messaging) into the same
  patch as the foreign-zone hydration fix. That coupling was flagged as
  colliding with the topbar lane and as something to strip out before a
  narrow port to current integration.
- Not independently reviewed or built in this pass (read-only investigation).

## Landed-elsewhere verdict: NOT landed

Searched `array/integration` HEAD (2cec73ff→ now 1451c030, "Publish Array 0.7.21
build 72") for the identifiers this diff introduces:
- `mountedZoneIds`, `qaHydrationScheduleCount`, `retireForeignAcquiredProjects`,
  `--workspace-foreign-zone-hydration-check`: zero matches anywhere in
  integration's `WorkspaceRuntime.swift`, `ContinuumApp.swift`, `run-matrix.sh`,
  or `matrix-inventory.txt`.
- `git log --since=2026-09-01 -i --grep='foreign|membership|zone' array/integration`
  returns only unrelated commits (kanban board, workspace-api agent tools, zone
  delete-tiles fix, drag/tidy work) — none is this fix.
- Integration's `switchWorkspace` DOES already filter `targetZones` through
  `mountableZones(...)` at switch time (so a foreign zone is excluded from the
  *arriving* scene during an explicit switch) and has comments acknowledging
  legacy foreign zones must be preserved-but-unmounted. But integration has no
  persistent `mountedZoneIds` boundary and, per the 2026-09-14 scout finding
  reproduced in .plans/65 line 194, its `reconcileHydration()` still "iterates
  raw `document.zones`" — i.e. integration lacks the specific fix for a
  foreign zone getting silently hydrated/acquired by camera-driven reconcile
  passes between explicit switches. Nothing since 09-14 closes that gap.

Conclusion: this is real, un-duplicated work; the underlying bug class (foreign
zone acquired via `reconcileHydration`, not just at explicit switch) is still
open on integration.

## Session-map / coordination-doc in-flight items

.plans/63-session-map.md (2026-09-08) — live/owned sessions at that time:
| Item | Branch | Status recorded |
|---|---|---|
| TR-06 provider requests + reply options | array/tr06-provider-requests | live session |
| Transcript integration (merge owner) | array/transcript-integration | live session |
| ST-01 agent status telemetry | array/st01-telemetry | live session |
| DI-01 dictation | array/dictation | live session |
| TR-01 file cards | array/tr01-file-cards | live session |
| TR-04 slash dispatch | array/tr04-slash-dispatch | live session |
| CX-01 workspace API + release prep | (this session) | live session |
| KB-01 kanban board | array/kb01-board | earlier owner, still of record |
| Ticket-prompt investigation (.plans/59) | — | earlier owner |
| Transcript program (45-handoff lineage) | — | earlier owner, 47M transcript |
| Unbounded-canvas rendering architecture | — | earlier owner, 17M transcript |
| TR-03 tool rows, TR-07 codex subagent visibility | — | no own session; folded into transcript-integration |
| array/agent-naming | array/agent-naming | no owning session; 619 lines, zero witnesses — flagged risky to merge |

This doc does not mention "workspace-foreign-zone-fix" or "foreign zone" at all.

.plans/65-release-0.7.21-coordination.md (2026-09-14, latest state) — lane inventory
and status:
| Item | Location | Status |
|---|---|---|
| Persistence (this worktree) | ~/array-worktrees/workspace-foreign-zone-fix, array/workspace-foreign-zone-fix | 108 commits behind, dirty (5 files, 433/58 — matches current state exactly). Audited as a "plausible real foreign-zone rehydration/controller-ownership route," explicitly "not proven empty-workspace data loss." Instruction: preserve old work, port narrowly onto current integration only after scoped coordination; flagged as colliding with chrome/topbar and the matrix file. |
| Chrome: topbar + start/stop | .worktrees/topbar-merge, array/topbar-merge | Clean at 61416361, one feature commit ahead, Sol APPROVE, fresh isolated checks passed; not landed; no manual fullscreen/drag QA. |
| Naming fallback | .worktrees/0721-naming, array/0721-naming | RED→GREEN 3/3, Sol APPROVE; no live-provider/full-matrix run. |
| Drag instruction overlap | .worktrees/0721-drag-overlay, array/0721-drag-overlay | Repaired after initial bug, RED/GREEN + Sol APPROVE; no manual drag QA. |
| Transcript lab + prose leading | .worktrees/0721-transcript, array/0721-transcript | 5 modified files + handoff; UNBUILT, UNTESTED, UNREVIEWED, no taste approval. |
| Transcript readability + lab (older) | .worktrees/transcript-subagents | 402 commits behind, zero unique code, dirty stale handoff; preserved untouched. |
| Dictation | ~/array-worktrees/dictation, array/dictation | One unmerged fake-engine Core commit; no composer/audio/backend/permissions wiring — audit only. |
| Sidebar + subagent transparency | audit queue 94, docs 96/98 | Three supervised gates (P3.6, P5.6, P7.1) pending; no new implementation. |
| VFX | separate exploration | No new implementation; scheduled after persistence; optional/non-blocking. |
| Process footprint | measurements/report | No implementation branch. |
| Computer Use | existing agent 6BAE5028... | Do not duplicate; separately fenced. |

Recorded next step for persistence specifically (line 225): "narrowly port
foreign-zone rehydration fix onto current integration, not the 108-commit-old
dirty patch" — i.e. this worktree's diff was intended as a *reference*
implementation to port, not to merge wholesale (because of its unrelated
chrome coupling), and per the search above that porting has not happened yet.

.plans/62-release-0.7.16-prep.md: no mentions of this worktree/branch, "foreign
zone," zones, workspace switching, tile persistence, agent home, or titlebar —
it predates this line of work and is not relevant here.

## Relevance to user complaints

- "Zones' names/project bindings revert after switch/relaunch": partially
  relevant. The diff hardens `lastActiveZoneId` repair and ownership-filtered
  zone identity across switch/boot (`mountedZoneIds`, `mountedZone(_:)`
  replacing raw `document.zones` lookups everywhere), and the self-check
  explicitly asserts a Work→Personal→Work round trip restores exact zones,
  viewport, and registry selection, and that the foreign zone's declared
  `projectId` in the persisted document is untouched. It does not appear to
  touch zone *naming*/color persistence directly, but it does harden the
  project-binding side of "did the right zone/project come back after a
  switch."
- "Agent tile in a zone born with blank home": not addressed. Nothing in this
  diff touches tile creation, agent home resolution, or spawn-time
  provisioning — it's scoped to zone mount/ownership/hydration.
- "Tiles/zones drift and overlap": indirectly relevant only in that the fixture
  reproduces a foreign zone geometrically overlapping the legitimate zone's
  viewport, but the fix is about *acquisition/mounting*, not about geometry/
  layout drift — it prevents the overlapping foreign zone from being
  hydrated/interacted with, it doesn't reposition or de-overlap zones.
- "Tiles outside a zone remain members" (the CLAUDE.md hazard-9 Membership
  invariant): closely related in spirit — this is the same class of bug
  (identity/ownership leaking across a boundary that should exclude it) but
  applied to zones-across-workspaces rather than tiles-across-zones. It does
  not directly fix the tile/zone membership invariant itself, but it's the
  same "must not treat something as a member of the wrong container" family,
  operating one level up (workspace ownership of zones/projects rather than
  zone ownership of tiles). Given hazard 9's emphasis, this diff should be
  read as adjacent-but-distinct from a direct tile-membership fix, and a
  reviewer should confirm it doesn't paper over a membership bug rather than
  fix a hydration bug.

Overall: this diff is real, complete-looking, witnessed work fixing a genuine
open gap (camera-driven `reconcileHydration` acquiring/hydrating a foreign
zone that boot-time mount correctly excludes) that has not landed on
integration by any other route. It is entangled with an unrelated switch-error
UI refactor that should be split out before porting, per the existing
coordination-doc instruction. It plausibly helps the "bindings revert after
switch/relaunch" complaint but doesn't address blank agent home or zone/tile
drift, and is only tangentially related to the tile-outside-zone membership
complaint.
