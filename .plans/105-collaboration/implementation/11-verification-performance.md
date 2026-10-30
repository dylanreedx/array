# Implementation study 11: verification, performance and release evidence

29 October 2026. Planning only. No build, tests, app launch, provider invocation, tmux connection, production relay request or Git mutation was performed. The witnesses and collaboration-specific scenario names below are proposals, not implemented command-line flags.

## Feasibility and existing seams

The repository has the right kinds of test boundaries to verify collaboration without a real teammate, production service or provider. They need new collaboration contracts; none presently establishes multi-human area sharing.

| Existing seam | What source establishes | Useful extension |
| --- | --- | --- |
| [Relay core checks](../../../Sources/ContinuumRevivedRelayCoreChecks/main.swift) | Temporary SQLite, separate provisioned Mac identities, one-use grants, cross-instance isolation, idempotent commands and restart persistence | Add actual multi-human membership/area identities and assert unauthorized principals receive neither commands nor payloads |
| [Relay HTTP integration checks](../../../Sources/ContinuumRevivedRelayIntegrationChecks/RelayHTTPOutboxChecks.swift) | Real NIO server on `127.0.0.1`, OS-assigned ports, temp database, production HTTP routing, event-driven traces, restart and an injected worker clock | Exercise area join/revoke/events/blobs through production endpoints, with controllable transport faults |
| [RelayHub checks](../../../Sources/ContinuumRevivedRelayChecks/main.swift) | In-process fan-out, sequence/cursor/snapshot recovery, scope enforcement and bounded stream collection | Reuse deterministic scheduling ideas, while testing the actual collaboration service rather than assuming this legacy hub is the hosted service |
| [Sync checks](../../../Sources/ContinuumRevivedSyncChecks/main.swift), [op-log tests](../../../Sources/ContinuumRevivedSyncChecks/OpLogTests.swift) | Deterministic ordering/tombstone fixtures and materialization checks | Add shared-area membership, artifact references and delete/revoke race outcomes to the chosen production reducer |
| [Production scene-owner witness](../../../Sources/ContinuumRevived/App/WorkspaceSceneOwnerChecks.swift) | App boot mounting through `AppDelegate.mountWorkspaceSceneAtBoot`; separate project roots, nonzero zone origins and actual view inspection | Mount shared-area views through the real new boot/capture/invite paths; compare rendered frames and owners independently of the projection model |
| [PerfScenarios](../../../Sources/ContinuumRevived/App/PerfScenarios.swift), [PerfBudget](../../../Sources/ContinuumRevivedCore/PerfBudget.swift) | Named count budgets, coarse time guards, non-vacuous teeth, axis-isolated fixtures | Add collaboration deltas, offscreen residency, cursor coalescing and hover-cost scenarios |
| [Appearance census](../../../Sources/ContinuumRevived/App/UIProbeAppearance.swift) | Sentinel and adopted-surface rendering, real appearance flips and owner-scoped colors | Render share controls, remote object states, cursors and hover cards in both themes, including disconnected/revoked/partial-usage states |

Important existing lesson: six scene checks were green while production never adopted its canvas because they called a checks-only install method. A collaboration mount witness must drive the production scene owner and user action seam. Constructing a projection and asserting its own fields is insufficient.

## A deterministic multi-client harness

Use three independent principals, A and B as invited coworkers and C as an uninvited outsider. Give A and B different app-support directories, explicit defaults suites, project roots and fixture CLI identities. The same filesystem path is not an acceptable two-machine fixture: project `.array/` ownership must remain independent.

Run the actual proposed collaboration service with a temporary SQLite/blob store and OS-assigned loopback ports. Start A/B production client coordinators against it. Use stable fixture person/device/area/command IDs and a virtual clock for lease expiry, presence timeout, retry and invitation expiry. Use awaited event barriers and observable traces to advance schedules; real-time timeouts serve only as failure guards.

Replace provider processes with existing-style offline protocol stand-ins. Feed realistic per-runner events through actual runner translators/dispatch. Record the exact local checkout and CLI identity used for each execution. An in-memory mock that independently reimplements the new server protocol is useful for unit tests but cannot be the only release witness.

Test these schedules with both normal and reversed delivery where the contract permits it:

