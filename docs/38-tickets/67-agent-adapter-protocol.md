# AgentAdapter protocol and canonical runtime event union

## What this delivers

A Swift protocol — `AgentAdapter` — that every managed-agent provider implements, and a
Swift enum — `AgentRuntimeEvent` — that every adapter emits. Together they are the
managed-tier contract: the definitive answer to "how does a caller start, steer, interrupt,
and respond to a headless agent session, and what events come back?"

From the system's point of view, the managed tier finally has a seam that callers can
target without branching on provider. The `AgentRuntimeEvent` stream feeds
`deriveAgentStatus`, which writes into `AgentDescriptor.status` — the same field the
dotfile readers write for observed shell tiles. The sidebar, zone rollup, and push service
read one field, one derivation function, regardless of which tier produced the value.

From the user's point of view, nothing is visible yet — the adapter protocol has no UI.
Its value surfaces in the next layer up: when a managed Claude, Codex, or ACP agent tile
lights up its status badge and approval dock, every bit of that is fed by `AgentRuntimeEvent`
flowing through `deriveAgentStatus`. This ticket is the load-bearing foundation under all
of that.

## How it fits

The pure status-derivation function (the ticket that introduced `deriveAgentStatus` and
`StatusSignals`) established the output side of the managed tier: given a `StatusSignals`
value with `hasPendingApproval`, `hasPendingUserInput`, `isRunning`, and `isCompleted`
populated, it produces a correct `AgentStatus`. This ticket defines where those fields
come from for managed agents: they are assembled by reading `AgentRuntimeEvent` values off
an adapter's `events: AsyncStream<AgentRuntimeEvent>` and projecting them into
`StatusSignals`.

The closed `AgentKind` enum (the ticket that introduced `AgentKind` with cases including
`.managed`) provides the type used in `AgentAdapter.providerKind: AgentKind`. Without the
enum, the adapter protocol cannot be typed correctly.

What this ticket directly unblocks: the four concrete adapter implementations (ACP, Codex
`app-server`, Claude SDK sidecar, OpenCode HTTP). Each is a struct conforming to
`AgentAdapter`; none of them can be written without the protocol in place first. The
managed-agent session record (the private, host-local struct that carries the resume
cursor and is explicitly never synced) also depends on the `AgentSession` type introduced
here. The approval dispatch path — the code that calls `respondToRequest` when the user
taps Approve — depends on the method signature being settled. And the full approval UX
tile (the managed-agent tile kind with its transcript view and approval dock) depends on
the event vocabulary being finalized, because each event variant maps to a concrete card
or state mutation in the view.

## The approach

Port `ProviderAdapterShape<TError>` from the t3code research spike
(`docs/2026-06-30-t3code-steal/03-provider-adapters-protocols.md`) to a plain Swift
`protocol`, dropping the Effect type system for `async throws` and `AsyncStream`. The
mapping is direct: `Effect<A, E>` becomes `async throws -> A`; `Stream<ProviderRuntimeEvent>`
becomes `AsyncStream<AgentRuntimeEvent>`; `Effect<void, E>` becomes `async throws`. No
new abstraction is introduced beyond what the source material describes.

The event union is a trimmed port of `ProviderRuntimeEvent`. The full t3code union has 47
variants; this ticket ships the subset that drives `StatusSignals` and the approval dock —
roughly 12 variants — with room to add the remainder as later adapters need them. The
12-variant target is not a limitation; it is the minimum that makes the derivation function
and approval path fully exercisable. The shape of each case (`sessionStateChanged`,
`turnCompleted`, `requestOpened`, etc.) is taken directly from the source material's payload
descriptions (`providerRuntime.ts:276,362,404,421`), translated to Swift naming conventions.

The I5 sync-boundary rule (no transcript bodies ever cross the sync layer) is enforced by
construction: `AgentRuntimeEvent` cases that carry body text (`contentDelta`, `itemStarted`
with a title) are tagged in a doc-comment as body-carrying and explicitly listed in the
taint scan (ticket nine) as forbidden from the synced payload. The protocol and event type
themselves impose no runtime enforcement at this layer — that is the taint scan's job —
but the doc-comments establish the contract so no future implementer has to infer it.

