# P2D.1 — The `spawn_agent` Pi extension
Phase: 2D · Depends on: P2C.5 · Tag: autonomous · Execution-mode: medium

## Goal
Give an orchestrator agent a way to create workers. Pi extensions can `registerTool`, and **Continuum
already translates every tool call in the stream** — so the tool call *is* the API. No IPC, no callback
channel, no new protocol.

## Files
- `Resources/PiExtensions/continuum-spawn-agent.ts` (new, shipped in-repo)
- `docs/38-tickets/90-agent-ux/P2D-orchestration-notes.md` (new: install + contract)

## Approach
A TypeScript extension (jiti loads it, no build step):
```ts
export default function (pi) {
  pi.registerTool({
    name: "spawn_agent",
    description: "Delegate work to a new Continuum agent. Returns immediately.",
    parameters: { role: "string?", prompt: "string", isolated: "boolean?" },
    execute: async (args) => ({ content: [{ type: "text", text: `spawned: ${args.role ?? "agent"}` }] })
  })
}
```
**Fire-and-forget**: the tool returns immediately with an acknowledgement. It does NOT create the agent
itself — Continuum does that when it observes the call (P2D.2). Keeping the extension inert avoids
needing the extension to reach back into the app, and avoids blocking (which would require RPC).

Ship it in-repo and document installing it to `~/.pi/agent/extensions/` (or project `.pi/extensions/`,
which requires project trust). Do NOT auto-install into the user's home from the app in this ticket.

## Done when
The extension loads under `pi` and `spawn_agent` appears in the tool list for an agent that allows it.

## Verify
Manual/scripted, outside the matrix (needs Pi): `pi --mode json -e Resources/PiExtensions/continuum-spawn-agent.ts -p "call spawn_agent with role=code-scout prompt=hello"` → the json stream contains a
`tool_execution_start` with `toolName: "spawn_agent"`. Capture that stream to a fixture file and commit
it — P2D.2's matrix check runs against the fixture, not against live Pi.

## Watch out
- Pi's built-in tools are `read, bash, edit, write, grep, find, ls` (the last three off by default);
  the tool allowlist is `--tools`. An orchestrator needs `spawn_agent` explicitly allowed.
- Do not have the extension shell out to Continuum. Inert by design.
