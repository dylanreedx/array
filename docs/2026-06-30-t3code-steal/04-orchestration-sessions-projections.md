# Stealing from t3code — Orchestration, Sessions & Projections

Status: **research / extraction — 2026-06-30.** Audience: a future implementing agent
with zero memory of the originating conversation. Ground truth is
`pingdotgg/t3code` (cloned read-only). Every claim is tagged:

- **[fact]** — verified against `t3code` at `file:line` (paths relative to the clone
  root `apps/server/src/…` or `packages/contracts/src/…`), or against a Continuum file
  I read.
- **[judgment]** — my reasoning about how it maps to Continuum; may be wrong.
- **[inferred]** — plausible from the code but not directly proven.

Read first: `docs/38-agent-orchestration-architecture.md` **Decision E** (`:340–363`, sync
the SPATIAL layer only) and `docs/2026-06-30-orchestration-spikes/SYNC-MODEL.md` (the
op-log recommendation). This doc is the **other half** of Decision E: t3code's
event-sourced projection model is the template for the ACTIVITY / agent-state layer that
Decision E says is *derived and one-directional*, not synced.

**The one-sentence thesis.** t3code proves the split Continuum is reaching for: **writes
go through one authority and become an append-only event log; reads are materialized
projections that are pushed one-way to subscribers (snapshot-then-tail); and the live
process/session handles live in a *separate, private* store that is never projected and
never leaves the host.** Continuum should sync the spatial layer bidirectionally
(op-log) and *project* the activity tree one-way — and keep runtime handles out of both.

---

## 0. Orientation — how t3code is laid out

[fact] t3code is a monorepo. The orchestration server is `apps/server/`. The pieces this
doc extracts:

| Concern | File(s) |
|---|---|
| Domain events + read-model types | `packages/contracts/src/orchestration.ts` |
| Pure command→events decider | `apps/server/src/orchestration/decider.ts` |
| Pure event→read-model projector (in-memory) | `apps/server/src/orchestration/projector.ts` |
| The engine (queue, dispatch, reconcile) | `apps/server/src/orchestration/Layers/OrchestrationEngine.ts` |
| Append-only event store (SQL) | `apps/server/src/persistence/Layers/OrchestrationEventStore.ts` |
| SQL read-model projectors + checkpoint replay | `apps/server/src/orchestration/Layers/ProjectionPipeline.ts` |
| Projection checkpoint table | `apps/server/src/persistence/Layers/ProjectionState.ts` |
| Session-lifecycle / lazy-resume | `apps/server/src/provider/Layers/ProviderService.ts` |
| Private runtime record (resume cursor) | `apps/server/src/persistence/ProviderSessionRuntime.ts` |
| The directory over that record | `apps/server/src/provider/Layers/ProviderSessionDirectory.ts` |
| Idle reaper | `apps/server/src/provider/Layers/ProviderSessionReaper.ts` |
| Schema (DDL) | `apps/server/src/persistence/Migrations/00{1,4,5}_*.ts` |
| One-way push to clients (snapshot+stream) | `apps/server/src/ws.ts` |

[fact] It is written in [Effect](https://effect.website) (an effect-system / DI library
for TS). `Effect.Effect<A, E, R>` = a lazy computation yielding `A`, failing with `E`,
needing services `R`. `Layer` = DI wiring. `Schema.Struct` = a runtime-validated,
codec-backed type. **For Continuum this is all incidental** — the *shapes* transfer, the
Effect machinery does not. Read `yield* x` as "await x", `Effect.gen(function*(){…})` as
"an async function".

---

## 1. What t3code does — the CQRS shape

### 1.1 The pipeline, end to end

[fact] The whole write path lives in `OrchestrationEngine.ts` and is remarkably small
(~340 lines). One diagram, then the code:

```
client → dispatchCommand(cmd)         [ws RPC, write side]
      → commandQueue (serialized, single consumer)   OrchestrationEngine.ts:90,303
      → idempotency check by commandId               :138  (command receipts)
      → decideOrchestrationCommand(cmd, readModel)    :153  ← PURE: (state,cmd)→events
      → [SQL transaction]                             :169
          for each planned event:
            eventStore.append(event)                  :176  ← append-only orchestration_events
            projectEvent(inMemModel, savedEvent)      :177  ← fold into in-mem read model
            projectionPipeline.projectEvent(event)    :178  ← materialize projection_* tables
          commandReceipt.upsert(accepted)             :190
      → PubSub.publish(event)                         :217  ← fan-out to subscribers (one-way)
```

**Reads never touch this path.** Clients read by *subscribing* to projections (§1.5).

### 1.2 The decider — pure `(state, command) → events`

[fact] `decideOrchestrationCommand` (`decider.ts:96`) is a pure function: it takes the
current `readModel` and one `command`, validates invariants against the read model, and
returns one or an array of *planned events* (`Omit<OrchestrationEvent, "sequence">` — the
store assigns the sequence). It has **no side effects** except minting UUIDs and reading
the clock; it never writes. Signature (`decider.ts:96–106`):

```ts
export const decideOrchestrationCommand = Effect.fn("decideOrchestrationCommand")(
  function* ({ command, readModel }: {
    readonly command: OrchestrationCommand;
    readonly readModel: OrchestrationReadModel;
  }): Effect.fn.Return<
    PlannedOrchestrationEvent | ReadonlyArray<PlannedOrchestrationEvent>,
    OrchestrationCommandInvariantError | PlatformError.PlatformError,
    Crypto.Crypto
  > {
    switch (command.type) { … }   // one arm per command type
  });
```

