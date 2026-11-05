import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { readdir, stat } from "node:fs/promises";
import { join } from "node:path";

// Continuum observes every tool call in the Pi event stream, so the spawn CALL
// is the API: `spawn_agent` acknowledges and returns immediately, and Continuum
// creates the child agent when it sees the call (P2D.2). Results come back over
// a FILE channel, not IPC: Continuum writes
// `<cwd>/.array/spawn-results/<toolCallId>.json` for every observed call —
// `refused` (with the reason) when it declines, `spawned` on launch, then a
// terminal `completed`/`failed`/`interrupted` carrying the child's final
// assistant text. `wait_agents` polls those files, which is what makes
// delegation collectable instead of fire-and-forget.

const RESULTS_DIR = join(".array", "spawn-results");
const TERMINAL = new Set(["error", "already_delivered", "refused", "completed", "failed", "interrupted"]);
const POLL_MS = 500;
const UNREGISTERED_AFTER_MS = 15_000;
const DEFAULT_TIMEOUT_S = 60;
const MIN_TIMEOUT_S = 5;
const MAX_TIMEOUT_S = 60;
// Best-effort discovery baseline for a no-handles wait: files older than this
// process belong to a previous turn.
const PROCESS_START_MS = Date.now() - process.uptime() * 1000;

interface SpawnResult {
  schema?: number;
  toolCallId?: string;
  status?: string;
  agentId?: string;
  role?: string;
  reason?: string;
  finalText?: string;
  finalTextTruncated?: boolean;
  endedAt?: string;
  turnIdentity?: string;
  recipientId?: string;
  deliveredVia?: string;
  deliveryReceipt?: string;
  report?: unknown;
}

function safeHandle(handle: string): boolean {
  return (
    handle.length > 0 &&
    handle.length <= 256 &&
    !handle.startsWith(".") &&
    !handle.includes("/") &&
    !handle.includes("\\")
  );
}

async function hostOperation(ctx: any, id: string, payload: unknown,
                             signal: AbortSignal | undefined, deadline: number): Promise<any> {
  if (process.env.CONTINUUM_ARRAY_MANAGED_AGENT !== "1" || !ctx.hasUI) return undefined;
  if (signal?.aborted || Date.now() >= deadline) return undefined;
  const controller = new AbortController();
  const onAbort = () => controller.abort();
  signal?.addEventListener("abort", onAbort, { once: true });
  let timer: ReturnType<typeof setTimeout> | undefined;
  let raw: string | undefined;
  try {
    raw = await Promise.race([
      ctx.ui.input(JSON.stringify({ schema: "array.workspace.v1", kind: "request",
        requestId: id, op: "operation.get", payload }), undefined,
        { signal: controller.signal, timeout: Math.min(500, Math.max(1, deadline - Date.now())) }),
      new Promise<undefined>(resolve => {
        timer = setTimeout(() => { controller.abort(); resolve(undefined); },
          Math.min(500, Math.max(1, deadline - Date.now())));
        controller.signal.addEventListener("abort", () => resolve(undefined), { once: true });
      }),
    ]);
  } finally {
    if (timer) clearTimeout(timer);
    signal?.removeEventListener("abort", onAbort);
  }
  if (raw === undefined) return undefined;
  try {
    const reply = JSON.parse(raw);
    if (reply.schema === "array.workspace.v1" && reply.requestId === id) return reply;
  } catch { /* retry same durable lookup id */ }
  return undefined;
}

async function pendingInput(ctx: any, signal: AbortSignal | undefined, deadline: number): Promise<string | undefined> {
  const reply = await hostOperation(ctx, `wait-${crypto.randomUUID()}`, { pendingInputOnly: true }, signal, deadline);
  return reply?.result?.pendingInput;
}

// The runner's stdio bridge supplies the caller identity. Never authorize
// against courier recipientId, environment agent ids, or file contents.
async function hostLookup(ctx: any, handle: string, requestId: string, signal?: AbortSignal, deadline = Date.now() + 60_000): Promise<SpawnResult | undefined> {
  if (process.env.CONTINUUM_ARRAY_MANAGED_AGENT !== "1" || !ctx.hasUI) {
    return { status: "error", reason: "Authenticated Array host bridge unavailable" };
  }
  const post = (id: string, payload: unknown) => hostOperation(ctx, id, payload, signal, deadline);
  const reply = await post(requestId, { operationId: handle });
  if (!reply) return { status: "spawned" };
  if (reply.status !== "ok") {
    if (reply.error?.code === "not_found") return undefined;
    return { status: "error", reason: reply.error?.code ?? "host lookup failed" };
  }
  const result = reply.result?.childResult as SpawnResult | undefined;
  if (!result) return { status: "spawned" };
  if (result.deliveryReceipt && !["already_delivered", "delivery_pending"].includes(result.status ?? "")) {
    const ack = await post(requestId + "-ack", { operationId: handle,
      deliveryReceipt: result.deliveryReceipt, acknowledgeDelivery: true });
    if (!ack) return { status: "spawned" };
    if (ack.status !== "ok") throw new Error("Helper acknowledgment failed; recover with deliveryReceipt " + result.deliveryReceipt);
  }
  return result;
}

