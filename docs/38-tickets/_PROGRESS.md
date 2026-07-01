# Overnight execution progress

Durable ledger for the Ralph loop. One row per attempted ticket. Source of truth for "done"
alongside the git log on `overnight/agent-orchestration`.

| ticket | status | commit | matrix | note |
| --- | --- | --- | --- | --- |
| (infra, not a ticket) | done | f42102a | matrix: green | Pre-existing bug: `zoneBoundsConfig group8` check read `paddingKey`/`emptyMinWidthKey`/`emptyMinHeightKey` from the SettingsSchema `"general"` section, but an earlier commit (1fc7afb) moved them to `"zones"`; the check `exit(1)`'d on the mismatch and silently skipped the entire back half of the suite on every run, predating this program. Fixed as a one-line commit; flag for morning review. |
| (infra, not a ticket) | done | eb7d4fe | n/a | Harness bug: `overnight-iteration-wf.js` hardcoded the implementer's repo path to the old `continuum-revived` checkout; the implementer correctly refused to fabricate progress in the wrong repo. Fixed. |
| 01-store-protocol-seam.md | done | c71d601 | matrix: green | Clean. Both reviewers cleared. Codex flagged `ContinuumApp.swift:7134` as an unmigrated `ProjectStore` param — verified dead/unreachable duplicate predating the ticket, left per policy. |
| 02-op-enum-logged-op-envelope.md | done | a4cba75 | matrix: green | Hand-resolved after the pre-hardening loop livelocked 3×; the implementer's dirty tree had actually addressed every concern (explicit frozen `CodingKeys`, `AnyKey` unknown-key guard, `FracIndex` boundary/prepend/append tests, `.target`-anchored deps guard). Verified: clean build, Core checks green, full matrix passed. |

## Reset for the hardened retry (2026-07-01)

Tickets **03** and **04** were attempted by the *pre-hardening* loop (single pass, no
self-repair, Sonnet reviewing Sonnet) and honestly **skipped** when review found real defects.
They have been reset to un-attempted so the hardened loop (3-round self-repair, real Opus +
GPT-5.5, high effort on re-model tickets) can complete them — they are foundational and block
many downstream tickets. Their prior findings, preserved so the morning review has them:

- **03 (membership register):** `Tile.zoneId` was round-tripped but not wired into production
  rendering (`WorkspaceRuntime` gated on `projectId != nil`; `CanvasNSView` used a private
  geometry map instead of `setTileZone`); `WorkspaceDocument.setTiles(_:forZone:)` reassigned
  `zoneId` on existing IDs only, dropping other fields; an LWW test used a local fold helper
  instead of the production merge path.
- **04 (z-order fractional index):** `FracIndex` missing `Hashable`; a `Tile.init(zIndex:)` shim
  defeated the compile-enforced migration (~185 call sites unmigrated); missing migration/backend
  tests + visual gate; and a real correctness bug — `.last` (0.75) is a reusable value, so
  `bringToFront`/spawn can hand out a duplicate `zPosition`; legacy migration overshoots `.last`.

- **04 retry (hardened loop, 3 rounds):** Opus cleared; Codex did not. Three concerns: (1)
  `CanvasEngine.bringToFront`/`WorkspaceDocument.bringZoneToFront` compute the promotion base from
  all *other* items then overwrite the target — if the target already has a large gap over the
  rest, promoting it can *lower* its z-position (target 0.99 vs. others maxing at 0.60 becomes
  0.675); added tests only cover a close promotion chain and miss this case. (2) Legacy `Tile`
  decode stores a placeholder `zPosition = 0.5` for `_legacyZIndex`, but rank-based redistribution
  only runs in `CanvasState`'s own decode path — `WorkspaceDocument` decodes embedded
  `groupZoneTiles` directly and never migrates their legacy ranks, so legacy group-zone tiles
  collapse to the same 0.5. No test covers that path. (3) Zone hit-testing
  (`CanvasNSView.tileId(at:)` / `zoneId(at:)`) still uses live-zone array/insertion order instead
  of sorting by the new `ZonePlacement.zPosition`, so front-to-back zone routing isn't actually
  driven by the migrated fractional index yet.