[fact] Sample arm — `thread.turn.start` emits **two** events atomically (`decider.ts:389–461`):
a `thread.message-sent` (role user) then a `thread.turn-start-requested` whose
`causationEventId` points back at the message event (`:446`) — causal linkage is captured
in the event, not inferred later. Invariants are checked first and *fail the command*
(e.g. `requireThread`, `decider.ts:390`; project-not-empty guard, `:172`).

[fact] A command can **decompose into a sequence of sub-commands**: `project.delete` with
`force` folds all child `thread.delete`s then the `project.delete` via
`decideCommandSequence` (`decider.ts:178–196`), which threads an evolving read model
through each sub-decision (`:73–91`). So the decider is *compositional*.

### 1.3 The projector — pure `(readModel, event) → readModel`

[fact] `projectEvent` (`projector.ts:190`) is the pure fold: `(OrchestrationReadModel,
OrchestrationEvent) → OrchestrationReadModel`, one `switch` arm per event type, each
decoding the event payload with a `Schema` and returning a **new** read model (immutable
update). `createEmptyReadModel` (`projector.ts:181`) is the identity/zero. Example
(`projector.ts:266–305`, `thread.created`): decode payload → build a fresh
`OrchestrationThread` → append-or-replace in `threads`. Everything is
copy-on-write `{ ...model, threads: … }`.

[fact] The same `projectEvent` is used in **three** places — the sign of a genuinely pure
fold: (a) inside the decider to preview the read model across a command sequence
(`decider.ts:86`); (b) in the engine to advance the authoritative in-memory model after
append (`OrchestrationEngine.ts:177`); (c) in the engine's crash-reconcile replay
(`:100`). One function, reused for compute-forward and replay-recover. **[judgment] this
reuse is the property Continuum should copy: the projection function must be a pure fold
so it can run live *and* as replay.**

### 1.4 In-memory read model + reconcile from a sequence checkpoint

[fact] The engine holds `commandReadModel` in memory (`OrchestrationEngine.ts:88`),
seeded at startup from the persisted projection snapshot
(`projectionSnapshotQuery.getCommandReadModel()`, `:301`) — *not* by replaying all events
from zero. Steady state: each committed event is folded into it (`:177,215`).

[fact] **Reconciliation on failure** (`OrchestrationEngine.ts:113–126`,
`reconcileReadModelAfterDispatchFailure`): if a dispatch fails mid-flight, it records the
sequence *before* dispatch (`dispatchStartSequence`, `:106`), then on failure reads
`eventStore.readFromSequence(dispatchStartSequence)` and re-folds those events into the
in-memory model (`:121`), re-publishing them (`:124`). This heals divergence between "what
I thought I committed" and "what actually landed in the log". The event log is the source
of truth; the in-memory model is a cache that can always be rebuilt from a checkpoint.

[fact] The **SQL** projections reconcile the same way but per-projector
(`ProjectionPipeline.ts`). Each projector is checkpointed by name in a `projection_state`
table (`{projector, last_applied_sequence, updated_at}`, `ProjectionState.ts:28`,
migration `005_Projections.ts:106`). At boot, `bootstrapProjector`
(`ProjectionPipeline.ts:1534`) reads `readFromSequence(lastAppliedSequence)` (`:1542`) and
replays only unseen events. **Critically**, applying an event and advancing its checkpoint
happen in *one* SQL transaction (`:1510–1520`) — so a crash can never leave the checkpoint
ahead of the write; replay is idempotent. `minLastAppliedSequence()` (`ProjectionState.ts:99`)
gives the low-water mark across all projectors (a natural compaction/GC horizon).

### 1.5 Reads are one-way projections — snapshot-then-tail

[fact] Clients never poll and never read the event log directly for state. They
**subscribe**. `ws.ts` `subscribeShell` (`:1062`) returns a `Stream.concat` of:
1. one `{ kind: "snapshot", snapshot }` from `projectionSnapshotQuery.getShellSnapshot()`
   (`ws.ts:1066,1087`), then
2. the live tail: `orchestrationEngine.streamDomainEvents` mapped to stream events
   (`ws.ts:1079–1085`), each `{ kind: "event", event }`.

[fact] The stream item type is exactly this union — `OrchestrationThreadStreamItem =
{kind:"snapshot"} | {kind:"event"}` (`contracts/orchestration.ts:1115`). Subscriptions
require a **read** scope (`AuthOrchestrationReadScope`, `ws.ts:282–284`); commands go
through a *separate* RPC (`dispatchCommand`, `contracts/orchestration.ts:1222`). Reads and
writes are physically different channels. **This is CQRS at the transport boundary.**

[fact] `streamDomainEvents` is backed by an unbounded `PubSub` (`OrchestrationEngine.ts:91,329`);
each accessor gets a fresh subscription so many consumers (the ws server, the runtime
ingestion, reactors) each independently receive every event, one-directionally.

### 1.6 The write-authority boundary is a *type*

[fact] This is the subtlest and most important idea. Commands split into two unions
(`contracts/orchestration.ts:660–781`):

- **`ClientOrchestrationCommand`** (16 arms): what a *client* may dispatch —
  `project.create`, `thread.create`, `thread.turn.start`, `thread.turn.interrupt`,
  `thread.approval.respond`, `thread.session.stop`, … (`:681–698`).
- **`InternalOrchestrationCommand`** (7 arms): what only *server-internal* code may
  dispatch — `thread.session.set`, `thread.message.assistant.delta`,
  `thread.activity.append`, `thread.turn.diff.complete`, `thread.reverted`, …
  (`:766–775`).

[fact] The internal commands are the **observed facts flowing back from the running
agent**. `ProviderRuntimeIngestion` translates raw provider events into internal commands
— e.g. it dispatches `thread.session.set` (`ProviderRuntimeIngestion.ts:1341,1591`) when
the provider's session status changes, and `thread.activity.append` /
`thread.message.assistant.delta` as the agent works. Those become events → projections →
the client's live stream. **The client cannot forge agent state; agent state is derived,
one-directionally, from the actual runtime.** [judgment] This is the exact discipline
Decision E wants for the activity tree.

