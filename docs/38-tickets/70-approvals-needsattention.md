# Approvals to needsAttention (managed tier)

> **Ruling C-20260702-012 (auth — read before implementing):** `respondToApproval` must NOT rely on the
> `.observer` scope floor. An `.observer`-scoped session (e.g. an iOS phone) must not be able to approve or
> deny an approval it does not own. This ticket must gate `respondToApproval` on the session **owning the
> target approval** (or holding an operator+ scope) before clearing the pending entry. See the 54/59 audit
> finding in `_CODEX_AUDIT.md`.

## What this delivers

A pending approval from a managed agent becomes the authoritative, highest-priority source of `AgentStatus.needsAttention` for that tile — checked before any reader-derived or engine-derived signal. Concretely: when a managed agent raises a permission request, a `UUID`-keyed `AgentApprovalRequest` lands in an in-memory pending store owned by the per-project runtime controller; the pure status-derivation function sees `hasPendingApproval = true` and returns `.needsAttention` unconditionally, above any `working` or `idle` signal. When the human (on Mac or iOS) responds, the symmetric `respondToApproval` call clears the pending entry and the derivation function naturally recomputes to `working` or `idle` on the next cycle.

From the user's perspective, a managed agent that needs permission is never silently buried behind a blue working pulse. The tile border goes orange, the sidebar row reads "needs you," and (once the iOS and push tickets land) the phone rings. Responding from any surface resolves it everywhere, because there is exactly one code path.

This is the ticket that closes the attention gap the agent-readers spike identified: Claude in `bypassPermissions` mode produces no file-derivable attention signal. The fix is not a better file reader — it is owning the approval channel for agents Continuum drives. For managed agents that channel is structured and deterministic. Shell tiles are untouched by this work; their two-regime separation is explicitly preserved.

## How it fits

This ticket is the payoff of the managed-tier foundation. It builds directly on the ACP driver (ticket 69), which establishes the `AgentAdapter` protocol and proves a real end-to-end managed session; without a live adapter emitting approval events, there is nothing for the pending store to receive. It also builds on the pure status-derivation function (ticket 32), which defines `StatusSignals.hasPendingApproval` and places it at the top of the priority ladder — this ticket is the first caller to actually set that flag to `true` via a real adapter event rather than a test fixture.

Once this lands, the approval dock and attention border (ticket 72) have a live, real-time `AgentStatus.needsAttention` to react to — they are blocked on this. The iOS approval action (ticket 62) reuses the `respondToApproval` command introduced here and can be wired directly without any new protocol work. The APNS push service (ticket 63) watches status transitions and fires on entry into `needsAttention`; this ticket is what makes that transition happen from a real managed-agent event rather than a synthetic one.

## The approach

The design is a requestId-keyed dictionary of `AgentApprovalRequest` values, owned by the per-project `ZoneRuntimeController`, updated by the adapter event stream, and consumed by the status derivation path.

**The type.** `AgentApprovalRequest` is a `Codable`, `Equatable`, `Sendable` struct living in `ContinuumRevivedCore`. It carries: a `UUID` request identifier (the primary key), the `tileId: UUID` it belongs to, a `kind: ApprovalRequestKind` closed enum, an optional `detail: String?` sanitized to ≤160 characters before storage, a `status` of `.pending` or `.resolved`, an optional `decision: ApprovalDecision?` set on resolution, and `createdAt: Date`. The `ApprovalRequestKind` enum maps the t3code canonical request taxonomy: `commandExecution`, `fileRead`, `fileChange`, `applyPatch`, `userInput`. The `ApprovalDecision` enum is the four decisions from t3's `ProviderApprovalDecision`: `accept`, `acceptForSession`, `decline`, `cancel`.

**The store.** `ZoneRuntimeController` gains a private `var pendingApprovals: [UUID: AgentApprovalRequest]` dictionary (keyed by `requestId`). This dictionary is the single source of truth for managed-approval state. It is never persisted — a restart is a clean slate, and any live approval whose adapter process died is simply gone. It is accessed only on the controller's actor/serial queue, so no additional locking is needed.

