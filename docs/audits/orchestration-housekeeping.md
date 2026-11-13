# Gaps 14–19 and housekeeping audit

Baseline: 83993fa5. Bench: `.worktrees/gaps-housekeeping`.

| Gap | Finding at baseline | Disposition |
|---|---|---|
| 14 | Usage deletion exists through `SettingsUsageModel.delete` in `App/Settings/SettingsUsagePane.swift` and `ManagedRunLedger.delete`. Stage/build timings are not recorded; later quality/context slices are explicitly excluded in `docs/internals/settings-usage-page.md`. | Deletion is implemented, not newly verified here. OPEN: new timing events and later quality/context/task-evidence views remain in scope. Disclosure row still needs owner's visual judgment. |
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
- Final committed-manifest fixture result: 44 passed, 0 failed.
- `python3 scripts/gate-prepass.py 83993fa5 e8faf92a`: 0 failures,
  0 advisories; manifest maps 11 of 486 full-run legs.

No Swift builds, full matrix, app self-checks, UI captures, tmux, provider or
live-pilot checks were run. Existing production witnesses were located, not
re-executed. Resource snapshot: 2 swift-build processes, 29% free memory,
64 GiB available; no build followed it. Managed crash marker preserved.

Independent review requested through `array_delegate`: Claude refused due
exhausted account usage; Codex refused because spawn depth 3 exceeds cap 2.
Lead was asked to delegate review from its own level. Review remains pending;
this commit is not approved for landing on the strength of this audit.


## Remaining scope and bounded next changes

These are OPEN 0.7.49 programme gaps, not closed by being switched off or by
being omitted from the current release document. The master plan is read
from `array/agent-standards:.plans/116-agent-standards/plans/README.md`;
individual plans below are in that same branch and folder. Wave sequencing
explains dependencies, not permission to mark incomplete work done.

### 14: usage slices — OPEN

Master section b explicitly puts command time and context word counts in
wave 2's first slice, quality/time in wave 3, review findings and stage in
wave 4. `usage-page.md`, Build order 1–3, confirms this. Consequently the
current first slice falls short even of the original wave-2 definition.
An expanded token table for one task already exists; the full task evidence,
checks and stage view remains OPEN, rather than the whole opened-row feature
being absent.

Bounded implementation order:

1. Add typed command duration/category rows through the one writer
   `Sources/ContinuumRevived/App/ManagedRunLedger.swift`; consume through
   `Sources/ContinuumRevivedCore/Agents/RunLedgerUsageReader.swift` and
   `UsageReport.swift`. Provider outcomes that lack an observed end remain
   unknown. Never infer build time from a reported pass or an agent's prose.
2. Add context size facts from the actual assembled injection, classified
   Array/project/personal, with unavailable CLI-owned layers explicitly
   unknown. Record counts/hashes only, never personal text. This depends on
   the layer source definition in part 18, not a scan of arbitrary user files.
3. Add integration/stage events in part 11/12, then project durations and the
   expanded task evidence view; add quality only from typed host observations.
   Review findings still require part 10; do not derive quality rates from
   unverified `AgentReport` declarations.

Extend the existing production `--settings-usage-check` for each slice:
fixture ledger -> report -> rendered words, including unknown values, an
open task excluded from rates, and no work while the pane is hidden. Require
light/dark captures for UI changes. Writer/reader restart and old-ledger
compatibility need separate assertions. Existing registration is in
`scripts/run-matrix.sh`; this audit did not run that app leg.

### 16: automatic pre-pass — OPEN

`gate-pre-pass.md`, Build order step 3, requires the final merged range before
review, plus helper ranges before reporting. Master section e puts the
pre-pass before review and requires timing evidence. Running its fixture in
the matrix is not that wiring.

Recommended host integration point: a **new immutable candidate-ready event**
in part 11, carrying the task id, checkout identity and host-captured base and
head object ids. There is no equivalent existing event in the current ledger.
`AgentSupervisor.fileReport` currently persists a declaration then calls
`ManagedRunLedger.reported` asynchronously; neither carries a base/head range.
A report's check claims must not be treated as a candidate-ready event.

Have that new event enqueue a dedicated utility worker and return immediately.
Keep it off `runnerLaunch`, provider event translation, hook replies, and the
ledger's append queue: a slow pre-pass must not delay telemetry writes. Use a
host-trusted packaged evaluator, not automatic execution of a script writable
inside the agent's checkout. Run it read-only against explicit revisions with
bounded process time/output, preserving the managed crash marker and isolated
process environment. No builds, app launches or tmux in the worker. Key results
by repository identity, base, head, evaluator and manifest versions; a changed
head invalidates the result. Missing base, invalid refs, subprocess timeout or
script error are unknown/error, never a clean pass. A report arriving early
still returns immediately and the lead may say integrated; a later review
request consumes only the result for its exact candidate. No inferred verified
status and no automatic user message are added by this worker.

Before enabling scheduling: drive the production candidate entry with a
fixture repository and controllable worker. Prove it returns while the worker
is held, ordinary launch/event delivery proceeds, findings/unmapped paths reach
the review request, a changed head invalidates an in-flight result, restart
cannot attach a stale result, and errors cannot become a pass. Register the
witness in the matrix and observe its leg. Measure end-to-end report/launch
latency and pre-review p95 on real diffs; asynchronous dispatch alone does not
prove no added wall time. Keep automatic scheduling OFF until these pass.
No scheduling implementation is claimed by this audit.

### 17: tool context cost — OPEN