---

## 2. What t3code does — the schema

### 2.1 The append-only event log — `orchestration_events`

[fact] Migration `001_OrchestrationEvents.ts:8`:

```sql
CREATE TABLE IF NOT EXISTS orchestration_events (
  sequence          INTEGER PRIMARY KEY AUTOINCREMENT,  -- GLOBAL total order
  event_id          TEXT NOT NULL UNIQUE,
  aggregate_kind    TEXT NOT NULL,                       -- 'project' | 'thread'
  stream_id         TEXT NOT NULL,                       -- the aggregate's id
  stream_version    INTEGER NOT NULL,                    -- PER-STREAM order (optimistic-concurrency)
  event_type        TEXT NOT NULL,
  occurred_at       TEXT NOT NULL,
  command_id        TEXT,                                -- idempotency / correlation
  causation_event_id TEXT,                               -- causal chain
  correlation_id    TEXT,
  actor_kind        TEXT NOT NULL,                       -- 'client'|'provider'|'server'
  payload_json      TEXT NOT NULL,
  metadata_json     TEXT NOT NULL
);
CREATE UNIQUE INDEX idx_orch_events_stream_version
  ON orchestration_events(aggregate_kind, stream_id, stream_version);   -- :26
```

[fact] Two orderings on purpose (`OrchestrationEventStore.ts:106–157` INSERT): a **global
`sequence`** (autoincrement) drives projection replay and the subscription tail; a
**per-stream `stream_version`** is computed at insert with a `COALESCE((SELECT
stream_version+1 …), 0)` subquery (`:125–135`) and made unique per `(aggregate_kind,
stream_id)` — that's the optimistic-concurrency guard for a single aggregate. `actor_kind`
is inferred from the command prefix / metadata (`inferActorKind`, `:70–90`).
`payload`/`metadata` are opaque JSON columns validated by `Schema` on the way in/out.

[fact] Reads are cursor-paged: `readFromSequence(sequenceExclusive, limit)`
(`OrchestrationEventStore.ts:211`) streams `WHERE sequence > ? ORDER BY sequence ASC` in
500-row pages (`:68,178`). This is the replay primitive both reconcile paths use.

### 2.2 The read-model tables — `projection_*`

[fact] Migration `005_Projections.ts`. These are **derived**, disposable, rebuildable
from the log. All keyed by the aggregate id; note they are *flat* SQL, not the nested
in-memory `OrchestrationReadModel`:

| Table | PK | Purpose (`005_Projections.ts`) |
|---|---|---|
| `projection_projects` | `project_id` | project shells (`:8`) |
| `projection_threads` | `thread_id` | thread shells; `latest_turn_id`, `deleted_at` (`:21`) |
| `projection_thread_messages` | `message_id` | transcript rows; `turn_id`, `is_streaming` (`:36`) |
| `projection_thread_activities` | `activity_id` | **the activity feed** — `tone`, `kind`, `summary`, `payload_json`, `turn_id` (`:49`) |
| `projection_thread_sessions` | `thread_id` | **derived, client-visible** session state — `status`, `provider_session_id`, `active_turn_id`, `last_error` (`:61`) |
| `projection_turns` | `row_id` | per-turn state + checkpoint ref/status/files; `UNIQUE(thread_id, turn_id)` (`:75`) |
| `projection_pending_approvals` | `request_id` | outstanding approvals; `status`, `decision` (`:95`) |
| `projection_state` | `projector` | **the replay checkpoint** — `last_applied_sequence` (`:106`) |

[fact] The activity feed (`projection_thread_activities`) is produced solely by
`thread.activity-appended` events (`contracts/orchestration.ts:1107`,
`ThreadActivityAppendedPayload:975`), each an `OrchestrationThreadActivity` = `{ id, tone:
info|tool|approval|error, kind, summary, payload, turnId, sequence?, createdAt }`
(`contracts/orchestration.ts:305–323`). **This append-only, tone-tagged activity feed is
the direct analogue of Continuum's activity tree.** [judgment]

### 2.3 The PRIVATE runtime record — `provider_session_runtime`

[fact] The load-bearing separation. This table is **never projected and never sent to a
client**. It holds the live handles + resume state for one provider session per thread.
Migration `004_ProviderSessionRuntime.ts:8`:

```sql
CREATE TABLE IF NOT EXISTS provider_session_runtime (
  thread_id           TEXT PRIMARY KEY,               -- ONE session per thread
  provider_name       TEXT NOT NULL,
  adapter_key         TEXT NOT NULL,
  runtime_mode        TEXT NOT NULL DEFAULT 'full-access',
  status              TEXT NOT NULL,                  -- starting|running|stopped|error
  last_seen_at        TEXT NOT NULL,                  -- drives the reaper
  resume_cursor_json  TEXT,                           -- OPAQUE provider resume token
  runtime_payload_json TEXT                           -- OPAQUE {cwd, modelSelection, activeTurnId,…}
);
-- migration 027 later adds provider_instance_id
```

[fact] The typed shape (`persistence/ProviderSessionRuntime.ts:33`): `resumeCursor` and
`runtimePayload` are `Schema.NullOr(Schema.Unknown)` — **deliberately opaque**; the
orchestration core never interprets them, only the adapter does. `status` is a *narrow*
runtime status — `starting|running|stopped|error` (`contracts/orchestration.ts:1152`) —
distinct from the richer *derived* session status
(`idle|starting|running|ready|interrupted|stopped|error`,
`OrchestrationSessionStatus:260`) that clients see. Upsert is a plain `ON CONFLICT
(thread_id) DO UPDATE` (`ProviderSessionRuntime.ts:151–184`).

