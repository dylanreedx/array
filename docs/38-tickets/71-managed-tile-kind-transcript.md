# `.managedAgent` tile kind and the structured transcript view

## What this delivers

After this ticket lands, Continuum has a second tile kind — `.managedAgent` — that renders a vertically-scrolling, card-based structured transcript alongside a persistent status header. The view is a real AppKit component: message cards accumulate streaming text with a live shimmer while the agent is working, tool-call cards collapse to a single-line summary with an expand arrow, a plan card updates in place as the turn progresses, and a diff card shows file-change summaries without duplicating the diff-review tile's functionality. The status header is always visible above the card list and carries the agent name, status glyph, phase label, and an elapsed timer that ticks while the agent works.

The tile reads as "an app view, not a terminal" at any zoom level. At thumbnail scale — the zoom level where a user glances across the fleet — the card layout and padded background distinguish it instantly from the dense monospaced grid of a `.terminal` tile. That visual distance is the deliberate, design-specified signal that tells a user whether a tile is being driven headlessly or observed as a shell process.

The canonical event type (`AgentRuntimeEvent`) is defined here, directly porting the status-driving subset of t3code's `ProviderRuntimeEvent` union into Swift. The managed tile's event sink receives this stream from the ACP driver (ticket 69), routes it through the pure status-derivation function (ticket 32), and reflects the derived `AgentStatus` in the header and in `AgentDescriptor.status` so the sidebar and zone rollup light up from the same observer read path every other tile uses.

This ticket does not touch `.terminal`. Shell tiles continue to be observed via readers; the new view is entirely additive. Every line of existing terminal, ghostty, and session-descriptor code is left exactly as it stands.

## How it fits

This ticket is the visual culmination of the managed tier. The pure status-derivation function (ticket 32) already exists and is proven by the golden table (ticket 33). The closed `AgentKind` enum (ticket 31) already carries `.managed` as a first-class case. The approvals-to-`needsAttention` work (ticket 70) has already established the `AgentApprovalRequest` pending store and the `respondToApproval` respond command. The ACP driver (ticket 69) is the live source of `AgentRuntimeEvent` values this view consumes.

What this ticket provides to everything that follows is a verified, snapshottable view surface the approval dock and attention border (ticket 72) can attach to, and a correct card renderer the waiting-for-input card (ticket 73) can extend with an answer field. The iOS observer (ticket 61) renders a read-only version of this same card taxonomy over the activity projection — the card type definitions established here are the structural contract that projection must carry.

The Component Lab is the home for the initial design pass. The view is built and iterated against a scripted fixture transcript first, before any live adapter is wired. This is the specified sequencing from the UX analysis: the card layout, the three reading states (working / waiting / done), and the approval dock's slide-up behavior are all designed and visually gated without a real agent running.

## The approach

A new `ManagedAgentTileNSView` subclasses `TileNSView` (matching the pattern established by `NoteTileNSView`, `FileTileNSView`, and the others in the sandbox). It owns a vertically-scrolling `NSScrollView` containing a single `NSStackView` that vends card views — one `NSView` subclass per card kind. Cards are appended to the bottom of the stack as events arrive; they are never reordered. A `content.delta` event finds the last assistant message card and appends text; it does not create a new card per delta. Tool-call cards are created on `item.started` and mutated in place on `item.completed`. The plan card is created on the first `turn.plan.updated` and its checklist updated on subsequent events. The diff card is created on `turn.diff.updated` and shows a compact file-change summary, not the full diff.

The status header is a fixed-height `NSView` pinned to the top of the tile, outside the scroll view. It contains the status glyph, agent name label, phase-text label, and elapsed timer. The glyph and phase text are driven directly from `AgentDescriptor.status` via the same `glyph(for:)` and `color(for:)` helpers the sidebar uses. The elapsed timer is a `CADisplayLink`-backed counter that starts on the first `turnStarted` event and pauses on `turnCompleted` or `sessionStateChanged(.stopped)`.

The `AgentRuntimeEvent` enum is a new type in `ContinuumRevivedCore`. It carries the status-driving subset of the 47-variant `ProviderRuntimeEvent` union: `sessionStateChanged`, `turnStarted`, `turnCompleted`, `itemStarted`, `itemCompleted`, `contentDelta`, `requestOpened`, `requestResolved`, `userInputRequested`, `tokenUsageUpdated`, and `runtimeError`. Additional variants are added by later tickets as needed; the enum is defined here because the derivation function and the tile view both need it, and neither should define it alone.

