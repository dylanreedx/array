# Agent control of iOS Preview

The visual control API provides `device.list`, `device.open`,
`device.observe`, `device.act` (bounded tap/swipe/text/key/Home/rotation),
`device.close`, and `device.build_run`. The tool names and
schemas live in the [shared catalog](../../Sources/ContinuumRevivedCore/Resources/PiExtensions/array-workspace-tools.json).
Codex/Claude's MCP helper and pi use that one definition; roled pi allowlists now
read it too. Provider adapters share the same host operation, grant and image
semantics. Actual model-turn acceptance is separate from transport acceptance.

This work is uncommitted follow-up to preview baseline `efcce530`. The
[plan](../../.plans/92-ios-device-preview/agent-control-plan.md) and
[progress record](../../.plans/92-ios-device-preview/agent-control-progress.md)
record the visual, bounded interaction and build-loop proofs. Semantic
inspection remains a separate proposed decision. No release, deployment or version bump is part of this work.

## Using visual control

1. Call `array_device_list` with your explicit Home `checkoutHandle`. It returns
   project tiles, available Xcode device templates, and receipt-owned devices.
2. Call `array_device_open` with `zoneId`, `templateId`, `allowBoot: true` and a
   stable `idempotencyKey` to create a fresh disposable simulator and an owned
   preview tile. It returns the actual `deviceId`, `tileId` and `sessionId`.
   Reconnect with `tileId`; an optional `deviceId` constrains that exact binding.
   Cold boot/connection is bounded. If it fails after the tile was saved, the
   error supplies that owned `tileId`; retry it explicitly instead of creating
   another simulator.
3. Call `array_device_observe` with checkout/session. It returns one upright JPEG
   image item and an `observationId`, pixel dimensions, orientation, geometry
   generation, sequence, emission/receive times and expiry budget.
4. Call `array_device_act` with `kind: "tap"`, checkout/session/observation,
   image-pixel `x`/`y`, and a stable action `idempotencyKey`. Coordinates use the
   image's top-left origin, with `0 <= x < width` and `0 <= y < height`.
5. Observe again to verify the app's response. `native_sequence_completed` only
   confirms that the native sequence finished. It does not establish an
   application assertion or completed animation.
6. `array_device_close` releases automation. It preserves the simulator, running
   app and remaining human viewer. Reopen the same owned tile to reuse it.

All actions require a current observation, scope and retry key. The other
`kind` values are:

| Kind | Fields and bounds |
| --- | --- |
| `swipe` | Image-pixel `x`, `y`, `endX`, `endY`; integer `milliseconds` from 100 to 1500; at most 60 native moves |
| `text` | `text`, 1–16384 UTF-8 bytes; writes the guest pasteboard and sends guest Command-V; leaves the Mac clipboard alone |
| `key` | `key`: `return`, `tab`, `backspace`, `escape`, `left`, `right`, `up`, `down`; one complete down/up pair |
| `home` | No extra fields; presses simulator Home |
| `rotate` | `orientation`: 1 portrait, 2 upside down, 3 landscape left, 4 landscape right; invalidates the observation |

Swipe endpoints share the tap transform and bounds. Cancellation/controller
loss ends held contact and fences the connection; an admitted partial action is
uncertain and never blindly replayed. Rotation completion acknowledges native
orientation, not the end of UIKit animation. Observe a settled layout before
choosing a new target. Reuse the same key to retrieve the original result;
changing the payload conflicts.

There is no fallback to a `booted` alias, the active project, another simulator,
the Mac desktop, shell/eval, or browser DOM automation. A missing/unmounted zone
returns `presentation_required`; the API never navigates the user's workspace,
arms a zone, changes the camera, or takes keyboard/pointer focus.

## Simulator ownership and permissions

To lend an existing simulator, a person can select it using the device picker on
an agent-owned tile, then choose Allow Agent Control. Another preview controlling
that device must disconnect first. This trusted UI handover never mints a managed
ownership receipt; Close preserves borrowed state. Direct adoption of an original
human tile by its tile ID remains unsupported in this slice.

A fresh agent tile creates a new simulator from a host-verified device-type and
runtime template. It never adopts the template source's app data. An arbitrary
existing machine-wide UUID cannot become agent-owned by creating a second tile.
An existing human/foreign tile cannot be adopted by naming its tile ID either.