[fact] **Two stores, verified distinct.** `provider_session_runtime` is written directly
by `ProviderSessionDirectory.upsert` (`ProviderSessionDirectory.ts:128`) — the private
record. `projection_thread_sessions` is written by the projector from `thread.session-set`
events (`ProjectionThreadSessions.ts`) — the client-visible derived view. **The private
handle store and the observable read model are separate tables with separate write
paths.** [judgment] This is precisely the "sync spatial / project activity / keep handles
private" trichotomy Decision E is chasing, realized in SQL.

[fact] `ProviderSessionDirectory.upsert` bumps `last_seen_at = now` on **every** write
(`ProviderSessionDirectory.ts:117,138`) and merges `runtime_payload` (`:143,47–58`); it is
called on every `sendTurn` (`ProviderService.ts:683`). So *activity* keeps a session
alive and *idleness* is just "no upsert lately" — which the reaper reads.

---

## 3. What t3code does — session lifecycle

### 3.1 Lazy resume — recover ON the next interaction, never eagerly at boot

[fact] **There is no eager re-spawn at server start.** I searched `bootstrap.ts` and
`serverRuntimeStartup.ts`: startup wires layers and starts the reaper + reactors
(`serverRuntimeStartup.ts:344–345`) but never calls `recoverSessionForThread` /
`startSession`. Sessions come back **on demand**.

[fact] The on-demand trigger is `resolveRoutableSession(threadId, operation,
allowRecovery)` (`ProviderService.ts:440`), called from every client-facing operation that
needs a live session — `sendTurn` (`:671`), `interruptTurn` (`:729`),
`respondToRequest` (`:766`), `respondToUserInput` (`:805`), and internally (`:983`), all
with `allowRecovery: true`. `stopSession` calls it with `allowRecovery: false` (`:838`) —
you don't resurrect a session merely to stop it. Logic (`:440–485`):

```
resolveRoutableSession:
  binding = directory.getBinding(threadId)         // the private runtime record
  if !binding: fail "no persisted binding"          // never seen this thread
  if adapter.hasSession(threadId): return {active:true}   // already live in memory
  if !allowRecovery: return {active:false}
  recovered = recoverSessionForThread({binding})    // ← lazy resume happens here
  return {active:true}
```

[fact] `recoverSessionForThread` (`ProviderService.ts:355`) has the **three branches**:

```
recoverSessionForThread(binding):
  adapter = registry.getByInstance(binding.providerInstanceId)
  hasResumeCursor = binding.resumeCursor != null

  // ── Branch 1: ADOPT-EXISTING (session still alive in adapter memory) ──  :371–388
  if adapter.hasSession(threadId):
      existing = adapter.listSessions().find(threadId)
      directory.upsert({...existing})               // re-bind, refresh last_seen
      analytics: strategy = "adopt-existing"
      return {adapter, session: existing}

  // ── Branch 2: no cursor → cannot recover ──                              :390–395
  if !hasResumeCursor:
      fail "no provider resume state is persisted"

  // ── Branch 3: RESUME-THREAD (rebuild from opaque cursor) ──             :397–429
  cwd = readPersistedCwd(binding.runtimePayload)     // from opaque runtime_payload
  model = readPersistedModelSelection(binding.runtimePayload)
  resumed = adapter.startSession({
      threadId, provider, providerInstanceId,
      cwd, modelSelection,
      resumeCursor: binding.resumeCursor,             // ← opaque token replayed to adapter
      runtimeMode: binding.runtimeMode ?? "full-access",
  })
  if resumed.provider != adapter.provider: fail "adapter/provider mismatch"
  directory.upsert({...resumed})                      // persist the fresh cursor
  analytics: strategy = "resume-thread"
  return {adapter, session: resumed}
```

[judgment] The elegance: the **orchestration core does not know what a resume cursor is**
— it stores the opaque blob, hands it back to the adapter on recovery, and the adapter
does the provider-specific magic. A "fresh-start" is not a branch here; it is the earlier
`startSession` path when there's no binding at all. Recovery is strictly
adopt → (else) resume-from-cursor → (else) fail-honestly.

### 3.2 The idle reaper — timer-driven, active-turn-aware, disconnect-blind

[fact] `ProviderSessionReaper.ts`. Constants: **30-min inactivity threshold** (`:16`),
**5-min sweep interval** (`:17`), both overridable. It is started once at boot
(`serverRuntimeStartup.ts:345`) and runs on a timer: `sweep.pipe(…,
Effect.repeat(Schedule.spaced(sweepIntervalMs)))` (`:120`). The sweep (`:36–104`):

```
sweep:
  for binding in directory.listBindings():
    if binding.status == "stopped": continue                      // :42
    idleMs = now - Date.parse(binding.lastSeenAt)
    if idleMs < inactivityThresholdMs: continue                   // :57  not idle enough
    thread = projectionSnapshotQuery.getThreadShellById(binding.threadId)
    if thread?.session?.activeTurnId != null:                     // :64  NEVER reap mid-turn
        log "skipped-active-turn"; continue
    providerService.stopSession({threadId})                       // :73  reap
    log "reaped" reason="inactivity_threshold"
```

[fact] **It reaps only when BOTH stale (idle ≥ 30 min) AND no active turn** (`:57` and
`:64`). The active-turn check reads the *projection* (`getThreadShellById`, `:61`) — the
reaper consults the derived read-model to protect live work. **There is no
disconnect-driven reaping anywhere**: I searched `ws.ts` for `disconnect`/`onClose`→
`stopSession` and found none. A client dropping its socket does not kill the agent; only
wall-clock idleness + no active turn does. [judgment] This is exactly Continuum's need —
"observe from iOS" must not reap the agent when the phone locks.

