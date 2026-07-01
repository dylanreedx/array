# Approval dock & attention border

## What this delivers

After this ticket, a managed-agent tile that is waiting for a human decision becomes unmissable from anywhere in the app. Three coordinated surfaces activate the moment a `request.opened` event arrives from the tile's adapter: an **inline approval dock** slides up from the bottom of the managed tile, presenting the request kind, a sanitized detail line, and three decision buttons (Approve / Approve for session / Decline); an **orange marching-ants focus border** rings the entire tile on the canvas regardless of which tile currently holds keyboard focus; and the sidebar dock's tile row and zone-rollup count both flip to orange and display "needs you" language. All three surfaces clear the instant the human responds, and the tile's status recomputes back to `working` or `idle`.

From a system perspective, the payoff is the direct closure of the "orange that isn't real" trust problem. Before this ticket, `needsAttention` on a managed tile is a state that can be set but has no authoritative visual consequence beyond a badge. After this ticket, a pending approval is *the* single authoritative source of `needsAttention` for managed agents (D23), and every visual surface that carries status is driven by that one source — nothing is fabricated, nothing is missed.

## How it fits

This ticket builds on two things that must already exist: the `AgentApprovalRequest` type and pending-approval store (the pure-Core approval model, which establishes the `[UUID: AgentApprovalRequest]` pending set and the `deriveAgentStatus` pure function that checks it above any running signal), and the managed-agent tile kind itself (which introduces `.managedAgent` as a `Tile.kind` and the card-based structured transcript view that this dock anchors to).

The orange attention border in `FocusBorderOverlay` — already config-driven and already tracking pan/zoom — is a new *trigger and color*, not new drawing machinery. That view already knows how to render an animated marching-ants dashed ring at any color its `configure(color:gap:animationDuration:)` call specifies; it already repositions itself on every pan/zoom event. This ticket teaches `CanvasNSView` to maintain a second, parallel set of "attention-bordered" tile IDs (distinct from the single focus-bordered tile ID), query them from the live `AgentStatus` of every installed tile view, and apply the overlay in orange when a tile is `needsAttention` regardless of focus.

The sidebar rollup (`SidebarAgentStatusRollup.dominantKind`) already encodes the precedence `needsAttention > working > ...` and already drives the zone row's color; this ticket's wiring contribution is ensuring the live pending-approval status propagates into `agentStatusesByTileId` so those already-built displays light up for real.

This ticket directly unblocks the iOS observer's approval affordance (which needs the same `respondToApproval` command path to be proven on Mac first) and the APNS push wiring (which fires on entry into `needsAttention` — it needs a confirmed, real-path `needsAttention` signal to trigger from).

## The approach

The work breaks cleanly into three layers: the Core model additions, the canvas attention-border mechanism, and the managed-tile view's approval dock.

**Core additions (pure, no AppKit).** Add two new types to `ContinuumRevivedCore`. First, `ApprovalDecision` — a `Codable`, `Sendable` enum with cases `accept`, `acceptForSession`, `decline`, and `cancel` (mirroring t3code's `ProviderApprovalDecision` exactly, because the command is symmetric across Mac and iOS). Second, `ApprovalRequestKind` — a `Codable`, `Sendable` enum covering `commandExecution`, `fileRead`, `fileChange`, `applyPatch`, and `userInput`, mapping to t3code's `CanonicalRequestType`. The existing `AgentApprovalRequest` type (introduced by the pending-approval store ticket) already carries `requestId: UUID`, `tileId: UUID`, `kind: ApprovalRequestKind`, `detail: String?` (capped at 160 characters, sanitized), `status: ApprovalStatus` (`.pending` / `.resolved`), and `decision: ApprovalDecision?`. No new Core model types are needed beyond these two enums.

Add a `respondToApproval(requestId: UUID, decision: ApprovalDecision)` method to the approval store. This method resolves the pending row (sets `status = .resolved`, `decision = decision`) and notifies the adapter. It is the single method both the Mac dock buttons and the future iOS observer call — the symmetric respond command (D23).

**Canvas attention-border.** `CanvasNSView` gains an `attentionTileIds: Set<UUID>` property tracking which installed tile views are currently `needsAttention`. A new private `applyAttentionBorders()` method iterates the attention set, finds each tile's view frame, and calls a second shared `FocusBorderOverlayView` instance (or one overlay per attention tile — see "Watch out for") configured with `NSColor.systemOrange.withAlphaComponent(0.8)` and a faster march speed of `1.4` seconds (distinctly faster than the focus border's default 2.5 s, so the two can visually coexist if a focused tile is also waiting). This method is called whenever any installed tile's `agentStatus` changes to or from `needsAttention`. `repositionFocusBorderIfNeeded` already handles pan/zoom tracking for the focus overlay; the same repositioning path is extended to cover attention overlays.

