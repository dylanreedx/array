# iOS development preview in Array

Research date: 2026-10-28. Requested exploration used 16 subagents. The first
production canvas tile and its Build & Run workflow are implemented; agent device
controls and the wider development workflow below remain proposals. See
[Build & Run](build-and-run.md) for the current implementation contract.

Follow-up: [executable proofs](proofs.md) records the production tile, offline
scene gate, bundled live simulator checks, real touch/typing/paste, rotated hit
testing, reconnect, light/dark snapshots and companion capture. Earlier fixture
proofs and sandbox failures are retained as history.

## Recommendation

Add an **iOS Preview** tile with an aspect-correct device screen and a restrained
device outline. Internally it remains an ordinary tile; visually it can feel like
an iPhone or iPad on the canvas. One visible device per tile makes side-by-side
development useful. Reuse existing project/zone ownership, focus, selection,
dragging, resizing, persistence and workspace API behavior.

Start with iOS Simulator and the existing Array companion. iPad is another device
configuration of the same backend. A Mac app preview requires a separate process
and window-capture backend; a MacBook illustration does not supply that capability.
Physical devices, Android, remote hosts and SwiftUI Preview execution are later
scopes. This proposal embeds a running simulated app, not Xcode's SwiftUI previews.

## What Apple and T3 actually provide

Apple introduced Device Hub with Xcode 27. Its live screens and device controls
are documented as part of Apple's application. Research found no documented public
third-party embeddable simulator NSView. Public lifecycle tooling and public
IOSurface/Metal rendering do not make simulator framebuffer acquisition public.

