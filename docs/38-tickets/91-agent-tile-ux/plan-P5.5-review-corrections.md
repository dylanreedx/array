# P5.5 review corrections — plan

Drafted 2026-08-03 during the P5.5 supervised acceptance session. **Plan only — no code has
changed.** Six defects were found by the owner exercising the installed v2 candidate
(`CONTINUUM_AGENT_TILE_V2=1`). All six are live-only: every deterministic gate is green because
the gates render offscreen, drive events without a real runner process, or bypass the
canvas/focus path. Each fix below therefore ships with a gate that would have caught it.

All corrections land under P5.5 (same pattern as the P3.12 owner corrections), **before**
packet step 5 (flip default / delete the legacy path). Not a new packet — the packet count and
queue are untouched.

## Fence exceptions to document in the ledger before editing

P5.5's fence is `ManagedAgentTileNSView.swift`, `TranscriptCardViews.swift`,
`ManagedTranscriptCardProjection.swift`, `ComponentLab.swift`, baselines, `qa-runs/`. These
corrections additionally need (owner present at this supervised gate):

- `Sources/ContinuumRevived/App/AgentSupervisor.swift` — capability-change seam (defect 1)
- `Sources/ContinuumRevived/Canvas/AgentComposer/AgentComposerView.swift` — action-task latch,
  focus hardening (defects 3, 5)
- `Sources/ContinuumRevived/Canvas/AgentComposer/AgentComposerFooterView.swift` and
  `.../ChoiceButton.swift` — footer layout and title measurement (defect 4)
- `Sources/ContinuumRevived/Canvas/AgentTranscript/AgentTranscriptListView.swift` — transcript
  background (defect 6)
- `Sources/ContinuumRevived/App/UIProbeGeometry.swift` (or the supervisor check file) — new gates

---

## Defect 1 — composer latches "Unavailable" after the first successful turn

### Symptom

Send one prompt; the agent replies; the action button reads "Unavailable" and stays that way.
Enter does nothing. The supervisor would accept a send — the tile never asks again.

### Root cause (repaint gap, not a state bug)

1. `send()` parks the runner: `runners[id] = runner` (`AgentSupervisor.swift:407`).
   `canSend = !occupied && state.acceptsNewTurn` where `occupied = runners[id] != nil`
   (`AgentSupervisor.swift:1203-1207`). This rule is correct and pinned by a check — a second
   `send` while a runner is in flight really is refused (`:393-396`).
2. The Pi process prints its terminal events (`turn_end` → `.turnCompleted`,
   `agent_settled` → `.sessionStateChanged(.ready)`) **before it exits**
   (`PiEventTranslator.swift:106-115`; `PiAgentRunner.run` blocks on `waitUntilExit`,
   `PiAgentRunner.swift:211`). So at the last event the tile will ever ingest,
   `occupied == true` → it caches `.ready` + `canSend:false`
   (`ManagedAgentTileNSView.swift:459-463`) → `AgentComposerPresentation.resolve` maps
   `.ready` + `!canSend` to `title:"Unavailable", isEnabled:false`
   (`AgentComposerPresentation.swift:109-118`).
3. Milliseconds later the process exits and `clearRunner` frees the slot
   (`AgentSupervisor.swift:428, 1601-1605`) — **emitting no event, notifying nobody**. The
   tile refreshes its snapshot only inside `ingest(_:)`; no further event ever arrives.
4. Even typing can't rescue it: `updateV2ComposerPresentation` reads the cached
   `v2TurnSnapshot` (`ManagedAgentTileNSView.swift:803`), and the keyboard path derives intent
   from the composer's own cached snapshot — `primaryIntent` returns `nil` when `!canSend`
   (`AgentComposerIntent.swift:135-139`), so Enter is silently dead.

### Why gates missed it

`checkLiveV2TileMigration` spawns with `prompt: nil` and drives events via `qaDeliver` — no
runner ever exists, `occupied` is always false (`AgentSupervisor.swift:3291-3423`). The
production race (terminal events arriving while the runner slot is still held) is
unrepresented.

### Fix (capability-truthful: re-read the supervisor's own truth when it changes)

**1a. Capability-change seam on the supervisor.** No fabricated events, no polling — a plain
notification fired wherever `runners` mutates:

```swift
// AgentSupervisor
var onTurnCapabilitiesChanged: ((AgentID) -> Void)?   // main-actor

private func runnersDidChange(for id: AgentID) { onTurnCapabilitiesChanged?(id) }
// call after: runners[id] = runner   (send, :407)
//             runners[id] = nil      (stop, :441; clearRunner, :1604)
```

