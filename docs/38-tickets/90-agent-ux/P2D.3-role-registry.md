# P2D.3 — Role registry from `.pi/agents/*.md`
Phase: 2D · Depends on: P2D.2 · Tag: autonomous · Execution-mode: low

## Goal
Give roles a first-class home. Five already exist on disk — `code-reviewer`, `code-scout`,
`implementer`, `platform-breaker`, `qa-reviewer` — and `HarnessRoleParser` already reads their
frontmatter (`model`, `reasoning`, `tools`) and `HarnessRoleRunBuilder` already maps it to
`--model`/`--thinking`/`--tools`. This is a promotion, not new machinery.

## Files
- `Sources/ContinuumRevivedCore/Agents/RoleRegistry.swift` (new)
- reuse `Sources/ContinuumRevivedCore/HarnessRoleRun.swift` (`HarnessRoleParser`, `isValidRoleId`)
- `Sources/ContinuumRevived/App/ContinuumApp.swift` (discovery currently inline ~:4935)

## Approach
Move discovery out of the AppDelegate into a Core `RoleRegistry` (so it is check-testable): scan
`<projectRoot>/.pi/agents/*.md`, parse via `HarnessRoleParser`, expose
`roles() -> [HarnessRole]` and `role(id:)`. A spawn's `role` resolves through it to model/thinking/tools;
an unknown role id is an error, not a silent default.

## Done when
`RoleRegistry` lists the five real roles from this repo, and a spawn with `role: "code-scout"` inherits
that role's model/reasoning/tools.

## Verify
Checks against a temp dir with two fixture role files (one valid, one missing `name`): valid parses,
invalid is skipped; unknown id returns nil; a role's `model`/`reasoning` map to the same flags
`HarnessRoleRunBuilder` produces (assert agreement so the two paths cannot drift).

## Watch out
- A role's `model` may be a bare alias while P0.10 requires fully-qualified ids — resolve through
  `AgentModelConfig` and fail loudly on an unqualified id rather than letting fuzzy matching back in.
- Role *ids* are I5-safe to publish; role file *paths* are not.
