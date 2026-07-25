# P2C.3 — Cleanup and orphan repair
Phase: 2C · Depends on: P2C.2 · Tag: autonomous · Execution-mode: medium

## Goal
Worktrees must not outlive their agents, or the repo accumulates dead trees and stale branches until
`git worktree list` is unusable.

## Files
- `Sources/ContinuumRevived/App/AgentSupervisor.swift`
- `Sources/ContinuumRevivedCore/Agents/WorktreeManager.swift`

## Approach
On agent **archive/delete** (not on tile close — see P2A.5): remove the worktree, and delete the branch
**only if it is fully merged or has no commits**; otherwise keep the branch and say so, because
discarding unmerged agent work silently is unacceptable. Add
`orphans(repo:knownAgents:) -> [(path, branch)]` for worktrees whose agent record is gone, plus a
`repair` that prunes them (`git worktree prune`) after reporting.

## Done when
Archiving an isolated agent removes its worktree, preserves unmerged work, and orphans are detectable.

## Verify
Temp-repo checks: archive → worktree gone, branch gone when empty/merged; with an unmerged commit →
worktree gone but branch **retained** and reported; delete a record behind the supervisor's back →
`orphans` lists it and `repair` prunes it.

## Watch out
- **Never** `git branch -D` unmerged work. Losing an agent's commits is worse than leaving a branch.
- `git worktree remove` refuses when the tree is dirty; decide deliberately (report, or `--force` only
  when the agent is archived AND the diff was captured). Document the choice in the commit body.
