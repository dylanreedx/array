# Stage 1 input safety implementation

Bench: `.worktrees/focus-safe-input`, release base `d41dad04`.

Result: the targeted matrix reports 10 legs passed, including all three new
behavioral witnesses. Restoration, semantic selection and bounded native-select
preflight are implemented. The universal popup lifetime exit condition remains
unmet; the limits below are material.

## Focus investigation

The first `outcome_unknown` was not an unrelated-input invalidation policy.
Temporary diagnostics in `BrowserActionQueue.finish` established authorization
remained nil (valid), while its input-count fence changed from 0 to 5. The
local monitor saw a sibling text view under the mouse, but the inactive fixture
window swallowed that activation click; all five keys still had WKWebView as
the first responder. `BrowserAutomation.noteUserEvent` therefore counted real
browser input, and `BrowserActionQueue.finish` correctly replaced the result
with `revokedInFlight`. No queue change is retained.

The fixture now reports key status without making itself key, and temporarily
accepts the first mouse on ComposerTextView, following CanvasPointerPathChecks.
It remains off-screen and never activates the check process.

With that correction, the baseline exposes a product bug: after the sibling
composer becomes first responder, subsequent direct webView.keyDown calls
forward the remaining agent text into the composer. The stale outer type
restore can also replace the user's new responder. The witness calls the
production workspace API after mountWorkspaceSceneAtBoot and delivers the user
click and keys through NSApp.sendEvent.

The fix guards restoration across every type await and invalidates synchronous
click/key restoration on input anywhere in Array (without broadening browser
ownership takeover), and restores only while the current responder belongs to
the target web view. Typing stops before additional native keys when another composer owns the
responder. Inactive-window typing may retain the original sibling responder;
that existing supported path remains valid only while its responder and
app-wide input generation are unchanged. The type action keeps its own native
focus borrow until its guarded defer rather than blurring the field between
its initial click and its keys. The error explicitly says a prefix may already exist and
requires observation before deciding what remains. This is safe interruption,
not continued trusted background typing after responder loss. Transient WebKit
focus changes and arbitrary programmatic responder changes remain Stage 2
compatibility questions.

Witness results: corrected baseline FAIL (sibling contained five `z` keys plus
remaining agent `a` text); fixed binary PASS (five `z` keys only, new responder
retained). Debug build passed. Logs: `/tmp/focus-valid-red.log` and
`/tmp/focus-proven-green.log`. Earlier stale-ref and outcome_unknown failures
were fixture failures, not the accepted red witness.

## HTML SELECT operation

`array_browser_select` publishes `browser.select`. It requires the existing
browser-control scope/grant and ownership path even when listing. Omit
`options` to list; pass `options: [{value, index?}]` to replace selectedness.
Indices are zero-based across all options. Repeated values require explicit
indices; disabled controls/options/groups and invalid selections reject before
the first DOM write. Empty selections are supported for multiple selects only.
The bounded listing retains labels, exact values, indices, groups, multiplicity
and selected/disabled state. Snapshots include the same HTML-select metadata.
The existing action result's `value` holds this listing as JSON.

The operation uses native DOM selectedness setters in the isolated automation
world, then emits bubbling, untrusted `input` and `change` events in that order
only if selection changed. It reads back after a yield and rejects a selection
that application reconciliation did not retain. Generic application-side state
is not introspectable: the witness also checks its fixture's application state
and rendered saved output; agents must inspect a real application's dependent
state before proceeding. `isTrusted`-dependent applications are a compatibility
gap, not a reason to claim these events are trusted. Custom ARIA comboboxes and
listboxes are rejected by this operation and retain their widget path.

Select witness: RED on the pre-operation binary (`unsupported: Unknown
operation browser.select`); GREEN with the implementation. It checks listing,
duplicate disambiguation, atomic validation, disabled option refusal, multiple
selection, untrusted event order, application model + rendered saved output,
controlled reconciliation refusal, and production grant denial. No newly
visible popup window appears. The initial all-window-count assertion was too
broad: an off-screen NSCampoLightweightUIHostWindow appears during fixture
startup. A control interval before *any* select action observes the same window;
the witness records that baseline rather than excluding a window by class name.
Logs: `/tmp/select-red.log`, `/tmp/select-control-green.log`.