**Orange takes precedence when a tile has both focus and attention.** When `borderedTileId` equals a tile in `attentionTileIds`, `applyFocusBorder()` suppresses the accent-color overlay for that tile (the attention overlay is already drawing over it in orange). A comment in code makes this precedence explicit.

**Managed tile approval dock.** The managed-agent tile view (`ManagedAgentTileView` or its equivalent AppKit class introduced by the managed-tile-kind ticket) gains a private `ApprovalDockView`. This view is hidden by default and slides up from the tile's bottom edge when `pendingApprovalRequest` is set to a non-nil value. The dock shows:

- A header row: a small orange `⚠` glyph + the label `"Approval needed"` in `.systemOrange`.
- A detail line: `requestKind.displayName + ": " + sanitizedDetail` in secondary text, using `SF Mono` for the detail value so command strings and file paths render legibly. If `detail` is nil the detail line is omitted.
- Three buttons in a horizontal stack: `Approve`, `Approve for session`, and `Decline`. `Approve` and `Approve for session` use `.systemOrange` as the button bezel tint; `Decline` uses the secondary label color. Tapping any button calls `respondToApproval(requestId:, decision:)` and then immediately hides the dock optimistically (the status recomputation will confirm).

The dock slides in with a 220 ms ease-out `NSAnimationContext` on the `frame` rather than an `isHidden` toggle, so the motion reads as the dock arriving from below the tile edge. On dismiss it slides back down and hides. Both directions respect `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` (jump-cut when true).

**Sidebar and zone-rollup wiring.** No new view code is needed. The sidebar and zone-rollup already render correctly for `needsAttention` — the work here is confirming that the live pending-approval status from the managed tile propagates into the `agentStatusesByTileId` dictionary that feeds `SidebarTreeBuilder.build(...)`. The observer/update path already writes `agentStatus` from `tileView.agentStatus` into that dictionary; as long as the managed tile's `agentStatus` property updates to `.needsAttention` when a pending approval arrives (which `deriveAgentStatus` guarantees), the sidebar wires up for free.

## Where it lives

**New files:**

- `Sources/ContinuumRevivedCore/ApprovalDecision.swift` — `ApprovalDecision` and `ApprovalRequestKind` enums + `ApprovalRequestKind.displayName: String` computed property.
- `Sources/ContinuumRevived/Canvas/ApprovalDockView.swift` — the `NSView` subclass for the inline dock, self-contained, no canvas dependency. Exposes a `var pendingRequest: AgentApprovalRequest? { didSet { updateVisibility() } }` and a `var onDecision: ((ApprovalDecision) -> Void)?` callback.

**Modified files and key symbols:**

