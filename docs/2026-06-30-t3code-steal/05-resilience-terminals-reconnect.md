# t3code steal — 05: Reconnect resilience + terminal attach/detach/scrollback

**For a future implementing agent.** Read alongside `docs/38-agent-orchestration-architecture.md`
(Decision A = session topology/tmux; Decision D = remote; invariants **I1** binding
bijection, **I8** restart survival). This doc mines **pingdotgg/t3code** for its
client-reconnect state machine and its server-owned terminal-session model, and maps
them onto Continuum's iOS observer + remote-attach control paths.

Clone read at
`…/scratchpad/t3code` (read-only). All `file:line` below are into that clone unless the
path starts with `Sources/` or `docs/` (those are Continuum). **Verified** = I read the
code; **Inferred** = reasoned from surrounding code, called out inline.

---

## 0. TL;DR — the one-paragraph shape

t3code is a **server-owns-the-pty** design. A Node server holds `node-pty` sessions in an
in-memory `Map` keyed by `(threadId, terminalId)`, persists each session's scrollback to a
debounced `.log` file on disk, and exposes attach/write/resize/close/subscribe as RPCs over
**one WebSocket** per environment. The pty's lifetime is the **server's**, not any client
socket's: a client disconnect only drops a *listener*; the pty keeps running and is reaped
only when idle (evicted past a cap) or explicitly closed. The **client** is a thin observer:
an `EnvironmentSupervisor` runs a retry-forever/exponential-backoff state machine that only
declares `connected` after the socket opens **and** an initial config RPC returns; every
durable subscription is a `Stream.switchMap` over the supervisor's current session, so on
reconnect it silently re-subscribes to the *replacement* session; snapshots are cached to
disk so the UI renders while offline; sequence/version guards stop a stale cache from
clobbering fresher live data.

**Continuum gets the same "survives client teardown" property a different way** — tmux owns
the session, ghostty attaches natively, no bytes stream to the Mac. So we **steal the client
supervisor for the iOS observer and remote-attach control**, not for the local ghostty path.
And we steal t3's **"reattach by stable id + replay persisted scrollback"** contract as the
spec our tmux `tmuxWindowTarget` seam (Decision A) must satisfy to make I1/I8 provable.

---

## 1. What t3code does (grounded)

### 1a. The client reconnect state machine — `EnvironmentSupervisor`

**File:** `packages/client-runtime/src/connection/supervisor.ts` (Verified). Companion prose:
`docs/architecture/connection-runtime.md` (Verified).

**Backoff table (capped ~16s), retry forever.** `supervisor.ts:32-35`:

```ts
const RETRY_DELAYS_MS = [1_000, 2_000, 4_000, 8_000, 16_000] as const;
const CONNECTION_ESTABLISHMENT_TIMEOUT = "15 seconds";
const CONNECTION_PROBE_TIMEOUT = "15 seconds";
const BACKOFF_RESET_AFTER_MS = 30_000;
// …
function retryDelayMs(failureCount: number): number {
  return RETRY_DELAYS_MS[Math.min(failureCount, RETRY_DELAYS_MS.length - 1)] ?? 16_000;  // :102
}
```

The `run()` loop (`:587-668`) is the heart. It reads a `SupervisorIntent { desired, network }`
each turn and:

- if `!desired` → `available` state, clear the lease, park on `waitForSignal`;
- if `network === "offline"` → `offline` state, clear the lease, park — **without consuming a
  retry attempt** (`:604-609`);
- else run one attempt; on failure, `failureCount += 1`, compute `delayMs =
  retryDelayMs(failureCount-1)`, set `backoff` state with a `retryAt` timestamp, and
  `waitForRetrySignal(delayMs)` (`:647-666`). No max attempts — it loops forever.
- **`ConnectionBlockedError`** (auth/permission/config) → `blocked` state and park on
  `waitForSignal` — it does **not** retry on a timer; only an external wakeup (credential
  change, user retry) unblocks it (`:631-645`).
- **Backoff reset:** a connection that stayed up ≥ `BACKOFF_RESET_AFTER_MS` (30s) is marked
  `stable`, which resets `failureCount` to 0 (`:562-563`, consumed at `:616-623`). A flapping
  link keeps climbing the backoff table; a genuinely-recovered one starts fresh.

**The "connected only after socket-open AND initial config RPC" gate.** This is the load-
bearing correctness rule (prose: `connection-runtime.md:50-56`). The session's `ready` effect
is defined in `packages/client-runtime/src/rpc/session.ts:128-138` (Verified):

```ts
return {
  client,
  initialConfig,
  ready: Deferred.await(connected).pipe(   // socket open (onConnect hook)
    Effect.andThen(initialConfig),          // …AND serverGetConfig RPC returns
    Effect.asVoid,
    Effect.raceFirst(Deferred.await(disconnected)),
  ),
  probe,                                     // re-runs serverGetConfig on demand
  closed: Deferred.await(disconnected),      // fires on WS onDisconnect
} satisfies RpcSession;
```

- `connected` resolves from the RpcClient `onConnect` hook; `disconnected` from `onDisconnect`
  (`session.ts:75-93`).
