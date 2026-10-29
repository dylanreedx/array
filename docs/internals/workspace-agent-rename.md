# Renaming agents: tile, sidebar and workspace API

An agent's name is its record's `displayName`, and `displayNameSource` says
who chose it. Every rename, from any surface, goes through
`AgentSupervisor.rename(agentID:to:source:)`. It sanitises the name the same
way for everyone (`AgentName.fromExplicitName`: whitespace collapsed, controls
stripped, 240-character storage cap), disarms any in-flight automatic naming,
saves before publishing, and fires `onDisplayNameRenamed` so the sidebar rows
rebuild. A failed save changes nothing in memory or on screen.

## Who may replace whom

| Source | Set by | Replaced by |
| --- | --- | --- |
| `manual` | the user: sidebar row, tile title, tile menu **Rename** | the user; an agent's *requested* rename |
| `requested` | an agent asked to rename (`nameIntent: requested`) | the user; another requested rename |
| `agent` | an agent's own initiative (`nameIntent: proactive`) | the user; any agent rename |
| automatic (`prompt`, `harness`, `generated`, ...) | Array's namers | the user; any agent rename; a higher automatic namer |

`agent` and `requested` both outrank every automatic namer
(`AgentDisplayNameSource.authority`), so the harness-title poll and the
generated-name titler never undo them. `refusesProactiveRename` is the
proactive rule: true for `manual` and `requested`. Both agent sources stay
out of the sync payload, like other model-authored names.

## The tile

Double-clicking the drawn title (`TileNSView.mouseDown`, before the selection
or a drag can claim the press), or **Rename** in the agent tile's menu, opens
an inline field in the title bar (`TitleBarView.beginTitleEdit`). Return or
losing focus commits, Escape cancels, and an empty or unchanged name keeps
the old one. An app chord typed while it is open commits it first, as for a
zone rename. Only a managed agent tile overrides `beginTitleRename`; other
tiles keep their double-click. While the field holds focus the tile's chrome
cannot rest into cached pixels.

## The workspace API

`agent.update` (`array_update_agent`) takes `displayName` with a required
`nameIntent` (`requested` or `proactive`), alongside or instead of
`identityColor`. An absent `identityColor` now leaves the colour alone;
`null` still clears it. Renaming yourself needs no approval; renaming another
agent uses the canvas-write grant the colour uses. A proactive rename of a
`manual` or `requested` name is `target_conflict`, checked before any approval
prompt and again at commit. Identifier-shaped names (a model id, role or
agent UUID) and names with no visible text are `invalid_request`.

The result adds `displayName` and `nameSource` (`user`, `requested`, `agent`
or `automatic`). `workspace.context` reports the caller's own `displayName`
and `nameSource`; `agent.find` and `agent.inspect` identities carry
`nameSource`, so an agent can follow the rule before it asks.

The guidance lives once in `array-workspace-tools.json` (tool description and
guidelines, read by pi and by the MCP catalogue), plus one sentence in
`WorkspaceMCPConfiguration.agentGuidance` (Claude's appended prompt) and
`WorkspaceMCPToolCatalog.serverInstructions` (MCP `initialize`, Claude and
Codex).

## Witnesses

- `--agent-tile-rename-check`: double-click, type, Return; Escape; an emptied
  and a whitespace-only name; the menu's **Rename**. All through
  `NSApp.sendEvent` into a production mount with the focus monitor, asserting
  the record, store, production sidebar row, drawn title and a relaunch.
  Writes light and dark captures to `qa-runs/agent-tile-rename/`.
- `--workspace-api-agent-rename-check`: context source, self rename with no
  prompt, cross-agent grant and denial, proactive refused on user and
  requested names (with no prompt), requested allowed, refusals, colour and
  name together, MCP and pi entries, real save failure, and the claude
  harness-title path yielding to agent-set names beside a positive control.
- CoreChecks `--workspace-api-contract-check` (request/result coding, source
  rules), `--workspace-api-exposure-check` (`agent.displayName` exposed through
  `agent.update`) and `--workspace-mcp-check` (guidance on both surfaces).