Host-created devices have durable receipts in the channel's own Application
Support, under `DeveloperTools/iOSPreview/managed-devices.json`. A receipt binds
exact UDID, principal, project, checkout, template and creation time. An owned
device whose tile was removed can be restored through its scoped receipt.
No model field can mint a receipt or a grant. Cleanup verifies the exact receipt;
it never identifies a device by display name or guesses which booted device to
shut down. Public tools do not expose reset/erase/delete. Normal Close leaves the
guest running. Remove unused managed devices in Xcode to free inventory.

Canvas metadata separately persists host-owned agent/checkout identity and
SHA256 creation key/payload digests. Retrying creation finds the same tile across
restart; a reused key with a different payload conflicts. Helper tokens,
endpoints, grants, live connections and temporary attachments are never persisted
there. Restoring the canvas does not boot a device automatically.

Free within a project uses the existing permission policy without additional
confirmation. Ask first uses the existing trusted approval seam; approving Open
for the session covers its visual interaction operations. Build & Run requires
its own approval under Ask first; Open does not silently grant building. A one-use approval
remains one use. Access is checked at dispatch and again before input or image
reply. Disabling tools or revoking a grant invalidates in-flight authority.

A simulator grant covers the whole selected simulator, including system UI and
other apps. It does not enforce app-only isolation. Native capture/HID remains in
the existing authenticated loopback helper, with no endpoint/token in model
replies and no OS-wide screen-recording or Mac-input automation route.

## Human control

The tile names the controlling agent and offers Take Control through the styled
Preview menu. Actual pointer/key input wins too. The host increments a control
generation, releases the attachment and cancels pending automation. The reclaim
is recorded by device for the running App process, so reopening a tile or
changing tile IDs cannot bypass it. During that process only the user's Allow
Agent Control action hands that device back. Reclaim state is not a durable ban:
after App restart, old sessions are invalid and a fresh Open rechecks the
persisted owner and current grants. These takeover
seams observe input in Array; they do not detect input from unrelated simulator
controllers outside Array. Input during
provisional connection is checked before an attachment can be minted.

A native input already dispatched can have an uncertain effect. Cancellation
cannot undo it. Its helper is fenced through real exit before another controller
is admitted; held input is released where possible and never replayed. The
caller receives an explicit uncertain outcome rather than a fictitious rollback.

## Fresh images and retry outcomes

`fresh.jpg` waits for a native frame callback after the request. It never satisfies
an observation from the tile's parked pixels or bytes already queued in its MJPEG
stream. There is one pending image request per helper, with a 4.5-second helper
and five-second host deadline. Assembly/decode/rotation/encoding stays off the
main thread. JPEG image bytes are bounded at 4 MiB (the base64 envelope is larger)
and decoded images at four million pixels, with per-side dimension limits too.

Emission time is not capture time. The native backend does not supply a verified
capture timestamp; the reply explicitly reports `nativeCaptureTimeKnown: false`.
A fresh callback does not by itself prove application transition completion.
For example, UIKit can report new landscape bounds while its screenshot is still
mid-rotation; observe the settled screen before choosing a new target.

The host-issued frame binds session/connection/control and geometry. A new
explicit observation replaces the previous handle; ordinary animated video
frames do not invalidate otherwise stable geometry. Rotation, reconnect, target
change and human takeover invalidate it. Frame/idle budgets use a monotonic
continuous clock and currently expire after 30 seconds.

Tap requests are atomic and acknowledged by correlated helper request ID after
both native calls settle. Invalid points, held human input and stale geometry
cause zero action HID. Geometry is checked again at execution after queued work.

Same key + same effective action returns its known result; a changed payload
conflicts. Pending retries report busy. If dispatch may have happened, lost ack,
cancellation or timeout reports `outcome_unknown` and retains a retry tombstone.
No automatic retry repeats a tap. Cached replies are reauthorized. Closed-session
history is bounded; an evicted old session cannot become live again or dispatch
input. After app restart old session handles cannot execute anything.

## Residency and resource limits

The App attachment retains the existing preview runtime independently of its
viewer. Hidden/cold workspace changes do not create another helper; Phase B
re-hosts the retained runtime on return. Ordinary human-only previews still
suspend with visibility. Explicit tile close and disconnect release automation.

Current limits:

- One active automation attachment per agent, two per app.
- Two inventory-managed simulators per agent, eight per app; these are separate
  from active attachments and survive restart for reuse.
- Thirty seconds of idle attachment grace, then hidden capture tears down.
- One input and one fresh observation at a time per attachment; overlapping work
  returns busy rather than queuing unbounded actions.
- 128 retry records per active session and 64 bounded closed-session ledgers.
- Existing latest-only decode/presentation and bounded native input queues remain.

