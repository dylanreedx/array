# Agent identity colour through the workspace API

`array_update_agent` calls `agent.update` in `array.workspace.v1`. Claude Code
and Codex receive it through MCP; Pi registers it from the same bundled JSON
catalog, including for agents with role-based tool allowlists.

Pass `agentId` and an explicit `identityColor`: `teal`, `blue`, `mint`, `purple`,
`orange`, `yellow`, `red`, or `null` to clear. Missing values, hex, and other names
are invalid. `ZoneColorConfig.palette` owns validation. `idempotencyKey` is
optional; retry the same intent with the same key. A different payload behind a
remembered key returns `idempotency_conflict`.

With Workspace Tools enabled, an agent can change its own colour without an
extra prompt. Updating another agent requires the same checkout and project,
and the caller's canvas-write grant. Missing legacy project stamps resolve
through the explicit checkout handle, never the active project. The first request can ask for that grant;
its approval explicitly covers tile moves/resizes and agent colours. Once and
session grants behave as for `canvas.apply`; out-of-scope targets return
`permission_denied` before prompting. Inspecting or delegating does not grant
canvas writes.

The response includes `operationId`, `agentId`, actual `identityColor` (including
explicit `null`), current workspace `revision`, and `durability` (`committed` or
`unchanged`). The shared supervisor setter saves before publishing changes to
views. A failed save returns `outcome_unknown` with `durability_failed`, rather
than claiming a commit. Recent operations record the outcome.

Colour updates preserve workspace, armed zone, focus, selection, camera and
geometry. They advance neither the structural revision nor user interaction
generation. They require no tile hydration or provider process.

`--workspace-api-agent-colour-check` drives production boot mounting, dispatch,
MCP and Pi host entry points. It observes rendered title bar, full border and
sidebar dot, disk reload, grant boundaries, idempotency, cancellation,
revocation, and a real filesystem save failure. `--agent-identity-color-check`
continues to witness native menus and preferences.

Every persisted field in `AgentRecord`, `Tile`, `TileMetadata`, and
`ZonePlacement` has an explicit decision in `WorkspaceAPIExposure`. Its field
census is derived from those models' actual coding keys, without a separate
handwritten census. `--workspace-api-exposure-check` rejects missing or stale
decisions, blank exclusion reasons, and exposed operations without a published
tool. This leg also runs the API request/result coding contracts, which the
full CoreChecks run can otherwise miss behind its inherited RED. New exposed
properties also need a production API witness.
