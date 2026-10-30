# Implementation research: teammate usage and presence on hover

29 October 2026. Planning only; no product implementation, provider invocation, app launch or runtime verification. Evidence is current source inspection, including pre-existing working-tree changes. Dylan's requirement is **live teammate token usage through cursor/avatar hover, with no constant usage overlay**. Numerical accuracy and partial/stale disclosure refine that requirement rather than removing it.

## Feasibility and the missing layer

Feasible: current managed runners already produce numeric usage events. The missing abstraction is an authoritative accounting ledger that preserves identity, counter semantics and coverage before publishing a collaborator summary. The current context meter is a measurement of the latest request's context occupancy, not a daily usage ledger.

`TokenUsageSnapshot` in [AgentStatusEngine.swift](../../../Sources/ContinuumRevivedCore/AgentStatusEngine.swift) contains only `inputTokens`, `outputTokens` and optional `totalCostUsd`. Its runtime event supplies a thread ID, but the snapshot has no timestamp, provider request identity, cumulative-versus-delta classification, cache categories, source owner or billing basis. Summing those snapshots would produce incorrect teammate totals. The richer `AgentContextWindowSnapshot` carries source/freshness/cache/cost fields but mixes per-request occupancy with run accounting; it is not an interchangeable ledger event.

No durable per-person daily usage ledger was found in the inspected current paths. This is a bounded source-search finding, not proof no usage-related code exists anywhere else.

## Actual runner capability matrix

| Runner/path | Source-observed emissions | Counter/coverage caution | Honest hover behavior before new telemetry support |
| --- | --- | --- | --- |
| Claude stream-json | `ClaudeEventTranslator.mainThreadPromptSnapshot` emits latest main-request prompt/cache observations from `message_start` and assistant usage. `translateResult` emits a run aggregate via `.tokenUsageUpdated` and processed/cost detail. | A result sums requests across the run; assistant frames describe one request. They cannot be summed together. Child frames are routed separately, and adopted children deliberately receive no occupancy meter. Whether parent accounting already includes descendants must be established before child totals are added. | Update observed request context promptly; publish finalized run accounting when reported. Do not present incomplete output as a measured continuously incrementing output count. |
| Codex app-server | `CodexAppServerEventTranslator.translateTokenUsage` consumes `thread/tokenUsage/updated`; `total` emits accounting and `last` emits per-request context. | `total` is cumulative session usage per current source contract, not an additive delta. Cached input is a subset of input on Codex. Notification/turn identity must survive normalization before dedup. | Show freshest reported session delta from a persisted baseline; report freshness explicitly. No guarantee of per-token callbacks. |
| Codex exec / rollout | `CodexEventTranslator.usageEvents` emits cumulative accounting at completion. `CodexRolloutTelemetry` reads bounded `token_count` records for latest request occupancy. | A rollout snapshot's `totalProcessedTokens` is latest-request usage, not session lifetime accounting. It cannot be accumulated as a stream of independent requests without identity. | Accounting updates at completion on this path; latest context may update independently. Mark accounting as pending while a turn runs if appropriate. |
| Pi RPC | `PiEventTranslator.translateUsageEvents` reads `message.usage`; `message_end` and `turn_end` can report the same response. It emits message input/output/cost plus richer cache and total observations. | Existing signature dedup uses response ID or timestamp and counters. Messages lacking either identity are not deduplicated by that set. It is in-memory translator state, not durable exactly-once accounting. Distinct per-message events must not be treated as cumulative session snapshots. | Update on reported message usage, with a durable message identity or explicitly weaker coverage. Do not manufacture streaming counts. |
| External/terminal sessions | Local transcript watching exists; Codex rollout can project limited numeric facts. | Observation availability is not universal machine-wide accounting or guaranteed request identity. Legacy sessions and terminal stdout should not become synthetic zeros. | Mark unsupported/partial coverage; include only authorized, observed measurements. |

Evidence: [ClaudeEventTranslator.swift](../../../Sources/ContinuumRevivedCore/AgentProviders/ClaudeEventTranslator.swift), [CodexAppServerEventTranslator.swift](../../../Sources/ContinuumRevivedCore/AgentProviders/CodexAppServerEventTranslator.swift), [CodexEventTranslator.swift](../../../Sources/ContinuumRevivedCore/AgentProviders/CodexEventTranslator.swift), [CodexRolloutTelemetry.swift](../../../Sources/ContinuumRevivedCore/AgentProviders/CodexRolloutTelemetry.swift), [PiEventTranslator.swift](../../../Sources/ContinuumRevivedCore/AgentProviders/PiEventTranslator.swift).