- `Sources/ContinuumRevivedCore/FocusBorderConfig.swift` — add `attentionColor: String = "Orange"` as a new non-configurable constant (not user-overridable; the attention color is a system semantic, not a preference), and `attentionSpeed: Double = 1.4` alongside the existing `defaultSpeed`. `"Orange"` is already in `colorOptions` at line 22 of this file.
- `Sources/ContinuumRevived/Canvas/CanvasNSView.swift` — `applyFocusBorder()` at line 696 extended to suppress the accent overlay for tiles in `attentionTileIds`; new `private(set) var attentionTileIds: Set<UUID> = []`; new `private func applyAttentionBorders()`; new `func updateAttentionBorder(for tileId: UUID, status: AgentStatus?)` called from the tile-status-update path. `AgentStatusRollup` at line 45 is already tracking `needsAttention: Int` in the zone-chrome rollup model — no change needed there.
- `Sources/ContinuumRevived/Canvas/TileNSView.swift` — `agentStatus` didSet at line 46 already propagates to the title bar; extend it to also notify the canvas (`canvas?.updateAttentionBorder(for: tile.id, status: agentStatus)`) so the attention overlay responds to live status changes without polling.
- The managed-agent tile view (introduced by the managed-tile-kind ticket) — install `ApprovalDockView` as a subview, wire `pendingRequest` from the tile's live approval state, route `onDecision` to `respondToApproval`.
- `Sources/ContinuumRevived/App/ComponentLab.swift` — add a new `LabEntry` with `id: "managed-agent.approval-dock"`, `category: "Managed Agent"`, and a `staticCard` that renders the managed tile's chrome in the three reading states (working, waiting, done) seeded from fixture data. The waiting state uses a scripted `AgentApprovalRequest` with `kind: .commandExecution` and `detail: "npm test"`.

## Implementation breadcrumbs

```swift
// --- ApprovalDecision.swift (Core, no AppKit) ---
public enum ApprovalDecision: String, Codable, Equatable, Sendable {
    case accept, acceptForSession, decline, cancel
}

public enum ApprovalRequestKind: String, Codable, Equatable, Sendable {
    case commandExecution, fileRead, fileChange, applyPatch, userInput
    public var displayName: String {
        switch self {
        case .commandExecution: return "Run command"
        case .fileRead:         return "Read file"
        case .fileChange:       return "Edit file"
        case .applyPatch:       return "Apply patch"
        case .userInput:        return "Answer needed"
        }
    }
}

// --- FocusBorderConfig.swift additions ---
public static let attentionColor: String = "Orange"   // semantic, not user-configurable
public static let attentionSpeed: Double = 1.4        // faster than focus to distinguish

// --- CanvasNSView.swift: attention overlay management ---
private(set) var attentionTileIds: Set<UUID> = []

func updateAttentionBorder(for tileId: UUID, status: AgentStatus?) {
    let wasAttention = attentionTileIds.contains(tileId)
    let isAttention  = status == .needsAttention
    guard wasAttention != isAttention else { return }
    if isAttention { attentionTileIds.insert(tileId) }
    else           { attentionTileIds.remove(tileId) }
    applyAttentionBorders()
}

private func applyAttentionBorders() {
    // Remove stale overlays for tiles no longer in the attention set.
    // Add/reposition overlays for tiles in the attention set.
    // Each attention overlay uses:
    //   color: Self.focusBorderColor(named: FocusBorderConfig.attentionColor).withAlphaComponent(0.8)
    //   gap: CGFloat(FocusBorderConfig.defaultGap)   // same gap as focus border
    //   animationDuration: FocusBorderConfig.attentionSpeed
    // When borderedTileId is in attentionTileIds, suppress focusBorderOverlay for it:
    //   attention-orange takes precedence — applyFocusBorder() checks this condition.
}

// --- TileNSView.swift: notify canvas on status change ---
var agentStatus: AgentStatus? {
    didSet {
        titleBar?.agentStatus = agentStatus
        canvas?.updateAttentionBorder(for: tile.id, status: agentStatus)
    }
}

// --- ApprovalDockView.swift: the dock ---
final class ApprovalDockView: NSView {
    var pendingRequest: AgentApprovalRequest? {
        didSet { configure(with: pendingRequest); animateIn(pendingRequest != nil) }
    }
    var onDecision: ((ApprovalDecision) -> Void)?

    private func configure(with request: AgentApprovalRequest?) {
        guard let request else { return }
        headerLabel.stringValue = "Approval needed"
        // detail: request.kind.displayName + ": " + (request.detail ?? "")
        // three buttons wired to onDecision(.accept), .acceptForSession, .decline
    }

    private func animateIn(_ show: Bool) {
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduced { isHidden = !show; return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = show ? 1 : 0
            // shift frame.origin.y by dockHeight to slide up from below tile edge
        } completionHandler: { [weak self] in
            if !show { self?.isHidden = true }
        }
    }
}
```