The full original notes are in the git history of this file (earlier `chore(overnight)` commits).
New attempts append their rows to the table above.

| 03-membership-tile-register.md | skipped | - | matrix: green | Hardened loop, 3 rounds, not cleared. Opus cleared; Codex did not: `CanvasState.currentSchemaVersion` bumped to 2, but a v1 project canvas loaded via `ProjectStore` keeps `schemaVersion == 1` and `saveCanvas` writes that value back unchanged — if `zoneId` is set on such a tile and saved, the file carries the new field while still declaring v1, so an old build accepts it and silently drops membership instead of hitting the intended v2 forward-incompat guard. Added v1 test only decodes the old shape, doesn't cover the real load→set zoneId→save→assert-schemaVersion-2 path. Working tree left dirty (uncommitted) for a human/next attempt to pick up. |
| 04-zorder-fractional-index.md | skipped | - | matrix: green | Hardened loop, 3 rounds, not cleared. Opus cleared; Codex did not — see "04 retry" notes above (bringToFront can lower an already-frontmost item; embedded `groupZoneTiles` legacy migration skipped; zone hit-testing still order-based, not zPosition-based). Working tree left dirty (uncommitted) for a human/next attempt to pick up. **2026-07-01 follow-up:** since 04 is permanently skipped (never re-attempted per policy) and 05 was next-ready, this dirty attempt was stashed rather than discarded so it wouldn't contaminate a new ticket's base — recoverable at `stash@{0}` ("wip: ticket 04 (zorder-fractional-index) hardened-loop rejected attempt, preserved for human review"). |
| 05-delete-tombstone.md | skipped | - | matrix: green | Hardened loop, 3 rounds, not cleared. Opus cleared; Codex did not: the new file `Sources/ContinuumRevivedSync/Tombstone.swift` was left **untracked** in git even though `Package.swift` adds/depends on the `ContinuumRevivedSync` target and `SpatialOpTests` imports `TombstoneSet`/`CompactionLedger` from it — the file never showed up in `git --no-pager diff`, so a plain commit of "the diff" would have silently omitted a required source file and left the package broken. Working tree left dirty (uncommitted, includes the untracked file) for a human/next attempt to pick up. **2026-07-01 follow-up:** since 05 is skipped and 06/07 (which depend on 03/04/05) stay blocked, 08 (deps only on 01/02, both done) was next-ready; this dirty attempt was stashed rather than discarded so it wouldn't contaminate 08's base — recoverable at `stash@{0}` ("wip: ticket 05 (delete-tombstone) hardened-loop rejected attempt, preserved for human review"). |
| 08-sync-observation-type-split.md | skipped | - | matrix: red (environment) | Hardened loop, 3 rounds, not cleared (Opus and Codex both withheld clearance on the same point). Implementation itself checks out: `swift build` clean, `ActivityStoreTests` all pass (logic + persistence round-trip + concurrent-append checks), no forbidden host-local fields on `AgentActivityEvent`, `apply(_:_:)` free function, only `main.swift` touched among existing files. The blocker is `./scripts/run-matrix.sh` failing at the pre-existing `--terminal-tmux-live-integration-check` with "timed out waiting for initial real terminal surface" — verified via `git stash -u` to reproduce the identical failure on baseline HEAD with zero ticket-08 files present, confirming it's a headless-sandbox environment limitation (no real terminal surface available), not a regression introduced by this ticket. Reviewers wouldn't clear with matrix red regardless of cause, so honestly skipped rather than fake-greened. Working tree left dirty (uncommitted, new files `ActivityStore.swift`/`AgentActivityEvent.swift`/`ActivityStoreTests.swift` + modified `main.swift`) for a human/next attempt to pick up on a machine with a real terminal surface. |
