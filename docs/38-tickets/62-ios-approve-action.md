# iOS approve action — symmetric `respondToApproval` over the control channel

## What this delivers

A user who receives an "Approval needed" push on their iPhone can open the Continuum iOS
observer app, tap the waiting agent, and approve or decline the request with one tap — and
the Mac's managed-agent tile instantly clears its orange marching-ants border and returns
to working. The approval travels the same `respondToApproval(requestId:decision:)` call the
Mac uses; no parallel code path exists. The iOS app's `Scope` type-level guarantee stays
intact throughout: answering an approval is a scoped control action on the agent channel,
not a spatial mutation, so the phone remains architecturally read-only for canvas state
even as it authors a control message.

In system terms: this ticket wires the iOS observer's approval affordance into the already-
defined `respondToApproval` command, routes that command over the authenticated control
channel to the host, and ensures the host's adapter processes it identically to a Mac-side
tap — with the `AgentApprovalRequest` store clearing, `deriveAgentStatus` recomputing to
`working`, and both the Mac tile and the iOS fleet list updating live.

## How it fits

This ticket is the iOS half of the symmetric respond command whose Mac half was shipped as
part of the managed approvals work (the ticket that wired approvals into `needsAttention`
and built the approval dock). That ticket established `AgentApprovalRequest` as the
pending-approval type, keyed by `requestId: UUID`; it built `ApprovalDecision`
(`.accept | .acceptForSession | .decline | .cancel`); and it wired `respondToApproval` on
the adapter so that a resolved request clears the pending store and triggers
`deriveAgentStatus` to recompute. This ticket consumes all of that as a given and adds
only the iOS surface and the control-channel routing.

It builds directly on the iOS observer app (the preceding ticket that ships the fleet list,
agent detail screen, and subscription to the activity projection). That ticket delivers the
`needsAttention` row, the agent detail view with a read-only transcript, and the wiring
that drives the UI from the activity projection. This ticket extends the detail screen with
the approval affordance and adds the outbound control-channel path.

It also builds on the pairing-token and `Scope` OptionSet model (the ticket that defined
`Scope` as an OptionSet and established that an `.observe` session token cannot represent a
spatial mutation, while approving is explicitly a permitted scoped control action). The
`Scope` check for the approve action must already be defined there; this ticket only needs
to verify the check passes when the approve call arrives.

What this ticket unblocks: it completes the full "approve from your phone" loop that the
APNS push ticket sets up. Without this ticket, a push taps through to a read-only detail
screen with no way to respond. With it, the phone is a fully functional approval surface.
Nothing else in Phase 6 is gated on this ticket.

## The approach

The iOS observer's agent detail screen already shows the pending-approval card when
`AgentStatus` is `needsAttention` and the activity projection carries a non-empty
`pendingApprovalRequests` entry for the agent. This ticket wires the card's three buttons
— Approve, Approve for session, Decline — to dispatch `respondToApproval(requestId:
decision:)` over the authenticated control channel, and handles the response lifecycle.

The control channel is a scoped bearer session established during device pairing, already
authorized with at least `.observe` scope. Approving requires no additional scope beyond
what the iOS session carries — approving is not a spatial mutation; it is a message to the
agent adapter, which the pairing grant explicitly permits. The approve call is authenticated
with the bearer token and sent as a JSON POST to the Mac host (or to the VPS when agents
run remotely, via the same `sshForward` reach path the rest of the control channel uses).

On the Mac side, the host's control-channel server receives `respondToApproval`, validates
the scope (must carry the token, must not be a bare unauthenticated request even on
localhost), looks up the `AgentApprovalRequest` by `requestId`, calls the adapter's
`respondToRequest(requestId:decision:)`, and the already-implemented completion path runs:
the pending store clears, `deriveAgentStatus` recomputes to `working` (or `idle` if the
turn is between rounds), the activity projection updates, and the Mac tile's border clears.
The iOS fleet list and agent detail screen receive the projection update via their existing
subscription and update without any additional code.