The `ManagedAgentSession` — the host-local record introduced in ticket 23 — gains an `events: AsyncStream<AgentRuntimeEvent>` property. The tile's `NSViewController`-equivalent layer subscribes to this stream on init, dispatches events on the main actor, and feeds both the status-header update path and the card-list append path. The subscription is torn down on `deinit`. No polling; no timers on the data path.

`TileKind` gains a `.managedAgent` case in `CanvasState.swift:67`. The canvas and spawner switch exhaustively on `TileKind`, so every switch site gets a compile-time gap when `.managedAgent` is added — each needs a concrete handler. In `CanvasNSView`, the tile-view factory switch returns a `ManagedAgentTileNSView` for `.managedAgent`. The sandbox spawn path and the Lab fixture path both get a `.managedAgent` option in this ticket, because the visual gate requires it.

The approval dock is deliberately left as a stub in this ticket — a zero-height view anchored to the tile bottom with no content. Ticket 72 fills it in. This keeps the boundary clean: this ticket owns card rendering and the status header; ticket 72 owns the dock and the orange attention border.

## Where it lives

**New files:**

- `Sources/ContinuumRevivedCore/AgentRuntimeEvent.swift` — `AgentRuntimeEvent` enum (the 11 status-driving variants), `ItemKind` (porting `CanonicalItemType`: `command_execution | file_change | mcp_tool_call | web_search | assistant_message | reasoning | plan | error`), `ItemStatus` (`inProgress | completed | failed | declined`), `SessionState` (`starting | ready | running | waiting | stopped | error`), `TurnOutcome` (`completed | failed | interrupted | cancelled`), `ApprovalKind` (porting `CanonicalRequestType`: `command_execution_approval | apply_patch_approval | tool_user_input`), `UserInputQuestion` (label + placeholder string pair), `TokenUsageSnapshot` (inputTokens / outputTokens / totalCostUsd)

- `Sources/ContinuumRevived/Canvas/ManagedAgentTileNSView.swift` — the tile view: status header, scroll view containing the card stack, stub approval dock anchor; subscribes to `ManagedAgentSession.events`

- `Sources/ContinuumRevived/Canvas/TranscriptCardViews.swift` — `MessageCardView` (user + assistant variants, streaming text append), `ToolCallCardView` (collapsed summary + expand toggle), `PlanCardView` (checklist that updates in place), `DiffCardView` (compact file-change summary)

**Modified files:**

- `Sources/ContinuumRevivedCore/CanvasState.swift:67` — add `.managedAgent` case to `TileKind`

- `Sources/ContinuumRevived/Canvas/CanvasNSView.swift` — tile-view factory switch: add `case .managedAgent` returning `ManagedAgentTileNSView(tile:session:)`. The switch that routes tile kinds to views is currently near the tile-install path; grep for the `case .terminal` arm to find the exact line.

- `Sources/ContinuumRevived/App/ComponentLab.swift:354` — `LabCatalog.entries(env:)`: add `managedAgentCard` entry under the "Tiles" category. Add `LabFixtures.managedAgentFixtureSession()` returning a canned `ManagedAgentSession` seeded with a scripted event sequence: two message cards (user + streaming assistant), one completed tool-call card (`command_execution`, title "npm test", duration 1.2s), one in-progress tool-call card (`file_change`, title "src/auth.ts"), and a pending `requestOpened` with kind `command_execution_approval`. The fixture toolbar provides "Fire approval" and "Complete turn" buttons that push additional events into the fixture session's continuation.

**Existing seams this ticket reads and must not break:**

- `Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift:85` — `AgentStatus` (six cases), `AgentDescriptor` (including `.status`). The managed tile writes back to `AgentDescriptor.status` after every derivation call, via the same path the readers use, so the sidebar and zone rollup pick it up without knowing the source.

- `Sources/ContinuumRevivedCore/SidebarTree.swift:3` — `SidebarAgentStatusKind.kind(for:)` and `SidebarAgentStatusRollup.dominantKind` are the rollup machinery. They continue to work unchanged because the managed tile updates `AgentDescriptor.status` and the sidebar reads that field.