## Native select preflight and its limits

The native-input backend inspects a ref's element and hit target, coordinate
hits through accessible frames/open shadow roots, associated labels, and the
focused element through accessible frames before dispatch. Known HTML SELECT
activation fails with `unsupported` and names `array_browser_select`.
Uninspectable frame input also fails before dispatch. Type checks the focused
DOM control before each character and before clear/submit; standalone key input
also requires the native responder still belong to the browser. ARIA widgets
continue on their ordinary widget path.

The witness installs a throwing hook immediately before the native input
boundary. Its baseline is RED because clicking SELECT reaches that hook. This
safely prevents a baseline native menu from ever appearing on the real display.
The fixed path must reject *before* the hook; the same hook interrupts an
ordinary custom-widget click before dispatch. The witness checks ref, label,
coordinate, type, key and same-origin-frame routes, verifies that blocked
clicks do not invoke/schedule their immediate/delayed showPicker handlers, and
checks new-window absence, pre-dispatch cancellation, inaccessible-frame refusal,
navigation and runtime teardown.

**Unmet universal popup lifetime condition.** These are bounded preflights, not
a universal public-WebKit popup suppression or cancellation mechanism. Arbitrary
page handlers on other controls, focus handlers, cached or delayed showPicker
calls, page scripts run by evaluate, and document/geometry/focus changes after
inspection but before native delivery are not universally prevented. A
cross-origin frame is refused rather than driven. Transformed frame native
input is conservatively refused. Closed shadow roots can conceal native SELECTs
from public inspection; those host clicks are not universally classified.
Native date/color/datalist, print,
autofill, browser/OS permission and authentication surfaces are not solved by
HTML-select preflight. No public native-select presentation/cancellation
delegate was established by the supplied research; this change does not add
private WebKit API or attempt system Escape. An already-open popup or a delayed
page-owned popup cannot be universally reclaimed on cancellation, navigation
or teardown by this implementation. Stage 1 cannot claim the full popup
lifetime guarantee or complete trusted typing after responder loss.


## Final causal evidence and negative controls

- The initial generic error is produced by
  `Sources/ContinuumRevived/App/BrowserActionQueue.swift:223` / `:224` /
  `:261`: `currentInputCount` was 5 against the captured 0; authorization was
  valid. The temporary trace's action reply was `busy` / `userTyping`, not a
  deadline failure. The key classification at
  `Sources/ContinuumRevived/BrowserEngine/BrowserAutomation.swift:742` uses the
  window responder; `:749` increments only the identified browser. The swallowed
  inactive-window click left WKWebView as that responder. This was a fixture
  routing problem, not an observed policy that cancels unrelated composers.
- The product path forwards native input at
  `Sources/ContinuumRevived/BrowserEngine/BrowserAutomation.swift:631`. The
  corrected fixture demonstrated remaining agent text reaching the newly
  clicked composer. That same production path is reachable while Array users
  change composer during a type; browser-local input fencing cannot protect it.
- The final focus witness attaches a second managed agent and its real
  ManagedAgentTileNSView composer. It mounts the native controls for checks,
  holds them awake through a check-only pointer predicate, and injects the user
  click through NSApp.sendEvent after exactly five native agent characters.
  It asserts the page contains `aaaaa`, the new composer and draft contain only
  `zzzzz`, and the responder remains the new composer. No real pointer moves.
- `/tmp/focus-managed-red.log`: with only the old browser-local restore put
  back, `newResponder=false`, `delivered=5`, `next=zzzzz`, `old=`. The local
  browser input count was 0. This isolates stale restoration independently
  from the earlier text-forwarding failure. `/tmp/focus-managed-green.log`
  passes with the safe restoration restored.
