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

Witness: `--managed-lead-tool-loading-check` launches a Claude Managed lead,
its helper, a solo agent and a Codex Managed lead through the production
supervisor and runners, then switches the lead to Free and the solo agent to
Managed. For each launch it takes the server configuration the CLI was given
at launch (the fixture Claude copies its `--mcp-config` file as it starts;
Codex carries the server environment in argv), starts that server with that
environment and reads `tools/list`. Mutation proofs: removing the pin, leaking
it to every Claude agent, or leaking it to a Codex lead each turn the leg red.

## How to measure

Both modes live in `scripts/measure-lead-tool-tokens.py`; run them from the
repository root after `swift build --product array-workspace-mcp`.

- `python3 -I scripts/measure-lead-tool-tokens.py count` is offline: it starts
  the built server, reads `tools/list` and prints every count below (tools,
  words, characters, the longest tools, the pinned tools' sizes, repeated
  sentences). Words are whitespace-separated; characters are the
  description's length and the length of `json.dumps(inputSchema)`.
- `python3 -I scripts/measure-lead-tool-tokens.py probe` is live: four
  `claude -p` requests (about 100,000 input tokens, mostly cache reads; the
  model defaults to `claude-haiku-5-5`, `--model` changes it). It prints each
  row's total input and the CLI's own count of deferred tools from its debug
  log. Claude's config writes go to a fresh temp dir, never `~/.claude`; the
  CLI reads its own login from the Keychain item of the config dir the shell
  already points at. `--dry-run` prints each row's argv and MCP config and
  runs nothing.

## Start-up tokens, measured

Claude Code 2.1.321, `claude-haiku-5-5`, one request per row answering "Reply
with the single word ok.", in an empty temp cwd with a temp
`CLAUDE_CONFIG_DIR` (no user CLAUDE.md, skills or plugins) and
`--no-session-persistence`. The argv is a lead's: guidance in
`--append-system-prompt`, the edit tools disallowed, `--strict-mcp-config`,
the real `array-workspace-mcp` with 36 tools. Not included: Array's hooks and
the lead brief (the same before and after). Total input = uncached + cache
write + cache read. These figures were taken with an ad-hoc version of the
script's `probe` rows (same argv and config); the committed script was checked
with `--dry-run` only, not rerun live.

| Run | Total input | vs. the deferred row | Deferred tools (CLI debug log) |
|---|---:|---:|---|
| CLI alone, no Array server | 17,227 | -1,572 | 14 |
| Lead before: every Array tool deferred | 18,799 | 0 | 50 |
| Lead after: the three tools pinned | 21,686 | +2,887 | 47 |
| Whole server `alwaysLoad: true` | 41,611 | +22,812 | 14 |

Every difference is against the one deferred row (18,799). The "before" row
ran the server built before the change; the same request on this branch's
server with no pin read 18,807 (8 tokens apart: temp paths differ in length).

- Array's deferred surface (names, server instructions, guidance line) costs
  1,572 tokens per request on top of the CLI's own floor.
- Pinning the three lead tools costs 2,887 tokens per request, paid only by
  Claude Managed leads. Estimate: `array_message_agent` is 46% of the three
  tools' description and schema characters (3,673 of 7,991), so about 1,300
  of those tokens.
- Loading Array's whole tool surface costs 22,812 tokens per request, for
  every agent.