The approve tap also immediately updates the iOS UI optimistically — the card enters a
"resolving" state (buttons greyed, a spinner on the tapped button) so the interaction feels
acknowledged even before the round-trip completes. On success the card dismisses; on error
(network loss, stale request, host unreachable) it shows a brief inline error and re-enables
the buttons so the user can try again or dismiss. There is no silent failure.

The deep-link path from a push tap feeds directly into this: when the user arrives at the
agent detail screen via a `continuum://agent/<tileId>` deep link, the approval card is
already rendered (the projection already shows `needsAttention`) and the buttons are live.
The push-tap path and the in-app-navigation path are identical from the card's perspective.

## Where it lives

**`Sources/ContinuumRevivedCore/AgentStatusEngine.swift`** — the primary seam named in the
spec. `AgentStatusEngine` (line 3) already ingests signals and recomputes `AgentStatus`.
The `ingest(.explicit(.working))` call is what the host fires after the adapter resolves
an approval. The iOS-side approval dispatch does not touch this file — it lives in the
adapter — but the ticket's logic tests drive this engine directly to prove that resolving an
approval causes the engine to recompute cleanly.

**`Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift`** — `AgentStatus` (line 85,
the six-case enum), `AgentDescriptor` (line 94, the per-tile status carrier). The
`AgentApprovalRequest` type (introduced by the managed-approvals ticket) and
`ApprovalDecision` enum live here as well; this ticket adds no new types to this file.

**`Sources/ContinuumRevivedCore/SidebarTree.swift`** — `SidebarAgentStatusRollup.dominantKind`
(line 42) already encodes `needsAttention > working` precedence and drives both the Mac
dock and the iOS fleet list. When the approval resolves and `AgentStatus` changes, the
rollup recomputes here automatically.