No dedicated plan covers total tool-description cost (handoff gap 17).
It is nevertheless within the programme's original context-cost goal;
master parts 5, 17 and 18 require measured reduction with hazard preservation.
Do not confuse handoff gap numbers with the master plan's part numbers.

Bounded first change: a deterministic offline context-size census over the
production `WorkspaceMCPToolCatalog` projection (`mcpDescription`, inputSchema,
`serverInstructions`) for each delivery mode and feature flag combination.
Count authored descriptions, rendered guidelines and parameter descriptions
separately, in whitespace words and bytes, not guessed tokens. This can feed
part 21's context section without changing what agents receive. Add a
behavioral serialization witness, then propose one redundant-description
removal at a time. Preserve operation identity, constraints and error recovery;
compare actual first-turn payloads and matched task outcomes before enabling
a shorter catalogue. Lead tool pinning is separately documented as a startup
cost/reliability tradeoff; do not silently remove it to make the census smaller.

### 18: helper diet — OPEN

Master part 5 explicitly places probes in wave 1, skill policy in wave 2, and
slim files behind parts 16/17. `helper-context-diet.md`, Build order 1–3,
requires live prompt inspection as well as fake-CLI delegation witnesses.
Existing historical probes prove little saving; they do not prove memory
absence, compaction safety or hazard preservation.

Bounded first implementation: persisted helper-only launch policy, OFF by
default, propagated through actual delegation/retry/resume and every harness
configuration. Capturing fake CLIs witness argv/settings composition and show
that leads remain unaffected. Enable only individually proven switches after
OAuth-safe live prompt captures include fresh, resume and compaction cases.
Never use Claude `--bare`, modify global CLI files, or treat a memory feature
name as proof. Record unsupported cases explicitly. Slim project context
still waits on reviewed part-17 destinations and representative hazard tasks.
A CLI switch is not a filesystem privacy boundary.

### 19: adoption — OPEN

Master wave 4 assigns adoption to part 17 after replay and retrieval. Handoff
requires human semantic reading, because the trace check proves presence, not
force. Bounded next step: present the full rule-to-destination trace plus exact
slim-file diff for Dylan's semantic review; resolve weakened/ambiguous rules,
then run representative hazard tasks before changing active instructions.
No instruction replacement is justified merely by a passing word-count or
trace-presence check.

## Follow-up verification limits

This follow-up inspected master and individual plans plus production source;
no production changes, builds, new behavioral checks, live provider calls or
preview app were made. Independent review is still pending at the lead level
because both delegation attempts above were refused. The eight explicit
register-or-declare decisions close that housekeeping classification only;
they add **zero nightly behavioral coverage**.


## Independent review revision

Reviewer DB6D4A31 requested changes on `e8faf92a`; it was not integrated.
The reviewer correctly identified that deterministic/offscreen behavior had
been excluded without an unattended incompatibility. This revision supersedes
the eight targeted-only decisions above:

| Flag | Revised decision | Implementation evidence |
|---|---|---|
| `--tidy-packer-check` | Register Core gate leg | `Sources/ContinuumRevivedCoreChecks/TidyPackerChecks.swift`: seeded corpus through production solve; optional PNG output omitted. |
| `--tidy-offscreen-defer-check` | Register app gate leg | `Sources/ContinuumRevived/App/TidyOffscreenDeferChecks.swift`: offscreen fixture, synthetic menu dispatch, parking/resize outcomes. |
| `--tidy-zone-shortcut-check` | Register app gate leg | `Sources/ContinuumRevived/App/AutoLayoutTidyLatencyChecks.swift`, `runShortcut`: mounts 12 tiles, synthesizes chord, asserts dispatch/commit. Earlier 89-tile latency description was wrong. |
| `--undo-toast-placement-check` | Register app gate leg | `Sources/ContinuumRevived/App/UndoToastPlacementChecks.swift`: offscreen production window, isolated defaults, geometry assertions; optional renders omitted. |
| `--tidy-camera-check` | Register app gate leg | `Sources/ContinuumRevived/App/TidyCameraChecks.swift`: offscreen fixture and synthetic events, asserts camera/undo outcomes. No demonstrated unattended incompatibility. |
| `--auto-layout-tidy-latency-check` | Register app gate leg | `AutoLayoutTidyLatencyChecks.run`: offscreen synthetic fixtures and behavioral/timing assertions, writes disposable qa-runs output. No demonstrated unattended incompatibility. |
| `--browser-focus-free-real-key-check` | Targeted only | `Sources/ContinuumRevived/App/BrowserFocusRestorationChecks.swift`, `runBrowserFocusFreeRealKeyCheck`: explicitly requires `ARRAY_ALLOW_REAL_KEY_PROOF=1`, external prior foreground PID, activation and real input. Unattended gate must not opt into this. |
| `--browser-pointer-real-active-check` | Targeted only, retired refusal | `Sources/ContinuumRevived/App/BrowserPointerRealActiveChecks.swift`: always throws REFUSED, preserving recognition to prevent an old command booting the full app. Earlier description as a current real-pointer experiment was wrong. |

The six new literal invocations are in `scripts/run-matrix.sh` adjacent to the
existing auto-layout fanout leg. Inventory is regenerated through
`scripts/check-matrix-inventory.sh` with
`CONTINUUM_UPDATE_MATRIX_INVENTORY=1`. These are existing behavioral witnesses;
no source-string tests were added as behavior proof. Registration and inventory
validation do not prove that the six app/Core outcomes pass. No full matrix
summary showing these six executions is available from this bench. No new
KNOWN-RED exclusions were added. Re-review requested through the lead.
