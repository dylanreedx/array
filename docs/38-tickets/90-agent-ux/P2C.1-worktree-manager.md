# P2C.1 — WorktreeManager
Phase: 2C · Depends on: P2B.8 · Tag: autonomous · Execution-mode: medium

## Goal
`AgentDescriptor.worktreePath` exists as a field but **nothing ever runs `git worktree`** — every real
caller passes `projectRoot.path`, the main checkout. So N parallel agents would edit one working tree
and clobber each other. This is a hard prerequisite for the orchestrator (2D).

## Files
- `Sources/ContinuumRevivedCore/Agents/WorktreeManager.swift` (new)
- `Sources/ContinuumRevivedCoreChecks/WorktreeManagerChecks.swift` (new)

## Approach
```swift
public struct WorktreeManager {
    public static func slug(role: String?, prompt: String?, id: AgentID) -> String  // pure, deterministic
    func add(repo: URL, slug: String) throws -> (path: URL, branch: String)
    func list(repo: URL) throws -> [(path: URL, branch: String)]
    func remove(repo: URL, path: URL, force: Bool) throws
}
```
Shell out to git the way `GitDiffEngine` already does (reuse its process/executable-resolution pattern
rather than inventing one). Layout: `<repo>/.worktrees/<slug>`, branch `agent/<slug>`. `slug` must be
filesystem- and ref-safe: lowercase, `[a-z0-9-]`, collapse runs, truncate, and suffix with a short id
prefix so two "fix auth" agents cannot collide.

## Done when
Add/list/remove work against a real temp repo, and slugs are deterministic and safe.

## Verify
`WorktreeManagerChecks` against a temp `git init` repo (create a commit first — `git worktree add`
needs a HEAD): add → the dir and branch exist and `list` reports them; remove → gone; adding the same
slug twice fails cleanly rather than corrupting; slug purity: no `/`, no spaces, no uppercase, stable
across calls, and two different ids yield different slugs for identical role+prompt.

## Watch out
- A branch that already exists must not be silently reused — that would put two agents on one branch.
- `.worktrees/` should be gitignored in the host repo; check and add it if absent (note it in the commit).
- Do not `git worktree add` in the checks without a temp repo — never touch the real repository.
