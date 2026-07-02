# Agent message-bus seam

> **Ruling C-20260701-009 (read before implementing):** where this ticket says `ActivityTreeSnapshot`
> meaning the **byTile fold read-model** (ticket 08's summary-per-tile snapshot), that type was renamed
> to **`ActivityLogSnapshot`**. The name `ActivityTreeSnapshot` now belongs to ticket 11's SidebarTree
> envelope. Use `ActivityLogSnapshot` for the fold read-model.

## What this delivers

By the time this ticket lands, Continuum has a named, typed, compilable stub for the app-level agent message bus described in Decision F of the architecture. No messages actually travel yet — no agent reads from this bus, no orchestration logic subscribes to it — but the vocabulary is locked into the codebase, the post/subscribe contract is expressed as a Swift protocol, and every future ticket that needs to route structured agent-to-agent messages has a concrete seam to build on rather than a blank page.

From the system's point of view: the bus is an `AgentMessageBus` protocol living in `ContinuumRevivedCore`, keyed off the runtime/session layer, with a matching `NullAgentMessageBus` no-op implementation that the app wires in at startup. The `AgentStatusEngine` gains an idle hook where a live bus can later be injected. `ZoneRuntimeController` holds a `bus` property of protocol type, wired to the null impl today, ready to receive the real impl without a call-site change.

## How it fits

This ticket is the last in the build plan — Phase 8 — and is deliberately deferred. The architecture names the seam explicitly under Decision F: "when it comes, it is an app-level message bus keyed off the session/runtime layer — agents post structured messages, tiles and agents subscribe, with the activity tree providing 'who is doing what.' It is never built on screen-scraping. This program names the seam and stops there." That is the exact scope of this ticket.

It builds on two upstream foundations that must be real before the seam makes sense. The session observer (the `SessionObserver` with budgets, Phase 3) is the live, per-project observer that knows which tile is running which agent and what state it is in. The activity tree snapshot (Phase 0's `ActivityTreeSnapshot` type) is the structured view of the whole fleet that any subscriber would need to navigate "who else is running and what are they doing." Both of those are upstream; this ticket depends on them being present and imports neither new concept nor new complexity — it simply names where structured inter-agent messages will eventually enter the system.

What this ticket directly unblocks is future agent-to-agent coordination: a managed agent that wants to delegate a subtask, a tile that wants to broadcast a progress event others can react to, or an orchestration layer that wants to fan out work across several tiles. None of those features are built here, but they all need a bus protocol to attach to, and that protocol is what this ticket produces.

## The approach

Define a narrow `AgentMessageBus` protocol in `ContinuumRevivedCore` expressing two operations: post a structured message (fire-and-forget from the sender's perspective) and subscribe to messages matching a predicate (returns a cancellable token). Define the structured message type — `AgentBusMessage` — as a Swift struct carrying a sender tile id, a typed payload (a closed enum of the message kinds the architecture anticipates), and a logical timestamp. Provide a `NullAgentMessageBus` that implements the protocol with no-op stubs. Wire `NullAgentMessageBus` into `ZoneRuntimeController` as a stored property of protocol type. Add an accessor on `AgentStatusEngine` that a future bus subscriber can call to deliver an inbound message that updates status — the accessor is present but the bus never calls it yet.

No Combine publishers, no actor isolation changes, no persistence, no network, no cross-process channel. The protocol surface is intentionally small: if post and subscribe are the right two verbs, a real implementation slips in without touching callers. If the real implementation needs more (e.g., a reply channel for synchronous request-response), that is an additive extension on top of this seam, not a reason to overdesign now.

The message payload enum starts with three cases that the architecture already anticipates needing: `.attentionChanged(tileId: UUID, status: AgentStatus)` (the bus equivalent of the status derivation output), `.progressNote(text: String)` (an agent broadcasting a human-readable progress update), and `.delegateTask(description: String, replyTo: UUID)` (the embryo of agent-to-agent delegation). These cases are stubs — they compile and are exhaustively switchable, but nothing produces or consumes them yet. This is enough to make the vocabulary concrete without guessing at a full schema.

The approach is deliberately not built on screen-scraping. The payload carries structured Swift values derived from the session/runtime layer; it has no terminal-output strings, no PTY bytes, and no parsed terminal escape sequences. This is the "never screen-scraping" constraint from Decision F, enforced by the type: nothing in `AgentBusMessage` is `String` except the human-readable progress note, and that is an output from the agent's own logic, not an input from a terminal scraper.

## Where it lives

**`Sources/ContinuumRevivedCore/AgentMessageBus.swift`** (new file)
- `public protocol AgentMessageBus: AnyObject` — the post/subscribe contract
- `public struct AgentBusMessage: Sendable` — sender, payload enum, Lamport clock value
- `public enum AgentBusPayload: Sendable` — the three stub cases above
- `public final class NullAgentMessageBus: AgentMessageBus` — no-op implementation

**`Sources/ContinuumRevivedCore/AgentStatusEngine.swift`** (existing file, line 3)
- Add `public mutating func ingestBusMessage(_ message: AgentBusMessage, at now: Date = Date()) -> AgentStatus` — currently routes to `ingest(.explicit(…))` only for `.attentionChanged` matching this engine's tile; all other cases are no-ops. This is the hook a live bus will call.

**`Sources/ContinuumRevived/App/ZoneRuntimeController.swift`** (existing file, line 6)
- Add `var agentBus: any AgentMessageBus = NullAgentMessageBus()` as a stored property on `ZoneRuntimeController`. No other code in the controller reads from it yet; the property is the injection point.

No other files change. The `agentKind` closed enum and the `AgentStatus` type (both already in `ContinuumRevivedCore`) are referenced by `AgentBusPayload` without modification.

## Implementation breadcrumbs

```swift
// AgentMessageBus.swift — ContinuumRevivedCore

public struct AgentBusMessage: Sendable {
    public let senderTileId: UUID
    public let logicalTime: UInt64   // Lamport clock value; use the op-log's clock
    public let payload: AgentBusPayload
}

public enum AgentBusPayload: Sendable {
    case attentionChanged(tileId: UUID, status: AgentStatus)
    case progressNote(text: String)
    case delegateTask(description: String, replyTo: UUID)
}

public protocol AgentMessageBus: AnyObject {
    /// Post a message to all current subscribers. Returns immediately.
    func post(_ message: AgentBusMessage)

    /// Subscribe to messages. The handler is called on an unspecified queue;
    /// callers must dispatch if they need a specific context.
    /// Returns a cancel token: retain it while the subscription should be live.
    @discardableResult
    func subscribe(handler: @escaping (AgentBusMessage) -> Void) -> AnyCancellable
}

public final class NullAgentMessageBus: AgentMessageBus {
    public init() {}
    public func post(_ message: AgentBusMessage) {}   // intentional no-op
    public func subscribe(handler: @escaping (AgentBusMessage) -> Void) -> AnyCancellable {
        AnyCancellable {}   // immediately-cancelled; handler is never called
    }
}
```

```swift
// AgentStatusEngine.swift — add alongside the existing `ingest` method

public mutating func ingestBusMessage(_ message: AgentBusMessage, at now: Date = Date()) -> AgentStatus {
    switch message.payload {
    case .attentionChanged(_, let status):
        // Route bus-delivered attention changes through the explicit signal path.
        return ingest(.explicit(status), at: now)
    case .progressNote, .delegateTask:
        // Not yet consumed by the status engine; future cases extend here.
        return self.status
    }
}
```

```swift
// ZoneRuntimeController.swift — add one stored property

var agentBus: any AgentMessageBus = NullAgentMessageBus()
```

The `AnyCancellable` type is from `Combine`, which `ContinuumRevivedCore` already imports indirectly through its existing use of `PassthroughSubject` in the observer stack. If a direct import is needed, add `import Combine` to the new file only. Do not introduce any new framework dependency beyond that.

The `logicalTime: UInt64` field on `AgentBusMessage` reuses the Lamport clock concept from the op-log core (Phase 0's op-log apply and compaction work), but does not import or depend on the op-log types directly — it carries only the counter value as a plain integer. If the op-log later exposes a shared `LogicalClock` type, the bus message can adopt it; for now a bare `UInt64` is sufficient and avoids creating a dependency from the bus seam onto the sync layer.

## How we test it

### Logic (pure Core checks)

Three pure checks, no daemon, no filesystem, no real clock:

1. **Null bus never delivers.** Create a `NullAgentMessageBus`. Subscribe with a handler that records calls. Post an `AgentBusMessage`. Assert the handler was never called. This proves the null implementation is a genuine no-op and the subscription token holds no strong reference to the handler after cancellation.

2. **Status engine routes attention from bus.** Create an `AgentStatusEngine` seeded with `idle`. Construct an `AgentBusMessage` with `payload: .attentionChanged(tileId: someId, status: .needsAttention)`. Call `ingestBusMessage`. Assert the returned status and `engine.status` are both `.needsAttention`. Then send `payload: .progressNote(text: "foo")` and assert status is unchanged (the engine ignores it). This proves `ingestBusMessage` correctly delegates to `ingest(.explicit(…))` for the one case it handles and is a no-op for others.

3. **Message round-trips through Codable.** Encode an `AgentBusMessage` (all three payload variants) to JSON and decode back; assert equality. This proves the struct is safely serializable for future transport use, and that no payload case drops fields or coerces types.

### Backend (real-path / integration)

One real-path check against the actual `ZoneRuntimeController` initialization path — no fake controller, no bypassed lifecycle:

**Bus property is present and injectable.** Launch a `ZoneRuntimeController` through its real `init(root:acquireLock:)` (using a temp directory, `acquireLock: false`). Assert `controller.agentBus is NullAgentMessageBus`. Then assign a `MockAgentMessageBus` (a test double that records posts) to `controller.agentBus`. Call `controller.agentBus.post(testMessage)`. Assert the mock recorded exactly one call with the expected message. This proves the injection point is wired and the property type admits the protocol without a downcast.

The `MockAgentMessageBus` for this check is a simple test-only class in the test target: it stores received messages in an array and calls all registered handlers synchronously. It is not production code.

### UX (visual gate + dogfood snippet)

This ticket ships no visible UI — the seam is internal plumbing with a null implementation. There is no dogfood snippet in the traditional sense because no user action surfaces the bus. The visual gate is therefore a build gate, not a visual inspection: the project must compile cleanly on the `feature/component-lab` branch with zero new warnings from the three new/modified files. The CI matrix check (macOS + Swift 5.10) is the gate; it is non-degenerate because it will fail if the `AgentMessageBus` protocol is unsatisfied, if `ZoneRuntimeController` introduces a type error at the bus property, or if `AgentStatusEngine` breaks any existing test by the addition of the new method.

A concrete dogfood step for a human reviewer: open the project in Xcode, navigate to `ZoneRuntimeController.swift`, and confirm the `agentBus` property appears in the Quick Help inspector with the type `any AgentMessageBus`. This is a 10-second check and proves the property is visible and correctly typed — not compiled away or made `private`.

## Execution mode

Autonomous. Every correctness claim this ticket makes — null bus is a no-op, status engine routes attention correctly, message is Codable, bus property accepts injection — is proven by pure Core logic checks and a real-path `ZoneRuntimeController` instantiation check, neither of which requires human eyes, visual inspection, a real agent, a running tmux daemon, or any cloud resource. The build-gate visual check is simple enough that the matrix result alone is a sufficient gate; no dogfood run is needed to prove a null implementation works.

## Done when

- [ ] `Sources/ContinuumRevivedCore/AgentMessageBus.swift` exists and is committed, containing `AgentMessageBus` protocol, `AgentBusMessage` struct, `AgentBusPayload` enum with the three stub cases, and `NullAgentMessageBus` class.
- [ ] `AgentStatusEngine.ingestBusMessage(_:at:)` is present in `AgentStatusEngine.swift` and correctly routes `.attentionChanged` to `ingest(.explicit(…))` while returning `self.status` unchanged for all other payload cases.
- [ ] `ZoneRuntimeController.agentBus` is a stored `var` of type `any AgentMessageBus`, default-initialized to `NullAgentMessageBus()`.
- [ ] All three Logic checks pass (null bus no-op, status routing, Codable round-trip).
- [ ] The Backend real-path check passes against a real `ZoneRuntimeController` init.
- [ ] The project builds cleanly on the CI matrix with zero new warnings in the three touched files.
- [ ] No existing test in the test suite regresses.
- [ ] No production code calls `post` or `subscribe` on the bus (the null impl is the only live wiring; a grep for `agentBus.post` and `agentBus.subscribe` in `Sources/ContinuumRevived` returns zero hits other than the property declaration itself).

## Depends on / unblocks

This ticket depends on the session observer with budgets being in place and stable — not because the bus calls the observer, but because the bus's eventual real implementation will route messages through the observer's tile-id namespace, and the session state that makes tile ids meaningful must be real before that step is coherent. It also depends on the activity tree snapshot type being present, for the same reason: any subscriber that wants to act on a message needs to know what the rest of the fleet is doing, and that snapshot is how it asks.

What this ticket unblocks is everything in the eventual agent-to-agent coordination layer — any feature where a tile posts a message that another tile or orchestration component reacts to. The `AgentMessageBus` protocol becomes the stable API those features compile against; as long as this seam is in place, the real implementation can be introduced behind the same protocol without touching call sites. It also unblocks a future managed-tier feature where a managed agent's ACP adapter posts a `.delegateTask` message to spin up a subordinate tile — that feature needs exactly the payload vocabulary and the injection point this ticket provides.

## Watch out for

**The `AnyCancellable` import.** `ContinuumRevivedCore` is a library target. If Combine is not already an explicit import in the module map, adding it is a one-line change to the module's Swift sources — but the implementer must verify it does not drag in AppKit symbols that would break the core's platform-agnostic build. Run `xcodebuild` for the `ContinuumRevivedCore` scheme in isolation before assuming the import is clean.

**Null impl must be genuinely inert.** The risk in a no-op implementation is that it looks like it works because nothing complains — including the logic check. Write the null-bus test as a strict assertion that the handler count is exactly zero after a post, not merely "no crash." A null bus that silently queues messages and leaks them would pass a crash-free check but would be a memory issue in a long-running workspace session.

**Do not overdesign the payload enum.** The three cases are exactly what the architecture anticipates at this stage; resist adding cases not named in the grounding docs. The enum is `closed` intentionally — future cases are additive (new enum case + new handler branch in `ingestBusMessage`). Adding a `.broadcast(any Sendable)` escape hatch now to avoid the closed-enum discipline would undo the type-safety rationale for a closed enum in the first place.

**Lamport clock value must not be wall-clock.** The `logicalTime: UInt64` field is a Lamport counter, not a Unix timestamp. If the implementer reaches for `Date().timeIntervalSince1970` to populate it, the bus message ordering will be wall-clock-sensitive and will break under the same conditions that make wall-clock sync ordering unreliable. Populate it with a monotonically incrementing counter maintained by the bus (even the null bus can vend a counter for test purposes; it just never delivers anything). The invariant spine's prohibition on wall-clock ordering (enforced in the op-log and the sync layer) applies equally here.

**Do not wire the null bus into the `SessionObserver`.** The observer already has its own output path (the activity tree and the `AgentStatus` derivation function). The bus is a peer channel for agent-to-agent messages, not a replacement for the observer's output. Injecting the bus into the observer at this phase would conflate two separate paths and make it harder to swap either one independently. The bus property lives on `ZoneRuntimeController`; the observer is a different owned object on the same controller and does not reference the bus property.
