# Agent control implementation progress

2026-10-29. **Visual, bounded interaction and build-loop slices implemented and verified.** This is uncommitted follow-up to preview
baseline `efcce530`, authorized by Dylan after the planning review. No staging,
commit, release, deployment or version bump was performed for this follow-up.

The authoritative implemented contract is
[workspace iOS Preview](../../docs/internals/workspace-ios-preview.md). The
[forward plan](agent-control-plan.md) also contains later work; the current six-tool catalog is published locally. Semantic inspection stays proposed.

## Implemented

- Six device tools in the single Core catalog, routed through the existing
  provider-neutral workspace API and permissions. Codex/Claude MCP and pi share
  schemas/guidance; roled pi allowlists derive from that catalog.
- Exact Home checkout, project/zone, principal and session binding. New tiles
  create a **fresh disposable simulator** from an installed template. An arbitrary
  existing UDID, human tile, foreign owner or model-supplied approval cannot grant
  control. Durable scoped receipts permit reuse of the caller's managed devices.
- App-owned attachments retain one existing native runtime across hidden/cold
  viewer lifetimes. Phase B rehosts it without duplicate helpers, navigation,
  focus/camera changes or zone arming. Idle/capacity/image/retry budgets are finite.
- A newly emitted frame barrier, upright bounded JPEG image blocks, monotonic
  frame expiry, shared image-to-native transforms and execution-time geometry
  checks. Emission/receive timestamps explicitly do not claim capture time.
- Atomic correlated native tap completion. Same-key retries return the known
  result; changed payload conflicts; uncertain dispatch retains a tombstone and
  never automatically replays. Native completion alone is not app success.
- Trusted Take Control/Allow Agent Control UI, device-wide reclaim within Array,
  startup takeover fences, dispatch/reply revocation and borrowed-state
  preservation. A person may lend a simulator through an agent-owned tile;
  direct adoption of an original human tile remains unsupported.
- A registered production `--workspace-api-device-check`, native MCP executable
  loopback, offline helper/runtime/API checks, and actual UIKit application
  readback through the live workspace API.

## Verification actually run

Raw evidence is under `qa-runs/overnight-2026-10-29/ios-control/`. A compact
[durable proof set](proofs/agent-control/README.md) preserves gate output, negative
controls, bundle manifest and rendered UI without QA stores or helper secrets.

| Check | Observed result |
| --- | --- |
| `scripts/run-matrix.sh --ios-preview-tile` | Latest `completion-matrix.log`: **12/12 legs PASS**, including the new API leg, real native MCP executable/authenticated HTTP/image item, role/catalog parity, exposure (97 keys), bridge and ownership checks |
| `scripts/run-matrix.sh --ios-preview-live` with canvas enabled | `live-final-matrix.log`: **2/2 PASS** on host-created disposable device; real portrait counter 0→1; retry/stale calls add zero input; original template device unchanged; receipt cleanup complete |
| Additional portrait/landscape API witness | `live-landscape-settled-matrix.log`: **2/2 PASS**; counter0→2, exactly once in each orientation; old geometry and retries add zero input; original device unchanged; all ten exact final/diagnostic device IDs verified absent |
| iOS companion build | `ios-build.log`: **BUILD SUCCEEDED** using generic iOS Simulator destination and isolated DerivedData |
| Dev bundle | `scripts/dev-app.sh --no-launch`: **PASS**; shared Desktop dev bundle rebuilt, not persistently relaunched |
| Bundle verification | QA-only copy of `scripts/check-app-bundle.sh`, with a verified disposable tmux socket and per-probe server cleanup: **PASS**; all eight checks, LaunchServices smoke and ad-hoc signature valid; no real defaults/App Support pollution |
| Rendered UI | Controller state and shared Preview controls inspected in both light and dark appearances |

The earlier portrait debug run measured ten fresh API observations: nearest-rank p50
54.4 ms, p95 222.9 ms; tap native ack 54.6 ms. The UI timer ran 117 ticks while
observations completed. Raw samples and endpoint are in
`live-final/canvas/workspace-api/device-api-report.json`. This is a small local
sample ending at the **API reply**, not physical display scanout, and does not
establish a performance improvement or sustained two-device behavior.
The final portrait+landscape run measured p50 45.0 ms/p95 215.9 ms, native tap ack
24.1 ms and 118 UI ticks, also ten samples with the same API-reply endpoint.
These variations are not a measured optimization.