Receipt corruption fails closed without overwriting the file or adopting/deleting
another device. Creation interrupted between `simctl create` and durable receipt
write may leave an unregistered empty simulator; the host never guesses ownership
by name to clean it. This crash window is not covered by the current witnesses.

## Service-owned Build & Run

`array_device_build_run` starts a local Debug simulator build or cancels an owned
job. It follows the same explicit Home checkout and identity policy as visual
control. Builds run the selected checkout's normal Xcode build phases; the API
accepts no arbitrary command, arguments, environment, signing, archive or upload.

Start with `kind: "start"`, `checkoutHandle`, current `sessionId`, checkout-relative
`projectFile` ending in `.xcodeproj`/`.xcworkspace`, exact `scheme`, and a stable
`idempotencyKey`. The host resolves symlinks, rejects escaping containers, and
probes schemes in that exact project. It returns `operationId` immediately.
Poll `array_get_operation` with that ID. Its `deviceBuild` result is tagged
`kind: "device_build"`, separate from a delegation's `childResult`.

| Build state | Meaning |
| --- | --- |
| `queued`, `building`, `installing`, `launching` | Job is active; operation status is `accepted` |
| `succeeded` | Verified fresh simulator app installed/launched on the exact session device; operation status is `committed` |
| `failed` | Job failed before installation admission |
| `cancelled` | Job cancelled before installation admission |
| `outcome_unknown` | Installation/launch may have had an effect; observe before another intent |

The result includes device, project/scheme, known bundle identity, installation
uncertainty, stable failure reason and up to 8192 UTF-8 bytes of private log tail.
It exposes no helper token or endpoint. An accepted job retains its retry record
even after failure/cancellation; retrying the same key retrieves that job instead
of rebuilding. A changed payload conflicts. Expired results never authorize blind
replay. Cancellation uses `kind: "cancel"`, checkout and your `operationId`; it
works after the preview lease ends and settles asynchronously.

One job per principal and two per app may run. Human and agent builds share an
exact-device exclusion guard. A job pins the existing attachment across hiding
and workspace changes; it never changes the user's presentation. Human takeover,
revocation, explicit close/disconnect, agent end and the 900-second whole-job
budget cancel its owned commands. A cancelled/failed compilation never proceeds
to settings, install or launch. Each run uses fresh products, validates platform/
bundle identity, and cleans its own DerivedData after command exit. Small logs
and successful run provenance remain in the dev app's own support directory.

Compiler stdout/stderr retain the newest 512 KiB during execution; the API returns
only the smaller private tail. While a build's viewer is hidden, its same helper
acknowledges a 1 FPS capture profile; revealing the tile or settling the job
restores its configured interactive rate. Profile acknowledgments are correlated
and bounded by five seconds. Idle visual leases retain the existing 30-second
budget. This reduces hidden capture work without releasing ownership or changing
coordinates. Sustained multi-device CPU/RSS and hard host-crash compiler cleanup
remain separate hardening checks.

## Verification boundary

The targeted offline gate is `scripts/run-matrix.sh --ios-preview-tile`. It
rebuilds App/Core/MCP helper and reports the device API, native MCP loopback,
provider catalog/image, roles, transcript details, exposure, preview, bridge,
process ownership and UI hygiene legs. The normal full matrix also registers the
new API check. Checks use isolated roots/defaults and mock native commands; they
do not touch a real simulator or the default tmux server.

The opt-in `--ios-preview-live` gate creates disposable devices. It proves the
production API against an actual UIKit counter, with native acknowledgements,
new images, retry/stale rejection and unchanged template device state. The
bounded interaction API live proof adds guest Unicode/backspace/Return readback,
UIKit swipe count, Home backgrounding, rotation and same-key retries for all kinds. Its owned
resources are cleaned by exact identity. These are transport/application
witnesses; a real Codex/Claude/pi model turn remains a separate acceptance gate.

Full release matrix, signed release bundle/notarization, sustained multi-device
performance and Xcode versions beyond those recorded in the proofs remain
unverified. No semantic accessibility tree, physical-device support, push injection
or App Store submission is provided. Human Build & Run remains the existing independent feature.

The current build/control proof runs the actual native MCP executable through the
production API, builds an isolated copy of the real companion on the exact owned
guest, switches workspaces during compilation, verifies stable retry identity,
and observes the installed app. The fake fixture's active-owner predicate is
explicitly overridden because it has no real model process. It does not establish
actual Codex/Claude/pi model-turn acceptance. See the dated slice 3/4 handoff for
the current bundle gate result; iOS-focused success is not a release approval.
