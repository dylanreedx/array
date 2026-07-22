# Provider adapter — Pi + GPT-5.6 (first provider)

**Phase 7 · ticket 88 · started 2026-07-22**

## Why / sequencing

Provider #1 is Pi driving GPT-5.6, chosen to de-risk the adapter architecture on the
friendliest surface before Claude Code (ticket 89): clean licensing (rides the existing
openai-codex/ChatGPT auth, no API key, no Claude-subscription volatility) and a rich
structured output. This adapter is the *feed* half of the agent tile (ticket 87 is the
render half).

## Discovery (all build-gating unknowns resolved 2026-07-22)

- **Pi is installed** (`~/.nvm/.../bin/pi`, v0.81.1) and exposes a structured surface:
  `--mode json` (event stream) and `--mode rpc`, `--print` non-interactive,
  `--provider`/`--model` (supports `provider/id`), on-disk sessions (`--session-dir`),
  and an extension system (`.pi/extensions/`). Richer than Claude Code (json *and* rpc).
- **GPT-5.6 is reachable now**: `~/.pi/agent/auth.json` is authed for `openai-codex`
  (ChatGPT backend) and `gpt-5.6` is in Pi's model catalog. Invoke with
  `pi -p --mode json --model openai-codex/gpt-5.6`.
- **Target contract already exists**: `AgentRuntimeEvent` (Core/AgentStatusEngine.swift)
  — sessionState, turn lifecycle, item (tool) lifecycle, contentDelta, approvals,
  userInput, tokenUsage, runtimeError — Codable, and already folded by the pure
  `ManagedAgentTranscriptModel` and ingested by `ManagedAgentTileNSView`. The adapter
  targets this; no new model needed.

### Real `--mode json` schema (captured live from GPT-5.6)

`session{id,cwd}` · `agent_start` · `turn_start` · `message_update{assistantMessageEvent:{type,delta}}`
with sub-types `text_start|text_delta|text_end`, `thinking_*`, `toolcall_*` ·
`tool_execution_start{toolCallId,toolName,args}` · `tool_execution_end{…,result,isError}` ·
`turn_end` · `agent_end` · `agent_settled`. Deltas are **incremental** (`"hello"`, `" world"`).

### Mapping (Pi → AgentRuntimeEvent)

| Pi event | AgentRuntimeEvent |
|---|---|
| `session{id}` | capture threadId; `sessionStateChanged(.ready)` |
| `agent_start` | `sessionStateChanged(.running)` |
| `turn_start` | `turnStarted(threadId, <synth turnId>)` |
| `message_update` text_delta | `contentDelta(.assistant, delta)` |
| `message_update` thinking_delta | `contentDelta(.reasoning, delta)` |
| `tool_execution_start` | `itemStarted(itemId: toolCallId, kind, title: toolName)` |
| `tool_execution_end` | `itemCompleted(status: isError ? .failed : .completed)` |
| `turn_end` | `turnCompleted(.completed)` |
| `agent_settled` | `sessionStateChanged(.ready)` |
| text/toolcall start/end markers, agent_end, user echoes | dropped |

## Slice 88.3 (done) — the pure translator

`Core/AgentProviders/PiEventTranslator.swift`: line-in → `[AgentRuntimeEvent]`, stateful
only for threadId + turn counter. Tested in `runPiEventTranslatorChecks` against the real
captured schema (exact sequence, turn-id synthesis, I5-safety). Matrix-gated.

## Watch-outs

1. **Pi emits no turn IDs** — synthesised as `<sessionId>#t<n>`, stable within a session.
2. **I5 by construction** — Pi events carry `session.cwd`, tool `args.path`, and tool
   `result.content` (the actual file body). `AgentRuntimeEvent` has no field for any of
   those, so mapping *drops* them; tool items carry only the tool NAME as title, never
   args. The check encodes every event and asserts the secret path/body are absent. This
   is the adapter's I5 seam; do not add a field that reintroduces them.
3. **Tool→ItemKind is coarse** — bash/inspect tools bucket to `.commandExecution`,
   edit/write→`.fileChange`, web→`.webSearch`. The exact tool name rides `title`. A finer
   taxonomy is a follow-up; deliberately not expanding the shared enum in this slice.
4. **`--mode rpc` is the bidirectional path** — for *driving* the agent from the phone
   (input + approvals) later. This slice is observe-only (json stream).
5. **`gpt-5.6-terra` appeared as the concrete model tag** in the live stream — the model
   id resolves to a variant; pin `openai-codex/gpt-5.6` and let Pi resolve.
6. **Reasoning is encrypted** on gpt-5.6-codex (thinking content came back empty/signed) —
   don't expect reasoning text; the reasoning stream may be markers only.

## Next slices

- **88.4 PiAgentRunner** (impure): spawn `pi -p --mode json --model openai-codex/gpt-5.6`,
  read stdout lines, feed the translator, emit events to the managed tile + activity
  projection; wire to the relay (I5 filtering stays at the publish/taint gate). Live
  dogfood: spawn a GPT-5.6 agent, watch turns/tools appear on Mac + phone.
- **88.5** rpc mode for input/approvals from the phone (uses the existing approval
  round-trip).
- **89** Claude Code as provider #2 behind the same seam (stream-json / session `.jsonl`).

## Verification

- `ContinuumRevivedCoreChecks → runPiEventTranslatorChecks` in `run-matrix.sh`.
- Live schema re-capture: `pi -p --mode json --model openai-codex/gpt-5.6 "<prompt>"`.