The lab fixture for visual gating:

```swift
// ComponentLab.swift — new category "Managed Agent"
LabEntry(
    id: "managed-agent.approval-dock",
    category: "Managed Agent",
    title: "Approval dock — three states",
    summary: "Working header, then waiting with dock + orange border, then done.",
    content: .staticCard(preferredSize: NSSize(width: 480, height: 520)) {
        // Build a ManagedAgentTileChrome view with three vertically-stacked states:
        // 1. agentStatus = .working      → blue ● header, no dock
        // 2. agentStatus = .needsAttention,
        //    pendingRequest = AgentApprovalRequest(kind: .commandExecution,
        //                                         detail: "npm test", ...)
        //    → orange ◆ header, dock visible, orange border drawn around tile frame
        // 3. agentStatus = .done         → green ✓ header, no dock
        ManagedAgentStatesPreview()
    }
)
```

## How we test it

### Logic (pure Core checks)

The pure `deriveAgentStatus(tile:pending:)` function must be tested exhaustively for priority. Table-drive these cases:

- A tile with a non-empty pending set (status `.pending`) and a `readerDerivedStatus` of `.working` must return `.needsAttention`. This is the priority ladder: approval wins over running.
- A tile with an empty pending set and `readerDerivedStatus = .working` must return `.working`.
- A tile whose only pending approval has `status = .resolved` must not return `.needsAttention` — resolved rows are inert.
- Multiple pending approvals for the same tile: `.needsAttention` regardless of count.

`ApprovalRequestKind.displayName` must produce a non-empty, human-readable string for every case (exhaustive switch test, no fallthrough).

`ApprovalDecision` must round-trip through `JSONEncoder`/`JSONDecoder` for all four cases.

### Backend (real-path integration)

The check must feed a real `request.opened` event through the managed-tile adapter path — not call `tile.agentStatus = .needsAttention` directly and assert it — and observe the downstream effects on live objects.

Concretely: install a `ManagedAgentTileView` into a real `CanvasNSView` with a seeded `AgentApprovalRequest` in the pending store. Call the adapter's event-dispatch path for `request.opened` with a `commandExecution` payload. Then assert:

1. `canvas.agentStatus(for: tileId) == .needsAttention` — the tile view's status updated.
2. `canvas.attentionTileIds.contains(tileId)` — the canvas registered the attention tile.
3. `canvas.qaAttentionBorderActive(for: tileId) == true` — the overlay is visible and animating at the tile's frame outset.
4. The managed tile view's `approvalDockView.isHidden == false` — the dock is visible.
5. The dock's detail label text contains `"Run command"` and the sanitized detail string.

Then call `respondToApproval(requestId:, decision: .accept)` through the same store path and assert: `canvas.agentStatus(for: tileId) != .needsAttention`, `canvas.attentionTileIds.isEmpty`, and `approvalDockView.isHidden == true`.

Write a manifest at `qa-runs/<timestamp>/approval-dock/manifest.json` carrying: `pendingApprovalTileStatus`, `attentionBorderActive`, `dockVisible`, `detailLabelText`, `postRespondStatus`, `postRespondDockVisible`. Values must be measured from live objects, not asserted as `true/false` booleans.

### UX (visual gate + dogfood snippet)