**iOS observer app — `AgentDetailView`** — the agent detail screen (part of the iOS observer
ticket's deliverable). This ticket adds the `PendingApprovalCard` component: the request
kind label, the sanitized detail string (≤160 chars, failure text redacted per I5), and the
three decision buttons wired to the control-channel dispatch. This component is also added
to the Component Lab as a fixture entry so it can be visually gated without a live device.

**iOS observer app — `ControlChannelClient`** — the outbound control-channel transport (part
of the pairing ticket's deliverable). This ticket calls `controlChannelClient
.respondToApproval(requestId: id, decision: decision)` which sends the authenticated POST.
No new transport code is added here; only a new call site.

**Mac host — control-channel server handler** — the inbound handler for the
`respondToApproval` RPC. This is the only genuinely new Mac-side code this ticket writes:
a handler that validates scope, looks up the `AgentApprovalRequest` by `requestId`,
delegates to the adapter's `respondToRequest`, and returns `200 OK` or a structured error
(`410 Gone` for a stale/already-resolved request, `403` for a scope violation, `404` for an
unknown requestId). The adapter completion path is not new — that was written by the
managed-approvals ticket.

## Implementation breadcrumbs

```swift
// 1. iOS PendingApprovalCard — rendered in AgentDetailView when status == .needsAttention

struct PendingApprovalCard: View {
    let request: AgentApprovalRequest   // from the activity projection
    @State private var resolving: ApprovalDecision? = nil
    @State private var error: String? = nil
    var onRespond: (ApprovalDecision) async throws -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(request.kind.displayName, systemImage: request.kind.systemImageName)
                .font(.headline)
            if let detail = request.detail {
                Text(detail)                // already sanitized ≤160 chars before leaving the Mac
                    .font(.body)
            }
            HStack {
                ApprovalButton("Approve",           decision: .accept,          resolving: $resolving, onRespond: onRespond)
                ApprovalButton("For session",       decision: .acceptForSession, resolving: $resolving, onRespond: onRespond)
                ApprovalButton("Decline",           decision: .decline,         resolving: $resolving, onRespond: onRespond)
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

// ApprovalButton: shows a ProgressView when resolving == self.decision; disables all buttons when resolving != nil
// On tap: set resolving = decision; call onRespond; on success dismiss (card disappears as projection updates);
//         on error: set error text, clear resolving so buttons re-enable

// 2. onRespond implementation — dispatches over the control channel

func respondToApproval(_ requestId: UUID, decision: ApprovalDecision) async throws {
    // ControlChannelClient sends:
    //   POST /v1/agent/<tileId>/approval/respond
    //   Authorization: Bearer <pairingSessionToken>
    //   Body: { "requestId": "<uuid>", "decision": "accept" | "acceptForSession" | "decline" | "cancel" }
    // Throws ControlChannelError.staleRequest on 410, .unauthorized on 403, .notFound on 404
    try await controlChannelClient.respondToApproval(requestId: requestId, decision: decision)
}

// 3. Mac host — inbound handler (new code in the control-channel server)

func handleRespondToApproval(requestId: UUID, decision: ApprovalDecision, scope: Scope) async throws -> HTTPResponse {
    guard scope.contains(.agentControl) else { return .forbidden }            // scope check — always, even loopback
    guard let request = pendingApprovals[requestId], request.status == .pending else {
        return .gone("approval already resolved or unknown")                   // 410 — safe to retry on iOS
    }
    try await adapter.respondToRequest(requestId: requestId, decision: decision)
    // adapter clears pendingApprovals[requestId], calls deriveAgentStatus, updates the projection
    return .ok
}

// 4. Optimistic UI — the card enters resolving state before the round-trip completes.
//    On projection update (approval cleared, status → working) the card disappears naturally
//    because AgentDetailView re-renders from the projection and PendingApprovalCard is
//    only shown when a pending approval exists for this tile.
//    No manual dismissal needed — the projection drives the view.
```

Key invariant the implementation must honor: `AgentApprovalRequest.status` on the host
transitions from `.pending` to `.resolved` exactly once, inside the adapter's
`respondToRequest`. If a second iOS tap or a concurrent Mac tap arrives after resolution,
the host returns `410 Gone` and both surfaces handle it as "already resolved" — the iOS
card re-fetches the projection (which now shows `status = working`) and dismisses cleanly.
There is no double-resolution race.

## How we test it

### Logic (pure Core checks)

Write a table-driven test in `AgentStatusEngineTests` that exercises the resolve lifecycle
end-to-end through the pure types, with no network and no device:

1. Construct an `AgentStatusEngine` with `initialStatus: .needsAttention` (representing a
   tile with a pending approval in flight).
2. Call `engine.ingest(.explicit(.working), at: now)` — simulating the host firing the
   "approval resolved" signal after the adapter confirms.
3. Assert `engine.status == .working` and `engine.statusUpdatedAt == now`.
4. Assert that a second `.explicit(.working)` at a later time does not re-fire a status
   change (idempotent resolve).

Also write a `SidebarAgentStatusRollupTests` case proving that when a zone had one
`needsAttention` tile and it resolves to `.working`, `dominantKind` shifts from
`.needsAttention` to `.working`. This verifies the priority ladder clears correctly across
the rollup — the most visible fleet-level signal.

### Backend (real-path integration)

The real-path check drives the actual control-channel round-trip against a local test host
(the fake transport from the injectable-substrates ticket wired as a local HTTP server, no
real VPS needed, but the full adapter and pending-store are live):

1. Start a test managed-agent session with a pending `AgentApprovalRequest` in the host's
   pending store (`status: .pending`).
2. Assert the activity projection delivered to a subscriber carries `hasPendingApproval:
   true` for the tile and `AgentStatus.needsAttention`.
3. Issue an authenticated `POST /v1/agent/<tileId>/approval/respond` with
   `decision: "accept"` over the control channel, using a valid scoped bearer token.
4. Assert the response is `200 OK`.
5. Assert the pending store is now empty (or the request shows `status: .resolved`).
6. Assert the activity projection update arrives at the subscriber with `AgentStatus.working`.
7. Issue a second identical POST with the same `requestId` and assert `410 Gone` — the
   stale-request guard works.
8. Issue the same POST with an unauthenticated (no Bearer header) request and assert `403` —
   the scope check fires even on loopback.

The manifest written to `qa-runs/<ts>/ios-approve-action/manifest.json` must carry the
observed HTTP status codes, the before/after `AgentStatus` values, the time from POST to
projection update, and a boolean `staleGuardFired: true`. No `{passed:true}` summary.

### UX (visual gate + dogfood snippet)

**Visual gate:** Add a `PendingApprovalCard` entry to `ComponentLab.swift`. Seed it with
a fixture `AgentApprovalRequest` of kind `.commandExecution`, detail `"npm test"`, status
`.pending`. Render the card over an opaque dark backdrop, call `cacheDisplay`, and assert
`!VisualSnapshot.metrics(for: snapshot).isBlank` — non-blank, non-uniform snapshot, per
the Tier-1 gate. The three buttons and the detail label must be present and non-degenerate.
Also render a second fixture with `resolving = .accept` and assert the spinner is present
and the buttons are visually dimmed (metrics check: the snapshot has lower average
brightness than the idle state, as a proxy for the greyed-out buttons).

**Dogfood snippet:**

Open the app on the Mac with a managed agent running in supervised mode. On the paired
iPhone, background the Continuum iOS app. On the Mac, let the managed agent reach an
approval checkpoint (or trigger one via the Component Lab's "Fire approval" fixture). Within
a few seconds, see exactly: a push notification titled "Approval needed" naming the agent
and the project. Tap it. The iOS app opens directly on that agent's detail screen. The
approval card is visible at the bottom: it shows the request kind (e.g. "Run command") and
the sanitized detail string (e.g. `"npm test"`), then the buttons "Approve", "For session",
"Decline". Tap "Approve". See exactly: the button immediately shows a spinner and the other
two buttons grey out. Within one network round-trip, the card dismisses and the agent row
in the fleet list switches from the orange `◆ needs you` label to the blue `● working`
label. On the Mac, simultaneously observe the tile's orange marching-ants border clear and
the header glyph return to the blue pulsing `●`. No transcript body text appeared in the
push payload.

## Execution mode

**Needs-substrate.** The logic and backend checks run autonomously against the fake
transport and need no real device. The UX visual gate runs in the Component Lab on the Mac
and needs no device. But the dogfood snippet — which is the only path that proves the
real push tap-through and the real control-channel round-trip between a physical iPhone
and the Mac host — requires a paired iOS device, a real APNS `.p8` credential, and a live
managed agent in supervised mode. Without these, the approve button's real network path and
the push deep-link entry cannot be exercised. The ticket is not done until the dogfood
snippet passes on a real device.

## Done when

- [ ] The iOS agent detail screen shows a `PendingApprovalCard` with Approve / For session
      / Decline buttons whenever the activity projection carries a `.pending` approval for
      the agent and `AgentStatus == .needsAttention`.
- [ ] Tapping a decision button sends an authenticated `respondToApproval` POST over the
      control channel with the correct `requestId` and `decision` value.
- [ ] The button enters a "resolving" spinner state immediately on tap; the other buttons
      are disabled while a response is in flight.
- [ ] On `200 OK`, the card dismisses as the projection updates to `AgentStatus.working`.
- [ ] On `410 Gone` (stale request), the card shows a brief inline "Already resolved" error
      and then re-fetches the projection to confirm the current state.
- [ ] On network failure, the card shows an inline error and re-enables the buttons.
- [ ] The Mac host's `respondToApproval` handler returns `403` for an unauthenticated or
      out-of-scope request, even on loopback.
- [ ] A second identical `respondToApproval` request after resolution returns `410 Gone`,
      not `200 OK` (no double-resolution).
- [ ] The `PendingApprovalCard` Component Lab entry passes the Tier-1 non-blank snapshot
      check in both idle and resolving states.
- [ ] The Logic core checks pass: status resolves from `needsAttention` to `working` after
      `ingest(.explicit(.working))`, and the rollup's `dominantKind` shifts accordingly.
- [ ] The Backend real-path check passes with a measured manifest carrying all eight
      assertions (status transitions, HTTP codes, stale guard, scope guard).
- [ ] The dogfood snippet passes on a real paired iPhone: push arrives, tap-through works,
      approve tap clears the card and the Mac border simultaneously.

## Depends on / unblocks

This ticket depends on three predecessors, all of which must be merged before work begins
here. First, the iOS observer app — the fleet list, agent detail screen, and activity
projection subscription; this ticket adds the approval affordance to an already-rendered
detail screen. Second, the managed-approvals ticket — the `AgentApprovalRequest` type,
`ApprovalDecision` enum, the pending store, and the Mac-side adapter path that `respondToApproval`
already invokes. Third, the pairing-token and `Scope` OptionSet — the control-channel
bearer session that carries the iOS request to the host and the scope check that validates it.

This ticket unblocks nothing in the build plan. It is the last iOS Phase 6 ticket in the
approval chain. The APNS push ticket (which fires the notification that leads the user here)
is a parallel sibling, not a dependency — push arrives whether or not the approve action
works, and the approve action works whether or not push is wired. The two are independent
and can land in either order.

## Watch out for

**The stale-request race is the sharpest edge.** The Mac-side approval dock and the iOS
approval card can both be visible at the same time. If the user taps "Approve" on the Mac a
fraction of a second before the phone sends its own POST, the Mac wins, the pending store
clears, and the iOS POST hits an already-resolved request. The `410 Gone` handler and the
iOS card's error recovery path must handle this gracefully — show "Already resolved," re-
fetch the projection (which now shows `working`), and dismiss. Do not re-throw the error as
a blocking failure. Write the stale-guard test in the Backend suite before touching the iOS
UI so the contract is clear.

**The scope check must fire on loopback.** Decision D6 is explicit: auth on every path
including loopback, never `if (localhost) skipAuth`. The Backend check must include an
unauthenticated-loopback case asserting `403`, not just a remote authenticated case. Any
implementation that skips the scope check when the control channel is a local socket is
wrong regardless of how it was motivated.

**I5: the approval card must show only sanitized metadata.** The `detail` string on
`AgentApprovalRequest` must already be capped at 160 characters and any failure text
must be redacted before the request leaves the Mac host's adapter and enters the activity
projection. The iOS card renders the detail string it receives; it must never independently
truncate or sanitize on the assumption that the host did it. Verify in the Backend check
that a fixture detail string of 200 characters arrives on the iOS subscriber as exactly 160
characters. The taint scan (the invariant-spine harness check) should already catch this at
the projection boundary, but the Backend check is the real-path gate.

**Optimistic UI and projection convergence must not conflict.** The card's optimistic
"resolving" state is driven by local `@State`. The projection-driven dismissal is driven by
the subscription update. Both paths try to change the card's visible state. The correct
order is: optimistic state sets in immediately on tap; projection update triggers the
dismissal. If the projection update arrives before the local state has a chance to render
(sub-millisecond on a local host), the card should still dismiss cleanly — the projection is
the source of truth and its update wins. Test this in the Backend check by asserting the
projection update arrives and the subscriber receives it, rather than asserting the local
optimistic state.

**The `continuum://agent/<tileId>` deep link is validated on receipt.** Following D7 and
the t3code pattern (`notificationPayload.ts:47`), the deep-link handler must validate the
URL scheme and the `<tileId>` is a valid UUID before navigating. A malformed push payload
must not crash or navigate to an undefined screen. Write one test case in the Logic suite
asserting that a malformed deep-link URL returns `.invalid` from the validator, not a
crash.