**1b. Tile subscribes in `attach`, re-runs the exact refresh `ingest` already does:**

```swift
// ManagedAgentTileNSView.attach(...)
supervisor.onTurnCapabilitiesChanged = { [weak self] id in
    guard let self, id == self.attachedAgentID else { return }
    self.refreshV2TurnSnapshot()   // = lines 459-463 + applyAgentHeader + updateV2ComposerPresentation
}
```

(If a single-closure seam is too narrow once multiple tiles/views need it, promote to a small
multicast or `AsyncStream<AgentID>` — same semantics. The supervisor is the only writer.)

**1c. Kill the stale cache while we're here.** `updateV2ComposerPresentation` derives from
`agentSource?.turnSnapshot(for:)` (live) instead of `v2TurnSnapshot` (cached), and the
`descriptor.status` OR-terms at `ManagedAgentTileNSView.swift:805-806` are deleted when a v2
snapshot exists — one source of truth, no cache to go stale. Push the fresh snapshot into the
composer (`updateTurnSnapshot`) on the same path so Enter agrees with the button.

### Gate

Extend the live-v2 supervisor leg with a **real scripted runner** (not `qaDeliver`): a
`ScriptedAgentRunner` that emits `turn_end`/`agent_settled` and then delays its `run()` return.
Assert: at the last event the button is not sendable (truthful); after `clearRunner` fires the
seam, the composer presentation flips to sendable **without any further runtime event**.
Negative witness: with the seam disconnected, the check must fail exactly at
`composer stayed Unavailable after the runner slot freed`.

---

## Defect 2 — outer tile chip stuck at "Working" while the inner header says "Ready"

### Symptom

After the turn completes, the v2 agent header reads Ready but the tile title-bar chip (and
sidebar/inbox/dock badge/phone payload) stays Working forever.

### Root cause (two definitions of "working", and a debounced sweep that wins last)

- Inner header: supervisor turn facts — `.turnCompleted` → `execution = .ready`
  (`AgentSupervisor.swift:1545`), presenter renders Ready. Correct.
- Tile legacy status: `AgentStatusEngine.deriveAgentStatus` checks
  `isRunning` (session `.running`/`.waiting`, `:570`) **before** `isCompleted` (`:192-198`), so
  at `turn_end` the projection still says `.working`.
- That `.working` is stamped onto the `turn.completed` activity draft
  (`ContinuumApp.swift:9059`), and `.sessionStateChanged` deliberately produces **no draft**
  (`ManagedAgentActivityBridge.swift:64-67`), so the activity fold never learns about the
  settle. 0.5 s later the debounced surface sweep writes the folded `.working` over the tile's
  own later `.done` (`ContinuumApp.swift:5457-5474`) — and nothing ever writes again.

### Fix (single ownership: the supervisor snapshot drives a v2 tile's status)

In `ingest` (`ManagedAgentTileNSView.swift:468-471`), when a v2 snapshot exists, derive the
legacy `AgentStatus` from the same presenter the header already uses instead of from
`model.currentStatus`:

```swift
// ingest(_:), v2 branch
if let snapshot = v2TurnSnapshot {
    let presented = AgentTileStatePresenter.present(name: ..., snapshot: snapshot, ...)
    descriptor.status = presented.status      // .ready → .idle, .needsAction → .needsAttention, …
    agentStatus = presented.status
} else {
    descriptor.status = model.currentStatus   // compatibility path unchanged
    agentStatus = model.currentStatus
}
```

`currentAgentStatus` then stamps activity drafts with the same value
(`ContinuumApp.swift:9059`), so the fold, the sweep, the sidebar, the dock badge, and the
phone payload agree with the header **by construction**. `AgentStatusEngine` is not touched —
P5.10's "settle, not turn_end, is idle" rule stays intact for the legacy path.

Defect 1's seam also re-runs this on `clearRunner`, so the chip can't strand between the last
event and process exit.

### Gate

Same scripted-runner leg as defect 1: after `turn_end` + `agent_settled` + slot-free, assert
`tile.agentStatus == .idle` and the folded activity row status is not `.working`.

---

## Defect 3 — latent: composer can wedge if its sink deallocates mid-send

### Root cause

`submitBoundIntent` (`AgentComposerView.swift:435-449`) guards on `actionTask == nil` but only
clears `actionTask` after a successful `await`. `actionSink` is captured `weak`; if it
deallocates mid-flight (detach during send — `detach()` nils the strong owner
`v2ActionAdapter`, `ManagedAgentTileNSView.swift:334`), the guard path returns **without
clearing `actionTask`** → the composer can never submit again.