The `AgentAdapter` protocol is `Sendable` and uses `actor`-safe async methods throughout,
because every concrete adapter will manage a child process or network connection on its
own actor. The `events` stream is a property, not a method, returning a single
`AsyncStream<AgentRuntimeEvent>` that the caller drives as an `AsyncSequence` loop. A
single adapter instance emits all events for all threads it manages; each event carries
a `threadId` so the caller can route.

## Where it lives

**Primary file:** `Sources/ContinuumRevivedCore/AgentStatusEngine.swift`

The protocol and event union are added at the bottom of this file, below the existing
`AgentStatusEngine` struct and the `StatusSignals` / `deriveAgentStatus` additions from
the pure status-derivation ticket. No new file is introduced; all managed-tier contracts
live in the same Core file as the status engine they feed.

**New symbols to create, in order of definition:**

`AgentSessionState` — a `public enum`, `Equatable`, `Sendable`, with cases `starting`,
`ready`, `running`, `waiting`, `stopped`, `error`. This is the Swift port of
`SessionState` from the t3code source (`SessionStateChangedPayload.state`,
`providerRuntime.ts:276`).

`TurnOutcome` — a `public enum`, `Equatable`, `Sendable`, with cases `completed`,
`failed`, `interrupted`, `cancelled`. Port of `TurnCompletedPayload.state`
(`providerRuntime.ts:362`).

`ItemKind` — a `public enum`, `Equatable`, `Sendable`, with cases `commandExecution`,
`fileChange`, `mcpToolCall`, `webSearch`, `assistantMessage`, `reasoning`, `plan`,
`error`. Port of `CanonicalItemType` (`providerRuntime.ts:121`).

`ItemStatus` — a `public enum`, `Equatable`, `Sendable`, with cases `inProgress`,
`completed`, `failed`, `declined`. Port of `ItemLifecyclePayload.status`
(`providerRuntime.ts:404`).

`ApprovalKind` — a `public enum`, `Equatable`, `Sendable`, with cases
`commandExecutionApproval`, `applyPatchApproval`, `toolUserInput`. Port of
`CanonicalRequestType` (`providerRuntime.ts:421`).

`ApprovalDecision` — a `public enum`, `Equatable`, `Sendable`, with cases `approve`,
`approveForSession`, `decline`. These map directly to the approval dock's three buttons.

`UserInputQuestion` — a `public struct`, `Equatable`, `Sendable`, with fields
`key: String` and `prompt: String`. The minimum shape needed to render an answer form.

`TokenUsageSnapshot` — a `public struct`, `Equatable`, `Sendable`, with fields
`inputTokens: Int`, `outputTokens: Int`, `totalCostUsd: Double?`. Port of
`ThreadTokenUsageSnapshot` (`providerRuntime.ts:307`), trimmed to what the status header
displays.

`AgentRuntimeEvent` — a `public enum`, `Sendable`, the canonical 12-variant union:

```
sessionStateChanged(AgentSessionState)
turnStarted(threadId: String, turnId: String)
turnCompleted(threadId: String, turnId: String, outcome: TurnOutcome, errorMessage: String?)
itemStarted(threadId: String, itemId: String, kind: ItemKind, title: String?)
itemCompleted(threadId: String, itemId: String, kind: ItemKind, status: ItemStatus)
contentDelta(threadId: String, turnId: String, streamKind: ContentStreamKind, delta: String)
requestOpened(threadId: String, requestId: String, kind: ApprovalKind)
requestResolved(threadId: String, requestId: String, decision: String)
userInputRequested(threadId: String, requestId: String, questions: [UserInputQuestion])
userInputResolved(threadId: String, requestId: String)
tokenUsageUpdated(threadId: String, snapshot: TokenUsageSnapshot)
runtimeError(threadId: String?, message: String)
```

