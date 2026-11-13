# Gaps 14–19 and housekeeping audit

Baseline: 83993fa5. Bench: `.worktrees/gaps-housekeeping`.

| Gap | Finding at baseline | Disposition |
|---|---|---|
| 14 | Usage deletion exists through `SettingsUsageModel.delete` in `App/Settings/SettingsUsagePane.swift` and `ManagedRunLedger.delete`. Stage/build timings are not recorded; later quality/context slices are explicitly excluded in `docs/internals/settings-usage-page.md`. | Deletion is implemented, not newly verified here. New timing events and later views remain product work. Disclosure row still needs owner's visual judgment. |
| 15 | `ProjectStandards.presence` bounds launch discovery to 512 entries; `ProjectStandardsPresence` caches directory stamps. Full index re-stats every file to detect in-place edits, off-main. `toolListNote` explicitly discloses restart-required availability. | Earlier discovery cost was addressed. Full index remains O(files); dynamic tool registration remains deferred, not silently promised. Existing checks: `--project-standards-index-check`, `--standards-resolution-check`. |
| 16 | Matrix line 764 runs the pre-pass fixture, not an actual change-range report. Coverage manifest maps 11 checks and explicitly reports unmapped changes. Bundle harness invocation is now mapped; FAST=0 handling is witnessed by the fixture suite. | Automatic change-range pre-pass remains OPEN. Mapping all legs remains OPEN. No automatic base/head selection policy was invented here. |
| 17 | Tool descriptions remain substantial. Managed Claude leads intentionally pin three tools (documented startup cost in `managed-lead-tool-loading.md` and `orchestration-release.md`). | Context cost remains OPEN; removing tool instructions without paired evidence would enable an unproven behavior change. |
| 18 | Helper diet is not implemented or measured on real repositories. | OPEN product work. No new switch enabled. |
| 19 | Slim files, layers and standards remain drafts; handoff explicitly requires a human semantic review before adoption. | OPEN adoption decision; no personal or project instructions replaced. |

## Housekeeping

The eight listed flags are neither registered nor targeted-only at baseline.
An earlier audit message incorrectly said they were declared: that statement
was corrected after reading the actual `targetedOnly` array, which contains
only `--managed-run-ledger-timing-check` and `--managed-launch-timing-check`.
This commit adds explicit targeted-only declarations for all eight. They do
not acquire nightly coverage. Five are AppKit tidy/geometry/latency probes,
two require real browser input, and one is a Core tidy corpus. The Core corpus
is suitable for future gate registration; the declaration makes today's
coverage limit explicit without claiming a run.

Three static effort lists remain at `AgentModelConfig.swift:64`,
`AgentProviders/ClaudeAgentRunner.swift:54`, and
`AgentProviders/CodexAgentRunner.swift:41`. The main launch path consults live
catalogue efforts (`AgentSupervisor.launchEffort`) but falls back to a static
list when absent. This remains OPEN; removing it requires behavioral launch
and catalogue witnesses. No claim that housekeeping is fully closed.

Historical subject rewording is deferred to the owner; no history rewritten.
Pi login remains CLI-owned. Other benches were inventoried, not removed:
their owners and uncommitted work were not established safe to delete.

## Verification and review

Ran with `ARRAY_AGENT_ID`, `TMUX`, `TMUX_PANE` unset, `TERM=xterm-256color`,
`CONTINUUM_SKIP_UI_BASELINES=1`, stdin `/dev/null`:

- `python3 scripts/check-gate-prepass.py`: 44 passed, 0 failed at baseline.
  Includes behavioral RED/GREEN fixture histories for missing registration,
  targeted-only declaration, removed declaration and missing reason; this
  suite is registered in `scripts/run-matrix.sh`.
- Final committed-manifest fixture result is reported separately by the agent.

No Swift builds, full matrix, app self-checks, UI captures, tmux, provider or
live-pilot checks were run. Existing production witnesses were located, not
re-executed. Resource snapshot: 2 swift-build processes, 29% free memory,
64 GiB available; no build followed it. Managed crash marker preserved.

Independent review requested through `array_delegate`: Claude refused due
exhausted account usage; Codex refused because spawn depth 3 exceeds cap 2.
Lead was asked to delegate review from its own level. Review remains pending;
this commit is not approved for landing on the strength of this audit.