**Feeding the store.** The ACP driver (or any future adapter conforming to `AgentAdapter`) emits canonical `AgentRuntimeEvent` values on its event stream. Two event variants feed the pending store:

- When the driver emits an event of kind `requestOpened` (carrying a `requestId`, `kind`, and optional `detail`), the controller upserts a `AgentApprovalRequest` with `status = .pending` into `pendingApprovals`.
- When the driver emits `requestResolved` (carrying the same `requestId` and a `decision`), the controller updates the existing entry to `status = .resolved, decision = decision`. Resolved entries are pruned from the dictionary after resolution — a pending entry that is resolved never reappears in the `hasPendingApproval` derivation.

There is a third path: if the adapter process dies or the driver calls `stop()` with unresolved approvals outstanding, the controller calls a `clearPendingApprovals(for: tileId)` helper that removes all entries for that tile. This prevents a zombie "needs attention" status on a tile whose agent is no longer running.

**Feeding the derivation function.** The `SessionObserver` already assembles `StatusSignals` for each tile on every observation cycle. For managed tiles, it adds one step: query `controller.pendingApprovals.values.contains { $0.tileId == tile.id && $0.status == .pending }` and set `signals.hasPendingApproval` accordingly. No new seam is needed; `StatusSignals.hasPendingApproval` already exists (ticket 32) and `deriveAgentStatus` already places it first in the cascade. Wiring it to real data is the entirety of what this ticket does on the derivation side.

**The respond command.** `respondToApproval(requestId: UUID, decision: ApprovalDecision)` is a method on `ZoneRuntimeController` (or a top-level command routed through it). It looks up the pending entry by `requestId`, forwards `decision` to the relevant adapter via `adapter.respond(requestId:, decision:)` (the `respond` slot on `AgentAdapter` defined in ticket 67), and immediately updates the store entry to `.resolved` — it does not wait for the adapter to echo back a `requestResolved` event, because that event may arrive asynchronously after the adapter has already acted. Updating the store immediately ensures the tile's status recomputes to non-attention on the next observer cycle without waiting for the event round-trip. When the `requestResolved` event arrives, the store update is idempotent.

This command is the single respond path for both Mac (invoked from the approval dock UI, ticket 72) and iOS (invoked from the iOS observer, ticket 62). It is defined in `ContinuumRevivedCore` so both targets can reach it without referencing AppKit.

**The two-regime firewall.** Nothing in this implementation touches `hookBreadcrumbPresent` or any shell-tile status path. `AgentApprovalRequest` carries a `tileId`; the store is only written to from adapter events, and adapters only exist for managed tiles. The `SessionObserver` only sets `hasPendingApproval = true` for tiles whose `agentKind == .managed`. An observed shell tile's `StatusSignals` always has `hasPendingApproval = false` by construction — the store simply has no entries for it. The two regimes are separated by the absence of data, not by a runtime check.

## Where it lives

**Primary new file:** `Sources/ContinuumRevivedCore/AgentApprovalRequest.swift`

This file contains four things: the `ApprovalRequestKind` enum, the `ApprovalDecision` enum, the `AgentApprovalRequest` struct, and the `ApprovalStatus` enum (`pending | resolved`). Placing them together in one file makes the entire approval type surface visible at a glance and easy to audit for sync-boundary compliance (I5).

**Modified file:** `Sources/ContinuumRevived/App/ZoneRuntimeController.swift`

`ZoneRuntimeController` gains:
- `private var pendingApprovals: [UUID: AgentApprovalRequest]` (line range to be determined by the implementer after reading the file; insert near other per-project mutable state)
- `func upsertPendingApproval(_ request: AgentApprovalRequest)` — internal, called from the adapter event handler
- `func clearPendingApprovals(for tileId: UUID)` — internal, called from adapter `stop()`
- `func respondToApproval(requestId: UUID, decision: ApprovalDecision) async throws` — public, the respond command

**Modified file:** `Sources/ContinuumRevivedCore/AgentStatusEngine.swift`

