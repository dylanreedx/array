# ACP driver — first end-to-end managed-agent adapter

## What this delivers

A running, observable managed-agent session driven entirely over the Agent Client Protocol (ACP). When this ticket is complete, Continuum can spawn an ACP-speaking agent binary — specifically `agent acp` (Cursor) or `grok agent stdio` (Grok) — hand it a prompt, watch its output stream as structured events, update the fleet status in real time, and interrupt or stop the session cleanly. The session's derived `AgentStatus` flows into the same `AgentDescriptor.status` field that every dotfile reader already writes, so the sidebar, zone rollup, and canvas tile status badge light up for a managed agent with no additional plumbing.

From the fleet's point of view: a managed agent tile now shows a live, authoritative blue working-pulse while the agent runs, flips to orange with a diamond on `request.opened` (an approval waiting), and lands on a green check when the turn completes — all from events, not file-tailing.

From the system's point of view: the `AgentAdapter` protocol has its first non-trivial conformance, the Node sidecar's ACP JavaScript client is exercised end-to-end against a real binary, and invariant I5 (no transcript body crosses the sync boundary) is verified by a taint check over the event projection path.

## How it fits

This ticket sits squarely in Phase 7 of the build plan, the managed-tier layer. It builds on two direct prerequisites. The `AgentAdapter` protocol and `AgentRuntimeEvent` union (the adapter-protocol ticket, one ahead of this one in the queue) define the exact Swift contract this driver must satisfy — `startSession`, `sendTurn`, `interruptTurn`, `stopSession`, `respondToRequest`, `respondToUserInput`, and the `events: AsyncStream<AgentRuntimeEvent>` property. Without that protocol in place there is nothing to conform to. The Node sidecar bundling ticket (one behind the protocol ticket, one ahead of this one) makes the ACP TypeScript client available as a bundled executable the Swift layer can spawn; without the sidecar, there is no runtime for the JavaScript ACP client to run in.

This ticket unblocks the approvals-to-`needsAttention` ticket directly: the approval ticket wires `request.opened` events from an adapter into the pending-approval store and calls `deriveAgentStatus` with `hasPendingApproval: true`, but it needs a real adapter emitting real `requestOpened` events to prove the path end-to-end. It also unblocks the managed transcript tile, which renders the card-based view from the same `AgentRuntimeEvent` stream. Both of those tickets wait on this one.

## The approach

The driver is a Swift actor, `ACPDriverSession`, that owns one child process (the Node sidecar process hosting `agent acp` or `grok agent stdio`) and communicates with it via the sidecar's stdin/stdout channel. The sidecar is itself the ACP client — it translates ACP JSON-RPC frames into a structured JSON stream that the Swift actor reads line by line, parses into `AgentRuntimeEvent` values, and offers into an `AsyncStream` continuation.

