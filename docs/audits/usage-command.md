# Command timing slice

Bench: gaps-usage-command, baseline 83993fa5.

Feasibility: production AgentToolDetailObservation has observedAt on starts
and ends, keyed by provider call id, plus a separately reportedDuration.
The proposed ledger records the host observation interval only. Provider
buffering can compress that interval; it is not execution CPU time or a
provider duration. No duration is inferred from prose or reported passes.

Classification is deliberately limited to simple swift build and swift test;
compound, wrapped and all other commands have unknown category. Missing,
backgrounded, interrupted, timed-out and uncorrelated ends remain unknown.
The ledger retains no command text/output. Starts remain durable unknowns
across restart; correlation state is live only. Old ledgers have no command
facts and display not recorded. Task detail shows observed sums and ended
coverage, with no rates or comparison of open tasks. Existing Settings rows
render the text; the pane remains a snapshot reader with no hidden work.

Production collection remains OFF pending independent sibling review and
combined gate validation. Lead should specifically review provider batching,
classification limits, telemetry-off transitions, call-id lifetime, and the
supervisor observation seam before enabling collection.

## Verification performed

- Prepared GhosttyKit with scripts/prepare-ghosttykit.sh.
- Before each build: observed respectively 3/3/3 swift-build processes,
  31/55/45 percent free memory, 55/65/64 GiB free disk; SDKROOT exported
  from xcrun. Builds used swift build --product Array -j 2.
- Baseline build passed (745 s). Changed old-ledger rendered-word assertion
  failed: old detail omitted command-time unknown/not-recorded disclosure.
  RED log: /tmp/usage-command-red-check.log.
- First implementation build failed: Command lacked Codable needed by the
  exported TaskLine. Added the conformance; next build passed (352 s).
- Extended --settings-usage-check passed, including production writer ->
  reader -> UsageReport -> rendered Settings text (12 s build, missing check
  end unknown, compound category unknown), restart preserving facts,
  old-ledger disclosure, hidden-pane inactivity and existing export/delete/
  large-ledger cases. GREEN log: /tmp/usage-command-green-check.log.
- Inspected /tmp/usage-page/commands-light.png and commands-dark.png: text
  wraps within the existing detail row without clipping. Luminance checks
  passed. No new UI component or pattern.
- Tests unset ARRAY_AGENT_ID/TMUX/TMUX_PANE, set TERM=xterm-256color and
  CONTINUUM_SKIP_UI_BASELINES=1, stdin /dev/null. Managed crash marker retained.
  No tmux command or real provider was used.
- Existing matrix registration: scripts/run-matrix.sh --settings-usage-check.
  Full matrix was NOT run, so no claim its summary reported this extension.
- RED-before/GREEN-after established the legacy disclosure regression.
  A disabled-writer mutation also failed `command starts not read`
  (/tmp/usage-command-mutation2-check.log). The first attempted mutation did
  not disable the writer: Swift parsed the following Void expression as the
  return value; that run passed and establishes no mutation protection.
  Correcting it to `return;` produced the expected RED. Mutation build
  preflights: 3 processes, 46/52 percent memory free, 61/59 GiB disk free.
  Final restore preflight: 3 processes, 38 percent memory, 58 GiB disk.
  Supervisor-to-runner/live-provider timing is not witnessed here.
  These are explicit enablement limits; production collection stays OFF.

## Review requested from lead

Please delegate independent sibling review (child review is blocked):
1. Are receipt intervals and narrow swift build/test categories sufficiently
   honest for this slice, especially buffered provider events?
2. Does the supervisor seam cover all intended harnesses without replay,
   and what live/mutation witnesses are needed before enabling it?
3. Review recording-off transitions, duplicate ids, deleted-task late ends,
   and turn/restart correlation cleanup. Off/on transitions mid-command are
   not separately witnessed; do not enable collection until resolved.

Bench remains available for review. No main-checkout edits, prod app action,
provider auth action, default tmux access, global Git config or push.

Final restoration: swift build --product Array -j 2 passed (71 s), followed
by a passing --settings-usage-check (/tmp/usage-command-final-check.log).
Both initial and final scripts/benches.sh inventories completed; this bench
is retained for lead review. All temporary writer mutations were removed.