- [Apple WWDC26 Device Hub](https://developer.apple.com/videos/play/wwdc2026/260/)
- [Apple Device Hub documentation](https://developer.apple.com/documentation/xcode/device-hub)
- [Apple device CLI documentation](https://developer.apple.com/documentation/xcode/interacting-with-devices-using-the-command-line)

T3 main was fetched at `5211acfe95a0c6d82a60e2524b5e46b47fe67a3e`, committed
2026-10-28T13:02:48Z. Root independently fetched that SHA's raw version file:
`agent-device` is `0.21.31`; `expo-device-hub` is
`0.19.0-canary-20261023-1357114`. Earlier exploration returned older pins;
these exact-SHA values supersede them. Upstream main and pinned package contents
must not be assumed identical.

T3 separates a supervised Expo Device Hub streaming helper, human input, and
agent-device semantic automation. Its device panel can float a viewer and share
the same device identity with agents. Closing a viewer stops streaming and leaves
the simulator running. It does not itself solve native Xcode build orchestration.

- [T3 architecture](https://github.com/pingdotgg/t3code/blob/5211acfe95a0c6d82a60e2524b5e46b47fe67a3e/docs/internals/devices.md)
- [T3 user workflow](https://github.com/pingdotgg/t3code/blob/5211acfe95a0c6d82a60e2524b5e46b47fe67a3e/docs/user/devices.md)
- [Exact tool versions](https://github.com/pingdotgg/t3code/blob/5211acfe95a0c6d82a60e2524b5e46b47fe67a3e/apps/server/src/device/deviceToolVersions.json)
- [Helper ownership](https://github.com/pingdotgg/t3code/blob/5211acfe95a0c6d82a60e2524b5e46b47fe67a3e/apps/server/src/device/LocalDeviceHost.ts)
- [Transport/input](https://github.com/pingdotgg/t3code/blob/5211acfe95a0c6d82a60e2524b5e46b47fe67a3e/packages/client-runtime/src/device/stream.ts)

The upstream native helper dynamically loads private CoreSimulator/SimulatorKit.
Current source uses IOSurface/CVPixelBuffer capture and VideoToolbox H.264.
Xcode 27 input paths also dynamically resolve private CoreDevice HID services.
These are compatibility dependencies, even when hidden behind open-source tools.

- [Expo framework loader](https://github.com/expo/expo-device-hub/blob/main/packages/serve-sim/packages/serve-sim/Sources/SimNative/SimFrameworks.swift)
- [Expo capture](https://github.com/expo/expo-device-hub/blob/main/packages/serve-sim/packages/serve-sim/Sources/SimNative/FrameCapture.swift)
- [Expo input](https://github.com/expo/expo-device-hub/blob/main/packages/serve-sim/packages/serve-sim/Sources/SimNative/HIDInjector.swift)

Borrow lifecycle contracts, input transforms, visibility policy, reconnect handling
and device identity. Do not copy the React UI or assume Electron WebCodecs behavior
works identically in WKWebView. Do not forward the entire helper origin: T3's
proxy explicitly excludes an upstream shell-execution route. Array needs narrow
typed operations, not a generic command endpoint.

[T3 proxy](https://github.com/pingdotgg/t3code/blob/5211acfe95a0c6d82a60e2524b5e46b47fe67a3e/apps/server/src/device/DeviceHubProxy.ts)

## Backend decision: prove before committing

Keep a narrow Array-owned adapter: discover, attach, receive frames, send input,
detach. Device lifecycle and build/install/run are separate services. Private
framework loading belongs in a disposable helper process, never Array's main
process. Ordinary Array startup must work without Xcode installed.

Compare these two paths in a bounded feasibility spike:

| Backend | Benefit | Work/uncertainty |
| --- | --- | --- |
| Pinned Expo/serve-sim helper | Closest reuse of T3's established stream/input path | Helper/runtime packaging, WKWebView codec support or native H.264 decoding, private input compatibility |
| FBSimulatorControl in an isolated native helper | SwiftPM/XCFramework availability, native framebuffer and persistent HID | Framework API churn, helper IPC/surface ownership, Xcode-specific compatibility |

[Meta's native framework documentation](https://github.com/facebook/idb/blob/main/FBSimulatorControl/README.md)
explicitly targets applications rendering and controlling simulators. Its
framebuffer ownership caveat when Apple's host app also presents a simulator
must be tested; don't promise simultaneous independent viewers yet.

Favor the T3/Expo path for shortest proof; select the native path if it materially
simplifies packaging and performs better. No zero-copy, latency or compatibility
claim is verified in Array yet. ScreenCaptureKit is a possible consent-requiring
window-capture fallback; it does not supply simulator touch injection by itself.

Input is an acceptance gate: tapping, dragging, release after leaving the screen,
rotation, modifiers, ordinary typing, Unicode/paste, focus loss and reconnection.
The inspected T3 client ignores arbitrary iOS sendText; basic pointer forwarding
does not establish pinch/multitouch support. Older serve-sim documentation warns
of foreground/Accessibility keyboard requirements; newer source implements a
different direct path. Test the exact pinned artifact, including operation while
Array remains frontmost. Do not ship a preview that steals focus into Device Hub.

## User experience

1. Add iOS Preview in the armed project zone; choose an installed simulator.
2. Attach to an existing session or explicitly boot the selected simulator.
3. Show the actual app screen with a compact app/device/status header.
4. Add Build & Run after attach/input works. Show scheme and build state; link
   logs to a dedicated log/terminal surface, outside the phone's screen.
5. Initial controls: device choice, Build & Run, Stop App, Home, Rotate,
   Screenshot, Logs, and external Device Hub/Simulator action when compatible.
6. Add deep-link/paste pairing and test-push injection for companion work.

Use ChoiceButton/ChoicePopover and shared tokens. Screen input controls the app;
the title moves the tile. Outer resizing preserves screen aspect and logical
resolution. Letterboxing and both orientations must map input correctly at every
canvas zoom. Define a clear keyboard-focus exit and preserve canvas shortcuts.

Persist configuration, never running processes, transport secrets or ephemeral
connections. A missing device offers selection/reconnect; it never adopts an
arbitrary booted simulator. Rehydration must not silently boot a fleet of devices.
Closing/parking detaches streaming. Stop App and Shut Down Simulator are explicit
separate actions. Prefer one controlling tile per device in v1; share a session
service if duplicate viewers are subsequently supported.

## Array integration

- `Sources/ContinuumRevivedCore/CanvasState.swift`: one tile kind, typed preview
  configuration, schema compatibility and explicit WorkspaceAPIExposure entries.
- `Canvas/TileNSView.swift` and `BrowserTileNSView.swift`: compose the new
  screen surface with the established tile lifecycle; browser stock menus are
  legacy styling and should not be copied.
- `App/TileSpawner.swift`: resolve one target zone for placement, sibling
  avoidance, z-position and installProjectTile; persist through owning project.
- `App/ContinuumApp.swift` Phase B: hydrate after the zone layer exists, retire
  orphaned runtimes, and materialize without re-tidying neighbors.
- `App/ZoneRuntimeController.swift`: owns attachment lifetimes and teardown.
  `WorkspaceRuntime` supplies global budgets across parked controllers.
- Workspace API: extend the existing provider-neutral catalog/authorization seam
  for discovery, screenshot and bounded control after human interaction works.
  No harness-specific duplicate tool implementations; no implicit camera,
  workspace or armed-zone changes from background device operations.

One renderer per tile, bounded pending frames, latest frame wins. Capture/decode
off the main thread; layout only changes geometry. Pan/zoom must not restart
capture or recreate renderers. Invisible and occluded tiles stop presentation
work; show that the preview is paused while the app continues running. Integrate
residency explicitly so snapshot caching cannot freeze a supposedly live screen.
Follow `docs/internals/performance.md` and measure alongside an Xcode build.

## Companion as first workload

`ios/project.yml` and `ios/Continuum.xcodeproj` define the existing SwiftUI app,
scheme `Continuum`, iOS 17+, bundle `dev.dylanreedx.continuum`, WidgetKit and
Live Activities. Keep internal identifiers stable. The app already has pairing,
agent transcripts, approvals, stop actions and a read-only canvas mirror.

`scripts/push-sim-test.sh` already builds/installs/launches and injects pushes.
Reuse its recipe, not its defaults: it can select an arbitrary booted simulator
and reuse a stale installed app. Pin UDID, checkout, scheme, DerivedData and
resulting app. Track build provenance. Build failure prevents install/launch;
cancellation affects only the owned build, and repeated Run cannot race.

Use isolated Array Dev/local relay pairing; do not reuse production phone pairing
or open the same project root in two installs. Preview QA uses a disposable
project root. Simulator notification injection tests rendering and actions;
physical-phone APNs, background delivery, signing and App Store readiness have
separate acceptance gates. Simulator support does not imply App Store readiness.

## Notification follow-up

Read-only history found `f206646d` (Oct 16) defaults the unset sound master to
ON, preserving explicit OFF and event opt-ins. `3c91af14` (Oct 26) fixes Claude
background children being marked complete at launch, and consumes actual later
completion frames. Neither establishes the cause of Dylan's observed banners.

Concrete source discrepancy: `Sources/ContinuumRevivedRelayCore/RelayAPNSService.swift`
classifies `status == "done"` as finished without first suppressing cancelled or
interrupted terminal outcomes. `Sources/ContinuumRevivedCore/APNSPushService.swift`
explicitly suppresses both. This is a code-level finding, not an end-to-end
reproduction. Audit real relay events for success, cancel, interrupt, background
child launch/completion, replay/reconnect, deduplication and user settings before
changing notification policy. Keep that fix separate from the preview work.

## Delivery sequence and acceptance gates

1. **Feasibility:** exact pinned backend; dedicated disposable simulator; live
   companion screen; accurate touch, keyboard and paste while Array is frontmost;
   helper crash recovery; compatibility with selected Xcode; basic CPU/memory
   measurements. Choose backend from observed results.
2. **Canvas preview:** real tile, persistent device selection, Phase B hydration,
   world-frame placement, focus, controls, disconnect/reconnect, visibility policy.
   Build via the existing terminal initially. This is already useful for coding.
3. **Build & Run:** project/scheme discovery, explicit destination, owned cancellable
   jobs, per-checkout outputs, live logs, install and launch. First acceptance app
   is Array's companion, with iPhone and iPad previews side by side.
4. **Companion development loop:** pairing via deep link/paste, test notifications,
   screenshots, appearance/Dynamic Type. Separately resolve notification truth.
5. **Agent controls:** shared device identity, grants, screenshots as image content,
   bounded input, revocation and explicit control ownership to avoid human/agent
   contention. Physical devices/macOS/Android/remote hosts are later work.

No schedule estimate until the feasibility gate resolves private HID compatibility
and helper packaging. Do not build a general IDE to reach the companion workflow.

## Deterministic witnesses and live QA

Proposed checks below do not exist yet; never invoke them before registration:

- Placement/persistence: actual world frames in nonzero-origin zones, correct
  project store, sibling avoidance, reload and missing-device recovery.
- Lifecycle: production mountWorkspaceSceneAtBoot, actual fixture frame visible,
  workspace round trip, exactly one attachment, close without killing borrowed
  device, failed persistence rolls back resources.
- Input: real view events to a recording transport across zoom, letterbox,
  rotation, focus loss and cancelled drag; assert delivered coordinates/state.
- Stream: fixture frame decode/presentation, stale-generation rejection,
  malformed-frame recovery, bounded backlog and no callbacks after teardown.
- Budget: no session restarts on pan/zoom; no hidden presentation work; resource
  counts return to baseline; actual latency/load measured separately.
- Build/run: explicit target despite other devices, build failure blocks launch,
  cancellation and repeated Run, no stale app substitution.
- UI: light/dark rendered verification, tokens, accessibility and input focus.

Register offline checks in the matrix and verify its final report lists them.
Use negative controls to establish the witnesses fail on the defects they guard.
Live QA uses a disposable device set and exact UDID only if the selected helper
honors both. No default `booted`, global shutdown, or user-device adoption. Clean
only owned resources. Simulator sandbox/service access was unavailable during
read-only help probes, so no live stream/build/input was verified in this study.

## Licensing and distribution

T3 and agent-device are MIT; Expo's root is MIT while serve-sim/serve-emu have
Apache-2.0 licenses. Preserve the relevant notices and inspect pinned transitive
dependencies before shipping. This research is not a complete dependency audit.

- [T3 license](https://github.com/pingdotgg/t3code/blob/main/LICENSE)
- [Expo license](https://github.com/expo/expo-device-hub/blob/main/LICENSE)
- [serve-sim license](https://github.com/expo/expo-device-hub/blob/main/packages/serve-sim/LICENSE)

Simulator-private code belongs in the externally distributed macOS host/helper,
not the iOS companion. Apple's public-API App Store rule and macOS notarization
are separate processes; neither guarantees a chosen helper will distribute
successfully. Validate signing, runtime loading and notarization before release.

## What was done

Sixteen parallel research tasks inspected Apple/T3/Expo/Meta sources, local canvas,
browser, companion, notification, API, performance and check infrastructure.
Root independently fetched T3 HEAD and its pinned version file, inspected the
notification classifiers and repository status, and ran scripts/benches.sh.
Read-only tool probes were performed; CoreSimulator access failed in the sandbox.
No dependencies installed, builds/tests run, simulator boots, input/push sends,
app launches, live state changes or Git mutations. The only workspace addition
is this research/implementation-plan document. Existing edits were preserved.
