# Stealing from t3code (3/N): Provider adapters + structured agent protocols

**Research spike, 2026-06-30.** For a future implementing agent. Maps t3code's
provider-adapter layer end-to-end so Continuum can spec a **"managed agent" path** —
agents Continuum *spawns as structured protocol sessions* — alongside the shell/terminal
tiles it *observes* via on-disk readers (the AGENT-READERS spike).

**The one-line thesis:** t3code and Continuum sit at opposite ends of the same spectrum.
Continuum today **observes** terminal-launched agents by tailing their session files
(`~/.claude/*.jsonl`, `~/.codex/sessions`, Pi `status.json` — read-only, zero-config,
detect-not-declare, Decision C of `docs/38`). t3code **drives** the agents it hosts over
**live structured protocols** (the Claude Agent SDK loop, the Codex `app-server` JSON-RPC,
ACP over stdio for Cursor/Grok, the OpenCode HTTP SDK), normalizing every provider's native
stream into **one canonical `ProviderRuntimeEvent` union** behind **one adapter interface**.
The managed path is that second tier — **new**, not a replacement for the readers.

All `file:line` references are into the clone at
`…/scratchpad/t3code` (read-only) unless prefixed `continuum:`. Claims are tagged
**[VERIFIED]** (read off source) or **[INFERRED]** (reasoned, flagged).

> **Naming note.** The seed brief referenced `provider/Services/ProviderAdapter.ts`,
> `Layers/ClaudeAdapter.ts`, Codex notifications `item_started`/`item_completed`, and
> `packages/shared/src/agentAwareness.ts`. The clone's real layout matches *mostly*: the
> interface is `apps/server/src/provider/Services/ProviderAdapter.ts` [VERIFIED], the impls
> are `apps/server/src/provider/Layers/{Claude,Codex,Cursor,Grok,OpenCode}Adapter.ts`
> [VERIFIED], `agentAwareness.ts` exists [VERIFIED]. **But** the Codex `app-server` protocol
> in this build uses `thread/start`, `turn/start`, `turn/started`, `turn/completed`,
> `item/*` method names — **not** `item_started`/`item_completed` (that was an older
> app-server dialect). Documented as found.

---

## 0. TL;DR — the shape of the steal

- **One interface, N providers.** `ProviderAdapterShape<TError>` (12 methods +
  `streamEvents: Stream<ProviderRuntimeEvent>`) is implemented once per provider. Callers
  (`ProviderService`) never branch on provider kind — they resolve an adapter by instance id
  and call the interface. **[VERIFIED]** `ProviderAdapter.ts:45`.
- **One canonical event union.** Every provider's native stream is normalized to
  `ProviderRuntimeEvent` — a **47-variant** discriminated union (`session.*`, `thread.*`,
  `turn.*`, `item.*`, `content.delta`, `request.*`, `user-input.*`, `task.*`, `hook.*`,
  `tool.*`, `runtime.error`, …). **[VERIFIED]** `providerRuntime.ts:148-1017`.
- **Four drive mechanisms, one contract.**
  - **Claude** = in-process `@anthropic-ai/claude-agent-sdk` `query({prompt, options})`
    consumed as `AsyncIterable<SDKMessage>`; resume by `sessionId`. No child process for the
    agent loop itself. **[VERIFIED]**
  - **Codex** = spawn `codex app-server`, JSON-RPC over stdio (typed client), consume
    `thread/started`/`turn/started`/`turn/completed` **notifications** + answer
    `item/*/requestApproval` **server requests**. **[VERIFIED]**
  - **Cursor / Grok** = spawn `agent acp` / `grok agent stdio`, **ACP** (Agent Client
    Protocol) JSON-RPC over stdio: `initialize`→`authenticate`→`session/new`→`session/prompt`,
    consume `session/update` notifications. **[VERIFIED]**
  - **OpenCode** = `@opencode-ai/sdk` HTTP client to a managed (or external) server;
    `session.create` / `session.promptAsync` + `event.subscribe()` consumed as an async
    iterable. **[VERIFIED]**
- **Driver = plain value.** A `ProviderDriver` is a record `{driverKind, metadata,
  configSchema, defaultConfig, create}`; `create()` returns a `ProviderInstance` bundling a
  live `adapter`. Multiple instances per driver (e.g. `codex_work` + `codex_personal`).
  **[VERIFIED]** `ProviderDriver.ts:119`, `builtInDrivers.ts:47`.
- **Status derivation** collapses the rich session/turn state into a 7-value UI phase enum
  (`starting|running|waiting_for_approval|waiting_for_input|completed|failed|stale`) in a
  **pure function** — `agentAwareness.ts:61`. This maps almost 1:1 onto Continuum's existing
  `AgentStatus`.

**Top-3 to steal, up front:** (1) the **canonical event union + adapter interface** as the
managed-agent contract; (2) **ACP** as the standardizing protocol (one runtime drives ≥2
agents); (3) the **pure status-derivation function** feeding the UI phase.

---

## 1. What t3code does (adapter layer, end to end)

### 1.1 The interface — `ProviderAdapterShape<TError>` [VERIFIED]

`apps/server/src/provider/Services/ProviderAdapter.ts:45-126`. This is *the* contract. Every
provider implements exactly this; `ProviderService` calls exactly this.