### 3.3 Multiplexing — one session per thread, unbounded threads

[fact] `provider_session_runtime.thread_id` is the PRIMARY KEY (`004:9`) → **at most one
provider session per thread**. There is no cap on the number of threads; each is an
independent row / aggregate stream. Routing is always `threadId → binding → adapter`
(`resolveRoutableSession`, `ProviderService.ts:445`). [judgment] Maps cleanly to
Continuum: one managed agent session per tile (or per thread-of-work), arbitrarily many
tiles.

---

## 4. Continuum sketch — the pattern, in Swift

This section is the payload for the implementing agent: the t3code shapes re-cast for
Continuum, wired to the seams `docs/38` already names (`ActivityStore`/`ActivityProjection`,
`TerminalSessionDescriptor`, `ZoneRuntimeController`). **All Swift below is illustrative
[judgment] — it does not exist in the repo yet.** Continuum's real types it leans on are
[fact]-cited.

### 4.1 `ActivityProjection` — append-only agent events → one-way activity tree

[fact] Continuum already has the *consumer*: `SidebarTreeBuilder.build(…,
agentStatusesByTileId:)` (`SidebarTree.swift:134`) and `AgentStatus`
(`TerminalSessionDescriptor.swift:85`, values `configuring/working/idle/needsAttention/
done/stale`). What's missing is a *source* that behaves like t3code's projection: an
append-only agent-event log folded into a materialized tree and **pushed** to observers.

[judgment] The Continuum analogue of `orchestration_events` (activity slice only) +
`projectEvent` + `streamDomainEvents`:

```swift
// The domain event — the analogue of OrchestrationThreadActivity + thread.activity-appended.
// This is the ONLY thing that crosses to an observer (iOS). Metadata only — I5 (docs/38:290).
struct AgentActivityEvent: Codable, Sendable {
    let sequence: UInt64            // global monotonic, like orchestration_events.sequence
    let tileId: UUID                // aggregate id  (t3code: stream_id)
    let runId: String?              // exact link to the agent's own store (Pi/Claude), if known
    let tone: Tone                  // info | tool | approval | error   (t3code tones, :305)
    let kind: String                // "turn.started", "tool.bash", "needs-attention", …
    let status: AgentStatus         // the DERIVED status (drives the existing UI field)
    let summary: String             // short, human — NEVER a transcript body (I5)
    let occurredAt: Date
}

// The materialized read model — the analogue of OrchestrationReadModel.threads.
// Rebuildable from the event log; a cache, not the source of truth.
struct ActivityTreeSnapshot: Codable, Sendable, Equatable {
    var snapshotSequence: UInt64
    var byTile: [UUID: TileActivity]          // keyed set, like projection_threads
}
struct TileActivity: Codable, Sendable, Equatable {
    var status: AgentStatus
    var lastSummary: String
    var recent: [AgentActivityEvent]          // capped ring, like MAX_THREAD_MESSAGES
    var updatedAt: Date
}

// The PURE fold — the analogue of projector.ts:projectEvent. Live AND replay use it.
func apply(_ tree: ActivityTreeSnapshot, _ e: AgentActivityEvent) -> ActivityTreeSnapshot {
    var next = tree
    next.snapshotSequence = e.sequence
    var t = next.byTile[e.tileId] ?? TileActivity(status: .idle, lastSummary: "",
                                                  recent: [], updatedAt: e.occurredAt)
    t.status = e.status
    t.lastSummary = e.summary
    t.recent = Array((t.recent + [e]).suffix(200))
    t.updatedAt = e.occurredAt
    next.byTile[e.tileId] = t
    return next
}

// The store + one-way push — the analogue of OrchestrationEventStore + PubSub.
actor ActivityStore {
    private var log: [AgentActivityEvent] = []      // append-only (persist as NDJSON/SQLite)
    private var tree = ActivityTreeSnapshot(snapshotSequence: 0, byTile: [:])
    private var observers: [UUID: AsyncStream<ActivityStreamItem>.Continuation] = [:]

    func append(_ e: AgentActivityEvent) {
        log.append(e); tree = apply(tree, e)         // fold forward
        for c in observers.values { c.yield(.event(e)) }   // fan-out, one-way
    }
    // snapshot-then-tail — the analogue of ws.ts subscribeShell (:1086)
    func subscribe() -> AsyncStream<ActivityStreamItem> {
        AsyncStream { cont in
            cont.yield(.snapshot(tree))              // current materialized tree first
            let id = UUID(); observers[id] = cont     // then the live tail
            cont.onTermination = { _ in Task { await self.removeObserver(id) } }
        }
    }
    // reconcile a lagging observer, like reconcileReadModelAfterDispatchFailure (:113)
    func replay(fromSequenceExclusive s: UInt64) -> [AgentActivityEvent] {
        log.filter { $0.sequence > s }
    }
}
enum ActivityStreamItem: Sendable { case snapshot(ActivityTreeSnapshot); case event(AgentActivityEvent) }
```

[judgment] The `SessionObserver` (`docs/38:298`) is the analogue of
`ProviderRuntimeIngestion`: it watches each agent's own store (Claude `sessions/<pid>.json`,
Pi `status.json` — `docs/38:258–260`) and calls `ActivityStore.append(…)`. The Mac renders
the tree; iOS `subscribe()`s and renders the *same* snapshot+tail. **iOS is a read-only
observer of a projection — it never writes activity.** That is Decision E's activity half,
built.

### 4.2 `ManagedAgentSessionRecord` — the analogue of `provider_session_runtime`

