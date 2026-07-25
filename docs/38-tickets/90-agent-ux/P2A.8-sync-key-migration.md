# P2A.8 — Sync aggregate key: tileId → agentId
Phase: 2A · Depends on: P2A.7 · Tag: autonomous · Execution-mode: high

## Goal
`AgentActivityEvent.tileId` is the aggregate key for everything the phone renders. Once an agent can
exist without a tile, keying activity by tile is wrong: a headless agent could not be observed at
all. This is the riskiest ticket in the program — it touches the I5 sync boundary.

## Files
- `Sources/ContinuumRevivedCore/AgentActivityEvent.swift` (`AgentActivityEvent`, `TileActivity`, `ActivityLogSnapshot`, `apply`)
- `Sources/ContinuumRevivedCore/AgentsBoardProjection.swift`
- `Sources/ContinuumRevivedSync/DesktopCompanionSyncService.swift`
- `Sources/ContinuumRevivedCore/AgentProviders/ManagedAgentActivityBridge.swift`
- `ios/Continuum/Sources/ContinuumApp.swift`
- checks: `AgentsBoardProjectionTests`, `ActivityStoreTests`, `DesktopCompanionSyncPublisherTests`, `ManagedAgentActivityBridgeChecks`

## Approach
Rename the aggregate key to `agentId` and add `tileId: UUID?` as an **optional view hint** (used only
by the phone's "Show on canvas"). Bump the event's `schemaVersion`/coding keys and decode
**forward-compatibly**: an old payload with only `tileId` decodes with `agentId = tileId` (they were
the same value historically), so a phone on an older build and a desktop on a newer one still
interoperate. Update `apply`'s `byTile` → `byAgent` and every consumer.

**I5 re-verification is part of this ticket, not a follow-up:** re-run the taint scan over the new
payload, confirm `agentId` carries no host-bound data (it is an opaque UUID), and confirm the
optional `tileId` adds no path/pid. Keep the `summary`-is-generic rules from the bridge intact.

## Done when
Desktop publishes agent-keyed activity; iOS renders it; an old-format payload still decodes; the
matrix (incl. the iOS build leg) is green.

## Verify
- Codable: a fixture of the OLD shape decodes with `agentId == tileId` (commit the fixture).
- `apply` fold determinism/order-independence checks still pass, now keyed by agent.
- I5: `SyncPayloadTaint.violations` empty for the new `SyncMessage.activity`; the existing
  secret/path witnesses in `ManagedAgentActivityBridgeChecks` still FAIL as designed.
- iOS: build green; the timeline still renders (its `AgentsBoardRow.id` becomes the agent id).

## Watch out
- **Do not** carry `cwd`, `worktreeBranch`, or a role *path* across the boundary. Role *id* is fine;
  a path is not.
- The phone's `canvasFocusRequest` uses the tile id — keep that working via the optional hint, and
  handle "agent has no tile" in the UI (the button should be absent, not broken).
- If the migration cannot be completed with a green matrix, mark BLOCKED rather than leaving the
  sync boundary half-migrated. A partially-renamed key is worse than either state.
