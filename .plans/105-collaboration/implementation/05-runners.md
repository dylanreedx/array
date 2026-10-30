# Managed runners: shared views and host-owned control

Research: 29 October 2026. Implementation planning only. Source inspection establishes existing seams, not exercised provider behavior. No CLI, app, tmux or production service was launched and no runner/product code was changed.

## Feasibility judgment

Shared live agent views are feasible without moving the executing session: Array already has app-lifetime runner ownership, multicast output and an atomic transcript snapshot plus live tail. Multi-human controls need new authenticated command routing, durable deduplication and human attribution above that seam. They must not instantiate a second runner on the recipient.

This is a component of a shared work area containing several people's own agents. The product does not need everyone to operate the same session. Two participants can inspect each other's published work while each deliberately supplies agreed context to their own host-local agents.

## Existing production seams

| Source | Observed contract | Planning implication |
| --- | --- | --- |
| [AgentSupervisor.swift](../../../Sources/ContinuumRevived/App/AgentSupervisor.swift), `AgentRunning` / `AgentSteeringRunning` / `AgentRequestResponding` | Runner capabilities derive from the bound process/refinement, not a provider-name table. | Publish a host capability snapshot and revalidate it at command execution. Do not claim universal controls from `harness`. |
| Same file, `runners`, `runnerGenerationTokens`, `idleSessionRunners` around lines 1122–1130 | One active runner per agent, retained generation tombstones, separate reusable idle sessions. | Shared identifiers include host/session generation; old remote input must never bind to a replacement runner accidentally. |
| Same file, `sendPrepared` around line 2884 | Refuses a second in-flight runner and checks expected agent identity and readiness. | Route through the supervisor rather than start providers in the collaboration client. |
| Same file, `transcriptAttachment` around line 7496 | Atomically returns complete semantic snapshot and registers a tail on the main actor. | Better export foundation than rebuilding from a tile or its bounded `events(for:)` history. |
| Same file, `turnSnapshot` around line 6510 | Locally mirrored/observed agents have no local send/stop; capabilities reflect current occupancy/request responder. | A remote shared view needs its own controller/client capability model, not a fake locally managed `AgentRecord`. |
| [ManagedAgentTileNSView.swift](../../../Sources/ContinuumRevived/Canvas/ManagedAgentTileNSView.swift), transcript attachment around line 822 | Existing tile attaches to a supervisor-owned semantic snapshot and event tail. | Factor a view data-source seam that remote projections can implement without inheriting runner launch behavior. |
| [AgentStatusEngine.swift](../../../Sources/ContinuumRevivedCore/AgentStatusEngine.swift), `AgentRuntimeEvent` around line 770 | Codable semantic/runtime events include text, questions, titles, errors and usage; no network sequence or authenticated human author is inherent in these cases. | A network envelope and explicit export policy are needed. Codable is not permission to publish every field. |
| [AgentComposerDraftStore.swift](../../../Sources/ContinuumRevivedCore/AgentComposerDraftStore.swift) | Durable host-local draft, submission-recovery and queued-message stores; file references include local paths. | Reuse recovery behavior; do not sync this store or treat it as a remote-command inbox. |
| [AgentPrompt.swift](../../../Sources/ContinuumRevivedCore/AgentPrompt.swift) | Prompt attachments and file references contain local file URLs and are deliberately non-Codable transport capabilities. | Remote attachments require authorized upload/materialization to host-managed content, then ordinary preparation checks. A recipient's `@path` is not usable on another machine. |
| [AgentMessageEnvelope.swift](../../../Sources/ContinuumRevivedCore/AgentMessageEnvelope.swift) | Existing attribution is specifically agent-to-agent; typed user text that impersonates its envelope is neutralized. | Add authenticated human provenance as structured metadata. Do not represent teammates as agents or trust text/XML as identity. |
| [ExternalSessionHandoff.swift](../../../Sources/ContinuumRevivedCore/ExternalSessions/ExternalSessionHandoff.swift) | Watching and moving-here are distinct; unknown ownership is not released. | Remote observation does not authorize concurrent session writes or transfer execution. |

Line numbers describe the inspected working tree and may move. Read actual definitions before implementing.

## Per-provider capability matrix from current source

All rows describe source-level capability, not new live tests. Final availability must be negotiated from the actual bound runner and current turn state.

