# Pi context meter and status truth

Status: **planned only — no implementation started**
Repository baseline inspected: `array/integration` at `096870a8` (Array 0.4.18)
Scope: managed agents whose persisted `harness` is `Pi`

## Problem

Pi is now a first-class managed-agent harness, but two pieces of telemetry are not yet truthful:

1. The radial context-window meter receives Pi usage, yet never gets a fraction, so its circle remains empty.
2. Pi turn failures and cancellations can be presented as successful completion because the translator maps every `turn_end` to `.completed`.

The context-meter defect is confirmed in the current code and current persisted production data. The status defect is confirmed at the adapter contract; the exact user-visible symptom still needs a focused reproduction before implementation.

## Evidence gathered

### Context meter: confirmed root cause

- `PiEventTranslator.translateUsageEvents` already captures `usage.input`, `output`, `cacheRead`, `cacheWrite`, and `totalTokens`, then emits `.contextWindowUpdated` with `source: .piMessageUsage`.
- `AgentContextOccupancy.promptTokens(from:)` explicitly returns `nil` for `.piMessageUsage`.
- `AgentContextOccupancyChecks` and `PiEventTranslatorChecks` currently enforce that abstention, so the current empty ring is expected behavior rather than a rendering failure.
- A current persisted Pi record (`F61F8D66-63D5-4571-A34B-BDEBC63CFFEF`) contains `totalProcessedTokens: 180992` and no `usedTokens`/`maxTokens`. The selected model is `openai-codex/gpt-5.6-sol`.
- Pi 0.84.1's own implementation defines context usage as `usage.totalTokens`, falling back to `input + output + cacheRead + cacheWrite` (`dist/core/compaction/compaction.js::calculateContextTokens`). Its `AgentSession.getContextUsage()` divides that token count by the model's `contextWindow`.
- Pi's local models store publishes `openai-codex/gpt-5.6-sol.contextWindow = 272000`, and Array's `AgentModelCatalog` already parses and exposes that exact value.

Therefore Array has both measured operands. For the observed record, the Pi-compatible last-known reading is `180992 / 272000`, about **66.5%**. No new telemetry source or guessed denominator is needed.

### Status: confirmed adapter mismatch

- `PiEventTranslator` currently maps every `turn_end` to:
  - usage events, then
  - `.turnCompleted(... outcome: .completed, errorMessage: nil)`.
- Pi's `turn_end.message` is an assistant message carrying `stopReason` and `errorMessage`.
- Current Pi sessions on this machine contain both `stopReason: "error"` and `stopReason: "aborted"` records, including network errors, overload, and context-window overflow.
- Pi JSON print mode does not convert a final assistant error into a non-zero process exit; relying on `PiAgentRunner` exit status cannot repair the false success classification.

This makes the translator the required source of truth:

| Pi assistant `stopReason` | Array turn outcome | Session/status effect |
|---|---|---|
| normal completion / tool completion | `.completed` | ready/idle after settlement |
| `error` | `.failed` with sanitized provider error text | failed/error surface |
| `aborted` | `.interrupted` (or `.cancelled` if an existing cancellation contract proves that is the established meaning) | interrupted surface |

Do not finalize the aborted mapping by intuition: confirm the existing runner cancellation contract and one captured event sequence first.

## Implementation plan

### 1. Capture RED witnesses before changing behavior

Update deterministic fixtures first, without changing their expectations to fit an implementation after the fact:

- Add a Pi usage fixture copied from the observed schema where `totalTokens == input + output + cacheRead + cacheWrite`.
- Assert the current production path leaves `usedTokens`/`maxTokens` absent and the installed radial meter has no fraction. Record this as RED evidence for the bug.
- Add complete Pi lifecycle fixtures for:
  1. successful turn,
  2. `stopReason: error` with `errorMessage`,
  3. `stopReason: aborted`,
  4. duplicate `message_end` + `turn_end` usage.
- Drive the status fixture through the translator and, where practical, the supervisor/tile projection so the visible failed/interrupted state is witnessed rather than only the enum mapping.

Primary checks:

- `Sources/ContinuumRevivedCoreChecks/PiEventTranslatorChecks.swift`
- `Sources/ContinuumRevivedCoreChecks/AgentContextOccupancyChecks.swift`
- installed-row coverage in `Sources/ContinuumRevived/App/UIProbeGeometry.swift` or the existing supervisor live-v2 fixture

### 2. Make Pi occupancy match Pi's own semantics

In `AgentContextOccupancy.promptTokens(from:)`:

- For `.piMessageUsage`, use `totalProcessedTokens` when it is present and positive.
- If compatibility with older Pi output is required, fall back only to the same documented formula Pi uses: `input + output + cacheRead + cacheWrite`, requiring at least one measured component and a positive result.
- Continue to require a positive model `contextWindow` from `AgentModelCatalog`; do not add a fallback model size.
- Let the existing `withDerivedOccupancy` path populate `usedTokens`/`maxTokens`, so persistence, stale seeding, presentation, and drawing remain shared with other harnesses.

