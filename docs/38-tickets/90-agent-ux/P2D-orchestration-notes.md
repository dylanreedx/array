# P2D — orchestration: the `spawn_agent` extension

How an orchestrator agent creates workers, and how Continuum finds out.

## The mechanism

Continuum already translates every tool call in the Pi event stream (`PiEventTranslator`). So the
tool **call** is the API. There is no IPC, no callback channel, no new protocol.

`Resources/PiExtensions/continuum-spawn-agent.ts` registers one tool, `spawn_agent`, and that tool
is **inert**: it acknowledges and returns immediately. It does not create an agent, does not shell
out to Continuum, and never blocks. Continuum creates the child when it observes the call (P2D.2).

Inert by design, for two reasons:
- reaching back into the app would need the extension to hold a channel to a running Continuum;
- waiting for the child would need a blocking round-trip, i.e. RPC.

## Contract

```
spawn_agent
  prompt   string             required   the task; self-contained, the child does not see this conversation
  role     string  optional              role name, e.g. code-scout
  isolated boolean optional              run in its own git worktree instead of the shared checkout
→ { content: [{ type: "text", text: "spawned: <role>" }], details: { role, isolated } }
```

The acknowledgement text is what the *orchestrator model* sees. The authoritative payload for
Continuum is the `args` on the observed call, not the result.

The tool also sets `promptSnippet` and `promptGuidelines`. That is not decoration: Pi leaves a
custom tool out of the system prompt's `Available tools` section entirely unless it has a
`promptSnippet`, so without it an orchestrator would have to infer the tool from its schema alone.
The guidelines state the fire-and-forget contract (do not wait, do not poll, the child sees none of
this conversation) and each bullet names `spawn_agent`, because Pi appends them flat into the shared
`Guidelines` section with no tool-name prefix.

## Install

Not auto-installed — the app does not write to your home directory.

```bash
# user-wide
cp Resources/PiExtensions/continuum-spawn-agent.ts ~/.pi/agent/extensions/

# or project-local (requires trusting the project: pi --approve)
cp Resources/PiExtensions/continuum-spawn-agent.ts .pi/extensions/

# or load explicitly for one run
pi -e Resources/PiExtensions/continuum-spawn-agent.ts
```

No build step: jiti loads the TypeScript directly. `typebox` and the `ExtensionAPI` type both come
from the installed `@earendil-works/pi-coding-agent` package.

## Allowlisting

Pi's built-in tools are `read, bash, edit, write` plus `grep, find, ls` (off by default). The tool
allowlist is `--tools`, and it applies to extension tools too — **an orchestrator must be given
`spawn_agent` explicitly**:

```bash
pi --tools read,bash,edit,write,spawn_agent ...
```

An agent that is not meant to orchestrate simply does not get it in its allowlist.

## The captured fixture

`Sources/ContinuumRevivedCoreChecks/Fixtures/spawn-agent-tool-call.jsonl` is a **real** `--mode json`
stream, captured verbatim with the extension loaded, from the shipped file above. It is the fixture
P2D.2's matrix check runs against, so that check never needs a live model.

Provenance is external to the artifact — the stream records the model (`openai-codex/gpt-5.6-sol`,
visible on every `message_*` line) but not the Pi version, which was 0.82.0 at capture. Re-run the
capture command below if you need to know it holds for a newer Pi; nothing downstream should depend
on the version, only on the `tool_execution_start` shape.

The load-bearing line is the `tool_execution_start`:

```json
{"type":"tool_execution_start","toolCallId":"call_…","toolName":"spawn_agent",
 "args":{"role":"code-scout","prompt":"Find every call site of AgentSupervisor.spawn …","isolated":true}}
```

Note the stream carries the args **twice** — once assembled over `message_update` /
`toolcall_delta` fragments, and once whole on `tool_execution_start`. Parse the latter; the deltas
are partial JSON by construction.

To re-capture after a change to the tool's schema:

```bash
pi --mode json -ne -e Resources/PiExtensions/continuum-spawn-agent.ts -nbt -t spawn_agent \
   -p 'Call the spawn_agent tool with role=code-scout, prompt="…", isolated=true. Then stop.' \
   > Sources/ContinuumRevivedCoreChecks/Fixtures/spawn-agent-tool-call.jsonl
```

`-ne` disables extension discovery so the capture cannot pick up whatever else is installed on the
capturing machine; `-nbt -t spawn_agent` leaves the model with exactly one tool.

The `session` line records the capturing machine's `cwd` (this repository's path). That is part of
the verbatim capture. It is a test fixture on disk, not a sync payload — the I5 rule that a host
path must never be published applies to what the translator *emits*, and P2D.2 asserts exactly that
against this stream.

## Verified

`pi --mode json -ne -e … -nbt -t spawn_agent -p "…"` exits 0 and the stream contains one
`tool_execution_start` with `toolName: "spawn_agent"` and the three arguments intact — which is this
ticket's whole done-criterion: the extension loads and the tool is callable.

Negative witness, same command with `-e` dropped: the run still exits 0 and contains **zero**
`tool_execution_start` events — the model has no such tool. So the capture above is evidence of this
file loading, not of Pi inventing a tool from the prompt.

Not covered here, by design: nothing in Continuum reads this stream yet. Detecting the call and
creating the child agent is P2D.2.
