# P5.5 composer action consolidation — plan

Drafted 2026-08-03 at the P5.5 supervised gate, owner-reported: the primary action's
journey across one live turn reads Send → **Unavailable** → Stop → **Unavailable** → Send —
sluggish, flickery, and unlike any CLI. Follows `plan-P5.5-review-corrections.md`; the
capability seam from that plan is what makes the two windows *visible* — this plan makes
them *coherent*.

## Why "Unavailable" appears twice per turn

Both windows are the supervisor truthfully reporting "no turn event says working, but the
runner slot is held" (`occupied = runners[id] != nil`):

1. **Send → first `turnStarted`**: the Pi process is spawning — the longest window, often
   visibly slow. `state == .ready`, `canSend == false` (occupied) → resolve renders
   "Unavailable" (`AgentComposerPresentation.swift`, `.ready` fallback).
2. **`agent_settled` → process exit**: terminal events are printed before the process
   exits, so the slot is briefly held after `state` returns to `.ready` → "Unavailable"
   again until `clearRunner` fires the capability seam.

The CLI never shows this because its contract is simpler: **from the moment you submit
until the turn is over, the interrupt affordance is available; otherwise the submit
affordance is.** Esc works during spawn and during drain — there is no third state.

## The change: one capability rule, one presentation case

### 1. `canStop` means "a runner is in flight" — `AgentSupervisor.turnSnapshot`

```swift
capabilities: .sendStop(
    canSend: !occupied && state.acceptsNewTurn,
    canStop: occupied                       // was: occupied && facts.execution == .working
)
```

This is MORE truthful, not less: `stop()` genuinely works in both windows — it kills a
spawning or draining process. The old term under-advertised the transport.
`accept(.stop)`'s `noTurnInProgress` refusal still fires whenever nothing is in flight,
because `occupied` is false then.

### 2. Stop presents whenever stopping is possible — `AgentComposerPresentation.resolve`

```swift
switch state {
case .ready where capabilities.canSend:   // unchanged — Send, enabled iff hasDraft
case _ where capabilities.canStop:        // NEW — one Stop case for .working AND the
                                          // in-flight .ready windows
case .working:                            // unchanged — passive "Working" (no stop RPC)
case .ready:                              // unchanged — "Unavailable", now meaning what
                                          // a label that blunt should: a true dead end
                                          // (unbound/detached composer, no capabilities)
}
```

Visible result across a turn: **Send → Stop → Send.** Pressing Stop in window 1 kills the
spawning runner; in window 2 it kills a draining one — both correct.

### 3. Footer pickers follow the same in-flight notion — `updateV2ComposerPresentation`

`controlsEnabled = !(executionState == .working || capabilities.canStop)` — otherwise the
model/effort pickers flash re-enabled during both windows. The `state:` argument passed to
`resolve` stays the truthful execution state; capabilities alone drive the Stop case.

## What deliberately does NOT change

- **The header.** P5.2's pinned rule stands: a live-but-idle process presents "Ready".
  Only the action button consolidates; the header keeps narrating events.
- **`canSend`.** Still `!occupied && acceptsNewTurn` — send-while-busy is refused
  truthfully and the pinned `occupied send transport advertised acceptance` witness stays.
- **Enter.** `AgentComposerIntentState.primaryIntent` is untouched: the BUTTON dispatches
  on the presentation's `primaryAction`, but Enter derives from Core's intent state, which
  returns send-or-nothing for `.ready` — Enter during a turn stays inert (CLI parity:
  Enter never interrupts; the explicit Stop control does). Steer/queue-on-Enter remains
  P5.7's compiled-capability work.
- **Queueing.** Send-during-turn = queue is P5.7 scope; not invented here.

## Tests — adjusted where pinned to the old rule, created where the rule was untested

1. **P4.6 truth table** (`ContinuumRevivedAgentUIChecks/main.swift`,
   `runComposerActionPresentationChecks`) — the exhaustive 64-row matrix currently pins
   `.ready + canStop` to `.unavailable`. Rows become:
   `canSend∧.ready → send` · `canStop (any state, no send·ready) → enabled stop` ·
   `.working without stop → passive Working` · `.ready without either → unavailable`.
   Secondary-action expectations stay keyed on `.working` (steer/queue are mid-turn
   concepts; both capabilities are compile-time false today).
2. **`capability-repaint` leg** (`--agent-supervisor-check`) — expectations move from
   "Unavailable" to "Stop" at the terminal event, and the leg GROWS the two windows it
   could not previously express:
   - immediately after `send`, before ANY runtime event: `canStop == true`, action title
     "Stop" (window 1 visible; the seam fired on `runners[id] = runner`);
   - NEW stop-during-spawn round: `send` → `accept(.stop)` while the runner has emitted
     nothing → `.accepted`, runner released (`stopCount`/`completedRuns` move), action
     returns to "Send". This is the affordance the consolidation advertises — it must be
     proven callable, not just painted.
3. **Turn-state leg** — `process alive but explicitly idle` still presents Ready with
   `canSend == false` (both pinned); it additionally asserts `canStop == true` there now
   (the drain window is stoppable).
4. **Provider-settings leg** — pickers stay dark from `send` through slot-free, not
   merely from `turnStarted` to `turnCompleted`.
5. **Required negative witness** — revert `canStop` to the old
   `occupied && execution == .working` term: the capability-repaint leg must go red at
   exactly the window-1 "Stop" assertion; restore by SHA and observe green.

Baselines: no Lab fixture renders an in-flight `.ready` window (they pass explicit
capabilities), so no baseline movement is expected; if one moves on Retina-Main it gets
the standard review-then-bless treatment.

## Fence exceptions to document in the ledger before editing

Beyond those already documented for the review corrections:
`Sources/ContinuumRevivedAgentUI/AgentComposerPresentation.swift` (the Stop case),
`Sources/ContinuumRevivedAgentUIChecks/main.swift` (truth table). `AgentSupervisor.swift`
and the check legs are already excepted.

## Order of work

1. Ledger fence addendum → capability rule + resolve case + footer in-flight notion.
2. Test adjustments/additions (items 1–4), gates green.
3. Negative witness (item 5), restore, green.
4. Focused checks ×5, full matrix on Retina-Main, relaunch for the owner.