- `initialConfig` is `Effect.cached(client[serverGetConfig]({}))` (`:116-121`) — **the config
  snapshot is memoized**, so it's the offline-surviving bootstrap config too (consumed by the
  `initialConfigAtom`, see 1c).
- Only after `runAttempt` sees the lease *and* re-checks intent does it flip state to
  `phase: "connected"` (`supervisor.ts:530-542`). A socket that opens but whose server never
  answers `serverGetConfig` is **not** connected — it times out
  (`CONNECTION_ESTABLISHMENT_TIMEOUT`, `:475`) and becomes a retry.

**Interrupts (wake the wait, start a fresh attempt).** `run()` blocks on a `Queue` of
`SupervisorSignal`s (`:42-47`): `ConnectRequested`, `DisconnectRequested`, `RetryRequested`,
`NetworkChanged`, `Wakeup`. They're fed by:
- connectivity change stream → `NetworkChanged` (`:670-681`),
- lifecycle/credential wakeups → `Wakeup` (`:682-685`),
- `connect`/`disconnect`/`retryNow` public effects (`:688-706`).

While *connected*, `monitorConnectedLease` (`:386-454`) also races an
`application-active` wakeup that fires a **health `probe`** (re-runs `serverGetConfig`, 15s
timeout) — if the probe fails, the lease is torn down and the loop reconnects. This is the
"is the server still there after the phone woke up?" check.

**Involuntary close → keep registration + cache, reconnect.** While connected, `runAttempt`
races the lease's `closed` against `monitorConnectedLease` (`:544-561`). If the socket drops,
`closed` fires (a `ConnectionTransientError`), the attempt returns a failure with
`established: true`, and the loop goes to backoff and retries — the environment registration
and the cached snapshots are untouched (`connection-runtime.md:45`).

**State exposed to the UI** — `SupervisorConnectionState` (`connection/model.ts:135-144`,
Verified): `{ desired, network, phase, stage, attempt, generation, lastFailure, retryAt }`.
`phase ∈ available|offline|connecting|backoff|connected|blocked`. The UI projects these to
`disconnected|synchronizing|ready` (`model.ts:146-162`). **`generation`** is an integer
bumped on every successful (re)connection (`supervisor.ts:611-623`) — the reconnect
epoch. It is *not* a timestamp; it's the key everything downstream keys off.

### 1b. The durable subscription that switches to the replacement session

**File:** `packages/client-runtime/src/rpc/client.ts:150-237` (Verified). This is the single
most stealable pattern.

```ts
export function subscribe<TTag extends EnvironmentSubscriptionRpcTag>(tag, input, options?) {
  return Stream.unwrap(
    EnvironmentSupervisor.pipe(Effect.map((supervisor) =>
      SubscriptionRef.changes(supervisor.session).pipe(   // ← current RpcSession, changes on reconnect
        Stream.switchMap(Option.match({
          onNone: () => Stream.empty,                       // offline → nothing
          onSome: (session) => {
            const method = session.client[tag];             // e.g. terminalAttach on THIS session
            const subscribeToSession = () => Stream.suspend(() =>
              method(input).pipe(Stream.catchCause((cause) => {
                const isTransportFailure = /* all failures are RpcClientError */;
                if (isTransportFailure) {
                  return Stream.fromEffect(Effect.logWarning(
                    "Durable RPC subscription lost its transport; waiting for the next session.",
                  )).pipe(Stream.drain);                    // ← drain, let switchMap re-fire on next session
                }
                if (hasOnlyExpectedFailures && options?.onExpectedFailure) {
                  // domain (not transport) failure → notify + optional timed resubscribe
                  return handled.pipe(Stream.concat(sleep(retryAfter)), Stream.concat(subscribeToSession()));
                }
                return Stream.failCause(cause);
              })));
            return subscribeToSession();
          },
        })),
      ),
    )),
  );
}
```

How it delivers "subscription atoms switch to replacement sessions"
(`connection-runtime.md:60-71`):
- `SubscriptionRef.changes(supervisor.session)` emits the new `RpcSession` each reconnect;
  `Stream.switchMap` **interrupts the old inner stream and starts a fresh one on the new
  session's client** — the subscription re-establishes with zero call-site awareness.
- A **transport** failure (socket died) doesn't error the outer stream — it drains and waits
  for the next session emission (the supervisor is already reconnecting). A **domain** failure
  (e.g. the server rejected this thread) is handled separately and optionally retried on a
  timer, "they do not take down a healthy transport" (`connection-runtime.md:62-63`).

**Terminal use of it** — `packages/client-runtime/src/state/terminal.ts:40-46` (Verified):

```ts
attach: createEnvironmentSubscriptionAtomFamily(runtime, {
  label: "environment-data:terminal:attach",
  subscribe: (input) =>
    subscribe(WS_METHODS.terminalAttach, input).pipe(               // ← the durable subscribe above
      Stream.scan(EMPTY_TERMINAL_BUFFER_STATE, applyTerminalAttachStreamEvent),  // fold events → buffer
    ),
}),
```

So a terminal view is `terminalAttach` folded through `applyTerminalAttachStreamEvent`
(client-side reducer, see 1e). On reconnect the whole thing re-subscribes; the server replies
with a fresh `snapshot` (full scrollback) and live output resumes.

### 1c. Offline snapshot survival + generation-keyed revalidation

