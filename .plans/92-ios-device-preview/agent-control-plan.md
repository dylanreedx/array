# Agent control of iOS Preview

Status: **visual, bounded interaction and build-loop slices implemented and verified; release gates remain separate. Verification and release boundaries are recorded in the progress note.**
Baseline: `efcce530` (iOS Preview). Cross-check performed 2026-10-28 against the
canonical checkout and the in-progress browser bench. Dylan authorized starting
implementation after this plan. See [implementation progress](agent-control-progress.md)
for the implemented boundary and evidence; the remaining architecture is proposed.

Implemented contract: [workspace iOS Preview](../../docs/internals/workspace-ios-preview.md).
The architecture below preserves the reviewed forward plan. Service-owned build
jobs are implemented; semantic inspection remains a separate proposed decision.

## Intended outcome

An agent can open an explicitly targeted project simulator, observe its screen,
perform bounded interactions, and verify the app through subsequent observations.
Dylan watches the same simulator in its canvas tile and can take control. Canvas
pan/zoom, focus and workspace selection do not determine automation coordinates
or silently redirect a request. The first workload is the Array companion.

The initial release is local iOS Simulator only. Physical devices, other Mac
applications, Android, remote hosts, App Store submission, arbitrary shell/eval,
multitouch/IME, push injection and new notification behavior are separate work.
The existing human preview and Build & Run remain usable independently.

## What the pre-implementation double-check established (2026-10-28)

| Area | Observed before implementation | Consequence for this work |
| --- | --- | --- |
| Frames and HID | Preview supplies real decoded images and touch/key/paste/Home/rotation, with live witnesses | Reuse the native adapter; do not build a second viewer |
| Agent API | Root `WorkspaceAPIOp` and the shared JSON catalog have no device operations; simulator selection is `notExposed` | New published contracts and exposure classifications are required |
| Command completion | `IOSPreviewSession.send` returns void; bridge sends connection admission and errors, without correlated success acknowledgements | Sending an event is not a completed agent action |
| Coordinates | Framebuffer images and displayed orientation differ; the tile applies rotation and letterboxing | One shared, tested image-to-native transform is required |
| Lifecycle | The tile suspends on occlusion, parking or removal; its view owns callbacks | An agent session cannot depend solely on view lifetime |
| Exclusivity | One runtime/controller controls a device, including a helper-exit reconnect fence | Reuse that device exclusivity; agent ownership is an additional layer |
| Builds | Exact-device, verified fresh products and owned process-group cancellation work; the tile owns the task | Agent build jobs need a service-owned lifetime and operation result |
| Shared plumbing | Host dispatch, supervisor-bound identity, revocation generations, operation lookup and MCP image replies exist | Extend this provider-neutral path |
| Browser foundation | Action queue, retry tombstones, leases and running-turn protection exist in the dirty browser bench, based at `f62ba3f3`; API integration is in progress | Verify the landed implementation before reuse; do not depend on another dirty checkout |
| Semantic inspection | Preview does not provide an accessibility/element tree | First visual interaction and later semantic targeting are distinct capabilities |

Relevant production sources:
[session/runtime](../../Sources/ContinuumRevived/IOSPreview/IOSPreviewRuntime.swift),
[bridge](../../Sources/ContinuumRevived/Resources/IOSPreview/bridge.cjs),
[tile input/lifecycle](../../Sources/ContinuumRevived/Canvas/IOSPreviewTileNSView.swift),
[build pipeline](../../Sources/ContinuumRevived/IOSPreview/IOSPreviewBuild.swift),
[host service](../../Sources/ContinuumRevived/App/WorkspaceAPIService.swift),
[contracts](../../Sources/ContinuumRevivedCore/WorkspaceAPI/WorkspaceAPIContracts.swift),
[tool catalog](../../Sources/ContinuumRevivedCore/Resources/PiExtensions/array-workspace-tools.json).
The browser [handoff](../80-browser-computer-use/HANDOFF.md) is a moving dependency,
not proof that its proposed tool surface is already available in this checkout.

