# P2C.5 — Per-agent diff
Phase: 2C · Depends on: P2C.4 · Tag: autonomous · Execution-mode: medium

## Goal
"What did this agent actually change?" is the first question on finishing. With a worktree per agent
the answer is a clean, attributable diff — and it feeds review-cost ordering later (P9.4).

## Files
- `Sources/ContinuumRevivedCore/Agents/AgentDiffSource.swift` (new)
- reuse `Sources/ContinuumRevivedCore/DiffReviewSource.swift` and `GitDiffEngine`

## Approach
For an isolated agent: diff `agent/<slug>` against its merge-base with the branch it forked from, in
that worktree. For a non-isolated agent there is no attributable diff — return `nil` rather than
guessing (the repo diff belongs to whoever touched it). Expose a summary
`(filesChanged: Int, insertions: Int, deletions: Int)` plus the existing `DiffReviewSource` payload for
a full view.

## Done when
An isolated agent reports accurate counts; a non-isolated agent reports `nil`.

## Verify
Temp-repo checks: create a worktree, commit two files, assert counts; assert `nil` for a
non-isolated agent; assert a merge-base diff (not a diff against the branch tip) so commits landing on
the base branch afterwards do not inflate the agent's numbers.

## Watch out
- Merge-base matters: diffing against the moving base branch tip will attribute other people's commits
  to this agent.
- Counts only here. Rendering is Phase 3; review-cost ordering is P9.4.
- Do not send file **paths** to the phone — counts are I5-safe, paths are not.