Behavioral negative controls include a red arbitrary-device adoption case before
the managed-device fix, a fresh-image barrier failing against the original bridge,
an intentionally wrong image rotation failing pixel assertions, and a changed
retry key causing the exact-once assertion to fail. The production sources were
not left mutated. A genuine MCP parity failure caught the old roled-pi allowlist;
its catalog-derived replacement passed subsequent 12-leg gates.

The final live extension first encountered a bounded cold-connect failure, then
caught a test-readiness error: UIKit's landscape bounds were already set while
the screenshot was visibly mid-rotation. The saved image/state identify the
failure; the witness now waits for the app's actual transition completion before
observing and tapping. The production transform/tap was unchanged. Its final
2/2 gate passed; all failed attempts and cleanup remain in the handoff.

Two bundle attempts failed before the final passing run: the first namespace
check needed `/var` canonicalization; a later terminal-theme check timed out when
the prestarted sentinel server's environment leaked between probes. The QA
wrapper now verifies the socket, stops the sentinel, and cleans only that explicit
socket between probes. Terminal product code was not changed for this issue.

Earlier foundation logs remain under `qa-runs/ios-agent-control/`. The first
negative Swift harness used a throwing main and exited by signal 133; it was
replaced with caught-error exit 1 and rerun. Subsequent negative controls use
normal failed exits. Other interrupted builds observed concurrent SettingsKit,
CanvasTileSelection or AgentSupervisor edits; no other agent's work was reverted.

## Remaining acceptance and scope

A real Codex/Claude/pi model turn using returned images is **not run**. Native MCP
transport/image delivery and shared pi catalog checks are proven; they do not
substitute for that model walkthrough. Full release matrix, release-configuration
signed/notarized bundle, sustained visible/hidden two-device CPU/RSS and Xcode 27
compatibility remain unverified.

Bounded agent actions are now proved below. Service-owned Build & Run jobs are now proved below. Semantic accessibility trees require a separate
decision; physical devices and App Store automation remain out of scope. Existing
human input/rotation/Build & Run remain independent preview features. The original
fixture-injected rotation proof was followed by a real agent rotation API proof.
No notification path changed.

No semantic backend or browser bench code was imported. The App-owned device
adapter uses the landed host grant/image/dispatch seams; device-specific native
completion and frame accounting remain explicitly scoped. No dependency was
installed into user-global locations. QA creates and cleans only exact owned
simulators and isolated app/project state; production Array and the default tmux
server were not used. No new bench/worktree was created.

## Bounded interaction slice verified (2026-10-29)

`slice3-schema-offline-retry-matrix.log`: **12/12**. Public catalog requires the
correct per-kind fields; every kind uses the existing scope/observation/retry
fences. The actual API witness cancels an in-flight swipe through real mouse
human takeover, returns uncertain completion, and never replays it. Native
controller loss ends held contact. Invalid endpoints/duration/keys/orientations/
UTF-8 bytes reject without native input. A tap-only negative adapter fails the
extended native behavioral check.

`slice3-api-live-matrix.log`: **2/2**. Real guest Unicode/backspace/Return readback,
UIKit swipe count, Home backgrounding, acknowledged rotation, portrait/landscape
taps and same-key no-extra-input for every kind. Template source unchanged;
`slice3-api-cleanup-verification.json` confirms both exact owned devices absent.
Native-only preceding gate also passed **2/2**. Compact evidence is under
[bounded interaction proofs](proofs/agent-control/bounded-interaction/).

Actual failures retained: two check compilation mistakes (non-Sendable dictionary
Task result, reused local name), stale tap-only schema expectation, and one
unrelated privacy-detail timing leg at 105.6ms against 100ms. Fixed the check
integration/schema, preserved the timing budget, and the complete rerun passed.
Concurrent App source edits caused earlier compilation invalidation; no other
agent's edits were reverted.

## Build loop verified (2026-10-29)

