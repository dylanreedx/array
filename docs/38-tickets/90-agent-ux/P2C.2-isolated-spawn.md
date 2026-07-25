# P2C.2 — `isolated:` spawn creates the worktree
Phase: 2C · Depends on: P2C.1 · Tag: autonomous · Execution-mode: medium

## Goal
Let a spawn opt into isolation so its agent works on its own branch in its own directory.

## Files
- `Sources/ContinuumRevived/App/AgentSupervisor.swift`
- `Sources/ContinuumRevivedCore/Agents/AgentRecord.swift` (`cwd`, `worktreeBranch` already present from P2A.1)

## Approach
`supervisor.spawn(..., isolated: Bool)`. When true: `WorktreeManager.add`, set `AgentRecord.cwd` to the
worktree path and `worktreeBranch` to the created branch; the runner's `Config.cwd` follows. When false:
`cwd` is the project root (today's behaviour, unchanged default).

Failure to create a worktree must fail the spawn with a clear error — do NOT silently fall back to the
main checkout, which would reintroduce exactly the clobbering this prevents.

## Done when
An isolated spawn runs its agent in `<repo>/.worktrees/<slug>` on `agent/<slug>`; a non-isolated spawn
behaves as before.

## Verify
Extend `--agent-supervisor-check` with a temp repo and the stub runner: isolated spawn → record's `cwd`
is inside `.worktrees/`, branch matches, and the stub's working directory is the worktree. Assert the
no-fallback rule: make `add` fail and assert `spawn` throws rather than returning a main-checkout agent.

## Watch out
- Disk cost is real; one worktree per agent adds up. Cleanup is P2C.3 — do not skip it.
- Do not make `isolated` default true in this ticket; that is a UX decision for the spawn surface.
