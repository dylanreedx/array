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

---

# Update — 2026-09-08, four parallel tracks integrated

Everything below is merged into `array/cx01-canvas-api` (tip `a61a0555`, base
`98e56e11`). Not merged to integration, not pushed. Four feature branches remain
as the reviewable units: `array/cx01-hardening`, `array/cx01-inspection`,
`array/cx01-geometry`, `array/cx01-delegation`.

## The operation surface now

| Op | Preset? | Owner route |
|---|---|---|
| `workspace.context` | yes | host projection |
| `artifact.open` | yes | `WorkspaceRuntime.preflightExplicitOpen` + `executeOpen` |
| `agent.find` | yes (own checkout, metadata only) | supervisor records + pure `AgentFindRanker` |
| `agent.inspect` | yes for SELF; other agents need approval | read-only transcript projection |
| `canvas.query` | yes | `snapshot(...)` → `CanvasEntityIndex` |
| `canvas.apply` | **no** — approval | the drag's own `beginGeometryEdit`/`commitGeometryEdit` path |
| `agent.delegate` | **no** — approval | `AgentSupervisor.handleSpawnRequest` (the `spawn_agent` path) |
| `agent.reveal` | yes | the existing reveal/present machinery |
| `operation.get` | yes | in-memory operation store, 200 live + 2000 tombstones |

The single authorization source is `WorkspaceAPIOp.sessionPresetOperations`
(defined in `WorkspaceAPIContracts+Canvas.swift`, consumed by `phase1Preset`).
The two withheld ops go through `presentWorkspaceToolApproval`, whose alert text
branches per op. `workspace.context.capabilities` advertises the preset only, and
a Core assertion pins the full wire order of `WorkspaceAPIOp`.

## Hardening landed

Pi stdin writes are serialized behind one queue in `PiRpcTransport`, witnessed by
eight concurrent 200 KB frames. `noteUserInteraction()` now fires at five user
seams (reveal-for-work, the shared zone-jump landing, fit-all, restore-previous,
palette spawn focus), so a stale `expectedInteractionGeneration` defers
presentation. The managed-agent tile menu carries a `Workspace Tools` checkmark
item that revokes grants immediately.

## Verified on the merged tree (Debug, isolated temp roots, tmux disabled)

App legs, all PASS: `--workspace-api-open-check`, `--workspace-api-grants-check`,
`--workspace-api-agents-check`, `--workspace-api-canvas-check`,
`--workspace-api-delegation-check`, `--workspace-api-pi-bridge-check`, plus
`--strict-agent-harness-check`, `--agent-supervisor-check`,
`--workspace-scene-owner-check`, `--zone-arming-check`,
`--agent-local-file-link-check`, `--agent-inbox-check`,
`--managed-agent-page-zoom-check`, `--canvas-persistence-model-check`,
`--zone-save-isolation-check`.

CoreChecks arms, all PASS: `--workspace-api-contract-check`,
`--workspace-api-agents-contract-check`, `--workspace-api-canvas-contract-check`,
`--workspace-operation-store-check`, `--role-registry-check`,
`--pi-host-tool-bridge-check`, `--pi-rpc-transport-check`.

`matrix-inventory.txt` regenerated (450 records) and `check-matrix-inventory.sh`
passes. Six workspace-api legs are registered in `scripts/run-matrix.sh`.

## Merge decisions a reviewer should check

- One preset set replaced the three tracks' separate constants; `agent.inspect`
  is preset-granted for SELF only, enforced by `inspectableAgentIds`.
- `WorkspaceContextResponse.encodedByteCeiling` is 1280. Capabilities are
  authorization truth and must stay complete, so the ops spend budget and the
  ceiling sheds `recentOperations` last.
- The roled-pi `--tools` allowlist now carries nine host tools; the pinned argv
  in `StrictAgentHarnessChecks` and `RoleRegistryChecks` was updated in step.
- The append-order assertion was widened from "the last two cases" to the full
  ordered list, so any new op must update it deliberately.

## Still not done

Real managed-pi acceptance for all nine tools, in a coordinator-assigned Dev
lane, per the procedure above. The extension TypeScript has no type-check gate.
A full matrix run from a real terminal session is still owed before merge.

## Protocol note

While probing for a spawn-extension check, the delegation track ran
`.build/debug/ContinuumRevivedCoreChecks` once with no arguments and without
`TMUX_TMPDIR` isolation. That bare run includes real-tmux coverage on the default
socket, which AGENTS.md forbids while Array may be running. It was not repeated
and no tmux server was inspected or killed, but it is recorded here because the
live app could have been disrupted.

---

# Update — a tenth op, `agent.message` (children only)

| Op | Preset? | Owner route |
|---|---|---|
| `agent.message` | **no** — approval | `AgentSupervisor.send` (the composer's own send path) |

Scope IS the feature: deliverable only when the target's `parentAgentID` is the
caller. A sibling, the caller's own parent, another agent's child and a target
outside the caller's checkout are all `permission_denied` with one message that
names no path and no id (so a refusal does not even confirm which ids exist);
SELF is `invalid_request`. Two gates enforce it — the resolve guard and a recheck
immediately before delivery — and removing only one leaves the leg green, which
is why the teeth test had to remove both.

`agent.message` is withheld from `sessionPresetOperations`, so the first message
per agent session goes through `presentWorkspaceToolApproval` (its own alert
branch, naming the child); an approved DELEGATION grants nothing here.
`workspace.context.capabilities` still lists seven, unchanged.

The result reports DELIVERY only — `delivery` (`delivered | queued | refused`),
`childAgentId`, `parentAgentId`, `childRunning`, `queuePosition`,
`refusalReason`, `operationId`, plus the presentation pair. Never the child's
answer; the tool guidance sends the model to `wait_agents` / `array_inspect_agent`
for that. `queued` is vocabulary the send path does not yet produce:
`AgentSupervisor.send` either starts the turn on the child's own runner or
declines, so a mid-turn child is `refused` with the reason rather than
double-prompted. The catalogue seam (`AgentSupervisor.sendRefusal`: harness
`.ready` AND the record's model listed) surfaces as a structured `unsupported`.

`idempotencyKey` is required and reuses the `agent.delegate` operation store:
same key + same text replays the first outcome and delivers nothing; same key +
different text is `idempotency_conflict`; a failure that delivered nothing does
not burn the key. Text is capped at 8 KB of UTF-8 and may not be blank.

Witnesses: `--workspace-api-delegation-check` acts I–N (delivery evidence is the
child's OWN fake-pi `prompts.log`, counted, and watched for a bounded window so
an async second write cannot sneak past a single sample), the Core section behind
`--workspace-operation-store-check`, and STEP 12 of `--workspace-api-demo`.
`array_message_agent` is the tenth roled-pi host tool; real pi parses the edited
extension (`--pi-extension-load-check`). No new check leg, so `run-matrix.sh` and
`matrix-inventory.txt` are unchanged.