```ts
export interface ProviderAdapterShape<TError> {
  readonly provider: ProviderDriverKind;
  readonly capabilities: ProviderAdapterCapabilities;   // { sessionModelSwitch: "in-session" | "unsupported" }

  // ---- lifecycle ----
  readonly startSession: (input: ProviderSessionStartInput) => Effect.Effect<ProviderSession, TError>;
  readonly sendTurn:     (input: ProviderSendTurnInput)     => Effect.Effect<ProviderTurnStartResult, TError>;
  readonly interruptTurn:(threadId: ThreadId, turnId?: TurnId) => Effect.Effect<void, TError>;
  readonly stopSession:  (threadId: ThreadId) => Effect.Effect<void, TError>;
  readonly stopAll:      () => Effect.Effect<void, TError>;

  // ---- interactive back-channel ----
  readonly respondToRequest:   (threadId: ThreadId, requestId: ApprovalRequestId,
                                 decision: ProviderApprovalDecision) => Effect.Effect<void, TError>;
  readonly respondToUserInput: (threadId: ThreadId, requestId: ApprovalRequestId,
                                 answers: ProviderUserInputAnswers) => Effect.Effect<void, TError>;

  // ---- introspection ----
  readonly listSessions:  () => Effect.Effect<ReadonlyArray<ProviderSession>>;
  readonly hasSession:    (threadId: ThreadId) => Effect.Effect<boolean>;
  readonly readThread:    (threadId: ThreadId) => Effect.Effect<ProviderThreadSnapshot, TError>;
  readonly rollbackThread:(threadId: ThreadId, numTurns: number) => Effect.Effect<ProviderThreadSnapshot, TError>;

  // ---- THE canonical output ----
  readonly streamEvents: Stream.Stream<ProviderRuntimeEvent>;
}
```

Notes that matter for Continuum:
- **`threadId` is the session key**, adapter-assigned and stable; a "thread" is one
  conversation/agent-run. **`turnId`** identifies one user→completion cycle within it.
- **`sendTurn` is a *steer*, not always a new turn.** In Claude, if a turn is already
  running, the new message is queued into the *live* agent loop (same turn); only a
  quiescent session starts a fresh turn. **[VERIFIED]** `ClaudeAdapter.ts:3648-3657`.
- **`respondToRequest` / `respondToUserInput`** are the human-in-the-loop back-channel:
  approvals (run this command? apply this patch?) and structured questions
  (`AskUserQuestion`). This is the piece a *terminal* tile fundamentally can't expose
  structurally — see §4.
- The whole thing is `Effect`-typed; a straight Swift port drops `Effect<A, E>` → `async
  throws -> A` and `Stream<T>` → `AsyncStream<T>` (§2.5).

### 1.2 The canonical event union — `ProviderRuntimeEvent` [VERIFIED]

`packages/contracts/src/providerRuntime.ts`. `ProviderRuntimeEvent = ProviderRuntimeEventV2`
(`:1019`), a `Schema.Union` of **47** structs (`:967-1017`), each `{ ...base, type, payload }`.

**Common base** (`ProviderRuntimeEventBase`, `:248`): `eventId`, `provider`,
`providerInstanceId?`, `threadId`, `createdAt`, `turnId?`, `itemId?`, `requestId?`,
`providerRefs?` (provider-native ids), `raw?` (the untouched source frame, for debugging).

**The 47 `type` literals** (`ProviderRuntimeEventType`, `:148-196`) — grouped:

| Group | Variants |
|---|---|
| **session** | `session.started`, `session.configured`, `session.state.changed`, `session.exited` |
| **thread** | `thread.started`, `thread.state.changed`, `thread.metadata.updated`, `thread.token-usage.updated`, `thread.realtime.{started,item-added,audio.delta,error,closed}` |
| **turn** | `turn.started`, `turn.completed`, `turn.aborted`, `turn.plan.updated`, `turn.proposed.{delta,completed}`, `turn.diff.updated` |
| **item** (tool/message lifecycle) | `item.started`, `item.updated`, `item.completed` |
| **content** | `content.delta` (streaming assistant/reasoning/command-output text) |
| **request** (approvals) | `request.opened`, `request.resolved` |
| **user-input** | `user-input.requested`, `user-input.resolved` |
| **task** (sub-agents) | `task.started`, `task.progress`, `task.completed` |
| **hook** | `hook.started`, `hook.progress`, `hook.completed` |
| **tool** | `tool.progress`, `tool.summary` |
| **account/mcp/model** | `auth.status`, `account.updated`, `account.rate-limits.updated`, `mcp.status.updated`, `mcp.oauth.completed`, `model.rerouted` |
| **diagnostics** | `config.warning`, `deprecation.notice`, `files.persisted`, `runtime.warning`, `runtime.error` |