- `Sources/ContinuumRevived/Canvas/CanvasNSView.swift:696` — `applyFocusBorder()` and `FocusBorderOverlayView` at `:5029`. This ticket does not add the attention variant yet (that is ticket 72). It must leave the existing focus-border path unmolested.

- `Sources/ContinuumRevived/App/ComponentLab.swift:711` — `runSelfCheck()`. The `managed-agent` Lab entry must be reachable and must return a `.staticCard` so the self-check's bitmap loop includes it and asserts non-blank. The fixture toolbar buttons are `.canvasSandbox`-style interactive controls within the card host and do not break the staticCard snapshot path.

## Implementation breadcrumbs

```swift
// AgentRuntimeEvent.swift — the canonical event union (status-driving subset)
public enum AgentRuntimeEvent: Sendable {
    case sessionStateChanged(SessionState)
    case turnStarted(turnId: String)
    case turnCompleted(turnId: String, outcome: TurnOutcome, errorMessage: String?)
    case itemStarted(itemId: String, kind: ItemKind, title: String?)
    case itemCompleted(itemId: String, kind: ItemKind, status: ItemStatus, durationSeconds: Double?)
    case contentDelta(streamKind: StreamKind, delta: String)   // body — never crosses sync boundary (I5)
    case requestOpened(requestId: String, kind: ApprovalKind, detail: String)
    case requestResolved(requestId: String, decision: String)
    case userInputRequested(requestId: String, questions: [UserInputQuestion])
    case tokenUsageUpdated(TokenUsageSnapshot)
    case runtimeError(message: String)
}

public enum StreamKind: Sendable { case assistant, reasoning, commandOutput }
```

```swift
// ManagedAgentTileNSView.swift — wire the event stream to header + cards
@MainActor final class ManagedAgentTileNSView: TileNSView {
    private let headerView: ManagedAgentStatusHeader   // glyph + name + phase + timer
    private let scrollView: NSScrollView
    private let cardStack: NSStackView                 // .vertical, spacing: 8
    private let approvalDockAnchor: NSView             // zero height until ticket 72

    private var session: ManagedAgentSession
    private var eventTask: Task<Void, Never>?

    // card tracking — keyed by itemId / turnId
    private var activeTool: [String: ToolCallCardView] = [:]
    private var lastAssistantCard: MessageCardView?
    private var planCard: PlanCardView?

    init(tile: Tile, session: ManagedAgentSession) {
        self.session = session
        // ... build layout
        super.init(tile: tile)
        startEventLoop()
    }

    private func startEventLoop() {
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.session.events {
                await MainActor.run { self.ingest(event) }
            }
        }
    }

    private func ingest(_ event: AgentRuntimeEvent) {
        // 1. Derive status (pure function — does not touch UI)
        let newStatus = deriveAgentStatus(signals: session.currentSignals())
        // 2. Update the header
        headerView.apply(status: newStatus, agentName: tile.title, elapsed: session.elapsed)
        // 3. Write back so sidebar/rollup see it
        session.updateStatus(newStatus)
        // 4. Append/mutate the appropriate card
        switch event {
        case .contentDelta(let streamKind, let delta) where streamKind == .assistant:
            if let card = lastAssistantCard { card.append(delta) }
            else {
                let card = MessageCardView(role: .assistant, initialText: delta)
                lastAssistantCard = card
                cardStack.addArrangedSubview(card)
            }
        case .itemStarted(let id, let kind, let title):
            let card = ToolCallCardView(kind: kind, title: title, status: .inProgress)
            activeTool[id] = card
            cardStack.addArrangedSubview(card)
        case .itemCompleted(let id, _, let status, let duration):
            activeTool[id]?.complete(status: status, duration: duration)
            activeTool.removeValue(forKey: id)
        case .turnCompleted:
            headerView.stopTimer()
            lastAssistantCard = nil
        case .requestOpened, .userInputRequested:
            // stub dock expansion — ticket 72 fills this in
            break
        default: break
        }
        // 5. Scroll to bottom if the user has not scrolled up
        if !userHasScrolledUp { scrollToBottom() }
    }
}
```