1. A creates an area from selected tiles and layout; B joins; C cannot fetch area data, blob metadata, transcript fragments or presence.
2. A/B edit different shared objects, then race on the same geometry/document revision; the chosen conflict semantics remain explicit and converge.
3. A publishes a boundary revision; B edits it; delivery of the old revision to an agent stays identifiable and the new revision is visibly unsent.
4. A human discussion message produces zero provider requests. A deliberate send produces one targeted request with exact author, context revision and execution host.
5. Drop a command acknowledgment after durable acceptance; retry the same intent, reconnect and restart the server; the host executes it once. A changed body under an old idempotency key must be refused.
6. Disconnect B before a host update; after resume, B receives a snapshot plus exact tail with no skipped durable events. Cached state remains explicitly stale while offline.
7. Revoke B concurrently with a queued command, artifact request and stream update. Assert the defined linearization point, deny subsequent work, terminate future delivery and do not describe already executed work as undone.
8. Delete a shared reference while a late geometry update arrives; it cannot resurrect content or widen access.
9. Restart A and B from their own stores. Shared views rebind to the same remote identities without creating a second runner or importing the other person's project into the local registry.
10. A's agent changes fixture files. B's shared diff updates; B's independent checkout remains byte-identical until an explicit integration operation is tested separately.

Do not use the real provider login, current project root, production app-support store or hosted relay. If terminal verification is eventually necessary, isolate `TMUX_TMPDIR`, unset inherited `TMUX`/`TMUX_PANE`, verify the server socket is inside that namespace and clean only that server. No terminal process is needed for the basic collaboration harness.

## Required native behavior witnesses

Capture/zone/workspace sharing should verify the installed view's world frame, relative layout and membership against independent expected geometry at nonzero origins and non-integral zoom. A correct zone stamp with an incorrect visible frame is a failure. Opening/reconnecting a remote session view must result in zero new local runner starts.

Use actual pointer/keyboard routing for rectangular capture, explicit membership review, invitation acceptance, shared move/resize, hover-card reveal and cancellation. Check that capture retains the source tile's project/runtime identity, does not arm an unrelated zone and does not publish neighboring or newly overlapping tiles without the chosen explicit action. Preserve personal camera/first responder during remote updates.

Presence and usage checks must assert:

- The hover card is absent at rest and appears only on the intended cursor/avatar/focus target.
- Fresh reported token events update the open card; nonstreaming providers remain honestly last-reported rather than animated estimates.
- Duplicate/cumulative/replayed usage events do not inflate totals; two views of one session are one usage source.
- Offline, missing and partially covered metrics show their actual scope/freshness; zero is not substituted for unknown.
- Dismissal removes the card and its presentation work; equivalent keyboard access works when the cursor is absent/offscreen.
- A moving cursor cannot steal focus, eat the gesture or make the card impossible to inspect.
- Human availability and execution-host availability remain separate.

## Performance targets to establish

Use counts as assertions and elapsed time as a coarse alarm, following [performance budgets](../../../docs/internals/performance-budgets.md), [scalability TDD](../../../docs/internals/scalability-tdd.md) and [surface guidance](../../../docs/internals/performance.md). The following are proposed structural targets; they are not measurements of current collaboration code.

| Scenario | Deterministic target and teeth |
| --- | --- |
| Presence flood | For N updates inside one display interval, at most one presentation commit per affected visible collaborator, displaying the final accepted position. At least one update applied; unrelated tile layout/model writes and prose measurements equal zero. |
| Closed usage hover | Provider observations update the semantic ledger, but produce zero hover-card mounts, text measurements, layout applies, timers or model calls while no card is shown. Semantic version still advances. |
| Open usage hover | Apply only the changed fields for the one open card; unrelated cards and transcript history receive zero applies. Closing/revoking frees the subscription/presentation handle. |
| Shared agent streaming | One delta visits changed plus visible rows, independent of total transcript rows (`10, 100, 1,000, 10,000`). No full transcript flatten/scan per delta. |
| Offscreen shared area | Semantic state catches up; expensive presentation work approaches zero. Re-entry causes one bounded catch-up. Mounted heavyweight views are bounded by visible+halo+explicit pins, not all saved remote objects. |
| Personal pan with collaboration | Fixed visible count, installed object counts `16, 32, 64, 128`, zoom `1.0` and `0.35`: zero per-tile bounds/model/prose writes and zero collaborative document writes. Camera/view-tree oracle proves the gesture really happened. |
| Captured-area geometry | Capturing K selected objects computes/persists K references and layout once; it does not enumerate every transcript row or hydrate cold artifacts. Reopening geometry must reproduce visible placement. |
| Recovery | Snapshot+tail transfers bounded pages; usage aggregation does not replay the entire transcript to reveal a hover card. Persisted caches have explicit retention/size policy. |

Vary collaborator count (`2, 8, 32`) independently from event rate and visible objects to establish slopes. Those are proposed load fixtures, not a supported capacity promise. Record actual byte/queue memory high-water marks and coalescing behavior. Establish reviewed versioned regression ceilings from measurements without replacing product targets with whatever the first run happens to achieve.

Do not claim 120 Hz from a green headless check. Existing `PerfScenarios.frameBudgetMs` is 8.3 ms, but the entire display interval also pays input, drawing and compositor work. Confirm real pan/zoom/hover under streaming load on 60 Hz and 120 Hz hardware using existing frame statistics; report which hardware was actually used. Keep those opt-in rendering/stress trials separate from small deterministic offline gates.

