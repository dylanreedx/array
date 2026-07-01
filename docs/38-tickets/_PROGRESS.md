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

The full original notes are in the git history of this file (earlier `chore(overnight)` commits).
New attempts append their rows to the table above.

| 03-membership-tile-register.md | skipped | - | matrix: green | Hardened loop, 3 rounds, not cleared. Opus cleared; Codex did not: `CanvasState.currentSchemaVersion` bumped to 2, but a v1 project canvas loaded via `ProjectStore` keeps `schemaVersion == 1` and `saveCanvas` writes that value back unchanged — if `zoneId` is set on such a tile and saved, the file carries the new field while still declaring v1, so an old build accepts it and silently drops membership instead of hitting the intended v2 forward-incompat guard. Added v1 test only decodes the old shape, doesn't cover the real load→set zoneId→save→assert-schemaVersion-2 path. Working tree left dirty (uncommitted) for a human/next attempt to pick up. |
