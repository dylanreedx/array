import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

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

const SCHEMA = "array.workspace.v1";
// Longer than Array's own host deadline (30 s) so the host's structured
// `outcome_unknown` answer wins over a bare timeout.
const TOOL_TIMEOUT_MS = 45_000;
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

export default function continuumWorkspaceTools(pi: ExtensionAPI) {
  pi.registerTool({
    name: "array_workspace_context",
    label: "Array Workspace Context",
    description:
      "Return your own identity as Array sees it: agentId, checkoutHandle (your Home checkout), workspace/zone/tile ids, structural revision, hydration coverage, the operations you are allowed, and recentOperations (outcomes of your recent Array requests, including ones cancelled after they took effect). Read-only and cheap.",
    promptSnippet: "Ask Array which workspace/zone/checkout you are in and what it can do for you",
    promptGuidelines: [
      "array_workspace_context is the authority on your zone, checkout handle and recent Array operations; never assume permissions or positions from prose.",
      "If a previous array_open_document returned cancelled or outcome_unknown, call array_workspace_context and read recentOperations before repeating it.",
    ],
    parameters: Type.Object({}),
    async execute(toolCallId, _params, signal, _onUpdate, ctx) {
      return asToolResult(await bridge(ctx, toolCallId, "workspace.context", {}, signal, TOOL_TIMEOUT_MS));
    },
  });

  pi.registerTool({
    name: "array_open_document",
    label: "Array Open Document",
    description:
      "Open or reveal a document as a tile on the Array canvas and return its real identity (tileId, artifactHandle, checkoutHandle, zone and world rect) plus what actually happened (document opened|existing|failed, relationship, presentation effects, draft preserved). Returns structured errors (not_found, target_conflict, permission_denied, scope_approval_required, presentation_required, unsupported, idempotency_conflict) instead of guessing. Never edits the file.",
    promptSnippet: "Open or reveal a file as a tile on the Array canvas and get its tile identity back",
    promptGuidelines: [
      "Use array_open_document (not bash or open) to show a file to the user on the canvas; quote the returned tileId when you refer to it.",
      "On not_found or target_conflict, re-check the path and handle; never substitute a similarly named file or another checkout.",
      "Prefer mode 'revealOnly' when you only want to point at something already open, and presentation.camera 'preserve' unless the user asked to be taken there.",
      "Reuse the same idempotencyKey when retrying an open that returned outcome_unknown or partial.",
    ],
    parameters: Type.Object({
      relativePath: Type.Optional(
        Type.String({ description: "Path relative to the checkout root (the explicit checkoutHandle, or your Home checkout when omitted)." }),
      ),
      checkoutHandle: Type.Optional(
        Type.String({ description: "A checkout handle from array_workspace_context or a prior result. An explicit handle wins over your Home default." }),
      ),
      artifactHandle: Type.Optional(
        Type.String({ description: "An artifactHandle Array returned earlier (ck_...:path). If it disagrees with checkoutHandle you get target_conflict." }),
      ),
      mode: Type.Optional(Type.Union([Type.Literal("openOrReveal"), Type.Literal("revealOnly")])),
      line: Type.Optional(Type.Integer({ minimum: 1, description: "One-based line to scroll to." })),
      presentation: Type.Optional(
        Type.Object({
          camera: Type.Optional(Type.Union([Type.Literal("preserve"), Type.Literal("revealResult")])),
          keyboardFocus: Type.Optional(Type.Union([Type.Literal("preserve"), Type.Literal("enterResult")])),
          selection: Type.Optional(Type.Union([Type.Literal("preserve"), Type.Literal("selectResult")])),
          workspace: Type.Optional(Type.Union([Type.Literal("preserve"), Type.Literal("allowSwitchToResolvedTarget")])),
          armedZone: Type.Optional(Type.Union([Type.Literal("preserve"), Type.Literal("setResolvedTarget")])),
        }),
      ),
      idempotencyKey: Type.Optional(Type.String({ maxLength: 128 })),
    }),
    async execute(toolCallId, params, signal, _onUpdate, ctx) {
      return asToolResult(await bridge(ctx, toolCallId, "artifact.open", params, signal, TOOL_TIMEOUT_MS));
    },
  });

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
