# 09 — Codex transcript rehydration on resume

Status: **implemented in source 2026-08-10; app build green. Focused CoreChecks
is blocked by an unrelated concurrent `SettingsField.slider` exhaustiveness
error, and installed/live-app smoke was intentionally not run.**

## Outcome

A managed agent backed by the native Codex CLI must reopen after an Array
relaunch with the same locally rendered previous transcript that Claude and Pi
agents already receive. The restored tile leads with `Previous session — N
messages restored`, renders the bounded prior conversation below it, stays
idle until the user submits the next prompt, and then continues the exact stored
Codex thread through `codex exec resume <thread-id>`.

Today these are two different capabilities:

- provider continuity exists: `AgentRecord.codexThreadId` is persisted and
  `CodexAgentRunner` reads it for the next turn;
- transcript rehydration does not: `ManagedTranscriptRehydrator` only locates
  Claude and Pi session files, returns `nil` for a Codex-only agent, and
  `ContinuumApp.rehydratePreviousSessionOrNotice` falls back to the old notice
  banner.

This plan closes the Codex display gap and adds an end-to-end witness that the
next prompt still resumes the same provider thread. It does not auto-start a
Codex process at launch.

## Root cause and regression boundary

Transcript rehydration shipped in `14e50ff` for Claude and Pi. The Codex backend
landed immediately afterward in `203d2b2`; the merge in `a934c1b` did not add a
Codex reader or extend the rehydrator's provider selection. Native Codex later
became the normal route for `openai-codex/*` models, exposing the missing branch
as a regression in the restored-agent experience.

The concrete fallback is:

1. `AgentSupervisor.restore()` marks the record restored.
2. `wireManagedAgentTile` calls `rehydratePreviousSessionOrNotice`.
3. `ManagedTranscriptRehydrator.rehydrate` checks only the Claude UUID file and
   the Pi derived-session file.
4. Neither exists for a native Codex agent, so it returns `nil`.
5. The tile renders `Previous session — send a prompt to continue.`

The existing `.plans/03-transcript-rehydration.md` header also still says
“planned, not started” even though the Claude/Pi implementation shipped. Update
that status as part of this work so the documentation no longer hides the
provider gap.

## Locked decisions

### Identify the rollout by stored thread ID

Codex continuity is stored, not derived. `AgentRecord.codexThreadId` is the
authoritative identity and the reader must match it exactly against the rollout
`session_meta.payload.id`. Never select the newest rollout or rely on cwd alone:
multiple Array agents can run concurrently in the same checkout.

Search Codex's active session tree under `<codex-home>/sessions/**/rollout-*.jsonl`
and the archived-session location supported by the installed Codex CLI. Resolve
`codex-home` from the child process environment (`CODEX_HOME` when present,
otherwise `~/.codex`). A zero-match or ambiguous-match result fails closed to the
existing notice.

### Reuse the display-only rehydration boundary

Codex rollout bodies remain desktop-local. The reader returns the existing
`RehydratedTranscript`; `AgentSupervisor.seedRehydratedTranscript` stores it in
the display-only buffer; `ManagedAgentTileNSView.renderRehydratedPreviousSession`
ingests it directly into the tile projection. It must never pass through
`AgentSupervisor.deliver`, `events(for:)`, or `recordManagedActivity`, because
those paths can cross the companion sync boundary.

### Parse the rollout schema, not `codex exec --json`

The persistent rollout is not the runner's small stdout schema. Structural
inspection of the current local format shows these useful envelopes:

- `event_msg/user_message` — prior user text;
- `event_msg/agent_message` — prior visible assistant text;
- `response_item/reasoning` — prior visible reasoning summaries when present;
- `response_item/function_call` and `function_call_output` — tool lifecycle;
- `session_meta` — exact thread identity and cwd;
- `turn_context`, `token_count`, task markers and other telemetry — not
  transcript content.

Use one canonical source for each visible message so duplicated
`response_item/message` and `event_msg/*_message` representations do not render
twice. Ignore encrypted reasoning content; only parse an explicitly visible
summary/text shape established by a captured fixture. Tool results restore
completion/failure status, not raw output bodies, matching the existing
Claude/Pi rehydration posture.

## Scope

Included:

- exact Codex rollout location by persisted thread ID;
- pure rollout JSONL normalization into the existing provider-neutral message
  model;