`ContentStreamKind` — a `public enum`, `Equatable`, `Sendable`, with cases `assistant`,
`reasoning`, `commandOutput`. Needed to type the `contentDelta` case without embedding
a string tag.

`AgentSession` — a `public struct`, `Equatable`, `Sendable`, with fields
`threadId: String` and `providerSessionId: String?`. The return value of
`AgentAdapter.startSession`. The `threadId` is the stable adapter-assigned identity;
`providerSessionId` is the opaque provider-native resume token (Claude's `sessionId`,
Codex's `thread.id`, ACP's `sessionId`).

`AgentSessionStartInput` — a `public struct`, `Equatable`, `Sendable`, with fields
`cwd: String`, `systemPrompt: String?`, `env: [String: String]`, `resumeThreadId: String?`.
The `resumeThreadId` carries a prior `threadId` so the adapter can resume rather than
start fresh.

`AgentSendTurnInput` — a `public struct`, `Equatable`, `Sendable`, with fields
`threadId: String`, `text: String`. The minimal shape for a user message or a steer.

`AgentTurnStartResult` — a `public struct`, `Equatable`, `Sendable`, with field
`turnId: String`. Returned by `sendTurn` so the caller can correlate subsequent events.

`UserInputAnswers` — a `public struct`, `Equatable`, `Sendable`, with field
`answers: [String: String]` (keyed by `UserInputQuestion.key`).

`AgentAdapter` — a `public protocol`, `Sendable`:

```swift
var providerKind: AgentKind { get }
func startSession(_ input: AgentSessionStartInput) async throws -> AgentSession
func sendTurn(_ input: AgentSendTurnInput) async throws -> AgentTurnStartResult
func interruptTurn(threadId: String, turnId: String?) async throws
func stopSession(threadId: String) async throws
func respondToRequest(threadId: String, requestId: String, decision: ApprovalDecision) async throws
func respondToUserInput(threadId: String, requestId: String, answers: UserInputAnswers) async throws
func hasSession(threadId: String) async -> Bool
var events: AsyncStream<AgentRuntimeEvent> { get }
```

**Seam that feeds the derivation function** — a free function that projects an
`AgentRuntimeEvent` stream into `StatusSignals`:

`func deriveStatusSignals(from events: [AgentRuntimeEvent], engineStatus: AgentStatus) -> StatusSignals`

This function is pure (takes a snapshot of accumulated events, not a live stream) and lives
alongside `deriveAgentStatus` in `AgentStatusEngine.swift`. The `SessionObserver` calls it
after each event batch to recompute `StatusSignals` before calling `deriveAgentStatus`.

**Existing symbols confirmed, unchanged:**

- `AgentStatusEngine` at `Sources/ContinuumRevivedCore/AgentStatusEngine.swift:3` —
  untouched; the engine's `Signal` enum and hysteresis logic remain exactly as-is.
- `StatusSignals` and `deriveAgentStatus` — already established by the pure
  status-derivation ticket; this ticket calls them but does not modify them.
- `AgentStatus` at `Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift:85` —
  the six-case enum that `deriveAgentStatus` returns; unchanged.
- `AgentKind` — the closed enum from the prior ticket, used in `AgentAdapter.providerKind`.

## Implementation breadcrumbs

