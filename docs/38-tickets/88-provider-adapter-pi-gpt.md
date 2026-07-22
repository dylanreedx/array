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

## Slice 88.4 (runner done) — the impure process engine

`Core/AgentProviders/PiAgentRunner.swift`: spawns `pi -p --mode json --model
openai-codex/gpt-5.6` via `/usr/bin/env`, streams stdout through the translator on a
serial queue, emits `AgentRuntimeEvent`s to a `@Sendable` callback as they arrive,
handles teardown + nonzero exit. Proven LIVE 2026-07-22 via the `continuum-pi-smoke`
harness: a real GPT-5.6 run produced 12 normalized events end-to-end (session→running,
a `read` tool round-trip in turn 1, assistant content streamed `"hello"/" from"/"
continuum"` in turn 2, completed→ready), with the file path/body correctly absent.

Watch-out (GUI): `/usr/bin/env pi` resolves on the shell PATH; a GUI-launched app must
inject a PATH including the pi install (nvm bin) or resolve pi's absolute path — the
shell-launched smoke inherits PATH so it "just works" there but the app won't.

## Slice 88.4b (done) — tile wiring

A managed-agent tile now runs GPT-5.6 live. `wireManagedAgentTile(tileId)` (spawn AND
restore paths) sets `ManagedAgentTileNSView.onSubmitPrompt`; submitting starts a
`PiAgentRunner` off the main thread, and each event is rebound to the tile's thread and
ingested on the main actor. Pieces:

- **Compose affordance** — a minimal compose row on the tile (`NSTextField` + Run,
  Return submits), gated: disabled while `.working`. QA'd via the `managed-agent`
  headless component snapshot (compose row renders, correctly disabled while working,
  dark-consistent with the header). The framework ComposeBox supersedes it later.
- **Thread rebinding** — a tile is keyed by a stable `managed-<uuid>` thread, but the
  adapter synthesises threadId from Pi's session id, so the tile's threadId filter would
  drop every event. `AgentRuntimeEvent.withThreadId(_:)` (pure, total) rebinds every
  thread-bearing case at the wiring boundary; matrix-pinned incl. a control proving
  un-remapped events DON'T land.
- **GUI PATH fix (deeper than expected)** — resolving `pi` absolutely is NOT enough: pi
  is a node script whose `#!/usr/bin/env node` shebang needs **node** on PATH too, and a
  GUI-thin PATH (`/usr/bin:/bin:/usr/sbin:/sbin`) has neither. `PiAgentRunner.run` now
  augments the child's PATH (`augmentedPath` + `liveExtraDirs` — nvm bins newest-first,
  homebrew, ~/.local/bin), fixing both lookups. **Proven live**: `continuum-pi-smoke`
  under an `env -i` thin PATH streamed 8 real GPT-5.6 events ("hello from continuum").
  Both helpers matrix-pinned (`runPiExecutableResolutionChecks`).

### In-app sanity check (2026-07-22)

`--managed-agent-live-check` drives the REAL launched window through the exact click
path (palette spawn → `wireManagedAgentTile` → tile Run action → `PiAgentRunner`) and
waits for a live GPT-5.6 reply to stream into the tile. **PASS**: the reply streamed in
(sentinel appeared twice — echo + model reply). Two findings while getting there:

1. **Harness must not block the main thread.** A `RunLoop`-spin wait did NOT drain the
   `DispatchQueue.main.async` ingests the tile relies on (a direct in-process runner
   control produced 8 events fine, proving the runner works; only the main-hop delivery
   was starved). Fixed by polling via `asyncAfter` so the normal NSApp loop drains
   ingests — i.e. it works for a real click; only the artificial harness was wrong.
2. **UX defects (FIXED, commit ffcf223).** Two bugs made the tile show nothing / one
   blob when dogfooded: (a) the transcript rendered BLANK — the `cardStack` was the
   scroll view's documentView with no autolayout pinning, so it had no resolved size and
   cards never laid out; fixed by pinning it to the clip view + a flipped stack (top-down).
   (b) cards concatenated across turns — `ManagedAgentTranscriptModel` only reset the
   active assistant card on `turnCompleted`; now also on `turnStarted` (88.4d), pinned by
   a multi-turn CoreCheck. Managed-agent headless snapshot now shows distinct cards.

## Next slices

- **88.4c Events → relay**: wire the tile's ingested events into the activity projection
  → relay so they reach the phone (I5 filtering stays at the publish/taint gate).
- **88.5 Session continuity + interaction**: the runner spawns each prompt with
  `--no-session`, so prompts are independent — NO memory across turns, and the approval
  dock isn't wired to the live runner. Real conversational interaction needs session
  persistence (drop `--no-session` / `--session-dir`) and rpc mode for input + approvals.
- **88.5** rpc mode for input/approvals from the phone (uses the existing approval
  round-trip).
- **89** Claude Code as provider #2 behind the same seam (stream-json / session `.jsonl`).

## Verification

- `ContinuumRevivedCoreChecks → runPiEventTranslatorChecks` in `run-matrix.sh`.
- Live schema re-capture: `pi -p --mode json --model openai-codex/gpt-5.6 "<prompt>"`.