No structural change. The only modification is confirming that `StatusSignals.hasPendingApproval` (already present from ticket 32) is being correctly set from the controller's store in the observer's signal-assembly loop. If ticket 32 has not yet landed when this ticket is implemented, `StatusSignals` must be defined here as part of this ticket's scope — do not proceed without it.

**Existing seam confirmed:** `Sources/ContinuumRevivedCore/AgentStatusEngine.swift:1` — `AgentStatusEngine` and `StatusSignals` live here; `deriveAgentStatus` is the pure function this ticket's store feeds into.

**Existing seam confirmed:** `Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift:85` — `AgentStatus` enum with `.needsAttention` at line 89; the return type of the derivation function.

**Not touched:** the `AgentStatusEngine` stateful struct (lines 3–112 of `AgentStatusEngine.swift`), any shell-tile reader, any observed-tile signal path, `hookBreadcrumbPresent`, `FocusBorderOverlay`, the sidebar view, or any UI layer. Those are downstream consumers of `AgentStatus`; they react to `.needsAttention` appearing without any changes required here.

## Implementation breadcrumbs

```swift
// AgentApprovalRequest.swift — all approval types in one place, auditable for I5

public enum ApprovalRequestKind: String, Codable, Equatable, Sendable {
    case commandExecution   // "run this shell command"
    case fileRead           // "read this path"
    case fileChange         // "write/modify this path"
    case applyPatch         // "apply this diff"
    case userInput          // agent asking a question, not requesting permission
}

public enum ApprovalDecision: String, Codable, Equatable, Sendable {
    case accept
    case acceptForSession   // approve this request kind for the rest of the session
    case decline
    case cancel             // withdrawn by the agent, no human action taken
}

public enum ApprovalStatus: String, Codable, Equatable, Sendable {
    case pending
    case resolved
}

public struct AgentApprovalRequest: Codable, Equatable, Sendable {
    public let requestId: UUID
    public let tileId: UUID
    public let kind: ApprovalRequestKind
    public let detail: String?          // sanitized to ≤160 chars on construction
    public private(set) var status: ApprovalStatus
    public private(set) var decision: ApprovalDecision?
    public let createdAt: Date

    public init(requestId: UUID, tileId: UUID, kind: ApprovalRequestKind,
                rawDetail: String?, createdAt: Date) {
        self.requestId = requestId
        self.tileId = tileId
        self.kind = kind
        // Sanitize: cap at 160 chars, redact on construction — never store a body
        self.detail = rawDetail.map { String($0.prefix(160)) }
        self.status = .pending
        self.decision = nil
        self.createdAt = createdAt
    }

    // Called when the adapter emits requestResolved or when the human responds
    public mutating func resolve(with decision: ApprovalDecision) {
        self.status = .resolved
        self.decision = decision
    }
}
```

```swift
// ZoneRuntimeController additions

private var pendingApprovals: [UUID: AgentApprovalRequest] = [:]

// Called from the adapter's event stream handler (runs on controller's serial queue)
func upsertPendingApproval(_ request: AgentApprovalRequest) {
    pendingApprovals[request.requestId] = request
    // A resolved entry is pruned immediately — it will never re-enter the pending check
    if request.status == .resolved {
        pendingApprovals.removeValue(forKey: request.requestId)
    }
}

// Called when the adapter stops with unresolved approvals outstanding
func clearPendingApprovals(for tileId: UUID) {
    pendingApprovals = pendingApprovals.filter { $0.value.tileId != tileId }
}

// The symmetric respond command — invoked identically from Mac dock and iOS observer
func respondToApproval(requestId: UUID, decision: ApprovalDecision) async throws {
    guard var entry = pendingApprovals[requestId] else { return }  // already resolved, no-op
    // Update store immediately so the next observer cycle sees .resolved
    entry.resolve(with: decision)
    pendingApprovals[requestId] = entry
    upsertPendingApproval(entry)   // prune resolved entry
    // Forward to adapter — adapter's response may arrive as requestResolved event (idempotent)
    guard let adapter = managedAdapters[entry.tileId] else { return }
    try await adapter.respond(requestId: requestId, decision: decision)
}

// hasPendingApproval query — called by SessionObserver during signal assembly
func hasPendingApproval(for tileId: UUID) -> Bool {
    pendingApprovals.values.contains { $0.tileId == tileId && $0.status == .pending }
}
```

