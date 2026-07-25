# P2A.7 — Restore agents (and optional views) on relaunch
Phase: 2A · Depends on: P2A.6 · Tag: autonomous · Execution-mode: medium

## Goal
Today `installInitialManagedAgentTile` (`ContinuumApp.swift` ~:3941) constructs a **fresh, empty**
`ManagedAgentTileNSView` and ignores the persisted record entirely — so an agent's status and
transcript die on restart even though the record survived. Once the inbox lists agents, that would
mean listing agents whose tiles are blank.

## Files
- `Sources/ContinuumRevived/App/ContinuumApp.swift` (boot restore path, `installInitialManagedAgentTile`)
- `Sources/ContinuumRevived/App/AgentSupervisor.swift`

## Approach
On boot: `AgentStore.loadAll()` → repopulate `supervisor.records`. For each record with a `tileId`
that still exists in `CanvasState`, attach a tile. **Do not auto-restart the provider process** —
a relaunched agent is `idle`/`stopped` until the user sends a prompt (auto-resuming N processes at
launch is surprising and expensive). Pi session continuity means the conversation resumes from
`--session-id` when the next prompt is sent, so history is not lost.

Transcript history: the desktop transcript lives only in the view today. Either (a) re-derive from
the Pi session JSONL (`~/.pi/agent/sessions/--<slug>--/*.jsonl` — the format is documented and
`SessionManager.list()` exists) or (b) show an explicit "previous session — send a prompt to
continue" placeholder. **Prefer (b) in this ticket**; (a) is a bigger feature and belongs in its own
ticket. Note the choice in the commit body.

## Done when
After a relaunch, previously-created agents are listed with correct identity/model/role, tiles that
existed are re-attached, and none of them auto-start a process.

## Verify
`--agent-restore-check`: write two records to a temp store (one with a tileId, one headless), boot
the restore path, assert both are in `supervisor.records`, assert the tiled one has a view attached,
assert neither has a live runner, then send a prompt to one and assert it starts.

## Watch out
- Do not resurrect stale agents whose project root no longer exists — mark them and skip, do not crash.
- `ManagedAgentSessionRecord` still exists for terminal/tmux agents; do not double-restore an agent
  from both stores.