### Fix

```swift
actionTask = Task { [weak self] in
    defer { self?.actionTask = nil }        // unconditional
    guard let acceptance = await self?.actionSink?.accept(intent, for: agentID) else { return }
    ...
}
```

(And/or clear the field in `unbindActionSink`, `:257-262`, which already cancels the task but
leaves the field set.)

### Gate

Composer check: bind a sink, start a send against a sink that deallocates before accepting,
then bind a fresh sink and assert a second send dispatches.

---

## Defect 4 — model/effort dropdowns truncate at every width; footer is not responsive

### Symptom

"Medium" renders `Medi…` and the model id sheds its tail (`openai-codex/gpt-5.6-…`) even at a
750 pt tile with ~350 pt of dead space to the right.

### Root causes (one measurement bug, then layout debt)

1. **The 4 pt bug.** `ChoiceButton.intrinsicContentSize` measures the raw string
   (`ChoiceButton.swift:60-63`) but the label's `NSTextFieldCell` insets text ~2 pt per side —
   drawable width is always 2 pt short of the string, so `.byTruncatingTail` fires at **every**
   width. The sibling control already documents and fixes exactly this
   (`ComposerActionButton.swift:41-45`, the `+ 4` cell-inset term). The arithmetic reproduces
   both observed strings exactly. Bonus inconsistency: intrinsic uses a `14` chevron term,
   `layout()` uses `12`.
2. **No absorber.** `AgentComposerFooterView`'s stack (`:50-64`) has no flexible spacer and
   both buttons hug at 250 → everything packs left at intrinsic size; surplus is dead space
   (also the click-escape surface of defect 5). Convention elsewhere is a bare `NSView()`
   spacer (`AgentTileHeaderView.swift:63`, `ManagedAgentTileNSView.swift:847`).
3. **Magic ratio.** `modelButton.width >= effortButton.width * 1.45` at required priority
   (`:61-63`) can force the effort button *below* intrinsic width when space is tight.
4. **Binary threshold.** Abbreviation flips on a hard-coded `compactWidth = 390` inside
   `layout()` (`:78-85`) instead of measured fit.
5. **Shipped ≠ reviewed.** The live v2 tile stacks the action button as a third row,
   left-aligned (`ManagedAgentTileNSView.swift:632-634, 661`); the Component Lab surface the
   design was approved against puts it inline, right-aligned (`ComponentLab.swift:878-891`).
   → **Owner decision needed: inline (as reviewed) or third row (as shipped).**

### Fix

```swift
// ChoiceButton — one measurement expression shared by intrinsic and layout,
// ported from ComposerActionButton.measuredTitleWidth:
private var measuredTitleWidth: CGFloat {
    ceil((titleLabel.stringValue as NSString).size(withAttributes: [.font: .token(.label)]).width) + 4
}
// intrinsicContentSize and layout() both use measuredTitleWidth and the same chevron metric.

// AgentComposerFooterView — absorb surplus explicitly:
let spacer = NSView()   // exempted by UIProbeGeometry.isSpacer
stack = NSStackView([contextLabel, modelButton, effortButton, spacer])

// Replace the 390 pt flip with measured fit, per control:
// pick the widest variant (full title → abbreviated → none) whose intrinsic width fits the
// width actually available to that button in layout(); model and effort shrink independently.
// Demote the 1.45 ratio to non-required (or delete it) so effort can never be squeezed below
// its intrinsic width.
```

Plus the owner's placement decision from (5), applied to `composeColumn`.

### Gate

New footer leg (in `checkLiveV2AgentTileLayout` widths 320/486/640/750/900): for both buttons,
`frame.width >= intrinsicContentSize.width` **and** the rendered title equals the selected
item's title (no ellipsis) whenever the row has slack; `expectNoAmbiguousLayout` on the footer
stack. Today's `expectNoClipping` compares frames only — text ellipsis inside a well-contained
frame is invisible to it, which is why this shipped.

---

## Defect 5 — first click doesn't focus the composer

### Symptom

Right after launch, clicking into the composer often does nothing; it works after first
clicking/selecting the tile.

### Root causes

1. **The agent tile never claims focus.** Every other editable tile overrides
   `acquireFocus(reason:)` to point at its editor (`NoteTileNSView.swift:61-65` et al.).
   `ManagedAgentTileNSView` doesn't, so the base implementation makes `contentBackdrop` — a
   plain `NSView` that refuses first responder — the target, and the **window** ends up first
   responder (`TileNSView.swift:329-337`). This path runs on tile spawn, app activation, and
   every click-router steal.