Service-owned job foundation passed **12/12** in
`slice4-foundation-final-matrix.log`, including hidden retention, exact device,
human/agent build exclusion, no installation after failure/cancel/owner end/
revocation, fresh products and cleanup. The production command probe proves a
newest 512KiB log budget and finite owned-process timeout.

The internal `device.build_run` path and tagged operation polling now pass the
production API check (`slice4-api-cancel-fixed-check.log`): separate Ask-first
build grant, stable success/failure retry identity, conditional start/cancel,
path-escape denial, bounded diagnostics, cancellation and install uncertainty.
The witness found and fixed an inherited guard that incorrectly demanded a live
session when cancelling an already-owned job. It also corrected a fixture's
launch argv index; production argv was already correct.

The first actual companion build proof expired its preview lease while copying
source/dependencies **before compilation**. Both exact devices were cleaned
(`slice4-idle-failure-cleanup.json`). Preparation now occurs before Open, keeping
the production 30-second idle budget intact. The prepared live rerun passed 2/2, followed by the final native MCP/resource
proof below. The build tool is now in the shared six-tool catalog with its
conditional schemas and privacy-safe row; Core/MCP/pi parity passes for 19
workspace tools. Historical running checkpoint: `qa-runs/overnight-2026-10-29/`
`ios-control/SLICE4-CHECKPOINT.md`.

Final build-loop verification:

- `slice4-capture-profile-matrix.log`: **12/12**, including native MCP start/poll/
  retry, separate build approval, revocation, whole-job deadline, owner end,
  hidden capture/restore and existing preview/process-tree/capability checks.
- `slice4-final-live-matrix.log`: **2/2**. Actual native MCP tool builds and runs
  the real companion on F6782709-9717-4E61-B7A0-CFBC2807EF74 from an isolated
  source copy; the workspace switches during compilation and the same helper
  survives. Retry keeps operation identity. Build loop 67.5908 seconds; hidden
  native profile 1 FPS delivered **4 frames in 3 seconds**, then interactive
  rate restored. This is not a CPU/RSS or physical-scanout benchmark.
- `slice4-core-contract.log` and `slice4-render-check.log`: pass; real tile
  renders visually reviewed in light/dark. Actual companion portrait screenshot
  visually inspected. No notification button was pressed or phone push sent.
- `slice4-dev-bundle.log`: shared Desktop dev bundle built in 41 seconds with
  `scripts/dev-app.sh --no-launch`; no persistent preview relaunch.
- **Bundle gate RED twice**: `slice4-bundle-check/manifest.json` and retry both
  fail only `--terminal-theme-fidelity-check` with `spawned terminal surface
  missing` (TileSpawner.swift:4847). Other seven bundle self-checks, LaunchServices
  and codesign pass; persistent App Support/defaults pollution false. Not a
  KNOWN-RED. No unrelated source was changed to mask it. The terminal owner's
  follow-up (`qa-runs/overnight-2026-10-29/terminal-bundle-handoff.md`) found
  Ghostty surface init returning OutOfMemory while the display slept; the leg
  passes with the display on. Rerun the bundle gate green before release.
- Release packaging check (2026-10-29): `WorkspaceAPIAgentsContractChecks`
  pinned the op order without `.deviceBuildRun`, so bare CoreChecks would fail
  the moment the build op landed. Added it; RED/GREEN recorded in the packet.
- `slice4-owned-device-cleanup.json`: all six exact slice-4 source/guest IDs
  absent, three managed ledgers empty, both successful jobs' DerivedData gone
  and retained compiler logs exactly 512 KiB with receipts preserved.
- Native key-down ambiguity has a genuine RED/GREEN witness: cleanup now tracks
  down intent before awaiting a native promise and attempts up after partial
  failure. A negative adapter disabling hidden capture reduction also fails
  its behavioral probe. These are temporary QA stand-ins, not product edits.

No required slice-3/4 feature implementation remains. Full release validation,
actual provider model-turn acceptance, sustained two-device CPU/RSS, host-crash
compiler cleanup and newer-Xcode compatibility remain unverified. Semantic
inspection is not implemented. Changes remain uncommitted.
