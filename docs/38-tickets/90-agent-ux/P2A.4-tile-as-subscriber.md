# P2A.4 — The tile becomes a subscriber, not an owner
Phase: 2A · Depends on: P2A.3 · Tag: autonomous · Execution-mode: medium

## Goal
Make `ManagedAgentTileNSView` a pure view over an agent's event stream — the same relationship the
phone already has via `ActivityProjectionReceiver`. That symmetry is the tell that this is the right
shape.

## Files
- `Sources/ContinuumRevived/Canvas/ManagedAgentTileNSView.swift`
- `Sources/ContinuumRevived/App/ContinuumApp.swift` (`wireManagedAgentTile`)

## Approach
Give the tile an `attach(agentID:supervisor:)` that subscribes and replays history so a
newly-attached view shows the conversation so far (snapshot-then-tail, like the phone). The tile
keeps its `ManagedAgentTranscriptModel` as a local projection; it just no longer owns the process.
`detach()` cancels the subscription only.

The tile's `wiringThreadId` currently keys transcript filtering; keep `AgentRuntimeEvent.withThreadId`
rebinding at the boundary (it exists and is matrix-pinned) so the model's filter still matches.

## Done when
A tile renders an agent's history on attach, live events continue to arrive, and `detach()` leaves
the agent running.

## Verify
Extend `--agent-supervisor-check`: spawn with a stub runner, emit 3 events, attach a tile, assert it
shows all 3 (replay), emit 2 more, assert 5, then detach and assert the runner is still alive and the
supervisor still receives events.

## Watch out
- Replay must not double-count if the subscription also delivers buffered events — define the
  snapshot/tail boundary explicitly, as `ActivityStore.subscribe()` does.
- Do not let the tile mutate the supervisor's record except through explicit supervisor calls.