```swift
// LabFixtures extension — scripted fixture session for the Lab entry
extension LabFixtures {
    @MainActor static func managedAgentFixtureSession() -> ManagedAgentSession {
        // Returns a session whose events continuation is held by the fixture.
        // The Lab entry's toolbar buttons push additional events into it:
        //   "Fire approval" → push .requestOpened(requestId: "r1", kind: .command_execution_approval,
        //                                          detail: "Run command: npm test")
        //   "Complete turn" → push .turnCompleted(turnId: "t1", outcome: .completed, errorMessage: nil)
        //   "Reset"         → create a fresh session and reload the tile view
        let (stream, continuation) = AsyncStream<AgentRuntimeEvent>.makeStream()
        let session = ManagedAgentSession(tileId: UUID(), events: stream, continuation: continuation)
        // Seed the initial transcript synchronously
        continuation.yield(.sessionStateChanged(.running))
        continuation.yield(.turnStarted(turnId: "t1"))
        continuation.yield(.contentDelta(streamKind: .assistant, delta: "I'll read the current guard, then refactor it to be idempotent."))
        continuation.yield(.itemStarted(itemId: "i1", kind: .command_execution, title: "npm test"))
        continuation.yield(.itemCompleted(itemId: "i1", kind: .command_execution, status: .completed, durationSeconds: 1.2))
        continuation.yield(.itemStarted(itemId: "i2", kind: .file_change, title: "src/auth.ts"))
        // i2 left in-progress so the Lab shows an active card
        return session
    }
}
```

```swift
// LabCatalog extension — the new entry
private static var managedAgentCard: LabEntry {
    LabEntry(
        id: "tiles.managedAgent",
        category: "Tiles",
        title: "Managed Agent Tile",
        summary: "Card-based structured transcript — message, tool-call, plan, diff cards + status header.",
        content: .staticCard(preferredSize: NSSize(width: 560, height: 560)) {
            let session = LabFixtures.managedAgentFixtureSession()
            let tile = LabFixtures.tile(kind: .managedAgent, title: "Claude · feature/login")
            let view = ManagedAgentTileNSView(tile: tile, session: session)
            view.frame = NSRect(x: 0, y: 0, width: 560, height: 560)
            return view
        }
    )
}
```

```swift
// deriveAgentStatus integration — the managed tile calls this after every event
// (already proven by the golden table in ticket 33; managed signals include hasPendingApprovals)
func deriveAgentStatus(signals: StatusSignals) -> AgentStatus {
    if signals.hasPendingApprovals || signals.hasPendingUserInput { return .needsAttention }
    switch signals.sessionState {
    case .starting:  return .configuring
    case .running:   return .working
    case .stopped, .error:
        return signals.lastTurnOutcome == .completed ? .done : .idle
    default:
        return signals.lastTurnOutcome == .completed ? .done : .idle
    }
}
// Note: this function already exists from ticket 32. The managed tile calls it;
// it does not reimplement it.
```

## How we test it

### Logic (pure Core checks)

The event-to-card mapping is pure: given a sequence of `AgentRuntimeEvent` values, the resulting card list has a deterministic shape. Write a table-driven Core check that replays the fixture event sequence through a `ManagedAgentTranscriptModel` (a pure, `@MainActor`-free value type extracted from `ManagedAgentTileNSView`) and asserts the card count, each card's kind and title, the final `lastAssistantCard` text, and the active-tool map. This is the structural analog of the reader golden fixture checks (ticket 39).

Separately, assert that the managed derivation path satisfies invariant I6: a `StatusSignals` with `hasPendingApprovals = true` and `sessionState = .running` must derive `.needsAttention`, not `.working`. This is a single-line addition to the golden table from ticket 33 — add the managed-approval row there rather than in a new file.

Assert I5 for the event type itself: `AgentRuntimeEvent` must not conform to any sync-layer protocol (the taint scan from ticket 9 will catch this at the type level if `AgentRuntimeEvent` is inadvertently added to a synced payload). Confirm the `ManagedAgentSession.updateStatus(_:)` write-back path touches only `AgentDescriptor.status`, never a `contentDelta` body or tool arg string.

### Backend (real-path, not bypassed)

Build a real-path check that feeds events through the view's actual `ingest(_:)` path — not by calling `ManagedAgentTranscriptModel` directly. The path is: create a `ManagedAgentSession` with a live `AsyncStream` continuation, instantiate a `ManagedAgentTileNSView` against it, install the view in a headless `NSWindow`, push a sequence of events through the continuation on the main actor, wait for the run loop to drain (one `RunLoop.main.run(until:)` tick is sufficient for the card-append path), then inspect the `cardStack.arrangedSubviews` count and the header's current glyph label.