## Three candidate tickets

### COL-QA-1 — Add an isolated three-principal collaboration harness

**Depends on:** shared-area protocol/store, human membership and host command contracts. Harness scaffolding can land before features, but every behavior belongs to its implementing ticket.

**Deliverable:** production relay/client harness with separate A/B stores/checkouts, outsider C, deterministic event barriers/faults/clock, fixture runners and reloadable SQLite/blob state.

**Acceptance:** all ten schedules above report expected identity, visibility, exactly-once execution and recovery outcomes. Report command counts and actual changed fixture paths. A negative authority mutation must fail; a positive admitted operation must pass, avoiding a permanently refusing mock that looks secure. No production endpoints or default tmux connection occur.

**Witness placement:** extend the actual relay core and HTTP integration check products and the shared-area client's Core/Sync checks; register each real invocation in the matrix and committed inventory. Names of any new collaboration-specific products/flags must be introduced in source before invocation.

### COL-QA-2 — Witness production-mounted share/capture/presence interactions

**Depends on:** native share entry points, area projections, session reference views and presence/usage presenters.

**Deliverable:** app witnesses driving real scene mount and pointer/keyboard action seams for workspace/zone/capture, remote views and hover card.

**Acceptance:** nonzero-origin/non-integral-zoom frames match installed view geometry; source ownership is unchanged; reconnect/remount starts zero duplicate runners; remote update preserves focus/camera; token hover absent at rest, live while revealed, dismissed cleanly and reachable by keyboard. Assert selected-object membership and no delivered neighboring data. Injected defects in frame conversion, implicit capture membership or rest-state hover visibility each make the corresponding witness red.

**Witness placement:** production scene-owner/mount pattern in the app target, all new flags handled before AppKit boot, matrix invocation and inventory entry. Do not rely only on `WorkspaceRuntime.install(into:)` fixtures.

### COL-QA-3 — Establish collaboration performance, appearance and release evidence

**Depends on:** small production vertical slice and instrumentation; can develop alongside native implementation.

**Deliverable:** reviewed fixture/metric manifest, count-budget scenarios in `PerfScenarios.all`, rendered adoption surfaces and a release evidence record tied to exact revisions.

**Acceptance:** structural targets above have non-vacuous teeth, visible scaling axes and published results; existing camera/streaming ceilings do not regress. Inspect light/dark, Increased Contrast, Reduce Motion, both scroller styles and keyboard/VoiceOver behavior. New `TokenThemed` owners render in appearance sweep plus adopted surfaces, use legal owner-scoped values and resting `nil` rather than transparent paint. All share menus use Array's existing choice components. Run the full matrix and required bundle gate; report real failures, documented known-reds, unexpected passes and skipped hardware legs separately.

**Witness placement:** `PerfScenarios`, UI appearance census and actual app witnesses. No new known-red is silently introduced or baseline automatically updated.

## Matrix and release discipline

Existing verified-in-source flags include `--workspace-scene-owner-check`, `--ui-probe-check` and `--perf-budget-check`; existing scenario names include `canvas.pan` and `canvas.fractional-pan`. No collaboration flag exists merely because this memo proposes a witness. Enumerate actual `--*-check` flags in `ContinuumApp.swift` before running one; an unknown flag boots the whole app.

`scripts/run-matrix.sh` already isolates each app check with temporary project/app-support directories and accounts for failures through `run_leg`/`run_app_check`. Extend those mechanisms. Inspect its final report rather than exit status alone; confirm every new leg printed. The script has source-line/inventory checks, so preserve pinned wrapper text and register literal invocations. Core changes also require the matrix's iOS build because Core is shared.

No version or release claim belongs to these planning tickets. When shipping is authorized, follow `RELEASE.md`, full matrix, bundle verification and isolated dev preview. Never update UI baselines automatically. If new invitations/mentions/agent-request notifications are added, update stable path IDs in `docs/internals/notification-paths.md` and provide notification delivery/suppression/revocation witnesses; local presence alone need not introduce a push.

## Remaining uncertainties

- The chosen human identity, durability, encryption/key rotation and area conflict contracts determine exact fault schedules; they must be explicit before harness acceptance is finalized.
- Per-runner usage semantics and supported remote actions need capability-specific fixtures. A successful generic fake must not imply production provider approval support.
- Current existing performance documents contain historical measurements and known debt; inspect current source/gate before choosing a baseline, rather than copying a historical measured value as a new pass claim.
- App-level multi-client fixtures may initially mount two independent coordinators in one process; a two-process smoke layer must still confirm no accidental global singleton/defaults sharing masks machine isolation defects.
- Native appearance, real hardware smoothness, live public networking and comparative usability remain unverified until deliberately exercised in isolated environments.
