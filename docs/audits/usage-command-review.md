# Command timing review revision

Revises unintegrated 64e4e6d9 after independent review 93307530.
Production collection remains OFF (`qaCommandTimingEnabled = false`).

## Source and provider provenance

- `CodexEventTranslator.translateItemStarted/Completed` normalizes exec
  `command_execution` item.started/item.completed frames. Its end supplies
  `exitCode`, not `shellOutcome`. Shapes match CodexAgentBackendChecks.
- `CodexAppServerEventTranslator.translateItemStarted/Completed` normalizes
  app-server `commandExecution` item/started and item/completed notifications.
  Its end also supplies `exitCode`, not `shellOutcome`. Shapes match the
  command cases in CodexAppServerParityChecks.
- `PiEventTranslator` tool_execution_start/end accepts provider `ts` strings
  for transcript observations. This behavior is preserved for its other
  consumers. The timing writer now requires an explicit receipt date, sampled
  at entry to `AgentSupervisor.ingestRuntimeObservation`; it cannot silently
  fall back to the tool detail's potentially provider-authored timestamp.
- A normal ended observation bounds host receipt time even when the provider
  gives no exit code/outcome (Pi/Claude can do this). It does not establish
  success. Explicit incomplete outcomes always leave duration unknown.

The extended `--settings-usage-check` uses production translators with their
actual end-frame shapes, `qaObserveSharedTranscript` through production
supervisor ingestion, the production ledger and reader, UsageReport, and
rendered Settings words. It supplies no synthetic succeeded shell outcome.
Exec and app-server have distinct Codex records; Pi has its own Pi record.
The fixture clock makes supervisor receipts 12/7/5 seconds apart. Translator
clocks deliberately disagree; Pi `ts` values are an hour apart. Exact receipt
source and harness provenance are asserted in the persisted ledger.

## Review fixes

1. Duration no longer requires the absent Codex success/failure shell outcome.
2. Receipt timing uses one supervisor clock. Old timing rows without explicit
   `supervisorReceipt` provenance stay readable with unknown duration.
3. The Settings write event invalidates live correlations on recording changes,
   including off/on with no intervening observations. Disabled observations
   also invalidate spans. Observer lifecycle follows managed settings wiring.
4. The consent control says "Record token usage and command timing" and its
   help explains that both stop, while prior records remain. Off-state wording
   names both. Setting ids/defaults keys are unchanged.
5. Coverage is labeled "measured", not "ended". Incomplete ends remain unknown.

Host span UUIDs separate durable rows from provider ids. A reused provider id
gets a separate unknown span, because an old late end cannot be disambiguated;
seen provider ids are rebuilt on restart. A restart drops live spans, and a late
end cannot recreate deleted task rows. No prose, quality, stages, context counts,
or execution-time estimate was added.

## Verification

Ran with ARRAY_AGENT_ID/TMUX/TMUX_PANE unset, TERM=xterm-256color,
CONTINUUM_SKIP_UI_BASELINES=1, stdin /dev/null; preserved the inherited
managed crash marker. No tmux command, production app action or provider
process/auth was used. SDKROOT was exported from xcrun before each build.

- Resource checks before the three builds: swift-build count 3/2/1,
  memory free 38/53/47 percent, disk free 51/49/52 GiB.
- First witness build passed (435 s). Baseline provider/supervisor run failed:
  `[nil, nil, nil]` instead of `[12,7,5]`, disclosure omitted command timing,
  and coverage was labeled ended. Log: /tmp/usage-command-review-red-check.log.
- Tightened witness build passed (72 s). Before the fixes, the same flag
  additionally failed the off/on-no-observations correlation and reused-id
  assertions. Log: /tmp/usage-command-review-red2-check.log. The consent
  assertion watches end-row persistence, so an already-unknown duration
  cannot hide a retained span.
- After-fix build passed (247 s). Extended --settings-usage-check passed:
  /tmp/usage-command-review-green-check.log. It checks the three production
  translators through supervisor ingestion, exact receipt intervals and
  persisted source/harness, Settings writes across off/on, reused ids,
  rendered measured coverage, restart with an old end, id reuse after
  restart, backgrounded/timed-out/interrupted ends despite exit 0, legacy
  rows without receipt provenance, late end after deletion, and existing
  hidden-pane/export/delete/large-ledger behavior.
- Existing matrix registration remains scripts/run-matrix.sh's
  --settings-usage-check; no new flag or unregistered witness was added.
  Full matrix was not run, and its summary has not reported this revision.
- Inspected provider-commands-light.png, provider-commands-dark.png and both
  lower captures in /tmp/usage-page. Command details, measured coverage,
  recording label and help wrap within existing rows with no clipping;
  luminance checks passed. No new control or UI pattern.
- git diff --check passed. Bench inventory was run for this revision.

The old audit documents 64e4e6d9 historically; this note supersedes its receipt,
end-status, consent and coverage claims.

Remaining limits: these are offline translator/supervisor
fixtures shaped from the existing schema checks, not new live-provider captures. Full combined matrix and sibling
re-review remain required before any enablement decision. No child reviewer
attempt will be made.

The broader --settings-panel-check also passed:
/tmp/usage-command-review-settings-panel.log. The literal flag was confirmed
in ContinuumApp.swift before invocation. Both Settings checks used the same
isolated test environment described above.

Re-review questions: does the receipt-only definition remain clear when an
ended frame omits exit status; are clock/harness provenance and legacy unknown
handling sufficient; does the Settings-event invalidation cover the intended
production consent writes; and is conservative unknown handling of reused
provider ids acceptable? Review the new provider/supervisor witness rather than
the older direct-writer fixture alone. No enablement is part of this revision.
