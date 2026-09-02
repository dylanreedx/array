# Array Compaction Lifecycle

## Summary

Add compaction as a first-class provider operation rather than treating `/compact` as a prompt. Support native manual compaction for Claude, Pi, and Codex; observe provider-initiated automatic compaction; preserve strict FIFO ordering with queued prompts; and represent compaction honestly when token counts or outcomes are unknown.

## Core behavior

- Introduce a provider-neutral `AgentCompactionRunning` capability and structured lifecycle events. Compaction never travels through `run(prompt:)`.
- Track requested, running, succeeded, failed, cancelled, and indeterminate phases; manual, threshold, overflow-recovery, provider-automatic, and unknown triggers; stable boundary IDs; exact or estimated token readings; retry state; provider; and timestamp.
- Give each agent one operation lease and a context epoch. Successful compaction increments the epoch; unsuccessful compaction does not. Reject stale telemetry from older runner generations or epochs.
- Deduplicate live and rehydrated boundaries by provider-stable identity. Preserve Array's complete transcript and never persist provider summaries, focus instructions, or opaque Codex compaction content.
- Extend persistence with optional fields so old records and compaction titles remain readable.

## Provider behavior

- Claude resumes the existing session and invokes native `/compact`, optionally with focus text. Status and compact-boundary frames drive lifecycle state, and Claude token counts are exact.
- Pi uses the persistent RPC process, sends `compact` once, listens while idle as well as during turns, preserves manual/threshold/overflow reasons and retry state, and labels post-token counts as estimates.
- Codex requires app-server plus an existing thread ID. A dedicated process initializes, resumes the thread, calls `thread/compact/start`, waits for the `contextCompaction` item to complete, and exits without calling `turn/start`. Focus text is rejected and opaque content is never inspected.
- Automatic policy is observe-only. Show effective settings only when a provider reports them; otherwise display provider-managed/unknown.

## Commands, queue, and recovery

- Make `/compact [focus]` canonical. Legacy provider-prefixed IDs resolve to the same typed intent but do not create duplicate completion rows.
- Resolve compaction while ready or working. Unsupported requests and Codex focus rejection preserve the draft.
- Replace the prompt-only queue with tagged prompt/compaction FIFO work items and migrate old queue files during decoding.
- Persist an in-flight compaction journal before dequeue. Success resumes FIFO; failure, cancellation, or uncertainty pauses later work until explicit resume.
- On relaunch, an unfinished journal becomes indeterminate and is never automatically retried. A subsequently rehydrated matching boundary may reconcile it to success.

## UI

- Show `Compacting context…` only while running and use a dedicated collapsed boundary renderer.
- Show exact token transitions only for exact pairs; prefix estimates with `≈`; never render `? → ?`.
- Render failures, cancellations, and indeterminate outcomes distinctly and explain recovery.
- Keep observed provider thresholds separate from Array's generic 75% and 90% pressure warnings.

## Verification

- Add focused `ContinuumRevivedCoreChecks --agent-compaction-check` and `Array --agent-compaction-ui-check` gates and register both in `scripts/run-matrix.sh` plus its inventory.
- Cover native dispatch, automatic-boundary behavior, epoch transitions, stale-event rejection, unknown occupancy, trigger fidelity, durable FIFO migration, pause/recovery, crash uncertainty, deduplication, transcript privacy, unsupported requests, focus rejection, and duplicate compaction refusal.
- Run:
  - `swift build --product ContinuumRevivedCoreChecks`
  - `.build/debug/ContinuumRevivedCoreChecks --agent-compaction-check`
  - `swift build --product Array`
  - `.build/debug/Array --agent-compaction-ui-check`
  - `CONTINUUM_SKIP_UI_BASELINES=1 scripts/run-matrix.sh`

The current full CoreChecks baseline has a pre-existing I2 grouped-view profile failure. Do not attribute it to this work or weaken that gate.