T3's inspected design separates preview streaming from semantic automation:
Expo handles streaming while agent-device supplies automation; its small device
MCP toolkit hands driving to a session-targeted CLI. This supports separating
viewing, ownership and automation; it does not establish that installing the
preview helper already gives Array semantic tools.
[Exact-SHA T3 design](https://github.com/pingdotgg/t3code/blob/5211acfe95a0c6d82a60e2524b5e46b47fe67a3e/docs/internals/devices.md),
[session-targeted shim](https://github.com/pingdotgg/t3code/blob/5211acfe95a0c6d82a60e2524b5e46b47fe67a3e/apps/server/src/device/AgentDeviceShim.ts).
An attempted Apple UI-test reference returned 404 and is excluded as evidence;
no new Apple/XCUITest capability is assumed by this plan.

## Architecture decisions proposed for v1

### One device session, with a viewer and an automation adapter

An App-owned device session holds capture/HID, the exact device binding,
connection generation and command queue. The existing tile subscribes to it;
an automation adapter can observe and act through that same session. Opening
an agent channel must not create a second input socket, helper or simulator.
The helper remains an isolated supervised process with its current local,
authenticated, typed protocol. No helper token, local endpoint or arbitrary
command route is exposed in model replies.

Address every operation by explicit checkout + tile/session handle. Resolve the
owning project controller, never the active controller or a `booted` alias. A
handle binds one exact host-local UDID, owner, connection/control generations
and project scope. Selecting another device invalidates old handles and queued
work. Missing/ambiguous/stale targets return errors; they never fall back.

Use the existing workspace API/grant/image infrastructure. After browser work
lands, reuse the proven ordering, retry and lease behavior through the smallest
appropriate common seam. Do not copy `BrowserActionQueue` into a second diverging
implementation or turn DOM, navigation and browser profiles into native APIs.
Do not introduce a general cross-platform automation framework to reach v1.

### Visual control first; semantic control requires a separate proof

The smallest usable vertical slice is screenshot → bounded tap/swipe/text →
new screenshot, using the already tested native adapter. This requires an agent
with image input; advertise no visual-control capability when its transport
cannot deliver the image. Browser DOM references do not apply to UIKit.

Before committing to a semantic backend, run an isolated feasibility proof of
a pinned agent-device version or another concrete native UI-test backend:
exact UDID, observed element tree, element action, app-owned result readback,
compatibility with Array's existing viewer and exclusivity, lifecycle, provider
transport, packaging/license and installation behavior. No installation or
backend selection is part of this documentation task. Do not expose a CLI shim
that bypasses host target binding, ownership, revocation or action accounting.
If semantic inspection is unavailable, return that fact; do not synthesize
labels or claim a screenshot is an accessibility tree.

### User control and existing permission policy

Use Array's current Agent permissions setting and project grants. Free permits
in-scope operations without additional confirmation. Ask first uses the existing
host approval seam; model fields cannot mint approval. Existing explicit user
authorization must be honored. No new blanket consent workflow is proposed.

An agent-created tile carries a host-issued owner. A human tile needs an
explicit host-recognized handover under that policy; another agent's ownership
cannot be overwritten by supplying its tile ID. Ownership, temporary control
lease and authorization are separate: an expired lease is not a grant to another
agent. Persist only appropriate configuration/owner identity; never grants,
helper tokens, control leases or live connections. Restart requires fresh
session validation and preserves the current no-auto-boot restore behavior.

The granted scope is the selected simulator, which can show system UI and other
apps. Do not advertise app-only isolation that the backend cannot enforce.
Default automated QA uses a host-created disposable simulator. Borrowing a
user-selected device requires the existing explicit targeting/handover route;
closing it detaches and leaves its app/device running. Never adopt a random
running simulator, reset it, erase it, or shut it down as cleanup.

Actual user input takes precedence. Increment a device control generation at
human input seams, cancel queued agent work, and release held inputs before
admitting new control. A native call already in flight may have an uncertain
effect. Do not replay it or claim instantaneous cancellation. The user sees who
is controlling the device and can stop/reclaim it. Agent input must not increment
the human takeover counter or steal the Mac pointer/first responder.

### Ordered commands and truthful outcomes

Add request IDs and correlated helper acknowledgements. An acknowledgement means
the bounded native input sequence completed, not that the app performed the
agent's intended task. An effect assertion needs a subsequent observation or
independent test-app readback. A frame arriving after an acknowledgement does
not by itself prove that the app's animation/transition finished.

Order mutations per device, including rotations and builds that replace the app.
A swipe is one bounded action, implemented with interruption checks between
segments; its internal moves may coalesce without dropping begin/end or
acknowledging omitted actions as individually executed. Release keys/touch on
completion, cancellation, revocation, takeover, disconnect and helper failure.
Agent text uses explicit supplied text, not the Mac clipboard or synthetic
Mac UI typing. Witness guest Unicode readback and absence of host clipboard
access; keep text out of persistent action summaries by default. Retain only
bounded screenshot artifacts under the existing artifact policy, not continuous
video or duplicate base64 transcripts.
An out-of-band control-generation change must invalidate queued agent actions
rather than sit behind a long gesture. A stuck native call needs a finite
failure/recovery route before new ownership is granted.

Reuse host retry identities. Same key + same target/payload returns the known
result; another payload conflicts. Cache access is re-authorized. Once dispatch
may have happened, lost acknowledgement/deadline returns `outcome_unknown` and
retains a retry tombstone. A request that expired before dispatch has no effect.
Neither condition automatically repeats a tap, paste, launch or build.
Cancellation after a committed effect reports that effect, not a fictitious undo.

Use existing error codes where they fit. Proposed device-specific codes such as
`device_not_live`, `stale_observation`, `user_took_control` and `device_busy`
require explicit contract/catalog changes before use. Errors name the recovery
route: observe again, release/handover, reconnect explicitly, or inspect a build.

### Image coordinates, observation freshness and budgets

Return an upright image with its own pixel dimensions and a host-issued frame
handle containing device/session, control and geometry generations, orientation,
sequence and helper-emission/host-receive timestamps. A true native capture
timestamp is included only if the backend supplies one; never label receive or
emission time as capture time. Use that image's coordinate space;
canvas zoom, tile chrome, letterboxing and display backing scale never enter an
agent payload. Convert once into the helper's raw normalized coordinates through
a shared pure transform also used by the human surface. Enforce finite in-bounds
points; the native layer does not silently repair invalid agent coordinates.

Validate the observation at execution, not only queue admission. Rotation,
device change, reconnect and human takeover invalidate it. New video frames with
unchanged geometry must not invalidate every action on an animated app. Proposed
frame-handle TTL is 30 seconds, returned to the caller; image acquisition should
wait for a fresh frame with a five-second acquisition deadline. Exact values need
fixture/live confirmation. Ordinary animation can still move a target: visual
control is not a guarantee of semantic element identity.

Use image content blocks through `WorkspaceMCPToolResult`; never send duplicate
base64 in JSON/text or return only an inaccessible local path. Recheck access
before asynchronous image delivery. Reuse the current 1400-pixel/4 MiB compressed
part/4-million decoded-pixel limits; choose a bounded encoded reply ceiling in
the contract tests. One pending capture per device; coalesce frames and keep
network assembly/decode off main. Snapshot freshness must not be inferred from
the tile's last painted or parked bitmap. Require an observation barrier that
returns a newly emitted helper frame after the request, instead of satisfying
it with bytes already queued in TCP. If true capture age is unavailable, report
that limit; a new emission alone does not prove a recent native capture.

### Session residency and resource ownership

A leased active agent session survives tile occlusion and workspace changes
without forcing presentation, switching workspaces or arming a zone. A human
Connect alone retains today's visibility behavior. Closing/disconnecting or
changing the target remains an explicit cancellation boundary. Panning/zooming
must neither restart the helper nor alter automation coordinates.

Separate a session's control lease from capture demand: retaining ownership
must not encode thirty frames/second for ten idle minutes. Proposed starting
budgets are one active automated device per agent and two per app, with a
bounded idle grace; capacity overflow returns busy rather than evicting another
agent or a human session. Before fixing durations, measure visible, hidden,
idle and running-turn workloads. Reuse browser turn/lease signals only after
checking their native-session semantics. No unbounded view hydration or capture
pin is allowed just because an agent record exists.

Keep the existing helper-exit fence through cancellation/reconnect and detach
only resources this session owns. Helper/host crash and app restart must not
leave active control, replay actions or delete user simulator state.

## Reviewed public surface and current implementation

The list/open/observe/act/close tools and build/run tool below are now callable; `act` accepts
bounded tap/swipe/text/named key/Home/rotation. New Open uses a fresh host-created simulator from an installed
template, or restores a scoped owned tile/device. Build jobs use separate Ask-first approval and tagged operation polling. The
[implemented contract](../../docs/internals/workspace-ios-preview.md) and shared
Core JSON catalog govern current payloads and recovery behavior.

| Proposed tool | Behavior | Boundary |
| --- | --- | --- |
| `array_device_list` | Project-bound devices/tiles, live state, ownership and capabilities | No connection or arbitrary machine-wide device adoption |
| `array_device_open` | Bind an explicit tile/device, or create an agent tile in an explicit project zone; return a session handle | Boot is explicit; no camera/focus/workspace changes; one controller |
| `array_device_observe` | Fresh upright screenshot plus frame/geometry/control metadata | Pixel observation in v1; semantic tree only when separately proved |
| `array_device_act` | Typed tap, bounded swipe, text, supported key, Home or rotation | Action ID, retry key, observation/epoch, deadline and completion result; no shell/eval/raw HID |
| `array_device_close` | Release the caller's automation lease and detach its owned attachment | Preserve borrowed app/device and any remaining human viewer |
| `array_device_build_run` | Start/cancel a validated project/scheme run and return an operation handle | Exact device and owning checkout; no signing/archive/upload |

For build/run, extend `operation.get` with a tagged build result rather than
assuming its existing delegation child-result format already fits. Cancellation
must identify the caller's owned run. Do not allow duplicate Run to race, cross-
project scheme paths or arbitrary argv/env. Grant revocation cancels the agent's
job, never a human job. Logs/provenance remain bounded artifacts in the owning
scope; a failed/cancelled build never installs a stale product. Keep long jobs
off main and outside a short interaction request's deadline.

## Delivery slices and deterministic exit criteria

The initial slice registers the actual `--workspace-api-device-check` and extends
the existing preview check. Later slices still require registered behavioral
witnesses; never invoke a proposed or guessed check name.
Each substantive change needs a failing behavior/negative control, then a passing
production path. Source-string assertions are not substitutes.

| Slice | Deliverable | Required exit |
| --- | --- | --- |
| 0: reconcile foundation | Re-read landed browser APIs/queues/leases; freeze contracts, policy and native session ownership; run isolated backend feasibility only when requested | Exact source/dependency revisions and a decision record; no reliance on dirty bench code or assumed semantic APIs |
| 1: device/session + observation | Shared session service, exact targeting, ownership and fresh image replies | Production mount/spawn/hydration; no duplicate helpers; real image reaches each enabled provider; no focus/camera change |
| 2: one complete action | Correlated native ack, queue, frame transform, takeover, revocation and retry uncertainty; begin with observe → tap → observe | The actual workspace API increments the disposable UIKit counter exactly once; denied/stale/revoked calls cause zero input |
| 3: bounded interaction | Swipe/text/key/Home/rotation and lifecycle/budget handling | Real field and Unicode readback; gesture cancellation releases; all orientation/zoom invariants; hidden active session and visible takeover behave correctly |
| 4: build loop | Service-owned jobs, operation polling/cancel, logs and provenance | Agent builds/installs/launches companion on its exact disposable device; failure/cancel/hidden/workspace-switch paths preserve correct ownership |
| 5: semantic inspection (separate decision) | Pinned backend, element references, truthful capability reporting | Real element tree/action/readback and coexistence witnesses; stale element identity cannot target another app/device |
| 6: hardening and release | All provider transports, light/dark UX, resource measurements, current release gates | Live agent walkthrough, user takeover, no orphan resources; full required matrix/release bundle checks pass |

The first agent milestone is one reliable observe → tap → observe through the
production API. UI navigation libraries, broad device settings and a general IDE
are not prerequisites.

## Acceptance matrix (initial slice evidence in the progress record)

| Case | Required observed outcome |
| --- | --- |
| Two booted simulators / duplicate viewers | The explicit device alone changes; one authoritative native controller |
| Wrong agent, checkout, user tile or forged grant | Existing policy applies; unauthorized cases cause no device input or screenshot leak |
| Free / Ask first / revocation | No extra prompt under Free; normal existing approval behavior under Ask first; revocation rechecked at dispatch and reply |
| Retried tap or paste / lost ack | Exactly one effect, or explicit uncertain outcome; never blind replay |
| Deadline in queue vs during native execution | No-effect expiry distinguished from outcome unknown; queue/barrier remains truthful |
| Pan, zoom 0.25/1/2, resize, portrait/landscape | Same image-space target reaches the same real control; transform applied once |
| Rotate/reconnect/change device after observe | Old handle rejected before HID; new observation required |
| Animated screen with newer frame sequence | Valid geometry/epoch observation remains usable within its stated TTL |
| Pointer/key takeover during queued swipe | Pending agent work stops; held inputs release; human keeps control; no cursor/focus theft |
| Host hides window or switches workspace | Agent operation retains a bounded session; no presentation or zone arming; human-only preview still suspends |
| Guest text input / clipboard | Supplied Unicode reaches the guest; automation never reads or overwrites the Mac clipboard; traces do not echo secret text |
| Agent ends/cancels, grant revoked, tile closes | Leases/queues/build ownership release correctly; borrowed device/app survives |
| Helper crash/hang/startup race / host restart | Typed failure; helper exit fenced; no stale callbacks, automatic action replay or orphan control |
| Oversized image/payload, queue flood, slow image consumer | Existing bounds hold; newest-only delivery; finite error; main thread stays responsive |
| Build install/launch failure / repeated Run | Correct command cutoff, no stale product, one run, stable operation identity and retained diagnostic receipt |
| One/two automated devices, visible/hidden/idle | Report throughput, latency, host/helper CPU/RSS and long-duration trend; counts return to baseline; no silent eviction |
| Provider parity | Image block usable in actual Codex/Claude/pi turn; text/JSON not duplicated; unavailable capability advertised accurately |
| UI | Shared components and tokens; visible controller/stop state; useful recovery errors in light and dark |

Use the existing disposable UIKit witness and app-owned state readback for
end-to-end input outcomes. Scene witnesses drive `mountWorkspaceSceneAtBoot`.
Offline stand-ins cover grants, queue order, helper acknowledgements, retries,
frames and cancellation; live checks cover real HID and provider image delivery.
Run against QA-owned roots/devices, never the user's current preview, project
state or default tmux socket. Performance results must state whether they end at
decoded-frame delivery or physical display presentation.

## Integration touchpoints and implementation-start checklist

The initial slice now uses the Core contracts, App API and native session seams
below; semantic inspection and full release hardening remain subsequent work:

- Core: `WorkspaceAPIContracts+Device`, appended operations/errors/grants, the
  shared tool JSON, exposure classification for any real new coding keys.
- App: `WorkspaceAPIService+Device`, a device session/ownership service, an adapter
  around the current preview runtime, shared action ordering/retry behavior, and
  service-owned build operations.
- Preview: acknowledged helper protocol, pure image-coordinate transform,
  frame metadata/freshness, view subscriptions, human takeover seams and visibility
  rules that distinguish human-only viewing from an active agent lease.
- All providers: existing MCP/pi image and request bridges plus shared guidance;
  no per-provider duplicate device engine, auth flow or arbitrary shell shim.
- Tests/matrix/UI census: behavioral legs registered as they land, rendered
  light/dark, bounded work assertions and owned live simulator cleanup.

Implementation-start decisions reviewed before coding (current decisions and
evidence are in the API contract and progress record):

1. The exact landed browser queue/lease/ownership API and what is actually shared.
2. The session owner and visibility/headless-demand model, with measured budgets.
3. Correlated acknowledgement, partial-effect/timeout and takeover semantics.
4. The observation coordinate/TTL schema and all transform invalidation rules.
5. Whether a semantic backend is deferred (recommended for the first visual
   vertical slice) or has passed its independent pinned feasibility proof.
6. The first production API witness and the rollout/capability switch. Disabled
   means device tools are not advertised; it is not a silent fallback to desktop
   automation or shell commands.

This list resolves implementation decisions; it does not create new user
permission prompts or delay already authorized work behind repeat approval.
No notifications are added in this plan. If later work changes alerts, pushes,
retry/suppression or tap actions, update the maintained notification-path map
and its behavioral witnesses in that same change.
