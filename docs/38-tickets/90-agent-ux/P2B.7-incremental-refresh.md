# P2B.7 — Incremental refresh instead of full reload
Phase: 2B · Depends on: P2B.4 · Tag: autonomous · Execution-mode: medium

## Goal
Everything today is a full `reload(tree:)` — `WorkspaceSidebarView.reload` rebuilds all items, calls
`outlineView.reloadData()`, collapses everything and re-expands. With many agents streaming, that is
both expensive and visually jumpy (and it will fight the frozen-order requirement in P3.4).

## Files
- `Sources/ContinuumRevivedCore/AgentsBoardProjection.swift` (`applyEvent` already exists ~:65)
- `Sources/ContinuumRevived/App/ContinuumApp.swift` (snapshot maintenance from P2B.4)

## Approach
Maintain the snapshot incrementally with the existing `AgentsBoardProjection.applyEvent(_:to:)` rather
than recomputing from disk on every event. Recompute fully only on structural change (workspace switch,
tile add/delete, project open). Expose a change-set (added / updated / removed agent ids) so a future
list view can diff rows instead of reloading.

## Done when
An agent event updates the snapshot without a disk read, and the change-set names exactly what moved.

## Verify
Checks (extend `AgentsBoardProjectionTests`, which already asserts incremental-vs-batch fold equality):
folding N events incrementally equals building from scratch; the change-set for a single agent's event
contains only that agent.

## Watch out
- The fold is order-independent by design (canonical `(sequence, replicaId)` order) — do not
  "optimise" by assuming arrival order.
- Do not rewrite `WorkspaceSidebarView` here; the diffing consumer is Phase 3.