- bounded tail reading and the existing “earlier history not shown” disclosure;
- user, assistant, reasoning-summary and tool-lifecycle reconstruction;
- provider selection across Codex, Claude and Pi;
- display-only/I5 verification;
- a restored-Codex tile integration witness;
- a separate real runner-continuity witness for the next prompt;
- correction of stale transcript-rehydration plan/backlog status.

Deferred:

- auto-resuming provider processes at app launch;
- rendering raw tool output or encrypted reasoning;
- changing the previous-session card design or adding a collapse interaction;
- changing Codex context-occupancy telemetry (`.plans/08` owns that work);
- changing stale-thread self-healing semantics in `CodexAgentRunner`.

## Implementation plan

### 1. Add a shared exact Codex rollout locator

Create `CodexRolloutLocator` in Core. Its pure contract accepts a sessions root
and full thread ID and returns exactly one verified rollout URL only when:

- the candidate is a readable regular `rollout-*.jsonl` file;
- its first `session_meta` record parses successfully;
- `session_meta.payload.id` equals the complete stored thread ID;
- duplicate candidates can be resolved only by an explicit active-versus-
  archived rule, never by “latest file wins”.

Factor or reuse the safe enumeration/session-meta pieces currently private to
`CodexAgentStateReader`; do not create a third recursive rollout scan. Keep
cwd-based state observation and thread-ID-based resume lookup as separate public
operations over the same locator substrate.

Primary files:

- `Sources/ContinuumRevivedCore/AgentProviders/CodexRolloutLocator.swift` — new;
- `Sources/ContinuumRevivedCore/Agents/CodexAgentStateReader.swift` — delegate
  enumeration/meta parsing where practical without changing its cwd behavior.

### 2. Add `CodexSessionTranscriptReader`

Create a pure parser matching the existing Claude/Pi reader shape:

```swift
public enum CodexSessionTranscriptReader {
    static func parse(
        lines: [String],
        threadId: String,
        truncated: Bool = false,
        limits: RehydrationLimits = .init()
    ) -> RehydratedTranscript

    static func read(
        sessionFileURL: URL,
        threadId: String,
        limits: RehydrationLimits
    ) -> RehydratedTranscript
}
```

Normalize rollout records into `NormalizedTranscriptMessage` and reuse
`ManagedTranscriptRehydrator.assemble` for caps, turn boundaries and event
construction. Preserve source order while deduplicating mirrored message
representations by their stable item/turn identity where available.

Mapping:

- user message → `.userPrompt(text)`;
- agent message → assistant `contentDelta`;
- visible reasoning summary → reasoning `contentDelta`;
- function/custom-tool call → `itemStarted` with a generic safe title;
- matching output → `itemCompleted` with completed/failed status;
- telemetry, context, task markers, developer/system instructions and unknown
  records → ignored.

Malformed lines fail individually rather than dropping the whole transcript.
An empty parse returns no rehydration so the existing notice remains honest.

Primary file:

- `Sources/ContinuumRevivedCore/AgentProviders/CodexSessionTranscriptReader.swift`
  — new.

### 3. Thread Codex identity and home through provider selection

Extend `ManagedTranscriptRehydrator.Inputs` with:

- `codexThreadId: String?`;
- resolved `codexHomeURL` or sessions roots;
- the actual preferred `AgentBackendConfig.Route`, resolved by
  `AgentSupervisor` using the same backend preference and live CLI availability
  as `productionRunner`.

`AgentSupervisor.rehydrationInputs(for:)` supplies the record's persisted
`codexThreadId`. Provider selection then follows this order:

1. resolve every provider file that can be proven to belong to this agent;
2. prefer the provider route the agent would run now when that provider has a
   valid transcript;
3. otherwise use the one unambiguous existing transcript;
4. if none can be proven, return `nil` and retain the notice fallback.

This keeps model-switch behavior deliberate and prevents an older Pi/Claude
file from hiding the newer native Codex thread.

Primary files:

- `Sources/ContinuumRevivedCore/AgentProviders/ManagedTranscriptRehydrator.swift`;
- `Sources/ContinuumRevived/App/AgentSupervisor.swift`.

`ContinuumApp.rehydratePreviousSessionOrNotice` and
`ManagedAgentTileNSView.renderRehydratedPreviousSession` should require no new
rendering path.

### 4. Prove display rehydration through the real restore wiring

Extend `TranscriptRehydrationChecks.swift` with a captured, body-sanitized Codex
rollout fixture covering:

- session meta with exact thread ID;
- user and assistant messages;
- a visible reasoning summary;
- one completed and one failed tool call;
- mirrored message envelopes to prove deduplication;
- malformed and unknown lines;
- a file larger than both message and byte caps.

