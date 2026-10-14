import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { readFileSync } from "node:fs";

// CX-01 (`.plans/59-parallel-product-investigations/canvas-awareness-api-design.md`, §15).
//
// Array's HOST TOOL BRIDGE for pi. Each tool below awaits Array through pi's
// own extension-UI channel: `ctx.ui.input(<JSON envelope>)` is emitted by rpc
// mode as an `extension_ui_request` frame, Array answers with an
// `extension_ui_response` carrying a JSON `value`, and that value is returned
// as the tool's result — so what Array writes IS what the model reads. Nothing
// here asserts who is asking: the request travels on this pi process's own
// stdio, which Array bound to exactly one agent record when it started it.
//
// Loaded by `-e <bundled path>` from Array-managed sessions only; never
// installed into `~/.pi`. Results (including structured errors and
// cancellation) are RETURNED, never thrown: pi flattens a thrown error to text
// and drops `details`, which would lose the machine-readable code.
//
// The tools themselves — names, descriptions, guidelines and JSON-schema
// parameters — are NOT written here. They live in `array-workspace-tools.json`
// beside this file, the one definition Claude and Codex also read over
// `array-workspace-mcp` (`WorkspaceMCPToolCatalog`). Edit the JSON; a tool
// described twice drifts.

const SCHEMA = "array.workspace.v1";
// Match the MCP clients' 24-hour request horizon, plus five seconds so the
// host's structured `outcome_unknown` answer wins over pi's bare UI timeout.
// Workspace scope approvals have no separate deadline and must stay pending
// until the user decides or the host's shared request horizon expires.
const TOOL_TIMEOUT_MS = 86_405_000;
const CONTEXT_TIMEOUT_MS = 2_000;

type Envelope = { schema: string; kind: "request"; requestId: string; op: string; payload: unknown };
type Reply = {
  schema: string;
  requestId: string;
  status: "ok" | "error" | "cancelled";
  result?: unknown;
  error?: { code: string; message: string; details?: unknown };
};

function errorReply(requestId: string, code: string, message: string): Reply {
  return { schema: SCHEMA, requestId, status: "error", error: { code, message } };
}

async function bridge(
  ctx: ExtensionContext,
  requestId: string,
  op: string,
  payload: unknown,
  signal: AbortSignal | undefined,
  timeout: number,
): Promise<Reply> {
  if (process.env.CONTINUUM_ARRAY_MANAGED_AGENT !== "1") {
    return errorReply(requestId, "unsupported", "Array workspace tools are available only inside an Array-managed session.");
  }
  if (!ctx.hasUI) {
    return errorReply(requestId, "unsupported", "Array host bridge unavailable in this pi mode.");
  }
  const envelope: Envelope = { schema: SCHEMA, kind: "request", requestId, op, payload };
  const raw = await ctx.ui.input(JSON.stringify(envelope), undefined, { signal, timeout });
  if (raw === undefined) {
    if (signal?.aborted) return { schema: SCHEMA, requestId, status: "cancelled" };
    return errorReply(
      requestId,
      "outcome_unknown",
      "Array did not answer before the bridge timeout. Do not repeat the effect blindly; call array_workspace_context and read recentOperations.",
    );
  }
  try {
    const reply = JSON.parse(raw) as Reply;
    if (reply?.schema !== SCHEMA || reply.requestId !== requestId) throw new Error("mismatched reply");
    return reply;
  } catch {
    return errorReply(requestId, "outcome_unknown", "Array returned an unreadable reply.");
  }
}

function asToolResult(reply: Reply) {
  return { content: [{ type: "text" as const, text: JSON.stringify(reply) }], details: reply };
}

type CatalogTool = {
  name: string;
  label: string;
  op: string;
  description: string;
  promptSnippet: string;
  promptGuidelines: string[];
  parameters: Record<string, unknown>;
};

const CATALOG = JSON.parse(
  readFileSync(new URL("./array-workspace-tools.json", import.meta.url), "utf8"),
) as { tools: CatalogTool[] };

export default function continuumWorkspaceTools(pi: ExtensionAPI) {
  for (const tool of CATALOG.tools) {
    pi.registerTool({
      name: tool.name,
      label: tool.label,
      description: tool.description,
      promptSnippet: tool.promptSnippet,
      promptGuidelines: tool.promptGuidelines,
      // Plain JSON Schema: pi validates non-TypeBox parameters itself.
      parameters: tool.parameters as any,
      async execute(toolCallId, params, signal, _onUpdate, ctx) {
        return asToolResult(await bridge(ctx, toolCallId, tool.op, params, signal, TOOL_TIMEOUT_MS));
      },
    });
  }

  // §7.1 automatic context: refreshed at every prompt boundary (rpc `prompt`
  // runs `before_agent_start` before answering), ~256 tokens, appended to the
  // system prompt. A slow or absent host appends nothing rather than stale data.
  pi.on("before_agent_start", async (event, ctx) => {
    const requestId = `ctx-${crypto.randomUUID()}`;
    const reply = await bridge(ctx, requestId, "workspace.context", { compact: true }, undefined, CONTEXT_TIMEOUT_MS);
    if (reply.status !== "ok" || !reply.result) return;
    return {
      systemPrompt:
        `${event.systemPrompt}\n\n# Array workspace context\n` +
        `Authoritative, refreshed each turn; details via array_workspace_context. ` +
        `Nearby resources are not implied to be authorized or current without another read.\n` +
        JSON.stringify(reply.result),
    };
  });
}