```swift
// ── Supporting enums ────────────────────────────────────────────────────────

public enum AgentSessionState: String, Equatable, Sendable {
    case starting, ready, running, waiting, stopped, error
}

public enum TurnOutcome: String, Equatable, Sendable {
    case completed, failed, interrupted, cancelled
}

public enum ItemKind: String, Equatable, Sendable {
    case commandExecution, fileChange, mcpToolCall, webSearch
    case assistantMessage, reasoning, plan, error
}

public enum ItemStatus: String, Equatable, Sendable {
    case inProgress, completed, failed, declined
}

public enum ApprovalKind: String, Equatable, Sendable {
    case commandExecutionApproval, applyPatchApproval, toolUserInput
}

public enum ApprovalDecision: String, Equatable, Sendable {
    case approve, approveForSession, decline
}

public enum ContentStreamKind: String, Equatable, Sendable {
    case assistant, reasoning, commandOutput
}

// ── Payload value types ──────────────────────────────────────────────────────

public struct UserInputQuestion: Equatable, Sendable {
    public let key: String
    public let prompt: String
}

public struct TokenUsageSnapshot: Equatable, Sendable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let totalCostUsd: Double?
}

public struct AgentSession: Equatable, Sendable {
    public let threadId: String
    public let providerSessionId: String?
}

public struct AgentSessionStartInput: Equatable, Sendable {
    public let cwd: String
    public let systemPrompt: String?
    public let env: [String: String]
    public let resumeThreadId: String?  // non-nil → resume, not start
}

public struct AgentSendTurnInput: Equatable, Sendable {
    public let threadId: String
    public let text: String
}

public struct AgentTurnStartResult: Equatable, Sendable {
    public let turnId: String
}

public struct UserInputAnswers: Equatable, Sendable {
    public let answers: [String: String]  // keyed by UserInputQuestion.key
}

// ── The canonical event union ────────────────────────────────────────────────
// Body-carrying cases (contentDelta, itemStarted title, runtimeError message)
// are marked [BODY]. These must NOT appear in the synced/projected payload.
// The taint scan (ticket 9) enforces this at the type level.

public enum AgentRuntimeEvent: Sendable {
    case sessionStateChanged(AgentSessionState)
    case turnStarted(threadId: String, turnId: String)
    case turnCompleted(threadId: String, turnId: String,
                       outcome: TurnOutcome, errorMessage: String?)  // errorMessage [BODY]
    case itemStarted(threadId: String, itemId: String,
                     kind: ItemKind, title: String?)                  // title [BODY]
    case itemCompleted(threadId: String, itemId: String,
                       kind: ItemKind, status: ItemStatus)
    case contentDelta(threadId: String, turnId: String,
                      streamKind: ContentStreamKind, delta: String)   // delta [BODY]
    case requestOpened(threadId: String, requestId: String, kind: ApprovalKind)
    case requestResolved(threadId: String, requestId: String, decision: String)
    case userInputRequested(threadId: String, requestId: String,
                            questions: [UserInputQuestion])
    case userInputResolved(threadId: String, requestId: String)
    case tokenUsageUpdated(threadId: String, snapshot: TokenUsageSnapshot)
    case runtimeError(threadId: String?, message: String)             // message [BODY]
}

// ── The adapter protocol ─────────────────────────────────────────────────────

public protocol AgentAdapter: Sendable {
    var providerKind: AgentKind { get }

    // Lifecycle
    func startSession(_ input: AgentSessionStartInput) async throws -> AgentSession
    func sendTurn(_ input: AgentSendTurnInput) async throws -> AgentTurnStartResult
    func interruptTurn(threadId: String, turnId: String?) async throws
    func stopSession(threadId: String) async throws

    // Human-in-the-loop back-channel
    func respondToRequest(
        threadId: String, requestId: String, decision: ApprovalDecision
    ) async throws
    func respondToUserInput(
        threadId: String, requestId: String, answers: UserInputAnswers
    ) async throws

    // Introspection
    func hasSession(threadId: String) async -> Bool

    // The canonical output — all events for all threads from this adapter
    var events: AsyncStream<AgentRuntimeEvent> { get }
}

// ── StatusSignals projection from events ─────────────────────────────────────
// Pure: takes a snapshot of accumulated events for one thread plus the engine's
// current output; returns a StatusSignals value for deriveAgentStatus to consume.
// The SessionObserver calls this after each event batch; no Date(), no I/O.

public func deriveStatusSignals(
    from events: [AgentRuntimeEvent],
    threadId: String,
    engineStatus: AgentStatus
) -> StatusSignals {
    var sessionState: AgentSessionState = .ready
    var latestTurnOutcome: TurnOutcome?
    var pendingApprovalIds: Set<String> = []
    var pendingUserInputIds: Set<String> = []

    for event in events {
        switch event {
        case .sessionStateChanged(let state):
            sessionState = state
        case .turnCompleted(let tid, _, let outcome, _) where tid == threadId:
            latestTurnOutcome = outcome
        case .requestOpened(let tid, let rid, _) where tid == threadId:
            pendingApprovalIds.insert(rid)
        case .requestResolved(let tid, let rid, _) where tid == threadId:
            pendingApprovalIds.remove(rid)
        case .userInputRequested(let tid, let rid, _) where tid == threadId:
            pendingUserInputIds.insert(rid)
        case .userInputResolved(let tid, let rid) where tid == threadId:
            pendingUserInputIds.remove(rid)
        default:
            break
        }
    }

    return StatusSignals(
        agentKind: .managed,
        hasPendingApproval:   !pendingApprovalIds.isEmpty,
        hasPendingUserInput:  !pendingUserInputIds.isEmpty,
        hookBreadcrumbPresent: false,         // never set for managed agents
        isError:     sessionState == .error || latestTurnOutcome == .failed,
        isStarting:  sessionState == .starting,
        isRunning:   sessionState == .running || sessionState == .waiting,
        isCompleted: latestTurnOutcome == .completed,
        engineStatus: engineStatus
    )
}
```