This split — Swift actor owns the process lifecycle; Node sidecar owns the ACP protocol — is the direct consequence of decision D2: the ACP protocol implementation lives in TypeScript (reusing t3code's `AcpSessionRuntime.ts` verbatim via the sidecar), and Swift drives it through a thin newline-delimited JSON bridge rather than re-implementing the protocol in Swift.

The control flow is as follows. `startSession` spawns the sidecar process, sends it a JSON start command containing the agent binary path, arguments, working directory, and auth method, and awaits a `session.started` acknowledgement on the sidecar's stdout. The sidecar then maintains the ACP handshake (`initialize` → `authenticate` → `session/new`), relaying all subsequent `session/update` notifications and `session/request_permission` server requests back to Swift as structured JSON lines. Swift parses each line into the appropriate `AgentRuntimeEvent` case and yields it into the continuation. `sendTurn` serializes to a JSON command line on the sidecar's stdin; the sidecar calls `session/prompt` on the ACP channel and the response flows back through the same event stream. `interruptTurn` sends an interrupt command; the sidecar cancels the in-flight `session/prompt` RPC fiber by closing the request. `stopSession` sends a stop command; the sidecar calls `session/stop` or kills the agent subprocess, then sends a `session.exited` event and exits cleanly.

The event stream never carries transcript bodies across any sync boundary. The `contentDelta` event is local to the view layer — it feeds the managed transcript tile's live text rendering — and is explicitly excluded from the event projection that the sync transport carries. The projection carries only the derived `AgentStatus` and the metadata fields (`threadId`, `turnId`, item titles at most 120 characters). This is the I5 guarantee applied to the managed tier.

A single `AcpAdapterFactory` struct provides the driver's entry point, taking a `ProcessSpawner` dependency (the injectable substrate from the foundations phase) and an `AgentAdapterConfiguration` (binary path, working directory, auth method). The factory produces an `ACPDriverSession` actor. No global state; one actor per managed tile.

## Where it lives

All new symbols belong in `Sources/ContinuumRevivedCore/`, alongside the existing adapter protocol definitions that this ticket depends on.

**`Sources/ContinuumRevivedCore/ACPDriverSession.swift`** — the primary new file. Contains `ACPDriverSession` (an `actor`), `AcpAdapterFactory` (a `struct` satisfying the adapter factory protocol), `AcpBridgeCommand` (a `Codable` enum of commands sent to the sidecar), `AcpBridgeFrame` (a `Codable` enum of frames received from the sidecar), and `AcpDriverError` (an error type covering spawn failure, handshake timeout, and protocol violation).

**`Sources/ContinuumRevivedCore/AgentStatusEngine.swift`** — the `deriveAgentStatus(signals:)` function and `StatusSignals` struct already live here (from the pure status-derivation ticket). The ACP driver calls `deriveAgentStatus` each time a status-relevant event arrives, writes the result into the tile's `AgentDescriptor.status`, and posts it to the observer. No changes to the file's existing symbols; this ticket adds no new symbols here.

**`Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift:85`** — `AgentStatus` enum (six cases: `configuring`, `working`, `idle`, `needsAttention`, `done`, `stale`). The driver maps ACP session states to these cases via `deriveAgentStatus`. No changes to this file.

**`Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift:94`** — `AgentDescriptor` struct. The driver writes `agentKind: .managed` and updates `status` and `statusUpdatedAt` on each state change. No structural changes.

The Node sidecar entry point (`sidecar/acp-bridge.js` or its compiled SEA equivalent) is the sidecar-bundling ticket's deliverable; this ticket's Swift code assumes the sidecar binary is available at a resolved path provided by `AgentAdapterConfiguration.sidecarbinaryPath`.

## Implementation breadcrumbs

```swift
// AcpBridgeCommand — what Swift sends to the sidecar on stdin (NDJSON, one per line)
enum AcpBridgeCommand: Codable {
    case start(agentBinary: String, args: [String], cwd: String, authMethodId: String)
    case sendTurn(sessionId: String, prompt: String)
    case interrupt(sessionId: String)
    case respond(sessionId: String, requestId: String, decision: ApprovalDecision)
    case stop(sessionId: String)
}

// AcpBridgeFrame — what the sidecar sends back on stdout (NDJSON)
// The sidecar maps ACP protocol events → these typed frames.
// Body-carrying fields (delta, toolDetail) are present here for the view layer;
// they must NEVER appear in the sync projection (I5).
enum AcpBridgeFrame: Codable {
    case sessionStarted(sessionId: String)
    case sessionStateChanged(sessionId: String, state: AcpSessionState) // starting|ready|running|waiting|stopped|error
    case turnStarted(sessionId: String, turnId: String)
    case turnCompleted(sessionId: String, turnId: String, outcome: TurnOutcome)
    case itemStarted(sessionId: String, itemId: String, kind: CanonicalItemKind, title: String?)
    case itemCompleted(sessionId: String, itemId: String, status: ItemCompletionStatus)
    case contentDelta(sessionId: String, delta: String)          // view-local; excluded from projection
    case requestOpened(sessionId: String, requestId: String, kind: ApprovalKind)
    case requestResolved(sessionId: String, requestId: String)
    case sessionExited(sessionId: String, reason: ExitReason)
    case protocolError(message: String)
}

// ACPDriverSession — one actor per managed tile
actor ACPDriverSession: AgentAdapter {
    private let config: AgentAdapterConfiguration
    private let spawner: ProcessSpawner
    private var process: Process?
    private var continuation: AsyncStream<AgentRuntimeEvent>.Continuation?
    private var sessionId: String?

    // AgentAdapter conformance
    var providerKind: AgentKind { .managed }
    var events: AsyncStream<AgentRuntimeEvent> { get { /* return stored stream */ } }

    func startSession(_ input: AgentSessionStartInput) async throws -> AgentSession {
        // 1. Spawn the sidecar process (uses injectable spawner, never Process() directly)
        // 2. Send AcpBridgeCommand.start(...) on stdin
        // 3. Read lines from stdout; await .sessionStarted frame (timeout: 10 s)
        //    — if timeout fires, kill process and throw AcpDriverError.handshakeTimeout
        // 4. Begin pumpFrames() task: read stdout lines indefinitely, parse, yield events
        // 5. Return AgentSession(threadId: sessionId, ...)
    }

    func sendTurn(_ input: AgentSendTurnInput) async throws -> AgentTurnStartResult {
        // Serialize AcpBridgeCommand.sendTurn(...) to stdin
        // The sidecar calls session/prompt; turn events arrive via the event stream
    }

    func interruptTurn(threadId: String, turnId: String?) async throws {
        // Serialize AcpBridgeCommand.interrupt(sessionId: threadId) to stdin
        // The sidecar cancels the in-flight session/prompt RPC fiber
    }

    func stopSession(threadId: String) async throws {
        // Serialize AcpBridgeCommand.stop(sessionId: threadId) to stdin
        // Await session.exited frame or process termination (timeout: 5 s), then kill
    }

    func respondToRequest(threadId: String, requestId: String, decision: ApprovalDecision) async throws {
        // Serialize AcpBridgeCommand.respond(...) to stdin
        // The sidecar forwards the approval decision to the agent via session/respond
    }

    private func pumpFrames() async {
        // Read stdout line by line using AsyncLineSequence
        for await line in process!.standardOutput.lines {
            guard let frame = try? JSONDecoder().decode(AcpBridgeFrame.self, from: Data(line.utf8)) else {
                // Log malformed frame; do not crash; do not yield a status
                continue
            }
            let event = frameToEvent(frame)     // maps AcpBridgeFrame → AgentRuntimeEvent
            continuation?.yield(event)
        }
        continuation?.finish()
    }

    private func frameToEvent(_ frame: AcpBridgeFrame) -> AgentRuntimeEvent {
        switch frame {
        case .sessionStateChanged(_, let state):
            return .sessionStateChanged(state.toSessionState())
        case .requestOpened(_, let requestId, let kind):
            return .requestOpened(requestId: requestId, kind: kind)
        // ... one case per AcpBridgeFrame variant
        }
    }
}

// Status derivation — called by the observer after each event, not inside the driver.
// The driver emits events; the observer calls deriveAgentStatus(signals:) and writes AgentDescriptor.
// This keeps the driver's responsibility narrow: protocol ↔ event translation only.
```

The sidecar bridge script (TypeScript, compiled into the SEA bundle by the sidecar-bundling ticket) mirrors this shape:

```typescript
// acp-bridge.ts — reads commands from stdin, drives AcpSessionRuntime, writes frames to stdout
async function main() {
    for await (const line of stdinLines()) {
        const cmd = JSON.parse(line) as AcpBridgeCommand;
        if (cmd.type === "start") {
            const runtime = await AcpSessionRuntime.create({ spawn: cmd, authMethodId: cmd.authMethodId });
            // wire runtime.getEvents() → JSON frames on stdout
            runtime.getEvents().pipe(Stream.runForEach(frame => writeLine(JSON.stringify(frame))));
        }
        if (cmd.type === "sendTurn") { await runtime.prompt({ sessionId: cmd.sessionId, prompt: cmd.prompt }); }
        if (cmd.type === "interrupt") { await runtime.interrupt(cmd.sessionId); }
        if (cmd.type === "stop") { await runtime.stop(cmd.sessionId); process.exit(0); }
    }
}
```

The sidecar reuses `AcpSessionRuntime` from t3code verbatim — the `initialize → authenticate → session/new → session/prompt` handshake is exactly the code at `acp/AcpSessionRuntime.ts:326-343, 519-540, 627, 707-748`. No protocol logic is re-implemented in Swift.

## How we test it

### Logic (pure Core checks)

Two logic checks, both runnable with `swift test` and zero live processes.

The first check validates `frameToEvent` exhaustively. For each `AcpBridgeFrame` case, construct a representative value, call `frameToEvent`, and assert the resulting `AgentRuntimeEvent` matches the expected case. Specifically: `sessionStateChanged(state: .running)` → `AgentRuntimeEvent.sessionStateChanged(.running)`; `requestOpened(requestId: "r1", kind: .commandExecution)` → `AgentRuntimeEvent.requestOpened(requestId: "r1", kind: .commandExecution)`; `contentDelta(delta: "hello")` → `AgentRuntimeEvent.contentDelta(streamKind: .assistant, delta: "hello")`. Every case in `AcpBridgeFrame` must have a row; exhaustive switch coverage enforced by the compiler.

The second check is a taint scan asserting I5 over the managed event projection path. Define a function `projectedPayload(from event: AgentRuntimeEvent) -> ProjectedEventPayload` that returns what the sync transport would carry for a given event. Write a table-driven check asserting that `projectedPayload` never includes a `delta` string, never includes tool input bodies, and never includes `errorMessage` fields longer than 160 characters. For each `AgentRuntimeEvent` case that carries body text (`contentDelta`, `itemStarted` with long title, `turnCompleted` with `errorMessage`), assert that `projectedPayload` drops the body and retains only the metadata (`threadId`, `turnId`, `itemId`, kind label, status). This is the managed-tier analog of the sync-boundary taint scan that runs for the spatial layer.

### Backend (real-path / integration, not bypassed)

The backend check spawns the real Node sidecar process (pre-built by the sidecar-bundling ticket) against a real ACP-speaking agent binary. The check uses `agent acp` (Cursor's CLI) with a test account that has been pre-authenticated on the CI machine; it is marked `needs-substrate` and does not run in the autonomous overnight loop.

The check drives this exact sequence: spawn `ACPDriverSession` → call `startSession` with a fixed working directory → await the `sessionStateChanged(.ready)` event → call `sendTurn` with the prompt `"Print the word SENTINEL and stop"` → collect events until `turnCompleted` → assert `turnCompleted` event arrived with `outcome: .completed` → assert at least one `contentDelta` event was received containing `"SENTINEL"` → assert the `AgentDescriptor.status` written after `deriveAgentStatus` is `.done`. Then call `stopSession` → assert the sidecar process exits within 5 seconds (not lingering). The entire check uses the real sidecar binary and a real `agent acp` subprocess; no mocks, no fakes for the ACP channel.

A second real-path check validates interrupt: call `startSession` → call `sendTurn` with a long-running prompt → immediately call `interruptTurn` → assert a `turnCompleted(outcome: .interrupted)` event arrives within 3 seconds → assert no further events arrive from the interrupted turn.

### UX (visual gate + dogfood snippet)

The visual gate runs in the Component Lab before the transcript tile ticket, seeded with a scripted fixture transcript. Add a fixture named `ACPManagedAgentFixture` to the Component Lab that replays a pre-recorded sequence of `AgentRuntimeEvent` values into a `MockAgentAdapter` (the same injectable fake used by the logic checks). The Component Lab renders the managed transcript tile driven by this fixture stream. Gate criteria: the status header shows the blue working-pulse ring while `sessionStateChanged(.running)` events are arriving; it switches to the orange diamond border and an actionable approval dock card when `requestOpened` arrives; it lands on the green check badge when `turnCompleted(outcome: .completed)` fires. All three transitions must be visually present in the rendered Component Lab fixture before this ticket is marked done — a screenshot of each state is the non-degenerate visual gate (not "tile appeared," but "tile shows the correct status color and card layout at each phase").

Concrete dogfood snippet: open Continuum → from the menu bar choose Agent → New Managed Agent → select "Cursor (ACP)" → set the working directory to any local repository → click Start. The managed-agent tile appears in the canvas with a teal configuring ring. Within 3 seconds (the sidecar handshake), the ring transitions to a blue working-pulse. Type a prompt in the tile's input field and press Return. Watch the transcript area: assistant message cards appear as `contentDelta` events stream in, each new chunk appending to the current card without a full re-render. If the agent requests an approval, the tile border turns orange-marching-ants and an Approve / Approve-for-session / Decline dock appears at the bottom of the tile. When the turn completes, the tile badge lands on a green check. The full sequence — start → prompt → stream → complete — must happen with no manual intervention beyond entering the prompt.

## Execution mode

**Needs-substrate.** The logic checks are autonomous (pure Swift, no process), but the backend check requires a pre-authenticated `agent acp` binary on the CI machine and a working network connection to Cursor's ACP endpoint. The sidecar binary must be present (delivered by the sidecar-bundling ticket). The UX visual gate requires a human to visually confirm the three status transitions in the Component Lab fixture, and the dogfood snippet requires a human to drive the real app. None of the three gates can be satisfied without real substrate; the autonomous overnight loop does not run this ticket.

## Done when

- [ ] `ACPDriverSession` actor exists in `Sources/ContinuumRevivedCore/ACPDriverSession.swift` and satisfies the `AgentAdapter` protocol with zero compile errors.
- [ ] `AcpBridgeCommand` and `AcpBridgeFrame` enums are `Codable`, exhaustive, and match the sidecar bridge script's type definitions byte-for-byte (round-trip test passes).
- [ ] `startSession` spawns the sidecar via the injectable `ProcessSpawner` (never `Process()` directly) and returns an `AgentSession` after receiving `sessionStarted`.
- [ ] `pumpFrames` reads stdout with `AsyncLineSequence`, parses each line as `AcpBridgeFrame`, maps it to `AgentRuntimeEvent`, and yields it into the `AsyncStream` continuation. Malformed lines are logged and skipped; they do not crash or stall the pump.
- [ ] `interruptTurn` causes the in-flight turn to complete with `outcome: .interrupted` within 3 seconds on the real-path check.
- [ ] `stopSession` exits the sidecar process within 5 seconds without leaving orphaned subprocesses.
- [ ] The `frameToEvent` logic check covers every `AcpBridgeFrame` case with a named assertion row.
- [ ] The I5 taint scan logic check passes: `projectedPayload` returns no transcript body for any event case.
- [ ] The real-path check runs against a live `agent acp` process, completes the `SENTINEL` prompt turn, asserts `turnCompleted(outcome: .completed)`, and asserts `AgentDescriptor.status == .done`.
- [ ] The Component Lab `ACPManagedAgentFixture` renders the three status states (working-pulse, orange attention dock, green check) from a pre-recorded event sequence, and a screenshot of each is attached to the check run.
- [ ] The dogfood snippet completes end-to-end in the real app with no errors in the console.
- [ ] `swift build` with no new warnings.
- [ ] Confirmed via the taint scan that no `contentDelta.delta` value, no tool input body, and no `errorMessage` longer than 160 characters appears in the value returned by `projectedPayload` for any event kind.

## Depends on / unblocks

This ticket depends on the `AgentAdapter` protocol and `AgentRuntimeEvent` union (the adapter-protocol ticket). The Swift `ACPDriverSession` must conform to `AgentAdapter`; without the protocol defined, the conformance cannot be written or tested. It also depends on the Node sidecar bundling ticket, which delivers the compiled sidecar binary containing the TypeScript ACP client. Without the sidecar binary, `startSession` has nothing to spawn and the real-path check cannot run.

This ticket unblocks the approvals-to-`needsAttention` ticket, which wires `requestOpened` events from a live adapter into the pending-approval store. That ticket needs a real adapter emitting real approval events, which only the ACP driver provides. It also unblocks the managed transcript tile ticket, which renders cards from `AgentRuntimeEvent` values; that ticket can use a `MockAgentAdapter` for its Component Lab fixture, but its real-path check needs a live driver. Both tickets are directly gated on this one landing first.

## Watch out for

**The sidecar's process lifecycle is the single hardest thing to get right.** An orphaned Node process is silent, invisible, and resource-leaking. Every early-exit path from `ACPDriverSession` — `interruptTurn` timeout, `stopSession` timeout, Task cancellation, Swift actor deallocation — must terminate the sidecar process. Use a `defer { process.terminate() }` guard immediately after spawn succeeds, wrapped in a scoped `withTaskCancellationHandler` that calls `process.terminate()` on cancellation. Test specifically: cancel the enclosing `Task` mid-turn and assert the sidecar process is no longer in `ps aux` within 2 seconds. Do not rely on the sidecar self-terminating when Swift's end of the pipe closes; some runtimes buffer and linger.

**The handshake timeout must be a hard abort, not a Swift concurrency timeout that leaves the process running.** If `startSession` times out waiting for `sessionStarted`, it must call `process.terminate()` before throwing `AcpDriverError.handshakeTimeout`. A throw alone will not stop the process.

**`contentDelta` events are body-carrying and must never reach the sync projection.** The sidecar delivers these at high frequency during a streaming turn. The Swift event pump yields them into `AsyncStream<AgentRuntimeEvent>` for the view layer — that is correct. The stop condition is `projectedPayload(from: .contentDelta(...))` returning a payload with no `delta` field. Add the I5 taint scan check before writing any sync transport integration, so the projection path is proven clean before it can accidentally carry bodies.

**ACP's `session/request_permission` is a server-to-client request, not a notification.** The sidecar must respond to it (with an approval or denial) on the agent's behalf after receiving the human decision via `AcpBridgeCommand.respond`. If the sidecar does not respond, the agent's RPC fiber is parked indefinitely — the agent appears stuck, the session never progresses, and `stopSession` will time out. The real-path interrupt check exercises this path; do not mark the check as passing unless the interruption actually resolves the parked RPC.

**De-duplicate `session/update` replays on reconnect.** t3code's `AcpSessionRuntime` (`:359-373`) explicitly de-duplicates `session/update` notifications against a replay buffer when a session is resumed. If the sidecar is restarted and resumes a session (for example, after a crash recovery), it will receive already-seen events from the agent. The sidecar bridge must track the last-seen event sequence number and skip events with sequence numbers at or below it. Failing to de-duplicate causes the managed transcript tile to show duplicate cards and the approval store to open already-resolved requests.