Update comments/tooltips that currently say Pi's shape is undocumented or deliberately underived. State that the numerator follows Pi 0.84.1's own `calculateContextTokens` contract and is a last-known reading after an assistant response.

### 3. Map Pi terminal outcomes truthfully

In `PiEventTranslator`:

- Parse `turn_end.message.stopReason` and `errorMessage`.
- Emit `.turnCompleted` with `.failed`, `.interrupted`/`.cancelled`, or `.completed` as established by the fixture table.
- Preserve usage-before-completion ordering.
- Keep raw provider payloads and tool details out of normalized events; only the provider's bounded `errorMessage` may cross the existing `[BODY]` field.
- Verify whether `agent_end.willRetry`, `auto_retry_start/end`, or `agent_settled` should suppress a transient failed surface during an automatic retry. Do not build a second status state machine: map only facts Pi explicitly emits into the existing session/turn model.

Likely minimal rule:

- terminal `turn_end(error)` produces failed turn status;
- an explicit retry-start event keeps the session running if the current Pi version emits it in JSON mode;
- final `agent_settled` returns only successful/normal completion to ready and must not erase a terminal failure before the user can see it.

The last point must be proven through the existing compact-status precedence rules before code is changed; `sessionStateChanged(.ready)` currently clears `compactStatusTurn`, which could otherwise erase a just-emitted failure.

### 4. Persistence and restore

Prove that:

- a Pi occupancy snapshot is persisted with measured `usedTokens` and the catalog `maxTokens`;
- reattaching marks it stale but preserves the numeric percentage;
- a post-compaction unknown state is not misrepresented as a fresh pre-compaction percentage;
- failed/interrupted turn status survives long enough to reach the tile and sidebar status owners, without inventing a permanently running session.

If compaction events are needed for truthfulness, add only the smallest provider-neutral event/state extension justified by a failing witness. Do not widen scope merely because Pi exposes more events.

### 5. Verification

Targeted, then full:

1. Rebuild and run `ContinuumRevivedCoreChecks`, including `--agent-context-occupancy-check` registration.
2. Run the real app self-check leg that owns the installed compact row (enumerate the exact existing flag from `ContinuumApp.swift`; do not guess it).
3. Run the relevant UI geometry/pixel/status checks and inspect any changed artifact.
4. Run `scripts/run-matrix.sh`; judge the summary, accounting only for documented KNOWN-RED legs.
5. End-to-end dogfood in `~/Desktop/Array Dev.app` on `~/array-scratch` with a real Pi turn:
   - observe a non-empty ring after completion;
   - compare displayed arithmetic to the captured Pi `totalTokens` and model-store `contextWindow`;
   - exercise or safely inject an error/abort and inspect the resulting tile/sidebar status.

Do not claim the user-visible bug fixed from CoreChecks alone. The real-route dogfood and observed meter/status are required for final verification.

## Expected files

Minimal expected touch set:

- `Sources/ContinuumRevivedCore/AgentContextOccupancy.swift`
- `Sources/ContinuumRevivedCore/AgentProviders/PiEventTranslator.swift`
- `Sources/ContinuumRevivedCoreChecks/AgentContextOccupancyChecks.swift`
- `Sources/ContinuumRevivedCoreChecks/PiEventTranslatorChecks.swift`
- one existing installed-row/supervisor witness if translator-only coverage cannot prove the visible status
- comments in `AgentCompactStatusPresentation.swift` only where they currently misdescribe Pi telemetry

Avoid changing the radial drawing view: it correctly draws a fraction when one is supplied. Avoid model-specific hard-coded windows, new persisted schema fields, or a Pi-only UI path.

## Acceptance criteria

- A completed Pi turn with `totalTokens = 180992` and model window `272000` yields stored `usedTokens = 180992`, `maxTokens = 272000`, and a visible ring/label near `67%`.
- Missing/invalid `totalTokens` or missing model window leaves occupancy unknown; it never invents `0%` or a denominator.
- Duplicate usage events remain deduplicated.
- Pi `stopReason: error` cannot produce `.completed` or ready/idle as its final visible turn result.
- Pi `stopReason: aborted` maps to the established interrupted/cancelled state and restores composer availability.
- A successful Pi turn still ends ready/idle.
- Restored occupancy remains numerically visible but stale-qualified.
- Existing Claude and Codex occupancy/status behavior is unchanged.
- Targeted checks, relevant rendered/status checks, full matrix, and real dev-app dogfood are all reported separately with actual outcomes.

## Out of scope

- redesigning the radial meter;
- warning/critical threshold policy;
- changing Pi, its models store, or its auth flow;
- replacing JSON mode with RPC;
- general ingestion of all Pi retry/compaction/session events unless a focused failing witness requires one for truthful occupancy or status.