The `deriveStatusSignals` function deliberately accumulates a snapshot of events rather
than keeping a separate stateful projection. That is intentional: the function is pure and
testable in isolation. A real `SessionObserver` will call it with the accumulated event
array for a given thread on every new event, re-deriving `StatusSignals` each time. The
array stays bounded because the observer prunes events older than the current session (a
`sessionStateChanged(.stopped)` or `stopSession` call marks the boundary).

One critical detail in the projection: `sessionState == .waiting` maps to `isRunning =
true`. The `waiting` state in the t3code source (`SessionStateChangedPayload`) means the
agent is alive but blocked — on a prompt, on a tool approval, on rate-limiting. That is
`isRunning` from the status derivation's point of view; the separate `pendingApprovalIds`
/ `pendingUserInputIds` sets handle the `needsAttention` elevation when the wait is
specifically due to an approval. Do not map `waiting` to `isCompleted` or the cascade will
incorrectly surface `.done`.

## How we test it

### Logic (pure Core checks)

Add a new test file `ContinuumRevivedCoreTests/AgentAdapterTests.swift` with two suites:
one for `AgentRuntimeEvent` round-trip and one for `deriveStatusSignals`.

**Event round-trip (I7 invariant):** For each of the 12 event cases, construct an instance,
encode it with `JSONEncoder`, decode it back with `JSONDecoder`, and assert the result
equals the original. This requires `AgentRuntimeEvent` to conform to `Codable` — add the
conformance as part of this ticket, using associated-value encoding (a `type` discriminator
key plus a `payload` key). The raw type strings must be stable because they will appear in
the local event store when that store lands. Pin each: `"sessionStateChanged"`,
`"turnStarted"`, `"turnCompleted"`, `"itemStarted"`, `"itemCompleted"`, `"contentDelta"`,
`"requestOpened"`, `"requestResolved"`, `"userInputRequested"`, `"userInputResolved"`,
`"tokenUsageUpdated"`, `"runtimeError"`.

**`deriveStatusSignals` projection table:** Each row is a list of `AgentRuntimeEvent`
values for one thread, a call to `deriveStatusSignals`, and an assertion on the resulting
`StatusSignals`. Required rows:

- A `requestOpened` event with no `requestResolved` → `hasPendingApproval == true`.
- A `requestOpened` followed by a matching `requestResolved` → `hasPendingApproval == false`
  (the resolved request is removed from the pending set).
- A `requestOpened` from a *different* threadId → not counted; `hasPendingApproval == false`
  for the queried thread (thread-scoping is correct).
