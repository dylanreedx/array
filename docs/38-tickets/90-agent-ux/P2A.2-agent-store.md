# P2A.2 — App-level AgentStore (cross-project)
Phase: 2A · Depends on: P2A.1 · Tag: autonomous · Execution-mode: medium

## Goal
Agents must be listable across every project and workspace. `ManagedAgentSessionStore` writes one
JSON file per tile under `ProjectStoreLayout.managedSessionsDirectory` — i.e. **per project** — and
only `activeController.managedSessionStore` is reachable at runtime, so a cross-project inbox is
impossible today.

## Files
- `Sources/ContinuumRevivedCore/Agents/AgentStore.swift` (new)
- `Sources/ContinuumRevivedCoreChecks/AgentStoreChecks.swift` (new)

## Approach
Follow `ManagedAgentSessionStore`'s shape exactly (`AtomicWriter`, one JSON file per record,
`upsert`/`load(id:)`/`delete(id:)`/`loadAll()`) but rooted in **application support**, not the
project: `~/Library/Application Support/continuum-revived/agents/<agentId>.json`. Reuse the existing
app-support path resolver (`AppDelegate.resolveAppSupportDir(smokeTest:)` has the convention;
put the pure path logic in Core so it is testable).

Injectable root directory so checks use a temp dir.

## Done when
`loadAll()` returns agents from every project; `upsert` is atomic; a corrupt single file does not
take down the whole load (skip it, log, keep going).

## Verify
`AgentStoreChecks` against a temp root: upsert/load/delete round-trip; `loadAll` ordering is
deterministic (sort by `createdAt` then id); a truncated/garbage JSON file is skipped rather than
throwing; concurrent `upsert` of two agents does not lose either (AtomicWriter guarantees).

## Watch out
- Do not reuse the project store's directory — that is the mistake being fixed.
- The smoke-test path must be isolated (see `resolveAppSupportDir(smokeTest:)`) or checks will
  pollute the real store.
- No migration of existing managed records here; P2A.7 owns that.
