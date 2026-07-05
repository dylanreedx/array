# iOS approve action — symmetric `respondToApproval` over the control channel

> **RULING BANNER — C-20260705-026 (night3 B5 = 62-ios-approve-action, orchestrator 2026-07-05).
> Binding; overrides the ticket text below where they conflict. The ticket predates the landed
> architecture: there is NO HTTP control channel — no `ControlChannelClient`, no Mac control-channel
> server, no Bearer/HTTP status semantics (403/410/404), and ticket 70's production pending store /
> adapter respond path is NOT built (skipped, C-20260703-018; ticket 40's SessionObserver also not
> built yet). The approve action rides the landed `SyncMessage`/demux wire exactly like B3 (activity)
> and B4 (spatial ops). Companion spec §2.4–2.5, §6.2, §6.4 supersede this ticket's surface
> description. Verified code facts as of 4771fc3: `requiredScope[.respondToApproval] ==
> .orchestrationRead` (`ScopeAuthorization.swift:23`) and `ContinuumRevivedCoreChecks/main.swift:868`
> asserts bare `.observer` CAN authorize it — both violate C-20260702-012 and are fixed by THIS item;
> `AgentActivityEvent` carries NO approval/request id (`AgentActivityEvent.swift:41-115`), so the
> phone currently has nothing to respond WITH; `AgentAdapter.respondToRequest(threadId:requestId:
> decision:)` + `ApprovalDecision` exist in `AgentStatusEngine.swift` (ticket 67); B3's
> `PendingAttentionCard` (`ios/Continuum/Sources/ContinuumApp.swift:319-357`) has Approve/Deny
> rendered `.disabled(true)` waiting for this item, and the Approvals tab is a placeholder reading
> "Approvals land with ticket 62."**
>
> 1. **Scope gate FIRST (the reason this item is in the queue — C-20260702-012):** flip
>    `requiredScope[.respondToApproval]` from `.orchestrationRead` to `.orchestrationOperate` in
>    `ScopeAuthorization.swift`, and fix the check at `ContinuumRevivedCoreChecks/main.swift:868` —
>    move `.respondToApproval` into the observer-denied table asserting `AuthError.missingScope(
>    .orchestrationOperate)`. The ruling's "session owns the target approval" leg is NOT modeled
>    tonight (approval→session ownership needs ticket 70's pending store; owed there). v1 gate =
>    operator+ only, enforced BOTH client-side (button state) and desktop-side (authoritative).
> 2. **Wire path (B4 precedent; frozen types respected):**
>    (a) Add `approvalRequestId: String?` to `AgentActivityEvent` AND `AgentActivityEventDraft` —
>    optional, `decodeIfPresent`/`encodeIfPresent` (adapter request ids are `String`). This is the
>    ONE wire-type addition and it is I5-clean (an opaque id — spec §3: notifications carry ONLY the
>    approval id; never detail text beyond the existing ≤500-char summary rule). Legacy-JSON
>    key-absence decode check (old event JSON without the key → nil) + round-trip check required.
>    (b) Two new `SyncMessage` cases: `.approvalResponse(ApprovalResponseRequest)` (phone→desktop:
>    `tileId: UUID`, `requestId: String`, `decision: ApprovalDecision`) and
>    `.approvalResponseAck(ApprovalResponseAck)` (desktop→phone: `requestId: String`, `outcome`, a
>    NEW closed enum: `resolved | stale | unauthorized | unknownRequest`). NO threadId on the wire —
>    the tileId→threadId mapping is host-local and lives behind the desktop seam (I5).
>    (c) `CloudKitSyncTransport.send` is an exhaustive switch — handle BOTH new cases with an honest
>    typed `SyncTransportError.sendFailed` (the desktop CK inbound pump does not exist — B4's
>    publisher-owed gap; a CK record write nobody fetches would be a fake success). The phone card
>    surfaces that through its normal error path. Live-CK leg: `device-gate-owed` +
>    `publisher-owed`, same tags as B4.
> 3. **Desktop-side responder (new, `ContinuumRevivedSync`):** an `ApprovalResponder` actor
>    mirroring `SpatialOpSender`'s shape — init(seam, demux, authorizedScope); `start()` registers
>    its demux subscription synchronously before returning (C-20260703-020 lesson); on
>    `.approvalResponse`: (i) `authorize(.respondToApproval, grantedScopes: authorizedScope)` — on
>    failure ack `.unauthorized` and NEVER invoke the seam; (ii) delegate to an injectable
>    `protocol ApprovalResponding: Sendable` whose respond(tileId:requestId:decision:) returns a
>    result distinguishing resolved / stale / unknownRequest; (iii) ack the outcome. The stale path
>    must NOT re-invoke resolution — at most one seam resolution per requestId (the ticket's
>    "sharpest edge", kept). The PRODUCTION consumer of the seam is ticket 70/69's adapter path —
>    NOT built; do NOT invent a ZoneRuntimeController pending store tonight (`publisher-owed`).
>    Checks use a fake seam that, on the first `.accept`, appends the resolution activity event
>    (tone `.approval`, status `.working`, same tileId) to the SAME `ActivityStore` the projection
>    sender serves — proving the projection-driven card-dismissal loop end to end.
> 4. **iOS surface (spec §6.2 supersedes the ticket's three-button card):** wire B3's
>    `PendingAttentionCard` — **Approve = `.accept`, Deny = `.decline`**; `.acceptForSession` /
>    `.cancel` stay desktop-side in v1. Remove `.disabled(true)` + the "Actions land with ticket
>    62" hint. Resolving state: tapped button shows a spinner, both disable. Ack handling:
>    `.resolved` → dismissal comes from the projection update (source of truth — do not manually
>    clear the card on ack alone); `.stale` → brief "Already resolved" inline note, dismissal again
>    projection-driven; `.unauthorized` or transport send failure → inline error + re-enable
>    buttons. Client-side gating: buttons disabled with an "observer scope" hint when
>    `model.grantedScope` fails `authorize(.respondToApproval, …)` — B4's DEBUG
>    `CONTINUUM_SCOPE_OVERRIDE=operator` hatch makes them live for morning dogfood. If the latest
>    pending-attention event carries NO `approvalRequestId` (legacy/desktop-old events), buttons
>    stay disabled with an honest "No approval id synced" hint — never send a fabricated id. The
>    model gains the respond path over the SAME shared demux (one transport, one demux — B3 rule);
>    register the ack listener before sending. **Approvals tab:** replace the placeholder (after
>    this item its text would be a standing lie) with the MINIMAL honest inbox per spec §6.4:
>    needs-attention rows via the Core helper below, tap → the SAME `AgentDetailView` (where the
>    card lives), tab badge = attention count, "Nothing needs you." empty state. NO
>    swipe-to-approve tonight (deferred alongside push).
> 5. **Shared logic in Core (night-3 rule):** pure `AgentsBoardProjection` helpers —
>    `approvalsInboxRows(from:)` (rows filtered `.needsAttention`, board order preserved) and
>    `attentionCount(from:)`; plus a respondable-request helper that returns (tileId,
>    approvalRequestId) from a `TileActivity` ONLY when the latest pending-attention event carries
>    the id (nil otherwise) — all table-checked in `ContinuumRevivedCoreChecks`.
> 6. **Checks (wired into the matrix; measured values printed; no `{passed:true}`):**
>    Core — flipped scope table (item 1); `approvalRequestId` round-trip + legacy key-absence;
>    inbox-rows/attention-count tables; respondable-request helper (nil-id → nil).
>    Sync real-path (`ContinuumRevivedSyncChecks`, B4 pattern — REAL `ActivityProjectionSender` +
>    `ApprovalResponder` + `ActivityProjectionReceiver` + fake seam over `FakeSyncTransport`):
>    (a) seed a pending approval event WITH `approvalRequestId` → receiver fold shows
>    `.needsAttention` + the id; (b) operator-scope respond `.accept` → seam invoked EXACTLY once
>    with (tileId, requestId, .accept), ack `.resolved`, resolution event flows sender→receiver,
>    folded status flips `.working` (the card-dismissal loop, measured); (c) SECOND identical
>    respond → ack `.stale`, seam invocation count STILL 1; (d) an observer-scope responder
>    instance → ack `.unauthorized`, seam never invoked (D6: the gate fires on every path);
>    (e) unknown requestId → ack `.unknownRequest`. Print observed acks, counts, statuses.
> 7. **ComponentLab (Dylan's 2026-07-04 directive):** iOS views exempt; the shared Core surface is
>    not — add an "Approvals Inbox" lab card (fixture snapshot, ≥2 `needsAttention` rows, one WITH
>    and one WITHOUT `approvalRequestId`, showing rows + attention count + a scope-gate outcome
>    line for observer vs operator) + its lab self-check, SAME commit (patterns: tickets 14/67,
>    B3's Agents Board card).
> 8. **Out of scope tonight (owed, never faked):** APNS push + lock-screen actions (B6);
>    deep-link validation incl. the malformed-URL logic case (B7 owns it); per-category settings
>    (B8); swipe-to-approve; phone-side `.acceptForSession`/`.cancel`; the ownership leg of
>    C-20260702-012 (ticket 70); production seam consumer + CK live leg (`publisher-owed` /
>    `device-gate-owed` → morning checklist). The ticket's HTTP status-code assertions and
>    `qa-runs/.../manifest.json` are VOID — superseded by item 6's Sync real-path check. The
>    real-device dogfood snippet: `device-gate-owed`.
> 9. **Gates:** (a) `swift build` clean; (b) `CONTINUUM_SKIP_SURFACE_CHECKS=1
>    ./scripts/run-matrix.sh` green incl. every new check; (c) `cd ios && xcodegen generate &&
>    xcodebuild -project Continuum.xcodeproj -scheme Continuum -destination 'generic/platform=iOS
>    Simulator' build` clean (`ios/project.yml` stays the source of truth). Ledger owed tags:
>    `visual-gate-owed` (simulator screenshots: card idle/resolving/stale/error + inbox with
>    badge), `device-gate-owed`, `publisher-owed`.
>
> **REV.2 — continuation adjudication (orchestrator, 2026-07-05, after 3 workflow rounds; B2/B3/B4
> precedent: bounded continuation before any skip row). Round-3 verdicts: both reviewers rejected
> with four concerns, all bounded. Rulings:**
> 1. **KindClassifier scope creep (both reviewers) — REVERT, ruled out-of-contract.** The
>    basename-split in `KindClassifier.swift` + its `SubstrateTests.swift` assertion are a rider on
>    a shared fleet-wide classifier that nothing in the approvals path uses. The orchestrator
>    reverts both files to HEAD directly (pure `git checkout`, no salvage needed). The idea itself
>    (normalize `/bin/zsh` → `.shell`) is plausibly useful — recorded in the ledger row as a
>    Track-A-tail candidate, NOT lost, NOT shipped unattended tonight.
> 2. **Duplicate-send hazard (Codex, binding fix):** in `PendingAttentionCard.submit`, a
>    `.resolved` or `.stale` ack must move the card to a terminal SETTLED state — spinner off,
>    BOTH buttons remain disabled until the projection removes the card (dismissal stays
>    projection-driven per banner item 4). `.unknownRequest` also settles (there is no valid
>    retry target; keep its "no longer available" note). ONLY `.unauthorized` and thrown
>    transport/send errors re-enable the buttons. Implement as one explicit terminal state (e.g.
>    `@State settled: Bool`) gating `.disabled(...)` alongside `resolving`/`gateHint`.
> 3. **Dead branch (Claude, cosmetic):** the `if outcome == .resolved || outcome == .stale`
>    with two identical `resolving = nil` branches collapses into the item-2 rework — no
>    identical-branch conditional survives.
> 4. **Process:** one continuation fix pass (codex-high per the escalation rule) implements items
>    2–3 ONLY (item 1 is an orchestrator revert; touch nothing else), re-proves all three gates
>    (swift build, matrix, iOS sim build), then a FRESH full dual review (Claude review model +
>    Codex) re-judges the whole diff. Both clear → commit; otherwise honest skip row.

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