```swift
// SessionObserver — signal assembly for a managed tile (additions only)
// Inside the loop that builds StatusSignals per tile, for managed tiles:

var signals = StatusSignals(agentKind: .managed, /* … other fields … */)
signals.hasPendingApproval = controller.hasPendingApproval(for: tile.id)
// hasPendingApproval = true → deriveAgentStatus returns .needsAttention unconditionally
let derivedStatus = deriveAgentStatus(signals: signals)
```

```swift
// Adapter event stream handler — wiring requestOpened / requestResolved events
// Inside the ACP driver's event loop (ticket 69):

case .requestOpened(let requestId, let kind, let detail):
    let request = AgentApprovalRequest(
        requestId: requestId, tileId: tileId,
        kind: kind, rawDetail: detail, createdAt: .now
    )
    controller.upsertPendingApproval(request)

case .requestResolved(let requestId, let decision):
    if var entry = controller.pendingApprovals[requestId] {
        entry.resolve(with: decision)
        controller.upsertPendingApproval(entry)   // triggers prune
    }
```

**The event-to-store loop must run on the controller's serial queue.** The pending store is mutated from the adapter event stream and queried from the observer tick. Both must land on the same queue or actor to avoid data races. If `ZoneRuntimeController` is already a class with a serial dispatch queue, dispatch both to it. If it is an actor, `await` it. Do not introduce a separate lock.

## How we test it

### Logic (pure Core checks)

Write table-driven tests in `ContinuumRevivedCoreTests/AgentApprovalRequestTests.swift` covering the type semantics and the derivation integration:

1. **Sanitization.** Construct an `AgentApprovalRequest` with a `rawDetail` of 200 characters; assert `detail` is truncated to exactly 160 characters.
2. **Resolution.** Construct a pending request; call `resolve(with: .accept)`; assert `status == .resolved`, `decision == .accept`.
3. **Derivation: approval beats running.** Build a `StatusSignals` with `hasPendingApproval = true`, `isRunning = true`, `agentKind = .managed`; call `deriveAgentStatus`; assert `.needsAttention`. This is the single most important invariant in the ticket — it must be an explicit named test, not incidentally covered.
4. **Derivation: resolved approval clears.** Build a `StatusSignals` with `hasPendingApproval = false`, `isRunning = true`, `agentKind = .managed`; assert `.working`. Confirms the store-clear path produces the right status.
5. **Shell tile firewall.** Build a `StatusSignals` with `hasPendingApproval = false`, `agentKind = .claude` (observed shell); assert `.needsAttention` is not returned for a running tile — i.e., the managed-only path does not leak into shell tiles by construction.
6. **Store query.** Unit-test `hasPendingApproval(for:)` on a mock controller: insert a pending entry for tile A, a resolved entry for tile B; assert A returns `true`, B returns `false`.
7. **clearPendingApprovals.** Insert two pending entries for tile A and one for tile B; call `clearPendingApprovals(for: tileA)`; assert store contains only tile B's entry.

All of these run with `swift test --filter AgentApprovalRequestTests` — no process spawning, no file I/O, no clock queries.

### Backend (real-path / integration, not bypassed)

The real-path check drives a minimal in-memory `FakeAgentAdapter` that implements `AgentAdapter` and synchronously emits a `requestOpened` event. The check feeds this adapter through the production `ZoneRuntimeController` event handling path — not by calling `upsertPendingApproval` directly — and asserts the derived status on the next `SessionObserver` tick.

Concretely: instantiate a `ZoneRuntimeController` against a temp project store (the same pattern used by existing controller integration checks); inject the `FakeAgentAdapter`; subscribe to its event stream; emit `requestOpened`; run one observer tick; read the tile's `AgentDescriptor.status` from the store; assert `.needsAttention`. Then emit `requestResolved` with `decision: .accept`; run another tick; assert `.working` (or `.idle` if the fake adapter has no running turn).

