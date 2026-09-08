# CX-01 handoff — workspace API Phase 0 + Phase 1 (2026-09-08)

Status: **implementation ready; end-to-end verification pending.** Everything
below is committed on `array/cx01-canvas-api` (worktree
`/Users/dylan/array-worktrees/cx01-canvas-api`, base `98e56e11`). Not merged,
not pushed. Design and the full implementation record: the CX-01 packet in
`.plans/59-parallel-product-investigations/canvas-awareness-api-design.md`
(§24) — that packet lives untracked in Dylan's main checkout.

## Commits

| SHA | Increment |
|---|---|
| `b2d15089` | Core v1 contracts; AgentRecord policy flag + Settings default; WorkspaceRuntime preflight/ensureSpawner/executeOpen split; interaction generation + structural revision; CanvasNSView readers |
| `efb42157` | Pi bridge: PiHostToolBridge, translator/runner state machine, bundled `continuum-workspace-tools.ts`, roled-pi host tools; harness + RoleRegistry check expectations |
| `662e4af4` | WorkspaceAPIService, AppDelegate/AgentSupervisor wiring, approval alert, three app legs + two CoreChecks sections + three targeted arms, matrix legs and inventory, AGENTS hazard 11, docs index |

## What a reviewer should read first

1. `Sources/ContinuumRevivedCore/WorkspaceAPI/WorkspaceAPIContracts.swift` — the frozen surface.
2. `Sources/ContinuumRevived/App/WorkspaceAPIService.swift` — `dispatch` is the §14.2 pipeline; `present` is §16.
3. `Sources/ContinuumRevived/App/WorkspaceRuntime.swift` — the `openDocument` tail and the new MARK section below it.
4. `Sources/ContinuumRevivedCore/AgentProviders/PiRpcAgentRunner.swift` — the bridge state machine; `PiHostToolBridge.swift` for the value types.
5. `Sources/ContinuumRevivedCore/Resources/PiExtensions/continuum-workspace-tools.ts`.
6. `Sources/ContinuumRevived/App/WorkspaceAPIChecks.swift` — the fixture is the acceptance scenario in code.

## How to verify (Debug, worktree, isolated)

```sh
cd /Users/dylan/array-worktrees/cx01-canvas-api
swift build --product Array && swift build --product ContinuumRevivedCoreChecks
.build/debug/ContinuumRevivedCoreChecks --workspace-api-contract-check
.build/debug/ContinuumRevivedCoreChecks --pi-host-tool-bridge-check
.build/debug/ContinuumRevivedCoreChecks --role-registry-check
for leg in workspace-api-open-check workspace-api-grants-check workspace-api-pi-bridge-check; do
  CONTINUUM_PROJECT_ROOT=$(mktemp -d) CONTINUUM_APP_SUPPORT=$(mktemp -d) \
    .build/debug/Array --$leg -continuum.terminal.tmux.enabled NO -continuum.terminal.tmux.path ""
done
```

All of the above were green at `662e4af4`. A headless `CONTINUUM_SKIP_UI_BASELINES=1
scripts/run-matrix.sh` run recorded five failures, triaged in the packet §24:
one was ours (supervisor `--tools` pin, fixed and re-run green); the palette-
over-browser leg fails identically on the pristine `98e56e11` binary; the tmux-
live leg needs a TTY; theme fidelity failed under load and passes standalone;
the bundle probe failed only on that theme self-check. The full CoreChecks run
stops at the load-sensitive real-tmux legs before the new sections, hence the
targeted arms. Re-run the matrix from a real terminal session before merging.

## The one thing that is NOT done: real managed-pi acceptance

Needs a coordinator-assigned Dev lane: a disposable project root outside
`~/Documents`, isolated `CONTINUUM_APP_SUPPORT`, never the shared preview or
`/Applications/Array.app`. Then:

1. Launch the Debug binary from this worktree with `open --env` and those two
   variables (tmux disabled). Note `~/.pi/agent/extensions` before and after: it
   must not change.
2. Create a pi agent, enable Workspace Tools for it (Settings default for new
   agents, or `AgentSupervisor.setWorkspaceToolsEnabled` — there is no per-agent
   menu item yet).
3. Prompt: "Call array_workspace_context and quote zoneId and checkoutHandle.
   Then open notes/README.md with array_open_document, camera preserve, and
   quote the tileId." Expect a tile; the session file's toolResult text is the
   `array.workspace.v1` JSON with that tileId; the system prompt carries
   `# Array workspace context`.
4. Open a missing file → the model quotes `not_found`.
5. Two parallel opens → two distinct tileIds.
6. Set `CONTINUUM_WORKSPACE_API_DELAY_MS=8000` (Debug only), open, press Stop
   inside the window → tool result `cancelled`; the next prompt's context
   `recentOperations` shows `cancelledBeforeEffect` (no tile) or
   `committedAfterCancel` with the tileId.
7. A roled agent proves the `--tools` append; stopping mid-request then
   prompting again proves `droppedRunnerGone` (stderr) and no stray result.

If pi cannot resolve the extension's imports from the bundle path, fall back to
installing it through `PiExtensionInstaller` gated on
`CONTINUUM_ARRAY_MANAGED_AGENT=1` (the extension already checks that marker).

## Open decisions for Dylan

- Per-agent revocation UI: the setter exists and revokes immediately; exposing
  it means an `InboxRowAction` pair (touches the inbox row model and checks).
- Harden `PiRpcTransport.writeLine` behind a write queue (three writers now).
- Interaction-generation gaps: keyboard camera jumps and palette-spawn focus.
- Phase 2 (inspection, visible delegation) is NOT started, per the assignment.