- A `userInputRequested` with no resolve → `hasPendingUserInput == true`.
- A `userInputRequested` followed by a matching `userInputResolved` →
  `hasPendingUserInput == false`.
- A `sessionStateChanged(.running)` → `isRunning == true`, `isStarting == false`.
- A `sessionStateChanged(.waiting)` → `isRunning == true` (waiting is live, not complete).
- A `sessionStateChanged(.starting)` → `isStarting == true`.
- A `turnCompleted` with `outcome: .completed`, session in `.ready` →
  `isCompleted == true`, `isRunning == false`, `isError == false`.
- A `turnCompleted` with `outcome: .failed` → `isError == true`.
- A `sessionStateChanged(.error)` → `isError == true`, `isRunning == false`.
- `hookBreadcrumbPresent` is always `false` in the result of `deriveStatusSignals`,
  regardless of any event combination, because managed adapters never write hook breadcrumbs.

Finally, call `deriveAgentStatus(signals:)` on each resulting `StatusSignals` and assert
the expected `AgentStatus`. For example: `hasPendingApproval == true` with `isRunning ==
true` → `.needsAttention` (attention wins per the priority cascade). This closes the loop
between the projection function and the derivation function in a single test.

Run with `swift test --filter AgentAdapterTests`. Zero daemons, zero file I/O, no real
process spawning.

### Backend (real-path / integration, not bypassed)

Write an integration test in `ContinuumRevivedCoreTests/AgentAdapterIntegrationTests.swift`
that exercises the projection function over a realistic event sequence read from a fixture
file. The fixture file lives at
`ContinuumRevivedCoreTests/Fixtures/managed-session-with-approval.jsonl`. Each line is a
JSON-encoded `AgentRuntimeEvent`. The sequence represents a full turn: `sessionStateChanged(.starting)`,
`sessionStateChanged(.running)`, `turnStarted`, `itemStarted(.commandExecution)`,
`requestOpened(.commandExecutionApproval)`, `requestResolved`, `itemCompleted(.commandExecution, .completed)`,
`turnCompleted(.completed)`, `sessionStateChanged(.ready)`.

The test reads the fixture file from the test bundle using `Bundle(for: Self.self)`,
decodes each line as `AgentRuntimeEvent` via `JSONDecoder`, then calls
`deriveStatusSignals` at each event boundary and asserts the cumulative `StatusSignals`
transitions correctly:

1. After `sessionStateChanged(.starting)`: `isStarting == true`.
2. After `sessionStateChanged(.running)` + `turnStarted`: `isRunning == true`.
3. After `requestOpened`: `hasPendingApproval == true`.
4. After `requestResolved`: `hasPendingApproval == false`, `isRunning == true`.
5. After `turnCompleted(.completed)` + `sessionStateChanged(.ready)`:
   `isCompleted == true`, `isRunning == false`.

Then call `deriveAgentStatus` at each step and assert the correct `AgentStatus` sequence:
`.configuring` → `.working` → `.needsAttention` → `.working` → `.done`. This sequence
directly asserts that a real managed-agent turn, encoded as real JSON on disk, produces
correct status transitions end-to-end with no mock adapters or bypassed paths.

The fixture file itself is the integration artifact — it is read from the real filesystem
(no mocking), decoded through the real `Codable` conformance, and projected through the
real functions. There is no spawned process and no live agent; the "real path" is the
JSON decode → accumulate → project → derive chain that will run identically in production.

### UX (visual gate + dogfood snippet)

The protocol and event types are pure definitions; they produce no visible UI on their
own. The visual gate for this ticket is a Component Lab fixture that renders a
`AgentRuntimeEvent` stream summary and the resulting `AgentStatus` badge, confirming that
the types are usable from the UI layer before any real adapter exists.