The `FakeAgentAdapter` must be defined in the test target, not in core. It must implement the same `AgentAdapter` protocol as the ACP driver (defined in ticket 67), so this test simultaneously serves as a protocol-conformance smoke test for the adapter seam.

This check must not call `deriveAgentStatus` directly. It drives the full event path — adapter event → store update → observer cycle → store read — and asserts the output of the store, not the output of the pure function. The pure-function behavior is already proven by the logic checks above.

### UX (visual gate + dogfood snippet)

The visual gate belongs to the approval dock ticket (ticket 72), which renders the tile with the pending approval and takes the Component Lab screenshot. This ticket does not own a new visual surface.

However, to avoid leaving the UX gate entirely deferred, include one targeted Component Lab check as part of this ticket's acceptance criteria: a new Lab fixture entry named `"Managed Agent — Approval Pending"` that creates a managed tile state with a synthetic pending `AgentApprovalRequest` injected directly into the tile's status (bypassing the adapter, since the Lab runs without a live ACP session), sets `AgentStatus.needsAttention`, and renders the tile header. The `ComponentLab.runSelfCheck()` assertion (`ComponentLab.swift:706`) then catches regressions in the tile header's attention rendering — the amber `◆ needs you` glyph — before the dock is built.

**Concrete dogfood snippet:**

Open the app and navigate to a workspace that has a managed agent tile running in supervised mode. In the Component Lab (`Control-Space` then select the Lab launcher), choose the `"Managed Agent — Approval Pending"` fixture. Click "Fire approval" in the fixture's toolbar. See exactly: the tile status header glyph change from a blue `●` to an **orange `◆`**, the header label update to `needs you`, the sidebar row for that tile update to the same orange diamond with the text "needs you," and the ambient zone chrome header read "1 needs you" in orange. Then click "Respond: Accept" in the fixture toolbar. See exactly: the glyph return to blue `●`, the label return to `working`, and the sidebar row clear to the working state. Both transitions should happen within one observer debounce cycle (250 ms).

## Execution mode

**Autonomous.** The logic checks are pure value-type assertions against `AgentApprovalRequest` and `deriveAgentStatus` — no clock, no file I/O, no daemon. The real-path check uses a `FakeAgentAdapter` that runs entirely in-process against a temp filesystem store (the same pattern as existing controller integration checks). The Component Lab fixture check renders AppKit chrome in a headless `NSWindow` and asserts non-blank via `VisualSnapshot.metrics` — no human eyes, no live adapter. The complete suite (logic + real-path + Lab fixture) is runnable by a CI matrix with `swift test` and `swift build`. No network, no VPS, no iOS device is required. The approval dock itself (ticket 72) is supervised because it requires a visual design judgment; this ticket's scope ends at the data layer and the status derivation, which are purely mechanical and fully provable by the three checks above.

## Done when

- [ ] `AgentApprovalRequest.swift` exists in `Sources/ContinuumRevivedCore/` with `ApprovalRequestKind`, `ApprovalDecision`, `ApprovalStatus`, and `AgentApprovalRequest` — all `Codable`, `Equatable`, `Sendable`.
- [ ] `AgentApprovalRequest.init` caps `rawDetail` at 160 characters — asserted by a logic check.
- [ ] `ZoneRuntimeController` has `pendingApprovals: [UUID: AgentApprovalRequest]`, `upsertPendingApproval`, `clearPendingApprovals(for:)`, `hasPendingApproval(for:)`, and `respondToApproval(requestId:decision:)` — all mutations routed through the controller's serial queue or actor.
- [ ] `respondToApproval` immediately marks the store entry `.resolved` before forwarding to the adapter, and the store prune removes the resolved entry — asserted by a logic check.
- [ ] `SessionObserver` sets `signals.hasPendingApproval` from `controller.hasPendingApproval(for: tileId)` for managed tiles — the real-path check confirms this propagates through to the stored `AgentDescriptor.status`.
- [ ] Adapter `requestOpened` event → `controller.upsertPendingApproval` path is exercised by the real-path check through the production event handler, not by calling `upsertPendingApproval` directly.
- [ ] The logic check row "approval beats running" (`hasPendingApproval = true, isRunning = true` → `.needsAttention`) is an explicit named test that passes.
- [ ] The shell-tile firewall test (observed `.claude` tile with no pending entries → never reaches `.needsAttention` through this path) passes.
- [ ] `clearPendingApprovals(for:)` is called from the adapter's `stop()` path — confirmed by the real-path check emitting a stop event and asserting the store is empty.
- [ ] The Component Lab fixture `"Managed Agent — Approval Pending"` exists and passes `ComponentLab.runSelfCheck()` with a non-blank, non-one-color snapshot.
- [ ] `swift build` passes with zero new warnings.
- [ ] No existing tests broken or deleted.
- [ ] `AgentApprovalRequest` contains no pane targets, PIDs, transcript bodies, or host-local handles — it is I5-clean. (Confirm by inspection; the taint-scan check from ticket 9 should pass without modification.)

