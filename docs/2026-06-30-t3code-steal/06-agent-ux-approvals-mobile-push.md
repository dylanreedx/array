# Stealing from t3code — Agent UX: status/approvals · mobile observer · APNS push

**Mining spike, 2026-06-30.** Area: **agent status UX + approvals + mobile observer +
push**. For a future implementing agent building Continuum's Decision C (agent
awareness), Decision E (iOS observer), and the "your agent needs you" push feature
(`docs/38-agent-orchestration-architecture.md`).

Source: read-only clone of **pingdotgg/t3code** at
`…/scratchpad/t3code`. All `t3:` paths are `file:line` in that clone. All `continuum:`
paths are in this repo. Confidence tags: **[VERIFIED]** = read directly in source;
**[INFERRED]** = my synthesis across files, flagged.

**The one-line thesis (verified):** t3code's `hasPendingApprovals` flag is checked
**first, above "running"**, when computing the agent's awareness phase
(`t3:packages/shared/src/agentAwareness.ts:88`), producing `waiting_for_approval` →
headline **"Approval needed"**. That single phase is pushed to the phone via APNS and
is the authoritative *"the agent needs you"* signal. **This is exactly the
`needsAttention` signal the Continuum AGENT-READERS spike found was NOT file-derivable
for Claude** — because t3code owns the provider process, the approval arrives as a
*structured event*, not a file to scrape. **Approvals close the gap — for managed
agents only.**

---

## 0. Architecture in one paragraph (how the pieces connect)

t3code is an **event-sourced orchestrator**. A managed agent ("provider") runs a
**thread**. The provider emits runtime events; when it needs permission it emits
`request.opened` (canonical `command_execution_approval` / `file_change_approval` /
…). The server projects that into a **pending-approvals table**; the thread's
projected shell then carries `hasPendingApprovals: true`. A pure function
`projectThreadAwareness()` maps the shell → an `AgentAwarenessState` with a `phase`.
A background worker (`AgentAwarenessRelay`) watches the domain-event stream, recomputes
that same awareness state on every relevant event, and **publishes it to a cloud relay**,
which fans it out to registered iPhones as **APNS push + Live Activity**. The phone is a
**thin observer** over the *same shared client-runtime* the desktop uses; to approve, it
dispatches `thread.approval.respond` back down the identical command path. Resolving the
approval emits `approval.resolved`, the projection clears, `hasPendingApprovals` flips
false, awareness recomputes to `running`, and a fresh state is pushed. The loop is
closed and symmetric.

```
provider needs permission
  → request.opened (command/file_change/…)                     [runtime event]
  → projection: pending-approval row {status:"pending"}         [ProjectionPipeline]
  → thread shell: hasPendingApprovals = true                    [ProjectionSnapshotQuery]
  → projectThreadAwareness() → phase "waiting_for_approval"     [agentAwareness.ts]   ← SAME fn, UI + push
  → AgentAwarenessRelay: publish RelayAgentActivityState        [server → relay]
  → relay → APNS "Approval needed" + deep link                  [push_notification / live_activity_update]
  → phone: tap → /threads/:env/:thread → PendingApprovalCard    [mobile, thin observer]
  → thread.approval.respond {decision}                          [SAME dispatchCommand path, desktop==mobile]
  → approval.resolved → pending row {status:"resolved"} → hasPendingApprovals=false → phase "running" → re-publish
```

---

## 1. What t3code does (file:line)

### 1a. Status phases — `projectThreadAwareness` [VERIFIED]
- **Phase enum** `AgentAwarenessPhase` (`t3:packages/shared/src/agentAwareness.ts:8`):
  `starting | running | waiting_for_approval | waiting_for_input | completed | failed | stale`.
- **Phase computation** `resolveThreadAwarenessPhase` (`…agentAwareness.ts:85`) — a
  strict **priority ladder**; approvals win over everything running:
  1. `hasPendingApprovals` → `waiting_for_approval` (`:88`)
  2. `hasPendingUserInput` → `waiting_for_input` (`:91`)
  3. session/turn `error` → `failed` (`:94`)
  4. session `starting` → `starting` (`:97`)
  5. session/turn `running` → `running` (`:100`)
  6. turn `completed` → `completed` (`:103`)
  7. else → `null` (no active awareness; idle threads render nothing) (`:106`)
- **Presentation**: `headlineForPhase` (`:109`) — `waiting_for_approval` → **"Approval
  needed"**, `running` → "Agent is working", `completed` → "Agent finished", `failed` →
  "Agent failed". `detailForPhase` (`:128`) supplies a subtitle (provider name / error).