Add a fixture to the existing Component Lab (accessible via menu bar → Developer →
Component Lab) named "AgentAdapter Event Projection". The fixture constructs the same
12-event sequence as the fixture file above — inline, with no file I/O — calls
`deriveStatusSignals` and `deriveAgentStatus`, and renders a vertical list of:
- Each event's type name as a gray label.
- The derived `AgentStatus` after that event as a status badge (the same badge component
  used in the sidebar and tile chrome).

**Dogfood snippet:** Open Continuum → menu bar → Developer → Component Lab → navigate to
"AgentAdapter Event Projection" in the list. You should see a sequence of 12 rows. Row 3
(`sessionStateChanged(running)`) shows a blue "working" badge. Row 7 (`requestOpened`)
shows an orange "needs attention" badge. Row 9 (`requestResolved`) shows a blue "working"
badge again. Row 11 (`turnCompleted .completed`) shows a green "done" badge. No row shows
a gray "stale" or amber "configuring" badge unless the fixture is deliberately constructed
to trigger those states. If any badge color is wrong, the projection or derivation
function has a bug in its priority cascade and must be fixed before marking this ticket
done.

This is the minimum visual gate: it proves the types compile cleanly against the UI layer,
the status badge components accept the derived values, and the priority cascade produces the
correct color sequence on a realistic event stream.

## Execution mode

Autonomous. The protocol and event union are pure Swift value types and a protocol
definition — no process spawning, no file I/O beyond the fixture read in the integration
test, and no UI interaction required to verify correctness. The Logic suite is a table of
struct-in / enum-out assertions that run with `swift test`. The Backend integration test
reads a fixture JSONL from the test bundle — a local filesystem read, no network, no live
agent. The UX gate in the Component Lab is constructable with inline data and can be
visually verified in a single app launch with no interaction beyond opening the lab panel.
The combined check (logic table + fixture round-trip + Component Lab visual) fully proves
the protocol and event union correct and usable per the verification doctrine. No human
decision is needed during implementation; the dogfood snippet is a final smoke-check that
can be run once at the end.

## Done when

- [ ] All supporting enums (`AgentSessionState`, `TurnOutcome`, `ItemKind`, `ItemStatus`,
  `ApprovalKind`, `ApprovalDecision`, `ContentStreamKind`) exist in
  `Sources/ContinuumRevivedCore/AgentStatusEngine.swift` with `String` raw values,
  `Codable`, `Equatable`, `Sendable` conformances.
- [ ] All payload value types (`UserInputQuestion`, `TokenUsageSnapshot`, `AgentSession`,
  `AgentSessionStartInput`, `AgentSendTurnInput`, `AgentTurnStartResult`,
  `UserInputAnswers`) exist in the same file, `Equatable` and `Sendable`.
- [ ] `AgentRuntimeEvent` enum exists with exactly the 12 cases listed, `Codable` and
  `Sendable`, with stable string discriminators for each case.
- [ ] `AgentAdapter` protocol exists with all eight method/property requirements, `Sendable`.
- [ ] `deriveStatusSignals(from:threadId:engineStatus:)` free function exists in
  `AgentStatusEngine.swift`, pure (no Date(), no file I/O, no spawning).
- [ ] `AgentRuntimeEvent` `Codable` round-trip test passes for all 12 cases.
- [ ] `deriveStatusSignals` projection table test passes for all 12 rows.
- [ ] Cross-check assertions: `hasPendingApproval == true` + `isRunning == true` →
  `deriveAgentStatus` returns `.needsAttention`; `sessionStateChanged(.waiting)` →
  `isRunning == true`; `hookBreadcrumbPresent` always `false` from this function.
- [ ] Fixture file
  `ContinuumRevivedCoreTests/Fixtures/managed-session-with-approval.jsonl` exists with
  the 12-event sequence and the integration test reads, decodes, and asserts all five
  status transitions correctly.
- [ ] `swift test --filter AgentAdapterTests` passes with zero daemons and zero network.
- [ ] Component Lab "AgentAdapter Event Projection" fixture renders the 12-row sequence
  with correct badge colors: blue at row 3, orange at row 7, blue at row 9, green at row 11.
