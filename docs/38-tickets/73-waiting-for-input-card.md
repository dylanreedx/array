# Distinct waiting-for-input card

## What this delivers

When a managed agent asks the user a question — "What should I name this file?", "Which
branch should I target?" — it emits a `user-input.requested` event rather than a permission
request. Today both kinds of interruption would collapse into the same approval dock (or
nothing at all). This ticket makes the distinction real and visible: a `user-input.requested`
event surfaces as its own card with a short inline answer field, clearly different in shape
and language from the approve/decline buttons of an approval request. The user can type a
reply directly in the card and submit it without switching to the terminal.

Both the approval dock and the user-input card map to `AgentStatus.needsAttention` — they
share the same urgency (orange `◆`, marching-ants border, sidebar "needs you" row) but
present completely different affordances. The approval dock says "may I?" with buttons; the
input card says "what do you think?" with a field.

On the system side, submitting the answer dispatches `respondToUserInput(requestId:
answers:)` through the managed agent adapter, clearing the pending input and returning
the agent to `working`. The round-trip is symmetric: the same command works from the Mac
view and, once the iOS observer app is built, from the phone.

## How it fits

This ticket lives inside the managed-agent tile, which is introduced by the managed-agent
tile scaffold (the ticket that adds `Tile.kind == .managedAgent` and its card-based view
layer). That scaffold gives the tile its card transcript, its persistent status header, and
the approval dock — all the structural chrome this ticket builds on top of.

The approval dock (also part of that scaffold) handles `request.opened` events. This ticket
adds the sibling affordance for `user-input.requested` events, keeping the two visually
distinct per locked decision D24. Both affordances depend on the attention border variant
already being wired: when `AgentStatus` is `needsAttention`, `CanvasNSView`'s
`FocusBorderOverlay` must already be painting in orange regardless of focus state. This
ticket inherits that border; it does not introduce it.

The `respondToUserInput` command dispatched here is the same shape as the approval
response — one path, identical on Mac and iOS — which is what later makes approving and
answering from the iOS observer trivially symmetrical (the iOS approve action ticket
consumes this seam unchanged).

The Component Lab gains a new static card for the user-input card itself, which slots into
the same `runSelfCheck()` sweep that gates the approval dock visually. Both are exercised
together when the Lab's self-check runs.

## The approach

Introduce a new `AgentUserInputRequest` model in `ContinuumRevivedCore`, parallel in shape
to `AgentApprovalRequest`. It carries a `requestId` (UUID), the `tileId` it belongs to,
the agent's question text (≤160 chars, sanitized at ingestion — the same I5 budget as
approval details), a status (`.pending` / `.resolved`), and the optional submitted answer.

The managed agent's event ingestion path (wherever `request.opened` events are already
handled) gains a sibling branch for `user-input.requested` that inserts an
`AgentUserInputRequest` into the pending-inputs store, keyed by `requestId`. The status
derivation function (`deriveAgentStatus`) consults both the pending-approvals set and the
pending-inputs set before any running/idle signal — either non-empty set returns
`needsAttention`. This preserves the priority ladder: pending input beats running, exactly
as pending approval does.

The view layer adds `UserInputCardView` — an `NSView` subcard that lives inside the managed
agent tile's scroll region, not pinned to the bottom edge the way the approval dock is.
When a `user-input.requested` event arrives, this card slides into the transcript at the
correct chronological position (after the last assistant message that triggered the
question). It shows the agent's question in a label, a single-line `NSTextField` for the
answer, and a "Submit" button. Pressing Return in the field or clicking Submit calls
`respondToUserInput`, clears the card, and lets the transcript resume.

Because the card appears inline in the transcript rather than as a bottom dock, the user
sees the context (what the agent was doing when it asked) immediately above the answer
field, without scrolling. This is the key UX difference from the approval dock, which is
anchored at the bottom edge of the tile.

Build and iterate the card in the Component Lab first, using a scripted fixture, before any
live adapter wires it. The Lab entry lets the card's layout, the field focus behavior, and
the submit-then-clear animation all be visually gated independently of a running agent.

## Where it lives

**Model — `Sources/ContinuumRevivedCore/`**

- New file `AgentUserInputRequest.swift` — defines `AgentUserInputRequest` (the struct
  described above) and `AgentUserInputStatus` (`.pending` / `.resolved`). Parallels the
  existing approval request shape from the t3code sketch in
  `docs/2026-06-30-t3code-steal/06-agent-ux-approvals-mobile-push.md` §2e.
- `AgentStatus` is already defined at `TerminalSessionDescriptor.swift:85`. No changes
  needed — `needsAttention` already covers both regimes.