- `/tmp/select-value-red.log`: deliberately omitting only the selected-value
  readback comparison fails when the application rewrites an option's value
  while retaining its selected index. The final tool checks both indices and
  values and its result includes the rendered application-state change.
- `/tmp/popup-red.log`: the baseline reaches the native input boundary once;
  the hook throws before delivery, so the negative control cannot open a menu
  on the actual display. The final witness rejects before that hook, including
  nested label coordinates, a select overlay above a frame target, transformed
  and inaccessible frames, and cancellation before dispatch.

Focus loss can follow a committed prefix. It uses the existing
`outcome_unknown` result code, with a specific focus-loss explanation, so the
existing queue retains the uncertain result rather than inviting an unsafe
replay. This is intentionally different from the original generic queue fence
error. No new action-result fields or BrowserActionQueue changes are added;
reconcile this error with the other helper's result/epoch contract on merge.

The select API bounds requests to 256 choices, controls to 500 options, and
checks the current/projected listing size before mutation. Application changes
to selected values or indices during reconciliation produce an explicit
uncertain result. Application-defined input/change handlers can still call
showPicker using prior activation: the semantic action itself requests no
native picker, but arbitrary page behavior is not universally suppressed.
Actual React/Vue package suites and arbitrary native-popup lifetime are not
verified by the controlled model/microtask fixtures.

## Validation and scope

Final command: `scripts/run-matrix.sh --focus-safe-input`, through the crash
isolation wrapper, with ARRAY_AGENT_ID unset, stdin closed, TERM=xterm-256color
and Xcode's toolchain on PATH. This targeted mode runs the matrix inventory,
three new app witnesses, the neighboring engine and workspace-browser API legs,
and CoreChecks' workspace contract, agents contract, MCP catalog and role
registry arms. It builds Array and CoreChecks in debug. The matrix uses its own
verified disposable tmux namespace; the default server is untouched.

The first targeted iterations exposed and then resolved the inaccessible-frame
ref fixture mistake, inactive-window native responder assumption, a retired
runtime reference in the API fixture, and two approval tests that used Enter
only as an authorization probe. Those approval probes now use zero-distance
scroll with the same control grants. No production approval UI is changed.
The initial crash-wrapper compile failed on a Command Line Tools SDK/linker
mismatch; it was rebuilt with the explicit Xcode compiler and SDK before runs.
An intermediate build failed because a source file changed while compiling;
it was rebuilt successfully before any result was trusted. Earlier failed
window-count assertions were resolved by the pre-select startup control
interval, not by excluding a window class.

The full matrix, release build, live tiles, actual system input, preview app,
prod app, real project roots and Stage 2 private APIs were not used. All source
edits and builds are in this bench. No pushes or version changes.

Minimal overlaps to reconcile with array/tile-sharing-contract:

- WorkspaceAPIService.swift / WorkspaceAPIService+Browser.swift: add select routing and
  request routing only; no ownership/takeover policy changes.
- BrowserActionExecutor.swift: route select and classify focus/select readback
  errors through existing results.
- BrowserAutomationScript.swift: additive SELECT metadata, semantic selection
  and native-input inspection; ref maps/epochs are not changed.
- Existing BrowserAutomationEngineChecks.swift and WorkspaceAPIBrowserChecks.swift:
  verify refusal of foreign native key delivery and use the current runtime.
- BrowserControlHardeningChecks.swift: two authorization probes use scroll;
  approval presentation and queue semantics are unchanged.
- Shared catalog/contract expectations, ContinuumApp check wiring, matrix and
  its inventory are extended for the published tool and behavioral witnesses.

BrowserActionQueue.swift has no retained edit. The bench remains for integration
of its committed work; no other bench is reclaimed.


Final receipt: `/tmp/focus-final-gate.log` ends with:

```
---- Focus safe input matrix (targeted): 10 leg(s) run ----
Focus safe input matrix (targeted) passed.
```