[fact] Continuum already separates identity: `TerminalSessionDescriptor.id ≠ .tileId`
(`docs/38:99`), a tile *points at* a runtime via `Tile.runtimeRef`
(`CanvasState.swift:45`), and host-local data (`command/args/cwd/env/scrollback`) lives in
`sessions/<id>.json` **outside** the synced canvas (`SYNC-MODEL.md:103–107`). So Continuum
is already on the right side of the private/synced line. What t3code adds is an explicit
**resume record** with an opaque cursor:

```swift
// The analogue of provider_session_runtime — PRIVATE, host-local, never synced, never projected.
struct ManagedAgentSessionRecord: Codable, Sendable {
    let tileId: UUID                     // PK — one managed session per tile (t3code: thread_id)
    var agentKind: AgentKind             // shell | claude | codex | pi   (docs/38:313)
    var status: RuntimeStatus            // starting | running | stopped | error (narrow, like t3code :1152)
    var lastSeenAt: Date                 // bumped on every interaction → drives the reaper
    var resumeCursor: Data?              // OPAQUE — e.g. Claude sessionId, Pi runId, codex rollout path
    var runtimePayload: Data?            // OPAQUE — {cwd, modelSelection, tmuxWindowTarget %pane_id, …}
}
```

[judgment] `resumeCursor` for Continuum is the *exact link* the AGENT-READERS spike already
found (`docs/38:258–260`): Claude's `sessionId` (from `sessions/<pid>.json`), Pi's `runId`
(run-dir basename), Codex's rollout path. `runtimePayload` is where the make-or-break
`tmuxWindowTarget` (`%pane_id`) from the TOPOLOGY spike (`docs/38:184`) belongs — captured at
spawn, opaque to the sync layer, used only on local re-bind. **`AgentDescriptor.runId`
already exists** (`TerminalSessionDescriptor.swift:94`) as a partial version of this.

### 4.3 Lazy-resume-on-focus — recover when the tile is interacted with

[judgment] t3code resumes on the next *operation*; Continuum's natural trigger is **tile
focus / first keystroke / re-bind after relaunch** — not app launch. The
`ZoneRuntimeController` (`ZoneRuntimeController.swift:6`, per-project, ref-counted) is the
host, mirroring t3code's `ProviderService`:

```swift
// In ZoneRuntimeController — analogue of resolveRoutableSession + recoverSessionForThread.
func routableSession(forTile tileId: UUID, allowRecovery: Bool) async throws -> LiveSession {
    guard let record = store.record(forTile: tileId) else {
        throw SessionError.noBinding                 // never spawned; caller must create fresh
    }
    if let live = liveSessions[tileId] { return live }        // Branch 1: adopt-existing
    guard allowRecovery else { return .inactive(record) }
    return try await recover(record)                          // lazy resume
}

func recover(_ r: ManagedAgentSessionRecord) async throws -> LiveSession {
    // Branch 1 already handled above (session live in memory / tmux window still alive).
    // Branch 2: no cursor → honest failure, do NOT fabricate.
    guard let cursor = r.resumeCursor else { throw SessionError.noResumeState }
    // Branch 3: resume-from-cursor. Re-bind the tmux window (runtimePayload.tmuxWindowTarget)
    // or replay the agent-specific cursor; the reader, not the core, interprets it.
    let live = try await adapter(for: r.agentKind).resume(tileId: r.tileId, cursor: cursor,
                                                          payload: r.runtimePayload)
    store.upsert(r.with(lastSeenAt: .now))            // refresh; persist any new cursor
    return live
}
```