| Capability | Claude managed runner | Codex managed runner | Pi RPC managed runner |
| --- | --- | --- | --- |
| Semantic output / transcript projection | Claude event translator into supervisor; snapshot/tail available | Codex event translator into supervisor; snapshot/tail available | Pi event translator into supervisor; snapshot/tail available |
| New ordinary prompt | `AgentRunning.run`; process retained across turns while useful | `run`; app-server turn path and CLI backend exist | `run`; long-lived RPC process |
| Array-owned next-turn queue | Supervisor queue; not a provider-specific claim | Same supervisor queue | Same supervisor queue |
| In-flight steering | `AgentSteeringRunning`; user-message replay/interrupt dispositions track acceptance/consumption | `AgentSteeringRunning`; app-server `turn/steer` pinned to `expectedTurnId`; no generic promise for exec fallback | `AgentSteeringRunning`; `steer` RPC, consumed through queue updates; turn-boundary after current tools, not mid-tool interruption |
| Turn interruption | Stream-json interrupt request; fallback process teardown is separate | App-server `turn/interrupt`; `stop()` has process termination fallback | RPC `abort`, leaves session transport available; clears/returns unread steer queue |
| Idle/background behavior | Long-lived process; unsolicited turns/background jobs can continue | Per-active-turn app-server control; do not assume persistent idle remote control | Long-lived RPC process; session kept for next turn |
| Provider request approval response | **Not presently wired through a production `AgentRequestResponding` conformer** | **Not presently wired through a production `AgentRequestResponding` conformer**; backend explicitly supplies `approval_policy=never` / `approvalPolicy: never` | **Not presently wired through a production `AgentRequestResponding` conformer**; workspace-tool bridge replies are a different path |
| Attachment preparation | Host-local image/file prompt preparation | Host-local image/file prompt preparation | Host-local image/file prompt preparation, including image-bearing steer payload |
| Usage observations | Translator reports provider result usage/context observations | Exec turn-completed usage plus app-server path; separate live telemetry study required | Usage observations from message usage with deduplication |
| Arbitrary external CLI session control | Not implied; separate discovery/watch/move rules | Not implied; provider application thread ownership may remain unknown | Not implied by managed RPC capability |

Evidence: app-target conformances in `AgentSupervisor.swift` near lines 189–228; concrete steer/interrupt methods in [ClaudeAgentRunner.swift](../../../Sources/ContinuumRevivedCore/AgentProviders/ClaudeAgentRunner.swift), [CodexAgentRunner.swift](../../../Sources/ContinuumRevivedCore/AgentProviders/CodexAgentRunner.swift) and [PiRpcAgentRunner.swift](../../../Sources/ContinuumRevivedCore/AgentProviders/PiRpcAgentRunner.swift). [PiAgentRunner.swift](../../../Sources/ContinuumRevivedCore/AgentProviders/PiAgentRunner.swift) is also present as the older one-shot implementation; production factory currently builds Pi RPC. Do not give a future one-shot/fallback instance RPC capabilities by provider name.

Important gap: repository-wide inspection found `AgentRequestResponding` conformances only in `ProviderRequestResponseChecks`' scripted `RespondingRunner`, not the real runners. `respondToRequest` has a meaningful checked seam, but cannot establish shipped provider response support. Keep remote approval unavailable unless an actual bound implementation is added and witnessed. Existing companion or workspace API approval handling must not be confused with provider command approval transport.

## Recommended projection boundary

Introduce a collaboration-specific `PublishedAgentRef`/projection, with opaque shared identity, host ownership, permitted metadata, live-state freshness, explicit capabilities and transcript/artifact references. Names are provisional. Do not serialize `AgentRecord`, composer drafts, provider config, host paths, credentials or raw side-channel observations.

Use a durable snapshot plus sequenced tail, scoped by shared-area membership and publishing revision. Each tail frame needs host/session identity, generation, monotonic stream sequence and stable event identity. Cursor after a snapshot must identify its exact boundary. If retention cannot satisfy reconnect, return a fresh permitted snapshot rather than skip unknown gaps or replay a turn into execution.

Semantic transcript content may itself contain code, secrets, local path text or private human material. The owner chooses the included history/content; the host enforces that choice before export. Existing phone-safe metadata streams are not automatically a complete code-sharing contract. An output-sanitization pass alone does not prove no sensitive content can cross.

A recipient-side remote agent view must never call local supervisor restore/spawn/send as if it owned the provider session. Reference removal, area close, hydration retirement, app restart and reconnect change view subscriptions only. The owner process continues according to its own lifecycle. Publish host-disconnected and last confirmed state separately; disconnection is not an observed process termination.

## Command routing and human attribution

Keep the initial area workflow centered on discussion and deliberate dispatch to each person's own agents. Add another person's direct control only under an explicit capability grant. Both cases can use the same durable command contract; UI defaults may differ.

Proposed command envelope contains authenticated human principal, area and membership revision, target published session/host/generation, command ID, explicit action (`send`, `queue`, `steer`, `interrupt`), prompt/context revision, authorized content handles and optional author/accepting-operator provenance. Actor identity comes from transport/auth, never a client-supplied display name.

At the host, authorize against current membership and session rights immediately before accepting work; reject stale generation/turn targets. Persist a command receipt/idempotency record before or transactionally with the dispatch boundary, and recover uncertain outcomes without blind repeat. A duplicate command returns its original receipt. A different payload with the same command key is an error. Area-history persistence and dispatch ledger must not produce a double send after crash.