(Located by a sub-search; `file:line` reported, spot-verified against the imports/exports.)

- **Cache store:** platform-provided `EnvironmentCacheStore`
  (`packages/client-runtime/src/connection/persistence.ts:50-76` — interface with
  `loadShell/saveShell/loadThread/saveThread`). Shell state hydrates from it at startup and
  writes back debounced 500ms (`state/shell.ts:48-89`), threads likewise
  (`state/threads.ts:51-97`). So `phase === "offline"` still renders the last-known shell/
  thread snapshot (`connection-runtime.md:64`: "Shell and thread snapshots are available
  while offline").
- **Bootstrap config survives** because `initialConfig` is `Effect.cached` (session.ts) and is
  read via `initialConfigAtom`, which itself is a `SubscriptionRef.changes(supervisor.session)`
  map (`state/session.ts:31-52`, Verified).
- **Generation-keyed query revalidation** (`state/runtime.ts:447-502`): a `rpcGenerationAtom`
  filters `supervisor.state` to `phase === "connected"` and emits `state.generation` through
  `Stream.changes`; query atoms depend on it, so a new generation re-runs finite queries. When
  offline the generation atom is `null` and the query `Effect.never`-suspends (doesn't error).
- **Cache-vs-live ordering guard** — the rule "cached projections never overwrite newer live
  data during a fast reconnect" (`connection-runtime.md:70-71`): shell/thread reducers compare
  a monotonic `snapshotSequence` and **drop** any event whose `sequence <= last seen`
  (`state/shell.ts:124-148`, `state/threads.ts:154-182`). Terminal uses a `version` counter
  that only ever increments (`state/terminalSession.ts`, see 1e).

### 1d. The server-side terminal model — `node-pty`, keyed sessions, disk scrollback

**File:** `apps/server/src/terminal/Manager.ts` (2624 lines, Verified in full).

**Session identity = `(threadId, terminalId)`.** `Manager.ts:1053-1055`:

```ts
function toSessionKey(threadId: string, terminalId: string): string {
  return `${threadId} ${terminalId}`;   // NUL-joined composite key
}
```

Sessions live in an in-memory `Map<string, TerminalSessionState>` inside a
`SynchronizedRef` (`:288-291`, `:1162-1165`). `TerminalSessionState` (`:232-257`) carries the
`node-pty` handle (`process`), `pid`, the full `history` string, `status`
(`starting|running|exited|error`), `cols/rows`, a monotonic `eventSequence`, and the two pty
`unsubscribe` callbacks. **Terminal ids are client-chosen and sent explicitly** — no
server-side allocation (`contracts/src/terminal.ts:32`, `DEFAULT_TERMINAL_ID = "term-1"`).

**Persisted scrollback on disk, debounced.** History path (`:1178-1184`):

```ts
const historyPath = (threadId, terminalId) => {
  const threadPart = toSafeThreadId(threadId);                        // "terminal_" + base64url(threadId)
  if (terminalId === DEFAULT_TERMINAL_ID) return path.join(logsDir, `${threadPart}.log`);
  return path.join(logsDir, `${threadPart}_${toSafeTerminalId(terminalId)}.log`);  // base64url(terminalId)
};
```

so scrollback lives at `{logsDir}/terminal_<b64url(threadId)>[_<b64url(terminalId)>].log`
(`terminalLogsDir` from server config, `:1116-1126`). Writes go through a **keyed coalescing
worker** debounced `DEFAULT_PERSIST_DEBOUNCE_MS = 40` ms (`:78`, `:1324-1354`); `close` and
context-change do an *immediate* flush (`:1374-1384`). On open, history is read back and
capped to `DEFAULT_HISTORY_LINE_LIMIT = 5000` lines (`:77`, `readHistory` `:1386-1465`, with a
one-time legacy-path migration). Output is sanitized to strip cursor/OSC query sequences
before it's appended to persisted history (`sanitizeTerminalHistoryChunk`, `:931-1039`) — the
persisted history is *display* text, not a raw byte log.

**Open = reuse-or-spawn, restore history on first open.** `openLocked` (`:2099-2220`):
- No existing session → `flushPersist` any pending write, `readHistory` from disk, create the
  state entry, `startSession`, return `snapshot(session)` (`:2105-2158`). **The restored
  `history` is in the snapshot the client renders** — this is scrollback replay.
- Existing session, launch context changed (cwd/env/worktree) or exited → reset history and
  respawn (`:2160-2210`).
- Existing running session → just resize if needed and return the current snapshot (reattach,
  no respawn) (`:2212-2219`).

**Attach = snapshot then live, with a buffer to avoid gaps.** `attachStream` (`:2305-2360`,
Verified) is the reattach contract:

```ts
const attachStream = (input, listener) => Effect.gen(function* () {
  const bufferedEvents: TerminalEvent[] = [];
  let deliverLive = false;
  unsubscribe = yield* subscribe((event) => {            // 1. start listening FIRST (buffer while we snapshot)
    if (event.threadId !== input.threadId || event.terminalId !== input.terminalId) return Effect.void;
    if (!deliverLive) { bufferedEvents.push(event); return Effect.void; }
    const attachEvent = terminalEventToAttachEvent(event);
    return attachEvent ? listener(attachEvent) : Effect.void;
  });
  const initialSnapshot = yield* openOrAttachForStream(input);  // 2. snapshot (opens if needed)
  yield* listener({ type: "snapshot", snapshot: initialSnapshot });  // 3. emit full snapshot (history)
  for (const event of bufferedEvents) {                          // 4. replay buffered, de-duped by sequence
    if (isDuplicateAttachSnapshotEvent(event, initialSnapshot)) continue;
    const attachEvent = terminalEventToAttachEvent(event);
    if (attachEvent) yield* listener(attachEvent);
  }
  deliverLive = true;                                            // 5. switch to live pass-through
  return () => { unsubscribe?.(); unsubscribe = null; };
});
```

The ordering (subscribe → snapshot → replay-buffered → live) guarantees **no output is lost
between the snapshot instant and going live**, and `isDuplicateAttachSnapshotEvent`
(`:392-402`) drops anything already reflected in the snapshot by comparing `sequence`. This
is exactly the gap-free reattach an observer needs after a reconnect.

**Survives client disconnect; reaped only on idle.** Critical finding — **verified by
absence**: `apps/server/src/ws.ts` has **no** disconnect/socket-close handler that kills
terminals (grep for `onDisconnect|socket…close|closeAll` in ws.ts → none). The attach RPC's
teardown only removes the *listener*:

```ts
// ws.ts:1566-1576 — terminalAttach wiring
[WS_METHODS.terminalAttach]: (input) => observeRpcStream(WS_METHODS.terminalAttach,
  Stream.callback((queue) => Effect.acquireRelease(
    terminalManager.attachStream(input, (event) => Queue.offer(queue, event)),
    (unsubscribe) => Effect.sync(unsubscribe),   // ← on stream end: unsubscribe LISTENER only
  )), { "rpc.aggregate": "terminal" }),
```

and `subscribe`'s unsubscribe just does `terminalEventListeners.delete(listener)`
(`Manager.ts:2297-2303`). The pty handle lives in the manager's state `Map`, owned by the
**server process** lifetime. So a pty dies only via:
1. explicit `terminalClose` RPC → `closeSession` → `stopProcess` (SIGTERM, 1s grace, SIGKILL)
   (`:1717-1744`, `:1932-1970`);
2. the process exiting on its own (drain sets `status:"exited"` but **keeps the entry** for
   scrollback/reattach) (`:1650-1713`);
3. **idle eviction** — `evictInactiveSessionsIfNeeded` drops only `status !== "running"`
   sessions beyond `DEFAULT_MAX_RETAINED_INACTIVE_SESSIONS = 128`, oldest-`updatedAt` first
   (`:81`, `:1569-1597`). **Running sessions are never evicted.**
4. server shutdown finalizer kills all ptys (`:2070-2097`).

This is how t3 gets "agent survives the observer leaving": the *server* is the durable host.

### 1e. Client-side terminal reducer (the folded buffer)

**File:** `packages/client-runtime/src/state/terminalSession.ts` (Verified).
`applyTerminalAttachStreamEvent(current, event)` (`:125-173`) folds the attach stream into a
`TerminalBufferState { buffer, status, error, updatedAt, version }`:
- `snapshot` / `restarted` → **replace** buffer from `event.snapshot.history` (trimmed to
  `DEFAULT_MAX_TERMINAL_BUFFER_BYTES = 512 KiB`, UTF-8-boundary-safe, `:65-89`);
- `output` → append `event.data`, `version + 1`;
- `cleared`/`exited`/`closed`/`error` → status transitions, `version + 1`;
- `activity` → unchanged.

The `version` counter is the client's monotonic guard. Note the buffer is **512 KiB on the
client** vs **5000 lines on disk** — the observer holds a bounded tail, the server holds the
canonical scrollback.

### 1f. Streaming + resubscription over the single WS

- **One WebSocket per environment.** The client builds one `RpcClient` over
  `makeProtocolSocket` (`session.ts:97-115`); every RPC (terminal, shell, threads, vcs)
  multiplexes on it. Streaming RPCs (`terminalAttach`, `subscribeTerminalEvents`,
  `subscribeTerminalMetadata`) are ordinary RPC-group streaming methods; on the server they're
  `observeRpcStream(Stream.callback(...))` bridging the manager's callback into an Effect
  `Queue` (`ws.ts:1566-1618`).
- **`retryTransientErrors: false`, `retryPolicy: Schedule.recurs(0)`** on the protocol
  (`session.ts:99-102`) — the transport does **not** retry. Retry is the supervisor's job, and
  only the supervisor's. One retry owner (`connection-runtime.md:32`, "The supervisor is the
  only retry owner").
- **Resubscription = re-issuing the streaming RPC on the new session**, driven entirely by the
  `Stream.switchMap` in 1b. There's no bespoke terminal-reconnect code; terminals inherit
  reconnection from the generic durable-subscribe.

---

## 2. Swift / Continuum sketch

Two distinct consumers, and the boundary between them is the whole point (§4):
**(A)** a `ConnectionSupervisor` for the **iOS observer + remote-attach control channel**
(this is where t3's supervisor transfers almost verbatim), and **(B)** the **local ghostty ↔
tmux** path, which does *not* stream bytes and so borrows only t3's *reattach contract*, not
its transport.

### 2a. `ConnectionSupervisor` for a remote/iOS observer

A direct port of `EnvironmentSupervisor`. Swift Concurrency (`actor` + `AsyncStream`) is the
natural substrate; the shape is 1:1 with §1a.

```swift
enum ConnectionPhase { case available, offline, connecting, backoff, connected, blocked }

struct ConnectionState: Equatable, Sendable {
    var desired: Bool
    var network: NetworkStatus            // unknown | offline | online
    var phase: ConnectionPhase
    var attempt: Int
    var generation: Int                   // reconnect epoch — bumps on each success
    var lastFailure: ConnectionError?
    var retryAt: Date?
}

actor ConnectionSupervisor {
    // The backoff table + gates, copied from t3 (supervisor.ts:32-35).
    private static let retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4),
                                                  .seconds(8), .seconds(16)]
    private static let establishTimeout: Duration = .seconds(15)
    private static let probeTimeout: Duration = .seconds(15)
    private static let backoffResetAfter: Duration = .seconds(30)

    // Observable outputs (SwiftUI reads these; the observer view binds to `session`).
    private(set) var state: ConnectionState
    private(set) var session: RemoteSession?          // the current live session (nil when down)

    private var intent = (desired: false, network: NetworkStatus.unknown)
    private let signals = AsyncStream<Signal>.makeStream()   // Connect/Disconnect/Retry/NetworkChanged/Wakeup

    func run() async {
        var failureCount = 0
        while true {
            if !intent.desired { setAvailable(); await waitForSignal(); continue }
            if intent.network == .offline {
                clearSession(); setOffline(failureCount)      // does NOT consume an attempt
                await waitForSignal(); continue
            }
            let attempt = failureCount + 1
            let outcome = await runAttempt(attempt: attempt, generation: state.generation + 1)
            switch outcome {
            case .connectedThenClosed(let stableForMs):
                state.generation += 1
                if stableForMs >= Self.backoffResetAfter { failureCount = 0 }   // reset if it lasted
                // fall through to backoff (involuntary close → reconnect)
                fallthrough
            case .failed:
                failureCount += 1
                let delay = Self.retryDelays[min(failureCount - 1, Self.retryDelays.count - 1)]
                setBackoff(retryAt: .now + delay)
                await raceFirst(sleep(delay), nextSignal())    // interruptible wait
            case .blocked(let err):
                setBlocked(err); await waitForSignal()         // auth/config: NO timer, external wakeup only
            case .interrupted:
                continue
            }
        }
    }

    // The gate: connected only after socket-open AND initial config RPC returns.
    private func runAttempt(attempt: Int, generation: Int) async -> AttemptOutcome {
        guard let s = try? await driver.openSocket(target, timeout: Self.establishTimeout)
        else { return .failed }
        do {
            _ = try await s.initialConfig()      // ← serverGetConfig-equivalent; cache the result
        } catch let e as BlockedError { return .blocked(e) }
        catch { s.close(); return .failed }

        self.session = s                         // publish → durable subscriptions switch to it (2b)
        state.phase = .connected; state.attempt = attempt
        let connectedAt = ContinuousClock.now
        await raceFirst(s.closed,                // involuntary close
                        monitorProbeOnAppActive(s))  // health probe when app returns to foreground
        clearSession()
        return .connectedThenClosed(stableForMs: ContinuousClock.now - connectedAt)
    }
}
```

Notes that matter:
- **`session` is the switchable handle.** Every observer subscription is "map the current
  session to a byte/event stream; when `session` changes, tear down and re-open" — Swift's
  equivalent of `Stream.switchMap`. With `AsyncStream` you cancel the inner `Task` and start a
  new one when a new session is published (see 2b).
- **`generation`** is the revalidation key for finite fetches (e.g. "list terminals on this
  host"): re-run when it changes; suspend when nil/offline.
- **Cache = local file.** Persist the last observed activity-tree / terminal-summary snapshot
  (Continuum already has `Codable` snapshots) so the phone renders offline; guard writes with
  a `version`/sequence exactly like `terminalSession.ts`.
- **All thresholds must be user-configurable** per the project's TDD/configurable-first
  doctrine — the five backoff steps, the two 15s timeouts, and the 30s reset each get a
  persisted default + a Settings entry, not the hardcoded constants above.

### 2b. Durable observer subscription (the switchMap, in Swift)

```swift
// Re-subscribes automatically across reconnects. `sessions` is an AsyncStream that yields the
// supervisor's current RemoteSession? each time it changes.
func durableTerminalStream(threadId: String, terminalId: String,
                           sessions: AsyncStream<RemoteSession?>) -> AsyncStream<TerminalAttachEvent> {
    AsyncStream { continuation in
        let pump = Task {
            var inner: Task<Void, Never>?
            for await session in sessions {          // ← changes on reconnect
                inner?.cancel()                       // ← switchMap: drop the old subscription
                guard let session else { continue }   // offline → nothing
                inner = Task {
                    do {
                        // Re-issues terminalAttach on the NEW session: server replies with a
                        // fresh snapshot (full scrollback) then live output — gap-free (§1d).
                        for try await ev in session.terminalAttach(threadId, terminalId) {
                            continuation.yield(ev)
                        }
                    } catch is TransportError {
                        // Transport died: do nothing — the supervisor is already reconnecting
                        // and will publish a new session, re-firing this loop.
                    } catch { continuation.yield(.error("\(error)")) }
                }
            }
            inner?.cancel()
        }
        continuation.onTermination = { _ in pump.cancel() }
    }
}
```

The client folds these into a bounded buffer exactly like `applyTerminalAttachStreamEvent`
(replace-on-snapshot, append-on-output, cap to N bytes, bump `version`).

### 2c. Mapping onto Continuum attaching ghostty to a (possibly SSH-forwarded) tmux

The **local** path is different and must stay different (see §4). Ghostty owns a real pty and
renders natively; Continuum never streams bytes to itself. What Continuum attaches to is a
**tmux window**, via the wrap command (Decision A/B). The t3 pieces that transfer here are the
*contract shape* the wrap must satisfy, not the transport:

| t3 concept | Continuum local equivalent (Decision A) |
|---|---|
| `(threadId, terminalId)` session key | `tmuxWindowTarget` (`%pane_id`) on `TerminalSessionDescriptor`, captured **at spawn** (doc `:180-185`) — the stable id |
| server-owned pty `Map` (survives disconnect) | tmux daemon owns the session/window (survives app quit) |
| `attachStream`: snapshot(history)→live | `tmux new-session -t <projSession> -s <viewSession>` + `select-window -t <%pane_id>` — the pane's own scrollback *is* the "snapshot"; ghostty renders it live |
| disk `.log` scrollback (5000 lines, 40ms debounce) | (fallback) `TerminalSessionDescriptor.scrollback` (`Sources/…/TerminalSessionDescriptor.swift:20`), captured at flush by `flushTerminalSessionSnapshot` (`Sources/…/TileSpawner.swift:371-409`) |
| idle eviction of dead sessions | `kill-window` at tile-close; session dies at 0 windows (doc lifecycle table `:199-204`) |

**What Continuum's tmux binding must guarantee to match t3's attach/reattach/scrollback**
(this is the acceptance spec for I1/I8, framed as t3 does it):

1. **Reattach by stable id, not by re-derivation.** t3 keys off `(threadId, terminalId)`; the
   pane it reattaches to is *the same pty*, byte-for-byte, because the server never dropped it.
   Continuum's equivalent must capture `tmuxWindowTarget = %pane_id` **synchronously at spawn**
   and persist it, then on restart bind by that id — **not** by today's implicit
   `new-session -A -s continuum-<tileId>` name-rebind (`Sources/…/TmuxSession.swift:12`), which
   collapses the moment N tiles share one session. This is the doc's explicit make-or-break
   seam (`docs/38 …:180-185`, Risk `:544-545`). Today there is **no production tmux-query
   code** and `listSessions()` reads on-disk descriptors, not `tmux ls`
   (`Sources/…/ProjectStore.swift:157`; restart rebind at `Sources/…/TileSpawner.swift:303`) —
   so the seam is genuinely unbuilt.
   - **I1 (bijection):** exactly one live tmux window per tile, no orphan window, no tile
     pointing at a dead `%pane_id`. t3's analogue: the session Map key is unique and the entry
     is dropped on close.
   - **I8 (restart survival):** after ghostty-client teardown + respawn, `pidBefore ==
     pidAfter`, `targetBefore == targetAfter`, `exitObserved == false`. t3's analogue: the pty
     survives client disconnect trivially because it's server-owned; Continuum must *prove* the
     tmux pane survives — hence the gated real-tmux sentinel check (`docs/38 …:425-431`).

2. **Scrollback replay on reattach must actually reach the surface.** In t3 the `snapshot`
   event *carries* `history` and the client renders it (`terminalSession.ts:131-133`).
   Continuum **persists** scrollback (`flushTerminalSessionSnapshot`) but on-screen replay is
   **explicitly deferred** — the code says so:
   `Sources/…/TileSpawner.swift:354-355` ("Scrollback replay is option (c): persisted to disk
   …, on-screen replay deferred (NEEDS-HUMAN mechanism decision pending)"). With native tmux
   reattach this mostly resolves itself (tmux repaints the pane's own scrollback on attach), so
   the persisted `descriptor.scrollback` is a **fallback** for the case where the tmux session
   is gone (fresh daemon, remote host unreachable) — the direct analogue of t3's disk `.log`
   read when a session must be recreated. Decide and document which of these fires when.

---

## 3. What Continuum steals (mapped to Decisions A / D)

1. **The `ConnectionSupervisor` state machine — for the iOS observer + remote-attach control
   (Decision D + E's iOS client).** Port `EnvironmentSupervisor` beat-for-beat: retry-forever
   with the `[1,2,4,8,16]s` table, the 30s stability reset, `blocked` (auth/config) parks with
   no timer, offline doesn't consume attempts, and — the correctness keystone — **`connected`
   only after socket-open AND an initial config RPC succeeds** (`session.ts:131-135`). This is
   the concrete answer to Decision D's open question "reconnect/backoff when the link drops"
   (`docs/38 …:335-338`) and it is the single retry owner (no per-call retry). Every observer
   subscription is a `switchMap`-over-current-session so reconnection is free (§2b).

2. **The "reattach by stable id + replay persisted scrollback" contract — for Decision A's
   tmux binding.** Adopt t3's attach ordering (subscribe→snapshot→replay-buffered→live,
   de-duped by sequence) as the *spec* for how an observer re-attaches, and adopt its stable-
   key discipline (`(threadId, terminalId)`) as the justification for capturing
   `tmuxWindowTarget` at spawn. Continuum already has the two halves t3 has —
   **tmux-owned scrollback** (native, on reattach) **and a snapshot fallback**
   (`TerminalSessionDescriptor.scrollback`) — but must (a) build the `%pane_id` capture seam so
   reattach is by-id not by-name, and (b) close the deferred on-screen-replay decision. This is
   what turns I1/I8 from prose into a checkable contract.

3. **Sequence/version anti-clobber guards + offline snapshot cache — for E's iOS observer.**
   Steal the monotonic `version`/`snapshotSequence` guard (drop any event `<=` last seen) so a
   cached projection never overwrites fresher live data on a fast reconnect
   (`terminalSession.ts` version; `shell.ts`/`threads.ts` sequence). Steal the "hydrate from a
   local cache at startup, debounce writes back" pattern for the phone rendering the activity
   tree offline. Continuum's snapshots are already `Codable` (`docs/38` §"serializable snapshot
   at every seam"), so this is additive.

4. **The `generation` epoch as the revalidation key.** Bump an integer on each successful
   reconnect; re-run finite fetches when it changes, suspend (don't error) when offline. Cheap,
   and it makes "did we actually reconnect, or just have a stale transport object?" a
   first-class fact — directly supporting the doc's rule that connection health is derived from
   supervisor state, not from "a transport object exists."

---

## 4. What does NOT transfer

1. **Byte-streaming to the renderer.** t3 streams pty **bytes** (`output` events) over the WS
   to a web/RN xterm renderer; the server owns the pty and the client is a dumb screen.
   **Continuum renders ghostty natively, attached to tmux — no bytes stream to the Mac.** So
   the entire `terminalAttach`-`output`-fold-buffer pipeline (`Manager.ts` drain →
   `applyTerminalAttachStreamEvent`) is **not** the local terminal path. It is only relevant to
   an **iOS observer** that wants to *see* a remote terminal without a native ghostty (there,
   you'd stream `capture-pane` output or an equivalent — a new server-side seam, not present
   today).

2. **The supervisor on the local ghostty path.** Locally there is no socket, no reconnect, no
   backoff — ghostty forks a pty for `tmux new-session …` and tmux persistence handles
   survival (Decision A, `docs/34` machinery kept). The `ConnectionSupervisor` applies to the
   **remote-attach control channel** (`ssh://host` in Decision D) and the **iOS link**, not to
   a tile on the same machine.

3. **Server-owned session table as the persistence mechanism.** t3's durability comes from an
   in-process `Map` + disk `.log` because *it has a long-lived server*. Continuum's durability
   comes from **tmux** (an external daemon). We do **not** build a Node-style session manager;
   we make tmux the host and capture the binding (`%pane_id`). t3's `evictInactiveSessions`
   /128-cap logic maps to `kill-window`/session-dies-at-0, not to an LRU in Swift.

4. **Effect-TS machinery.** The `Effect`/`Stream`/`SubscriptionRef`/`Scope` runtime is idiom,
   not architecture. Port the *shape* (state machine, switchMap, cached snapshot, sequence
   guard) to Swift Concurrency (`actor`, `AsyncStream`, `Task` cancellation). Don't import the
   paradigm.

5. **`serverGetConfig` as the readiness probe.** The *idea* (an RPC that proves the peer is
   responsive, gating `connected`) transfers; the specific method doesn't. Continuum's
   remote/iOS readiness probe is whatever cheap round-trip the host daemon or ssh channel
   offers (e.g. a `tmux list-sessions` over ssh, or a daemon `ping`).

---

## 5. Open questions / forks

1. **iOS observer transport for terminals.** t3 streams pty bytes; Continuum has no such
   server today. Fork: (a) a small **Continuum host daemon** on the Mac/VPS that exposes an
   attach-stream RPC (t3-style, cleanest, ties to Decision D's "daemon vs ssh-wrap" open
   question `docs/38 …:337-338`); or (b) the observer shells `tmux capture-pane`/`pipe-pane`
   over ssh on a poll (fast to ship, lossy, higher latency). t3's `attachStream` is the
   reference design for (a). **Recommend (a) long-term, (b) as a spike.**

2. **Does native tmux reattach make the persisted `scrollback` fallback redundant, or
   complementary?** On a live daemon, `select-window` repaints the pane's own scrollback, so
   `descriptor.scrollback` is only needed when the session is *gone* (fresh daemon / remote
   down). Decide the precedence rule and where on-screen replay happens — this is the deferred
   NEEDS-HUMAN decision at `Sources/…/TileSpawner.swift:354-355`. (t3 has no fork here: the
   server always replays from disk because there's no native terminal to repaint.)

3. **What is Continuum's `serverGetConfig`?** For remote/iOS, pick the cheap readiness RPC that
   gates `connected`. Candidate: a `tmux list-sessions -F` round-trip (doubles as the
   `SessionTopologySnapshot` reconciliation oracle, `docs/38` §"serializable snapshot"). Fork:
   dedicated ping vs. reuse the topology query.

4. **Backoff/timeout config surface.** Per the project's configurable-first doctrine, the five
   backoff steps + two 15s timeouts + 30s reset must each be user-settable with persisted
   defaults. Fork: one "reconnect aggressiveness" preset vs. seven individual knobs. (t3
   hardcodes them; we can't.)

5. **Client buffer bound for the observer.** t3 caps the *client* buffer at 512 KiB and disk at
   5000 lines. Continuum's iOS observer needs its own cap (phones are memory-constrained). Fork:
   match 512 KiB, or make it a function of device class.

6. **Probe-on-wake vs. always-on.** t3 probes only on `application-active`. On iOS this maps to
   scene-phase `active`; on a background-capable Mac observer we may want a periodic heartbeat
   instead. Fork: event-driven probe (t3) vs. interval heartbeat.

7. **Multiple observers on one session (the mirror question).** t3 allows N clients to attach
   the same `(threadId,terminalId)` (they all get the snapshot+live fanout). Continuum's
   Decision B de-mirrors via grouped sessions for *local* tiles, but an **iOS observer watching
   a tile a Mac is also viewing** is the deliberate-shared-view case (I2's exception,
   `docs/38` invariant table). Confirm the observer path is read-only and doesn't perturb the
   Mac's `select-window`.

---

## Appendix — file:line index (verified reads)

**t3code (`…/scratchpad/t3code`):**
- `packages/client-runtime/src/connection/supervisor.ts` — the whole state machine
  (backoff `:32-35,:102-104`; `run` `:587-668`; connected gate `:530-542`; involuntary-close
  race `:544-563`; blocked `:631-645`; probe-on-active `:405-448`; `generation` `:611-623`).
- `packages/client-runtime/src/rpc/session.ts:116-138` — `initialConfig` cached, `ready` gate,
  `probe`, `closed`; `:99-102` transport no-retry.
- `packages/client-runtime/src/rpc/client.ts:150-237` — durable `subscribe` (`Stream.switchMap`
  over `supervisor.session`, transport-drain-and-wait).
- `packages/client-runtime/src/connection/model.ts:135-162` — `SupervisorConnectionState`,
  phase projection.
- `packages/client-runtime/src/state/terminal.ts:40-46` — terminal attach atom = durable
  subscribe + scan.
- `packages/client-runtime/src/state/terminalSession.ts:65-89,:125-173` — 512 KiB buffer,
  `applyTerminalAttachStreamEvent`, `version` guard.
- `packages/client-runtime/src/state/session.ts:31-52` — `initialConfigAtom` over session
  changes.
- (sub-search, reported) `state/shell.ts:48-89,:124-148`, `state/threads.ts:51-97,:154-182`,
  `state/runtime.ts:447-502`, `connection/persistence.ts:50-76` — offline cache + sequence
  guards + generation revalidation.
- `apps/server/src/terminal/Manager.ts` — session key `:1053-1055`; state `:232-257`; history
  path/persist `:1178-1184,:1324-1384`; readHistory `:1386-1465`; `openLocked` `:2099-2220`;
  `attachStream` `:2305-2360` + dup-guard `:392-402`; stop/close `:1717-1744,:1932-1970`; idle
  eviction `:81,:1569-1597`; shutdown finalizer `:2070-2097`; subprocess-activity poll
  `:1972-2068`.
- `apps/server/src/ws.ts:322-330,:1562-1618` — terminal RPC scopes + streaming wiring; **no
  disconnect-kills-terminal handler (verified absent).**
- `packages/contracts/src/terminal.ts` — full terminal contract (`DEFAULT_TERMINAL_ID` `:9`;
  `TerminalAttachInput` `:49-58`; `TerminalSessionSnapshot.history` `:96-111`;
  `TerminalAttachStreamEvent` `:223-233`).
- `packages/contracts/src/rpc.ts:183-184,:228,:481-649` — `WS_METHODS` + RPC defs.
- `docs/architecture/connection-runtime.md` — the prose spec of all of the above.

**Continuum (`/Users/dylan/Documents/personal/continuum-revived`):**
- `docs/38-agent-orchestration-architecture.md` — Decision A `:163-217`; lifecycle table
  `:199-204`; `tmuxWindowTarget` seam `:180-185`; Decision D `:324-338`; invariants I1/I8
  `:416,:423`; real-path reattach check `:425-431`.
- `Sources/ContinuumRevivedCore/TmuxSession.swift:8-24` — `sessionName`/`wrap`
  (`new-session -A -s continuum-<tileId>`).
- `Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift:3-82` — descriptor incl.
  `scrollback: String?` (`:20`), `AgentDescriptor` (`:94`), `restoredForBoot` `:78`. **No
  `tmuxWindowTarget` field yet.**
- `Sources/ContinuumRevived/App/TileSpawner.swift:276-358` (`restartTerminalTile`, rebind by
  `tileId` `:303`, scrollback carry-forward `:345`, deferred-replay note `:354-355`);
  `:371-409` (`flushTerminalSessionSnapshot`, bounded capture).
- `Sources/ContinuumRevivedCore/ProjectStore.swift:157` — `listSessions()` reads on-disk
  descriptors (not `tmux ls`).