The manifest written to `qa-runs/<ts>/managed-agent-transcript/manifest.json` must carry: `cardCount` (integer, expected 3 for the fixture sequence above), `headerStatus` (string, expected `"working"`), `activeToolCount` (integer, expected 1), and `derivedStatusAfterApproval` (string, expected `"needsAttention"` after pushing a `requestOpened` event through the continuation).

Push a `requestOpened` event and assert the manifest captures the `needsAttention` transition — this exercises the full event → derivation → header-update path with a real `NSView` in the loop, matching the verification doctrine's requirement for a real-path check driving the true event path rather than a model-only assertion.

### UX (visual gate + dogfood snippet)

The Component Lab self-check (`ComponentLab.runSelfCheck()` at `ComponentLab.swift:711`) already bitmaps every `.staticCard` entry and asserts non-blank via `VisualSnapshot.metrics`. Adding the `managedAgent` entry to `LabCatalog.entries(env:)` automatically gates it. The assertions to add are:

1. The `tiles.managedAgent` entry is present in the catalog (join the existing launcher-presence checks at line 724).
2. The bitmap for `tiles.managedAgent.png` passes `!metrics.isBlank` — at 560×560 with a dark backdrop, the card chrome (header, card outlines, glyph, text) must produce more than one distinct sampled color. The Tier-1 gate from the verification doctrine (docs/26) requires `distinctSampledColors >= 3` as the non-degenerate threshold for this surface; a pure-white or pure-grey render means a card failed to draw.

**Dogfood snippet:**

Open the app → press `⌃Space` to open the command palette, type "Component Lab", press Return → in the left nav, click "Tiles" to expand it → click "Managed Agent Tile." The right pane shows the structured transcript: a status header reading `● Claude · feature/login [working · 0s]` in the accent blue, below it two cards (an assistant message card reading "I'll read the current guard, then refactor it to be idempotent." and a collapsed green-checkmark tool-call card reading "✓ npm test  0.2s"), and an in-progress blue-pulse tool-call card reading "● file_change  src/auth.ts" at the bottom.

Click the "Fire approval" toolbar button in the Lab fixture controls → see exactly: the header glyph change from blue `●` to orange `◆` and the label change to `needs you`. The approval dock stub at the bottom of the tile gains a one-line placeholder text "Approval dock — ticket 72" in muted gray (confirming the dock anchor is wired even though it has no content yet). Click "Complete turn" → the header settles to green `✓`, the timer shows a static duration, and the in-progress tool-call card updates to `✓ file_change  src/auth.ts  done`.

## Execution mode

Supervised — because the primary deliverable is a rendered view that must be visually inspected through the Component Lab and dogfooded by hand. The card layout, header typography, glyph colors, streaming text shimmer, and reading-state transitions are all rendered pixels that only a human eye can verify as correct. The real-path check and the bitmap non-blank gate are necessary but not sufficient: a card that is technically non-blank but has the wrong padding, illegible text, or misaligned glyph still fails, and that failure only surfaces in the dogfood pass. The three-part UX contract from the UX analysis requires the dogfood snippet to be executed; the matrix cannot replace it.

## Done when

- [ ] `TileKind.managedAgent` compiles and the `CaseIterable` conformance lists it; every switch on `TileKind` in the codebase has an explicit `case .managedAgent` arm (no `default` silently swallowing it).
- [ ] `AgentRuntimeEvent.swift` exists in `ContinuumRevivedCore` with the 11 variants above; the type is `Sendable`, not `Codable`, and carries no conformance to any sync-layer protocol.
- [ ] `ManagedAgentTileNSView` renders in the Component Lab with the fixture sequence producing at least three distinct card views; `ComponentLab.runSelfCheck()` passes including the `tiles.managedAgent` entry without a blank-render failure.
- [ ] The status header updates from `working` (blue `●`) to `needsAttention` (orange `◆`) when a `requestOpened` event is pushed through the fixture continuation; the real-path check manifest confirms `derivedStatusAfterApproval == "needsAttention"`.
- [ ] `AgentDescriptor.status` is updated by the managed tile's write-back path and is readable by the sidebar's existing `SidebarTreeBuilder` without any modification to `SidebarTree.swift`.
- [ ] No line of `TerminalSessionDescriptor.swift`, the ghostty surface, or any `.terminal` code path is modified.
- [ ] The I5 taint scan (ticket 9) passes: `AgentRuntimeEvent` does not appear in any synced or projected payload type.
- [ ] The golden table (ticket 33) has a row confirming `hasPendingApprovals=true + sessionState=.running → .needsAttention` for the managed derivation path.
- [ ] The dogfood snippet above produces the exact described visual output — blue working header, orange attention flip on "Fire approval," green settled header on "Complete turn."