Then use the existing `accept`/prepared-prompt/composer pathway instead of bypassing validation through direct runner calls. Preserve the current distinction between **accepted by Array**, **queued locally**, **provider accepted/consumed**, **turn started** and **completed**. `IntentAcceptance.accepted` is not execution completion. On reconnect or host crash, expose uncertainty if evidence cannot decide whether dispatch happened.

Do not implement remote “Stop” by blindly calling supervisor `stop(id)`: the composer `.stop` route attempts turn interruption, whereas teardown `stop(id)` kills. The command needs the intended scope. Similarly, Pi steering has turn-boundary semantics; UI must not promise mid-tool steering across providers.

## Ticket candidates

### RUN-01 — Publish authorized agent snapshots and reference-only remote views

**Outcome:** a shared area can show two hosts' real agent transcripts/status without creating another executor or leaking excluded host state.

Dependencies: shared-area identity/membership model, authenticated transport, area object references and view data-source integration.

Scope: permitted projection schema, atomic snapshot/tail bridge, bounded sequencing/backpressure, reconnect refresh, negotiated live controls, remote view lifecycle. Keep artifact bytes in the separate artifact service.

Acceptance/witness: two isolated host fixtures and two views; late join sees permitted snapshot plus each subsequent event once; private history excluded from delivered bytes; dropped tail leads to resnapshot; remove/readd/hydrate/relaunch recipient creates zero runners; source runner count remains exactly one. A stale host generation cannot update the new view. Mount through the production workspace scene owner for canvas assertions. Register deterministic behavioral legs in the matrix and confirm the summary reports them.

### RUN-02 — Route attributed, idempotent human dispatch through host supervision

**Outcome:** a participant deliberately sends a specific shared-context revision to a chosen authorized agent, retaining proposer/acceptor and actual dispatch outcome.

Dependencies: RUN-01, human permissions, immutable context/artifact revisions, durable host command receipt store. Human discussion itself must never auto-dispatch.

Scope: explicit send/next-turn queue; host checks and prepared attachment materialization; durable receipt/recovery; structured provenance; optional steer/interrupt only when bound capabilities and exact target state permit. Start with each owner's own agents plus owner-accepted teammate suggestions; direct coworker prompting is a separate grant rather than an assumed default.

Acceptance/witness: duplicate/reordered delivery, dropped response and crash around dispatch create at most one authorized dispatch or an honest unresolved receipt; spoofed authorship, revoked membership, wrong host, stale turn/generation and inaccessible attachment are rejected. A queued proposal can be withdrawn before provider submission; sent input is not mislabeled as cancellable. Local and remote UI display the same author/context revision and outcomes. Script all three production runner transport seams offline, including Codex steer refusal and Pi boundary disposition.

### RUN-03 — Negotiate provider control gaps before advertising approvals or transfer

**Outcome:** remote control UI advertises only witnessed bound-runner actions, and unsupported provider approvals/external ownership are explicit.

Dependencies: RUN-01 capability publication; separate authorization for approvals/terminal/transfer if those are later scoped in.

Scope: production capability audit, no production responder => no approval button, distinguish workspace-tool approval from provider request handling, enforce watched/externally held sessions as non-writable. Actual provider approval implementation or cross-host transfer should be follow-on work with provider-specific contracts; it is not required to unlock shared areas.

Acceptance/witness: scripted production-bound capability snapshots for Claude/Codex/Pi RPC/one-shot fallback; transient disconnect invalidates operations; unsolicited Claude background turn updates status without an extra executor; unknown external owner refuses writes; no QA-only responder makes production controls look supported. If real response transport is implemented, prove accepted-for-dispatch, actual provider response and resolution separately, including duplicate/stale request rejection.

## Remaining uncertainties and limits

- The current code has extensive source comments with historical one-shot assumptions. The inspected live definitions and factory sites take precedence; future work must reconfirm bindings in the intended release branch.
- There is no universal durable transcript event sequence ready for the network. A collaboration event envelope and retained snapshot boundary are new work.
- Existing human prompts have local transcript IDs generated on echo; they do not supply authenticated multi-human provenance or remote idempotency by themselves.
- Provider subprocess acceptance can be unknowable after certain crashes. The product must preserve that uncertainty rather than promise exactly-once external side effects.
- Attachment bytes and relative code references require authorized materialization. Host-local path references cannot simply travel between collaborators.
- No real cross-provider prompt, approval, attachment, cancel, transfer or usage tests were run. Future provider capability probes must use fixtures/disposable projects and maintain CLI-owned auth and production-state isolation.

Validation in this task: read source definitions and call sites only; some first-pass guessed file paths were absent and were corrected by `rg` discovery. No runtime assertions are claimed. Board mutations and final phased-ticket selection belong to the parent coordinator, not this research agent.