Existing checks document useful fixtures: [PiEventTranslatorChecks.swift](../../../Sources/ContinuumRevivedCoreChecks/PiEventTranslatorChecks.swift) covers duplicate message/turn reports and raw-data exclusion; [ClaudeAgentBackendChecks.swift](../../../Sources/ContinuumRevivedCoreChecks/ClaudeAgentBackendChecks.swift) separates run sums from request occupancy; [CodexAgentBackendChecks.swift](../../../Sources/ContinuumRevivedCoreChecks/CodexAgentBackendChecks.swift) and [CodexAppServerParityChecks.swift](../../../Sources/ContinuumRevivedCoreChecks/CodexAppServerParityChecks.swift) cover current normalization. These checks were read, not run.

## Normalize without inventing cross-provider equivalence

Introduce an additive accounting contract alongside existing occupancy events. Preserve original semantic type:

- Provider/model and adapter version.
- Host/device, authoritative session/runner generation, provider session, run/turn/request/message identity where genuinely available.
- Whether the observation is a request total, run total, cumulative session checkpoint or a correction; whether it includes child work.
- Raw numeric categories with declared semantics: fresh input, total input, cached input subset, cache writes, output and provider total when supplied. Unknown fields remain unknown.
- Provider observation time when available, host receipt time, report sequence and durability status.
- Cost amount plus [AgentCostBasis](../../../Sources/ContinuumRevivedCore/AgentCostBasis.swift); never turn a list-price estimate into money billed.

The Pi fixture has input/output plus separately reported cache fields and a provider `totalTokens` that equals input+output. Existing comments are inconsistent about whether Pi input is pre-summed: Claude's result comment says it is, whereas the Pi occupancy fixture explicitly derives prompt size as input+cache-read+cache-write. Therefore choose a named usage-total definition using actual protocol fixtures and provider semantics before adding cache categories to a cross-provider total. Preserve reported categories losslessly in the meantime. Codex cached input must never be added again to inclusive input. Claude's run input combines its three separate input counters in the current adapter.

## Proposed authoritative ledger

The execution host emits authorized numeric observations; viewers do not derive usage by counting transcript appearances or tiles. Store deduplicated source observations and normalized accounting increments durably before publishing summaries. A collaborator's two views of one agent count once.

For cumulative sources, persist checkpoints keyed by provider session plus accounting epoch; compute nonnegative increments only within a known continuous epoch. A counter reduction, reset, session fork, adapter change or missing baseline needs a reconciliation state, not an arbitrary subtraction or full lifetime total added again. The first observed lifetime checkpoint cannot honestly be attributed to today without historical event evidence. Record available coverage from that point or recover authorized history under a separate backfill process.

For message/run totals, upsert the same observation identity and handle later revisions explicitly. Do not count a finalized run and the same run's interim requests twice. Retry dedup uses provider/work identity, not merely equal numeric values: two real requests can cost the same. Native subagents and separately managed agents need an inclusion contract; when a parent already includes child usage, use an authoritative inclusive parent or mutually exclusive children, not both.

Keep execution owner, initiating person and accounting subject separate. Initial teammate cards can attribute owned agents' measured usage to their owner and expose contributor attribution separately where known. A guest submitting a prompt should not silently move the whole session's lifetime usage to that guest. Provider spend ownership and token authorship are not synonyms.

For Today, choose a stable named period/timezone in the area policy and publish its boundaries with the summary. Attribute finalized measurements to their observed accounting interval; requests spanning midnight are assigned by an explicit completion/report-time convention unless finer timestamps exist. A lifetime counter with unknown timing cannot be exactly split across days. A daily result can be partial without being zero.

Scope is independent of period. Recommend current shared area's authorized agents as an initial summary, with an explicit preference to expose a broader personal aggregate if desired. Do not reveal unrelated private session/project titles to explain a global number. Keep the requested hover number available regardless of which scope is chosen.

## Bounded presence and hover publication

Person presence, cursor/view location, runner activity and usage freshness are separate fields. Keep presence ephemeral; account totals survive reconnect and derive from the durable ledger. A person can be away while their agents run.