Codex and Pi: no change, so before equals after (`--managed-codex-launch-check`
keeps its frozen argv and the new leg checks the Codex lead's server). Not
measured live: a Codex run writes state under `~/.codex` even with
`--ephemeral`, which this task may not do. An earlier probe measured Codex's
own floor at 16,515 (`.plans/116-agent-standards/evidence/probe-helper-context.md`).

## Proposal (not implemented): shorter tool descriptions

Rewording descriptions changes every agent's behaviour, so each cut needs its
own paired replay before it ships. Counts from `count`:

The surface is 36 tools, 5,010 description words (32,238 characters) and
983 words of parameter descriptions (23,385 characters of schema JSON). The
server instructions are 282 words. Longest, by description plus schema
characters:

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
   883 words are copies after the first (a sentence counts when it appears
   verbatim in more than one tool's description). The browser lines are
   already in the server instructions; keep them there once.
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

Expected saving. All of these are estimates. They convert characters to
tokens at the whole surface's measured rate: 22,812 tokens for 55,623
characters of description and schema, about 0.41 tokens per character.

- Cutting a third of the description words (about 10,700 of 32,238
  characters) would save about 4,400 tokens on the whole surface. Per request
  at start-up it saves little, because deferred tools cost only their names;
  it is paid back on every ToolSearch load.
- For a Claude Managed lead, a 200-word `array_message_agent` (about 1,470
  fewer characters) would cut the pin's 2,887 tokens by about 600.
- The server instructions repeat much of the guidance line. Removing roughly
  half of their 282 words (about 900 characters) would save every Claude and
  Codex agent about 370 tokens on every request.

## Experimental task chooser (plan 117)

`agents.managedMode.chooser` is off by default. `ARRAY_MANAGED_CHOOSER=1`
selects it for a launch; `0` overrides the preference. Only root Claude Managed
leads participate. The launch adds `array_plan` to the three pinned tools and
loads its schema from a separate optional resource. Free agents, helpers, Codex,
Pi, and switch-off servers retain their existing tool catalog and pins.

The chooser brief and its scoped delegate guideline clarify that a Managed task
already permits choosing justified helpers without another delegation request.
Requests to work alone and Array's Agent permissions still apply. This changes
no host grants; the default delegate guideline and shared Pi resource stay intact.

The short chooser brief asks for solo work unless two or more different-file
parts justify the repeated reading. `array_plan` carries `choice`, `reason`,
and titled contracts in `parts`. The host stores the status and posts one local transcript notice,
returns an ownership verdict and partial pre-pass coverage, and records the
choice in the ledger without its prose. The visible reason stays in the local
status/transcript, like existing local notices. Coverage refreshes asynchronously at launch and plan
calls; the reply labels partial/absent/loading coverage and includes its snapshot
time. Replies cap registered checks at eight per part and unowned check paths at
32, with total counts so omissions are explicit. Repeating the same choice is idempotent; another
choice in that request is refused. One-part splits and ownership overlaps are
advised, and never refuse a delegation. A declaration alone does not latch.

The first implementation delegation closes the request's tool latch before
child creation begins. `readOnly: true` labels investigation/review and does
not latch. While latched, authenticated Array coordination and native reads
remain available; all command execution, editing and unknown MCP/plugin tools
are refused. The last implementation helper's terminal result reopens editing
for integration. The next dispatched user request starts with a new identity and declaration.
Unfinished implementation writes from an older task remain fenced until those
helpers finish. A follow-up to a completed implementation helper re-fences the
lead while the helper works again; stop/archive releases that fence. Queued
helper-result wakes keep their task identity.

Chooser PreToolUse hooks fail closed on a missing token, malformed input,
unavailable host, missing host policy acknowledgement, or timeout, including
trimmed large edits. This also temporarily refuses solo editing and reads when
the host cannot establish its policy. Other hook events never print a tool
decision on failure. An app restart cannot silently acknowledge an orphaned CLI;
the refusal tells the lead to resume/relaunch in Array, rather than repeatedly
retry the orphaned process. Implementation-writer markers are saved in the
helper's host-owned delegation context before its first send, set again on
follow-ups, and cleared on known terminal/explicit stop. A resumed lead restores
unresolved markers as write fences, even if its in-memory request was lost. Native Agent/Task tools are
excluded from chooser launches. The legacy hook transport remains fail open.

This is an experimental tool-boundary policy, **not a proven write sandbox**.
Claude's strict sandbox is fixed at process launch and cannot yet close at a
mid-turn delegation while permitting solo writes beforehand. The chooser
currently takes precedence over the separate strict-lead setting. A background
job launched during solo work can outlive the transition; read-only is the
lead's declaration, not a helper filesystem capability. These gaps keep the
chooser off. No live-provider effectiveness, speed, token saving, or default-on
claim follows from the offline witnesses.

Behavioral witnesses: `--orchestration-plan-check`,
`--orchestration-request-lifecycle-check`, and
`--orchestration-request-policy-check`, registered in the matrix.