Both debug products built successfully in that run. All three new app legs are
printed as PASS, and the neighboring engine/API and four CoreChecks arms pass.
There are no pending failures in this targeted gate. This does not cover the
full matrix, arbitrary picker suppression/lifetime, Stage 2 editor compatibility,
or actual React/Vue packages.

Changed files (for integration; BrowserActionQueue is intentionally absent):

- `.plans/113-focus-free-agent-input/implementation-focus-safe-input.md`
- `Sources/ContinuumRevived/App/BrowserActionExecutor.swift`
- `Sources/ContinuumRevived/App/BrowserAutomationEngineChecks.swift`
- `Sources/ContinuumRevived/App/BrowserControlHardeningChecks.swift`
- `Sources/ContinuumRevived/App/BrowserFocusRestorationChecks.swift`
- `Sources/ContinuumRevived/App/BrowserNativeSelectPreflightChecks.swift`
- `Sources/ContinuumRevived/App/BrowserSelectChecks.swift`
- `Sources/ContinuumRevived/App/ContinuumApp.swift`
- `Sources/ContinuumRevived/App/StrictAgentHarnessChecks.swift`
- `Sources/ContinuumRevived/App/WorkspaceAPIBrowserChecks.swift`
- `Sources/ContinuumRevived/App/WorkspaceAPIService+Browser.swift`
- `Sources/ContinuumRevived/App/WorkspaceAPIService.swift`
- `Sources/ContinuumRevived/BrowserEngine/BrowserAutomation.swift`
- `Sources/ContinuumRevived/BrowserEngine/BrowserAutomationScript.swift`
- `Sources/ContinuumRevivedCore/Agents/ArrayWorkspaceTool.swift`
- `Sources/ContinuumRevivedCore/Resources/PiExtensions/array-workspace-tools.json`
- `Sources/ContinuumRevivedCore/WorkspaceAPI/WorkspaceAPIContracts+Browser.swift`
- `Sources/ContinuumRevivedCore/WorkspaceAPI/WorkspaceAPIContracts+Canvas.swift`
- `Sources/ContinuumRevivedCore/WorkspaceAPI/WorkspaceAPIContracts.swift`
- `Sources/ContinuumRevivedCoreChecks/RoleRegistryChecks.swift`
- `Sources/ContinuumRevivedCoreChecks/WorkspaceAPIAgentsContractChecks.swift`
- `Sources/ContinuumRevivedCoreChecks/WorkspaceAPIContractChecks.swift`
- `Sources/ContinuumRevivedCoreChecks/WorkspaceMCPChecks.swift`
- `docs/38-tickets/90-agent-ux/matrix-inventory.txt`
- `scripts/run-matrix.sh`

## Combined Stage 1 branch: array/focus-free-input

This section supersedes the branch-only integration notes and gate receipt
above. The local branch merges `array/focus-safe-input` at `99e30b04` with
`array/tile-sharing-contract` through `f777a433`. Main checkout and
`array/integration` are untouched; there is no push or version bump.

Reconciled behavior:

- SELECT metadata, listing, mutation and native activation refusal use opaque,
  document-qualified refs and the shared document epoch. Navigation rejects old
  refs. Typing checks both host responder and DOM ref focus across awaits.
- All select paths use the common action identity/retry session and structured
  result. Listings have effects `none`; successful selection is `committed`;
  atomic validation failures and native SELECT refusal are rejected with effects
  `none`. Selection reconciliation failure is `unknown`, requires a fresh
  snapshot and permits only the same retry key.
- Focus loss during typing reports code `outcome_unknown` with structured state
  and effects `partial`, the delivered prefix count, retry
  `observe_before_new_action`, and `freshSnapshotRequired=true`.
- SELECT listing and picking both respect durable user takeover. Inspecting a
  paused tile cannot reacquire its lease or hide Return to agent. Return to agent
  must be followed by a fresh snapshot before selection can resume.
- Workspace API contract and exposure checks explicitly include browser.select.
  BrowserActionQueue.swift has three small integration changes: the shared
  effects classifier treats a SELECT listing as a read for retry persistence and
  result decoration. The service still requires control for this operation.