Publish a small area-authorized usage summary projection, with revision, covered sessions/count, provider coverage, interval, measured totals, last observation and connection state. Do not send raw transcripts, paths, credentials or host-bound records for a token card. Revoked members lose summary subscriptions as well as cursor updates.

The latest summary can be cached with a low-frequency revision notification; expanding a hover card subscribes only to that participant's visible details. Coalesce network/UI updates and cancel listeners when the card or area closes. The implementation should avoid per-cursor frame measurements, repeated filesystem scans and an observer per hidden agent tile. Exact cadence, throttles and payload limits must be measured and selected in implementation, not claimed here.

Cursor label, avatar and participants list should reveal the same stable card. Support keyboard focus/activation and screen readers; no usage badge remains after hover/focus ends. Moving into the card should allow inspection without chasing a moving cursor. Use existing Array styled popovers/tokens and verify actual light/dark rendering, Reduce Motion and Increased Contrast. Hover should never invoke a model or CLI query merely to manufacture a fresher number.

## Ticket candidates

### USAGE-01 — Define runner accounting observations and durable exactly-once ledger

Dependencies: shared person/session identity contracts and durable local store ownership; can start as offline Core work before networking. Extend provider adapters with source identity and counter semantics rather than repurposing context occupancy.

Acceptance: imported fixtures normalize Claude run aggregates, Codex cumulative checkpoints and Pi message totals without double-counting; preserved raw numeric categories have declared inclusion semantics. Restart/replay/reconnect/revision correction do not increase totals twice; reset/fork/unknown baseline becomes explicit partial coverage. Child-inclusive versus independent worker counts have a tested policy. No credential/tool content enters numeric payloads. Today has a stable timezone and no unproved historical attribution.

Witness: deterministic CoreChecks fixture sequence with duplicate reports, two legitimate equal-sized requests, crash/restart, counter reset, fork baseline, midnight boundary and native-subagent overlap. Add named gate invocation to the matrix and verify it is reported; do not invent an existing flag.

### USAGE-02 — Publish authorized teammate summaries and ephemeral presence

Dependencies: USAGE-01, area membership/revocation service, shared agent-reference projection. Derive one canonical counted session set per summary and retain owner/contributor distinctions.

Acceptance: two clients receive increasing summary revisions from one host ledger; duplicated agent views and reconnect do not inflate counts. One area's subscription cannot obtain another area's session metadata; owner-chosen wider aggregates expose only declared aggregate fields. Revocation removes access to cached-detail refresh and new updates; disconnect/freshness/partial runner coverage remain legible. Coalescing and subscription budgets have deterministic counters.

Witness: isolated two-member/third-outsider transport harness with replay, membership removal, host offline, mixed telemetry support, daily interval rollover and many hidden agents. Assert delivered payloads and final counts, not source strings.

### USAGE-03 — Render live usage in cursor/avatar hover card

Dependencies: USAGE-02, native collaborator cursor/avatar surfaces and shared component styling.

Acceptance: hover/focus shows freshest measured usage and interval/scope/coverage; asynchronous updates reach the open card without moving it or stealing focus. Leaving hover/focus removes the usage overlay and releases detail subscriptions. Avatar/keyboard path works with an offscreen cursor. Unsupported telemetry, stale host, zero measured usage and missing data are different rendered states. No constant usage overlay, provider call, model call or private title leakage. Follow/camera actions remain separate from hover.

Witness: production-mounted AppKit check driving hover, focus, live numeric revisions, moving cursor, cancellation and revocation; real light/dark appearance sweep, accessibility state inspection and work counters proving no listeners or unbounded updates after dismissal. Register witnesses in the matrix; no native preview or runtime check was performed during this memo.

## Open decisions before promising a number

1. Name the default total: provider-reported tokens, a normalized processed-token definition, or both in detail.
2. Establish parent/child accounting inclusion using real supported runner fixtures; do not assume native child totals are independent.
3. Decide area versus personal aggregate scope, Today timezone and midnight attribution convention.
4. Determine which provider events can identify a request durably; where they cannot, mark accuracy/coverage limits before presenting exact totals.
5. Decide whether unsupported external sessions appear only in running counts or also as incomplete usage coverage.

No exact usage-stream cadence, billing claim or per-token live guarantee is established by this source investigation.
