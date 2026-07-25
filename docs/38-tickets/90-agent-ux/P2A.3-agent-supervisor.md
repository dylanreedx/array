# P2A.3 — AgentSupervisor owns the runners
Phase: 2A · Depends on: P2A.2 · Tag: autonomous · Execution-mode: high

## Goal
Move runner ownership out of the view. Today `ContinuumApp.managedAgentRunners` is keyed by tile and
the tile view is the de-facto owner, so closing a tile ends the agent. The supervisor is the
app-lifetime owner; views come and go.

## Files
- `Sources/ContinuumRevived/App/AgentSupervisor.swift` (new)
- `Sources/ContinuumRevived/App/ContinuumApp.swift` (`wireManagedAgentTile` ~:7410, `managedAgentRunners` ~:2628)

## Approach
```swift
@MainActor final class AgentSupervisor {
    func spawn(role: String?, prompt: String?, cwd: URL, model: String, thinking: String) -> AgentID
    func send(_ prompt: String, to: AgentID)
    func stop(_ id: AgentID)
    func events(for: AgentID) -> AsyncStream<AgentRuntimeEvent>   // multicast: tile + inventory + phone
    var records: [AgentID: AgentRecord] { get }
}
```
Keep `PiAgentRunner` as-is (Phase 5 replaces it with the RPC client). The supervisor holds the
runner, persists the `AgentRecord` via `AgentStore`, and **multicasts** events so more than one
consumer can observe the same agent — that multicast is what makes a tile a detachable view rather
than the owner. Model the fan-out on `ActivityStore.subscribe()`'s snapshot-then-tail contract.

`wireManagedAgentTile` stops creating runners and instead binds the tile to
`supervisor.events(for:)` and routes `onSubmitPrompt` to `supervisor.send`.

## Done when
Spawning goes through the supervisor; no `PiAgentRunner` is constructed by a view; two consumers can
subscribe to one agent and both receive every event.

## Verify
New `--agent-supervisor-check`: spawn a **fake** runner (inject a stub emitting a scripted event
sequence — do NOT require Pi/network in the matrix), attach two subscribers, assert both receive the
full sequence in order, assert the record persists, assert `stop` terminates and the record reflects
it. Use the P0.8 `waitUntil` for async settling.

## Watch out
- The runner is injectable for testability, but the production path must still use `PiAgentRunner`.
- `PiAgentRunner.run` is blocking — keep it off the main thread as `wireManagedAgentTile` already does.
- Do not delete `managedAgentRunners` until nothing references it; a stale second owner will double-spawn.
