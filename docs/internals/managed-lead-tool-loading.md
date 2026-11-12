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

## The fix: pin three tools for a Claude Managed lead

`AgentSupervisor.runnerLaunch` gives a Claude Managed lead (mode Managed, no
parent) a workspace MCP configuration that names three tools in
`ARRAY_WORKSPACE_ALWAYS_LOADED_TOOLS`. `array-workspace-mcp` lists exactly
those with `_meta: {"anthropic/alwaysLoad": true}`; every other tool stays
deferred. The set lives in `ManagedLeadHookState.alwaysLoadedTools`:

- `array_status`: the brief's first instruction is "post [the plan] with
  array_status".
- `array_delegate`: the brief's core instruction, and the call that went out
  empty in the pilot.
- `array_message_agent`: the brief tells a lead to send a follow-up to an
  existing helper with it instead of delegating again. Leads do this often,
  and a deferred one invites the same empty first call. The brief's "never
  wait, poll or message a helper to check on it" still stands.
  `--managed-mode-hooks-check` fails if the delivered brief stops naming any
  pinned tool.

Not pinned: `array_report` (helpers report, leads do not) and the browser,
device, board and canvas tools (task-specific).

Everyone else is unchanged: a helper (Free, parented), a solo Free agent, a
Codex lead (never given the key: Codex has no pin) and Pi (not MCP). Their
server environment, and so their `--mcp-config` file and argv, are byte for
byte what they were.

The server-wide `"alwaysLoad": true` was not used: it loads all 36 tools
(about 22,800 more tokens per request, below) and makes Claude's start wait
for the server to connect.

Witness: `--managed-lead-tool-loading-check` launches a Managed lead, its
helper and a solo agent through the production supervisor and Claude runner,
reads the `--mcp-config` from each real argv, starts the server it names and
reads `tools/list`.

## Start-up tokens, measured

One `claude -p` request per row, answering "Reply with the single word ok."
Claude Code 2.1.321, `claude-haiku-5-5`, the Array work account's own login,
`CLAUDE_CONFIG_DIR` in a temp dir (no user CLAUDE.md, skills or plugins), an
empty temp cwd, `--no-session-persistence`. The argv is a lead's: guidance in
`--append-system-prompt`, the edit tools disallowed, `--strict-mcp-config`,
the real `array-workspace-mcp` with 36 tools. Not included: Array's hooks and
the lead brief (about 150 words, the same before and after). Total input =
uncached + cache write + cache read.

| Run | Total input | vs. deferred | Deferred tools (CLI debug log) |
|---|---:|---:|---|
| CLI alone, no Array server | 17,227 | | 14 |
| Lead before: every Array tool deferred | 18,799 | 0 | 50 |
| Same, built from this branch (pin absent) | 18,807 | +8 | 50 |
| Lead after: three tools pinned | 21,686 | +2,879 | 47 |
| Whole server `alwaysLoad: true` | 41,611 | +22,812 | 14 |

- Array's deferred surface (names, server instructions, guidance line) costs
  about 1,570 tokens per request on top of the CLI's own floor.
- Pinning the three lead tools costs about 2,900 tokens per request, paid
  only by Claude Managed leads. `array_message_agent` alone is about half.
- Loading Array's whole tool surface would cost about 22,800 tokens per
  request, for every agent.
- The 8-token difference between the two "before" rows is the temp paths.

Codex and Pi: no change, so before equals after (the frozen-argv leg
`--managed-codex-launch-check` passes). Not measured live: a Codex run
writes state under `~/.codex` even with `--ephemeral`, which this task may
not do. The earlier probe measured Codex's own floor at 16,515
(`.plans/116-agent-standards/evidence/probe-helper-context.md`).

## Proposal (not implemented): shorter tool descriptions

Rewording descriptions changes every agent's behaviour, so each cut needs its
own paired replay before it ships. What the numbers say:

The surface is 36 tools, 5,010 description words (32,238 characters) and
983 words of parameter descriptions (23,385 characters of schema JSON).
Longest, by description plus schema characters:

| Tool | Description words | Description + schema chars |
|---|---:|---:|
| array_message_agent | 443 | 3,673 |
| array_device_act | 212 | 3,561 |
| array_delegate | 248 | 3,440 |
| array_canvas_apply | 172 | 2,714 |
| array_device_build_run | 241 | 2,585 |
| array_board_apply | 194 | 2,424 |
| array_device_open | 178 | 2,408 |
| array_open_document | 146 | 2,311 |
| array_update_agent | 288 | 2,309 |
| array_board_manage | 214 | 2,064 |

What could move out:

1. Repeated family text: five sentences repeated in 10 to 11 browser tools
   ("Take a snapshot first, act by ref...", "do not fall back to curl or
   Playwright", the retry and effects lines) and three in five device tools.
   883 words are repeats of a first copy. The browser lines are already in
   the server instructions; keep them there once.
2. Return shapes and error catalogues in prose ("Returns delivery
   ('delivered', 'queued' or 'refused'), childAgentId...", "Errors are
   structured: permission_denied (...), invalid_request (...)..."). The
   reply already names its code and next step; the model needs the prose only
   when it gets that error.
3. Rules said twice inside one description: `array_message_agent` says the
   reply is not in the result twice and explains the idempotency key twice.
4. Rules the guidance line already gives every Claude and Codex agent:
   `array_update_agent`'s renaming rules (288 words) and the delegate/message
   basics.

Expected saving, an estimate: a third of the description words, about 1,700
words. On the whole surface that is roughly 5,000 to 6,000 tokens. Per
request at start-up it is small, because deferred tools cost only their
names; it is paid back on every ToolSearch load and, for a Claude Managed
lead, at start: a 200-word `array_message_agent` would cut the pin's cost
from about 2,900 to about 2,000 tokens. Trimming the server instructions
(282 words), which overlap the guidance line, saves every Claude and Codex
agent about 250 tokens on every request.