## Depends on / unblocks

This ticket depends on the `AgentAdapter` protocol and canonical event union (ticket 67), which defines the `requestOpened` and `requestResolved` event variants and the `respond(requestId:decision:)` adapter slot. It depends on the ACP driver (ticket 69), which is the first adapter to emit real approval events. And it depends on the pure status-derivation function (ticket 32), which defines `StatusSignals.hasPendingApproval` and the priority cascade this ticket activates with real data.

Once this ticket lands, the approval dock and attention border (ticket 72) have a live `AgentStatus.needsAttention` to render against — that ticket is the immediate visual consumer and is blocked here. The iOS approval action (ticket 62) reuses `respondToApproval` verbatim, routed over the control channel; nothing new is needed on the command side. The APNS push service (ticket 63) watches `AgentStatus` transitions emitted by the `SessionObserver`; this ticket is what makes the `working → needsAttention` transition happen from a real adapter event rather than a synthetic one. The waiting-for-input card (ticket 73) reuses the same store and respond path for `ApprovalRequestKind.userInput`; no new infrastructure is needed, only a UI distinction.

## Watch out for

**The concurrent-access trap is the most likely implementation failure.** The pending store is written by the adapter event stream (which may be on a background queue or async context) and read by the observer tick (which runs on its own cadence). If both are not serialized onto the same queue or actor, data races will produce intermittent `needsAttention` flicker or — worse — a missed attention signal that silently under-claims. Verify that every mutation of `pendingApprovals` is dispatched to the same serial context. A race here violates I6 (status soundness) in a way that is nearly impossible to reproduce in a logic test.

**`respondToApproval` must update the store before forwarding to the adapter, not after.** If the store update waits for the adapter to echo back a `requestResolved` event, the tile stays in `needsAttention` for an extra observer cycle after the human has already clicked Approve. That flicker is a broken UX even if both operations eventually produce the same result. The store is the source of truth for the derivation path; make it correct first.

**Do not let resolved entries accumulate in the store.** A resolved entry that is never pruned means `hasPendingApproval(for:)` stays correct (it filters by `.pending`), but the dictionary grows without bound over a long session with many approvals. Prune resolved entries in `upsertPendingApproval` immediately when `status == .resolved` — do not defer cleanup to a separate sweep.

**The `clearPendingApprovals` call on adapter `stop()` must not be skipped when the adapter exits uncleanly.** If the ACP process crashes or the driver's stream throws, the stop path may not be reached via the normal code path. Add a `defer { controller.clearPendingApprovals(for: tileId) }` in the adapter's task/async scope so that any exit — clean or not — drains the pending store for that tile. A zombie `needsAttention` on a dead agent is the most user-visible failure mode of this ticket.

**Shell tiles must never write to the pending store.** There is no code path today that would route a shell tile into `upsertPendingApproval`, because only managed adapters emit `requestOpened` events. Do not add a defensive check inside `upsertPendingApproval` that silently discards shell-tile entries — instead, confirm by inspection that no call site of `upsertPendingApproval` can be reached from a non-managed tile, and assert this in the real-path check by confirming a shell-tile `tileId` never appears in the store after any observer cycle.
