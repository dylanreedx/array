# P2B.6 — Stop `applyObserverStatuses` nil-ing managed tiles' badges
Phase: 2B · Depends on: P2B.5 · Tag: autonomous · Execution-mode: low

## Goal
`applyObserverStatuses` (`ContinuumApp.swift` ~:4545) loops **all** tiles and assigns
`canvasBadgeStatus(statuses[tile.id])` — which is `nil` for managed-agent tiles, so it actively erases
the status the managed tile just computed for itself. A one-line class of bug with a visible symptom.

## Files
- `Sources/ContinuumRevived/App/ContinuumApp.swift` (~:4545)

## Approach
Assign from the unified snapshot (P2B.4). If an entry is absent for a tile, **leave the existing badge
alone** rather than writing `nil` — absence of information is not information.

## Done when
A managed agent's badge survives an observer status sweep.

## Verify
Check: set a managed tile's status via its own ingest path, trigger an observer sweep that has no entry
for it, assert the badge is unchanged. This is the regression witness — it must FAIL if the `nil`
assignment returns.

## Watch out
- Do not flip the default the other way for terminal tiles: a terminal that genuinely went idle must
  still be able to clear its badge. Distinguish "no entry" from "entry says nil".