[judgment] And the reaper, one-to-one with t3code: a timer in `ZoneRuntimeController` (say
30-min idle / 5-min sweep, **both user-configurable per Dylan's config-first doctrine**),
reaping a session only when `now - lastSeenAt ≥ threshold` **and** the `ActivityTreeSnapshot`
shows no in-flight turn for that tile — and **never** on a client/iOS disconnect. Continuum's
extra nuance from the TOPOLOGY spike: reaping ≠ killing the tmux session; "project release =
DETACH, never kill" (`docs/38:204`). So the Continuum reaper detaches/forgets the *managed
record*, leaving the tmux window alive for later re-adoption.

---

## 5. What Continuum steals — mapped to Decision E

Ranked by leverage. Each names the Continuum seam.

**S1 — Split sync (bidirectional op-log) from observation (one-way projection).** *This is
the headline.* t3code treats *all* state as event-sourced projections; Continuum should
adopt the projection pattern **only for the activity/agent layer**, and keep the op-log
(`SYNC-MODEL.md`) for the spatial layer. Concretely:
- **Spatial** (`CanvasState`, `WorkspaceDocument`) → **op-log, bidirectional** — because
  two devices genuinely *co-edit* positions/membership; convergence must be a theorem (I4).
- **Activity tree + agent/session status** → **projection, one-way** — because it is
  *derived from what the agent actually did*; a device *observes* it, never authors it.
  Build `ActivityStore`/`ActivityProjection` (§4.1) as snapshot-then-tail, exactly like
  `ws.ts subscribeShell`. This directly implements `docs/38:421–423` ("the activity tree
  syncs as a derived projection … cross-platform agreement is snapshot equality").
- **Enforce the boundary with a type**, à la t3code's `Client` vs `Internal` command split
  (§1.6): the activity `append` API is server/observer-internal; the sync `Op` enum
  (`SYNC-MODEL.md:299`) carries only spatial ops. A device cannot inject activity, and the
  op-log cannot carry a runtime handle (I5 becomes type-level, `SYNC-MODEL.md:392–398`).

**S2 — Two stores: private runtime record vs projected read-model.** Steal the
`provider_session_runtime` ↔ `projection_thread_sessions` separation (§2.3). Continuum gets
a **private, host-local `ManagedAgentSessionRecord`** (§4.2, PK `tileId`, opaque
`resumeCursor` + `runtimePayload`) that **never syncs and never projects**, and a separate
**derived, observable** `AgentStatus`/activity view that does project one-way. This is the
physical realization of Decision E's "sync layer 1 only; a second device re-binds locally"
(`docs/38:349–351`). The `tmuxWindowTarget` (`%pane_id`) belongs in `runtimePayload`.

**S3 — Lazy resume on focus, never eager at boot; timer reaper, never on disconnect.**
Steal `recoverSessionForThread`'s three branches (§3.1) and the reaper's dual gate (§3.2)
verbatim into `ZoneRuntimeController`: adopt-existing → resume-from-opaque-cursor →
fail-honestly; reap only when stale **and** no active turn; disconnect never reaps. This
makes "observe from iOS" safe by construction — the phone locking, or a stale socket, can
never reap a working agent.

**S4 — Pure fold reused for live + replay; checkpoint the projector.** Steal the discipline
that `projectEvent` is a pure `(model, event) → model` used both to advance live and to
replay-reconcile (§1.3–1.4), plus the `projection_state` per-projector checkpoint applied
*in the same transaction as the write* (§2.1, `ProjectionPipeline.ts:1510`). Continuum's
`apply(tree, event)` (§4.1) must be that pure fold, and the activity log must carry a
global `sequence` so a lagging iOS observer reconciles by `replay(fromSequenceExclusive:)`
— the analogue of `readFromSequence`. This is also how the I4 fuzz's "byte-identical from
any replay order" (`SYNC-MODEL.md:506`) becomes testable for the activity side: snapshot
equality after replay.

**S5 — (consider) event-source the activity stream itself.** t3code's activity feed is
literally an append-only, tone-tagged event log (`thread.activity-appended`, §2.2).
Continuum's activity tree could be *derived from* an `AgentActivityEvent` log rather than
recomputed each poll — giving free history, free replay, and a natural iOS payload. This is
lighter than event-sourcing the *spatial* layer (which stays op-log). [judgment] Worth it;
it's a small log with a pure fold, not a CRDT.

---

## 6. What does NOT transfer

**N1 — Do not event-source the spatial layer.** t3code event-sources *everything*; for
Continuum's canvas that is heavier than needed and *wrong-shaped*. The spatial state is a
small keyed-set of structs, co-edited by ≤ a few devices, where the hard cases (move-vs-
delete, reorder, membership) dissolve under the op-log's re-modeling
(`SYNC-MODEL.md:283–398`). Full event-sourcing there buys history Continuum doesn't need
and a heavier merge story. **Op-log for spatial, projection for activity — do not
cross-apply.** [judgment]

**N2 — Do not centralize on a server.** t3code is client→server: one authoritative
`OrchestrationEngine` owns the single command queue, the single event log, and fans
projections out. Continuum is **offline-first, native, peer-ish**: the Mac is authoritative
for its *own* agents' activity, but the *spatial* state must converge P2P/CloudKit with no
central authority (`SYNC-MODEL.md:576–594`). So the "single serialized command queue"
(`OrchestrationEngine.ts:90`) transfers only *locally* — as the per-host ordering of one
device's own activity events — **not** as a global write authority. Two Macs each project
their own agents; neither is "the server". [judgment]

**N3 — The Effect/DI/SQL machinery is not the lesson.** t3code's `Effect.gen`, `Layer`,
`SqlSchema`, `PubSub` are TS-ecosystem plumbing. Continuum's equivalents are `actor` +
`AsyncStream` (§4.1) and its existing `Codable` + `AtomicWriter` (`ProjectStore.swift:78`).
Copy the *shapes* (append-only log, pure fold, snapshot+tail, checkpoint, opaque cursor,
two stores), not the framework. [judgment]

**N4 — Full multi-provider adapter richness is agent #3's turf, not this doc's.** t3code
carries a large adapter matrix (`provider/Layers/*Adapter.ts`, Claude/Codex/Cursor/Grok/
OpenCode). The *session-lifecycle* seam is what transfers here; the adapter/protocol layer
is out of scope (owned by agent #3, per the boundary). Continuum's `AgentStateReader`
protocol (`docs/38:270`) is the seam that meets it. [fact — boundary per prompt]

**N5 — Nested in-memory read model vs flat SQL projections.** t3code keeps *both* a nested
`OrchestrationReadModel` (in-memory, for the decider) and *flat* `projection_*` SQL tables
(for queries). Continuum's activity tree is small enough that the **in-memory
`ActivityTreeSnapshot` alone likely suffices** (persisted as one blob or a small NDJSON
log); the flat-table projection layer is probably over-engineering at Continuum's scale.
Adopt the *concept* (materialized read model), skip the dual-representation. [judgment]

---

## 7. Open questions / forks

1. **Persistence of the activity log.** t3code uses SQLite with WAL
   (`Sqlite.ts:36`). Continuum's core is dependency-free JSON today (`SYNC-MODEL.md:269`).
   Fork: append-only **NDJSON** activity log (in-grain with `AtomicWriter`, zero new dep)
   vs a small SQLite file (indexed queries, but a new dependency). [judgment] NDJSON +
   in-memory fold first; SQLite only if history queries demand it.

2. **Where does the activity `sequence` come from across devices?** t3code's global
   autoincrement assumes one authority. If two Macs each project their own agents, is the
   activity `sequence` per-device (namespaced by a `replicaId`, like the op-log's OpId,
   `SYNC-MODEL.md:294`) or global? [inferred] per-device + `(sequence, replicaId)` tie-break,
   reusing the op-log's Lamport discipline, since activity is per-host anyway.

3. **Compaction / retention of the activity log.** t3code caps in-memory
   (`MAX_THREAD_MESSAGES = 2000`, `projector.ts:32`) and has `minLastAppliedSequence` as a
   GC horizon (`ProjectionState.ts:99`). Continuum needs a retention policy for
   `AgentActivityEvent` (ring buffer? per-tile cap? time window?) — mirrors the op-log's
   own compaction open question (`SYNC-MODEL.md:388`, `:603`).

4. **Does the derived `AgentStatus` need its own event, or is it a field on each activity
   event?** t3code separates `thread.session-set` (session status) from
   `thread.activity-appended` (feed items). Continuum could fold status into each activity
   event (§4.1, simpler) or emit a distinct status-change event (cleaner history). [judgment]
   fold-into-activity first; split only if status history is independently valuable.

5. **Reaper thresholds + config surface.** Per Dylan's config-first doctrine, the 30-min /
   5-min constants (`ProviderSessionReaper.ts:16–17`) must be **user-configurable with a
   persisted default + a Settings entry** — not hardcoded. Open: are they global or
   per-project/per-agent-kind? [judgment] global default, per-project override.

6. **`needsAttention` honesty vs the projection.** `docs/38:319–321` says Claude
   `needsAttention` is hook-only in bypass mode; an activity event carrying a fabricated
   `needsAttention` status would poison the projection. Fork: gate `needsAttention` events
   behind the hook signal, emit `working`/`idle` otherwise (I6 soundness,
   `docs/38:421`). [fact — the constraint; judgment — the gating.]

7. **Should the op-log store seam and the activity store seam be the *same* protocol?**
   `SYNC-MODEL.md:494` proposes hiding the op-log behind the Decision-E store protocol.
   Open: is `ActivityStore` a *third* seam, or does the transport (CloudKit/relay) carry
   both op-log ops and activity stream items over one channel with two logical topics?
   [inferred] one transport, two topics (spatial-ops, activity-events); one `SyncTransport`
   fake tests both (`docs/38:410`, `:459`).

---

## 8. Provenance (files read in t3code, 2026-06-30)

- `packages/contracts/src/orchestration.ts` — `OrchestrationSession:271`,
  `OrchestrationSessionStatus:260`, `OrchestrationThreadActivity:305`,
  `OrchestrationThread:344`, `OrchestrationReadModel:370`, `EventBaseFields:989`,
  `OrchestrationEvent` union `:1001–1113`, `OrchestrationThreadStreamItem:1115`,
  `Client`/`Internal`/`OrchestrationCommand` unions `:660–781`,
  `ProviderSessionRuntimeStatus:1152`, `ThreadActivityAppendedPayload:975`.
- `apps/server/src/orchestration/decider.ts` — `decideOrchestrationCommand:96`,
  `decideCommandSequence:62`, `thread.turn.start` two-event arm `:389–461`,
  `project.delete` decomposition `:163–212`.
- `apps/server/src/orchestration/projector.ts` — `createEmptyReadModel:181`,
  `projectEvent:190`, `thread.created:266`, `thread.session-set:444`,
  `thread.activity-appended:665`, caps `:32–33`.
- `apps/server/src/orchestration/Layers/OrchestrationEngine.ts` — in-mem model `:88`,
  seed from snapshot `:301`, command queue `:90,303`, idempotency `:138`, decide `:153`,
  txn append+project `:169–199`, reconcile-replay `:113–126`, PubSub fan-out `:91,217,329`.
- `apps/server/src/orchestration/Layers/ProjectionPipeline.ts` — `runProjectorForEvent`
  (apply+checkpoint in one txn) `:1501–1532`, `bootstrapProjector` (replay from checkpoint)
  `:1534–1548`, projector list `:1460–1499`.
- `apps/server/src/persistence/Layers/OrchestrationEventStore.ts` — INSERT (dual ordering)
  `:106–157`, `stream_version` COALESCE `:125–135`, `inferActorKind:70`,
  `readFromSequence` (cursor paging) `:211–261`.
- `apps/server/src/persistence/Layers/ProjectionState.ts` — checkpoint upsert `:24–43`,
  `minLastAppliedSequence:99`.
- `apps/server/src/persistence/ProviderSessionRuntime.ts` — typed record (opaque
  cursor/payload) `:33–50`, upsert SQL `:151–184`.
- `apps/server/src/provider/Layers/ProviderSessionDirectory.ts` — `upsert` (bump
  last_seen, merge payload) `:103–149`, `getBinding:89`, `listBindings:173`.
- `apps/server/src/provider/Layers/ProviderService.ts` — `recoverSessionForThread` (3
  branches) `:355–438`, `resolveRoutableSession` `:440–485`, recovery call sites `:671,
  729,766,805,838,983`.
- `apps/server/src/provider/Layers/ProviderSessionReaper.ts` — thresholds `:16–17`, sweep
  (idle+active-turn gate) `:36–104`, timer start `:106–128`.
- `apps/server/src/persistence/Migrations/001_OrchestrationEvents.ts` (event log DDL),
  `004_ProviderSessionRuntime.ts` (private record DDL), `005_Projections.ts` (read-model
  DDL incl. `projection_state:106`).
- `apps/server/src/ws.ts` — read scopes `:282–284`, `subscribeShell` snapshot+tail
  `:1062–1090`.
- `apps/server/src/serverRuntimeStartup.ts` — reaper/reactor start `:344–345` (no eager
  session recovery).
- `apps/server/src/orchestration/Layers/ProviderRuntimeIngestion.ts` — `thread.session.set`
  internal dispatch `:1341,1591`.

**Continuum files referenced** (verified via `docs/38` and `SYNC-MODEL.md` citations, not
re-read here): `TerminalSessionDescriptor.swift:85,94`, `CanvasState.swift:45`,
`SidebarTree.swift:134`, `ZoneRuntimeController.swift:6`, `ProjectStore.swift:78`.