Key payload sub-shapes worth stealing wholesale (all body-carrying, so they're a *superset*
of what Continuum's I5 privacy rule allows — see §3):
- `SessionStateChangedPayload` (`:276`): `state: "starting"|"ready"|"running"|"waiting"|"stopped"|"error"` — **this is the liveness signal**.
- `TurnCompletedPayload` (`:362`): `state: "completed"|"failed"|"interrupted"|"cancelled"`, `stopReason?`, `usage?`, `totalCostUsd?`, `errorMessage?`.
- `ItemLifecyclePayload` (`:404`): `itemType: CanonicalItemType`, `status: "inProgress"|"completed"|"failed"|"declined"`, `title?`, `detail?`. `CanonicalItemType` (`:121`) unifies tool kinds across providers: `command_execution`, `file_change`, `mcp_tool_call`, `web_search`, `assistant_message`, `reasoning`, `plan`, `error`, ….
- `RequestOpenedPayload` (`:421`): `requestType: CanonicalRequestType` (`command_execution_approval`, `apply_patch_approval`, `tool_user_input`, …) — the approval kind.
- `ThreadTokenUsageSnapshot` (`:307`): a rich token/cost meter.

**The canonicalization is the value.** Codex emits `turn/completed` with its own shape;
Claude emits an `SDKResultMessage`; ACP emits `session/update` with a `stopReason`. All three
land as `{type: "turn.completed", payload: {state, ...}}`. The UI/status code reads **one**
schema.

### 1.3 The driver SPI + catalog [VERIFIED]

A **`ProviderDriver<Config, R>`** is a *plain record*, not a service — because you need many
instances of one driver (`ProviderDriver.ts:1-37, :119-157`):

```ts
export interface ProviderDriver<Config, R = never> {
  readonly driverKind: ProviderDriverKind;                 // "codex" | "claudeAgent" | "cursor" | "grok" | "opencode"
  readonly metadata: { displayName: string; supportsMultipleInstances?: boolean };
  readonly configSchema: Schema.Codec<Config, unknown>;    // decodes the opaque settings envelope
  readonly defaultConfig: () => Config;
  readonly create: (input: ProviderDriverCreateInput<Config>) =>
    Effect.Effect<ProviderInstance, ProviderDriverError, R | Scope.Scope>;
}
```

`create()` returns a **`ProviderInstance`** (`:64`) = `{ instanceId, driverKind,
continuationIdentity, displayName?, enabled, snapshot, adapter, textGeneration }`. The
`adapter` is the live `ProviderAdapterShape`. Resource lifecycle is the returned effect's
`Scope`: closing the scope kills the child processes / SDK query / event fibers.

The static set ships in **`builtInDrivers.ts:47`**:
```ts
export const BUILT_IN_DRIVERS = [CodexDriver, ClaudeDriver, CursorDriver, GrokDriver, OpenCodeDriver];
```

**Per-provider catalog metadata** (binary / home / install / update), gathered from each
`Drivers/*Driver.ts` [VERIFIED]:

| driverKind | binary (default) | spawn/connect | install/update | home isolation |
|---|---|---|---|---|
| `claudeAgent` | `claude` (`.local/bin/claude`) | **in-process SDK** (`pathToClaudeCodeExecutable`) | npm `@anthropic-ai/claude-code` / brew `claude-code` / native `claude update` | per-instance HOME via env; capabilities probe keyed on binary+HOME (`ClaudeDriver.ts:63-82,151-161`) |
| `codex` | `codex` | spawn `codex app-server` | npm `@openai/codex` / brew `codex` (`CodexDriver.ts:64-69`) | `CODEX_HOME=<homePath>` shadow home per instance (`CodexDriver.ts:123-146`, `CodexSessionRuntime.ts:716-720`) |
| `cursor` | `agent` | spawn `agent [-e <endpoint>] acp` (**ACP**) | `agent update` (`CursorDriver.ts:57-65`, `CursorAcpSupport.ts:37-45`) | env; `authMethodId: "cursor_login"` |
| `grok` | `grok` | spawn `grok agent stdio` (**ACP**) | manual only (`GrokDriver.ts:44-49`) | env; `XAI_API_KEY` → `xai.api_key` auth, else `cached_token` (`GrokAcpSupport.ts:31-51`) |
| `opencode` | `opencode` | HTTP SDK to spawned/external server | npm `opencode-ai` / brew / native `opencode upgrade` (`OpenCodeDriver.ts:60-78`) | own server process (or `serverUrl` for external) per instance |

The driver's declared `R` (its infra deps — `ChildProcessSpawner`, `FileSystem`, `Path`,
`HttpClient`, …) is aggregated into `BuiltInDriversEnv` (`builtInDrivers.ts:35`); the runtime
layer must satisfy the union. **Continuum analog:** an `AgentAdapterDependencies` struct
(process spawner, fs, clock) injected into each adapter's factory.

### 1.4 How an adapter is selected + instantiated [VERIFIED]

`ProviderService` is the router (`Layers/ProviderService.ts`). It does **not** switch on
provider kind:

1. **Registry.** `ProviderInstanceRegistry` owns a live `Map<InstanceId, ProviderInstance>`,
   built by iterating `BUILT_IN_DRIVERS`, decoding each configured instance's settings via
   `driver.configSchema`, and calling `driver.create(...)`. (`ProviderDriver.ts:1-13`.)
