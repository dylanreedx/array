import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

// Continuum observes every tool call in the Pi event stream, so the CALL is the API.
// This extension is deliberately inert: it acknowledges and returns immediately, and
// Continuum creates the child agent when it sees the call (P2D.2). It never reaches
// back into the app — no IPC, no callback channel, nothing to block on.
export default function continuumSpawnAgent(pi: ExtensionAPI) {
  pi.registerTool({
    name: "spawn_agent",
    label: "Spawn Agent",
    description:
      "Delegate work to a new Continuum agent. Returns immediately; the agent runs in parallel and reports back through Continuum, not through this tool.",
    // Without promptSnippet a custom tool is left out of the system prompt's "Available tools"
    // section entirely — an orchestrator would have to infer the tool exists from its schema alone.
    promptSnippet: "Delegate a self-contained task to a new Continuum agent",
    promptGuidelines: [
      "spawn_agent is fire-and-forget: it returns an acknowledgement, not the agent's work. Do not wait for a result or call it again to poll.",
      // Guidelines are appended flat to the shared Guidelines section with no tool-name prefix,
      // so each bullet has to name spawn_agent itself.
      "A spawn_agent agent does not see this conversation, so put everything it needs in prompt.",
      "Pass isolated: true to spawn_agent when the new agent will edit files, so it works in its own git worktree.",
    ],
    parameters: Type.Object({
      prompt: Type.String({ description: "The task for the new agent. Self-contained: it does not see this conversation." }),
      role: Type.Optional(Type.String({ description: "Role name for the new agent, e.g. code-scout." })),
      isolated: Type.Optional(Type.Boolean({ description: "Run the agent in its own git worktree instead of the shared checkout." })),
    }),
    async execute(_toolCallId, params) {
      const role = params.role ?? "agent";
      return {
        content: [{ type: "text", text: `spawned: ${role}` }],
        details: { role, isolated: params.isolated ?? false },
      };
    },
  });
}