**Visual gate.** Add the `"managed-agent.approval-dock"` lab entry to `ComponentLab.runSelfCheck()`. The self-check already renders every `staticCard` entry over an opaque dark backdrop and asserts `!metrics.isBlank`. The lab card renders all three reading states (working / waiting / done) so the gate catches a blank dock, a missing header glyph, and a degenerate approval dock in a single pass. The PNG is written to `qa-runs/<timestamp>/component-lab/managed-agent.approval-dock.png`.

In addition, snapshot the second state in isolation — the waiting state with the orange dock visible — and assert `metrics.distinctSampledColors >= 6`. A blank or mono-color render means the dock failed to draw; six distinct sampled colors is a loose but meaningful floor for a view containing text labels, button bezels, an orange accent header, and a dark tile background.

**Dogfood snippet.**

Open the app → `Control-Space` then type "Component Lab" → select the "Managed Agent" category in the left nav → select "Approval dock — three states" → see exactly:

- Top tile: a blue `●` glyph in the header next to "Claude · feature/auth", label reads `working · 0:14`, no dock visible below the card area.
- Middle tile: the header glyph has changed to an orange `◆`, the label reads `needs you`, a dashed **orange border rings the entire tile** (marching, visibly faster than the focus border on any other tile), and below the last tool-call card a panel has slid up reading "⚠ Approval needed" in orange, with the detail line "Run command: `npm test`" in monospace, and three buttons: `[ Approve ]` `[ Approve for session ]` `[ Decline ]` — the first two tinted orange, the last in secondary gray.
- Bottom tile: a static green `✓`, label reads `done · 1:03`, no dock.

Then in the real canvas: spawn a managed-agent tile (Component Lab sandbox → "Managed Agent" sandbox entry → fire the "Trigger approval" fixture button in the toolbar) → see the tile's header flip from blue to orange, the dock slide up, and a matching orange dashed ring appear around that tile on the canvas. Click `Approve` → see the dock slide down and disappear, the header return to blue `● working`, and the orange ring clear. Elapsed time from click to cleared ring should be under one second with no intermediate blank state.

## Execution mode

**Supervised.** The approval dock slide animation, the orange border color against the canvas background, the readability of the monospace detail line at the tile's default zoom level, and the motion contrast between the faster attention ring and the standard focus ring all require a real-app visual pass to validate. The logic and backend checks prove the plumbing; they do not prove that the orange is the right orange, that the dock doesn't clip the tile's bottom edge, or that the animation reads as a "slide up" rather than a fade. Dylan's dogfood pass over the Component Lab entry is the gate.

## Done when

- [ ] `ApprovalDecision` and `ApprovalRequestKind` compile in `ContinuumRevivedCore` with no AppKit import; all four decision cases and all five request kind cases are exhaustively handled in every switch site.
- [ ] `FocusBorderConfig` carries `attentionColor = "Orange"` and `attentionSpeed = 1.4` as named constants; no magic literals appear in the canvas attention-border code.
- [ ] `CanvasNSView.attentionTileIds` is non-empty while any installed tile view reports `agentStatus == .needsAttention`; it is empty once all such tiles resolve.
- [ ] `CanvasNSView.qaAttentionBorderActive(for:)` returns `true` for every tile ID in `attentionTileIds` and `false` for all others.
- [ ] A focused tile that is also in `attentionTileIds` shows the orange attention ring only — the accent-color focus overlay is suppressed for that tile, and a code comment explains the precedence rule.
- [ ] `ApprovalDockView` renders with the correct kind display name, the sanitized detail string in `SF Mono`, and three decision buttons; its `isHidden` is `false` when `pendingRequest != nil` and `true` after `onDecision` fires.
- [ ] Calling `respondToApproval` from the dock clears the pending-approval row, removes the tile from `attentionTileIds`, hides the dock, and causes `deriveAgentStatus` to return a non-`needsAttention` value — all verified by the backend real-path check.
- [ ] The `"managed-agent.approval-dock"` lab entry exists and passes `ComponentLab.runSelfCheck()` with `!metrics.isBlank` and `metrics.distinctSampledColors >= 6` for the waiting-state snapshot.
- [ ] The dogfood snippet produces exactly the described visual output: orange `◆` header, orange marching-ants ring faster than the standard focus ring, dock with correct text and buttons, clean dismiss on Approve.
- [ ] `detail` is capped at 160 characters before being stored in `AgentApprovalRequest.detail`; a test confirms strings longer than 160 characters are truncated and shorter ones pass through unchanged.
- [ ] `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == true` in a test environment causes the dock to appear/disappear without animation (instant `isHidden` toggle, no frame shift).