2. **Binding.** A persisted binding maps `threadId → instanceId` (agent #4's turf). To route
   an operation, `ProviderService` reads the binding, gets `instanceId`, then
   `registry.getByInstance(instanceId)` → the `adapter`, then calls
   `adapter.startSession/sendTurn/...`. (`ProviderService.ts:445-481`.)
3. **Event multiplexing.** `reconcileInstanceSubscriptions` (`ProviderService.ts:322-346`)
   forks one fiber per instance that pipes `adapter.streamEvents` into a single merged
   runtime bus, **stamping `providerInstanceId`** and asserting the emitted `provider` matches
   the instance's driver (`:184-199`). Hot add/remove of instances re-reconciles; orphaned
   fibers die when the old adapter's stream terminates.

So selection = **binding lookup → registry lookup → interface call**. Clean seam.

---

## 2. Code snippets (the point) — one per provider, then the Swift sketch

### 2.1 Claude — in-process Agent SDK loop [VERIFIED]

`apps/server/src/provider/Layers/ClaudeAdapter.ts`. **No child process for the agent loop** —
the SDK's `query()` returns an `AsyncIterable<SDKMessage>` you consume directly.

**Start** (`:3443-3521`, `:3611`): build options, call `query`, fork a fiber that streams
messages into handlers.
```ts
import { query, type Options as ClaudeQueryOptions, type SDKMessage,
         type SDKUserMessage, type CanUseTool } from "@anthropic-ai/claude-agent-sdk";

const queryOptions: ClaudeQueryOptions = {
  ...(input.cwd ? { cwd: input.cwd } : {}),
  ...(apiModelId ? { model: apiModelId } : {}),
  pathToClaudeCodeExecutable: claudeBinaryPath,
  systemPrompt: { type: "preset", preset: "claude_code" },
  settingSources: [...CLAUDE_SETTING_SOURCES],
  ...(permissionMode ? { permissionMode } : {}),                 // "plan" | "bypassPermissions" | ...
  ...(existingResumeSessionId ? { resume: existingResumeSessionId } : {}),  // <-- RESUME BY SESSION ID
  ...(newSessionId ? { sessionId: newSessionId } : {}),
  includePartialMessages: true,
  canUseTool,                                                     // <-- approval callback (see below)
  env: claudeEnvironment,
};

const queryRuntime = createQuery({ prompt, options: queryOptions });
//                    ^ default createQuery = ({prompt, options}) => query({prompt, options})  (:1364)
```

**Consume** (`:2887-2914`) — the async iterable becomes an Effect `Stream`, one handler per
message type, running until `context.stopped`:
```ts
const runSdkStream = (context) =>
  Stream.fromAsyncIterable(context.query, (cause) => new ProviderAdapterProcessError({ ... }))
    .pipe(
      Stream.takeWhile(() => !context.stopped),
      Stream.runForEach((message) => handleSdkMessage(context, message)),
    );

// handleSdkMessage dispatches on message.type (:2860):
//   "user" | "assistant" | "result" | "system" | "tool_progress" | "auth_status" | ...
// each handler calls offerRuntimeEvent(...) → Queue.offer(runtimeEventQueue, canonicalEvent)
```

**Steer** (`sendTurn`, `:3730`): a new prompt while a turn runs is `Queue.offer`ed into the
live loop's prompt queue — the SDK's streaming-input mode. Resume state is a `resumeCursor`
carrying `{ resume: sessionId, resumeSessionAt: lastAssistantUuid, turnCount }` (`:3532`).

**Approvals** via the SDK's `canUseTool` callback (`:3250-3406`): when Claude wants a tool,
the callback opens a `request.opened` event, parks a `Deferred`, and
`respondToRequest`/`respondToUserInput` complete it (`:3771-3803`). `AskUserQuestion` becomes
`user-input.requested`.

**Output** (`:3865`): `get streamEvents() { return Stream.fromQueue(runtimeEventQueue); }`.

**The Claude takeaway:** this agent is **headless** — a programmatic loop, no TUI. That is
the crux of the fork for Continuum (§4).

### 2.2 Codex — spawn `codex app-server`, JSON-RPC over stdio [VERIFIED]

`Layers/CodexSessionRuntime.ts` + typed client `packages/effect-codex-app-server/src/client.ts`.

**Spawn** (`CodexSessionRuntime.ts:722-754`):
```ts
const spawnCommand = yield* resolveSpawnCommand(options.binaryPath, ["app-server", ...(options.appServerArgs ?? [])], { env, extendEnv });
const child = yield* spawner.spawn(
  ChildProcess.make(spawnCommand.command, spawnCommand.args, {
    cwd: options.cwd,
    env: { ...options.environment, ...(resolvedHomePath ? { CODEX_HOME: resolvedHomePath } : {}) },
    forceKillAfter: CODEX_APP_SERVER_FORCE_KILL_AFTER,
    shell: spawnCommand.shell,
  }),
);
// wrap the child's stdio in the typed JSON-RPC client:
const clientContext = yield* CodexClient.layerChildProcess(child).pipe(Layer.build, ...);
const client = yield* Effect.service(CodexClient.CodexAppServerClient).pipe(Effect.provide(clientContext));
```
The `CodexAppServerClient` (`client.ts:38-78, :197-219`) is a schema-typed JSON-RPC wrapper
over stdio with four verbs: `request(method, payload)`, `notify(method, payload)`,
`handleServerRequest(method, handler)`, `handleServerNotification(method, handler)` — payloads
are decoded/encoded against a generated schema (`_generated/meta.gen.ts`). The child's stdout
is framed NDJSON; the transport (`protocol.ts` / `_internal/stdio.ts`) does the JSON-RPC
plumbing.

**Handshake + a request** (`:1202`, `:1290`):
```ts
yield* client.request("initialize", buildCodexInitializeParams());
yield* client.notify("initialized", undefined);
// ... start a thread + turn:
return input.client.request("thread/start", startParams);          // (:460) — or "thread/resume" (:464) w/ fallback to start
const rawResponse = yield* client.raw.request("turn/start", params); // (:1290)
yield* client.request("turn/interrupt", { ... });                    // (:1323)
```

**Consume notifications** → session state (`:889-949`) — this is the "`item_started`/
`item_completed`" analog, in the newer dialect:
```ts
yield* client.handleServerNotification("thread/started", (payload) => updateSession(sessionRef, { resumeCursor: { threadId: payload.thread.id } }));
yield* client.handleServerNotification("turn/started",  (payload) => updateSession(sessionRef, { status: "running", activeTurnId: TurnId.make(payload.turn.id) }));
yield* client.handleServerNotification("turn/completed",(payload) => updateSession(sessionRef, { status: payload.turn.status === "failed" ? "error" : "ready", activeTurnId: undefined, ... }));
yield* client.handleServerNotification("error",         (payload) => updateSession(sessionRef, { status: payload.willRetry ? "running" : "error", lastError: payload.error.message }));
// item lifecycle → canonical item.* events (:505, :569, :880 handle item/*, item/agentMessage/delta, etc.)
```

**Answer approvals** via **server requests** (Codex asks the client) (`:952-1066`):
```ts
yield* client.handleServerRequest("item/commandExecution/requestApproval", (payload) => Effect.gen(function* () {
  const requestId = ApprovalRequestId.make(yield* randomUUIDv4("command-approval-request"));
  // emit request.opened, park a Deferred, await the human decision, respond to codex
}));
yield* client.handleServerRequest("item/fileChange/requestApproval", ...);
yield* client.handleServerRequest("item/tool/requestUserInput", ...);
```

**Codex takeaway:** an out-of-process structured server. **Also headless** — `codex
app-server` speaks JSON-RPC, not a TUI. (Distinct from the *terminal* `codex` a Continuum
shell tile hosts today.)

### 2.3 Cursor / Grok — ACP (Agent Client Protocol) over stdio [VERIFIED]

`apps/server/src/provider/acp/AcpSessionRuntime.ts` is the shared runtime; the two
providers differ only in the spawn command and auth method.

**Spawn** — the only per-provider difference:
```ts
// Cursor (CursorAcpSupport.ts:37):     command: settings?.binaryPath || "agent",  args: [...(-e endpoint)?, "acp"]
// Grok   (GrokAcpSupport.ts:36):        command: settings?.binaryPath || "grok",   args: ["agent", "stdio"]
```
Both feed `AcpSessionRuntime.layer({ spawn, authMethodId, clientCapabilities })`.

**Spawn + handshake + session** (`AcpSessionRuntime.ts:326-343`, `:519-540`, `:627`):
```ts
const child = yield* spawner.spawn(ChildProcess.make(spawnCommand.command, spawnCommand.args, { cwd, env, shell }));
const acp   = yield* EffectAcpClient.layerChildProcess(child, { ...logging }); // typed ACP client over stdio

const initializeResult = yield* acp.agent.initialize({ protocolVersion: 1, clientCapabilities, clientInfo });
yield* acp.agent.authenticate({ methodId: options.authMethodId });            // "cursor_login" | "xai.api_key" | "cached_token"
// new session (or loadSession for resume, :582):
const sessionSetupResult = yield* runLoggedRequest("session/new", newPayload, acp.agent.newSession(newPayload));
```

**Prompt** (`:707-748`) — one turn, serialized by a semaphore; the RPC fiber can be
interrupted to cancel:
```ts
prompt: (payload) => promptSerializationSemaphore.withPermit(Effect.gen(function* () {
  const requestPayload = { sessionId: started.sessionId, ...payload };
  const promptRpcFiber = yield* runLoggedRequest("session/prompt", requestPayload, acp.agent.prompt(requestPayload)).pipe(Effect.forkIn(runtimeScope));
  return yield* Fiber.join(promptRpcFiber);  // resolves with { stopReason } (or "cancelled" on interrupt)
})),
```

**Consume `session/update` notifications** (`:359-373`) — the streaming agent output
(assistant chunks, tool calls, plan, mode changes). Handled, de-duplicated against replay, and
pushed onto `eventQueue`; `getEvents: () => Stream.fromQueue(eventQueue)` (`:696`). Also
registers a `session/request_permission` handler (`:102`) → approvals.

**ACP takeaway:** **one runtime, two agents** (Cursor + Grok today, any ACP agent tomorrow —
Gemini CLI, Zed's agents, etc.). ACP is an emerging **open standard**
(agentclientprotocol.com, referenced in the code's own doc-comments). This is the highest-
leverage single steal: adopt ACP and Continuum gets a *family* of managed agents from one
integration. **Still headless** (stdio JSON-RPC), like Codex.

### 2.4 OpenCode — HTTP SDK to a managed server [VERIFIED]

`provider/opencodeRuntime.ts` (server lifecycle) + `Layers/OpenCodeAdapter.ts` (drive).

**Connect** (`opencodeRuntime.ts:479-517`): if `serverUrl` set, use it (external, no scope);
else spawn `opencode` and wait for `"opencode server listening"` on stdout (`:39`,
`:343-410`). Then:
```ts
import { createOpencodeClient } from "@opencode-ai/sdk/v2";
const client = createOpencodeClient({ baseUrl, directory, headers?, throwOnError: true });
```

**Drive** (`OpenCodeAdapter.ts:1073`, `:1241`, `:416`):
```ts
const openCodeSession = yield* runOpenCodeSdk("session.create", () => client.session.create({ ... }));
yield* runOpenCodeSdk("session.promptAsync", () => context.client.session.promptAsync({ ... }));
yield* runOpenCodeSdk("session.abort", () => context.client.session.abort({ sessionID: context.openCodeSessionId }));
```

**Consume** (`OpenCodeAdapter.ts:978-992`) — a long-poll SSE subscription as an async iterable,
with an `AbortController` finalizer:
```ts
runOpenCodeSdk("event.subscribe", () => context.client.event.subscribe(undefined, { signal: eventsAbortController.signal }))
  .pipe(
    Stream.fromAsyncIterable(iterable, (cause) => new OpenCodeRuntimeError({ operation: "event.subscribe", ... })),
    Stream.runForEach((event) => handleSubscribedEvent(context, event)),   // → canonical events; text → content.delta (:614)
  );
get streamEvents() { return Stream.fromQueue(runtimeEvents); }             // (:1468)
```

**OpenCode takeaway:** the odd one out — **HTTP, not stdio**; and the server can be **remote**
(`serverUrl`). That naturally aligns with Continuum's Decision D (remote execution): a managed
OpenCode agent could live on a VPS with only the HTTP client local.

### 2.5 Swift / Continuum sketch — `AgentAdapter` + `ManagedAgentSession`

A direct port, dropping Effect for `async`/`AsyncStream`. **This is a sketch to spec against,
not final API.** It maps events → the **existing** `AgentStatus`
(`continuum:Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift:85`) so managed
agents light up the *same* sidebar/rollup the readers feed.

```swift
// The canonical event — Continuum's port of ProviderRuntimeEvent (trimmed to the variants
// that drive status + UI; the full 47 can follow). Body-carrying by nature; see §3 on I5.
public enum AgentRuntimeEvent: Sendable {
    case sessionStateChanged(SessionState)                 // starting|ready|running|waiting|stopped|error
    case turnStarted(turnId: String)
    case turnCompleted(TurnOutcome)                        // completed|failed|interrupted|cancelled + errorMessage?
    case itemStarted(ItemKind, title: String?)             // command_execution|file_change|assistant_message|reasoning|...
    case itemCompleted(ItemKind, status: ItemStatus)
    case contentDelta(streamKind: StreamKind, delta: String)   // <-- transcript text; NEVER crosses sync (I5)
    case requestOpened(requestId: String, kind: ApprovalKind)  // needs a human decision
    case requestResolved(requestId: String, decision: String)
    case userInputRequested(requestId: String, questions: [UserInputQuestion])
    case tokenUsageUpdated(TokenUsageSnapshot)
    case runtimeError(message: String)
}

public protocol AgentAdapter: Sendable {                   // mirrors ProviderAdapterShape
    var providerKind: AgentKind { get }                    // .claude | .codex | .cursor | .grok | .opencode
    func startSession(_ input: AgentSessionStartInput) async throws -> AgentSession
    func sendTurn(_ input: AgentSendTurnInput) async throws -> AgentTurnStartResult
    func interruptTurn(threadId: String, turnId: String?) async throws
    func stopSession(threadId: String) async throws
    func respondToRequest(threadId: String, requestId: String, decision: ApprovalDecision) async throws
    func respondToUserInput(threadId: String, requestId: String, answers: UserInputAnswers) async throws
    func hasSession(threadId: String) async -> Bool
    var events: AsyncStream<AgentRuntimeEvent> { get }     // == streamEvents
}
```

**`ManagedAgentSession`** — spawns the child process (Codex/ACP) or drives the in-process
loop (Claude), pumps native frames → `AgentRuntimeEvent`, and derives `AgentStatus`:

```swift
// One structural difference per provider:
//   .codex  -> Process("codex", ["app-server"]),  JSON-RPC over stdin/stdout (NDJSON frames)
//   .cursor -> Process("agent", ["acp"]),          ACP JSON-RPC over stdio
//   .grok   -> Process("grok", ["agent","stdio"]), ACP JSON-RPC over stdio
//   .claude -> NO child for the loop; drive @anthropic-ai/claude-agent-sdk (via a Node
//              sidecar or a Swift Anthropic client). resume by sessionId.
//   .opencode -> HTTP client to a spawned/remote server; SSE event.subscribe long-poll.

// Status derivation — the port of agentAwareness.ts:61 (§4). Pure, testable, feeds the
// SAME AgentDescriptor.status the readers write.
func deriveStatus(session: SessionState, latestTurn: TurnOutcome?, hasPendingApprovals: Bool,
                  hasPendingUserInput: Bool) -> AgentStatus {
    if hasPendingApprovals || hasPendingUserInput { return .needsAttention }   // waiting_for_{approval,input}
    if session == .error || latestTurn == .failed  { return .idle }            // "failed" -> surface via detail; not a status enum case
    if session == .starting                          { return .configuring }
    if session == .running                           { return .working }
    if latestTurn == .completed                      { return .done }
    return .idle
}
```

**The managed-agent tile vs. a terminal tile** — the concrete fork:

| | Terminal tile (today) | Managed-agent tile (new) |
|---|---|---|
| Process | tmux window hosts a **TUI** (`claude`, `codex`, shell) | a **headless** structured session (SDK loop / `app-server` / ACP / HTTP) |
| Render | **ghostty surface** — raw pty bytes, colors, cursor | a **structured transcript view** (message/tool/plan cards) — ghostty renders *nothing* useful here |
| Input | keystrokes into the pty | `sendTurn(text)` + **structured** approve/deny/answer buttons |
| Status source | **read the agent's own files** (`AgentStateReader`, AGENT-READERS) | **derive from `events`** (`AgentRuntimeEvent` → `AgentStatus`) — first-class, no file tail |
| Identity | pane pid → session file (Claude), mtime+cwd (Codex) | adapter-assigned `threadId`; exact, no guessing |
| Persistence | tmux session survives; files on disk | adapter session + event store (agent #4) |
| Approvals | **impossible to expose structurally** (it's just terminal text) | `request.opened` → real UI affordance |

Both are tiles on the canvas; they are **different tile kinds** with different view/input
layers. See §4.

---

## 3. What Continuum steals — mapped to Decision C

Decision C (`docs/38` §C) says *"every tile is observed identically; agent-ness is detected,
not declared."* That governs **terminal-launched** agents and **stays exactly as specified**.
The managed path is an **additive second tier**:

1. **The adapter interface as the managed-agent contract.** Port `ProviderAdapterShape` →
   `AgentAdapter` (§2.5). One protocol, N providers; callers never branch. This is the
   "declare" tier — the user *chooses* "spawn a managed Claude/Codex/Cursor agent," and
   Continuum drives it. It does **not** replace detection; it's a different entry point.
   *(Steal: the interface + the routing seam `ProviderService` → binding → registry.)*

2. **The canonical event union.** Port `ProviderRuntimeEvent` → `AgentRuntimeEvent`. Even if
   phase 1 only implements ~10 variants, adopt the **shape** (`{type, threadId, turnId?,
   itemId?, payload}` + `session.state.changed` / `turn.completed` / `item.*` / `request.*`).
   It is the managed-tier analog of the readers' `AgentSnapshot` — and it lets *one* status
   function serve both tiers. *(Steal: the union + `CanonicalItemType`/`CanonicalRequestType`
   vocabulary.)*

3. **ACP (Agent Client Protocol) as a standard.** This is the strategic steal. `agent acp` /
   `grok agent stdio` run through **one** `AcpSessionRuntime`; the protocol is an open
   standard (agentclientprotocol.com) that Gemini CLI, Zed, and others speak. Continuum
   implementing **one** ACP client yields a *family* of managed agents from a single
   integration — far better ROI than N bespoke integrations. *(Steal: adopt ACP first; make
   Cursor/Grok the reference agents.)*

4. **Pure status derivation.** `agentAwareness.ts:61` is a **pure function** from
   session/turn/pending-approval state → a 7-value phase. Port it (§2.5 `deriveStatus`) — it
   maps onto the existing `AgentStatus` and satisfies `docs/38`'s I6 ("status soundness") by
   construction: it's fed by *positive events*, not guesses. *(Steal: the pure-function
   discipline + the phase mapping table.)*

5. **Driver = plain value, instance = live adapter, multi-instance by config.** The
   `ProviderDriver`/`ProviderInstance` split (one `codex` driver, `codex_work` +
   `codex_personal` instances) is a clean pattern for "same agent binary, different
   HOME/account." *(Steal: the driver record + per-instance HOME isolation via
   `CODEX_HOME`/env.)*

**Boundary reminder (unchanged):** readers (AGENT-READERS spike) are the tier for
**terminal-launched** agents — the shell tile a user already has, running `claude`
interactively; Continuum watches its `~/.claude/*.jsonl` and never drives it. **Adapters** are
the tier for agents **Continuum spawns** as structured sessions. They coexist:
`AgentDescriptor.status` is the shared sink — a reader writes it for observed tiles, a managed
adapter's `deriveStatus` writes it for managed tiles. The sidebar/rollup
(`SidebarTreeBuilder`, `CanvasNSView` rollup) reads one field, source-agnostic.

**I5 privacy line still binds the managed tier — and is *harder* there.** The readers are I5-
clean by shape (they only read metadata). A managed adapter's event stream **carries bodies**
(`content.delta`, `item` titles, tool inputs, `errorMessage`). Continuum must keep the *body-
carrying* events **local to the view layer** and let only the *derived* `AgentStatus` +
metadata cross the sync boundary — exactly the split `docs/38` Decision E already mandates
(sync layer 1 only; live pane/session state re-binds locally). Spec this explicitly: the
managed event store (agent #4) is local; sync gets the projection.

---

## 4. What does NOT transfer — the headless fork (read this twice)

**A managed agent is NOT "an agent in a terminal." It is a different tile kind.** This is the
single most important thing to carry back.

- **The Claude SDK session is headless.** `query({prompt, options})` is a *programmatic loop*
  yielding `SDKMessage`s (`ClaudeAdapter.ts:3508`). There is **no interactive TUI** to render
  in a ghostty surface. Same for `codex app-server` (JSON-RPC, `CodexSessionRuntime.ts:722`),
  ACP (`agent acp` / `grok agent stdio`, stdio JSON-RPC), and OpenCode (HTTP). **None** of the
  four managed drive mechanisms produces terminal output a ghostty tile can meaningfully show.
  Piping their stdout into ghostty would render JSON-RPC frame noise, not an agent UI.
- **Therefore a managed-agent tile needs a *structured transcript view*, not a terminal
  surface.** Message cards, tool-call cards (from `item.*`), plan (`turn.plan.updated`), diffs
  (`turn.diff.updated`), and **approval affordances** (`request.opened` → approve/deny
  buttons; `user-input.requested` → a question form). That's a real new SwiftUI/AppKit view,
  a real new tile `kind`, and a real new input path (`sendTurn` + `respondToRequest`).
- **Detect-not-declare does not apply to the managed tier.** Managed agents are *declared* —
  the user picks "spawn a managed Codex agent." There's nothing to detect; the adapter *is*
  the source of truth. This is the philosophical inverse of Decision C's terminal tier, and
  that's fine — they're **two tiers for two use cases**, not a contradiction. Terminal tiles:
  "I'm living in my terminal running claude, just watch me." Managed tiles: "spawn me an agent
  and give me structured controls."
- **The `Effect` machinery does not transfer.** t3code is built on Effect (`Effect<A,E>`,
  `Stream`, `Layer`, `Scope`, `Queue`, `Ref`, `Fiber`, `Deferred`, `Semaphore`). Swift's
  equivalents: `async throws`, `AsyncStream`, structured concurrency + `withTaskGroup`,
  `Task`/cancellation, actors for the session map, `CheckedContinuation` for the `Deferred`-
  parked approvals. Port the **architecture** (interface, event union, per-provider drive,
  status function), not the runtime.
- **`textGeneration` is orthogonal.** Each driver also bundles a `textGeneration` closure
  (commit-message/PR/branch/title generation via one-shot `codex exec` / `claude` calls). It's
  a separate concern from the agent session and out of scope for the managed-tile spec.

**Practical implication:** the managed path is **more product than plumbing**. The adapters are
tractable (§2 shows all four). The hard, novel work is the **managed-agent tile UX** — the
transcript view and the approval/answer affordances that a terminal fundamentally can't offer.

---

## 5. Open questions / forks (for Dylan to lock)

**The big one:** *Does Continuum add a managed-agent tile kind at all — and if so, which
protocol per agent?*

- **Fork A — add the managed tier now, or defer.** Terminal-tile observation (readers) is
  already spec'd and lower-risk; it delivers "see what my agents are doing" without new UX.
  The managed tier is a bigger bet (new tile kind, transcript view, approvals) but unlocks
  what terminals *can't* do: structured approvals, programmatic steering, remote agents, and a
  cross-device controllable agent (the iOS story — a phone can't drive a ghostty TUI, but it
  *can* render a transcript + tap approve). **Recommendation to weigh:** if the iOS/remote arc
  matters, the managed tier is the only path that serves it; if the near-term goal is "know my
  local agents' status," readers alone suffice.

- **Fork B — protocol per agent.** If managed: **ACP first** (Cursor + Grok, and the whole ACP
  family for one integration cost). Codex `app-server` and the Claude SDK are worth it for the
  two most-used agents, but each is bespoke. Question: is a **Node sidecar** acceptable to host
  `@anthropic-ai/claude-agent-sdk` and `@opencode-ai/sdk` (they're npm packages, no native
  Swift), or does Continuum want pure-Swift clients (an Anthropic HTTP client; an ACP client in
  Swift; a Codex JSON-RPC client in Swift)? A sidecar is faster to ship and reuses t3code's
  exact drive code; pure-Swift is cleaner long-term and avoids a Node runtime dependency in a
  native app. **This is the pivotal build decision.**

- **Fork C — one tile kind or two.** Is a managed agent a *new* `Tile.kind` (`.managedAgent`)
  distinct from `.terminal`, or a *mode* of a tile? `docs/38` Decision C deliberately kept tile
  `kind = .terminal` for observed agents. Managed agents are structurally different enough
  (view + input) that a new kind seems right — but confirm against the canvas/zone model.

- **Fork D — do the tiers converge on identity?** A managed session has an adapter-assigned
  `threadId`; an observed session has a pid/runId/cwd link. If a user "promotes" a terminal
  agent to managed (or vice-versa), is there a shared identity? Probably not for phase 1
  (they're distinct lifecycles), but name the seam.

- **Fork E — approvals UX ownership.** `request.opened` / `user-input.requested` are agent #6's
  turf (approvals/UX). The adapter *emits* them and *consumes* the decision
  (`respondToRequest`); the tile *renders* the affordance. Confirm the hand-off with #6.

- **Smaller opens:** (1) how much of the 47-variant event union to port in phase 1 (start with
  the ~10 status-driving ones); (2) whether to adopt t3code's `ProviderDriver`/instance split
  or a simpler "one adapter per agent kind" for phase 1; (3) remote managed agents (OpenCode's
  `serverUrl` / SSH-hosted `app-server`) align with Decision D — sequence after local works;
  (4) I5 enforcement mechanism for body-carrying managed events (taint test that the synced
  projection excludes `content.delta`/tool bodies).

---

## Sources (file:line)

**t3code (clone, read-only):**
- Interface: `apps/server/src/provider/Services/ProviderAdapter.ts:45-126`.
- Event union: `packages/contracts/src/providerRuntime.ts:148-196` (type literals),
  `:248-262` (base), `:276,362,404,421` (key payloads), `:967-1017` (the union), `:1019` (alias).
- Session contracts: `packages/contracts/src/provider.ts:34-110` (`ProviderSession`,
  `ProviderSessionStartInput`, `ProviderSendTurnInput`, `ProviderTurnStartResult`).
- Driver SPI: `apps/server/src/provider/ProviderDriver.ts:64-157`; catalog
  `builtInDrivers.ts:35-53`; `builtInProviderCatalog.ts:1-17`.
- Drivers: `Drivers/{Claude,Codex,Cursor,Grok,OpenCode}Driver.ts` (kinds, binaries, install,
  home isolation) — Claude `:59-82,110-217`; Codex `:62-146`; Cursor `:55-101`; Grok `:42-102`;
  OpenCode `:57-115`.
- Claude drive: `Layers/ClaudeAdapter.ts:9-22` (SDK import), `:1358-1367` (createQuery),
  `:2860-2914` (dispatch + stream), `:3443-3521` (options+query), `:3611-3639` (fork),
  `:3648-3742` (sendTurn/steer), `:3771-3803` (approvals), `:3865` (streamEvents).
- Codex drive: `Layers/CodexSessionRuntime.ts:722-754` (spawn), `:889-949` (notifications),
  `:952-1066` (approval server-requests), `:1202-1339` (init/turn/interrupt/read/rollback);
  typed client `packages/effect-codex-app-server/src/client.ts:38-78,197-269`.
- ACP drive: `acp/AcpSessionRuntime.ts:326-343` (spawn), `:359-373` (session/update),
  `:519-540` (init/auth), `:582,627` (load/new), `:696-748` (events+prompt);
  spawn cmds `acp/CursorAcpSupport.ts:32-46`, `acp/GrokAcpSupport.ts:31-51`.
- OpenCode drive: `provider/opencodeRuntime.ts:479-517` (connect/client),
  `Layers/OpenCodeAdapter.ts:978-992` (event.subscribe), `:1073,1241,416` (create/prompt/abort),
  `:1468` (streamEvents).
- Routing: `Layers/ProviderService.ts:184-199` (stamp/assert), `:300-349` (subscription
  reconcile), `:445-481` (binding→registry→adapter).
- Status derivation: `packages/shared/src/agentAwareness.ts:8-142` (phase enum + pure
  `projectThreadAwareness` / `resolveThreadAwarenessPhase`).

**Continuum:**
- `Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift:85-119` — `AgentStatus`
  (`configuring|working|idle|needsAttention|done|stale`), `AgentDescriptor`
  (`agentKind, worktreePath, status, statusUpdatedAt, runId`).
- `docs/38-agent-orchestration-architecture.md` §C (agent awareness), §E (sync boundary), I5/I6.
- `docs/2026-06-30-orchestration-spikes/AGENT-READERS.md` — the observed/terminal tier this
  managed tier sits *beside*.
