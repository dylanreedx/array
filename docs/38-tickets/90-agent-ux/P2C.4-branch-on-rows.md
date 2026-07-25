# P2C.4 — Surface branch + worktree on rows and in the tile
Phase: 2C · Depends on: P2C.3 · Tag: autonomous · Execution-mode: low

## Goal
If an agent is working on its own branch, that has to be visible — otherwise you cannot tell which of
five agents is about to touch your current checkout.

## Files
- `Sources/ContinuumRevivedCore/Agents/AgentContextIndex.swift` (from P2B.3)
- `Sources/ContinuumRevived/Canvas/ManagedAgentTileNSView.swift` (header)

## Approach
Add `worktreeBranch` and an `isIsolated` flag to the context, render as a compact chip in the tile
header (tokens from P1.3, type from P1.4). Add a **branch-mismatch warning** when the agent's branch is
not the repo's currently checked-out branch — T3 Code surfaces exactly this and it prevents a whole
class of confusion.

## Done when
An isolated agent's tile shows its branch; a mismatch against the current checkout is visibly flagged.

## Verify
Geometry/contrast gates (P0.3/P0.4) cover the new chip. Add a Component Lab entry with three states
(no worktree · isolated matching · isolated mismatched) so baselines (P0.6) cover it.

## Watch out
- **I5:** the branch *name* may cross to the phone; the worktree **path** must not.
- Reading the repo's current branch is I/O — cache it, do not shell out per render.