Extend the existing `runAgentRestoreChecks` section that already plants Claude
and Pi files:

1. persist an `AgentRecord` with `model = openai-codex/...` and a known
   `codexThreadId`;
2. plant its rollout under a temporary Codex home;
3. call the real restore/rehydration path;
4. assert the planted user and assistant text reaches the tile;
5. assert the placeholder text does not;
6. assert `Previous session — N messages restored` leads the cards;
7. assert the tile is idle and sendable;
8. assert the syncable activity draft recorder remains empty;
9. assert a wrong/latest rollout from the same cwd is not selected.

Teeth-check the witness by temporarily removing the Codex branch from
`ManagedTranscriptRehydrator.rehydrate` and confirming the check turns red.

### 5. Prove the next prompt resumes the same Codex thread

Transcript display and provider continuation are separate contracts. Add an
app-side runner-factory witness over a restored record which asserts:

- `AgentSupervisor.codexRunnerConfig(for:)` receives the persisted thread ID;
- the first post-restore argv is `codex exec resume <same-id> ...`;
- a `thread.started` observation with that same ID does not rewrite identity;
- the accepted prompt appends below the rehydrated boundary exactly once.

Keep the existing live two-turn Codex continuity smoke as the external gate. If
the stored rollout is missing, the current self-heal to a fresh thread remains
valid, but the old transcript must not be falsely presented as the newly resumed
thread.

### 6. Correct documentation and matrix inventory

- Mark `.plans/03-transcript-rehydration.md` as shipped for Claude/Pi with Codex
  explicitly completed by this plan.
- Update `.plans/backlog.md` to name all three supported providers only when the
  implementation and witnesses are green.
- Register any new Core check entry point in
  `Sources/ContinuumRevivedCoreChecks/main.swift` and re-bless the matrix
  inventory.

## Verification

Required automated gates:

```sh
swift run ContinuumRevivedCoreChecks --transcript-rehydration-check
swift run Array --agent-restore-check
swift run ContinuumRevivedCoreChecks --codex-agent-backend-check
swift build --product Array
./scripts/run-matrix.sh
```

Required installed-app smoke:

1. Start a native Codex-backed managed agent and exchange at least two turns,
   including one tool call.
2. Record the agent's persisted `codexThreadId` without exposing transcript
   content in logs.
3. Quit and relaunch Array.
4. Open the restored agent from History/inbox.
5. Confirm the previous user/assistant conversation appears behind the restored
   boundary instead of the placeholder.
6. Send a codeword-recall prompt.
7. Confirm the response recalls the prior codeword and the Codex process used
   the same thread ID.
8. Confirm no restored message bodies entered the companion activity timeline.

## Completion criteria

- Native Codex, Claude and Pi restored agents all rehydrate prior transcripts.
- Exact stored Codex thread identity selects the rollout; newest/cwd heuristics
  cannot cross agents.
- Missing, archived-unavailable, malformed or ambiguous rollouts fail honestly
  to the existing notice.
- Rehydrated bodies stay display-only and never sync.
- The first new prompt after relaunch resumes the same Codex thread when its
  rollout still exists.
- The old placeholder is no longer the normal path for a valid native Codex
  session.

## Implementation record — 2026-08-10

Implemented the source path described above:

- shared `CodexRolloutLocator` enumeration/metadata decoding now backs the
  existing state reader and exact stored-thread lookup;
- active and archived rollouts are matched by full `session_meta.payload.id`,
  with ambiguity failing closed;
- `CodexSessionTranscriptReader` restores canonical event-message bodies,
  visible reasoning summaries and tool lifecycle while ignoring mirrored
  message rows, raw tool output/arguments and encrypted reasoning;
- `ManagedTranscriptRehydrator.Inputs` now carries the stored Codex identity,
  resolved Codex home and production backend route;
- the restored-agent witness plants a wrong same-cwd rollout and an exact
  rollout, asserts only the exact transcript renders display-only, and proves
  the restored runner's argv starts `exec resume <same-id>`.

Verification performed without launching or interacting with the installed
Array app:

- `swift build --disable-sandbox --product Array` — passed;
- `git diff --check` — passed;
- the Core and transcript-check sources compiled, but linking the full
  `ContinuumRevivedCoreChecks` target stopped on an unrelated concurrent change:
  `main.swift` does not yet handle the new `SettingsField.slider` case;
- `--agent-restore-check`, matrix, and installed-app smoke were not executed to
  honor the explicit constraint not to touch the live production app.
