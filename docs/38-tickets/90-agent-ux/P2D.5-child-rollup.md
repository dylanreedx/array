# P2D.5 — Child rollup on the parent row
Phase: 2D · Depends on: P2D.4, P4.2 · Tag: autonomous · Execution-mode: medium

## Goal
A collapsed parent must still tell you whether anything under it needs you — otherwise collapsing hides
exactly the thing the inbox exists to surface.

## Files
- `Sources/ContinuumRevivedAgentUI/AgentInboxRow.swift`
- `Sources/ContinuumRevivedCore/AgentsBoardProjection.swift`
- lifecycle: `effectiveSettled` from P4.2

## Approach
Compute a rollup on each parent: `(children: Int, working: Int, needsYou: Int, failed: Int)` and render
it as a compact secondary line ("3 children · 1 needs you"). Reuse the **blocker precedence** rule from
P4.2: a parent is **not settleable while any child is blocked or running**, exactly as a blocked agent
outranks an explicit settle. That single rule keeps collapsed groups honest.

## Done when
A collapsed parent shows its rollup, and settling a parent with a blocked child is refused.

## Verify
Pure checks: rollup counts correct across mixed child states; `effectiveSettled(parent)` returns
`active` while a child is blocked even with `settledOverride == .settled`; when all children settle,
the parent becomes settleable. This is a precedence-matrix addition to P4.13.

## Watch out
- Do not double-count grandchildren if a depth cap of 2 is allowed — decide and assert whether the
  rollup is direct-children-only or transitive.
- The rollup must be derived, never stored, or it will go stale.