/** Handles of result files written since this process started (no-handles mode). */
async function discoverHandles(cwd: string): Promise<string[]> {
  try {
    const dir = join(cwd, RESULTS_DIR);
    const names = await readdir(dir);
    const handles: string[] = [];
    for (const name of names) {
      if (name.startsWith(".") || !name.endsWith(".json")) continue;
      try {
        const info = await stat(join(dir, name));
        if (info.mtimeMs >= PROCESS_START_MS) handles.push(name.slice(0, -".json".length));
      } catch {
        // Racing a rename; the next poll sees it.
      }
    }
    return handles;
  } catch {
    return [];
  }
}

function describe(handle: string, result: SpawnResult | undefined, note?: string): string {
  if (note) return `${handle}: ${note}`;
  if (!result) return `${handle}: no result yet`;
  const role = result.role ?? "agent";
  switch (result.status) {
    case "error":
      return `${handle}: helper delivery error — ${result.reason}`;
    case "already_delivered":
      return `${handle} (${role}): already_delivered — ${result.reason}`;
    case "refused":
      return `${handle} (${role}): REFUSED — ${result.reason ?? "no reason recorded"}`;
    case "spawned":
      return `${handle} (${role}): still running — its output will appear in its own tile`;
    case "completed": {
      const truncated = result.finalTextTruncated ? "\n[final text truncated]" : "";
      return `${handle} (${role}): completed\n${result.finalText ?? "(the agent produced no final message)"}${truncated}`;
    }
    case "failed":
      return `${handle} (${role}): FAILED — ${result.reason ?? "no error recorded"}`;
    case "interrupted":
      return `${handle} (${role}): interrupted before finishing`;
    default:
      return `${handle} (${role}): unknown status ${String(result.status)}`;
  }
}

function sleep(ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve) => {
    const timer = setTimeout(done, ms);
    if (signal?.aborted) { done(); return; }
    function done() {
      signal?.removeEventListener("abort", done);
      clearTimeout(timer);
      resolve();
    }
    signal?.addEventListener("abort", done, { once: true });
  });
}

