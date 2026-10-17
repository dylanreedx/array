# 77 · Agent colour through the workspace API, and a guard for the next feature

Written 2026-10-17. Target: the next quick release. Small, but it touches the
workspace API contract, so it follows that contract's rules
(`CLAUDE.md` hazard 11).

## The ask (Dylan)

"Agents can change their colours right? If a user asks an agent tile to change a
colour of its or another agent's colour it can? How can we 1. get this adapted to
the Canvas API/MCP 2. make sure we can adapt future items."

## What is true today (checked at 8312b295)

1. Agent identity colour is not on `array/integration` yet. It is commit
   `d3db37d1` on `array/agent-colour` (bench `.worktrees/agent-colour`), owned by
   another session. **Wait for it to land.** Don't cherry-pick it, and don't
   edit that bench.
2. Even once it lands, only the menus can set it: the tile's menu and the
   sidebar row's menu.
3. The workspace API has 12 tools:
   - array_workspace_context
   - array_open_document
   - array_find_agent
   - array_inspect_agent
   - array_reveal_agent
   - array_message_agent
   - array_delegate
   - array_get_operation
   - array_canvas_query
   - array_canvas_apply
   - array_board_query
   - array_board_apply

   `array_canvas_apply` has only `Op { move, resize }`. No tool can set an
   agent's colour or a zone's colour, or rename anything.
4. So an agent asked "make yourself blue" has no tool for it.

## Part 1: expose identity colour

Where the API lives:
- Contracts: `Sources/ContinuumRevivedCore/WorkspaceAPI/WorkspaceAPIContracts*.swift`
- MCP catalog (claude, codex): `WorkspaceMCPToolCatalog.swift`
- Tool names: `Sources/ContinuumRevivedCore/Agents/ArrayWorkspaceTool.swift`
- pi extension: `Sources/ContinuumRevivedCore/Resources/PiExtensions/continuum-workspace-tools.ts`

The MCP catalog and the pi extension are fed from the same tool names, so one
new tool reaches all three CLIs. Confirm that in the code before relying on
it.

Shape. A proposal; read the contract before choosing:
- One update operation for agent appearance. Either a new op beside move/resize
  on `canvas.apply`, or an `agent.update` tool. Pick whichever matches how the
  contract already splits agent operations from canvas operations
  (`WorkspaceAPIContracts+Agents.swift` vs `+Canvas.swift`).
- Input: the target agent, plus `identityColor` set to a palette name or `null`
  for none.
- Validate against `ZoneColorConfig.palette`. Never accept hex; an agent must
  not invent a colour the UI can't show.
- Write through the same setter the menu uses (in `AgentSupervisor`, from
  d3db37d1). One writer means:
  - the title bar wash, the "Full border" outline and the sidebar dot all
    change together
  - the colour persists in `AgentRecord`
- Permissions: changing ANOTHER agent's colour is a cross-agent write. Gate it
  exactly as moving that agent's tile is gated: through the caller's grant, and
  `permission_denied` outside it. An agent may always change its own colour.
- Return the usual result shape: operation id, revision, committed or
  unchanged. Setting the colour it already has returns `unchanged`.
- It must not bump `interactionGeneration` (hazard 11b).
- Optional, same op family, only if cheap: zone colour. Leave renames out
  unless Dylan asks.

Witness (RED before, GREEN after; it must drive production):
- A new `--workspace-api-agent-colour-check`, or an arm in
  `--workspace-api-agents-check`. Enumerate the real flags first; never guess
  one.
- Drive the real API entry point:
  - one agent sets its own colour
  - then a second agent's colour, inside the grant
  - then one outside the grant, which must be refused
- Assert outcomes, not source text:
  - the tile's title-bar colour
  - the sidebar row's dot
  - the `AgentRecord` after a reload
  - an invalid name or a hex value is refused
- Extend `WorkspaceAPIContractChecks` (CoreChecks) for the request and result
  coding.
- Register the leg in `scripts/run-matrix.sh` and the matrix inventory
  (`docs/38-tickets/90-agent-ux/matrix-inventory.txt`). Then confirm a real
  matrix run prints it.

## Part 2: a guard so the next feature doesn't miss the API

Why this happened: identity colour shipped menu-only because nothing asks
"can agents do this too?" when a new user-editable field lands.

The guard:
- Keep one table of every user-editable property on agents, tiles and zones.
  Mark each one either `exposed(<operation>)` or `notExposed("<reason>")`.
  Good homes: the WorkspaceAPI folder, or beside `BuiltInSettingRegistry` if
  that fits better.
- Add a CoreChecks arm that reads the REAL field list from the code (for
  example the `CodingKeys` of `AgentRecord`, the zone record and the tile
  record, made `CaseIterable` if needed). It fails when a field has no entry in
  the table.
  - Never keep a second hand-written list of fields; a hand-kept list is how
    the claude model list hid Opus 5.5.
  - Fields that aren't user-editable (ids, timestamps, runtime state) still get
    an entry, marked `internal`. That way a new field always forces a decision.
- Teeth test: add a dummy field, see it go RED, and remove it. Record this in
  the commit body.
- Add a short "What a new user-editable property owes" note under hazard 11 in
  `CLAUDE.md`: an entry in that table, and if exposed, an operation plus a
  witness that drives it.
- First, search for an existing check like this (`grep -rn "exposed\|Exposure"
  Sources`). If one exists, extend it instead.

## Done means

- Agent colour can be set through the API by all three CLIs, with a witness
  that drives production.
- The parity guard is red when a field is unclassified, and green now.
- A full matrix run (`CONTINUUM_SKIP_UI_BASELINES=1`, private
  `TMUX_TMPDIR`) prints both new legs. The only failures are the KNOWN-RED legs
  and the capture-cli-fixtures leg, which has been failing since claude
  2.1.302.
- Commits go on a bench branch, as Dylan, with `type(area): description`
  subjects and no AI trailers. No push. Stop for Dylan's OK before merging into
  integration.
- `docs/user/` or `docs/internals/` gets a line on the new tool if an API page
  lists the tools there; check.
