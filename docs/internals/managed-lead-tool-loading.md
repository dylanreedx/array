# Managed lead: which workspace tools load up front

Measured 2026-11-11 on this Mac: Claude Code 2.1.321, codex-cli 0.167.0,
pi 1.5.0. Re-check these facts when a CLI updates; every one below was read
from the installed CLI, not from memory.

## Why this exists

In the live replay pilot two Managed leads on Claude Code never called an
`array_*` tool and did the work through the shell, though the lead brief told
them to plan with `array_status` and delegate with `array_delegate`. When a
prompt asked for helpers, the lead's first `array_delegate` call went out with
empty arguments and the host refused it.

Claude Code defers MCP tools: the model sees only their names until it loads a
schema through ToolSearch. A lead's core tool was one search away, and a call
made before the search carries no schema.

## What each CLI does

### Claude Code 2.1.321: defers, and can pin one tool

- MCP tools are deferred behind ToolSearch by default. `ENABLE_TOOL_SEARCH`
  (`true`, `false`, `auto`, `auto:N`) switches the whole mechanism; it is not
  per tool.
- A server can pin one tool: list it in `tools/list` with
  `_meta: {"anthropic/alwaysLoad": true}`. The client sets the tool's
  `alwaysLoad`, and an `alwaysLoad` tool is never deferred. From the bundled
  client:
  `alwaysLoad: !serverDefersAllTools && (serverAlwaysLoad && !(... _meta["anthropic/alwaysLoad"] === false) || _meta["anthropic/alwaysLoad"] === true)`
  and `if (tool.alwaysLoad === true) return false /* not deferred */`.
- The launching host can pin a whole server with `"alwaysLoad": true` in its
  `--mcp-config` entry. The CLI's own help text for it: "When true, all tools
  from this server are always included in the prompt and never deferred
  behind tool search, except a tool the server itself lists with _meta
  anthropic/alwaysLoad set to false. ... As a side effect, true also blocks
  startup until the server is connected (capped at the standard 5s connect
  timeout)". `"alwaysLoad": false` defers every tool, overriding the per-tool
  pin.
- `claude --help` names neither key. There is no argv flag for either.

### Codex 0.167.0: defers, and offers no pin

- An Array-launched Codex session's developer message lists
  `Deferred tool namespaces: - mcp__array_workspace: <server instructions>`.
  In code mode the model reaches the tools through `exec`; "Some deferred
  nested tools may be omitted from this description. They are still available
  on the global `tools` object and listed in `ALL_TOOLS`". Seen in a real
  Array helper's rollout, which filtered `ALL_TOOLS` and then called
  `array_report`.
- The feature `tool_search_always_defer_mcp_tools` reads `removed, true`: the
  behaviour is permanent.
- The MCP server config keys in the binary are `command`, `args`, `cwd`, `env`,
  `startup_timeout_*`, `startup_readiness`, `supports_parallel_tool_calls`,
  `omit_tools_from`, `enabled_tools`, `disabled_tools`, `tool_timeout_sec`,
  `default_tools_approval_mode` and similar. None pins a tool. No
  `_meta` key it reads does either.
- So a Codex lead cannot be given its tools up front. It calls them from
  JavaScript with an object argument rather than a schema-checked call, so
  the empty-arguments failure has not been seen there.

### Pi 1.5.0: does not defer Array's tools

- Array gives Pi its tools through its own extension
  (`continuum-workspace-tools.ts`, loaded with `-e`), not MCP. An extension
  tool's exposure defaults to `direct`: declared to the model like any other
  tool (`dist/core/extensions/types.d.ts`, `exposure` "Default: `direct`").
- Pi's own MCP servers default to `codemode` exposure and can be set per tool
  with `toolExposure`; Array does not use that path.
- Nothing to fix for Pi: every Array tool already loads with its schema.