## Depends on / unblocks

This ticket requires the pure status-derivation function (ticket 32) and its golden table companion (ticket 33) to exist and pass, because the managed tile calls `deriveAgentStatus` on every event and the golden table must cover the managed-approval row before this ticket is considered done. The closed `AgentKind` enum (ticket 31) must be in place because `ManagedAgentSession` stores its `agentKind` as `AgentKind.managed`, not a free string. The private managed-agent session record (ticket 23) is the home for `ManagedAgentSession`; its structure is defined there and this ticket populates its `events` stream. The ACP driver (ticket 69) is the runtime source of events that this tile will consume in production, though the ticket itself is proven against the fixture stream.

What this ticket directly unblocks is the approval dock and attention border (ticket 72), which needs a `ManagedAgentTileNSView` to attach the dock to and a wired `requestOpened` event path to trigger the dock's slide-up animation. The waiting-for-input card (ticket 73) similarly depends on the card renderer established here. The iOS observer (ticket 61) references the card taxonomy by name — the type definitions in `AgentRuntimeEvent.swift` are the structural contract the activity projection carries for transcript rendering on the phone.

## Watch out for

**The hardest thing to get right is the I5 boundary.** The `AgentRuntimeEvent` enum carries transcript bodies — `contentDelta` text, tool call titles, command strings in `requestOpened.detail`. These must never cross the sync boundary. The temptation is to derive an `ActivityTreeSnapshot` field from the event stream and include card content in it; resist this entirely. The projection carries only the derived `AgentStatus` and sanitized metadata (phase label, headline, detail ≤160 chars with failure text redacted — exactly t3's `sanitizeRelayAgentActivityState`). If the taint scan (ticket 9) is run after this ticket lands and passes, the I5 line is held; if it fails, stop and fix before shipping.

**Status write-back must go through the derivation function, never be set directly.** Setting `AgentDescriptor.status = .needsAttention` from inside a `requestOpened` handler without calling `deriveAgentStatus(signals:)` first violates I6 and breaks the priority ladder. The derivation function is the one path; it takes `StatusSignals` including `hasPendingApprovals` and returns the correct status. Only the derivation function's output should be written to `AgentDescriptor.status`.

**The approval dock stub must be zero height and zero interaction.** The tick-72 dock is not just visual — it owns the `respondToApproval` call. Stubbing it with any partial implementation risks an unhandled `requestOpened` event silently setting status to `needsAttention` with no affordance to clear it. The stub must be truly inert: zero height, no action wiring, no partial button.

**`CaseIterable` on `TileKind` has downstream consumers.** Anything iterating `TileKind.allCases` — the sandbox spawn toolbar, the project settings tile-kind picker, any launch-profile kind validation — will now see `.managedAgent` and may need an explicit guard. Audit every call site of `TileKind.allCases` and ensure `.managedAgent` is either included intentionally or excluded by an explicit filter, not silently broken by a missing case.

**Streaming text append must not create a new card per delta.** `content.delta` events arrive at high frequency during a streaming turn. Each delta must be appended to the text storage of the existing `lastAssistantCard`. Creating a new `MessageCardView` per delta would produce hundreds of card views per turn, destroying layout performance. The `lastAssistantCard` tracking variable is the guard; it must be set on `turnStarted` (or on the first `content.delta` if no explicit turn-started event preceded it) and cleared on `turnCompleted`.

**The Lab fixture's `AsyncStream` continuation must not leak.** `AsyncStream.makeStream()` returns a `(stream, continuation)` pair. The continuation keeps the stream alive; the view holds the stream via the session. If the Lab entry is deselected and the card host deallocated, `eventTask` must be cancelled and `continuation.finish()` must be called, otherwise the stream is retained indefinitely. Verify this in the teardown path of `ManagedAgentTileNSView.deinit`.