The combined targeted matrix ran once, not the full matrix. Its 17 reported
legs were inventory, eleven app witnesses and five CoreChecks arms. Fifteen
passed initially; select and workspace-api-browser failed. The select failure
exposed a production integration bug: a reader snapshot touched the paused
agent's lease and hid Return to agent. WorkspaceAPIService+Browser.swift now
keeps a user-held read from rearming that gate or clearing handback state. The
select witness was red then green across this correction.

The API fixture had retained a deliberate user takeover into its separate
renderer-recovery scenario. It now returns control through the real tile action
and obtains a fresh snapshot first. A further fixture-only failure came from
snapshotting a directly spawned user browser across its initial about:blank
commit. The new epoch check correctly rejected that snapshot (effects none);
the fixture waits for this initial navigation to finish instead of weakening
the production epoch guard. The call helper includes the fixture line in errors.

Focus observed through public makeFirstResponder tracing and production tools:
`Ordinary agent click: responderBorrowObserved=true,
originalResponderAfterAction=false`. The ordinary click still takes first
responder, and this fixture's original composer was not restored by completion.
Stage 1 is not focus-free native input. During typing, the sibling managed-agent
composer received all five user keystrokes and persisted them in its draft;
the page retained only five agent characters. The sibling retained focus. The
agent saw `outcome_unknown`, `state=partial`, `effects=partial`,
`deliveredCharacters=5`, `retry=observe_before_new_action`, and a required fresh
snapshot. The count is an observed prefix, not a promise of total application
side effects.

Universal popup lifetime remains open. Known HTML SELECT activation paths are
refused before native dispatch, and semantic selection avoids the native popup.
Public APIs do not enforce suppression for arbitrary page handlers, immediate
or delayed/cached showPicker calls, closed shadow trees, the check/dispatch race,
or already-open native popup cancellation. No universal guarantee is claimed.

Combined run leg receipt (`/tmp/focus-combined-stage1.log`):

| Leg | Initial result |
| --- | --- |
| scripts/check-matrix-inventory.sh | pass |
| --browser-focus-restoration-check | pass |
| --browser-select-check | fail, then pass after paused-read fix |
| --browser-native-select-preflight-check | pass |
| --browser-automation-engine-check | pass |
| --workspace-api-browser-check | fail; fixture corrections described above |
| --browser-unrelated-input-check | pass |
| --browser-ref-identity-check | pass |
| --browser-action-results-check | pass |
| --browser-writer-transfer-check | pass |
| --browser-durable-takeover-check | pass; affected-neighbor rerun also exit 0 |
| --browser-action-queue-check | pass |
| --workspace-api-exposure-check | pass |
| --workspace-api-contract-check | pass |
| --workspace-api-agents-contract-check | pass |
| --workspace-mcp-check | pass |
| --role-registry-check | pass |

Debug Array and CoreChecks builds in the combined run succeeded. The subsequent
Array rebuilds also exited 0 before using their binaries. Select rerun log:
`/tmp/combined--browser-select-check.log`; takeover neighbor:
`/tmp/focus-durable-rerun.log`. Only affected legs were rerun. Shell syntax and
`git diff --check` passed. `scripts/benches.sh` ran without reclaiming other
benches; this bench remains for local integration review.

Final affected API rerun: exit 0, with
`Workspace browser API: MCP browser operations, ownership, permissions,
residency, caps, restart and popup passed` in `/tmp/focus-api-final.log`. This
also completed the fifteen embedded browser hardening scenarios. A sample
while it was running showed the deliberate queued site-approval wait, not a
blocked chrome sendEvent; no change was made for that wait.

All 17 combined legs now have passing results: fifteen on the single combined
run, the two failures on affected reruns after their fixes. The takeover
neighbor also passed its affected rerun. No second combined matrix or full
matrix was run. Final debug Array build exited 0 (`/tmp/focus-integration-final-build.log`);
CoreChecks was unchanged after its successful combined-run build and arms.
