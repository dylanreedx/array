# WS4 dispatch — completion awareness, read semantics, and glow

## Shared workstream target

This packet defines **WS4: completion awareness** in Array. Begin from the I1 checkpoint at `<BASE_SHA>`. The rendered `<ROLE>` controls authority: a lead implements; a reviewer or tester evaluates the same locked target under only its selected overlay.

The fully rendered common protocol prepended to this dispatch is binding. The checked-in `00-agent-protocol.md` is an unresolved reference template and never overrides rendered values.

Read `<WORKTREE>/AGENTS.md`, the master plan, `00-agent-protocol.md`, and the current awareness/status checks. Work only in `<WORKTREE>` and keep evidence under `<EVIDENCE_DIR>`.

### Outcome

Unify completion/read behavior around one product truth:

- A terminal event arriving while the managed-agent tile is genuinely actively viewed is immediately read, but produces one restrained finite green acknowledgment glow/pulse.
- A terminal event arriving while another tile/window/app is active remains durably unread until a deliberate reveal/visit.
- Application deactivation, modal occlusion, workspace switching, restoration, and focus-memory bookkeeping cannot falsely acknowledge an event.
- Failure and action-required/input/approval remain persistent, distinct attention states until their own resolution rules are met.
- Deliberate reveal/focus funnels durable acknowledgment and visible signal clearing through one operation.
- Reduce Motion shows one static green acknowledgment for the same finite 1.2–1.6 second window, then clears to the ordinary read appearance. It has no pulse, persistent success badge/glow, infinite animation, or steady-state timer.
- The visual treatment does not change tile or zone geometry and does not clip.

### Known defect

There are currently two awareness systems that can drift: durable `AgentRecord` terminal watermarks and `AgentSignalCenter.currentByTile`. Focus clears both, but a completion that arrives after the tile was already focused can leave the visible signal until the user exits and re-enters. Application resignation also releases responder focus while `AgentSupervisor.focusedAgentID` can remain armed, allowing a background completion to be treated as read.

### Inspect first

- `Sources/ContinuumRevivedCore/AgentAwareness.swift`
- `Sources/ContinuumRevivedCoreChecks/AgentAwarenessChecks.swift`
- agent terminal watermark/read fields in Core
- `Sources/ContinuumRevived/App/AgentSoundSystem.swift` (`AgentSignalCenter`)
- focus/viewing and event-ingestion paths in `Sources/ContinuumRevived/App/AgentSupervisor.swift`
- application/window focus paths in `Sources/ContinuumRevived/App/ContinuumApp.swift`
- `Sources/ContinuumRevived/Canvas/AgentSignalBadgeView.swift`
- `Sources/ContinuumRevived/Canvas/AgentTile/AgentTileStatePresenter.swift`
- managed tile/inbox reveal paths and current awareness/status checks

### Owned scope

Own awareness model, signal center, focused-view/read wiring, the signal badge/state presenter, and new focused checks. Use only narrow focus/event hunks in supervisor/AppDelegate. Do not change provider terminal semantics, transcript hierarchy, generic tile layout, or notification product policy beyond deduplication required by this contract.

### Required design

Introduce or centralize a pure `isActivelyViewed` decision using all relevant facts: app active, host window key/visible, tile actually visible or in Focus Mode, correct focus scope/responder, and no blocking modal/occlusion state represented by the product. Keep remembered restoration target separate from current active viewing. Event ingestion receives this decision; it does not infer read status from a stale tile ID later.

The transition flourish should be subtle: a static green glow plus about two pulse cycles over 1.2–1.6 seconds, then no animation object/timer remains. Use a deterministic animation clock/phase seam for tests. Keep failure/action-required visually and semantically stronger. Respect Reduce Motion and application inactivity.

### Required witnesses

1. Pure transition table for completed, failed, and action-required across active-viewed, other-tile, app-inactive, modal, workspace-away, deliberate revisit, activation restoration, and duplicate-event cases.
2. Assert durable unread watermark, signal center state, badge presentation, sound, notification eligibility, and animation generation exactly once per event.
3. Production AppKit focus/window witness repeated 10 times:
   - already focused at completion;
   - another tile focused;
   - app inactive at completion then activated;
   - deliberate revisit;
   - modal/Focus Mode/workspace switch as applicable;
   - repeated completion and out-of-order/deduplicated delivery.
4. Reduce Motion witness proves identical read semantics, a finite static substitute that clears to the ordinary read appearance, zero pulse animations, and zero steady timers after the acknowledgment window.
5. Restart/workspace round trip proves away-state unread is durable while an already-viewed completion does not resurrect.
6. Accessibility output names success/failure/action-required and read/unread accurately; keyboard reveal clears only eligible unread.

Capture Aqua/Dark Aqua at pulse phases 0/25/50/75/100%, final rest, away-unread, read-clear, failure, action-required, and Reduce Motion. Semantic JSON records app/window/tile focus facts, watermarks, signal kind, pulse generation/phase, active animation count, and timer count.

### Required commands

```sh
export CONTINUUM_PROJECT_ROOT="<QA_PROJECT_ROOT>"
export CONTINUUM_APP_SUPPORT="<QA_APP_SUPPORT>"
export TMUX_TMPDIR="<QA_TMUX_TMPDIR>"
unset TMUX TMUX_PANE
swift build
swift run ContinuumRevivedCoreChecks
swift run ContinuumRevivedAgentUIChecks
.build/debug/Array --agent-awareness-check
.build/debug/Array --observer-sweep-badge-check
.build/debug/Array --agent-status-check
.build/debug/Array --agent-completion-semantic-check
.build/debug/Array --agent-inbox-check
.build/debug/Array --completion-awareness-viewed-check
scripts/check-matrix-inventory.sh
```

Confirm existing flags before first invoking the new one. The lead must add the production focus/application/finite-animation witness under exact flag `--completion-awareness-viewed-check` and register it in the matrix. Reviewer/tester dispatch is gated on the candidate containing it; both run it directly and prove that leg—not merely composer completion semantics—visibly executes.

### Stop rules

Stop if provider lifecycle meanings must change, the app cannot represent active-view facts without a cross-workstream architectural change, or deterministic animation control would require global animation rewrites. Do not “fix” the bug by clearing every signal at receipt or by treating remembered focus as active viewing.

### Success

Focused completion acknowledges once without a stale badge, away completion persists until deliberate read, failure/action-required retain their semantics, animation is finite and accessible, and root receives phase-by-phase screenshots and exact state evidence.

## Independent reviewer overlay

Trace event arrival through durable watermark, signal center, view presenter, sounds/notifications, and deliberate acknowledgment. Look for stale `focusedAgentID`, dual clearing paths, duplicate observer delivery, app resignation gaps, timers retained by views, and semantic collapse of failed/action-required into success. Reject any focus-only test that does not exercise actual key-window/application transitions.

## Independent tester overlay

Drive the full focus/background/revisit matrix 10 times in one semantic/state batch in a clean isolated app. Render deterministic UIProbe phases 0/25/50/75/100 plus rest once per unique visual state, and separately capture one production live-window progression proving the 1.2–1.6 second finish; do not time five live screenshots with sleeps. Inspect accessibility state and counts for badge/sound/notification/pulse. FAIL on duplication, omission, stale badge, false background read, action-required auto-clear, geometry change, clipped glow, persistent Reduce Motion success treatment, or any animation/timer remaining after settle.
