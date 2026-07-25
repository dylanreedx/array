# P2D.2 — Detect the spawn call in the translated stream
Phase: 2D · Depends on: P2D.1 · Tag: autonomous · Execution-mode: medium

## Goal
Turn an observed `spawn_agent` tool call into a real child agent. This is the whole orchestration
mechanism, and it costs almost nothing because we already parse the stream.

## Files
- `Sources/ContinuumRevivedCore/AgentProviders/PiEventTranslator.swift` (args are currently dropped — see below)
- `Sources/ContinuumRevivedCore/Agents/SpawnRequest.swift` (new, pure parse)
- `Sources/ContinuumRevived/App/AgentSupervisor.swift`
- `Sources/ContinuumRevivedCoreChecks/SpawnRequestChecks.swift` (new)

## Approach
`PiEventTranslator` deliberately drops tool `args` for I5 reasons — and that must stay true for
**anything that crosses the sync boundary**. So do NOT widen `AgentRuntimeEvent`. Instead add a
*local-only* side channel: the translator exposes the raw args for a whitelisted tool name
(`spawn_agent`) via a separate, non-`Codable` callback or an out-of-band `SpawnRequest` value that the
supervisor consumes in-process and never publishes.

```swift
public struct SpawnRequest: Equatable, Sendable {   // NOT Codable — must not cross the boundary
    public let role: String?; public let prompt: String; public let isolated: Bool
    public static func parse(toolName: String, argsJSON: String) -> SpawnRequest?
}
```
The supervisor, on receiving one, calls `spawn(role:prompt:cwd:isolated:)` with `parentAgentID` set to
the emitting agent.

## Done when
Feeding the committed fixture stream (P2D.1) through the translator + supervisor produces one child
agent with the right role/prompt and `parentAgentID` set.

## Verify
`SpawnRequestChecks`: parse the real captured fixture; reject malformed args; reject a non-whitelisted
tool name. Then `--agent-supervisor-check` extension: feed the fixture to a stub-runner parent, assert
exactly one child spawned, parent link correct, and **assert the child's prompt/role never appear in
any published `AgentActivityEvent`** (I5 witness — the tool NAME may cross, the args may not).

## Watch out
- **I5 is the hazard here.** `prompt` is user/model text and `cwd` is a host path; neither may be
  published. Keep `SpawnRequest` non-Codable so it cannot be serialized by accident.
- Guard against a spawn loop: an agent whose prompt causes it to spawn agents that spawn agents. Add a
  depth cap (e.g. 2) and a per-parent child cap; refuse beyond it and surface the refusal in the parent's
  transcript.