- [ ] `swift build` passes with zero errors and zero new warnings.
- [ ] No existing tests in `AgentStatusEngineTests` are broken or deleted.
- [ ] All body-carrying cases in `AgentRuntimeEvent` are annotated with `// [BODY]` in the
  source, per the I5 taint scan contract.

## Depends on / unblocks

This ticket depends on the closed `AgentKind` enum, specifically the `.managed` case used
in `AgentAdapter.providerKind`. It also depends on the pure status-derivation ticket, which
introduced `StatusSignals` and `deriveAgentStatus` — `deriveStatusSignals` calls
`deriveAgentStatus` and the field names of `StatusSignals` must be settled before the
projection function can be written.

It directly unblocks the four concrete adapter implementations: the ACP adapter (the first
managed-tier provider, covering Cursor and Grok with one integration), the Codex
`app-server` adapter (JSON-RPC over stdio), the Claude SDK sidecar adapter (driving the
headless Claude loop), and the OpenCode HTTP adapter. Each is a struct conforming to
`AgentAdapter`; none can be stubbed out or tested without the protocol in place. It also
unblocks the private managed-agent session record ticket, which stores `AgentSession`
values (the type introduced here) for resume. And it is a prerequisite for the managed
approval path, which calls `respondToRequest` and `respondToUserInput` — methods defined
here — in response to `requestOpened` events — a case defined here.

## Watch out for

**The single hardest thing to get right is thread-scoping in `deriveStatusSignals`.** Every
event in the `AgentRuntimeEvent` union carries a `threadId` (or an optional `threadId` for
`runtimeError`). The projection function receives events for all threads from a given
adapter and must accumulate state only for the queried `threadId`. A naive implementation
that forgets the `where tid == threadId` guard on switch cases will incorrectly count
approvals and completions from other threads, producing `hasPendingApproval == true` on a
thread that has no open requests. This is not a theoretical edge case: the ACP adapter
multiplexes multiple sessions onto one `events` stream (identical to how t3code's
`ProviderService` multiplexes multiple instances). The Logic test that passes a
`requestOpened` with a *different* threadId and asserts `hasPendingApproval == false` is
the specific tripwire for this bug.

**Do not store `AgentRuntimeEvent` values in `AgentDescriptor` or in any synced type.**
The event union contains body-carrying cases (`contentDelta`, `itemStarted.title`,
`runtimeError.message`). These must never appear in the synced spatial payload or the
projected activity tree payload. The correct pattern: accumulate events in a host-local
store (the managed-agent session record, a later ticket), derive `StatusSignals` from that
store, call `deriveAgentStatus`, and write only the resulting `AgentStatus` into
`AgentDescriptor.status`. The `AgentDescriptor` is what syncs (via the activity projection
— layer 1 only, as Decision E specifies); the raw events stay host-local. Crossing this
line violates I5 and will require a rework of the sync boundary.

**The `sessionStateChanged(.waiting)` → `isRunning = true` mapping is non-obvious.** The
`waiting` state in the adapter protocol means the agent session is alive but blocked on
input, rate limiting, or a tool handshake that has not yet produced an approval request.
It is explicitly not `isCompleted`. If you map it to anything other than `isRunning`, the
status derivation will drop to `.idle` during tool-call execution (when the Claude SDK is
waiting for a `canUseTool` callback to be answered, or when Codex is processing a
`requestApproval` server request before it has emitted the response). The test row
asserting `sessionStateChanged(.waiting)` → `isRunning == true` is the specific guard.

**`sendTurn` is a steer, not always a new turn.** The t3code source documents
(`ClaudeAdapter.ts:3648–3657`) that if a turn is already running when `sendTurn` is called,
the message is queued into the live agent loop rather than starting a new turn. This ticket
defines the method signature but not the behavior; the concrete adapter implementations
must respect this contract. Document it in the protocol's doc-comment on `sendTurn` so the
implementer does not assume a new `turnStarted` event always follows a `sendTurn` call.
