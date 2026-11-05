# Stage 1 input safety implementation

Bench: `.worktrees/focus-safe-input`, release base `d41dad04`.

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

The fix removes restoration spanning type awaits, invalidates synchronous
click/key restoration on input anywhere in Array (without broadening browser
ownership takeover), and restores only while the current responder belongs to
the target web view. Typing stops before additional native keys when focus has
left that web view. The error explicitly says a prefix may already exist and
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