## Depends on / unblocks

This ticket depends on the pure-Core approval model (the `AgentApprovalRequest` type, the pending-approval store, and the `deriveAgentStatus` pure function that checks the pending set above any running signal). It also depends on the managed-agent tile kind being introduced — the approval dock is a subview of the managed tile's view, not a floating overlay, and it assumes `ManagedAgentTileView` exists as an installable `TileNSView` subclass before this ticket starts.

This ticket directly unblocks the iOS observer's approval affordance, because the `respondToApproval(requestId:, decision:)` command path proven here is the identical call the iOS surface will dispatch. It also unblocks the APNS push wiring, which monitors status transitions into `needsAttention` and fires a push on the first entry — that wiring is meaningless until a confirmed real-path `needsAttention` signal exists to trigger it. The sidebar activity dock wiring (which feeds `agentStatusesByTileId` from real observer data rather than mock fixtures) can proceed in parallel but benefits from confirming the `needsAttention` propagation chain here first.

## Watch out for

**One overlay instance versus one per tile.** The current `FocusBorderOverlay` is a single instance tracking one tile at a time (focus is single-tile by definition). The attention set can contain multiple tiles simultaneously — every managed-agent tile currently waiting for an approval gets a ring. The implementation must decide: one overlay per attention tile (straightforward, but requires bookkeeping a `[UUID: FocusBorderOverlayView]` map and ensuring stale overlays are removed), or a single overlay animated to track one tile at a time (wrong for the multi-tile case). Use one overlay per attention tile. This is a named risk because the existing single-overlay pattern looks tempting to extend but is the wrong shape for a set.

**Overlay z-ordering after tile install/reorder.** `applyFocusBorder()` already re-adds the focus overlay above all subviews after every call (`overlay.removeFromSuperview(); addSubview(overlay, positioned: .above, relativeTo: nil)` at `CanvasNSView.swift:711-712`). The attention overlays must do the same — any newly installed tile view will be added above a previously-positioned attention overlay, silently hiding it. Call `removeFromSuperview(); addSubview(_:positioned:relativeTo:)` for every attention overlay any time the canvas subview order changes.

**Dock slide-up clipping at tile bottom edge.** If the managed tile's content view clips to bounds, the dock's initial off-screen position (below the tile edge) will be invisible before the animation starts rather than appearing to slide in. The dock should be added as a sibling overlay anchored to the tile's bottom edge, not as a subview of the scrollable transcript, so the animation origin is outside the clip region and the slide reads correctly.

**`detail` sanitization must happen at ingestion, not at display time.** The 160-character cap and any failure-text redaction must be applied when the `AgentApprovalRequest` is first constructed from the adapter event — not in the dock's display code. If sanitization happens at display time, the raw unsanitized string is briefly stored in a type that crosses the managed-session store, violating I5 even if it never reaches the sync boundary. Cap at ingestion; the dock trusts that `request.detail` is already clean.

**Stop condition: if the managed-tile-kind ticket does not exist.** This ticket's dock is a subview of `ManagedAgentTileView`. If that class does not yet exist (the managed-tile-kind ticket has not landed), stop and block on it rather than introducing a parallel `ManagedAgentTileView` stub that will conflict. The attention border mechanism in `CanvasNSView` is independent and can be built and tested in isolation against any `TileNSView` with `agentStatus = .needsAttention`, but the dock cannot ship without its parent view.