export default function continuumSpawnAgent(pi: ExtensionAPI) {
  pi.registerTool({
    name: "spawn_agent",
    label: "Spawn Agent",
    description:
      "Delegate work to a new Array agent. Returns immediately with a handle; the agent runs in parallel. Collect its result with wait_agents(handles) — never by sleeping or polling.",
    // Without promptSnippet a custom tool is left out of the system prompt's "Available tools"
    // section entirely — an orchestrator would have to infer the tool exists from its schema alone.
    promptSnippet: "Delegate a self-contained task to a new Array agent",
    promptGuidelines: [
      // Guidelines are appended flat to the shared Guidelines section with no tool-name prefix,
      // so each bullet has to name spawn_agent itself.
      "spawn_agent returns an acknowledgement with a [handle: ...]; collect the agent's result by calling wait_agents with that handle. Never sleep, loop, or re-call spawn_agent to poll.",
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
            text: `spawned: ${role} [handle: ${toolCallId}] — collect the result with wait_agents`,
          },
        ],
        details: { role, isolated: params.isolated ?? false, handle: toolCallId },
      };
    },
  });

  pi.registerTool({
    name: "wait_agents",
    label: "Wait for Agents",
    description:
      "Wait for spawn_agent agents to finish and return their results. Pass the [handle: ...] values spawn_agent returned; with no handles it waits on every spawn from this turn (best-effort). Returns early on user steering or inbox input; otherwise blocks until every requested agent is done or the timeout passes (maximum 60 s), then returns each agent's final message, refusal reason, or failure.",
    promptSnippet: "Collect the results of spawn_agent agents",
    promptGuidelines: [
      "After delegating with spawn_agent, call wait_agents with the handles to collect the results. It blocks for you — do not run sleep commands while agents work.",
    ],
    parameters: Type.Object({
      handles: Type.Optional(
        Type.Array(Type.String(), {
          description: "The [handle: ...] values returned by spawn_agent. Omit to wait on every spawn from this turn.",
        }),
      ),
      timeoutSeconds: Type.Optional(
        Type.Number({ description: "How long to wait before returning partial results. Default and maximum 60." }),
      ),
    }),
    async execute(_toolCallId, params, signal, _onUpdate, ctx) {
      const cwd: string = ctx.cwd;
      const timeoutS = Math.min(MAX_TIMEOUT_S, Math.max(MIN_TIMEOUT_S, params.timeoutSeconds ?? DEFAULT_TIMEOUT_S));
      const deadline = Date.now() + timeoutS * 1000;
      const startedAt = Date.now();

      const explicit = (params.handles ?? []).filter(safeHandle);
      const badHandles = (params.handles ?? []).filter((h) => !safeHandle(h));
      const discovering = explicit.length === 0;
      const pending = new Set<string>(explicit);
      const lookupIDs = new Map<string, string>();
      const finished = new Map<string, SpawnResult>();
      const notes = new Map<string, string>();
      for (const bad of badHandles) notes.set(bad, "not a valid spawn_agent handle");

      let interrupted: string | undefined;
      for (;;) {
        if (!signal?.aborted) {
          const reason = await pendingInput(ctx, signal, deadline);
          if (reason === "user_steer" || reason === "inbox") interrupted = reason;
        }
        if (discovering) {
          for (const handle of await discoverHandles(cwd)) {
            if (!finished.has(handle) && !notes.has(handle)) pending.add(handle);
          }
        }
        for (const handle of [...pending]) {
          if (interrupted || signal?.aborted || Date.now() >= deadline) break;
          const reason = await pendingInput(ctx, signal, deadline);
          if (reason === "user_steer" || reason === "inbox") { interrupted = reason; break; }
          if (!lookupIDs.has(handle)) lookupIDs.set(handle, `${_toolCallId}-${crypto.randomUUID()}`);
          const result = await hostLookup(ctx, handle, lookupIDs.get(handle)!, signal, deadline);
          if (result?.status && TERMINAL.has(result.status)) {
            finished.set(handle, result);
            pending.delete(handle);
          } else if (!result && Date.now() - startedAt > UNREGISTERED_AFTER_MS) {
            // Keep waiting for the others; this one never appeared.
            notes.set(handle, "Array did not register this spawn — its result cannot be collected");
            pending.delete(handle);
          } else if (result) {
            // Non-terminal (spawned): remember the latest snapshot for a
            // timeout/abort report.
            notes.delete(handle);
            finished.delete(handle);
          }
        }
        const doneWaiting =
          (!discovering && pending.size === 0) ||
          // Best-effort no-handles mode: done once everything discovered so far
          // is terminal — but give Array the same 15s grace to register a spawn
          // before concluding there was nothing to wait on.
          (discovering && pending.size === 0 &&
            (finished.size > 0 || Date.now() - startedAt > UNREGISTERED_AFTER_MS));
        const timedOut = Date.now() >= deadline;
        if (doneWaiting || timedOut || signal?.aborted || interrupted) {
          const lines: string[] = [];
          const report = new Set<string>([...explicit, ...badHandles, ...finished.keys(), ...notes.keys(), ...pending]);
          if (report.size === 0) {
            lines.push(
              discovering
                ? "No spawn results found for this turn. Pass the [handle: ...] values spawn_agent returned."
                : "Nothing to wait on.",
            );
          }
          for (const handle of report) {
            if (notes.has(handle)) {
              lines.push(describe(handle, undefined, notes.get(handle)));
            } else if (finished.has(handle)) {
              lines.push(describe(handle, finished.get(handle)));
            } else {
              lines.push(describe(handle, { status: "spawned" }));
            }
          }
          if (timedOut && pending.size > 0) {
            lines.push(`(waited ${timeoutS}s; the agents above marked still running have not finished)`);
          }
          if (signal?.aborted && pending.size > 0) {
            lines.push("(wait aborted; partial results above)");
          }
          if (interrupted) lines.push(`(interrupted: ${interrupted}; you may end your turn while helpers continue)`);
          return { content: [{ type: "text", text: lines.join("\n\n") }],
            details: { interrupted: interrupted ?? (signal?.aborted ? "cancelled" : undefined),
              timedOut: !interrupted && !signal?.aborted && timedOut,
              agents: [...report].map(handle => ({ handle,
                status: finished.get(handle)?.status ?? (notes.has(handle) ? "unknown" : "running") })) } };
        }
        await sleep(POLL_MS, signal);
      }
    },
  });
}