- **Deep link** `buildAgentAwarenessDeepLink` (`:46`) →
  `/threads/<env>/<thread>` — the push tap-target.
- **Two helper predicates that name the two axes** (`:53`, `:57`):
  - `isTerminalAgentAwarenessPhase` = `completed | failed` (a run ended).
  - **`isInterruptiveAgentAwarenessPhase` = `waiting_for_approval | waiting_for_input |
    failed`** — this is literally t3code's definition of *"needs the human."*
- Test `t3:packages/shared/src/agentAwareness.test.ts:57` asserts **"prioritizes
  approval requests over running state"** — the priority is deliberate and tested.

### 1b. Runtime modes — full-access vs supervised [VERIFIED]
- `docs/architecture/runtime-modes.md` (whole file, 7 lines): a global toolbar switch.
  - **Full access** (default): `approvalPolicy: never` + `sandboxMode: danger-full-access`.
  - **Supervised**: `approvalPolicy: on-request` + `sandboxMode: workspace-write`, "then
    prompts in-app for command/file approvals."
- Wire contract `RuntimeMode` (`t3:packages/contracts/src/orchestration.ts:117`):
  `approval-required | auto-accept-edits | full-access`; default `full-access` (`:123`).
  (Doc says two; contract ships three — `auto-accept-edits` is the middle tier.)
- Policy/sandbox enums (`orchestration.ts:35`, `:42`): `ProviderApprovalPolicy` =
  `untrusted | on-failure | on-request | never`; `ProviderSandboxMode` = `read-only |
  workspace-write | danger-full-access`.
