# Claude/Codex workspace tools

Status: shipped in 0.7.18/build 69.

## Goal

Give native Claude Code and Codex managed agents the same Array workspace
awareness and controlled canvas operations currently available to managed Pi
agents.

## Boundary

The existing `WorkspaceAPIService` remains the only authority for identity,
checkout scope, workspace-tools policy, approval prompts, revision checks,
gesture conflicts, persistence, and undo registration. Provider integrations
must only transport MCP requests to that service; they must not reimplement
canvas or permission logic.

## Design

1. Add an Array-owned MCP server surface shared by Claude and Codex. It exposes
   the existing workspace operations as MCP tools, with the same schemas and
   descriptions as the Pi extension.
2. Add a host-local, per-agent authenticated IPC channel between the MCP child
   process and the running Array app. The caller identity is bound when Array
   creates the channel; it is never trusted from a model-authored argument.
3. Start the MCP server only for Array-managed Claude/Codex sessions and pass
   the provider's native MCP configuration at launch. Do not write the user's
   global Claude or Codex configuration.
4. Refresh compact workspace context at each prompt boundary for both native
   providers. Tool results remain structured JSON so cancellation, approval,
   `outcome_unknown`, and `recentOperations` retain their existing semantics.
5. Keep the Pi bridge unchanged except for sharing the tool catalog and tests.

## Acceptance

- Claude and Codex can call workspace context, open/reveal, canvas query, and
  canvas apply in an isolated managed session.
- First canvas mutation requires the existing Array approval; denial is a
  structured refusal and does not move anything.
- Stale revision, active gesture, revocation, cancellation, and idempotent
  retry behavior match the current Pi/API checks.
- The same MCP server works for Claude CLI and Codex app-server; no provider
  credentials or global configuration are modified.
- Provider launch argv/config, MCP handshake, tool schemas, host routing, and
  end-to-end mutation each have deterministic checks.

## Non-goals

- Giving unmanaged external Claude/Codex processes access to Array.
- Direct AppKit access from an agent or MCP child.
- Duplicating the board engine or adding provider-specific canvas semantics.