- The status derivation function (introduced by the derive-agent-status ticket) needs to
  check `hasPendingUserInput` before running/idle, exactly as it checks
  `hasPendingApprovals`. Add a `hasPendingUserInput` parameter to its signature and update
  the priority ladder there.

**View — `Sources/ContinuumRevived/` (managed agent tile file)**

- `UserInputCardView` — the new `NSView` subcard. Contains an `NSTextField` (editable,
  single-line, placeholder "Type your answer…"), a label showing the agent's question, a
  Submit `NSButton`, and a small header label reading "Agent is asking:". The card's
  background is a rounded rect matching the managed tile's card-on-backdrop pattern, in a
  slightly warmer tint than tool-call cards to distinguish it at a glance.
- The managed agent tile's event sink, already handling `request.opened` for the approval
  dock, gains a branch for `user-input.requested` that instantiates and inserts
  `UserInputCardView` at the right position in the transcript stack.
- On submit, the card fades out (100 ms opacity animation), then removes itself from the
  hierarchy after the fade completes.

**Lab — `Sources/ContinuumRevived/App/ComponentLab.swift`**

- A new `LabEntry` in the `"Managed Agent"` category (alongside the approval dock entry).
  ID: `"managed.userInputCard"`. Content: `.staticCard(preferredSize: NSSize(width: 480,
  height: 160))` that constructs a `UserInputCardView` seeded with a fixture question ("What
  should I name the new migration file?") in `.pending` status.
- Append to `entries(env:)` at `ComponentLab.swift:355`.

**Check — `Sources/ContinuumRevived/Canvas/CanvasNSView.swift` (or a companion check file)**

- A real-path integration check that feeds a synthetic `user-input.requested` event through
  the managed tile's event sink and asserts the derived status flips to `needsAttention` and
  the pending-inputs count is 1. Then calls the respond path and asserts the count drops to
  0 and status returns to `working`. Writes measured values to `qa-runs/<ts>/user-input-card/manifest.json`.
  Pattern modeled on the existing `runAgentStatusBadgeSelfCheck` at
  `CanvasNSView.swift:3102`.

## Implementation breadcrumbs

```swift
// --- ContinuumRevivedCore/AgentUserInputRequest.swift ---

public enum AgentUserInputStatus: String, Codable, Equatable, Sendable {
    case pending
    case resolved
}

public struct AgentUserInputRequest: Codable, Equatable, Sendable {
    public let requestId: UUID
    public let tileId: UUID
    public let question: String      // ≤160 chars; sanitized at ingestion (I5)
    public var status: AgentUserInputStatus
    public var answer: String?       // nil until resolved
    public let createdAt: Date
}

// --- Extend the status derivation fn signature ---

// Before: deriveAgentStatus(tile:pendingApprovals:readerDerived:)
// After:  deriveAgentStatus(tile:pendingApprovals:pendingUserInputs:readerDerived:)
// Priority ladder (mirrors t3's resolveThreadAwarenessPhase):
//   1. pendingApprovals.contains(pending for this tile)  → .needsAttention
//   2. pendingUserInputs.contains(pending for this tile) → .needsAttention
//   3. readerDerived (working / idle / done / stale)

// --- UserInputCardView (NSView) ---

final class UserInputCardView: NSView {
    private let headerLabel: NSTextField    // "Agent is asking:"  small, muted
    private let questionLabel: NSTextField  // the agent's question text, wrapping
    private let answerField: NSTextField    // editable, single-line, placeholder "Type your answer…"
    private let submitButton: NSButton      // title "Submit", .bezelStyle = .rounded

    var onSubmit: ((String) -> Void)?       // answer text → caller dispatches respondToUserInput

    func configure(question: String) {
        questionLabel.stringValue = question
        answerField.stringValue = ""
        window?.makeFirstResponder(answerField)  // take focus so the user can type immediately
    }

    func dismissAnimated() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            self.animator().alphaValue = 0
        } completionHandler: {
            self.removeFromSuperview()
        }
    }
}

// --- Managed tile event sink branch ---

case .userInputRequested(let req):
    // Upsert into pending-inputs store (keyed by requestId)
    pendingUserInputs[req.requestId] = AgentUserInputRequest(
        requestId: req.requestId, tileId: tileId,
        question: String(req.question.prefix(160)),   // I5 cap
        status: .pending, answer: nil, createdAt: Date()
    )
    // Insert card into the transcript stack at the current insertion point
    let card = UserInputCardView()
    card.configure(question: req.question)
    card.onSubmit = { [weak self] answer in
        self?.respondToUserInput(requestId: req.requestId, answer: answer)
    }
    transcriptStack.insertArrangedSubview(card, at: transcriptStack.arrangedSubviews.endIndex)

// --- respondToUserInput ---

func respondToUserInput(requestId: UUID, answer: String) {
    // 1. Mark resolved in the pending store → hasPendingUserInput drops to false
    pendingUserInputs[requestId]?.status = .resolved
    pendingUserInputs[requestId]?.answer = answer
    // 2. Dispatch to the adapter (same call shape as respondToApproval)
    adapter.respondToUserInput(requestId: requestId, answers: ["response": answer])
    // 3. Re-derive AgentStatus — will now return .working if no other attention signals
    updateDerivedStatus()
    // 4. The card dismisses itself via onSubmit→dismissAnimated (called by the card)
}

// --- ComponentLab entry ---

private static var userInputCard: LabEntry {
    LabEntry(
        id: "managed.userInputCard",
        category: "Managed Agent",
        title: "User Input Card",
        summary: "Inline answer-field card for agent questions (user-input.requested). " +
                 "Distinct from the approval dock — field instead of buttons.",
        content: .staticCard(preferredSize: NSSize(width: 480, height: 160)) {
            let card = UserInputCardView(frame: NSRect(x: 0, y: 0, width: 480, height: 160))
            card.configure(question: "What should I name the new migration file?")
            return card
        }
    )
}
// Append userInputCard to entries(env:) at ComponentLab.swift:355
```

## How we test it

### Logic (pure Core checks)

Write table-driven tests in `ContinuumRevivedCoreTests` for the updated status derivation function. Cover every row in the priority ladder:

- A tile with one pending approval and no pending inputs returns `.needsAttention`.
- A tile with no pending approvals but one pending input returns `.needsAttention`.
- A tile with both pending returns `.needsAttention` (not a different value — both collapse identically).
- A tile with zero pending of either kind, and a reader-derived `working` signal, returns `.working`.
- Resolving the pending input (status flips to `.resolved`) and re-deriving with a `working` reader signal returns `.working`.
- An empty (unknown/nil) reader-derived signal with no pending of either kind returns `.stale` (or whatever the derivation's under-claim floor is) — never fabricates `working`.

These are pure function calls with no app state; they run headlessly in the matrix.

### Backend (real-path integration)

Add a check (following the `runAgentStatusBadgeSelfCheck` pattern at
`CanvasNSView.swift:3102`) that exercises the full event → store → derive → view path
without bypassing any layer:

1. Construct a managed tile view in a test window (no ghostty surface needed — this is an
   AppKit card view).
2. Push a synthetic `user-input.requested` event through the tile's event sink (the same
   function the live adapter will call).
3. Assert: `pendingUserInputs.count == 1`; derived status is `.needsAttention`; the
   transcript stack contains exactly one `UserInputCardView`; the card's question label
   matches the fixture question.
4. Simulate a submit (call `respondToUserInput(requestId:answer:)` directly on the tile
   view, as a UI action would).
5. Assert: `pendingUserInputs[requestId]?.status == .resolved`; derived status is `.working`
   (given a `working` reader-derived baseline); the `UserInputCardView` has been removed from
   the transcript stack (alpha 0 or removed from superview).
6. Write observed values to `qa-runs/<timestamp>/user-input-card/manifest.json`:
   ```json
   {
     "pendingInputCountBefore": 1,
     "derivedStatusBefore": "needsAttention",
     "cardPresentBefore": true,
     "pendingInputCountAfter": 0,
     "derivedStatusAfter": "working",
     "cardPresentAfter": false
   }
   ```

This check is a real path through the production executor. It does not set
`status = .needsAttention` directly and assert it back — it feeds the event and asserts
the derived consequence.

### UX (visual gate + dogfood snippet)

The Component Lab self-check (`runSelfCheck()` at `ComponentLab.swift:711`) automatically
picks up the new `"managed.userInputCard"` entry because it iterates `qaEntries()` and
snapshots every `.staticCard`. It renders the card over an opaque dark (`0.12` grey)
backdrop, calls `bitmapImageRepForCachingDisplay`, and asserts `VisualSnapshot.metrics` are
not blank (not zero-sized, not one flat color). The PNG is written to the `qa-runs`
directory alongside the approval dock and sidebar snapshots. No extra wiring is needed
beyond appending the entry.

**Dogfood snippet.** Open the app, then open the Component Lab with `Control-Space` followed
by the "Component Lab" launcher (or via the Debug menu if wired). In the left entry list,
expand "Managed Agent" and select "User Input Card". You should see exactly: a card on a
dark background with a small muted header reading "Agent is asking:", below it the fixture
question "What should I name the new migration file?" in normal weight, below that a
single-line text field with placeholder text "Type your answer…", and a rounded "Submit"
button to its right. The answer field should receive keyboard focus automatically. Type a
short answer and press Return — the card should fade out in roughly 100 ms and disappear.
If the card is blank, or the question text is absent, or the field does not accept input, or
pressing Return does nothing, the gate fails.

To see the attention state integration, if the managed-agent tile scaffold is already
present: open a managed agent tile that has a pending user-input request (fire one via the
fixture toolbar's "Fire user input" button). Confirm the tile header switches to the orange
`◆` glyph and the "needs you" label, the marching-ants border appears in orange around the
tile, and the user-input card appears inline in the transcript — not at the bottom edge
where the approval dock would appear. Submit the answer and confirm the header returns to
blue `●` and the border clears.

## Execution mode

Supervised. The Logic checks run headlessly and the Backend check runs without a display,
but the UX gate requires a real app launch to confirm the card layout, field focus behavior,
fade-out animation, and the inline positioning of the card within the transcript. The dogfood
snippet above is the non-bypassable visual gate. A green matrix without a human eyes pass
on the Lab entry does not constitute "done" for this ticket, per the verification doctrine.

## Done when

- [ ] `AgentUserInputRequest` and `AgentUserInputStatus` are defined in
  `ContinuumRevivedCore` and compile cleanly.
- [ ] The status derivation function accepts a `pendingUserInputs` parameter and the
  priority-ladder table tests all pass headlessly.
- [ ] Feeding a `user-input.requested` event through the managed tile's event sink inserts
  exactly one `UserInputCardView` into the transcript stack.
- [ ] Calling `respondToUserInput` marks the request resolved, re-derives status to
  `.working`, and removes the card from the transcript (confirmed by the Backend check
  manifest).
- [ ] The `"managed.userInputCard"` Lab entry is present in the catalog, renders a non-blank
  card snapshot under `runSelfCheck()`, and the PNG is written to `qa-runs`.
- [ ] The dogfood snippet executes without error: card visible, field focusable, Return
  submits, card fades out.
- [ ] The card appears inline in the transcript (chronological position), not pinned to the
  tile's bottom edge (that position is reserved for the approval dock).
- [ ] The question text is capped at 160 characters at ingestion; a fixture question longer
  than 160 chars is truncated before it reaches the label.
- [ ] No transcript body text (the agent's question verbatim from the event payload) appears
  in any synced or projected payload — the sync boundary carries only the derived
  `AgentStatus` and sanitized metadata (I5 invariant).

## Depends on / unblocks

This ticket depends on the managed-agent tile scaffold — the tile must already exist as
`Tile.kind == .managedAgent` with a card transcript and a working event sink — and on the
attention border variant being wired into `CanvasNSView`'s `FocusBorderOverlay` (the orange
marching-ants treatment for any tile in `needsAttention` state, regardless of focus). Both
of those are earlier tickets in the managed-agent tier. The approval dock must also be
present, because this ticket introduces the sibling affordance alongside it, and the two
share the same underlying `needsAttention` status signal.

This ticket unblocks the iOS approve action ticket's extension to user-input answering: once
`respondToUserInput` exists as a named, symmetric command on the Mac, the iOS surface can
call it identically without any adapter work on the iOS side.

## Watch out for

**The card must not replace the approval dock when both are pending at once.** A managed
agent could, in theory, emit a `request.opened` and a `user-input.requested` in the same
session. Both must coexist in the transcript simultaneously: the approval dock remains pinned
at the bottom, and the user-input card appears inline at its chronological position above
the dock. The status derivation correctly returns `needsAttention` for either (both are in
the same pending set), so status is not the risk — the risk is the view layer rendering one
and discarding the other. Confirm the "both pending" case with a fixture before shipping.

**Field focus must not steal from the tile's own focus model.** The managed tile's answer
field calls `window?.makeFirstResponder(answerField)` when the card appears. This must only
fire when the managed tile itself is the focused tile (i.e., in the canvas scope). If the
user is working in a different tile and a user-input request arrives, the border and status
should update, but the answer field must not yank keyboard focus away from wherever the user
is. Gate the `makeFirstResponder` call on the tile being the current canvas focus target.

**Question text sanitization is mandatory at ingestion, not at display.** The 160-character
cap and any stripping of unsafe content must happen when the `user-input.requested` event
is first processed, before the text is stored in `AgentUserInputRequest.question`. Do not
rely on the label's layout to truncate — store the already-sanitized string, so the Backend
check can assert the stored value is within bounds, not just that it renders truncated.

**The card's answer must never travel over the sync/observation boundary.** The submitted
answer goes to the adapter and stays local (it may appear in the transcript for reference,
stored locally). It is not part of the sanitized awareness projection that crosses to iOS or
any relay. The I5 taint scan (the taint-scan harness from the invariant-spine ticket) must
be run over the projected payload after a user-input submission to confirm the answer text
is absent.