2. **Clicks on composer chrome de-focus the tile.** The editor is inset 12 pt
   (`AgentComposerView.swift:132-135`) and the footer has the defect-4 dead space; clicks
   there fall through to `CanvasNSView.mouseDown` (`CanvasNSView.swift:1788-1791`), which
   deselects the tile and takes first responder itself. The mouse-up click-router then sees a
   non-descendant first responder and re-enters via the broken `acquireFocus` above. Once the
   tile has been selected once, clicks that land on actual glyphs let the text view take first
   responder and the router's `acceptingExisting: true` branch leaves it alone — exactly the
   observed "select the tile first" behavior.
3. **Reentrancy hazard.** `AgentComposerView.acceptsFirstResponder == true` and
   `becomeFirstResponder()` calls `window?.makeFirstResponder(textView)` (`:198-200`) —
   reentering `makeFirstResponder` from inside itself can leave the shell as first responder
   with no caret.

### Fix

```swift
// ManagedAgentTileNSView — the one missing override (mirrors NoteTileNSView):
override func acquireFocus(reason: FocusRequest) -> Bool {
    canvas?.bringToFront(tileId: tile.id)
    window?.makeFirstResponder(v2Composer?.textView ?? contentView)
    return true
}

// AgentComposerView — claim clicks on the padding ring so they can't fall through
// to the canvas deselect path:
override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(textView)
    super.mouseDown(with: event)
}
// (or hitTest → textView for points inside bounds; pick one, not both)

// Reentrancy: acceptsFirstResponder returns false (AppKit finds the text view itself),
// OR guard becomeFirstResponder against reentering makeFirstResponder.
```

### Gate

Mirror `NoteTileNSView.runNoteClickFocusSelfCheck` (`NoteTileNSView.swift:94-220`) for the v2
tile: real `ManagedAgentTileNSView(useV2: true)` in a canvas with a `FocusBroker`, dispatch a
click on the text view **and** one on the composer padding, run the click router, assert
`window.firstResponder === v2Composer.textView` and `focusBroker.activeSurface == .tile(id)`
in both cases.

---

## Defect 6 — transcript background is wallpaper-orange

### Symptom

The empty transcript region renders warm brown (`#433C3A` sampled) — no such color exists in
the token palette (all surfaces are cool blue-grays; `tileBody` dark is `#14171C`).

### Root cause

`AgentTranscriptListView.configureCollectionView()` sets `scrollView.drawsBackground = false`
(`:135`) but never clears `collectionView.backgroundColors` — `NSCollectionView` draws its
default background, `windowBackgroundColor`, **over** the tile's correct `tileBody` backdrop.
With macOS "wallpaper tinting in windows" enabled and a warm wallpaper, that color is the
observed brown. Offscreen gate renders resolve the same default to a plain dark gray — and the
baselines were blessed with it, so pixel gates matched.

### Fix

```swift
collectionView.backgroundColors = [.clear]   // tileBody backdrop shows through, as designed
```

### Gate

Assert `collectionView.backgroundColors == [.clear]` in the transcript list self-check (a
pixel gate cannot see this: the tint is desktop-dependent by nature). Baselines should not
move — blessed renders never showed the tint.

---

## Order of work

1. Defect 1 (send-availability repaint) + defect 2 (status single-ownership) — acceptance
   blockers; the core loop is "send, watch status, send again".
2. Defect 5 (focus) — one override + one click-claim.
3. Defect 4 (footer measurement/layout) — needs the owner's inline-vs-third-row call first.
4. Defect 6 (background) and defect 3 (latch) — one-liners with their checks.
5. Each fix lands with its gate; then focused checks ×5, full headless matrix
   (`CONTINUUM_SKIP_UI_BASELINES=1` while the main display is non-retina), supervised surface
   matrix on Retina-Main once the built-in display is main again, then packet step 5
   (flip default, delete legacy path) after explicit owner approval.

## Open decisions (owner)

1. **Action button placement:** inline right-aligned with the footer (as reviewed in Component
   Lab) or third row (as shipped)? The reviewed layout is the default recommendation.
2. **Seam shape for defect 1:** single closure (`onTurnCapabilitiesChanged`) is the minimum;
   promote to multicast/`AsyncStream` only if a second subscriber exists today.
3. Confirm all six land under P5.5 as review corrections (vs. deferring 3/4/6 to a follow-up
   packet). Recommendation: all six — each was found by the acceptance this packet exists to
   run, and the legacy-path deletion should not land on top of known-broken v2 UX.