- Both flow into `ProviderSessionStartInput` (`t3:packages/contracts/src/provider.ts:61-63`:
  `approvalPolicy`, `sandboxMode`, `runtimeMode`). **The mode literally sets whether the
  agent will ever raise an approval.** Full-access ⇒ `never` ⇒ no approvals ⇒ awareness
  never enters `waiting_for_approval` (exactly Continuum's bypassPermissions gap — see §4).
- `runtimeMode` is per-thread and settable live: `thread.runtime-mode-set` command
  (`orchestration.ts:537`) → `ThreadRuntimeModeSetPayload` (`:879`).

### 1c. The approval flow — request → project → respond [VERIFIED]

**(i) The agent raises a request** — provider runtime event `request.opened`
(`t3:packages/contracts/src/providerRuntime.ts:173`, `:794`):
```ts
// providerRuntime.ts:135  the request taxonomy
CanonicalRequestType = "command_execution_approval" | "file_read_approval"
  | "file_change_approval" | "apply_patch_approval" | "exec_command_approval"
  | "tool_user_input" | "dynamic_tool_call" | "auth_tokens_refresh" | "unknown";
// providerRuntime.ts:421  the request payload (metadata only — a short detail + args)
RequestOpenedPayload = Struct({ requestType: CanonicalRequestType,
                                detail?: string, args?: unknown });
```
Each open request carries an `ApprovalRequestId`. `request.resolved` (`:174`, `:804`)
mirrors it with a `decision`. There is a parallel `user-input.requested` /
`user-input.resolved` pair (`:175`,`:176`, payload `UserInputQuestion[]` at `:441`) — the
"agent is asking a question" (not a permission) case → `waiting_for_input`.

**(ii) The server projects it into a pending-approval row.** The projector
`applyPendingApprovalsProjection`
(`t3:apps/server/src/orchestration/Layers/ProjectionPipeline.ts:1338`) consumes
`thread.activity-appended` events and keys off `activity.kind`:
```ts
// ProjectionPipeline.ts:1417  ONLY an approval.requested opens a pending row
if (event.payload.activity.kind !== "approval.requested") return;
// …:1423  upsert {status:"pending", decision:null, resolvedAt:null}
projectionPendingApprovalRepository.upsert({ requestId, threadId,
  turnId: event.payload.activity.turnId, status: "pending",
  decision: null, createdAt, resolvedAt: null });
// …:1353  approval.resolved  → upsert {status:"resolved", decision, resolvedAt}
// …:1384  provider.approval.respond.failed (stale/unknown) → also resolve, decision:null
```
The row schema `ProjectionPendingApproval`
(`t3:apps/server/src/persistence/Services/ProjectionPendingApprovals.ts:24`):
`{ requestId, threadId, turnId, status: "pending"|"resolved", decision, createdAt,
resolvedAt }`. Repo API is a plain upsert/list/get/delete keyed by `requestId` (`:53`).

**(iii) The shell flag is a count over that table.** `ProjectionSnapshotQuery`
lists pending rows and derives the boolean (`ProjectionPipeline.ts:561`, `:574`):
```ts
const [messages, proposedPlans, activities, pendingApprovals] = yield* Effect.all([ …,
  projectionPendingApprovalRepository.listByThreadId({ threadId }) ]);
const pendingApprovalCount = pendingApprovals.filter(a => a.status === "pending").length;
const pendingUserInputCount = derivePendingUserInputCountFromActivities(activities); // :133
```
`OrchestrationThreadShell` (`t3:packages/contracts/src/orchestration.ts:390`) carries
`hasPendingApprovals: boolean` (`:407`) + `hasPendingUserInput: boolean` (`:408`). That
shell is the input to `projectThreadAwareness` (§1a).

**(iv) The client responds** — command `thread.approval.respond`
(`t3:packages/contracts/src/orchestration.ts:627`):
```ts
ThreadApprovalRespondCommand = Struct({ type: "thread.approval.respond",
  commandId, threadId, requestId: ApprovalRequestId,
  decision: ProviderApprovalDecision, createdAt });
// orchestration.ts:131  the four decisions
ProviderApprovalDecision = "accept" | "acceptForSession" | "decline" | "cancel";
```
Dispatched through the **shared** client-runtime (desktop + mobile use the identical
call): `respondToThreadApproval`
(`t3:packages/client-runtime/src/operations/commands.ts:213`) → `dispatch(...)` →
`dispatchCommand` RPC (`:79`; RPC surface `orchestration.ts:1221`). The user-input
analog is `thread.user-input.respond` (`orchestration.ts:636`, client `:224`) with
`answers: Record<string,unknown>`. The command becomes domain event
`thread.approval-response-requested` (`orchestration.ts:797`, payload `:924`) which the
provider adapter turns into the real accept/deny to the agent process (adapters =
agent #3's area; e.g. `GrokAdapter.ts:685`, `CursorAdapter.ts:689` settle a
`pendingApprovals` Map by `requestId`).

### 1d. Mobile observer — thin client over the shared runtime [VERIFIED]
- **Connection is the shared runtime.** `apps/mobile/src/connection/runtime.ts:1` imports
  `Connection` from **`@t3tools/client-runtime/connection`** and just layers in
  platform capabilities. The RN app does **not** re-implement orchestration; it consumes
  the same projection stream (`orchestration.subscribeShell` / `subscribeThread`,
  `orchestration.ts:31`) the desktop does.
- **Platform layer supplies only device-specific edges**
  (`apps/mobile/src/connection/platform.ts:1`): network status via `expo-network` (`:44`),
  wakeups via RN `AppState` "active" (`:66`), auth via a Clerk/cloud session (`:88`),
  a stable `RelayDeviceIdentity.deviceId` (`:121`). **SSH is explicitly desktop-only**
  (`:143` "SSH environments are only available in the desktop app") — the phone
  **observes and interacts, it does not host agents.** This is the exact "iOS = observer,
  not runtime" boundary Continuum's Decision E wants.
- **Native modules** are thin renderers, not logic (`apps/mobile/modules/`):
  `t3-terminal`, `t3-markdown-text`, `t3-review-diff`, `t3-composer-editor`.
- **Mobile approval UI** exists as first-class screens:
  `apps/mobile/src/features/threads/PendingApprovalCard.tsx` and
  `PendingUserInputCard.tsx` — the approve/deny + answer surfaces, wired to the shared
  `respondToThreadApproval` command.

### 1e. APNS push — server → relay → phone [VERIFIED]

**(i) Server-side publisher** `AgentAwarenessRelay`
(`t3:apps/server/src/relay/AgentAwarenessRelay.ts:48`). `start()` (`:481`) forks a
subscription to the domain-event stream and, per event, decides whether to publish:
```ts
// AgentAwarenessRelay.ts:512  the push trigger — watch the SAME event stream
Stream.runForEach(orchestrationEngine.streamDomainEvents, (event) => {
  const threadId = eventThreadId(event);                 // :56
  if (!shouldPublishAgentAwarenessEvent(event)) return …; // :67 filter
  return worker.enqueue(threadId);                        // coalesced per-thread publish
});
// AgentAwarenessRelay.ts:67  what is worth pushing
shouldPublishAgentAwarenessEvent(event):
  thread.activity-appended → kind ∈ { approval.requested, approval.resolved,
      provider.approval.respond.failed, user-input.requested, user-input.resolved,
      runtime.error }                                    // :75-83  ← approvals are push-worthy
  thread.message-sent → only when !streaming
  runtime-mode-set / interaction-mode-set / proposed-plan → false
```
`publishThreadUnsafe` (`:309`) then: reads the thread+project shell → calls
`resolveAgentAwarenessRelayPublishSnapshot` (`:206`) which runs **the same
`projectThreadAwareness`** (`:233`) → **dedupes by state identity** (`:382`,
`agentAwarenessPublishIdentity` `:89` = JSON minus `updatedAt`, so pushes fire only on
*meaningful* change) → signs a short-lived (5-min, `:191`) JWT proof over the state
(`makePublishProof` `:182`) → POSTs to the relay (`:353`).

**(ii) The published payload** `RelayAgentActivityState`
(`t3:packages/contracts/src/relay.ts:86`) is **byte-for-byte the awareness state**:
`{ environmentId, threadId, projectTitle, threadTitle, phase, headline, detail?,
modelTitle, updatedAt, deepLink }` — same `RelayAgentAwarenessPhase` (`:20`, identical 7
values). **Privacy at the boundary**: `sanitizeRelayAgentActivityState` (`:114`) caps
`detail` at 160 chars and **replaces any failure detail with a fixed
`"The agent run failed."`** (`:112`) — no error bodies leave the environment. (Mirrors
Continuum's I5.)

**(iii) The relay endpoint + fan-out.** `publishAgentActivity` POST
`/v1/environments/:env/threads/:thread/agent-activity`
(`t3:packages/contracts/src/relay.ts:979`), env-authenticated (`:994`). It returns
`RelayPublishResponse` (`:813`) = per-device `RelayDeliveryResult` (`:797`) carrying
`kind: RelayDeliveryKind` (`:789` = `live_activity_start | live_activity_update |
live_activity_end | push_notification`) plus **`apnsStatus`/`apnsReason`/`apnsId`**
(`:802-804`) — i.e. the relay talks APNS and reports the APNS result per device.

**(iv) Device registration + notify preferences.** Phone registers via
`registerDevice` POST `/v1/mobile/devices` (`relay.ts:845`) with
`RelayDeviceRegistrationRequest` (`:38`): `deviceId`, `platform:"ios"`,
`iosMajorVersion (≥18)`, `pushToken?`, `pushToStartToken?` (Live Activity start token),
and **`preferences: RelayAgentAwarenessPreferences`** (`:28`):
```ts
{ liveActivitiesEnabled, notificationsEnabled,
  notifyOnApproval, notifyOnInput, notifyOnCompletion, notifyOnFailure }  // relay.ts:28
```
Built mobile-side by `makeRelayDeviceRegistrationRequest`
(`t3:apps/mobile/src/features/agent-awareness/registrationPayload.ts:5`) — all four
`notifyOn*` default `true`. **These four categories map 1:1 to the interruptive/terminal
phases**: `notifyOnApproval`↔`waiting_for_approval`, `notifyOnInput`↔`waiting_for_input`,
`notifyOnFailure`↔`failed`, `notifyOnCompletion`↔`completed`. There's a separate Live
Activity push token via `registerLiveActivity` (`relay.ts:856`).

**(v) Phone receipt + navigation** (`expo-notifications`).
`useAgentNotificationNavigation`
(`t3:apps/mobile/src/features/agent-awareness/notificationNavigation.ts:8`) listens for
tapped notifications and routes once (dedup by identifier) to the deep link.
`extractAgentNotificationDeepLink` (`…/notificationPayload.ts:72`) pulls
`data.deepLink` (or reconstructs `/threads/<env>/<thread>` from `environmentId`+
`threadId`) and **validates its shape** (`normalizeThreadDeepLink` `:47`: exactly
`/threads/<a>/<b>`, no query/fragment) before navigating — a nice defense against
malformed push payloads. Registration/token lifecycle lives in
`…/agent-awareness/remoteRegistration.ts` (device id + push token → `registerDevice`).

---

## 2. Code snippets — the four load-bearing shapes + a Continuum sketch

### 2a. The status-phase computation (the pattern to copy) [VERIFIED]
```ts
// t3:packages/shared/src/agentAwareness.ts:85 — approvals first, then input, then run-state
function resolveThreadAwarenessPhase(thread): AgentAwarenessPhase | null {
  if (thread.hasPendingApprovals)  return "waiting_for_approval"; // ← the needsAttention signal
  if (thread.hasPendingUserInput)  return "waiting_for_input";
  if (thread.session?.status === "error" || thread.latestTurn?.state === "error") return "failed";
  if (thread.session?.status === "starting") return "starting";
  if (thread.session?.status === "running" || thread.latestTurn?.state === "running") return "running";
  if (thread.latestTurn?.state === "completed") return "completed";
  return null; // idle → no awareness card
}
```

### 2b. The approval request/respond types + control flow [VERIFIED]
```ts
// REQUEST (agent → server), providerRuntime.ts:421 — metadata only
RequestOpenedPayload = { requestType: CanonicalRequestType /* command/file_change/… */,
                         detail?, args? };   // carries an ApprovalRequestId
// PROJECT (ProjectionPipeline.ts:1417) — only approval.requested opens a pending row;
//   approval.resolved / respond.failed close it → hasPendingApprovals recomputed
// RESPOND (client → server), orchestration.ts:627
ThreadApprovalRespondCommand = { type:"thread.approval.respond",
  threadId, requestId, decision:"accept"|"acceptForSession"|"decline"|"cancel", … };
// dispatched by the SHARED runtime — commands.ts:213 (desktop == mobile)
```

### 2c. The APNS publish path (the push trigger + payload) [VERIFIED]
```ts
// t3:apps/server/src/relay/AgentAwarenessRelay.ts:512 — one worker, watches domain events
Stream.runForEach(orchestrationEngine.streamDomainEvents, (event) => {
  if (!shouldPublishAgentAwarenessEvent(event)) return skip; // :67 — approval.* is in-set
  return worker.enqueue(eventThreadId(event));               // coalesce per thread
});
// publish: recompute projectThreadAwareness → dedupe by identity (:382) → sign 5-min JWT
//   (:182) → POST /v1/environments/:env/threads/:thread/agent-activity  (relay.ts:979)
// payload RelayAgentActivityState = the awareness state verbatim (relay.ts:86)
//   { phase:"waiting_for_approval", headline:"Approval needed", deepLink:"/threads/…", … }
// relay → APNS; result carries apnsStatus/apnsReason/apnsId (relay.ts:802)
```

### 2d. Mobile connect + render skeleton [VERIFIED]
```ts
// connect: reuse the shared runtime, add only platform edges
// t3:apps/mobile/src/connection/runtime.ts:17
Connection.layer.pipe(Layer.provideMerge(mergeAll(runtimeContextLayer, platformLayer)));
// platform.ts:143 — phone can't host: SSH gateway fails "desktop only"
// receive push → navigate, notificationNavigation.ts:8
Notifications.addNotificationResponseReceivedListener((r) =>
  routeAgentNotificationResponseOnce({ response:r, navigate:(dl)=>router.push(dl) }));
// approve from the phone → SAME command as desktop
respondToThreadApproval({ threadId, requestId, decision:"accept" });
```

### 2e. Continuum sketch (Swift) — managed agent → needsAttention → APNS [INFERRED]

Grounds in existing Continuum seams (`AgentStatus` at
`continuum:Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift:85`;
`AgentDescriptor` `:94`). **Scope: MANAGED agents** (Continuum-spawned via a provider
adapter that has a structured approval channel) — see §4 for why shell tiles are excluded.

```swift
// 1. A managed agent raises an approval. Continuum gets a STRUCTURED event from its
//    adapter (not a scraped file), mirroring RequestOpenedPayload.
enum ApprovalRequestKind: String, Codable, Sendable {
    case commandExecution, fileRead, fileChange, applyPatch, userInput   // t3 CanonicalRequestType
}
struct AgentApprovalRequest: Codable, Equatable, Sendable {   // NEW Continuum type
    let requestId: UUID
    let tileId: UUID                      // or threadId once managed agents have threads
    let kind: ApprovalRequestKind
    var detail: String?                   // ≤160 chars, sanitized (I5)
    var status: ApprovalStatus            // .pending | .resolved
    var decision: ApprovalDecision?       // .accept | .acceptForSession | .decline | .cancel
    let createdAt: Date
}

// 2. The pending set is the SINGLE source of needsAttention for managed agents.
//    (t3's projectThreadAwareness: hasPendingApprovals checked FIRST.)
func agentStatus(for tile: TileState, pending: [AgentApprovalRequest]) -> AgentStatus {
    if pending.contains(where: { $0.tileId == tile.id && $0.status == .pending }) {
        return .needsAttention          // ← closes the AGENT-READERS gap, authoritatively
    }
    // else fall back to the file/hook-derived reader status (working/idle/done/stale)
    return tile.readerDerivedStatus
}

// 3. needsAttention (or done/failed) → an iOS APNS push, deduped by identity.
struct AgentAwarenessState: Codable, Equatable {   // == t3 RelayAgentActivityState
    let tileId: UUID; let projectTitle, tileTitle: String
    let phase: AgentPhase              // mirror t3's 7 phases OR reuse AgentStatus
    let headline: String               // "Approval needed"
    var detail: String?; let deepLink: String   // "continuum://tiles/<id>" or web /threads/…
    let updatedAt: Date
}
protocol AgentPushService {            // NEW seam; impl talks APNS (or via a relay)
    func publish(_ state: AgentAwarenessState?) async   // nil = tombstone/clear
}
// A watcher over the observer's status changes: on transition INTO needsAttention/done/
// failed, build the state, dedupe by (everything except updatedAt), publish once.

// 4. iOS observer = thin client over Continuum's synced projection (Decision E).
//    Phone subscribes to the SidebarTree/activity projection (NOT the 2D canvas, NOT
//    runtimeRefs — I5). Renders the fleet; taps a needsAttention row → approval UI →
//    sends the SAME respond command the Mac uses. Phone never hosts a session.
func respondToApproval(_ id: UUID, _ decision: ApprovalDecision) { /* → adapter, both platforms */ }
```

**Where each piece lands in Continuum:**
| t3code | Continuum seam |
|---|---|
| `hasPendingApprovals` → `waiting_for_approval` | pending-approval set → `AgentStatus.needsAttention` |
| `projectThreadAwareness()` (shared, UI+push) | one function feeding both `SidebarTree` render **and** push |
| pending-approvals projection table | a `[UUID: AgentApprovalRequest]` keyed by requestId in `ZoneRuntimeController`/observer |
| `AgentAwarenessRelay` (event stream → publish) | an `AgentPushService` fed by the `SessionObserver`'s status transitions |
| `RelayAgentActivityState` | `AgentAwarenessState` (metadata only, I5-clean) |
| mobile `Connection.layer` reuse | iOS reuses Continuum's sync/projection client; no canvas, no runtime host |
| `thread.approval.respond` (shared cmd) | one `respondToApproval` path, desktop == iOS |

---

## 3. What Continuum steals — mapped to Decision C / E / push

1. **Approvals are the authoritative `needsAttention` — for managed agents. (Decision C;
   resolves the AGENT-READERS gap.)** [VERIFIED that t3 does this] The reader spike
   concluded Claude `needsAttention` is *not file-derivable in bypassPermissions mode* and
   must stay hook-only. t3code shows the real fix isn't a better file reader — it's
   **owning the approval channel**: a supervised managed agent emits a structured
   `request.opened`, the orchestrator projects a pending flag, and the awareness phase
   goes `waiting_for_approval` **deterministically, first, above "running."** For any agent
   Continuum *manages* through an adapter (not user-typed in a shell), copy this:
   `pending approval exists ⇒ AgentStatus.needsAttention`, no scraping, no guessing.
   **New seam: an `AgentApprovalRequest` type + a pending-approvals store keyed by
   requestId**, checked before any reader-derived status when computing `AgentStatus`.

2. **Runtime mode is the on/off switch for the whole signal. (Decision C.)** [VERIFIED]
   t3's Full-access = `approvalPolicy: never` = the agent never asks = awareness never hits
   `waiting_for_approval` — this **is** the bypassPermissions blind spot, named and
   made a *user choice*. Steal the model: a per-managed-agent **runtime mode**
   (`full-access` | `supervised`) that sets the adapter's approval policy. Supervised mode
   is what *creates* the needsAttention signal; the user opts into observability by
   choosing it. Continuum should expose this per agent (configurable-first doctrine).

3. **One awareness function feeds both the fleet view and the push; watch the event
   stream, dedupe, push only on meaningful change. (Decision E + push.)** [VERIFIED]
   `projectThreadAwareness` is computed identically for the in-app card and the APNS
   payload (`AgentAwarenessRelay.ts:233`), and pushes fire only when the state's identity
   (minus timestamp) changes (`:382`). For Continuum: compute `AgentStatus` (+ a small
   awareness struct) **once** in the `SessionObserver`; render `SidebarTree` from it
   **and** feed an `AgentPushService` from the same transitions. Push on entry into
   `needsAttention`/`done` only. **New seams: an `AgentPushService` (APNS, directly or via
   a relay) + an `AgentAwarenessState` DTO** (metadata only — mirrors I5; t3 caps detail at
   160 chars and redacts failure text, `relay.ts:112`).

4. **iOS observer = thin client over the shared projection, symmetric commands, never a
   host. (Decision E.)** [VERIFIED] The RN app reuses `@t3tools/client-runtime` and only
   supplies device edges; SSH/hosting is desktop-only (`platform.ts:143`); approving uses
   the *same* command as desktop (`commands.ts:213`). Continuum's iOS app should subscribe
   to the **synced spatial+activity projection** (Decision E's "sync layer 1 + activity
   tree"), render the tree (not the 2D canvas, not `runtimeRef` bindings), and send the
   identical `respondToApproval` command the Mac sends. **This is the concrete shape of
   "iOS = spatial sync + activity tree + on-demand pane view."**

5. **Notify categories = the phases. (push UX.)** [VERIFIED] Four toggles
   (`notifyOnApproval/Input/Completion/Failure`, `relay.ts:28`) map exactly to
   interruptive+terminal phases. Continuum's push settings should be the same four, and
   the deep link should be validated on receipt before navigation
   (`notificationPayload.ts:47`).

---

## 4. What does NOT transfer (be explicit)

- **Continuum's shell/terminal tiles — user-typed agents — have NO structured approval
  channel.** [VERIFIED by contrast] t3code's approvals exist *because the orchestrator
  owns the provider process* and injects an approval policy (`ProviderSessionStartInput`,
  `provider.ts:61`). A tile where the user typed `claude`/`codex`/`pi` themselves has no
  such injection point — Continuum only *observes* it via files/hooks (the AGENT-READERS
  design). For those tiles, **`needsAttention` stays hook/file-based** (Claude
  `Notification`/`PermissionRequest` hook; Pi `status.json` reason; Codex has none), with
  the spike's honest "under-claim rather than fabricate" floor. **Approvals-as-authoritative-
  needsAttention applies to MANAGED agents only.** Continuum thus has *two* needsAttention
  regimes and must not conflate them:
  - **Managed agent** (adapter, structured approval): `needsAttention` = pending approval, authoritative.
  - **Observed shell tile** (user-typed): `needsAttention` = hook/file heuristic, best-effort.
- **The whole event-sourced orchestrator + Effect stack.** [VERIFIED scope] t3's pending
  projection, domain-event log, and Effect `Layer`/`Service` machinery are agent #4's
  (event-store) territory. Continuum needn't adopt event sourcing to steal the *pattern*
  — a plain `[requestId: AgentApprovalRequest]` map + "pending ⇒ needsAttention" is enough.
- **The cloud relay as a mandatory hop.** [INFERRED] t3 pushes via a signed-JWT relay
  because environments are remote/NAT'd and there are multiple observers. Continuum could
  publish to APNS **directly** from the Mac (it's a native app with its own APNS creds) and
  add a relay only if/when agents run on a VPS (Decision D) or multiple phones observe. The
  *awareness-state shape and the "push on meaningful transition" logic* transfer; the relay
  topology is optional.
- **Live Activities specifically.** [VERIFIED exists] t3 ships Live Activity start/update/
  end tokens (`relay.ts:789`, `registerLiveActivity` `:856`). Nice-to-have, iOS-18+, and
  strictly additive over plain push — defer.
- **`auto-accept-edits` middle tier.** [VERIFIED] t3's third runtime mode auto-approves
  file edits but still gates commands. Continuum can start with just full-access/supervised
  and add the middle tier later.

---

## 5. Open questions / forks

1. **Do Continuum managed agents even have "threads"?** t3's unit is a thread (a
   conversation with a turn history). Continuum's unit is a *tile*. The approval model
   assumes a request belongs to a thread/session. Fork: (a) give managed agents a thread
   abstraction, or (b) attach approvals directly to `tileId`. The sketch used `tileId`; if
   Continuum grows conversation history, revisit.
2. **Which adapters give a structured approval channel?** t3 has real approval plumbing in
   `GrokAdapter`/`CursorAdapter`/`CodexSessionRuntime` (agent #3's area). Continuum's
   readers today are file-based (Claude/Codex/Pi). **Does Continuum plan to *drive* agents
   via an adapter (able to inject `approvalPolicy` and receive `request.opened`), or only
   *observe* them?** Only the former unlocks §3.1. If Continuum stays observe-only, the
   authoritative-approval win is unavailable and Claude's `Notification` hook remains the
   best `needsAttention` — worth deciding explicitly.
3. **APNS direct vs relay.** (See §4.) Decide before building `AgentPushService`: direct
   from Mac (simplest, local-only) vs relay (needed for remote agents / multi-device). The
   *interface* is the same; the backing differs. Recommend: direct first, relay as the
   Decision D/E upgrade.
4. **Where does the awareness struct live vs. the synced projection?** t3 keeps
   `RelayAgentActivityState` separate from the orchestration projection and recomputes it
   at publish time. Continuum's `SidebarTree` already exists; is the push state a second
   derivation of it, or a field on it? (Recommend: derive both from the observer's
   `AgentStatus` output — one source, two renders, per §3.3.)
5. **User-input vs approval split.** t3 cleanly separates `waiting_for_approval`
   (permission) from `waiting_for_input` (the agent asks a question, `UserInputQuestion[]`).
   Both are "interruptive." Continuum's `AgentStatus` has only `needsAttention` — do we
   collapse both into it (simpler) or add a sibling case (richer phone UX: "approve this
   command" vs "answer this question")? t3's richer split is the better UX if managed
   agents ask questions.
6. **Deep-link scheme.** t3 uses web-style `/threads/<env>/<thread>`. Continuum needs a
   `continuum://` URL scheme (or universal link) that resolves to a tile/agent on the
   phone; define it alongside the iOS observer.

---

## Appendix — file:line index (t3code clone)

- `packages/shared/src/agentAwareness.ts` — phase enum `:8`; `resolveThreadAwarenessPhase` `:85` (approvals-first `:88`); `headlineForPhase` `:109`; `isInterruptiveAgentAwarenessPhase` `:57`; deep link `:46`; tests `agentAwareness.test.ts:57` (priority), `:79` (running).
- `docs/architecture/runtime-modes.md` — full-access vs supervised (approvalPolicy/sandboxMode).
- `packages/contracts/src/orchestration.ts` — `ProviderApprovalPolicy` `:35`; `ProviderSandboxMode` `:42`; `RuntimeMode` `:117`; `ProviderApprovalDecision` `:131`; `OrchestrationSession` `:271` (+status `:260`); `OrchestrationThreadShell.hasPendingApprovals` `:407`/`hasPendingUserInput` `:408`; `ThreadApprovalRespondCommand` `:627`; `ThreadUserInputRespondCommand` `:636`; event types `:783` (`thread.approval-response-requested` `:797`); `ThreadApprovalResponseRequestedPayload` `:924`; `ProjectionPendingApprovalStatus` `:1180`; RPC schemas `:1221`.
- `packages/contracts/src/providerRuntime.ts` — `CanonicalRequestType` `:135`; runtime event types `:148` (`request.opened` `:173`, `user-input.requested` `:175`); `RequestOpenedPayload` `:421`; `UserInputQuestion` `:441`; `ProviderRuntimeRequestOpenedEvent` `:794`.
- `packages/contracts/src/provider.ts` — `ProviderSessionStartInput` approvalPolicy/sandbox/runtimeMode `:61-63`; `ProviderRespondToRequestInput` `:98`; `ProviderRespondToUserInputInput` `:105`; `ProviderEvent` `:114`.
- `apps/server/src/orchestration/Layers/ProjectionPipeline.ts` — `derivePendingUserInputCountFromActivities` `:133`; shell derivation `:561`/`:574`; `applyPendingApprovalsProjection` `:1338` (approval.resolved `:1353`, respond.failed `:1384`, approval.requested-only guard `:1417`, pending upsert `:1423`).
- `apps/server/src/persistence/Services/ProjectionPendingApprovals.ts` — `ProjectionPendingApproval` `:24`; repo shape `:53`.
- `apps/server/src/relay/AgentAwarenessRelay.ts` — service `:48`; `shouldPublishAgentAwarenessEvent` `:67`; `sanitizeRelayAgentActivityState` `:114` (redaction `:112`); publish snapshot `:206`; `publishThreadUnsafe` `:309` (dedupe `:382`, POST `:353`); JWT proof `:182` (5-min `:191`); `start` `:481` (event stream `:512`).
- `packages/contracts/src/relay.ts` — `RelayAgentAwarenessPhase` `:20`; `RelayAgentAwarenessPreferences` `:28`; `RelayDeviceRegistrationRequest` `:38`; `RelayClientDeviceRecord` `:50`; `RelayLiveActivityRegistrationRequest` `:75`; `RelayAgentActivityState` `:86`; `RelayDeliveryKind` `:789`; `RelayDeliveryResult` (apns* `:802`) `:797`; `registerDevice` `:845`; `registerLiveActivity` `:856`; `publishAgentActivity` `:979`.
- `apps/mobile/src/connection/runtime.ts:17` — shared `Connection.layer`. `…/connection/platform.ts` — expo-network `:44`, wakeups `:66`, SSH desktop-only `:143`.
- `apps/mobile/src/features/agent-awareness/` — `registrationPayload.ts:5`; `notificationNavigation.ts:8`; `notificationPayload.ts:47`/`:72`; `remoteRegistration.ts`.
- `apps/mobile/src/features/threads/` — `PendingApprovalCard.tsx`, `PendingUserInputCard.tsx`.
- `packages/client-runtime/src/operations/commands.ts` — `respondToThreadApproval` `:213`; `respondToThreadUserInput` `:224`; dispatch `:79`.
