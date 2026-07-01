# Overnight execution progress

Durable ledger for the Ralph loop. One row per attempted ticket. Source of truth for "done"
alongside the git log on `overnight/agent-orchestration`.

| ticket | status | commit | matrix | note |
| --- | --- | --- | --- | --- |
| (infra, not a ticket) | done | f42102a | matrix: green | Pre-existing bug: `zoneBoundsConfig group8` check read moved SettingsSchema keys from the wrong section and `exit(1)`'d, silently skipping half the suite. Fixed. |
| (infra, not a ticket) | done | eb7d4fe | n/a | Harness bug: implementer repo path hardcoded to the wrong checkout. Fixed. |
| 01-store-protocol-seam.md | done | c71d601 | matrix: green | Clean; both reviewers cleared. |
| 02-op-enum-logged-op-envelope.md | done | a4cba75 | matrix: green | Hand-resolved; frozen wire format, full matrix passed. |

## Reset for the Fable-orchestrated retry (2026-07-01)

Config now: **Fable 5 orchestrates** each iteration, **Sonnet 5 implements**, **Opus + GPT-5.5
review**; the loop's matrix skips the four terminal-**surface**-rendering checks (they can't run
headless — a supervised GUI matrix pass covers them); new files are `git add -N`'d so reviewers see
them. Tickets 03,04,05,08,10,12,14 are reset to un-attempted so the new config re-drives them. The
implementer is instructed to read these prior findings first. Rejected dirty attempts for 04/05/08/10/12
were **stashed** (recoverable via `git stash list`) for human review.

**Prior findings to address on re-attempt:**
- **03 (membership register):** bump-then-save schema-version bug — a v1 canvas loaded via `ProjectStore`
  keeps `schemaVersion==1`; saving with `zoneId` set writes the new field under a v1 declaration, so an
  old build silently drops membership instead of hitting the v2 guard. Also: register must be wired into
  production rendering (`WorkspaceRuntime` gated on `projectId != nil`; `CanvasNSView` used a geometry map,
  not `setTileZone`); `setTiles(_:forZone:)` dropped non-`zoneId` fields; an LWW test used a local fold
  helper, not the production merge path.
- **04 (z-order fractional index):** `FracIndex` needs `Hashable`; remove the `Tile.init(zIndex:)` shim and
  migrate ALL ~185 call sites (compile-enforced); `bringToFront` must not lower an already-frontmost item;
  `WorkspaceDocument` embedded `groupZoneTiles` legacy ranks must be migrated (not collapsed to 0.5); zone
  hit-testing must sort by `zPosition`, not array order; add migration/backend tests.
- **05 (delete tombstone):** the new `ContinuumRevivedSync/Tombstone.swift` was left untracked while
  `Package.swift`/tests depend on it — the `git add -N` rule now fixes this; ensure the new target's files
  are all tracked so a plain commit doesn't break the package.
- **08 (sync/observation type split):** implementation was CLEAN — its only blocker was the headless
  surface-check matrix failure, now fixed. Should pass now.
- **10 (session topology snapshot):** clean; blocked by the surface-check + an untracked new file — both
  now fixed. Should pass now.
- **12 (injectable substrates):** clean (`TransportLoggedOp` naming collision with ticket 02 resolved);
  blocked only by the surface check — now fixed. Should pass now.
- **14 (project session naming):** must actually construct a `ZoneRuntimeController` via the lock-free
  init and exercise `projectSessionName()` / `killProjectSessionCommand()` (the surrogate check only hit
  the pure `TmuxSession.*` statics — zero coverage on the new controller methods). Add the assertion to the
  ComponentLab self-check. Also drop the inline comment claiming `ProjectStore` has no protocol — it does
  (`StoreProtocols.swift:5 ProjectStoring`).

New attempts append their rows to the table above.
