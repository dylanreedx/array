import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

// Continuum observes every tool call in the Pi event stream, so the spawn CALL
// is the API: `spawn_agent` acknowledges and returns immediately, and Continuum
// creates the child agent when it sees the call (P2D.2). Only a pi session
// Array runs has its calls observed, and Array delivers every child's result
// into that session itself (a wake, or joining the running turn): one channel
// per recipient (`WorkspaceResultDelivery`). There is deliberately no
// `wait_agents` here. It was a second channel to the same results, and a pi
// Array does not run could never collect through it.

export default function continuumSpawnAgent(pi: ExtensionAPI) {
  pi.registerTool({
    name: "spawn_agent",
    label: "Spawn Agent",
    description:
      "Delegate work to a new Array agent. Returns immediately with a handle; the agent runs in parallel. Array delivers its result to you by itself: continue independent work or end your turn. Never sleep, poll or message it to check.",
    // Without promptSnippet a custom tool is left out of the system prompt's "Available tools"
    // section entirely — an orchestrator would have to infer the tool exists from its schema alone.
    promptSnippet: "Delegate a self-contained task to a new Array agent",
    promptGuidelines: [
      // Guidelines are appended flat to the shared Guidelines section with no tool-name prefix,
      // so each bullet has to name spawn_agent itself.
      "spawn_agent returns an acknowledgement with a [handle: ...]. Continue independent work or end your turn: Array delivers the result to you by itself. Never sleep, loop or re-call spawn_agent to poll.",
      "A spawn_agent agent does not see this conversation, so put everything it needs in prompt.",
      "Pass isolated: true to spawn_agent when the new agent will edit files, so it works in its own git worktree.",
    ],
    parameters: Type.Object({
      prompt: Type.String({ description: "The task for the new agent. Self-contained: it does not see this conversation." }),
      role: Type.Optional(Type.String({ description: "Role name for the new agent, e.g. code-scout." })),
      isolated: Type.Optional(Type.Boolean({ description: "Run the agent in its own git worktree instead of the shared checkout." })),
    }),
    async execute(toolCallId, params) {
      const role = params.role ?? "agent";
      return {
        content: [
          {
            type: "text",
            text: `spawned: ${role} [handle: ${toolCallId}] — Array delivers the result; continue independent work or end your turn`,
          },
        ],
        details: { role, isolated: params.isolated ?? false, handle: toolCallId },
      };
    },
  });
}
